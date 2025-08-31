import 'dart:async';
import 'dart:convert';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class BleProvError implements Exception {
  final String message;
  BleProvError(this.message);
  @override
  String toString() => 'BleProvError: $message';
}

class ProvUuids {
  static final Uuid service = Uuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid ssid    = Uuid.parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid pass    = Uuid.parse("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid go      = Uuid.parse("6E400004-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid stat    = Uuid.parse("6E400005-B5A3-F393-E0A9-E50E24DCCA9E");
}

class ImuUuids {
  static final Uuid service = Uuid.parse("7E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid imuNtf  = Uuid.parse("7E400002-B5A3-F393-E0A9-E50E24DCCA9E");
  static final Uuid apCtrl  = Uuid.parse("7E400003-B5A3-F393-E0A9-E50E24DCCA9E");
}

class ProvDevice {
  final String id;
  final String name;
  final int rssi;
  ProvDevice({required this.id, required this.name, required this.rssi});
}

class IMUSample {
  final int ts;     // ms since boot
  final double ax, ay, az; // g
  final double gx, gy, gz; // deg/s
  IMUSample({required this.ts, required this.ax, required this.ay, required this.az,
    required this.gx, required this.gy, required this.gz});
  factory IMUSample.fromJson(Map<String, dynamic> m) => IMUSample(
    ts: (m['ts'] as num).toInt(),
    ax: (m['ax'] as num).toDouble(),
    ay: (m['ay'] as num).toDouble(),
    az: (m['az'] as num).toDouble(),
    gx: (m['gx'] as num).toDouble(),
    gy: (m['gy'] as num).toDouble(),
    gz: (m['gz'] as num).toDouble(),
  );
}

class BleProvisioningService {
  final FlutterReactiveBle _ble;
  BleProvisioningService({FlutterReactiveBle? ble}) : _ble = ble ?? FlutterReactiveBle();

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  String? _deviceId;
  QualifiedCharacteristic? _ssidCh, _passCh, _goCh, _statCh;
  QualifiedCharacteristic? _imuNtfCh, _apCtrlCh;

  final _statusController = StreamController<String>.broadcast();
  final _connStateController = StreamController<DeviceConnectionState>.broadcast();
  final _imuController = StreamController<IMUSample>.broadcast();

  Stream<String> get statusStream => _statusController.stream;
  Stream<DeviceConnectionState> get connectionState => _connStateController.stream;
  Stream<IMUSample> get imuStream => _imuController.stream;

  // 扫描：用名字前缀即可（设备连接后不会再被扫到）
  Stream<ProvDevice> scan({Duration? timeout, String namePrefix = "PROV_"}) {
    _scanSub?.cancel();
    final ctrl = StreamController<ProvDevice>();
    _scanSub = _ble.scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency).listen(
          (d) {
        if (namePrefix.isNotEmpty && !d.name.startsWith(namePrefix)) return;
        ctrl.add(ProvDevice(id: d.id, name: d.name, rssi: d.rssi));
      },
      onError: ctrl.addError,
    );
    if (timeout != null) {
      Future.delayed(timeout, () async { await _scanSub?.cancel(); await ctrl.close(); });
    }
    return ctrl.stream;
  }

  Future<void> stopScan() async => _scanSub?.cancel();

  Future<void> connect(String deviceId, {Duration? timeout}) async {
    // 关键：连接前停止扫描，避免冲突
    await stopScan();
    await disconnect();

    final comp = Completer<void>();
    _connSub = _ble.connectToDevice(id: deviceId, connectionTimeout: timeout).listen((u) async {
      _connStateController.add(u.connectionState);

      if (u.connectionState == DeviceConnectionState.connected) {
        _deviceId = deviceId;
        await _setupChars(deviceId);

        try { await _ble.requestMtu(deviceId: deviceId, mtu: 247); } catch (_) {}

        _startStatNotify();                  // 订阅通知
        _statusController.add("ble_connected");

        // 读取一次快照（强制 GATT 读，确认畅通）
        try {
          final snap = await readStatus();
          if (snap.isNotEmpty) {
            // 逐行透传到上层，和 notify 行保持一致
            for (final line in snap.split(RegExp(r'[\r\n]+'))) {
              final t = line.trim();
              if (t.isNotEmpty) _statusController.add(t);
            }
          }
        } catch (_) {}

        if (!comp.isCompleted) comp.complete();
      } else if (u.connectionState == DeviceConnectionState.disconnected) {
        _statusController.add("ble_disconnected");
        if (!comp.isCompleted) comp.completeError(BleProvError("Disconnected before ready"));
      }
    }, onError: (e) {
      if (!comp.isCompleted) comp.completeError(e);
    });

    return comp.future;
  }

  Future<void> disconnect() async {
    await stopImu();
    _deviceId = null;
    _ssidCh = _passCh = _goCh = _statCh = null;
    _imuNtfCh = _apCtrlCh = null;
    await _connSub?.cancel(); _connSub = null;
  }

  Future<void> _setupChars(String deviceId) async {
    _ssidCh = QualifiedCharacteristic(deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.ssid);
    _passCh = QualifiedCharacteristic(deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.pass);
    _goCh   = QualifiedCharacteristic(deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.go);
    _statCh = QualifiedCharacteristic(deviceId: deviceId, serviceId: ProvUuids.service, characteristicId: ProvUuids.stat);

    _imuNtfCh = QualifiedCharacteristic(deviceId: deviceId, serviceId: ImuUuids.service, characteristicId: ImuUuids.imuNtf);
    _apCtrlCh = QualifiedCharacteristic(deviceId: deviceId, serviceId: ImuUuids.service, characteristicId: ImuUuids.apCtrl);
  }

  StreamSubscription<List<int>>? _statSub;
  void _startStatNotify() {
    final ch = _statCh; if (ch == null) return;
    _statSub?.cancel();
    _statSub = _ble.subscribeToCharacteristic(ch).listen((data) {
      final s = _safeDecode(data);
      for (final line in s.split(RegExp(r'[\r\n]+'))) {
        final t = line.trim();
        if (t.isNotEmpty) _statusController.add(t);
      }
    }, onError: (_) => _statusController.add("stat_notify_error"));
  }

  Future<void> writeSsid(String ssid) async {
    final ch = _ssidCh; if (ch == null) throw BleProvError("SSID char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode(ssid));
  }
  Future<void> writePassword(String pass) async {
    final ch = _passCh; if (ch == null) throw BleProvError("PASS char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode(pass));
  }
  Future<void> sendGo() async {
    final ch = _goCh; if (ch == null) throw BleProvError("GO char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode("1"));
  }
  Future<String> readStatus() async {
    final ch = _statCh; if (ch == null) throw BleProvError("STAT char missing");
    return _safeDecode(await _ble.readCharacteristic(ch)).trim();
  }

  Future<void> setAp(bool on) async {
    final ch = _apCtrlCh; if (ch == null) throw BleProvError("AP_CTRL char missing");
    await _ble.writeCharacteristicWithResponse(ch, value: utf8.encode(on ? "1" : "0"));
  }
  Future<void> apOn() => setAp(true);
  Future<void> apOff() => setAp(false);

  StreamSubscription<List<int>>? _imuSub;
  Future<void> startImu() async {
    final ch = _imuNtfCh; if (ch == null) throw BleProvError("IMU notify char missing");
    _imuSub?.cancel();
    _imuSub = _ble.subscribeToCharacteristic(ch).listen((data) {
      try {
        final m = jsonDecode(_safeDecode(data)) as Map<String, dynamic>;
        _imuController.add(IMUSample.fromJson(m));
      } catch (_) {}
    });
  }
  Future<void> stopImu() async { await _imuSub?.cancel(); _imuSub = null; }

  String _safeDecode(List<int> data) {
    try { return utf8.decode(data, allowMalformed: true); }
    catch (_) { return String.fromCharCodes(data); }
  }

  Future<void> dispose() async {
    await _scanSub?.cancel();
    await _connSub?.cancel();
    await _statSub?.cancel();
    await _imuSub?.cancel();
    await _statusController.close();
    await _connStateController.close();
    await _imuController.close();
  }
}
