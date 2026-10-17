import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'background_task_bar.dart';
import 'bloom.dart';
import 'platform_services.dart';
import 'reader_state.dart';
import 'theme.dart';
import 'tts_chapters.dart';
import 'tts_chapters_page.dart';
import 'tts_controller.dart';
import 'tts_prepare.dart';
import 'tts_text.dart';

/// iPhone 听书, all in one panel from the headphone icon: play what has been
/// spoken, speak more of the book, and the voice and pace.
class TtsPanel extends StatefulWidget {
  const TtsPanel({
    super.key,
    required this.reader,
    required this.settings,
    required this.tts,
    required this.onPlay,
    required this.onDownloadVoice,
    this.localSpeech,
  });

  final ReaderState reader;
  final ReadingSettings settings;
  final TtsController tts;

  /// The reader page's own play/pause, which says why when it cannot.
  final Future<void> Function() onPlay;
  final VoidCallback onDownloadVoice;
  final LocalSpeechSynthesizer? localSpeech;

  @override
  State<TtsPanel> createState() => _TtsPanelState();
}

class _TtsPanelState extends State<TtsPanel> {
  bool? _voiceReady;

  /// Whether the chapter open in the reader has been spoken.
  bool _spoken = false;
  int _bytes = 0;
  (int?, int) _shown = (null, -1);

  @override
  void initState() {
    super.initState();
    TtsChapters.instance.addListener(_load);
    TtsPrepare.instance.addListener(_onJob);
    widget.reader.addListener(_onReader);
    unawaited(_load());
    unawaited(_checkVoice());
  }

  @override
  void dispose() {
    TtsChapters.instance.removeListener(_load);
    TtsPrepare.instance.removeListener(_onJob);
    widget.reader.removeListener(_onReader);
    super.dispose();
  }

  void _onReader() {
    if (_shown != (widget.reader.info?.id, widget.reader.chapterIndex)) {
      unawaited(_load());
    }
  }

  bool _wasRunning = false;

  /// A job that ended has changed what is spoken and the space it takes.
  void _onJob() {
    final running = TtsPrepare.instance.running;
    if (_wasRunning && !running) unawaited(_load());
    _wasRunning = running;
  }

  Future<void> _load() async {
    final info = widget.reader.info;
    final chapter = widget.reader.chapterIndex;
    _shown = (info?.id, chapter);
    final spoken = info == null
        ? null
        : await TtsChapters.instance.chapter(info, chapter);
    final bytes = await TtsChapters.instance.totalBytes();
    if (!mounted) return;
    setState(() {
      _spoken = spoken != null;
      _bytes = bytes;
    });
  }

  Future<void> _checkVoice() async {
    bool ready;
    try {
      ready = await (widget.localSpeech ?? AppServices.instance.localSpeech)
          .ready();
    } catch (_) {
      ready = false;
    }
    if (mounted) setState(() => _voiceReady = ready);
  }

  void _speak(int count) {
    final info = widget.reader.info;
    if (info == null) return;
    unawaited(
      TtsPrepare.instance.start(
        book: info,
        fromChapter: widget.reader.chapterIndex,
        count: count,
        voice: widget.settings.ttsLocalVoice,
        speech: widget.localSpeech,
        reader: widget.reader,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.settings,
      widget.tts,
      TtsPrepare.instance,
    ]),
    builder: (context, _) {
      final t = widget.settings.theme;
      final job = TtsPrepare.instance;
      final playing = widget.tts.playing;
      final info = widget.reader.info;
      final chapter = widget.reader.chapterIndex;
      final title = info == null || chapter >= info.chapters.length
          ? ''
          : info.chapters[chapter].title;
      final label = TextStyle(color: t.text, fontSize: 15);
      return Material(
        color: t.raisedSurface,
        elevation: 8,
        shadowColor: Colors.black45,
        surfaceTintColor: Colors.transparent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: context.tr(playing ? '暂停' : '播放'),
                      iconSize: 30,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: playing || _spoken
                          ? () {
                              // Back to the text while it plays.
                              if (!playing) Navigator.pop(context);
                              unawaited(widget.onPlay());
                            }
                          : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        translate: false,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: label,
                      ),
                    ),
                    if (!_spoken && !playing)
                      Text(
                        '未合成',
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (job.activity case final a?)
                  BloomProgress(
                    label: describeActivity(a),
                    value: a.fraction,
                    color: t.muted,
                    textColor: t.text,
                    trailing: TextButton(
                      onPressed: job.cancel,
                      child: const Text('停止'),
                    ),
                  )
                else if (_voiceReady == false)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '朗读语音未安装',
                          style: TextStyle(color: t.muted, fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onDownloadVoice();
                        },
                        child: const Text('去下载'),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Text('合成', style: label),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final (n, name) in const [
                              (1, '本章'),
                              (5, '5 章'),
                              (10, '10 章'),
                              (20, '20 章'),
                            ])
                              ActionChip(
                                label: Text(
                                  name,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                onPressed: _voiceReady == true
                                    ? () => _speak(n)
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 18),
                Text('音色', style: label),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in localVoices)
                      ChoiceChip(
                        label: Text(v.label),
                        selected: widget.settings.ttsLocalVoice == v.id,
                        onSelected: (_) =>
                            widget.settings.setTtsLocalVoice(v.id),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '语速 · ${widget.settings.ttsSpeed.toStringAsFixed(2)}×',
                  style: label,
                ),
                Slider(
                  value: widget.settings.ttsSpeed.clamp(0.6, 2.0),
                  min: 0.6,
                  max: 2.0,
                  divisions: 14,
                  label: '${widget.settings.ttsSpeed.toStringAsFixed(2)}×',
                  onChanged: widget.settings.setTtsSpeed,
                  onChangeEnd: (_) => widget.tts.onSpeedChanged(),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('已合成', style: label),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatSpokenBytes(_bytes),
                        translate: false,
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                      Icon(Icons.chevron_right, color: t.muted),
                    ],
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TtsChaptersPage(settings: widget.settings),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
