import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/app_localizations.dart';
import 'package:novel/settings_page.dart';
import 'package:novel/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings switches the app chrome to English and persists it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await ReadingSettings.load();

    Widget app() => ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        locale: settings.language.locale,
        builder: (context, child) => AppLanguageScope(
          language: settings.language,
          child: child ?? const SizedBox.shrink(),
        ),
        home: SettingsPage(settings: settings),
      ),
    );

    await tester.pumpWidget(app());
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('界面语言'), findsOneWidget);

    await tester.tap(find.text('界面语言'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('App language'), findsOneWidget);
    expect(find.text('AI Runtime & Device'), findsOneWidget);

    final restored = await ReadingSettings.load();
    expect(restored.language, AppLanguage.english);
  });

  testWidgets('book content can opt out of interface translation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppLanguageScope(
          language: AppLanguage.english,
          child: Scaffold(body: Text('设置', translate: false)),
        ),
      ),
    );

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
  });
}
