import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';

import 'ai_runtime.dart';
import 'platform_services.dart';
import 'platform_support.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart' show stopAi;
import 'src/rust/api/book.dart';
import 'src/rust/api/tts.dart' show stopTts;
import 'tts_chapters.dart';
import 'tts_text.dart';

/// 提前合成: speaks chapters before anyone listens, so listening later is
/// playback and nothing else — for devices that cannot speak as fast as they
/// play.
///
/// On Windows the sentences go into the local engine's cache, where playback
/// finds them by itself (see `synth` in `app/rust/src/api/tts.rs`); a sentence
/// not prepared is spoken live as usual. On iPhone each chapter becomes a file
/// of its own ([TtsChapters]), and only those are played: the GPU speaks while
/// the app is on screen, and behind it, with 锁屏运行 on, the CPU carries on.
///
/// One job for the whole app, outliving the reader page that started it.
/// Sentence by sentence, so stopping loses at most the one in flight and
/// starting again skips whatever is already spoken.
class TtsPrepare extends ChangeNotifier with WidgetsBindingObserver {
  TtsPrepare._();
  static final instance = TtsPrepare._();

  /// The book being prepared; null when idle.
  int? bookId;
  String title = '';
  int firstChapter = 0;
  int chapterCount = 0;

  /// Sentences through the engine, of [total].
  int done = 0;
  int total = 0;

  /// Null until enough sentences have been spoken to measure a pace.
  Duration? remaining;

  /// Why the last job stopped short, for whoever shows it.
  String? error;

  int _gen = 0;

  bool get running => bookId != null;
  double get fraction => total == 0 ? 0 : done / total;

  /// The job said the way every background task is, for the progress bars.
  AiActivity? get activity => running
      ? AiActivity(
          title: title,
          label: '提前合成 $chapterCount 章',
          done: done,
          total: total,
          remaining: remaining,
        )
      : null;

  Future<void> start({
    required BookInfo book,
    required int fromChapter,
    required int count,
    required String voice,
    LocalSpeechSynthesizer? speech,
    ReaderState? reader,
  }) async {
    final gen = ++_gen;
    final s = speech ?? AppServices.instance.localSpeech;
    final end = (fromChapter + count).clamp(0, book.chapters.length);
    bookId = book.id;
    title = book.title;
    firstChapter = fromChapter;
    chapterCount = end - fromChapter;
    done = 0;
    total = 0;
    remaining = null;
    error = null;
    // A job this one replaces may be waiting to be back on screen.
    _wake();
    notifyListeners();
    if (AppPlatformSupport.speaksByChapter) {
      await _byChapter(gen, book, fromChapter, end, voice, s, reader);
    } else {
      await _bySentence(gen, book, fromChapter, end, voice, s);
    }
  }

  Future<void> _bySentence(
    int gen,
    BookInfo book,
    int from,
    int end,
    String voice,
    LocalSpeechSynthesizer s,
  ) async {
    final texts = <String>[];
    try {
      for (var c = from; c < end; c++) {
        final paras = await chapterParagraphs(path: book.path, index: c);
        if (gen != _gen) return;
        texts.addAll(chapterUtterances(paras).map((u) => u.text));
      }
    } catch (e) {
      if (gen != _gen) return;
      error = '$e';
      bookId = null;
      notifyListeners();
      return;
    }
    total = texts.length;
    notifyListeners();

    // Paced by characters actually spoken: sentences differ in length, and a
    // cached one costs nothing. The first one spoken also waits for the
    // engine to load, so the pace starts after it.
    var left = texts.fold<int>(0, (n, t) => n + t.length);
    var warm = false;
    var paced = 0;
    var pacedChars = 0;
    var spent = Duration.zero;
    var failures = 0;
    for (final text in texts) {
      final clock = Stopwatch()..start();
      try {
        if (await s.prepare(text: text, voice: voice)) {
          if (warm) {
            paced++;
            pacedChars += text.length;
            spent += clock.elapsed;
          }
          warm = true;
        }
        failures = 0;
      } catch (e) {
        if (gen != _gen) return;
        // One refused sentence is left for live playback; an engine that
        // refuses everything is worth stopping for.
        if (++failures >= 3) {
          error = '$e';
          break;
        }
      }
      if (gen != _gen) return;
      done++;
      left -= text.length;
      if (paced >= 2) remaining = spent * (left / pacedChars);
      notifyListeners();
    }
    if (gen != _gen) return;
    bookId = null;
    notifyListeners();
  }

  Future<void> _byChapter(
    int gen,
    BookInfo book,
    int from,
    int end,
    String voice,
    LocalSpeechSynthesizer s,
    ReaderState? reader,
  ) async {
    final store = TtsChapters.instance;
    // What there is to say, leaving out the chapters already spoken in this
    // voice; one spoken in part carries on.
    final work = <(int, List<TtsUtt>)>[];
    try {
      for (var c = from; c < end; c++) {
        final kept = await store.chapter(book, c);
        if (gen != _gen) return;
        if (kept != null && kept.complete && kept.voice == voice) continue;
        final paras = await chapterParagraphs(path: book.path, index: c);
        if (gen != _gen) return;
        final utts = chapterUtterances(paras);
        if (utts.isNotEmpty) work.add((c, utts));
      }
    } catch (e) {
      if (gen != _gen) return;
      error = '$e';
      bookId = null;
      notifyListeners();
      return;
    }
    total = work.fold<int>(0, (n, w) => n + w.$2.length);
    notifyListeners();
    if (work.isEmpty) {
      bookId = null;
      notifyListeners();
      return;
    }

    _watch(true);
    unawaited(_keepAlive(AiRuntimeSettings.instance.lockedEnabled));
    // The phone has memory for one model at a time: the AI queue waits, and
    // the one it had loaded goes before the voice comes.
    if (reader != null) {
      _reader = reader;
      reader.holdAiForSpeech(true);
      while (reader.aiActive) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (gen != _gen) return;
      }
      try {
        await stopAi();
      } catch (_) {}
      if (gen != _gen) return;
    }

    var left = work.fold<int>(
      0,
      (n, w) => n + w.$2.fold<int>(0, (m, u) => m + u.text.length),
    );
    // As many sentences in flight as the voice speaks at once here: the
    // engine takes them together, each in turn added to the chapter.
    final lanes = await _lanes();
    // Paced by characters spoken since the first one came back, which also
    // waited for the voice to load.
    final pace = Stopwatch();
    var pacedChars = 0;
    var skipped = 0;
    Object? why;
    try {
      for (final (c, utts) in work) {
        final w = await store.write(book, c, voice, utts);
        // Twice, then left out: a chapter missing one sentence is still
        // worth having. Two left out in a row is the engine, not them.
        Future<Uint8List?> speak(int i) async {
          for (var attempt = 0; attempt < 2; attempt++) {
            try {
              return await s.synthesize(text: utts[i].text, voice: voice);
            } catch (e) {
              why = e;
            }
            if (gen != _gen) return null;
          }
          return null;
        }

        final flying = <int, Future<Uint8List?>>{};
        try {
          for (var i = 0; i < w.next; i++) {
            left -= utts[i].text.length;
          }
          done += w.next;
          notifyListeners();
          var ahead = w.next;
          while (!w.done) {
            // What is in flight is kept whatever happens; more only goes
            // out while the job may run.
            if (!flying.containsKey(w.next)) {
              await _mayRun(gen);
              if (gen != _gen) return;
              flying[w.next] = speak(w.next);
              ahead = w.next + 1;
            }
            while (ahead < utts.length && ahead < w.next + lanes && _mayGo) {
              flying[ahead] = speak(ahead);
              ahead++;
            }
            final text = utts[w.next].text;
            final wav = await flying.remove(w.next)!;
            if (gen != _gen) return;
            if (wav != null) {
              await w.add(wav);
              skipped = 0;
              if (pace.isRunning) {
                pacedChars += text.length;
              } else {
                pace.start();
              }
            } else {
              if (++skipped >= 2) throw why ?? '语音合成失败';
              await w.skip();
            }
            done++;
            left -= text.length;
            if (pacedChars > 0 && pace.elapsed.inSeconds >= 20) {
              remaining = pace.elapsed * (left / pacedChars);
            }
            notifyListeners();
          }
          await w.finish();
        } finally {
          await w.close();
        }
      }
    } catch (e) {
      if (gen != _gen) return;
      error = '$e';
    }
    if (gen != _gen) return;
    bookId = null;
    notifyListeners();
    unawaited(_windDown());
  }

  bool get _mayGo => !_offScreen || AiRuntimeSettings.instance.lockedEnabled;

  /// How many sentences the voice speaks at once on this phone: what the 听书
  /// experiments found it does well (tts.rs, `tuned`), one without them.
  static Future<int> _lanes() async {
    try {
      final dir = AppServices.instance.storage.supportChild('tts');
      final file = File('${dir.path}${Platform.pathSeparator}engine.json');
      if (!await file.exists()) return 1;
      final lanes = (jsonDecode(await file.readAsString()) as Map)['lanes'];
      return lanes is int ? lanes.clamp(1, 4) : 1;
    } catch (_) {
      return 1;
    }
  }

  void cancel() {
    if (!running) return;
    _gen++;
    bookId = null;
    _wake();
    notifyListeners();
    unawaited(_windDown());
  }

  // ── iPhone: on screen and off ─────────────────────────────────────────

  ReaderState? _reader;
  bool _watching = false;
  bool _offScreen = false;
  Completer<void>? _back;

  void _watch(bool on) {
    if (on == _watching) return;
    _watching = on;
    if (on) {
      final state = WidgetsBinding.instance.lifecycleState;
      _offScreen = state != null && _behind(state);
      WidgetsBinding.instance.addObserver(this);
      AiRuntimeSettings.instance.addListener(_lockedChanged);
    } else {
      WidgetsBinding.instance.removeObserver(this);
      AiRuntimeSettings.instance.removeListener(_lockedChanged);
    }
  }

  static bool _behind(AppLifecycleState s) =>
      s == AppLifecycleState.hidden ||
      s == AppLifecycleState.paused ||
      s == AppLifecycleState.detached;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _offScreen = _behind(state);
    _wake();
  }

  void _lockedChanged() {
    unawaited(_keepAlive(AiRuntimeSettings.instance.lockedEnabled));
    _wake();
  }

  /// Off screen the job waits, unless 锁屏运行 is on: then the engine moves
  /// to the CPU by itself (tts.rs) and the job goes on.
  Future<void> _mayRun(int gen) async {
    while (gen == _gen &&
        _offScreen &&
        !AiRuntimeSettings.instance.lockedEnabled) {
      final back = _back = Completer<void>();
      await back.future;
    }
  }

  void _wake() {
    final back = _back;
    if (back != null && !back.isCompleted) back.complete();
  }

  /// The job over: the voice lets go of its memory, and then the AI queue
  /// may have it back — unless another job has started meanwhile.
  Future<void> _windDown() async {
    if (!AppPlatformSupport.speaksByChapter) return;
    if (!running) {
      _watch(false);
      await _keepAlive(false);
    }
    try {
      await stopTts();
    } catch (_) {}
    if (running) return;
    _reader?.holdAiForSpeech(false);
    _reader = null;
  }

  AudioPlayer? _silence;
  bool _silent = false;

  /// iOS keeps an app behind the screen running only while it plays
  /// something. With 锁屏运行 on, the job plays silence for as long as it
  /// runs, starting while the app is still on screen: iOS does not let it
  /// start from behind.
  Future<void> _keepAlive(bool wanted) async {
    final on = wanted && running;
    if (on == _silent) return;
    _silent = on;
    try {
      if (!on) {
        await _silence?.stop();
        return;
      }
      final player = _silence ??= AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(DeviceFileSource(await _silenceFile()));
    } catch (_) {
      _silent = false;
    }
  }

  /// A second of 24 kHz 16-bit mono, all zeros.
  static Future<String> _silenceFile() async {
    final dir = AppServices.instance.storage.temporaryChild('tts_keep');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}silence.wav');
    if (!await file.exists()) {
      List<int> le32(int v) => [for (final s in [0, 8, 16, 24]) (v >> s) & 0xff];
      final wav = BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(le32(36 + 48000))
        ..add('WAVEfmt '.codeUnits)
        ..add(le32(16))
        ..add([1, 0, 1, 0])
        ..add(le32(24000))
        ..add(le32(48000))
        ..add([2, 0, 16, 0])
        ..add('data'.codeUnits)
        ..add(le32(48000))
        ..add(Uint8List(48000));
      await file.writeAsBytes(wav.takeBytes(), flush: true);
    }
    return file.path;
  }
}
