import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/place_graph_page.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/src/rust/frb_generated.dart';
import 'package:novel/theme.dart';

/// A made-up book: a single town so tapping the center of the canvas hits it.
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
    ];
    final kept = [
      for (final p in allPlaces)
        if (!_removed.contains(p.name)) p,
    ];
    return PlaceAtlas(
      places: kept,
      stages: [
        PlaceStage(from: 0, to: 5, area: 0, spots: Uint32List.fromList([0])),
      ],
      setting: Int32List.fromList(kept.isEmpty ? [-1] : [0, 0, 0, 0, 0]),
      upto: 5,
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
  chapterCount: 5,
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

  testWidgets('full-book map hides bottom list until a place is tapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlaceGraphPage(book: _book, settings: ReadingSettings()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('全书 5 章 · 1 处主要地点 · 0 条路线（点击地点查看详情）'),
      findsOneWidget,
    );
    // Details panel stays hidden until a node is tapped.
    expect(find.text('常在这里的人：甲、乙'), findsNothing);

    // Tap the single node centered on the canvas.
    final canvas = find.byType(CustomPaint).last;
    await tester.tap(canvas);
    await tester.pumpAndSettle();
    expect(find.text('常在这里的人：甲、乙'), findsOneWidget);
    expect(find.text('章节：1、2、3、4、5'), findsOneWidget);

    // Remove the place, then restore it from the AppBar action.
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('已移除 1'), findsOneWidget);

    await tester.tap(find.text('已移除 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 青石镇'));
    await tester.pumpAndSettle();
    expect(
      find.text('全书 5 章 · 1 处主要地点 · 0 条路线（点击地点查看详情）'),
      findsOneWidget,
    );
  });
}
