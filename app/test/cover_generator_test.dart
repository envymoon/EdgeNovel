import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/app_localizations.dart';
import 'package:novel/cover_generator.dart';
import 'package:novel/src/rust/api/image.dart';
import 'package:novel/src/rust/frb_generated.dart';
import 'package:novel/theme.dart';

/// The image engine without the engine: records what the dialog asks for and
/// lets the test say how drawing goes.
class _FakeImageApi implements RustLibApi {
  final draws = <(List<String>, List<String>, String, List<String>)>[];
  StreamController<CoverProgress>? drawing;
  var cancels = 0;

  @override
  Future<CoverChoices> crateApiImageCoverChoices() async => const CoverChoices(
    people: ['小女孩', '少女', '少年', '老爷爷'],
    scenes: ['仙侠', '都市', '插画'],
    groups: [
      CoverTagGroup(name: '发色', labels: ['黑发', '银发'], most: 1, personal: true),
      CoverTagGroup(name: '手持', labels: ['剑', '伞'], most: 1, personal: true),
      CoverTagGroup(
        name: '时间天气',
        labels: ['雪', '雨', '夜晚'],
        most: 2,
        personal: false,
      ),
    ],
  );

  @override
  Future<String> crateApiImageDefaultCoverScene({
    required List<String> genreTags,
  }) async => genreTags.isEmpty ? '插画' : genreTags.first;

  @override
  Stream<CoverProgress> crateApiImageDrawCover({
    required List<String> people,
    required List<String> scenes,
    required String title,
    required List<String> cues,
    required int seed,
  }) {
    draws.add((people, scenes, title, cues));
    drawing = StreamController<CoverProgress>();
    return drawing!.stream;
  }

  @override
  Future<void> crateApiImageCancelCover() async => cancels++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CoverProgress _at(int stage, int step, [String? path]) =>
    CoverProgress(stage: stage, step: step, steps: 4, path: path);

void main() {
  late _FakeImageApi api;
  late Directory tmp;

  setUpAll(() => RustLib.initMock(api: api = _FakeImageApi()));
  // Real file IO does not complete under the widget tester's fake clock, so
  // everything on disk here is done synchronously.
  setUp(() {
    api.draws.clear();
    api.cancels = 0;
    tmp = Directory.systemTemp.createTempSync('cover_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Opens the dialog from a button and keeps what it hands back.
  Future<List<String?>> open(WidgetTester tester) async {
    final result = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result.add(
              await showCoverGenerator(
                context,
                theme: readingThemes[1],
                genreTags: const ['都市'],
                title: '剑来',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  FilterChip filter(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(FilterChip)),
  );

  testWidgets('draws with the chosen person and the book\'s own setting', (
    tester,
  ) async {
    final result = await open(tester);
    // The book is tagged 都市, so that is where it starts, with a girl and
    // the title left out.
    expect(filter(tester, '都市').selected, isTrue);
    expect(filter(tester, '少女').selected, isTrue);
    expect(filter(tester, '《剑来》').selected, isFalse);

    // People and worlds are picked and unpicked, any number of them.
    await tester.tap(find.text('少年'));
    await tester.tap(find.text('老爷爷'));
    await tester.tap(find.text('少女'));
    await tester.tap(find.text('仙侠'));
    await tester.pump();
    await tester.ensureVisible(find.text('《剑来》'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('《剑来》'));
    await tester.pump();
    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(api.draws.single.$1, ['少年', '老爷爷']);
    expect(api.draws.single.$2, ['都市', '仙侠']);
    expect(api.draws.single.$3, '剑来');
    expect(api.draws.single.$4, isEmpty);

    api.drawing!.add(_at(1, 2));
    await tester.pump();
    expect(find.text('正在绘制 2 / 4'), findsOneWidget);
    // Choices are frozen while a picture is being drawn.
    expect(filter(tester, '小女孩').onSelected, isNull);

    final picture = File('${tmp.path}${Platform.pathSeparator}a.png');
    picture.writeAsBytesSync(const [0]);
    api.drawing!.add(_at(3, 4, picture.path));
    await api.drawing!.close();
    await tester.pump();
    expect(find.text('换一张'), findsOneWidget);

    await tester.tap(find.text('用这张'));
    await tester.pump();
    expect(result, [picture.path]);
    // The chosen picture is the caller's to adopt; it must still be there.
    expect(picture.existsSync(), isTrue);
  });

  testWidgets('another picture replaces the first, which is then cleaned up', (
    tester,
  ) async {
    final result = await open(tester);
    final first = File('${tmp.path}${Platform.pathSeparator}1.png');
    final second = File('${tmp.path}${Platform.pathSeparator}2.png');
    first.writeAsBytesSync(const [0]);
    second.writeAsBytesSync(const [0]);

    await tester.tap(find.text('生成'));
    await tester.pump();
    api.drawing!.add(_at(3, 4, first.path));
    await api.drawing!.close();
    await tester.pump();

    await tester.tap(find.text('换一张'));
    await tester.pump();
    api.drawing!.add(_at(3, 4, second.path));
    await api.drawing!.close();
    await tester.pump();

    await tester.tap(find.text('用这张'));
    await tester.pump();
    expect(result, [second.path]);
    expect(first.existsSync(), isFalse);
    expect(second.existsSync(), isTrue);
  });

  testWidgets('closing mid-drawing stops the engine and returns nothing', (
    tester,
  ) async {
    final result = await open(tester);
    await tester.tap(find.text('生成'));
    await tester.pump();
    api.drawing!.add(_at(1, 1));
    await tester.pump();

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(api.cancels, 1);
    expect(result, [null]);
  });

  testWidgets('tags are picked within their group', (tester) async {
    await open(tester);
    FilterChip filter(String label) => tester.widget(
      find.ancestor(of: find.text(label), matching: find.byType(FilterChip)),
    );
    Future<void> tap(String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    // Open two groups and pick: one hair colour at a time, two skies.
    await tap('发色');
    await tap('黑发');
    await tap('银发');
    expect(filter('黑发').selected, isFalse);
    await tap('时间天气');
    await tap('雪');
    await tap('夜晚');
    // Drawing animates until it ends, so no settling after this one.
    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(api.draws.single.$3, '');
    expect(api.draws.single.$4, ['银发', '雪', '夜晚']);
  });

  testWidgets('nobody on the cover leaves the person\'s tags out of reach', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('少女'));
    await tester.pump();
    await tester.ensureVisible(find.text('发色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发色'));
    await tester.pumpAndSettle();
    expect(filter(tester, '黑发').onSelected, isNull);
    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(api.draws.single.$1, isEmpty);
  });

  testWidgets('an engine error is shown and drawing can be tried again', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('生成'));
    await tester.pump();
    api.drawing!.addError('生图失败：显存不足');
    await api.drawing!.close();
    await tester.pump();
    expect(find.text('生图失败：显存不足'), findsOneWidget);
    expect(find.text('生成'), findsOneWidget);
  });
}
