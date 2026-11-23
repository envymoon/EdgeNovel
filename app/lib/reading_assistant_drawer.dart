import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import 'app_localizations.dart';
import 'platform_support.dart';
import 'reader_state.dart';
import 'theme.dart';

class ReadingAssistantDrawer extends StatelessWidget {
  final ReaderState reader;
  final ReadingSettings settings;
  final VoidCallback onSearch;
  final VoidCallback onBookDetail;
  final VoidCallback onAppearance;
  final VoidCallback onAiRuntime;
  final VoidCallback? onEasterEggs;
  final VoidCallback? onGestureTurn;

  const ReadingAssistantDrawer({
    super.key,
    required this.reader,
    required this.settings,
    required this.onSearch,
    required this.onBookDetail,
    required this.onAppearance,
    required this.onAiRuntime,
    this.onEasterEggs,
    this.onGestureTurn,
  });

  void _run(BuildContext context, VoidCallback action) {
    Navigator.pop(context);
    Future<void>.delayed(Duration.zero, action);
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    final width = MediaQuery.sizeOf(context).width.clamp(300, 390).toDouble();
    return Drawer(
      width: width,
      backgroundColor: t.surface,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([reader, settings]),
          builder: (context, _) {
            final t = settings.theme;
            return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '阅读助手',
                            style: TextStyle(
                              color: t.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('关闭'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      color: t.muted,
                    ),
                  ],
                ),
              ),
              _section(t, '当前位置'),
              _group(
                t,
                children: [
                  _entry(
                    t,
                    icon: Icons.manage_search,
                    title: '搜索',
                    onTap: () => _run(context, onSearch),
                  ),
                  _entry(
                    t,
                    icon: Icons.menu_book_outlined,
                    title: '阅读报告',
                    onTap: () => _run(context, onBookDetail),
                  ),
                ],
              ),
              if (AppPlatformSupport.hasAiEngine) ...[
                const SizedBox(height: 18),
                _section(t, '准备阅读助手'),
                _group(
                  t,
                  children: [
                    _entry(
                      t,
                      icon: Icons.tune,
                      title: '后台处理',
                      subtitle:
                          '${reader.aiQueueState} · ${reader.aiRuntime.modeName}',
                      onTap: () => _run(context, onAiRuntime),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              _section(t, '阅读设置'),
              _group(
                t,
                children: [
                  _entry(
                    t,
                    icon: Icons.text_fields,
                    title: '阅读外观',
                    onTap: () => _run(context, onAppearance),
                  ),
                  if (onEasterEggs case final open?)
                    _entry(
                      t,
                      icon: Icons.auto_awesome_mosaic_outlined,
                      title: '彩蛋',
                      onTap: () => _run(context, open),
                    ),
                  if (onGestureTurn case final open?)
                    _entry(
                      t,
                      icon: Icons.waving_hand_outlined,
                      title: '隔空翻页',
                      onTap: () => _run(context, open),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _section(t, '护眼'),
              _group(
                t,
                children: [
                  _eyeFilterTile(t),
                  Divider(
                    height: 1,
                    indent: 46,
                    endIndent: 12,
                    color: t.muted.withValues(alpha: 0.14),
                  ),
                  _eyeReminderTile(context, t),
                ],
              ),
            ],
          );
          },
        ),
      ),
    );
  }

  Widget _eyeFilterTile(ReadingTheme t) {
    final pct = ((settings.eyeCareStrength - 0.15) / (0.85 - 0.15) * 100)
        .round()
        .clamp(0, 100);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true,
          minTileHeight: 54,
          contentPadding: const EdgeInsets.fromLTRB(13, 1, 8, 1),
          leading: Icon(Icons.wb_twilight_outlined, color: t.muted, size: 20),
          title: Text(
            '防蓝光滤镜',
            style: TextStyle(color: t.text, fontSize: 13.5),
          ),
          subtitle: Text(
            settings.eyeCareFilter ? '柔和暖光 · $pct%' : '已关闭',
            style: TextStyle(color: t.muted, fontSize: 10.5, height: 1.3),
          ),
          trailing: Switch.adaptive(
            value: settings.eyeCareFilter,
            onChanged: settings.setEyeCareFilter,
          ),
          onTap: () => settings.setEyeCareFilter(!settings.eyeCareFilter),
        ),
        if (settings.eyeCareFilter)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Row(
              children: [
                Text('柔和', style: TextStyle(color: t.muted, fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: settings.eyeCareStrength,
                    min: 0.15,
                    max: 0.85,
                    onChanged: settings.setEyeCareStrength,
                  ),
                ),
                Text('强效', style: TextStyle(color: t.muted, fontSize: 11)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _eyeReminderTile(BuildContext context, ReadingTheme t) {
    final mins = settings.eyeCareReminderMinutes;
    final isCustom = !ReadingSettings.eyeCareReminderPresets.contains(mins);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          minTileHeight: 54,
          contentPadding: const EdgeInsets.fromLTRB(13, 1, 8, 1),
          leading: Icon(Icons.visibility_outlined, color: t.muted, size: 20),
          title: Text(
            '护眼提醒',
            style: TextStyle(color: t.text, fontSize: 13.5),
          ),
          subtitle: Text(
            settings.eyeCareReminder ? '每 $mins 分钟提醒休息' : '已关闭',
            style: TextStyle(color: t.muted, fontSize: 10.5, height: 1.3),
          ),
          trailing: Switch.adaptive(
            value: settings.eyeCareReminder,
            onChanged: settings.setEyeCareReminder,
          ),
          onTap: () => settings.setEyeCareReminder(!settings.eyeCareReminder),
        ),
        if (settings.eyeCareReminder)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in ReadingSettings.eyeCareReminderPresets)
                  ChoiceChip(
                    label: Text('$preset 分', style: const TextStyle(fontSize: 11.5)),
                    visualDensity: VisualDensity.compact,
                    selected: mins == preset,
                    onSelected: (_) =>
                        settings.setEyeCareReminderMinutes(preset),
                  ),
                ChoiceChip(
                  label: Text(
                    isCustom ? '$mins 分' : '自定义',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  visualDensity: VisualDensity.compact,
                  selected: isCustom,
                  onSelected: (_) => _askCustomReminder(context, t),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _askCustomReminder(BuildContext context, ReadingTheme t) async {
    final ctl = TextEditingController(
      text: settings.eyeCareReminderMinutes.toString(),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text(
          '自定义提醒间隔',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: TextStyle(color: t.text),
          decoration: InputDecoration(
            hintText: '1 - 180',
            suffixText: context.tr('分钟'),
          ),
          onSubmitted: (v) {
            final parsed = int.tryParse(v.trim());
            if (parsed != null && parsed >= 1) {
              Navigator.pop(dialogContext, parsed);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          FilledButton.tonal(
            onPressed: () {
              final parsed = int.tryParse(ctl.text.trim());
              if (parsed != null && parsed >= 1) {
                Navigator.pop(dialogContext, parsed);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (result != null) {
      settings.setEyeCareReminderMinutes(result);
    }
  }

  Widget _section(ReadingTheme t, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
    child: Text(
      text,
      style: TextStyle(
        color: t.muted,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

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
    Widget? trailing,
    VoidCallback? onTap,
  }) => ListTile(
    dense: true,
    minTileHeight: subtitle == null ? 50 : 58,
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 1),
    leading: Icon(icon, color: t.muted, size: 20),
    title: Text(title, style: TextStyle(color: t.text, fontSize: 13.5)),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.muted, fontSize: 10.5, height: 1.3),
          ),
    trailing: trailing ?? Icon(Icons.chevron_right, color: t.muted, size: 19),
    enabled: onTap != null,
    onTap: onTap,
  );
}
