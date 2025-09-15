// lib/video/imu_video_generator.dart
//
// ffmpeg_kit_flutter_new 3.2.0
// HUD：右上/左上角小卡片，显示速度（km/h）+ 航向（°）；采用 TextPainter 先测量再布局，避免重叠。
// 速度：滑动均值去重力 -> 积分 -> 漂移抑制；航向：gz 去偏置后积分（演示用途）
// 修复点：
//  - 新增 onProgress 回调（0~1），各阶段持续上报真实进度
//  - FFmpeg 合成显式加 -start_number 1（两路一致），避免帧序起始推断不一致
//  - 渲染覆盖图严格按 frameCount 生成，确保与底图逐帧对齐
//
// ⚠️ 重要：调用方 recFps 必须与固件一致（你的固件为 10fps）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' as fp; // TextPainter
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
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
  final int recFps;             // 固件 REC_FPS（例：10/12）——务必与固件一致
  final int outFps;             // 输出帧率，建议 30
  final int crf;                // 画质 18~23
  final String? outDirOverride; // 输出目录（可选）

  // HUD 定位/缩放
  final String hudCorner;       // 'topRight' | 'topLeft'
  final double hudScale;        // 占画面宽度比例（0.18~0.55）

  // IMU 频率（固件是 100Hz）
  final int imuHz;

  const ImuVideoGeneratorConfig({
    required this.framesDir,
    required this.imuCsvPath,
    this.recFps = 12,   // 调用处务必覆盖为 10（你的固件）
    this.outFps = 30,
    this.crf = 18,
    this.outDirOverride,
    this.hudCorner = 'topRight',
    this.hudScale = 0.22, // 小一点
    this.imuHz = 100,
  });
}

class ImuVideoGeneratorResult {
  final String rawMp4;   // 图片直接合成的视频
  final String hudMp4;   // 叠加 HUD 后的视频
  ImuVideoGeneratorResult({required this.rawMp4, required this.hudMp4});
}

class ImuVideoGenerator {
  /// 生成视频（带可选进度回调 0~1）
  static Future<ImuVideoGeneratorResult> generate(
      ImuVideoGeneratorConfig cfg, {
        void Function(double p)? onProgress,
      }) async {
    double _p = 0.0;
    void report(double v) {
      _p = v.clamp(0.0, 1.0);
      if (onProgress != null) onProgress!(_p);
    }

    // 分配各阶段的大致权重（总和=1）：
    // 解析/插值 10% + 渲染覆盖图 60% + 合成 raw 10% + 合成 hud 20%
    const wParse = 0.10;
    const wOver  = 0.60;
    const wRaw   = 0.10;
    const wHud   = 0.20;

    // 1) 输出目录
    final dir = cfg.outDirOverride ?? (await getApplicationDocumentsDirectory()).path;
    final outRaw = '$dir/out_raw.mp4';
    final overlayDir = '$dir/overlays';
    final outHud = '$dir/out_hud.mp4';
    await Directory(overlayDir).create(recursive: true);

    // 2) 分辨率（读第一帧）
    final firstFrame = _firstFramePath(cfg.framesDir);
    final dim = await _readImageDim(File(firstFrame));

    // 3) 解析 IMU + 插值到帧
    report(0.02 * wParse);
    final samples = await _parseImuCsv(cfg.imuCsvPath);
    report(0.40 * wParse);
    final frameCount = _countFrames(cfg.framesDir);
    if (frameCount <= 0) {
      throw Exception('未找到帧文件（frame_00001.jpg 起）。');
    }
    final frameDtMs = (1000.0 / cfg.recFps);

    final speedSeries   = _estimateSpeedKmhFromImu(samples, imuHz: cfg.imuHz);
    report(0.70 * wParse);
    final headingSeries = _estimateHeadingDegFromImu(samples, imuHz: cfg.imuHz);

    final perFrameSpeedKmh = _interpSeriesToFrames(
      timesMs: speedSeries.timesMs,
      values: speedSeries.values,
      frameCount: frameCount,
      frameDtMs: frameDtMs,
    );
    final perFrameHeadingDeg = _interpSeriesToFrames(
      timesMs: headingSeries.timesMs,
      values: headingSeries.values,
      frameCount: frameCount,
      frameDtMs: frameDtMs,
    );
    report(1.0 * wParse);

    // 4) 渲染透明 HUD 覆盖图（与帧同尺寸，严格渲染 frameCount 张）
    await _renderHudOverlays(
      overlayDir: overlayDir,
      sizeW: dim.width,
      sizeH: dim.height,
      perFrameSpeedKmh: perFrameSpeedKmh,
      perFrameHeadingDeg: perFrameHeadingDeg,
      hudCorner: cfg.hudCorner,
      hudScale: cfg.hudScale,
      onProgress: (i, n) {
        // 在 wOver 区间内线性推进
        final local = (i / n).clamp(0.0, 1.0);
        report(wParse + local * wOver);
      },
    );

    // 5) 合成 out_raw.mp4
    report(wParse + wOver + 0.05 * wRaw);
    await _ff(
        '-y '
            '-framerate ${cfg.recFps} -start_number 1 -i ${_esc(cfg.framesDir)}/frame_%05d.jpg '
            '-c:v libx264 -profile:v high -pix_fmt yuv420p -r ${cfg.outFps} ${_esc(outRaw)}'
    );
    report(wParse + wOver + 1.0 * wRaw);

    // 6) 叠加 overlay 得 out_hud.mp4
    report(wParse + wOver + wRaw + 0.05 * wHud);
    await _ff(
        '-y '
            '-framerate ${cfg.recFps} -start_number 1 -i ${_esc(cfg.framesDir)}/frame_%05d.jpg '
            '-framerate ${cfg.recFps} -start_number 1 -i ${_esc(overlayDir)}/overlay_%05d.png '
            '-filter_complex "[0:v][1:v]overlay=0:0:format=auto" '
            '-c:v libx264 -pix_fmt yuv420p -r ${cfg.outFps} -crf ${cfg.crf} ${_esc(outHud)}'
    );
    report(1.0);

    return ImuVideoGeneratorResult(rawMp4: outRaw, hudMp4: outHud);
  }

  // ---------- 工具与实现 ----------

  static String _firstFramePath(String framesDir) => '$framesDir/frame_00001.jpg';

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

  // ---------- 速度估算（IMU-only） ----------
  static _Series _estimateSpeedKmhFromImu(List<ImuSample> xs, {int imuHz = 100}) {
    final n = xs.length;
    if (n == 0) return _Series([], []);

    const double G = 9.80665;
    final double dt = 1.0 / imuHz;

    final int win = ((imuHz * 0.8).round()).clamp(5, 400); // ~0.8s 窗口
    const double accThresh = 0.18; // m/s^2 认为近静止
    const int calmNeeded = 12;     // 连续 calmNeeded 采样低于阈值 → 强抑制
    const double decayFast = 0.82; // 强抑制衰减
    const double decaySoft = 0.985;// 常规轻微衰减

    final qx = <double>[], qy = <double>[], qz = <double>[];
    double sx = 0, sy = 0, sz = 0;

    double vx = 0, vy = 0, vz = 0;
    int calm = 0;

    final times = <int>[];
    final velKmh = <double>[];

    for (int i = 0; i < n; i++) {
      final a = xs[i];

      // 滑动平均估计重力方向（单位 g）
      qx.add(a.ax); sx += a.ax; if (qx.length > win) sx -= qx.removeAt(0);
      qy.add(a.ay); sy += a.ay; if (qy.length > win) sy -= qy.removeAt(0);
      qz.add(a.az); sz += a.az; if (qz.length > win) sz -= qz.removeAt(0);
      final curWin = qx.length;
      final gx = sx / curWin, gy = sy / curWin, gz = sz / curWin;

      // 线性加速度（去重力）→ m/s^2
      final lax = (a.ax - gx) * G;
      final lay = (a.ay - gy) * G;
      final laz = (a.az - gz) * G;

      final amag = math.sqrt(lax * lax + lay * lay + laz * laz);
      if (amag < accThresh) calm++; else calm = 0;

      // 欧拉积分 + 漂移抑制
      vx += lax * dt; vy += lay * dt; vz += laz * dt;
      vx *= decaySoft; vy *= decaySoft; vz *= decaySoft;
      if (calm >= calmNeeded) { vx *= decayFast; vy *= decayFast; vz *= decayFast; }

      double speedMps = math.sqrt(math.max(0, vx * vx + vy * vy + vz * vz));
      double kmh = speedMps * 3.6;
      if (!kmh.isFinite || kmh.isNaN || kmh < 0) kmh = 0.0;

      times.add(a.tsMs);
      velKmh.add(kmh);
    }

    return _Series(times, velKmh);
  }

  // ---------- 航向角估算（仅用 gz，去偏置后积分） ----------
  static _Series _estimateHeadingDegFromImu(List<ImuSample> xs, {int imuHz = 100}) {
    final n = xs.length;
    if (n == 0) return _Series([], []);

    final double dt = 1.0 / imuHz;
    final int win = ((imuHz * 2.0).round()).clamp(8, 800); // ~2s 平滑偏置
    final qz = <double>[];
    double sz = 0;

    double heading = 0.0; // deg
    final times = <int>[];
    final vals = <double>[];

    for (int i = 0; i < n; i++) {
      final gzi = xs[i].gz;

      // 滑动均值估计 gz 偏置
      qz.add(gzi); sz += gzi; if (qz.length > win) sz -= qz.removeAt(0);
      final bias = sz / qz.length;

      final gzNoBias = gzi - bias; // deg/s
      heading += gzNoBias * dt;    // 积分为 deg
      heading = heading % 360.0; if (heading < 0) heading += 360.0;

      times.add(xs[i].tsMs);
      vals.add(heading);
    }

    return _Series(times, vals);
  }

  /// 把非均匀时间序列插值到帧序列（t = i * frameDtMs）
  static List<double> _interpSeriesToFrames({
    required List<int> timesMs,
    required List<double> values,
    required int frameCount,
    required double frameDtMs,
  }) {
    final out = List<double>.filled(frameCount, values.isNotEmpty ? values.first : 0.0);
    if (timesMs.isEmpty) return out;

    for (int i = 0; i < frameCount; i++) {
      final t = (i * frameDtMs).round();
      if (t <= timesMs.first) { out[i] = values.first; continue; }
      if (t >= timesMs.last)  { out[i] = values.last;  continue; }
      int lo = 0, hi = timesMs.length - 1;
      while (lo + 1 < hi) {
        final mid = (lo + hi) >> 1;
        if (timesMs[mid] <= t) lo = mid; else hi = mid;
      }
      final t0 = timesMs[lo], t1 = timesMs[hi];
      final v0 = values[lo], v1 = values[hi];
      final k = (t - t0) / (t1 - t0).clamp(1, 1 << 30);
      double val = v0 + (v1 - v0) * k;
      if (!val.isFinite || val.isNaN) val = 0.0;
      out[i] = val;
    }
    return out;
  }

  // ---------- HUD 渲染（角落小卡片：速度 + 航向） ----------
  static Future<void> _renderHudOverlays({
    required String overlayDir,
    required int sizeW,
    required int sizeH,
    required List<double> perFrameSpeedKmh,
    required List<double> perFrameHeadingDeg,
    required String hudCorner,
    required double hudScale,
    void Function(int i, int n)? onProgress,
  }) async {
    final n = math.min(
      math.min(perFrameSpeedKmh.length, perFrameHeadingDeg.length),
      // 强制与帧数一致：防止 overlay 少/多于底图
      perFrameSpeedKmh.length,
    );

    for (int i = 0; i < n; i++) {
      final path = '$overlayDir/overlay_${(i + 1).toString().padLeft(5, '0')}.png';
      final img = await _drawHud(
        sizeW, sizeH,
        perFrameSpeedKmh[i],
        perFrameHeadingDeg[i],
        hudCorner,
        hudScale,
      );
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(byteData!.buffer.asUint8List());
      img.dispose();

      if (onProgress != null && (i & 3) == 0) { // 每4帧报一次，降低回调频率
        onProgress(i + 1, n);
      }
    }
    if (onProgress != null) onProgress(n, n);
  }

  static Future<ui.Image> _drawHud(
      int w,
      int h,
      double rawKmh,
      double rawHeadingDeg,
      String hudCorner,   // 仍保留参数以兼容签名，但此版本固定“左上角=方向，右上角=速度”
      double hudScale,    // 此版本不使用卡片比例，依旧保留参数以兼容
      ) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.save(); // 背景透明

    // 保护数值
    double kmh = rawKmh;
    if (!kmh.isFinite || kmh.isNaN || kmh < 0) kmh = 0.0;
    kmh = kmh.clamp(0.0, 999.9);

    double hd = rawHeadingDeg % 360.0;
    if (hd < 0) hd += 360.0;

    // 分辨率自适应字号（偏小，适合 ~320p）
    final sMin = math.min(w.toDouble(), h.toDouble());
    final pad = (sMin * 0.02).clamp(4.0, 10.0);  // 内边距
    final spSize = (sMin * 0.08).clamp(14.0, 44.0); // 速度字号
    final hdSize = (sMin * 0.08).clamp(12.0, 34.0); // 方向字号

    // 文本
    final speedStr = kmh < 10.0 ? '${kmh.toStringAsFixed(1)} km/h'
        : '${kmh.toStringAsFixed(0)} km/h';
    final headingStr = '${hd.round()}°';

    // 左上角：方向角
    _tpTextWithOutline(
      c,
      headingStr,
      x: pad,
      y: pad,
      size: hdSize,
      alignRight: false,
    );

    // 右上角：速度（右对齐）
    final spWidth = _measureTextWidthTP(speedStr, spSize, fp.FontWeight.w700);
    _tpTextWithOutline(
      c,
      speedStr,
      x: w - pad - spWidth,
      y: pad,
      size: spSize,
      alignRight: false,
      weight: fp.FontWeight.w700,
    );

    c.restore();
    final pic = rec.endRecording();
    return pic.toImage(w, h);
  }

  // ---------- 绘制工具 ----------
  static void _tpTextWithOutline(
      ui.Canvas c,
      String text, {
        required double x,
        required double y,
        double size = 22.0,
        ui.Color fill = const ui.Color(0xFFFFFFFF),
        ui.Color stroke = const ui.Color(0xCC000000),
        double strokePx = 1.2,
        fp.FontWeight weight = fp.FontWeight.w700,
        bool alignRight = false, // 若想用右对齐，可先测宽，再给合适的 x
      }) {
    final spanFill = fp.TextSpan(
      text: text,
      style: fp.TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: fill,
      ),
    );
    final spanStroke = fp.TextSpan(
      text: text,
      style: fp.TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: stroke,
      ),
    );

    final tpFill = fp.TextPainter(
      text: spanFill,
      textAlign: fp.TextAlign.left,
      textDirection: fp.TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 2048);

    final tpStroke = fp.TextPainter(
      text: spanStroke,
      textAlign: fp.TextAlign.left,
      textDirection: fp.TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 2048);

    double dx = x;
    if (alignRight) dx = x - tpFill.width;

    // 简单的描边：四个方向的黑色文字 + 正中央白色文字
    final offsets = <ui.Offset>[
      ui.Offset(dx - strokePx, y),
      ui.Offset(dx + strokePx, y),
      ui.Offset(dx, y - strokePx),
      ui.Offset(dx, y + strokePx),
    ];
    for (final o in offsets) {
      tpStroke.paint(c, o);
    }
    tpFill.paint(c, ui.Offset(dx, y));
  }

  static double _measureTextWidthTP(String text, double size, fp.FontWeight weight) {
    return _makeTp(text, size, const ui.Color(0xFFFFFFFF), weight).width;
  }

  static fp.TextPainter _makeTp(
      String text,
      double size,
      ui.Color color,
      fp.FontWeight weight,
      ) {
    final span = fp.TextSpan(
      text: text,
      style: fp.TextStyle(fontSize: size, fontWeight: weight, color: color),
    );
    final tp = fp.TextPainter(
      text: span,
      textAlign: fp.TextAlign.left,
      textDirection: fp.TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 2048);
    return tp;
  }

  static String _esc(String p) => '"${p.replaceAll('"', r'\"')}"';

  static Future<void> _ff(String cmd) async {
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (rc?.isValueSuccess() != true) {
      final logs = (await session.getAllLogs()).map((e) => e.getMessage()).join('\n');
      throw Exception('FFmpeg failed: $rc\n$logs');
    }
  }
}

// ---------- 辅助类型 ----------
class _Dim {
  final int width, height;
  _Dim(this.width, this.height);
}

class _Series {
  final List<int> timesMs;
  final List<double> values;
  _Series(this.timesMs, this.values);
}
