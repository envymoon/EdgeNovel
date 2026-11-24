import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';

import 'easter_eggs.dart';
import 'shelf_categories.dart';
import 'src/rust/api/sync.dart';

const int lanSyncDiscoveryPort = 45891;
const String _discoveryMagic = 'ZHIYUE_LAN_SYNC_V1';

/// A discovered peer running Zhiyue on the same local Wi-Fi network.
class LanSyncPeer {
  final String deviceId;
  final String name;
  final String platform;
  final String host;
  final int port;
  final DateTime lastSeen;

  const LanSyncPeer({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.host,
    required this.port,
    required this.lastSeen,
  });
}

/// Prepared merge session between this device and a remote peer (dry-run),
/// or from a local backup archive file when [isFileImport] is true.
class LanSyncSession {
  final String host;
  final int port;
  final String pin;
  final String remoteManifestJson;
  final Map<String, dynamic> remoteManifest;
  final SyncMergePlan plan;
  final bool isFileImport;
  final String? archiveFilePath;

  const LanSyncSession({
    required this.host,
    required this.port,
    required this.pin,
    required this.remoteManifestJson,
    required this.remoteManifest,
    required this.plan,
    this.isFileImport = false,
    this.archiveFilePath,
  });
}

/// Combined summary after a bidirectional LAN sync completes.
class LanSyncOutcome {
  final SyncApplyResult localResult;
  final int localEggsAdded;
  final int localCategoriesAdded;
  final bool remoteApplied;
  final String? remoteNote;

  const LanSyncOutcome({
    required this.localResult,
    required this.localEggsAdded,
    required this.localCategoriesAdded,
    required this.remoteApplied,
    this.remoteNote,
  });
}

String localPlatformLabel() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  return 'Device';
}

String localDeviceDisplayName() {
  final host = Platform.localHostname.trim();
  final plat = localPlatformLabel();
  if (host.isEmpty || host.toLowerCase() == 'localhost') return '$plat 设备';
  return '$host ($plat)';
}

/// Find the most likely private LAN IPv4 addresses on this machine.
Future<List<String>> localLanIpv4Addresses() async {
  final out = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            ip.startsWith('172.')) {
          out.add(ip);
        }
      }
    }
    if (out.isEmpty) {
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          out.add(addr.address);
        }
      }
    }
  } catch (_) {}
  return out;
}

Future<String> _buildExtraJson() async {
  await EasterEggEngine.instance.ensureLoaded();
  return jsonEncode({
    'easter_eggs': EasterEggEngine.instance.exportSyncData(),
    'shelf_categories': ShelfCategories.instance.exportSyncNames(),
  });
}

Future<(int, int)> _mergeExtraFromManifest(
  Map<String, dynamic> manifest,
) async {
  var eggsAdded = 0;
  var catsAdded = 0;
  final extra = manifest['extra'];
  if (extra is Map<String, dynamic>) {
    final eggs = extra['easter_eggs'];
    if (eggs is Map) {
      eggsAdded = await EasterEggEngine.instance.mergeSyncData(
        Map<String, dynamic>.from(eggs),
      );
    }
    final cats = extra['shelf_categories'];
    if (cats is List) {
      catsAdded = ShelfCategories.instance.mergeSyncNames(cats);
    }
  }
  return (eggsAdded, catsAdded);
}

String _sanitizeFileName(String raw, String fallbackUid) {
  final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (cleaned.isEmpty) return '$fallbackUid.txt';
  return cleaned.toLowerCase().endsWith('.txt') ? cleaned : '$cleaned.txt';
}

/// Local HTTP + UDP-discovery host that allows another Zhiyue device on the
/// same Wi-Fi to connect, preview diffs, and perform a bidirectional merge.
class LanSyncHost {
  HttpServer? _server;
  RawDatagramSocket? _udp;
  Timer? _beaconTimer;
  final String pin;
  final String deviceName;
  String? _deviceId;
  final Map<String, String> _uploadedFiles = {};
  final Map<String, String> _uploadedCovers = {};
  final void Function(String message)? onRemoteActivity;

  LanSyncHost({
    String? pin,
    String? deviceName,
    this.onRemoteActivity,
  }) : pin =
           pin ??
           (1000 + math.Random.secure().nextInt(9000)).toString(),
       deviceName = deviceName ?? localDeviceDisplayName();

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _deviceId = await syncDeviceId();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handleRequest);
    await _startBeacon();
  }

  Future<void> _startBeacon() async {
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      _udp = sock;
      _sendBeacon();
      _beaconTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _sendBeacon(),
      );
    } catch (_) {
      // UDP broadcast can be restricted on some networks; manual IP entry still works.
    }
  }

  Future<void> _sendBeacon() async {
    final sock = _udp;
    if (sock == null || _server == null || _deviceId == null) return;
    final ips = await localLanIpv4Addresses();
    if (ips.isEmpty) return;
    final payload = utf8.encode(
      jsonEncode({
        'magic': _discoveryMagic,
        'device_id': _deviceId,
        'name': deviceName,
        'platform': localPlatformLabel(),
        'host': ips.first,
        'port': _server!.port,
      }),
    );
    try {
      sock.send(
        payload,
        InternetAddress('255.255.255.255'),
        lanSyncDiscoveryPort,
      );
    } catch (_) {}
  }

  bool _checkPin(HttpRequest req) => req.headers.value('x-sync-pin') == pin;

  Future<void> _handleRequest(HttpRequest req) async {
    final res = req.response;
    res.headers.contentType = ContentType.json;
    if (!_checkPin(req)) {
      res.statusCode = HttpStatus.unauthorized;
      res.write(jsonEncode({'error': '配对码不正确'}));
      await res.close();
      return;
    }
    try {
      final segs = req.uri.pathSegments;
      if (req.method == 'GET' && segs.length == 1 && segs[0] == 'ping') {
        res.write(
          jsonEncode({
            'ok': true,
            'device_id': _deviceId ?? await syncDeviceId(),
            'device_name': deviceName,
            'platform': localPlatformLabel(),
          }),
        );
      } else if (req.method == 'GET' &&
          segs.length == 1 &&
          segs[0] == 'manifest') {
        onRemoteActivity?.call('对端正在读取同步清单…');
        final extra = await _buildExtraJson();
        final manifest = await syncExportManifest(
          deviceName: deviceName,
          extraJson: extra,
        );
        res.write(manifest);
      } else if (req.method == 'GET' && segs.length == 2 && segs[0] == 'book') {
        final uid = segs[1];
        final path = await syncGetBookFilePath(syncUid: uid);
        if (path == null || !File(path).existsSync()) {
          res.statusCode = HttpStatus.notFound;
          res.write(jsonEncode({'error': '文件不存在'}));
        } else {
          res.headers.contentType = ContentType.binary;
          await File(path).openRead().pipe(res);
          return;
        }
      } else if (req.method == 'GET' &&
          segs.length == 2 &&
          segs[0] == 'cover') {
        final uid = segs[1];
        final path = await syncGetCoverFilePath(syncUid: uid);
        if (path == null || !File(path).existsSync()) {
          res.statusCode = HttpStatus.notFound;
          res.write(jsonEncode({'error': '封面不存在'}));
        } else {
          res.headers.contentType = ContentType.binary;
          await File(path).openRead().pipe(res);
          return;
        }
      } else if (req.method == 'POST' &&
          segs.length == 2 &&
          segs[0] == 'upload-book') {
        final uid = segs[1];
        final rawName = req.uri.queryParameters['filename'] ?? '$uid.txt';
        final safe = _sanitizeFileName(rawName, uid);
        final dir = await syncBooksDir();
        final target = File('$dir${Platform.pathSeparator}sync_${uid.substring(0, math.min(8, uid.length))}_$safe');
        final sink = target.openWrite();
        await sink.addStream(req);
        await sink.close();
        _uploadedFiles[uid] = target.path;
        onRemoteActivity?.call('已接收书籍文件：$safe');
        res.write(jsonEncode({'ok': true, 'path': target.path}));
      } else if (req.method == 'POST' &&
          segs.length == 2 &&
          segs[0] == 'upload-cover') {
        final uid = segs[1];
        final ext = (req.uri.queryParameters['ext'] ?? 'png')
            .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
        final dir = await syncCoversDir();
        final target = File(
          '$dir${Platform.pathSeparator}sync_$uid.${ext.isEmpty ? 'png' : ext}',
        );
        final sink = target.openWrite();
        await sink.addStream(req);
        await sink.close();
        _uploadedCovers[uid] = target.path;
        res.write(jsonEncode({'ok': true, 'path': target.path}));
      } else if (req.method == 'POST' &&
          segs.length == 1 &&
          segs[0] == 'apply') {
        final bodyStr = await utf8.decoder.bind(req).join();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final remoteManifestJson = body['manifest_json'] as String;
        final resolutions =
            (body['resolutions'] as Map?)?.cast<String, dynamic>() ?? const {};
        onRemoteActivity?.call('正在合并对端变更…');
        final result = await syncApplyMerge(
          remoteManifestJson: remoteManifestJson,
          resolutionsJson: jsonEncode(resolutions),
          importedFilesJson: jsonEncode(_uploadedFiles),
          importedCoversJson: jsonEncode(_uploadedCovers),
        );
        final parsed = jsonDecode(remoteManifestJson) as Map<String, dynamic>;
        final (eggsAdded, catsAdded) = await _mergeExtraFromManifest(parsed);
        _uploadedFiles.clear();
        _uploadedCovers.clear();
        onRemoteActivity?.call(
          '双向同步完成：新增 ${result.booksImported} 本书、${result.eventsAdded} 条记录、$eggsAdded 个彩蛋',
        );
        res.write(
          jsonEncode({
            'ok': true,
            'books_imported': result.booksImported.toInt(),
            'progress_updated': result.progressUpdated.toInt(),
            'events_added': result.eventsAdded.toInt(),
            'eggs_added': eggsAdded,
            'categories_added': catsAdded,
          }),
        );
      } else {
        res.statusCode = HttpStatus.notFound;
        res.write(jsonEncode({'error': '未知接口'}));
      }
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      res.write(jsonEncode({'error': '$e'}));
    }
    await res.close();
  }

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close(force: true);
    _server = null;
  }
}

/// Passive UDP listener that discovers nearby Zhiyue hosts on the same Wi-Fi.
class LanSyncDiscovery {
  RawDatagramSocket? _socket;
  Timer? _pruneTimer;
  String? _selfDeviceId;
  final Map<String, LanSyncPeer> _peers = {};
  final void Function(List<LanSyncPeer> peers) onChanged;

  LanSyncDiscovery({required this.onChanged});

  Future<void> start() async {
    _selfDeviceId = await syncDeviceId();
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanSyncDiscoveryPort,
        reuseAddress: true,
      );
      _socket = sock;
      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        try {
          final m =
              jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (m['magic'] != _discoveryMagic) return;
          final id = m['device_id'] as String?;
          final port = (m['port'] as num?)?.toInt() ?? 0;
          if (id == null || id == _selfDeviceId || port <= 0) return;
          final host =
              (m['host'] as String?)?.trim().isNotEmpty == true
                  ? (m['host'] as String).trim()
                  : dg.address.address;
          _peers[id] = LanSyncPeer(
            deviceId: id,
            name: (m['name'] as String?) ?? '挚阅设备',
            platform: (m['platform'] as String?) ?? '',
            host: host,
            port: port,
            lastSeen: DateTime.now(),
          );
          onChanged(_peers.values.toList());
        } catch (_) {}
      });
      _pruneTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final cutoff = DateTime.now().subtract(const Duration(seconds: 8));
        final before = _peers.length;
        _peers.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
        if (_peers.length != before) onChanged(_peers.values.toList());
      });
    } catch (_) {
      // Port may already be bound or multicast/broadcast disabled; manual IP still works.
    }
  }

  void stop() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
  }
}

/// Client that connects to a [LanSyncHost], previews diffs, and runs a
/// zero-loss bidirectional merge.
class LanSyncClient {
  static Future<LanSyncSession> connectAndPlan({
    required String host,
    required int port,
    required String pin,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.get(host, port, '/manifest');
      req.headers.set('x-sync-pin', pin);
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode == HttpStatus.unauthorized) {
        throw Exception('配对码不正确，请检查对端屏幕上的 4 位数字');
      }
      if (res.statusCode != HttpStatus.ok) {
        throw Exception('对端返回错误 (${res.statusCode})：$body');
      }
      final parsed = jsonDecode(body) as Map<String, dynamic>;
      final plan = await syncPlanMerge(remoteManifestJson: body);
      return LanSyncSession(
        host: host,
        port: port,
        pin: pin,
        remoteManifestJson: body,
        remoteManifest: parsed,
        plan: plan,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<LanSyncOutcome> executeBidirectionalMerge({
    required LanSyncSession session,
    required Map<String, String> resolutions,
    required bool syncBookFiles,
    required void Function(String status, double progress) onProgress,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final importedFiles = <String, String>{};
    final importedCovers = <String, String>{};

    try {
      final remoteBooks =
          (session.remoteManifest['books'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const [];
      final remoteByUid = {
        for (final b in remoteBooks)
          if (b['sync_uid'] is String) b['sync_uid'] as String: b,
      };

      final pullList = syncBookFiles
          ? session.plan.booksToPull
          : const <SyncBookRef>[];
      final pushList = syncBookFiles
          ? session.plan.booksToPush
          : const <SyncBookRef>[];
      final totalSteps = pullList.length + pushList.length + 3;
      var step = 0;

      // 1. Download missing books (and covers) from remote peer.
      if (pullList.isNotEmpty) {
        final booksDir = await syncBooksDir();
        final coversDir = await syncCoversDir();
        for (final b in pullList) {
          step++;
          onProgress('正在接收《${b.title}》…', step / totalSteps);
          final meta = remoteByUid[b.syncUid];
          final rawName =
              (meta?['file_name'] as String?) ?? '${b.title}.txt';
          final safe = _sanitizeFileName(rawName, b.syncUid);
          final target = File(
            '$booksDir${Platform.pathSeparator}sync_${b.syncUid.substring(0, math.min(8, b.syncUid.length))}_$safe',
          );
          final req = await client.get(
            session.host,
            session.port,
            '/book/${Uri.encodeComponent(b.syncUid)}',
          );
          req.headers.set('x-sync-pin', session.pin);
          final res = await req.close();
          if (res.statusCode == HttpStatus.ok) {
            final sink = target.openWrite();
            await res.pipe(sink);
            importedFiles[b.syncUid] = target.path;
          } else {
            await res.drain<void>();
          }

          if (meta?['has_cover'] == true) {
            final creq = await client.get(
              session.host,
              session.port,
              '/cover/${Uri.encodeComponent(b.syncUid)}',
            );
            creq.headers.set('x-sync-pin', session.pin);
            final cres = await creq.close();
            if (cres.statusCode == HttpStatus.ok) {
              final cfile = File(
                '$coversDir${Platform.pathSeparator}sync_${b.syncUid}.png',
              );
              await cres.pipe(cfile.openWrite());
              importedCovers[b.syncUid] = cfile.path;
            } else {
              await cres.drain<void>();
            }
          }
        }
      }

      // 2. Push our unique books (and covers) to the remote peer.
      for (final b in pushList) {
        step++;
        onProgress('正在发送《${b.title}》到对端…', step / totalSteps);
        final path = await syncGetBookFilePath(syncUid: b.syncUid);
        if (path != null && File(path).existsSync()) {
          final fileName = path.split(RegExp(r'[\\/]')).last;
          final req = await client.post(
            session.host,
            session.port,
            '/upload-book/${Uri.encodeComponent(b.syncUid)}?filename=${Uri.encodeQueryComponent(fileName)}',
          );
          req.headers.set('x-sync-pin', session.pin);
          await req.addStream(File(path).openRead());
          final res = await req.close();
          await res.drain<void>();
        }
        final coverPath = await syncGetCoverFilePath(syncUid: b.syncUid);
        if (coverPath != null && File(coverPath).existsSync()) {
          final ext = coverPath.contains('.')
              ? coverPath.split('.').last
              : 'png';
          final creq = await client.post(
            session.host,
            session.port,
            '/upload-cover/${Uri.encodeComponent(b.syncUid)}?ext=${Uri.encodeQueryComponent(ext)}',
          );
          creq.headers.set('x-sync-pin', session.pin);
          await creq.addStream(File(coverPath).openRead());
          final cres = await creq.close();
          await cres.drain<void>();
        }
      }

      // 3. Export our pre-merge manifest so the remote peer receives our data too.
      step++;
      onProgress('正在备份并合并本机数据…', step / totalSteps);
      final localExtra = await _buildExtraJson();
      final localManifestJson = await syncExportManifest(
        deviceName: localDeviceDisplayName(),
        extraJson: localExtra,
      );

      // 4. Apply merge locally (creates sync_backup_last.db automatically).
      final localResult = await syncApplyMerge(
        remoteManifestJson: session.remoteManifestJson,
        resolutionsJson: jsonEncode(resolutions),
        importedFilesJson: jsonEncode(importedFiles),
        importedCoversJson: jsonEncode(importedCovers),
      );
      final (eggsAdded, catsAdded) = await _mergeExtraFromManifest(
        session.remoteManifest,
      );

      // 5. Mirror conflict resolutions and apply on the remote peer too.
      step++;
      onProgress('正在同步合并对端设备…', step / totalSteps);
      final mirroredResolutions = <String, String>{};
      for (final e in resolutions.entries) {
        mirroredResolutions[e.key] = switch (e.value) {
          'local' => 'remote',
          'remote' => 'local',
          _ => 'further_bookmark',
        };
      }
      var remoteApplied = false;
      String? remoteNote;
      try {
        final req = await client.post(session.host, session.port, '/apply');
        req.headers.set('x-sync-pin', session.pin);
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'manifest_json': localManifestJson,
            'resolutions': mirroredResolutions,
          }),
        );
        final res = await req.close();
        await res.drain<void>();
        if (res.statusCode == HttpStatus.ok) {
          remoteApplied = true;
        } else {
          remoteNote = '对端合并返回 ${res.statusCode}';
        }
      } catch (e) {
        remoteNote = '本机已合并完成，但对端回调中断：$e';
      }

      onProgress('同步完成', 1.0);
      return LanSyncOutcome(
        localResult: localResult,
        localEggsAdded: eggsAdded,
        localCategoriesAdded: catsAdded,
        remoteApplied: remoteApplied,
        remoteNote: remoteNote,
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// Offline backup export/import (.zip or .json) powered by the exact same
/// zero-loss Git-style merge engine as LAN sync.
class LocalBackupArchive {
  /// Export all reading data, books metadata, progress, bookmarks, annotations,
  /// cleanup rules, archived stats, easter eggs and shelf categories into a
  /// portable `.zip` file (optionally bundling TXT files & custom covers).
  static Future<({int bookFilesBundled, int totalBytes})> exportToZip({
    required String outputPath,
    required bool includeBookFiles,
    void Function(String status, double progress)? onProgress,
  }) async {
    onProgress?.call('正在导出全部阅读数据…', 0.1);
    final extra = await _buildExtraJson();
    final manifestJson = await syncExportManifest(
      deviceName: localDeviceDisplayName(),
      extraJson: extra,
    );
    final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
    final books =
        (manifest['books'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    final archive = Archive();
    final manifestBytes = utf8.encode(manifestJson);
    archive.addFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    var bundled = 0;
    if (includeBookFiles && books.isNotEmpty) {
      for (var i = 0; i < books.length; i++) {
        final b = books[i];
        final uid = b['sync_uid'] as String?;
        final title = (b['title'] as String?) ?? '未命名';
        if (uid == null || uid.isEmpty) continue;
        onProgress?.call(
          '正在打包《$title》…',
          0.15 + 0.7 * ((i + 1) / books.length),
        );
        final path = await syncGetBookFilePath(syncUid: uid);
        if (path != null && File(path).existsSync()) {
          final bytes = await File(path).readAsBytes();
          archive.addFile(ArchiveFile('books/$uid.txt', bytes.length, bytes));
          bundled++;
        }
        final coverPath = await syncGetCoverFilePath(syncUid: uid);
        if (coverPath != null && File(coverPath).existsSync()) {
          final bytes = await File(coverPath).readAsBytes();
          archive.addFile(ArchiveFile('covers/$uid.png', bytes.length, bytes));
        }
      }
    }

    onProgress?.call('正在写入备份文件…', 0.92);
    final encoded = ZipEncoder().encode(archive);
    final outFile = File(outputPath);
    await outFile.writeAsBytes(encoded, flush: true);
    onProgress?.call('导出完成', 1.0);
    return (bookFilesBundled: bundled, totalBytes: encoded.length);
  }

  /// Open a `.zip` or `.json` backup file and compute a dry-run merge plan
  /// without modifying local data yet.
  static Future<LanSyncSession> inspectFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('找不到选中的备份文件');
    }
    late final String manifestJson;
    if (filePath.toLowerCase().endsWith('.json')) {
      manifestJson = await file.readAsString();
    } else {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final entry = archive.findFile('manifest.json');
      if (entry == null) {
        throw Exception('备份包中缺少 manifest.json，可能不是挚阅备份文件');
      }
      manifestJson = utf8.decode(entry.content as List<int>);
    }
    final parsed = jsonDecode(manifestJson) as Map<String, dynamic>;
    final plan = await syncPlanMerge(remoteManifestJson: manifestJson);
    return LanSyncSession(
      host: 'backup-file',
      port: 0,
      pin: '',
      remoteManifestJson: manifestJson,
      remoteManifest: parsed,
      plan: plan,
      isFileImport: true,
      archiveFilePath: filePath,
    );
  }

  /// Apply an approved file-import merge, extracting bundled TXT/cover files
  /// for newly added books if requested.
  static Future<LanSyncOutcome> applyFileImport({
    required LanSyncSession session,
    required Map<String, String> resolutions,
    required bool importBookFiles,
    required void Function(String status, double progress) onProgress,
  }) async {
    final importedFiles = <String, String>{};
    final importedCovers = <String, String>{};

    final archivePath = session.archiveFilePath;
    if (importBookFiles &&
        archivePath != null &&
        archivePath.toLowerCase().endsWith('.zip')) {
      onProgress('正在解压备份包中的书籍文件…', 0.15);
      final bytes = await File(archivePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final booksDir = await syncBooksDir();
      final coversDir = await syncCoversDir();
      final remoteBooks =
          (session.remoteManifest['books'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const [];
      final remoteByUid = {
        for (final b in remoteBooks)
          if (b['sync_uid'] is String) b['sync_uid'] as String: b,
      };
      final pullList = session.plan.booksToPull;
      for (var i = 0; i < pullList.length; i++) {
        final b = pullList[i];
        onProgress(
          '正在导入《${b.title}》…',
          0.2 + 0.55 * ((i + 1) / math.max(1, pullList.length)),
        );
        final bookEntry = archive.findFile('books/${b.syncUid}.txt');
        if (bookEntry != null) {
          final meta = remoteByUid[b.syncUid];
          final rawName =
              (meta?['file_name'] as String?) ?? '${b.title}.txt';
          final safe = _sanitizeFileName(rawName, b.syncUid);
          final target = File(
            '$booksDir${Platform.pathSeparator}sync_${b.syncUid.substring(0, math.min(8, b.syncUid.length))}_$safe',
          );
          await target.writeAsBytes(bookEntry.content as List<int>, flush: true);
          importedFiles[b.syncUid] = target.path;
        }
        final coverEntry = archive.findFile('covers/${b.syncUid}.png');
        if (coverEntry != null) {
          final target = File(
            '$coversDir${Platform.pathSeparator}sync_${b.syncUid}.png',
          );
          await target.writeAsBytes(
            coverEntry.content as List<int>,
            flush: true,
          );
          importedCovers[b.syncUid] = target.path;
        }
      }
    }

    onProgress('正在备份并合并数据到本机…', 0.85);
    final localResult = await syncApplyMerge(
      remoteManifestJson: session.remoteManifestJson,
      resolutionsJson: jsonEncode(resolutions),
      importedFilesJson: jsonEncode(importedFiles),
      importedCoversJson: jsonEncode(importedCovers),
    );
    final (eggsAdded, catsAdded) = await _mergeExtraFromManifest(
      session.remoteManifest,
    );
    onProgress('导入合并完成', 1.0);
    return LanSyncOutcome(
      localResult: localResult,
      localEggsAdded: eggsAdded,
      localCategoriesAdded: catsAdded,
      remoteApplied: false,
    );
  }
}
