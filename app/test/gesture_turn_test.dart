import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/gesture_turn.dart';
import 'package:novel/gesture_turn_page.dart';
import 'package:novel/theme.dart';

const _channel = MethodChannel('novel/gesture');

/// What the phone would say over the channel.
Future<void> _say(String method, Object? arguments) => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );

void main() {
  testWidgets('the page runs the camera, shows what it saw, and saves the picks', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    GestureTurn.instance; // installs its handler
    final settings = ReadingSettings();
    // Tall enough for every row.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: GestureTurnPage(settings: settings)),
    );
    await tester.pump();
    expect(calls, ['start']);

    await _say('seen', {'face': true, 'hand': false});
    await _say('gesture', 'nod');
    await tester.pump();
    // Shown in the box, besides its own row in the list.
    expect(find.text('点头'), findsNWidgets(2));
    expect(find.text('脸 ✓   手 —'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('点头'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(settings.gestureTurn, isTrue);

    // A wave switched on turns forward; it can be made to turn back.
    final wave = find.ancestor(
      of: find.text('向右挥手'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(of: wave, matching: find.byType(Switch)));
    await tester.pump();
    expect(settings.gestureActions['swipeRight'], 1);
    await tester.tap(find.descendant(of: wave, matching: find.text('上一页')));
    await tester.pump();
    expect(settings.gestureActions['swipeRight'], -1);
    await tester.tap(find.descendant(of: wave, matching: find.byType(Switch)));
    await tester.pump();
    expect(settings.gestureActions.containsKey('swipeRight'), isFalse);

    await tester.pumpWidget(const SizedBox());
    // Each change is sent while it runs.
    expect(calls.toSet(), {'start', 'watch', 'stop'});
    expect(calls.first, 'start');
    expect(calls.last, 'stop');
    debugDefaultTargetPlatformOverride = null;
  });
}
