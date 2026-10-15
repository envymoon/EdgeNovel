import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows branding keeps the legacy persistent-data identity', () {
    final resource = File('windows/runner/Runner.rc').readAsStringSync();

    // path_provider_windows derives the AppData folder from CompanyName and
    // ProductName (%APPDATA%\com.novel\novel). Changing either makes an
    // existing library appear to disappear. The window title and
    // FileDescription are only what the user sees, so they carry the name.
    expect(resource, contains('VALUE "CompanyName", "com.novel"'));
    expect(resource, contains('VALUE "ProductName", "novel"'));
  });

  test('Android keeps the application id its data is stored under', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    // Android keys an app's private storage to this id; a new id installs as
    // a different app with an empty library.
    expect(gradle, contains('applicationId = "com.novel.novel"'));
  });

  test('Windows llama.cpp download uses a compatible pinned release', () {
    final source = File('lib/ai_page.dart').readAsStringSync();

    expect(source, contains("const _llamaBuild = 'b9957'"));
    expect(
      source,
      isNot(
        contains('api.github.com/repos/ggml-org/llama.cpp/releases/latest'),
      ),
    );
  });
}
