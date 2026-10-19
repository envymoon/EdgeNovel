import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'theme.dart';

/// Where 意见反馈 goes: a group robot's webhook (飞书 / 企业微信 / 钉钉).
/// Empty until there is one; the page shows, and sending waits for it.
const feedbackWebhook = '';

/// The request body the robot at [url] takes for [text]: 飞书 and Lark one
/// shape, 企业微信 and 钉钉 the other.
@visibleForTesting
Map<String, Object> feedbackBody(String url, String text) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.contains('feishu') || host.contains('larksuite')) {
    return {
      'msg_type': 'text',
      'content': {'text': text},
    };
  }
  return {
    'msgtype': 'text',
    'text': {'content': text},
  };
}

/// The message: what was written, who to answer if they said, and the
/// version and system it came from.
@visibleForTesting
String feedbackText({
  required String body,
  required String contact,
  required String version,
  required String system,
}) => [
  '挚阅反馈 · $version · $system',
  if (contact.trim().isNotEmpty) '联系：${contact.trim()}',
  '',
  body.trim(),
].join('\n');

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({
    super.key,
    required this.settings,
    required this.version,
    this.webhook = feedbackWebhook,
  });

  final ReadingSettings settings;
  final String version;
  final String webhook;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _body = TextEditingController();
  final _contact = TextEditingController();
  bool _sending = false;
  String? _status;

  @override
  void dispose() {
    _body.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final url = widget.webhook;
    if (url.isEmpty || _body.text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _status = null;
    });
    final text = feedbackText(
      body: _body.text,
      contact: _contact.text,
      version: widget.version,
      system: Platform.operatingSystem,
    );
    String? why;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(feedbackBody(url, text))));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final answer = await utf8.decodeStream(res);
      if (res.statusCode != 200) {
        why = 'HTTP ${res.statusCode}';
      } else {
        // The robots answer 200 either way, and say in the body.
        try {
          final j = jsonDecode(answer) as Map<String, dynamic>;
          final code = j['code'] ?? j['errcode'] ?? j['StatusCode'] ?? 0;
          if (code != 0) why = '${j['msg'] ?? j['errmsg'] ?? code}';
        } catch (_) {}
      }
    } catch (e) {
      why = '$e';
    } finally {
      client.close(force: true);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _status = why == null ? '已发送，谢谢' : '发送失败：$why';
      if (why == null) {
        _body.clear();
        _contact.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final open = widget.webhook.isNotEmpty;
    InputDecoration field(String hint) => InputDecoration(
      hintText: context.tr(hint),
      hintStyle: TextStyle(color: t.muted, fontSize: 14),
      filled: true,
      fillColor: t.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.outline),
      ),
    );
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('意见反馈', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          TextField(
            controller: _body,
            minLines: 6,
            maxLines: 12,
            maxLength: 2000,
            style: TextStyle(color: t.text, fontSize: 14),
            decoration: field('想说的话'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _contact,
            maxLength: 100,
            style: TextStyle(color: t.text, fontSize: 14),
            decoration: field('联系方式（选填）'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: open && !_sending && _body.text.trim().isNotEmpty
                ? _send
                : null,
            child: Text(_sending ? '发送中…' : '发送'),
          ),
          if (!open || _status != null) ...[
            const SizedBox(height: 12),
            Text(
              open ? _status! : '反馈通道暂未开通',
              style: TextStyle(color: t.muted, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}
