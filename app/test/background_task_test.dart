import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/analysis_run_card.dart';
import 'package:novel/background_task_bar.dart';
import 'package:novel/reader_state.dart';
import 'package:novel/theme.dart';
import 'package:novel/tts_prepare.dart';

void main() {
  test('time left rounds up and never reads zero while work remains', () {
    expect(formatRemaining(const Duration(seconds: 20)), '不到 1 分钟');
    expect(formatRemaining(const Duration(seconds: 61)), '约 2 分钟');
    expect(formatRemaining(const Duration(minutes: 15)), '约 15 分钟');
    expect(formatRemaining(const Duration(minutes: 60)), '约 1 小时');
    expect(formatRemaining(const Duration(minutes: 90)), '约 1 小时 30 分钟');
  });

  Future<void> phoneWidth(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<List<String>> pumpCard(
    WidgetTester tester,
    AiTaskState state, {
    bool complete = false,
  }) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: AnalysisRunCard(
              reader: ReaderState(),
              settings: ReadingSettings(),
              icon: Icons.auto_awesome_outlined,
              title: '章节分析',
              coverage: '1200 / 1392 章',
              complete: complete,
              state: state,
              startLabel: '继续分析',
              idleText: '还有 192 章没有分析',
              error: '引擎返回 500',
              onStart: () => pressed.add('start'),
              onPause: () => pressed.add('pause'),
              onRunNow: () => pressed.add('now'),
            ),
          ),
        ),
      ),
    );
    return pressed;
  }

  testWidgets('nothing runs until the button is pressed', (tester) async {
    await phoneWidth(tester);
    final pressed = await pumpCard(tester, AiTaskState.none);
    expect(find.text('还有 192 章没有分析'), findsOneWidget);
    expect(pressed, isEmpty);
    await tester.tap(find.text('继续分析'));
    expect(pressed, ['start']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a finished pass offers no button', (tester) async {
    await phoneWidth(tester);
    await pumpCard(tester, AiTaskState.none, complete: true);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('every state fits a phone and wires its buttons', (tester) async {
    await phoneWidth(tester);

    var pressed = await pumpCard(tester, AiTaskState.waiting);
    await tester.tap(find.text('立即运行'));
    await tester.tap(find.text('暂停'));
    expect(pressed, ['now', 'pause']);
    expect(tester.takeException(), isNull);

    pressed = await pumpCard(tester, AiTaskState.running);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('暂停'));
    expect(pressed, ['pause']);
    expect(tester.takeException(), isNull);

    pressed = await pumpCard(tester, AiTaskState.paused);
    await tester.tap(find.text('继续'));
    expect(pressed, ['start']);
    expect(tester.takeException(), isNull);

    pressed = await pumpCard(tester, AiTaskState.failed);
    expect(find.textContaining('引擎返回 500'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(pressed, ['start']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提前合成 gets the task bar and its progress', (tester) async {
    await phoneWidth(tester);
    final reader = ReaderState();
    final job = TtsPrepare.instance
      ..bookId = 1
      ..title = '诡秘之主'
      ..chapterCount = 5
      ..total = 800
      ..done = 200
      ..remaining = const Duration(minutes: 6);
    addTearDown(job.cancel);
    expect(BackgroundTaskBar.shows(reader), isTrue);

    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackgroundTaskBar(
            reader: reader,
            settings: ReadingSettings(),
            onOpen: () => opened.add('queue'),
            onOpenSpeech: () => opened.add('speech'),
          ),
        ),
      ),
    );
    expect(find.text('《诡秘之主》提前合成 5 章 · 200 / 800 · 约 6 分钟'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.25);
    await tester.tap(find.byType(TaskLine));
    expect(opened, ['speech']);
    expect(tester.takeException(), isNull);
  });
}
