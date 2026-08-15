import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'font_manager.dart';
import 'ai_runtime.dart';
import 'reader_page.dart';
import 'reader_state.dart';
import 'reading_session_store.dart';
import 'platform_services.dart';
import 'shelf_categories.dart';
import 'shelf_page.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/tts.dart';
import 'src/rust/frb_generated.dart';
import 'theme.dart';
import 'app_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep the native library name in app-owned code. The code generator derives
  // it by running Cargo metadata; if that tool is unavailable during generation
  // it silently emits "UNKNOWN", leaving the Windows process alive but unable to
  // draw its first frame. An explicit loader is also portable to Android/iOS.
  final nativeLibrary = await loadExternalLibrary(
    const ExternalLibraryLoaderConfig(
      stem: 'rust_lib_novel',
      ioDirectory: 'rust/target/release/',
      webPrefix: 'pkg/',
    ),
  );
  await RustLib.init(externalLibrary: nativeLibrary);
  // Rust must not guess where an app may write; the platform decides.
  final services = await AppServices.initialize();
  final storage = services.storage;
  await initStore(dir: storage.support.path);
  await initAi(dir: storage.supportChild('ai').path);
  await initTts(dir: storage.supportChild('tts').path);
  // Read-aloud used to grind chapters into WAVs here ahead of time. It no longer
  // keeps anything, so reclaim whatever an older build left behind rather than
  // leave gigabytes stranded in a directory nothing will ever open again.
  final oldTtsCache = storage.supportChild('tts_cache');
  if (await oldTtsCache.exists()) {
    await oldTtsCache.delete(recursive: true).catchError((_) => oldTtsCache);
  }
  final settings = await ReadingSettings.load();
  await FontManager.instance.initialize(
    storage.support.path,
    selectedFamily: settings.fontFamily,
  );
  if (!FontManager.instance.hasFamily(settings.fontFamily)) {
    settings.setFontFamily('');
  }
  await ShelfCategories.instance.initialize();
  await AiRuntimeSettings.instance.initialize(
    deviceStatus: services.deviceStatus,
  );
  final readingSessionStore = await ReadingSessionStore.load();
  final reader = ReaderState(
    aiRuntime: AiRuntimeSettings.instance,
    readingSessionStore: readingSessionStore,
  );
  final restoredReading = await reader.restoreReadingSession();
  await reader.initializeAiQueue(readingActive: restoredReading);
  runApp(
    NovelApp(
      settings: settings,
      reader: reader,
      initialReading: restoredReading,
    ),
  );
}

class NovelApp extends StatefulWidget {
  final ReadingSettings settings;
  final ReaderState reader;
  final bool initialReading;

  const NovelApp({
    super.key,
    required this.settings,
    required this.reader,
    this.initialReading = false,
  });

  @override
  State<NovelApp> createState() => _NovelAppState();
}

class _NovelAppState extends State<NovelApp> with WidgetsBindingObserver {
  late final ReaderState reader = widget.reader;
  late final ReadingSettings settings = widget.settings;
  late bool _reading = widget.initialReading;
  final _executionPolicy = AppExecutionPolicy.current();

  void _leaveReader(ShelfItem? _) {
    reader.setReadingActive(false);
    setState(() => _reading = false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reader.setReadingActive(_reading);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The last stretch of reading before the app goes away is the one most likely
  /// to be lost. Write it when the app leaves the foreground, not on exit —
  /// Android and iOS may never give us an exit.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    reader.setAiExecutionAllowed(_executionPolicy.aiAllowedIn(state));
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(reader.endSession());
      reader.setReadingActive(false);
    } else if (state == AppLifecycleState.resumed && _reading) {
      reader.resumeSession();
      reader.setReadingActive(true);
    }
    // The engine is a separate OS process; nobody kills it for us.
    if (state == AppLifecycleState.detached) {
      stopAi();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final t = settings.theme;
        return MaterialApp(
          title: settings.language == AppLanguage.english
              ? 'Novel Reader'
              : '小说阅读器',
          debugShowCheckedModeBanner: false,
          locale: settings.language.locale,
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => AppLanguageScope(
            language: settings.language,
            child: child ?? const SizedBox.shrink(),
          ),
          theme: ThemeData(
            brightness: t.isDark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: t.background,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF7B6A52),
              brightness: t.isDark ? Brightness.dark : Brightness.light,
            ),
          ),
          home: _reading
              ? ReaderPage(
                  reader: reader,
                  settings: settings,
                  onBack: _leaveReader,
                )
              : ShelfPage(
                  reader: reader,
                  settings: settings,
                  onOpened: () {
                    reader.setReadingActive(true);
                    setState(() => _reading = true);
                  },
                ),
        );
      },
    );
  }
}
