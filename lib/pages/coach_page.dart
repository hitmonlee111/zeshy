import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';

enum TimeRange { today, last7, thisMonth }

// —— 主题色 —— //
class _Brand {
  static const Color mint = Color(0xFF22C8A3);
  static const Color blue = Color(0xFF2F7CF6);
  static const Color orange = Color(0xFFFFB020);
  static const Color purple = Color(0xFF7A5AF5);
  static const Color red = Color(0xFFE53935);
  static Color tint(Color c, [double o = .16]) => c.withOpacity(o);
}

class CoachPage extends StatefulWidget {
  const CoachPage({super.key});
  @override
  State<CoachPage> createState() => _CoachPageState();
}

class _CoachPageState extends State<CoachPage> {
  TimeRange _range = TimeRange.today;
  late _RangeData _data;

  final ImagePicker _picker = ImagePicker();
  XFile? _pickedVideo;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _data = _DataFactory.generate(_range);
  }

  void _onChangeRange(TimeRange r) {
    setState(() {
      _range = r;
      _data = _DataFactory.generate(_range);
    });
  }

  Future<void> _pickVideo() async {
    setState(() => _picking = true);
    try {
      final file = await _picker.pickVideo(source: ImageSource.gallery);
      if (!mounted) return;
      setState(() => _pickedVideo = file);
      if (file != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已选择视频：${file.name}')),
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      final msg = e.message ?? e.code;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选择失败：$msg')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选择失败：$e')));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // —— 顶部时间范围：置中（取消“Statistics”标题） —— //
              Center(
                child: PopupMenuButton<TimeRange>(
                  initialValue: _range,
                  onSelected: _onChangeRange,
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: TimeRange.today, child: Text('Today')),
                    PopupMenuItem(value: TimeRange.last7, child: Text('Last 7 days')),
                    PopupMenuItem(value: TimeRange.thisMonth, child: Text('This month')),
                  ],
                  child: TextButton(
                    onPressed: null,
                    child: Text(
                      _range == TimeRange.today
                          ? 'Today'
                          : _range == TimeRange.last7
                          ? 'Last 7 days'
                          : 'This month',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // —— Statistics（无白底） —— //
              _StatsSection(data: _data),

              const SizedBox(height: 18),

              // —— 下面模块保持 —— //
              const _SectionHeader(title: '能量消耗'),
              const SizedBox(height: 8),
              _Card(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department_outlined,
                        color: _Brand.orange, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '本${_labelByRange(_range)}预估消耗：${_data.calories} kcal',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: () => ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('营养建议（示例）'))),
                      child: const Text('营养建议'),
                    )
                  ],
                ),
              ),

              const SizedBox(height: 18),
              const _SectionHeader(title: '技术指标'),
              const SizedBox(height: 8),
              _Card(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 180,
                      child: Row(
                        children: [
                          Expanded(
                            child: _GaugeRing(
                              value: _data.rhythmStability,
                              label: '节奏稳定度',
                              showCenterPercent: true,
                              ringColor: _Brand.mint,
                              containerColor: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _FrequencyCard(
                              value: _data.turnFrequency,
                              iconColor: _Brand.blue,
                              containerColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _FootSymmetry(
                      leftCount: _data.turnLeft,
                      rightCount: _data.turnRight,
                      leftColor: _Brand.mint,
                      rightColor: _Brand.blue,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),
              const _SectionHeader(title: '挑战'),
              const SizedBox(height: 8),
              SizedBox(
                height: 140,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _ChallengeCard(
                      title: '节奏稳定 30 秒',
                      desc: '转弯间隔方差 ≤ 0.20s',
                      progress: _data.rhythmStability,
                      progressColor: _Brand.mint,
                      action: () {},
                    ),
                    _ChallengeCard(
                      title: '速度稳定 20 秒',
                      desc: '±8% 波动内保持',
                      progress: math.min(1, _data.speedStability),
                      progressColor: _Brand.blue,
                      action: () {},
                    ),
                    _ChallengeCard(
                      title: '首次跳跃',
                      desc: '检测到一次明显起跳',
                      progress: _data.firstJumpDone ? 1 : 0.2,
                      progressColor: _Brand.orange,
                      action: () {},
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),
              const _SectionHeader(title: '录像分析'),
              const SizedBox(height: 8),
              _Card(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.video_file_outlined, size: 32, color: _Brand.blue),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _pickedVideo == null
                            ? '从系统相册选择滑雪视频，提交给模型分析（示例仅选择视频，不做上传）。'
                            : '已选择：${_pickedVideo!.name}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _picking ? null : _pickVideo,
                      icon: _picking
                          ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                          : const Icon(Icons.upload_file),
                      label: Text(_picking ? '处理中…' : '选择视频'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _labelByRange(TimeRange r) {
    switch (r) {
      case TimeRange.today:
        return '日';
      case TimeRange.last7:
        return '周';
      case TimeRange.thisMonth:
        return '月';
    }
  }
}

//
// ------------------- 数据模型 -------------------
//

class _RangeData {
  final List<double> speedSeries;
  final List<String> xLabels;

  final double distanceKm;
  final double avgSpeed;
  final double maxSpeed;
  final int elevationGain;
  final int calories;

  final double accelPeakG;
  final double headingVarDeg;

  final int turnLeft;
  final int turnRight;
  final double symmetry;        // 0..1
  final double rhythmStability; // 0..1
  final double turnFrequency;   // 次/分
  final bool firstJumpDone;
  final double speedStability;  // 0..1

  final double weekDistanceKm;
  final double weekAvgSpeed;
  final double weekRhythmAvg;
  final double deltaAvgSpeed;
  final double deltaRhythm;
  final List<String> recommendations;

  _RangeData({
    required this.speedSeries,
    required this.xLabels,
    required this.distanceKm,
    required this.avgSpeed,
    required this.maxSpeed,
    required this.elevationGain,
    required this.calories,
    required this.accelPeakG,
    required this.headingVarDeg,
    required this.turnLeft,
    required this.turnRight,
    required this.symmetry,
    required this.rhythmStability,
    required this.turnFrequency,
    required this.firstJumpDone,
    required this.speedStability,
    required this.weekDistanceKm,
    required this.weekAvgSpeed,
    required this.weekRhythmAvg,
    required this.deltaAvgSpeed,
    required this.deltaRhythm,
    required this.recommendations,
  });
}

class _DataFactory {
  static final _rnd = math.Random(7);

  static _RangeData generate(TimeRange r) {
    switch (r) {
      case TimeRange.today:
        return _today();
      case TimeRange.last7:
        return _last7();
      case TimeRange.thisMonth:
        return _thisMonth();
    }
  }

  static _RangeData _today() {
    final labels = List<String>.generate(12, (i) {
      final h = 9 + i;
      return '${h.toString().padLeft(2, '0')}:00';
    });
    final speeds = _smoothSeries(12, min: 8, max: 50);

    final distance = speeds.reduce((a, b) => a + b) / speeds.length * 0.6;
    final avg = speeds.reduce((a, b) => a + b) / speeds.length;
    final mx = speeds.reduce(math.max);
    final elev = 400 + _rnd.nextInt(300);
    final cal = 500 + _rnd.nextInt(400);

    final accG = (0.4 + _rnd.nextDouble() * 0.8);
    final headingStd = 18 + _rnd.nextDouble() * 12;

    final left = 40 + _rnd.nextInt(25);
    final right = 38 + _rnd.nextInt(25);
    final sym = 1 - (left - right).abs() / (left + right);
    final rhythm = 0.65 + _rnd.nextDouble() * 0.25;
    final freq = 1.4 + _rnd.nextDouble() * 0.7;
    final firstJump = _rnd.nextBool();
    final spStab = 0.5 + _rnd.nextDouble() * 0.4;

    return _RangeData(
      speedSeries: speeds,
      xLabels: labels,
      distanceKm: distance,
      avgSpeed: avg,
      maxSpeed: mx,
      elevationGain: elev,
      calories: cal,
      accelPeakG: accG,
      headingVarDeg: headingStd,
      turnLeft: left,
      turnRight: right,
      symmetry: sym.clamp(0, 1),
      rhythmStability: rhythm.clamp(0, 1),
      turnFrequency: freq,
      firstJumpDone: firstJump,
      speedStability: spStab.clamp(0, 1),
      weekDistanceKm: 32.4 + _rnd.nextDouble() * 6,
      weekAvgSpeed: 28.0 + _rnd.nextDouble() * 6,
      weekRhythmAvg: 0.6 + _rnd.nextDouble() * 0.2,
      deltaAvgSpeed: -1.3 + _rnd.nextDouble() * 2.6,
      deltaRhythm: -0.08 + _rnd.nextDouble() * 0.16,
      recommendations: _recommendations(),
    );
  }

  static _RangeData _last7() {
    final labels = const ['Sat','Sun','Mon','Tue','Wed','Thu','Fri'];
    final speeds = _smoothSeries(7, min: 20, max: 42);

    final distance = 25 + _rnd.nextDouble() * 20;
    final avg = speeds.reduce((a, b) => a + b) / speeds.length;
    final mx = speeds.reduce(math.max);
    final elev = 1500 + _rnd.nextInt(800);
    final cal = 2800 + _rnd.nextInt(1200);

    final accG = (0.5 + _rnd.nextDouble() * 0.6);
    final headingStd = 22 + _rnd.nextDouble() * 10;

    final left = 200 + _rnd.nextInt(80);
    final right = 210 + _rnd.nextInt(70);
    final sym = 1 - (left - right).abs() / (left + right);
    final rhythm = 0.6 + _rnd.nextDouble() * 0.25;
    final freq = 1.2 + _rnd.nextDouble() * 0.5;
    final firstJump = true;
    final spStab = 0.55 + _rnd.nextDouble() * 0.35;

    return _RangeData(
      speedSeries: speeds,
      xLabels: labels,
      distanceKm: distance,
      avgSpeed: avg,
      maxSpeed: mx,
      elevationGain: elev,
      calories: cal,
      accelPeakG: accG,
      headingVarDeg: headingStd,
      turnLeft: left,
      turnRight: right,
      symmetry: sym.clamp(0, 1),
      rhythmStability: rhythm.clamp(0, 1),
      turnFrequency: freq,
      firstJumpDone: firstJump,
      speedStability: spStab.clamp(0, 1),
      weekDistanceKm: distance,
      weekAvgSpeed: avg,
      weekRhythmAvg: rhythm,
      deltaAvgSpeed: -0.8 + _rnd.nextDouble() * 1.6,
      deltaRhythm: -0.06 + _rnd.nextDouble() * 0.12,
      recommendations: _recommendations(),
    );
  }

  static _RangeData _thisMonth() {
    final weekCount = 5;
    final labels = List<String>.generate(weekCount, (i) => 'Wk${i + 1}');
    final speeds = _smoothSeries(weekCount, min: 22, max: 40);

    final distance = 90 + _rnd.nextDouble() * 60;
    final avg = speeds.reduce((a, b) => a + b) / speeds.length;
    final mx = speeds.reduce(math.max);
    final elev = 5200 + _rnd.nextInt(2000);
    final cal = 9800 + _rnd.nextInt(2500);

    final accG = 0.55 + _rnd.nextDouble() * 0.5;
    final headingStd = 20 + _rnd.nextDouble() * 8;

    final left = 900 + _rnd.nextInt(260);
    final right = 880 + _rnd.nextInt(260);
    final sym = 1 - (left - right).abs() / (left + right);
    final rhythm = 0.62 + _rnd.nextDouble() * 0.2;
    final freq = 1.25 + _rnd.nextDouble() * 0.4;
    final firstJump = true;
    final spStab = 0.6 + _rnd.nextDouble() * 0.3;

    return _RangeData(
      speedSeries: speeds,
      xLabels: labels,
      distanceKm: distance,
      avgSpeed: avg,
      maxSpeed: mx,
      elevationGain: elev,
      calories: cal,
      accelPeakG: accG,
      headingVarDeg: headingStd,
      turnLeft: left,
      turnRight: right,
      symmetry: sym.clamp(0, 1),
      rhythmStability: rhythm.clamp(0, 1),
      turnFrequency: freq,
      firstJumpDone: firstJump,
      speedStability: spStab.clamp(0, 1),
      weekDistanceKm: distance / 4.0,
      weekAvgSpeed: avg,
      weekRhythmAvg: rhythm,
      deltaAvgSpeed: -0.6 + _rnd.nextDouble() * 1.2,
      deltaRhythm: -0.05 + _rnd.nextDouble() * 0.10,
      recommendations: _recommendations(),
    );
  }

  static List<double> _smoothSeries(int n, {required double min, required double max}) {
    final arr = List<double>.generate(n, (i) {
      final t = i / math.max(1, n - 1);
      final base = min + (max - min) * (0.3 + 0.7 * (0.5 + 0.5 * math.sin(2 * math.pi * t)));
      final noise = (_rnd.nextDouble() - 0.5) * (max - min) * 0.08;
      return (base + noise).clamp(min, max);
    });
    return arr;
  }

  static List<String> _recommendations() {
    return [
      '保持左右转弯间隔更均匀（目标差异 ≤ 0.2s）。',
      '在中低速雪道练习固定节奏：1.5 秒/次，连续 8～10 次。',
      '尝试缩小转弯半径，逐步提高横向加速度至 0.8G。',
    ];
  }
}

//
// ------------------- UI 组件（含新 Stats 模块） -------------------
//

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final txt = Theme.of(context).textTheme.titleMedium;
    return Row(
      children: [
        Text(title, style: txt?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

// 通用白卡容器（其他模块使用）
class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.5,
      shadowColor: Colors.black12,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: padding ?? const EdgeInsets.symmetric(vertical: 6),
        child: child,
      ),
    );
  }
}

/// =======================================================
/// ===============  新的 Statistics 组件  =================
/// =======================================================

class _StatsSection extends StatefulWidget {
  const _StatsSection({required this.data});
  final _RangeData data;

  @override
  State<_StatsSection> createState() => _StatsSectionState();
}

class _StatsSectionState extends State<_StatsSection> {
  bool _expanded = false;
  double _goalKm = 20.0; // 目标里程

  Future<void> _editGoalDialog() async {
    final ctrl = TextEditingController(text: _goalKm.toStringAsFixed(1));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置目标里程'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: '例如：20.0', suffixText: 'km'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(ctrl.text.trim());
      if (v != null && v > 0) {
        setState(() => _goalKm = v); // 触发重绘
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final progress = _goalKm > 0 ? (d.distanceKm / _goalKm).clamp(0, 1) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部大圆环（可点击设置目标；中央无图标）
        GestureDetector(
          onTap: _editGoalDialog,
          child: _StatsRingHeader(
            value: d.distanceKm,
            unit: 'km',
            label: '里程（目标 ${_goalKm.toStringAsFixed(1)}）',
            progress: progress.toDouble(),
            color: _Brand.mint,
          ),
        ),
        const SizedBox(height: 6),

        // 第一排：均速 / 落差 / 加速度 —— 轻信息块（无框）
        Row(
          children: [
            Expanded(
              child: _MetricLite(
                icon: Icons.speed_rounded,
                iconColor: _Brand.blue,
                valueText: d.avgSpeed.toStringAsFixed(1),
                unit: 'km/h',
                title: '均速',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricLite(
                icon: Icons.terrain_rounded,
                iconColor: _Brand.orange,
                valueText: d.elevationGain.toString(),
                unit: 'm',
                title: '落差',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricLite(
                icon: Icons.speed_outlined,
                iconColor: _Brand.red,
                valueText: d.accelPeakG.toStringAsFixed(2),
                unit: 'G',
                title: '加速度',
              ),
            ),
          ],
        ),

        // 下拉箭头
        IconButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          iconSize: 20,
          splashRadius: 22,
          icon: AnimatedRotation(
            turns: _expanded ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ),

        // 展开区：两列 Wrap，自适应且无框
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: _expanded
              ? LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final gap = 8.0;
              final colW = (w - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.explore_rounded,
                      iconColor: _Brand.purple,
                      valueText: d.headingVarDeg.toStringAsFixed(0),
                      unit: '°',
                      title: '方向波动',
                    ),
                  ),
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.flash_on_rounded,
                      iconColor: _Brand.mint,
                      valueText: d.maxSpeed.toStringAsFixed(1),
                      unit: 'km/h',
                      title: '急速',
                    ),
                  ),
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.flight_takeoff_rounded,
                      iconColor: _Brand.blue,
                      valueText:
                      (d.firstJumpDone ? 0.6 : 0.2).toStringAsFixed(1),
                      unit: 's',
                      title: '滞空',
                    ),
                  ),
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.height_rounded,
                      iconColor: _Brand.orange,
                      valueText:
                      (d.firstJumpDone ? 0.9 : 0.3).toStringAsFixed(1),
                      unit: 'm',
                      title: '腾空高度',
                    ),
                  ),
                ],
              );
            },
          )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 顶部大圆环（无中心图标）
class _StatsRingHeader extends StatelessWidget {
  const _StatsRingHeader({
    required this.value,
    required this.unit,
    required this.label,
    required this.progress,
    required this.color,
  });

  final double value;     // 里程值
  final String unit;      // 'km'
  final String label;     // '里程'
  final double progress;  // 0..1
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final ring = (w * 0.62).clamp(150.0, 220.0);
      final stroke = (ring * 0.12).clamp(10.0, 16.0);

      return SizedBox(
        height: ring + 8,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: ring,
              height: ring,
              child: CustomPaint(
                painter: _RingPainter(
                  progress: progress,
                  color: color,
                  trackColor: color.withOpacity(.18),
                  stroke: stroke,
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value >= 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(2),
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      height: 1.0,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(unit,
                    style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(label, style: const TextStyle(color: Colors.black54, fontSize: 12)),
              ],
            ),
          ],
        ),
      );
    });
  }
}

/// 轻信息块（无边框/无阴影/无圆圈）
class _MetricLite extends StatelessWidget {
  const _MetricLite({
    required this.icon,
    required this.iconColor,
    required this.valueText,
    required this.unit,
    required this.title,
  });

  final IconData icon;
  final Color iconColor;
  final String valueText;
  final String unit;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26, color: iconColor),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            valueText,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.0),
          ),
        ),
        const SizedBox(height: 2),
        Text(unit, style: const TextStyle(color: Colors.black54, fontSize: 12)),
        const SizedBox(height: 2),
        Text(title, style: const TextStyle(color: Colors.black54, fontSize: 12)),
      ],
    );
  }
}

// —— 环形画笔（为保证目标修改后必重绘，这里总是返回 true） —— //
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.stroke,
  });

  final double progress; // 0..1
  final Color color;
  final Color trackColor;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2 - stroke / 2;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final progPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // 背景轨道
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi,
      false,
      trackPaint,
    );
    // 进度（超出满圈即画满）
    final sweep = 2 * math.pi * progress.clamp(0, 1);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      progPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => true;
}

// —— 下面保留你原有的 Frequency / Foot / Challenge 组件（未改） —— //

class _FrequencyCard extends StatelessWidget {
  const _FrequencyCard({
    required this.value,
    this.iconColor = _Brand.blue,
    this.containerColor = Colors.white,
  });
  final double value;
  final Color iconColor;
  final Color containerColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.loop, color: iconColor, size: 20),
                const SizedBox(width: 6),
                const Text('转弯频率', style: TextStyle(color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 26,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${value.toStringAsFixed(2)} 次/分',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FootSymmetry extends StatelessWidget {
  const _FootSymmetry({
    required this.leftCount,
    required this.rightCount,
    this.leftColor = _Brand.mint,
    this.rightColor = _Brand.blue,
  });

  final int leftCount;
  final int rightCount;
  final Color leftColor;
  final Color rightColor;

  @override
  Widget build(BuildContext context) {
    final total = (leftCount + rightCount).clamp(1, 1 << 30);
    final leftRatio = leftCount / total;
    final rightRatio = rightCount / total;

    double scale(double r) => 0.8 + 0.4 * r;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: 70,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Transform.scale(
                      scale: scale(leftRatio),
                      child: _FootIcon(color: leftColor, isLeft: true),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${(leftRatio * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                const Text('左脚', style: TextStyle(color: Colors.black54, fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: 70,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Transform.scale(
                      scale: scale(rightRatio),
                      child: _FootIcon(color: rightColor, isLeft: false),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${(rightRatio * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                const Text('右脚', style: TextStyle(color: Colors.black54, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FootIcon extends StatelessWidget {
  const _FootIcon({required this.color, this.isLeft = true});
  final Color color;
  final bool isLeft;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FootPainter(color: color, isLeft: isLeft),
      size: const Size(60, 100),
    );
  }
}

class _FootPainter extends CustomPainter {
  _FootPainter({required this.color, required this.isLeft});
  final Color color;
  final bool isLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final paint = Paint()
      ..color = color.withOpacity(.85)
      ..style = PaintingStyle.fill;

    final footPath = Path()
      ..moveTo(w * .2, h * .25)
      ..quadraticBezierTo(w * .05, h * .55, w * .25, h * .9)
      ..quadraticBezierTo(w * .5, h * 1.02, w * .75, h * .9)
      ..quadraticBezierTo(w * .95, h * .55, w * .8, h * .25)
      ..quadraticBezierTo(w * .5, h * .05, w * .2, h * .25)
      ..close();

    if (!isLeft) {
      canvas.translate(w, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(footPath, paint);

    final toePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final toeCenters = [
      Offset(w * .22, h * .18),
      Offset(w * .34, h * .13),
      Offset(w * .46, h * .12),
      Offset(w * .58, h * .15),
    ];
    final toeR = w * .06;
    for (final c in toeCenters) {
      canvas.drawCircle(c, toeR, toePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FootPainter old) =>
      old.color != color || old.isLeft != isLeft;
}

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({
    required this.title,
    required this.desc,
    required this.progress,
    required this.action,
    this.progressColor = _Brand.mint,
  });

  final String title;
  final String desc;
  final double progress;
  final VoidCallback action;
  final Color progressColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      margin: const EdgeInsets.only(right: 12),
      child: Card(
        elevation: 1.5,
        shadowColor: Colors.black12,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      value: progress.clamp(0, 1),
                      strokeWidth: 6,
                      color: progressColor,
                      backgroundColor: progressColor.withOpacity(.25),
                    ),
                  ),
                  Text('${(progress * 100).round()}%',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: action, icon: const Icon(Icons.play_arrow_rounded)),
            ],
          ),
        ),
      ),
    );
  }
}

/// —— 技术指标用环（保持不变） —— ///
class _GaugeRing extends StatelessWidget {
  const _GaugeRing({
    required this.value,
    required this.label,
    this.showCenterPercent = false,
    this.ringColor = _Brand.mint,
    this.containerColor = Colors.white,
  });

  final double value; // 0..1
  final String label;
  final bool showCenterPercent;
  final Color ringColor;
  final Color containerColor;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0, 1).toDouble();

    return LayoutBuilder(
      builder: (context, c) {
        final side = math.min(c.maxWidth, c.maxHeight);
        final diameter = (side * 0.72).clamp(72.0, 160.0).toDouble();
        final stroke = (diameter * 0.12).clamp(8.0, 14.0).toDouble();

        return Container(
          decoration: BoxDecoration(
            color: containerColor,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: diameter,
                  height: diameter,
                  child: CustomPaint(
                    painter: _RingPainter(
                      progress: v,
                      color: ringColor,
                      trackColor: ringColor.withOpacity(.2),
                      stroke: stroke,
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: showCenterPercent
                            ? Text(
                          '${(v * 100).round()}%',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                        )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(label,
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ),
        );
      },
    );
  }
}
