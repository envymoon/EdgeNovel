import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'font_manager.dart';
import 'theme.dart';

class FontPage extends StatefulWidget {
  final ReadingSettings settings;

  const FontPage({super.key, required this.settings});

  @override
  State<FontPage> createState() => _FontPageState();
}

class _FontPageState extends State<FontPage> {
  FontManager get manager => FontManager.instance;

  @override
  void initState() {
    super.initState();
    manager.loadInstalledFonts();
  }

  Future<void> _select(FontPack pack) async {
    try {
      if (!manager.isInstalled(pack)) await manager.download(pack);
      await manager.ensureLoaded(pack);
      widget.settings.setFontFamily(pack.family);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('字体准备失败：$error')));
    }
  }

  Future<void> _import() async {
    try {
      final pack = await manager.importLocalFont();
      if (pack != null) widget.settings.setFontFamily(pack.family);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('字体导入失败：$error')));
    }
  }

  Future<void> _delete(FontPack pack) async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.background,
        title: Text('删除“${pack.name}”？', style: TextStyle(color: t.text)),
        content: Text(
          '以后仍可重新下载。小说和阅读设置不会被删除。',
          style: TextStyle(color: t.muted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (widget.settings.fontFamily == pack.family) {
      widget.settings.setFontFamily('');
    }
    await manager.delete(pack);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([manager, widget.settings]),
      builder: (context, _) {
        final t = widget.settings.theme;
        return Scaffold(
          backgroundColor: t.background,
          appBar: AppBar(
            backgroundColor: t.background,
            surfaceTintColor: Colors.transparent,
            title: Text('阅读字体', style: TextStyle(color: t.text, fontSize: 17)),
            iconTheme: IconThemeData(color: t.muted),
            actions: [
              TextButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('导入'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                '字体不会随应用安装。需要哪一款再下载，也可以导入自己的 TTF / OTF。',
                style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.5),
              ),
              const SizedBox(height: 14),
              for (final pack in manager.packs) ...[
                _fontCard(pack, t),
                const SizedBox(height: 10),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _fontCard(FontPack pack, ReadingTheme t) {
    final selected = widget.settings.fontFamily == pack.family;
    final installed = manager.isInstalled(pack);
    final downloading = manager.isDownloading(pack);
    final progress = manager.progressFor(pack);
    final error = manager.errorFor(pack);
    final previewFamily = installed ? pack.family : null;

    return Material(
      color: selected
          ? t.text.withValues(alpha: 0.07)
          : t.muted.withValues(alpha: 0.035),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected
              ? t.text.withValues(alpha: 0.45)
              : t.muted.withValues(alpha: 0.16),
        ),
        borderRadius: BorderRadius.circular(13),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: downloading ? null : () => _select(pack),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      pack.name,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_circle, size: 20, color: t.text)
                  else if (downloading)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 2,
                      ),
                    )
                  else if (!installed)
                    IconButton(
                      tooltip: context.tr('下载'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _select(pack),
                      icon: const Icon(Icons.download_outlined, size: 21),
                    )
                  else if (pack.id != systemFont.id)
                    PopupMenuButton<String>(
                      tooltip: context.tr('字体选项'),
                      onSelected: (value) {
                        if (value == 'delete') _delete(pack);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: Text('删除字体')),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                pack.sample,
                style: TextStyle(
                  color: t.text,
                  fontFamily: previewFamily?.isEmpty == true
                      ? null
                      : previewFamily,
                  fontSize: 21,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '${pack.description}  ·  ${pack.sizeLabel}',
                style: TextStyle(color: t.muted, fontSize: 11.5),
              ),
              if (pack.license.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  '${pack.license}${pack.source.isEmpty ? '' : '  ·  ${pack.source}'}',
                  style: TextStyle(
                    color: t.muted.withValues(alpha: 0.75),
                    fontSize: 10.5,
                  ),
                ),
              ],
              if (downloading) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: progress),
              ],
              if (error != null) ...[
                const SizedBox(height: 7),
                Text(
                  '下载失败，点按重试',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
