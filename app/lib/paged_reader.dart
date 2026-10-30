import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'annotation_page.dart';
import 'page_curl.dart';
import 'reader_interaction.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';
import 'tts_controller.dart';

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

  /// For a chunk cut off at the foot of a page: the rest of the paragraph,
  /// laid out after [text] and clipped to [lines]. Justified text leaves a
  /// paragraph's last line ragged, and the line at the foot of a page is not
  /// the paragraph's last.
  final String tail;
  final int lines;

  const PageChunk(
    this.paraIndex,
    this.kind,
    this.text,
    this.endsParagraph,
    this.sourceStart,
    this.sourceEnd,
    this.leadingNonSource, {
    this.tail = '',
    this.lines = 0,
  });
}

class BookPage {
  final List<PageChunk> chunks;

  /// The width the page was measured at. It is drawn at exactly this width,
  /// so its lines break where they were counted.
  final double width;

  const BookPage(this.chunks, {this.width = double.infinity});

  /// Where this page starts, for progress: the first paragraph on it.
  int get firstPara => chunks.isEmpty ? 0 : chunks.first.paraIndex;

  /// And how far into that paragraph, for a page that opens mid-paragraph.
  int get firstStart => chunks.isEmpty ? 0 : chunks.first.sourceStart;
}

/// The first-line indent: two ideographs drawn in no colour. Not two
/// ideographic spaces — a justified line hands its leading spaces out to the
/// gaps between its characters, which closed the indent up on the first line
/// of every paragraph.
const indentGlyphs = '中中';
const indentStyle = TextStyle(color: Color(0x00000000));

/// Measuring and drawing pick fallback fonts by locale: the measuring
/// TextPainter has none of its own, a Text takes the app's (English for some
/// readers). Both read the same one from the style.
const _hans = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');

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
      fontFamily: s.resolvedReadingFont,
      locale: _hans,
      fontSize: s.fontSize + 4,
      fontWeight: FontWeight.w600,
      height: 1.5,
    ),
    ParaKind.volume => TextStyle(
      color: t.muted,
      fontFamily: s.resolvedReadingFont,
      locale: _hans,
      fontSize: s.fontSize + 1,
      letterSpacing: 3,
      height: 1.5,
    ),
    ParaKind.interstitial => TextStyle(
      color: t.muted,
      fontFamily: s.resolvedReadingFont,
      locale: _hans,
      fontSize: s.fontSize - 2,
      fontStyle: FontStyle.italic,
      height: s.lineHeight,
    ),
    ParaKind.body => TextStyle(
      color: t.text,
      fontFamily: s.resolvedReadingFont,
      locale: _hans,
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
  // A pixel narrower than the page: a line that just fits here must still fit
  // after layout snaps the page to the screen's pixels, or it wraps once more
  // on screen and the page's last line falls off the end.
  final pageWidth = size.width - 1;

  void flush() {
    if (chunks.isNotEmpty) {
      pages.add(BookPage(chunks, width: pageWidth));
      chunks = <PageChunk>[];
    }
    remaining = size.height;
  }

  for (var i = 0; i < paras.length; i++) {
    final p = paras[i];
    final width = pageWidth - ty.horizontalInset(p.kind);
    var text = p.kind == ParaKind.body && settings.firstLineIndent
        ? '$indentGlyphs${p.text}'
        : p.text;
    final prefixLength = text.length - p.text.length;
    var displayOffset = 0;
    PageChunk chunk(
      String value,
      bool endsParagraph, {
      String tail = '',
      int lines = 0,
    }) {
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
        tail: tail,
        lines: lines,
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
      final rest = text.substring(cut);
      chunks.add(
        chunk(text.substring(0, cut), false, tail: rest, lines: fit),
      );
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

  /// Paging back off the chapter's first page, before the chapter before it
  /// opens: true when the reader put something there (a 章间立绘), and this
  /// chapter stays.
  final bool Function()? onBackOffStart;

  /// 听书: the page follows the sentence being spoken, and shows it.
  final TtsController? tts;

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
    this.onBackOffStart,
    this.tts,
  });

  @override
  State<PagedReader> createState() => PagedReaderState();
}

class PagedReaderState extends State<PagedReader>
    with SingleTickerProviderStateMixin {
  PageController? _ctrl;
  List<BookPage> _pages = const [];
  String _signature = '';
  int _chapter = -1;
  Size _size = Size.zero;

  /// Chapters already cut into pages: this one and, cut while the reader
  /// reads, the ones either side, so a turn across a chapter's edge costs no
  /// more than any other turn.
  final Map<int, (String, List<BookPage>)> _laidOut = {};

  /// The page the copies under the reader are drawn around; see [_readyAround].
  int _shown = -1;

  /// Text at the top of the current page, as (paragraph, start), so
  /// re-pagination (font change, window resize) lands back on the same text,
  /// not on the page where its paragraph began.
  int _topPara = 0;
  int _topStart = 0;

  /// Set when paging backwards across a chapter boundary: the previous chapter
  /// must open on its last page, not its first.
  bool _landAtEnd = false;

  /// Where the pointer went down, to tell a tap from a drag without entering
  /// the gesture arena — arbitration against the PageView's drag recognizer is
  /// exactly the tap latency being avoided here.
  Offset _downAt = Offset.zero;

  /// The page the pointer went down on. A swipe on the chapter's first or
  /// last page has nowhere to go inside the PageView; it goes on into the
  /// chapter beside it, as a tap there does.
  int _downPage = 0;

  /// The sentence being spoken, as (paragraph, start): the page turns when
  /// it moves on to the next one.
  (int, int) _spoken = (-1, -1);

  /// 仿真翻页: the page turning over the one it uncovers, drawn over both
  /// while it turns (page_curl.dart). Pictures of the two pages, taken from
  /// the page on screen and the copies drawn under it ([_readyAround]).
  PageCurl? _curl;

  /// Which way [_curl] turns (1 on, -1 back), and whether, let go, it goes
  /// all the way over or falls back.
  int _curlDir = 0;
  bool _curlCompletes = false;

  /// Its turn once let go or tapped: from where to where, how, and how far it
  /// lifts on the way (a tap lifts the corner a little as it goes over).
  late final AnimationController _curlRun;
  Offset _curlFrom = Offset.zero;
  Offset _curlTo = Offset.zero;
  double _curlRise = 0;
  Curve _curlCurve = Curves.easeOut;

  /// The finger turning [_curl]: 1 or -1 while it drags a page, 0 before a
  /// drag has started one, null once a drag could not (the page then turns
  /// at once when it is let go), 2 when the plate came instead.
  int? _dragDir = 0;
  Offset _downLocal = Offset.zero;
  double _lastDx = 0;

  /// The whole box pages are drawn in, margins included.
  Size _box = Size.zero;

  final _currentKey = GlobalKey();
  final _prevKey = GlobalKey();
  final _nextKey = GlobalKey();

  bool get _curlMode =>
      widget.settings.pageMode == PageMode.curl && !widget.annotationMode;

  @override
  void initState() {
    super.initState();
    widget.tts?.addListener(_onSpeech);
    _curlRun = AnimationController(vsync: this)
      ..addListener(_onCurlRun)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _endCurl();
      });
  }

  @override
  void didUpdateWidget(PagedReader old) {
    super.didUpdateWidget(old);
    if (old.tts != widget.tts) {
      old.tts?.removeListener(_onSpeech);
      widget.tts?.addListener(_onSpeech);
    }
  }

  void _onSpeech() {
    final tts = widget.tts!;
    final now = (tts.activeParagraph, tts.activeStart);
    if (now == _spoken || !mounted) return;
    _spoken = now;
    if (now.$1 >= 0) {
      final page = _pageOf(now.$1, now.$2);
      if (page != _page) {
        _dropCurl();
        _ctrl?.jumpToPage(page);
      }
    }
    setState(() {});
  }

  /// The page on which [start] of paragraph [para] is.
  int _pageOf(int para, int start) {
    for (var i = 0; i < _pages.length; i++) {
      for (final c in _pages[i].chunks) {
        if (c.paraIndex == para && start < c.sourceEnd) return i;
      }
    }
    return _pageContaining(para);
  }

  int get _page => _ctrl?.hasClients == true
      ? _ctrl!.page!.round()
      : _ctrl?.initialPage ?? 0;

  /// Turn one page; roll into the neighbouring chapter at either edge.
  /// [pastPlate]: back from the plate before this chapter, so on into the
  /// chapter before without showing it again.
  void turn(int dir, {bool pastPlate = false}) {
    // A tap while a page is still turning: that one lands at once.
    if (_curl != null && _dragDir != 1 && _dragDir != -1) _endCurl();
    if (_curlMode && !pastPlate && _curl == null) {
      final h = _box.height;
      if (_startCurl(dir, h)) {
        if (_curl != null) {
          _runCurl(
            dir > 0 ? _curl!.gone : _curl!.corner,
            completes: true,
            rise: h * 0.12,
            curve: Curves.easeInOut,
          );
        }
        return;
      }
    }
    final r = widget.reader;
    final target = _page + dir;
    if (target >= 0 && target < _pages.length) {
      // A tap shows the next page at once: a slide, however short, is felt as
      // the page catching before it turns. Dragging still slides.
      _ctrl?.jumpToPage(target);
    } else if (dir > 0) {
      r.next();
    } else if (r.chapterIndex > 0) {
      if (!pastPlate && (widget.onBackOffStart?.call() ?? false)) return;
      _landAtEnd = true;
      r.prev();
    }
  }

  /// Lifts the page that turns [dir] by its right edge at [y]: the page on
  /// screen going on, the page before coming back over it. False when the
  /// pages either side are not drawn yet; the page then turns at once. True
  /// with no [_curl] when the plate before this chapter came instead.
  bool _startCurl(int dir, double y) {
    if (_shown != _page || _ctrl?.hasClients != true || _box.isEmpty) {
      return false;
    }
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final here = _snap(_currentKey, ratio);
    final there = _snap(dir > 0 ? _nextKey : _prevKey, ratio);
    if (here == null || there == null) {
      here?.dispose();
      there?.dispose();
      return false;
    }
    if (dir < 0 && _page == 0 && (widget.onBackOffStart?.call() ?? false)) {
      here.dispose();
      there.dispose();
      return true;
    }
    setState(() {
      _curlDir = dir;
      _curlCompletes = false;
      _curl = PageCurl(
        top: dir > 0 ? here : there,
        under: dir > 0 ? there : here,
        scale: ratio,
        corner: Offset(_box.width, y.clamp(0, _box.height)),
        size: _box,
        turned: dir < 0,
      );
    });
    return true;
  }

  /// A picture of what [key]'s boundary last drew, or null if it has not.
  static ui.Image? _snap(GlobalKey key, double ratio) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.hasSize) return null;
    try {
      return box.toImageSync(pixelRatio: ratio);
    } catch (_) {
      return null;
    }
  }

  void _runCurl(
    Offset to, {
    required bool completes,
    double rise = 0,
    Curve curve = Curves.easeOut,
  }) {
    final curl = _curl!;
    _curlFrom = curl.at.value;
    _curlTo = to;
    _curlRise = rise;
    _curlCurve = curve;
    _curlCompletes = completes;
    final way = (curl.gone - curl.corner).distance;
    final left = way <= 0 ? 0.0 : ((to - _curlFrom).distance / way).clamp(0, 1);
    _curlRun.duration = Duration(milliseconds: (120 + 300 * left).round());
    _curlRun.forward(from: 0);
  }

  void _onCurlRun() {
    final curl = _curl;
    if (curl == null) return;
    final t = _curlCurve.transform(_curlRun.value);
    curl.at.value =
        Offset.lerp(_curlFrom, _curlTo, t)! -
        Offset(0, _curlRise * math.sin(math.pi * t));
  }

  /// The turn has landed: on the page uncovered, or back where it was.
  void _endCurl() {
    final curl = _curl;
    if (curl == null) return;
    _curlRun.stop();
    final dir = _curlDir;
    if (!_curlCompletes) {
      _dropCurl();
      return;
    }
    curl.at.value = dir > 0 ? curl.gone : curl.corner;
    final target = _page + dir;
    if (target >= 0 && target < _pages.length) {
      _ctrl?.jumpToPage(target);
      _dropCurl();
      return;
    }
    // Into the chapter beside it, which opens a moment later: the picture of
    // its page stays up until then ([_rebuild]).
    _curlCompletes = false;
    final r = widget.reader;
    if (dir > 0) {
      unawaited(r.next());
    } else {
      _landAtEnd = true;
      unawaited(r.prev());
    }
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted && identical(_curl, curl)) _dropCurl();
    });
  }

  void _dropCurl() {
    final curl = _curl;
    if (curl == null) return;
    _curlRun.stop();
    _dragDir = 0;
    if (mounted) setState(() => _curl = null);
    curl.dispose();
  }

  /// The finger on a page in 仿真: once it has gone sideways, it holds the
  /// page's right edge — going on, the page on screen's; going back, the page
  /// before's, coming back over from the left.
  void _dragCurl(PointerMoveEvent e) {
    final moved = e.localPosition - _downLocal;
    if (_dragDir == 0) {
      if (moved.dx.abs() < 10 || moved.dx.abs() <= moved.dy.abs()) return;
      final dir = moved.dx < 0 ? 1 : -1;
      // By a corner when taken near the top or the bottom, straight across
      // in between.
      final h = _box.height;
      final y = _downLocal.dy < h / 3
          ? 0.0
          : _downLocal.dy > h * 2 / 3
          ? h
          : _downLocal.dy;
      _dragDir = !_startCurl(dir, y)
          ? null
          : _curl != null
          ? dir
          : 2;
    }
    final curl = _curl;
    final dir = _dragDir;
    if (curl == null || dir == null || dir.abs() != 1) return;
    final c = curl.corner;
    final byCorner = c.dy <= 0 || c.dy >= _box.height;
    // Going on, the edge stays under the finger; coming back, the page comes
    // twice as fast, so one swipe across brings it all the way.
    final x = dir > 0
        ? c.dx + moved.dx
        : math.min(curl.gone.dx + 2 * moved.dx, c.dx);
    curl.at.value = Offset(x, c.dy + (byCorner ? moved.dy : 0));
    _lastDx = e.delta.dx;
  }

  /// The finger let go of a page it was turning: over, if it was still
  /// going that way, else back. False when it was turning none.
  bool _letGoCurl() {
    final dir = _dragDir;
    _dragDir = 0;
    if (dir == 2) return true;
    final curl = _curl;
    if (curl == null || dir == null || dir.abs() != 1) return false;
    final moved = curl.at.value - (dir > 0 ? curl.corner : curl.gone);
    final over = dir > 0
        ? moved.dx < -24 && _lastDx <= 2
        : moved.dx > 24 && _lastDx >= -2;
    _runCurl(over == (dir > 0) ? curl.gone : curl.corner, completes: over);
    return true;
  }

  String _signatureOf(int chapter, int paragraphs, Size size) {
    final s = widget.settings;
    final r = widget.reader;
    return '${r.info?.id}|$chapter|$paragraphs|$size|'
        '${s.fontFamily}|${s.fontSize}|${s.lineHeight}|${s.paragraphSpacing}|${s.firstLineIndent}|${s.themeIndex}|'
        '${r.annotations.map((a) => '${a.id}:${a.updatedAt}').join(',')}';
  }

  List<BookPage> _paginate(int chapter, List<Paragraph> paras, Size size) {
    final s = widget.settings;
    final annotated = <int>{
      for (var i = 0; i < paras.length; i++)
        if (widget.reader
            .annotationsForParagraph(paras[i], chapter: chapter)
            .isNotEmpty)
          i,
    };
    return paginate(paras, size, s, s.theme, annotated);
  }

  void _rebuild(Size size) {
    final r = widget.reader;
    final sig = _signatureOf(r.chapterIndex, r.paragraphs.length, size);
    if (sig == _signature) return;
    _signature = sig;
    _size = size;
    _shown = -1;
    // New pages: the pictures of the old ones go, a page turned into this
    // chapter having landed.
    if (_curl case final curl?) {
      _curlRun.stop();
      _curl = null;
      _dragDir = 0;
      curl.dispose();
    }

    final ready = _laidOut[r.chapterIndex];
    _pages = ready?.$1 == sig
        ? ready!.$2
        : _paginate(r.chapterIndex, r.paragraphs, size);
    _laidOut
      ..removeWhere((c, _) => (c - r.chapterIndex).abs() > 1)
      ..[r.chapterIndex] = (sig, _pages);

    final int initial;
    if (r.chapterIndex != _chapter) {
      // Fresh chapter: open on the restored paragraph (0 unless a book was
      // just reopened), or on the last page when paging backwards into it.
      _chapter = r.chapterIndex;
      initial = _landAtEnd
          ? _pages.length - 1
          : _pageContaining(r.initialParagraph);
      _landAtEnd = false;
      _topPara = _pages[initial].firstPara;
      _topStart = _pages[initial].firstStart;
    } else {
      // Same text, new geometry: stay on the words being read. The spot itself
      // is kept until a turn, so A+ then A- comes back to the very same page.
      initial = _pageOf(_topPara, _topStart);
    }

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
        _readyAround();
      }
    });
  }

  /// Once a turn has settled and its frame is out, in frames in which nothing
  /// moves: cut the chapters either side into pages, and draw the pages a turn
  /// would show under the reader, where nobody sees them. Whichever way the
  /// next turn goes, its page is laid out and its characters drawn once
  /// already — a character's first drawing is the slow one.
  void _readyAround() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        final r = widget.reader;
        for (final c in [r.chapterIndex + 1, r.chapterIndex - 1]) {
          final paras = r.nearbyParagraphs(c);
          if (paras == null) continue;
          final sig = _signatureOf(c, paras.length, _size);
          if (_laidOut[c]?.$1 != sig) {
            _laidOut[c] = (sig, _paginate(c, paras, _size));
          }
        }
        setState(() => _shown = _page);
      })
      ..ensureVisualUpdate();
  }

  /// The pages one turn away from [_shown], in this chapter or the one beside
  /// it, each with the key its copy is drawn under.
  List<(BookPage, GlobalKey)> get _neighbours {
    if (_shown < 0 || _shown >= _pages.length) return const [];
    final c = widget.reader.chapterIndex;
    return [
      if (_shown > 0)
        (_pages[_shown - 1], _prevKey)
      else if (_laidOut[c - 1]?.$2 case final prev?)
        (prev.last, _prevKey),
      if (_shown < _pages.length - 1)
        (_pages[_shown + 1], _nextKey)
      else if (_laidOut[c + 1]?.$2 case final next?)
        (next.first, _nextKey),
    ];
  }

  int _pageContaining(int paraIndex) {
    final i = _pages.lastIndexWhere((p) => p.firstPara <= paraIndex);
    return i < 0 ? 0 : i;
  }

  @override
  void dispose() {
    widget.tts?.removeListener(_onSpeech);
    _ctrl?.dispose();
    _curlRun.dispose();
    _curl?.dispose();
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
        _box = constraints.biggest;
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
            onPointerDown: (e) {
              // A second finger leaves a page being dragged alone; one still
              // turning lands before the finger takes the next.
              if (_dragDir == 1 || _dragDir == -1) return;
              _downAt = e.position;
              _downLocal = e.localPosition;
              _downPage = _page;
              if (_curl != null) _endCurl();
              _dragDir = 0;
            },
            onPointerMove: _curlMode ? _dragCurl : null,
            // The pages do not scroll in 仿真: a notch of the wheel turns one,
            // and the notches that come while it turns are let go by.
            onPointerSignal: _curlMode
                ? (e) {
                    if (e is PointerScrollEvent &&
                        e.scrollDelta.dy != 0 &&
                        _curl == null) {
                      turn(e.scrollDelta.dy > 0 ? 1 : -1);
                    }
                  }
                : null,
            onPointerCancel: (_) => _letGoCurl(),
            onPointerUp: (e) {
              if (_letGoCurl()) return;
              final moved = e.position - _downAt;
              if (!widget.annotationMode &&
                  moved.dx.abs() > 40 &&
                  moved.dx.abs() > moved.dy.abs()) {
                // 仿真 has no sliding pages: a swipe the curl could not
                // take turns the page at once.
                if (_curlMode) {
                  turn(moved.dx < 0 ? 1 : -1);
                } else if (moved.dx < 0 && _downPage >= _pages.length - 1) {
                  turn(1);
                } else if (moved.dx > 0 && _downPage <= 0) {
                  turn(-1);
                }
                return;
              }
              if (!widget.annotationMode && moved.distance < 12) {
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final (page, key) in _neighbours)
                  IgnorePointer(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        key: key,
                        // On paper, for a picture of it to turn (_startCurl).
                        child: ColoredBox(
                          color: t.background,
                          child: Padding(
                            padding: widget.padding,
                            child: _PageView(
                              page: page,
                              settings: widget.settings,
                              theme: t,
                              reader: widget.reader,
                              annotationMode: false,
                              plain: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                RepaintBoundary(
                  key: _currentKey,
                  child: ColoredBox(
                    color: t.background,
                    child: _pageView(context, t),
                  ),
                ),
                if (_curl case final curl?)
                  IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: PageCurlPainter(curl, t.background),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pageView(BuildContext context, ReadingTheme t) => ScrollConfiguration(
    // Desktops exclude mouse dragging from scrollables by default; a page you
    // cannot drag with the mouse feels broken.
    behavior: ScrollConfiguration.of(
      context,
    ).copyWith(dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse}),
    child: NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        if (n.depth == 0) _readyAround();
        return false;
      },
      child: PageView.builder(
        key: ValueKey(_signature),
        controller: _ctrl,
        // 仿真: the finger turns the page over (_dragCurl), never slides it.
        physics: _curlMode ? const NeverScrollableScrollPhysics() : null,
        itemCount: _pages.length,
        onPageChanged: (i) {
          _topPara = _pages[i].firstPara;
          _topStart = _pages[i].firstStart;
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
            spoken: widget.tts,
          ),
        ),
      ),
    ),
  );
}

class _PageView extends StatelessWidget {
  final BookPage page;
  final ReadingSettings settings;
  final ReadingTheme theme;
  final ReaderState reader;
  final bool annotationMode;
  final ValueChanged<AnnotationDraft?>? onAnnotationSelection;

  /// Text only, for a page that may belong to another chapter than the
  /// reader's paragraphs: no annotation tags.
  final bool plain;

  /// The sentence being spoken is shown the way the scrolling reader shows it.
  final TtsController? spoken;

  const _PageView({
    required this.page,
    required this.settings,
    required this.theme,
    required this.reader,
    required this.annotationMode,
    this.onAnnotationSelection,
    this.plain = false,
    this.spoken,
  });

  /// [c]'s text as it was measured, justified: the indent in no colour, and a
  /// chunk cut off at the page's foot laid out with the rest of its paragraph
  /// so its last line is justified like the others. The spoken sentence is
  /// marked with a background only: the lines must break where pagination
  /// measured them.
  Widget _text(PageChunk c, TextStyle style) {
    final lead = c.leadingNonSource;
    final body = c.text.substring(lead);
    final spans = <TextSpan>[
      if (lead > 0)
        TextSpan(text: c.text.substring(0, lead), style: indentStyle),
    ];
    final tts = spoken;
    if (c.kind == ParaKind.body &&
        tts != null &&
        tts.activeParagraph == c.paraIndex &&
        tts.activeEnd > c.sourceStart &&
        tts.activeStart < c.sourceEnd) {
      int at(int source) => (source - c.sourceStart).clamp(0, body.length);
      final a = at(math.max(tts.activeStart, c.sourceStart));
      final b = at(math.min(tts.activeEnd, c.sourceEnd));
      spans
        ..add(TextSpan(text: body.substring(0, a)))
        ..add(
          TextSpan(
            text: body.substring(a, b),
            style: TextStyle(
              backgroundColor: theme.text.withValues(alpha: 0.13),
            ),
          ),
        )
        ..add(TextSpan(text: body.substring(b)));
    } else {
      spans.add(TextSpan(text: body));
    }
    if (c.tail.isNotEmpty) spans.add(TextSpan(text: c.tail));
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: TextAlign.justify,
      maxLines: c.tail.isEmpty ? null : c.lines,
      overflow: TextOverflow.clip,
      semanticsLabel: body,
    );
  }

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
          child: _text(c, ty.style(c.kind)),
        ),
        ParaKind.body => _text(c, ty.style(c.kind)),
        _ => Text(c.text, style: ty.style(c.kind)),
      };
      final text = annotationMode && c.kind == ParaKind.body
          ? SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: c.text.substring(0, c.leadingNonSource),
                    style: indentStyle,
                  ),
                  TextSpan(text: c.text.substring(c.leadingNonSource)),
                ],
              ),
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
      final annotations = c.endsParagraph && !plain
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
    // Whatever measuring got wrong stays on its own page instead of spilling
    // into the margin under it.
    return ClipRect(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: page.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}
