import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'ai_runtime_page.dart';
import 'background_task_bar.dart';
import 'data_guard.dart';
import 'font_manager.dart';
import 'keep_alive.dart';
import 'ai_runtime.dart';
import 'reader_page.dart';
import 'reader_state.dart';
import 'reading_session_store.dart';
import 'platform_services.dart';
import 'platform_support.dart';
import 'shelf_categories.dart';
import 'shelf_page.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/image.dart';
import 'src/rust/api/tts.dart';
import 'src/rust/frb_generated.dart';
import 'theme.dart';
import 'tts_prepare.dart';
import 'tts_chapters_page.dart';
import 'tts_server_page.dart';
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
  // Before this build's code opens anything: if it is a new build, keep a copy
  // of the library it is about to run against.
  await DataGuard.snapshotIfNewBuild(storage.support);
  await initStore(dir: storage.support.path);
  await initAi(dir: storage.supportChild('ai').path);
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    AppPlatformSupport.iosEngineAvailable = (await aiStatus()).engine;
  }
  await initTts(dir: storage.supportChild('tts').path);
  await initImage(dir: storage.supportChild('image').path);
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
  if (windowsAppearance &&
      settings.interfaceFontFamily.isNotEmpty &&
      !settings.interfaceFontFamily.startsWith('system:')) {
    final pack = FontManager.instance.packs
        .where((p) => p.family == settings.interfaceFontFamily)
        .firstOrNull;
    try {
      if (pack == null || !FontManager.instance.isInstalled(pack)) {
        settings.setInterfaceFontFamily('');
      } else {
        await FontManager.instance.ensureLoaded(pack);
      }
    } catch (_) {
      settings.setInterfaceFontFamily('');
    }
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
  final _navigator = GlobalKey<NavigatorState>();
  bool _runtimeOpen = false;

  Future<void> _openBackgroundSettings() async {
    final nav = _navigator.currentState;
    if (nav == null || _runtimeOpen) return;
    _runtimeOpen = true;
    await nav.push(
      MaterialPageRoute(
        builder: (_) => AiRuntimePage(settings: settings, reader: reader),
      ),
    );
    _runtimeOpen = false;
  }

  Future<void> _openSpeechSettings() async {
    final nav = _navigator.currentState;
    if (nav == null || _runtimeOpen) return;
    _runtimeOpen = true;
    await nav.push(
      MaterialPageRoute(
        builder: (_) => AppPlatformSupport.speaksByChapter
            ? TtsChaptersPage(settings: settings)
            : TtsServerPage(settings: settings),
      ),
    );
    _runtimeOpen = false;
  }

  /// Every screen but the reader's page gets the background-work bar on top.
  /// The tree keeps the same shape whether the bar shows or not, so the
  /// navigator below it is never rebuilt and no screen loses its place.
  Widget _withTaskBar(Widget child) => ListenableBuilder(
    listenable: Listenable.merge([reader, TtsPrepare.instance]),
    builder: (context, _) {
      final shown = !_reading && BackgroundTaskBar.shows(reader);
      return Column(
        children: [
          if (shown)
            BackgroundTaskBar(
              reader: reader,
              settings: settings,
              onOpen: _openBackgroundSettings,
              onOpenSpeech: _openSpeechSettings,
            )
          else
            const SizedBox.shrink(),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: shown,
              child: child,
            ),
          ),
        ],
      );
    },
  );

  void _leaveReader(ShelfItem? _) {
    reader.setReadingActive(false);
    setState(() => _reading = false);
    // Closed for another book's chapter tapped in 已合成.
    unawaited(_openSpoken());
  }

  /// A chapter tapped in 已合成 with no book open, or another one: its book
  /// opens, and the reader page goes to the chapter and opens 听书 there.
  Future<void> _openSpoken() async {
    final want = spokenChapterWanted.value;
    if (want == null || _reading) return;
    final book = reader.shelf.where((b) => b.id == want.$1).firstOrNull;
    if (book == null) {
      spokenChapterWanted.value = null;
      return;
    }
    _navigator.currentState?.popUntil((route) => route.isFirst);
    await reader.open(book.path);
    if (!mounted || !reader.isOpen) {
      spokenChapterWanted.value = null;
      return;
    }
    reader.setReadingActive(true);
    setState(() => _reading = true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reader.setReadingActive(_reading);
    spokenChapterWanted.addListener(_openSpoken);
    if (_backgroundWindows) {
      _background.setMethodCallHandler(_onBackground);
      reader.addListener(_aliveChanged);
      AiRuntimeSettings.instance.addListener(_aliveChanged);
      _aliveChanged();
    }
  }

  // ── 锁屏/后台运行 ─────────────────────────────────────────────────────────
  // iOS gives the GPU only to the app on screen. With the switch on, the
  // queue keeps the app running while it has work ([SilentKeepAlive]), and
  // the moment the app is off screen — locked, or another app in front — it
  // goes on on the CPU, and back on the GPU when the app is.
  //
  // Where the app was not kept running, iOS still lends it a stretch of CPU
  // when it sees fit (a BGProcessingTask, AppDelegate.swift). The queue runs
  // in it the same way and hands the window back when it is done, when it is
  // waiting on something a window cannot fix, or when the system wants it
  // back.
  static const _background = MethodChannel('novel/background');
  static bool get _backgroundWindows =>
      defaultTargetPlatform == TargetPlatform.iOS;
  bool _inWindow = false;
  Timer? _windowWatch;
  final _alive = SilentKeepAlive(mix: true);
  AppLifecycleState _life =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  void _aliveChanged() {
    final want =
        AiRuntimeSettings.instance.lockedEnabled &&
        AppPlatformSupport.hasAiEngine &&
        (reader.aiRunnable || reader.aiActive);
    // It can start only on screen; behind it, it can only stop.
    if (want && _life != AppLifecycleState.resumed) return;
    unawaited(
      _alive.set(want).then((changed) {
        if (changed) return _offScreenChanged();
      }),
    );
  }

  /// On screen: the GPU. Off it: the CPU while the app is kept running or in
  /// a lent window, and nothing otherwise.
  Future<void> _offScreenChanged() async {
    final behind = _life != AppLifecycleState.resumed;
    final going = behind && (_alive.on || _inWindow);
    if (_backgroundWindows) {
      await AiRuntimeSettings.instance.setCpuOnly(going);
    }
    reader.setAiExecutionAllowed(
      _executionPolicy.aiAllowedIn(_life) || going,
    );
  }

  Future<dynamic> _onBackground(MethodCall call) async {
    switch (call.method) {
      case 'run':
        await _enterWindow();
      case 'expire':
        await _leaveWindow(more: true, tell: false);
    }
  }

  Future<void> _enterWindow() async {
    final runtime = AiRuntimeSettings.instance;
    if (!runtime.lockedEnabled || !reader.aiRunnable) {
      await _background.invokeMethod('done', {'more': false});
      return;
    }
    _inWindow = true;
    await _offScreenChanged();
    _windowWatch?.cancel();
    _windowWatch = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_inWindow && !reader.aiActive) {
        unawaited(_leaveWindow(more: reader.aiRunnable));
      }
    });
  }

  Future<void> _leaveWindow({required bool more, bool tell = true}) async {
    if (!_inWindow) return;
    _inWindow = false;
    _windowWatch?.cancel();
    await _offScreenChanged();
    if (tell) await _background.invokeMethod('done', {'more': more});
  }

  @override
  void dispose() {
    spokenChapterWanted.removeListener(_openSpoken);
    reader.removeListener(_aliveChanged);
    AiRuntimeSettings.instance.removeListener(_aliveChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The last stretch of reading before the app goes away is the one most likely
  /// to be lost. Write it when the app leaves the foreground, not on exit —
  /// Android and iOS may never give us an exit.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _life = state;
    if (_inWindow && state == AppLifecycleState.resumed) {
      // Back on screen mid-window: off the CPU, back onto the GPU.
      unawaited(_leaveWindow(more: false));
    } else {
      unawaited(_offScreenChanged());
    }
    if (_backgroundWindows) _aliveChanged();
    if (_backgroundWindows &&
        state == AppLifecycleState.paused &&
        AiRuntimeSettings.instance.lockedEnabled &&
        AppPlatformSupport.hasAiEngine &&
        reader.aiRunnable) {
      unawaited(_background.invokeMethod('schedule'));
    }
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
        return MaterialApp(
          title: settings.language == AppLanguage.english ? 'Zhiyue' : '挚阅',
          debugShowCheckedModeBanner: false,
          locale: settings.language.locale,
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          navigatorKey: _navigator,
          builder: (context, child) => AppLanguageScope(
            language: settings.language,
            child: _withTaskBar(child ?? const SizedBox.shrink()),
          ),
          theme: buildAppTheme(settings),
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
