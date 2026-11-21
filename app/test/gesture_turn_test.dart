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

    await tester.pumpWidget(
      MaterialApp(home: GestureTurnPage(settings: settings)),
    );
    await tester.pump();
    expect(calls, ['start']);

    await _say('seen', {'face': true, 'hand': false});
    await _say('gesture', 'nod');
    await tester.pump();
    expect(find.text('点头'), findsOneWidget);
    expect(find.text('脸 ✓   手 —'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('点头'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(settings.gestureTurn, isTrue);

    await tester.tap(find.text('向右转头'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('向右挥手').last);
    await tester.pumpAndSettle();
    expect(settings.gestureNext, 'swipeRight');

    await tester.pumpWidget(const SizedBox());
    expect(calls, ['start', 'stop']);
    debugDefaultTargetPlatformOverride = null;
  });
}
