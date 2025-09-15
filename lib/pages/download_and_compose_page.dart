import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:path_provider/path_provider.dart';

// ✅ 跟你当前安装版本匹配的签名
import 'package:saver_gallery/saver_gallery.dart' as saver;
// ✅ 新增：内置播放器
import 'package:video_player/video_player.dart';

import 'package:zeshy/video/imu_video_generator.dart';

class DownloadAndComposePage extends StatefulWidget {
  const DownloadAndComposePage({super.key, required this.deviceIp});
  final String deviceIp;

  @override
  State<DownloadAndComposePage> createState() => _DownloadAndComposePageState();
}

class _DownloadAndComposePageState extends State<DownloadAndComposePage> {
  late final http_io.IOClient _client;
  late final HttpClient _io;

  bool _loading = true;
  List<String> _sessions = [];
  final Set<String> _picked = {};

  bool _working = false;
  String _phase = '—';
  double _progress = 0.0; // 0~1
  final _log = StringBuffer();

  // 最近生成的 HUD 列表（用于“保存到相册”和“预览”）
  final List<String> _hudOutputs = [];

  @override
  void initState() {
    super.initState();

    _io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20) // 放宽握手
      ..idleTimeout = Duration.zero // 禁止 keep-alive
      ..autoUncompress = false
      ..maxConnectionsPerHost = 1; // 串行 socket
    _client = http_io.IOClient(_io);

    _loadSessions();
  }

  @override
  void dispose() {
    _client.close();
    try { _io.close(force: true); } catch (_) {}
    super.dispose();
  }

  /* ======================= UI helpers ======================= */

  void _appendLog(String s) {
    _log.writeln('${DateTime.now().toIso8601String().substring(11, 19)}  $s');
    if (!mounted) return;
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: _log.toString()));
    _snack('日志已复制到剪贴板');
  }

  Future<void> _exportLog() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/download_log_${DateTime.now().millisecondsSinceEpoch}.txt');
    await f.writeAsString(_log.toString());
    _snack('已导出到：${f.path}');
  }

  /* ======================= HTTP utils ======================= */

  bool _isRetryable(Object e) {
    final s = e.toString();
    return e is TimeoutException ||
        e is SocketException ||
        s.contains('Connection failed') ||
        s.contains('Software caused connection abort') ||
        s.contains('Connection reset by peer') ||
        s.contains('Broken pipe');
  }

  Future<http.Response> _get(Uri url, {Duration? timeout, int retries = 2}) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        _appendLog('GET $url');
        final resp = await _client
            .get(
          url,
          headers: const {
            'Connection': 'close',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
            'Cache-Control': 'no-cache',
          },
        )
            .timeout(timeout ?? const Duration(seconds: 8));
        return resp;
      } catch (e) {
        if (attempt > retries || !_isRetryable(e)) rethrow;
        _appendLog('GET 重试 #$attempt：$url（$e）');
        await Future.delayed(Duration(milliseconds: 200 * attempt));
      }
    }
  }

  /* -------- 会话列表（返回目录名，如 REC_88） -------- */
  Future<List<String>> _fetchSessions(String ip) async {
    final url = Uri.parse('http://$ip/fs/list');
    final r = await _get(url);
    if (r.statusCode == 409) throw Exception('设备正在录制中（409 Conflict）');
    if (r.statusCode != 200) {
      throw Exception('HTTP ${r.statusCode}（列会话） body=${r.body}');
    }
    return _parseListResult(r.body, wantDirs: true, basePath: '/')
        .map((e) => e.replaceFirst(RegExp(r'^/'), '')) // 只保留 REC_xxx 名称
        .toList();
  }

  // 兼容多种返回：items[{name,type}], sessions[], files[], 纯数组，或纯文本行
  List<String> _parseListResult(String body, {required bool wantDirs, required String basePath}) {
    try {
      final decoded = json.decode(body);
      final out = <String>[];

      if (decoded is Map) {
        if (decoded['items'] is List) {
          for (final it in (decoded['items'] as List)) {
            if (it is! Map) continue;
            var name = (it['name'] ?? '').toString();
            if (name.isEmpty) continue;
            final type = (it['type'] ?? '').toString().toLowerCase();
            final isDir = type == 'dir' || type == 'directory' || (it['dir'] == true);
            if (wantDirs && isDir) out.add(_join(basePath, name));
            if (!wantDirs && !isDir) out.add(_join(basePath, name));
          }
          return _finalizeList(out, wantDirs);
        }
        if (decoded['sessions'] is List) {
          for (final s in (decoded['sessions'] as List)) {
            out.add(_join(basePath, s.toString()));
          }
          return _finalizeList(out, wantDirs);
        }
        if (decoded['files'] is List && !wantDirs) {
          for (final s in (decoded['files'] as List)) {
            out.add(_join(basePath, s.toString()));
          }
          return _finalizeList(out, wantDirs);
        }
      } else if (decoded is List) {
        for (final s in decoded) {
          out.add(_join(basePath, s.toString()));
        }
        return _finalizeList(out, wantDirs);
      }

      // 纯文本（按行）
      final out2 = <String>[];
      for (final ln in const LineSplitter().convert(body)) {
        final t = ln.trim();
        if (t.isEmpty) continue;
        out2.add(_join(basePath, t));
      }
      return _finalizeList(out2, wantDirs);
    } catch (_) {
      final out = <String>[];
      for (final ln in const LineSplitter().convert(body)) {
        final t = ln.trim();
        if (t.isEmpty) continue;
        out.add(_join(basePath, t));
      }
      return _finalizeList(out, wantDirs);
    }
  }

  // —— 统一路径拼接：去掉 name 的前导斜杠，避免出现 “//” —— //
  String _join(String base, String name) {
    var nm = name.replaceAll('\\', '/').trim();
    nm = nm.replaceFirst(RegExp(r'^/+'), ''); // 重要：去前导斜杠
    if (base.endsWith('/')) return '$base$nm';
    return '$base/$nm';
  }

  List<String> _finalizeList(List<String> xs, bool wantDirs) {
    if (wantDirs) return xs.map((e) => e.replaceFirst(RegExp(r'^/'), '')).toList();
    return xs;
  }

  bool _isImage(String p) {
    final lower = p.toLowerCase();
    return RegExp(r'\.(jpg|jpeg|png)$').hasMatch(lower);
  }

  bool _isCsv(String p) => p.toLowerCase().endsWith('.csv');

  bool _looksLikeFile(String p) {
    final lower = p.toLowerCase();
    return RegExp(r'\.(jpg|jpeg|png|bmp|gif|csv|mp4|mov|bin|dat|txt)$').hasMatch(lower);
  }

  /* ------------------- 列某会话的“文件列表” ------------------- */
  Future<List<String>> _fetchFilesInSession(String ip, String sessionName) async {
    final sess = sessionName.replaceFirst(RegExp(r'^/'), '');

    final tryUrls = <Uri>[
      Uri.parse('http://$ip/fs/list?session=/$sess'), // ✅ 固件实现
      Uri.parse('http://$ip/fs/list?session=$sess'),
      Uri.parse('http://$ip/fs/list?path=/$sess'),
      Uri.parse('http://$ip/fs/list?dir=/$sess'),
      Uri.parse('http://$ip/fs/list?path=$sess'),
    ];

    http.Response? last;
    for (final url in tryUrls) {
      try {
        final r = await _get(url);
        last = r;

        if (r.statusCode == 200) {
          final raw = _parseListResult(r.body, wantDirs: false, basePath: '/');

          // 补齐为绝对路径：/REC_xxx/<name>，并压双斜杠
          final abs = <String>[];
          for (var e in raw) {
            var it = e.replaceAll('\\', '/').trim();
            it = it.replaceAll(RegExp(r'//+'), '/');
            if (!it.startsWith('/')) it = '/$it';
            if (!it.startsWith('/$sess/')) {
              final base = '/$sess/';
              final name = it.replaceFirst(RegExp(r'^/+'), '');
              it = '$base$name';
            }
            abs.add(it.replaceAll(RegExp(r'//+'), '/'));
          }

          final files = abs.where(_looksLikeFile).toList();

          // —— 关键：先图像，最后 CSV —— //
          files.sort((a, b) {
            final ai = _isImage(a);
            final bi = _isImage(b);
            if (ai != bi) return ai ? -1 : 1; // 图片优先
            final ac = _isCsv(a);
            final bc = _isCsv(b);
            if (ac != bc) return ac ? 1 : -1; // CSV 最后
            // 尝试让 frame_xxxxx.jpg 升序
            final ra = RegExp(r'frame_(\d+)\.jpg').firstMatch(a.toLowerCase());
            final rb = RegExp(r'frame_(\d+)\.jpg').firstMatch(b.toLowerCase());
            if (ra != null && rb != null) {
              final na = int.tryParse(ra.group(1) ?? '0') ?? 0;
              final nb = int.tryParse(rb.group(1) ?? '0') ?? 0;
              return na.compareTo(nb);
            }
            return a.compareTo(b);
          });

          if (files.isNotEmpty) return files;
          continue;
        }
        if (r.statusCode == 409) throw Exception('设备正在录制中（409 Conflict）');
        if (r.statusCode == 404 && r.body.toUpperCase().contains('NO SESSION')) {
          continue;
        }
      } catch (_) {
        continue;
      }
    }

    final msg = (last == null)
        ? '列文件失败：无响应'
        : '列文件失败：HTTP ${last.statusCode} body=${last.body}';
    throw Exception(msg);
  }

  /* -------- 生成下载 URL 候选：多数固件只接受不编码的 path -------- */
  List<Uri> _fileUrlCandidates(String ip, String absPath) {
    final safe = absPath.replaceAll(RegExp(r'//+'), '/'); // 压双斜杠
    return [
      Uri.parse('http://$ip/fs/file?path=$safe'),                                   // 原样（首选）
      Uri.parse('http://$ip/fs/file?path=${Uri.encodeComponent(safe)}'),             // 编码
      // 下面两条只是兼容兜底；你的固件不支持 file=，正常会 400/超时
      Uri.parse('http://$ip/fs/file?file=$safe'),
      Uri.parse('http://$ip/fs/file?file=${Uri.encodeComponent(safe)}'),
    ];
  }

  // —— 下载前做一次 /status 预热 —— //
  Future<void> _warmUp(String ip) async {
    try {
      await _get(Uri.parse('http://$ip/status'), timeout: const Duration(seconds: 2), retries: 0);
    } catch (_) {}
  }

  // —— 流式下载（串行 + 候选 URL 回退 + 指数退避 + 轻延时）—— //
  Future<void> _downloadOneFile(
      String ip,
      String absPath,
      Directory outDir, {
        bool isFirst = false,
      }) async {
    // 首文件喘息/文件间间隙
    if (isFirst) {
      await Future.delayed(const Duration(milliseconds: 300));
    } else {
      await Future.delayed(const Duration(milliseconds: 120));
    }

    await _warmUp(ip);

    final candidates = _fileUrlCandidates(ip, absPath);
    final fname = absPath.split('/').last;

    // 针对 CSV 放宽超时
    final isCsv = _isCsv(absPath);
    final connectOrFirstChunkTimeout = isCsv ? const Duration(seconds: 60) : const Duration(seconds: 30);
    final streamTimeout = isCsv ? const Duration(minutes: 12) : const Duration(minutes: 4);

    for (final url in candidates) {
      const maxRetries = 3;
      int attempt = 0;

      while (true) {
        attempt++;
        try {
          _appendLog('GET(stream) $url');
          final req = http.Request('GET', url);
          req.headers.addAll(const {
            'Connection': 'close',
            'Accept': '*/*',
            'Accept-Encoding': 'identity',
            'Cache-Control': 'no-cache',
          });

          // 连接与首包：CSV 更宽松
          final streamed = await _client.send(req).timeout(connectOrFirstChunkTimeout);

          if (streamed.statusCode == 409) {
            throw Exception('设备正在录制中（409 Conflict）');
          }
          if (streamed.statusCode != 200) {
            throw Exception('HTTP ${streamed.statusCode}');
          }

          final file = File('${outDir.path}/$fname');
          final sink = file.openWrite();

          await streamed.stream
              .timeout(streamTimeout)
              .forEach(sink.add);

          await sink.flush();
          await sink.close();

          await Future.delayed(const Duration(milliseconds: 100));
          return; // 成功
        } catch (e) {
          if (attempt >= maxRetries || !_isRetryable(e)) {
            _appendLog('候选失败：$url（$e）');
            break; // 尝试下一个候选 URL
          }
          _appendLog('下载重试 #$attempt：$fname（原因：$e）');
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }

    throw Exception('下载失败：$fname');
  }

  /* ======================= 保存到相册（按你当前包的签名） ======================= */

  Future<bool> _saveOneToGallery(String filePath) async {
    try {
      final basename = filePath.split('/').last;

      final res = await saver.SaverGallery.saveFile(
        filePath: filePath,
        fileName: basename,
        // 保存到 DCIM/Movies/Goggles（部分 ROM 会归档到“相册-视频”）
        androidRelativePath: 'Movies/Goggles',
        skipIfExists: false,
      );

      final ok = (res.isSuccess == true);
      _appendLog('保存到相册：success=$ok path=$filePath');
      return ok;
    } on PlatformException catch (e) {
      _appendLog('保存到相册失败(权限/平台)：$e');
      return false;
    } catch (e) {
      _appendLog('保存到相册失败：$e');
      return false;
    }
  }

  Future<void> _saveLatestHudToGallery() async {
    if (_hudOutputs.isEmpty) {
      _snack('本次还没有生成 HUD 视频');
      return;
    }
    final last = _hudOutputs.last;
    _appendLog('保存到相册：$last');
    final ok = await _saveOneToGallery(last);
    _snack(ok ? '已保存到相册（DCIM/Movies/Goggles 或系统视频库）' : '保存到相册失败');
  }

  /* ======================= 预览最近 HUD ======================= */

  Future<void> _openLatestHudPreview() async {
    if (_hudOutputs.isEmpty) {
      _snack('本次还没有生成 HUD 视频');
      return;
    }
    final path = _hudOutputs.last;
    _appendLog('预览 HUD：$path');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _VideoPlayerPage(path: path)),
    );
  }

  /* ======================= Workflows ======================= */

  Future<void> _loadSessions() async {
    setState(() => _loading = true);
    try {
      final sess = await _fetchSessions(widget.deviceIp);
      sess.sort();
      if (!mounted) return;
      setState(() => _sessions = sess);
      _appendLog('会话数量：${sess.length} -> ${sess.map((e) => "/$e").join(", ")}');
    } catch (e) {
      _snack('加载会话失败：$e');
      _appendLog('加载会话失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _downloadAndCompose() async {
    if (_picked.isEmpty) {
      _snack('请先选择至少一个会话');
      return;
    }

    setState(() { _working = true; _phase = '准备目录'; _progress = 0; _hudOutputs.clear(); });

    final doc = await getApplicationDocumentsDirectory();
    final base = Directory('${doc.path}/Goggles');
    if (!await base.exists()) await base.create(recursive: true);

    final sel = _picked.toList();
    bool firstFile = true;

    for (int i = 0; i < sel.length; i++) {
      final sessName = sel[i].replaceFirst(RegExp(r'^/'), '');
      final outDir = Directory('${base.path}/$sessName');
      if (!await outDir.exists()) await outDir.create(recursive: true);

      // 1) 列该会话文件
      setState(() { _phase = '列文件：$sessName'; _progress = i / sel.length; });
      List<String> files;
      try {
        files = await _fetchFilesInSession(widget.deviceIp, sessName);
      } catch (e) {
        _appendLog('列文件失败：$e');
        _snack('处理失败：$e');
        setState(() { _working = false; });
        return;
      }
      if (files.isEmpty) {
        _appendLog('会话 $sessName 无可下载文件，跳过。');
        continue;
      }

      // 2) 下载（图片优先、CSV 最后）
      int done = 0;
      for (final p in files) {
        setState(() {
          _phase = '下载：$sessName';
          final chunk = 0.60; // 下载阶段占本会话 60%
          _progress = (i / sel.length) + (done / files.length) * (chunk / sel.length);
        });
        try {
          await _downloadOneFile(widget.deviceIp, p, outDir, isFirst: firstFile);
        } catch (e) {
          _appendLog('下载失败：$e');
          _snack('下载失败：$e');
          setState(() { _working = false; });
          return;
        } finally {
          done++;
          firstFile = false;
        }
      }

      // 3) HUD 合成（使用生成器的真实进度）
      setState(() {
        _phase = '合成 HUD：$sessName';
      });

      // 下载阶段已推进到 60%；把 onProgress(0~1) 映射到后 40%
      final baseProgress = (i + 0.60) / sel.length; // 本会话合成起点
      final endProgress  = (i + 1.00) / sel.length; // 本会话结束

      try {
        final imu = File('${outDir.path}/imu.csv');
        if (!await imu.exists()) {
          _appendLog('警告：$sessName 缺少 imu.csv，跳过合成。');
        } else {
          final res = await ImuVideoGenerator.generate(
            ImuVideoGeneratorConfig(
              framesDir: outDir.path,
              imuCsvPath: imu.path,
              recFps: 10,     // ⚠️ 与固件 REC_FPS=10 一致
              outFps: 30,
              crf: 18,
              outDirOverride: outDir.path,
            ),
            onProgress: (v) {
              // v: 0~1，把它线性映射到 [baseProgress, endProgress]
              final p = baseProgress + (endProgress - baseProgress) * v;
              if (mounted) {
                setState(() {
                  _progress = p;
                  _phase = '合成 HUD：$sessName';
                });
              }
            },
          );
          _appendLog('HUD完成：${res.hudMp4}');
          _hudOutputs.add(res.hudMp4);
        }
      } catch (e) {
        _appendLog('合成失败：$e');
        _snack('合成失败：$e');
        setState(() { _working = false; });
        return;
      }

      // 4) 本会话完成：收口到 100%
      setState(() {
        _phase = '完成：$sessName';
        _progress = endProgress;
      });
    }

    setState(() { _working = false; _phase = '完成'; _progress = 1.0; });
    _snack('所选会话下载并处理完成 ✅（App Documents/Goggles/ 下）');
  }

  /* ======================= UI ======================= */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载并合成 HUD'),
        actions: [
          IconButton(icon: const Icon(Icons.copy), tooltip: '复制日志', onPressed: _copyLog),
          IconButton(icon: const Icon(Icons.save_alt), tooltip: '导出日志为文件', onPressed: _exportLog),
          IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新会话列表', onPressed: _loading ? null : _loadSessions),
        ],
      ),
      body: Column(
        children: [
          if (_working)
            LinearProgressIndicator(value: _progress.clamp(0.0, 1.0)),
          if (_working)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text('$_phase ${(100 * _progress).toStringAsFixed(0)}%'),
            ),
          // 会话列表（占 2 份高度）
          Flexible(
            flex: 2,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _sessions.isEmpty
                ? const Center(child: Text('暂无会话（确认 SD 卡内已有 /REC_... 目录）'))
                : ListView.separated(
              itemCount: _sessions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = _sessions[i];
                final picked = _picked.contains(s);
                return ListTile(
                  title: Text('/$s', overflow: TextOverflow.ellipsis),
                  trailing: Checkbox(
                    value: picked,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) _picked.add(s);
                        else _picked.remove(s);
                      });
                    },
                  ),
                  onTap: () {
                    setState(() {
                      picked ? _picked.remove(s) : _picked.add(s);
                    });
                  },
                );
              },
            ),
          ),
          // 操作按钮（两行：避免小屏挤不下）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_picked.isEmpty || _working) ? null : _downloadAndCompose,
                        icon: const Icon(Icons.download),
                        label: Text(_working
                            ? '处理中… ${(100 * _progress).toStringAsFixed(0)}%'
                            : '下载并合成'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_hudOutputs.isEmpty || _working) ? null : _saveLatestHudToGallery,
                        icon: const Icon(Icons.video_library_outlined),
                        label: const Text('保存到相册'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (_hudOutputs.isEmpty || _working) ? null : _openLatestHudPreview,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('预览最近 HUD'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 日志面板（占 1 份高度，可复制）
          Flexible(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      _log.isEmpty ? '（日志空）' : _log.toString(),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
    final name = widget.path.split('/').last;
    return Scaffold(
      appBar: AppBar(title: Text('预览：$name')),
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
