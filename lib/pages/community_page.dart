// community_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// 新增：HUD视频合成 & 内置播放器
import 'package:video_player/video_player.dart';

import '../video/imu_video_generator.dart';

class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  final _ble = FlutterReactiveBle();

  // 与固件一致的 UUID
  static final Uuid svcDbg  = Uuid.parse("12345678-1234-5678-1234-56789abcdef0");
  static final Uuid stat    = Uuid.parse("12345678-1234-5678-1234-56789abcdef1"); // READ+NOTIFY
  static final Uuid apCtrl  = Uuid.parse("12345678-1234-5678-1234-56789abcdef2"); // WRITE "1"/"0"

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _statSub;

  final List<DiscoveredDevice> _found = [];
  DiscoveredDevice? _sel;
  String _conn = '未连接';
  final _log = StringBuffer();

  QualifiedCharacteristic? _chStat, _chAp;

  bool _scanning = false;

  // 记录 AP 的 IP（来自 STAT: ap_on:192.168.4.1）
  String? _apIp;

  @override
  void dispose() {
    _stopScan();
    _disconnect();
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
    setState(() {
      _found.clear();
      _sel = null;
      _scanning = true;
    });
    _append('开始扫描…(过滤包含调试服务UUID)');

    _scanSub?.cancel();
    _scanSub = _ble.scanForDevices(withServices: [svcDbg], scanMode: ScanMode.lowLatency)
        .listen((d) {
      if (!_found.any((x) => x.id == d.id)) {
        setState(() {
          _found.add(d);
          _sel ??= d;
        });
      }
    }, onError: (e) {
      _append('扫描错误: $e');
    });
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect() async {
    final dev = _sel;
    if (dev == null) {
      _snack('请选择一个设备');
      return;
    }
    await _stopScan();

    _append('连接 ${dev.name} (${dev.id}) …');
    _connSub?.cancel();
    final c = Completer<void>();

    _connSub = _ble
        .connectToDevice(id: dev.id, connectionTimeout: const Duration(seconds: 12))
        .listen((u) async {
      setState(() => _conn = u.connectionState.toString());
      if (u.connectionState == DeviceConnectionState.connected) {
        try { await _ble.requestMtu(deviceId: dev.id, mtu: 185); } catch (_) {}
        _chStat = QualifiedCharacteristic(deviceId: dev.id, serviceId: svcDbg, characteristicId: stat);
        _chAp   = QualifiedCharacteristic(deviceId: dev.id, serviceId: svcDbg, characteristicId: apCtrl);
        _bindStat();
        _append('连接成功。');
        if (!c.isCompleted) c.complete();
      } else if (u.connectionState == DeviceConnectionState.disconnected) {
        _append('已断开。');
        if (!c.isCompleted) c.completeError('disconnected');
      }
    }, onError: (e) {
      if (!c.isCompleted) c.completeError(e);
    });

    try {
      await c.future;
    } catch (e) {
      _snack('连接失败：$e');
    }
  }

  Future<void> _disconnect() async {
    await _statSub?.cancel();
    _statSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _chStat = _chAp = null;
    setState(() {
      _conn = '未连接';
      _apIp = null;
    });
  }

  void _bindStat() {
    final ch = _chStat;
    if (ch == null) return;
    _statSub?.cancel();

    _statSub = _ble.subscribeToCharacteristic(ch).listen((data) {
      final s = _safeDecode(data).trim();
      if (s.isEmpty) return;
      _append('[STAT] $s');

      // 抓取 ap_on:IP
      final m = RegExp(r'^ap_on:\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})$').firstMatch(s);
      if (m != null) {
        setState(() => _apIp = m.group(1));
        _snack('热点就绪：$_apIp（密码 12345678）');
      }
    }, onError: (e) {
      _append('STAT 订阅错误: $e');
    });

    // 读一次当前值
    () async {
      try {
        final v = await _ble.readCharacteristic(ch);
        final s = _safeDecode(v).trim();
        if (s.isNotEmpty) {
          _append('[STAT(read)] $s');
          final m = RegExp(r'^ap_on:\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})$').firstMatch(s);
          if (m != null) setState(() => _apIp = m.group(1));
        }
      } catch (e) {
        _append('读取 STAT 失败: $e');
      }
    }();
  }

  Future<void> _ap(bool on) async {
    final ch = _chAp;
    if (ch == null) {
      _snack('未连接/未发现 AP 控制特征');
      return;
    }
    try {
      await _ble.writeCharacteristicWithResponse(ch, value: on ? utf8.encode("1") : utf8.encode("0"));
      _append(on ? '已写入开启AP("1")' : '已写入关闭AP("0")');
      if (!on) setState(() => _apIp = null);
      if (on && _apIp == null) {
        // 固件 AP 的固定 IP
        setState(() => _apIp = '192.168.4.1');
      }
    } catch (e) {
      _snack('写入失败：$e');
    }
  }

  // 打开下载弹窗
  Future<void> _openDownload() async {
    final ip = _apIp;
    if (ip == null) {
      _snack('请先通过“开启热点”让设备进入 AP 模式');
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _DownloadSheet(
        deviceIp: ip,
        onLog: _append,
      ),
    );
  }

  // —— 工具 —— //
  void _append(String s) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    setState(() => _log.writeln('$t  $s'));
  }

  String _safeDecode(List<int> d) {
    try { return utf8.decode(d, allowMalformed: true); }
    catch (_) { return String.fromCharCodes(d); }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: _scanning ? _stopScan : _startScan,
              icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
              label: Text(_scanning ? '停止扫描' : '开始扫描'),
            ),
            FilledButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.link),
              label: const Text('连接所选'),
            ),
            OutlinedButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('断开'),
            ),
            // 视频下载入口（需要 AP IP）
            FilledButton.icon(
              onPressed: _apIp == null ? null : _openDownload,
              icon: const Icon(Icons.download),
              label: Text(_apIp == null ? '先开启热点' : '视频下载'),
            ),
          ]),
          const SizedBox(height: 8),

          DropdownButtonFormField<DiscoveredDevice>(
            value: _sel,
            items: _found.map((d) => DropdownMenuItem(
              value: d,
              child: Text('${d.name.isEmpty ? "(无名)" : d.name}  [${d.id}]'),
            )).toList(),
            onChanged: (v) => setState(() => _sel = v),
            decoration: const InputDecoration(
              labelText: '发现的设备（包含调试服务UUID）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(child: Text('连接状态：$_conn   AP: ${_apIp ?? "(未开)"}')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _ap(true),
                icon: const Icon(Icons.wifi),
                label: const Text('开启热点'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _ap(false),
                icon: const Icon(Icons.wifi_off),
                label: const Text('关闭热点'),
              ),
            ],
          ),

          const SizedBox(height: 12),
          const Text('日志 / STAT：'),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  _log.isEmpty ? '（暂无）' : _log.toString(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- 下载弹窗：列会话、勾选并下载到本地 + 生成HUD视频 ---------------- */

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
  final Set<String> _picked = {};
  bool _downloading = false;
  int _done = 0, _total = 0;

  // 新增：HUD 生成状态
  bool _genWorking = false;
  double _genProgress = 0.0;          // 阶段式 0.0~1.0
  String? _lastHudPath;               // 最近一次生成的视频，便于预览

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    // 对当前组件自身的setState是安全的
    setState(() => _loading = true);
    final url = 'http://${widget.deviceIp}/fs/list';

    // 【修复】将调用父组件setState的操作延迟到构建之后
    Future(() => widget.onLog('GET $url'));
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) {
        widget.onLog('列会话失败：HTTP ${r.statusCode}  body=${r.body}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('列会话失败：HTTP ${r.statusCode}')),
          );
        }
        return;
      }
      List<String> sess = [];
      try {
        final j = jsonDecode(r.body);
        if (j is List) {
          sess = j.map((e) => e.toString()).toList();
        } else if (j is Map) {
          if (j['sessions'] is List) {
            sess = (j['sessions'] as List).map((e) => e.toString()).toList();
          } else if (j['dirs'] is List) {
            sess = (j['dirs'] as List).map((e) => e.toString()).toList();
          }
        }
      } catch (e) {
        widget.onLog('解析失败：$e  body=${r.body}');
      }
      setState(() => _sessions = sess);
      widget.onLog('会话数量：${sess.length}');
    } catch (e) {
      widget.onLog('请求异常：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请求异常：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _downloadPicked() async {
    if (_picked.isEmpty) return;
    setState(() { _downloading = true; _done = 0; _total = 0; });
    try {
      final doc = await getApplicationDocumentsDirectory();
      final base = Directory('${doc.path}/Goggles');
      if (!await base.exists()) await base.create(recursive: true);

      for (final sess in _picked) {
        // 1) 列该会话内所有文件
        final q = sess.startsWith('/') ? sess : '/$sess';
        final listUrl = 'http://${widget.deviceIp}/fs/list?session=${Uri.encodeComponent(q)}';
        widget.onLog('GET $listUrl');
        final r = await http.get(Uri.parse(listUrl)).timeout(const Duration(seconds: 8));
        if (r.statusCode != 200) {
          widget.onLog('列文件失败：HTTP ${r.statusCode}  body=${r.body}');
          continue;
        }

        List<String> files = [];
        try {
          final j = jsonDecode(r.body);
          if (j is List) files = j.map((e) => e.toString()).toList();
        } catch (e) {
          widget.onLog('解析文件列表失败：$e  body=${r.body}');
        }

        if (files.isEmpty) continue;

        final sessName = q.substring(1);
        final outDir = Directory('${base.path}/$sessName');
        if (!await outDir.exists()) await outDir.create(recursive: true);

        _total += files.length;
        setState(() {});

        // 2) 逐个下载
        for (final p in files) {
          final url = 'http://${widget.deviceIp}/fs/file?path=${Uri.encodeComponent(p)}';
          widget.onLog('GET $url');
          try {
            final rr = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 1));
            if (rr.statusCode == 200) {
              final local = File('${outDir.path}/${p.split('/').last}');
              await local.writeAsBytes(rr.bodyBytes);
            } else {
              widget.onLog('下载失败：HTTP ${rr.statusCode}');
            }
          } catch (e) {
            widget.onLog('下载异常：$e');
          } finally {
            _done += 1;
            if (mounted) setState(() {});
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载完成（保存在 App Documents/Goggles/ 下）')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载出错：$e')),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // 新增：生成 HUD 视频（所选会话逐个生成）
  Future<void> _generateHudForPicked() async {
    if (_picked.isEmpty) {
      widget.onLog('未选择会话，无法生成HUD视频');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择至少一个会话')),
      );
      return;
    }

    setState(() { _genWorking = true; _genProgress = 0.0; _lastHudPath = null; });

    try {
      final doc = await getApplicationDocumentsDirectory();
      final base = Directory('${doc.path}/Goggles');

      int i = 0;
      for (final sess in _picked) {
        // session 目录（我们下载时就是存在这里）
        final q = sess.startsWith('/') ? sess.substring(1) : sess; // 去掉开头的斜杠
        final sessDir = Directory('${base.path}/$q');
        final imu = File('${sessDir.path}/imu.csv');
        if (!await sessDir.exists() || !await imu.exists()) {
          widget.onLog('跳过：$q（目录或 imu.csv 不存在）');
          i++;
          continue;
        }

        // 估计阶段进度：本次会话占全体的 1/_picked.length
        final double chunk = 1.0 / _picked.length;

        // 1) 解析/准备（10%）
        setState(() { _genProgress = (i * chunk) + chunk * 0.10; });

        // 2) 调用生成器（阶段 40%→80%）
        setState(() { _genProgress = (i * chunk) + chunk * 0.40; });
        final res = await ImuVideoGenerator.generate(
          ImuVideoGeneratorConfig(
            framesDir: sessDir.path,
            imuCsvPath: imu.path,
            recFps: 12,
            outFps: 30,
            crf: 18,
            outDirOverride: sessDir.path, // 输出到该会话目录
          ),
        );
        setState(() {
          _lastHudPath = res.hudMp4;
          _genProgress = (i * chunk) + chunk * 0.80;
        });

        // 3) 完成本会话（100% of chunk）
        i++;
        setState(() { _genProgress = (i * chunk); });

        widget.onLog('HUD已生成：${res.hudMp4}');
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_picked.length == 1
            ? 'HUD视频已生成：$_lastHudPath'
            : '所选会话的HUD视频已全部生成')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('生成出错：$e')),
      );
    } finally {
      if (mounted) setState(() { _genWorking = false; });
    }
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
                  const Text('选择会话下载', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新列表',
                    onPressed: _loading ? null : _loadSessions,
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
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _sessions.isEmpty
                  ? const Center(child: Text('暂无会话（确认 SD 卡内已有 /REC_... 目录）'))
                  : ListView.builder(
                controller: controller,
                itemCount: _sessions.length,
                itemBuilder: (_, i) {
                  final s = _sessions[i];
                  final picked = _picked.contains(s);
                  return ListTile(
                    title: Text(s, overflow: TextOverflow.ellipsis),
                    trailing: Checkbox(
                      value: picked,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) _picked.add(s); else _picked.remove(s);
                        });
                      },
                    ),
                    onTap: () {
                      setState(() {
                        if (picked) _picked.remove(s); else _picked.add(s);
                      });
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: (_picked.isEmpty || _downloading || _genWorking) ? null : _downloadPicked,
                          icon: const Icon(Icons.download),
                          label: Text(_downloading
                              ? '下载中… ${_done}/${_total == 0 ? "?" : _total}'
                              : '下载所选'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: (_picked.isEmpty || _downloading || _genWorking) ? null : _generateHudForPicked,
                          icon: const Icon(Icons.movie_edit),
                          label: Text(_genWorking
                              ? '生成中… ${(_genProgress * 100).clamp(0, 100).toStringAsFixed(0)}%'
                              : '生成HUD视频'),
                        ),
                      ),
                    ],
                  ),
                  if (_genWorking) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _genProgress.clamp(0.0, 1.0)),
                  ],
                  if (!_genWorking && _lastHudPath != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => _VideoPlayerPage(path: _lastHudPath!),
                              ));
                            },
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('预览HUD视频'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/* ---------------- 内置播放器页面（预览生成的 HUD MP4） ---------------- */

class _VideoPlayerPage extends StatefulWidget {
  const _VideoPlayerPage({required this.path});
  final String path;

  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
  late final VideoPlayerController _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _ctrl.play();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('预览：${widget.path.split('/').last}')),
      body: Center(
        child: _ready
            ? AspectRatio(
          aspectRatio: _ctrl.value.aspectRatio,
          child: VideoPlayer(_ctrl),
        )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: _ready
          ? FloatingActionButton(
        onPressed: () {
          setState(() {
            _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play();
          });
        },
        child: Icon(_ctrl.value.isPlaying ? Icons.pause : Icons.play_arrow),
      )
          : null,
    );
  }
}
