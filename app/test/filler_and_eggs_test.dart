import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/easter_eggs.dart';
import 'package:novel/easter_eggs_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/theme.dart';
import 'package:novel/tics_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EasterEggEngine.instance.resetForTest();
  });

  testWidgets('TicsPage renders style fingerprint, tics, and jumps to chapter', (
    tester,
  ) async {
    const path = 'test_tics_book.txt';
    seedAuthorTicsForTest(
      path,
      AuthorTics(
        totalChars: 250000,
        chapterCount: 50,
        dialogueRatio: 0.44,
        avgSentenceLen: 16.5,
        exclamPer10K: 92.0,
        ellipsisPer10K: 34.0,
        questionPer10K: 40.0,
        styleTags: const ['对话密集', '短句疾风', '叹号狂魔'],
        items: [
          TicItem(
            phrase: '倒吸一口凉气',
            category: '神态动作',
            count: 88,
            per10K: 3.52,
            chapterHits: 40,
            peakChapter: 3,
            peakCount: 6,
            sample: '众人见状不由得倒吸一口凉气，面色大变。',
            sampleChapter: 2,
            buckets: Uint32List.fromList(const [2, 3, 4, 5, 1, 2]),
          ),
        ],
      ),
    );
    final info = BookInfo(
      id: 1,
      path: path,
      title: '测试书',
      encoding: 'utf-8',
      style: 'zh',
      totalBytes: 1000,
      charCount: 250000,
      chapters: [
        for (var i = 0; i < 5; i++)
          ChapterInfo(
            index: i,
            title: '第${i + 1}章',
            start: i * 100,
            end: (i + 1) * 100,
          ),
      ],
      volumes: const [],
      interstitialCount: 0,
      anomalies: const [],
      lastChapter: 1,
      lastOffset: 0,
      careerFocus: '',
      romanceFocus: '',
      growthFocus: '',
    );

    int? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: TicsPage(
          info: info,
          settings: ReadingSettings(),
          onOpenChapter: (i) => opened = i,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('写作指纹'), findsNothing);
    expect(find.text('对话密集'), findsNothing);
    expect(find.text('高频写法'), findsOneWidget);
    expect(find.text('倒吸一口凉气'), findsOneWidget);
    expect(find.text('对话占比'), findsOneWidget);
    expect(find.text('平均句长'), findsOneWidget);

    await tester.tap(find.textContaining('最密: 第4章'));
    await tester.pumpAndSettle();
    expect(opened, isNull);
  });

  testWidgets('EasterEggsPage hides locked eggs as ??? and unlocks on trigger', (
    tester,
  ) async {
    final settings = ReadingSettings();
    await tester.pumpWidget(
      MaterialApp(home: EasterEggsPage(settings: settings)),
    );
    await tester.pumpAndSettle();

    final total = EasterEggEngine.catalog.length;
    expect(total, greaterThanOrEqualTo(40));
    expect(find.text('已发现 0 / $total'), findsOneWidget);
    expect(find.text('???'), findsWidgets);
    expect(find.text('记忆回溯'), findsNothing);

    // Trigger rewind_memory (12 backward turns within 45s).
    final engine = EasterEggEngine.instance;
    engine.onBookOpen(bookId: 1, bookTitle: '诡秘', enabled: true);
    for (var i = 0; i < 12; i++) {
      engine.onPageTurn(
        backward: true,
        visibleText: '',
        baselineCharsPerMin: 500,
        bookTitle: '诡秘',
        enabled: true,
      );
    }
    await tester.pumpAndSettle();

    expect(find.text('已发现 1 / $total'), findsOneWidget);
    expect(find.text('记忆回溯'), findsOneWidget);
    expect(engine.activeBanner.value?.def.id, 'rewind_memory');

    // Already-unlocked egg must never re-trigger.
    engine.dismissBanner();
    for (var i = 0; i < 12; i++) {
      engine.onPageTurn(
        backward: true,
        visibleText: '',
        baselineCharsPerMin: 500,
        bookTitle: '诡秘',
        enabled: true,
      );
    }
    expect(engine.activeBanner.value, isNull);
    expect(engine.unlocked['rewind_memory']?.count, 1);

    // While TTS is playing, page turns must not trigger manual pace/dwell eggs.
    engine.resetForTest();
    engine.onBookOpen(bookId: 1, bookTitle: '诡秘', enabled: true);
    engine.onTtsState(playing: true, bookTitle: '诡秘', enabled: true);
    for (var i = 0; i < 15; i++) {
      engine.onPageTurn(
        backward: true,
        visibleText: '',
        baselineCharsPerMin: 500,
        bookTitle: '诡秘',
        enabled: true,
        ttsPlaying: true,
      );
    }
    expect(engine.activeBanner.value, isNull);
    expect(engine.unlockedCount, 0);
  });

  test('onBackground resets continuous session duration and counters', () {
    final engine = EasterEggEngine.instance;
    engine.resetForTest();
    engine.onBookOpen(bookId: 1, bookTitle: '诡秘', enabled: true);

    // Simulate 200 minutes having elapsed, then the phone locking (background).
    engine.backdateSessionForTest(const Duration(minutes: 200));
    for (var i = 0; i < 290; i++) {
      engine.onPageTurn(
        backward: false,
        visibleText: '正文内容',
        baselineCharsPerMin: 500,
        bookTitle: '诡秘',
        enabled: true,
      );
    }
    engine.onBackground();
    engine.onResume();

    // After waking up, neither iron_eyes nor marathon_pages should fire.
    engine.onSpeedWindow(
      chars: 250,
      secs: 30,
      baselineCharsPerMin: 500,
      bookTitle: '诡秘',
      enabled: true,
    );
    for (var i = 0; i < 20; i++) {
      engine.onPageTurn(
        backward: false,
        visibleText: '正文内容',
        baselineCharsPerMin: 500,
        bookTitle: '诡秘',
        enabled: true,
      );
    }
    expect(engine.unlocked.containsKey('iron_eyes'), isFalse);
    expect(engine.unlocked.containsKey('marathon_pages'), isFalse);
  });
}
