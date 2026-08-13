import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'ai_page.dart';
import 'ai_runtime_page.dart';
import 'bloom.dart';
import 'cast_graph_page.dart';
import 'cover.dart';
import 'landmine_page.dart';
import 'mood_page.dart';
import 'platform_support.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// The decision layer before the reader.
///
/// This deliberately does not claim that the current 0.6B pipeline can judge a
/// whole novel. It gathers the useful, already-existing outputs in one place,
/// states their coverage, and keeps the evidence-first landmine scan honest.
/// The reading assistant remains a separate surface inside the reader.
class BookDetailPage extends StatefulWidget {
  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;
  final Future<void> Function(int? chapter, int? offset) onRead;

  const BookDetailPage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
    required this.onRead,
  });

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  BookInfo? _info;
  IndexStatus? _index;
  List<BookAnnotation> _annotations = const [];
  Set<int> _completedChapters = const {};
  RelationshipStructureInfo? _relationship;
  bool _relationshipLoading = false;
  bool _openingReader = false;
  String? _relationshipError;
  String? _error;
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    _wasBusy = widget.reader.enriching || widget.reader.indexing;
    widget.reader.addListener(_onReader);
    _load();
  }

  @override
  void dispose() {
    widget.reader.removeListener(_onReader);
    super.dispose();
  }

  void _onReader() {
    final busy = widget.reader.enriching || widget.reader.indexing;
    if (_wasBusy && !busy) _load();
    _wasBusy = busy;
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final completedFuture = listCompletedChapters(bookId: widget.book.id);
      final results = await Future.wait<Object>([
        openBook(path: widget.book.path),
        indexStatus(path: widget.book.path, bookId: widget.book.id),
        listAnnotations(bookId: widget.book.id),
      ]);
      final completed = await completedFuture;
      if (!mounted) return;
      setState(() {
        _info = results[0] as BookInfo;
        _index = results[1] as IndexStatus;
        _annotations = results[2] as List<BookAnnotation>;
        _completedChapters = completed.map((value) => value.toInt()).toSet();
        _error = null;
      });
      _loadRelationship();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadRelationship({bool force = false}) async {
    if (_relationshipLoading || (!force && _relationship != null)) return;
    setState(() {
      _relationshipLoading = true;
      _relationshipError = null;
    });
    try {
      final result = await relationshipStructure(
        path: widget.book.path,
        bookId: widget.book.id,
      );
      if (!mounted) return;
      setState(() {
        _relationship = result;
        _relationshipLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _relationshipError = '$e';
        _relationshipLoading = false;
      });
    }
  }

  Future<void> _startAnalysis() async {
    final status = await aiStatus();
    if (!mounted) return;
    if (!status.engine || status.model == null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: widget.settings.theme.background,
          title: const Text('需要先下载本地 AI 模型'),
          content: const Text('模型按需下载，书籍内容仍在本机处理。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('去下载'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AiPage(settings: widget.settings)),
        );
      }
      return;
    }
    widget.reader.startEnrich(widget.book);
  }

  void _startIndex() {
    widget.reader.startIndex(
      widget.book.id,
      widget.book.path,
      title: widget.book.title,
    );
  }

  void _open(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _read(int? chapter, int? offset) async {
    final info = _info;
    if (info == null || _openingReader) return;
    setState(() => _openingReader = true);
    await widget.onRead(chapter, offset);
    if (!mounted) return;
    setState(() => _openingReader = false);
    if (!widget.reader.isOpen) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.reader.error ?? '无法打开这本书')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final info = _info;
    final compact =
        AppPlatformSupport.layoutForWidth(MediaQuery.sizeOf(context).width) ==
        AppLayoutClass.compact;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          widget.book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: info == null
          ? _opening(t)
          : SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 16 : 24,
                        8,
                        compact ? 16 : 24,
                        40,
                      ),
                      children: [
                        _bookHeader(t, info, compact: compact),
                        const SizedBox(height: 18),
                        _readButton(t),
                        const SizedBox(height: 28),
                        _reportHeader(t),
                        const SizedBox(height: 12),
                        _coverage(t, info),
                        const SizedBox(height: 12),
                        _narrativeFocus(t, info),
                        const SizedBox(height: 12),
                        _relationshipCard(t, info),
                        const SizedBox(height: 12),
                        _reportEntries(t, info),
                        const SizedBox(height: 20),
                        _preparation(t, info),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _opening(ReadingTheme t) => Center(
    child: _error == null
        ? Bloom(color: t.muted, size: 34)
        : Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '书籍详情加载失败\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB3574D),
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
  );

  Widget _bookHeader(ReadingTheme t, BookInfo info, {required bool compact}) {
    final started = widget.book.lastOpenedAt != null;
    final progress = info.chapters.isEmpty
        ? 0.0
        : ((info.lastChapter + 1) / info.chapters.length).clamp(0, 1);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextCover(
          title: widget.book.title,
          hue: widget.book.coverHue,
          coverPath: widget.book.coverPath,
          width: compact ? 72 : 82,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text,
                  fontSize: compact ? 18 : 20,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '${widget.book.author ?? '佚名'} · ${info.chapters.length} 章',
                style: TextStyle(color: t.muted, fontSize: 12.5),
              ),
              if (widget.book.genreTags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.book.genreTags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: t.muted.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          tag,
                          style: TextStyle(color: t.muted, fontSize: 10.5),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 13),
              Text(
                started
                    ? '已读 ${(progress * 100).toStringAsFixed(0)}% · '
                          '${info.chapters[info.lastChapter.clamp(0, info.chapters.length - 1)].title}'
                    : '尚未开始阅读',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _readButton(ReadingTheme t) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: _openingReader ? null : () => _read(null, null),
      icon: _openingReader
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.menu_book_outlined, size: 19),
      label: Text(
        _openingReader
            ? '正在打开'
            : widget.book.lastOpenedAt == null
            ? '开始阅读'
            : '继续阅读',
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    ),
  );

  Widget _reportHeader(ReadingTheme t) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '扫书报告',
              style: TextStyle(
                color: t.text,
                fontSize: 19,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: t.muted.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '基础版',
              style: TextStyle(color: t.muted, fontSize: 10.5),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '可能包含未读内容。',
        style: TextStyle(color: t.muted, fontSize: 12, height: 1.6),
      ),
    ],
  );

  Widget _coverage(ReadingTheme t, BookInfo info) {
    final summaries = info.chapters
        .where((c) => (c.summary ?? '').trim().isNotEmpty)
        .length;
    final moods = info.chapters
        .where((c) => (c.mood ?? '').trim().isNotEmpty)
        .length;
    final indexed = _index?.indexed ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.text.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _coverageItem(t, '章节分析', '$summaries / ${info.chapters.length}'),
          _divider(t),
          _coverageItem(t, '氛围标签', '$moods / ${info.chapters.length}'),
          _divider(t),
          _coverageItem(t, '全文检索', '$indexed / ${info.chapters.length}'),
        ],
      ),
    );
  }

  Widget _coverageItem(ReadingTheme t, String label, String value) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: t.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: t.muted, fontSize: 10.5)),
      ],
    ),
  );

  Widget _divider(ReadingTheme t) =>
      Container(width: 1, height: 30, color: t.muted.withValues(alpha: 0.16));

  Widget _narrativeFocus(ReadingTheme t, BookInfo info) => Container(
    padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
    decoration: BoxDecoration(
      border: Border.all(color: t.muted.withValues(alpha: 0.16)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune, size: 17, color: t.muted),
            const SizedBox(width: 7),
            Text(
              '叙事侧重',
              style: TextStyle(
                color: t.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _focusItem(t, '事业线', info.careerFocus),
            const SizedBox(width: 8),
            _focusItem(t, '感情线', info.romanceFocus),
            const SizedBox(width: 8),
            _focusItem(t, '升级线', info.growthFocus),
          ],
        ),
      ],
    ),
  );

  Widget _focusItem(ReadingTheme t, String label, String level) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: t.text.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            level,
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(color: t.muted, fontSize: 10.5)),
        ],
      ),
    ),
  );

  Widget _relationshipCard(ReadingTheme t, BookInfo info) {
    final report = _relationship;
    if (report == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: t.muted.withValues(alpha: 0.16)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            if (_relationshipLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.favorite_border, size: 19, color: t.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _relationshipLoading
                    ? '正在核对全书人物与感情关系…'
                    : _relationshipError == null
                    ? '感情结构暂时无法生成'
                    : '感情结构生成失败，可稍后重试',
                style: TextStyle(color: t.muted, fontSize: 12.5),
              ),
            ),
            if (!_relationshipLoading)
              TextButton(
                onPressed: () => _loadRelationship(force: true),
                child: const Text('重试'),
              ),
          ],
        ),
      );
    }

    final evidenceCount =
        report.groupEvidence.length +
        report.people.fold<int>(
          0,
          (sum, person) => sum + person.evidence.length,
        );
    final confidence = switch (report.confidence) {
      >= 3 => '高可信',
      2 => '中等可信',
      1 => '有限依据',
      _ => '证据不足',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        border: Border.all(color: t.muted.withValues(alpha: 0.16)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_border, size: 18, color: t.muted),
              const SizedBox(width: 7),
              Text(
                '感情结构',
                style: TextStyle(
                  color: t.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: t.text.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  report.label,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(confidence, style: TextStyle(color: t.muted, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            report.reason,
            style: TextStyle(color: t.text, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 7),
          Text(
            '主角：${report.protagonist} · 全书 ${report.analyzedChapters} 章'
            ' · 核对 ${report.candidateCount} 名人物',
            style: TextStyle(color: t.muted, fontSize: 10.8, height: 1.4),
          ),
          if (evidenceCount > 0) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _open(
                  _RelationshipEvidencePage(
                    info: info,
                    report: report,
                    settings: widget.settings,
                    onOpenChapter: _read,
                  ),
                ),
                icon: const Icon(Icons.article_outlined, size: 17),
                label: Text('查看 $evidenceCount 条原文依据'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _reportEntries(ReadingTheme t, BookInfo info) {
    final summaryCount = info.chapters
        .where((c) => (c.summary ?? '').trim().isNotEmpty)
        .length;
    final moodCount = info.chapters
        .where((c) => (c.mood ?? '').trim().isNotEmpty)
        .length;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.muted.withValues(alpha: 0.16)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          _entry(
            t,
            icon: Icons.notes_outlined,
            title: '章节概览',
            subtitle: summaryCount == 0 ? '暂无' : '$summaryCount 章',
            onTap: () => _open(
              _ChapterSummaryPage(
                info: info,
                settings: widget.settings,
                lastChapter: widget.book.lastOpenedAt == null
                    ? null
                    : info.lastChapter,
                annotations: _annotations,
                completedChapters: _completedChapters,
                onOpenChapter: _read,
              ),
            ),
          ),
          _line(t),
          _entry(
            t,
            icon: Icons.account_tree_outlined,
            title: '人物构成与关系',
            subtitle: '人物、活跃章节与关系',
            onTap: () => _open(
              CastGraphPage(book: widget.book, settings: widget.settings),
            ),
          ),
          _line(t),
          _entry(
            t,
            icon: Icons.report_gmailerrorred_outlined,
            title: '排雷原文',
            subtitle: '查看候选原文',
            onTap: () => _open(
              LandminePage(
                book: widget.book,
                reader: widget.reader,
                settings: widget.settings,
              ),
            ),
          ),
          _line(t),
          _entry(
            t,
            icon: Icons.show_chart,
            title: '节奏与氛围',
            subtitle: moodCount == 0 ? '暂无' : '$moodCount 章',
            onTap: () =>
                _open(MoodPage(book: widget.book, settings: widget.settings)),
          ),
        ],
      ),
    );
  }

  Widget _entry(
    ReadingTheme t, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    leading: Icon(icon, color: t.muted, size: 22),
    title: Text(title, style: TextStyle(color: t.text, fontSize: 14)),
    subtitle: Text(
      subtitle,
      style: TextStyle(color: t.muted, fontSize: 11, height: 1.35),
    ),
    trailing: Icon(Icons.chevron_right, color: t.muted, size: 19),
    onTap: onTap,
  );

  Widget _line(ReadingTheme t) =>
      Divider(height: 1, indent: 52, color: t.muted.withValues(alpha: 0.13));

  Widget _preparation(ReadingTheme t, BookInfo info) {
    final summaryCount = info.chapters
        .where((c) => (c.summary ?? '').trim().isNotEmpty)
        .length;
    final summaryDone = summaryCount >= info.chapters.length;
    final indexDone = (_index?.indexed ?? 0) >= info.chapters.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '准备报告',
          style: TextStyle(
            color: t.text,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '这些任务在后台逐章完成，可以暂停和继续。',
          style: TextStyle(color: t.muted, fontSize: 11.5),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: summaryDone
                  ? null
                  : widget.reader.enrichQueued && !widget.reader.enrichPaused
                  ? widget.reader.stopEnrich
                  : _startAnalysis,
              icon: widget.reader.enriching
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined, size: 17),
              label: Text(
                summaryDone
                    ? '章节分析已完成'
                    : widget.reader.enrichPaused
                    ? '继续章节分析'
                    : widget.reader.enrichQueued
                    ? '暂停章节分析'
                    : '生成章节分析',
              ),
            ),
            OutlinedButton.icon(
              onPressed: indexDone
                  ? null
                  : widget.reader.indexQueued && !widget.reader.indexPaused
                  ? widget.reader.stopIndex
                  : _startIndex,
              icon: widget.reader.indexing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.manage_search, size: 17),
              label: Text(
                indexDone
                    ? '全文检索已完成'
                    : widget.reader.indexPaused
                    ? '继续全文检索'
                    : widget.reader.indexQueued
                    ? '暂停全文检索'
                    : '建立全文检索',
              ),
            ),
            TextButton.icon(
              onPressed: () => _open(
                AiRuntimePage(settings: widget.settings, reader: widget.reader),
              ),
              icon: const Icon(Icons.schedule_outlined, size: 17),
              label: const Text('后台处理设置'),
            ),
          ],
        ),
      ],
    );
  }
}

class _RelationshipEvidencePage extends StatelessWidget {
  final BookInfo info;
  final RelationshipStructureInfo report;
  final ReadingSettings settings;
  final Future<void> Function(int? chapter, int? offset) onOpenChapter;

  const _RelationshipEvidencePage({
    required this.info,
    required this.report,
    required this.settings,
    required this.onOpenChapter,
  });

  String _kindLabel(String kind) => switch (kind) {
    'explicit_spouse' => '明确伴侣',
    'explicit_marriage' => '婚姻关系',
    'sexual_relation' => '明确亲密关系',
    'mutual_love' => '双向感情',
    'affection' => '感情表达',
    'romantic_intimacy' => '恋爱互动',
    'intimacy' => '亲密互动',
    'group_harem' => '多人关系原文',
    _ => '关系依据',
  };

  Widget _evidenceTile(ReadingTheme t, RelationshipEvidenceInfo evidence) {
    final chapter = info.chapters.isEmpty
        ? 0
        : evidence.chapter.clamp(0, info.chapters.length - 1);
    final title = info.chapters.isEmpty
        ? '第 ${evidence.chapter + 1} 章'
        : info.chapters[chapter].title;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onOpenChapter(evidence.chapter, null),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _kindLabel(evidence.kind),
                    style: TextStyle(color: t.muted, fontSize: 10.5),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right, size: 17, color: t.muted),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                evidence.text,
                style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.55),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '感情结构依据 · ${info.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 36),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.muted.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '结论：${report.label}\n${report.reason}\n'
              '这些是规则找到的原文依据；点击任一段可直接跳到对应章节。',
              style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.55),
            ),
          ),
          if (report.groupEvidence.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '直接关系依据',
              style: TextStyle(
                color: t.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 7),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: t.muted.withValues(alpha: 0.15)),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < report.groupEvidence.length; i++) ...[
                    _evidenceTile(t, report.groupEvidence[i]),
                    if (i + 1 < report.groupEvidence.length)
                      Divider(
                        height: 1,
                        color: t.muted.withValues(alpha: 0.12),
                      ),
                  ],
                ],
              ),
            ),
          ],
          for (final person in report.people)
            if (person.evidence.isNotEmpty) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      person.name,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    person.status,
                    style: TextStyle(color: t.muted, fontSize: 10.5),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: t.muted.withValues(alpha: 0.15)),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < person.evidence.length; i++) ...[
                      _evidenceTile(t, person.evidence[i]),
                      if (i + 1 < person.evidence.length)
                        Divider(
                          height: 1,
                          color: t.muted.withValues(alpha: 0.12),
                        ),
                    ],
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class _ChapterSummaryPage extends StatefulWidget {
  final BookInfo info;
  final ReadingSettings settings;
  final int? lastChapter;
  final List<BookAnnotation> annotations;
  final Set<int> completedChapters;
  final Future<void> Function(int? chapter, int? offset) onOpenChapter;

  const _ChapterSummaryPage({
    required this.info,
    required this.settings,
    required this.lastChapter,
    required this.annotations,
    required this.completedChapters,
    required this.onOpenChapter,
  });

  @override
  State<_ChapterSummaryPage> createState() => _ChapterSummaryPageState();
}

class _ChapterSummaryPageState extends State<_ChapterSummaryPage> {
  final ItemScrollController _scroll = ItemScrollController();

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final chapters = widget.info.chapters;
    final summarized = chapters
        .where((c) => (c.summary ?? '').trim().isNotEmpty)
        .length;
    final last = chapters.isEmpty
        ? 0
        : (widget.lastChapter ?? 0).clamp(0, chapters.length - 1);
    final annotationCountByChapter = <int, int>{};
    for (final annotation in widget.annotations) {
      annotationCountByChapter.update(
        annotation.chapter,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '章节概览 · ${widget.info.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: chapters.isEmpty
          ? Center(
              child: Text('没有可用章节', style: TextStyle(color: t.muted)),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    decoration: BoxDecoration(
                      color: t.muted.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '摘要覆盖 $summarized / ${chapters.length} 章，内容可能透露后续剧情。',
                            style: TextStyle(
                              color: t.muted,
                              fontSize: 11.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: widget.lastChapter == null
                              ? null
                              : () => _scroll.scrollTo(
                                  index: last,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOut,
                                ),
                          icon: const Icon(Icons.my_location, size: 16),
                          label: Text(
                            widget.lastChapter == null ? '尚无阅读记录' : '定位最近阅读',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ScrollablePositionedList.builder(
                    itemScrollController: _scroll,
                    initialScrollIndex: last,
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 36),
                    itemCount: chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      final summary = (chapter.summary ?? '').trim();
                      final annotationCount =
                          annotationCountByChapter[index] ?? 0;
                      final completed = widget.completedChapters.contains(
                        index,
                      );
                      final isLast =
                          widget.lastChapter != null &&
                          index == last &&
                          !completed;
                      return Material(
                        color: isLast
                            ? t.text.withValues(alpha: 0.045)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          leading: SizedBox(
                            width: 30,
                            child: Icon(
                              isLast ? Icons.history : Icons.menu_book_outlined,
                              color: isLast ? t.text : t.muted,
                              size: 19,
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  chapter.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isLast ? t.text : t.muted,
                                    fontSize: 13.5,
                                    fontWeight: isLast
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isLast)
                                Padding(
                                  padding: const EdgeInsets.only(left: 7),
                                  child: Text(
                                    '阅读中',
                                    style: TextStyle(
                                      color: t.text,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              if (completed)
                                Padding(
                                  padding: const EdgeInsets.only(left: 7),
                                  child: Icon(
                                    Icons.check_circle,
                                    color: t.muted,
                                    size: 14,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: summary.isEmpty && annotationCount == 0
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    [
                                      if (annotationCount > 0)
                                        '$annotationCount 条标注',
                                      if (summary.isNotEmpty) summary,
                                    ].join('\n'),
                                    maxLines: annotationCount == 0 ? 2 : 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: t.muted.withValues(alpha: 0.82),
                                      fontSize: 11.5,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: t.muted,
                            size: 18,
                          ),
                          onTap: () => widget.onOpenChapter(index, null),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
