import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'bloom.dart';
import 'src/rust/api/source.dart';
import 'platform_services.dart';
import 'theme.dart';

/// 书源管理 — the user's rule sheets, and whether they actually work.
///
/// We ship none of these. A source is a JSON file describing how to read one
/// website; the user brings their own, and this page's real job is to tell them
/// the truth about what they brought. A sheet whose JSON parses is not a sheet
/// that works — the site may be dead, or it may need a JavaScript engine we do
/// not have. So sources are made to *prove themselves* against the live site:
/// search a word, open a book, read a chapter.
///
/// The thing to design around is scale. A legado export is not five sources, it
/// is two or three thousand, and most of them died years ago. So: validation
/// runs many sites at once and writes each verdict down as it lands, the list is
/// filterable because nobody scrolls three thousand rows, and until a validation
/// pass exists we say plainly that search is running on untested sources — which
/// it is, and which is why it is slow.
///
/// Failing sources are kept, greyed, not deleted: a site that is down today is
/// often up next week.
class SourceManagerPage extends StatefulWidget {
  final ReadingSettings settings;

  const SourceManagerPage({super.key, required this.settings});

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

enum _Filter { all, ok, untested, failed }

class _SourceManagerPageState extends State<SourceManagerPage> {
  List<SourceItem> _sources = [];
  bool _loading = true;
  String? _error;
  _Filter _filter = _Filter.all;

  /// A single source being tested from its own menu.
  final _testing = <String>{};

  /// A whole-list pass.
  StreamSubscription<TestFeed>? _sub;
  TestFeed? _feed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await listSources();
      if (mounted) {
        setState(() {
          _sources = s;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _importFile() async {
    final path = await AppServices.instance.files.pickSourceFile();
    if (path == null) return;
    await _import(
      () async => importSources(json: await File(path).readAsString()),
    );
  }

  Future<void> _importText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _import(
      () => t.startsWith('http')
          ? importSourcesFromUrl(url: t)
          : importSources(json: t),
    );
  }

  Future<void> _import(Future<int> Function() run) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await run();
      await _load();
      messenger.showSnackBar(SnackBar(content: Text('导入 $n 个书源')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pasteDialog() async {
    final ctl = TextEditingController();
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.background,
        title: Text('粘贴书源', style: TextStyle(color: t.text, fontSize: 16)),
        content: TextField(
          controller: ctl,
          maxLines: 6,
          style: TextStyle(color: t.text, fontSize: 13),
          decoration: InputDecoration(
            hintText: '书源 JSON，或一个书源链接',
            hintStyle: TextStyle(color: t.muted, fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('导入', style: TextStyle(color: t.text)),
          ),
        ],
      ),
    );
    if (ok == true) await _importText(ctl.text);
  }

  Future<void> _test(SourceItem s) async {
    setState(() => _testing.add(s.url));
    try {
      await testSource(url: s.url);
    } catch (_) {
      // The verdict is stored by Rust either way; the reload below shows it.
    }
    if (!mounted) return;
    setState(() => _testing.remove(s.url));
    await _load();
  }

  /// Validate the list. Verdicts are written down one at a time on the Rust
  /// side, so a pass that is stopped — or a page that is closed — still keeps
  /// every answer it already got.
  void _testAll({required bool onlyUntested}) {
    _sub?.cancel();
    setState(() => _error = null);
    _sub = testSources(onlyUntested: onlyUntested).listen(
      (f) {
        if (mounted) setState(() => _feed = f);
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _error = '$e';
            _feed = null;
          });
        }
      },
      onDone: () async {
        if (!mounted) return;
        setState(() => _feed = null);
        await _load();
      },
    );
  }

  void _stopTests() {
    cancelTests();
    _sub?.cancel();
    setState(() => _feed = null);
    _load();
  }

  List<SourceItem> get _visible => switch (_filter) {
    _Filter.all => _sources,
    _Filter.ok => _sources.where((s) => s.ok == true).toList(),
    _Filter.untested => _sources.where((s) => s.ok == null).toList(),
    _Filter.failed => _sources.where((s) => s.ok == false).toList(),
  };

  /// Delete whatever the filter is showing — which is what makes "delete the 500
  /// dead ones" a single tap. Unrecoverable, and the list is long enough that
  /// nobody could check it afterwards, so the count is spelled out first.
  Future<void> _deleteVisible() async {
    final doomed = _visible;
    if (doomed.isEmpty) return;
    final all = _filter == _Filter.all;
    final t = widget.settings.theme;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.background,
        title: Text(
          all ? '删除全部书源？' : '删除这 ${doomed.length} 个书源？',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('算了', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        ],
      ),
    );
    if (go != true) return;
    final n = all
        ? await deleteAllSources()
        : await deleteSources(urls: doomed.map((s) => s.url).toList());
    if (!mounted) return;
    setState(() => _filter = _Filter.all);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('删了 $n 个书源')));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final ok = _sources.where((s) => s.ok == true).length;
    final failed = _sources.where((s) => s.ok == false).length;
    final untested = _sources.length - ok - failed;
    final list = _visible;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('书源', style: TextStyle(color: t.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '从文件导入',
            icon: const Icon(Icons.file_open_outlined),
            color: t.muted,
            onPressed: _importFile,
          ),
          IconButton(
            tooltip: '粘贴导入',
            icon: const Icon(Icons.content_paste),
            color: t.muted,
            onPressed: _pasteDialog,
          ),
        ],
      ),
      body: _loading
          ? Center(child: Bloom(color: t.muted, size: 34))
          // A builder, not a children: list — an export of three thousand
          // sources must not cost three thousand widgets just to look at.
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              itemCount: list.length + 1,
              itemBuilder: (_, i) => i == 0
                  ? _header(t, ok, failed, untested)
                  : _tile(t, list[i - 1]),
            ),
    );
  }

  Widget _header(ReadingTheme t, int ok, int failed, int untested) {
    final empty = _sources.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null) ...[
          Text(
            _error!,
            style: const TextStyle(color: Color(0xFFB3574D), fontSize: 12),
          ),
          const SizedBox(height: 12),
        ],
        // Counts only. The page used to explain itself at length; the numbers say
        // the same thing and the reader is here to look at sources, not prose.
        Text(
          empty ? '还没有书源' : '共 ${_sources.length} 个，$ok 个留用',
          style: TextStyle(color: t.muted, fontSize: 12, height: 1.9),
        ),
        const SizedBox(height: 14),
        if (!empty) ...[
          _testBar(t, untested),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _chip(t, '全部 ${_sources.length}', _Filter.all),
              _chip(t, '留用 $ok', _Filter.ok),
              _chip(t, '未校验 $untested', _Filter.untested),
              _chip(t, '已淘汰 $failed', _Filter.failed),
              if (_visible.isNotEmpty)
                InkWell(
                  onTap: _deleteVisible,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          size: 14,
                          color: Color(0xFFB3574D),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _filter == _Filter.all
                              ? '全部删除'
                              : '删除这 ${_visible.length} 个',
                          style: const TextStyle(
                            color: Color(0xFFB3574D),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _chip(ReadingTheme t, String label, _Filter f) {
    final on = _filter == f;
    return InkWell(
      onTap: () => setState(() => _filter = f),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(
            color: t.muted.withValues(alpha: on ? 0.55 : 0.18),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(color: on ? t.text : t.muted, fontSize: 11),
        ),
      ),
    );
  }

  Widget _testBar(ReadingTheme t, int untested) {
    final f = _feed;
    if (f != null) {
      return BloomProgress(
        label: '正在校验书源',
        detail:
            '${f.done}/${f.total} · 可用 ${f.ok} · 失败 ${f.failed}\n'
            '${f.sourceName.trim()}：${f.message}',
        value: f.total == 0 ? null : f.done / f.total,
        color: t.muted,
        textColor: t.text,
        trailing: TextButton(
          onPressed: _stopTests,
          child: Text('停止', style: TextStyle(color: t.muted, fontSize: 12)),
        ),
      );
    }
    return Wrap(
      children: [
        if (untested > 0)
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            icon: Icon(Icons.fact_check_outlined, size: 18, color: t.muted),
            label: Text(
              '校验未校验的 $untested 个',
              style: TextStyle(color: t.text, fontSize: 13),
            ),
            onPressed: () => _testAll(onlyUntested: true),
          ),
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onPressed: () => _testAll(onlyUntested: false),
          child: Text('全部重新校验', style: TextStyle(color: t.muted, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _tile(ReadingTheme t, SourceItem s) {
    final busy = _testing.contains(s.url);
    final ok = s.ok;
    final dot = switch (ok) {
      true => const Color(0xFF5E8C61),
      false => const Color(0xFFB3574D),
      _ => t.muted.withValues(alpha: 0.4),
    };
    // The only line worth printing under a source is the one you might act on: a
    // site that would not answer might answer tomorrow. Everything else the dot
    // already said.
    final state = s.note.startsWith('请求失败') ? s.note : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        border: Border.all(color: t.muted.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ok == false ? t.muted : t.text,
                    fontSize: 13,
                  ),
                ),
                if (state.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    state,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.muted, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Bloom(color: t.muted, size: 18),
            )
          else ...[
            Switch(
              value: s.enabled,
              activeThumbColor: t.text,
              onChanged: (v) async {
                await setSourceEnabled(url: s.url, enabled: v);
                await _load();
              },
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, color: t.muted, size: 20),
              color: t.background,
              onSelected: (v) async {
                if (v == 'test') {
                  await _test(s);
                } else if (v == 'delete') {
                  await deleteSource(url: s.url);
                  await _load();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'test',
                  child: Text(
                    '校验',
                    style: TextStyle(color: t.text, fontSize: 13),
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    '删除',
                    style: TextStyle(color: t.text, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
