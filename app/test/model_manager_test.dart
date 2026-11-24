import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/model_manager.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-model-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'verified install keeps the old model and rollback swaps both',
    () async {
      const oldBytes = 'old-model';
      const newBytes = 'new-model';
      final package = _packageFor(newBytes);
      final old = File('${directory.path}${Platform.pathSeparator}legacy.gguf');
      await old.writeAsString(oldBytes);
      final download = File(
        '${directory.path}${Platform.pathSeparator}${package.downloadFileName}',
      );
      await download.writeAsString(newBytes);
      var stopped = 0;

      const manager = ModelManager();
      await manager.installDownloaded(
        directory: directory.path,
        package: package,
        download: download,
        stopEngine: () async {
          stopped++;
        },
      );

      var state = await manager.inspect(directory.path, package);
      expect(await state.activeFile!.readAsString(), newBytes);
      expect(await state.rollbackFile!.readAsString(), oldBytes);
      expect(state.isVerifiedCurrent(package), isTrue);
      expect(stopped, 1);

      await manager.rollback(
        directory: directory.path,
        package: package,
        stopEngine: () async {
          stopped++;
        },
      );
      state = await manager.inspect(directory.path, package);
      expect(await state.activeFile!.readAsString(), oldBytes);
      expect(await state.rollbackFile!.readAsString(), newBytes);
      expect(stopped, 2);
    },
  );

  test('bad checksum never replaces the current model', () async {
    const manager = ModelManager();
    final package = _packageFor('expected');
    final active = File(
      '${directory.path}${Platform.pathSeparator}${package.activeFileName}',
    );
    await active.writeAsString('current');
    final download = File(
      '${directory.path}${Platform.pathSeparator}${package.downloadFileName}',
    );
    await download.writeAsString('corrupt');
    var stopped = false;

    await expectLater(
      manager.installDownloaded(
        directory: directory.path,
        package: package,
        download: download,
        stopEngine: () async {
          stopped = true;
        },
      ),
      throwsA(isA<ModelFileInvalid>()),
    );
    expect(await active.readAsString(), 'current');
    expect(stopped, isFalse);
  });

  test('a good file that fails to switch in is not called invalid', () async {
    const manager = ModelManager();
    final package = _packageFor('good');
    final download = File(
      '${directory.path}${Platform.pathSeparator}${package.downloadFileName}',
    );
    await download.writeAsString('good');

    await expectLater(
      manager.installDownloaded(
        directory: directory.path,
        package: package,
        download: download,
        stopEngine: () async => throw '引擎还在忙',
      ),
      throwsA(isNot(isA<ModelFileInvalid>())),
    );
    expect(await download.readAsString(), 'good');
  });

  test(
    'chat tiers have distinct download targets and switch via rollback',
    () async {
      expect(
        chatModelStandardPackage.downloadFileName,
        isNot(chatModelHighPackage.downloadFileName),
      );
      const standardBytes = 'standard-0.6b';
      const highBytes = 'high-1.7b';
      final standard = _packageFor(standardBytes, id: 'tier-std', version: '1');
      final high = _packageFor(highBytes, id: 'tier-high', version: '1');

      const manager = ModelManager();
      final stdDl = File(
        '${directory.path}${Platform.pathSeparator}${standard.downloadFileName}',
      );
      await stdDl.writeAsString(standardBytes);
      await manager.installDownloaded(
        directory: directory.path,
        package: standard,
        download: stdDl,
        stopEngine: () async {},
      );

      final highDl = File(
        '${directory.path}${Platform.pathSeparator}${high.downloadFileName}',
      );
      await highDl.writeAsString(highBytes);
      await manager.installDownloaded(
        directory: directory.path,
        package: high,
        download: highDl,
        stopEngine: () async {},
      );

      var state = await manager.inspect(directory.path, high);
      expect(state.isVerifiedCurrent(high), isTrue);
      expect(state.isVerifiedRollback(standard), isTrue);
      expect(state.activePackageFrom([standard, high]), high);

      await manager.rollback(
        directory: directory.path,
        package: standard,
        stopEngine: () async {},
      );
      state = await manager.inspect(directory.path, standard);
      expect(state.isVerifiedCurrent(standard), isTrue);
      expect(state.isVerifiedRollback(high), isTrue);
      expect(state.activePackageFrom([standard, high]), standard);

      // Deleting the active tier promotes the remaining downloaded tier.
      await manager.deletePackage(
        directory: directory.path,
        package: standard,
        stopEngine: () async {},
      );
      state = await manager.inspect(directory.path, high);
      expect(state.isVerifiedCurrent(high), isTrue);
      expect(state.canRollback, isFalse);
      expect(await state.activeFile!.readAsString(), highBytes);
    },
  );
}

ManagedModelPackage _packageFor(
  String content, {
  String id = 'test-chat',
  String version = '2',
}) => ManagedModelPackage(
  id: id,
  version: version,
  displayName: 'Test',
  role: ManagedModelRole.chat,
  sourceFileName: 'test.gguf',
  urls: const ['https://example.invalid/test.gguf'],
  sha256: sha256.convert(utf8.encode(content)).toString(),
  minimumBytes: 1,
);
