import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/ai_runtime.dart';
import 'package:novel/platform_support.dart';
import 'package:novel/platform_services.dart';
import 'package:novel/src/rust/api/ai.dart';

void main() {
  test('phones bundle the engine; mobile stays foreground-only', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(AppPlatformSupport.hasBundledAiEngine, isTrue);
    expect(AppPlatformSupport.hasAiEngine, isTrue);
    expect(AppPlatformSupport.canDownloadAiEngine, isFalse);
    expect(AppPlatformSupport.supportsBackgroundAi, isFalse);
    expect(AppPlatformSupport.bundledEngineIsCpuOnly, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(AppPlatformSupport.hasAiEngine, isFalse);
    expect(AppPlatformSupport.hasReadAloud, isFalse);
    AppPlatformSupport.iosEngineAvailable = true;
    addTearDown(() => AppPlatformSupport.iosEngineAvailable = false);
    expect(AppPlatformSupport.hasBundledAiEngine, isTrue);
    expect(AppPlatformSupport.hasAiEngine, isTrue);
    expect(AppPlatformSupport.hasReadAloud, isTrue);
    expect(AppPlatformSupport.hasBundledTtsEngine, isTrue);
    expect(AppPlatformSupport.bundledEngineIsCpuOnly, isFalse);
    expect(AppPlatformSupport.canDownloadAiEngine, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(AppPlatformSupport.hasBundledAiEngine, isFalse);
    expect(AppPlatformSupport.hasAiEngine, isTrue);
  });
  test('a warm phone holds quiet AI; only a hot one holds the rest', () {
    final ai = AiRuntimeSettings.instance;
    addTearDown(() => ai.mode = AiRunMode.quiet);
    AiDeviceState phone(String thermal) => AiDeviceState(
      platform: 'ios',
      charging: true,
      batteryPercent: 80,
      logicalCores: 6,
      thermalState: thermal,
    );
    expect(ai.waitingReason(phone('nominal'), reading: false), isNull);
    expect(ai.waitingReason(phone('fair'), reading: false), isNotNull);
    ai.mode = AiRunMode.balanced;
    expect(ai.waitingReason(phone('fair'), reading: false), isNull);
    expect(ai.waitingReason(phone('serious'), reading: false), isNotNull);
  });
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
