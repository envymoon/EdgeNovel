import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Talking to a text-to-speech server the user runs on some other machine of
/// their own — a desktop, a home server, whatever has a GPU in it.
///
/// Why this exists: good-sounding Chinese speech costs more compute than a
/// phone (or a thin laptop) can spend in real time, and the alternative we tried
/// — grinding chapters out locally in advance — bought quality with hours of
/// waiting and gigabytes of WAV. Moving synthesis to a machine that is already
/// sitting there idle costs the user one deployment and then nothing: any voice
/// that machine can run, at once, with no local storage at all.
///
/// The wire format is OpenAI's `/v1/audio/speech` on purpose. It is what every
/// self-hosted TTS project already speaks, so "our" server (see `tts-server/`)
/// is merely the one we make easy — a user who prefers another can point the
/// app at it and it works, and a better model next year needs no app release.
///
/// Nothing but the sentence being spoken ever leaves the device, it goes only to
/// an address the user typed themselves, and no audio is kept afterwards.

/// Where the server is and what to ask it for.
class TtsServer {
  /// e.g. `http://192.168.1.8:8880` — no trailing slash, no `/v1`.
  final String baseUrl;

  /// Optional; sent as a bearer token. Most local servers ignore it.
  final String apiKey;

  /// Server-side model name. Empty means "whatever it defaults to".
  final String model;

  const TtsServer({required this.baseUrl, this.apiKey = '', this.model = ''});

  bool get configured => baseUrl.trim().isNotEmpty;

  Uri _uri(String path) {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    // A bare host:port is the shape people actually type off a router page.
    if (!b.startsWith('http://') && !b.startsWith('https://')) b = 'http://$b';
    return Uri.parse('$b$path');
  }
}

/// A voice the server offers. [id] goes on the wire; [label] is what the user
/// picks from. Servers that only return names give us both the same.
class RemoteVoice {
  final String id;
  final String label;
  const RemoteVoice(this.id, this.label);
}

class TtsRemoteError implements Exception {
  final String message;
  TtsRemoteError(this.message);
  @override
  String toString() => message;
}

/// One client for the whole app: a single [HttpClient] keeps the TCP connection
/// alive between sentences, which is most of what makes back-to-back synthesis
/// feel gapless over a LAN.
class TtsRemoteClient {
  final _http = HttpClient()..idleTimeout = const Duration(seconds: 30);

  void close() => _http.close(force: true);

  Future<HttpClientRequest> _open(
    String method,
    TtsServer s,
    String path,
    Duration timeout,
  ) async {
    _http.connectionTimeout = timeout;
    final uri = s._uri(path);
    final req = method == 'GET'
        ? await _http.getUrl(uri)
        : await _http.postUrl(uri);
    if (s.apiKey.trim().isNotEmpty) {
      req.headers.set('authorization', 'Bearer ${s.apiKey.trim()}');
    }
    return req;
  }

  /// Synthesize one sentence and return the WAV bytes.
  ///
  /// WAV rather than mp3 deliberately: it needs no decoder on the client, and
  /// on a LAN the extra bytes cost less than the decode would.
  Future<Uint8List> speak(
    TtsServer s, {
    required String text,
    required String voice,
    required double speed,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    try {
      final req = await _open('POST', s, '/v1/audio/speech', timeout);
      req.headers.contentType = ContentType.json;
      req.add(
        utf8.encode(
          jsonEncode({
            if (s.model.trim().isNotEmpty) 'model': s.model.trim(),
            'input': text,
            'voice': voice,
            'speed': speed,
            'response_format': 'wav',
          }),
        ),
      );
      final res = await req.close().timeout(timeout);
      final body = await _collect(res);
      if (res.statusCode != 200) {
        throw TtsRemoteError('服务端返回 ${res.statusCode}：${_brief(body)}');
      }
      if (body.isEmpty) throw TtsRemoteError('服务端返回了空音频');
      return body;
    } on TtsRemoteError {
      rethrow;
    } catch (e) {
      throw TtsRemoteError(_friendly(e));
    }
  }

  /// What voices the server has. `/v1/audio/voices` is what kokoro-fastapi and
  /// our own server expose; anything else gets an empty list and the user types
  /// the voice name by hand, which still works.
  Future<List<RemoteVoice>> voices(TtsServer s) async {
    try {
      final req = await _open(
        'GET',
        s,
        '/v1/audio/voices',
        const Duration(seconds: 8),
      );
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = utf8.decode(await _collect(res), allowMalformed: true);
      if (res.statusCode != 200) return const [];
      return _parseVoices(jsonDecode(body));
    } catch (_) {
      return const [];
    }
  }

  /// Reachability, phrased for the settings page: either how many voices it has
  /// or why it could not be reached.
  Future<String> ping(TtsServer s) async {
    final vs = await voices(s);
    if (vs.isNotEmpty) return '连接正常 · ${vs.length} 个音色';
    // No voice list is not itself a failure, so prove the address answers at all
    // by asking it to say something very short.
    await speak(
      s,
      text: '测试',
      voice: '',
      speed: 1.0,
      timeout: const Duration(seconds: 20),
    );
    return '连接正常';
  }

  Future<Uint8List> _collect(HttpClientResponse res) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      b.add(chunk);
    }
    return b.takeBytes();
  }
}

/// Both shapes seen in the wild: `["af_bella", …]` and
/// `{"voices": [{"id": …, "name": …}, …]}`.
List<RemoteVoice> _parseVoices(dynamic json) {
  final list = json is Map ? (json['voices'] ?? json['data']) : json;
  if (list is! List) return const [];
  final out = <RemoteVoice>[];
  for (final v in list) {
    if (v is String) {
      out.add(RemoteVoice(v, v));
    } else if (v is Map) {
      final id = '${v['id'] ?? v['name'] ?? ''}';
      if (id.isEmpty) continue;
      out.add(RemoteVoice(id, '${v['label'] ?? v['name'] ?? id}'));
    }
  }
  return out;
}

String _brief(Uint8List body) {
  final s = utf8.decode(body, allowMalformed: true).trim();
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

/// Network errors are unreadable by default, and the fixes differ, so name them.
String _friendly(Object e) {
  if (e is SocketException) {
    return '连不上服务端，检查地址与端口';
  }
  if (e is HandshakeException) return 'HTTPS 握手失败，本地服务通常应该用 http://';
  if (e is FormatException) return '地址格式不对，应形如 http://192.168.1.8:8880';
  if (e.toString().contains('TimeoutException')) return '服务端没有及时响应';
  return '$e';
}
