import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/image.dart';
import 'theme.dart';

/// Whether this device can draw covers: the engine, the model and its decoder
/// are all installed. The edit dialog only offers AI 生成 when they are.
Future<bool> coverGeneratorReady() async {
  try {
    return (await imageStatus()).ready;
  } catch (_) {
    return false;
  }
}

/// Draw a cover with the local image model. Returns the chosen picture — a temp
/// file the caller adopts with setBookCover and may then delete — or null.
/// The book's genre tags pick the starting scene; the [title] can go into the
/// prompt like a tag.
Future<String?> showCoverGenerator(
  BuildContext context, {
  required ReadingTheme theme,
  required List<String> genreTags,
  String title = '',
}) async {
  final choices = await coverChoices();
  final scene = await defaultCoverScene(genreTags: genreTags);
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CoverGenerator(
      theme: theme,
      choices: choices,
      scene: scene,
      title: title,
    ),
  );
}

class _CoverGenerator extends StatefulWidget {
  final ReadingTheme theme;
  final CoverChoices choices;
  final String scene;
  final String title;

  const _CoverGenerator({
    required this.theme,
    required this.choices,
    required this.scene,
    required this.title,
  });

  @override
  State<_CoverGenerator> createState() => _CoverGeneratorState();
}

class _CoverGeneratorState extends State<_CoverGenerator> {
  /// Who is on the cover, in the order picked. None draws scenery.
  late final List<String> _people = [
    if (widget.choices.people.contains('少女')) '少女',
  ];

  /// The worlds the cover mixes, in the order picked.
  late final List<String> _scenes = [widget.scene];

  /// Put the title into the prompt.
  bool _withTitle = false;

  /// The tags picked, in the order they go into the picture.
  final List<String> _picked = [];

  final _random = Random();

  StreamSubscription<CoverProgress>? _sub;
  CoverProgress? _progress;
  String? _error;
  String? _picture;

  /// Every picture drawn here. All but the one handed back are deleted on the
  /// way out; they are temp files nobody else knows about.
  final _drafts = <String>[];

  bool get _drawing => _sub != null;

  bool get _nobody => _people.isEmpty;

  CoverTagGroup? _groupOf(String label) {
    for (final g in widget.choices.groups) {
      if (g.labels.contains(label)) return g;
    }
    return null;
  }

  /// Pick `label`, making room in its group by dropping the oldest pick.
  void _pick(String label) {
    if (_picked.contains(label)) return;
    final g = _groupOf(label);
    if (g == null) return;
    final same = _picked.where(g.labels.contains).toList();
    if (same.length >= g.most) _picked.remove(same.first);
    _picked.add(label);
  }

  void _toggle(String label) => setState(() {
    if (!_picked.remove(label)) _pick(label);
  });

  /// A different mix each time: a chance at something from every group.
  void _shuffle() => setState(() {
    _picked.clear();
    for (final g in widget.choices.groups) {
      if (g.labels.isEmpty) continue;
      // A role dresses the person whole; it comes up less, so the looks can.
      final chance = g.name == '身份' ? 0.2 : 0.5;
      if (_random.nextDouble() < chance) {
        _pick(g.labels[_random.nextInt(g.labels.length)]);
      }
    }
  });

  void _draw() {
    setState(() {
      _error = null;
      _progress = null;
    });
    _sub =
        drawCover(
          people: List.of(_people),
          scenes: List.of(_scenes),
          title: _withTitle ? widget.title : '',
          cues: List.of(_picked),
          seed: _random.nextInt(1 << 31),
        ).listen(
          (p) {
            if (!mounted) return;
            setState(() {
              _progress = p;
              final path = p.path;
              if (path != null) {
                _drafts.add(path);
                _picture = path;
              }
            });
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = '$e');
          },
          onDone: () {
            if (mounted) setState(() => _sub = null);
          },
        );
  }

  void _close([String? chosen]) {
    if (_drawing) unawaited(cancelCover());
    _sub?.cancel();
    _sub = null;
    for (final d in _drafts) {
      if (d == chosen) continue;
      try {
        File(d).deleteSync();
      } catch (_) {}
    }
    Navigator.pop(context, chosen);
  }

  String _status(BuildContext context) {
    final p = _progress;
    if (p == null || p.stage == 0) return context.tr('准备中，正在载入模型');
    if (p.stage == 1) return '${context.tr('正在绘制')} ${p.step} / ${p.steps}';
    if (p.stage == 2) return context.tr('正在成图');
    return context.tr('完成');
  }

  double? _fraction() {
    final p = _progress;
    if (p == null || p.stage == 0) return null;
    // Drawing is most of the time; loading and decoding are the slivers either
    // side of it.
    if (p.stage == 1) return 0.1 + 0.75 * p.step / p.steps;
    if (p.stage == 2) return 0.9;
    return 1;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final accent = Theme.of(context).colorScheme.primary;
    final picture = _picture;

    /// Any number of [labels], picked into [picked] in order.
    Widget chips(List<String> labels, List<String> picked) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in labels)
          FilterChip(
            label: Text(label),
            selected: picked.contains(label),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: _drawing
                ? null
                : (on) => setState(
                    () => on ? picked.add(label) : picked.remove(label),
                  ),
          ),
      ],
    );

    Widget heading(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: TextStyle(color: t.muted, fontSize: 12)),
          ),
          ?trailing,
        ],
      ),
    );

    Widget group(CoverTagGroup g) {
      final off = _drawing || (_nobody && g.personal);
      final mine = _picked.where(g.labels.contains).toList();
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          visualDensity: VisualDensity.compact,
          title: Text(
            g.name,
            style: TextStyle(
              color: off ? t.muted.withValues(alpha: 0.5) : t.text,
              fontSize: 13,
            ),
          ),
          subtitle: mine.isEmpty
              ? null
              : Text(
                  mine.join('、'),
                  style: TextStyle(color: accent, fontSize: 11.5),
                ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final label in g.labels)
                    FilterChip(
                      label: Text(label),
                      selected: _picked.contains(label),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: off ? null : (_) => _toggle(label),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      backgroundColor: t.raisedSurface,
      title: Text('AI 生成封面', style: TextStyle(color: t.text, fontSize: 16)),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 150,
                    height: 225,
                    alignment: Alignment.center,
                    color: t.muted.withValues(alpha: 0.08),
                    // The flower is in the progress row below; one is enough.
                    // A picture being replaced fades while its successor is
                    // drawn.
                    child: picture != null
                        ? Opacity(
                            opacity: _drawing ? 0.4 : 1,
                            child: Image.file(
                              File(picture),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.broken_image_outlined,
                                color: t.muted,
                              ),
                            ),
                          )
                        : Icon(
                            Icons.auto_awesome_outlined,
                            color: t.muted.withValues(alpha: 0.5),
                            size: 30,
                          ),
                  ),
                ),
              ),
              if (_drawing) ...[
                const SizedBox(height: 14),
                BloomProgress(
                  label: _status(context),
                  value: _fraction(),
                  color: t.muted,
                  textColor: t.text,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  translate: false,
                  style: const TextStyle(
                    color: Color(0xFFB3574D),
                    fontSize: 12,
                  ),
                ),
              ],
              heading('人物'),
              chips(widget.choices.people, _people),
              heading('题材'),
              chips(widget.choices.scenes, _scenes),
              if (widget.title.isNotEmpty) ...[
                heading('书名'),
                FilterChip(
                  label: Text('《${widget.title}》', translate: false),
                  selected: _withTitle,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: _drawing
                      ? null
                      : (on) => setState(() => _withTitle = on),
                ),
              ],
              heading(
                '标签',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: _drawing ? null : _shuffle,
                      icon: const Icon(Icons.casino_outlined, size: 16),
                      label: const Text('随机'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    TextButton(
                      onPressed: _drawing || _picked.isEmpty
                          ? null
                          : () => setState(_picked.clear),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              for (final g in widget.choices.groups) group(g),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _close(),
          child: Text('取消', style: TextStyle(color: t.muted)),
        ),
        TextButton(
          onPressed: _drawing ? null : _draw,
          child: Text(picture == null ? '生成' : '换一张'),
        ),
        TextButton(
          onPressed: _drawing || picture == null ? null : () => _close(picture),
          child: Text(
            '用这张',
            style: TextStyle(color: picture == null ? null : accent),
          ),
        ),
      ],
    );
  }
}
