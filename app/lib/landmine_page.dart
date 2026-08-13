import 'package:flutter/material.dart';

import 'ai_page.dart';
import 'bloom.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 排雷 — the pre-reading content scan.
///
/// This page shows passages. It does not show a verdict, and there is no code
/// path in it that could: no score is rendered, no "found / not found" is
/// claimed, no book is ever called clean. That is not modesty, it is the
/// measurement. The retriever's top cosine on this question is 0.504 for a
/// novel that has the trope and 0.503 for one that does not — the number is
/// noise. And the 0.6B that could have judged the passages reads a couple's own
/// wedding night as adultery, which would drop an innocent book for a lie.
///
/// What survives measurement is retrieval's ranking: the passages it puts at
/// the top of a book that really has the trope really are the ones. So the app
/// finds the paragraphs and the reader — who needs three seconds — decides.
///
/// Everything here is behind a tap, and this is the one screen in the app that
/// scans past the reader's progress, because a warning about chapter 700 is
/// useless to someone standing at chapter 1.
class LandminePage extends StatefulWidget {
  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;

  const LandminePage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
  });

  @override
  State<LandminePage> createState() => _LandminePageState();
}

class _LandminePageState extends State<LandminePage> {
  IndexStatus? _index;
  List<Landmine> _presets = const [];
  final _hits = <String, List<SearchHit>>{};

  /// The live phase of each running scan, keyed by landmine id.
  final _running = <String, ScanProgress>{};
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
    super.dispose();
  }

  void _onReader() {
    if (!widget.reader.indexing && _index != null) _refresh();
    if (mounted) setState(() {});
  }

  /// Opening the page has to be able to fail out loud. This asks Rust to decode
  /// and cut a book that may never have been opened this run, and when that threw
  /// the page used to sit on a spinner forever, which reads as a hang.
  Future<void> _refresh() async {
    try {
      final s = await indexStatus(
        path: widget.book.path,
        bookId: widget.book.id,
      );
      final p = await landmines();
      if (mounted) {
        setState(() {
          _index = s;
          _presets = p;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _scan(Landmine m) async {
    setState(() {
      _running[m.id] = ScanProgress(phase: '准备…', waited: 0, total: 0);
      _error = null;
    });
    try {
      final stream = scanLandmine(
        path: widget.book.path,
        bookId: widget.book.id,
        id: m.id,
        k: 6,
      );
      await for (final p in stream) {
        if (!mounted) return;
        setState(() {
          _running[m.id] = p;
          if (p.hits != null) _hits[m.id] = p.hits!;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running.remove(m.id));
    }
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
        title: Text(
          '排雷 · ${widget.book.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: s == null
          ? _opening(t)
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFB3574D),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  '排雷仅展示相关嫌疑片段，仅作参考。',
                  style: TextStyle(color: t.muted, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 14),
                if (!s.hasModel)
                  _needModel(t)
                else if (widget.reader.indexing)
                  _indexing(t)
                else if (s.indexed == 0)
                  _needIndex(t, s)
                else
                  ..._presets.map((m) => _card(t, m, s)),
              ],
            ),
    );
  }

  /// The book is decoded and cut on the way in — seconds, for a long one. If
  /// that fails, say so; never sit here spinning.
  Widget _opening(ReadingTheme t) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: _error != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB3574D),
                    fontSize: 13,
                    height: 1.7,
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Bloom(color: t.muted, size: 34),
                const SizedBox(height: 16),
                Text('正在打开书籍…', style: TextStyle(color: t.muted, fontSize: 13)),
              ],
            ),
    ),
  );

  Widget _card(ReadingTheme t, Landmine m, IndexStatus s) {
    final hits = _hits[m.id];
    final busy = _running[m.id];
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: t.muted.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.name,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (busy == null)
                TextButton(
                  onPressed: () => _scan(m),
                  child: Text(
                    hits == null ? '扫描' : '重新扫描',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          if (busy != null) ...[
            const SizedBox(height: 14),
            BloomProgress(
              label: busy.phase,
              // Nothing in a scan can honestly report a fraction: the long part
              // is a model loading off disk. The bar sweeps, the flower moves,
              // and the line below says which step we are on and how long it has
              // been on it.
              value: null,
              detail: _scanDetail(busy),
              color: t.muted,
              textColor: t.text,
            ),
          ],
          if (hits != null) ...[
            const SizedBox(height: 14),
            Divider(height: 1, color: t.muted.withValues(alpha: 0.12)),
            const SizedBox(height: 8),
            if (hits.isEmpty)
              Text(
                '没有可供判断的候选原文',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
            ...hits.map((h) => _hit(t, h)),
          ],
        ],
      ),
    );
  }

  /// The second line under the bar: whatever this step can honestly say about
  /// itself. A model warming up knows only how long it has been at it; the
  /// comparison knows how much text it is up against.
  String? _scanDetail(ScanProgress p) {
    if (p.waited > 0) return '已等待 ${p.waited} 秒';
    if (p.total > 0) return '${p.total} 段';
    return null;
  }

  /// Collapsed by default. Opening it is a spoiler and has to be the reader's
  /// own decision, taken one paragraph at a time.
  Widget _hit(ReadingTheme t, SearchHit h) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 10),
      iconColor: t.muted,
      collapsedIconColor: t.muted,
      title: Text(
        h.title.isEmpty ? '第 ${h.chapter + 1} 章' : h.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.text, fontSize: 13),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            h.text,
            style: TextStyle(color: t.text, fontSize: 13, height: 1.7),
          ),
        ),
      ],
    ),
  );

  Widget _needModel(ReadingTheme t) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '排雷需要嵌入模型',
        style: TextStyle(
          color: t.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 18),
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

  Widget _needIndex(ReadingTheme t, IndexStatus s) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '先为这本书建立索引',
        style: TextStyle(
          color: t.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: () =>
              widget.reader.startIndex(widget.book.id, widget.book.path),
          child: const Text('建立索引'),
        ),
      ),
    ],
  );

  /// The one wait in this app that genuinely knows its own length — chapters
  /// done out of chapters to do — so this bar fills for real.
  Widget _indexing(ReadingTheme t) {
    final p = widget.reader.indexProgress;
    final value = p == null || p.total == 0 ? null : p.done / p.total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BloomProgress(
          label: p == null ? '正在启动本机引擎…' : '正在建立索引 · ${p.done} / ${p.total}',
          detail: p?.title,
          value: value,
          color: t.muted,
          textColor: t.text,
          trailing: TextButton(
            onPressed: widget.reader.stopIndex,
            child: const Text('中断', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}
