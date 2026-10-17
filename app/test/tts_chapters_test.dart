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
    await dir.delete(recursive: true);
  });

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
    expect(part.path, endsWith('.part.wav'));
    final head = ByteData.sublistView(await File(part.path).readAsBytes());
    expect(head.getUint32(40, Endian.little), (1000 + 220) * 24 * 2);

    // Spoken again later: it carries on from the second sentence.
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
    // 1 s, a pause of 0.22 s; 0.5 s, then 0.48 s at the paragraph's end;
    // the sentence left out is a pause of its own.
    expect(spoken.sentences.map((s) => s.ms), [0, 1220, 2200]);
    expect(spoken.sentences.map((s) => s.paragraph), [0, 0, 1]);
    expect(spoken.sentenceAt(const Duration(milliseconds: 1500)), 1);
    expect(spoken.sentenceAt(const Duration(milliseconds: 9000)), 2);

    final wav = await File(spoken.path).readAsBytes();
    final d = ByteData.sublistView(wav);
    final samples = (1000 + 220 + 500 + 480 + 480) * 24;
    expect(d.getUint32(40, Endian.little), samples * 2);
    expect(wav.length, 44 + samples * 2);
    expect(d.getInt16(44, Endian.little), 1000);
  });

  test('a chapter half spoken by an earlier version carries on', () async {
    final b = book();
    var w = await store.write(b, 0, 'serena', utts);
    await w.add(clip(1000));
    await w.close();
    // The name the earlier version gave it.
    await File('${dir.path}/7/0.part.wav').rename('${dir.path}/7/0.wav.part');
    expect(await store.chapter(b, 0), isNull);

    w = await store.write(b, 0, 'serena', utts);
    expect(w.next, 1);
    await w.close();
    expect((await store.chapter(b, 0))!.sentences, hasLength(1));
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
