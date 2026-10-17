import 'package:flutter_test/flutter_test.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/tts_text.dart';

List<String> sentences(String text) => [
  for (final s in sentenceSegments(text)) text.substring(s.start, s.end),
];

void main() {
  test('a sentence keeps its closing quote and its run of enders', () {
    expect(sentences('“你好。”他说。'), ['“你好。”', '他说。']);
    expect(sentences('什么？！真的……”好吧。'), ['什么？！', '真的……”', '好吧。']);
    expect(sentences('《书名》。’走吧'), ['《书名》。’', '走吧']);
  });

  test('marks with no sound are left out, pauses read as pauses', () {
    expect(speakable('“你好。”'), '你好。');
    expect(speakable('他说：“走——”'), '他说，走。');
    expect(speakable('我......我不知道'), '我，我不知道');
    expect(speakable('可是......'), '可是。');
    expect(speakable('什么？！'), '什么？');
    expect(speakable('（笑）好吧～'), '笑好吧。');
  });

  test('a lone mark has nothing to say', () {
    for (final s in ['”', '“', '*', '* * *', '......', '“......”', '——', '。']) {
      expect(speakable(s), '', reason: s);
    }
  });

  test('numbers, names and letters read as they are', () {
    expect(speakable('花了3.5元，12:30到'), '花了3.5元，12:30到');
    expect(speakable('一共1,000人'), '一共1000人');
    expect(speakable('约翰·史密斯来了'), '约翰 史密斯来了');
    expect(speakable('Ａ１号'), 'A1号');
    expect(speakable('打折50%'), '打折50%');
    // A site's name stamped in in dressed-up letters.
    expect(speakable('𝐤𝐚𝐧𝐜𝐨𝐦第一章'), '第一章');
  });

  test('a chapter leaves out what has nothing to say', () {
    Paragraph p(String text) =>
        Paragraph(kind: ParaKind.body, text: text, start: 0, end: 0);
    final utts = chapterUtterances([p('“走吧。”'), p('*'), p('他点头。”')]);
    expect(utts.map((u) => u.text), ['走吧。', '他点头。']);
    expect(utts.map((u) => u.paragraphIndex), [0, 2]);
    // The range is the sentence as written, quotes and all.
    expect([utts[0].start, utts[0].end], [0, 5]);
  });
}
