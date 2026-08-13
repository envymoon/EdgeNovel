import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FontPack {
  final String id;
  final String name;
  final String family;
  final String description;
  final String sample;
  final String sizeLabel;
  final String license;
  final String source;
  final String fileName;
  final List<String> downloadUrls;
  final bool custom;

  const FontPack({
    required this.id,
    required this.name,
    required this.family,
    required this.description,
    required this.sample,
    required this.sizeLabel,
    required this.license,
    required this.source,
    required this.fileName,
    required this.downloadUrls,
    this.custom = false,
  });

  factory FontPack.custom({
    required String id,
    required String name,
    required String family,
    required String fileName,
  }) => FontPack(
    id: id,
    name: name,
    family: family,
    description: '从本机导入',
    sample: '云边有个小卖部',
    sizeLabel: '本地字体',
    license: '请确认你有权使用该字体',
    source: '',
    fileName: fileName,
    downloadUrls: const [],
    custom: true,
  );
}

const systemFont = FontPack(
  id: 'system',
  name: '系统默认',
  family: '',
  description: '跟随设备，清晰稳定',
  sample: '故事从这一页开始',
  sizeLabel: '无需下载',
  license: '',
  source: '',
  fileName: '',
  downloadUrls: [],
);

const downloadableFonts = <FontPack>[
  FontPack(
    id: 'source_han_serif_sc',
    name: '思源宋体',
    family: 'NovelSourceHanSerif',
    description: '端正、有书卷气，适合长篇阅读',
    sample: '山川异域，风月同天',
    sizeLabel: '约 24 MB',
    license: 'SIL Open Font License 1.1',
    source: 'github.com/adobe-fonts/source-han-serif',
    fileName: 'SourceHanSerifSC-Regular.otf',
    downloadUrls: [
      'https://raw.githubusercontent.com/adobe-fonts/source-han-serif/release/OTF/SimplifiedChinese/SourceHanSerifSC-Regular.otf',
      'https://cdn.jsdelivr.net/gh/adobe-fonts/source-han-serif@release/OTF/SimplifiedChinese/SourceHanSerifSC-Regular.otf',
    ],
  ),
  FontPack(
    id: 'lxgw_wenkai_gb',
    name: '霞鹜文楷',
    family: 'NovelLxgwWenKai',
    description: '温柔自然，像认真写下的手稿',
    sample: '晚风吹过长街与旧书页',
    sizeLabel: '约 26 MB',
    license: 'SIL Open Font License 1.1',
    source: 'github.com/lxgw/LxgwWenKaiGB',
    fileName: 'LXGWWenKaiGB-Regular.ttf',
    downloadUrls: [
      'https://raw.githubusercontent.com/lxgw/LxgwWenKaiGB/main/fonts/TTF/LXGWWenKaiGB-Regular.ttf',
      'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKaiGB@main/fonts/TTF/LXGWWenKaiGB-Regular.ttf',
    ],
  ),
  FontPack(
    id: 'zcool_kuaile',
    name: '站酷快乐体',
    family: 'NovelZcoolKuaiLe',
    description: '圆润俏皮，适合轻松、可爱的故事',
    sample: '今天也要快乐地读故事呀',
    sizeLabel: '约 1.5 MB',
    license: 'SIL Open Font License 1.1',
    source: 'github.com/google/fonts',
    fileName: 'ZCOOLKuaiLe-Regular.ttf',
    downloadUrls: [
      'https://raw.githubusercontent.com/google/fonts/main/ofl/zcoolkuaile/ZCOOLKuaiLe-Regular.ttf',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zcoolkuaile/ZCOOLKuaiLe-Regular.ttf',
    ],
  ),
  FontPack(
    id: 'ma_shan_zheng',
    name: '马善政毛笔体',
    family: 'NovelMaShanZheng',
    description: '灵动的毛笔字，适合武侠与古风',
    sample: '仗剑天涯，且听风吟',
    sizeLabel: '约 5.9 MB',
    license: 'SIL Open Font License 1.1',
    source: 'github.com/google/fonts',
    fileName: 'MaShanZheng-Regular.ttf',
    downloadUrls: [
      'https://raw.githubusercontent.com/google/fonts/main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mashanzheng/MaShanZheng-Regular.ttf',
    ],
  ),
  FontPack(
    id: 'long_cang',
    name: '龙藏体',
    family: 'NovelLongCang',
    description: '洒脱特别，像旧信笺上的字迹',
    sample: '人间忽晚，山河已秋',
    sizeLabel: '约 5.2 MB',
    license: 'SIL Open Font License 1.1',
    source: 'github.com/google/fonts',
    fileName: 'LongCang-Regular.ttf',
    downloadUrls: [
      'https://raw.githubusercontent.com/google/fonts/main/ofl/longcang/LongCang-Regular.ttf',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/longcang/LongCang-Regular.ttf',
    ],
  ),
];

class FontManager extends ChangeNotifier {
  FontManager._();

  static final instance = FontManager._();

  late Directory _directory;
  SharedPreferences? _prefs;
  final Set<String> _installedIds = {};
  final Set<String> _loadedFamilies = {};
  final Map<String, double?> _progress = {};
  final Map<String, String> _errors = {};
  final List<FontPack> _customFonts = [];

  List<FontPack> get packs => [
    systemFont,
    ...downloadableFonts,
    ..._customFonts,
  ];

  bool isInstalled(FontPack pack) =>
      pack.id == systemFont.id || _installedIds.contains(pack.id);

  bool isDownloading(FontPack pack) => _progress.containsKey(pack.id);

  double? progressFor(FontPack pack) => _progress[pack.id];

  String? errorFor(FontPack pack) => _errors[pack.id];

  String displayNameForFamily(String family) =>
      packs
          .where((pack) => pack.family == family)
          .map((pack) => pack.name)
          .firstOrNull ??
      systemFont.name;

  Future<void> initialize(
    String appSupportPath, {
    required String selectedFamily,
  }) async {
    _directory = Directory('$appSupportPath${Platform.pathSeparator}fonts');
    await _directory.create(recursive: true);
    _prefs = await SharedPreferences.getInstance();
    _restoreCustomFonts();

    for (final pack in [...downloadableFonts, ..._customFonts]) {
      if (await _fileFor(pack).exists()) _installedIds.add(pack.id);
    }
    final selected = packs
        .where((pack) => pack.family == selectedFamily)
        .firstOrNull;
    if (selected != null && isInstalled(selected)) {
      await ensureLoaded(selected);
    }
  }

  bool hasFamily(String family) {
    if (family.isEmpty) return true;
    return packs.any((pack) => pack.family == family && isInstalled(pack));
  }

  Future<void> loadInstalledFonts() async {
    for (final pack in packs.where(isInstalled)) {
      await ensureLoaded(pack);
    }
  }

  Future<void> ensureLoaded(FontPack pack) async {
    if (pack.family.isEmpty || _loadedFamilies.contains(pack.family)) return;
    final file = _fileFor(pack);
    if (!await file.exists()) throw StateError('字体文件不存在');
    final bytes = await file.readAsBytes();
    final loader = FontLoader(pack.family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loadedFamilies.add(pack.family);
    notifyListeners();
  }

  Future<void> download(FontPack pack) async {
    if (pack.downloadUrls.isEmpty || isDownloading(pack)) return;
    _errors.remove(pack.id);
    _progress[pack.id] = null;
    notifyListeners();

    final target = _fileFor(pack);
    final part = File('${target.path}.part');
    Object? lastError;
    try {
      for (final url in pack.downloadUrls) {
        try {
          if (await part.exists()) await part.delete();
          await _downloadOne(url, part, pack.id);
          if (await target.exists()) await target.delete();
          await part.rename(target.path);
          _installedIds.add(pack.id);
          await ensureLoaded(pack);
          _progress.remove(pack.id);
          notifyListeners();
          return;
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError ?? StateError('没有可用的下载地址');
    } catch (error) {
      if (await part.exists()) await part.delete();
      _progress.remove(pack.id);
      _errors[pack.id] = '$error';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _downloadOne(String url, File part, String id) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          '下载失败（${response.statusCode}）',
          uri: Uri.parse(url),
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          _progress[id] = total > 0 ? received / total : null;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      if (received == 0) throw const FormatException('下载内容为空');
    } finally {
      client.close(force: true);
    }
  }

  Future<FontPack?> importLocalFont() async {
    final sourcePath = await AppServices.instance.files.pickFont();
    if (sourcePath == null) return null;

    final source = File(sourcePath);
    final original = source.uri.pathSegments.last;
    final dot = original.lastIndexOf('.');
    final displayName = dot > 0 ? original.substring(0, dot) : original;
    final extension = dot > 0 ? original.substring(dot).toLowerCase() : '.ttf';
    final id = 'custom_${DateTime.now().microsecondsSinceEpoch}';
    final pack = FontPack.custom(
      id: id,
      name: displayName,
      family: 'NovelUserFont_$id',
      fileName: '$id$extension',
    );
    await source.copy(_fileFor(pack).path);
    _customFonts.add(pack);
    _installedIds.add(pack.id);
    _saveCustomFonts();
    await ensureLoaded(pack);
    notifyListeners();
    return pack;
  }

  Future<void> delete(FontPack pack) async {
    if (pack.id == systemFont.id) return;
    final file = _fileFor(pack);
    if (await file.exists()) await file.delete();
    _installedIds.remove(pack.id);
    _errors.remove(pack.id);
    if (pack.custom) {
      _customFonts.removeWhere((item) => item.id == pack.id);
      _saveCustomFonts();
    }
    notifyListeners();
  }

  File _fileFor(FontPack pack) =>
      File('${_directory.path}${Platform.pathSeparator}${pack.fileName}');

  void _restoreCustomFonts() {
    final raw = _prefs?.getString('customFonts');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final value in list) {
        final item = value as Map<String, dynamic>;
        _customFonts.add(
          FontPack.custom(
            id: item['id'] as String,
            name: item['name'] as String,
            family: item['family'] as String,
            fileName: item['fileName'] as String,
          ),
        );
      }
    } catch (_) {
      _prefs?.remove('customFonts');
    }
  }

  void _saveCustomFonts() {
    _prefs?.setString(
      'customFonts',
      jsonEncode([
        for (final pack in _customFonts)
          {
            'id': pack.id,
            'name': pack.name,
            'family': pack.family,
            'fileName': pack.fileName,
          },
      ]),
    );
  }
}
