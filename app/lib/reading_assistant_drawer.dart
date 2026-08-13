import 'package:flutter/material.dart';

import 'reader_state.dart';
import 'theme.dart';

class ReadingAssistantDrawer extends StatelessWidget {
  final ReaderState reader;
  final ReadingSettings settings;
  final VoidCallback onSearch;
  final VoidCallback onBookDetail;
  final VoidCallback onAppearance;
  final VoidCallback onAiRuntime;

  const ReadingAssistantDrawer({
    super.key,
    required this.reader,
    required this.settings,
    required this.onSearch,
    required this.onBookDetail,
    required this.onAppearance,
    required this.onAiRuntime,
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
      backgroundColor: t.background,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: reader,
          builder: (context, _) => ListView(
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
                          const SizedBox(height: 3),
                          Text(
                            '回顾当前位置，继续理解正在读的故事',
                            style: TextStyle(color: t.muted, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
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
                    title: '回忆搜索',
                    subtitle: '搜索已读内容',
                    onTap: () => _run(context, onSearch),
                  ),
                  _entry(
                    t,
                    icon: Icons.menu_book_outlined,
                    title: '书籍详情',
                    subtitle: '扫书报告、人物与章节概览',
                    onTap: () => _run(context, onBookDetail),
                  ),
                ],
              ),
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
              const SizedBox(height: 18),
              _section(t, '阅读设置'),
              _group(
                t,
                children: [
                  _entry(
                    t,
                    icon: Icons.text_fields,
                    title: '阅读外观',
                    subtitle: '字体、背景与翻页',
                    onTap: () => _run(context, onAppearance),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
