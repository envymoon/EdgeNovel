import 'package:flutter/material.dart' hide Text;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'app_localizations.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// One flat list, because a nested list of 1500 chapters is worse to scroll than
/// a flat one. Volumes appear as headers inside the flow, which is what a reader
/// looking for "somewhere in volume three" actually needs.
sealed class _Row {
  const _Row();
}

class _VolumeRow extends _Row {
  final String title;
  const _VolumeRow(this.title);
}

class _ChapterRow extends _Row {
  final int index;
  final String title;

  /// Shown only for chapters the reader has moved past: ahead of them a summary
  /// is a spoiler, behind them it is a memory aid. The mood label used to ride
  /// in front of it and no longer does — a table of contents is for finding a
  /// chapter, and 氛围 has its own page now, where it is legible.
  final String? summary;
  final bool completed;
  final bool reading;
  final int annotationCount;
  const _ChapterRow(
    this.index,
    this.title,
    this.summary,
    this.completed,
    this.reading,
    this.annotationCount,
  );
}

class TocDrawer extends StatefulWidget {
  final ReaderState reader;
  final ReadingSettings settings;

  const TocDrawer({super.key, required this.reader, required this.settings});

  @override
  State<TocDrawer> createState() => _TocDrawerState();
}

class _TocDrawerState extends State<TocDrawer> {
  final _scroll = ItemScrollController();
  String _query = '';

  List<_Row> _rows(BookInfo info) {
    final q = _query.trim();
    final chapters = info.chapters;

    String? summaryFor(int i) =>
        widget.reader.isChapterCompleted(i) ? chapters[i].summary : null;
    _ChapterRow chapterRow(int i) {
      final annotationCount = widget.reader.annotationsForChapter(i).length;
      final completed = widget.reader.isChapterCompleted(i);
      return _ChapterRow(
        i,
        chapters[i].title,
        summaryFor(i),
        completed,
        i == widget.reader.chapterIndex && !completed,
        annotationCount,
      );
    }

    if (q.isNotEmpty) {
      return [
        for (var i = 0; i < chapters.length; i++)
          if (chapters[i].title.contains(q)) chapterRow(i),
      ];
    }

    final volumeAt = <int, String>{
      for (final v in info.volumes) v.firstChapter: v.title,
    };
    return [
      for (var i = 0; i < chapters.length; i++) ...[
        if (volumeAt.containsKey(i)) _VolumeRow(volumeAt[i]!),
        chapterRow(i),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final info = widget.reader.info!;
    final rows = _rows(info);

    // Open on the chapter being read, not at the top of a 1500-row list.
    final here = rows.indexWhere(
      (r) => r is _ChapterRow && r.index == widget.reader.chapterIndex,
    );

    return Drawer(
      backgroundColor: t.background,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                style: TextStyle(color: t.text, fontSize: 14),
                cursorColor: t.text,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: context.tr('搜索 ${info.chapters.length} 章'),
                  hintStyle: TextStyle(color: t.muted, fontSize: 14),
                  prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text('没有匹配的章节', style: TextStyle(color: t.muted)),
                    )
                  : ScrollablePositionedList.builder(
                      itemScrollController: _scroll,
                      initialScrollIndex: here > 0 ? here : 0,
                      itemCount: rows.length,
                      itemBuilder: (context, i) => switch (rows[i]) {
                        _VolumeRow(:final title) => Padding(
                          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                          child: Text(
                            title,
                            style: TextStyle(
                              color: t.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        _ChapterRow(
                          :final index,
                          :final title,
                          :final summary,
                          :final completed,
                          :final reading,
                          :final annotationCount,
                        ) =>
                          ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            selected: index == widget.reader.chapterIndex,
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: index == widget.reader.chapterIndex
                                          ? t.text
                                          : t.muted,
                                      fontSize: 13,
                                      fontWeight:
                                          index == widget.reader.chapterIndex
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (completed)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 5),
                                    child: Icon(
                                      Icons.check_circle,
                                      color: t.muted,
                                      size: 13,
                                    ),
                                  ),
                                if (reading)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.radio_button_checked,
                                          color: t.text,
                                          size: 11,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          '阅读中',
                                          style: TextStyle(
                                            color: t.text,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: summary == null && annotationCount == 0
                                ? null
                                : Text(
                                    [
                                      if (annotationCount > 0)
                                        '$annotationCount 条标注',
                                      ?summary,
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: t.muted.withValues(alpha: 0.75),
                                      fontSize: 11,
                                    ),
                                  ),
                            trailing: null,
                            onTap: () {
                              widget.reader.goToChapter(index);
                              Navigator.pop(context);
                            },
                          ),
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
