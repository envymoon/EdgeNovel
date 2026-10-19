import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'platform_services.dart';
import 'platform_support.dart';
import 'theme.dart';

/// 「1.2 GB」「35 MB」「0.4 MB」.
String formatStorageBytes(int bytes) {
  final mb = bytes / (1 << 20);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// One kind of thing the app keeps, and where.
class StorageKind {
  const StorageKind(this.label, this.paths);

  final String label;

  /// Under the app's support folder.
  final List<String> paths;
}

/// What the app keeps, by kind. What is in none of them counts as 其他.
const storageKinds = <StorageKind>[
  StorageKind('书籍', ['books']),
  StorageKind('书架与阅读数据', ['library.db', 'library.db-wal', 'library.db-shm']),
  StorageKind('字体', ['fonts']),
  StorageKind('AI 模型与数据', ['ai']),
  StorageKind('语音模型', ['tts']),
  StorageKind('生图模型', ['image']),
  StorageKind('已合成听书', ['tts_chapters']),
  StorageKind('封面', ['covers']),
  StorageKind('备份', ['backups']),
];

/// What can go and be made again when needed, under the support folder:
/// sentences spoken as the voice went, the 听书 experiments' output. The
/// temporary folder's are too ([_temporary]).
const cachePaths = ['tts/cache', 'tts/experiment'];

/// The bytes under [path], a file or a folder.
Future<int> storageBytes(String path) async {
  try {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) return await File(path).length();
    if (type != FileSystemEntityType.directory) return 0;
    var n = 0;
    await for (final f in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (f is File) {
        try {
          n += await f.length();
        } catch (_) {}
      }
    }
    return n;
  } catch (_) {
    return 0;
  }
}

/// 存储空间: what the app keeps on this device, by kind, and the caches that
/// can go.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.settings});

  final ReadingSettings settings;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  List<(String, int)>? _rows;
  int _cache = 0;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _at(String root, String path) =>
      '$root${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}';

  /// The temporary folders that are the app's: a phone gives it one of its
  /// own, a computer shares one with every program, of which only the
  /// app's folders are its.
  List<Directory> get _temporary {
    final storage = AppServices.instance.storage;
    if (AppPlatformSupport.isMobile) return [storage.temporary];
    return [
      for (final name in ['tts_play', 'tts_keep']) storage.temporaryChild(name),
    ];
  }

  /// The files under [d], the folders staying for what writes into them.
  Future<void> _clearFiles(Directory d) async {
    try {
      if (!await d.exists()) return;
      await for (final f in d.list(recursive: true, followLinks: false)) {
        if (f is! File) continue;
        // A file in use stays, and goes next time.
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    final storage = AppServices.instance.storage;
    final root = storage.support.path;
    var cache = 0;
    for (final d in _temporary) {
      cache += await storageBytes(d.path);
    }
    for (final p in cachePaths) {
      cache += await storageBytes(_at(root, p));
    }
    final rows = <(String, int)>[];
    var counted = 0;
    for (final kind in storageKinds) {
      var n = 0;
      for (final p in kind.paths) {
        n += await storageBytes(_at(root, p));
      }
      counted += n;
      // The caches inside the voice's folder are counted as caches.
      if (kind.paths.contains('tts')) {
        for (final p in cachePaths) {
          n -= await storageBytes(_at(root, p));
        }
      }
      if (n > 0) rows.add((kind.label, n));
    }
    final rest = await storageBytes(root) - counted;
    if (rest > 0) rows.add(('其他', rest));
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _cache = cache;
    });
  }

  Future<void> _clear() async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text('清理缓存？', style: TextStyle(color: t.text, fontSize: 16)),
        content: Text(
          '书、进度、标注、模型和已合成的听书不受影响。',
          style: TextStyle(color: t.muted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    final storage = AppServices.instance.storage;
    try {
      await AppServices.instance.localSpeech.clearCache();
    } catch (_) {}
    for (final p in cachePaths) {
      await _clearFiles(Directory(_at(storage.support.path, p)));
    }
    for (final d in _temporary) {
      await _clearFiles(d);
    }
    await _load();
    if (mounted) setState(() => _clearing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final rows = _rows;
    final label = TextStyle(color: t.text, fontSize: 14);
    final value = TextStyle(color: t.muted, fontSize: 13);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('存储空间', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: rows == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                Material(
                  clipBehavior: Clip.antiAlias,
                  color: t.surface,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: t.outline),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      for (final (name, bytes) in rows)
                        ListTile(
                          title: Text(name, style: label),
                          trailing: Text(
                            formatStorageBytes(bytes),
                            translate: false,
                            style: value,
                          ),
                        ),
                      ListTile(
                        title: Text('缓存', style: label),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formatStorageBytes(_cache),
                              translate: false,
                              style: value,
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _clearing || _cache == 0
                                  ? null
                                  : _clear,
                              child: const Text('清理'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
