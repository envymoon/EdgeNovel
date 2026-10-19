import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum DownloadStopKind { paused, cancelled }

class DownloadStopped implements Exception {
  const DownloadStopped(this.kind);

  final DownloadStopKind kind;
}

typedef DownloadProgressCallback = void Function(int received, int? total);
typedef HttpClientFactory = HttpClient Function();

/// A file download that keeps its partial bytes across pauses, network errors,
/// and process restarts. The completed file is still verified by ModelManager
/// before it can replace an installed model.
class ResumableFileDownload {
  ResumableFileDownload({HttpClientFactory? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClientFactory _clientFactory;
  HttpClient? _client;
  Completer<void>? _finished;
  bool _pauseRequested = false;
  bool _cancelRequested = false;

  /// On iOS, the .part file the system is filling for this download.
  String? _systemPart;

  bool get stopping => _pauseRequested || _cancelRequested;

  void pause() {
    if (stopping) return;
    _pauseRequested = true;
    _client?.close(force: true);
    if (_systemPart case final part?) _SystemTransfer.stop(part, keep: true);
  }

  Future<void> cancel(File target) async {
    _cancelRequested = true;
    _client?.close(force: true);
    if (_systemPart case final part?) _SystemTransfer.stop(part, keep: false);
    final finished = _finished;
    if (finished != null) {
      await finished.future;
    } else {
      await discard(target);
    }
  }

  static File partialFile(File target) => File('${target.path}.part');

  static Future<int> pendingBytes(File target) async {
    if (await target.exists()) return target.length();
    final partial = partialFile(target);
    return await partial.exists() ? partial.length() : 0;
  }

  static Future<void> discard(File target) async {
    final partial = partialFile(target);
    if (await partial.exists()) await partial.delete();
    final resume = File('${partial.path}.resume');
    if (await resume.exists()) await resume.delete();
    if (await target.exists()) await target.delete();
  }

  Future<void> downloadFirst(
    List<String> urls,
    File target, {
    required DownloadProgressCallback onProgress,
  }) async {
    _finished = Completer<void>();
    try {
      if (urls.isEmpty) throw '没有可用的下载地址';
      if (await target.exists()) return;

      Object? lastError;
      for (final url in urls) {
        _throwIfStopped();
        try {
          await _download(url, target, onProgress);
          return;
        } on DownloadStopped {
          rethrow;
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError ?? '下载失败';
    } finally {
      try {
        if (_cancelRequested) await discard(target);
      } finally {
        _finished?.complete();
        _finished = null;
      }
    }
  }

  Future<void> _download(
    String url,
    File target,
    DownloadProgressCallback onProgress,
  ) async {
    if (Platform.isIOS) return _downloadBySystem(url, target, onProgress);
    final partial = partialFile(target);
    await partial.parent.create(recursive: true);
    var existing = await partial.exists() ? await partial.length() : 0;
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 20);
    _client = client;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'novel-reader');
      if (existing > 0) request.headers.set('Range', 'bytes=$existing-');
      final response = await request.close();
      _throwIfStopped();

      var append =
          existing > 0 && response.statusCode == HttpStatus.partialContent;
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existing > 0) {
        await partial.delete();
        existing = 0;
        throw '服务器拒绝续传，正在重新下载';
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw 'HTTP ${response.statusCode}';
      }
      if (!append) existing = 0;

      final total = _totalBytes(response, existing);
      onProgress(existing, total);
      final sink = partial.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = existing;
      try {
        await for (final chunk in response) {
          _throwIfStopped();
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      _throwIfStopped();
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
    } catch (_) {
      _throwIfStopped();
      rethrow;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  /// iOS suspends an app soon after it leaves the screen, and a download the
  /// app runs itself stops with it. The system's own transfer goes on: it
  /// fetches the rest from [existing] and adds it to the same .part file.
  Future<void> _downloadBySystem(
    String url,
    File target,
    DownloadProgressCallback onProgress,
  ) async {
    final partial = partialFile(target);
    await partial.parent.create(recursive: true);
    final existing = await partial.exists() ? await partial.length() : 0;
    onProgress(existing, null);
    _throwIfStopped();
    _systemPart = partial.path;
    try {
      await _SystemTransfer.fetch(url, partial.path, existing, onProgress);
    } catch (error) {
      _throwIfStopped();
      if (error == 'HTTP 416' && existing > 0) {
        await discard(target);
        throw '服务器拒绝续传，正在重新下载';
      }
      rethrow;
    } finally {
      _systemPart = null;
    }
    _throwIfStopped();
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  }

  int? _totalBytes(HttpClientResponse response, int existing) {
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = contentRange == null
        ? null
        : RegExp(r'/([0-9]+)$').firstMatch(contentRange);
    final rangedTotal = int.tryParse(match?.group(1) ?? '');
    if (rangedTotal != null) return rangedTotal;
    return response.contentLength >= 0
        ? existing + response.contentLength
        : null;
  }

  Never _stopped() => throw DownloadStopped(
    _cancelRequested ? DownloadStopKind.cancelled : DownloadStopKind.paused,
  );

  void _throwIfStopped() {
    if (stopping) _stopped();
  }
}

/// The app's side of the iOS background transfer (Transfers in AppDelegate).
/// A transfer is known by its .part file, which outlives the app: one begun
/// before the app was last ended is picked up again, not started twice.
class _SystemTransfer {
  static const _channel = MethodChannel('novel/transfer');
  static final _waiting =
      <String, (Completer<void>, DownloadProgressCallback)>{};
  static bool _listening = false;

  static Future<void> fetch(
    String url,
    String part,
    int offset,
    DownloadProgressCallback onProgress,
  ) async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_event);
    }
    final done = Completer<void>();
    // It may end before the start call returns; awaited below all the same.
    done.future.ignore();
    _waiting[part] = (done, onProgress);
    try {
      await _channel.invokeMethod<String>('start', {
        'url': url,
        'part': part,
        'offset': offset,
      });
      await done.future;
    } finally {
      if (identical(_waiting[part]?.$1, done)) _waiting.remove(part);
    }
  }

  static Future<void> stop(String part, {required bool keep}) => _channel
      .invokeMethod<void>(keep ? 'pause' : 'cancel', {'part': part})
      .catchError((_) {});

  static Future<void> _event(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final waiting = _waiting[args['part']];
    if (waiting == null) return;
    final (done, onProgress) = waiting;
    switch (call.method) {
      case 'progress':
        onProgress(
          (args['received'] as num).toInt(),
          (args['total'] as num?)?.toInt(),
        );
      case 'done':
        if (done.isCompleted) return;
        final error = args['error'] as String?;
        if (error == null) {
          done.complete();
        } else {
          done.completeError(error);
        }
    }
  }
}
