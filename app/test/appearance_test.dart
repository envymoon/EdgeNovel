import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:novel/app_localizations.dart' as ui;
import 'package:novel/appearance_page.dart';
import 'package:novel/theme.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'interface preferences persist without changing book typography',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({'fontFamily': 'BookFont'});
      final settings = await ReadingSettings.load();
      settings.setInterfaceFontFamily('system:KaiTi');
      settings.setAccent(3);
      settings.setUniformInterfaceWeight(false);
      final restored = await ReadingSettings.load();
      expect(restored.resolvedInterfaceFont, 'KaiTi');
      expect(restored.resolvedReadingFont, 'BookFont');
      expect(restored.accentIndex, 3);
      expect(restored.uniformInterfaceWeight, false);
      restored.setFontFamily('');
      expect(restored.resolvedReadingFont, 'Microsoft YaHei');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(restored.resolvedReadingFont, isNull);
    },
  );

  testWidgets('uniform UI weight leaves explicit book font weight intact', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const [InterfaceTypography(uniform: true)],
        ),
        home: const Column(
          children: [
            ui.Text('menu', style: TextStyle(fontWeight: FontWeight.w600)),
            ui.Text(
              'book',
              translate: false,
              style: TextStyle(
                fontFamily: 'BookFont',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('menu')).style!.fontWeight,
      FontWeight.w400,
    );
    expect(
      tester.widget<Text>(find.text('book')).style!.fontWeight,
      FontWeight.w600,
    );
  });

  testWidgets(
    'appearance offers independent interface font and weight controls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final settings = ReadingSettings()..setFontFamily('BookFont');
      await tester.pumpWidget(
        MaterialApp(home: AppearancePage(settings: settings)),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('楷体').last);
      await tester.pumpAndSettle();
      expect(settings.interfaceFontFamily, 'system:KaiTi');
      expect(settings.fontFamily, 'BookFont');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(settings.uniformInterfaceWeight, false);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
