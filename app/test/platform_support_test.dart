import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/platform_support.dart';
import 'package:novel/platform_services.dart';

void main() {
  test('mobile and desktop capabilities stay separate', () {
    expect(AppPlatformSupport.isMobilePlatform(TargetPlatform.iOS), isTrue);
    expect(AppPlatformSupport.isMobilePlatform(TargetPlatform.android), isTrue);
    expect(
      AppPlatformSupport.isMobilePlatform(TargetPlatform.windows),
      isFalse,
    );
    expect(
      AppPlatformSupport.isDesktopPlatform(TargetPlatform.windows),
      isTrue,
    );
  });

  test('layout classes use phone and tablet boundaries', () {
    expect(AppPlatformSupport.layoutForWidth(390), AppLayoutClass.compact);
    expect(AppPlatformSupport.layoutForWidth(768), AppLayoutClass.medium);
    expect(AppPlatformSupport.layoutForWidth(1200), AppLayoutClass.expanded);
  });

  test('mobile lifecycle policy only permits foreground AI', () {
    const mobile = AppExecutionPolicy(mobile: true);
    const desktop = AppExecutionPolicy(mobile: false);
    expect(mobile.aiAllowedIn(AppLifecycleState.resumed), isTrue);
    expect(mobile.aiAllowedIn(AppLifecycleState.paused), isFalse);
    expect(mobile.aiAllowedIn(AppLifecycleState.inactive), isFalse);
    expect(desktop.aiAllowedIn(AppLifecycleState.paused), isTrue);
  });
}
