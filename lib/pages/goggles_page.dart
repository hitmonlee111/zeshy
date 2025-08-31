// 保持你发来的内容结构，只改了下载面板请求与少量细节

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'package:zeshy/pages/pairing_sheet.dart';
import 'package:zeshy/services/ble_provisioning_service.dart';

class GogglesPage extends StatefulWidget {
  const GogglesPage({super.key});
  @override
  State<GogglesPage> createState() => _GogglesPageState();
}

class _GogglesPageState extends State<GogglesPage> {
  final _svc = BleProvisioningService();

  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameFilterCtrl = TextEditingController(text: 'PROV_');

  String _connStatus = '未连接';
  String _provStatus = '—';
  String _log = '';
  bool _scanning = false;

  String? _deviceIp;
  bool _streamError = false;
  int _streamEpoch = 0;

  StreamSubscription<IMUSample>? _imuSub;
  bool _imuOn = false;
  int? _lastTs;
  double _vx = 0, _vy = 0, _vz = 0;
  double _speed = 0;

  StreamSubscription<String>? _statSubMain;
  static const _kLastIpKey = 'last_device_ip';

  @override
  void initState() {
    super.initState();
    _loadLastIpAndTryUse();
    _listenStatInPage();
  }

  void _listenStatInPage() {
    _statSubMain?.cancel();
    _statSubMain = _svc.statusStream.listen((txt) async {
      _appendLog('[STAT-MAIN] $txt');

      if (txt.startsWith('ap_on:')) {
        final ip = txt.substring('ap_on:'.length).trim();
        await _saveLastIp(ip);
        if (!mounted) return;
        setState(() {
          _deviceIp = ip;
          _provStatus = '热点已开启';
          _streamError = false;
          _streamEpoch++;
        });
        return;
      }
      if (txt.startsWith('wifi_ok:')) {
        final ip = txt.substring('wifi_ok:'.length).trim();
        await _saveLastIp(ip);
        if (!mounted) return;
        setState(() {
          _deviceIp = ip;
          _provStatus = '已连上 Wi-Fi';
          _streamError = false;
          _streamEpoch++;
        });
        return;
      }
      if (txt.contains('wifi_connecting')) {
        if (mounted) setState(() => _provStatus = '设备正在连接 Wi-Fi…');
      } else if (txt.contains('wifi_fail_auth')) {
        if (mounted) setState(() => _provStatus = 'Wi-Fi 密码错误');
      } else if (txt.contains('wifi_fail_notfound')) {
        if (mounted) setState(() => _provStatus = '找不到该 SSID');
      } else if (txt.contains('ble_connected')) {
        if (mounted) setState(() => _connStatus = '已连接');
      } else if (txt.contains('ap_off')) {
        if (mounted) setState(() => _provStatus = '热点已关闭');
      }
    });
  }

  Future<void> _loadLastIpAndTryUse() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final ip = sp.getString(_kLastIpKey);
      if (ip == null || ip.isEmpty) return;
      if (await _probeIp(ip)) {
        setState(() => _deviceIp = ip);
        _resetStream();
        _appendLog('使用上次保存的 IP：$ip');
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

  // ---- BLE IMU 开关 ----
  Future<void> _toggleImu() async {
    if (_imuOn) {
      await _stopImuBle();
    } else {
      await _startImuBle();
    }
  }

  Future<void> _startImuBle() async {
    try {
      await _svc.startImu();
      _imuSub?.cancel();
      _imuSub = _svc.imuStream.listen(_updateSpeedFromImuSample);
      setState(() => _imuOn = true);
      _appendLog('IMU 订阅已开启（BLE）');
    } catch (e) {
      _snack('IMU 订阅失败: $e');
    }
  }

  Future<void> _stopImuBle() async {
    await _svc.stopImu();
    await _imuSub?.cancel();
    _imuSub = null;
    setState(() {
      _imuOn = false;
      _lastTs = null;
      _vx = _vy = _vz = 0;
      _speed = 0;
    });
    _appendLog('IMU 订阅已关闭');
  }

  void _updateSpeedFromImuSample(IMUSample s) {
    final ts = s.ts;
    final dt = (_lastTs == null) ? 0.04 : (ts - _lastTs!) / 1000.0; // 25Hz≈40ms
    _lastTs = ts;

    final ax = s.ax, ay = s.ay, az = s.az;

    final roll  = math.atan2(ay, az);
    final pitch = math.atan2(-ax, math.sqrt(ay*ay + az*az));

    const g = 9.80665;
    final ax_ms2 = ax * g, ay_ms2 = ay * g, az_ms2 = az * g;

    final sr = math.sin(roll),  cr = math.cos(roll);
    final sp = math.sin(pitch), cp = math.cos(pitch);

    final ax_w = ax_ms2 * cp + ay_ms2 * sr*sp + az_ms2 * cr*sp;
    final ay_w = ay_ms2 * cr - az_ms2 * sr;
    final az_w = -ax_ms2 * sp + ay_ms2 * sr*cp + az_ms2 * cr*cp;

    final lin_ax = ax_w;
    final lin_ay = ay_w;
    final lin_az = az_w - g;

    const decay = 0.985;
    _vx = (_vx + lin_ax * dt) * decay;
    _vy = (_vy + lin_ay * dt) * decay;
    _vz = (_vz + lin_az * dt) * decay;

    _speed = math.sqrt(_vx*_vx + _vy*_vy + _vz*_vz);
    if (mounted) setState(() {});
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
        ssidCtrl: _ssidCtrl,
        passCtrl: _passCtrl,
        onLog: _appendLog,
        onConnStatus: (s) => setState(() => _connStatus = s),
        onProvStatus: (s) => setState(() => _provStatus = s),
        onDeviceIp: (ip) async {
          await _saveLastIp(ip);
          if (!mounted) return;
          setState(() => _deviceIp = ip);
          _resetStream();
        },
        onScanningChanged: (b) => setState(() => _scanning = b),
        initialDeviceIp: _deviceIp,
      ),
    );

    try { await _svc.stopScan(); } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _openDownload() async {
    if (_deviceIp == null) {
      _appendLog('请求开启 AP 并等待 IP…');
      try { await _svc.setAp(true); }
      catch (e) { _snack('开启热点失败：$e'); return; }

      final comp = Completer<void>();
      late final StreamSubscription sub;
      sub = _svc.statusStream.listen((s) async {
        if (s.startsWith('ap_on:')) {
          final ip = s.substring('ap_on:'.length).trim();
          await _saveLastIp(ip);
          if (!mounted) return;
          setState(() => _deviceIp = ip);
          comp.complete();
          await sub.cancel();
        }
      });
      try { await comp.future.timeout(const Duration(seconds: 10)); }
      catch (_) { await sub.cancel(); _snack('等待 AP IP 超时'); return; }
    }

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _DownloadSheet(deviceIp: _deviceIp!, onLog: _appendLog),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _statSubMain?.cancel();
    _imuSub?.cancel();
    _svc.dispose();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
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
                          value: _provStatus,
                          color: _statusColor(_provStatus, isConn: false),
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

              // 流 + 速度
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
                          if (_deviceIp != null && !_streamError)
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
                                  _deviceIp == null
                                      ? '未获取到设备 IP。\n可通过“配对设备”→ 开启热点 或 等待加载上次 IP。'
                                      : '流已断开（可能超时）\n请点击右上角刷新',
                                  textAlign: TextAlign.center, style: textTheme.titleMedium,
                                ),
                              ),
                            ),
                          Positioned(
                            left: 8, top: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(12)),
                              child: Text(
                                '速度：${_speed.toStringAsFixed(2)} m/s',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
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
                                  onPressed: (_deviceIp == null) ? null : () { _resetStream(); _appendLog('手动刷新 MJPEG 流。'); },
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
                        onPressed: _toggleImu,
                        icon: Icon(_imuOn ? Icons.stop_circle_outlined : Icons.sensors),
                        label: Text(_imuOn ? '停止同步 IMU' : '同步 IMU'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _openDownload,
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

/* ------------------------- 下载弹窗 ------------------------- */

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({required this.deviceIp, required this.onLog});
  final String deviceIp;
  final void Function(String) onLog;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  bool _loading = true;
  List<String> _sessions = [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() => _loading = true);
    try {
      // 固件：/fs/list —— 返回 ["\/REC_...","\/REC_..."]
      final r = await http.get(Uri.parse('http://${widget.deviceIp}/fs/list'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final arr = (jsonDecode(r.body) as List).map((e) => e.toString()).toList();
        setState(() => _sessions = arr);
      } else {
        _toast('HTTP ${r.statusCode}');
      }
    } catch (e) {
      widget.onLog('加载会话失败: $e');
      _toast('加载会话失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _downloadSelected() async {
    if (_selected.isEmpty) return;
    final dir = await getApplicationDocumentsDirectory();

    for (final raw in _selected) {
      final sess = raw.startsWith('/') ? raw : '/$raw';
      final sessName = sess.replaceFirst('/', ''); // 本地目录名如 REC_1234
      final localSessDir = Directory('${dir.path}/$sessName');
      if (!await localSessDir.exists()) await localSessDir.create(recursive: true);

      // 1) 获取该会话下的文件列表
      final listUrl = 'http://${widget.deviceIp}/fs/list?session=${Uri.encodeComponent(sess)}';
      try {
        final lr = await http.get(Uri.parse(listUrl)).timeout(const Duration(seconds: 6));
        if (lr.statusCode != 200) { _toast('列文件失败: $sessName'); continue; }
        final files = (jsonDecode(lr.body) as List).map((e) => e.toString()).toList();

        // 2) 逐个拉取文件
        for (final p in files) {
          final path = p.startsWith('/') ? p : '/$p';
          final fname = path.split('/').last;
          final url = 'http://${widget.deviceIp}/fs/file?path=${Uri.encodeComponent(path)}';
          final fr = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 1));
          if (fr.statusCode == 200) {
            final out = File('${localSessDir.path}/$fname');
            await out.writeAsBytes(fr.bodyBytes);
          } else {
            _toast('下载失败: $fname (${fr.statusCode})');
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存到 ${localSessDir.path}')),
          );
        }
      } catch (e) {
        _toast('下载异常: $e');
      }
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    for (final raw in _selected.toList()) {
      final sess = raw.startsWith('/') ? raw : '/$raw';
      final url = 'http://${widget.deviceIp}/fs/delete?session=${Uri.encodeComponent(sess)}';
      try {
        final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          setState(() { _sessions.remove(raw); _selected.remove(raw); });
        } else {
          _toast('删除失败: HTTP ${r.statusCode}');
        }
      } catch (e) {
        _toast('删除异常: $e');
      }
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.55,
      maxChildSize: 0.98,
      builder: (_, controller) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Text('选择会话下载/删除', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _sessions.isEmpty
                  ? const Center(child: Text('暂无会话'))
                  : ListView.builder(
                controller: controller,
                itemCount: _sessions.length,
                itemBuilder: (_, i) {
                  final s = _sessions[i];
                  final picked = _selected.contains(s);
                  return ListTile(
                    title: Text(s, overflow: TextOverflow.ellipsis),
                    trailing: Checkbox(
                      value: picked,
                      onChanged: (v) {
                        setState(() { v == true ? _selected.add(s) : _selected.remove(s); });
                      },
                    ),
                    onTap: () {
                      setState(() {
                        picked ? _selected.remove(s) : _selected.add(s);
                      });
                    },
                  );
                },
              ),
            ),
            if (!_loading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _selected.isEmpty ? null : _downloadSelected,
                        icon: const Icon(Icons.download),
                        label: const Text('下载所选 (到本地文件夹)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _selected.isEmpty ? null : _deleteSelected,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('删除所选'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/* ------------------------- 视觉组件 & 辅助函数 ------------------------- */

Color _statusColor(String s, {required bool isConn}) {
  const connBase = Color(0xFF2563EB);
  const provBase = Color(0xFF7C3AED);
  final base = isConn ? connBase : provBase;

  if (s.contains('已连接') || s.contains('已连上') || s.contains('热点已开启')) return base;
  if (s.contains('失败') || s.contains('错误') || s.contains('找不到')) return const Color(0xFFEF4444);
  if (s.contains('连接中') || s.contains('正在')) return const Color(0xFFF59E0B);
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
