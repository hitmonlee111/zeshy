// lib/pages/goggles_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' show DeviceConnectionState;

import 'package:zeshy/pages/download_and_compose_page.dart';
import 'package:zeshy/pages/pairing_sheet.dart';
import 'package:zeshy/services/ble_provisioning_service.dart';

class GogglesPage extends StatefulWidget {
  const GogglesPage({super.key});
  @override
  State<GogglesPage> createState() => _GogglesPageState();
}

class _GogglesPageState extends State<GogglesPage> with WidgetsBindingObserver {
  final _svc = BleProvisioningService();
  final _nameFilterCtrl = TextEditingController(text: 'DBG_');

  String _connStatus = '未连接';
  String _provStatus = '—';
  String _log = '';
  bool _scanning = false;

  String? _deviceIp;
  bool _ipAlive = false;
  bool _streamError = false;
  int _streamEpoch = 0;

  StreamSubscription<String>? _statSubMain;
  StreamSubscription<DeviceConnectionState>? _connSub;
  Timer? _hbTimer;
  int _hbMiss = 0;
  static const _hbPeriod = Duration(seconds: 3);
  static const _hbTolerance = 3;
  static const _kLastIpKey = 'last_device_ip';

  // 下载期间“网络占用”标志（暂停 MJPEG + 心跳）
  bool _netHeld = false;

  // 新增：状态守望（兜底自愈 UI）
  Timer? _consistencyTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);  // 监听前后台
    _loadLastIpAndTryUse();
    _listenBleConnState();
    _listenStatInPage();
    _startConsistencyWatchdog();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 关键：回前台时重绑订阅 + 立即刷新一次真实状态
    if (state == AppLifecycleState.resumed) {
      _appendLog('App resumed，重绑订阅并刷新状态。');
      _listenBleConnState();   // 保险：重订阅 BLE 连接流
      _listenStatInPage();     // 重订阅 STAT（固件 onSubscribe 会推送上次状态）
      if (!_netHeld) _startHeartbeat();
      _refreshStatuses();      // 主动探测 /status + 回填 BLE 文案
    } else if (state == AppLifecycleState.paused) {
      _appendLog('App paused，暂停心跳。');
      _stopHeartbeat();
    }
  }

  void _startConsistencyWatchdog() {
    _consistencyTimer?.cancel();
    _consistencyTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      if (!_netHeld && _deviceIp != null) {
        _refreshStatuses();
      }
    });
  }

  Future<void> _refreshStatuses() async {
    // 1) 网络 + IP：直接探测 /status
    final ip = _deviceIp;
    if (ip != null) {
      final ok = await _probeIp(ip);
      if (!mounted) return;
      setState(() {
        _ipAlive = ok;
        if (ok) {
          // 如果 UI 还显示离线/—，拉回到“热点就绪”
          if (_provStatus == '—' || _provStatus.contains('离线')) {
            _provStatus = '热点就绪';
          }
        } else {
          _provStatus = '热点离线';
        }
      });
      if (ok) _resetStream(); // 回前台后 MJPEG 可能超时，成功就刷新
    }

    // 2) BLE 文案回填：利用 service 的最近状态
    final st = _svc.isConnectedSync ? '已连接' : '未连接';
    if (mounted && _connStatus != st) {
      setState(() => _connStatus = st);
    }
  }

  void _listenBleConnState() {
    _connSub?.cancel();
    _connSub = _svc.connectionState.listen((s) {
      switch (s) {
        case DeviceConnectionState.connecting:
          _setConn('连接中…'); break;
        case DeviceConnectionState.connected:
          _setConn('已连接'); break;
        case DeviceConnectionState.disconnected:
          _setConn('未连接'); break;
        case DeviceConnectionState.disconnecting:
          _setConn('断开中…'); break;
        default:
          _setConn(s.toString());
      }
    });
    // 立即用 service 的同步状态回填一次（防止刚进入时状态为空）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_svc.isConnectedSync) {
        _setConn('已连接');
      }
    });
  }

  void _setConn(String s) {
    if (!mounted) return;
    setState(() => _connStatus = s);
  }

  void _listenStatInPage() {
    _statSubMain?.cancel();
    _statSubMain = _svc.statusStream.listen((txt) async {
      _appendLog('[STAT] $txt');
      if (txt.startsWith('ap_on:')) {
        final ip = txt.substring('ap_on:'.length).trim();
        await _acceptNewIp(ip, label: '热点已开启');
      } else if (txt.contains('ap_off')) {
        _stopHeartbeat();
        if (mounted) {
          setState(() {
            _provStatus = '热点已关闭';
            _ipAlive = false;
          });
        }
      } else if (txt.contains('ble_connected')) {
        _setConn('已连接');
      }
    });
  }

  Future<void> _acceptNewIp(String ip, {required String label}) async {
    await _saveLastIp(ip);
    if (!mounted) return;
    setState(() {
      _deviceIp = ip;
      _provStatus = label;
      _streamError = false;
      _ipAlive = true;
      _streamEpoch++;
    });
    if (!_netHeld) _startHeartbeat();
  }

  void _startHeartbeat() {
    _hbTimer?.cancel();
    _hbMiss = 0;
    if (_deviceIp == null) return;
    _hbTimer = Timer.periodic(_hbPeriod, (_) async {
      if (_netHeld) return; // 被占用时不探活
      final ok = await _probeIp(_deviceIp!);
      if (!mounted) return;
      if (ok) {
        if (!_ipAlive) setState(() => _ipAlive = true);
        _hbMiss = 0;
      } else {
        _hbMiss++;
        if (_hbMiss >= _hbTolerance) {
          if (_ipAlive) {
            setState(() {
              _ipAlive = false;
              _provStatus = '热点离线';
            });
          }
        }
      }
    });
  }

  void _stopHeartbeat() {
    _hbTimer?.cancel();
    _hbTimer = null;
    _hbMiss = 0;
  }

  // 统一在进入/退出下载页时“挂起/恢复网络”
  void _holdNetwork(bool hold) {
    if (_netHeld == hold) return;
    setState(() {
      _netHeld = hold;
      _streamError = false;
    });
    if (hold) {
      _stopHeartbeat();
    } else {
      _startHeartbeat();
      _resetStream();
    }
  }

  Future<void> _loadLastIpAndTryUse() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final ip = sp.getString(_kLastIpKey);
      if (ip == null || ip.isEmpty) return;
      if (await _probeIp(ip)) {
        if (!mounted) return;
        setState(() {
          _deviceIp = ip;
          _ipAlive = true;
        });
        _resetStream();
        _appendLog('使用上次保存的 IP：$ip');
        if (!_netHeld) _startHeartbeat();
      } else {
        _appendLog('上次 IP 不可用：$ip');
      }
    } catch (_) {}
  }

  Future<void> _saveLastIp(String ip) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLastIpKey, ip);
      _appendLog('已保存 IP：$ip');
    } catch (_) {}
  }

  Future<bool> _probeIp(String ip) async {
    try {
      final r = await http
          .get(Uri.parse('http://$ip/status'))
          .timeout(const Duration(milliseconds: 900));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _appendLog(String s) {
    setState(() {
      _log += '${DateTime.now().toIso8601String().substring(11, 19)}  $s\n';
    });
  }

  void _resetStream() {
    _streamError = false;
    _streamEpoch++;
    setState(() {});
  }

  Future<void> _openPairingSheet() async {
    setState(() => _scanning = false);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFF5F5F5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => PairingSheet(
        svc: _svc,
        nameFilterCtrl: _nameFilterCtrl,
        onLog: _appendLog,
        onConnStatus: (s) => setState(() => _connStatus = s),
        onProvStatus: (s) => setState(() => _provStatus = s),
        onDeviceIp: (ip) async {
          await _acceptNewIp(ip, label: '热点就绪');
        },
        onScanningChanged: (b) => setState(() => _scanning = b),
        initialDeviceIp: _deviceIp,
      ),
    );
    try { await _svc.stopScan(); } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _openDownload() async {
    if (_deviceIp == null || !_ipAlive) {
      _appendLog('未检测到热点，尝试开启 AP 并等待 IP…');
      try { await _svc.setAp(true); }
      catch (e) { _snack('开启热点失败：$e'); return; }

      final comp = Completer<void>();
      late final StreamSubscription sub;
      sub = _svc.statusStream.listen((s) async {
        if (s.startsWith('ap_on:')) {
          final ip = s.substring('ap_on:'.length).trim();
          await _acceptNewIp(ip, label: '热点已开启');
          comp.complete();
          await sub.cancel();
        }
      });
      try { await comp.future.timeout(const Duration(seconds: 10)); }
      catch (_) { await sub.cancel(); _snack('等待 AP IP 超时'); return; }
    }

    if (!mounted) return;
    if (_deviceIp == null || !_ipAlive) {
      _snack('热点不可用，请重试');
      return;
    }

    // 进入下载页前：挂起 MJPEG + 心跳
    _holdNetwork(true);
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => DownloadAndComposePage(deviceIp: _deviceIp!),
    ));
    // 返回后：恢复
    _holdNetwork(false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statSubMain?.cancel();
    _connSub?.cancel();
    _hbTimer?.cancel();
    _consistencyTimer?.cancel();
    _svc.dispose();
    _nameFilterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final textTheme = Theme.of(context).textTheme;

    final totalW = MediaQuery.of(context).size.width;
    const hPad = 50.0, gap = 20.0;
    final avail = totalW - hPad * 2;
    final tileW = ((avail - gap) / 2).clamp(120.0, 180.0);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: insets + 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Center(
                      child: Image.asset(
                        'assets/pictures/goggles.png',
                        width: 200, height: 200, fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _StatusTile(
                          width: tileW, title: '连接',
                          value: _connStatus,
                          color: _statusColor(_connStatus, isConn: true),
                        ),
                        const SizedBox(width: gap),
                        _StatusTile(
                          width: tileW, title: '网络',
                          value: _ipAlive ? _provStatus : (_provStatus == '—' ? '—' : '离线'),
                          color: _statusColor(_ipAlive ? _provStatus : '离线', isConn: false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.center,
                      child: _PrimaryCTA(
                        label: _scanning ? '正在扫描…' : '配对设备',
                        icon: _scanning ? Icons.sync : Icons.link,
                        busy: _scanning,
                        onTap: _scanning ? null : _openPairingSheet,
                      ),
                    ),
                  ],
                ),
              ),

              // 流（下载期间不创建 MJPEG 连接）
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 3))],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Stack(
                        children: [
                          if (!_netHeld && _deviceIp != null && !_streamError && _ipAlive)
                            Positioned.fill(
                              child: Mjpeg(
                                stream: 'http://${_deviceIp!}/stream?e=$_streamEpoch',
                                isLive: true,
                                timeout: const Duration(seconds: 6),
                                error: (ctx, err, st) {
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (mounted) setState(() => _streamError = true);
                                  });
                                  return Center(
                                    child: Text('MJPEG 错误：$err\n请点击右上角刷新',
                                        textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                                  );
                                },
                              ),
                            )
                          else
                            Positioned.fill(
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                                child: Text(
                                  _netHeld
                                      ? '下载处理中，已暂停实时流…'
                                      : _deviceIp == null
                                      ? '未获取到设备 IP。\n可通过“配对设备”→ 开启热点 或 等待加载上次 IP。'
                                      : (_ipAlive ? '流已断开（可能超时）\n请点击右上角刷新'
                                      : '热点离线或不可达，请检查设备。'),
                                  textAlign: TextAlign.center, style: textTheme.titleMedium,
                                ),
                              ),
                            ),
                          Positioned(
                            right: 8, top: 8,
                            child: Tooltip(
                              message: '刷新视频流',
                              child: Material(
                                color: Colors.black.withOpacity(0.25), shape: const CircleBorder(),
                                child: IconButton(
                                  icon: const Icon(Icons.refresh, color: Colors.white),
                                  onPressed: (_deviceIp == null || !_ipAlive || _netHeld) ? null : () {
                                    _resetStream();
                                    _appendLog('手动刷新 MJPEG 流。');
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // 底部操作
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _netHeld ? null : _openDownload,
                        icon: const Icon(Icons.download),
                        label: const Text('下载视频'),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // 日志
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('日志', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 140),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(border: Border.all(color: Colors.black12), borderRadius: BorderRadius.circular(8)),
                        child: SingleChildScrollView(
                          child: Text(_log.isEmpty ? '（暂无）' : _log, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _statusColor(String s, {required bool isConn}) {
  const connBase = Color(0xFF2563EB);
  const provBase = Color(0xFF7C3AED);
  final base = isConn ? connBase : provBase;

  if (s.contains('已连接') || s.contains('热点已开启') || s.contains('就绪')) return base;
  if (s.contains('离线')) return const Color(0xFFEF4444);
  if (s.contains('连接中')) return const Color(0xFFF59E0B);
  return const Color(0xFF64748B);
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.title, required this.value, required this.color, required this.width});
  final String title; final String value; final Color color; final double width;
  @override
  Widget build(BuildContext context) {
    final bg = color.withOpacity(.15), tx = color;
    return SizedBox(
      width: width, height: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Center(
          child: RichText(
            text: TextSpan(
              style: TextStyle(color: tx, fontWeight: FontWeight.w700, letterSpacing: .2),
              children: [
                TextSpan(text: '$title：'),
                TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w900)),
              ],
            ),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _PrimaryCTA extends StatelessWidget {
  const _PrimaryCTA({required this.label, required this.icon, this.onTap, this.busy = false});
  final String label; final IconData icon; final VoidCallback? onTap; final bool busy;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final enabled = onTap != null;
    return Material(
      color: enabled ? cs.primary : cs.surfaceVariant, shape: const StadiumBorder(), clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap, customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (busy)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
            else
              Icon(icon, size: 18, color: enabled ? cs.onPrimary : cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: enabled ? cs.onPrimary : cs.onSurfaceVariant, fontWeight: FontWeight.w800, letterSpacing: .3)),
          ]),
        ),
      ),
    );
  }
}
