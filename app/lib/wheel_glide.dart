import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Turns mouse-wheel notches into a glide.
///
/// Flutter applies each notch as an instant jump of the platform's distance (on
/// Windows about three lines of text), so reading by wheel advances in visible
/// lurches. This travels [scale] of that distance and glides there on a
/// critically damped spring. A notch that arrives mid-glide moves the
/// destination and keeps the current speed, so a spun wheel runs as one
/// continuous motion rather than a series of fresh starts.
///
/// Wrap each *item* of the list, not the list: pointer signals reach the
/// innermost listener first and the first to claim one wins, so a wrapper
/// outside the scrollable would always lose to the list's own jump. For the
/// same reason the glide cannot be an `animateTo`: while that runs, the list's
/// contents ignore the pointer, so every notch after the first fell through to
/// the jump. Touchpads and touch screens arrive as pan gestures, not wheel
/// signals, and keep their native feel.
class WheelGlide extends StatelessWidget {
  const WheelGlide({super.key, required this.scale, required this.child});

  /// Fraction of the platform's per-notch distance to travel.
  final double scale;
  final Widget child;

  static final _glides = Expando<_GlideActivity>();

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Opaque so the gaps between lines and the margins inside the item
      // catch the wheel too.
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent ||
            event.kind != PointerDeviceKind.mouse) {
          return;
        }
        final delta = event.scrollDelta.dy * scale;
        final position = Scrollable.maybeOf(context)?.position;
        if (delta == 0 || position is! ScrollPositionWithSingleContext) return;
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          (_) => _glide(position, delta),
        );
      },
      child: child,
    );
  }

  static void _glide(ScrollPositionWithSingleContext position, double delta) {
    var glide = _glides[position];
    // A drag, a keyboard page or read-aloud following ends the glide by
    // starting its own activity; the next notch then starts from where the
    // text is, not from a stale destination.
    if (glide != null && glide.disposed) glide = null;
    final from = glide?.target ?? position.pixels;
    final to = (from + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (to == from) return;
    if (glide == null) {
      glide = _glides[position] = _GlideActivity(position);
      position.beginActivity(glide);
    }
    glide.glideTo(to);
  }
}

/// Carries the list toward [target] on a spring, retargeted by each notch.
class _GlideActivity extends ScrollActivity {
  _GlideActivity(ScrollPositionWithSingleContext super.delegate)
    : target = delegate.pixels,
      _controller = AnimationController.unbounded(
        value: delegate.pixels,
        vsync: delegate.context.vsync,
      ) {
    _controller.addListener(_tick);
  }

  /// Critically damped, so it never overshoots; a lone notch settles in about
  /// a third of a second, easing in and out.
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 400,
  );
  static const _tolerance = Tolerance(distance: 0.5, velocity: 5);

  final AnimationController _controller;
  double target;
  bool disposed = false;

  void glideTo(double to) {
    target = to;
    // Starting from the current speed is what keeps a spun wheel smooth. The
    // future completes only when the glide arrives, not when a later notch
    // replaces it.
    _controller
        .animateWith(
          SpringSimulation(
            _spring,
            _controller.value,
            to,
            _controller.velocity,
            tolerance: _tolerance,
            snapToEnd: true,
          ),
        )
        .then((_) {
          if (!disposed) delegate.goBallistic(0);
        });
  }

  void _tick() {
    // Overscroll means the edge was reached.
    if (delegate.setPixels(_controller.value) != 0) delegate.goIdle();
  }

  @override
  void dispatchOverscrollNotification(
    ScrollMetrics metrics,
    BuildContext context,
    double overscroll,
  ) {
    OverscrollNotification(
      metrics: metrics,
      context: context,
      overscroll: overscroll,
      velocity: velocity,
    ).dispatch(context);
  }

  /// Unlike `animateTo`, keep the contents hit-testable, so the next notch
  /// reaches [WheelGlide] instead of the list's jump.
  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => _controller.velocity;

  @override
  void dispose() {
    disposed = true;
    _controller.dispose();
    super.dispose();
  }
}
