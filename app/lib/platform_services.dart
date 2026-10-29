import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_support.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/tts.dart' as native_tts;

/// Directories owned by the application. Feature code asks for a named child
/// instead of deciding where Android, iOS or Windows should write files.
class AppStoragePaths {
  const AppStoragePaths({required this.support, required this.temporary});

  final Directory support;
  final Directory temporary;

  static Future<AppStoragePaths> discover() async => AppStoragePaths(
    support: await getApplicationSupportDirectory(),
    temporary: await getTemporaryDirectory(),
  );

  Directory supportChild(String name) =>
      Directory('${support.path}${Platform.pathSeparator}$name');

  Directory temporaryChild(String name) =>
      Directory('${temporary.path}${Platform.pathSeparator}$name');
}

/// The file chooser is deliberately the only place that knows file_picker.
/// Mobile uses the system document picker and therefore needs no broad storage
/// permission; returned files are local copies that the importer can retain.
class AppFileAccess {
  const AppFileAccess();

  Future<List<String>> pickBooks() async {
    final picked = await _pick(
      title: '导入 TXT 小说',
      type: FileType.custom,
      extensions: const ['txt'],
      multiple: true,
    );
    if (!AppPlatformSupport.isMobile) return picked;
    // A phone hands over a copy in the temporary folder, which the system may
    // empty at any time: the shelf keeps its own.
    final books = (await AppStoragePaths.discover()).supportChild('books');
    await books.create(recursive: true);
    final kept = <String>[];
    for (final p in picked) {
      final source = File(p);
      final name = p.split(Platform.pathSeparator).last;
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      final length = await source.length();
      var target = File('${books.path}${Platform.pathSeparator}$name');
      // The same file picked again is the same book; another file by the same
      // name gets a name of its own.
      for (var n = 2; await target.exists(); n++) {
        if (await target.length() == length) break;
        target = File('${books.path}${Platform.pathSeparator}$stem ($n)$ext');
      }
      await source.copy(target.path);
      kept.add(target.path);
    }
    return kept;
  }

  Future<String?> pickCoverImage() async {
    final paths = await _pick(title: '选择封面图片', type: FileType.image);
    return paths.firstOrNull;
  }

  Future<String?> pickFont() async {
    final paths = await _pick(
      title: '导入字体',
      type: FileType.custom,
      extensions: const ['ttf', 'otf'],
    );
    return paths.firstOrNull;
  }

  Future<String?> pickSourceFile() async {
    final paths = await _pick(
      title: '导入书源 JSON',
      type: FileType.custom,
      extensions: const ['json', 'txt'],
    );
    return paths.firstOrNull;
  }

  Future<List<String>> _pick({
    required String title,
    required FileType type,
    List<String>? extensions,
    bool multiple = false,
  }) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: title,
      type: type,
      allowedExtensions: extensions,
      allowMultiple: multiple,
      withData: false,
    );
    if (result == null) return const [];
    return result.files.map((file) => file.path).whereType<String>().toList();
  }
}

/// What iOS counts against the app when it decides to end it, in MB: now, the
/// most since launch, and the most it would allow. Read from the app's own
/// accounting (AppDelegate.swift); null on other platforms.
class AppMemory {
  const AppMemory(this.now, this.peak, this.limit);

  final int now;
  final int peak;
  final int limit;

  static Future<AppMemory?> read() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final m = await const MethodChannel(
        'novel/memory',
      ).invokeMapMethod<String, int>('read');
      final now = m?['now'];
      if (now == null) return null;
      int mb(int bytes) => bytes ~/ (1 << 20);
      return AppMemory(
        mb(now),
        mb(m!['peak'] ?? now),
        mb(now + (m['left'] ?? 0)),
      );
    } catch (_) {
      return null;
    }
  }
}

/// What the phone is doing right now (AppDelegate.swift, Native.kt): the
/// CPU's busy share across all cores, and, where the phone shows them to an
/// app, the GPU's and the battery's temperature (Android shows only the
/// battery's). Null on other platforms.
class DeviceLoad {
  const DeviceLoad({this.cpu, this.gpu, this.batteryCelsius});

  final int? cpu;
  final int? gpu;
  final double? batteryCelsius;

  static Future<DeviceLoad?> read() async {
    if (!AppPlatformSupport.isMobile) return null;
    try {
      final m = await const MethodChannel(
        'novel/device',
      ).invokeMapMethod<String, int>('load');
      if (m == null) return null;
      final tenths = m['batteryTenths'];
      return DeviceLoad(
        cpu: m['cpu'],
        gpu: m['gpu'],
        batteryCelsius: tenths == null ? null : tenths / 10,
      );
    } catch (_) {
      return null;
    }
  }
}

abstract interface class DeviceStatusReader {
  Future<AiDeviceState> read();
}

/// The Rust bridge supplies Windows facts; on a phone the app adds the phone's
/// own heat, power and memory, without which the queue cannot cool down or
/// wait for a charger.
class NativeDeviceStatusReader implements DeviceStatusReader {
  const NativeDeviceStatusReader();

  @override
  Future<AiDeviceState> read() async {
    final base = await aiDeviceState();
    if (!AppPlatformSupport.isMobile) return base;
    try {
      final d = await const MethodChannel(
        'novel/device',
      ).invokeMapMethod<String, Object>('read');
      if (d == null) return base;
      final memory = d['memoryMb'] as int?;
      return AiDeviceState(
        platform: base.platform,
        charging: d['charging'] as bool? ?? base.charging,
        batteryPercent: d['battery'] as int? ?? base.batteryPercent,
        idleSeconds: base.idleSeconds,
        logicalCores: base.logicalCores,
        totalMemoryMb: memory == null ? base.totalMemoryMb : BigInt.from(memory),
        thermalState: d['thermal'] as String? ?? base.thermalState,
      );
    } catch (_) {
      return base;
    }
  }
}

abstract interface class LocalSpeechSynthesizer {
  Future<bool> ready();

  Future<Uint8List> synthesize({required String text, required String voice});

  /// Speak a sentence into the cache for later; false when it already was.
  Future<bool> prepare({required String text, required String voice});

  Future<int> cacheBytes();

  Future<void> clearCache();
}

/// Keeps the bundled voice behind the same boundary as future iOS/Android
/// speech adapters. Playback and chapter-following remain shared code.
class NativeLocalSpeechSynthesizer implements LocalSpeechSynthesizer {
  const NativeLocalSpeechSynthesizer();

  @override
  Future<bool> ready() => native_tts.ttsReady();

  @override
  Future<Uint8List> synthesize({required String text, required String voice}) =>
      native_tts.synth(text: text, voice: voice);

  @override
  Future<bool> prepare({required String text, required String voice}) =>
      native_tts.prepare(text: text, voice: voice);

  @override
  Future<int> cacheBytes() => native_tts.ttsCacheBytes();

  @override
  Future<void> clearCache() => native_tts.clearTtsCache();
}

/// Shared lifecycle policy. Until a native background scheduler is connected,
/// mobile inference is foreground-only; Windows keeps its existing behaviour.
class AppExecutionPolicy {
  const AppExecutionPolicy({required this.mobile});

  final bool mobile;

  factory AppExecutionPolicy.current() =>
      AppExecutionPolicy(mobile: AppPlatformSupport.isMobile);

  bool aiAllowedIn(AppLifecycleState state) =>
      !mobile || state == AppLifecycleState.resumed;
}

class AppServices {
  AppServices._({required this.storage})
    : files = const AppFileAccess(),
      deviceStatus = const NativeDeviceStatusReader(),
      localSpeech = const NativeLocalSpeechSynthesizer();

  final AppStoragePaths storage;
  final AppFileAccess files;
  final DeviceStatusReader deviceStatus;
  final LocalSpeechSynthesizer localSpeech;

  static AppServices? _instance;

  static AppServices get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('AppServices.initialize must run before use');
    }
    return value;
  }

  static Future<AppServices> initialize() async {
    final existing = _instance;
    if (existing != null) return existing;
    final created = AppServices._(storage: await AppStoragePaths.discover());
    _instance = created;
    return created;
  }
}
