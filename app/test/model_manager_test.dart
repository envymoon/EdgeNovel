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
      throwsA(anything),
    );
    expect(await active.readAsString(), 'current');
    expect(stopped, isFalse);
  });
}

ManagedModelPackage _packageFor(String content) => ManagedModelPackage(
  id: 'test-chat',
  version: '2',
  displayName: 'Test',
  role: ManagedModelRole.chat,
  sourceFileName: 'test.gguf',
  urls: const ['https://example.invalid/test.gguf'],
  sha256: sha256.convert(utf8.encode(content)).toString(),
  minimumBytes: 1,
);
