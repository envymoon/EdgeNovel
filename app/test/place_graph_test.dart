import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/place_graph_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/src/rust/frb_generated.dart';
import 'package:novel/theme.dart';

/// A made-up book: a town, a school two chapters away, and back.
class _FakePlaces implements RustLibApi {
  @override
  Future<PlaceAtlas> crateApiBookPlaceAtlas({
    required String path,
    required int bookId,
    required int upToChapter,
  }) async => PlaceAtlas(
    places: const [
      PlaceNode(
        name: '青石镇',
        mentions: 40,
        chapters: 6,
        firstChapter: 0,
        settings: 5,
        people: ['甲', '乙'],
      ),
      PlaceNode(
        name: '白鹿书院',
        mentions: 30,
        chapters: 4,
        firstChapter: 2,
        settings: 3,
        people: ['甲'],
      ),
      PlaceNode(
        name: '书院后山',
        mentions: 9,
        chapters: 2,
        firstChapter: 3,
        parent: 1,
        settings: 0,
        people: [],
      ),
    ],
    stages: [
      PlaceStage(from: 0, to: 3, area: 0, spots: Uint32List.fromList([0, 1])),
      PlaceStage(from: 4, to: 7, area: 1, spots: Uint32List.fromList([1, 2])),
    ],
    setting: Int32List.fromList([0, 0, 1, 1, 0, 0, 1, 0]),
    upto: 8,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _book = ShelfItem(
  id: 1,
  path: 'book.txt',
  title: '书',
  chapterCount: 8,
  lastChapter: 0,
  lastOffset: 0,
  totalBytes: 1,
  addedAt: 0,
  encoding: 'utf-8',
  coverHue: 0,
  lastChapterTitle: '',
  pinned: false,
  genreTags: [],
);

void main() {
  setUpAll(() => RustLib.initMock(api: _FakePlaces()));

  testWidgets('routes come from the setting changing, and a stage narrows them', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlaceGraphPage(book: _book, settings: ReadingSettings()),
      ),
    );
    await tester.pumpAndSettle();

    // 青石镇 ↔ 白鹿书院 is one route, travelled four times.
    expect(find.text('全书 8 章 · 3 处 · 2 段地图 · 1 条路线'), findsOneWidget);

    await tester.tap(find.text('青石镇 5'));
    await tester.pumpAndSettle();
    expect(find.text('来往：白鹿书院 4 次'), findsOneWidget);
    expect(find.text('常在这里的人：甲、乙'), findsOneWidget);
    expect(find.text('章节：1、2、5、6、8'), findsOneWidget);

    // The second map, chapters 5–8: in from the school, over and back again.
    // Too few places stood in there, so its spots fill the graph out.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 5–8 章'));
    await tester.pumpAndSettle();
    expect(find.text('第 5–8 章 · 3 处 · 1 条路线'), findsOneWidget);
    await tester.tap(find.text('青石镇 5'));
    await tester.pumpAndSettle();
    expect(find.text('来往：白鹿书院 3 次'), findsOneWidget);
    expect(find.text('章节：5、6、8'), findsOneWidget);
  });
}
