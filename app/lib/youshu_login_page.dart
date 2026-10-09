import 'dart:collection';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_localizations.dart';
import 'theme.dart';
import 'youshu_service.dart';

class YoushuLoginPage extends StatefulWidget {
  final ReadingSettings settings;
  const YoushuLoginPage({super.key, required this.settings});
  @override
  State<YoushuLoginPage> createState() => _YoushuLoginPageState();
}

class _YoushuLoginPageState extends State<YoushuLoginPage> {
  final service = YoushuService.instance;
  WebViewEnvironment? _environment;
  InAppWebViewController? _controller;
  bool _ready = false;
  bool _checking = false;
  String? _error;
  int _progress = 0;
  String _host = 'www.youshu.me';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final environment = await service.environment();
      if (mounted) {
        setState(() {
          _environment = environment;
          _ready = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _verify() async {
    final controller = _controller;
    if (controller == null || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      if (!isYoushuUrl(await controller.getUrl())) {
        throw StateError('请返回优书网登录页面');
      }
      // Inspect only the current page: login must not fetch a sample book.
      final response = await controller
          .callAsyncJavaScript(
            functionBody: '''
        return !document.querySelector('form[name="frmlogin"]') &&
          !document.querySelector('form#t_frmlogin') &&
          (!!document.querySelector(
              'a[href*="logout"], a[href*="loginout"], a[href*="action=logout"]') ||
            Array.from(document.querySelectorAll('a')).some((link) =>
              /退出|注销/.test(link.textContent || '')));
      ''',
          )
          .timeout(const Duration(seconds: 15));
      if (response?.value != true) {
        throw StateError('尚未验证登录，请在网页中完成登录和验证码后再试');
      }
      await service.setEnabled(true);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = '尚未验证登录，请完成网页登录后再试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _checking = true);
    try {
      await service.clearLogin();
      if (mounted) Navigator.pop(context, false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = '已暂停更新，但清除登录状态失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('登录优书网'),
      actions: [
        IconButton(
          tooltip: context.tr('刷新'),
          icon: const Icon(Icons.refresh),
          onPressed: () => _controller?.reload(),
        ),
        TextButton(
          onPressed: _checking ? null : _disconnect,
          child: const Text('退出登录'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.lock_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text('https://$_host', translate: false)),
                FilledButton(
                  onPressed: _ready && !_checking ? _verify : null,
                  child: Text(_checking ? '验证中…' : '完成登录'),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '默认勾选下次自动登录，登录状态保存在本机。网站使登录失效时需重新登录。仅主动打开书评或手动更新时查询该书。',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          if (!_ready && _error != null)
            TextButton(onPressed: _prepare, child: const Text('重试')),
          if (_ready && _progress < 100)
            LinearProgressIndicator(value: _progress / 100),
          Expanded(
            child: !_ready
                ? (_error == null
                      ? const Center(child: CircularProgressIndicator())
                      : const SizedBox.shrink())
                : InAppWebView(
                    webViewEnvironment: _environment,
                    initialUserScripts: UnmodifiableListView([
                      UserScript(
                        source: '''
                          document.querySelectorAll('input[name="usecookie"]').forEach(
                            (input) => { input.checked = true; });
                        ''',
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                      ),
                    ]),
                    initialUrlRequest: URLRequest(
                      url: WebUri('https://www.youshu.me/login.php'),
                    ),
                    initialSettings: InAppWebViewSettings(
                      useShouldOverrideUrlLoading: true,
                      mediaPlaybackRequiresUserGesture: true,
                      supportMultipleWindows: true,
                      javaScriptCanOpenWindowsAutomatically: false,
                    ),
                    onWebViewCreated: (controller) => _controller = controller,
                    onProgressChanged: (_, value) {
                      if (mounted) setState(() => _progress = value);
                    },
                    onLoadStart: (_, url) {
                      if (mounted && isYoushuUrl(url)) {
                        setState(() {
                          _host = url!.host;
                          _error = null;
                        });
                      }
                    },
                    shouldOverrideUrlLoading: (_, action) async {
                      if (action.isForMainFrame &&
                          !isYoushuUrl(action.request.url)) {
                        if (mounted) setState(() => _error = '登录窗口仅打开优书网链接');
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.ALLOW;
                    },
                    onCreateWindow: (_, _) async => false,
                    onPermissionRequest: (_, request) async =>
                        PermissionResponse(
                          resources: request.resources,
                          action: PermissionResponseAction.DENY,
                        ),
                    onReceivedError: (_, request, _) {
                      if (mounted && request.isForMainFrame == true) {
                        setState(() => _error = '网页加载失败，请刷新重试');
                      }
                    },
                    onReceivedHttpError: (_, request, _) {
                      if (mounted && request.isForMainFrame == true) {
                        setState(() => _error = '优书网暂时无法连接，请稍后重试');
                      }
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
