import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/stats.dart';
import 'theme.dart';

/// Compact end-of-book completion card embedded directly after the final
/// paragraph of the last chapter in scroll mode (or triggered at the end of
/// paged mode).
class BookFinishReportCard extends StatefulWidget {
  final int bookId;
  final ReadingTheme theme;
  final VoidCallback? onOpenFull;
  final VoidCallback? onBackToShelf;

  const BookFinishReportCard({
    super.key,
    required this.bookId,
    required this.theme,
    this.onOpenFull,
    this.onBackToShelf,
  });

  @override
  State<BookFinishReportCard> createState() => _BookFinishReportCardState();
}

class _BookFinishReportCardState extends State<BookFinishReportCard> {
  BookFinishReport? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BookFinishReportCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final tz = DateTime.now().timeZoneOffset.inSeconds;
      final r = await bookFinishReport(bookId: widget.bookId, tzSecs: tz);
      if (mounted) {
        setState(() {
          _report = r;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(child: Bloom(color: t.muted, size: 28)),
      );
    }
    final r = _report;
    if (r == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 36, 0, 56),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.outline),
        ),
        child: _ReportBody(
          report: r,
          theme: t,
          compact: true,
          onOpenFull: widget.onOpenFull,
          onBackToShelf: widget.onBackToShelf,
        ),
      ),
    );
  }
}

/// Full-screen completion reading report shown when turning past the very last
/// page of a book in paged mode or tapping the finish-report action.
class BookFinishReportPage extends StatefulWidget {
  final int bookId;
  final ReadingSettings settings;

  const BookFinishReportPage({
    super.key,
    required this.bookId,
    required this.settings,
  });

  @override
  State<BookFinishReportPage> createState() => _BookFinishReportPageState();
}

class _BookFinishReportPageState extends State<BookFinishReportPage> {
  BookFinishReport? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tz = DateTime.now().timeZoneOffset.inSeconds;
      final r = await bookFinishReport(bookId: widget.bookId, tzSecs: tz);
      if (mounted) setState(() => _report = r);
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
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('完本阅读报告', style: TextStyle(color: t.text, fontSize: 16)),
      ),
      body: _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: t.muted)),
            )
          : _report == null
          ? Center(child: Bloom(color: t.muted, size: 32))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: t.outline),
                      ),
                      child: _ReportBody(
                        report: _report!,
                        theme: t,
                        compact: false,
                        onBackToShelf: () {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  final BookFinishReport report;
  final ReadingTheme theme;
  final bool compact;
  final VoidCallback? onOpenFull;
  final VoidCallback? onBackToShelf;

  const _ReportBody({
    required this.report,
    required this.theme,
    required this.compact,
    this.onOpenFull,
    this.onBackToShelf,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final r = report;
    final totalSecs = r.totalSecs.toInt();
    final spanDays = r.spanDays.toInt();
    final activeDays = r.activeDays.toInt();
    final charsWan = _fmtWan(r.totalChars.toInt());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.auto_stories_outlined, size: 18, color: t.muted),
            const SizedBox(width: 8),
            Text(
              '终章 · 完本阅读报告',
              style: TextStyle(
                color: t.muted,
                fontSize: 12,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '《${r.title}》',
          translate: false,
          style: TextStyle(
            color: t.text,
            fontSize: 21,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (r.author != null && r.author!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '${r.author}  ·  ${r.chapterCount} 章  ·  约 $charsWan 万字',
            translate: false,
            style: TextStyle(color: t.muted, fontSize: 12.5),
          ),
        ] else ...[
          const SizedBox(height: 4),
          Text(
            '${r.chapterCount} 章  ·  约 $charsWan 万字',
            style: TextStyle(color: t.muted, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          r.closingLine,
          style: TextStyle(
            color: t.text.withValues(alpha: 0.9),
            fontSize: 14.5,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 20),
        Divider(color: t.muted.withValues(alpha: 0.16), height: 1),
        const SizedBox(height: 18),
        Row(
          children: [
            _metric(t, totalSecs > 0 ? _fmtDur(totalSecs) : '—', '累计阅读'),
            _metric(t, spanDays > 0 ? '$spanDays 天' : '—', '陪伴跨度'),
            _metric(
              t,
              r.bookCpm != null ? '${_roundCpm(r.bookCpm!)} 字/分' : '—',
              '本书均速',
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (r.firstReadAt != null && r.lastReadAt != null)
          _detailRow(
            t,
            '阅读起止',
            '${_fmtDate(r.firstReadAt!.toInt())} — ${_fmtDate(r.lastReadAt!.toInt())}',
            note: activeDays > 0 ? '共读 $activeDays 天' : null,
          ),
        if (r.longestSitting.toInt() > 0)
          _detailRow(t, '最长单次连读', _fmtDur(r.longestSitting.toInt())),
        if (r.bookCpm != null && r.libraryCpm != null)
          _detailRow(t, '与平时对比', _speedCompare(r.bookCpm!, r.libraryCpm!)),
        if (r.latestHour != null)
          _detailRow(t, '最晚读到', _fmtHour(r.latestHour!.toInt())),
        if (r.topChapterTitle != null && r.topChapterSecs.toInt() >= 60)
          _detailRow(
            t,
            '停留最久一章',
            r.topChapterTitle!,
            note: _fmtDur(r.topChapterSecs.toInt()),
            translateValue: false,
          ),
        if (r.annotations.toInt() > 0 ||
            r.bookmarks.toInt() > 0 ||
            r.textCuts.toInt() > 0)
          _detailRow(
            t,
            '书内印记',
            [
              if (r.bookmarks.toInt() > 0) '${r.bookmarks} 个书签',
              if (r.annotations.toInt() > 0) '${r.annotations} 条标注',
              if (r.textCuts.toInt() > 0) '清理 ${r.textCuts} 处广告',
            ].join(' · '),
          ),
        if (r.topCharacters.isNotEmpty)
          _detailRow(
            t,
            '核心人物',
            r.topCharacters.join('、'),
            translateValue: false,
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            if (compact && onOpenFull != null) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: onOpenFull,
                  child: const Text('全屏查看'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (onBackToShelf != null)
              Expanded(
                child: FilledButton.tonal(
                  onPressed: onBackToShelf,
                  child: const Text('返回书架'),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _metric(ReadingTheme t, String value, String label) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: t.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: t.muted, fontSize: 11.5)),
      ],
    ),
  );

  Widget _detailRow(
    ReadingTheme t,
    String label,
    String value, {
    String? note,
    bool translateValue = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Text(label, style: TextStyle(color: t.muted, fontSize: 13)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            translate: translateValue,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.text, fontSize: 13),
          ),
        ),
        if (note != null) ...[
          const SizedBox(width: 8),
          Text(note, style: TextStyle(color: t.muted, fontSize: 11.5)),
        ],
      ],
    ),
  );
}

String _roundCpm(double cpm) => '${(cpm / 10).round() * 10}';

String _fmtWan(int chars) {
  final w = chars / 10000;
  return w >= 100 ? '${w.round()}' : w.toStringAsFixed(1);
}

String _fmtDur(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final m = seconds ~/ 60;
  if (m < 60) return '$m 分钟';
  final h = m / 60;
  if (h >= 10) return '${h.round()} 小时';
  final tenths = (h * 10).round();
  return tenths % 10 == 0 ? '${tenths ~/ 10} 小时' : '${h.toStringAsFixed(1)} 小时';
}

String _fmtDate(int unixSecs) {
  final d = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
  return '${d.year}/${d.month}/${d.day}';
}

String _fmtHour(int h) =>
    h <= 4 ? '凌晨 $h 点' : (h >= 22 ? '深夜 $h 点' : '$h:00');

String _speedCompare(double bookCpm, double libCpm) {
  if (libCpm <= 0) return '—';
  final diffPct = ((bookCpm - libCpm) / libCpm * 100).round();
  if (diffPct.abs() < 5) return '与平时持平';
  return diffPct > 0 ? '比平时快 $diffPct%' : '比平时慢 ${diffPct.abs()}%';
}
