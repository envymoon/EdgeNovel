import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/easter_eggs.dart';
import 'package:novel/easter_eggs_page.dart';
import 'package:novel/filler_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EasterEggEngine.instance.resetForTest();
  });

  testWidgets('FillerPage renders curve and lets reader jump to a chapter', (
    tester,
  ) async {
    const path = 'test_filler_book.txt';
    seedFillerForTest(path, [0.22, 0.35, 0.78, 0.41, 0.85]);
    final info = BookInfo(
      id: 1,
      path: path,
      title: '测试书',
      encoding: 'utf-8',
      style: 'zh',
      totalBytes: 1000,
      charCount: 5000,
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
        home: FillerPage(
          info: info,
          settings: ReadingSettings(),
          current: 1,
          onOpenChapter: (i) => opened = i,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('全书均值'), findsOneWidget);
    expect(find.text('5 / 5 章'), findsOneWidget);
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

    expect(find.text('已发现 0 / 12'), findsOneWidget);
    expect(find.text('???'), findsWidgets);
    expect(find.text('记忆回溯'), findsNothing);

    // Trigger rewind_memory (6 backward turns within 30s).
    final engine = EasterEggEngine.instance;
    engine.onBookOpen(bookId: 1, bookTitle: '诡秘', enabled: true);
    for (var i = 0; i < 6; i++) {
      engine.onPageTurn(
        backward: true,
        visibleText: '',
        baselineCharsPerMin: 500,
        bookTitle: '诡秘',
        enabled: true,
      );
    }
    await tester.pumpAndSettle();

    expect(find.text('已发现 1 / 12'), findsOneWidget);
    expect(find.text('记忆回溯'), findsOneWidget);
    expect(engine.activeBanner.value?.def.id, 'rewind_memory');
  });
}
