// pairing_sheet.dart —— 统一用 BleProvisioningService 托管连接与AP控制
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'package:zeshy/services/ble_provisioning_service.dart';

class PairingSheet extends StatefulWidget {
  const PairingSheet({
    super.key,
    required this.svc,
    required this.nameFilterCtrl,
    required this.onLog,
    required this.onConnStatus,
    required this.onProvStatus,
    required this.onDeviceIp,
    this.onScanningChanged,
    this.initialDeviceIp,
  });

  final BleProvisioningService svc;
  final TextEditingController nameFilterCtrl;
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
  // 仅用于扫描；连接/通知/AP 都交给 BleProvisioningService
  final _ble = FlutterReactiveBle();
  static final Uuid svcDbg = Uuid.parse("12345678-1234-5678-1234-56789abcdef0");

  final List<DiscoveredDevice> _devices = [];
  DiscoveredDevice? _selected;

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<DeviceConnectionState>? _connSub;
  StreamSubscription<String>? _statSub;

  bool _scanning = false;
  bool _busy = false;
  String? _currentIp;

  @override
  void initState() {
    super.initState();
    _currentIp = widget.initialDeviceIp;

    // 监听父级 svc 的连接状态（显示到本页标题区域 & 回调给外部）
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

    // 监听父级 svc 的 STAT（ap_on:IP / ap_off / 其他日志）
    _bindSvcStatusStream();

    // 初始把“配置状态”重置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onProvStatus('—');
    });
  }

  @override
  void dispose() {
    // 只停扫描、取消本页订阅；不主动断开 BLE（连接由父级 _svc 托管）
    _scanSub?.cancel();
    _connSub?.cancel();
    _statSub?.cancel();
    super.dispose();
  }

  /* ================= 扫描 ================= */

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
    widget.onLog('开始扫描…（过滤服务UUID）');

    _scanSub?.cancel();
    _scanSub = _ble.scanForDevices(withServices: [svcDbg], scanMode: ScanMode.lowLatency).listen((d) {
      final prefix = widget.nameFilterCtrl.text.trim();
      if (prefix.isNotEmpty && !d.name.startsWith(prefix)) return;
      if (_devices.any((x) => x.id == d.id)) return;
      setState(() {
        _devices.add(d);
        _selected ??= d;
      });
    }, onError: (e) {
      widget.onLog('扫描错误: $e');
      _snack('扫描错误: $e');
    });

    Future.delayed(const Duration(seconds: 10), _stopScan);
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    if (mounted) {
      setState(() => _scanning = false);
      widget.onScanningChanged?.call(false);
    }
  }

  /* ================= 连接（交给 _svc） ================= */

  Future<void> _connect() async {
    final dev = _selected;
    if (dev == null) { _snack('请先选择设备'); return; }

    setState(() => _busy = true);
    await _stopScan();

    widget.onLog('连接 ${dev.name} (${dev.id}) …');
    widget.onConnStatus('连接中…');

    try {
      await widget.svc.connect(dev.id, timeout: const Duration(seconds: 15));
      widget.onLog('连接成功（连接由父级 _svc 托管，关闭此页不会断开）。');
      // 连接建立后，STAT 里如果已经是 ap_on:IP，会被 _bindSvcStatusStream 捕获
    } catch (e) {
      widget.onLog('连接失败: $e');
      _snack('连接失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    // 用户明确点“断开”才断开
    await widget.svc.disconnect();
    widget.onLog('已断开 BLE。');
    widget.onConnStatus('未连接');
  }

  /* ================= STAT / AP（均走 _svc） ================= */

  void _bindSvcStatusStream() {
    _statSub?.cancel();
    _statSub = widget.svc.statusStream.listen((s) async {
      // 透传日志
      widget.onLog(s);
      widget.onProvStatus(s);

      // 捕获 ap_on:IP
      final ap = RegExp(r'^ap_on:\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})$').firstMatch(s);
      if (ap != null) {
        final ip = ap.group(1)!;
        setState(() => _currentIp = ip);
        await widget.onDeviceIp(ip);
      }

      if (s.contains('ap_off')) {
        setState(() => _currentIp = null);
      }
    });
  }

  Future<void> _apOn() async {
    try {
      await widget.svc.setAp(true);
      widget.onLog('请求开启 AP…（等待 STAT: ap_on:<IP>）');
      // 有些固件会立即上报，也有1~2秒延迟；_bindSvcStatusStream 会把 IP 告诉外层
    } catch (e) {
      _snack('开启 AP 失败: $e');
    }
  }

  Future<void> _apOff() async {
    try {
      await widget.svc.setAp(false);
      widget.onLog('已请求关闭 AP');
    } catch (e) {
      _snack('关闭 AP 失败: $e');
    }
  }

  /* ================= UI ================= */

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
        initialChildSize: 0.88,
        minChildSize: 0.55,
        maxChildSize: 0.98,
        builder: (_, controller) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    const Text('设备配对 / 下载设置',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (_scanning)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.all(16),
                  children: [
                    _Section(
                      title: '发现与连接',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SizedBox(
                                width: 240,
                                child: TextField(
                                  controller: widget.nameFilterCtrl,
                                  decoration: const InputDecoration(
                                    labelText: '名称过滤（如 DBG_，可留空）',
                                    border: OutlineInputBorder(),
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
                          const SizedBox(height: 10),
                          DropdownButtonFormField<DiscoveredDevice>(
                            value: _selected,
                            isExpanded: true,
                            items: _devices.map((d) => DropdownMenuItem(
                              value: d,
                              child: Text(
                                '${d.name.isEmpty ? "(无名设备)" : d.name}  [${d.rssi} dBm]',
                                overflow: TextOverflow.ellipsis,
                              ),
                            )).toList(),
                            onChanged: (v) => setState(() => _selected = v),
                            decoration: const InputDecoration(
                              labelText: '选择设备', border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              FilledButton.icon(
                                onPressed: _busy ? null : _connect,
                                icon: const Icon(Icons.link),
                                label: const Text('连接'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _disconnect,
                                icon: const Icon(Icons.link_off),
                                label: const Text('断开（仅 BLE）'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _Section(
                      title: '下载模式（设备热点 AP）',
                      subtitle: '通过 _svc 开启 AP，STAT 上报 "ap_on:<IP>" 后，以 HTTP 访问设备文件系统。',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8, runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: _apOn,
                                icon: const Icon(Icons.wifi),
                                label: const Text('开启热点'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _apOff,
                                icon: const Icon(Icons.wifi_off),
                                label: const Text('关闭热点'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.router, size: 18, color: Colors.black54),
                              const SizedBox(width: 6),
                              Text('设备 IP：${_currentIp ?? "—"}'),
                            ],
                          ),
                        ],
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

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.child});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.5,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, style: const TextStyle(color: Colors.black54)),
          ],
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }
}
