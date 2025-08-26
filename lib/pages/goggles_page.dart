import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeshy/pages/pairing_sheet.dart';
import 'package:zeshy/services/ble_provisioning_service.dart';

class GogglesPage extends StatefulWidget {
  const GogglesPage({super.key});
  @override
  State<GogglesPage> createState() => _GogglesPageState();
}

class _GogglesPageState extends State<GogglesPage> {
  // BLE 业务：给弹窗复用
  final _svc = BleProvisioningService();

  // 控件（共享给弹窗，便于保留输入）
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameFilterCtrl = TextEditingController(text: 'PROV_');

  String _connStatus = '未连接';
  String _provStatus = '—';
  String _log = '';
  bool _scanning = false; // 仅用于主页面小圈圈

  // —— 画面 & 刷新 —— //
  String? _deviceIp; // 持久化，BLE 不在也能用
  bool _streamError = false;
  int _streamEpoch = 0;

  // —— IMU（速度）—— //
  Timer? _imuTimer;
  int? _lastTs;
  double _vx = 0, _vy = 0, _vz = 0;
  double _speed = 0;

  // —— 主页面常驻订阅 —— //
  StreamSubscription<String>? _statSubMain;

  static const _kLastIpKey = 'last_device_ip';

  @override
  void initState() {
    super.initState();
    _loadLastIpAndTryUse();
    _listenStatInPage(); // 常驻监听 STAT
  }

  void _listenStatInPage() {
    _statSubMain?.cancel();
    _statSubMain = _svc.statusStream.listen((txt) async {
      _appendLog('[STAT-MAIN] $txt');

      if (txt.startsWith('wifi_ok:')) {
        final ip = txt.substring('wifi_ok:'.length).trim();
        await _saveLastIp(ip);
        if (!mounted) return;
        setState(() {
          _deviceIp = ip;
          _provStatus = '已连上 Wi-Fi';
          _streamError = false;
          _streamEpoch++; // 触发 MJPEG 重连
        });
        _startImuLoop();
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
        _startImuLoop();
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

  // —— IMU：启动/停止拉取 & 速度 —— //
  void _startImuLoop() {
    _imuTimer?.cancel();
    final ip = _deviceIp;
    if (ip == null) return;
    _imuTimer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      try {
        final r = await http.get(Uri.parse('http://$ip/imu'),
            headers: const {'Cache-Control': 'no-cache'});
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          _updateSpeedFromImu(j);
        }
      } catch (_) {}
    });
  }

  void _stopImuLoop() {
    _imuTimer?.cancel();
    _imuTimer = null;
  }

  void _updateSpeedFromImu(Map<String, dynamic> m) {
    final ts = (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final dt = (_lastTs == null) ? 0.05 : (ts - _lastTs!) / 1000.0;
    _lastTs = ts;

    final ax = (m['ax'] ?? 0).toDouble();
    final ay = (m['ay'] ?? 0).toDouble();
    final az = (m['az'] ?? 0).toDouble();

    final roll  = math.atan2(ay, az);
    final pitch = math.atan2(-ax, math.sqrt(ay*ay + az*az));

    const g = 9.80665;
    final ax_ms2 = ax * g;
    final ay_ms2 = ay * g;
    final az_ms2 = az * g;

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

  // —— 刷新 MJPEG —— //
  void _resetStream() {
    _streamError = false;
    _streamEpoch++;
    setState(() {});
  }

  // —— 打开底部弹窗（关闭后必定复位扫描）—— //
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
          _startImuLoop();
        },
        onScanningChanged: (b) => setState(() => _scanning = b),
        initialDeviceIp: _deviceIp,
      ),
    );

    try {
      await _svc.stopScan();
    } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  @override
  void dispose() {
    _statSubMain?.cancel();
    _stopImuLoop();
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

    // 计算两块状态卡片的对称宽度
    final totalW = MediaQuery.of(context).size.width;
    const hPad = 50.0;             // 与页面左右留白保持一致
    const gap = 20.0;              // 两卡片间距
    final avail = totalW - hPad * 2;
    final tileW = ((avail - gap) / 2).clamp(120.0, 180.0);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5), // ★ 整页背景：#F5F5F5
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: insets + 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部：居中大图 + 状态行 + 配对按钮
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Center(
                      child: Image.asset(
                        'assets/pictures/goggles.png',
                        width: 200,
                        height: 200,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // —— 状态卡片：一排、居中、对称、等宽、扁平 —— //
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _StatusTile(
                          width: tileW,
                          title: '连接',
                          value: _connStatus,
                          color: _statusColor(_connStatus, isConn: true),
                          // 成功不显示对号 —— 不放任何图标
                        ),
                        const SizedBox(width: gap),
                        _StatusTile(
                          width: tileW,
                          title: '配网',
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

              // 实时画面 + 速度叠加 + 刷新按钮
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(20),   // 统一更大圆角
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),   // 保证流画面也被裁剪
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
                                    child: Text(
                                      'MJPEG 错误：$err\n请点击右上角刷新',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.red),
                                    ),
                                  );
                                },
                              ),
                            )
                          else
                            Positioned.fill(
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  _deviceIp == null
                                      ? '未获取到设备 IP。\n可先用“配对设备”完成配网或等待加载上次 IP。'
                                      : '流已断开（可能超时）\n请点击右上角刷新',
                                  textAlign: TextAlign.center,
                                  style: textTheme.titleMedium,
                                ),
                              ),
                            ),

                          // 左上：速度叠加
                          Positioned(
                            left: 8,
                            top: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.45),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '速度：${_speed.toStringAsFixed(2)} m/s',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),

                          // 右上：刷新按钮
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Tooltip(
                              message: '刷新视频流',
                              child: Material(
                                color: Colors.black.withOpacity(0.25),
                                shape: const CircleBorder(),
                                child: IconButton(
                                  icon: const Icon(Icons.refresh, color: Colors.white),
                                  onPressed: (_deviceIp == null)
                                      ? null
                                      : () {
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
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            _log.isEmpty ? '（暂无）' : _log,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12.5,
                            ),
                          ),
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

/* ------------------------- 视觉组件 & 辅助函数 ------------------------- */

/// 状态色（按内容区分：连接/配网；成功态不显示图标，仅颜色）
Color _statusColor(String s, {required bool isConn}) {
  // 基础色系（连接偏蓝，配网偏紫，更易区分）
  const connBase = Color(0xFF2563EB); // 蓝
  const provBase = Color(0xFF7C3AED); // 紫

  final base = isConn ? connBase : provBase;

  if (s.contains('已连接') || s.contains('已连上')) {
    return base; // 成功：主色
  }
  if (s.contains('失败') || s.contains('错误') || s.contains('找不到')) {
    return const Color(0xFFEF4444); // 错误：红
  }
  if (s.contains('连接中') || s.contains('正在')) {
    return const Color(0xFFF59E0B); // 进行中：琥珀
  }
  return const Color(0xFF64748B);   // 默认：灰蓝
}

/// 扁平风“状态卡片”——等宽、等高、无图标（满足“成功不需要对号”）
class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.title,
    required this.value,
    required this.color,
    required this.width,
  });

  final String title;
  final String value;
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    final bg = color.withOpacity(.15);   // 背景淡色
    final tx = color;                    // 文本主色

    return SizedBox(
      width: width,
      height: 36, // 小巧
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20), // 更圆润
        ),
        child: Center(
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                color: tx,
                fontWeight: FontWeight.w700,
                letterSpacing: .2,
              ),
              children: [
                TextSpan(text: '$title：'),
                TextSpan(
                  text: value,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// 主 CTA 胶囊按钮（扁平风）
class _PrimaryCTA extends StatelessWidget {
  const _PrimaryCTA({
    required this.label,
    required this.icon,
    this.onTap,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    return Material(
      color: enabled ? cs.primary : cs.surfaceVariant,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              else
                Icon(icon, size: 18, color: enabled ? cs.onPrimary : cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? cs.onPrimary : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
