import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/wheel_glide.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

void main() {
  Future<ScrollController> pumpList(WidgetTester tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView.builder(
          controller: controller,
          itemCount: 200,
          itemBuilder: (context, i) => WheelGlide(
            scale: 0.5,
            child: SizedBox(height: 40, child: Text('line $i')),
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> wheel(WidgetTester tester, double dy) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(ListView))),
    );
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  }

  /// Pumps [frames] 60 Hz frames and returns the offset after each.
  Future<List<double>> frames(
    WidgetTester tester,
    ScrollController controller,
    int frames,
  ) async {
    final offsets = <double>[];
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      offsets.add(controller.offset);
    }
    return offsets;
  }

  testWidgets('a wheel notch glides a reduced distance instead of jumping', (
    tester,
  ) async {
    final controller = await pumpList(tester);

    await wheel(tester, 100);
    await tester.pump();
    // The list's own handler would already be at 100.
    expect(controller.offset, lessThan(50));

    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(50));

    await tester.pumpAndSettle();
    expect(controller.offset, 50);
  });

  testWidgets('a spun wheel moves as one glide, never a jump', (tester) async {
    final controller = await pumpList(tester);

    final offsets = <double>[];
    for (var notch = 0; notch < 5; notch++) {
      await wheel(tester, 100);
      offsets.addAll(await frames(tester, controller, 5));
    }
    await tester.pumpAndSettle();
    expect(controller.offset, 250);

    var previous = 0.0;
    for (final offset in offsets) {
      expect(offset, greaterThanOrEqualTo(previous - 1e-9));
      // A notch is 50 here; a frame that covers most of one is a jump.
      expect(offset - previous, lessThan(15));
      previous = offset;
    }
  });

  testWidgets('a notch back during a glide reverses it', (tester) async {
    final controller = await pumpList(tester);

    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 50));
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 50));
    await wheel(tester, -100);
    await tester.pumpAndSettle();
    expect(controller.offset, 50);
  });

  testWidgets('the reader\'s positioned list glides the same way', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ScrollablePositionedList.builder(
          itemCount: 200,
          itemBuilder: (context, i) => WheelGlide(
            scale: 0.5,
            child: SizedBox(height: 40, child: Text('line $i')),
          ),
        ),
      ),
    );
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final center = tester.getCenter(find.byType(ScrollablePositionedList));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    for (var notch = 0; notch < 3; notch++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(position.pixels, lessThan(50.0 * (notch + 1)));
    }
    await tester.pumpAndSettle();
    expect(position.pixels, 150);
  });

  testWidgets('the glide stops at the top', (tester) async {
    final controller = await pumpList(tester);

    await wheel(tester, -100);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });
}
