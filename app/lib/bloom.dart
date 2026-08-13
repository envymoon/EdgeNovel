import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A flower that opens and closes, forever, while something is working.
///
/// It exists because the honest progress bar for most of this app's waiting is
/// indeterminate — a model loading its weights off disk cannot say how far along
/// it is, and a bar that invents a percentage is a lie. What a reader actually
/// needs to know in that moment is only that the app is alive. A shape that
/// breathes says that better than a spinner, which is the same shape a frozen
/// app leaves on screen.
class Bloom extends StatefulWidget {
  final double size;
  final Color color;

  const Bloom({super.key, this.size = 26, required this.color});

  @override
  State<Bloom> createState() => _BloomState();
}

class _BloomState extends State<Bloom> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => CustomPaint(
      size: Size.square(widget.size),
      painter: _BloomPainter(_c.value, widget.color),
    ),
  );
}

class _BloomPainter extends CustomPainter {
  final double t;
  final Color color;

  const _BloomPainter(this.t, this.color);

  static const _petals = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    for (var i = 0; i < _petals; i++) {
      // Each petal opens a beat after the one before it, so the flower unfurls
      // rather than inflating.
      final phase = (t - i * 0.055) % 1.0;
      // 0 → 1 → 0: open, hold, close.
      final open = math.sin(math.max(phase, 0) * math.pi);
      final eased = Curves.easeOutCubic.transform(open.clamp(0.0, 1.0));

      final angle = i * 2 * math.pi / _petals;
      final reach = r * (0.30 + 0.58 * eased);

      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(angle);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(0, -reach * 0.62),
          width: r * (0.34 + 0.30 * eased),
          height: reach * 1.05,
        ),
        Paint()
          ..color = color.withValues(alpha: 0.20 + 0.55 * eased)
          ..style = PaintingStyle.fill,
      );
      canvas.restore();
    }

    // A steady heart, so the flower never fully disappears between beats.
    canvas.drawCircle(
      c,
      r * 0.17,
      Paint()..color = color.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_BloomPainter old) => old.t != t || old.color != color;
}

/// The flower, a bar, and a line of text saying what is actually happening.
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
