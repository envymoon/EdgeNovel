import 'package:flutter/foundation.dart';

enum AppLayoutClass { compact, medium, expanded }

/// One place for platform and form-factor decisions used by the shared UI.
/// Native integrations stay behind capability checks instead of leaking
/// Windows assumptions into reading and library pages.
abstract final class AppPlatformSupport {
  static bool get isMobile => isMobilePlatform(defaultTargetPlatform);

  static bool get isDesktop => isDesktopPlatform(defaultTargetPlatform);

  static bool get supportsBookDrop => isDesktop;

  static bool get usesExternalAiProcess => isDesktop || hasBundledAiEngine;

  static bool get canDownloadAiEngine => isDesktop;

  static bool get hasBundledAiEngine =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Mobile document pickers grant access to the selected files themselves;
  /// the app must never request permission to browse all user storage.
  static bool get usesScopedDocumentAccess => isMobile;

  /// A native scheduler will replace this during platform integration. Until
  /// then mobile AI is intentionally foreground-only.
  static bool get supportsBackgroundAi => isDesktop;

  /// 听书 is hidden until it is worth using: the voices it can run today are
  /// too poor to read a book by. The code and any installed voice stay; this
  /// brings every entry back.
  static const hasReadAloud = false;

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
