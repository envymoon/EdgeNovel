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

  /// Mobile document pickers grant access to the selected files themselves;
  /// the app must never request permission to browse all user storage.
  static bool get usesScopedDocumentAccess => isMobile;

  /// The queue runs off screen by itself only on desktop; on a phone it does
  /// with 锁屏/后台运行 on (main.dart).
  static bool get supportsBackgroundAi => isDesktop;

  /// 听书: on Windows with the AI voice; on a phone with the AI voice where
  /// it is installed and the phone's own voice where not, so on every phone.
  /// Elsewhere every entry stays hidden.
  static bool get hasReadAloud =>
      defaultTargetPlatform == TargetPlatform.windows ||
      isMobile;

  /// The AI voice (Qwen3-TTS): a downloaded engine on Windows, one shipped in
  /// the app on Android and iOS (there from the same 16.4 the AI engine
  /// needs).
  static bool get hasAiVoice =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.android ||
      (defaultTargetPlatform == TargetPlatform.iOS && iosEngineAvailable);

  /// The 听书 engine ships inside the app, so only the voice is a download.
  static bool get hasBundledTtsEngine => isMobile;

  /// AI 封面 and 章间立绘: a downloaded engine on desktop, one shipped in the
  /// app on Android and iOS (there from the same 16.4 the AI engine needs).
  static bool get hasImageGen =>
      isDesktop ||
      defaultTargetPlatform == TargetPlatform.android ||
      (defaultTargetPlatform == TargetPlatform.iOS && iosEngineAvailable);

  /// The picture engine ships inside the app, so only the model is a
  /// download.
  static bool get hasBundledImageEngine => isMobile;

  /// Phone 听书 plays chapters spoken ahead into files (tts_chapters.dart)
  /// and nothing else: listening is mostly with the screen locked, and a
  /// phone cannot speak as fast as it plays. With no AI voice installed the
  /// phone's own voice reads instead.
  static bool get speaksByChapter => isMobile;

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
