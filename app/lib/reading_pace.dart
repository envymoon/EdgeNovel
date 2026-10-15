import 'dart:math' as math;

/// One stretch of reading for the speed log: when it began, how long it ran,
/// how many characters went past.
class PaceWindow {
  final int chapter;
  final int startedAt;
  final int secs;
  final int chars;

  const PaceWindow({
    required this.chapter,
    required this.startedAt,
    required this.secs,
    required this.chars,
  });
}

/// Cuts reading into windows of about [window] for the speed log.
///
/// It only measures; it does not judge. A reader who looked away, or flicked
/// through pages hunting for a name, still produces windows — Rust sorts them
/// out by their speed when counting (`reading_stats`), so the rule can improve
/// later without losing what was recorded. Two things are left out here because
/// no rule could recover them afterwards:
///
/// * Ground already covered. Characters count only the first time they scroll
///   past the top of the screen, so reading back over a page adds time but no
///   text, and a scroll back up does not count the same lines twice.
/// * Time away. A gap of [away] with no movement at all closes the window at
///   the last movement; the gap itself is never recorded.
///
/// Windows end at the last movement, not "now": the last screen of a chapter
/// never scrolls past the top, so its reading time would come with no text.
class ReadingPaceTracker {
  ReadingPaceTracker({DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  static const window = Duration(seconds: 30);
  static const away = Duration(minutes: 5);

  /// Shorter leftovers say too little to be worth a row.
  static const minimum = Duration(seconds: 10);

  int? _chapter;
  int _furthest = 0;
  DateTime? _start;
  DateTime? _lastMove;
  int _chars = 0;

  /// The top visible paragraph is now [paragraph] of [chapter].
  /// [charsBetween] counts the characters of paragraphs `[from, to)`. Returns a
  /// window when this movement closes one.
  PaceWindow? moved(
    int chapter,
    int paragraph,
    int Function(int from, int to) charsBetween,
  ) {
    final now = _now();
    final start = _start;
    final last = _lastMove;
    if (start == null || last == null || _chapter != chapter) {
      _begin(chapter, paragraph, now);
      return null;
    }
    if (now.difference(last) > away) {
      // They were gone. What was read before they left is kept; the gap and
      // whatever moved on their return are not.
      final done = _close(start, last);
      _begin(chapter, math.max(paragraph, _furthest), now);
      return done;
    }
    if (paragraph > _furthest) {
      _chars += charsBetween(_furthest, paragraph);
      _furthest = paragraph;
    }
    _lastMove = now;
    if (now.difference(start) >= window) {
      final done = _close(start, now);
      _start = now;
      _chars = 0;
      return done;
    }
    return null;
  }

  /// The sitting or the chapter is over: close what is open, up to the last
  /// movement. The next [moved] starts afresh.
  PaceWindow? finish() {
    final start = _start;
    final last = _lastMove;
    final done = start == null || last == null ? null : _close(start, last);
    _start = null;
    _lastMove = null;
    _chapter = null;
    _chars = 0;
    return done;
  }

  void _begin(int chapter, int paragraph, DateTime now) {
    _chapter = chapter;
    _furthest = paragraph;
    _start = now;
    _lastMove = now;
    _chars = 0;
  }

  PaceWindow? _close(DateTime start, DateTime end) {
    final secs = end.difference(start).inSeconds;
    if (_chars <= 0 || end.difference(start) < minimum) return null;
    return PaceWindow(
      chapter: _chapter!,
      startedAt: start.millisecondsSinceEpoch ~/ 1000,
      secs: secs,
      chars: _chars,
    );
  }
}
