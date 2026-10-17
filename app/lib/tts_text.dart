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
/// run of them (……, ？！) and any closing quote or bracket with the sentence
/// it ends. Ranges tile the whole paragraph (no gaps) so the reader can map a
/// tap anywhere to a sentence. Works in UTF-16 code units — the unit
/// `String.substring` and `TextSpan` use — so highlight offsets line up with
/// what is drawn.
List<TtsSeg> sentenceSegments(String text) {
  const enders = '。！？!?…⋯\n';
  const closers = '」』"\'）)】”’》〉＂';
  final out = <TtsSeg>[];
  var segStart = 0;
  var i = 0;
  while (i < text.length) {
    if (enders.contains(text[i])) {
      var end = i + 1;
      while (end < text.length &&
          (closers.contains(text[end]) || enders.contains(text[end]))) {
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
/// skipped; titles, body and author notes are read. A sentence with nothing
/// to say once [speakable] (a lone mark, a row of asterisks) carries no
/// utterance.
List<TtsUtt> chapterUtterances(List<Paragraph> paras) {
  final out = <TtsUtt>[];
  for (var i = 0; i < paras.length; i++) {
    final p = paras[i];
    if (p.kind == ParaKind.volume) continue;
    for (final s in sentenceSegments(p.text)) {
      final txt = speakable(p.text.substring(s.start, s.end));
      if (txt.isEmpty) continue;
      out.add(TtsUtt(i, s.start, s.end, txt));
    }
  }
  return out;
}

/// What the voice is given to say for [text]. Marks with no sound of their
/// own (quotes, brackets, asterisks, and letters dressed up in other Unicode
/// forms, as sites stamp their names into a text) it takes for words of some
/// language and makes up a stretch of speech for, so they are left out; the
/// ones that stand for a pause (……, ——, ～, a row of dots) become the comma
/// or full stop it reads as one. Empty when nothing is left to say.
String speakable(String text) {
  final runes = text.runes.map(_plain).toList();
  bool digit(int at) =>
      at >= 0 && at < runes.length && runes[at] >= 0x30 && runes[at] <= 0x39;
  final out = StringBuffer();
  // The pause a run of marks stands for, written once something follows.
  var pause = '';
  var space = false;
  for (var k = 0; k < runes.length; k++) {
    final c = runes[k];
    final mark = _pauses[c];
    if (_sounds(c)) {
      if (out.isNotEmpty) {
        if (pause.isNotEmpty) {
          out.write(pause);
        } else if (space) {
          out.write(' ');
        }
      }
      pause = '';
      space = false;
      out.writeCharCode(c);
    } else if ((c == 0x2E || c == 0x3A) && digit(k - 1) && digit(k + 1)) {
      // 3.5, 12:30
      out.writeCharCode(c);
    } else if (c == 0x2C && digit(k - 1) && digit(k + 1)) {
      // 1,000
    } else if (mark != null) {
      // A row of dots is an ellipsis, not stops.
      final dots =
          c == 0x2E &&
          (k + 1 < runes.length && runes[k + 1] == 0x2E ||
              k > 0 && runes[k - 1] == 0x2E);
      final p = dots ? '，' : mark;
      if (_strength(p) > _strength(pause)) pause = p;
    } else if (c == 0x20 || c == 0x3000 || c == 0x09 || c == 0xB7 ||
        c == 0x30FB) {
      // 约翰·史密斯 is one name.
      space = true;
    }
  }
  if (out.isEmpty) return '';
  if (pause.isNotEmpty) out.write(pause == '，' ? '。' : pause);
  return out.toString();
}

/// Full-width letters and digits as the plain ones.
int _plain(int c) =>
    c >= 0xFF10 && c <= 0xFF19 ||
        c >= 0xFF21 && c <= 0xFF3A ||
        c >= 0xFF41 && c <= 0xFF5A
    ? c - 0xFEE0
    : c;

final _letter = RegExp(r'^[\p{L}\p{Nd}]$', unicode: true);

/// A letter or digit of any script, and %; not the mathematical forms of
/// Latin letters and digits (𝐤, 𝟏), which a text has only as decoration.
bool _sounds(int c) {
  if (c == 0x25) return true;
  if (c >= 0x1D400 && c <= 0x1D7FF) return false;
  return _letter.hasMatch(String.fromCharCode(c));
}

/// The marks that stand for a pause, and the one each reads as.
const _pauses = <int, String>{
  0x3002: '。', // 。
  0x2E: '。', // .
  0xFF0E: '。', // ．
  0xFF1F: '？', // ？
  0x3F: '？', // ?
  0xFF01: '！', // ！
  0x21: '！', // !
  0xFF0C: '，', // ，
  0x2C: '，', // ,
  0x3001: '，', // 、
  0xFF1B: '，', // ；
  0x3B: '，', // ;
  0xFF1A: '，', // ：
  0x3A: '，', // :
  0x2026: '，', // …
  0x22EF: '，', // ⋯
  0x2014: '，', // —
  0x2013: '，', // –
  0x2015: '，', // ―
  0xFF5E: '，', // ～
  0x7E: '，', // ~
  0x301C: '，', // 〜
};

int _strength(String pause) => switch (pause) {
  '' => 0,
  '，' => 1,
  '。' => 2,
  _ => 3,
};

/// The local voices: the named speakers of Qwen3-TTS's CustomVoice model that
/// speak Chinese natively. Dylan and Eric bring their dialects with them.
class LocalVoice {
  final String id;
  final String label;
  const LocalVoice(this.id, this.label);
}

const localVoices = <LocalVoice>[
  LocalVoice('uncle_fu', 'Uncle Fu · 男声'),
  LocalVoice('serena', 'Serena · 女声'),
  LocalVoice('vivian', 'Vivian · 女声'),
  LocalVoice('dylan', 'Dylan · 京腔男声'),
  LocalVoice('eric', 'Eric · 川味男声'),
];
