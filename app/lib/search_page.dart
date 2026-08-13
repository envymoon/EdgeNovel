import 'package:flutter/material.dart';

import 'ai_page.dart';
import 'bloom.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// Two searches, one page.
///
/// *原文* is exact substring matching: no model, no index, nothing to install,
/// works on a book imported thirty seconds ago. It answers "where does it say
/// this", which is most of what a reader actually needs.
///
/// *语义* answers the other question — "where was that old man selling pills" —
/// where the reader remembers the scene but not a single word of it. That one
/// costs a 48 MB model and an indexing pass, so it asks before it takes them.
///
/// Both stop at the chapter being read. Finding a name from chapter 900 while
/// standing in chapter 20 is a spoiler however it was found.
enum _Mode { literal, semantic }

class SearchPage extends StatefulWidget {
  final ReaderState reader;
  final ReadingSettings settings;

  const SearchPage({super.key, required this.reader, required this.settings});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _input = TextEditingController();
  _Mode _mode = _Mode.literal;
  IndexStatus? _index;
  List<SearchHit> _hits = const [];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.reader.addListener(_onReader);
    _refresh();
  }

  @override
  void dispose() {
    widget.reader.removeListener(_onReader);
    _input.dispose();
    super.dispose();
  }

  /// The index grows while this page is open; when a run ends, re-read how much
  /// of the book it covered.
  void _onReader() {
    if (!widget.reader.indexing && _index != null) _refresh();
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final b = widget.reader.info;
    if (b == null) return;
    final s = await indexStatus(path: b.path, bookId: b.id);
    if (mounted) setState(() => _index = s);
  }

  /// True when semantic search can actually run right now.
  bool get _semanticReady =>
      _index != null &&
      _index!.hasModel &&
      _index!.indexed > 0 &&
      !widget.reader.indexing;

  Future<void> _search() async {
    final q = _input.text.trim();
    if (q.isEmpty) return;
    if (_mode == _Mode.semantic && !_semanticReady) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final b = widget.reader.info!;
      // The chapter being read is included: the reader has seen it.
      final upTo = widget.reader.chapterIndex;
      final hits = _mode == _Mode.literal
          ? await searchText(path: b.path, query: q, upToChapter: upTo, k: 50)
          : await semanticSearch(
              path: b.path,
              bookId: b.id,
              query: q,
              upToChapter: upTo,
              k: 12,
            );
      if (mounted) setState(() => _hits = hits);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _searching = false;
          _searched = true;
        });
      }
    }
  }

  void _setMode(_Mode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      // The two searches answer differently; showing one's results under the
      // other's name would be a lie.
      _hits = const [];
      _searched = false;
      _error = null;
    });
  }

  void _jump(SearchHit h) {
    widget.reader.goToOffset(h.chapter, h.start);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final s = _index;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('搜索', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: s == null
          ? Center(child: Bloom(color: t.muted, size: 34))
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<_Mode>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      textStyle: WidgetStateProperty.all(
                        const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: _Mode.literal,
                        label: Text('原文'),
                        icon: Icon(Icons.search, size: 16),
                      ),
                      ButtonSegment(
                        value: _Mode.semantic,
                        label: Text('语义'),
                        icon: Icon(Icons.auto_awesome, size: 16),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (v) => _setMode(v.first),
                  ),
                  const SizedBox(height: 14),
                  _field(t),
                  const SizedBox(height: 10),
                  _hint(t, s),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFB3574D),
                        fontSize: 12,
                      ),
                    ),
                  Expanded(child: _results(t, s)),
                ],
              ),
            ),
    );
  }

  Widget _field(ReadingTheme t) => TextField(
    controller: _input,
    autofocus: true,
    style: TextStyle(color: t.text, fontSize: 14),
    cursorColor: t.text,
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => _search(),
    decoration: InputDecoration(
      isDense: true,
      hintText: _mode == _Mode.literal ? '书里的原话' : '用自己的话描述情节或人物',
      hintStyle: TextStyle(color: t.muted, fontSize: 14),
      prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
      suffixIcon: _searching
          ? Padding(
              padding: const EdgeInsets.all(11),
              child: Bloom(color: t.muted, size: 16),
            )
          : null,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );

  Widget _hint(ReadingTheme t, IndexStatus s) {
    final read = widget.reader.chapterIndex + 1;
    final extra = _mode == _Mode.semantic && s.hasModel && s.indexed < s.total
        ? ' · 索引已覆盖 ${s.indexed}/${s.total} 章'
        : '';
    return Text(
      '只搜索已读的前 $read 章$extra',
      style: TextStyle(color: t.muted, fontSize: 11),
    );
  }

  Widget _results(ReadingTheme t, IndexStatus s) {
    if (_mode == _Mode.semantic) {
      if (!s.hasModel) return _needModel(t);
      if (widget.reader.indexing) return _indexing(t);
      if (s.indexed == 0) return _needIndex(t, s);
    }
    if (_hits.isEmpty) {
      return Center(
        child: Text(
          _searched && !_searching ? '没有找到' : '',
          style: TextStyle(color: t.muted, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: t.muted.withValues(alpha: 0.12)),
      itemBuilder: (context, i) => _hit(t, _hits[i]),
    );
  }

  /// The embedder is a separate, optional download, and it is asked for here —
  /// at the moment it would be used — rather than shipped with the app.
  Widget _needModel(ReadingTheme t) => ListView(
    children: [
      const SizedBox(height: 8),
      Text(
        '语义搜索需要一个嵌入模型',
        style: TextStyle(
          color: t.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AiPage(settings: widget.settings),
              ),
            );
            await _refresh();
          },
          child: const Text('去下载'),
        ),
      ),
    ],
  );

  Widget _needIndex(ReadingTheme t, IndexStatus s) => ListView(
    children: [
      const SizedBox(height: 8),
      Text(
        '先为这本书建立索引',
        style: TextStyle(
          color: t.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: () {
            final b = widget.reader.info!;
            widget.reader.startIndex(b.id, b.path);
          },
          child: const Text('建立索引'),
        ),
      ),
    ],
  );

  Widget _indexing(ReadingTheme t) {
    final p = widget.reader.indexProgress;
    final value = p == null || p.total == 0 ? null : p.done / p.total;
    return ListView(
      children: [
        const SizedBox(height: 8),
        BloomProgress(
          label: p == null ? '正在启动本机引擎…' : '正在建立索引 · ${p.done} / ${p.total}',
          detail: p?.title,
          value: value,
          color: t.muted,
          textColor: t.text,
        ),
        if (widget.reader.indexError != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.reader.indexError!,
            style: const TextStyle(color: Color(0xFFB3574D), fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: widget.reader.stopIndex,
            child: const Text('中断', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _hit(ReadingTheme t, SearchHit h) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 6),
    title: Text(
      h.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: t.muted, fontSize: 11),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        h.text,
        maxLines: 3,
        style: TextStyle(color: t.text, fontSize: 13, height: 1.5),
      ),
    ),
    onTap: () => _jump(h),
  );
}
