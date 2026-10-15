import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small star that keeps changing shape while something is working: a dot,
/// four teardrops, eight spokes, a six-pointed star, six teardrops, eight fat
/// ones, and back — after the spinner beside Claude Code's status line
/// (· ✢ ✳ ✶ ✻ ✽). They are drawn, not set in a font: fonts on Windows
/// and Android disagree about these marks, and ✳ comes out as an emoji.
///
/// It exists because the honest progress bar for most of this app's waiting is
/// indeterminate — a model loading its weights off disk cannot say how far along
/// it is, and a bar that invents a percentage is a lie. What a reader actually
/// needs to know in that moment is only that the app is alive. A shape that
/// keeps changing says that better than a spinner, which is the same shape a
/// frozen app leaves on screen.
///
/// It moves like a flip-book: a handful of still drawings shown in turn, not a
/// smooth tween. That is the look, and it is also cheap — a few repaints a
/// second instead of one every frame, which matters for the small star that
/// sits in the task bar through an hour of background analysis on a phone.
class Bloom extends StatefulWidget {
  final double size;
  final Color color;

  const Bloom({super.key, this.size = 26, required this.color});

  @override
  State<Bloom> createState() => _BloomState();
}

/// The drawings, each the star's outline for a radius `r` around the origin.
final _glyphs = <Path Function(double r)>[
  (r) => _dot(r * 0.13), // ·
  (r) => _spokes(4, _teardrop(r * 0.02, r * 0.82, r * 0.16)), // ✢
  (r) => _spokes(8, _bar(r * 0.78, r * 0.12)), // ✳
  (r) => _star(6, r * 0.82, r * 0.44), // ✶
  (r) => _spokes(6, _teardrop(r * 0.1, r * 0.82, r * 0.13)), // ✻
  (r) => _spokes(8, _teardrop(r * 0.06, r * 0.82, r * 0.17)), // ✽
];

/// Which drawing each beat shows: out to the fattest and back again.
const _sequence = [0, 1, 2, 3, 4, 5, 5, 4, 3, 2, 1, 0];
const _beat = Duration(milliseconds: 120);

Path _dot(double radius) =>
    Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: radius));

/// `n` copies of `spoke` (which points up) turned evenly around the origin,
/// as one outline so a translucent colour does not darken where they meet.
Path _spokes(int n, Path spoke) {
  final all = Path();
  for (var i = 0; i < n; i++) {
    all.addPath(
      spoke,
      Offset.zero,
      matrix4: Matrix4.rotationZ(i * 2 * math.pi / n).storage,
    );
  }
  return all;
}

/// A spoke pointing up, coming to a point at `from` and swelling into a round
/// end of radius `bulb` that reaches `to`.
Path _teardrop(double from, double to, double bulb) {
  final centre = Offset(0, -(to - bulb));
  // Where the straight sides meet the round end, measured from straight down.
  final side = math.acos(bulb / (to - bulb - from));
  return Path()
    ..moveTo(0, -from)
    ..arcTo(
      Rect.fromCircle(center: centre, radius: bulb),
      math.pi / 2 + side,
      2 * math.pi - 2 * side,
      false,
    )
    ..close();
}

/// A round-ended bar from the origin up to `to`.
Path _bar(double to, double width) => Path()
  ..addRRect(
    RRect.fromLTRBR(
      -width / 2,
      -to,
      width / 2,
      width / 2,
      Radius.circular(width / 2),
    ),
  );

/// A filled star with `points` points, one straight up.
Path _star(int points, double outer, double inner) {
  final star = Path();
  for (var i = 0; i < points * 2; i++) {
    final a = i * math.pi / points - math.pi / 2;
    final k = i.isEven ? outer : inner;
    final p = Offset(k * math.cos(a), k * math.sin(a));
    i == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
  }
  return star..close();
}

class _BloomState extends State<Bloom> {
  Timer? _timer;
  int _step = 0;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pauses on a page that is covered or offstage, as a ticker would; and
    // with system animations turned off it simply shows the star.
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final run = TickerMode.valuesOf(context).enabled && !_reduced;
    if (run && _timer == null) {
      _timer = Timer.periodic(
        _beat,
        (_) => setState(() => _step = (_step + 1) % _sequence.length),
      );
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(widget.size),
    painter: _BloomPainter(_reduced ? 4 : _sequence[_step], widget.color),
  );
}

class _BloomPainter extends CustomPainter {
  final int glyph;
  final Color color;

  const _BloomPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    canvas.drawPath(
      _glyphs[glyph](r).shift(size.center(Offset.zero)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_BloomPainter old) =>
      old.glyph != glyph || old.color != color;
}

/// The star, a bar, and a line of text saying what is actually happening.
///
/// `value` is null when the work genuinely cannot report a fraction; the bar
/// then sweeps instead of filling. Pass a real fraction only when there is one.
class BloomProgress extends StatelessWidget {
  final String label;
  final String? detail;
  final double? value;
  final Color color;
  final Color textColor;
  final Widget? trailing;

  const BloomProgress({
    super.key,
    required this.label,
    required this.color,
    required this.textColor,
    this.detail,
    this.value,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Bloom(color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: value,
          minHeight: 3,
          backgroundColor: color.withValues(alpha: 0.12),
        ),
      ),
      if (detail != null) ...[
        const SizedBox(height: 8),
        Text(
          detail!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 11),
        ),
      ],
    ],
  );
}
