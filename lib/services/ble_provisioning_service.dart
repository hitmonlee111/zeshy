import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class BleProvisioningService {
  BleProvisioningService({
    Uuid? serviceUuid,
    Uuid? statUuid,
    Uuid? apCtrlUuid,
  })  : _svcUuid = serviceUuid ?? Uuid.parse("12345678-1234-5678-1234-56789abcdef0"),
        _statUuid = statUuid ?? Uuid.parse("12345678-1234-5678-1234-56789abcdef1"),
        _apUuid   = apCtrlUuid ?? Uuid.parse("12345678-1234-5678-1234-56789abcdef2");

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid _svcUuid;
  final Uuid _statUuid; // READ + NOTIFY
  final Uuid _apUuid;   // WRITE ("1"/"0")

  String? _deviceId;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _statSub;

  QualifiedCharacteristic? _chStat;
  QualifiedCharacteristic? _chAp;

  final _connCtrl = StreamController<DeviceConnectionState>.broadcast();
  Stream<DeviceConnectionState> get connectionState => _connCtrl.stream;

  final _statCtrl = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statCtrl.stream;

  // 新增：记录最近一次连接状态，供页面同步查询
  DeviceConnectionState? _lastState;
  DeviceConnectionState? get lastConnectionState => _lastState;
  bool get isConnectedSync => _lastState == DeviceConnectionState.connected;

  String? get currentDeviceId => _deviceId;

  Future<void> connect(String deviceId, {Duration timeout = const Duration(seconds: 15)}) async {
    if (_deviceId == deviceId && _chAp != null && _chStat != null) {
      _statCtrl.add('ble_connected');
      _connCtrl.add(DeviceConnectionState.connected);
      _lastState = DeviceConnectionState.connected;
      return;
    }

    await disconnect();

    _deviceId = deviceId;
    final completer = Completer<void>();

    _connSub = _ble
        .connectToDevice(id: deviceId, connectionTimeout: timeout)
        .listen((u) async {
      _connCtrl.add(u.connectionState);
      _lastState = u.connectionState;

      if (u.connectionState == DeviceConnectionState.connected) {
        try { await _ble.requestMtu(deviceId: deviceId, mtu: 185); } catch (_) {}

        _chStat = QualifiedCharacteristic(deviceId: deviceId, serviceId: _svcUuid, characteristicId: _statUuid);
        _chAp   = QualifiedCharacteristic(deviceId: deviceId, serviceId: _svcUuid, characteristicId: _apUuid);

        final ready = await _waitGattReady();
        if (!ready) {
          _statCtrl.add('ble_error:gatt_not_ready');
          if (!completer.isCompleted) completer.completeError('GATT not ready');
          return;
        }

        _bindStatNotifications();
        _statCtrl.add('ble_connected');
        if (!completer.isCompleted) completer.complete();
      } else if (u.connectionState == DeviceConnectionState.disconnected) {
        _teardown();
        _statCtrl.add('ble_disconnected');
        if (!completer.isCompleted) completer.completeError('disconnected');
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    return completer.future;
  }

  Future<void> disconnect() async {
    await _statSub?.cancel();
    _statSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _teardown();
    _lastState = DeviceConnectionState.disconnected;
  }

  Future<void> setAp(bool on) async {
    final ch = _chAp;
    if (ch == null) {
      throw StateError('AP characteristic not ready (not connected or not discovered)');
    }

    final data = on ? utf8.encode('1') : utf8.encode('0');

    try {
      await _ble.writeCharacteristicWithResponse(ch, value: data);
    } on PlatformException {
      await _ble.writeCharacteristicWithoutResponse(ch, value: data);
    }
  }

  Future<void> stopScan() async {
    // no-op
  }

  void dispose() {
    _statSub?.cancel();
    _connSub?.cancel();
    _connCtrl.close();
    _statCtrl.close();
  }

  Future<bool> _waitGattReady() async {
    for (int i = 0; i < 3; i++) {
      try {
        final v = await _ble.readCharacteristic(_chStat!);
        final s = _safeDecode(v).trim();
        if (s.isNotEmpty) _statCtrl.add('[STAT(read)] $s');
        return true;
      } on PlatformException {
        await Future.delayed(Duration(milliseconds: 250 + 150 * i));
        continue;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  void _bindStatNotifications() {
    final ch = _chStat;
    if (ch == null) return;

    _statSub?.cancel();
    _statSub = _ble.subscribeToCharacteristic(ch).listen((data) {
      final s = _safeDecode(data).trim();
      if (s.isEmpty) return;
      _statCtrl.add(s);
    }, onError: (e) {
      _statCtrl.add('ble_error:stat_subscribe:$e');
    });
  }

  void _teardown() {
    _chStat = null;
    _chAp = null;
    _deviceId = null;
  }

  String _safeDecode(List<int> d) {
    try { return utf8.decode(d, allowMalformed: true); }
    catch (_) { return String.fromCharCodes(d); }
  }
}
