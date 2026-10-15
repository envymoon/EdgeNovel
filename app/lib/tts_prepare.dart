import 'package:flutter/foundation.dart';

import 'platform_services.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'tts_text.dart';

/// 提前合成: speaks chapters into the local engine's cache before anyone
/// listens, so listening later is playback and nothing else — for devices that
/// cannot speak as fast as they play. Playback finds the clips by itself (see
/// `synth` in `app/rust/src/api/tts.rs`); a sentence not prepared is spoken
/// live as usual.
///
/// One job for the whole app, outliving the reader page that started it.
/// Sentence by sentence, so stopping loses at most the one in flight and
/// starting again skips whatever is already cached.
class TtsPrepare extends ChangeNotifier {
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
    notifyListeners();

    final texts = <String>[];
    try {
      for (var c = fromChapter; c < end; c++) {
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

  void cancel() {
    if (!running) return;
    _gen++;
    bookId = null;
    notifyListeners();
  }
}
