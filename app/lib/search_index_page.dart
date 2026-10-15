import 'package:flutter/material.dart' hide Text;

import 'analysis_run_card.dart';
import 'app_localizations.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// Where a book's search index is built. The search itself lives in the reader,
/// next to the text it jumps into; this page only owns the slow part.
class SearchIndexPage extends StatefulWidget {
  const SearchIndexPage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
  });

  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;

  @override
  State<SearchIndexPage> createState() => _SearchIndexPageState();
}

class _SearchIndexPageState extends State<SearchIndexPage> {
  IndexStatus? _status;
  AiTaskState? _lastState;
  int _lastDone = -1;

  @override
  void initState() {
    super.initState();
    widget.reader.addListener(_onReader);
    _load();
  }

  @override
  void dispose() {
    widget.reader.removeListener(_onReader);
    super.dispose();
  }

  /// The count on the card follows the run, but a database read per chapter
  /// is more than it needs: re-read when the task changes state, and every
  /// twenty chapters while it runs.
  void _onReader() {
    final state = widget.reader.indexStateFor(widget.book.id);
    final done = widget.reader.indexProgress?.done ?? 0;
    final changed = state != _lastState;
    final stepped =
        state == AiTaskState.running && done != _lastDone && done % 20 == 0;
    _lastState = state;
    _lastDone = done;
    if (changed || stepped) _load();
  }

  Future<void> _load() async {
    try {
      final s = await indexStatus(
        path: widget.book.path,
        bookId: widget.book.id,
      );
      if (mounted) setState(() => _status = s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final s = _status;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '语义检索 · ${widget.book.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
            children: [
              SearchIndexCard(
                book: widget.book,
                reader: widget.reader,
                settings: widget.settings,
                done: s?.indexed ?? 0,
                total: s?.total ?? widget.book.chapterCount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
