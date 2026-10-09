import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/shelf_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/theme.dart';

void main() {
  testWidgets('shelf shows only the current cached summary for an opened book', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    Future<void> show({String? summary, int? opened = 1}) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: BookCard(
        item: ShelfItem(id: 1, path: 'test.txt', title: '测试书',
          chapterCount: 100, lastChapter: 8, lastOffset: 1200,
          totalBytes: 500000, lastOpenedAt: opened, encoding: 'UTF-8',
          coverHue: 120, lastChapterTitle: '', lastChapterSummary: summary,
          pinned: false, genreTags: const [],
        ),
        theme: readingThemes[1], category: null,
        onTap: () {}, onReport: () {}, onDelete: () {}, onDeleteForever: () {},
        onRename: () {}, onEncoding: () {}, onPin: () {}, onCategory: () {},
      ))));
    }
    try {
      await show(summary: '主角在此章找到线索。');
      expect(find.text('读到 第 9 章'), findsOneWidget);
      expect(find.text('主角在此章找到线索。'), findsOneWidget);
      final summary = tester.widget<Text>(find.text('主角在此章找到线索。'));
      expect(summary.maxLines, 2);
      await show();
      expect(find.text('读到 第 9 章'), findsOneWidget);
      expect(find.text('主角在此章找到线索。'), findsNothing);
      await show(summary: '主角在此章找到线索。', opened: null);
      expect(find.text('尚未开始'), findsOneWidget);
      expect(find.text('主角在此章找到线索。'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
