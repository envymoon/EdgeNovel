import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/place_graph_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/src/rust/frb_generated.dart';
import 'package:novel/theme.dart';

/// A made-up book: a town, a school two chapters away, and back.
class _FakePlaces implements RustLibApi {
  final Set<String> _removed = {};

  @override
  Future<PlaceAtlas> crateApiBookPlaceAtlas({
    required String path,
    required int bookId,
    required int upToChapter,
  }) async {
    final allPlaces = [
      const PlaceNode(
        name: '青石镇',
        mentions: 40,
        chapters: 6,
        firstChapter: 0,
        rank: 2,
        settings: 5,
        people: ['甲', '乙'],
      ),
      const PlaceNode(
        name: '白鹿书院',
        mentions: 30,
        chapters: 4,
        firstChapter: 2,
        rank: 2,
        settings: 3,
        people: ['甲'],
      ),
      const PlaceNode(
        name: '书院后山',
        mentions: 9,
        chapters: 2,
        firstChapter: 3,
        rank: 1,
        parent: 1,
        settings: 0,
        people: [],
      ),
    ];
    final kept = [
      for (final p in allPlaces)
        if (!_removed.contains(p.name)) p,
    ];
    return PlaceAtlas(
      places: kept,
      stages: [
        PlaceStage(from: 0, to: 3, area: 0, spots: Uint32List.fromList([0, 1])),
        PlaceStage(
          from: 4,
          to: 7,
          area: kept.length > 1 ? 1 : 0,
          spots: Uint32List.fromList(kept.length > 2 ? [1, 2] : [0]),
        ),
      ],
      setting: Int32List.fromList([
        0,
        0,
        kept.length > 1 ? 1 : 0,
        kept.length > 1 ? 1 : 0,
        0,
        0,
        kept.length > 1 ? 1 : 0,
        0,
      ]),
      upto: 8,
      removed: _removed.toList(),
    );
  }

  @override
  Future<void> crateApiBookRemovePlace({
    required int bookId,
    required String name,
    required bool removed,
  }) async {
    if (removed) {
      _removed.add(name);
    } else {
      _removed.remove(name);
    }
  }

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
  final fake = _FakePlaces();
  setUpAll(() => RustLib.initMock(api: fake));

  testWidgets('routes, stage return-to-full-book, and manual place removal', (
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

    // Switch to stage 2 and verify one-tap return to 全书.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 5–8 章'));
    await tester.pumpAndSettle();
    expect(find.text('第 5–8 章 · 3 处 · 1 条路线'), findsOneWidget);
    expect(find.text('返回全书'), findsOneWidget);

    await tester.tap(find.text('返回全书'));
    await tester.pumpAndSettle();
    expect(find.text('全书 8 章 · 3 处 · 2 段地图 · 1 条路线'), findsOneWidget);

    // Remove a place by hand, then restore it.
    await tester.tap(find.text('书院后山 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('已移除 1 处（点击恢复）'), findsOneWidget);
    expect(find.text('+ 书院后山'), findsOneWidget);

    await tester.tap(find.text('+ 书院后山'));
    await tester.pumpAndSettle();
    expect(find.text('书院后山 0'), findsOneWidget);
  });
}
