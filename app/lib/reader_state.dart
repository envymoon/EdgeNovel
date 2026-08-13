import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_runtime.dart';
import 'reading_session_store.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';

enum _AiTaskKind { enrich, semanticIndex }

T? _firstOrNull<T>(Iterable<T> values) {
  for (final value in values) {
    return value;
  }
  return null;
}

class _AiQueuedTask {
  _AiQueuedTask({
    required this.kind,
    required this.bookId,
    required this.path,
    required this.title,
    this.paused = false,
    this.failed = false,
  });

  final _AiTaskKind kind;
  final int bookId;
  final String path;
  final String title;
  bool paused;
  bool failed;

  String get label => kind == _AiTaskKind.enrich ? '章节摘要' : '语义索引';

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'bookId': bookId,
    'path': path,
    'title': title,
    'paused': paused,
    'failed': failed,
  };

  static _AiQueuedTask? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final path = value['path'];
    final title = value['title'];
    final bookId = value['bookId'];
    if (path is! String || title is! String || bookId is! int) return null;
    return _AiQueuedTask(
      kind:
          value['kind'] == _AiTaskKind.semanticIndex.name ||
              value['kind'] == 'index'
          ? _AiTaskKind.semanticIndex
          : _AiTaskKind.enrich,
      bookId: bookId,
      path: path,
      title: title,
      paused: value['paused'] == true,
      failed: value['failed'] == true,
    );
  }
}

/// Holds what the reader is showing. The book itself stays in Rust; this only
/// remembers where we are and caches the paragraphs of the chapter on screen.
class ReaderState extends ChangeNotifier {
  ReaderState({AiRuntimeSettings? aiRuntime, this.readingSessionStore})
    : aiRuntime = aiRuntime ?? AiRuntimeSettings.instance;

  static const _queueKey = 'aiRuntime.queue.v1';
  final AiRuntimeSettings aiRuntime;
  final ReadingSessionStore? readingSessionStore;

  List<ShelfItem> shelf = const [];
  BookInfo? info;
  int chapterIndex = 0;
  List<Paragraph> paragraphs = const [];
  List<BookAnnotation> annotations = const [];
  Set<int> completedChapters = const {};
  String? error;
  bool loading = false;

  /// Byte offset of the topmost paragraph on screen. Saved as progress, and the
  /// only thing that survives a better paragraph splitter.
  int _offset = 0;
  int _coverageChapter = -1;
  bool _sawChapterStart = false;
  final Set<int> _completionInFlight = {};

  /// The offset progress was restored to. Consumed by [_load], which turns it
  /// into [initialParagraph] before the reader builds — restoring by scrolling
  /// after the fact is a visible jump.
  int? _pendingOffset;

  /// The paragraph the current chapter should open on: 0 normally, the reading
  /// position when a book was just reopened.
  int initialParagraph = 0;

  int _sessionStart = 0;
  int _sessionStartOffset = 0;
  Timer? _saveDebounce;
  Future<void> _progressWrites = Future<void>.value();
  int _navigationRevision = 0;
  int? _pendingChapterIndex;

  bool get isOpen => info != null;
  int get currentOffset => _offset;
  Paragraph? get currentParagraph {
    if (paragraphs.isEmpty) return null;
    final index = paragraphs.lastIndexWhere((p) => p.start <= _offset);
    return paragraphs[index < 0 ? 0 : index];
  }

  List<BookAnnotation> annotationsForChapter(int chapter) => annotations
      .where((annotation) => annotation.chapter == chapter)
      .toList(growable: false);

  List<BookAnnotation> annotationsForParagraph(Paragraph paragraph) =>
      annotations
          .where(
            (annotation) =>
                annotation.chapter == chapterIndex &&
                annotation.start >= paragraph.start &&
                annotation.start < paragraph.end,
          )
          .toList(growable: false);

  bool isChapterCompleted(int chapter) => completedChapters.contains(chapter);

  // ── Unified AI background queue ─────────────────────────────────────────
  // The queue is owned by app state, not a page. It is persisted separately
  // from generated data, and every Rust task still checkpoints each chapter.
  final List<_AiQueuedTask> _aiQueue = [];
  _AiQueuedTask? _activeAiTask;
  SharedPreferences? _queuePrefs;
  Timer? _aiMonitor;
  Timer? _engineIdleTimer;
  bool _schedulerBusy = false;
  bool _readingActive = false;
  bool _aiExecutionAllowed = true;
  bool _pauseRequested = false;
  String? _pauseReason;
  bool _forceNext = false;
  bool _activeForced = false;
  int _engineRevision = 0;
  bool _restartEngineAfterPause = false;
  AiDeviceState? aiDevice;
  String? aiWaitingReason;

  StreamSubscription<EnrichProgress>? _enrichSub;
  EnrichProgress? enrichProgress;
  String? enrichingTitle;
  String? _enrichingPath;
  String? enrichError;

  bool get enriching => _enrichSub != null;
  bool get enrichQueued =>
      _aiQueue.any((task) => task.kind == _AiTaskKind.enrich);
  bool get indexQueued =>
      _aiQueue.any((task) => task.kind == _AiTaskKind.semanticIndex);
  bool get enrichPaused => _aiQueue.any(
    (task) => task.kind == _AiTaskKind.enrich && (task.paused || task.failed),
  );
  bool get indexPaused => _aiQueue.any(
    (task) =>
        task.kind == _AiTaskKind.semanticIndex && (task.paused || task.failed),
  );
  bool get aiBusy => _activeAiTask != null;
  int get aiQueuedCount => _aiQueue.length;
  bool get aiHasFailed => _aiQueue.any((task) => task.failed);
  bool get aiHasPaused => _aiQueue.any((task) => task.paused);
  String get aiQueueState {
    final active = _activeAiTask;
    if (active != null) return '正在${active.label}';
    if (_aiQueue.isEmpty) return '当前没有后台任务';
    if (aiHasFailed) return '有任务失败，等待重试';
    if (_aiQueue.every((task) => task.paused)) return '任务已暂停';
    return aiWaitingReason ?? '等待运行';
  }

  String? get aiQueueDetail {
    final active = _activeAiTask;
    if (active != null) return '${active.title} · ${active.label}';
    if (_aiQueue.isEmpty) return null;
    final next = _aiQueue.first;
    return '${next.title} · ${next.label} · 共 ${_aiQueue.length} 项';
  }

  Future<void> initializeAiQueue({bool readingActive = false}) async {
    _readingActive = readingActive;
    _queuePrefs = await SharedPreferences.getInstance();
    final raw = _queuePrefs?.getString(_queueKey);
    if (raw != null) {
      try {
        final values = jsonDecode(raw);
        if (values is List) {
          _aiQueue.addAll(values.map(_AiQueuedTask.fromJson).whereType());
        }
      } catch (_) {
        // A malformed queue is disposable; completed chapter data is not.
        await _queuePrefs?.remove(_queueKey);
      }
    }
    _engineRevision = aiRuntime.engineRevision;
    aiRuntime.addListener(_policyChanged);
    _aiMonitor = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _scheduleAi(),
    );
    _scheduleAi();
  }

  void setReadingActive(bool value) {
    if (_readingActive == value) return;
    _readingActive = value;
    _scheduleAi();
  }

  /// Mobile operating systems decide when background compute may run. Until a
  /// native scheduler grants a task window, pausing the app must also pause the
  /// model queue instead of accidentally treating the device as "idle".
  void setAiExecutionAllowed(bool value) {
    if (_aiExecutionAllowed == value) return;
    _aiExecutionAllowed = value;
    _scheduleAi();
  }

  void startEnrich(ShelfItem b) {
    _enqueue(
      _AiQueuedTask(
        kind: _AiTaskKind.enrich,
        bookId: b.id,
        path: b.path,
        title: b.title,
      ),
    );
  }

  Future<void> stopEnrich() async {
    final task = _activeAiTask?.kind == _AiTaskKind.enrich
        ? _activeAiTask
        : _firstOrNull(_aiQueue.where((t) => t.kind == _AiTaskKind.enrich));
    if (task == null) return;
    task.paused = true;
    if (_activeAiTask == task) {
      await _requestActivePause('已手动暂停');
    } else {
      await _persistAiQueue();
      notifyListeners();
    }
  }

  StreamSubscription<IndexProgress>? _indexSub;
  IndexProgress? indexProgress;
  String? indexError;

  /// Only for the shelf banner, which has to name the book it is chewing on —
  /// the search and 排雷 screens already know which book they are looking at.
  String? indexingTitle;

  bool get indexing => _indexSub != null;

  void startIndex(int bookId, String path, {String? title}) {
    _enqueue(
      _AiQueuedTask(
        kind: _AiTaskKind.semanticIndex,
        bookId: bookId,
        path: path,
        title: title ?? '未命名小说',
      ),
    );
  }

  Future<void> stopIndex() async {
    final task = _activeAiTask?.kind == _AiTaskKind.semanticIndex
        ? _activeAiTask
        : _firstOrNull(
            _aiQueue.where((t) => t.kind == _AiTaskKind.semanticIndex),
          );
    if (task == null) return;
    task.paused = true;
    if (_activeAiTask == task) {
      await _requestActivePause('已手动暂停');
    } else {
      await _persistAiQueue();
      notifyListeners();
    }
  }

  void _enqueue(_AiQueuedTask task) {
    final existing = _firstOrNull(
      _aiQueue.where((t) => t.kind == task.kind && t.bookId == task.bookId),
    );
    if (existing != null) {
      existing.paused = false;
      existing.failed = false;
    } else {
      _aiQueue.add(task);
    }
    aiWaitingReason = null;
    _persistAiQueue();
    notifyListeners();
    _scheduleAi();
  }

  Future<void> runNextAiNow() async {
    if (_aiQueue.isEmpty) return;
    for (final task in _aiQueue) {
      task.paused = false;
      task.failed = false;
    }
    _forceNext = true;
    aiWaitingReason = null;
    await _persistAiQueue();
    notifyListeners();
    _scheduleAi();
  }

  Future<void> retryFailedAi() async {
    for (final task in _aiQueue.where((task) => task.failed)) {
      task.failed = false;
      task.paused = false;
    }
    enrichError = null;
    indexError = null;
    await _persistAiQueue();
    notifyListeners();
    _scheduleAi();
  }

  Future<void> pauseAllAi() async {
    for (final task in _aiQueue) {
      task.paused = true;
    }
    if (_activeAiTask != null) {
      await _requestActivePause('已手动暂停');
    } else {
      await _persistAiQueue();
      notifyListeners();
    }
  }

  /// Removes paused work from the persistent queue. Chapters that already
  /// finished stay cached, so restarting later only processes what remains.
  Future<void> cancelPausedAi() async {
    final removedKinds = _aiQueue
        .where((task) => task.paused)
        .map((task) => task.kind)
        .toSet();
    if (removedKinds.isEmpty) return;

    final active = _activeAiTask;
    final cancelActive = active != null && active.paused;
    _aiQueue.removeWhere((task) => task.paused);
    _forceNext = false;

    if (removedKinds.contains(_AiTaskKind.enrich) &&
        active?.kind != _AiTaskKind.enrich) {
      enrichProgress = null;
      enrichError = null;
      enrichingTitle = null;
      _enrichingPath = null;
    }
    if (removedKinds.contains(_AiTaskKind.semanticIndex) &&
        active?.kind != _AiTaskKind.semanticIndex) {
      indexProgress = null;
      indexError = null;
      indexingTitle = null;
    }

    aiWaitingReason = null;
    await _persistAiQueue();
    notifyListeners();

    if (cancelActive && !_pauseRequested) {
      await _requestActivePause('正在取消任务');
    }
  }

  Future<void> _scheduleAi() async {
    if (_schedulerBusy) return;
    _schedulerBusy = true;
    try {
      if (!_aiExecutionAllowed) {
        aiWaitingReason = '等待系统允许后台运行';
        if (_activeAiTask != null && !_pauseRequested) {
          await _requestActivePause(aiWaitingReason!);
        }
        notifyListeners();
        return;
      }
      final state = await aiRuntime.readDeviceState();
      aiDevice = state;

      final active = _activeAiTask;
      if (active != null) {
        final reason = aiRuntime.waitingReason(
          state,
          reading: _readingActive,
          forceNow: _activeForced,
        );
        if (reason != null && !_pauseRequested) {
          await _requestActivePause(reason);
        }
        notifyListeners();
        return;
      }

      final next = _firstOrNull(
        _aiQueue.where((task) => !task.paused && !task.failed),
      );
      if (next == null) {
        notifyListeners();
        return;
      }
      final force = _forceNext;
      final reason = aiRuntime.waitingReason(
        state,
        reading: _readingActive,
        forceNow: force,
      );
      if (reason != null) {
        aiWaitingReason = reason;
        notifyListeners();
        return;
      }
      _forceNext = false;
      _startAiTask(next, forced: force);
    } catch (e) {
      aiWaitingReason = '暂时无法读取设备状态';
      notifyListeners();
    } finally {
      _schedulerBusy = false;
    }
  }

  void _startAiTask(_AiQueuedTask task, {required bool forced}) {
    _engineIdleTimer?.cancel();
    _activeAiTask = task;
    _activeForced = forced;
    _pauseRequested = false;
    _pauseReason = null;
    aiWaitingReason = null;
    task.failed = false;

    if (task.kind == _AiTaskKind.enrich) {
      enrichError = null;
      enrichProgress = null;
      enrichingTitle = task.title;
      _enrichingPath = task.path;
      _enrichSub = enrichBook(path: task.path, bookId: task.bookId).listen(
        (progress) {
          enrichProgress = progress;
          if (progress.error != null) enrichError = progress.error;
          notifyListeners();
        },
        onError: (Object error) {
          enrichError = '$error';
          _finishAiTask(task, failed: true);
        },
        onDone: () => _finishAiTask(task),
      );
    } else {
      indexError = null;
      indexProgress = null;
      indexingTitle = task.title;
      _indexSub = indexBook(path: task.path, bookId: task.bookId).listen(
        (progress) {
          indexProgress = progress;
          if (progress.error != null) indexError = progress.error;
          notifyListeners();
        },
        onError: (Object error) {
          indexError = '$error';
          _finishAiTask(task, failed: true);
        },
        onDone: () => _finishAiTask(task),
      );
    }
    _persistAiQueue();
    notifyListeners();
  }

  Future<void> _requestActivePause(String reason) async {
    final task = _activeAiTask;
    if (task == null || _pauseRequested) return;
    _pauseRequested = true;
    _pauseReason = reason;
    aiWaitingReason = reason;
    if (task.kind == _AiTaskKind.enrich) {
      await cancelEnrich();
    } else {
      await cancelIndex();
    }
    notifyListeners();
  }

  void _finishAiTask(_AiQueuedTask task, {bool failed = false}) {
    if (_activeAiTask != task) return;
    final wasCancelled = !_aiQueue.contains(task);
    final wasPaused = _pauseRequested || task.paused;
    if (failed) {
      task.failed = true;
    } else if (!wasPaused) {
      _aiQueue.remove(task);
    }

    if (task.kind == _AiTaskKind.enrich) {
      _enrichSub = null;
      enrichingTitle = null;
      if (wasCancelled) {
        enrichProgress = null;
        enrichError = null;
      }
      final path = _enrichingPath;
      _enrichingPath = null;
      if (path != null && info?.path != path) closeBook(path: path);
      loadLibrary();
    } else {
      _indexSub = null;
      indexingTitle = null;
      if (wasCancelled) {
        indexProgress = null;
        indexError = null;
      }
    }
    _activeAiTask = null;
    _activeForced = false;
    _pauseRequested = false;
    if (_restartEngineAfterPause) {
      _restartEngineAfterPause = false;
      stopAi();
    }
    if (!wasCancelled && _pauseReason != null) {
      aiWaitingReason = _pauseReason;
    }
    _pauseReason = null;
    _persistAiQueue();
    _scheduleEngineUnload();
    notifyListeners();
    _scheduleAi();
  }

  Future<void> _persistAiQueue() async {
    final p = _queuePrefs;
    if (p == null) return;
    if (_aiQueue.isEmpty) {
      await p.remove(_queueKey);
    } else {
      await p.setString(
        _queueKey,
        jsonEncode(_aiQueue.map((task) => task.toJson()).toList()),
      );
    }
  }

  void _scheduleEngineUnload() {
    _engineIdleTimer?.cancel();
    _engineIdleTimer = Timer(aiRuntime.engineIdleDuration, () {
      if (_activeAiTask == null) stopAi();
    });
  }

  void _policyChanged() {
    if (_engineRevision != aiRuntime.engineRevision) {
      _engineRevision = aiRuntime.engineRevision;
      if (_activeAiTask != null) {
        _restartEngineAfterPause = true;
        _requestActivePause('正在应用新的运行方式');
      } else {
        stopAi();
      }
    }
    _scheduleAi();
  }

  Future<void> loadLibrary() async {
    shelf = await listBooks();
    notifyListeners();
    // Books imported before genre tags existed carry none, and nothing would
    // ever give them any: a book is tagged when it is decoded. Tag them once,
    // in the background, then repaint. Costs a file read each and happens once.
    if (shelf.any((b) => b.genreTags.isEmpty)) {
      final n = await backfillGenres();
      if (n > 0) {
        shelf = await listBooks();
        notifyListeners();
      }
    }
  }

  /// Register books on the shelf without entering the reader. Import is a shelf
  /// action; opening is a reading action — conflating them meant importing three
  /// books dropped you into the last one.
  Future<int> importPaths(Iterable<String> paths) async {
    loading = true;
    error = null;
    notifyListeners();
    var imported = 0;
    try {
      for (final p in paths.where((p) => p.toLowerCase().endsWith('.txt'))) {
        await openBook(path: p);
        await closeBook(path: p);
        imported++;
      }
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      await loadLibrary();
    }
    return imported;
  }

  /// Re-parse a shelved book with a user-chosen encoding (null = back to
  /// detection). Returns the encoding it decoded as, or throws.
  Future<String> reEncode(ShelfItem item, String? encoding) async {
    final info = await setBookEncoding(
      bookId: item.id,
      path: item.path,
      encoding: encoding,
    );
    await closeBook(path: item.path);
    await loadLibrary();
    return info.encoding;
  }

  Future<void> open(String path) async {
    loading = true;
    error = null;
    _saveDebounce?.cancel();
    _pendingChapterIndex = null;
    notifyListeners();
    try {
      final b = await openBook(path: path);
      info = b;
      _pendingOffset = b.lastOffset > 0 ? b.lastOffset : null;
      _beginSession(b.lastOffset);
      await _load(b.lastChapter);
      final annotationsFuture = listAnnotations(bookId: b.id);
      final completedFuture = listCompletedChapters(bookId: b.id);
      annotations = await annotationsFuture;
      completedChapters = (await completedFuture)
          .map((value) => value.toInt())
          .toSet();
      await readingSessionStore?.remember(path);
    } catch (e) {
      error = '$e';
      info = null;
      annotations = const [];
      completedChapters = const {};
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Restores the route only after every durable subsystem is initialized.
  /// [open] then restores the exact byte offset, annotations and completed
  /// chapters from the database as usual.
  Future<bool> restoreReadingSession() async {
    final path = readingSessionStore?.activeBookPath;
    if (path == null) return false;
    await open(path);
    if (isOpen) return true;
    await readingSessionStore?.clear();
    error = null;
    notifyListeners();
    return false;
  }

  Future<bool> _load(int i) async {
    final b = info!;
    final targetChapter = i.clamp(0, b.chapters.length - 1);
    final target = _pendingOffset;
    _pendingOffset = null;
    final revision = ++_navigationRevision;
    _pendingChapterIndex = targetChapter;
    final loadedParagraphs = await chapterParagraphs(
      path: b.path,
      index: targetChapter,
    );
    if (revision != _navigationRevision || info?.id != b.id) return false;

    final restoredParagraph = target == null
        ? 0
        : loadedParagraphs
              .lastIndexWhere((p) => p.start <= target)
              .clamp(0, loadedParagraphs.length);

    chapterIndex = targetChapter;
    paragraphs = loadedParagraphs;
    initialParagraph = restoredParagraph;
    _coverageChapter = targetChapter;
    _sawChapterStart = restoredParagraph == 0;
    _offset = loadedParagraphs.isEmpty
        ? b.chapters[targetChapter].start
        : loadedParagraphs[restoredParagraph].start;
    _pendingChapterIndex = null;
    notifyListeners();
    return true;
  }

  Future<void> goToChapter(int i) async {
    if (info == null || i < 0 || i >= info!.chapters.length) return;
    _saveDebounce?.cancel();
    _pendingOffset = null;
    if (!await _load(i)) return;
    await _writeProgress(
      bookId: info!.id,
      chapter: chapterIndex,
      offset: _offset,
    );
  }

  Future<void> next() =>
      goToChapter((_pendingChapterIndex ?? chapterIndex) + 1);
  Future<void> prev() =>
      goToChapter((_pendingChapterIndex ?? chapterIndex) - 1);

  /// Jump to a byte offset — a semantic-search hit. The chapter opens on the
  /// paragraph that contains the offset, not at its top: sending the reader to
  /// "chapter 412" hands them back the problem they came to search with.
  Future<void> goToOffset(int chapter, int offset) async {
    if (info == null || chapter < 0 || chapter >= info!.chapters.length) return;
    _saveDebounce?.cancel();
    _pendingOffset = offset;
    if (!await _load(chapter)) return;
    await _writeProgress(
      bookId: info!.id,
      chapter: chapterIndex,
      offset: _offset,
    );
  }

  Future<void> saveAnnotationSelection({
    required int chapter,
    required Paragraph paragraph,
    required int start,
    required int end,
    required String body,
  }) async {
    final book = info;
    if (book == null) return;
    final safeStart = start.clamp(0, paragraph.text.length);
    final safeEnd = end.clamp(safeStart, paragraph.text.length);
    final quote = paragraph.text.substring(safeStart, safeEnd);
    if (quote.trim().isEmpty) return;
    final byteStart =
        paragraph.start +
        utf8.encode(paragraph.text.substring(0, safeStart)).length;
    final byteEnd = byteStart + utf8.encode(quote).length;
    await saveAnnotation(
      annotationId: null,
      bookId: book.id,
      chapter: chapter,
      start: byteStart,
      end: byteEnd,
      quote: quote,
      body: body,
    );
    annotations = await listAnnotations(bookId: book.id);
    notifyListeners();
  }

  Future<void> updateAnnotation(BookAnnotation annotation, String body) async {
    final book = info;
    if (book == null) return;
    await saveAnnotation(
      annotationId: annotation.id,
      bookId: book.id,
      chapter: annotation.chapter,
      start: annotation.start,
      end: annotation.end,
      quote: annotation.quote,
      body: body,
    );
    annotations = await listAnnotations(bookId: book.id);
    notifyListeners();
  }

  Future<void> removeAnnotation(BookAnnotation annotation) async {
    final book = info;
    if (book == null) return;
    await deleteAnnotation(bookId: book.id, annotationId: annotation.id);
    annotations = await listAnnotations(bookId: book.id);
    notifyListeners();
  }

  Future<void> markCurrentChapterCompleted() async {
    final book = info;
    final chapter = chapterIndex;
    if (book == null ||
        completedChapters.contains(chapter) ||
        _completionInFlight.contains(chapter)) {
      return;
    }
    _completionInFlight.add(chapter);
    try {
      await markChapterCompleted(bookId: book.id, chapter: chapter);
      completedChapters = {...completedChapters, chapter};
      notifyListeners();
    } finally {
      _completionInFlight.remove(chapter);
    }
  }

  /// A chapter is complete only after this reading session has actually seen
  /// its beginning and then its end. Directory and annotation jumps therefore
  /// never fill the chapters in between or complete a chapter entered midway.
  Future<void> recordChapterViewport({
    required bool atStart,
    required bool atEnd,
  }) async {
    if (info == null) return;
    if (_coverageChapter != chapterIndex) {
      _coverageChapter = chapterIndex;
      _sawChapterStart = false;
    }
    if (atStart) _sawChapterStart = true;
    if (atEnd && _sawChapterStart) await markCurrentChapterCompleted();
  }

  /// Called as the reader scrolls. Cheap, so it must not touch the database on
  /// every frame.
  void onVisibleParagraph(int paragraphIndex) {
    if (paragraphIndex < 0 || paragraphIndex >= paragraphs.length) return;
    _offset = paragraphs[paragraphIndex].start;
    _save();
  }

  void _save() {
    final b = info;
    if (b == null) return;
    final savedChapter = chapterIndex;
    final savedOffset = _offset;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), () {
      _writeProgress(bookId: b.id, chapter: savedChapter, offset: savedOffset);
    });
  }

  Future<void> _writeProgress({
    required int bookId,
    required int chapter,
    required int offset,
  }) {
    final write = _progressWrites.then(
      (_) => saveProgress(bookId: bookId, chapter: chapter, offset: offset),
    );
    _progressWrites = write.catchError((Object _) {});
    return write;
  }

  void _beginSession(int fromOffset) {
    _sessionStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _sessionStartOffset = fromOffset;
  }

  void resumeSession() {
    if (info != null && _sessionStart == 0) _beginSession(_offset);
  }

  /// A session is written when the reader leaves, not while they read. Sessions
  /// where nothing moved are dropped in Rust: the heatmap should count reading,
  /// not an app left open on a desk.
  Future<void> endSession() async {
    final b = info;
    if (b == null) return;
    _saveDebounce?.cancel();
    final chapter = chapterIndex;
    final offset = _offset;
    final sessionStart = _sessionStart;
    final sessionStartOffset = _sessionStartOffset;
    _sessionStart = 0;
    await _writeProgress(bookId: b.id, chapter: chapter, offset: offset);
    if (sessionStart != 0) {
      await logEvent(
        bookId: b.id,
        started: sessionStart,
        ended: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        from: sessionStartOffset,
        to: offset,
      );
    }
  }

  Future<void> closeCurrent() async {
    await endSession();
    _saveDebounce?.cancel();
    _navigationRevision++;
    _pendingChapterIndex = null;
    final b = info;
    // Keep the Rust-side text alive if the enrichment pass is still reading it.
    if (b != null && b.path != _enrichingPath) await closeBook(path: b.path);
    info = null;
    paragraphs = const [];
    annotations = const [];
    completedChapters = const {};
    chapterIndex = 0;
    _coverageChapter = -1;
    _sawChapterStart = false;
    await readingSessionStore?.clear();
    await loadLibrary();
  }

  Future<void> delete(int bookId) async {
    await removeBook(bookId: bookId);
    await loadLibrary();
  }

  /// The book and everything the app made of it.
  Future<void> deleteForever(int bookId) async {
    await deleteBook(bookId: bookId);
    await loadLibrary();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _aiMonitor?.cancel();
    _engineIdleTimer?.cancel();
    aiRuntime.removeListener(_policyChanged);
    super.dispose();
  }
}
