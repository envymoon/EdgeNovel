import 'dart:io';

import 'package:flutter/foundation.dart';

import 'hosted_download.dart';
import 'model_download.dart';
import 'platform_services.dart';
import 'src/rust/api/dict.dart';

const _xinhua =
    'raw.githubusercontent.com/pwxcoo/chinese-xinhua/fe6d6c2e8baa82187f4c96bbe042e43f96c05666/data';

HostedFile _data(String name, int bytes, String sha256, {bool cdn = false}) =>
    HostedFile(name, bytes, sha256, [
      'https://$_xinhua/$name',
      'https://ghfast.top/https://$_xinhua/$name',
      // jsDelivr serves files under 20 MB only.
      if (cdn)
        'https://cdn.jsdelivr.net/gh/pwxcoo/chinese-xinhua@fe6d6c2e8baa82187f4c96bbe042e43f96c05666/data/$name',
    ]);

/// chinese-xinhua (MIT): characters, words, idioms. Turned into one small
/// database once downloaded, and the files thrown away.
final dictionaryFiles = [
  _data(
    'word.json',
    27499599,
    '1e9a43c9adada412f21d0416a37242a2c2bea55adaf87d5648ab9b4116b7ed0c',
  ),
  _data(
    'ci.json',
    26129191,
    '739e086d61dc9b95cd1df92095720e6391f952a41c476d3281ef95ebed869a09',
  ),
  _data(
    'idiom.json',
    10319857,
    '1d4b4f454ce1c416d6a1ab2369d6e66c0ff99e04390172eef70790499e21ce19',
    cdn: true,
  ),
];

/// 字典: downloaded only by who wants it, then looked up from the 标注
/// dialog.
class Dictionary {
  Dictionary._();

  static final instance = Dictionary._();

  /// Whether it is there to look things up in.
  final installed = ValueNotifier<bool>(false);

  /// The download's share while it runs, 1 while the database is made.
  final progress = ValueNotifier<double?>(null);

  final error = ValueNotifier<String?>(null);

  Directory? _dir;
  ResumableFileDownload? _transfer;

  Future<Directory> _folder() async =>
      _dir ??= AppServices.instance.storage.supportChild('dict');

  @visibleForTesting
  void useFolder(Directory dir) => _dir = dir;

  Future<File> _db() async =>
      File('${(await _folder()).path}${Platform.pathSeparator}dict.db');

  /// Whether it was downloaded before; checked once at start.
  Future<void> check() async {
    try {
      installed.value = await (await _db()).exists();
    } catch (_) {}
  }

  Future<void> install() async {
    if (_transfer != null) return;
    final transfer = _transfer = ResumableFileDownload();
    error.value = null;
    progress.value = 0;
    try {
      final dir = await _folder();
      await dir.create(recursive: true);
      await downloadHostedFiles(dir.path, dictionaryFiles, transfer, (p) {
        progress.value = p;
      });
      progress.value = 1;
      await dictBuild(dir: dir.path);
      installed.value = true;
    } on DownloadStopped {
      // Cancelled.
    } catch (e) {
      error.value = '$e';
    } finally {
      _transfer = null;
      progress.value = null;
    }
  }

  void cancel() => _transfer?.pause();

  Future<void> remove() async {
    installed.value = false;
    final dir = await _folder();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<int> bytes() async {
    final db = await _db();
    return await db.exists() ? db.length() : 0;
  }

  /// What the dictionary says about [text]; nothing when it is not installed
  /// or does not know it.
  Future<List<DictEntry>> lookup(String text) async {
    if (!installed.value) return const [];
    try {
      return await dictLookup(path: (await _db()).path, text: text);
    } catch (_) {
      return const [];
    }
  }
}
