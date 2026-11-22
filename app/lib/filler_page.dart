import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'pace_page.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 注水度 — per-chapter padding / repetition curve (`novel_core::filler`).
///
/// Same presentation language as 节奏 (pace_page.dart): counted directly from
/// the text without a model, cached per session, with a smooth trend over the
/// whole book and a list of the most padded stretches.

final _fillerCache = <String, Future<List<double?>>>{};

Future<List<double?>> loadFiller(String path, int chapters) async {
  final cached = _fillerCache[path];
  if (cached != null) {
    try {
      final v = await cached;
      if (v.length == chapters) return v;
    } catch (_) {}
  }
  final fresh = chapterFiller(path: path);
  _fillerCache[path] = fresh;
  try {
    return await fresh;
  } catch (_) {
    _fillerCache.remove(path);
    rethrow;
  }
}

@visibleForTesting
void seedFillerForTest(String path, List<double?> scores) =>
    _fillerCache[path] = Future.value(scores);

Color fillerColor(ReadingTheme t) =>
    Color.lerp(const Color(0xFF4A7F9E), t.text, 0.22)!;

class FillerPage extends StatefulWidget {
  final BookInfo info;
  final ReadingSettings settings;
  final int? current;
  final ValueChanged<int> onOpenChapter;

  const FillerPage({
    super.key,
    required this.info,
    required this.settings,
    this.current,
    required this.onOpenChapter,
  });

  @override
  State<FillerPage> createState() => _FillerPageState();
}

class _FillerPageState extends State<FillerPage> {
  List<double?>? _raw;
  String? _error;
  int? _focused;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final scores = await loadFiller(
        widget.info.path,
        widget.info.chapters.length,
      );
      if (!mounted) return;
      setState(() {
        _raw = scores;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _grade(double avg) {
    if (avg < 0.28) return '很扎实';
    if (avg < 0.42) return '偏紧凑';
    if (avg < 0.56) return '中等';
    if (avg < 0.70) return '略注水';
    return '高注水';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final accent = fillerColor(t);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '注水度 · ${widget.info.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: _raw == null ? _opening(t) : _body(t, accent, _raw!),
    );
  }

  Widget _opening(ReadingTheme t) => Center(
    child: _error != null
        ? Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFB3574D), fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Bloom(color: t.muted, size: 34),
              const SizedBox(height: 16),
              Text('正在测算注水度…', style: TextStyle(color: t.muted, fontSize: 13)),
            ],
          ),
  );

  Widget _body(ReadingTheme t, Color accent, List<double?> raw) {
    final curve = PaceCurve(raw);
    if (curve.measured == 0) {
      return Center(
        child: Text(
          '章节过短，暂时无法测算注水度',
          style: TextStyle(color: t.muted, fontSize: 13),
        ),
      );
    }
    final vals = raw.whereType<double>().toList();
    final avg = vals.reduce((a, b) => a + b) / vals.length;
    final half = PaceCurve.trendHalf(raw.length);
    final trend = curve.smooth(half);
    final peaks = curve.peaks();
    final focused = _focused;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        Row(
          children: [
            Text(
              '全书均值 ${(avg * 100).round()}%',
              style: TextStyle(
                color: t.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _grade(avg),
                style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            Text(
              '${curve.measured} / ${raw.length} 章',
              style: TextStyle(color: t.muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '综合句式重复、词汇丰富度、高频套话与跨章推进测算，越高表示水分越重',
          style: TextStyle(color: t.muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 200,
          child: LayoutBuilder(
            builder: (_, box) => GestureDetector(
              onTapDown: (d) => _pick(d.localPosition.dx, box.maxWidth, raw.length),
              onHorizontalDragUpdate: (d) =>
                  _pick(d.localPosition.dx, box.maxWidth, raw.length),
              child: CustomPaint(
                size: Size.infinite,
                painter: _FillerChartPainter(
                  raw: raw,
                  trend: trend,
                  current: widget.current,
                  focused: focused,
                  accent: accent,
                  theme: t,
                ),
              ),
            ),
          ),
        ),
        if (focused != null && focused < widget.info.chapters.length) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: t.muted.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.info.chapters[focused].title,
                        translate: false,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        raw[focused] == null
                            ? '第 ${focused + 1} 章 · 篇幅较短'
                            : '第 ${focused + 1} 章 · 注水度 ${(raw[focused]! * 100).round()}%',
                        style: TextStyle(color: t.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => widget.onOpenChapter(focused),
                  child: const Text('前往'),
                ),
              ],
            ),
          ),
        ],
        if (peaks.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            '疑似高水区间',
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (final idx in peaks)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              dense: true,
              title: Text(
                widget.info.chapters[idx].title,
                translate: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.text, fontSize: 13.5),
              ),
              subtitle: Text(
                '第 ${idx + 1} 章 · 注水度 ${((raw[idx] ?? 0) * 100).round()}%',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
              trailing: Icon(Icons.chevron_right, size: 18, color: t.muted),
              onTap: () => widget.onOpenChapter(idx),
            ),
        ],
      ],
    );
  }

  void _pick(double dx, double width, int n) {
    if (n <= 0 || width <= 0) return;
    final i = ((dx / width) * n).floor().clamp(0, n - 1);
    if (_focused != i) setState(() => _focused = i);
  }
}

class _FillerChartPainter extends CustomPainter {
  final List<double?> raw;
  final List<double?> trend;
  final int? current;
  final int? focused;
  final Color accent;
  final ReadingTheme theme;

  _FillerChartPainter({
    required this.raw,
    required this.trend,
    required this.current,
    required this.focused,
    required this.accent,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = raw.length;
    if (n == 0) return;
    const top = 12.0, bottom = 18.0;
    final h = math.max(size.height - top - bottom, 1.0);
    double xOf(int i) => n == 1 ? size.width / 2 : i / (n - 1) * size.width;
    double yOf(double v) => top + (1 - v.clamp(0.0, 1.0)) * h;

    // Subtle 25 / 50 / 75% reference lines.
    final gridPaint = Paint()
      ..color = theme.muted.withValues(alpha: 0.12)
      ..strokeWidth = 0.8;
    for (final level in const [0.25, 0.5, 0.75]) {
      final y = yOf(level);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Raw per-chapter bars in light tint.
    final barW = math.max(size.width / n * 0.7, 1.0);
    final barPaint = Paint()
      ..color = accent.withValues(alpha: 0.18)
      ..strokeWidth = barW;
    for (var i = 0; i < n; i++) {
      final v = raw[i];
      if (v == null) continue;
      final x = xOf(i);
      canvas.drawLine(Offset(x, top + h), Offset(x, yOf(v)), barPaint);
    }

    // Smooth trend line.
    final path = Path();
    var started = false;
    for (var i = 0; i < n; i++) {
      final v = trend[i];
      if (v == null) continue;
      final pt = Offset(xOf(i), yOf(v));
      if (!started) {
        path.moveTo(pt.dx, pt.dy);
        started = true;
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    if (started) {
      canvas.drawPath(
        path,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Current reading chapter marker.
    if (current != null && current! >= 0 && current! < n) {
      final x = xOf(current!);
      canvas.drawLine(
        Offset(x, top),
        Offset(x, top + h),
        Paint()
          ..color = theme.text.withValues(alpha: 0.45)
          ..strokeWidth = 1.2,
      );
    }

    // Focused chapter crosshair.
    if (focused != null && focused! >= 0 && focused! < n) {
      final x = xOf(focused!);
      canvas.drawLine(
        Offset(x, top),
        Offset(x, top + h),
        Paint()
          ..color = accent.withValues(alpha: 0.85)
          ..strokeWidth = 1.4,
      );
      final v = raw[focused!] ?? trend[focused!];
      if (v != null) {
        canvas.drawCircle(
          Offset(x, yOf(v)),
          4,
          Paint()..color = accent,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FillerChartPainter old) =>
      old.raw != raw ||
      old.focused != focused ||
      old.current != current ||
      old.theme != theme;
}
