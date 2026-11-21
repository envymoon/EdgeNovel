import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/annotation_page.dart';
import 'package:novel/dictionary.dart';
import 'package:novel/src/rust/api/dict.dart';
import 'package:novel/src/rust/frb_generated.dart';
import 'package:novel/theme.dart';

class _FakeDict implements RustLibApi {
  final asked = <String>[];

  @override
  Future<List<DictEntry>> crateApiDictDictLookup({
    required String path,
    required String text,
  }) async {
    asked.add(text);
    return [
      DictEntry(
        kind: DictKind.zi,
        word: '行',
        pinyin: 'xíng',
        body: '行háng\n⒈排，队列。\n行xíng\n⒈走。',
        source: '',
        example: '',
      ),
      DictEntry(
        kind: DictKind.chengyu,
        word: '行云流水',
        pinyin: 'xíng yún liú shuǐ',
        body: '比喻自然。',
        source: '某书',
        example: '文章如行云流水。',
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final fake = _FakeDict();
  setUpAll(() => RustLib.initMock(api: fake));

  test('looks up only once downloaded', () async {
    final d = Dictionary.instance..useFolder(Directory.systemTemp);
    d.installed.value = false;
    expect(await d.lookup('行'), isEmpty);
    expect(fake.asked, isEmpty);
    d.installed.value = true;
    expect(await d.lookup('行'), hasLength(2));
    expect(fake.asked, ['行']);
  });

  testWidgets('shows readings, meanings, source and example', (tester) async {
    final entries = await fake.crateApiDictDictLookup(path: '', text: '行');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DictionaryEntries(
            entries: entries,
            theme: ReadingSettings().theme,
          ),
        ),
      ),
    );
    final reading = tester.widget<Text>(find.text('行xíng'));
    expect(reading.style?.fontWeight, FontWeight.w600);
    final meaning = tester.widget<Text>(find.text('⒈走。'));
    expect(meaning.style?.fontWeight, isNot(FontWeight.w600));
    expect(find.text('出处：某书'), findsOneWidget);
    expect(find.text('例：文章如行云流水。'), findsOneWidget);
  });
}
