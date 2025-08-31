import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' show DeviceConnectionState;
import 'package:zeshy/services/ble_provisioning_service.dart';

class PairingSheet extends StatefulWidget {
  const PairingSheet({
    super.key,
    required this.svc,
    required this.nameFilterCtrl,
    required this.ssidCtrl,
    required this.passCtrl,
    required this.onLog,
    required this.onConnStatus,
    required this.onProvStatus,
    required this.onDeviceIp,
    this.onScanningChanged,
    this.initialDeviceIp,
  });

  final BleProvisioningService svc;
  final TextEditingController nameFilterCtrl;
  final TextEditingController ssidCtrl;
  final TextEditingController passCtrl;

  final void Function(String log) onLog;
  final void Function(String connStatus) onConnStatus;
  final void Function(String provStatus) onProvStatus;
  final Future<void> Function(String ip) onDeviceIp;
  final void Function(bool scanning)? onScanningChanged;

  final String? initialDeviceIp;

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet> {
  final List<ProvDevice> _devices = [];
  ProvDevice? _selected;

  StreamSubscription<ProvDevice>? _scanSub;
  StreamSubscription<DeviceConnectionState>? _connSub;
  StreamSubscription<String>? _statSub;
  StreamSubscription<IMUSample>? _imuSub;

  bool _scanning = false;
  bool _busy = false;

  IMUSample? _lastImu;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onProvStatus('—');
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _statSub?.cancel();
    _imuSub?.cancel();
    super.dispose();
  }

  Future<void> _ensurePerms() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> _startScan() async {
    await _ensurePerms();
    setState(() { _devices.clear(); _selected = null; _scanning = true; });
    widget.onScanningChanged?.call(true);
    widget.onProvStatus('—');
    widget.onLog('开始扫描…');

    _scanSub?.cancel();
    _scanSub = widget.svc.scan().listen((d) {
      final prefix = widget.nameFilterCtrl.text.trim();
      if (prefix.isNotEmpty && !d.name.startsWith(prefix)) return;
      if (_devices.any((x) => x.id == d.id)) return;
      setState(() { _devices.add(d); _selected ??= d; });
    }, onError: (e) {
      widget.onLog('扫描错误: $e');
    }, onDone: () {
      setState(() => _scanning = false);
      widget.onScanningChanged?.call(false);
      widget.onLog('扫描结束，共发现 ${_devices.length} 台设备。');
    });

    Future.delayed(const Duration(seconds: 10), () async { await _stopScan(); });
  }

  Future<void> _stopScan() async {
    await widget.svc.stopScan();
    if (mounted) { setState(() => _scanning = false); widget.onScanningChanged?.call(false); }
  }

  Future<void> _connect() async {
    final dev = _selected;
    if (dev == null) { _snack('请先选择设备'); return; }

    setState(() => _busy = true);
    widget.onLog('连接 ${dev.name} (${dev.id}) …');

    // ★ 关键：连接前确保停扫
    await _stopScan();

    _connSub?.cancel();
    _connSub = widget.svc.connectionState.listen((s) {
      final text = switch (s) {
        DeviceConnectionState.connecting => '连接中…',
        DeviceConnectionState.connected => '已连接 ✅',
        DeviceConnectionState.disconnecting => '断开中…',
        DeviceConnectionState.disconnected => '未连接',
        _ => s.toString(),
      };
      widget.onConnStatus(text);
    });

    try {
      await widget.svc.connect(dev.id, timeout: const Duration(seconds: 15));
      widget.onLog('连接成功。');

      // 绑定 STAT 流（含快照 & notify）
      _bindStatusStream();
    } catch (e) {
      widget.onLog('连接失败: $e');
      _snack('连接失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await _stopImu();
    await _statSub?.cancel(); _statSub = null;
    await widget.svc.disconnect();
    widget.onLog('已断开 BLE。');
    widget.onConnStatus('未连接');
  }

  void _bindStatusStream() {
    _statSub?.cancel();
    _statSub = widget.svc.statusStream.listen((s) async {
      widget.onLog(s);
      widget.onProvStatus(s);

      final ap = RegExp(r'^ap_on:(\d{1,3}(?:\.\d{1,3}){3})$').firstMatch(s);
      if (ap != null) { await widget.onDeviceIp(ap.group(1)!); return; }

      final m = RegExp(r'^wifi_ok:(\d{1,3}(?:\.\d{1,3}){3})$').firstMatch(s);
      if (m != null) { await widget.onDeviceIp(m.group(1)!); return; }
    });
  }

  Future<void> _provision() async {
    final ssid = widget.ssidCtrl.text.trim();
    final pass = widget.passCtrl.text;
    if (ssid.isEmpty) { _snack('请输入 SSID（2.4GHz）'); return; }

    setState(() => _busy = true);
    widget.onProvStatus('发送凭据中…');

    try {
      widget.onLog('写入 SSID …');  await widget.svc.writeSsid(ssid);
      widget.onLog('写入 Password …'); await widget.svc.writePassword(pass);
      widget.onLog('发送 GO=1 …'); await widget.svc.sendGo();
      widget.onProvStatus('设备正在连接 Wi-Fi…');
      _snack('已发送，观察状态…');
    } catch (e) {
      widget.onLog('配网指令失败: $e');
      _snack('配网失败，请看日志');
      widget.onProvStatus('失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apOn() async { try { await widget.svc.setAp(true); widget.onLog('请求开启 AP…'); } catch (e) { _snack('开启 AP 失败: $e'); } }
  Future<void> _apOff() async { try { await widget.svc.setAp(false); widget.onLog('已请求关闭 AP'); } catch (e) { _snack('关闭 AP 失败: $e'); } }

  Future<void> _startImu() async {
    try {
      await widget.svc.startImu();
      _imuSub?.cancel();
      _imuSub = widget.svc.imuStream.listen((s) { setState(() => _lastImu = s); });
      widget.onLog('IMU 订阅已开启（BLE）');
    } catch (e) {
      _snack('IMU 订阅失败: $e');
    }
  }
  Future<void> _stopImu() async {
    await widget.svc.stopImu();
    await _imuSub?.cancel(); _imuSub = null;
    setState(() => _lastImu = null);
    widget.onLog('IMU 订阅已关闭');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
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
                    const Text('设备配对 / 下载设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (_scanning)
                      const Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
              const Divider(height: 1),

              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Wrap(
                      spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 260,
                          child: TextField(
                            controller: widget.nameFilterCtrl,
                            decoration: const InputDecoration(
                              labelText: '名称过滤（如 PROV_，可留空）', border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _scanning ? _stopScan : _startScan,
                          icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
                          label: Text(_scanning ? '停止扫描' : '开始扫描'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    DropdownButtonFormField<ProvDevice>(
                      value: _selected, isExpanded: true,
                      items: _devices.map((d) => DropdownMenuItem(
                        value: d,
                        child: Text('${d.name.isEmpty ? '(无名设备)' : d.name}  [${d.rssi} dBm]', overflow: TextOverflow.ellipsis),
                      )).toList(),
                      onChanged: (v) => setState(() => _selected = v),
                      decoration: const InputDecoration(labelText: '选择设备', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton(onPressed: _busy ? null : _connect, child: const Text('连接')),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _disconnect, child: const Text('断开（仅 BLE）')),
                      ],
                    ),

                    const SizedBox(height: 16),

                    Card(
                      elevation: 1.5,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('下载模式（设备热点 AP）', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          const Text('下载/删除视频时，请先通过 BLE 开启 AP，收到 "ap_on:192.168.4.1" 后，App 以 HTTP 访问设备。'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8, runSpacing: 8,
                            children: [
                              FilledButton.icon(onPressed: _apOn, icon: const Icon(Icons.wifi), label: const Text('开启热点')),
                              OutlinedButton.icon(onPressed: _apOff, icon: const Icon(Icons.wifi_off), label: const Text('关闭热点')),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (widget.initialDeviceIp != null)
                            Text('当前设备 IP：${widget.initialDeviceIp}', style: const TextStyle(color: Colors.black54)),
                        ]),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Card(
                      elevation: 1.5,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('IMU 实时（BLE 预览，可选）', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          const Text('用于现场验证 BLE 链路；录制落盘数据在会话目录 imu.csv（时间戳与视频相对齐）。'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8, runSpacing: 8,
                            children: [
                              FilledButton.icon(onPressed: _startImu, icon: const Icon(Icons.sensors), label: const Text('开始 IMU')),
                              OutlinedButton.icon(onPressed: _stopImu, icon: const Icon(Icons.stop_circle_outlined), label: const Text('停止 IMU')),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_lastImu != null)
                            Text(
                              'ts=${_lastImu!.ts}ms  '
                                  'a=(${_lastImu!.ax.toStringAsFixed(2)}, ${_lastImu!.ay.toStringAsFixed(2)}, ${_lastImu!.az.toStringAsFixed(2)}) g  '
                                  'gyr=(${_lastImu!.gx.toStringAsFixed(1)}, ${_lastImu!.gy.toStringAsFixed(1)}, ${_lastImu!.gz.toStringAsFixed(1)}) °/s',
                              style: const TextStyle(fontFamily: 'monospace'),
                            )
                          else
                            const Text('尚无数据'),
                        ]),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Card(
                      elevation: 1.5,
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('可选：连接到路由器（测试用）', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          const Text('产品流程建议用 AP 下载；除非调试，不必连家庭路由器。'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8, runSpacing: 8,
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 420),
                                child: TextField(
                                  controller: widget.ssidCtrl,
                                  decoration: const InputDecoration(labelText: 'Wi-Fi SSID（2.4GHz）', border: OutlineInputBorder()),
                                ),
                              ),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 420),
                                child: TextField(
                                  controller: widget.passCtrl,
                                  decoration: const InputDecoration(labelText: 'Wi-Fi 密码', border: OutlineInputBorder()),
                                  obscureText: true,
                                ),
                              ),
                              SizedBox(
                                width: 220,
                                child: FilledButton.icon(
                                  onPressed: _busy ? null : _provision,
                                  icon: const Icon(Icons.send),
                                  label: Text(_busy ? '处理中…' : '发送凭据 + GO'),
                                ),
                              ),
                            ],
                          ),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
