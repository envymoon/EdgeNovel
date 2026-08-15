import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'reader_state.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

class AnnotationDraft {
  final int chapter;
  final Paragraph paragraph;
  final int start;
  final int end;

  const AnnotationDraft({
    required this.chapter,
    required this.paragraph,
    required this.start,
    required this.end,
  });

  String get quote => paragraph.text.substring(start, end);
}

Future<void> showAnnotationEditor(
  BuildContext context, {
  required ReaderState reader,
  required ReadingSettings settings,
  required Paragraph paragraph,
  AnnotationDraft? draft,
  BookAnnotation? annotation,
}) async {
  final t = settings.theme;
  final controller = TextEditingController(text: annotation?.body ?? '');
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: t.background,
      title: Text(
        annotation == null ? '添加标注' : '编辑标注',
        style: TextStyle(color: t.text, fontSize: 17),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              constraints: const BoxConstraints(maxHeight: 110),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.muted.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(
                  annotation?.quote ?? draft?.quote ?? paragraph.text,
                  style: TextStyle(color: t.muted, fontSize: 12, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 500,
              minLines: 3,
              maxLines: 7,
              style: TextStyle(color: t.text),
              decoration: InputDecoration(
                hintText: context.tr('写下你的想法'),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (annotation != null)
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'delete'),
            child: const Text('删除', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text('取消', style: TextStyle(color: t.muted)),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, 'save'),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (!context.mounted) {
    controller.dispose();
    return;
  }
  try {
    if (action == 'delete' && annotation != null) {
      await reader.removeAnnotation(annotation);
    } else if (action == 'save') {
      if (annotation == null) {
        if (draft == null) return;
        await reader.saveAnnotationSelection(
          chapter: draft.chapter,
          paragraph: paragraph,
          start: draft.start,
          end: draft.end,
          body: controller.text,
        );
      } else {
        await reader.updateAnnotation(annotation, controller.text);
      }
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('标注保存失败：$e')));
    }
  } finally {
    controller.dispose();
  }
}

Future<void> showAnnotationComments(
  BuildContext context, {
  required ReaderState reader,
  required ReadingSettings settings,
  required Paragraph paragraph,
  required List<BookAnnotation> annotations,
}) async {
  final t = settings.theme;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.background,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.62,
        child: Column(
          children: [
            ListTile(
              title: Text(
                '标注',
                style: TextStyle(
                  color: t.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                paragraph.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.muted, fontSize: 11.5),
              ),
            ),
            Divider(height: 1, color: t.muted.withValues(alpha: 0.14)),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: annotations.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: t.muted.withValues(alpha: 0.11)),
                itemBuilder: (context, i) {
                  final annotation = annotations[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(
                      annotation.body,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    trailing: Icon(
                      Icons.edit_outlined,
                      color: t.muted,
                      size: 17,
                    ),
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      await showAnnotationEditor(
                        context,
                        reader: reader,
                        settings: settings,
                        paragraph: paragraph,
                        annotation: annotation,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _AnnotationAction { jump, edit, delete }

class AnnotationPage extends StatelessWidget {
  final ReaderState reader;
  final ReadingSettings settings;

  const AnnotationPage({
    super.key,
    required this.reader,
    required this.settings,
  });

  void _startAnnotationMode(BuildContext context) {
    Navigator.pop(context, true);
  }

  Future<void> _runAction(
    BuildContext context,
    _AnnotationAction action,
    BookAnnotation annotation,
    int chapter,
  ) async {
    if (action == _AnnotationAction.delete) {
      try {
        await reader.removeAnnotation(annotation);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('标注已删除')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
        }
      }
      return;
    }
    if (action == _AnnotationAction.edit) {
      final paragraph = Paragraph(
        kind: ParaKind.body,
        text: annotation.quote,
        start: annotation.start,
        end: annotation.end,
      );
      await showAnnotationEditor(
        context,
        reader: reader,
        settings: settings,
        paragraph: paragraph,
        annotation: annotation,
      );
      return;
    }
    await reader.goToOffset(chapter, annotation.start);
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = settings.theme;
    return ListenableBuilder(
      listenable: reader,
      builder: (context, _) {
        final info = reader.info;
        final annotations = reader.annotations;
        return Scaffold(
          backgroundColor: t.background,
          appBar: AppBar(
            backgroundColor: t.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            iconTheme: IconThemeData(color: t.muted),
            title: Text('标注', style: TextStyle(color: t.text, fontSize: 17)),
            actions: [
              IconButton(
                tooltip: context.tr('选择正文'),
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: info == null
                    ? null
                    : () => _startAnnotationMode(context),
              ),
            ],
          ),
          body: info == null || annotations.isEmpty
              ? Center(
                  child: Text(
                    '点击右上角，返回正文选择要标注的内容',
                    style: TextStyle(color: t.muted, fontSize: 13),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
                  itemCount: annotations.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: t.muted.withValues(alpha: 0.12),
                  ),
                  itemBuilder: (context, i) {
                    final annotation = annotations[i];
                    final chapter = annotation.chapter.clamp(
                      0,
                      info.chapters.length - 1,
                    );
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 7,
                      ),
                      title: Text(
                        annotation.body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${info.chapters[chapter].title} · ${annotation.quote}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.muted, fontSize: 11.5),
                        ),
                      ),
                      trailing: PopupMenuButton<_AnnotationAction>(
                        tooltip: context.tr('更多'),
                        icon: Icon(Icons.more_horiz, color: t.muted, size: 19),
                        onSelected: (action) =>
                            _runAction(context, action, annotation, chapter),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _AnnotationAction.jump,
                            child: Text('跳转到原文'),
                          ),
                          PopupMenuItem(
                            value: _AnnotationAction.edit,
                            child: Text('编辑'),
                          ),
                          PopupMenuDivider(),
                          PopupMenuItem(
                            value: _AnnotationAction.delete,
                            child: Text(
                              '删除',
                              style: TextStyle(color: Color(0xFFB3574D)),
                            ),
                          ),
                        ],
                      ),
                      onTap: () async {
                        await reader.goToOffset(chapter, annotation.start);
                        if (context.mounted) Navigator.pop(context);
                      },
                    );
                  },
                ),
        );
      },
    );
  }
}
