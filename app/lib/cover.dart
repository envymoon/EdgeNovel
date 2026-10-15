import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A cover drawn from the title, not generated from it. The hero is the first
/// CJK character of the title rasterized into a 16×16 grid and drawn as pixel
/// blocks — the font is already the authoritative picture of what a character
/// looks like, so the result is deterministic and never malformed, which is
/// exactly what a tiny language model asked to "draw" a grid cannot promise.
/// Saturation and lightness stay fixed; only the hue varies per title.
const _grid = 16;

/// Each glyph once as a single outline of its lit cells in a unit square, so a
/// cover draws it in one call at any size. Kept for the session: a glyph never
/// changes, and there is one per distinct first character on the shelf.
final _glyphs = <String, Path?>{};
final _pending = <String, Future<Path?>>{};

/// Rasterize one character at 1 font-pixel per grid cell and threshold the
/// alpha channel.
Future<Path?> _glyph(String char) => _pending.putIfAbsent(char, () async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final tp = TextPainter(
    text: TextSpan(
      text: char,
      style: TextStyle(
        fontSize: _grid.toDouble(),
        color: const Color(0xFFFFFFFF),
        fontWeight: FontWeight.w600,
        height: 1.0,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset((_grid - tp.width) / 2, (_grid - tp.height) / 2));
  final img = await recorder.endRecording().toImage(_grid, _grid);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  Path? path;
  if (data != null) {
    const cell = 1 / _grid;
    const gap = cell * 0.14;
    path = Path();
    for (var i = 0; i < _grid * _grid; i++) {
      // Antialiased stroke edges sit at partial alpha; 96 keeps the stroke
      // connected without swallowing the counters.
      if (data.getUint8(i * 4 + 3) < 96) continue;
      path.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i % _grid * cell + gap / 2,
            i ~/ _grid * cell + gap / 2,
            cell - gap,
            cell - gap,
          ),
          const Radius.circular(cell * 0.16),
        ),
      );
    }
  }
  return _glyphs[char] = path;
});

/// Forget decoded cover pictures after a cover file is written over. They are
/// decoded at the size they are shown, under keys a path alone cannot name, so
/// the whole cache goes; it only holds small pictures and refills on sight.
void forgetCovers() {
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}

class TextCover extends StatelessWidget {
  final String title;
  final int hue;
  final double width;

  /// A reader-chosen image on disk. When present and readable, it replaces the
  /// generated cover entirely.
  final String? coverPath;

  const TextCover({
    super.key,
    required this.title,
    required this.hue,
    this.width = 84,
    this.coverPath,
  });

  @override
  Widget build(BuildContext context) {
    final path = coverPath;
    final picture = path != null && File(path).existsSync()
        ? Image.file(
            File(path),
            fit: BoxFit.cover,
            // Decoded at the size it is shown, not the 512×768 it was drawn
            // at: a shelf of full-size pictures held over a megabyte apiece.
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round(),
            // A cover file that has gone bad should not take the shelf down
            // with it; fall back to the generated cover.
            errorBuilder: (_, _, _) => _generated(),
          )
        : _generated();
    return RepaintBoundary(
      child: Container(
        width: width,
        height: width * 1.4,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: CustomPaint(foregroundPainter: const _Binding(), child: picture),
      ),
    );
  }

  Widget _generated() {
    final top = HSLColor.fromAHSL(1, hue.toDouble(), 0.24, 0.42).toColor();
    final bottom = HSLColor.fromAHSL(1, hue.toDouble(), 0.28, 0.25).toColor();
    final cjk = RegExp(r'[㐀-鿿]');
    final char = title.isEmpty
        ? '书'
        : title.characters.firstWhere(
            cjk.hasMatch,
            orElse: () => title.characters.first,
          );
    final ink = Colors.white.withValues(alpha: 0.92);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
      ),
      child: Padding(
        // Centred on the board, not on the spine.
        padding: EdgeInsets.only(left: width * _spine),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SizedBox.square(
                  dimension: width * 0.6,
                  child: _glyphs.containsKey(char)
                      ? _glyphView(char, ink)
                      : FutureBuilder<Path?>(
                          future: _glyph(char),
                          builder: (context, _) => _glyphView(char, ink),
                        ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(6, 0, 6, width * 0.09),
              // FittedBox + noScaling: the cover is fixed-size decoration,
              // and OS text scaling must shrink-to-fit here, not overflow.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  title.characters.take(6).join(),
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: width * 0.1,
                    fontWeight: FontWeight.w500,
                    letterSpacing: width * 0.015,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glyphView(String char, Color ink) {
    final path = _glyphs[char];
    // For a frame at most, or a glyph the raster couldn't see.
    if (path == null) {
      return Center(
        child: Text(
          char,
          textScaler: TextScaler.noScaling,
          style: TextStyle(color: ink, fontSize: width * 0.4),
        ),
      );
    }
    return CustomPaint(painter: _GlyphPainter(path, ink));
  }
}

/// The spine's share of the cover's width.
const _spine = 0.06;

/// What makes a picture a book: a darker strip down the spine and the crease
/// where the board folds, over drawn and chosen covers alike.
class _Binding extends CustomPainter {
  const _Binding();

  @override
  void paint(Canvas canvas, Size size) {
    final spine = size.width * _spine;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, spine, size.height),
      Paint()..color = const Color(0x2E000000),
    );
    canvas.drawRect(
      Rect.fromLTWH(spine, 0, 1, size.height),
      Paint()..color = const Color(0x24FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_Binding old) => false;
}

class _GlyphPainter extends CustomPainter {
  final Path glyph;
  final Color color;

  const _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width);
    // A pixel's worth of shadow down and to the right lifts the character off
    // the board.
    canvas.drawPath(
      glyph.shift(const Offset(0.5 / _grid, 0.5 / _grid)),
      Paint()..color = const Color(0x40000000),
    );
    canvas.drawPath(glyph, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
