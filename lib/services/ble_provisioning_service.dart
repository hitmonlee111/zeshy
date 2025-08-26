import 'dart:async';
import 'dart:convert';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// 简单异常类型
class BleProvError implements Exception {
  final String message;
  BleProvError(this.message);
  @override
  String toString() => 'BleProvError: $message';
}

/// GATT UUID 常量（与设备固件一致）
class ProvUuids {
  static final Uuid service = Uuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid ssid    = Uuid.parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid pass    = Uuid.parse("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid go      = Uuid.parse("6E400004-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid stat    = Uuid.parse("6E400005-B5A3-F393-E0A9-E50E24DCCA9E");
}

/// 设备发现结果（给上层用）
class ProvDevice {
  final String id;   // deviceId / MAC(安卓) / UUID(iOS)
  final String name; // 广播名（例如 PROV_xxxx）
  final int rssi;
  ProvDevice({required this.id, required this.name, required this.rssi});
}

/// BLE 配网接口层（无 UI/业务逻辑）
class BleProvisioningService {
  final FlutterReactiveBle _ble;

  BleProvisioningService({FlutterReactiveBle? ble})
      : _ble = ble ?? FlutterReactiveBle();

  // ---- 内部状态 ----
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _statNotifySub;

  String? _deviceId;
  QualifiedCharacteristic? _ssidChar, _passChar, _goChar, _statChar;

  final _statusController = StreamController<String>.broadcast();
  final _connStateController = StreamController<DeviceConnectionState>.broadcast();

  /// 设备状态通知（来自 STAT 特征或内部事件）
  Stream<String> get statusStream => _statusController.stream;

  /// 原生连接状态流（可选）
  Stream<DeviceConnectionState> get connectionState => _connStateController.stream;

  // ---------- 扫描 ----------
  /// 过滤扫描，返回包含 Service UUID 的设备流（上层自己做去重/列表）
  Stream<ProvDevice> scan({Duration? timeout}) {
    // 停掉旧扫描
    _scanSub?.cancel();
    final controller = StreamController<ProvDevice>();

    _scanSub = _ble
        .scanForDevices(withServices: [ProvUuids.service], scanMode: ScanMode.lowLatency)
        .listen((d) {
      controller.add(ProvDevice(id: d.id, name: d.name, rssi: d.rssi));
    }, onError: controller.addError);

    if (timeout != null) {
      Future.delayed(timeout, () async {
        await _scanSub?.cancel();
        await controller.close();
      });
    }
    return controller.stream;
  }

  Future<void> stopScan() async => _scanSub?.cancel();

  // ---------- 连接 / 断开 ----------
  Future<void> connect(String deviceId, {Duration? timeout}) async {
    await disconnect();

    final comp = Completer<void>();
    _connSub = _ble
        .connectToDevice(id: deviceId, connectionTimeout: timeout)
        .listen((update) async {
      _connStateController.add(update.connectionState);

      if (update.connectionState == DeviceConnectionState.connected) {
        _deviceId = deviceId;
        await _setupCharacteristics(deviceId);

        // 1) 申请较大 MTU（忽略失败）
        try { await _ble.requestMtu(deviceId: deviceId, mtu: 247); } catch (_) {}

        // 2) 订阅 STAT（分包重组）
        _startStatusNotify();

        // 3) 发一个“已连上 BLE”的状态给上层
        _statusController.add("ble_connected");

        // 4) 读一次快照（如果设备在我们订阅之前刚好写过一次）
        try {
          final snap = await readStatus();
          final s = snap.trim();
          if (s.isNotEmpty) _statusController.add(s);
        } catch (_) {}

        if (!comp.isCompleted) comp.complete();
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        _statusController.add("ble_disconnected");
        if (!comp.isCompleted) {
          comp.completeError(BleProvError("Disconnected before ready"));
        }
      }
    }, onError: (e) {
      if (!comp.isCompleted) comp.completeError(e);
    });

    return comp.future;
  }

  Future<void> disconnect() async {
    await _statNotifySub?.cancel();
    _statNotifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    _deviceId = null;
    _ssidChar = _passChar = _goChar = _statChar = null;
    _statBuf.clear();
  }

  // ---------- 写入/读取 ----------
  Future<void> writeSsid(String ssid) async {
    final ch = _ssidChar;
    if (ch == null) throw BleProvError("Not connected / SSID char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode(ssid));
  }

  Future<void> writePassword(String password) async {
    final ch = _passChar;
    if (ch == null) throw BleProvError("Not connected / PASS char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode(password));
  }

  /// 触发 GO=1，开始连 Wi-Fi
  Future<void> sendGo() async {
    final ch = _goChar;
    if (ch == null) throw BleProvError("Not connected / GO char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode("1"));
  }

  /// 读取当前 STAT 字符串（可选）
  Future<String> readStatus() async {
    final ch = _statChar;
    if (ch == null) throw BleProvError("Not connected / STAT char missing");
    final data = await _ble.readCharacteristic(ch);
    return _safeDecode(data).trim();
  }

  // ---------- 内部：发现特征 / 订阅 STAT（带分包重组） ----------
  Future<void> _setupCharacteristics(String deviceId) async {
    _ssidChar = QualifiedCharacteristic(
        deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.ssid);
    _passChar = QualifiedCharacteristic(
        deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.pass);
    _goChar = QualifiedCharacteristic(
        deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.go);
    _statChar = QualifiedCharacteristic(
        deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.stat);
  }

  // 用来拼接分包的缓冲区
  final StringBuffer _statBuf = StringBuffer();
  String? _lastWifiOkIp; // 简单去重

  void _startStatusNotify() {
    final ch = _statChar;
    if (ch == null) return;

    _statNotifySub?.cancel();
    _statNotifySub = _ble.subscribeToCharacteristic(ch).listen((data) {
      final chunk = _safeDecode(data);
      _handleStatChunk(chunk);
    }, onError: (e) {
      _statusController.add("stat_notify_error");
    });
  }

  // 处理分包/黏包：按行分发；同时在整个缓冲里匹配 wifi_ok:IP
  void _handleStatChunk(String chunk) {
    if (chunk.isEmpty) return;

    _statBuf.write(chunk);
    final whole = _statBuf.toString();

    // 1) 按行切分，把完整的行依次发出（末尾可能有半行，先保留在缓冲）
    final parts = whole.split(RegExp(r'[\r\n]+'));
    final endedWithNewline = RegExp(r'[\r\n]+$').hasMatch(whole);
    final completeCount = endedWithNewline ? parts.length : (parts.length - 1);

    for (var i = 0; i < completeCount; i++) {
      final line = parts[i].trim();
      if (line.isNotEmpty) {
        _statusController.add(line);
      }
    }

    // 2) 如果缓冲里包含 wifi_ok:IP，不论是否按行对齐，都额外发一次（去重）
    final match = RegExp(r'wifi_ok:\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})').firstMatch(whole);
    if (match != null) {
      final ip = match.group(1)!;
      if (ip != _lastWifiOkIp) {
        _lastWifiOkIp = ip;
        _statusController.add('wifi_ok:$ip');
      }
    }

    // 3) 只保留未完成的半行在缓冲中
    final leftover = endedWithNewline ? '' : parts.last;
    _statBuf
      ..clear()
      ..write(leftover);
  }

  String _safeDecode(List<int> data) {
    try {
      // 允许格式不规范的字节，尽量别抛异常
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      // 退化为直接字节串
      return String.fromCharCodes(data);
    }
  }

  Future<void> dispose() async {
    await stopScan();
    await disconnect();
    await _statusController.close();
    await _connStateController.close();
  }
}
