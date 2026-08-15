import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'reader_state.dart';
import 'source_manager_page.dart';
import 'src/rust/api/source.dart';
import 'theme.dart';

/// 找书 — search every working source at once, then bring the book home.
///
/// The result of tapping 下载 is a TXT file in the app's books directory and a
/// new row on the shelf. That is the whole trick: nothing downstream of this
/// page knows the book came from the web. Byte offsets, chapter cutting, the
/// index, summaries, 排雷 — all of it works on the file, and the file is real.
///
/// Sources answer at very different speeds and some never answer at all, so the
/// results stream in as they land rather than making the reader wait for the
/// slowest site on the list.
class DiscoverPage extends StatefulWidget {
  final ReaderState reader;
  final ReadingSettings settings;

  const DiscoverPage({super.key, required this.reader, required this.settings});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

/// One book, as offered by however many sites happen to have it.
class _Group {
  final String name;
  final String author;
  final List<FoundBookItem> offers = [];
  _Group(this.name, this.author);
}

class _DiscoverPageState extends State<DiscoverPage> {
  final _ctl = TextEditingController();
  StreamSubscription<SearchFeed>? _sub;

  final _groups = <String, _Group>{};
  int _done = 0;
  int _total = 0;
  String _at = '';
  bool _searching = false;
  bool _exact = false;
  String? _error;

  @override
  void dispose() {
    _sub?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final key = _ctl.text.trim();
    if (key.isEmpty || _searching) return;
    setState(() {
      _groups.clear();
      _done = 0;
      _total = 0;
      _at = '';
      _error = null;
      _searching = true;
    });
    _sub?.cancel();
    _sub = searchSources(key: key, exact: _exact).listen(
      (f) {
        if (!mounted) return;
        setState(() {
          _done = f.done;
          _total = f.total;
          _at = f.sourceName;
          for (final h in f.hits) {
            // One book, many sites. Grouping by title+author is what makes the
            // page usable: without it a popular novel arrives forty times.
            final k = '${h.name}|${h.author}';
            _groups
                .putIfAbsent(k, () => _Group(h.name, h.author))
                .offers
                .add(h);
          }
        });
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _error = '$e';
            _searching = false;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _searching = false);
      },
    );
  }

  void _stop() {
    cancelSearch();
    _sub?.cancel();
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final groups = _groups.values.toList()
      ..sort((a, b) => b.offers.length.compareTo(a.offers.length));

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: TextField(
          controller: _ctl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: t.text, fontSize: 15),
          cursorColor: t.text,
          decoration: InputDecoration(
            hintText: context.tr('书名或作者'),
            hintStyle: TextStyle(color: t.muted, fontSize: 15),
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          IconButton(
            tooltip: context.tr('搜索'),
            icon: const Icon(Icons.search),
            color: t.muted,
            onPressed: _search,
          ),
          IconButton(
            tooltip: context.tr('书源'),
            icon: const Icon(Icons.dns_outlined),
            color: t.muted,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SourceManagerPage(settings: widget.settings),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _exactToggle(t),
            ),
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: BloomProgress(
                label: '正在问遍所有书源',
                detail: _total == 0 ? null : '$_done/$_total · 刚问过 $_at',
                value: _total == 0 ? null : _done / _total,
                color: t.muted,
                textColor: t.text,
                trailing: TextButton(
                  onPressed: _stop,
                  child: Text(
                    '停止',
                    style: TextStyle(color: t.muted, fontSize: 12),
                  ),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB3574D), fontSize: 13),
              ),
            ),
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _searching
                            ? ''
                            : _done > 0
                            ? '什么都没搜到'
                            : '',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: t.muted,
                          fontSize: 13,
                          height: 1.9,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                    itemCount: groups.length,
                    itemBuilder: (_, i) => _card(t, groups[i]),
                  ),
          ),
        ],
      ),
    );
  }

  /// Sites decide for themselves what a keyword means, and many read it as "show
  /// them everything". This does not ask them to be stricter — it drops the hits
  /// whose title is not the word you typed, after they arrive.
  Widget _exactToggle(ReadingTheme t) {
    final on = _exact;
    return InkWell(
      onTap: () => setState(() => _exact = !_exact),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: t.muted.withValues(alpha: on ? 0.55 : 0.2)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.check : Icons.filter_alt_outlined,
              size: 13,
              color: on ? t.text : t.muted,
            ),
            const SizedBox(width: 5),
            Text(
              '书名全字匹配',
              style: TextStyle(color: on ? t.text : t.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(ReadingTheme t, _Group g) {
    final head = g.offers.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: t.muted.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  g.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              if (g.author.isNotEmpty)
                Text(g.author, style: TextStyle(color: t.muted, fontSize: 12)),
            ],
          ),
          if (head.lastChapter.isNotEmpty || head.wordCount.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (head.wordCount.isNotEmpty) head.wordCount,
                if (head.lastChapter.isNotEmpty) '最新 ${head.lastChapter}',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.muted, fontSize: 11),
            ),
          ],
          if (head.intro.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              head.intro,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.muted, fontSize: 12, height: 1.6),
            ),
          ],
          const SizedBox(height: 10),
          // Which site to take it from is the reader's call, and it is the whole
          // ballgame: the same title runs 1303 chapters on one site and 50 on
          // the next, and the search result says nothing about which. So there
          // is one button here, and it goes and finds out.
          Row(
            children: [
              InkWell(
                onTap: () => _compare(g),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: t.muted.withValues(alpha: 0.45)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.straighten, size: 13, color: t.muted),
                      const SizedBox(width: 6),
                      Text(
                        '比一比 ${g.offers.length} 个源',
                        style: TextStyle(color: t.text, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _compare(_Group g) async {
    final t = widget.settings.theme;
    final messenger = ScaffoldMessenger.of(context);
    final chosen = await showDialog<FoundBookItem>(
      context: context,
      builder: (_) => _ComparePanel(group: g, theme: t),
    );
    if (chosen == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(
        offer: chosen,
        theme: t,
        onDone: (path) async {
          await widget.reader.importPaths([path]);
          messenger.showSnackBar(
            SnackBar(content: Text('《${chosen.name}》已加入书架')),
          );
        },
      ),
    );
  }
}

/// The sources that have this book, side by side, measured.
///
/// The numbers arrive one site at a time and the list re-sorts under them, so
/// the best offer rises to the top on its own. "Best" is not simply the longest:
/// a source whose chapters are ciphertext is worthless however many it has, so
/// readable copies sort above unreadable ones no matter the count.
class _ComparePanel extends StatefulWidget {
  final _Group group;
  final ReadingTheme theme;

  const _ComparePanel({required this.group, required this.theme});

  @override
  State<_ComparePanel> createState() => _ComparePanelState();
}

class _ComparePanelState extends State<_ComparePanel> {
  final _probes = <String, OfferProbe>{};
  StreamSubscription<OfferProbe>? _sub;
  bool _measuring = true;

  @override
  void initState() {
    super.initState();
    _sub =
        probeOffers(
          offers: widget.group.offers
              .map((o) => Offer(sourceUrl: o.sourceUrl, bookUrl: o.bookUrl))
              .toList(),
        ).listen(
          (p) {
            if (mounted) setState(() => _probes[p.sourceUrl] = p);
          },
          onDone: () {
            if (mounted) setState(() => _measuring = false);
          },
          onError: (_) {
            if (mounted) setState(() => _measuring = false);
          },
        );
  }

  @override
  void dispose() {
    cancelProbe();
    _sub?.cancel();
    super.dispose();
  }

  /// Readable beats unreadable; among readable, longest wins; the not-yet-
  /// measured wait at the bottom rather than jumping about.
  int _rank(FoundBookItem o) {
    final p = _probes[o.sourceUrl];
    if (p == null) return 1;
    if (p.readable) return -p.chapters;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final offers = [...widget.group.offers]
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    // The one to take, if any has proved itself: most chapters among the
    // readable. Everything else in this list is measured against it.
    final best = offers
        .where((o) => _probes[o.sourceUrl]?.readable == true)
        .fold<FoundBookItem?>(null, (b, o) {
          final n = _probes[o.sourceUrl]!.chapters;
          return b == null || n > _probes[b.sourceUrl]!.chapters ? o : b;
        });

    return AlertDialog(
      backgroundColor: t.background,
      title: Text(
        '《${widget.group.name}》· ${offers.length} 个源',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.text, fontSize: 16),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_measuring) ...[
              Text(
                '正在比较各源…',
                style: TextStyle(color: t.muted, fontSize: 11, height: 1.7),
              ),
              const SizedBox(height: 10),
            ],
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: offers.length,
                itemBuilder: (_, i) => _row(t, offers[i], offers[i] == best),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('关闭', style: TextStyle(color: t.muted)),
        ),
      ],
    );
  }

  Widget _row(ReadingTheme t, FoundBookItem o, bool best) {
    final p = _probes[o.sourceUrl];
    final broken = p != null && !p.readable;
    return InkWell(
      onTap: () => Navigator.pop(context, o),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: best
                ? t.text.withValues(alpha: 0.45)
                : t.muted.withValues(alpha: 0.18),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          o.sourceName.isEmpty ? o.sourceUrl : o.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: broken ? t.muted : t.text,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (best) ...[
                        const SizedBox(width: 6),
                        Text(
                          '最全',
                          style: TextStyle(
                            color: t.text,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  if (p == null)
                    Text('正在数…', style: TextStyle(color: t.muted, fontSize: 11))
                  else
                    Text(
                      [
                        if (p.chapters > 0) '${p.chapters} 章',
                        if (p.readable && p.lastTitle.isNotEmpty)
                          '最新 ${p.lastTitle}',
                        if (p.note.isNotEmpty) p.note,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: broken ? const Color(0xFFB3574D) : t.muted,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (p == null)
              Bloom(color: t.muted, size: 14)
            else
              Icon(
                Icons.download_outlined,
                size: 16,
                color: broken ? t.muted.withValues(alpha: 0.4) : t.muted,
              ),
          ],
        ),
      ),
    );
  }
}

/// The download itself: a real fraction, because here we genuinely know the
/// denominator — the table of contents told us how many chapters there are.
class _DownloadDialog extends StatefulWidget {
  final FoundBookItem offer;
  final ReadingTheme theme;
  final Future<void> Function(String path) onDone;

  const _DownloadDialog({
    required this.offer,
    required this.theme,
    required this.onDone,
  });

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  DownloadProgress? _p;
  String? _error;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final o = widget.offer;
    try {
      await for (final p in downloadBook(
        sourceUrl: o.sourceUrl,
        bookUrl: o.bookUrl,
        title: o.name,
        author: o.author,
      )) {
        if (!mounted) return;
        setState(() => _p = p);
        final path = p.path;
        if (path != null) {
          await widget.onDone(path);
          if (mounted) {
            setState(() => _finished = true);
            Navigator.pop(context);
          }
          return;
        }
      }
      if (mounted && !_finished) setState(() => _error = '下载没有完成');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final p = _p;
    final done = p?.done ?? 0;
    final total = p?.total ?? 0;
    final failed = p?.failed ?? 0;
    return AlertDialog(
      backgroundColor: t.background,
      title: Text(
        '《${widget.offer.name}》',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.text, fontSize: 16),
      ),
      content: SizedBox(
        width: 360,
        child: _error != null
            ? Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFFB3574D),
                  fontSize: 13,
                  height: 1.7,
                ),
              )
            : BloomProgress(
                label: p?.phase ?? '正在读取目录…',
                detail: total == 0
                    ? '来源：${widget.offer.sourceName}'
                    : '$done/$total 章${failed > 0 ? ' · $failed 章抓不到' : ''}',
                value: total == 0 ? null : done / total,
                color: t.muted,
                textColor: t.text,
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelDownload();
            Navigator.pop(context);
          },
          child: Text(
            _error != null ? '关闭' : '停止',
            style: TextStyle(color: t.muted),
          ),
        ),
      ],
    );
  }
}
