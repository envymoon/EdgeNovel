import 'package:flutter/material.dart' hide Text;
import 'app_localizations.dart';
import 'theme.dart';
import 'youshu_login_page.dart';
import 'youshu_service.dart';
import 'youshu_parser.dart';

/// Reading a book detail only reads local metadata, never the network.
class YoushuReviewEntry extends StatefulWidget {
  final String title;
  final String? author;
  final ReadingSettings settings;
  const YoushuReviewEntry({
    super.key,
    required this.title,
    this.author,
    required this.settings,
  });
  @override
  State<YoushuReviewEntry> createState() => _YoushuReviewEntryState();
}

class _YoushuReviewEntryState extends State<YoushuReviewEntry> {
  YoushuSnapshot? _snapshot;
  bool _localReady = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = YoushuService.instance;
    final cached = await service.cached(widget.title, widget.author);
    if (mounted) {
      setState(() {
        _snapshot = cached;
        _localReady = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final rating = snapshot?.book?.ratings.current;
    final archived = snapshot?.book?.ratings.archived;
    final ratingLabel = rating != null
        ? '优书网现行 ${rating.score.toStringAsFixed(1)}/10 · ${rating.count}人评分'
        : archived != null
        ? '旧优书存档 ${archived.score.toStringAsFixed(1)}/10 · ${archived.count}人评分'
        : '优书网';
    if (snapshot?.reviews.isEmpty == true) {
      if (rating == null && snapshot?.book?.ratings.archived == null) {
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _openReviews,
            child: const Text('重新检查书评'),
          ),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.rate_review_outlined),
          title: const Text('书评'),
          subtitle: Text(ratingLabel, translate: false),
          trailing: const Icon(Icons.chevron_right),
          onTap: !_localReady ? null : _openReviews,
        ),
      ),
    );
  }

  Future<void> _openReviews() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => YoushuReviewsPage(
          title: widget.title,
          author: widget.author,
          settings: widget.settings,
          initial: _snapshot,
        ),
      ),
    );
    if (mounted) _load();
  }
}

class YoushuReviewsPage extends StatefulWidget {
  final String title;
  final String? author;
  final ReadingSettings settings;
  final YoushuSnapshot? initial;
  const YoushuReviewsPage({
    super.key,
    required this.title,
    this.author,
    required this.settings,
    required this.initial,
  });
  @override
  State<YoushuReviewsPage> createState() => _YoushuReviewsPageState();
}

class _YoushuReviewsPageState extends State<YoushuReviewsPage> {
  late YoushuSnapshot _snapshot =
      widget.initial ?? YoushuSnapshot(null, const [], DateTime.now(), null);
  late List<YoushuReview> _reviews = List.of(_snapshot.reviews);
  late String? _next = _snapshot.nextPath;
  bool _busy = false;
  bool _stopRequested = false;
  String? _error;

  @override
  void dispose() {
    _stopRequested = true;
    super.dispose();
  }

  bool get _needsLogin =>
      _error?.contains('登录') == true || _error?.contains('登錄') == true;
  @override
  void initState() {
    super.initState();
    if (widget.initial == null) _refresh();
  }

  Future<void> _refresh({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _stopRequested = false;
      _error = null;
    });
    try {
      if (more && _next != null && _snapshot.book != null) {
        final page = await YoushuService.instance.loadMore(
          widget.title,
          widget.author,
        );
        if (!mounted) return;
        setState(() {
          _snapshot = page;
          _reviews = List.of(page.reviews);
          _next = page.nextPath;
        });
      } else {
        final result = await YoushuService.instance.refresh(
          widget.title,
          widget.author,
          force: true,
        );
        if (!mounted || result == null) return;
        setState(() {
          _snapshot = result;
          _reviews = List.of(result.reviews);
          _next = result.nextPath;
        });
      }
      while (mounted && !_stopRequested && _next != null) {
        // One request at a time; every completed page is persisted by service.
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!mounted || _stopRequested) break;
        final page = await YoushuService.instance.loadMore(
          widget.title,
          widget.author,
        );
        if (!mounted) return;
        setState(() {
          _snapshot = page;
          _reviews = List.of(page.reviews);
          _next = page.nextPath;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLogin() async {
    final loggedIn = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => YoushuLoginPage(settings: widget.settings),
      ),
    );
    // The user already opened this book's reviews and explicitly logged in.
    if (loggedIn == true && mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('书评'),
      actions: [
        IconButton(
          tooltip: context.tr('刷新'),
          onPressed: _busy ? null : () => _refresh(),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: context.tr('登录优书网'),
          icon: const Icon(Icons.account_circle_outlined),
          onPressed: _openLogin,
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _reviews.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _snapshot.book?.title ?? widget.title,
                      translate: false,
                      style: const TextStyle(fontSize: 20),
                    ),
                    const SizedBox(height: 8),
                    if (_snapshot.book != null)
                      YoushuRatingsView(ratings: _snapshot.book!.ratings),
                    Text(
                      '优书网 · ${_snapshot.updated.toLocal().toString().substring(0, 16)}',
                      translate: false,
                    ),
                    const Text('包含旧站存档和新评论，可能涉及剧透。已加载内容保存在本地，仅手动更新。'),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已保存 ${_reviews.length} 条${!_busy && _snapshot.paginationVerified && _snapshot.book != null && _next == null ? ' · 已加载全部可见书评' : ''}',
                            translate: false,
                          ),
                        ),
                        if (_busy)
                          TextButton(
                            onPressed: _stopRequested
                                ? null
                                : () => setState(() => _stopRequested = true),
                            child: Text(_stopRequested ? '正在暂停…' : '暂停'),
                          )
                        else if (_next != null || !_snapshot.paginationVerified)
                          TextButton(
                            onPressed: () => _refresh(more: _next != null),
                            child: const Text('继续加载全部'),
                          ),
                      ],
                    ),
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _error!,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                  ),
                                ),
                                if (_needsLogin) ...[
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                    onPressed: _busy ? null : _openLogin,
                                    icon: const Icon(Icons.login),
                                    label: const Text('登录优书网'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }
              if (index <= _reviews.length) {
                final review = _reviews[index - 1];
                return Card(
                  key: ValueKey(review.id),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          review.content,
                          style: const TextStyle(height: 1.65),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${review.date}${review.stars == null ? '' : ' · ${'★' * review.stars!}'}',
                          translate: false,
                          style: TextStyle(
                            color: widget.settings.theme.muted,
                            fontSize: 12,
                          ),
                        ),
                        if (review.excerpt) const Text('原站摘要'),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  if (!_busy && _error == null && _reviews.isEmpty)
                    Text(_snapshot.book == null ? '尚未匹配到优书网书籍' : '暂无书评'),
                  if (_next != null)
                    TextButton(
                      onPressed: _busy ? null : () => _refresh(more: true),
                      child: const Text('继续加载全部'),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

}

class YoushuRatingsView extends StatelessWidget {
  final YoushuRatings ratings;
  const YoushuRatingsView({super.key, required this.ratings});

  @override
  Widget build(BuildContext context) {
    final current = ratings.current;
    final archived = ratings.archived;
    if (current == null && archived == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          if (current != null)
            Text(
              'youshu.me 现行 ${current.score.toStringAsFixed(1)}/10 · ${current.count} 人',
              translate: false,
            ),
          if (archived != null)
            Text(
              '旧优书存档 ${archived.score.toStringAsFixed(1)}/10 · ${archived.count} 人',
              translate: false,
            ),
        ],
      ),
    );
  }
}
