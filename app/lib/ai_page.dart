import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

import 'ai_cache_page.dart';
import 'ai_runtime_page.dart';
import 'bloom.dart';
import 'model_download.dart';
import 'model_manager.dart';
import 'platform_support.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/tts.dart';
import 'theme.dart';
import 'tts_server_page.dart';

/// Install and inspect the local AI engine: llama.cpp's server binary plus one
/// small GGUF model, both plain files in one directory. Everything is also
/// installable by hand — the download buttons are convenience, not magic.
class AiPage extends StatefulWidget {
  final ReadingSettings settings;

  const AiPage({super.key, required this.settings});

  @override
  State<AiPage> createState() => _AiPageState();
}

/// sherpa-onnx: the read-aloud engine, run as a child process. Its Chinese
/// front-end (jieba + rule FSTs) is what Piper lacked. The Windows build is one
/// .tar.bz2 — the binary + onnxruntime.dll and friends. `ghfast.top` is a GitHub
/// proxy for when the direct release host is slow from the mainland.
const _sherpaVer = 'v1.13.4';
const _engineFile = 'sherpa-onnx-$_sherpaVer-win-x64-shared-MD-Release.tar.bz2';
const _engineUrls = [
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/$_sherpaVer/$_engineFile',
  'https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/$_sherpaVer/$_engineFile',
];

/// The Chinese voice: Kokoro, multilingual, converted for sherpa-onnx. One
/// .tar.bz2 with the onnx model, the packed speaker embeddings (voices.bin —
/// eight Chinese speakers, four male / four female, pick via --sid at synth),
/// tokens, espeak-ng data, the Chinese+English lexicons, and the date/number
/// rule FSTs. A male narration voice reads far closer to "telling a story" than
/// MeloTTS's single conversational voice did.
const _voiceFile = 'kokoro-multi-lang-v1_0.tar.bz2';
const _voiceUrls = [
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$_voiceFile',
  'https://ghfast.top/https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$_voiceFile',
];

class _AiPageState extends State<AiPage> {
  static const _models = ModelManager();
  AiStatus? _status;
  TtsStatus? _ts;
  ManagedModelState? _chatModel;
  ManagedModelState? _embeddingModel;
  double? _engineProgress;
  double? _modelProgress;
  double? _embedProgress;
  double? _piperProgress;
  double? _voiceProgress;
  String? _engineError;
  String? _modelError;
  String? _embedError;
  String? _modelStage;
  String? _embedStage;
  String? _piperError;
  String? _voiceError;
  int _chatPendingBytes = 0;
  int _embedPendingBytes = 0;
  ResumableFileDownload? _chatTransfer;
  ResumableFileDownload? _embedTransfer;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // The engine starts and dies outside this page (enrichment runs, crashes,
    // orphans); a status painted once at initState quietly turns into a lie.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _chatTransfer?.pause();
    _embedTransfer?.pause();
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await aiStatus();
    final ts = await ttsStatus();
    final states = await Future.wait([
      _models.inspect(s.dir, chatModelPackage),
      _models.inspect(s.dir, embeddingModelPackage),
    ]);
    final pending = await Future.wait([
      _models.pendingDownloadBytes(s.dir, chatModelPackage),
      _models.pendingDownloadBytes(s.dir, embeddingModelPackage),
    ]);
    if (mounted) {
      setState(() {
        _status = s;
        _ts = ts;
        _chatModel = states[0];
        _embeddingModel = states[1];
        _chatPendingBytes = pending[0];
        _embedPendingBytes = pending[1];
      });
    }
  }

  /// Stream a URL to a file, reporting progress. Downloads to `.part` and
  /// renames on success so a torn download never masquerades as an install.
  Future<void> _fetch(
    String url,
    File out,
    void Function(double?) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final part = File('${out.path}.part');
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'novel-reader');
      final resp = await req.close();
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final total = resp.contentLength;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          got += chunk.length;
          onProgress(total > 0 ? got / total : null);
        }
      } finally {
        await sink.close();
      }
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> _downloadEngine() async {
    setState(() {
      _engineProgress = 0;
      _engineError = null;
    });
    try {
      // Release assets carry the build number in the name, so ask the API
      // which zip is current instead of hardcoding a version.
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      String? url;
      try {
        final req = await client.getUrl(
          Uri.parse(
            'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest',
          ),
        );
        req.headers.set('User-Agent', 'novel-reader');
        final resp = await req.close();
        if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
        final release = jsonDecode(await resp.transform(utf8.decoder).join());
        // Vulkan build first: it drives NVIDIA/AMD/Intel GPUs alike and falls
        // back to CPU at runtime when no usable GPU exists. Pure-CPU zip is
        // the safety net if a release ever ships without a Vulkan asset.
        String? cpuUrl;
        for (final a in (release['assets'] as List)) {
          final name = (a['name'] as String).toLowerCase();
          if (!name.endsWith('.zip') ||
              !name.contains('win') ||
              !name.contains('x64')) {
            continue;
          }
          if (name.contains('vulkan')) {
            url = a['browser_download_url'] as String;
            break;
          }
          if (name.contains('cpu') || name.contains('avx2')) {
            cpuUrl ??= a['browser_download_url'] as String;
          }
        }
        url ??= cpuUrl;
      } finally {
        client.close();
      }
      if (url == null) throw '在发布页没找到 Windows 版本';

      final dir = _status!.dir;
      final zip = File('$dir${Platform.pathSeparator}engine.zip');
      await _fetch(url, zip, (p) => setState(() => _engineProgress = p));

      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final f in archive) {
        if (!f.isFile) continue;
        final out = File('$dir${Platform.pathSeparator}${f.name}');
        await out.create(recursive: true);
        await out.writeAsBytes(f.content as List<int>);
      }
      await zip.delete();
    } catch (e) {
      _engineError = '$e';
    } finally {
      _engineProgress = null;
      await _refresh();
    }
  }

  Future<void> _downloadModel() => _downloadManagedModel(
    chatModelPackage,
    onProgress: (value) => _modelProgress = value,
    onError: (value) => _modelError = value,
    onStage: (value) => _modelStage = value,
  );

  Future<void> _downloadEmbed() => _downloadManagedModel(
    embeddingModelPackage,
    onProgress: (value) => _embedProgress = value,
    onError: (value) => _embedError = value,
    onStage: (value) => _embedStage = value,
  );

  Future<void> _downloadManagedModel(
    ManagedModelPackage package, {
    required void Function(double?) onProgress,
    required void Function(String?) onError,
    required void Function(String?) onStage,
  }) async {
    if (_transferFor(package) != null) return;
    final transfer = ResumableFileDownload();
    _setTransfer(package, transfer);
    setState(() {
      onProgress(0);
      onError(null);
      onStage('正在下载');
    });
    final directory = _status!.dir;
    final out = _models.downloadTarget(directory, package);
    try {
      await transfer.downloadFirst(
        package.urls,
        out,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(
            () =>
                onProgress(total == null || total <= 0 ? 0 : received / total),
          );
        },
      );
      if (mounted) setState(() => onStage('正在校验并切换'));
      await _models.installDownloaded(
        directory: directory,
        package: package,
        download: out,
        stopEngine: stopAi,
      );
    } on DownloadStopped catch (stopped) {
      if (mounted) {
        setState(() {
          onError(null);
          onStage(stopped.kind == DownloadStopKind.paused ? '已暂停，可继续' : null);
        });
      }
    } catch (e) {
      // A completed but invalid file cannot be resumed. Network failures occur
      // before this rename, so their .part bytes remain available for retry.
      if (await out.exists()) await out.delete();
      if (mounted) {
        setState(() {
          onError('$e');
          onStage('下载中断，可继续');
        });
      }
    } finally {
      _setTransfer(package, null);
      if (mounted) {
        setState(() {
          onProgress(null);
        });
      }
      await _refresh();
    }
  }

  ResumableFileDownload? _transferFor(ManagedModelPackage package) =>
      package.role == ManagedModelRole.chat ? _chatTransfer : _embedTransfer;

  void _setTransfer(
    ManagedModelPackage package,
    ResumableFileDownload? transfer,
  ) {
    if (package.role == ManagedModelRole.chat) {
      _chatTransfer = transfer;
    } else {
      _embedTransfer = transfer;
    }
  }

  void _pauseModelDownload(ManagedModelPackage package) {
    _transferFor(package)?.pause();
  }

  Future<void> _cancelModelDownload(
    ManagedModelPackage package, {
    required void Function(double?) onProgress,
    required void Function(String?) onError,
    required void Function(String?) onStage,
  }) async {
    final directory = _status!.dir;
    final target = _models.downloadTarget(directory, package);
    final transfer = _transferFor(package);
    if (transfer == null) {
      await _models.discardPendingDownload(directory, package);
    } else {
      await transfer.cancel(target);
    }
    if (mounted) {
      setState(() {
        onProgress(null);
        onError(null);
        onStage(null);
      });
    }
    await _refresh();
  }

  String _withPending(String subtitle, int bytes) =>
      bytes <= 0 ? subtitle : '$subtitle · 已下载 ${_size(bytes)}，可继续';

  /// Try each mirror in turn for a single file.
  Future<void> _fetchFirst(
    List<String> urls,
    File out,
    void Function(double?) onProgress,
  ) async {
    Object? lastError;
    for (final url in urls) {
      try {
        await _fetch(url, out, onProgress);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? '下载失败';
  }

  /// A .tar.bz2 (the sherpa engine, or the voice), streamed to a temp file then
  /// unpacked by Rust into the tts dir — keeping the archive's own top folder.
  Future<void> _downloadTarBz2(
    String name,
    List<String> urls,
    void Function(double?) onProgress,
    void Function(String?) onError,
    VoidCallback onDone,
  ) async {
    setState(() {
      onProgress(0);
      onError(null);
    });
    final dir = _ts!.dir;
    final archive = File('$dir${Platform.pathSeparator}_$name.tar.bz2');
    try {
      await _fetchFirst(urls, archive, onProgress);
      await extractTarBz2(archivePath: archive.path, destDir: dir);
    } catch (e) {
      onError('$e');
    } finally {
      if (await archive.exists()) await archive.delete();
      onDone();
      await _refresh();
    }
  }

  Future<void> _downloadTtsEngine() => _downloadTarBz2(
    'engine',
    _engineUrls,
    (p) => setState(() => _piperProgress = p),
    (e) => _piperError = e,
    () => setState(() => _piperProgress = null),
  );

  Future<void> _downloadTtsVoice() => _downloadTarBz2(
    'voice',
    _voiceUrls,
    (p) => setState(() => _voiceProgress = p),
    (e) => _voiceError = e,
    () => setState(() => _voiceProgress = null),
  );

  String _modelSubtitle(
    ManagedModelPackage package,
    ManagedModelState? state,
    String? detectedName,
    int bytes,
  ) {
    if (state?.installed != true && detectedName == null) {
      return package.role == ManagedModelRole.chat
          ? '约 640 MB，下载后自动校验'
          : '约 48 MB，下载后自动校验';
    }
    final version = state?.activeVersion ?? '现有版本';
    final verified = state?.isVerifiedCurrent(package) == true
        ? '已校验'
        : '未记录校验';
    final rollback = state?.canRollback == true ? ' · 可恢复旧版' : '';
    return '$version · $verified · ${_size(bytes)}$rollback';
  }

  Future<void> _rollbackModel(ManagedModelPackage package, String label) async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.background,
        title: Text('恢复旧版$label？'),
        content: const Text('当前版本会被保留，之后仍可再次切换回来。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _models.rollback(
        directory: _status!.dir,
        package: package,
        stopEngine: stopAi,
      );
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$label已切换')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final s = _status;
    final compact =
        AppPlatformSupport.layoutForWidth(MediaQuery.sizeOf(context).width) ==
        AppLayoutClass.compact;
    final chatInstalled = _chatModel?.installed ?? s?.model != null;
    final embeddingInstalled =
        _embeddingModel?.installed ?? s?.embedModel != null;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('AI 引擎', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: s == null
          ? Center(child: Bloom(color: t.muted, size: 34))
          : SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: EdgeInsets.all(compact ? 16 : 20),
                    children: [
                      Text(
                        '本地运行，不上传文本。模型按需下载。建议 8 GB 内存。',
                        style: TextStyle(
                          color: t.muted,
                          fontSize: 13,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.tune, size: 20, color: t.muted),
                        title: Text(
                          'AI 运行与设备',
                          style: TextStyle(color: t.text, fontSize: 14),
                        ),
                        subtitle: Text(
                          '速度、电量与后台',
                          style: TextStyle(color: t.muted, fontSize: 12),
                        ),
                        trailing: Icon(Icons.chevron_right, color: t.muted),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AiRuntimePage(settings: widget.settings),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (AppPlatformSupport.usesExternalAiProcess)
                        _item(
                          t,
                          ok: s.engine,
                          title: '推理引擎 · llama.cpp',
                          subtitle: s.engine
                              ? '已安装 · ${_size(s.engineBytes)}'
                              : '约 30–90 MB，从 GitHub 下载',
                          progress: _engineProgress,
                          error: _engineError,
                          onDownload: _downloadEngine,
                          onDelete: s.engine
                              ? () => _delete('推理引擎', deleteEngine)
                              : null,
                        ),
                      _item(
                        t,
                        ok: chatInstalled,
                        title: '模型 · Qwen3 0.6B (Q8) — 摘要 / 氛围',
                        subtitle: _withPending(
                          _modelSubtitle(
                            chatModelPackage,
                            _chatModel,
                            s.model,
                            s.modelBytes,
                          ),
                          _chatPendingBytes,
                        ),
                        progress: _modelProgress,
                        progressText: _modelStage,
                        error: _modelError,
                        onDownload: _downloadModel,
                        downloadLabel: _chatPendingBytes > 0 ? '继续' : '下载',
                        hasPendingDownload: _chatPendingBytes > 0,
                        onPause: () => _pauseModelDownload(chatModelPackage),
                        onCancel: () => _cancelModelDownload(
                          chatModelPackage,
                          onProgress: (value) => _modelProgress = value,
                          onError: (value) => _modelError = value,
                          onStage: (value) => _modelStage = value,
                        ),
                        onReinstall: chatInstalled ? _downloadModel : null,
                        onRollback: _chatModel?.canRollback == true
                            ? () => _rollbackModel(chatModelPackage, '摘要模型')
                            : null,
                        onDelete: chatInstalled
                            ? () => _delete(
                                '摘要模型',
                                () => _models.deleteInstalled(
                                  directory: s.dir,
                                  package: chatModelPackage,
                                  stopEngine: stopAi,
                                ),
                              )
                            : null,
                      ),
                      _item(
                        t,
                        ok: embeddingInstalled,
                        title: '嵌入模型 · BGE small 中文 — 语义搜索',
                        subtitle: _withPending(
                          _modelSubtitle(
                            embeddingModelPackage,
                            _embeddingModel,
                            s.embedModel,
                            s.embedBytes,
                          ),
                          _embedPendingBytes,
                        ),
                        progress: _embedProgress,
                        progressText: _embedStage,
                        error: _embedError,
                        onDownload: _downloadEmbed,
                        downloadLabel: _embedPendingBytes > 0 ? '继续' : '下载',
                        hasPendingDownload: _embedPendingBytes > 0,
                        onPause: () =>
                            _pauseModelDownload(embeddingModelPackage),
                        onCancel: () => _cancelModelDownload(
                          embeddingModelPackage,
                          onProgress: (value) => _embedProgress = value,
                          onError: (value) => _embedError = value,
                          onStage: (value) => _embedStage = value,
                        ),
                        onReinstall: embeddingInstalled ? _downloadEmbed : null,
                        onRollback: _embeddingModel?.canRollback == true
                            ? () =>
                                  _rollbackModel(embeddingModelPackage, '嵌入模型')
                            : null,
                        onDelete: embeddingInstalled
                            ? () => _delete(
                                '嵌入模型',
                                () => _models.deleteInstalled(
                                  directory: s.dir,
                                  package: embeddingModelPackage,
                                  stopEngine: stopAi,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.storage_outlined,
                          size: 20,
                          color: t.muted,
                        ),
                        title: Text(
                          'AI 生成数据',
                          style: TextStyle(color: t.text, fontSize: 14),
                        ),
                        subtitle: Text(
                          '摘要、氛围与索引',
                          style: TextStyle(color: t.muted, fontSize: 12),
                        ),
                        trailing: Icon(Icons.chevron_right, color: t.muted),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AiCachePage(settings: widget.settings),
                          ),
                        ),
                      ),
                      if (AppPlatformSupport.isDesktop) ...[
                        const Divider(height: 32),
                        // The bundled engine is honestly labelled as the fallback it is:
                        // it works with zero setup and sounds like it. The good voices
                        // are one page away, on a machine that can actually run them.
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.headset_mic_outlined,
                            size: 20,
                            color: t.muted,
                          ),
                          title: Text(
                            '听书服务',
                            style: TextStyle(color: t.text, fontSize: 14),
                          ),
                          trailing: Icon(Icons.chevron_right, color: t.muted),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  TtsServerPage(settings: widget.settings),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _item(
                          t,
                          ok: _ts?.engine ?? false,
                          title: '朗读引擎 · sherpa-onnx',
                          subtitle: (_ts?.engine ?? false)
                              ? '已安装 · ${_size(_ts!.engineBytes)}'
                              : '约 20 MB，从 GitHub 下载',
                          progress: _piperProgress,
                          error: _piperError,
                          onDownload: _downloadTtsEngine,
                          onDelete: (_ts?.engine ?? false)
                              ? () => _delete('朗读引擎', deleteTtsEngine)
                              : null,
                        ),
                        _item(
                          t,
                          ok: _ts?.voice != null,
                          title: '中文语音 · Kokoro（8 音色，含男声旁白）',
                          subtitle: _ts?.voice == null
                              ? '约 340 MB，从 GitHub 下载'
                              : '${_ts!.voice} · ${_size(_ts!.voiceBytes)}',
                          progress: _voiceProgress,
                          error: _voiceError,
                          onDownload: _downloadTtsVoice,
                          onDelete: _ts?.voice != null
                              ? () => _delete('中文语音', deleteTtsVoice)
                              : null,
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            s.running ? Icons.circle : Icons.circle_outlined,
                            size: 10,
                            color: s.running
                                ? const Color(0xFF2E7D32)
                                : t.muted,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            s.running ? '引擎运行中' : '引擎未运行',
                            style: TextStyle(color: t.muted, fontSize: 12),
                          ),
                          const Spacer(),
                          if (s.running)
                            TextButton(
                              onPressed: () async {
                                await stopAi();
                                await _refresh();
                              },
                              child: const Text(
                                '停止',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                      const Divider(height: 32),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              s.dir,
                              style: TextStyle(color: t.muted, fontSize: 11),
                            ),
                          ),
                          if (Platform.isWindows)
                            TextButton(
                              onPressed: () => Process.run('explorer', [s.dir]),
                              child: const Text(
                                '打开目录',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// Deleting is the user's right, not a trap: say plainly what it costs, then
  /// do it. Everything here is re-downloadable.
  Future<void> _delete(String what, Future<void> Function() go) async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.background,
        title: Text('删除$what？', style: TextStyle(color: t.text, fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await go();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
    await _refresh();
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.round()} MB';
  }

  Widget _item(
    ReadingTheme t, {
    required bool ok,
    required String title,
    required String subtitle,
    required double? progress,
    String? progressText,
    required String? error,
    required VoidCallback onDownload,
    String downloadLabel = '下载',
    bool hasPendingDownload = false,
    VoidCallback? onPause,
    VoidCallback? onCancel,
    VoidCallback? onDelete,
    VoidCallback? onReinstall,
    VoidCallback? onRollback,
  }) {
    final progressLabel = progressText == '正在下载' && progress != null
        ? progress == 0
              ? '正在连接…'
              : '正在下载 · ${(progress * 100).round()}%'
        : progressText ??
              (progress == 0
                  ? '正在连接…'
                  : progress == null
                  ? null
                  : '${(progress * 100).round()}%');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The flower stands in for the icon while the bytes are coming
              // down, so the row itself is alive and not just the bar under it.
              if (progress != null)
                Bloom(color: t.muted, size: 20)
              else
                Icon(
                  ok ? Icons.check_circle : Icons.download_outlined,
                  size: 20,
                  color: ok ? const Color(0xFF2E7D32) : t.muted,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: t.text, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(color: t.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (!ok && progress == null) ...[
                FilledButton.tonal(
                  onPressed: onDownload,
                  child: Text(downloadLabel),
                ),
                if (hasPendingDownload && onCancel != null)
                  IconButton(
                    tooltip: '取消下载',
                    onPressed: onCancel,
                    icon: const Icon(Icons.close),
                  ),
              ],
              if (ok &&
                  progress == null &&
                  (onReinstall != null || onRollback != null))
                PopupMenuButton<String>(
                  tooltip: '管理版本',
                  icon: Icon(Icons.more_horiz, size: 20, color: t.muted),
                  onSelected: (value) {
                    switch (value) {
                      case 'reinstall':
                        onReinstall?.call();
                        return;
                      case 'rollback':
                        onRollback?.call();
                        return;
                      case 'delete':
                        onDelete?.call();
                        return;
                      case 'cancelDownload':
                        onCancel?.call();
                        return;
                    }
                  },
                  itemBuilder: (_) => [
                    if (onReinstall != null)
                      PopupMenuItem(
                        value: 'reinstall',
                        child: Text(hasPendingDownload ? '继续下载' : '重新下载并校验'),
                      ),
                    if (hasPendingDownload && onCancel != null)
                      const PopupMenuItem(
                        value: 'cancelDownload',
                        child: Text('取消未完成下载'),
                      ),
                    if (onRollback != null)
                      const PopupMenuItem(
                        value: 'rollback',
                        child: Text('恢复旧版'),
                      ),
                    if (onDelete != null)
                      const PopupMenuItem(value: 'delete', child: Text('删除模型')),
                  ],
                )
              else if (ok && progress == null && onDelete != null)
                IconButton(
                  tooltip: '删除',
                  icon: Icon(Icons.delete_outline, size: 20, color: t.muted),
                  onPressed: onDelete,
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                // 0 means the request is out but no bytes have landed: the
                // server has not told us the size yet, so the bar sweeps rather
                // than claiming 0%.
                value: progress == 0 ? null : progress,
                minHeight: 4,
                backgroundColor: t.muted.withValues(alpha: 0.12),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              progressLabel ?? '',
              style: TextStyle(color: t.muted, fontSize: 11),
            ),
            if (onPause != null || onCancel != null)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 4,
                  children: [
                    if (onPause != null)
                      TextButton(onPressed: onPause, child: const Text('暂停')),
                    if (onCancel != null)
                      TextButton(
                        onPressed: onCancel,
                        child: const Text('取消下载'),
                      ),
                  ],
                ),
              ),
          ],
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              '下载失败：$error',
              style: const TextStyle(color: Color(0xFFB3574D), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
