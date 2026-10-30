import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 仿真翻页: a page lifted by its right edge rolls over a cylinder lying along
/// the fold, and what has gone over lies flat on top of the rest, back side
/// up. Both pages come in as pictures of themselves, so a frame is a few dozen
/// textured triangles whatever is printed on them, the same on every platform.
class PageCurl {
  /// The page that turns, and the page it uncovers.
  final ui.Image top;
  final ui.Image under;

  /// Image pixels per logical pixel.
  final double scale;

  /// The point of the page's right edge taken hold of, where it lies flat.
  final Offset corner;

  /// Where that point is now: [corner] while the page lies flat, [gone] once
  /// it has turned all the way over.
  final ValueNotifier<Offset> at;

  final Size size;

  PageCurl({
    required this.top,
    required this.under,
    required this.scale,
    required this.corner,
    required this.size,
    required bool turned,
  }) : at = ValueNotifier(corner) {
    if (turned) at.value = gone;
  }

  /// The roll's radius once the page is well under way; it is tighter while
  /// the page has only just been lifted.
  static double radiusFor(Size size) =>
      math.min(size.shortestSide * 0.09, 44.0);

  /// The shadow the turning page throws on the one under it.
  static double shadowFor(Size size) =>
      math.min(size.shortestSide * 0.06, 28.0);

  /// Far enough to the left that neither the page, its roll nor its shadow is
  /// left on screen.
  Offset get gone {
    final r = radiusFor(size);
    return Offset(
      corner.dx - (2 * size.width + 2 * r + 2 * shadowFor(size) + 8),
      corner.dy,
    );
  }

  void dispose() {
    top.dispose();
    under.dispose();
    at.dispose();
  }
}

class PageCurlPainter extends CustomPainter {
  final PageCurl curl;

  /// The paper's colour, which the back of the page mostly is: the print on
  /// its front shows through faintly, mirrored.
  final Color paper;

  PageCurlPainter(this.curl, this.paper) : super(repaint: curl.at);

  /// Cuts across the roll; the flat parts need none.
  static const _steps = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Offset.zero & size;
    final pixels = Paint()..filterQuality = FilterQuality.low;
    canvas.save();
    canvas.clipRect(page);
    canvas.drawImageRect(curl.under, _whole(curl.under), page, pixels);

    final c = curl.corner;
    var lift = c - curl.at.value;
    // Taken by the edge, a page goes over to the left, never steeper than
    // about 60 degrees.
    final across = math.max(lift.dx, 0.0);
    lift = Offset(across, lift.dy.clamp(-2 * across, 2 * across));
    final d = lift.distance;
    if (d < 0.5) {
      canvas.drawImageRect(curl.top, _whole(curl.top), page, pixels);
      canvas.restore();
      return;
    }

    // n points from the fold toward where the page is lifted; s is how far a
    // point of the page lies past the fold's axis o, along n. The lifted
    // point c is half a turn of the roll beyond where it lands.
    final n = lift / d;
    final r = math.min(PageCurl.radiusFor(size), d / math.pi);
    final half = math.pi * r;
    final o = c - n * ((d + half) / 2);
    final along = Offset(-n.dy, n.dx);
    double sOf(Offset x) => (x - o).dx * n.dx + (x - o).dy * n.dy;

    final corners = [
      page.topLeft,
      page.topRight,
      page.bottomRight,
      page.bottomLeft,
    ].map(sOf).toList();
    final lo = corners.reduce(math.min);
    final hi = corners.reduce(math.max);
    // Every corner of the page is a cut, so the page between two cuts is
    // exactly a four-sided strip.
    final cuts =
        <double>{
          ...corners,
          0,
          for (var i = 1; i < _steps; i++) half * i / _steps,
          half,
        }.where((s) => s >= lo && s <= hi).toList()
          ..sort();

    // Where a point at s lands: unchanged before the axis, round the roll,
    // then flat on top going back.
    double landing(double s) => s <= 0
        ? s
        : s < half
        ? r * math.sin(s / r)
        : half - s;

    final ends = [
      for (final s in cuts) _span(o + n * s, along, size),
    ];
    Offset place(Offset x, double s) => x + n * (landing(s) - s);

    final shader = ImageShader(
      curl.top,
      TileMode.clamp,
      TileMode.clamp,
      Matrix4.diagonal3Values(1 / curl.scale, 1 / curl.scale, 1).storage,
      filterQuality: FilterQuality.low,
    );
    final textured = Paint()..shader = shader;
    final rim = math.pi * r / 2;

    // Strips facing up (before the top of the roll) and facing down (past it,
    // the back), each as triangles of the page laid where they land.
    ui.Vertices strips(bool back) {
      final at = <Offset>[];
      final from = <Offset>[];
      for (var i = 0; i + 1 < cuts.length; i++) {
        if (((cuts[i] + cuts[i + 1]) / 2 >= rim) != back) continue;
        final (a0, b0) = ends[i];
        final (a1, b1) = ends[i + 1];
        final quad = [a0, b0, b1, a1];
        final landed = [
          for (final (k, x) in quad.indexed) place(x, cuts[i + (k < 2 ? 0 : 1)]),
        ];
        for (final k in const [0, 1, 2, 0, 2, 3]) {
          at.add(landed[k]);
          from.add(quad[k]);
        }
      }
      return ui.Vertices(VertexMode.triangles, at, textureCoordinates: from);
    }

    // The outline of the part between cuts [from, to], as it lands.
    Path outline(double from, double to) {
      final left = <Offset>[];
      final right = <Offset>[];
      for (var i = 0; i < cuts.length; i++) {
        if (cuts[i] < from || cuts[i] > to) continue;
        left.add(place(ends[i].$1, cuts[i]));
        right.add(place(ends[i].$2, cuts[i]));
      }
      return Path()..addPolygon([...left, ...right.reversed], true);
    }

    // Shades the band between distances [from] and [to] past the axis, as
    // the page lands, from [a] to [b].
    void band(double from, double to, Color a, Color b) {
      canvas.save();
      canvas.translate(o.dx, o.dy);
      canvas.rotate(math.atan2(n.dy, n.dx));
      final far = size.longestSide * 2;
      final rect = Rect.fromLTRB(from, -far, to, far);
      canvas.drawRect(
        rect,
        Paint()..shader = LinearGradient(colors: [a, b]).createShader(rect),
      );
      canvas.restore();
    }

    // How far the lifted part reaches past the axis.
    final reach = hi >= rim ? r : r * math.sin(math.max(hi, 0) / r);
    band(
      reach,
      reach + PageCurl.shadowFor(size),
      Colors.black.withValues(alpha: 0.22),
      Colors.black.withValues(alpha: 0),
    );

    final front = strips(false);
    canvas.drawVertices(front, BlendMode.srcOver, textured);
    front.dispose();
    // The roll darkens as it turns away from the light.
    if (hi > 0) {
      canvas.save();
      canvas.clipPath(outline(0, rim));
      band(
        0,
        reach,
        Colors.black.withValues(alpha: 0),
        Colors.black.withValues(alpha: 0.16),
      );
      canvas.restore();
    }

    if (hi > rim) {
      final backOutline = outline(rim, hi);
      canvas.drawShadow(backOutline, Colors.black, 3, false);
      final back = strips(true);
      canvas.drawVertices(back, BlendMode.srcOver, textured);
      back.dispose();
      canvas.save();
      canvas.clipPath(backOutline);
      canvas.drawPaint(Paint()..color = paper.withValues(alpha: 0.88));
      band(
        0,
        r,
        Colors.black.withValues(alpha: 0),
        Colors.black.withValues(alpha: 0.1),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  static Rect _whole(ui.Image image) =>
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

  /// The part of the line through [base] along [along] that is on the page.
  static (Offset, Offset) _span(Offset base, Offset along, Size size) {
    var u0 = -double.maxFinite;
    var u1 = double.maxFinite;
    void side(double b, double step, double extent) {
      // A line running along this side is between its edges already: the
      // cuts never go past the page's corners.
      if (step.abs() < 1e-9) return;
      var a = -b / step;
      var z = (extent - b) / step;
      if (a > z) (a, z) = (z, a);
      u0 = math.max(u0, a);
      u1 = math.min(u1, z);
    }

    side(base.dx, along.dx, size.width);
    side(base.dy, along.dy, size.height);
    if (u1 < u0) u1 = u0;
    return (base + along * u0, base + along * u1);
  }

  @override
  bool shouldRepaint(PageCurlPainter old) =>
      old.curl != curl || old.paper != paper;
}
