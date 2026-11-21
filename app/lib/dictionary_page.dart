import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'dictionary.dart';
import 'theme.dart';

String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} MB';

/// 字典: download it, or delete it.
class DictionaryPage extends StatefulWidget {
  final ReadingSettings settings;

  const DictionaryPage({super.key, required this.settings});

  @override
  State<DictionaryPage> createState() => _DictionaryPageState();
}

class _DictionaryPageState extends State<DictionaryPage> {
  final _d = Dictionary.instance;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _d.installed.addListener(_size);
    unawaited(_size());
  }

  @override
  void dispose() {
    _d.installed.removeListener(_size);
    super.dispose();
  }

  Future<void> _size() async {
    final n = await _d.bytes();
    if (mounted) setState(() => _bytes = n);
  }

  Future<void> _remove() async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: const Text('删除字典？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await _d.remove();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final download = dictionaryFiles.fold<int>(0, (n, f) => n + f.bytes);
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('字典', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_d.installed, _d.progress, _d.error]),
        builder: (context, _) {
          final p = _d.progress.value;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Material(
                clipBehavior: Clip.antiAlias,
                color: t.surface,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: t.outline),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: p != null
                      ? BloomProgress(
                          label: p >= 1 ? '正在整理字典' : '正在下载字典',
                          detail: p >= 1 ? null : '${(p * 100).floor()}%',
                          value: p >= 1 ? null : p,
                          color: t.muted,
                          textColor: t.text,
                          trailing: p >= 1
                              ? null
                              : TextButton(
                                  onPressed: _d.cancel,
                                  child: const Text('取消'),
                                ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '字、词、成语',
                                    style: TextStyle(
                                      color: t.text,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _d.error.value ??
                                        (_d.installed.value
                                            ? '已下载 · ${_mb(_bytes)}'
                                            : '约 ${_mb(download)}'),
                                    style: TextStyle(
                                      color: _d.error.value != null
                                          ? const Color(0xFFB3574D)
                                          : t.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_d.installed.value)
                              TextButton(
                                onPressed: _remove,
                                child: const Text(
                                  '删除',
                                  style: TextStyle(color: Color(0xFFB3574D)),
                                ),
                              )
                            else
                              FilledButton.tonal(
                                onPressed: () => unawaited(_d.install()),
                                child: const Text('下载'),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
