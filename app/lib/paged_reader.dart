import 'dart:ui';

import 'package:flutter/material.dart';

import 'annotation_page.dart';
import 'reader_interaction.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// One piece of a paragraph on one page. Usually the whole paragraph; a
/// paragraph taller than the remaining space is split at a line boundary and
/// continues as another chunk on the next page.
class PageChunk {
  final int paraIndex;
  final ParaKind kind;
  final String text;
  final bool endsParagraph;
  final int sourceStart;
  final int sourceEnd;
  final int leadingNonSource;

  const PageChunk(
    this.paraIndex,
    this.kind,
    this.text,
    this.endsParagraph,
    this.sourceStart,
    this.sourceEnd,
    this.leadingNonSource,
  );
}

class BookPage {
  final List<PageChunk> chunks;

  const BookPage(this.chunks);

  /// Where this page starts, for progress: the first paragraph on it.
  int get firstPara => chunks.isEmpty ? 0 : chunks.first.paraIndex;
}

/// The one source of text styles for paged reading. Measurement (TextPainter)
/// and rendering (Text) must agree to the pixel, so both read from here —
/// duplicating these numbers is how pages start overflowing.
class _Typography {
  final ReadingSettings s;
  final ReadingTheme t;

  const _Typography(this.s, this.t);

  TextStyle style(ParaKind kind) => switch (kind) {
    ParaKind.title => TextStyle(
      color: t.text,
      fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
      fontSize: s.fontSize + 4,
      fontWeight: FontWeight.w600,
      height: 1.5,
    ),
    ParaKind.volume => TextStyle(
      color: t.muted,
      fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
      fontSize: s.fontSize + 1,
      letterSpacing: 3,
      height: 1.5,
    ),
    ParaKind.interstitial => TextStyle(
      color: t.muted,
      fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
      fontSize: s.fontSize - 2,
      fontStyle: FontStyle.italic,
      height: s.lineHeight,
    ),
    ParaKind.body => TextStyle(
      color: t.text,
      fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
      fontSize: s.fontSize,
      height: s.lineHeight,
    ),
  };

  double spacingBefore(ParaKind kind) => switch (kind) {
    ParaKind.title => 8,
    ParaKind.volume => 28,
    _ => 0,
  };

  double spacingAfter(ParaKind kind) => switch (kind) {
    ParaKind.title => 24,
    ParaKind.volume => 28,
    _ => s.paragraphSpacing,
  };

  /// Interstitials render inside a bordered container that eats width.
  double horizontalInset(ParaKind kind) =>
      kind == ParaKind.interstitial ? 14 : 0;
}

/// Fill pages of [size] with the chapter's paragraphs, splitting the ones that
/// straddle a page at a rendered line boundary.
List<BookPage> paginate(
  List<Paragraph> paras,
  Size size,
  ReadingSettings settings,
  ReadingTheme theme,
  Set<int> annotatedParagraphs,
) {
  final ty = _Typography(settings, theme);
  final pages = <BookPage>[];
  var chunks = <PageChunk>[];
  var remaining = size.height;

  void flush() {
    if (chunks.isNotEmpty) {
      pages.add(BookPage(chunks));
      chunks = <PageChunk>[];
    }
    remaining = size.height;
  }

  for (var i = 0; i < paras.length; i++) {
    final p = paras[i];
    final width = size.width - ty.horizontalInset(p.kind);
    var text = p.kind == ParaKind.body && settings.firstLineIndent
        ? '　　${p.text}'
        : p.text;
    final prefixLength = text.length - p.text.length;
    var displayOffset = 0;
    PageChunk chunk(String value, bool endsParagraph) {
      final sourceStart = (displayOffset - prefixLength).clamp(
        0,
        p.text.length,
      );
      final leadingNonSource = (prefixLength - displayOffset).clamp(
        0,
        value.length,
      );
      final sourceEnd = (sourceStart + value.length - leadingNonSource).clamp(
        sourceStart,
        p.text.length,
      );
      return PageChunk(
        i,
        p.kind,
        value,
        endsParagraph,
        sourceStart,
        sourceEnd,
        leadingNonSource,
      );
    }

    if (chunks.isNotEmpty) remaining -= ty.spacingBefore(p.kind);

    while (text.isNotEmpty) {
      final annotationHeight = annotatedParagraphs.contains(i) ? 18.0 : 0.0;
      final tp = TextPainter(
        text: TextSpan(text: text, style: ty.style(p.kind)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);

      if (tp.height + annotationHeight <= remaining + 0.5) {
        chunks.add(chunk(text, true));
        remaining -= tp.height + annotationHeight + ty.spacingAfter(p.kind);
        break;
      }

      // The paragraph itself fits but its folded annotation tag does not. Move
      // both to the next page when possible; otherwise reserve tag space while
      // splitting so the final chunk never loses or overlaps the tag.
      if (annotationHeight > 0 &&
          tp.height <= remaining + 0.5 &&
          chunks.isNotEmpty) {
        flush();
        continue;
      }

      // Count whole rendered lines that fit, then cut the string there.
      final lines = tp.computeLineMetrics();
      var acc = 0.0;
      var fit = 0;
      final lineRoom =
          remaining - (tp.height <= remaining + 0.5 ? annotationHeight : 0);
      for (final lm in lines) {
        if (acc + lm.height > lineRoom + 0.5) break;
        acc += lm.height;
        fit++;
      }
      if (fit == 0) {
        if (chunks.isEmpty) {
          // A single line taller than the page. Place it and move on rather
          // than loop forever; it will clip, and nothing sane produces it.
          chunks.add(chunk(text, true));
          text = '';
        }
        flush();
        continue;
      }

      final midOfLastFit = Offset(width, acc - lines[fit - 1].height / 2);
      var cut = tp.getLineBoundary(tp.getPositionForOffset(midOfLastFit)).end;
      cut = cut.clamp(1, text.length);
      chunks.add(chunk(text.substring(0, cut), false));
      final rest = text.substring(cut);
      text = rest.trimLeft();
      displayOffset += cut + rest.length - text.length;
      flush();
    }
  }
  flush();
  return pages.isEmpty ? const [BookPage([])] : pages;
}

class PagedReader extends StatefulWidget {
  final ReaderState reader;
  final ReadingSettings settings;
  final EdgeInsets padding;

  /// Reports (current page, pages in chapter) upward for the bottom bar.
  final ValueNotifier<(int, int)> pageInfo;
  final bool annotationMode;
  final ValueChanged<AnnotationDraft?>? onAnnotationSelection;
  final bool compactTapZones;
  final VoidCallback? onToggleControls;

  const PagedReader({
    super.key,
    required this.reader,
    required this.settings,
    required this.padding,
    required this.pageInfo,
    this.annotationMode = false,
    this.onAnnotationSelection,
    this.compactTapZones = false,
    this.onToggleControls,
  });

  @override
  State<PagedReader> createState() => PagedReaderState();
}

class PagedReaderState extends State<PagedReader> {
  PageController? _ctrl;
  List<BookPage> _pages = const [];
  String _signature = '';
  int _chapter = -1;

  /// Paragraph at the top of the current page, so re-pagination (font change,
  /// window resize) can land back on the same text.
  int _topPara = 0;

  /// Set when paging backwards across a chapter boundary: the previous chapter
  /// must open on its last page, not its first.
  bool _landAtEnd = false;

  /// Where the pointer went down, to tell a tap from a drag without entering
  /// the gesture arena — arbitration against the PageView's drag recognizer is
  /// exactly the tap latency being avoided here.
  Offset _downAt = Offset.zero;

  int get _page => _ctrl?.hasClients == true
      ? _ctrl!.page!.round()
      : _ctrl?.initialPage ?? 0;

  /// Turn one page; roll into the neighbouring chapter at either edge.
  void turn(int dir) {
    final r = widget.reader;
    final target = _page + dir;
    if (target >= 0 && target < _pages.length) {
      _ctrl?.animateToPage(
        target,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      );
    } else if (dir > 0) {
      r.next();
    } else if (r.chapterIndex > 0) {
      _landAtEnd = true;
      r.prev();
    }
  }

  void _rebuild(Size size) {
    final s = widget.settings;
    final r = widget.reader;
    final sig =
        '${r.info?.id}|${r.chapterIndex}|${r.paragraphs.length}|$size|'
        '${s.fontFamily}|${s.fontSize}|${s.lineHeight}|${s.paragraphSpacing}|${s.firstLineIndent}|${s.themeIndex}|'
        '${r.annotations.map((a) => '${a.id}:${a.updatedAt}').join(',')}';
    if (sig == _signature) return;
    _signature = sig;

    final annotated = <int>{
      for (var i = 0; i < r.paragraphs.length; i++)
        if (r.annotationsForParagraph(r.paragraphs[i]).isNotEmpty) i,
    };
    _pages = paginate(r.paragraphs, size, s, s.theme, annotated);

    final int initial;
    if (r.chapterIndex != _chapter) {
      // Fresh chapter: open on the restored paragraph (0 unless a book was
      // just reopened), or on the last page when paging backwards into it.
      _chapter = r.chapterIndex;
      initial = _landAtEnd
          ? _pages.length - 1
          : _pageContaining(r.initialParagraph);
      _landAtEnd = false;
    } else {
      // Same text, new geometry: stay on the paragraph being read.
      initial = _pageContaining(_topPara);
    }
    _topPara = _pages[initial].firstPara;

    final old = _ctrl;
    _ctrl = PageController(initialPage: initial);
    // Both deferred: _rebuild runs during build, when notifying listeners and
    // disposing a controller the old PageView still holds are both illegal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old?.dispose();
      if (mounted) {
        widget.pageInfo.value = (initial + 1, _pages.length);
        widget.reader.recordChapterViewport(
          atStart: initial == 0,
          atEnd: initial == _pages.length - 1,
        );
      }
    });
  }

  int _pageContaining(int paraIndex) {
    final i = _pages.lastIndexWhere((p) => p.firstPara <= paraIndex);
    return i < 0 ? 0 : i;
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inner = Size(
          constraints.maxWidth - widget.padding.horizontal,
          constraints.maxHeight - widget.padding.vertical,
        );
        _rebuild(inner);
        // Tap zones: left half of the page is back, right half is forward. Raw
        // pointer events, not a GestureDetector: a tap recognizer must wait out
        // the PageView's drag recognizer before it may fire, and that
        // arbitration is felt as lag on every single page turn.
        //
        // Pages ignore OS text scaling: pagination measures with TextPainter at
        // scale 1.0, and text drawn any larger than measured overflows every
        // page by a constant strip. Font size in the reader is the in-app
        // setting's job.
        return MediaQuery.withNoTextScaling(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _downAt = e.position,
            onPointerUp: (e) {
              if (!widget.annotationMode &&
                  (e.position - _downAt).distance < 12) {
                switch (resolveReaderTap(
                  x: e.localPosition.dx,
                  width: constraints.maxWidth,
                  compact: widget.compactTapZones,
                  annotationMode: widget.annotationMode,
                )) {
                  case ReaderTapAction.previousPage:
                    turn(-1);
                  case ReaderTapAction.nextPage:
                    turn(1);
                  case ReaderTapAction.toggleControls:
                    widget.onToggleControls?.call();
                  case ReaderTapAction.none:
                    break;
                }
              }
            },
            child: ScrollConfiguration(
              // Desktops exclude mouse dragging from scrollables by default;
              // a page you cannot drag with the mouse feels broken.
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
              ),
              child: PageView.builder(
                key: ValueKey(_signature),
                controller: _ctrl,
                itemCount: _pages.length,
                onPageChanged: (i) {
                  _topPara = _pages[i].firstPara;
                  widget.reader.onVisibleParagraph(_topPara);
                  widget.pageInfo.value = (i + 1, _pages.length);
                  widget.reader.recordChapterViewport(
                    atStart: i == 0,
                    atEnd: i == _pages.length - 1,
                  );
                },
                itemBuilder: (context, i) => Padding(
                  padding: widget.padding,
                  child: _PageView(
                    page: _pages[i],
                    settings: widget.settings,
                    theme: t,
                    reader: widget.reader,
                    annotationMode: widget.annotationMode,
                    onAnnotationSelection: widget.onAnnotationSelection,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PageView extends StatelessWidget {
  final BookPage page;
  final ReadingSettings settings;
  final ReadingTheme theme;
  final ReaderState reader;
  final bool annotationMode;
  final ValueChanged<AnnotationDraft?>? onAnnotationSelection;

  const _PageView({
    required this.page,
    required this.settings,
    required this.theme,
    required this.reader,
    required this.annotationMode,
    this.onAnnotationSelection,
  });

  @override
  Widget build(BuildContext context) {
    final ty = _Typography(settings, theme);
    final children = <Widget>[];
    for (var i = 0; i < page.chunks.length; i++) {
      final c = page.chunks[i];
      if (i > 0) {
        children.add(
          SizedBox(
            height:
                ty.spacingAfter(page.chunks[i - 1].kind) +
                ty.spacingBefore(c.kind),
          ),
        );
      }
      final plainText = switch (c.kind) {
        ParaKind.volume => Center(child: Text(c.text, style: ty.style(c.kind))),
        ParaKind.interstitial => Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.muted.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
          ),
          child: Text(c.text, style: ty.style(c.kind)),
        ),
        _ => Text(c.text, style: ty.style(c.kind)),
      };
      final text = annotationMode && c.kind == ParaKind.body
          ? SelectableText(
              c.text,
              style: ty.style(c.kind),
              onSelectionChanged: (selection, _) {
                final paragraph = reader.paragraphs[c.paraIndex];
                final start =
                    (c.sourceStart + selection.start - c.leadingNonSource)
                        .clamp(c.sourceStart, c.sourceEnd);
                final end = (c.sourceStart + selection.end - c.leadingNonSource)
                    .clamp(c.sourceStart, c.sourceEnd);
                if (selection.isCollapsed || end <= start) {
                  onAnnotationSelection?.call(null);
                  return;
                }
                onAnnotationSelection?.call(
                  AnnotationDraft(
                    chapter: reader.chapterIndex,
                    paragraph: paragraph,
                    start: start,
                    end: end,
                  ),
                );
              },
            )
          : plainText;
      final annotations = c.endsParagraph
          ? reader.annotationsForParagraph(reader.paragraphs[c.paraIndex])
          : const <BookAnnotation>[];
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            if (annotations.isNotEmpty)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => showAnnotationComments(
                  context,
                  reader: reader,
                  settings: settings,
                  paragraph: reader.paragraphs[c.paraIndex],
                  annotations: annotations,
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: 3, bottom: 1),
                  child: Text(
                    '◌ ${annotations.length}',
                    style: TextStyle(color: theme.muted, fontSize: 9),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
