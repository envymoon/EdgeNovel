import 'package:flutter_test/flutter_test.dart';
import 'package:novel/reading_pace.dart';

/// Ten paragraphs of 100 characters each.
int _chars(int from, int to) => (to - from) * 100;

void main() {
  late DateTime now;
  late ReadingPaceTracker tracker;

  setUp(() {
    now = DateTime(2026, 10, 11, 21);
    tracker = ReadingPaceTracker(clock: () => now);
  });

  PaceWindow? after(Duration d, int paragraph, {int chapter = 3}) {
    now = now.add(d);
    return tracker.moved(chapter, paragraph, _chars);
  }

  test('steady reading closes a window about every thirty seconds', () {
    expect(tracker.moved(3, 0, _chars), isNull);
    expect(after(const Duration(seconds: 15), 2), isNull);
    final w = after(const Duration(seconds: 15), 4)!;
    expect(w.chapter, 3);
    expect(w.secs, 30);
    expect(w.chars, 400);
    expect(
      w.startedAt,
      DateTime(2026, 10, 11, 21).millisecondsSinceEpoch ~/ 1000,
    );
    // The next window starts where that one ended.
    final next = after(const Duration(seconds: 40), 6)!;
    expect((next.secs, next.chars), (40, 200));
  });

  test('reading back over a page adds time but never text twice', () {
    tracker.moved(3, 5, _chars);
    after(const Duration(seconds: 10), 2); // scrolled back up
    after(const Duration(seconds: 10), 5); // and down again
    final w = after(const Duration(seconds: 10), 6)!;
    expect(w.chars, 100);
    expect(w.secs, 30);
  });

  test('time away is not recorded, what came before it is', () {
    tracker.moved(3, 0, _chars);
    after(const Duration(seconds: 20), 3);
    final w = after(const Duration(minutes: 20), 4)!;
    expect((w.secs, w.chars), (20, 300));
    // Back now: a fresh window from the return, with nothing carried over.
    final next = after(const Duration(seconds: 30), 7)!;
    expect((next.secs, next.chars), (30, 300));
  });

  test('a new chapter starts over and the old one is closed by the caller', () {
    tracker.moved(3, 0, _chars);
    after(const Duration(seconds: 25), 4);
    final w = tracker.finish()!;
    expect((w.chapter, w.secs, w.chars), (3, 25, 400));
    expect(after(const Duration(seconds: 5), 0, chapter: 4), isNull);
    final next = after(const Duration(seconds: 30), 2, chapter: 4)!;
    expect((next.chapter, next.chars), (4, 200));
  });

  test('finishing ends at the last movement, not at the moment of leaving', () {
    tracker.moved(3, 0, _chars);
    after(const Duration(seconds: 20), 3);
    now = now.add(const Duration(minutes: 3)); // read the last screen, left
    final w = tracker.finish()!;
    expect(w.secs, 20);
  });

  test('leftovers too short or with no text are dropped', () {
    tracker.moved(3, 0, _chars);
    after(const Duration(seconds: 5), 2);
    expect(tracker.finish(), isNull);
    tracker.moved(3, 2, _chars);
    after(const Duration(seconds: 40), 1); // only went backwards
    expect(tracker.finish(), isNull);
  });

  test(
    'a jump down the chapter is recorded as it is, for the rules to judge',
    () {
      tracker.moved(3, 0, _chars);
      final w = after(const Duration(seconds: 31), 9)!;
      expect((w.secs, w.chars), (31, 900));
    },
  );
}
