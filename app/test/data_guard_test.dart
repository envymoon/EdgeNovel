import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel/data_guard.dart';

void main() {
  late Directory support;
  final sep = Platform.pathSeparator;

  setUp(() => support = Directory.systemTemp.createTempSync('data_guard'));
  tearDown(() => support.deleteSync(recursive: true));

  List<String> snapshots() {
    final dir = Directory('${support.path}${sep}backups');
    if (!dir.existsSync()) return [];
    return dir.listSync().whereType<Directory>().map((d) => d.path).toList()
      ..sort();
  }

  test('a new build copies the library before it runs', () async {
    File('${support.path}${sep}library.db').writeAsStringSync('db');
    File('${support.path}${sep}library.db-wal').writeAsStringSync('wal');
    File(
      '${support.path}${sep}shared_preferences.json',
    ).writeAsStringSync('{}');

    final first = await DataGuard.snapshotIfNewBuild(
      support,
      build: 'a',
      now: DateTime(2026, 10, 9, 12),
    );
    expect(first, isNotNull);
    expect(File('${first!.path}${sep}library.db').readAsStringSync(), 'db');
    expect(File('${first.path}${sep}library.db-wal').readAsStringSync(), 'wal');
    expect(
      File('${first.path}${sep}shared_preferences.json').existsSync(),
      isTrue,
    );

    // Restarting the same build does not copy again.
    expect(
      await DataGuard.snapshotIfNewBuild(
        support,
        build: 'a',
        now: DateTime(2026, 10, 9, 13),
      ),
      isNull,
    );
    expect(snapshots(), hasLength(1));
  });

  test('only the newest snapshots are kept', () async {
    File('${support.path}${sep}library.db').writeAsStringSync('db');
    for (var i = 0; i < DataGuard.keep + 2; i++) {
      await DataGuard.snapshotIfNewBuild(
        support,
        build: 'build $i',
        now: DateTime(2026, 10, 9, 12, i),
      );
    }
    final kept = snapshots();
    expect(kept, hasLength(DataGuard.keep));
    expect(kept.last, endsWith('20261009-120400'));
  });

  test('a fresh install has nothing to copy', () async {
    expect(await DataGuard.snapshotIfNewBuild(support, build: 'a'), isNull);
    expect(snapshots(), isEmpty);
  });
}
