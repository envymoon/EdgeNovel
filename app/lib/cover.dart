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

final _glyphCache = <String, Future<List<bool>?>>{};

/// Rasterize one character at 1 font-pixel per grid cell and threshold the
/// alpha channel. Cached forever: a glyph never changes within a session.
Future<List<bool>?> _rasterize(String char) {
  return _glyphCache.putIfAbsent(char, () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final tp = TextPainter(
      text: TextSpan(
        text: char,
        style: TextStyle(
          fontSize: _grid.toDouble(),
          color: Color(0xFFFFFFFF),
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
    if (data == null) return null;
    return List<bool>.generate(
      _grid * _grid,
      // Antialiased stroke edges sit at partial alpha; 96 keeps the stroke
      // connected without swallowing the counters.
      (i) => data.getUint8(i * 4 + 3) >= 96,
    );
  });
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
    if (path != null && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          width: width,
          height: width * 1.4,
          fit: BoxFit.cover,
          // A cover file that has gone bad should not take the shelf down with
          // it; fall back to the generated cover.
          errorBuilder: (_, _, _) => _generated(context),
        ),
      );
    }
    return _generated(context);
  }

  Widget _generated(BuildContext context) {
    final base = HSLColor.fromAHSL(1, hue.toDouble(), 0.32, 0.42).toColor();
    final deep = HSLColor.fromAHSL(1, hue.toDouble(), 0.36, 0.28).toColor();
    final cjk = RegExp(r'[㐀-鿿]');
    final char = title.isEmpty
        ? '书'
        : title.characters.firstWhere(
            cjk.hasMatch,
            orElse: () => title.characters.first,
          );

    return Container(
      width: width,
      height: width * 1.4,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, deep],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SizedBox(
                width: width * 0.62,
                height: width * 0.62,
                child: FutureBuilder<List<bool>?>(
                  future: _rasterize(char),
                  builder: (context, snap) => snap.data == null
                      // One frame at most, or a glyph the raster couldn't see.
                      ? Center(
                          child: Text(
                            char,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontSize: width * 0.4,
                            ),
                          ),
                        )
                      : CustomPaint(
                          painter: _GlyphPainter(
                            on: snap.data!,
                            color: Colors.white.withValues(alpha: 0.92),
                            faint: Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            // FittedBox + noScaling: the cover is fixed-size decoration, and OS
            // text scaling must shrink-to-fit here, not overflow the box.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                title.characters.take(6).join(),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: width * 0.115,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  final List<bool> on;
  final Color color;

  /// Off-cells get a whisper of ink so the grid reads as pixel art, not as a
  /// character with a strange haircut.
  final Color faint;

  _GlyphPainter({required this.on, required this.color, required this.faint});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / _grid;
    final gap = cell * 0.16;
    final inkPaint = Paint()..color = color;
    final faintPaint = Paint()..color = faint;
    for (var y = 0; y < _grid; y++) {
      for (var x = 0; x < _grid; x++) {
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x * cell + gap / 2,
            y * cell + gap / 2,
            cell - gap,
            cell - gap,
          ),
          Radius.circular(cell * 0.18),
        );
        canvas.drawRRect(r, on[y * _grid + x] ? inkPaint : faintPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.on != on || old.color != color || old.faint != faint;
}
