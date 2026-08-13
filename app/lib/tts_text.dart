import 'src/rust/api/book.dart';

/// Turning a chapter into things to say. Nothing here touches audio or disk —
/// it is the one piece of read-aloud that is the same whoever synthesizes.

/// A half-open character range `[start, end)` within a paragraph's text — one
/// sentence. Used to carve the chapter into utterances and, in the reader, to
/// highlight the sentence being spoken and to seek by tapping one.
class TtsSeg {
  final int start;
  final int end;
  const TtsSeg(this.start, this.end);
}

/// One thing to speak: a sentence, tagged with the paragraph it came from and
/// its character range within that paragraph, so the reader can highlight and
/// scroll to exactly that sentence while it plays.
class TtsUtt {
  final int paragraphIndex;
  final int start;
  final int end;
  final String text;
  const TtsUtt(this.paragraphIndex, this.start, this.end, this.text);
}

/// Split a paragraph into sentence ranges on Chinese/ASCII enders, keeping any
/// closing quote or bracket with the sentence it ends. Ranges tile the whole
/// paragraph (no gaps) so the reader can map a tap anywhere to a sentence.
/// Works in UTF-16 code units — the unit `String.substring` and `TextSpan` use —
/// so highlight offsets line up with what is drawn.
List<TtsSeg> sentenceSegments(String text) {
  const enders = '。！？!?…\n';
  const closers = '」』"\'）)】';
  final out = <TtsSeg>[];
  var segStart = 0;
  var i = 0;
  while (i < text.length) {
    if (enders.contains(text[i])) {
      var end = i + 1;
      while (end < text.length && closers.contains(text[end])) {
        end++;
      }
      out.add(TtsSeg(segStart, end));
      i = end;
      segStart = end;
    } else {
      i++;
    }
  }
  if (segStart < text.length) out.add(TtsSeg(segStart, text.length));
  return out;
}

/// Flatten a chapter's paragraphs into the sentence queue. Volume dividers are
/// skipped; titles, body and author notes are read. Whitespace-only segments
/// carry no utterance.
List<TtsUtt> chapterUtterances(List<Paragraph> paras) {
  final out = <TtsUtt>[];
  for (var i = 0; i < paras.length; i++) {
    final p = paras[i];
    if (p.kind == ParaKind.volume) continue;
    for (final s in sentenceSegments(p.text)) {
      final txt = p.text.substring(s.start, s.end).trim();
      if (txt.isEmpty) continue;
      out.add(TtsUtt(i, s.start, s.end, txt));
    }
  }
  return out;
}

/// Pace as the local sherpa-onnx engine wants it: 1.0 is the voice's natural
/// speed, larger is slower. (Remote servers take `speed` the other way round,
/// the way OpenAI defines it, so this conversion stays local to that backend.)
double ttsLengthScale(double speed) => (1.0 / speed).clamp(0.4, 2.5);

/// The bundled local voices — sherpa-onnx Kokoro speaker ids. Kept as the
/// no-setup fallback for someone who has not stood a server up; the good voices
/// live on the server (see `tts_remote.dart`).
class LocalVoice {
  final int sid;
  final String label;
  const LocalVoice(this.sid, this.label);
}

const localVoices = <LocalVoice>[
  LocalVoice(49, '云健 · 男声旁白'),
  LocalVoice(50, '云希 · 男声'),
  LocalVoice(52, '云扬 · 男声'),
  LocalVoice(51, '云夏 · 男声'),
  LocalVoice(47, '晓晓 · 女声'),
  LocalVoice(45, '晓贝 · 女声'),
  LocalVoice(46, '晓妮 · 女声'),
  LocalVoice(48, '晓伊 · 女声'),
];

String localVoiceLabel(int sid) => localVoices
    .firstWhere((v) => v.sid == sid, orElse: () => LocalVoice(sid, '音色 $sid'))
    .label;
