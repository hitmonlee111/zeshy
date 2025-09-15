import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';

enum TimeRange { today, last7, thisMonth }

// ======== Config: Board IP (editable) ========
const String kBoardIp = '192.168.4.1';

// —— Brand Colors —— //
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
  State<CoachPage> createState() => CoachPageState();
}

class CoachPageState extends State<CoachPage> {
  TimeRange _range = TimeRange.today;
  late _RangeData _data;

  final ImagePicker _picker = ImagePicker();
  XFile? _pickedVideo;
  bool _picking = false;

  // ===== New: refresh state =====
  bool _refreshing = false;

  // ===== Animation version tick (for AnimatedSwitcher) =====
  int _v = 0;

  @override
  void initState() {
    super.initState();
    _data = _DataFactory.generate(_range); // initial demo data
  }

  void _onChangeRange(TimeRange r) {
    setState(() {
      _range = r;
      // For demo: regenerate sample; you can aggregate from computed results instead.
      _data = _DataFactory.generate(_range);
      _v++; // trigger cross-fade
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
          SnackBar(content: Text('Selected video: ${file.name}')),
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      final msg = e.message ?? e.code;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Selection failed: $msg')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Selection failed: $e')));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  // =======================================================
  // ======= Refresh entry: called from the main AppBar =====
  // =======================================================
  Future<void> refreshFromAppBar() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final result = await _downloadAllImuAndCompute(kBoardIp);
      if (!mounted) return;
      // Update UI with computed metrics (keep layout unchanged; just swap data)
      setState(() {
        _data = result;
        _v++; // trigger cross-fade on refresh
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Refreshed. Metrics updated from IMU data.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Refresh failed: $e')));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // =======================================================
  // ============== Networking & Metrics (MVP) =============
  // =======================================================
  Future<_RangeData> _downloadAllImuAndCompute(String ip) async {
    // 1) List sessions
    final sessions = await _fetchSessions(ip);
    if (sessions.isEmpty) {
      throw Exception('No sessions');
    }

    // 2) For each session, find imu.csv and download
    final allSamples = <_ImuSample>[];
    final tmpDir = await getTemporaryDirectory();
    for (final sess in sessions) {
      final files = await _fetchFilesInSession(ip, sess);
      if (!files.contains('/$sess/imu.csv')) {
        // Firmware may respond with bare filenames; normalize to "/REC_xxx/imu.csv".
        // If not found in normalized list, try a loose match.
        if (!files.any((e) => e.toLowerCase().endsWith('imu.csv'))) {
          // No IMU file in this session; skip it.
          continue;
        }
      }

      final url = Uri.parse('http://$ip/fs/file?path=/$sess/imu.csv');
      final out = File('${tmpDir.path}/$sess-imu.csv');

      final r = await http.get(url).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        // Retry once without leading slash
        final r2 = await http
            .get(Uri.parse('http://$ip/fs/file?path=$sess/imu.csv'))
            .timeout(const Duration(seconds: 20));
        if (r2.statusCode != 200) {
          continue;
        }
        await out.writeAsBytes(r2.bodyBytes);
      } else {
        await out.writeAsBytes(r.bodyBytes);
      }

      final samples = await _parseImuCsv(out);
      allSamples.addAll(samples);
    }

    if (allSamples.isEmpty) {
      throw Exception('No imu.csv found in sessions');
    }

    // 3) Compute metrics from IMU samples
    final calc = _Metrics.fromImu(allSamples);

    // 4) Map back to page data model (no UI structure changes)
    final d = _RangeData(
      speedSeries: calc.speedSeries, // used by charts (rings here)
      xLabels: List<String>.generate(calc.speedSeries.length, (i) => '${i + 1}'),
      distanceKm: calc.distanceKm,
      avgSpeed: calc.avgSpeed,
      maxSpeed: calc.maxSpeed,
      elevationGain: calc.elevationGain,
      calories: calc.caloriesKcal,
      accelPeakG: calc.accelPeakG,
      headingVarDeg: calc.headingVarDeg,
      turnLeft: calc.turnLeft,
      turnRight: calc.turnRight,
      symmetry: calc.symmetry,
      rhythmStability: calc.rhythmStability,
      turnFrequency: calc.turnFrequency, // per min
      firstJumpDone: calc.maxAirtimeS > 0.15,
      speedStability: calc.speedStability,
      weekDistanceKm: calc.distanceKm, // simple reuse
      weekAvgSpeed: calc.avgSpeed,
      weekRhythmAvg: calc.rhythmStability,
      deltaAvgSpeed: 0, // no historical compare yet
      deltaRhythm: 0,
      recommendations: _DataFactory._recommendations(),
    );
    return d;
  }

  // ------- Firmware APIs ------- //
  Future<List<String>> _fetchSessions(String ip) async {
    final url = Uri.parse('http://$ip/fs/list');
    final r = await http.get(url).timeout(const Duration(seconds: 8));
    if (r.statusCode == 409) {
      throw Exception('Device is recording (409)');
    }
    if (r.statusCode != 200) {
      throw Exception('List sessions failed: HTTP ${r.statusCode}');
    }

    // Could be ["\/REC_21","\/REC_88"] or ["/REC_88", ...] or ["REC_88", ...]
    final decoded = json.decode(r.body);
    final out = <String>[];
    if (decoded is List) {
      for (final it in decoded) {
        var s = it.toString().trim();
        s = s.replaceAll('\\', '/');
        s = s.replaceFirst(RegExp(r'^/+'), '');
        if (!s.startsWith('REC_')) {
          final m = RegExp(r'(REC_\d+)').firstMatch(s);
          if (m != null) s = m.group(1)!;
        }
        if (s.startsWith('REC_')) out.add(s);
      }
    }
    out.sort();
    return out;
  }

  Future<List<String>> _fetchFilesInSession(String ip, String sess) async {
    final url = Uri.parse('http://$ip/fs/list?session=/$sess');
    final r = await http.get(url).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('List files failed: HTTP ${r.statusCode}');
    }
    final decoded = json.decode(r.body);
    final out = <String>[];
    if (decoded is List) {
      for (final s in decoded) {
        final name = s.toString();
        out.add('/$sess/$name');
      }
    }
    return out;
  }

  // ------- CSV parsing ------- //
  Future<List<_ImuSample>> _parseImuCsv(File f) async {
    final lines = await f.readAsLines();
    final out = <_ImuSample>[];
    for (final ln in lines) {
      final t = ln.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#')) continue;
      if (t.startsWith('ts_ms')) continue;
      final parts = t.split(',');
      if (parts.length < 7) continue;
      final ts = int.tryParse(parts[0]) ?? 0;
      double p(String x) => double.tryParse(x) ?? 0.0;
      out.add(_ImuSample(
        tsMs: ts,
        ax: p(parts[1]),
        ay: p(parts[2]),
        az: p(parts[3]),
        gx: p(parts[4]), // deg/s
        gy: p(parts[5]),
        gz: p(parts[6]),
      ));
    }
    out.sort((a, b) => a.tsMs.compareTo(b.tsMs));
    return out;
  }

  // ======================= UI =======================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      // Note: no AppBar here; use the shared main AppBar
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // —— Top range selector centered (no "Statistics" title) —— //
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

              // —— Statistics (no white background) —— //
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: KeyedSubtree(
                  key: ValueKey('stats-$_v'),
                  child: _StatsSection(data: _data),
                ),
              ),
              const SizedBox(height: 18),

              // —— Energy —— //
              const _SectionHeader(title: 'Energy'),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: KeyedSubtree(
                  key: ValueKey('energy-$_v'),
                  child: _EnergyRowCompact(
                    calories: _data.calories,
                    rangeLabel: _labelByRange(_range),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // —— Technical Metrics —— //
              const _SectionHeader(title: 'Technical Metrics'),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: KeyedSubtree(
                  key: ValueKey('tech-$_v'),
                  child: _Card(
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
                                  label: 'Rhythm Stability',
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
                ),
              ),
              const SizedBox(height: 18),

              // —— Challenges —— //
              const _SectionHeader(title: 'Challenges'),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: KeyedSubtree(
                  key: ValueKey('challenges-$_v'),
                  child: SizedBox(
                    height: 140,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _ChallengeCard(
                          title: 'Keep Rhythm for 30 s',
                          desc: 'Turn-interval variance ≤ 0.20 s',
                          progress: _data.rhythmStability,
                          progressColor: _Brand.mint,
                          action: () {},
                        ),
                        _ChallengeCard(
                          title: 'Speed Stable for 20 s',
                          desc: 'Stay within ±8% fluctuation',
                          progress: math.min(1, _data.speedStability),
                          progressColor: _Brand.blue,
                          action: () {},
                        ),
                        _ChallengeCard(
                          title: 'First Jump',
                          desc: 'Detect one clear takeoff',
                          progress: _data.firstJumpDone ? 1 : 0.2,
                          progressColor: _Brand.orange,
                          action: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // —— Video Analysis —— //
              const _SectionHeader(title: 'Video Analysis'),
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
                            ? 'Pick a ski video from the system gallery and send it to the model for analysis (demo only — no upload).'
                            : 'Selected: ${_pickedVideo!.name}',
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
                      label: Text(_picking ? 'Processing…' : 'Pick Video'),
                    ),
                  ],
                ),
              ),

              // Optional: small hint while refreshing
              if (_refreshing)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(
                    child: Text(
                      'Refreshing IMU data…',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
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
        return 'day';
      case TimeRange.last7:
        return 'week';
      case TimeRange.thisMonth:
        return 'month';
    }
  }
}

class _EnergyRowCompact extends StatelessWidget {
  const _EnergyRowCompact({required this.calories, required this.rangeLabel});
  final int calories;
  final String rangeLabel; // 'day' | 'week' | 'month'

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.zero, // 去掉大内边距
      child: ListTile(
        leading: const Icon(Icons.local_fire_department_outlined,
            color: _Brand.orange, size: 22),
        title: const Text(
          'Calories',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Tag('${rangeLabel[0].toUpperCase()}${rangeLabel.substring(1)}'),
            const SizedBox(width: 8),
            Text(
              '$calories kcal',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        trailing: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _Brand.orange.withOpacity(.15),
            foregroundColor: _Brand.orange,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          ),
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nutrition tips (demo)')),
          ),
          child: const Text(
            'Tips',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minLeadingWidth: 0,
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? _Brand.orange.withOpacity(.12);
    final t = (color ?? _Brand.orange).withOpacity(.9);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: t, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ------------------- Data Model ------------------- //
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
  final double turnFrequency;   // per min
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
      'Keep left/right turn intervals more even (target diff ≤ 0.2 s).',
      'Practice fixed rhythm on green/blue runs: 1.5 s/turn, 8–10 turns in a row.',
      'Try smaller turn radius and gradually increase lateral accel up to ~0.8 G.',
    ];
  }
}

// ------------------- Metrics Core ------------------- //
class _ImuSample {
  final int tsMs; // relative ms
  final double ax, ay, az; // g (includes gravity)
  final double gx, gy, gz; // deg/s

  _ImuSample({
    required this.tsMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });
}

class _Metrics {
  // Visualization / mapping
  final List<double> speedSeries;

  // Distance / speed / elevation / calories (rough)
  final double distanceKm;
  final double avgSpeed;
  final double maxSpeed;
  final int elevationGain;
  final int caloriesKcal;

  // Accel / heading
  final double accelPeakG;
  final double headingVarDeg;

  // Turning / rhythm / symmetry / stability
  final int turnLeft;
  final int turnRight;
  final double symmetry;
  final double rhythmStability; // 0..1
  final double turnFrequency;   // per min
  final double speedStability;  // 0..1

  // Jumping
  final double maxAirtimeS;
  final double maxJumpHeightM;

  _Metrics({
    required this.speedSeries,
    required this.distanceKm,
    required this.avgSpeed,
    required this.maxSpeed,
    required this.elevationGain,
    required this.caloriesKcal,
    required this.accelPeakG,
    required this.headingVarDeg,
    required this.turnLeft,
    required this.turnRight,
    required this.symmetry,
    required this.rhythmStability,
    required this.turnFrequency,
    required this.speedStability,
    required this.maxAirtimeS,
    required this.maxJumpHeightM,
  });

  static _Metrics fromImu(List<_ImuSample> xs) {
    if (xs.length < 10) {
      return _empty();
    }

    // Time steps
    final dt = <double>[];
    for (int i = 1; i < xs.length; i++) {
      dt.add(((xs[i].tsMs - xs[i - 1].tsMs) / 1000.0).clamp(0.001, 0.2));
    }

    // Accel magnitude (includes gravity)
    double accelPeak = 0;
    for (final s in xs) {
      final mag = math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
      if (mag > accelPeak) accelPeak = mag;
    }

    // Simple “speed proxy”:
    // - Use horizontal (x,y) accel RMS, integrate into proxy and add a small leak
    // - Slight boost from turning rhythm
    final n = xs.length;
    final lateral = List<double>.generate(
        n, (i) => math.sqrt(xs[i].ax * xs[i].ax + xs[i].ay * xs[i].ay)); // g
    final rms = _movingRms(lateral, win: 10); // smoothing
    final sp = List<double>.filled(n, 0.0);
    double v = 0;
    for (int i = 1; i < n; i++) {
      final dti = dt[i - 1];
      // Empirical scale: convert g*s to m/s roughly
      const kAccToSpeed = 2.6; // tunable
      // Leak to suppress drift
      const leak = 0.02;
      v = (v + kAccToSpeed * rms[i] * dti) * (1 - leak);
      sp[i] = v.clamp(0, 50); // cap to avoid runaway
    }

    // Turn detection: gz zero-crossing + amplitude threshold
    final turns = <int>[]; // indices
    final peaks = <double>[];
    for (int i = 1; i < n; i++) {
      final prev = xs[i - 1].gz;
      final cur = xs[i].gz;
      if ((prev <= 0 && cur > 0) || (prev >= 0 && cur < 0)) {
        // Look for local peak to filter jitter
        final w0 = math.max(0, i - 4), w1 = math.min(n - 1, i + 4);
        double maxAbs = 0, peak = 0;
        for (int k = w0; k <= w1; k++) {
          final a = xs[k].gz.abs();
          if (a > maxAbs) {
            maxAbs = a;
            peak = xs[k].gz;
          }
        }
        if (maxAbs >= 20) { // threshold (deg/s)
          turns.add(i);
          peaks.add(peak);
        }
      }
    }
    final turnCount = turns.length;
    final tTotal = (xs.last.tsMs - xs.first.tsMs) / 1000.0;
    final turnFreq = tTotal > 1 ? (turnCount / tTotal * 60.0) : 0.0; // per min

    // Left vs right
    int l = 0, r = 0;
    for (final p in peaks) {
      if (p > 0) r++;
      if (p < 0) l++;
    }
    final sym = (l + r) > 0 ? (1 - (l - r).abs() / (l + r)) : 1.0;

    // Rhythm stability: coefficient of variation (CV) of turn intervals -> 1/(1+k*CV)
    final intervals = <double>[];
    for (int i = 1; i < turns.length; i++) {
      final t0 = xs[turns[i - 1]].tsMs / 1000.0;
      final t1 = xs[turns[i]].tsMs / 1000.0;
      intervals.add(t1 - t0);
    }
    final cv = _cv(intervals);
    final rhythm = 1.0 / (1.0 + 1.8 * cv); // k=1.8 tunable
    final rhythmClamped = rhythm.clamp(0.0, 1.0);

    // Heading variance: integrate gz (deg/s) -> heading (deg), compute std
    final heading = <double>[0];
    double h = 0;
    for (int i = 1; i < n; i++) {
      h += xs[i].gz * dt[i - 1]; // deg
      heading.add(h);
    }
    final headingStd = _std(heading);

    // Speed stability: inverse of CV of speed series
    final spMean = sp.reduce((a, b) => a + b) / math.max(1, sp.length);
    final spStd = _std(sp);
    final spCv = (spMean > 1e-6) ? spStd / spMean : 0.0;
    final spStab = 1.0 / (1.0 + 1.6 * spCv);

    // Distance / avg / max (using proxy speed)
    final distanceM = _trapz(sp, dt); // m
    final distanceKm = distanceM / 1000.0;
    final avgSpeed = spMean;        // m/s
    final maxSpeed = sp.reduce(math.max); // m/s

    // Elevation gain (very rough): integrate (az-1g) to vz, then to z; sum positive segments
    final vz = <double>[0.0];
    double vzi = 0;
    for (int i = 1; i < n; i++) {
      final dti = dt[i - 1];
      final azNoG = xs[i].az - 1.0; // remove 1g
      vzi = vzi * 0.98 + (azNoG * 9.80665) * dti * 0.2; // leak + scaling
      vz.add(vzi);
    }
    double z = 0, lastZ = 0, gain = 0;
    for (int i = 1; i < n; i++) {
      z += ((vz[i] + vz[i - 1]) * 0.5) * dt[i - 1];
      if (z > lastZ) {
        gain += (z - lastZ);
      }
      lastZ = z;
    }
    final elevationGain = gain.isNaN ? 0 : gain.clamp(0, 5000).round();

    // Calories (very rough): k * distance (no body weight available)
    final calories = (distanceKm * 45.0).round();

    // Airtime: segments where |az| < 0.2 g
    double maxAir = 0;
    int st = -1;
    for (int i = 0; i < n; i++) {
      final lowG = xs[i].az.abs() < 0.2;
      if (lowG && st < 0) st = i;
      if (!lowG && st >= 0) {
        final T = (xs[i].tsMs - xs[st].tsMs) / 1000.0;
        if (T > maxAir) maxAir = T;
        st = -1;
      }
    }
    if (st >= 0) {
      final T = (xs.last.tsMs - xs[st].tsMs) / 1000.0;
      if (T > maxAir) maxAir = T;
    }
    final g = 9.80665;
    final maxH = g * maxAir * maxAir / 8.0; // m

    // m/s -> km/h for UI
    double mpsToKmh(double v) => v * 3.6;

    return _Metrics(
      speedSeries: sp.map(mpsToKmh).toList(),
      distanceKm: distanceKm,
      avgSpeed: mpsToKmh(avgSpeed),
      maxSpeed: mpsToKmh(maxSpeed),
      elevationGain: elevationGain,
      caloriesKcal: calories,
      accelPeakG: accelPeak,
      headingVarDeg: headingStd,
      turnLeft: l,
      turnRight: r,
      symmetry: sym,
      rhythmStability: rhythmClamped,
      turnFrequency: turnFreq,
      speedStability: spStab.clamp(0.0, 1.0),
      maxAirtimeS: maxAir,
      maxJumpHeightM: maxH,
    );
  }

  static _Metrics _empty() => _Metrics(
    speedSeries: const [],
    distanceKm: 0,
    avgSpeed: 0,
    maxSpeed: 0,
    elevationGain: 0,
    caloriesKcal: 0,
    accelPeakG: 0,
    headingVarDeg: 0,
    turnLeft: 0,
    turnRight: 0,
    symmetry: 1,
    rhythmStability: 0,
    turnFrequency: 0,
    speedStability: 0,
    maxAirtimeS: 0,
    maxJumpHeightM: 0,
  );

  static List<double> _movingRms(List<double> x, {int win = 10}) {
    final n = x.length;
    final out = List<double>.filled(n, 0);
    double acc = 0;
    final q = <double>[];
    for (int i = 0; i < n; i++) {
      final v2 = x[i] * x[i];
      acc += v2;
      q.add(v2);
      if (q.length > win) acc -= q.removeAt(0);
      final m = acc / q.length;
      out[i] = math.sqrt(math.max(0, m));
    }
    return out;
  }

  static double _std(List<double> x) {
    if (x.isEmpty) return 0;
    final m = x.reduce((a, b) => a + b) / x.length;
    double s = 0;
    for (final v in x) s += (v - m) * (v - m);
    return math.sqrt(s / x.length);
  }

  static double _cv(List<double> x) {
    if (x.length < 2) return 0;
    final m = x.reduce((a, b) => a + b) / x.length;
    if (m.abs() < 1e-6) return 0;
    final st = _std(x);
    return st / m;
  }

  static double _trapz(List<double> v, List<double> dt) {
    double s = 0;
    for (int i = 1; i < v.length; i++) {
      s += (v[i] + v[i - 1]) * 0.5 * dt[i - 1];
    }
    return s;
  }
}

// ------------------- UI Components (unchanged layout) ------------------- //
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

class _StatsSection extends StatefulWidget {
  const _StatsSection({required this.data});
  final _RangeData data;
  @override
  State<_StatsSection> createState() => _StatsSectionState();
}

class _StatsSectionState extends State<_StatsSection> {
  bool _expanded = false;
  double _goalKm = 20.0; // distance goal

  Future<void> _editGoalDialog() async {
    final ctrl = TextEditingController(text: _goalKm.toStringAsFixed(1));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Distance Goal'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: 'e.g., 20.0', suffixText: 'km'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(ctrl.text.trim());
      if (v != null && v > 0) {
        setState(() => _goalKm = v);
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
        GestureDetector(
          onTap: _editGoalDialog,
          child: _StatsRingHeader(
            value: d.distanceKm,
            unit: 'km',
            label: 'Distance (Goal ${_goalKm.toStringAsFixed(1)})',
            progress: progress.toDouble(),
            color: _Brand.mint,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _MetricLite(
                icon: Icons.speed_rounded,
                iconColor: _Brand.blue,
                valueText: d.avgSpeed.toStringAsFixed(1),
                unit: 'km/h',
                title: 'Avg Speed',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricLite(
                icon: Icons.terrain_rounded,
                iconColor: _Brand.orange,
                valueText: d.elevationGain.toString(),
                unit: 'm',
                title: 'Elevation Gain',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MetricLite(
                icon: Icons.speed_outlined,
                iconColor: _Brand.red,
                valueText: d.accelPeakG.toStringAsFixed(2),
                unit: 'G',
                title: 'Peak Accel',
              ),
            ),
          ],
        ),
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
                      title: 'Heading Variance',
                    ),
                  ),
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.flash_on_rounded,
                      iconColor: _Brand.mint,
                      valueText: d.maxSpeed.toStringAsFixed(1),
                      unit: 'km/h',
                      title: 'Top Speed',
                    ),
                  ),
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.flight_takeoff_rounded,
                      iconColor: _Brand.blue,
                      valueText: (widget.data.firstJumpDone
                          ? '≥${(0.6).toStringAsFixed(1)}'
                          : (0.2).toStringAsFixed(1)),
                      unit: 's',
                      title: 'Airtime',
                    ),
                  ),
                  SizedBox(
                    width: colW,
                    child: _MetricLite(
                      icon: Icons.height_rounded,
                      iconColor: _Brand.orange,
                      valueText: (widget.data.firstJumpDone
                          ? (0.9).toStringAsFixed(1)
                          : (0.3).toStringAsFixed(1)),
                      unit: 'm',
                      title: 'Jump Height',
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

class _StatsRingHeader extends StatelessWidget {
  const _StatsRingHeader({
    required this.value,
    required this.unit,
    required this.label,
    required this.progress,
    required this.color,
  });

  final double value;     // distance
  final String unit;      // 'km'
  final String label;     // 'Distance'
  final double progress;  // 0..1
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final ring = (w * 0.62).clamp(150.0, 220.0);
      final stroke = (ring * 0.12).clamp(10.0, 16.0);
      final numberText =
      value >= 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(2);

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
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: Text(
                      numberText,
                      key: ValueKey(numberText),
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
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

    final trackPaint = Paint
      ()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final progPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi,
      false,
      trackPaint,
    );

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
                const Text('Turn Frequency', style: TextStyle(color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 26,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${value.toStringAsFixed(2)} / min',
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
                const Text('Left Foot', style: TextStyle(color: Colors.black54, fontSize: 12)),
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
                const Text('Right Foot', style: TextStyle(color: Colors.black54, fontSize: 12)),
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
