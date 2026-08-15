import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 氛围图 — the book's pacing, big enough to actually read.
///
/// This used to be a 44-pixel strip at the top of the table of contents, which
/// for a 1300-chapter book meant a thousand dots in a few hundred pixels: a
/// smudge. Rhythm is the whole point of the thing, and rhythm needs room. So it
/// gets a page, a labelled axis, and as much width as the book needs — scroll it
/// sideways, and the ups and downs are chapters you can name.
///
/// It stops at the chapter being read, like everything else in this app. The
/// shape of a story's own tension curve is a spoiler: a spike at chapter 700
/// tells you something happens there, and you did not ask.
class MoodPage extends StatefulWidget {
  final ShelfItem book;
  final ReadingSettings settings;

  const MoodPage({super.key, required this.book, required this.settings});

  @override
  State<MoodPage> createState() => _MoodPageState();
}

/// How hard each mood drives the plot, 0..1. An interpretation, not data — one
/// table, so retuning the whole chart is one edit.
const _arousal = {
  '热血': 0.95,
  '紧张': 0.85,
  '悬疑': 0.70,
  '压抑': 0.55,
  '悲伤': 0.45,
  '轻松': 0.30,
  '温馨': 0.20,
  '平静': 0.10,
};
const _pleasant = {'热血', '轻松', '温馨', '平静'};

class _MoodPageState extends State<MoodPage> {
  BookInfo? _info;
  String? _error;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await openBook(path: widget.book.path);
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '节奏与氛围 · ${widget.book.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB3574D),
                    fontSize: 13,
                  ),
                ),
              ),
            )
          : _info == null
          ? Center(child: Bloom(color: t.muted, size: 34))
          : _body(t, _info!),
    );
  }

  Widget _body(ReadingTheme t, BookInfo info) {
    final readUpTo = info.chapters.length;
    final pts = <(int, double, bool)>[
      for (var i = 0; i < readUpTo; i++)
        if (_arousal.containsKey(info.chapters[i].mood))
          (
            i,
            _arousal[info.chapters[i].mood]!,
            _pleasant.contains(info.chapters[i].mood),
          ),
    ];

    if (pts.length < 3) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            readUpTo == 0 ? '这本书还没有章节' : '还没有氛围标签',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.muted, fontSize: 13, height: 1.9),
          ),
        ),
      );
    }

    final warm = t.isDark ? const Color(0xFFE8A54B) : const Color(0xFFB26A00);
    final cool = t.isDark ? const Color(0xFF6FA8E0) : const Color(0xFF2F6DB3);
    final sel = _selected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '全书 ${info.chapters.length} 章，其中 ${pts.length} 章有氛围标签',
                  style: TextStyle(color: t.muted, fontSize: 12),
                ),
              ),
              _legendDot(warm, '愉快', t),
              const SizedBox(width: 12),
              _legendDot(cool, '紧张', t),
            ],
          ),
        ),
        // The chapter under the last tap: the reason the chart is worth having a
        // page of its own is that a dot can now say which chapter it is.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: sel == null
              ? const SizedBox(height: 17)
              : Text(
                  '第 ${sel + 1} 章 · ${info.chapters[sel].mood ?? '—'} · ${info.chapters[sel].title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 13),
                ),
        ),
        Expanded(child: _chart(t, pts, warm, cool)),
        _distribution(t, info, readUpTo, warm, cool),
      ],
    );
  }

  Widget _legendDot(Color c, String label, ReadingTheme t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: t.muted, fontSize: 11)),
    ],
  );

  /// A fixed axis on the left, and as much chart as the book needs on the right.
  /// Roughly 6 px per chapter, so a 1300-chapter book is a few screens wide and
  /// each chapter keeps a pixel to stand on — instead of a thousand dots fighting
  /// for three hundred.
  Widget _chart(
    ReadingTheme t,
    List<(int, double, bool)> pts,
    Color warm,
    Color cool,
  ) {
    final first = pts.first.$1;
    final last = pts.last.$1;
    final span = (last - first) < 1 ? 1 : last - first;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 44,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                for (final e in _arousal.entries)
                  Positioned(
                    right: 6,
                    // Same mapping as the painter: pad 10 at each end.
                    top: 10 + (1 - e.value) * (box.maxHeight - 20) - 6,
                    child: Text(
                      e.key,
                      style: TextStyle(color: t.muted, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final width = (span * 6.0).clamp(box.maxWidth, 20000.0);
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: 20),
                child: GestureDetector(
                  onTapUp: (d) {
                    final i =
                        first + (d.localPosition.dx / width * span).round();
                    setState(() => _selected = i.clamp(first, last));
                  },
                  child: CustomPaint(
                    size: Size(width, box.maxHeight),
                    painter: _MoodPainter(
                      pts: pts,
                      first: first,
                      span: span,
                      selected: _selected,
                      grid: t.muted.withValues(alpha: 0.12),
                      line: t.muted.withValues(alpha: 0.55),
                      mark: t.text,
                      warm: warm,
                      cool: cool,
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

  /// What this book is actually made of, counted. The curve shows the rhythm;
  /// this shows the mix, which is the thing a reader deciding on a book wants.
  Widget _distribution(
    ReadingTheme t,
    BookInfo info,
    int readUpTo,
    Color warm,
    Color cool,
  ) {
    final counts = <String, int>{};
    for (var i = 0; i < readUpTo; i++) {
      final m = info.chapters[i].mood;
      if (m != null && _arousal.containsKey(m)) {
        counts[m] = (counts[m] ?? 0) + 1;
      }
    }
    final total = counts.values.fold(0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();
    final order = _arousal.keys.where(counts.containsKey).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('氛围分布', style: TextStyle(color: t.muted, fontSize: 11)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Row(
              children: [
                for (final m in order)
                  Expanded(
                    flex: counts[m]!,
                    child: Container(
                      height: 6,
                      color: (_pleasant.contains(m) ? warm : cool).withValues(
                        alpha: 0.35 + 0.65 * _arousal[m]!,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final m in order)
                Text(
                  '$m ${(counts[m]! * 100 / total).round()}%',
                  style: TextStyle(color: t.muted, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MoodPainter extends CustomPainter {
  final List<(int, double, bool)> pts;
  final int first;
  final int span;
  final int? selected;
  final Color grid;
  final Color line;
  final Color mark;
  final Color warm;
  final Color cool;

  const _MoodPainter({
    required this.pts,
    required this.first,
    required this.span,
    required this.selected,
    required this.grid,
    required this.line,
    required this.mark,
    required this.warm,
    required this.cool,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 10.0;
    double xOf(int i) => (i - first) / span * size.width;
    double yOf(double a) => pad + (1 - a) * (size.height - 2 * pad);

    // One rule per mood, so a peak can be read off against a name instead of
    // being merely taller than its neighbour.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final a in _arousal.values) {
      canvas.drawLine(Offset(0, yOf(a)), Offset(size.width, yOf(a)), gridPaint);
    }

    final path = Path()..moveTo(xOf(pts.first.$1), yOf(pts.first.$2));
    for (final (i, a, _) in pts.skip(1)) {
      path.lineTo(xOf(i), yOf(a));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Dots only when they have room; past that the line carries the shape and
    // a thousand overlapping circles would just thicken it into a bar.
    final gap = size.width / span;
    if (gap >= 3) {
      for (final (i, a, pleasant) in pts) {
        canvas.drawCircle(
          Offset(xOf(i), yOf(a)),
          gap >= 8 ? 3 : 2,
          Paint()..color = pleasant ? warm : cool,
        );
      }
    }

    if (selected != null) {
      final x = xOf(selected!);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = mark.withValues(alpha: 0.45)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_MoodPainter old) =>
      old.pts != pts || old.selected != selected || old.line != line;
}
