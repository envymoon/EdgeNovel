import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'font_manager.dart';
import 'font_page.dart';
import 'theme.dart';

class AppearancePage extends StatelessWidget {
  final ReadingSettings settings;
  const AppearancePage({super.key, required this.settings});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) {
      final t = settings.theme;
      final custom =
          settings.interfaceFontFamily.isNotEmpty &&
          !settings.interfaceFontFamily.startsWith('system:');
      return Scaffold(
        backgroundColor: t.background,
        appBar: AppBar(
          title: const Text('外观'),
          backgroundColor: t.topBar,
          surfaceTintColor: Colors.transparent,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text('界面字体'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey(settings.interfaceFontFamily),
                  initialValue: custom
                      ? 'custom'
                      : settings.interfaceFontFamily,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('微软雅黑（默认）')),
                    const DropdownMenuItem(
                      value: 'system:SimSun',
                      child: Text('宋体'),
                    ),
                    const DropdownMenuItem(
                      value: 'system:KaiTi',
                      child: Text('楷体'),
                    ),
                    const DropdownMenuItem(
                      value: 'system:Segoe UI',
                      child: Text('Segoe UI'),
                    ),
                    if (custom)
                      DropdownMenuItem(
                        value: 'custom',
                        child: Text(
                          FontManager.instance.displayNameForFamily(
                            settings.interfaceFontFamily,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null && value != 'custom') {
                      settings.setInterfaceFontFamily(value);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.font_download_outlined),
                  title: const Text('下载或导入界面字体'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          FontPage(settings: settings, forInterface: true),
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('统一界面字重'),
                  subtitle: const Text('菜单和标题使用常规粗细'),
                  value: settings.uniformInterfaceWeight,
                  onChanged: settings.setUniformInterfaceWeight,
                ),
                const SizedBox(height: 24),
                const Text('主题色'),
                const SizedBox(height: 12),
                ThemeSwatches(settings: settings),
                const SizedBox(height: 24),
                const Text('强调色'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (var i = 0; i < interfaceAccents.length; i++)
                      Semantics(
                        button: true,
                        selected: i == settings.accentIndex,
                        label: context.tr(['暖棕', '青绿', '雾蓝', '梅紫', '陶红'][i]),
                        child: InkWell(
                          onTap: () => settings.setAccent(i),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: interfaceAccents[i],
                              shape: BoxShape.circle,
                            ),
                            child: i == settings.accentIndex
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: t.outline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '故事从这一页开始',
                        style: TextStyle(
                          color: t.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '界面与阅读字体分别设置',
                        style: TextStyle(color: t.muted, fontSize: 14),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Text(
                          '预览',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
