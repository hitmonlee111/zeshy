// lib/pages/hud_test_page.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../video/imu_video_generator.dart';

/// =============== HUD 生成本地测试页（Android 本机 Download/REC_xx） ===============
class HudTestPage extends StatefulWidget {
  const HudTestPage({super.key});

  @override
  State<HudTestPage> createState() => _HudTestPageState();
}

class _HudTestPageState extends State<HudTestPage> {
  // 默认指向 /storage/emulated/0/Download/REC_88
  final _dirCtrl =
  TextEditingController(text: '/storage/emulated/0/Download/REC_88');

  bool _checking = false;
  bool _generating = false;
  String _checkSummary = '';
  String _lastRaw = '';
  String _lastHud = '';
  final _log = StringBuffer();
  double _progress = 0.0;

  void _append(String s) {
    final now = DateTime.now();
    final t =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() => _log.writeln('[$t] $s'));
  }

  // ---------------------- 关键：调试用“所有文件访问”权限 ----------------------
  Future<bool> ensureFsPermsForDownload() async {
    if (!Platform.isAndroid) return true;

    final di = DeviceInfoPlugin();
    final info = await di.androidInfo;
    final sdk = info.version.sdkInt;

    // Android 13+：读媒体需要 READ_MEDIA_*；写 Download 往往仍被 scoped 限制 -> 申请 MANAGE_EXTERNAL_STORAGE
    if (sdk >= 33) {
      final img = await Permission.photos.request();  // READ_MEDIA_IMAGES
      final vid = await Permission.videos.request();  // READ_MEDIA_VIDEO
      var manage = await Permission.manageExternalStorage.status;
      if (!manage.isGranted) {
        manage = await Permission.manageExternalStorage.request();
        if (!manage.isGranted) {
          _append('请在系统设置中开启“所有文件访问权限”');
          await openAppSettings();
          return false;
        }
      }
      return img.isGranted && vid.isGranted && manage.isGranted;
    }

    // Android 11/12：直接申请 All files
    if (sdk >= 30) {
      var manage = await Permission.manageExternalStorage.status;
      if (!manage.isGranted) {
        manage = await Permission.manageExternalStorage.request();
        if (!manage.isGranted) {
          _append('请在系统设置中开启“所有文件访问权限”');
          await openAppSettings();
          return false;
        }
      }
      // 读旧机型媒体兜底
      final store = await Permission.storage.request();
      return manage.isGranted && store.isGranted;
    }

    // Android 10 及以下
    final store = await Permission.storage.request();
    return store.isGranted;
  }
  // -------------------------------------------------------------------------

  Future<void> _check() async {
    if (!await ensureFsPermsForDownload()) {
      _snack('请授予存储权限（尤其“所有文件访问”）后重试');
      return;
    }

    final dir = Directory(_dirCtrl.text.trim());
    if (!await dir.exists()) {
      _snack('目录不存在：${dir.path}');
      return;
    }
    setState(() {
      _checking = true;
      _checkSummary = '';
      _lastRaw = '';
      _lastHud = '';
      _progress = 0.0;
    });

    try {
      final frames = dir
          .listSync()
          .whereType<File>()
          .where((f) =>
          RegExp(r'frame_\d{5}\.jpe?g$', caseSensitive: false)
              .hasMatch(f.path.split('/').last))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      final imu = File('${dir.path}/imu.csv');
      final hasImu = await imu.exists();

      // 缺帧检查
      List<String> holes = [];
      if (frames.isNotEmpty) {
        final existing = frames
            .map((f) => int.tryParse(RegExp(r'frame_(\d{5})', caseSensitive: false)
            .firstMatch(f.path.split('/').last)
            ?.group(1) ??
            ''))
            .whereType<int>()
            .toSet();
        final minIdx = existing.reduce((a, b) => a < b ? a : b);
        final maxIdx = existing.reduce((a, b) => a > b ? a : b);
        for (int i = minIdx; i <= maxIdx; i++) {
          if (!existing.contains(i)) holes.add(i.toString().padLeft(5, '0'));
        }
      }

      final ok = frames.isNotEmpty && hasImu;
      final sum = StringBuffer()
        ..writeln('目录：${dir.path}')
        ..writeln('帧数：${frames.length}${frames.isEmpty ? "（为空）" : ""}')
        ..writeln('imu.csv：${hasImu ? "存在" : "缺失"}')
        ..writeln(holes.isEmpty
            ? '缺帧：无'
            : '缺帧：${holes.length} 个（例：${holes.take(10).join(", ")}${holes.length > 10 ? "..." : ""}）')
        ..writeln(ok
            ? '✅ 资源就绪，可以生成'
            : '❌ 资源不完整，无法生成（需要 frame_00001.jpg… 与 imu.csv）');

      setState(() => _checkSummary = sum.toString());
      _append('检查完成：${ok ? "可生成" : "资源不完整"}');
    } catch (e) {
      _snack('检查失败：$e');
      _append('检查失败：$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _generate() async {
    if (!await ensureFsPermsForDownload()) {
      _snack('请授予存储权限（尤其“所有文件访问”）后重试');
      return;
    }

    final dir = Directory(_dirCtrl.text.trim());
    final framesDir = dir.path;
    final imuPath = '${dir.path}/imu.csv';

    if (!await dir.exists() || !await File(imuPath).exists()) {
      _snack('请先检查目录，确保存在帧与 imu.csv');
      return;
    }

    setState(() {
      _generating = true;
      _progress = 0.0;
      _lastRaw = '';
      _lastHud = '';
    });

    Timer(const Duration(milliseconds: 300), () {
      if (mounted && _generating) setState(() => _progress = 0.1);
    });

    try {
      _append('开始生成：建立时间轴并渲染 HUD 覆盖图…');
      setState(() => _progress = 0.2);

      final res = await ImuVideoGenerator.generate(
        ImuVideoGeneratorConfig(
          framesDir: framesDir,
          imuCsvPath: imuPath,
          recFps: 12,
          outFps: 30,
          crf: 18,
          outDirOverride: framesDir, // 直接输出到 Download/REC_xx
        ),
      );

      _append('生成完成：\nraw=${res.rawMp4}\nhud=${res.hudMp4}');
      setState(() {
        _lastRaw = res.rawMp4;
        _lastHud = res.hudMp4;
        _progress = 1.0;
      });
      _snack('生成完成');
    } catch (e) {
      _snack('生成失败：$e');
      _append('生成失败：$e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _checking || _generating;
    return Scaffold(
      appBar: AppBar(title: const Text('HUD 生成测试（Download/REC_xx）')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _dirCtrl,
              decoration: const InputDecoration(
                labelText: '会话目录（含 frame_00001.jpg… 与 imu.csv）',
                hintText: '/storage/emulated/0/Download/REC_88',
                border: OutlineInputBorder(),
              ),
              enabled: !busy,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _check,
                    icon: const Icon(Icons.search),
                    label: Text(_checking ? '检查中…' : '检查目录'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _generate,
                    icon: const Icon(Icons.movie_edit),
                    label: Text(_generating ? '生成中…' : '生成 HUD 视频'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: busy ? (_progress.clamp(0.0, 1.0)) : null,
              minHeight: 6,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _checkSummary.isEmpty ? '（先点“检查目录”）' : _checkSummary,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
            ),
            const Divider(),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    _log.isEmpty ? '（日志）' : _log.toString(),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                  ),
                ),
              ),
            ),
            if (_lastHud.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _VideoPreviewPage(path: _lastHud),
                        ),
                      ),
                      icon: const Icon(Icons.play_circle),
                      label: const Text('预览：HUD视频'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_lastRaw.isNotEmpty)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _VideoPreviewPage(path: _lastRaw),
                          ),
                        ),
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('预览：原始视频'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============== 简易播放器页 ===============
class _VideoPreviewPage extends StatefulWidget {
  const _VideoPreviewPage({required this.path});
  final String path;

  @override
  State<_VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends State<_VideoPreviewPage> {
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
        onPressed: () =>
            setState(() => _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play()),
        child: Icon(_ctrl.value.isPlaying ? Icons.pause : Icons.play_arrow),
      )
          : null,
    );
  }
}
