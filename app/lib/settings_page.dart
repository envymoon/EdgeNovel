import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'ai_page.dart';
import 'ai_runtime_page.dart';
import 'font_page.dart';
import 'platform_support.dart';
import 'source_manager_page.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// Lightweight entry points for app-wide preferences and data controls.
///
/// This page deliberately performs no database or AI status query while
/// opening. Expensive, feature-specific data is loaded only after the reader
/// enters that feature's own management page.
class SettingsPage extends StatelessWidget {
  final ReadingSettings settings;

  const SettingsPage({super.key, required this.settings});

  /// Keep in step with `version:` in pubspec.yaml.
  static const appVersion = '1.0.0';

  Future<bool> _confirmClearHistory(
    BuildContext context,
    ReadingTheme t,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.background,
        title: Text('清空全部阅读记录？', style: TextStyle(color: t.text, fontSize: 16)),
        content: Text(
          '阅读时长、连续阅读天数和阅读画像所依据的数据都会被删除，且无法恢复。'
          '小说文件与阅读进度不会受影响。',
          style: TextStyle(color: t.muted, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _clearHistory(BuildContext context, ReadingTheme t) async {
    if (!await _confirmClearHistory(context, t) || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await clearReadingEvents();
      messenger.showSnackBar(const SnackBar(content: Text('阅读记录已清空')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('清空失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    final compact =
        AppPlatformSupport.layoutForWidth(MediaQuery.sizeOf(context).width) ==
        AppLayoutClass.compact;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('设置', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 24,
                8,
                compact ? 16 : 24,
                40,
              ),
              children: [
                _sectionLabel(t, '阅读'),
                _group(
                  t,
                  children: [
                    _entry(
                      t,
                      icon: Icons.language,
                      title: '界面语言',
                      subtitle: settings.language == AppLanguage.english
                          ? 'English'
                          : '简体中文',
                      onTap: () => _chooseLanguage(context, t),
                    ),
                    _entry(
                      t,
                      icon: Icons.tune,
                      title: 'AI 运行与设备',
                      subtitle: '速度、电量与后台',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AiRuntimePage(settings: settings),
                        ),
                      ),
                    ),
                    _entry(
                      t,
                      icon: Icons.font_download_outlined,
                      title: '阅读字体',
                      subtitle: '下载或导入字体',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FontPage(settings: settings),
                        ),
                      ),
                    ),
                    _entry(
                      t,
                      icon: Icons.dns_outlined,
                      title: '书源管理',
                      subtitle: '在线书源',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SourceManagerPage(settings: settings),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _sectionLabel(t, '本地 AI'),
                _group(
                  t,
                  children: [
                    _entry(
                      t,
                      icon: Icons.auto_awesome_outlined,
                      title: '模型、引擎与生成数据',
                      subtitle: '模型与生成数据',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AiPage(settings: settings),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _sectionLabel(t, '数据与隐私'),
                _group(
                  t,
                  children: [
                    _entry(
                      t,
                      icon: Icons.history_toggle_off,
                      title: '清空阅读记录',
                      subtitle: '保留书籍',
                      destructive: true,
                      showChevron: false,
                      onTap: () => _clearHistory(context, t),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _sectionLabel(t, '关于'),
                _group(
                  t,
                  children: [
                    _entry(
                      t,
                      icon: Icons.info_outline,
                      title: '版本',
                      trailing: appVersion,
                      showChevron: false,
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

  Widget _sectionLabel(ReadingTheme t, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      title,
      style: TextStyle(
        color: t.muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Future<void> _chooseLanguage(BuildContext context, ReadingTheme t) async {
    final selected = await showDialog<AppLanguage>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        backgroundColor: t.background,
        title: Text('界面语言', style: TextStyle(color: t.text, fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(dialogContext, AppLanguage.simplifiedChinese),
            child: Row(
              children: [
                Expanded(
                  child: Text('简体中文', style: TextStyle(color: t.text)),
                ),
                if (settings.language == AppLanguage.simplifiedChinese)
                  Icon(Icons.check, color: t.text, size: 18),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, AppLanguage.english),
            child: Row(
              children: [
                Expanded(
                  child: Text('English', style: TextStyle(color: t.text)),
                ),
                if (settings.language == AppLanguage.english)
                  Icon(Icons.check, color: t.text, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null) settings.setLanguage(selected);
  }

  Widget _group(ReadingTheme t, {required List<Widget> children}) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      border: Border.all(color: t.muted.withValues(alpha: 0.16)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(children: children),
  );

  Widget _entry(
    ReadingTheme t, {
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    VoidCallback? onTap,
    bool destructive = false,
    bool showChevron = true,
  }) {
    final color = destructive ? const Color(0xFFB3574D) : t.text;
    return ListTile(
      minTileHeight: 62,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      leading: Icon(icon, size: 20, color: destructive ? color : t.muted),
      title: Text(title, style: TextStyle(color: color, fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.35),
            ),
      trailing: trailing != null
          ? Text(trailing, style: TextStyle(color: t.muted, fontSize: 12))
          : showChevron
          ? Icon(Icons.chevron_right, color: t.muted, size: 20)
          : null,
      onTap: onTap,
    );
  }
}
