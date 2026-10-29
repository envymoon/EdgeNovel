import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'keep_alive.dart';
import 'reader_state.dart';
import 'platform_services.dart';
import 'platform_support.dart';
import 'theme.dart';
import 'tts_chapters.dart';
import 'tts_remote.dart';
import 'tts_text.dart';

/// Reads the current chapter aloud, highlighting and scrolling to the sentence
/// being spoken and carrying on into the next chapter at the end.
///
/// Synthesis happens sentence by sentence, a few sentences ahead of the voice,
/// so the wait is paid once at the start and never again mid-chapter. Where that
/// synthesis happens is the user's choice: on a server they run (see
/// `tts_remote.dart`) or on this machine's own engine (Qwen3-TTS, see
/// `app/rust/src/api/tts.rs`).
///
/// Nothing is kept here. Audio lives in memory until it has been spoken and
/// then it is gone; the only thing on disk is one scratch file per in-flight
/// clip, because the audio backends want a path. Sentences spoken ahead of time
/// (`tts_prepare.dart`) come back from the local engine's own cache.
///
/// On iPhone nothing is spoken as the voice goes: a chapter plays from the
/// file it is spoken ahead into ([TtsChapters]), as far as it has been
/// spoken, and the voice follows its index from sentence to sentence. With
/// no AI voice installed the phone's own voice reads it instead, as it goes
/// ([_startSystem]).
class TtsController extends ChangeNotifier {
  final ReaderState reader;
  final ReadingSettings settings;
  final LocalSpeechSynthesizer _localSpeech;
  TtsController(
    this.reader,
    this.settings, {
    LocalSpeechSynthesizer? localSpeech,
    bool enableIo = true,
  }) : _localSpeech = localSpeech ?? AppServices.instance.localSpeech,
       _player = enableIo ? AudioPlayer() : null,
       _silence = enableIo && defaultTargetPlatform == TargetPlatform.iOS
           ? AudioPlayer()
           : null,
       _remote = enableIo ? TtsRemoteClient() : null {
    final player = _player;
    if (_byChapter && player != null) _listen(player);
    if (enableIo && defaultTargetPlatform == TargetPlatform.android) {
      addListener(_holdListening);
    }
  }

  /// Android lets an app behind the screen go on only as a foreground
  /// service: listening holds one for as long as it plays, so a locked
  /// phone reads on from chapter to chapter (keep_alive.dart).
  final _listening = SilentKeepAlive(reason: 'listen');

  void _holdListening() => unawaited(_listening.set(playing));

  AudioPlayer? _player;

  void _listen(AudioPlayer player) {
    _positionSub = player.onPositionChanged.listen(_onSpokenPosition);
    _completeSub = player.onPlayerComplete.listen((_) => _onSpokenEnd());
  }

  /// What plays after a piece ends plays in a player of its own. The one
  /// that played it lets go of its file by itself once through, a moment
  /// after saying so — late enough to take the next piece with it, were that
  /// handed to it — and then says where it stopped, which is not where the
  /// next piece is.
  Future<void> _freshPlayer() async {
    final old = _player;
    if (old == null) return;
    await _positionSub?.cancel();
    await _completeSub?.cancel();
    final player = _player = AudioPlayer();
    _listen(player);
    unawaited(Future.delayed(const Duration(seconds: 5), old.dispose));
  }

  /// iPhone: chapters spoken ahead are played, and nothing else.
  static bool get _byChapter => AppPlatformSupport.speaksByChapter;

  /// iPhone without the AI voice: the phone's own reads (AppDelegate.swift).
  static const _speech = MethodChannel('novel/speech');

  /// The reader the phone's voice is reading for; what it says goes there.
  static TtsController? _speaking;

  /// Reading in the phone's voice, and paused within a sentence of it.
  bool _system = false;
  bool _systemPaused = false;

  /// The chapter its sentences are of: one turned to while paused is read
  /// from its own start.
  (int?, int) _systemChapter = (null, -1);

  /// Whether the AI voice is there to play chapters spoken ahead; where not,
  /// iPhone reads in its own voice.
  Future<bool> aiVoiceReady() async {
    if (!AppPlatformSupport.hasAiVoice) return false;
    try {
      return await _localSpeech.ready();
    } catch (_) {
      return false;
    }
  }

  /// The chapter playing, while [_byChapter], and the piece of it.
  SpokenChapter? _spoken;
  int _piece = 0;
  Duration? _pausedAt;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<void>? _completeSub;

  /// iOS lets an app behind the screen run only while it plays something.
  /// While the voice waits for its next sentence — behind the screen it comes
  /// from the slower CPU — this plays silence, so listening with the screen
  /// locked does not end at the first wait.
  final AudioPlayer? _silence;
  final TtsRemoteClient? _remote;

  /// How far ahead of the voice to synthesize. Three sentences is enough to
  /// cover a slow server without building a backlog that a pause would waste.
  static const _lookahead = 3;

  bool playing = false;

  /// True while the voice has caught up with synthesis and is waiting. The
  /// reader shows this — a silence you were told about is a very different
  /// experience from one you weren't.
  bool buffering = false;

  /// Whether a sentence has been heard since [start]. Waiting before the first
  /// one is the voice starting up, and the reader says so.
  bool heard = false;

  /// The sentence being spoken: its paragraph and character range. -1 when idle.
  int activeParagraph = -1;
  int activeStart = -1;
  int activeEnd = -1;

  /// Set when playback stopped for a reason worth telling the user about.
  String? notice;

  /// Bumped on every stop/pause/seek so in-flight loops know they are stale.
  int _gen = 0;

  /// Completed on pause/stop/seek to unblock a loop awaiting playback or a gap.
  Completer<void>? _stop;

  List<TtsUtt> _utts = const [];
  int _pos = 0;

  /// Synthesized and not yet spoken, by utterance index. Only ever holds the
  /// look-ahead window.
  final Map<int, Uint8List> _ready = {};
  final Set<int> _inflight = {};

  /// Sentences the backend refused. Remembered so a sentence that cannot be
  /// synthesized is skipped once, rather than retried forever — without this a
  /// single bad line stops the chapter dead.
  final Set<int> _failed = {};

  /// Signalled whenever a clip lands, so the player can stop waiting.
  Completer<void>? _arrived;

  Directory? _scratch;
  int _scratchSlot = 0;

  // ── What the reader reads ──────────────────────────────────────────────
  double get speed => settings.ttsSpeed;
  bool get hasQueue => _utts.isNotEmpty;
  int get position => _pos;
  int get total => _utts.length;
  bool get usingRemote => !_byChapter && settings.ttsRemote;

  /// How far synthesis has run ahead of the voice, as a fraction of the chapter,
  /// for the secondary track of the progress bar.
  double get bufferedFraction {
    if (_utts.isEmpty) return 0;
    if (_byChapter) return 1;
    final ahead = _ready.keys.where((i) => i >= _pos).length;
    return ((_pos + ahead) / _utts.length).clamp(0.0, 1.0);
  }

  void clearNotice() {
    notice = null;
  }

  Future<void> toggle() => playing ? pause() : start();

  /// Begin (or resume) reading the current chapter. With [fromIndex], start at
  /// that sentence. Throws a Chinese message the caller can show.
  Future<void> start({int? fromIndex}) async {
    if (playing) return;
    if (_byChapter) {
      if (await aiVoiceReady()) return _startSpoken(fromIndex);
      return _startSystem(fromIndex);
    }
    if (!settings.ttsRemote && !await _localSpeech.ready()) {
      throw '朗读语音未安装';
    }
    if (_utts.isEmpty) _buildUtts();
    if (_utts.isEmpty) return;
    _pos = (fromIndex ?? (_pos >= _utts.length ? 0 : _pos)).clamp(
      0,
      _utts.length - 1,
    );
    playing = true;
    heard = false;
    notice = null;
    _stop = Completer<void>();
    final gen = ++_gen;
    final u = _utts[_pos];
    _setActive(u.paragraphIndex, u.start, u.end);
    notifyListeners();
    unawaited(_feed(gen));
    unawaited(_run(gen));
  }

  Future<void> pause() async {
    if (!playing) return;
    playing = false;
    _gen++;
    if (_system) {
      _systemPaused = true;
      notifyListeners();
      await _speech.invokeMethod('pause');
      return;
    }
    if (_byChapter) {
      final at = await _player?.getCurrentPosition();
      _pausedAt = at == null ? null : _pieceStart + at;
      await _player?.pause();
      notifyListeners();
      return;
    }
    _release();
    await _player?.stop();
    notifyListeners(); // keeps the queue/highlight/progress so resume is exact
  }

  /// Stop and forget position — used when the book closes or a chapter is
  /// navigated by hand.
  Future<void> stop() async {
    playing = false;
    buffering = false;
    _gen++;
    _release();
    _clearActive();
    _utts = const [];
    _pos = 0;
    _ready.clear();
    _inflight.clear();
    _failed.clear();
    _spoken = null;
    _pausedAt = null;
    TtsChapters.instance.playing = null;
    if (_system) {
      _system = false;
      _systemPaused = false;
      await _speech.invokeMethod('stop');
    }
    await _player?.stop();
    notifyListeners();
  }

  /// Jump to a sentence by index (progress-bar drag).
  Future<void> seekTo(int index) async {
    if (_utts.isEmpty) return;
    final i = index.clamp(0, _utts.length - 1);
    _pos = i;
    final u = _utts[i];
    _setActive(u.paragraphIndex, u.start, u.end);
    if (_system) {
      _systemPaused = false;
      if (playing) await _speakFrom(i);
      notifyListeners();
      return;
    }
    final spoken = _spoken;
    if (_byChapter && spoken != null) {
      _pausedAt = null;
      if (playing) await _seekSpoken(spoken.sentences[i].ms);
      notifyListeners();
      return;
    }
    _gen++;
    _release();
    _dropStale();
    await _player?.stop();
    if (playing) {
      _stop = Completer<void>();
      final gen = ++_gen;
      unawaited(_feed(gen));
      unawaited(_run(gen));
    } else {
      notifyListeners();
    }
  }

  /// Jump to the sentence a reader tapped, identified by its paragraph and the
  /// range start the reader built its spans from. Starts playback if idle.
  Future<void> seekToSentence(int paragraphIndex, int segStart) async {
    if (_utts.isEmpty) _buildUtts();
    final idx = _uttIndexOf(paragraphIndex, segStart);
    if (idx < 0) return;
    if (playing) {
      await seekTo(idx);
    } else {
      try {
        await start(fromIndex: idx);
      } catch (_) {
        // No voice configured: a tap stays silent. The headphone menu is the
        // path that explains what to do about it.
      }
    }
  }

  /// Pace changed. The local engine has no pace of its own — playback is
  /// stretched instead — so nothing buffered goes stale; a server is asked for
  /// the pace, and what it already made is made at the old one.
  Future<void> onSpeedChanged() async {
    // The phone's voice takes its pace sentence by sentence: what is queued
    // is queued again at the new one.
    if (_system) {
      _systemPaused = false;
      if (playing) await _speakFrom(_pos);
      notifyListeners();
      return;
    }
    if (usingRemote) return onVoiceOrSpeedChanged();
    await _player?.setPlaybackRate(speed);
    notifyListeners();
  }

  /// Voice, pace or server changed: what is buffered was made with the old
  /// settings, so throw it away and re-synthesize from where we are.
  Future<void> onVoiceOrSpeedChanged() async {
    // What plays was spoken in its own voice, and kept.
    if (_byChapter) return onSpeedChanged();
    final wasPlaying = playing;
    if (playing) await pause();
    _ready.clear();
    _inflight.clear();
    _failed.clear();
    if (wasPlaying) {
      await start(fromIndex: _pos);
    } else {
      notifyListeners();
    }
  }

  // ── iPhone: the phone's own voice ───────────────────────────────────────

  Future<void> _startSystem(int? fromIndex) async {
    // Sentences of a chapter spoken ahead carry no text.
    final chapter = (reader.info?.id, reader.chapterIndex);
    if (_utts.isEmpty || !_system || chapter != _systemChapter) {
      if (chapter != _systemChapter) _pos = 0;
      _systemChapter = chapter;
      _spoken = null;
      _pausedAt = null;
      _systemPaused = false;
      _buildUtts();
    }
    if (_utts.isEmpty) return;
    _system = true;
    _pos = (fromIndex ?? (_pos >= _utts.length ? 0 : _pos)).clamp(
      0,
      _utts.length - 1,
    );
    playing = true;
    heard = true;
    buffering = false;
    notice = null;
    _gen++;
    final u = _utts[_pos];
    _setActive(u.paragraphIndex, u.start, u.end);
    notifyListeners();
    _speaking = this;
    _speech.setMethodCallHandler(_onSystemSpeech);
    if (fromIndex == null && _systemPaused) {
      _systemPaused = false;
      if (await _speech.invokeMethod<bool>('resume') == true) return;
    }
    _systemPaused = false;
    await _speakFrom(_pos);
  }

  /// The chapter from sentence [from] on, queued in the phone's voice, a
  /// breath after each sentence as [_gap] gives the AI voice.
  Future<void> _speakFrom(int from) async {
    final gaps = <double>[];
    for (var i = from; i < _utts.length; i++) {
      final next = i + 1;
      var ms = 220;
      if (next < _utts.length &&
          _utts[next].paragraphIndex != _utts[i].paragraphIndex) {
        ms += 260;
      }
      gaps.add(ms / speed / 1000);
    }
    try {
      await _speech.invokeMethod('speak', {
        'texts': [for (var i = from; i < _utts.length; i++) _utts[i].text],
        'gaps': gaps,
        'from': from,
        'rate': systemRate(speed),
      });
    } on PlatformException catch (e) {
      // Android with no Chinese voice installed.
      playing = false;
      notifyListeners();
      throw e.message ?? '朗读失败';
    }
  }

  /// The pace slider's 0.6–2× as the phone's voice takes it: 0.5 is its own
  /// pace, 1 the fastest it goes.
  static double systemRate(double speed) =>
      (speed <= 1 ? 0.5 * speed : 0.5 + (speed - 1) * 0.25).clamp(0.1, 1.0);

  static Future<void> _onSystemSpeech(MethodCall call) async {
    final self = _speaking;
    if (self == null || !self._system) return;
    switch (call.method) {
      case 'sentence':
        final i = call.arguments as int;
        if (i >= self._utts.length) return;
        self._pos = i;
        final u = self._utts[i];
        self._setActive(u.paragraphIndex, u.start, u.end);
        self.notifyListeners();
      case 'end':
        await self._onSystemEnd();
    }
  }

  /// The chapter read to the end: on into the next one, and at the book's
  /// end the voice stops.
  Future<void> _onSystemEnd() async {
    if (!playing) return;
    final gen = _gen;
    final info = reader.info;
    await reader.markCurrentChapterCompleted();
    if (gen != _gen) return;
    if (info == null || reader.chapterIndex >= info.chapters.length - 1) {
      playing = false;
      _pos = _utts.length;
      _clearActive();
      notifyListeners();
      return;
    }
    await reader.next();
    if (gen != _gen) return;
    _buildUtts();
    _systemChapter = (reader.info?.id, reader.chapterIndex);
    _pos = 0;
    if (_utts.isEmpty) {
      playing = false;
      _clearActive();
      notifyListeners();
      return;
    }
    final u = _utts[0];
    _setActive(u.paragraphIndex, u.start, u.end);
    notifyListeners();
    await _speakFrom(0);
  }

  // ── iPhone: chapters spoken ahead ───────────────────────────────────────

  Future<void> _startSpoken(int? fromIndex) async {
    final info = reader.info;
    if (info == null) return;
    final spoken = await TtsChapters.instance.chapter(
      info,
      reader.chapterIndex,
    );
    if (spoken == null || spoken.sentences.isEmpty) throw '本章未合成';
    if (_spoken?.id != spoken.id) _pausedAt = null;
    _spoken = spoken;
    _utts = _spokenUtts(spoken);
    _pos = (fromIndex ?? (_pos >= _utts.length ? 0 : _pos)).clamp(
      0,
      _utts.length - 1,
    );
    // Resumed where it was paused, mid-sentence; anywhere else from the
    // start of the sentence.
    final at = fromIndex == null && _pausedAt != null
        ? _pausedAt!
        : Duration(milliseconds: spoken.sentences[_pos].ms);
    _pausedAt = null;
    playing = true;
    heard = true;
    buffering = false;
    notice = null;
    final gen = ++_gen;
    final u = _utts[_pos];
    _setActive(u.paragraphIndex, u.start, u.end);
    notifyListeners();
    await _playSpoken(gen, at);
  }

  static List<TtsUtt> _spokenUtts(SpokenChapter spoken) => [
    for (final s in spoken.sentences) TtsUtt(s.paragraph, s.start, s.end, ''),
  ];

  /// Where the piece playing starts in the chapter.
  Duration get _pieceStart {
    final pieces = _spoken?.pieces;
    return pieces == null || _piece >= pieces.length
        ? Duration.zero
        : Duration(milliseconds: pieces[_piece].ms);
  }

  /// To [ms] into the chapter: within the piece playing, or in the one it
  /// falls in.
  Future<void> _seekSpoken(int ms) async {
    final at = Duration(milliseconds: ms);
    if (_spoken?.pieceAt(at) == _piece) {
      await _player?.seek(at - _pieceStart);
    } else {
      await _playSpoken(_gen, at);
    }
  }

  /// Plays from [at] into the chapter, in the piece it falls in.
  Future<void> _playSpoken(int gen, Duration at) async {
    final player = _player;
    final spoken = _spoken;
    if (player == null || spoken == null) return;
    _piece = spoken.pieceAt(at);
    final piece = spoken.pieces[_piece];
    // A piece being spoken into when the chapter was read has been made
    // smaller since, and its WAV gone.
    var path = piece.path;
    if (path.endsWith('.wav') && !await File(path).exists()) {
      path = '${path.substring(0, path.length - 4)}.m4a';
    }
    if (gen != _gen) return;
    TtsChapters.instance.playing = path;
    await player.setSource(DeviceFileSource(path));
    if (gen != _gen) return;
    final within = at - Duration(milliseconds: piece.ms);
    if (within > Duration.zero) await player.seek(within);
    await player.setPlaybackRate(speed);
    if (gen != _gen) return;
    await player.resume();
  }

  void _onSpokenPosition(Duration at) {
    final spoken = _spoken;
    if (!playing || spoken == null || _utts.isEmpty) return;
    // Only where the piece playing is: what a player says as it lets go of
    // one is not.
    final t = _pieceStart + at;
    if (spoken.pieceAt(t) != _piece) return;
    final i = spoken.sentenceAt(t).clamp(0, _utts.length - 1);
    if (i == _pos) return;
    _pos = i;
    final u = _utts[i];
    _setActive(u.paragraphIndex, u.start, u.end);
    notifyListeners();
  }

  /// The chapter heard to the end: on into the next one if it has been
  /// spoken, and otherwise the voice stops here. A chapter heard as far as
  /// it had been spoken goes on with whatever has been spoken since, and
  /// stops where that runs out.
  Future<void> _onSpokenEnd() async {
    final was = _spoken;
    if (!playing || was == null) return;
    final gen = _gen;
    await _freshPlayer();
    if (gen != _gen) return;
    // On into the chapter's next piece.
    if (_piece + 1 < was.pieces.length) {
      await _playSpoken(gen, Duration(milliseconds: was.pieces[_piece + 1].ms));
      return;
    }
    final info = reader.info;
    if (!was.complete) {
      final now = info == null
          ? null
          : await TtsChapters.instance.chapter(info, reader.chapterIndex);
      if (gen != _gen) return;
      final from = was.sentences.length;
      if (now == null || now.sentences.length <= from) {
        notice = '只合成到这里';
        playing = false;
        _pausedAt = null;
        // Played again, it goes on from what has been spoken by then.
        _pos = from;
        _clearActive();
        notifyListeners();
        return;
      }
      _spoken = now;
      _utts = _spokenUtts(now);
      _pos = from;
      final u = _utts[from];
      _setActive(u.paragraphIndex, u.start, u.end);
      notifyListeners();
      await _playSpoken(gen, Duration(milliseconds: now.sentences[from].ms));
      return;
    }
    final next = reader.chapterIndex + 1;
    final last = info == null || next >= info.chapters.length;
    final spoken = info == null || last
        ? null
        : await TtsChapters.instance.chapter(info, next);
    if (gen != _gen) return;
    await reader.markCurrentChapterCompleted();
    if (gen != _gen) return;
    if (spoken == null || spoken.sentences.isEmpty) {
      if (!last) notice = '下一章未合成';
      playing = false;
      _pausedAt = null;
      _pos = _utts.length;
      _clearActive();
      notifyListeners();
      return;
    }
    await reader.next();
    if (gen != _gen) return;
    _spoken = spoken;
    _utts = _spokenUtts(spoken);
    _pos = 0;
    final u = _utts[0];
    _setActive(u.paragraphIndex, u.start, u.end);
    notifyListeners();
    await _playSpoken(gen, Duration.zero);
  }

  // ── Segmentation ───────────────────────────────────────────────────────

  void _buildUtts() => _utts = chapterUtterances(reader.paragraphs);

  int _uttIndexOf(int paragraphIndex, int segStart) {
    for (var k = 0; k < _utts.length; k++) {
      final u = _utts[k];
      if (u.paragraphIndex == paragraphIndex && u.start == segStart) return k;
    }
    return -1;
  }

  // ── Synthesis ──────────────────────────────────────────────────────────

  /// One sentence to bytes, through whichever backend is configured.
  Future<Uint8List> _synth(String text) async {
    if (settings.ttsRemote) {
      final remote = _remote;
      if (remote == null) throw '测试环境未启用远程朗读';
      return remote.speak(
        settings.ttsServer,
        text: text,
        voice: settings.ttsServerVoice,
        speed: settings.ttsSpeed,
      );
    }
    return _localSpeech.synthesize(text: text, voice: settings.ttsLocalVoice);
  }

  /// Keeps the look-ahead window full, two sentences in flight at a time. Runs
  /// alongside playback for as long as this generation is current; a synthesis
  /// failure leaves a hole, which the player skips rather than stalling on.
  Future<void> _feed(int gen) async {
    Future<void> worker() async {
      while (gen == _gen && playing) {
        final next = _needed();
        if (next == null) {
          await Future.delayed(const Duration(milliseconds: 60));
          continue;
        }
        _inflight.add(next);
        try {
          final bytes = await _synth(_utts[next].text);
          if (gen != _gen) return;
          if (next >= _pos) _ready[next] = bytes;
        } catch (e) {
          if (gen != _gen) return;
          _failed.add(next);
          // First failure is worth surfacing: with a remote server it usually
          // means the address stopped answering, and silently skipping every
          // sentence would look like the app broke rather than the link.
          notice ??= '合成失败：$e';
        } finally {
          _inflight.remove(next);
          _wake();
        }
      }
    }

    await Future.wait([worker(), worker()]);
  }

  /// The lowest un-synthesized index inside the window, or null if it is full.
  int? _needed() {
    final end = (_pos + _lookahead).clamp(0, _utts.length);
    for (var i = _pos; i < end; i++) {
      if (!_ready.containsKey(i) &&
          !_inflight.contains(i) &&
          !_failed.contains(i)) {
        return i;
      }
    }
    return null;
  }

  void _dropStale() {
    _ready.removeWhere((i, _) => i < _pos);
    _failed.removeWhere((i) => i < _pos);
  }

  void _wake() {
    final a = _arrived;
    if (a != null && !a.isCompleted) a.complete();
  }

  /// Wait for clip [i] to arrive, or for a pause/stop/seek. Returns its bytes,
  /// or null if it will never come (synthesis of it failed, or we are stale).
  Future<Uint8List?> _await(int i, int gen) async {
    while (gen == _gen && playing) {
      final got = _ready[i];
      if (got != null) return got;
      if (_failed.contains(i)) return null;
      if (!_inflight.contains(i) && _needed() == null) return null;
      if (!buffering) {
        buffering = true;
        unawaited(_holdOn(true));
        notifyListeners();
      }
      _arrived = Completer<void>();
      await Future.any([_arrived!.future, if (_stop != null) _stop!.future]);
    }
    return null;
  }

  // ── Playback ───────────────────────────────────────────────────────────

  Future<void> _run(int gen) async {
    while (gen == _gen && playing) {
      if (_pos >= _utts.length) {
        final info = reader.info;
        if (info == null || reader.chapterIndex >= info.chapters.length - 1) {
          break;
        }
        if (_failed.isEmpty) await reader.markCurrentChapterCompleted();
        await reader.next();
        if (gen != _gen) return;
        _buildUtts();
        _ready.clear();
        _failed.clear();
        _pos = 0;
        if (_utts.isEmpty) break;
      }

      final u = _utts[_pos];
      _setActive(u.paragraphIndex, u.start, u.end);

      final bytes = await _await(_pos, gen);
      if (gen != _gen) return;
      if (buffering) {
        buffering = false;
        unawaited(_holdOn(false));
        notifyListeners();
      }
      if (bytes != null) {
        heard = true;
        await _play(bytes, gen);
        if (gen != _gen) return;
        await _gap(_pos, gen); // a breath between sentences → phrasing
        if (gen != _gen) return;
      }
      _ready.remove(_pos);
      _pos++;
      notifyListeners(); // progress advanced
    }

    if (gen == _gen) {
      playing = false;
      buffering = false;
      _clearActive();
      notifyListeners();
    }
  }

  /// Play one clip and wait until it finishes — or until a pause/stop/seek
  /// unblocks us early. Subscribe before playing so a very short clip cannot
  /// finish in the gap between play() returning and us listening.
  ///
  /// The bytes go through a scratch file because the desktop audio backends
  /// take paths, not buffers. Four rotating slots means the file a player is
  /// still holding is never the one being overwritten, and none of it outlives
  /// the session.
  Future<void> _play(Uint8List bytes, int gen) async {
    final path = await _scratchPath();
    await File(path).writeAsBytes(bytes, flush: true);
    if (gen != _gen) return;
    final player = _player;
    if (player == null) return;
    final complete = player.onPlayerComplete.first;
    await player.setSource(DeviceFileSource(path));
    await player.setPlaybackRate(usingRemote ? 1.0 : speed);
    await player.resume();
    if (gen != _gen) return;
    await Future.any([complete, if (_stop != null) _stop!.future]);
  }

  Future<Directory> _scratchDir() async {
    var d = _scratch;
    if (d == null) {
      d = AppServices.instance.storage.temporaryChild('tts_play');
      await d.create(recursive: true);
      _scratch = d;
    }
    return d;
  }

  Future<String> _scratchPath() async {
    final d = await _scratchDir();
    _scratchSlot = (_scratchSlot + 1) % 4;
    return '${d.path}${Platform.pathSeparator}$_scratchSlot.wav';
  }

  /// A short silence after a sentence, longer at a paragraph boundary, scaled by
  /// pace — this is what turns a run-on read into something with cadence.
  /// Interruptible so pause/stop/seek don't wait it out.
  Future<void> _gap(int pos, int gen) async {
    final next = pos + 1;
    var ms = 220;
    if (next < _utts.length &&
        _utts[next].paragraphIndex != _utts[pos].paragraphIndex) {
      ms += 260; // a fuller pause when a new paragraph begins
    }
    ms = (ms / speed).round();
    await Future.any([
      Future.delayed(Duration(milliseconds: ms)),
      if (_stop != null) _stop!.future,
    ]);
  }

  /// See [_silence].
  Future<void> _holdOn(bool on) async {
    final silence = _silence;
    if (silence == null) return;
    if (!on) return silence.stop();
    final file = File(
      '${(await _scratchDir()).path}${Platform.pathSeparator}silence.wav',
    );
    if (!await file.exists()) {
      // A second of 24 kHz 16-bit mono, all zeros.
      final wav = BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(_le32(36 + 48000))
        ..add('WAVEfmt '.codeUnits)
        ..add(_le32(16))
        ..add([1, 0, 1, 0])
        ..add(_le32(24000))
        ..add(_le32(48000))
        ..add([2, 0, 16, 0])
        ..add('data'.codeUnits)
        ..add(_le32(48000))
        ..add(Uint8List(48000));
      await file.writeAsBytes(wav.takeBytes(), flush: true);
    }
    await silence.setReleaseMode(ReleaseMode.loop);
    if (!buffering) return;
    await silence.play(DeviceFileSource(file.path));
    // The sentence came while it started.
    if (!buffering) await silence.stop();
  }

  static List<int> _le32(int v) => [
    for (final shift in [0, 8, 16, 24]) (v >> shift) & 0xff,
  ];

  void _release() {
    if (_stop != null && !_stop!.isCompleted) _stop!.complete();
    unawaited(_holdOn(false));
    _wake();
  }

  void _setActive(int p, int start, int end) {
    if (activeParagraph != p || activeStart != start || activeEnd != end) {
      activeParagraph = p;
      activeStart = start;
      activeEnd = end;
      notifyListeners();
    }
  }

  void _clearActive() {
    activeParagraph = -1;
    activeStart = -1;
    activeEnd = -1;
  }

  @override
  void dispose() {
    _gen++;
    if (_speaking == this) {
      _speaking = null;
      if (_system) _speech.invokeMethod('stop').ignore();
    }
    _release();
    unawaited(_listening.set(false));
    _positionSub?.cancel();
    _completeSub?.cancel();
    _player?.dispose();
    _silence?.dispose();
    _remote?.close();
    _scratch?.delete(recursive: true).ignore();
    super.dispose();
  }
}
