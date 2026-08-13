import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_support.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/tts.dart' as native_tts;
import 'tts_text.dart';

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

  Future<List<String>> pickBooks() => _pick(
    title: '导入 TXT 小说',
    type: FileType.custom,
    extensions: const ['txt'],
    multiple: true,
  );

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

abstract interface class DeviceStatusReader {
  Future<AiDeviceState> read();
}

/// The current native bridge supplies Windows facts. Android and iOS adapters
/// can later implement the same contract without changing queue policy.
class NativeDeviceStatusReader implements DeviceStatusReader {
  const NativeDeviceStatusReader();

  @override
  Future<AiDeviceState> read() => aiDeviceState();
}

abstract interface class LocalSpeechSynthesizer {
  Future<bool> ready();

  Future<Uint8List> synthesize({
    required String text,
    required double speed,
    required int voice,
  });
}

/// Keeps the bundled voice behind the same boundary as future iOS/Android
/// speech adapters. Playback and chapter-following remain shared code.
class NativeLocalSpeechSynthesizer implements LocalSpeechSynthesizer {
  const NativeLocalSpeechSynthesizer();

  @override
  Future<bool> ready() => native_tts.ttsReady();

  @override
  Future<Uint8List> synthesize({
    required String text,
    required double speed,
    required int voice,
  }) => native_tts.synth(
    text: text,
    lengthScale: ttsLengthScale(speed),
    voice: 'kokoro-$voice',
  );
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
