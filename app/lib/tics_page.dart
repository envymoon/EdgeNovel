import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 作者口癖 — writing habits, stylistic fingerprint, and recurring phrases
/// (`novel_core::tics`), counted directly from the book without a model.

final _ticsCache = <String, Future<AuthorTics>>{};

Future<AuthorTics> loadAuthorTics(String path) async {
  final cached = _ticsCache[path];
  if (cached != null) {
    try {
      return await cached;
    } catch (_) {}
  }
  final fresh = authorTics(path: path);
  _ticsCache[path] = fresh;
  try {
    return await fresh;
  } catch (_) {
    _ticsCache.remove(path);
    rethrow;
  }
}

@visibleForTesting
void seedAuthorTicsForTest(String path, AuthorTics tics) =>
    _ticsCache[path] = Future.value(tics);

Color _ticsAccent(ReadingTheme t) =>
    Color.lerp(const Color(0xFFB87333), t.text, 0.18)!;

class TicsPage extends StatefulWidget {
  final BookInfo info;
  final ReadingSettings settings;
  final ValueChanged<int>? onOpenChapter;

  const TicsPage({
    super.key,
    required this.info,
    required this.settings,
    this.onOpenChapter,
  });

  @override
  State<TicsPage> createState() => _TicsPageState();
}

class _TicsPageState extends State<TicsPage> {
  AuthorTics? _data;
  String? _error;
  String _selectedCat = '全部';

  static const _categories = [
    '全部',
    '神态动作',
    '说话腔调',
    '心理情绪',
    '转折推进',
    '夸张惊叹',
    '口头禅',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await loadAuthorTics(widget.info.path);
      if (!mounted) return;
      setState(() {
        _data = res;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _chapterTitle(int idx) {
    if (idx >= 0 && idx < widget.info.chapters.length) {
      return widget.info.chapters[idx].title;
    }
    return '第 ${idx + 1} 章';
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final accent = _ticsAccent(t);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '文风 · ${widget.info.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: _data == null ? _opening(t) : _body(t, accent, _data!),
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
              Text('正在扫描文风…', style: TextStyle(color: t.muted, fontSize: 13)),
            ],
          ),
  );

  Widget _body(ReadingTheme t, Color accent, AuthorTics data) {
    final availableCats = <String>{'全部'};
    for (final it in data.items) {
      availableCats.add(it.category);
    }
    final cats = _categories.where(availableCats.contains).toList();
    final filtered = _selectedCat == '全部'
        ? data.items
        : data.items.where((it) => it.category == _selectedCat).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _styleCard(t, accent, data),
        const SizedBox(height: 18),
        if (cats.length > 2) ...[
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cats.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final c = cats[i];
                final selected = c == _selectedCat;
                return ChoiceChip(
                  label: Text(
                    c,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? t.background : t.text,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  selected: selected,
                  showCheckmark: false,
                  backgroundColor: t.muted.withValues(alpha: 0.08),
                  selectedColor: accent,
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _selectedCat = c),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
        ],
        Row(
          children: [
            Text(
              '高频写法',
              style: TextStyle(
                color: t.text,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Text(
              '共 ${filtered.length} 项',
              style: TextStyle(color: t.muted, fontSize: 11.5),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                '当前分类下暂无高频写法',
                style: TextStyle(color: t.muted, fontSize: 13),
              ),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++)
            _ticCard(t, accent, i + 1, filtered[i]),
      ],
    );
  }

  Widget _styleCard(ReadingTheme t, Color accent, AuthorTics data) {
    final charsWan = (data.totalChars / 10000.0).toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.muted.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.muted.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _metric(t, '${(data.dialogueRatio * 100).round()}%', '对话占比'),
              _metric(t, '${data.avgSentenceLen.toStringAsFixed(1)} 字', '平均句长'),
              _metric(t, '$charsWan 万字', '共 ${data.chapterCount} 章'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _metric(t, data.exclamPer10K.toStringAsFixed(0), '叹号 / 万字'),
              _metric(t, data.questionPer10K.toStringAsFixed(0), '问号 / 万字'),
              _metric(t, data.ellipsisPer10K.toStringAsFixed(0), '省略号 / 万字'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(ReadingTheme t, String value, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            color: t.text,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: t.muted, fontSize: 11)),
      ],
    ),
  );

  Widget _ticCard(ReadingTheme t, Color accent, int rank, TicItem item) {
    final peakIdx = item.peakChapter;
    final sampleIdx = item.sampleChapter;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
      decoration: BoxDecoration(
        color: t.muted.withValues(alpha: 0.065),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.muted.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '$rank',
                  style: TextStyle(
                    color: rank <= 3 ? accent : t.muted,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                item.phrase,
                translate: false,
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: t.muted.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item.category,
                  style: TextStyle(color: t.muted, fontSize: 10.5),
                ),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${item.count} 次',
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${item.per10K.toStringAsFixed(1)} / 万字',
                    style: TextStyle(color: t.muted, fontSize: 10.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 18,
                  child: CustomPaint(
                    painter: _SparklinePainter(
                      buckets: item.buckets,
                      accent: accent,
                      muted: t.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '最密: 第${peakIdx + 1}章(${item.peakCount}次)',
                style: TextStyle(color: accent, fontSize: 11),
              ),
            ],
          ),
          if (item.sample.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: t.background.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _highlightedSample(item.sample, item.phrase, t, accent),
                  const SizedBox(height: 3),
                  Text(
                    '— ${_chapterTitle(sampleIdx)}',
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.muted.withValues(alpha: 0.8),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _highlightedSample(
    String sample,
    String phrase,
    ReadingTheme t,
    Color accent,
  ) {
    final idx = sample.indexOf(phrase);
    if (idx < 0) {
      return Text(
        sample,
        translate: false,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
      );
    }
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
        children: [
          TextSpan(text: sample.substring(0, idx)),
          TextSpan(
            text: phrase,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.w700,
              backgroundColor: accent.withValues(alpha: 0.14),
            ),
          ),
          TextSpan(text: sample.substring(idx + phrase.length)),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<int> buckets;
  final Color accent;
  final Color muted;

  _SparklinePainter({
    required this.buckets,
    required this.accent,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (buckets.isEmpty) return;
    var maxVal = 1;
    for (final v in buckets) {
      if (v > maxVal) maxVal = v;
    }
    final n = buckets.length;
    final step = size.width / n;
    final barW = math.max(step * 0.68, 1.5);
    final basePaint = Paint()..color = muted.withValues(alpha: 0.16);
    final barPaint = Paint()..color = accent.withValues(alpha: 0.72);

    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      basePaint..strokeWidth = 0.8,
    );
    for (var i = 0; i < n; i++) {
      final v = buckets[i];
      if (v <= 0) continue;
      final h = math.max((v / maxVal) * (size.height - 2), 2.0);
      final x = i * step + (step - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barW, h),
          const Radius.circular(1.5),
        ),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.buckets != buckets || old.accent != accent;
}
