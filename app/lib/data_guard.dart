import 'dart:io';

/// Copies the reader's irreplaceable state aside the first time a new build
/// starts, before that build's code opens or migrates anything.
///
/// Rebuilding never touches this data — it lives in the platform's app-data
/// folder, not next to the executable — but a new build runs new code against
/// it, and a faulty migration or delete would be written straight into the only
/// copy. The snapshot is the way back: close the app and copy the files in the
/// newest `backups/<time>/` folder over the ones in the data folder (removing
/// any `library.db-shm` / `library.db-wal` left there).
///
/// Only the database and preferences are copied. Books, fonts and models are
/// files the reader chose or downloaded; no migration rewrites them.
abstract final class DataGuard {
  /// Snapshots kept; the oldest beyond this are removed.
  static const keep = 3;

  static const _files = [
    'library.db',
    'library.db-wal',
    'shared_preferences.json',
  ];

  /// Returns the snapshot folder when one was taken. Never throws: failing to
  /// back up must not stop the reader from opening.
  static Future<Directory?> snapshotIfNewBuild(
    Directory support, {
    String? build,
    DateTime? now,
  }) async {
    try {
      final stamp = build ?? currentBuild();
      if (stamp == null) return null;
      final backups = Directory(_join(support.path, 'backups'));
      final marker = File(_join(backups.path, 'build.txt'));
      if (await marker.exists() && await marker.readAsString() == stamp) {
        return null;
      }
      final present = <File>[
        for (final name in _files)
          if (await File(_join(support.path, name)).exists())
            File(_join(support.path, name)),
      ];
      // A fresh install has nothing to protect yet.
      if (present.isNotEmpty) {
        final target = Directory(
          _join(backups.path, _folderName(now ?? DateTime.now())),
        );
        try {
          await target.create(recursive: true);
          for (final file in present) {
            await file.copy(_join(target.path, _name(file.path)));
          }
        } catch (_) {
          // A half-written snapshot would look like a good one later.
          await target.delete(recursive: true).catchError((_) => target);
          return null;
        }
        await _prune(backups);
        await marker.writeAsString(stamp);
        return target;
      }
      await backups.create(recursive: true);
      await marker.writeAsString(stamp);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Identifies the running build by the size and time of the files a rebuild
  /// replaces: the runner, the Dart code and the Rust library. Null where they
  /// cannot be found next to the executable (mobile installs).
  static String? currentBuild() {
    final exe = File(Platform.resolvedExecutable);
    final dir = exe.parent.path;
    final parts = <String>[];
    for (final path in [
      exe.path,
      _join(dir, 'rust_lib_novel.dll'),
      _join(dir, _join('data', 'app.so')),
      _join(dir, _join('data', _join('flutter_assets', 'kernel_blob.bin'))),
    ]) {
      final stat = File(path).statSync();
      if (stat.type == FileSystemEntityType.notFound) continue;
      parts.add(
        '${_name(path)}:${stat.size}:${stat.modified.millisecondsSinceEpoch}',
      );
    }
    return parts.length > 1 ? parts.join('|') : null;
  }

  static Future<void> _prune(Directory backups) async {
    final snapshots = await backups
        .list()
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();
    snapshots.sort((a, b) => _name(b.path).compareTo(_name(a.path)));
    for (final old in snapshots.skip(keep)) {
      await old.delete(recursive: true).catchError((_) => old);
    }
  }

  static String _folderName(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

  static String _name(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
}
