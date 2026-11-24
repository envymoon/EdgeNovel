import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'model_download.dart';

enum ManagedModelRole { chat, embedding }

class ManagedModelPackage {
  const ManagedModelPackage({
    required this.id,
    required this.version,
    required this.displayName,
    required this.role,
    required this.sourceFileName,
    required this.urls,
    required this.sha256,
    required this.minimumBytes,
    this.estimatedLabel = '',
  });

  final String id;
  final String version;
  final String displayName;
  final ManagedModelRole role;
  final String sourceFileName;
  final List<String> urls;
  final String sha256;
  final int minimumBytes;
  final String estimatedLabel;

  String get activeFileName => switch (role) {
    ManagedModelRole.chat => 'novel-chat-current.gguf',
    ManagedModelRole.embedding => 'novel-embed-current.gguf',
  };

  String get rollbackFileName => switch (role) {
    ManagedModelRole.chat => 'novel-chat-previous.gguf.rollback',
    ManagedModelRole.embedding => 'novel-embed-previous.gguf.rollback',
  };

  String get recordFileName => switch (role) {
    ManagedModelRole.chat => '.novel-chat-model.json',
    ManagedModelRole.embedding => '.novel-embed-model.json',
  };

  String get downloadFileName => '$activeFileName.$id.download';
}

const chatModelStandardPackage = ManagedModelPackage(
  id: 'qwen3-0.6b-q8-zh-only',
  version: '2026.11-q8-zh-only',
  displayName: 'Qwen3 0.6B 标准版',
  role: ManagedModelRole.chat,
  sourceFileName: 'Qwen3-0.6B-Q8_0-zh-only.gguf',
  urls: [
    'https://huggingface.co/ianhaimo/Qwen3-0.6B-Q8_0-zh-GGUF/resolve/main/Qwen3-0.6B-Q8_0-zh-only.gguf',
    'https://hf-mirror.com/ianhaimo/Qwen3-0.6B-Q8_0-zh-GGUF/resolve/main/Qwen3-0.6B-Q8_0-zh-only.gguf',
  ],
  sha256: 'f412a1321ab5dd3bff203b004f22dc53127f465b703e2211c44f7416ae0fce99',
  minimumBytes: 450 * 1024 * 1024,
  estimatedLabel: '约 482 MB',
);

const chatModelHighPackage = ManagedModelPackage(
  id: 'qwen3-1.7b-q4km-zh-only',
  version: '2026.11-q4km-zh-only',
  displayName: 'Qwen3 1.7B 高配版',
  role: ManagedModelRole.chat,
  sourceFileName: 'Qwen3-1.7B-Q4_K_M-zh.gguf',
  urls: [
    'https://huggingface.co/ianhaimo/Qwen3-1.7B-Q4_K_M-zh-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M-zh.gguf',
    'https://hf-mirror.com/ianhaimo/Qwen3-1.7B-Q4_K_M-zh-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M-zh.gguf',
  ],
  sha256: 'ecf8f2809324f95054b377d961cb995f2c1b254557665cb9b68e39220270c0f4',
  minimumBytes: 820 * 1024 * 1024,
  estimatedLabel: '约 861 MB',
);

const chatModelPackage = chatModelStandardPackage;
const chatModelPackages = [chatModelStandardPackage, chatModelHighPackage];

const embeddingModelPackage = ManagedModelPackage(
  id: 'bge-small-zh-v1.5-f16',
  version: '1.5-f16',
  displayName: 'BGE small 中文 F16',
  role: ManagedModelRole.embedding,
  sourceFileName: 'bge-small-zh-v1.5-f16.gguf',
  urls: [
    'https://huggingface.co/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/bge-small-zh-v1.5-f16.gguf',
    'https://hf-mirror.com/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/bge-small-zh-v1.5-f16.gguf',
  ],
  sha256: 'ab9b81d9cd329c712eee379cf0068eabe6a5e2a01d0def61535eba9384085e2c',
  minimumBytes: 40 * 1024 * 1024,
  estimatedLabel: '约 48 MB',
);

/// The downloaded file itself is wrong; any other failure leaves it worth
/// keeping, to be installed again without fetching it anew.
class ModelFileInvalid implements Exception {
  const ModelFileInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}

class ManagedModelState {
  const ManagedModelState({
    required this.activeFile,
    required this.activeId,
    required this.activeVersion,
    required this.activeSha256,
    required this.rollbackFile,
    required this.previousId,
    required this.previousVersion,
    required this.previousSha256,
  });

  final File? activeFile;
  final String? activeId;
  final String? activeVersion;
  final String? activeSha256;
  final File? rollbackFile;
  final String? previousId;
  final String? previousVersion;
  final String? previousSha256;

  bool get installed => activeFile != null;
  bool get canRollback => rollbackFile != null;

  bool isVerifiedCurrent(ManagedModelPackage package) =>
      activeId == package.id &&
      activeVersion == package.version &&
      activeSha256 == package.sha256;

  bool isVerifiedRollback(ManagedModelPackage package) =>
      canRollback &&
      previousId == package.id &&
      previousVersion == package.version &&
      previousSha256 == package.sha256;

  ManagedModelPackage? activePackageFrom(List<ManagedModelPackage> packages) {
    for (final package in packages) {
      if (isVerifiedCurrent(package)) return package;
    }
    return null;
  }
}

class ModelManager {
  const ModelManager();

  Future<ManagedModelState> inspect(
    String directory,
    ManagedModelPackage package,
  ) async {
    final dir = Directory(directory);
    final record = await _readRecord(dir, package);
    File? active;
    final recordedName = record?['activeFile'] as String?;
    if (recordedName != null) {
      final candidate = File(_join(dir.path, recordedName));
      if (await candidate.exists()) active = candidate;
    }
    active ??= await _findActive(dir, package.role);

    String? id = record?['activeId'] as String?;
    String? version = record?['activeVersion'] as String?;
    String? activeHash = record?['activeSha256'] as String?;
    if (active != null && record == null) {
      final name = _name(active.path);
      if (name == package.sourceFileName || name == package.activeFileName) {
        id = package.id;
        version = package.version;
      }
    }

    final rollbackCandidate = File(_join(dir.path, package.rollbackFileName));
    final rollback = await rollbackCandidate.exists()
        ? rollbackCandidate
        : null;
    return ManagedModelState(
      activeFile: active,
      activeId: id,
      activeVersion: version,
      activeSha256: activeHash,
      rollbackFile: rollback,
      previousId: record?['previousId'] as String?,
      previousVersion: record?['previousVersion'] as String?,
      previousSha256: record?['previousSha256'] as String?,
    );
  }

  File downloadTarget(String directory, ManagedModelPackage package) =>
      File(_join(directory, package.downloadFileName));

  Future<int> pendingDownloadBytes(
    String directory,
    ManagedModelPackage package,
  ) => ResumableFileDownload.pendingBytes(downloadTarget(directory, package));

  Future<void> discardPendingDownload(
    String directory,
    ManagedModelPackage package,
  ) => ResumableFileDownload.discard(downloadTarget(directory, package));

  Future<void> installDownloaded({
    required String directory,
    required ManagedModelPackage package,
    required File download,
    required Future<void> Function() stopEngine,
  }) async {
    await _verify(download, package);
    final dir = Directory(directory);
    await dir.create(recursive: true);
    final before = await inspect(directory, package);
    await stopEngine();

    final activeTarget = File(_join(directory, package.activeFileName));
    final rollbackTarget = File(_join(directory, package.rollbackFileName));
    final previousActive = before.activeFile;
    String? previousOriginalPath;
    var installedNew = false;
    try {
      if (await rollbackTarget.exists()) await rollbackTarget.delete();
      if (previousActive != null && await previousActive.exists()) {
        previousOriginalPath = previousActive.path;
        await previousActive.rename(rollbackTarget.path);
      }
      if (await activeTarget.exists()) await activeTarget.delete();
      await download.rename(activeTarget.path);
      installedNew = true;
      await _writeRecord(dir, package, {
        'activeId': package.id,
        'activeVersion': package.version,
        'activeSha256': package.sha256,
        'activeFile': package.activeFileName,
        'previousId': before.activeId,
        'previousVersion': before.activeVersion,
        'previousSha256': before.activeSha256,
        'previousFile': previousOriginalPath == null
            ? null
            : package.rollbackFileName,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      if (installedNew && await activeTarget.exists()) {
        await activeTarget.delete();
      }
      if (previousOriginalPath != null && await rollbackTarget.exists()) {
        await rollbackTarget.rename(previousOriginalPath);
      }
      rethrow;
    }
  }

  Future<void> rollback({
    required String directory,
    required ManagedModelPackage package,
    required Future<void> Function() stopEngine,
  }) async {
    final state = await inspect(directory, package);
    final active = state.activeFile;
    final previous = state.rollbackFile;
    if (active == null || previous == null) throw '没有可恢复的旧版本';
    await stopEngine();

    final swap = File('${active.path}.swap');
    if (await swap.exists()) await swap.delete();
    try {
      await active.rename(swap.path);
      await previous.rename(active.path);
      await swap.rename(previous.path);
    } catch (_) {
      if (!await active.exists() && await previous.exists()) {
        await previous.rename(active.path);
      }
      if (await swap.exists() && !await previous.exists()) {
        await swap.rename(previous.path);
      }
      rethrow;
    }

    final dir = Directory(directory);
    await _writeRecord(dir, package, {
      'activeId': state.previousId,
      'activeVersion': state.previousVersion,
      'activeSha256': state.previousSha256,
      'activeFile': _name(active.path),
      'previousId': state.activeId,
      'previousVersion': state.activeVersion,
      'previousSha256': state.activeSha256,
      'previousFile': _name(previous.path),
      'installedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> deleteInstalled({
    required String directory,
    required ManagedModelPackage package,
    required Future<void> Function() stopEngine,
  }) async {
    final state = await inspect(directory, package);
    await stopEngine();
    if (state.activeFile case final active?) {
      if (await active.exists()) await active.delete();
    }
    if (state.rollbackFile case final previous?) {
      if (await previous.exists()) await previous.delete();
    }
    final record = File(_join(directory, package.recordFileName));
    if (await record.exists()) await record.delete();
    final download = downloadTarget(directory, package);
    await ResumableFileDownload.discard(download);
  }

  /// Removes only [package]. When another model occupies the opposite slot
  /// (active vs rollback), keeps that other model intact (promoting it to
  /// active if [package] was the active one).
  Future<void> deletePackage({
    required String directory,
    required ManagedModelPackage package,
    required Future<void> Function() stopEngine,
  }) async {
    final state = await inspect(directory, package);
    final dir = Directory(directory);
    final download = downloadTarget(directory, package);

    if (state.isVerifiedRollback(package)) {
      if (state.rollbackFile case final previous?) {
        if (await previous.exists()) await previous.delete();
      }
      await _writeRecord(dir, package, {
        'activeId': state.activeId,
        'activeVersion': state.activeVersion,
        'activeSha256': state.activeSha256,
        'activeFile': state.activeFile == null
            ? null
            : _name(state.activeFile!.path),
        'previousId': null,
        'previousVersion': null,
        'previousSha256': null,
        'previousFile': null,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await ResumableFileDownload.discard(download);
      return;
    }

    if (state.isVerifiedCurrent(package) && state.rollbackFile != null) {
      await stopEngine();
      final activeTarget = File(_join(directory, package.activeFileName));
      if (state.activeFile case final active?) {
        if (await active.exists()) await active.delete();
      }
      if (await activeTarget.exists()) await activeTarget.delete();
      await state.rollbackFile!.rename(activeTarget.path);
      await _writeRecord(dir, package, {
        'activeId': state.previousId,
        'activeVersion': state.previousVersion,
        'activeSha256': state.previousSha256,
        'activeFile': package.activeFileName,
        'previousId': null,
        'previousVersion': null,
        'previousSha256': null,
        'previousFile': null,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await ResumableFileDownload.discard(download);
      return;
    }

    await deleteInstalled(
      directory: directory,
      package: package,
      stopEngine: stopEngine,
    );
  }

  Future<void> _verify(File file, ManagedModelPackage package) async {
    if (!await file.exists()) throw '下载文件不存在';
    final length = await file.length();
    if (length < package.minimumBytes) {
      throw const ModelFileInvalid('文件大小异常，可能下载不完整');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString().toLowerCase() != package.sha256.toLowerCase()) {
      throw const ModelFileInvalid('文件校验失败，已保留当前模型');
    }
  }

  Future<File?> _findActive(Directory directory, ManagedModelRole role) async {
    if (!await directory.exists()) return null;
    final files = await directory
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is File && entry.path.toLowerCase().endsWith('.gguf'),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final lower = _name(file.path).toLowerCase();
      final embedding = ['bge', 'embed', 'gte', 'e5-'].any(lower.contains);
      if (embedding == (role == ManagedModelRole.embedding)) return file;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _readRecord(
    Directory directory,
    ManagedModelPackage package,
  ) async {
    final file = File(_join(directory.path, package.recordFileName));
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRecord(
    Directory directory,
    ManagedModelPackage package,
    Map<String, Object?> value,
  ) async {
    final file = File(_join(directory.path, package.recordFileName));
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  static String _join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  static String _name(String path) => path.split(RegExp(r'[/\\]')).last;
}
