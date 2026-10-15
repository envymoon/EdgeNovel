import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_runtime.dart';
import 'platform_support.dart';
import 'reading_pace.dart';
import 'reading_session_store.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/image.dart';
import 'src/rust/api/stats.dart';

enum _AiTaskKind { enrich, semanticIndex, cast, plates }

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
    this.upTo = 0,
    this.paused = false,
    this.failed = false,
  });

  final _AiTaskKind kind;
  final int bookId;
  final String path;
  final String title;

  /// Chapters the cast pass reads up to. Unused by the other kinds.
  final int upTo;
  bool paused;
  bool failed;

  String get label => switch (kind) {
    _AiTaskKind.enrich => '章节分析',
    _AiTaskKind.semanticIndex => '语义检索',
    _AiTaskKind.cast => '人物分析',
    _AiTaskKind.plates => '章间立绘',
  };

  String get doing => switch (kind) {
    _AiTaskKind.enrich => '正在分析章节',
    _AiTaskKind.semanticIndex => '正在建立语义检索',
    _AiTaskKind.cast => '正在分析人物',
    _AiTaskKind.plates => '正在画章间立绘',
  };

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'bookId': bookId,
    'path': path,
    'title': title,
    'upTo': upTo,
    'paused': paused,
    'failed': failed,
  };

  static _AiQueuedTask? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final path = value['path'];
    final title = value['title'];
    final bookId = value['bookId'];
    if (path is! String || title is! String || bookId is! int) return null;
    final kind = switch (value['kind']) {
      'semanticIndex' || 'index' => _AiTaskKind.semanticIndex,
      'cast' => _AiTaskKind.cast,
      'plates' => _AiTaskKind.plates,
      _ => _AiTaskKind.enrich,
    };
    final upTo = value['upTo'] is int ? value['upTo'] as int : 0;
    // A cast pass that does not know how far to read would read nothing.
    if (kind == _AiTaskKind.cast && upTo <= 0) return null;
    return _AiQueuedTask(
      kind: kind,
      bookId: bookId,
      path: path,
      title: title,
      upTo: upTo,
      paused: value['paused'] == true,
      failed: value['failed'] == true,
    );
  }
}

/// Where one book's task of one kind stands in the queue.
enum AiTaskState { none, waiting, running, paused, failed }

/// The three model passes behind the cast graph, run in this order: names
/// first (an edge to something that is not a person is not worth a summary),
/// then relationships, then backgrounds (the longest reads, and the graph is
/// usable without them).
enum CastStep { vet, label, describe }

class CastRunProgress {
  const CastRunProgress(this.step, this.done, this.total, this.detail);

  final CastStep step;
  final int done;
  final int total;

  /// The item just finished, e.g. 「张三 ↔ 李四 → 师徒」; empty before the first.
  final String detail;

  String get label => switch (step) {
    CastStep.vet => '校对人物',
    CastStep.label => '总结交际',
    CastStep.describe => '归纳人物',
  };
}

/// The running task, said the same way whatever kind it is — what the app-wide
/// progress bar and the background settings page show.
class AiActivity {
  const AiActivity({
    required this.title,
    required this.label,
    required this.done,
    required this.total,
    this.detail,
    this.remaining,
  });

  final String title;
  final String label;
  final int done;
  final int total;
  final String? detail;

  /// Null until enough items have finished to measure a pace.
  final Duration? remaining;

  double? get fraction => total == 0 ? null : done / total;
}

/// 「约 3 分钟」. Rounded up, because a countdown that reaches zero while the
/// work is still going reads as a lie.
String formatRemaining(Duration d) {
  final minutes = (d.inSeconds / 60).ceil();
  if (minutes <= 1) return '不到 1 分钟';
  if (minutes < 60) return '约 $minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '约 $hours 小时' : '约 $hours 小时 $rest 分钟';
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

  /// Reading speed, cut into windows as the reader moves; see [ReadingPaceTracker].
  final ReadingPaceTracker _speedLog = ReadingPaceTracker();
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

  /// Work that will start by itself once the device allows it.
  bool get aiHasRunnable =>
      _aiQueue.any((task) => !task.paused && !task.failed);

  String get aiQueueState {
    final active = _activeAiTask;
    if (active != null) return active.doing;
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
    _loadPlates(_queuePrefs!);
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

  // ── Cast graph model pass ───────────────────────────────────────────────
  CastRunProgress? castProgress;
  String? castError;

  /// The book the cast results below belong to.
  int? castBookId;

  /// What this run has written so far, so the graph can show each summary as it
  /// lands. Keyed like the graph keys edges: 「甲 乙」.
  final Map<String, String> castLabels = {};
  final Map<String, String> castBackgrounds = {};

  AiTaskState castStateFor(int bookId) => _stateOf(_AiTaskKind.cast, bookId);

  /// The graph was reset, so what this run wrote is gone from the database and
  /// must not be handed back to the page either.
  void forgetCastResults(int bookId) {
    if (castBookId != bookId) return;
    castLabels.clear();
    castBackgrounds.clear();
  }

  /// Started from the graph, by someone looking at it: it goes to the front of
  /// the queue and runs now instead of waiting for the device to go idle, and
  /// a longer pass that is already running steps aside for it (that pass stays
  /// queued and picks up from its last finished chapter afterwards).
  void startCast(ShelfItem b) {
    final task =
        _firstOrNull(
          _aiQueue.where((t) => t.kind == _AiTaskKind.cast && t.bookId == b.id),
        ) ??
        _AiQueuedTask(
          kind: _AiTaskKind.cast,
          bookId: b.id,
          path: b.path,
          title: b.title,
          upTo: b.chapterCount,
        );
    task.paused = false;
    task.failed = false;
    if (_activeAiTask == task) return;
    _aiQueue.remove(task);
    _aiQueue.insert(0, task);
    if (castBookId != b.id) {
      castLabels.clear();
      castBackgrounds.clear();
    }
    castBookId = b.id;
    castError = null;
    _forceNext = true;
    aiWaitingReason = null;
    _persistAiQueue();
    notifyListeners();
    if (_activeAiTask != null) {
      _requestActivePause('让位给人物分析');
    } else {
      _scheduleAi();
    }
  }

  Future<void> stopCast(int bookId) => _pauseFor(_AiTaskKind.cast, bookId);

  Future<void> _cancelCastStep() async {
    switch (castProgress?.step) {
      case CastStep.vet:
        await cancelVet();
      case CastStep.label:
        await cancelRelabel();
      case CastStep.describe:
        await cancelDescribe();
      case null:
        break;
    }
  }

  Future<void> _runCast(_AiQueuedTask task) async {
    final path = task.path;
    final bookId = task.bookId;
    final upTo = task.upTo;
    try {
      castProgress = const CastRunProgress(CastStep.vet, 0, 0, '');
      notifyListeners();
      await for (final v in vetNames(
        path: path,
        bookId: bookId,
        upToChapter: upTo,
      )) {
        // Re-sent on every item: the step clears its cancel flag when it
        // starts, so a pause asked for in that instant would otherwise be lost.
        if (_pauseRequested) await cancelVet();
        castProgress = CastRunProgress(
          CastStep.vet,
          v.done,
          v.total,
          v.name.isEmpty ? '' : '${v.name} → ${v.isPerson ? '人物' : '不是人物，已移除'}',
        );
        _pace('cast-vet', v.done, v.total);
        notifyListeners();
      }
      if (_pauseRequested) {
        _finishAiTask(task);
        return;
      }

      castProgress = const CastRunProgress(CastStep.label, 0, 0, '');
      notifyListeners();
      await for (final p in labelRelations(
        path: path,
        bookId: bookId,
        upToChapter: upTo,
      )) {
        if (_pauseRequested) await cancelRelabel();
        if (p.label.isNotEmpty) castLabels['${p.a} ${p.b}'] = p.label;
        castProgress = CastRunProgress(
          CastStep.label,
          p.done,
          p.total,
          p.a.isEmpty ? '' : '${p.a} ↔ ${p.b} → ${p.label}',
        );
        _pace('cast-label', p.done, p.total);
        notifyListeners();
      }
      if (_pauseRequested) {
        _finishAiTask(task);
        return;
      }

      castProgress = const CastRunProgress(CastStep.describe, 0, 0, '');
      notifyListeners();
      await for (final p in describePeople(
        path: path,
        bookId: bookId,
        upToChapter: upTo,
      )) {
        if (_pauseRequested) await cancelDescribe();
        if (p.background.isNotEmpty) castBackgrounds[p.name] = p.background;
        castProgress = CastRunProgress(
          CastStep.describe,
          p.done,
          p.total,
          // A background read from chapter summaries is two paragraphs (who,
          // then what happened); the progress line has room for the first.
          p.name.isEmpty ? '' : '${p.name} → ${p.background.split('\n').first}',
        );
        _pace('cast-describe', p.done, p.total);
        notifyListeners();
      }
      _finishAiTask(task);
    } catch (e) {
      castError = '$e';
      _finishAiTask(task, failed: true);
    }
  }

  // ── 章间立绘 ─────────────────────────────────────────────────────────────
  // A picture every few chapters, drawn in the queue when the reader asks on
  // the 章间立绘 page, once, and shown by the reader between two chapters.
  // The key holds the spacing of each book's unfinished job, so a paused or
  // queued one picks up where it was after a restart.
  static const _platesKey = 'plates.every.v1';
  final Map<int, int> _plateEvery = {};
  PlateProgress? plateProgress;
  String? plateError;

  /// Chapters between plates in a book's unfinished job, or null when it has
  /// none.
  int? plateEveryFor(int bookId) => _plateEvery[bookId];

  AiTaskState plateStateFor(int bookId) => _stateOf(_AiTaskKind.plates, bookId);

  void _loadPlates(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_platesKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in map.entries) {
        final id = int.tryParse(e.key);
        final every = e.value;
        if (id != null && every is int && every > 0) _plateEvery[id] = every;
      }
    } catch (_) {
      // A setting that cannot be read is the same as never set.
    }
  }

  Future<void> _savePlates() async {
    final p = _queuePrefs ?? await SharedPreferences.getInstance();
    await p.setString(
      _platesKey,
      jsonEncode({for (final e in _plateEvery.entries) '${e.key}': e.value}),
    );
  }

  /// Draw a book's plates `every` chapters apart, those not drawn yet. Once:
  /// when it has finished, nothing more is drawn until asked again.
  Future<void> drawPlatesFor(ShelfItem b, int every) async {
    _plateEvery[b.id] = every;
    await _savePlates();
    _enqueue(
      _AiQueuedTask(
        kind: _AiTaskKind.plates,
        bookId: b.id,
        path: b.path,
        title: b.title,
      ),
    );
  }

  /// Drop a book's unfinished job. What it drew stays.
  Future<void> cancelPlatesFor(int bookId) async {
    _plateEvery.remove(bookId);
    await _savePlates();
    final active = _activeAiTask;
    _aiQueue.removeWhere(
      (t) => t.kind == _AiTaskKind.plates && t.bookId == bookId,
    );
    await _persistAiQueue();
    if (active != null &&
        active.kind == _AiTaskKind.plates &&
        active.bookId == bookId) {
      await _requestActivePause('已取消章间立绘');
    }
    notifyListeners();
  }

  /// Drop a book's job and delete every plate it has.
  Future<void> deletePlatesFor(int bookId) async {
    await cancelPlatesFor(bookId);
    await clearPlates(bookId: bookId);
    notifyListeners();
  }

  Future<void> stopPlatesFor(int bookId) =>
      _pauseFor(_AiTaskKind.plates, bookId);
  Future<void> runPlatesNow(int bookId) => _runNow(_AiTaskKind.plates, bookId);

  // ── Pace ────────────────────────────────────────────────────────────────
  // Measured from the first finished item, not from the start: the first one
  // also pays for loading the engine, and counting it would inflate every
  // estimate after.
  String _paceKey = '';
  DateTime? _paceSince;
  int _paceFrom = 0;
  Duration? _remaining;

  void _pace(String key, int done, int total) {
    final now = DateTime.now();
    if (key != _paceKey || _paceSince == null || done < _paceFrom) {
      _paceKey = key;
      _paceSince = now;
      _paceFrom = done;
      _remaining = null;
      return;
    }
    final finished = done - _paceFrom;
    if (finished < 2) return;
    final each = now.difference(_paceSince!) ~/ finished;
    _remaining = each * (total - done);
  }

  void _resetPace() {
    _paceKey = '';
    _paceSince = null;
    _remaining = null;
  }

  /// The running task, or null when nothing is running.
  AiActivity? get aiActivity {
    final task = _activeAiTask;
    if (task == null) return null;
    switch (task.kind) {
      case _AiTaskKind.enrich:
        final p = enrichProgress;
        return AiActivity(
          title: task.title,
          label: task.label,
          done: p?.done ?? 0,
          total: p?.total ?? 0,
          detail: p?.title,
          remaining: _remaining,
        );
      case _AiTaskKind.semanticIndex:
        final p = indexProgress;
        return AiActivity(
          title: task.title,
          label: task.label,
          done: p?.done ?? 0,
          total: p?.total ?? 0,
          detail: p?.title,
          remaining: _remaining,
        );
      case _AiTaskKind.plates:
        // What is being drawn is the reader's to find between chapters.
        final p = plateProgress;
        return AiActivity(
          title: task.title,
          label: task.label,
          done: p?.done ?? 0,
          total: p?.total ?? 0,
          remaining: _remaining,
        );
      case _AiTaskKind.cast:
        final p = castProgress;
        return AiActivity(
          title: task.title,
          label: p == null
              ? task.label
              : '${task.label} · 第 ${p.step.index + 1}/3 步${p.label}',
          done: p?.done ?? 0,
          total: p?.total ?? 0,
          detail: p?.detail,
          remaining: _remaining,
        );
    }
  }

  // ── Per-book controls, for the pages that start and stop one book's work ─
  AiTaskState _stateOf(_AiTaskKind kind, int bookId) {
    final active = _activeAiTask;
    if (active != null && active.kind == kind && active.bookId == bookId) {
      return AiTaskState.running;
    }
    final task = _firstOrNull(
      _aiQueue.where((t) => t.kind == kind && t.bookId == bookId),
    );
    if (task == null) return AiTaskState.none;
    if (task.failed) return AiTaskState.failed;
    if (task.paused) return AiTaskState.paused;
    return AiTaskState.waiting;
  }

  AiTaskState enrichStateFor(int bookId) =>
      _stateOf(_AiTaskKind.enrich, bookId);
  AiTaskState indexStateFor(int bookId) =>
      _stateOf(_AiTaskKind.semanticIndex, bookId);

  Future<void> stopEnrichFor(int bookId) =>
      _pauseFor(_AiTaskKind.enrich, bookId);
  Future<void> stopIndexFor(int bookId) =>
      _pauseFor(_AiTaskKind.semanticIndex, bookId);

  /// Waiting work the reader wants now: to the front, past the device policy
  /// for this one run. Whatever is already running is left to finish.
  Future<void> runEnrichNow(int bookId) => _runNow(_AiTaskKind.enrich, bookId);
  Future<void> runIndexNow(int bookId) =>
      _runNow(_AiTaskKind.semanticIndex, bookId);

  Future<void> _pauseFor(_AiTaskKind kind, int bookId) async {
    final task = _firstOrNull(
      _aiQueue.where((t) => t.kind == kind && t.bookId == bookId),
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

  Future<void> _runNow(_AiTaskKind kind, int bookId) async {
    final task = _firstOrNull(
      _aiQueue.where((t) => t.kind == kind && t.bookId == bookId),
    );
    if (task == null || _activeAiTask == task) return;
    task.paused = false;
    task.failed = false;
    _aiQueue.remove(task);
    _aiQueue.insert(0, task);
    _forceNext = true;
    aiWaitingReason = null;
    await _persistAiQueue();
    notifyListeners();
    _scheduleAi();
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
    if (removedKinds.contains(_AiTaskKind.plates) &&
        active?.kind != _AiTaskKind.plates) {
      plateProgress = null;
      plateError = null;
    }
    if (removedKinds.contains(_AiTaskKind.cast) &&
        active?.kind != _AiTaskKind.cast) {
      castProgress = null;
      castError = null;
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
        if (AppPlatformSupport.hasBundledAiEngine && !_aiExecutionAllowed) {
          // Release native model memory as well as pausing the shared queue.
          // In-flight inference is retried from the last completed chapter.
          await stopAi();
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
      // Nothing to run is the state of an idle app all day: this tick comes
      // every ten seconds, and telling the shelf about it rebuilt every card.
      if (next == null) return;
      final force = _forceNext;
      final reason = aiRuntime.waitingReason(
        state,
        reading: _readingActive,
        forceNow: force,
      );
      if (reason != null) {
        if (reason != aiWaitingReason) {
          aiWaitingReason = reason;
          notifyListeners();
        }
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
    _resetPace();

    if (task.kind == _AiTaskKind.plates) {
      plateError = null;
      plateProgress = null;
      final every = _plateEvery[task.bookId];
      if (every == null) {
        // Cancelled while it waited.
        Future.microtask(() => _finishAiTask(task));
      } else {
        // Stopped through cancelPlates, which ends the stream.
        drawPlates(path: task.path, bookId: task.bookId, every: every).listen(
          (progress) {
            plateProgress = progress;
            _pace('plates', progress.done, progress.total);
            notifyListeners();
          },
          onError: (Object error) {
            plateError = '$error';
            _finishAiTask(task, failed: true);
          },
          onDone: () => _finishAiTask(task),
        );
      }
    } else if (task.kind == _AiTaskKind.cast) {
      if (castBookId != task.bookId) {
        castLabels.clear();
        castBackgrounds.clear();
      }
      castBookId = task.bookId;
      castError = null;
      castProgress = null;
      _runCast(task);
    } else if (task.kind == _AiTaskKind.enrich) {
      enrichError = null;
      enrichProgress = null;
      enrichingTitle = task.title;
      _enrichingPath = task.path;
      _enrichSub = enrichBook(path: task.path, bookId: task.bookId).listen(
        (progress) {
          enrichProgress = progress;
          if (progress.error != null) enrichError = progress.error;
          _pace('enrich', progress.done, progress.total);
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
          _pace('index', progress.done, progress.total);
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
    switch (task.kind) {
      case _AiTaskKind.enrich:
        await cancelEnrich();
      case _AiTaskKind.semanticIndex:
        await cancelIndex();
      case _AiTaskKind.cast:
        await _cancelCastStep();
      case _AiTaskKind.plates:
        await cancelPlates();
    }
    notifyListeners();
  }

  void _finishAiTask(_AiQueuedTask task, {bool failed = false}) {
    if (_activeAiTask != task) return;
    final wasCancelled = !_aiQueue.contains(task);
    final wasPaused = _pauseRequested || task.paused;
    if (failed && !wasPaused) {
      task.failed = true;
    } else if (!wasPaused) {
      _aiQueue.remove(task);
    }

    _resetPace();
    if (task.kind == _AiTaskKind.plates) {
      if (wasCancelled || wasPaused) {
        plateProgress = null;
        plateError = null;
      } else if (!failed) {
        // Done: the job is over, and the next one is the reader's to ask for.
        _plateEvery.remove(task.bookId);
        _savePlates();
      }
      // The plan read the whole book into memory; let it go unless it is
      // the one being read.
      if (info?.path != task.path) closeBook(path: task.path);
    } else if (task.kind == _AiTaskKind.cast) {
      castProgress = null;
      if (wasCancelled || wasPaused) castError = null;
    } else if (task.kind == _AiTaskKind.enrich) {
      _enrichSub = null;
      enrichingTitle = null;
      if (wasCancelled || wasPaused) {
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
      if (wasCancelled || wasPaused) {
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
    _logSpeedWindow(_speedLog.finish());
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
    _logSpeedWindow(
      _speedLog.moved(chapterIndex, paragraphIndex, _charsBetween),
    );
  }

  int _charsBetween(int from, int to) {
    var n = 0;
    for (var i = from; i < to && i < paragraphs.length; i++) {
      n += paragraphs[i].text.length;
    }
    return n;
  }

  /// Fire and forget: a lost speed window costs half a minute of statistics,
  /// and must never cost the reader a page turn.
  void _logSpeedWindow(PaceWindow? w) {
    final b = info;
    if (w == null || b == null) return;
    try {
      unawaited(
        logReadingWindow(
          bookId: b.id,
          chapter: w.chapter,
          started: w.startedAt,
          secs: w.secs,
          chars: w.chars,
        ).catchError((Object _) {}),
      );
    } catch (_) {
      // No native library (widget tests).
    }
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
    _logSpeedWindow(_speedLog.finish());
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
