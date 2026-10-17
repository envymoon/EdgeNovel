import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_services.dart';
import 'src/rust/api/book.dart';
import 'tts_text.dart';

/// iPhone 听书 (AppPlatformSupport.speaksByChapter): chapters spoken ahead
/// into files of their own, which is all listening plays. Listening is mostly
/// with the screen locked, where iOS lends no GPU to speak as the voice goes.
///
/// A chapter is a run of pieces, a minute or so of speech each, holding its
/// sentences with the pauses between them already in, and beside them an
/// index of where each sentence and each piece starts, so the reader can
/// follow the voice. The piece being spoken into is a WAV, which plays as it
/// grows; once it is long enough it is closed, at a paragraph's end, and made
/// an .m4a (AAC, as a book app's audio is, a sixth of the size) while speaking
/// goes on into the next, and so is the one in hand when speaking stops. Each
/// is made once, from the voice's own samples. The chapter is finished once
/// its index is written, which is last; until then a `.part.json` says how
/// far it got: what is in plays, and speaking it again carries on from there.
///
/// Everything here can be spoken again: deleting it costs only the time.
class TtsChapters extends ChangeNotifier {
  TtsChapters._();
  static final instance = TtsChapters._();

  /// Where the chapters go instead, for tests.
  @visibleForTesting
  Directory? root;

  /// How long a piece runs before it is closed at a paragraph's end, or at
  /// twice that anywhere.
  @visibleForTesting
  static int pieceSeconds = 60;

  Directory get _root =>
      root ?? AppServices.instance.storage.supportChild('tts_chapters');

  String _book(int id) => '${_root.path}${Platform.pathSeparator}$id';

  String _base(int book, int chapter) =>
      '${_book(book)}${Platform.pathSeparator}$chapter';

  /// The file playing now, which a WAV made smaller is not deleted under;
  /// such a WAV goes once playback moves off it.
  String? get playing => _playing;
  String? _playing;
  set playing(String? path) {
    final was = _playing;
    _playing = path;
    if (was == null || was == path || !was.endsWith('.wav')) return;
    try {
      if (File('${was.substring(0, was.length - 4)}.m4a').existsSync()) {
        File(was).deleteSync();
      }
    } catch (_) {}
  }

  /// The chapter as spoken, as far as it has been, or null when none of it
  /// is (or it was spoken from a different book that had the same id
  /// before it).
  Future<SpokenChapter?> chapter(BookInfo book, int index) async {
    if (index < 0 || index >= book.chapters.length) return null;
    final base = _base(book.id, index);
    final title = book.chapters[index].title;
    try {
      final meta = await _readJson(File('$base.json'));
      if (meta != null && meta['title'] == title) {
        final pieces = await _pieces(base, meta, complete: true);
        if (pieces != null) {
          return _spoken(base, meta, pieces, complete: true);
        }
      }
      final part = await _readJson(File('$base.part.json'));
      if (part == null || part['title'] != title || (part['n'] as int) == 0) {
        return null;
      }
      final pieces = await _pieces(base, part, complete: false);
      if (pieces == null) return null;
      return _spoken(base, part, pieces, complete: false);
    } catch (_) {
      return null;
    }
  }

  /// The pieces of the audio an index stands for, and where each starts;
  /// null when one is missing.
  Future<List<SpokenPiece>?> _pieces(
    String base,
    Map<String, dynamic> meta, {
    required bool complete,
  }) async {
    final starts = meta['pieces'] as List?;
    if (starts == null) {
      final path = await _whole(base, meta, complete: complete);
      return path == null ? null : [SpokenPiece(path, 0)];
    }
    final rate = meta['rate'] as int;
    final tag = meta['tag'] as String;
    final total = (meta['bytes'] as int) ~/ 2;
    final out = <SpokenPiece>[];
    for (var k = 0; k < starts.length; k++) {
      final start = starts[k] as int;
      final end = k + 1 < starts.length ? starts[k + 1] as int : total;
      // The piece speaking goes on into next, with nothing in it yet.
      if (end <= start) continue;
      final path = await _piece(_piecePath(base, tag, k), end - start);
      if (path == null) return null;
      out.add(SpokenPiece(path, start * 1000 ~/ rate));
    }
    return out.isEmpty ? null : out;
  }

  /// A piece as it plays: its .m4a once made, the WAV of [samples] until
  /// then. The WAV goes once the .m4a stands in for it and nothing plays it.
  Future<String?> _piece(String stem, int samples) async {
    final m4a = File('$stem.m4a');
    final wav = File('$stem.wav');
    if (await m4a.exists()) {
      if (playing != wav.path && await wav.exists()) {
        try {
          await wav.delete();
        } catch (_) {}
      }
      return m4a.path;
    }
    if (await wav.exists() && await wav.length() >= _head + samples * 2) {
      return wav.path;
    }
    return null;
  }

  /// A chapter an earlier version spoke into one file.
  Future<String?> _whole(
    String base,
    Map<String, dynamic> meta, {
    required bool complete,
  }) async {
    if (complete) return _piece(base, 0);
    final audio = File('$base.part.wav');
    return await audio.exists() &&
            await audio.length() >= _head + (meta['bytes'] as int)
        ? audio.path
        : null;
  }

  static String _piecePath(String base, String tag, int k) => '$base.$tag.$k';

  static SpokenChapter _spoken(
    String base,
    Map<String, dynamic> meta,
    List<SpokenPiece> pieces, {
    required bool complete,
  }) {
    final rate = meta['rate'] as int;
    return SpokenChapter(
      id: '$base.${meta['tag'] ?? ''}',
      pieces: pieces,
      voice: meta['voice'] as String,
      complete: complete,
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
    final progress = File('$base.part.json');
    await _upgrade(base, progress);
    String tag;
    var starts = <int>[0];
    var next = 0;
    var bytes = 0;
    var rate = 0;
    var spans = <List<int>>[];
    final was = await _readJson(progress);
    if (was != null &&
        was['voice'] == voice &&
        was['title'] == title &&
        was['text'] == text &&
        was['pieces'] is List &&
        await _carriesOn(base, was)) {
      tag = was['tag'] as String;
      starts = [for (final v in was['pieces'] as List) v as int];
      next = was['n'] as int;
      bytes = was['bytes'] as int;
      rate = was['rate'] as int;
      spans = [
        for (final s in was['s'] as List) [for (final v in s as List) v as int],
      ];
      // Closed before the app last went, and not made smaller then.
      for (var k = 0; k + 1 < starts.length; k++) {
        final stem = _piecePath(base, tag, k);
        if (!await File('$stem.m4a').exists()) unawaited(_compress(stem));
      }
    } else {
      tag = _newTag();
      // An earlier start that did not finish goes; a finished chapter plays
      // on until this one is.
      if (await progress.exists()) await progress.delete();
      final done = await _readJson(File('$base.json'));
      await _sweep(base, keep: done?['tag'] as String?);
    }
    final raf = await File(
      '${_piecePath(base, tag, starts.length - 1)}.wav',
    ).open(mode: FileMode.append);
    // Whatever was written after the last sentence counted goes. The header
    // in front says how much there is, so what is in plays as it is.
    final inPiece = bytes - starts.last * 2;
    await raf.truncate(_head + inPiece);
    await raf.setPosition(0);
    await raf.writeFrom(
      ChapterWriter._header(inPiece, rate == 0 ? 24000 : rate),
    );
    await raf.setPosition(_head + inPiece);
    return ChapterWriter._(
      this,
      base: base,
      tag: tag,
      voice: voice,
      title: title,
      text: text,
      utts: utts,
      raf: raf,
      next: next,
      bytes: bytes,
      rate: rate,
      spans: spans,
      starts: starts,
    );
  }

  static String _newTag() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// A chapter half spoken by an earlier version, one WAV under one of its
  /// names, carries on with that WAV as its first piece.
  Future<void> _upgrade(String base, File progress) async {
    final part = File('$base.part.wav');
    final old = File('$base.wav.part');
    if (await old.exists() && !await part.exists()) {
      await old.rename(part.path);
    }
    final was = await _readJson(progress);
    if (was == null || was['pieces'] != null || !await part.exists()) return;
    final tag = _newTag();
    await part.rename('${_piecePath(base, tag, 0)}.wav');
    await _writeJson(progress, {
      ...was,
      'tag': tag,
      'pieces': [0],
    });
  }

  /// Whether every piece of a half-spoken chapter is there, the last as the
  /// WAV to go on speaking into.
  Future<bool> _carriesOn(String base, Map<String, dynamic> was) async {
    final tag = was['tag'] as String;
    final starts = was['pieces'] as List;
    final total = (was['bytes'] as int) ~/ 2;
    for (var k = 0; k < starts.length; k++) {
      final stem = _piecePath(base, tag, k);
      final end = k + 1 < starts.length ? starts[k + 1] as int : total;
      final wav = File('$stem.wav');
      final whole =
          await wav.exists() &&
          await wav.length() >= _head + (end - (starts[k] as int)) * 2;
      if (k == starts.length - 1) return whole;
      if (!whole && !await File('$stem.m4a').exists()) return false;
    }
    return false;
  }

  /// Every file of the chapter at [base] but its indexes and the pieces
  /// tagged [keep]: what earlier tries at it left. The one file an earlier
  /// version finished a chapter into stays too, unless the chapter goes
  /// [whole].
  Future<void> _sweep(String base, {String? keep, bool whole = false}) async {
    final sep = base.lastIndexOf(Platform.pathSeparator);
    final dir = Directory(base.substring(0, sep));
    final chapter = '${base.substring(sep + 1)}.';
    if (!await dir.exists()) return;
    for (final f in await dir.list().toList()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.startsWith(chapter)) continue;
      final rest = name.substring(chapter.length);
      if (rest == 'json' || rest == 'part.json') continue;
      if (!whole && (rest == 'm4a' || rest == 'wav')) continue;
      if (keep != null && rest.startsWith('$keep.')) continue;
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  static const _audio = MethodChannel('novel/audio');

  /// A closed piece's WAV as AAC (AppDelegate.swift), on the CPU beside the
  /// voice on the GPU, written aside and renamed, so a piece is never half
  /// one. The WAV goes once nothing plays it ([_piece]); a piece that would
  /// not convert stays a WAV.
  Future<void> _compress(String stem) async {
    if (!Platform.isIOS || !_compressing.add(stem)) return;
    final wav = '$stem.wav';
    final aside = '$stem.tmp.m4a';
    try {
      await _audio.invokeMethod('m4a', {'from': wav, 'to': aside});
      // Deleted, or spoken again, meanwhile.
      if (!await File(wav).exists()) {
        await File(aside).delete();
        return;
      }
      await File(aside).rename('$stem.m4a');
      if (playing != wav) {
        try {
          await File(wav).delete();
        } catch (_) {}
      }
      notifyListeners();
    } catch (_) {
      try {
        await File(aside).delete();
      } catch (_) {}
    } finally {
      _compressing.remove(stem);
    }
  }

  final _compressing = <String>{};

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
        final m = RegExp(r'^(\d+)\.(.+)$').firstMatch(name);
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
    // The indexes first: without them the rest is never played.
    for (final ext in ['json', 'part.json']) {
      final f = File('$base.$ext');
      if (await f.exists()) await f.delete();
    }
    await _sweep(base, whole: true);
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

/// One file of a spoken chapter, and where in the chapter it starts.
class SpokenPiece {
  const SpokenPiece(this.path, this.ms);

  final String path;
  final int ms;
}

class SpokenChapter {
  const SpokenChapter({
    required this.id,
    required this.pieces,
    required this.voice,
    required this.sentences,
    this.complete = true,
  });

  /// Which audio this is: the chapter spoken over again is another.
  final String id;

  /// The files it plays from, one after the other.
  final List<SpokenPiece> pieces;
  final String voice;
  final List<SpokenSentence> sentences;

  /// Every sentence is in; otherwise [sentences] are the ones spoken so far.
  final bool complete;

  /// The piece [at] falls in.
  int pieceAt(Duration at) {
    final ms = at.inMilliseconds;
    var k = 0;
    while (k + 1 < pieces.length && pieces[k + 1].ms <= ms) {
      k++;
    }
    return k;
  }

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
/// [finish]ed. [close] without finishing keeps what was spoken for next time.
class ChapterWriter {
  ChapterWriter._(
    this._store, {
    required this.base,
    required this.tag,
    required this.voice,
    required this.title,
    required this.text,
    required this.utts,
    required RandomAccessFile raf,
    required this.next,
    required int bytes,
    required int rate,
    required List<List<int>> spans,
    required List<int> starts,
  }) : _raf = raf,
       _bytes = bytes,
       _rate = rate,
       _spans = spans,
       _starts = starts;

  final TtsChapters _store;
  final String base;
  final String tag;
  final String voice;
  final String title;
  final int text;
  final List<TtsUtt> utts;

  /// The piece being spoken into: the last of [_starts].
  RandomAccessFile _raf;

  /// The first sentence still to speak.
  int next;

  /// Every sample so far, as bytes.
  int _bytes;
  int _rate;
  final List<List<int>> _spans;

  /// Where each piece starts, in samples.
  final List<int> _starts;
  bool _closed = false;

  bool get done => next >= utts.length;

  int get _inPiece => _bytes - _starts.last * 2;

  String get _stem => TtsChapters._piecePath(base, tag, _starts.length - 1);

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
    final ends = last || utts[next + 1].paragraphIndex != u.paragraphIndex;
    final gap = Uint8List(rate * (ends ? 480 : 220) ~/ 1000 * 2);
    final even = pcm.length & ~1;
    await _raf.writeFrom(pcm, 0, even);
    await _raf.writeFrom(gap);
    _bytes += even + gap.length;
    await _raf.setPosition(0);
    await _raf.writeFrom(_header(_inPiece, rate));
    await _raf.setPosition(TtsChapters._head + _inPiece);
    await _raf.flush();
    next++;
    // Long enough: closed where a paragraph ends, so the step to the next
    // file falls in its pause, and made smaller while speaking goes on.
    final seconds = _inPiece ~/ 2 ~/ rate;
    final full = TtsChapters.pieceSeconds;
    final closed = !last && (ends && seconds >= full || seconds >= 2 * full)
        ? await _nextPiece()
        : null;
    await _save();
    if (closed != null) unawaited(_store._compress(closed));
  }

  /// The piece in hand closed, and the next one begun; the closed one's stem.
  Future<String> _nextPiece() async {
    final closed = _stem;
    await _raf.close();
    _starts.add(_bytes ~/ 2);
    _raf = await File('$_stem.wav').open(mode: FileMode.write);
    await _raf.writeFrom(_header(0, _rate == 0 ? 24000 : _rate));
    return closed;
  }

  Future<void> _save() => TtsChapters._writeJson(File('$base.part.json'), {
    'voice': voice,
    'title': title,
    'text': text,
    'n': next,
    'bytes': _bytes,
    'rate': _rate == 0 ? 24000 : _rate,
    's': _spans,
    'tag': tag,
    'pieces': _starts,
  });

  /// Every sentence in: the chapter is whole, and on an iPhone its last
  /// piece is made smaller while the next chapter is spoken.
  Future<void> finish() async {
    _closed = true;
    await _raf.close();
    final last = _stem;
    // Nothing went into the piece begun last.
    final into = _inPiece > 0 || _starts.length == 1;
    if (!into) {
      await File('$last.wav').delete();
      _starts.removeLast();
    }
    // Replaces the index of the chapter as spoken before, in one step.
    await TtsChapters._writeJson(File('$base.json'), {
      'voice': voice,
      'title': title,
      'rate': _rate == 0 ? 24000 : _rate,
      'bytes': _bytes,
      's': _spans,
      'tag': tag,
      'pieces': _starts,
    });
    await File('$base.part.json').delete();
    await _store._sweep(base, keep: tag, whole: true);
    _store._changed();
    if (into) unawaited(_store._compress(last));
  }

  /// Stopped before the end: what was spoken is made smaller now, and
  /// speaking again goes on into a new piece.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_inPiece == 0) {
      await _raf.close();
      // Stopped before its first sentence came.
      if (_bytes == 0) await File('$_stem.wav').delete();
      return;
    }
    final closed = await _nextPiece();
    await _save();
    await _raf.close();
    unawaited(_store._compress(closed));
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
