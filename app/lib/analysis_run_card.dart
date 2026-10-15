import 'package:flutter/material.dart' hide Text;

import 'ai_page.dart';
import 'app_localizations.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// Ask for the model first when it is missing; otherwise queue the pass.
Future<void> startWithModel(
  BuildContext context,
  ReadingSettings settings, {
  required Future<bool> Function() hasModel,
  required String missing,
  required VoidCallback start,
}) async {
  if (await hasModel()) {
    start();
    return;
  }
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: settings.theme.background,
      title: Text(missing),
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
  if (go == true && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AiPage(settings: settings)),
    );
  }
}

/// The chapter pass behind 章节概览: one run writes each chapter's summary.
/// (It used to write a mood label too, for the 氛围 chart that 节奏 replaced.)
class ChapterAnalysisCard extends StatelessWidget {
  const ChapterAnalysisCard({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
    required this.done,
    required this.total,
  });

  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: reader,
    builder: (context, _) => AnalysisRunCard(
      reader: reader,
      settings: settings,
      icon: Icons.auto_awesome_outlined,
      title: '章节分析',
      coverage: '$done / $total 章',
      complete: total > 0 && done >= total,
      state: reader.enrichStateFor(book.id),
      startLabel: done == 0 ? '开始分析' : '继续分析',
      idleText: done == 0 ? '尚未运行' : '还有 ${total - done} 章没有分析',
      error: reader.enrichError,
      onStart: () => startWithModel(
        context,
        settings,
        hasModel: () async {
          final s = await aiStatus();
          return s.engine && s.model != null;
        },
        missing: '需要先下载本地 AI 模型',
        start: () => reader.startEnrich(book),
      ),
      onPause: () => reader.stopEnrichFor(book.id),
      onRunNow: () => reader.runEnrichNow(book.id),
    ),
  );
}

/// The embedding pass that semantic search reads from.
class SearchIndexCard extends StatelessWidget {
  const SearchIndexCard({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
    required this.done,
    required this.total,
  });

  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: reader,
    builder: (context, _) => AnalysisRunCard(
      reader: reader,
      settings: settings,
      icon: Icons.manage_search,
      title: '语义检索',
      coverage: '$done / $total 章',
      complete: total > 0 && done >= total,
      state: reader.indexStateFor(book.id),
      startLabel: done == 0 ? '建立索引' : '继续建立',
      idleText: done == 0 ? '尚未建立' : '还有 ${total - done} 章没有建立索引',
      error: reader.indexError,
      onStart: () => startWithModel(
        context,
        settings,
        hasModel: () async =>
            (await indexStatus(path: book.path, bookId: book.id)).hasModel,
        missing: '需要先下载嵌入模型',
        start: () => reader.startIndex(book.id, book.path, title: book.title),
      ),
      onPause: () => reader.stopIndexFor(book.id),
      onRunNow: () => reader.runIndexNow(book.id),
    ),
  );
}

/// Start, pause and progress for one book's background pass, shown inside the
/// page whose content that pass produces. Nothing here starts on its own: the
/// page opens on what is already there, and the work begins when the reader
/// presses the button. Pace and device policy live in the background settings
/// behind the app-wide bar; this card only says where this book's task stands.
class AnalysisRunCard extends StatelessWidget {
  const AnalysisRunCard({
    super.key,
    required this.reader,
    required this.settings,
    required this.icon,
    required this.title,
    required this.coverage,
    required this.complete,
    required this.state,
    required this.startLabel,
    required this.onStart,
    required this.onPause,
    required this.onRunNow,
    this.idleText = '尚未运行',
    this.error,
    this.options,
  });

  final ReaderState reader;
  final ReadingSettings settings;
  final IconData icon;
  final String title;

  /// What is already done, e.g. 「120 / 1392 章」.
  final String coverage;
  final bool complete;
  final AiTaskState state;
  final String startLabel;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onRunNow;

  /// Said when nothing is queued and the work is not finished.
  final String idleText;
  final String? error;

  /// Under the title, e.g. how often.
  final Widget? options;

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    final activity = state == AiTaskState.running ? reader.aiActivity : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: t.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(coverage, style: TextStyle(color: t.muted, fontSize: 11.5)),
            ],
          ),
          if (options != null) ...[const SizedBox(height: 10), options!],
          const SizedBox(height: 10),
          ..._status(t, activity),
        ],
      ),
    );
  }

  List<Widget> _status(ReadingTheme t, AiActivity? activity) {
    final small = TextStyle(color: t.muted, fontSize: 11.5, height: 1.45);
    Widget row(String text, List<Widget> buttons, {Color? color}) => Row(
      children: [
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: color == null ? small : small.copyWith(color: color),
          ),
        ),
        ...buttons,
      ],
    );
    final compact = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 12),
      ),
    );

    switch (state) {
      case AiTaskState.running:
        final a = activity;
        return [
          LinearProgressIndicator(
            value: a?.fraction,
            minHeight: 3,
            color: t.text.withValues(alpha: 0.55),
            backgroundColor: t.muted.withValues(alpha: 0.14),
          ),
          const SizedBox(height: 8),
          row(
            a == null || a.total == 0
                ? '正在启动本机引擎…'
                : [
                    '${a.done} / ${a.total}',
                    if (a.remaining != null) formatRemaining(a.remaining!),
                    if ((a.detail ?? '').isNotEmpty) a.detail!,
                  ].join(' · '),
            [
              TextButton(
                onPressed: onPause,
                style: compact,
                child: const Text('暂停'),
              ),
            ],
          ),
        ];
      case AiTaskState.waiting:
        return [
          row(reader.aiBusy ? '排队中' : reader.aiWaitingReason ?? '即将开始', [
            TextButton(
              onPressed: onRunNow,
              style: compact,
              child: const Text('立即运行'),
            ),
            TextButton(
              onPressed: onPause,
              style: compact,
              child: const Text('暂停'),
            ),
          ]),
        ];
      case AiTaskState.paused:
        return [
          row('已暂停', [
            FilledButton.tonal(
              onPressed: onStart,
              style: compact,
              child: const Text('继续'),
            ),
          ]),
        ];
      case AiTaskState.failed:
        return [
          row(error == null ? '运行失败' : '运行失败：$error', [
            FilledButton.tonal(
              onPressed: onStart,
              style: compact,
              child: const Text('重试'),
            ),
          ], color: const Color(0xFFB3574D)),
        ];
      case AiTaskState.none:
        if (complete) return [row('已完成', const [])];
        return [
          row(idleText, [
            FilledButton.tonal(
              onPressed: onStart,
              style: compact,
              child: Text(startLabel),
            ),
          ]),
        ];
    }
  }
}
