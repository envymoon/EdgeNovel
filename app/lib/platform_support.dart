import 'package:flutter/foundation.dart';

enum AppLayoutClass { compact, medium, expanded }

/// One place for platform and form-factor decisions used by the shared UI.
/// Native integrations stay behind capability checks instead of leaking
/// Windows assumptions into reading and library pages.
abstract final class AppPlatformSupport {
  static bool get isMobile => isMobilePlatform(defaultTargetPlatform);

  static bool get isDesktop => isDesktopPlatform(defaultTargetPlatform);

  static bool get supportsBookDrop => isDesktop;

  /// Whether the local model can run here at all.
  static bool get hasAiEngine => isDesktop || hasBundledAiEngine;

  static bool get canDownloadAiEngine => isDesktop;

  /// The engine ships inside the app instead of being downloaded: an
  /// executable in the APK on Android, compiled into the app on iOS.
  static bool get hasBundledAiEngine =>
      defaultTargetPlatform == TargetPlatform.android ||
      (defaultTargetPlatform == TargetPlatform.iOS && iosEngineAvailable);

  /// iOS starts the engine from 16.4 on; an older iOS runs the app without AI.
  /// Set at startup from the engine's own answer.
  static bool iosEngineAvailable = false;

  /// Android's bundled engine is CPU-only; iOS's runs on the GPU (Metal).
  static bool get bundledEngineIsCpuOnly =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Mobile document pickers grant access to the selected files themselves;
  /// the app must never request permission to browse all user storage.
  static bool get usesScopedDocumentAccess => isMobile;

  /// A native scheduler will replace this during platform integration. Until
  /// then mobile AI is intentionally foreground-only.
  static bool get supportsBackgroundAi => isDesktop;

  /// 听书 runs Qwen3-TTS locally: a downloaded engine on Windows, one compiled
  /// into the app on iOS, from the same 16.4 the AI engine needs. Elsewhere
  /// every entry stays hidden.
  static bool get hasReadAloud =>
      defaultTargetPlatform == TargetPlatform.windows ||
      (defaultTargetPlatform == TargetPlatform.iOS && iosEngineAvailable);

  /// The 听书 engine ships inside the app, so only the voice is a download.
  static bool get hasBundledTtsEngine =>
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool isMobilePlatform(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  static bool isDesktopPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux;

  static AppLayoutClass layoutForWidth(double width) {
    if (width < 600) return AppLayoutClass.compact;
    if (width < 1000) return AppLayoutClass.medium;
    return AppLayoutClass.expanded;
  }
}
