// lib/video/imu_video_generator.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:path_provider/path_provider.dart';

class ImuSample {
  final int tsMs; // 相对录像开始的毫秒
  final double ax, ay, az; // g
  final double gx, gy, gz; // deg/s
  ImuSample(this.tsMs, this.ax, this.ay, this.az, this.gx, this.gy, this.gz);
}

class ImuVideoGeneratorConfig {
  final String framesDir;       // 帧目录: frame_00001.jpg ...
  final String imuCsvPath;      // imu.csv
  final int recFps;             // 固件中 REC_FPS=12
  final int outFps;             // 输出视频帧率, 建议 30
  final int crf;                // 画质, 18~23
  final String? outDirOverride; // 输出目录(可选)
  const ImuVideoGeneratorConfig({
    required this.framesDir,
    required this.imuCsvPath,
    this.recFps = 12,
    this.outFps = 30,
    this.crf = 18,
    this.outDirOverride,
  });
}

class ImuVideoGeneratorResult {
  final String rawMp4;   // 图片直接合成的视频
  final String hudMp4;   // 叠加 HUD 后的视频
  ImuVideoGeneratorResult({required this.rawMp4, required this.hudMp4});
}

/// 一键生成（图片 → raw mp4 → 渲染 HUD → 合成 HUD mp4）
class ImuVideoGenerator {
  static Future<ImuVideoGeneratorResult> generate(ImuVideoGeneratorConfig cfg) async {
    // 1) 输出目录
    final dir = cfg.outDirOverride ?? (await getApplicationDocumentsDirectory()).path;
    final outRaw = '$dir/out_raw.mp4';
    final overlayDir = '$dir/overlays';
    final outHud = '$dir/out_hud.mp4';
    await Directory(overlayDir).create(recursive: true);

    // 2) 分辨率（读第一帧）
    final firstFrame = _firstFramePath(cfg.framesDir);
    final dim = await _readImageDim(File(firstFrame));

    // 3) 解析 IMU 并插值到帧时间轴
    final samples = await _parseImuCsv(cfg.imuCsvPath);
    final frameCount = _countFrames(cfg.framesDir);
    final frameDtMs = (1000.0 / cfg.recFps);
    final perFrameImu = List<ImuSample>.generate(frameCount, (i) {
      final t = (i * frameDtMs).round();
      return _interpImuAt(samples, t);
    });

    // 4) 渲染透明 HUD 覆盖图（与帧数一致）
    await _renderHudOverlays(
      overlayDir: overlayDir,
      sizeW: dim.width,
      sizeH: dim.height,
      perFrame: perFrameImu,
      fps: cfg.recFps,
    );

    // 5) 合成 out_raw.mp4（按 REC_FPS）
    await _ff('-y -framerate ${cfg.recFps} -i ${_esc(cfg.framesDir)}/frame_%05d.jpg '
        '-c:v libx264 -profile:v high -pix_fmt yuv420p -r ${cfg.outFps} ${_esc(outRaw)}');

    // 6) overlay 合成：原始帧 + 透明 HUD
    await _ff('-y -framerate ${cfg.recFps} -i ${_esc(cfg.framesDir)}/frame_%05d.jpg '
        '-framerate ${cfg.recFps} -i ${_esc(overlayDir)}/overlay_%05d.png '
        '-filter_complex "[0:v][1:v]overlay=0:0:format=auto" '
        '-c:v libx264 -pix_fmt yuv420p -r ${cfg.outFps} -crf ${cfg.crf} ${_esc(outHud)}');

    return ImuVideoGeneratorResult(rawMp4: outRaw, hudMp4: outHud);
  }

  // ---------- 工具与实现 ----------

  static String _firstFramePath(String framesDir) {
    // 假设至少有一帧，且命名从 00001 开始（你的固件逻辑如此）
    return '$framesDir/frame_00001.jpg';
  }

  static Future<_Dim> _readImageDim(File f) async {
    final bytes = await f.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final fi = await codec.getNextFrame();
    final img = fi.image;
    return _Dim(img.width, img.height);
  }

  static int _countFrames(String framesDir) {
    final dir = Directory(framesDir);
    if (!dir.existsSync()) return 0;
    final files = dir
        .listSync()
        .whereType<File>()
        .map((e) => e.path)
        .where((p) => RegExp(r'frame_\d{5}\.jpe?g$', caseSensitive: false).hasMatch(p))
        .toList()
      ..sort();
    return files.length;
  }

  static Future<List<ImuSample>> _parseImuCsv(String csvPath) async {
    final f = File(csvPath);
    if (!await f.exists()) return [];
    final lines = const LineSplitter().convert(await f.readAsString());
    final out = <ImuSample>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('ts_ms')) continue;
      final parts = line.split(',');
      if (parts.length < 7) continue;
      try {
        final ts = int.parse(parts[0]);
        final ax = double.parse(parts[1]);
        final ay = double.parse(parts[2]);
        final az = double.parse(parts[3]);
        final gx = double.parse(parts[4]);
        final gy = double.parse(parts[5]);
        final gz = double.parse(parts[6]);
        out.add(ImuSample(ts, ax, ay, az, gx, gy, gz));
      } catch (_) {}
    }
    return out;
  }

  static ImuSample _interpImuAt(List<ImuSample> xs, int tMs) {
    if (xs.isEmpty) return ImuSample(tMs, 0, 0, 0, 0, 0, 0);
    if (tMs <= xs.first.tsMs) return ImuSample(tMs, xs.first.ax, xs.first.ay, xs.first.az, xs.first.gx, xs.first.gy, xs.first.gz);
    if (tMs >= xs.last.tsMs) {
      final last = xs.last;
      return ImuSample(tMs, last.ax, last.ay, last.az, last.gx, last.gy, last.gz);
    }
    // 二分定位
    int lo = 0, hi = xs.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (xs[mid].tsMs <= tMs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = xs[lo], b = xs[hi];
    final span = (b.tsMs - a.tsMs).clamp(1, 1000000).toDouble();
    final k = (tMs - a.tsMs) / span;
    double lerp(double u, double v) => u + (v - u) * k;
    return ImuSample(
      tMs,
      lerp(a.ax, b.ax),
      lerp(a.ay, b.ay),
      lerp(a.az, b.az),
      lerp(a.gx, b.gx),
      lerp(a.gy, b.gy),
      lerp(a.gz, b.gz),
    );
  }

  static Future<void> _renderHudOverlays({
    required String overlayDir,
    required int sizeW,
    required int sizeH,
    required List<ImuSample> perFrame,
    required int fps,
  }) async {
    // 串行最简实现；如需更快可拆成 Isolate 分片渲染
    for (int i = 0; i < perFrame.length; i++) {
      final path = '$overlayDir/overlay_${(i + 1).toString().padLeft(5, '0')}.png';
      final img = await _drawHud(sizeW, sizeH, perFrame[i], fps);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(byteData!.buffer.asUint8List());
      img.dispose();
    }
  }

  /// 实际 HUD 绘制：可自由设计
  static Future<ui.Image> _drawHud(int w, int h, ImuSample s, int fps) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.save();

    // 透明背景（不绘制即可）

    // 半透明面板
    final paintPanel = ui.Paint()
      ..color = const ui.Color(0x66000000)
      ..style = ui.PaintingStyle.fill;

    // 顶部信息栏
    const double pad = 16.0;
    const double barH = 68.0;
    _rrect(c, ui.Rect.fromLTWH(pad, pad, w - pad * 2, barH), 14.0, paintPanel);

    // 右上 HUD 数值
    const ui.Color textColor = ui.Color(0xFFFFFFFF);
    _text(c, 'Ax ${s.ax.toStringAsFixed(2)}  Ay ${s.ay.toStringAsFixed(2)}  Az ${s.az.toStringAsFixed(2)}',
        x: w - 24.0, y: 28.0, alignRight: true, size: 22.0, color: textColor);
    final gMag = math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
    _text(c, '|G| ${gMag.toStringAsFixed(2)}     Gz ${s.gz.toStringAsFixed(1)} °/s',
        x: w - 24.0, y: 54.0, alignRight: true, size: 22.0, color: textColor);

    // 左下角：简易罗盘（用 gz 直接映射角度，演示效果）
    const double compR = 90.0;
    final double compX = 32.0 + compR;
    final double compY = h - 32.0 - compR;
    _circle(c, ui.Offset(compX, compY), compR, const ui.Color(0x55FFFFFF), 4.0);
    // 指针（用 gz 近似当前转动趋势）
    final double angleRad = (s.gz) * math.pi / 180.0 * 0.25; // 缩放 0.25 仅为示意
    final p2 = ui.Offset(
      compX + compR * 0.9 * math.cos(-math.pi / 2 + angleRad),
      compY + compR * 0.9 * math.sin(-math.pi / 2 + angleRad),
    );
    _line(c, ui.Offset(compX, compY), p2, const ui.Color(0xFFFFFFFF), 6.0);
    _text(c, 'TURN', x: compX, y: compY + compR + 12.0, size: 18.0, color: textColor, center: true);

    // 底部时间轴
    final double tSec = s.tsMs / 1000.0;
    final ui.Rect timelineRect = ui.Rect.fromLTWH(16.0, h - 32.0, w - 32.0, 12.0);
    _rrect(c, timelineRect, 6.0, ui.Paint()..color = const ui.Color(0x33FFFFFF));
    final safeDenom = math.max(tSec, 0.00001).toDouble();
    final progW = (timelineRect.width * (tSec / safeDenom)).clamp(0.0, timelineRect.width);
    _rrect(
      c,
      ui.Rect.fromLTWH(timelineRect.left, timelineRect.top, progW, timelineRect.height),
      6.0,
      ui.Paint()..color = const ui.Color(0x99FFFFFF),
    );
    _text(c, _fmtTime(tSec), x: w / 2.0, y: timelineRect.top - 20.0, size: 18.0, color: textColor, center: true);

    c.restore();
    final pic = rec.endRecording();
    return pic.toImage(w, h);
  }

  // ------- 画图小工具（统一使用 ui.Color） -------
  static void _rrect(ui.Canvas c, ui.Rect r, double radius, ui.Paint p) {
    c.drawRRect(ui.RRect.fromRectAndRadius(r, ui.Radius.circular(radius)), p);
  }

  static void _circle(ui.Canvas c, ui.Offset o, double r, ui.Color color, double stroke) {
    final p = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = stroke;
    c.drawCircle(o, r, p);
  }

  static void _line(ui.Canvas c, ui.Offset a, ui.Offset b, ui.Color color, double w) {
    final p = ui.Paint()
      ..color = color
      ..strokeWidth = w
      ..strokeCap = ui.StrokeCap.round;
    c.drawLine(a, b, p);
  }

  static void _text(ui.Canvas c, String text,
      {required double x,
        required double y,
        double size = 22.0,
        ui.Color color = const ui.Color(0xFFFFFFFF),
        bool alignRight = false,
        bool center = false}) {
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: size,
      fontWeight: ui.FontWeight.w600,
      fontFamily: 'Roboto',
      textAlign: center ? ui.TextAlign.center : (alignRight ? ui.TextAlign.right : ui.TextAlign.left),
    ))
      ..pushStyle(ui.TextStyle(color: color))
      ..addText(text);
    final p = pb.build();
    p.layout(const ui.ParagraphConstraints(width: 2000.0));
    double dx = x, dy = y;
    final w = p.maxIntrinsicWidth;
    if (alignRight) dx = x - w;
    if (center) dx = x - w / 2.0;
    c.drawParagraph(p, ui.Offset(dx, dy));
  }

  static String _fmtTime(double sec) {
    final h = (sec ~/ 3600);
    final m = ((sec % 3600) ~/ 60);
    final s = (sec % 60);
    // 形如 00:01:23.45
    final sStr = s.toStringAsFixed(2).padLeft(5, '0');
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:$sStr';
  }

  static String _esc(String p) => '"${p.replaceAll('"', r'\"')}"';

  static Future<void> _ff(String cmd) async {
    final ses = await FFmpegKit.execute(cmd);
    final rc = await ses.getReturnCode();
    if (rc?.isValueSuccess() != true) {
      final logs = (await ses.getAllLogs()).map((e) => e.getMessage()).join('\n');
      throw Exception('FFmpeg failed: $rc\n$logs');
    }
  }
}

class _Dim {
  final int width, height;
  _Dim(this.width, this.height);
}
