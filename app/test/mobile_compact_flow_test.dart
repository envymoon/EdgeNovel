import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/platform_services.dart';
import 'package:novel/reader_page.dart';
import 'package:novel/reader_state.dart';
import 'package:novel/settings_page.dart';
import 'package:novel/shelf_categories.dart';
import 'package:novel/shelf_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CompactReader extends ReaderState {
  _CompactReader() {
    shelf = const [
      ShelfItem(
        id: 1,
        path: 'compact-test.txt',
        title: '窄屏测试小说',
        author: '作者',
        chapterCount: 120,
        lastChapter: 8,
        lastOffset: 1200,
        totalBytes: 500000,
        lastOpenedAt: 1,
        encoding: 'UTF-8',
        coverHue: 120,
        lastChapterTitle: '第九章',
        pinned: false,
        genreTags: ['悬疑', '都市'],
      ),
    ];
  }

  @override
  Future<void> loadLibrary() async {}
}

class _CompactOpenReader extends _CompactReader {
  _CompactOpenReader() {
    info = BookInfo(
      id: 1,
      path: 'compact-test.txt',
      title: '窄屏测试小说',
      author: '作者',
      encoding: 'UTF-8',
      style: 'web',
      totalBytes: 500000,
      chapters: const [
        ChapterInfo(index: 0, title: '第一章 开始', start: 0, end: 10000),
        ChapterInfo(index: 1, title: '第二章 继续', start: 10000, end: 20000),
      ],
      volumes: const [],
      interstitialCount: 0,
      anomalies: const [],
      lastChapter: 0,
      lastOffset: 0,
      careerFocus: '中等',
      romanceFocus: '较少',
      growthFocus: '较多',
    );
    paragraphs = List.generate(
      30,
      (index) => Paragraph(
        kind: ParaKind.body,
        text: '这是用于验证手机窄屏阅读布局的正文段落。第 $index 段。',
        start: index * 100,
        end: index * 100 + 80,
      ),
    );
  }

  @override
  void onVisibleParagraph(int paragraphIndex) {}

  @override
  Future<void> recordChapterViewport({
    required bool atStart,
    required bool atEnd,
  }) async {}
}

class _SilentSpeech implements LocalSpeechSynthesizer {
  @override
  Future<bool> ready() async => true;

  @override
  Future<Uint8List> synthesize({
    required String text,
    required double speed,
    required int voice,
  }) async => Uint8List(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ShelfCategories.instance.initialize();
  });

  Future<void> setCompactSize(WidgetTester tester, {double width = 390}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('320 wide shelf keeps all mobile entry points reachable', (
    tester,
  ) async {
    await setCompactSize(tester, width: 320);
    final reader = _CompactReader();
    await tester.pumpWidget(
      MaterialApp(
        home: ShelfPage(
          reader: reader,
          settings: ReadingSettings(),
          onOpened: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('窄屏测试小说'), findsWidgets);
    expect(find.byTooltip('导入 TXT'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('找书'), findsOneWidget);
    expect(find.text('本地 AI'), findsOneWidget);
    expect(find.text('阅读数据'), findsOneWidget);
    expect(find.text('主题色'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact shelf can enter the real settings page without overflow',
    (tester) async {
      await setCompactSize(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: ShelfPage(
            reader: _CompactReader(),
            settings: ReadingSettings(),
            onOpened: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('阅读字体'), findsOneWidget);
      expect(find.text('模型、引擎与生成数据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('book card actions remain reachable at 320 width', (
    tester,
  ) async {
    await setCompactSize(tester, width: 320);
    final item = _CompactReader().shelf.single;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookCard(
            item: item,
            theme: readingThemes[1],
            category: '正在读',
            onTap: () {},
            onReport: () {},
            onDelete: () {},
            onDeleteForever: () {},
            onEncoding: () {},
            onRename: () {},
            onPin: () {},
            onCategory: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('扫书报告'), findsOneWidget);
    expect(find.text('分类 · 正在读'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader, chapters and assistant fit mobile width', (
    tester,
  ) async {
    await setCompactSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          reader: _CompactOpenReader(),
          settings: ReadingSettings(),
          localSpeech: _SilentSpeech(),
          enableTtsIo: false,
          onBack: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('阅读助手'), findsOneWidget);
    expect(find.byTooltip('标注'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.text('第一章 开始'), findsWidgets);
    expect(find.text('第二章 继续'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(385, 300));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('阅读助手'));
    await tester.pumpAndSettle();
    expect(find.text('回忆搜索'), findsOneWidget);
    expect(find.text('书籍详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back closes the chapter drawer before leaving reader', (
    tester,
  ) async {
    await setCompactSize(tester);
    var leftReader = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          reader: _CompactOpenReader(),
          settings: ReadingSettings(),
          localSpeech: _SilentSpeech(),
          enableTtsIo: false,
          onBack: (_) => leftReader = true,
        ),
      ),
    );
    await tester.pump();

    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
    await tester.tap(find.byIcon(Icons.list));
    await tester.pumpAndSettle();
    expect(scaffold.isDrawerOpen, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(scaffold.isDrawerOpen, isFalse);
    expect(leftReader, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('annotation selection mode returns to the compact reader', (
    tester,
  ) async {
    await setCompactSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          reader: _CompactOpenReader(),
          settings: ReadingSettings(),
          localSpeech: _SilentSpeech(),
          enableTtsIo: false,
          onBack: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('标注'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('选择正文'), findsOneWidget);
    await tester.tap(find.byTooltip('选择正文'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('拖动选择要标注的文字'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
