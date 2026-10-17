import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/tts_chapters.dart';
import 'package:novel/tts_text.dart';

/// A WAV the way the engine gives one: 24 kHz 16-bit mono, [ms] long.
Uint8List clip(int ms, {int rate = 24000}) {
  final n = rate * ms ~/ 1000 * 2;
  final h = ByteData(44 + n);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + n, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, n, Endian.little);
  for (var i = 44; i < 44 + n; i += 2) {
    h.setInt16(i, 1000, Endian.little);
  }
  return h.buffer.asUint8List();
}

BookInfo book({int id = 7, String first = '第一章 开始'}) => BookInfo(
  id: id,
  path: 'tts-test.txt',
  title: '听书测试',
  author: null,
  encoding: 'UTF-8',
  style: 'web',
  totalBytes: 1000,
  chapters: [
    ChapterInfo(index: 0, title: first, start: 0, end: 500),
    const ChapterInfo(index: 1, title: '第二章 继续', start: 500, end: 1000),
  ],
  volumes: const [],
  interstitialCount: 0,
  anomalies: const [],
  lastChapter: 0,
  lastOffset: 0,
  careerFocus: '',
  romanceFocus: '',
  growthFocus: '',
);

const utts = [
  TtsUtt(0, 0, 4, '第一句。'),
  TtsUtt(0, 4, 8, '第二句。'),
  TtsUtt(1, 0, 4, '第三句。'),
];

void main() {
  late Directory dir;
  final store = TtsChapters.instance;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tts_chapters_test');
    store.root = dir;
  });

  tearDown(() async {
    store.root = null;
    TtsChapters.pieceSeconds = 60;
    await dir.delete(recursive: true);
  });

  int samples(String path) =>
      ByteData.sublistView(File(path).readAsBytesSync()).getUint32(
        40,
        Endian.little,
      ) ~/
      2;

  test('what is spoken plays at once, and speaking carries on', () async {
    final b = book();
    expect(await store.chapter(b, 0), isNull);
    var w = await store.write(b, 0, 'serena', utts);
    await w.add(clip(1000));
    await w.close();

    // One sentence in: it plays, as a WAV of what there is.
    final part = await store.chapter(b, 0);
    expect(part, isNotNull);
    expect(part!.complete, isFalse);
    expect(part.sentences.map((s) => s.ms), [0]);
    expect(part.pieces, hasLength(1));
    expect(part.pieces.single.path, endsWith('.0.wav'));
    expect(samples(part.pieces.single.path), (1000 + 220) * 24);

    // Spoken again later: it carries on from the second sentence, into a
    // piece of its own.
    w = await store.write(b, 0, 'serena', utts);
    expect(w.next, 1);
    await w.add(clip(500));
    await w.skip();
    expect(w.done, isTrue);
    await w.finish();

    final spoken = await store.chapter(b, 0);
    expect(spoken, isNotNull);
    expect(spoken!.complete, isTrue);
    expect(spoken.voice, 'serena');
    expect(spoken.id, part.id);
    // 1 s, a pause of 0.22 s; 0.5 s, then 0.48 s at the paragraph's end;
    // the sentence left out is a pause of its own.
    expect(spoken.sentences.map((s) => s.ms), [0, 1220, 2200]);
    expect(spoken.sentences.map((s) => s.paragraph), [0, 0, 1]);
    expect(spoken.sentenceAt(const Duration(milliseconds: 1500)), 1);
    expect(spoken.sentenceAt(const Duration(milliseconds: 9000)), 2);
    expect(spoken.pieces.map((p) => p.ms), [0, 1220]);
    expect(spoken.pieceAt(const Duration(milliseconds: 1000)), 0);
    expect(spoken.pieceAt(const Duration(milliseconds: 2500)), 1);

    expect(samples(spoken.pieces[0].path), (1000 + 220) * 24);
    final wav = await File(spoken.pieces[1].path).readAsBytes();
    expect(wav.length, 44 + (500 + 480 + 480) * 24 * 2);
    expect(ByteData.sublistView(wav).getInt16(44, Endian.little), 1000);
    // The index and the two pieces: nothing else is left behind.
    final names = Directory(
      '${dir.path}/7',
    ).listSync().map((f) => f.uri.pathSegments.last);
    expect(names.where((n) => n.startsWith('0.')), hasLength(3));
  });

  test('a long chapter goes in pieces, closed where paragraphs end', () async {
    TtsChapters.pieceSeconds = 1;
    final b = book();
    const four = [
      TtsUtt(0, 0, 4, '第一句。'),
      TtsUtt(0, 4, 8, '第二句。'),
      TtsUtt(1, 0, 4, '第三句。'),
      TtsUtt(2, 0, 4, '第四句。'),
    ];
    final w = await store.write(b, 0, 'serena', four);
    for (var i = 0; i < 4; i++) {
      await w.add(clip(800));
    }
    await w.finish();
    final spoken = (await store.chapter(b, 0))!;
    expect(spoken.sentences.map((s) => s.ms), [0, 1020, 2300, 3580]);
    // Past a second only within the paragraph: it waits for the
    // paragraph's end.
    expect(spoken.pieces.map((p) => p.ms), [0, 2300, 3580]);
    expect(spoken.pieces.map((p) => samples(p.path)), [
      2300 * 24,
      1280 * 24,
      1280 * 24,
    ]);
  });

  test('a chapter half spoken by an earlier version carries on', () async {
    final b = book();
    var w = await store.write(b, 0, 'serena', utts);
    await w.add(clip(1000));
    await w.close();
    // As the earlier version left it: one WAV, under the name it gave it.
    final progress = File('${dir.path}/7/0.part.json');
    final was = jsonDecode(await progress.readAsString()) as Map;
    final first = '${dir.path}/7/0.${was['tag']}.0.wav';
    await File(first).rename('${dir.path}/7/0.wav.part');
    await File('${dir.path}/7/0.${was['tag']}.1.wav').delete();
    await progress.writeAsString(
      jsonEncode({...was}..remove('tag')..remove('pieces')),
    );
    expect(await store.chapter(b, 0), isNull);

    w = await store.write(b, 0, 'serena', utts);
    expect(w.next, 1);
    await w.add(clip(500));
    await w.close();
    // Spoken on into the WAV it had.
    final part = (await store.chapter(b, 0))!;
    expect(part.sentences.map((s) => s.ms), [0, 1220]);
    expect(part.pieces.map((p) => p.ms), [0]);
  });

  test('a chapter an earlier version finished plays until spoken over', () async {
    final b = book();
    final w = await store.write(b, 0, 'serena', utts.sublist(0, 1));
    await w.add(clip(100));
    await w.finish();
    // As the earlier version left it: one WAV and an index without pieces.
    final index = File('${dir.path}/7/0.json');
    final meta = jsonDecode(await index.readAsString()) as Map;
    await File(
      '${dir.path}/7/0.${meta['tag']}.0.wav',
    ).rename('${dir.path}/7/0.wav');
    await index.writeAsString(
      jsonEncode({...meta}..remove('tag')..remove('pieces')),
    );
    final old = (await store.chapter(b, 0))!;
    expect(old.pieces.single.path, endsWith('0.wav'));

    var again = await store.write(b, 0, 'vivian', utts.sublist(0, 1));
    expect(again.next, 0);
    await again.close();
    expect((await store.chapter(b, 0))!.voice, 'serena');
    again = await store.write(b, 0, 'vivian', utts.sublist(0, 1));
    await again.add(clip(100));
    await again.finish();
    expect((await store.chapter(b, 0))!.voice, 'vivian');
    expect(await File('${dir.path}/7/0.wav').exists(), isFalse);
  });

  test('another voice or other text starts the chapter over', () async {
    final b = book();
    var w = await store.write(b, 0, 'serena', utts);
    await w.add(clip(100));
    await w.close();
    w = await store.write(b, 0, 'vivian', utts);
    expect(w.next, 0);
    await w.close();
    w = await store.write(b, 0, 'vivian', utts.sublist(1));
    expect(w.next, 0);
    await w.close();
  });

  test('a book that took an old id finds nothing of the old one', () async {
    final w = await store.write(book(), 0, 'serena', utts.sublist(0, 1));
    await w.add(clip(100));
    await w.finish();
    expect(await store.chapter(book(), 0), isNotNull);
    expect(await store.chapter(book(first: '楔子'), 0), isNull);
  });

  test('已合成 lists, sizes and deletes', () async {
    final b = book();
    var w = await store.write(b, 0, 'serena', utts.sublist(0, 1));
    await w.add(clip(100));
    await w.finish();
    w = await store.write(b, 1, 'serena', utts);
    await w.add(clip(100));
    await w.close();

    var books = await store.list();
    expect(books, hasLength(1));
    expect(books.single.title, '听书测试');
    expect(books.single.chapters.map((c) => c.complete), [true, false]);
    expect(books.single.chapters.first.title, '第一章 开始');
    expect(await store.totalBytes(), greaterThan(4800 * 2));

    await store.deleteChapter(b.id, 0);
    expect(await store.chapter(b, 0), isNull);
    books = await store.list();
    expect(books.single.chapters.map((c) => c.index), [1]);

    await store.deleteChapter(b.id, 1);
    expect(await store.list(), isEmpty);
    expect(await Directory('${dir.path}/7').exists(), isFalse);
  });
}
