import 'package:flutter/material.dart' hide Text;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'app_localizations.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/image.dart';
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

/// A 章间立绘, listed after the chapter it follows.
class _PlateRow extends _Row {
  final int chapter;
  const _PlateRow(this.chapter);
}

class _ChapterRow extends _Row {
  final int index;
  final String title;

  /// Shown only for chapters the reader has moved past: ahead of them a summary
  /// is a spoiler, behind them it is a memory aid. The mood label used to ride
  /// in front of it and no longer does — a table of contents is for finding a
  /// chapter. (Mood labels are gone altogether now; 节奏 is counted instead.)
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

  /// Show the plate drawn after a chapter.
  final ValueChanged<int>? onPlate;

  const TocDrawer({
    super.key,
    required this.reader,
    required this.settings,
    this.onPlate,
  });

  @override
  State<TocDrawer> createState() => _TocDrawerState();
}

class _TocDrawerState extends State<TocDrawer> {
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  String _query = '';

  /// The chapters a plate follows.
  Set<int> _plates = const {};

  @override
  void initState() {
    super.initState();
    _loadPlates();
  }

  Future<void> _loadPlates() async {
    final id = widget.reader.info?.id;
    if (id == null || widget.onPlate == null) return;
    try {
      final chapters = await plateChapters(bookId: id);
      if (mounted) setState(() => _plates = chapters.toSet());
    } catch (_) {}
  }

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
        if (_plates.contains(i)) _PlateRow(i),
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
      backgroundColor: t.surface,
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
                  : _FastScroller(
                      count: rows.length,
                      scroll: _scroll,
                      positions: _positions,
                      theme: t,
                      labelAt: (i) {
                        for (var k = i; k >= 0; k--) {
                          final r = rows[k];
                          if (r is _ChapterRow) return r.title;
                          if (r is _VolumeRow) return r.title;
                        }
                        return '';
                      },
                      child: ScrollablePositionedList.builder(
                        itemScrollController: _scroll,
                        itemPositionsListener: _positions,
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
                          _PlateRow(:final chapter) => ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: Icon(
                              Icons.image_outlined,
                              color: t.muted,
                              size: 16,
                            ),
                            minLeadingWidth: 0,
                            title: Text(
                              '章间立绘',
                              style: TextStyle(color: t.muted, fontSize: 13),
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              widget.onPlate?.call(chapter);
                            },
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
            ),
          ],
        ),
      ),
    );
  }
}

/// A thumb down the right edge of a long list, dragged to go anywhere in it
/// at once, with the chapter it is at beside it while held. Rows differ in
/// height, so it goes by row, not by pixel.
class _FastScroller extends StatefulWidget {
  const _FastScroller({
    required this.count,
    required this.scroll,
    required this.positions,
    required this.theme,
    required this.labelAt,
    required this.child,
  });

  final int count;
  final ItemScrollController scroll;
  final ItemPositionsListener positions;
  final ReadingTheme theme;
  final String Function(int row) labelAt;
  final Widget child;

  /// Lists shorter than this scroll well enough by finger.
  static const minRows = 60;

  @override
  State<_FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<_FastScroller> {
  static const _thumb = 44.0;

  /// Where the thumb is held, 0 to 1; null while it is not.
  double? _held;
  int _row = 0;

  /// Where the list is, 0 to 1, from its first row in view.
  double _at() {
    final shown = widget.positions.itemPositions.value;
    if (shown.isEmpty) return 0;
    var first = widget.count;
    var last = 0;
    for (final p in shown) {
      if (p.itemTrailingEdge > 0 && p.index < first) first = p.index;
      if (p.itemLeadingEdge < 1 && p.index > last) last = p.index;
    }
    final span = widget.count - (last - first + 1);
    return span <= 0 ? 0 : (first / span).clamp(0.0, 1.0);
  }

  void _drag(double dy, double height) {
    final f = ((dy - _thumb / 2) / (height - _thumb)).clamp(0.0, 1.0);
    final row = (f * (widget.count - 1)).round();
    setState(() {
      _held = f;
      _row = row;
    });
    widget.scroll.jumpTo(index: row);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count < _FastScroller.minRows) return widget.child;
    final t = widget.theme;
    return LayoutBuilder(
      builder: (context, box) {
        final height = box.maxHeight;
        return Stack(
          children: [
            widget.child,
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (d) => _drag(d.localPosition.dy, height),
                onVerticalDragUpdate: (d) =>
                    _drag(d.localPosition.dy, height),
                onVerticalDragEnd: (_) => setState(() => _held = null),
                onVerticalDragCancel: () => setState(() => _held = null),
                child: ValueListenableBuilder(
                  valueListenable: widget.positions.itemPositions,
                  builder: (context, _, _) {
                    final f = _held ?? _at();
                    return Stack(
                      children: [
                        Positioned(
                          top: f * (height - _thumb),
                          right: 3,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: _held == null ? 4 : 7,
                            height: _thumb,
                            decoration: BoxDecoration(
                              color: t.muted.withValues(
                                alpha: _held == null ? 0.35 : 0.7,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (_held case final f?)
              Positioned(
                top: (f * (height - _thumb) + _thumb / 2 - 18).clamp(
                  0.0,
                  height - 36,
                ),
                right: 36,
                child: IgnorePointer(
                  child: Container(
                    constraints: BoxConstraints(maxWidth: box.maxWidth - 64),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: t.raisedSurface,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 6),
                      ],
                    ),
                    child: Text(
                      widget.labelAt(_row),
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, fontSize: 13),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
