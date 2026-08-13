import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'annotation_page.dart';
import 'ai_runtime_page.dart';
import 'book_detail_page.dart';
import 'font_manager.dart';
import 'font_page.dart';
import 'paged_reader.dart';
import 'platform_services.dart';
import 'reading_assistant_drawer.dart';
import 'platform_support.dart';
import 'reader_state.dart';
import 'search_page.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';
import 'toc_drawer.dart';
import 'tts_controller.dart';
import 'tts_text.dart';
import 'tts_server_page.dart';

class ReaderPage extends StatefulWidget {
  final ReaderState reader;
  final ReadingSettings settings;
  final ValueChanged<ShelfItem?> onBack;
  final LocalSpeechSynthesizer? localSpeech;
  final bool enableTtsIo;

  const ReaderPage({
    super.key,
    required this.reader,
    required this.settings,
    required this.onBack,
    this.localSpeech,
    this.enableTtsIo = true,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _pagedKey = GlobalKey<PagedReaderState>();

  /// (current page, pages in chapter), fed by the paged reader. A notifier so
  /// only the bottom-bar text rebuilds on every page turn.
  final _pageInfo = ValueNotifier<(int, int)>((1, 1));

  late final TtsController _tts;

  bool get _isPaged => widget.settings.pageMode == PageMode.paged;

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_onScroll);
    _tts = TtsController(
      widget.reader,
      widget.settings,
      localSpeech: widget.localSpeech,
      enableIo: widget.enableTtsIo,
    );
    _tts.addListener(_onTtsTick);
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onScroll);
    _tts.removeListener(_onTtsTick);
    _tts.dispose();
    _pageInfo.dispose();
    super.dispose();
  }

  /// The last paragraph we scrolled to. The controller also notifies as
  /// background synthesis finishes sentences, which must not re-trigger a
  /// scroll — only a genuine change of spoken paragraph does.
  int _followed = -1;
  int _observedChapter = -1;
  bool _atChapterEnd = false;
  bool _closing = false;
  bool _annotationMode = false;
  AnnotationDraft? _annotationDraft;
  bool _chromeVisible = true;

  void _toggleChrome() {
    if (_annotationMode) return;
    setState(() => _chromeVisible = !_chromeVisible);
  }

  /// Follow the spoken paragraph: scroll it into view (scroll mode only; the
  /// paged reader paginates independently).
  void _onTtsTick() {
    final msg = _tts.notice;
    if (msg != null) {
      _tts.clearNotice();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            action: SnackBarAction(label: '设置', onPressed: _openTtsSettings),
          ),
        );
      }
    }
    final i = _tts.activeParagraph;
    if (i == _followed) return;
    _followed = i;
    if (_isPaged || i < 0 || !_itemScroll.isAttached) return;
    _itemScroll.scrollTo(
      index: i,
      alignment: 0.35,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// Voice, pace and server all live on one page, because they are one decision:
  /// where the reading voice comes from.
  Future<void> _openTtsSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TtsServerPage(settings: widget.settings),
      ),
    );
    await _tts.onVoiceOrSpeedChanged();
  }

  Future<void> _toggleTts() async {
    try {
      await _tts.toggle();
    } catch (e) {
      if (!mounted) return;
      // Only reachable on the local fallback: with no engine installed and no
      // server set up, there is no voice at all, and either fix is a page away.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          action: SnackBarAction(label: '去设置', onPressed: _openTtsSettings),
        ),
      );
    }
  }

  ShelfItem? get _currentBook {
    final id = widget.reader.info?.id;
    for (final book in widget.reader.shelf) {
      if (book.id == id) return book;
    }
    return null;
  }

  void _openPage(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  void _openAppearance() {
    final t = widget.settings.theme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.background,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.88,
          child: SettingsSheet(settings: widget.settings),
        ),
      ),
    );
  }

  Future<void> _openAnnotations() async {
    final start = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AnnotationPage(reader: widget.reader, settings: widget.settings),
      ),
    );
    if (start == true && mounted) {
      if (_tts.playing || _tts.hasQueue) await _tts.stop();
      setState(() {
        _annotationMode = true;
        _annotationDraft = null;
        _chromeVisible = true;
      });
    }
  }

  void _setAnnotationDraft(AnnotationDraft? draft) {
    if (!_annotationMode || _annotationDraft == draft) return;
    setState(() => _annotationDraft = draft);
  }

  void _exitAnnotationMode() {
    if (!_annotationMode) return;
    setState(() {
      _annotationMode = false;
      _annotationDraft = null;
      _chromeVisible = true;
    });
  }

  Future<void> _saveAnnotationDraft() async {
    final draft = _annotationDraft;
    if (draft == null) return;
    await showAnnotationEditor(
      context,
      reader: widget.reader,
      settings: widget.settings,
      paragraph: draft.paragraph,
      draft: draft,
    );
    if (mounted) setState(() => _annotationDraft = null);
  }

  void _openBookDetail() {
    final book = _currentBook;
    if (book == null) return;
    _openPage(
      BookDetailPage(
        book: book,
        reader: widget.reader,
        settings: widget.settings,
        onRead: (chapter, offset) async {
          if (chapter != null) {
            if (offset == null) {
              await widget.reader.goToChapter(chapter);
            } else {
              await widget.reader.goToOffset(chapter, offset);
            }
          }
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  /// Chapter navigation by hand invalidates the read-aloud queue, so stop it.
  void _navChapter(void Function() go) {
    if (_tts.playing) _tts.stop();
    go();
  }

  Future<void> _nextChapter() async {
    if (_tts.playing) await _tts.stop();
    await widget.reader.next();
  }

  void _onScroll() {
    final visible = _positions.itemPositions.value;
    if (visible.isEmpty) return;
    if (_observedChapter != widget.reader.chapterIndex) {
      _observedChapter = widget.reader.chapterIndex;
      _atChapterEnd = false;
    }
    final last = widget.reader.paragraphs.length - 1;
    _atChapterEnd =
        last >= 0 &&
        visible.any(
          (position) =>
              position.index == last && position.itemTrailingEdge <= 1.02,
        );
    final atChapterStart = visible.any(
      (position) => position.index == 0 && position.itemLeadingEdge >= -0.02,
    );
    unawaited(
      widget.reader.recordChapterViewport(
        atStart: atChapterStart,
        atEnd: _atChapterEnd,
      ),
    );
    final top = visible
        .where((p) => p.itemTrailingEdge > 0)
        .reduce((a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b);
    widget.reader.onVisibleParagraph(top.index);
  }

  /// Scroll by 90% of a viewport — the 10% overlap keeps one line of context,
  /// which is what lets the eye pick up where it left off. Expressed as an
  /// alignment shift on the top visible item, so it works whatever the
  /// paragraph heights are.
  void _page(int dir) {
    if (_isPaged) {
      _pagedKey.currentState?.turn(dir);
      return;
    }
    final visible = _positions.itemPositions.value;
    if (visible.isEmpty || !_itemScroll.isAttached) return;
    final top = visible
        .where((p) => p.itemTrailingEdge > 0)
        .reduce((a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b);
    _itemScroll.scrollTo(
      index: top.index,
      alignment: top.itemLeadingEdge - dir * 0.9,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _back() async {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
      return;
    }
    if (scaffold?.isEndDrawerOpen == true) {
      scaffold!.closeEndDrawer();
      return;
    }
    if (_annotationMode) {
      _exitAnnotationMode();
      return;
    }
    if (_closing) return;
    _closing = true;
    final bookBeforeClose = _currentBook;
    await _tts.stop();
    await widget.reader.closeCurrent();
    final book = bookBeforeClose == null
        ? null
        : widget.reader.shelf.cast<ShelfItem?>().firstWhere(
            (item) => item?.id == bookBeforeClose.id,
            orElse: () => bookBeforeClose,
          );
    widget.onBack(book);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.pageDown) {
      _page(1);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _page(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      // Arrows follow the mode: pages when reading by pages, chapters when
      // scrolling (where space already pages).
      _isPaged ? _page(1) : unawaited(_nextChapter());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _isPaged ? _page(-1) : _navChapter(widget.reader.prev);
    } else if (key == LogicalKeyboardKey.escape && e is KeyDownEvent) {
      _annotationMode ? _exitAnnotationMode() : _back();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _readerIconButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required bool compact,
  }) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon),
    color: color,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: compact ? 40 : 48, height: 48),
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
  );

  Widget _ttsMenu(ReadingTheme t, {required bool compact}) => ListenableBuilder(
    listenable: _tts,
    builder: (context, _) => SizedBox(
      width: compact ? 40 : 48,
      child: PopupMenuButton<String>(
        tooltip: '听书',
        padding: EdgeInsets.zero,
        icon: Icon(
          _tts.playing
              ? Icons.headset_off_outlined
              : Icons.headset_mic_outlined,
          color: _tts.playing ? t.text : t.muted,
        ),
        onSelected: (value) =>
            value == 'play' ? _toggleTts() : _openTtsSettings(),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'play',
            child: Text(_tts.playing ? '暂停朗读' : '收听本章'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'settings', child: Text('听书设置…')),
        ],
      ),
    ),
  );

  Widget _narrowReaderMenu(ReadingTheme t) => ListenableBuilder(
    listenable: _tts,
    builder: (context, _) => SizedBox(
      width: 40,
      child: PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_horiz, color: t.muted),
        onSelected: (value) {
          switch (value) {
            case 'annotations':
              _openAnnotations();
              return;
            case 'tts':
              _toggleTts();
              return;
            case 'ttsSettings':
              _openTtsSettings();
              return;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'annotations',
            child: ListTile(
              leading: Icon(Icons.comment_outlined),
              title: Text('标注'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'tts',
            child: ListTile(
              leading: Icon(
                _tts.playing
                    ? Icons.headset_off_outlined
                    : Icons.headset_mic_outlined,
              ),
              title: Text(_tts.playing ? '暂停朗读' : '收听本章'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'ttsSettings',
            child: ListTile(
              leading: Icon(Icons.tune),
              title: Text('听书设置'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return ListenableBuilder(
      listenable: widget.reader,
      builder: (context, _) {
        final info = widget.reader.info;
        if (info == null) return const SizedBox.shrink();
        final width = MediaQuery.sizeOf(context).width;
        final compact =
            AppPlatformSupport.layoutForWidth(width) == AppLayoutClass.compact;
        final narrow = width < 380;
        final showControls = !compact || _chromeVisible || _annotationMode;
        final readerPadding = EdgeInsets.fromLTRB(
          compact ? 20 : 28,
          compact ? 12 : 20,
          compact ? 20 : 28,
          compact ? 28 : 40,
        );
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _back();
          },
          child: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: Scaffold(
              key: _scaffoldKey,
              appBar: showControls
                  ? AppBar(
                      backgroundColor: t.background,
                      surfaceTintColor: Colors.transparent,
                      elevation: 0,
                      titleSpacing: compact ? 0 : null,
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _back,
                      ),
                      title: Text(
                        info.chapters[widget.reader.chapterIndex].title,
                        style: TextStyle(
                          color: t.text,
                          fontSize: compact ? 13.5 : 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      iconTheme: IconThemeData(color: t.muted),
                      actions: [
                        if (narrow)
                          _narrowReaderMenu(t)
                        else ...[
                          _readerIconButton(
                            tooltip: '标注',
                            icon: Icons.comment_outlined,
                            color: widget.reader.annotations.isEmpty
                                ? t.muted
                                : t.text,
                            onPressed: _openAnnotations,
                            compact: compact,
                          ),
                          _ttsMenu(t, compact: compact),
                        ],
                        Builder(
                          builder: (ctx) => _readerIconButton(
                            tooltip: '目录',
                            icon: Icons.list,
                            color: t.muted,
                            onPressed: () => Scaffold.of(ctx).openDrawer(),
                            compact: compact,
                          ),
                        ),
                        Builder(
                          builder: (ctx) => _readerIconButton(
                            tooltip: '阅读助手',
                            icon: Icons.auto_awesome_outlined,
                            color: t.muted,
                            onPressed: () => Scaffold.of(ctx).openEndDrawer(),
                            compact: compact,
                          ),
                        ),
                      ],
                    )
                  : null,
              drawer: TocDrawer(
                reader: widget.reader,
                settings: widget.settings,
              ),
              endDrawer: ReadingAssistantDrawer(
                reader: widget.reader,
                settings: widget.settings,
                onSearch: () => _openPage(
                  SearchPage(reader: widget.reader, settings: widget.settings),
                ),
                onBookDetail: _openBookDetail,
                onAppearance: _openAppearance,
                onAiRuntime: () => _openPage(
                  AiRuntimePage(
                    settings: widget.settings,
                    reader: widget.reader,
                  ),
                ),
              ),
              body: SafeArea(
                top: !showControls,
                bottom: !showControls,
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: widget.settings.pageWidth,
                    ),
                    child: _isPaged
                        ? PagedReader(
                            key: _pagedKey,
                            reader: widget.reader,
                            settings: widget.settings,
                            padding: readerPadding,
                            pageInfo: _pageInfo,
                            annotationMode: _annotationMode,
                            onAnnotationSelection: _setAnnotationDraft,
                            compactTapZones: compact,
                            onToggleControls: _toggleChrome,
                          )
                        // The list is rebuilt per chapter and opens directly on the
                        // restored paragraph: scrolling to it after building would be
                        // a visible jump.
                        : GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: compact && !_annotationMode
                                ? _toggleChrome
                                : null,
                            child: ListenableBuilder(
                              listenable: _tts,
                              builder: (context, _) =>
                                  ScrollablePositionedList.builder(
                                    key: ValueKey(widget.reader.chapterIndex),
                                    initialScrollIndex:
                                        widget.reader.initialParagraph,
                                    itemScrollController: _itemScroll,
                                    itemPositionsListener: _positions,
                                    padding: readerPadding.copyWith(bottom: 60),
                                    itemCount: widget.reader.paragraphs.length,
                                    itemBuilder: (context, i) => ParagraphView(
                                      para: widget.reader.paragraphs[i],
                                      settings: widget.settings,
                                      theme: t,
                                      active: _tts.activeParagraph == i,
                                      activeStart: _tts.activeParagraph == i
                                          ? _tts.activeStart
                                          : -1,
                                      onTapSentence: compact
                                          ? null
                                          : (start) =>
                                                _tts.seekToSentence(i, start),
                                      annotations: widget.reader
                                          .annotationsForParagraph(
                                            widget.reader.paragraphs[i],
                                          ),
                                      onShowAnnotations: (annotations) =>
                                          showAnnotationComments(
                                            context,
                                            reader: widget.reader,
                                            settings: widget.settings,
                                            paragraph:
                                                widget.reader.paragraphs[i],
                                            annotations: annotations,
                                          ),
                                      annotationMode: _annotationMode,
                                      annotationChapter:
                                          widget.reader.chapterIndex,
                                      onAnnotationSelection:
                                          _setAnnotationDraft,
                                    ),
                                  ),
                            ),
                          ),
                  ),
                ),
              ),
              bottomNavigationBar: showControls
                  ? SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListenableBuilder(
                            listenable: _tts,
                            builder: (context, _) => _tts.hasQueue
                                ? _ttsBar(t)
                                : const SizedBox.shrink(),
                          ),
                          _annotationMode
                              ? _annotationBar(t)
                              : _bottomBar(info, t),
                        ],
                      ),
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }

  Widget _annotationBar(ReadingTheme t) {
    final selected = _annotationDraft != null;
    return Material(
      color: t.background,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: t.muted.withValues(alpha: 0.16)),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.text_fields, size: 17, color: t.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selected ? '已选择正文' : '拖动选择要标注的文字',
                  style: TextStyle(color: t.muted, fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: _exitAnnotationMode,
                child: const Text('退出'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: selected ? _saveAnnotationDraft : null,
                child: const Text('添加标注'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The read-aloud strip: it stays up while a chapter is queued, not just while
  /// sound is coming out, so pause leaves the position and the progress bar
  /// where they were. Play/pause, a sentence-level progress bar whose secondary
  /// track shows how far synthesis has run ahead of the voice, a speed cycle,
  /// and a stop that dismisses it.
  Widget _ttsBar(ReadingTheme t) {
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final total = _tts.total;
    final pos = _tts.position.clamp(0, total > 0 ? total - 1 : 0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: t.background,
        border: Border(top: BorderSide(color: t.muted.withValues(alpha: 0.15))),
      ),
      child: Row(
        children: [
          // While waiting on synthesis the button becomes a spinner in place:
          // the silence is explained without the strip changing shape.
          _tts.buffering
              ? const SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : IconButton(
                  tooltip: _tts.playing ? '暂停' : '继续',
                  icon: Icon(_tts.playing ? Icons.pause : Icons.play_arrow),
                  color: t.text,
                  onPressed: _tts.toggle,
                ),
          Expanded(
            child: total > 1
                ? SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      activeTrackColor: t.text.withValues(alpha: 0.7),
                      inactiveTrackColor: t.muted.withValues(alpha: 0.25),
                      // How far synthesis has run ahead of the voice.
                      secondaryActiveTrackColor: t.muted.withValues(
                        alpha: 0.55,
                      ),
                      thumbColor: t.text,
                    ),
                    child: Slider(
                      value: pos.toDouble(),
                      min: 0,
                      max: (total - 1).toDouble(),
                      secondaryTrackValue: (_tts.bufferedFraction * (total - 1))
                          .toDouble(),
                      onChanged: (v) => _tts.seekTo(v.round()),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Text(
            '${pos + 1} / $total',
            style: TextStyle(color: t.muted, fontSize: 12),
          ),
          TextButton(
            onPressed: () {
              final i = speeds.indexOf(widget.settings.ttsSpeed);
              widget.settings.setTtsSpeed(speeds[(i + 1) % speeds.length]);
              _tts.onVoiceOrSpeedChanged();
            },
            child: Text(
              '${_tts.speed}×',
              style: TextStyle(color: t.muted, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: '听书设置',
            icon: const Icon(Icons.tune, size: 20),
            color: t.muted,
            onPressed: _openTtsSettings,
          ),
          IconButton(
            tooltip: '停止朗读',
            icon: const Icon(Icons.close),
            color: t.muted,
            onPressed: _tts.stop,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BookInfo info, ReadingTheme t) {
    final r = widget.reader;
    final i = r.chapterIndex;
    final n = info.chapters.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: t.background,
      child: Row(
        children: [
          IconButton(
            tooltip: '上一章',
            icon: const Icon(Icons.chevron_left),
            color: t.muted,
            onPressed: i > 0 ? () => _navChapter(r.prev) : null,
          ),
          Expanded(
            // Paged mode counts where you are in the chapter; chapter position
            // already lives in the title and the TOC.
            child: _isPaged
                ? ValueListenableBuilder(
                    valueListenable: _pageInfo,
                    builder: (context, (int, int) p, _) => Text(
                      '本章 ${p.$1} / ${p.$2} 页',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.muted, fontSize: 12),
                    ),
                  )
                : Text(
                    '${i + 1} / $n   ·   ${info.encoding}'
                    '${info.interstitialCount > 0 ? '   ·   插页 ${info.interstitialCount}' : ''}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted, fontSize: 12),
                  ),
          ),
          _Clock(theme: t),
          IconButton(
            tooltip: i < n - 1
                ? '下一章'
                : r.isChapterCompleted(i)
                ? '已读完'
                : '本书末章',
            icon: Icon(
              i < n - 1
                  ? Icons.chevron_right
                  : r.isChapterCompleted(i)
                  ? Icons.check_circle
                  : Icons.check_circle_outline,
            ),
            color: t.muted,
            onPressed: i < n - 1 ? _nextChapter : null,
          ),
        ],
      ),
    );
  }
}

/// Time in the reader's eye line, because fullscreen reading hides the system
/// clock — on the phone builds it hides the status bar's battery too, so the
/// Android version must extend this with a battery indicator (battery_plus).
class _Clock extends StatefulWidget {
  final ReadingTheme theme;

  const _Clock({required this.theme});

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '$hh:$mm',
        style: TextStyle(color: widget.theme.muted, fontSize: 12),
      ),
    );
  }
}

class ParagraphView extends StatefulWidget {
  final Paragraph para;
  final ReadingSettings settings;
  final ReadingTheme theme;

  /// This paragraph contains the sentence read-aloud is voicing.
  final bool active;

  /// Start offset of that sentence within [para]`.text`, or -1. Body text is
  /// laid out as one span per sentence, so the highlight lands on the sentence
  /// being spoken rather than the whole paragraph.
  final int activeStart;

  /// Tapping a sentence jumps read-aloud to it.
  final void Function(int segStart)? onTapSentence;
  final List<BookAnnotation> annotations;
  final ValueChanged<List<BookAnnotation>>? onShowAnnotations;
  final bool annotationMode;
  final int annotationChapter;
  final ValueChanged<AnnotationDraft?>? onAnnotationSelection;

  const ParagraphView({
    super.key,
    required this.para,
    required this.settings,
    required this.theme,
    this.active = false,
    this.activeStart = -1,
    this.onTapSentence,
    this.annotations = const [],
    this.onShowAnnotations,
    this.annotationMode = false,
    this.annotationChapter = 0,
    this.onAnnotationSelection,
  });

  @override
  State<ParagraphView> createState() => _ParagraphViewState();
}

class _ParagraphViewState extends State<ParagraphView> {
  /// One recognizer per sentence span. Recognizers are not garbage-collected by
  /// the framework, so they are rebuilt and disposed with the spans.
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    _disposeTaps();
    super.dispose();
  }

  void _disposeTaps() {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
  }

  Paragraph get para => widget.para;
  ReadingSettings get settings => widget.settings;
  ReadingTheme get theme => widget.theme;
  bool get active => widget.active;

  @override
  Widget build(BuildContext context) {
    final content = _content();
    final child = content;
    // Body paragraphs carry the highlight on the spoken sentence itself; the
    // rest (title, notes) have no sentence spans, so they highlight whole.
    if (!active || para.kind == ParaKind.body) return child;
    return Container(
      decoration: BoxDecoration(
        color: theme.text.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: theme.text.withValues(alpha: 0.5), width: 3),
        ),
      ),
      child: child,
    );
  }

  /// Split the body into one span per sentence: the spoken one gets a soft
  /// background, and every one of them is tappable to seek there. The ranges
  /// come from the same splitter the player queues from, so a tap maps to
  /// exactly one utterance.
  List<InlineSpan> _sentenceSpans() {
    _disposeTaps();
    final text = para.text;
    final spans = <InlineSpan>[];
    if (settings.firstLineIndent) {
      spans.add(const TextSpan(text: '　　'));
    }
    for (final seg in sentenceSegments(text)) {
      final tap = widget.onTapSentence == null
          ? null
          : (TapGestureRecognizer()
              ..onTap = () => widget.onTapSentence?.call(seg.start));
      if (tap != null) _taps.add(tap);
      spans.add(
        TextSpan(
          text: text.substring(seg.start, seg.end),
          recognizer: tap,
          style: active && seg.start == widget.activeStart
              ? TextStyle(
                  backgroundColor: theme.text.withValues(alpha: 0.13),
                  color: theme.text,
                )
              : null,
        ),
      );
    }
    return spans;
  }

  Widget _content() {
    switch (para.kind) {
      case ParaKind.title:
        return Padding(
          padding: const EdgeInsets.only(bottom: 24, top: 8),
          child: Text(
            para.text,
            style: TextStyle(
              color: theme.text,
              fontFamily: settings.fontFamily.isEmpty
                  ? null
                  : settings.fontFamily,
              fontSize: settings.fontSize + 4,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
        );

      case ParaKind.volume:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: Text(
              para.text,
              style: TextStyle(
                color: theme.muted,
                fontFamily: settings.fontFamily.isEmpty
                    ? null
                    : settings.fontFamily,
                fontSize: settings.fontSize + 1,
                letterSpacing: 3,
              ),
            ),
          ),
        );

      // Author notes and site ads sit flush against the margin exactly like a
      // chapter title, so shape alone cannot tell them apart. They are shown —
      // readers followed these books for years and the notes are part of what
      // they read — but set apart, so they never read as story.
      case ParaKind.interstitial:
        return Container(
          margin: EdgeInsets.only(bottom: settings.paragraphSpacing),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.muted.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
          ),
          child: Text(
            para.text,
            style: TextStyle(
              color: theme.muted,
              fontFamily: settings.fontFamily.isEmpty
                  ? null
                  : settings.fontFamily,
              fontSize: settings.fontSize - 2,
              fontStyle: FontStyle.italic,
              height: settings.lineHeight,
            ),
          ),
        );

      case ParaKind.body:
        final textStyle = TextStyle(
          color: theme.text,
          fontFamily: settings.fontFamily.isEmpty ? null : settings.fontFamily,
          fontSize: settings.fontSize,
          height: settings.lineHeight,
        );
        final text = widget.annotationMode
            ? SelectableText(
                '${settings.firstLineIndent ? '　　' : ''}${para.text}',
                style: textStyle,
                onSelectionChanged: (selection, _) {
                  final indent = settings.firstLineIndent ? 2 : 0;
                  final start = (selection.start - indent).clamp(
                    0,
                    para.text.length,
                  );
                  final end = (selection.end - indent).clamp(
                    0,
                    para.text.length,
                  );
                  if (selection.isCollapsed || end <= start) {
                    widget.onAnnotationSelection?.call(null);
                    return;
                  }
                  widget.onAnnotationSelection?.call(
                    AnnotationDraft(
                      chapter: widget.annotationChapter,
                      paragraph: para,
                      start: start,
                      end: end,
                    ),
                  );
                },
              )
            : Text.rich(TextSpan(children: _sentenceSpans()), style: textStyle);
        return Padding(
          padding: EdgeInsets.only(bottom: settings.paragraphSpacing),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              if (widget.annotations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () =>
                        widget.onShowAnnotations?.call(widget.annotations),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 9,
                            color: theme.muted,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${widget.annotations.length}',
                            style: TextStyle(color: theme.muted, fontSize: 9),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
    }
  }
}

class SettingsSheet extends StatelessWidget {
  final ReadingSettings settings;

  const SettingsSheet({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final t = settings.theme;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('翻页方式', style: TextStyle(color: t.muted, fontSize: 12)),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final (mode, label) in [
                    (PageMode.scroll, '上下滚动'),
                    (PageMode.paged, '左右翻页'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: ChoiceChip(
                        label: Text(
                          label,
                          style: const TextStyle(fontSize: 13),
                        ),
                        selected: settings.pageMode == mode,
                        onSelected: (_) => settings.setPageMode(mode),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('背景', style: TextStyle(color: t.muted, fontSize: 12)),
              const SizedBox(height: 10),
              ThemeSwatches(settings: settings),
              const SizedBox(height: 20),
              Text('字体', style: TextStyle(color: t.muted, fontSize: 12)),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: 46,
                leading: Icon(Icons.font_download_outlined, color: t.muted),
                title: Text(
                  FontManager.instance.displayNameForFamily(
                    settings.fontFamily,
                  ),
                  style: TextStyle(color: t.text, fontSize: 14),
                ),
                subtitle: Text(
                  '按需下载或导入本地字体',
                  style: TextStyle(color: t.muted, fontSize: 11),
                ),
                trailing: Icon(Icons.chevron_right, color: t.muted),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FontPage(settings: settings),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '字号 ${settings.fontSize.toInt()}',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
              Slider(
                value: settings.fontSize,
                min: 12,
                max: 34,
                divisions: 22,
                onChanged: settings.setFontSize,
              ),
              Text(
                '行距 ${settings.lineHeight.toStringAsFixed(1)}',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
              Slider(
                value: settings.lineHeight,
                min: 1.2,
                max: 2.6,
                divisions: 14,
                onChanged: settings.setLineHeight,
              ),
              Text(
                '页宽 ${settings.pageWidth.toInt()}',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
              Slider(
                value: settings.pageWidth,
                min: 520,
                max: 1080,
                divisions: 14,
                onChanged: settings.setPageWidth,
              ),
              Text(
                '段距 ${settings.paragraphSpacing.toInt()}',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
              Slider(
                value: settings.paragraphSpacing,
                min: 0,
                max: 32,
                divisions: 16,
                onChanged: settings.setParagraphSpacing,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  '首行缩进',
                  style: TextStyle(color: t.muted, fontSize: 13),
                ),
                value: settings.firstLineIndent,
                onChanged: settings.setFirstLineIndent,
              ),
            ],
          ),
        );
      },
    );
  }
}
