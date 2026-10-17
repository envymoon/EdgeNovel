import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/paged_reader.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final settings = ReadingSettings();
  final paras = [
    for (var i = 0; i < 12; i++)
      Paragraph(
        kind: ParaKind.body,
        text: '他把灯挑亮了些，又低头看那张旧地图。' * (3 + i),
        start: i * 1000,
        end: i * 1000 + 900,
      ),
  ];
  final pages = paginate(
    paras,
    const Size(350, 600),
    settings,
    settings.theme,
    const {},
  );

  test('a chunk cut at the foot of a page shows exactly its own lines', () {
    final cut = [
      for (final page in pages)
        for (final c in page.chunks)
          if (!c.endsParagraph) (page, c),
    ];
    expect(cut, isNotEmpty);
    for (final (page, c) in cut) {
      expect(c.lines, greaterThan(0));
      expect(c.tail, isNotEmpty);
      // Drawn the way the page draws it: the paragraph's remainder at the
      // page's width, clipped to the lines counted for this page.
      final tp = TextPainter(
        text: TextSpan(
          text: c.text + c.tail,
          style: TextStyle(
            fontFamily: settings.resolvedReadingFont,
            locale: const Locale.fromSubtags(
              languageCode: 'zh',
              scriptCode: 'Hans',
            ),
            fontSize: settings.fontSize,
            height: settings.lineHeight,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: c.lines,
      )..layout(maxWidth: page.width);
      final lines = tp.computeLineMetrics();
      expect(lines, hasLength(c.lines));
      final end = tp
          .getLineBoundary(
            tp.getPositionForOffset(Offset(page.width, lines.last.baseline)),
          )
          .end;
      expect(end, c.text.length);
    }
  });

  test('the indent is drawn, not spaced, and the text survives paging', () {
    for (var i = 0; i < paras.length; i++) {
      final chunks = [
        for (final page in pages)
          for (final c in page.chunks)
            if (c.paraIndex == i) c,
      ];
      expect(chunks.first.text, startsWith(indentGlyphs));
      expect(chunks.first.leadingNonSource, indentGlyphs.length);
      expect(
        chunks.map((c) => c.text.substring(c.leadingNonSource)).join(),
        paras[i].text,
      );
    }
  });
}
