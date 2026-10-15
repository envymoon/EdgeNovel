import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'background_task_bar.dart';
import 'bloom.dart';
import 'platform_services.dart';
import 'theme.dart';
import 'tts_prepare.dart';
import 'tts_remote.dart';
import 'tts_text.dart';

/// Where read-aloud gets its voice from: this machine's own engine, or a
/// server the user runs elsewhere — and which voice, at what pace.
class TtsServerPage extends StatefulWidget {
  final ReadingSettings settings;
  const TtsServerPage({super.key, required this.settings});

  @override
  State<TtsServerPage> createState() => _TtsServerPageState();
}

class _TtsServerPageState extends State<TtsServerPage> {
  final _client = TtsRemoteClient();

  late final _url = TextEditingController(text: widget.settings.ttsServerUrl);
  late final _key = TextEditingController(text: widget.settings.ttsServerKey);
  late final _model = TextEditingController(
    text: widget.settings.ttsServerModel,
  );
  late final _voice = TextEditingController(
    text: widget.settings.ttsServerVoice,
  );

  List<RemoteVoice> _voices = const [];
  String? _status;
  bool _testing = false;

  /// Bytes of speech prepared ahead and waiting in the cache.
  int _cached = 0;

  @override
  void initState() {
    super.initState();
    if (widget.settings.ttsServerUrl.isNotEmpty) _loadVoices();
    TtsPrepare.instance.addListener(_loadCached);
    _loadCached();
  }

  @override
  void dispose() {
    TtsPrepare.instance.removeListener(_loadCached);
    _client.close();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _voice.dispose();
    super.dispose();
  }

  void _save() => widget.settings.setTtsServer(
    url: _url.text,
    key: _key.text,
    model: _model.text,
    voice: _voice.text,
  );

  Future<void> _loadCached() async {
    int n;
    try {
      n = await AppServices.instance.localSpeech.cacheBytes();
    } catch (_) {
      n = 0;
    }
    if (mounted) setState(() => _cached = n);
  }

  Future<void> _clearCached() async {
    TtsPrepare.instance.cancel();
    try {
      await AppServices.instance.localSpeech.clearCache();
    } catch (_) {}
    await _loadCached();
  }

  Future<void> _loadVoices() async {
    final vs = await _client.voices(widget.settings.ttsServer);
    if (!mounted) return;
    setState(() => _voices = vs);
  }

  Future<void> _test() async {
    _save();
    setState(() {
      _testing = true;
      _status = null;
    });
    String msg;
    try {
      msg = await _client.ping(widget.settings.ttsServer);
    } catch (e) {
      msg = '$e';
    }
    await _loadVoices();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _status = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        foregroundColor: t.text,
        elevation: 0,
        title: const Text('听书服务'),
      ),
      body: ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.settings.ttsRemote,
              onChanged: (v) {
                _save();
                widget.settings.setTtsRemote(v);
                if (v && widget.settings.ttsServerUrl.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('先填服务端地址')));
                }
              },
              title: Text(
                '使用远程服务',
                style: TextStyle(color: t.text, fontSize: 15),
              ),
              subtitle: Text(
                widget.settings.ttsRemote ? '朗读走远程合成' : '朗读走本机',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            _field(t, _url, '服务端地址', 'http://192.168.1.8:8880'),
            _field(t, _model, '模型（可选）', ''),
            _field(t, _key, '密钥（可选）', '', obscure: true),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _testing ? null : _test,
                  child: Text(_testing ? '测试中…' : '测试连接'),
                ),
                const SizedBox(width: 12),
                if (_status != null)
                  Expanded(
                    child: Text(
                      _status!,
                      style: TextStyle(
                        color: _status!.startsWith('连接正常')
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFC62828),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 36),
            Text('音色', style: TextStyle(color: t.text, fontSize: 15)),
            const SizedBox(height: 8),
            if (widget.settings.ttsRemote) ...[
              if (_voices.isEmpty)
                _field(t, _voice, '音色名', 'zf_xiaoxiao')
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in _voices)
                      ChoiceChip(
                        label: Text(v.label),
                        selected: _voice.text == v.id,
                        onSelected: (_) {
                          setState(() => _voice.text = v.id);
                          _save();
                        },
                      ),
                  ],
                ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in localVoices)
                    ChoiceChip(
                      label: Text(v.label),
                      selected: widget.settings.ttsLocalVoice == v.id,
                      onSelected: (_) => widget.settings.setTtsLocalVoice(v.id),
                    ),
                ],
              ),
            if (!widget.settings.ttsRemote &&
                (TtsPrepare.instance.running || _cached > 0))
              _cacheRow(t),
            const SizedBox(height: 24),
            Text(
              '语速 · ${widget.settings.ttsSpeed.toStringAsFixed(2)}×',
              style: TextStyle(color: t.text, fontSize: 15),
            ),
            Slider(
              value: widget.settings.ttsSpeed,
              min: 0.6,
              max: 2.0,
              divisions: 14,
              label: '${widget.settings.ttsSpeed.toStringAsFixed(2)}×',
              onChanged: widget.settings.setTtsSpeed,
            ),
          ],
        ),
      ),
    );
  }

  /// What is prepared, how far a running job has got, and the way to stop it
  /// or let the space go.
  Widget _cacheRow(ReadingTheme t) {
    final job = TtsPrepare.instance;
    final mb = (_cached / (1 << 20)).round();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: switch (job.activity) {
        final a? => BloomProgress(
          label: describeActivity(a),
          value: a.fraction,
          detail: '已合成 · $mb MB',
          color: t.muted,
          textColor: t.text,
          trailing: TextButton(onPressed: job.cancel, child: const Text('停止')),
        ),
        null => Row(
          children: [
            Expanded(
              child: Text(
                '已合成 · $mb MB',
                style: TextStyle(color: t.muted, fontSize: 13),
              ),
            ),
            if (_cached > 0)
              TextButton(onPressed: _clearCached, child: const Text('清空')),
          ],
        ),
      },
    );
  }

  Widget _field(
    ReadingTheme t,
    TextEditingController c,
    String label,
    String hint, {
    String? help,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: c,
      obscureText: obscure,
      style: TextStyle(color: t.text, fontSize: 14),
      onChanged: (_) => _save(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: help,
        helperMaxLines: 2,
        isDense: true,
        labelStyle: TextStyle(color: t.muted),
        hintStyle: TextStyle(color: t.muted.withValues(alpha: 0.6)),
        helperStyle: TextStyle(color: t.muted, fontSize: 11),
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
