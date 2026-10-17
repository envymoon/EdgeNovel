import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'platform_services.dart';
import 'src/rust/api/book.dart';
import 'tts_text.dart';

/// iPhone 听书 (AppPlatformSupport.speaksByChapter): chapters spoken ahead
/// into files of their own, which is all listening plays. Listening is mostly
/// with the screen locked, where iOS lends no GPU to speak as the voice goes.
///
/// A chapter is one WAV holding its sentences with the pauses between them
/// already in, and beside it an index of where each sentence starts, so the
/// reader can follow the voice. It counts once the index is written, which is
/// last; until then it is a `.wav.part` of the sentences so far and a
/// `.part.json` saying how far it got, so speaking it again carries on from
/// there.
///
/// Everything here can be spoken again: deleting it costs only the time.
class TtsChapters extends ChangeNotifier {
  TtsChapters._();
  static final instance = TtsChapters._();

  /// Where the chapters go instead, for tests.
  @visibleForTesting
  Directory? root;

  Directory get _root =>
      root ?? AppServices.instance.storage.supportChild('tts_chapters');

  String _book(int id) => '${_root.path}${Platform.pathSeparator}$id';

  String _base(int book, int chapter) =>
      '${_book(book)}${Platform.pathSeparator}$chapter';

  /// The chapter as spoken, or null when it is not (or was spoken from a
  /// different book that had the same id before it).
  Future<SpokenChapter?> chapter(BookInfo book, int index) async {
    if (index < 0 || index >= book.chapters.length) return null;
    final base = _base(book.id, index);
    try {
      final meta = await _readJson(File('$base.json'));
      final wav = File('$base.wav');
      if (meta == null || !await wav.exists()) return null;
      if (meta['title'] != book.chapters[index].title) return null;
      final rate = meta['rate'] as int;
      return SpokenChapter(
        path: wav.path,
        voice: meta['voice'] as String,
        sentences: [
          for (final s in meta['s'] as List)
            SpokenSentence(
              s[0] as int,
              s[1] as int,
              s[2] as int,
              (s[3] as int) * 1000 ~/ rate,
            ),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// Start (or carry on with) speaking chapter [index] of [book] as [utts].
  /// What was spoken before in the same voice from the same text is kept.
  Future<ChapterWriter> write(
    BookInfo book,
    int index,
    String voice,
    List<TtsUtt> utts,
  ) async {
    await Directory(_book(book.id)).create(recursive: true);
    await _writeJson(
      File('${_book(book.id)}${Platform.pathSeparator}book.json'),
      {'title': book.title},
    );
    final base = _base(book.id, index);
    final title = book.chapters[index].title;
    final text = _fnv(utts.map((u) => u.text));
    final part = File('$base.wav.part');
    final progress = File('$base.part.json');
    var next = 0;
    var bytes = 0;
    var rate = 0;
    var spans = <List<int>>[];
    final was = await _readJson(progress);
    if (was != null &&
        was['voice'] == voice &&
        was['title'] == title &&
        was['text'] == text &&
        await part.exists() &&
        await part.length() >= _head + (was['bytes'] as int)) {
      next = was['n'] as int;
      bytes = was['bytes'] as int;
      rate = was['rate'] as int;
      spans = [
        for (final s in was['s'] as List) [for (final v in s as List) v as int],
      ];
    }
    final raf = await part.open(mode: FileMode.append);
    // Whatever was written after the last sentence counted goes. Room is
    // left for the header, written once the chapter is finished and its
    // length known.
    await raf.truncate(_head + bytes);
    await raf.setPosition(_head + bytes);
    return ChapterWriter._(
      this,
      base: base,
      voice: voice,
      title: title,
      text: text,
      utts: utts,
      raf: raf,
      next: next,
      bytes: bytes,
      rate: rate,
      spans: spans,
    );
  }

  /// Everything spoken, by book, for 已合成.
  Future<List<SpokenBook>> list() async {
    final out = <SpokenBook>[];
    if (!await _root.exists()) return out;
    await for (final d in _root.list()) {
      if (d is! Directory) continue;
      final id = int.tryParse(d.path.split(Platform.pathSeparator).last);
      if (id == null) continue;
      final meta = await _readJson(
        File('${d.path}${Platform.pathSeparator}book.json'),
      );
      final chapters = <int, SpokenEntry>{};
      await for (final f in d.list()) {
        if (f is! File) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        final m = RegExp(
          r'^(\d+)\.(wav|json|wav\.part|part\.json)$',
        ).firstMatch(name);
        if (m == null) continue;
        final c = int.parse(m[1]!);
        final e = chapters[c] ??= SpokenEntry(c);
        e.bytes += await f.length();
        if (m[2] == 'json') {
          e.complete = true;
          e.title = (await _readJson(f))?['title'] as String? ?? e.title;
        } else if (m[2] == 'part.json') {
          e.title ??= (await _readJson(f))?['title'] as String?;
        }
      }
      if (chapters.isEmpty) continue;
      out.add(
        SpokenBook(
          id,
          meta?['title'] as String? ?? '',
          chapters.values.toList()..sort((a, b) => a.index.compareTo(b.index)),
        ),
      );
    }
    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  Future<int> totalBytes() async {
    var n = 0;
    for (final b in await list()) {
      n += b.bytes;
    }
    return n;
  }

  Future<void> deleteChapter(int book, int index) async {
    final base = _base(book, index);
    // The index first: without it the rest is never played.
    for (final ext in ['json', 'wav', 'wav.part', 'part.json']) {
      final f = File('$base.$ext');
      if (await f.exists()) await f.delete();
    }
    final d = Directory(_book(book));
    if (await d.exists() &&
        !await d.list().any(
          (f) => !f.path.endsWith('${Platform.pathSeparator}book.json'),
        )) {
      await d.delete(recursive: true);
    }
    notifyListeners();
  }

  Future<void> deleteBook(int book) async {
    final d = Directory(_book(book));
    if (await d.exists()) await d.delete(recursive: true);
    notifyListeners();
  }

  void _changed() => notifyListeners();

  /// The WAV header's bytes, ahead of the samples.
  static const _head = 44;

  static Future<Map<String, dynamic>?> _readJson(File f) async {
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Written aside and renamed, so a crash never leaves half of one.
  static Future<void> _writeJson(File f, Map<String, Object?> value) async {
    final part = File('${f.path}.tmp');
    await part.writeAsString(jsonEncode(value), flush: true);
    await part.rename(f.path);
  }

  /// 32-bit FNV-1a over the sentences, to tell a chapter's text changed.
  static int _fnv(Iterable<String> texts) {
    var h = 0x811c9dc5;
    for (final t in texts) {
      for (final c in t.codeUnits) {
        h = ((h ^ c) * 0x01000193) & 0xffffffff;
      }
      h = ((h ^ 0x0a) * 0x01000193) & 0xffffffff;
    }
    return h;
  }
}

/// One sentence of a spoken chapter: where it is in the text, and where it
/// starts in the audio.
class SpokenSentence {
  const SpokenSentence(this.paragraph, this.start, this.end, this.ms);

  final int paragraph;
  final int start;
  final int end;
  final int ms;
}

class SpokenChapter {
  const SpokenChapter({
    required this.path,
    required this.voice,
    required this.sentences,
  });

  final String path;
  final String voice;
  final List<SpokenSentence> sentences;

  /// The sentence playing at [at].
  int sentenceAt(Duration at) {
    final ms = at.inMilliseconds;
    var lo = 0;
    var hi = sentences.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (sentences[mid].ms <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

class SpokenBook {
  SpokenBook(this.id, this.title, this.chapters);

  final int id;
  final String title;
  final List<SpokenEntry> chapters;

  int get bytes => chapters.fold(0, (n, c) => n + c.bytes);
}

class SpokenEntry {
  SpokenEntry(this.index);

  final int index;
  String? title;
  bool complete = false;
  int bytes = 0;
}

/// A chapter being spoken, one sentence at a time ([add], [skip]) and then
/// [finish]ed into its WAV. [close] without finishing keeps what was spoken
/// for next time.
class ChapterWriter {
  ChapterWriter._(
    this._store, {
    required this.base,
    required this.voice,
    required this.title,
    required this.text,
    required this.utts,
    required RandomAccessFile raf,
    required this.next,
    required int bytes,
    required int rate,
    required List<List<int>> spans,
  }) : _raf = raf,
       _bytes = bytes,
       _rate = rate,
       _spans = spans;

  final TtsChapters _store;
  final String base;
  final String voice;
  final String title;
  final int text;
  final List<TtsUtt> utts;
  final RandomAccessFile _raf;

  /// The first sentence still to speak.
  int next;
  int _bytes;
  int _rate;
  final List<List<int>> _spans;
  bool _closed = false;

  bool get done => next >= utts.length;

  /// Sentence [next], spoken: [wav] as the engine gave it.
  Future<void> add(Uint8List wav) async {
    final (rate, pcm) = _pcm(wav);
    if (_rate == 0) _rate = rate;
    if (rate != _rate) throw '采样率不一致';
    await _append(pcm);
  }

  /// Sentence [next] left out: the engine would not speak it.
  Future<void> skip() => _append(Uint8List(0));

  Future<void> _append(Uint8List pcm) async {
    final u = utts[next];
    final rate = _rate == 0 ? 24000 : _rate;
    _spans.add([u.paragraphIndex, u.start, u.end, _bytes ~/ 2]);
    // The pause after it, longer where a paragraph ends: the one playback
    // left between sentences when it spoke them as it went.
    final last = next + 1 >= utts.length;
    final ms = last || utts[next + 1].paragraphIndex != u.paragraphIndex
        ? 480
        : 220;
    final gap = Uint8List(rate * ms ~/ 1000 * 2);
    final even = pcm.length & ~1;
    await _raf.writeFrom(pcm, 0, even);
    await _raf.writeFrom(gap);
    await _raf.flush();
    _bytes += even + gap.length;
    next++;
    await TtsChapters._writeJson(File('$base.part.json'), {
      'voice': voice,
      'title': title,
      'text': text,
      'n': next,
      'bytes': _bytes,
      'rate': rate,
      's': _spans,
    });
  }

  /// Every sentence in: the chapter becomes playable.
  Future<void> finish() async {
    final rate = _rate == 0 ? 24000 : _rate;
    await _raf.setPosition(0);
    await _raf.writeFrom(_header(_bytes, rate));
    await _raf.flush();
    await close();
    // An index of another voice's audio never stands beside the new audio.
    final index = File('$base.json');
    if (await index.exists()) await index.delete();
    await File('$base.wav.part').rename('$base.wav');
    await TtsChapters._writeJson(index, {
      'voice': voice,
      'title': title,
      'rate': rate,
      's': _spans,
    });
    await File('$base.part.json').delete();
    _store._changed();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }

  /// The sample rate and the samples of a WAV from the engine.
  static (int, Uint8List) _pcm(Uint8List wav) {
    final d = ByteData.sublistView(wav);
    String tag(int at) => String.fromCharCodes(wav.sublist(at, at + 4));
    if (wav.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw '不是 WAV';
    }
    var rate = 0;
    var at = 12;
    while (at + 8 <= wav.length) {
      final size = d.getUint32(at + 4, Endian.little);
      if (tag(at) == 'fmt ') rate = d.getUint32(at + 12, Endian.little);
      if (tag(at) == 'data') {
        final end = (at + 8 + size).clamp(at + 8, wav.length);
        return (rate, Uint8List.sublistView(wav, at + 8, end));
      }
      at += 8 + size + (size & 1);
    }
    throw 'WAV 无数据';
  }

  /// 16-bit mono PCM at [rate].
  static Uint8List _header(int bytes, int rate) {
    final h = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    h.setUint32(4, 36 + bytes, Endian.little);
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
    h.setUint32(40, bytes, Endian.little);
    return h.buffer.asUint8List();
  }
}
