import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/cleanup.dart';
import 'theme.dart';

/// 文本整理: what the rules found in the book that is not the book, a group to
/// each kind. Ticked groups go with one tap; a group opens to show its lines.
/// The file is never changed, so 还原原文 puts everything back.
class TextCleanupPage extends StatefulWidget {
  const TextCleanupPage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
    this.phrase,
  });

  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;

  /// Words the reader marked as an advert in the reader.
  final String? phrase;

  @override
  State<TextCleanupPage> createState() => _TextCleanupPageState();
}

/// A group and which of its lines are ticked.
class _Group {
  _Group(this.group) : on = group.checked ? {for (var i = 0; i < group.items.length; i++) i} : {};

  final CleanupGroup group;
  final Set<int> on;

  bool get all => on.length == group.items.length;
}

class _TextCleanupPageState extends State<TextCleanupPage> {
  CleanupReport? _report;
  List<_Group> _groups = const [];
  String? _error;
  bool _busy = true;

  String get _path => widget.book.path;

  @override
  void initState() {
    super.initState();
    _load(phrase: widget.phrase);
  }

  Future<void> _load({String? phrase}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await findCleanup(path: _path);
      final groups = report.groups.map(_Group.new).toList();
      if (phrase != null && phrase.trim().isNotEmpty) {
        final mine = await findCleanupPhrase(path: _path, phrase: phrase);
        if (mine.items.isNotEmpty) groups.insert(0, _Group(mine));
      }
      if (!mounted) return;
      setState(() {
        _report = report;
        _groups = groups;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  int get _ticked => _groups.fold(0, (n, g) => n + g.on.length);

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addPhrase() async {
    final t = widget.settings.theme;
    final controller = TextEditingController();
    final phrase = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text('添加', style: TextStyle(color: t.text, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: t.text),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('查找'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (phrase == null || phrase.trim().isEmpty || !mounted) return;
    try {
      final found = await findCleanupPhrase(path: _path, phrase: phrase);
      if (!mounted) return;
      if (found.items.isEmpty) {
        _say('没有找到');
        return;
      }
      setState(() => _groups = [_Group(found), ..._groups]);
    } catch (e) {
      if (mounted) _say('$e');
    }
  }

  Future<bool> _confirm(String title, String action) async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text(title, style: TextStyle(color: t.text, fontSize: 17)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _remove() async {
    final report = _report;
    final n = _ticked;
    if (report == null || n == 0) return;
    if (!await _confirm('删除 $n 处？', '删除')) return;
    final cuts = [
      for (final g in _groups)
        for (final i in g.on) ...g.group.items[i].cuts,
    ];
    setState(() => _busy = true);
    try {
      await widget.reader.settleBefore(_path);
      await applyCleanup(
        path: _path,
        bookId: widget.book.id,
        totalBytes: report.totalBytes,
        cuts: cuts,
      );
      await widget.reader.reopenAfterRecut(_path);
      if (!mounted) return;
      _say('已删除 $n 处');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _say('$e');
    }
  }

  Future<void> _restore() async {
    if (!await _confirm('还原原文？', '还原')) return;
    setState(() => _busy = true);
    try {
      await widget.reader.settleBefore(_path);
      await restoreOriginalText(path: _path, bookId: widget.book.id);
      await widget.reader.reopenAfterRecut(_path);
      if (!mounted) return;
      _say('已还原');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _say('$e');
    }
  }

  Future<void> _open(_Group g) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _GroupPage(group: g, settings: widget.settings),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final n = _ticked;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '文本整理 · ${widget.book.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
        actions: [
          if (_report?.restorable ?? false)
            TextButton(
              onPressed: _busy ? null : _restore,
              child: const Text('还原原文'),
            ),
          IconButton(
            tooltip: context.tr('添加'),
            onPressed: _busy || _report == null ? null : _addPhrase,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _body(t),
      bottomNavigationBar: _groups.isEmpty
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: FilledButton(
                  onPressed: _busy || n == 0 ? null : _remove,
                  child: Text('删除所选（$n 处）'),
                ),
              ),
            ),
    );
  }

  Widget _body(ReadingTheme t) {
    if (_busy && _report == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, style: TextStyle(color: t.muted)),
        ),
      );
    }
    if (_groups.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('没有找到', style: TextStyle(color: t.text, fontSize: 15)),
                const SizedBox(height: 10),
                Text(
                  '若有漏网广告，可在阅读页点选词图标选中广告文字并「标为广告」，或点右上角 + 手动添加。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          itemCount: _groups.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) =>
              i == 0 ? _adHint(t) : _groupRow(t, _groups[i - 1]),
        ),
      ),
    );
  }

  Widget _adHint(ReadingTheme t) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: t.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: t.outline),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.highlight_alt, size: 17, color: t.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '若有漏网广告，可在阅读页点选词图标选中广告文字并「标为广告」，或点右上角 + 手动添加。',
            style: TextStyle(color: t.muted, fontSize: 12, height: 1.45),
          ),
        ),
      ],
    ),
  );

  Widget _groupRow(ReadingTheme t, _Group g) {
    final count = g.group.items.length;
    final same = g.group.kind == g.group.label;
    return Material(
      clipBehavior: Clip.antiAlias,
      color: t.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: t.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(6, 2, 12, 2),
        leading: Checkbox(
          tristate: true,
          value: g.all ? true : (g.on.isEmpty ? false : null),
          onChanged: _busy
              ? null
              : (_) => setState(() {
                  if (g.all) {
                    g.on.clear();
                  } else {
                    g.on.addAll(List.generate(count, (i) => i));
                  }
                }),
        ),
        title: Text(
          g.group.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 14),
        ),
        subtitle: Text(
          same ? '$count 处' : '${g.group.kind} · $count 处',
          style: TextStyle(color: t.muted, fontSize: 11.5),
        ),
        trailing: Icon(Icons.chevron_right, color: t.muted, size: 19),
        onTap: _busy ? null : () => _open(g),
      ),
    );
  }
}

/// One group's lines, each with what would go struck through.
class _GroupPage extends StatefulWidget {
  const _GroupPage({required this.group, required this.settings});

  final _Group group;
  final ReadingSettings settings;

  @override
  State<_GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<_GroupPage> {
  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final g = widget.group;
    final items = g.group.items;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          g.group.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (g.all) {
                g.on.clear();
              } else {
                g.on.addAll(List.generate(items.length, (i) => i));
              }
            }),
            child: Text(g.all ? '全不选' : '全选'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 4, 18, 24),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final item = items[i];
              final on = g.on.contains(i);
              return InkWell(
                onTap: () => setState(() => on ? g.on.remove(i) : g.on.add(i)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: on,
                        onChanged: (_) => setState(() => on ? g.on.remove(i) : g.on.add(i)),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RichText(
                                text: TextSpan(
                                  style: TextStyle(color: t.text, fontSize: 13.5, height: 1.5),
                                  children: [
                                    for (final p in item.pieces)
                                      TextSpan(
                                        text: p.text,
                                        style: p.removed
                                            ? TextStyle(
                                                color: on ? t.muted : t.text,
                                                decoration: on ? TextDecoration.lineThrough : null,
                                                backgroundColor: t.muted.withValues(alpha: 0.12),
                                              )
                                            : null,
                                      ),
                                  ],
                                ),
                              ),
                              if (item.chapterTitle.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  item.chapterTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: t.muted, fontSize: 11),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
