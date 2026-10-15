import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 节奏图 — how intense each chapter is, read off the book's own words.
///
/// This replaced 氛围图 (mood_page.dart, kept but no longer reachable). The
/// model's eight mood labels measured no better than a constant; counting
/// danger, fighting and exclamation words over each whole chapter told intense
/// chapters from calm ones reliably (`novel_core::pace` has the numbers). No
/// model is involved, so every book has a curve the moment it is imported.
///
/// The whole book is drawn, ahead of the reader too. In the scan report that is
/// the point — it is read before deciding on a book — and the reader's strip
/// was asked for as the whole curve with a dot for where the reader is.

final _paceCache = <String, Future<List<double?>>>{};

/// One book's scores, fetched once per session: counting is quick, but the
/// reader's strip rebuilds on every page turn. A cached result whose length no
/// longer matches the chapter list (the book was re-decoded) is fetched again.
Future<List<double?>> loadPace(String path, int chapters) async {
  final cached = _paceCache[path];
  if (cached != null) {
    try {
      final v = await cached;
      if (v.length == chapters) return v;
    } catch (_) {}
  }
  final fresh = chapterPace(path: path);
  _paceCache[path] = fresh;
  try {
    return await fresh;
  } catch (_) {
    _paceCache.remove(path);
    rethrow;
  }
}

/// Stands in for the Rust side in widget tests, which have no native library.
@visibleForTesting
void seedPaceForTest(String path, List<double?> scores) =>
    _paceCache[path] = Future.value(scores);

/// Per-chapter scores (0 is the book's average, higher is more intense, null
/// for a chapter too short to say) and the few ways the UI reads them.
class PaceCurve {
  final List<double?> raw;

  PaceCurve(this.raw);

  int get length => raw.length;
  int get measured => raw.where((v) => v != null).length;

  /// Centred moving average over ±[half] chapters, skipping chapters with no
  /// score. A chapter keeps a value as long as any neighbour has one.
  List<double?> smooth(int half) {
    final n = raw.length;
    final sum = List<double>.filled(n + 1, 0);
    final count = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      sum[i + 1] = sum[i] + (raw[i] ?? 0);
      count[i + 1] = count[i] + (raw[i] == null ? 0 : 1);
    }
    final out = List<double?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      final a = math.max(0, i - half);
      final b = math.min(n, i + half + 1);
      final c = count[b] - count[a];
      if (c > 0) out[i] = (sum[b] - sum[a]) / c;
    }
    return out;
  }

  /// A window that reads at a glance: about a fortieth of the book, so a long
  /// serial shows its arcs instead of every chapter's jitter.
  static int trendHalf(int chapters) => (chapters / 80).round().clamp(1, 20);

  /// The values at two percentiles, used as the bottom and top of a chart so
  /// that one freak chapter does not flatten everything else.
  static (double, double) bounds(
    List<double?> xs, {
    double lo = 0.03,
    double hi = 0.97,
  }) {
    final v = xs.whereType<double>().toList()..sort();
    if (v.isEmpty) return (0, 1);
    return (v[((v.length - 1) * lo).round()], v[((v.length - 1) * hi).round()]);
  }

  /// [xs] mapped onto 0..1 between [b].
  static List<double?> scale(List<double?> xs, (double, double) b) {
    final span = b.$2 - b.$1;
    return [
      for (final x in xs)
        x == null
            ? null
            : span <= 0
            ? 0.5
            : ((x - b.$1) / span).clamp(0.0, 1.0),
    ];
  }

  /// The most intense stretches: peaks of the trend, kept apart so that one
  /// long battle is one entry, each named by its single most intense chapter.
  /// In reading order.
  List<int> peaks() {
    final n = raw.length;
    final half = trendHalf(n);
    final trend = smooth(half);
    final sorted = trend.whereType<double>().toList()..sort();
    if (sorted.length < 10) return const [];
    final floor = sorted[(sorted.length * 0.75).floor()];
    final want = (n / 80).round().clamp(3, 8);
    final gap = math.max(half * 3, n ~/ 25);
    // Tops only: a point on the shoulder of a stretch already picked is not a
    // second stretch, however far it sits from the first pick.
    bool top(int i) {
      for (var j = math.max(0, i - half); j <= math.min(n - 1, i + half); j++) {
        if (trend[j] != null && trend[j]! > trend[i]!) return false;
      }
      return true;
    }

    final order = [
      for (var i = 0; i < n; i++)
        if (trend[i] != null && trend[i]! > floor && top(i)) i,
    ]..sort((a, b) => trend[b]!.compareTo(trend[a]!));
    final picked = <int>[];
    for (final i in order) {
      if (picked.length == want) break;
      if (picked.every((p) => (p - i).abs() > gap)) picked.add(i);
    }
    final out = <int>{};
    for (final p in picked) {
      var best = -1;
      for (var j = math.max(0, p - half); j <= math.min(n - 1, p + half); j++) {
        if (raw[j] != null && (best < 0 || raw[j]! > raw[best]!)) best = j;
      }
      if (best >= 0) out.add(best);
    }
    return out.toList()..sort();
  }

  /// Where one chapter stands in its own book, in words. A rank, because the
  /// score itself has no unit a reader could use.
  String describe(int i) {
    final x = raw[i];
    if (x == null) return '篇幅太短，未计算';
    final v = raw.whereType<double>();
    final p = v.where((y) => y < x).length / v.length;
    if (p >= 0.9) return '全书最激烈的一成';
    if (p >= 0.7) return '较激烈';
    if (p >= 0.3) return '中等';
    return '平缓';
  }
}

Color paceColor(ReadingTheme t) =>
    t.isDark ? const Color(0xFFE8A54B) : const Color(0xFFB26A00);

class PacePage extends StatefulWidget {
  final BookInfo info;
  final ReadingSettings settings;

  /// The reader's chapter, marked on the curve; null for a book not started.
  final int? current;

  /// Opens a chapter in the reader. Without it the page only shows.
  final void Function(int chapter)? onOpenChapter;

  const PacePage({
    super.key,
    required this.info,
    required this.settings,
    this.current,
    this.onOpenChapter,
  });

  @override
  State<PacePage> createState() => _PacePageState();
}

class _PacePageState extends State<PacePage> {
  /// Roughly five pixels a chapter: a 1500-chapter book is a few screens wide
  /// and each chapter still has a bar of its own.
  static const _perChapter = 5.0;
  static const _pad = 8.0;

  PaceCurve? _curve;
  List<double?> _bars = const [];
  List<double?> _line = const [];
  List<int> _peaks = const [];
  String? _error;
  int? _selected;
  ScrollController? _scroll;
  double _width = 0;
  double _viewport = 0;

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
    _load();
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final v = await loadPace(widget.info.path, widget.info.chapters.length);
      final c = PaceCurve(v);
      // Bars are single chapters; the line is a five-chapter average drawn on
      // the same scale, so a bar above the line really is above its stretch.
      final b = PaceCurve.bounds(v);
      if (!mounted) return;
      setState(() {
        _curve = c;
        _bars = PaceCurve.scale(v, b);
        _line = PaceCurve.scale(c.smooth(2), b);
        _peaks = c.peaks();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  double _xOf(int i) {
    final n = widget.info.chapters.length;
    return n <= 1 ? _width / 2 : _pad + i / (n - 1) * (_width - 2 * _pad);
  }

  void _select(int i, {bool scroll = false}) {
    setState(() => _selected = i);
    final s = _scroll;
    if (!scroll || s == null || !s.hasClients) return;
    s.animateTo(
      (_xOf(i) - _viewport / 2).clamp(0.0, s.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '节奏 · ${widget.info.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: _error != null
          ? _message(t, _error!, error: true)
          : _curve == null
          ? Center(child: Bloom(color: t.muted, size: 34))
          : widget.info.chapters.isEmpty
          ? _message(t, '这本书还没有章节')
          : _curve!.measured < 5
          ? _message(t, '章节太少或太短，画不出节奏')
          : _body(t, _curve!),
    );
  }

  Widget _message(ReadingTheme t, String text, {bool error = false}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: error ? const Color(0xFFB3574D) : t.muted,
          fontSize: 13,
          height: 1.9,
        ),
      ),
    ),
  );

  Widget _body(ReadingTheme t, PaceCurve curve) {
    final accent = paceColor(t);
    final chapters = widget.info.chapters;
    final sel = _selected;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        SizedBox(
          height: 46,
          child: Row(
            children: [
              Expanded(
                child: sel == null
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '第 ${sel + 1} 章 · ${curve.describe(sel)}',
                            style: TextStyle(color: t.muted, fontSize: 11.5),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            chapters[sel].title,
                            translate: false,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.text, fontSize: 14),
                          ),
                        ],
                      ),
              ),
              if (sel != null && widget.onOpenChapter != null)
                TextButton(
                  onPressed: () => widget.onOpenChapter!(sel),
                  child: const Text('从这章读'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(height: 220, child: _chart(t, accent)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            _legend(
              t,
              Icon(Icons.arrow_drop_down, size: 18, color: accent),
              '激烈高峰',
            ),
            if (widget.current != null)
              _legend(
                t,
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: t.text,
                    shape: BoxShape.circle,
                  ),
                ),
                '读到这里',
              ),
          ],
        ),
        if (_peaks.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('最激烈的几段', style: TextStyle(color: t.muted, fontSize: 11)),
          const SizedBox(height: 6),
          for (final p in _peaks)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _select(p, scroll: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        '第 ${p + 1} 章',
                        style: TextStyle(
                          color: p == sel ? accent : t.muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        chapters[p].title,
                        translate: false,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.text, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 16),
        // The strip under the reader is this chart in small; hiding it is
        // also in 阅读外观.
        ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '在阅读底栏显示全书节奏',
              style: TextStyle(color: t.muted, fontSize: 13),
            ),
            value: widget.settings.paceStrip,
            onChanged: widget.settings.setPaceStrip,
          ),
        ),
      ],
    );
  }

  Widget _legend(ReadingTheme t, Widget mark, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      mark,
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: t.muted, fontSize: 11)),
    ],
  );

  /// A fixed axis on the left and as much chart as the book needs on the right,
  /// opened on the reader's chapter.
  Widget _chart(ReadingTheme t, Color accent) {
    final n = widget.info.chapters.length;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 34,
          child: Stack(
            children: [
              Positioned(
                top: 12,
                left: 0,
                child: Text(
                  '激烈',
                  style: TextStyle(color: t.muted, fontSize: 10),
                ),
              ),
              Positioned(
                bottom: 2,
                left: 0,
                child: Text(
                  '平缓',
                  style: TextStyle(color: t.muted, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              _viewport = box.maxWidth;
              _width = math.max(
                box.maxWidth,
                math.min(n * _perChapter, 20000.0),
              );
              _scroll ??= ScrollController(
                initialScrollOffset: math.max(
                  0.0,
                  math.min(
                    _xOf(widget.current ?? 0) - box.maxWidth / 2,
                    _width - box.maxWidth,
                  ),
                ),
              );
              return SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: GestureDetector(
                  onTapUp: (d) {
                    final f = (d.localPosition.dx - _pad) / (_width - 2 * _pad);
                    _select((f * (n - 1)).round().clamp(0, n - 1));
                  },
                  child: CustomPaint(
                    size: Size(_width, box.maxHeight),
                    painter: _PaceChartPainter(
                      bars: _bars,
                      line: _line,
                      peaks: _peaks,
                      current: widget.current,
                      selected: _selected,
                      pad: _pad,
                      accent: accent,
                      ink: t.text,
                      ground: t.background,
                      rule: t.muted.withValues(alpha: 0.18),
                      mark: t.muted.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PaceChartPainter extends CustomPainter {
  final List<double?> bars;
  final List<double?> line;
  final List<int> peaks;
  final int? current;
  final int? selected;
  final double pad;
  final Color accent;
  final Color ink;
  final Color ground;
  final Color rule;
  final Color mark;

  const _PaceChartPainter({
    required this.bars,
    required this.line,
    required this.peaks,
    required this.current,
    required this.selected,
    required this.pad,
    required this.accent,
    required this.ink,
    required this.ground,
    required this.rule,
    required this.mark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    if (n == 0) return;
    const top = 16.0;
    const bottom = 4.0;
    final h = size.height - top - bottom;
    double xOf(int i) =>
        n <= 1 ? size.width / 2 : pad + i / (n - 1) * (size.width - 2 * pad);
    double yOf(double v) => top + (1 - v) * h;
    final step = n <= 1 ? size.width : (size.width - 2 * pad) / (n - 1);

    canvas.drawLine(
      Offset(0, size.height - bottom),
      Offset(size.width, size.height - bottom),
      Paint()
        ..color = rule
        ..strokeWidth = 1,
    );

    final peakSet = peaks.toSet();
    final barW = (step * 0.62).clamp(1.0, 6.0);
    for (var i = 0; i < n; i++) {
      final v = bars[i];
      if (v == null) continue;
      canvas.drawRect(
        Rect.fromLTRB(
          xOf(i) - barW / 2,
          yOf(v),
          xOf(i) + barW / 2,
          size.height - bottom,
        ),
        Paint()
          ..color = accent.withValues(alpha: peakSet.contains(i) ? 0.55 : 0.2),
      );
    }

    // The line breaks where there is nothing to average, rather than drawing a
    // confident slope across chapters that were never measured.
    final path = Path();
    var open = false;
    for (var i = 0; i < n; i++) {
      final v = line[i];
      if (v == null) {
        open = false;
        continue;
      }
      if (open) {
        path.lineTo(xOf(i), yOf(v));
      } else {
        path.moveTo(xOf(i), yOf(v));
        open = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    for (final p in peaks) {
      final x = xOf(p);
      canvas.drawPath(
        Path()
          ..moveTo(x - 4.5, 2)
          ..lineTo(x + 4.5, 2)
          ..lineTo(x, 9)
          ..close(),
        Paint()..color = accent,
      );
    }

    if (selected != null && selected! < n) {
      final x = xOf(selected!);
      canvas.drawLine(
        Offset(x, top - 4),
        Offset(x, size.height - bottom),
        Paint()
          ..color = mark
          ..strokeWidth = 1,
      );
    }

    final c = current;
    if (c != null && c >= 0 && c < n) {
      final x = xOf(c);
      final v = line[c] ?? bars[c] ?? 0.0;
      canvas.drawCircle(Offset(x, yOf(v)), 6, Paint()..color = ground);
      canvas.drawCircle(Offset(x, yOf(v)), 4.5, Paint()..color = ink);
    }
  }

  @override
  bool shouldRepaint(_PaceChartPainter old) =>
      old.bars != bars ||
      old.line != line ||
      old.selected != selected ||
      old.current != current ||
      old.accent != accent ||
      old.ink != ink;
}

/// The whole book's pace in one slim line under the reader: the part already
/// read in colour, the rest in grey, a dot where the reader is. Tapping opens
/// the full chart; a long press or a right click hides it. Draws nothing for a
/// book too short to have a shape.
class PaceStrip extends StatefulWidget {
  final BookInfo info;
  final int chapter;
  final ReadingTheme theme;
  final VoidCallback onTap;
  final VoidCallback? onHide;

  const PaceStrip({
    super.key,
    required this.info,
    required this.chapter,
    required this.theme,
    required this.onTap,
    this.onHide,
  });

  @override
  State<PaceStrip> createState() => _PaceStripState();
}

class _PaceStripState extends State<PaceStrip> {
  List<double?>? _line;
  String? _path;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PaceStrip old) {
    super.didUpdateWidget(old);
    if (old.info.path != widget.info.path ||
        old.info.chapters.length != widget.info.chapters.length) {
      _load();
    }
  }

  Future<void> _load() async {
    final path = widget.info.path;
    _path = path;
    try {
      final v = await loadPace(path, widget.info.chapters.length);
      if (!mounted || _path != path) return;
      final c = PaceCurve(v);
      final trend = c.smooth(PaceCurve.trendHalf(v.length));
      setState(
        () => _line = c.measured < 10
            ? null
            // Full range: the trend is already an average, so it has no
            // freak values to guard against, and clipping flattens its peaks.
            : PaceCurve.scale(trend, PaceCurve.bounds(trend, lo: 0, hi: 1)),
      );
    } catch (_) {
      if (mounted && _path == path) setState(() => _line = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    final t = widget.theme;
    return Tooltip(
      message: context.tr('全书节奏'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onHide,
        onSecondaryTap: widget.onHide,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: SizedBox(
            height: 22,
            width: double.infinity,
            child: CustomPaint(
              painter: _PaceStripPainter(
                line: line,
                chapter: widget.chapter,
                read: paceColor(t),
                unread: t.muted,
                ink: t.text,
                ground: t.background,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaceStripPainter extends CustomPainter {
  final List<double?> line;
  final int chapter;
  final Color read;
  final Color unread;
  final Color ink;
  final Color ground;

  const _PaceStripPainter({
    required this.line,
    required this.chapter,
    required this.read,
    required this.unread,
    required this.ink,
    required this.ground,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = line.length;
    if (n < 2) return;
    const pad = 5.0;
    const top = 4.0;
    final base = size.height - 1;
    double xOf(int i) => pad + i / (n - 1) * (size.width - 2 * pad);
    double yOf(double v) => top + (1 - v) * (base - top);

    // Two passes over the same shape, split at the reader's chapter, so the
    // part behind them reads as progress.
    void shape(int from, int to, Color c, double fill, double stroke) {
      final edge = Path();
      final area = Path();
      int? first;
      int? last;
      for (var i = from; i <= to; i++) {
        final v = line[i];
        if (v == null) continue;
        if (first == null) {
          edge.moveTo(xOf(i), yOf(v));
          area.moveTo(xOf(i), base);
          area.lineTo(xOf(i), yOf(v));
          first = i;
        } else {
          edge.lineTo(xOf(i), yOf(v));
          area.lineTo(xOf(i), yOf(v));
        }
        last = i;
      }
      if (first == null) return;
      area
        ..lineTo(xOf(last!), base)
        ..close();
      canvas.drawPath(area, Paint()..color = c.withValues(alpha: fill));
      canvas.drawPath(
        edge,
        Paint()
          ..color = c.withValues(alpha: stroke)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final at = chapter.clamp(0, n - 1);
    shape(at, n - 1, unread, 0.10, 0.45);
    shape(0, at, read, 0.18, 0.85);

    var v = line[at];
    for (var d = 1; v == null && d < n; d++) {
      v =
          (at - d >= 0 ? line[at - d] : null) ??
          (at + d < n ? line[at + d] : null);
    }
    final dot = Offset(xOf(at), yOf(v ?? 0.5));
    canvas.drawCircle(dot, 4.6, Paint()..color = ground);
    canvas.drawCircle(dot, 3.4, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_PaceStripPainter old) =>
      old.line != line ||
      old.chapter != chapter ||
      old.read != read ||
      old.ink != ink;
}
