import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'background_task_bar.dart';
import 'bloom.dart';
import 'theme.dart';
import 'tts_chapters.dart';
import 'tts_prepare.dart';

/// 「32 MB」, with a decimal while it is small.
String formatSpokenBytes(int bytes) {
  final mb = bytes / (1 << 20);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// A chapter tapped in 已合成, as (book, chapter): the reader goes to it and
/// opens 听书 on it (reader_page.dart), opening its book first when another
/// is open or none is (main.dart).
final spokenChapterWanted = ValueNotifier<(int, int)?>(null);

/// 已合成: the chapters spoken ahead on this iPhone, by book, with the space
/// each takes and the way to let it go.
class TtsChaptersPage extends StatefulWidget {
  const TtsChaptersPage({super.key, required this.settings});

  final ReadingSettings settings;

  @override
  State<TtsChaptersPage> createState() => _TtsChaptersPageState();
}

class _TtsChaptersPageState extends State<TtsChaptersPage> {
  List<SpokenBook>? _books;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    TtsChapters.instance.addListener(_load);
    TtsPrepare.instance.addListener(_onJob);
    _wasRunning = TtsPrepare.instance.running;
    unawaited(_load());
  }

  @override
  void dispose() {
    TtsChapters.instance.removeListener(_load);
    TtsPrepare.instance.removeListener(_onJob);
    super.dispose();
  }

  void _onJob() {
    final running = TtsPrepare.instance.running;
    if (_wasRunning && !running) unawaited(_load());
    _wasRunning = running;
  }

  Future<void> _load() async {
    final books = await TtsChapters.instance.list();
    if (mounted) setState(() => _books = books);
  }

  Future<bool> _confirm(String what) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text('删除$what？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _deleteBook(SpokenBook b) async {
    if (!await _confirm('《${b.title}》的已合成音频')) return;
    final job = TtsPrepare.instance;
    if (job.bookId == b.id) job.cancel();
    try {
      await TtsChapters.instance.deleteBook(b.id);
    } catch (_) {
      await _load();
    }
  }

  Future<void> _deleteChapter(SpokenBook b, SpokenEntry c) async {
    if (!await _confirm('「${_name(c)}」的已合成音频')) return;
    final job = TtsPrepare.instance;
    if (job.bookId == b.id) job.cancel();
    try {
      await TtsChapters.instance.deleteChapter(b.id, c.index);
    } catch (_) {
      await _load();
    }
  }

  static String _name(SpokenEntry c) => c.title ?? '第 ${c.index + 1} 章';

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final books = _books;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        foregroundColor: t.text,
        elevation: 0,
        title: const Text('已合成'),
      ),
      body: ListenableBuilder(
        listenable: TtsPrepare.instance,
        builder: (context, _) {
          final job = TtsPrepare.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 40),
            children: [
              if (job.activity case final a?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: BloomProgress(
                    label: describeActivity(a),
                    value: a.fraction,
                    color: t.muted,
                    textColor: t.text,
                    trailing: TextButton(
                      onPressed: job.cancel,
                      child: const Text('停止'),
                    ),
                  ),
                ),
              if (books != null && books.isEmpty && !job.running)
                Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: Center(
                    child: Text(
                      '暂无已合成章节',
                      style: TextStyle(color: t.muted, fontSize: 13),
                    ),
                  ),
                ),
              for (final b in books ?? const <SpokenBook>[]) ...[
                ListTile(
                  title: Text(
                    '《${b.title}》',
                    translate: false,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatSpokenBytes(b.bytes),
                        translate: false,
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                      IconButton(
                        tooltip: context.tr('删除'),
                        icon: const Icon(Icons.delete_outline),
                        color: t.muted,
                        onPressed: () => _deleteBook(b),
                      ),
                    ],
                  ),
                ),
                for (final c in b.chapters)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 32, right: 16),
                    onTap: () => spokenChapterWanted.value = (b.id, c.index),
                    title: Text(
                      _name(c),
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.complete ? t.text : t.muted,
                        fontSize: 14,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          c.complete
                              ? formatSpokenBytes(c.bytes)
                              : '未完成 · ${formatSpokenBytes(c.bytes)}',
                          style: TextStyle(color: t.muted, fontSize: 12),
                        ),
                        IconButton(
                          tooltip: context.tr('删除'),
                          icon: const Icon(Icons.close, size: 18),
                          color: t.muted,
                          onPressed: () => _deleteChapter(b, c),
                        ),
                      ],
                    ),
                  ),
                Divider(color: t.outline, height: 16),
              ],
            ],
          );
        },
      ),
    );
  }
}
