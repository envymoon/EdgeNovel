import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ai_page.dart';
import 'bloom.dart';
import 'platform_support.dart';
import 'reader_state.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 人物图谱 — who is in the book and who stands with whom, across the whole book.
///
/// Counted, not read: novel_core finds the cast from dialogue attribution and the
/// edges from co-occurrence. For each pair it collects the relationship-bearing
/// sentences, and the local model reads them all together and writes a one- or
/// two-sentence summary of how the two get on. (It used to pick a single category
/// label from a closed set, but the small model could not choose stably between
/// near-synonyms or for pairs that are two things at once, so it describes them
/// instead.) The same treatment gives each character a background: their own
/// sentences, sampled toward the ones that say who they are, read in one pass.
/// Every claim — about a pair or about a person — opens to the sentences it
/// rests on.
///
/// The model pass runs only when asked for, and in the shared background
/// queue: it keeps going after this page is closed and shows in the app-wide
/// progress bar like every other pass.
class CastGraphPage extends StatefulWidget {
  final ShelfItem book;
  final ReaderState reader;
  final ReadingSettings settings;

  const CastGraphPage({
    super.key,
    required this.book,
    required this.reader,
    required this.settings,
  });

  @override
  State<CastGraphPage> createState() => _CastGraphPageState();
}

class _CastGraphPageState extends State<CastGraphPage> {
  CastGraph? _graph;
  String? _error;

  List<Offset> _pos = const [];
  int? _selected;

  final Map<String, String> _modelLabel = {};
  final Map<String, String> _modelBackground = {};
  bool _hasModel = false;
  AiTaskState? _lastState;

  @override
  void initState() {
    super.initState();
    widget.reader.addListener(_onReader);
    _lastState = widget.reader.castStateFor(widget.book.id);
    _load();
  }

  @override
  void dispose() {
    widget.reader.removeListener(_onReader);
    super.dispose();
  }

  AiTaskState get _castState => widget.reader.castStateFor(widget.book.id);

  bool get _castActive =>
      _castState == AiTaskState.running || _castState == AiTaskState.waiting;

  /// Take each summary as the background pass writes it, and re-read the graph
  /// once the pass stops: a verdict may have removed someone and renumbered
  /// every edge.
  void _onReader() {
    final r = widget.reader;
    if (r.castBookId == widget.book.id) {
      _modelLabel.addAll(r.castLabels);
      _modelBackground.addAll(r.castBackgrounds);
    }
    final state = _castState;
    final stopped =
        _lastState == AiTaskState.running && state != AiTaskState.running;
    _lastState = state;
    if (stopped) _load();
    if (mounted) setState(() {});
  }

  String _key(String a, String b) => '$a $b';

  Future<void> _load() async {
    try {
      final g = await castGraph(
        path: widget.book.path,
        bookId: widget.book.id,
        upToChapter: widget.book.chapterCount,
        top: widget.settings.castTop,
      );
      final s = await aiStatus();
      if (!mounted) return;
      setState(() {
        _graph = g;
        _pos = _layout(g);
        _hasModel = s.engine && s.model != null;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// A background written in this run wins over the stored one: when an
  /// outdated background is being rewritten, the new text is the answer.
  String? _backgroundOf(CastPerson p) =>
      _modelBackground[p.name] ?? p.background;

  /// Backgrounds that could now be written from better material, and have not
  /// been rewritten in this run yet.
  int _outdated(CastGraph g) => g.people
      .where(
        (p) => p.backgroundOutdated && !_modelBackground.containsKey(p.name),
      )
      .length;

  String? _labelOf(CastRelation e) {
    if (e.label != null) return e.label;
    final g = _graph!;
    return _modelLabel[_key(g.people[e.a].name, g.people[e.b].name)];
  }

  /// The first [n] of the ten: the graph is drawn again for them.
  Future<void> _setTop(int n) async {
    if (widget.settings.castTop == n) return;
    widget.settings.setCastTop(n);
    setState(() => _selected = null);
    await _load();
  }

  Future<void> _runModel() async {
    if (!_hasModel) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => AiPage(settings: widget.settings)),
      );
      final s = await aiStatus();
      if (mounted) setState(() => _hasModel = s.engine && s.model != null);
      return;
    }
    widget.reader.startCast(widget.book);
  }

  Future<void> _reset() async {
    await forgetRelations(bookId: widget.book.id);
    widget.reader.forgetCastResults(widget.book.id);
    if (!mounted) return;
    setState(() {
      _modelLabel.clear();
      _modelBackground.clear();
      _graph = null;
    });
    await _load();
  }

  // ── force-directed layout (Fruchterman–Reingold), run once ────────────────
  List<Offset> _layout(CastGraph g) {
    final n = g.people.length;
    if (n == 0) return const [];
    final rnd = math.Random(
      1,
    ); // deterministic: the same book lays out the same
    final pos = List<Offset>.generate(n, (i) {
      final a = 2 * math.pi * i / n;
      // A ring plus a little jitter beats a perfect circle at breaking symmetry.
      return Offset(
        0.5 + 0.3 * math.cos(a) + (rnd.nextDouble() - 0.5) * 0.02,
        0.5 + 0.3 * math.sin(a) + (rnd.nextDouble() - 0.5) * 0.02,
      );
    });
    if (n == 1) return pos;

    final k = 0.9 / math.sqrt(n); // ideal edge length
    final maxW = g.edges.fold<int>(1, (m, e) => math.max(m, e.weight));
    var temp = 0.12;
    for (var iter = 0; iter < 320; iter++) {
      final disp = List<Offset>.filled(n, Offset.zero);
      // Repulsion between every pair.
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          var d = pos[i] - pos[j];
          var dist = d.distance;
          if (dist < 1e-4) {
            d = Offset(rnd.nextDouble() - 0.5, rnd.nextDouble() - 0.5);
            dist = d.distance;
          }
          final f = (k * k / dist);
          final u = d / dist * f;
          disp[i] += u;
          disp[j] -= u;
        }
      }
      // Attraction along edges, stronger for heavier co-occurrence.
      for (final e in g.edges) {
        var d = pos[e.a] - pos[e.b];
        var dist = d.distance;
        if (dist < 1e-4) dist = 1e-4;
        final pull = 0.5 + 0.5 * (e.weight / maxW);
        final f = dist * dist / k * pull;
        final u = d / dist * f;
        disp[e.a] -= u;
        disp[e.b] += u;
      }
      for (var i = 0; i < n; i++) {
        var dd = disp[i];
        final dl = dd.distance;
        if (dl > temp) dd = dd / dl * temp;
        pos[i] += dd;
        pos[i] = Offset(pos[i].dx.clamp(0.0, 1.0), pos[i].dy.clamp(0.0, 1.0));
      }
      temp = math.max(0.012, temp * 0.985); // cool
    }
    // Normalize to the unit square so the painter can scale to any canvas.
    var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
    for (final p in pos) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    final w = math.max(maxX - minX, 1e-3), h = math.max(maxY - minY, 1e-3);
    return pos
        .map((p) => Offset((p.dx - minX) / w, (p.dy - minY) / h))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final g = _graph;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '人物图谱 · ${widget.book.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
        actions: [
          // Always available once a graph is on screen: the cache now outlives
          // the app, so this is the only way to make it read the book again.
          if (g != null && !_castActive)
            TextButton(
              onPressed: _reset,
              child: Text(
                '重新分析',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
            ),
        ],
      ),
      body: g == null ? _opening(t) : _content(t, g),
    );
  }

  Widget _opening(ReadingTheme t) => Center(
    child: _error != null
        ? Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB3574D),
                    fontSize: 13,
                    height: 1.7,
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Bloom(color: t.muted, size: 34),
              const SizedBox(height: 16),
              Text('正在扫描人物…', style: TextStyle(color: t.muted, fontSize: 13)),
            ],
          ),
  );

  Widget _content(ReadingTheme t, CastGraph g) {
    if (g.people.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '还没认出足够的人物',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.muted, fontSize: 13, height: 1.8),
          ),
        ),
      );
    }
    return Column(
      children: [
        _bar(t, g),
        Expanded(
          child: LayoutBuilder(
            builder: (_, box) => GestureDetector(
              onTapUp: (d) => _tap(d.localPosition, box.biggest),
              child: CustomPaint(
                size: Size.infinite,
                painter: _GraphPainter(
                  graph: g,
                  pos: _pos,
                  labelOf: _labelOf,
                  selected: _selected,
                  theme: t,
                ),
              ),
            ),
          ),
        ),
        _panel(t, g),
      ],
    );
  }

  /// What is left for the model, said in one clause. Two counts in one sentence
  /// ("3 段关系、5 位人物") rather than two lines, because it is one button.
  String _pending(int relations, int people, [int outdated = 0]) => [
    if (relations > 0) '$relations 段关系没有总结',
    if (people > 0) '$people 位人物还没归纳背景',
    if (outdated > 0) '$outdated 位人物的背景可以重写得更完整',
  ].join('、');

  Widget _bar(ReadingTheme t, CastGraph g) {
    final residual = g.edges.where((e) => _labelOf(e) == null).length;
    final unwritten = g.people.where((p) => _backgroundOf(p) == null).length;
    final outdated = _outdated(g);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: t.muted.withValues(alpha: 0.12)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '全书 ${g.upto} 章 · ${g.people.length} 人 · ${g.edges.length} 段关系',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: 12),
                ),
              ),
              for (final n in ReadingSettings.castTopChoices)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text('$n 人', style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selected: widget.settings.castTop == n,
                    onSelected: (_) => _setTop(n),
                  ),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFB3574D), fontSize: 11),
            ),
          ],
          ..._modelStatus(t, residual, unwritten, outdated),
        ],
      ),
    );
  }

  /// The model pass for this book, as the background queue reports it.
  List<Widget> _modelStatus(
    ReadingTheme t,
    int residual,
    int unwritten,
    int outdated,
  ) {
    if (!AppPlatformSupport.hasAiEngine) return const [];
    final r = widget.reader;
    final state = _castState;
    final small = TextStyle(color: t.muted, fontSize: 11, height: 1.5);
    Widget action(String label, VoidCallback onPressed) => FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
    Widget row(String text, Widget button, {Color? color}) => Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: color == null ? small : small.copyWith(color: color),
          ),
        ),
        const SizedBox(width: 10),
        button,
      ],
    );

    switch (state) {
      case AiTaskState.running:
        final p = r.castProgress;
        final remaining = r.aiActivity?.remaining;
        return [
          const SizedBox(height: 12),
          BloomProgress(
            label: p == null
                ? '本地模型准备中'
                : [
                    '本地模型${p.label}（第 ${p.step.index + 1}/3 步）'
                        ' · ${p.done} / ${p.total}',
                    if (remaining != null) formatRemaining(remaining),
                  ].join(' · '),
            detail: p == null || p.detail.isEmpty ? '启动中…' : p.detail,
            value: p == null || p.total == 0 ? null : p.done / p.total,
            color: t.muted,
            textColor: t.text,
            trailing: TextButton(
              onPressed: () => r.stopCast(widget.book.id),
              child: const Text('暂停', style: TextStyle(fontSize: 12)),
            ),
          ),
        ];
      case AiTaskState.waiting:
        return [
          const SizedBox(height: 10),
          row(
            '排队中，等前面的任务让出本机引擎',
            TextButton(
              onPressed: () => r.stopCast(widget.book.id),
              child: const Text('暂停', style: TextStyle(fontSize: 12)),
            ),
          ),
        ];
      case AiTaskState.failed:
        return [
          const SizedBox(height: 10),
          row(
            r.castError == null ? '人物分析失败' : '人物分析失败：${r.castError}',
            action('重试', _runModel),
            color: const Color(0xFFB3574D),
          ),
        ];
      case AiTaskState.paused:
        return [
          const SizedBox(height: 10),
          row(
            [
              '已暂停',
              if (residual > 0 || unwritten > 0 || outdated > 0)
                _pending(residual, unwritten, outdated),
            ].join(' · '),
            action('继续', _runModel),
          ),
        ];
      case AiTaskState.none:
        if (residual == 0 && unwritten == 0 && outdated == 0) return const [];
        final onlyRewrite = residual == 0 && unwritten == 0;
        return [
          const SizedBox(height: 10),
          row(
            _pending(residual, unwritten, outdated),
            action(
              !_hasModel
                  ? '去下载'
                  : onlyRewrite
                  ? '重写背景'
                  : '让它读',
              _runModel,
            ),
          ),
        ];
    }
  }

  void _tap(Offset p, Size size) {
    final g = _graph!;
    final rect = _canvasRect(size);
    int? hit;
    var best = double.infinity;
    for (var i = 0; i < g.people.length; i++) {
      final c = _scaled(_pos[i], rect);
      final r = _nodeRadius(g, i);
      final d = (c - p).distance;
      if (d <= r + 6 && d < best) {
        best = d;
        hit = i;
      }
    }
    setState(() => _selected = (hit == _selected) ? null : hit);
  }

  Widget _panel(ReadingTheme t, CastGraph g) {
    final sel = _selected;
    return Container(
      // Taller than it was: the background sits above the edges now, and a panel
      // that fits only the background would hide that there are edges at all.
      constraints: const BoxConstraints(maxHeight: 300),
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.muted.withValues(alpha: 0.12))),
      ),
      child: sel == null ? _legend(t) : _relations(t, g, sel),
    );
  }

  Widget _legend(ReadingTheme t) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
    child: Text('点一个人查看', style: TextStyle(color: t.muted, fontSize: 13)),
  );

  /// 「依据：章节概览」, with a note when a better one could now be written.
  /// Nothing while a rewrite from this run is on screen: the stored source
  /// describes the text it replaced.
  String? _sourceLine(CastPerson p) {
    if (_modelBackground.containsKey(p.name)) return null;
    final source = p.backgroundSource;
    final parts = [
      if (source != null) '依据：$source',
      if (p.backgroundOutdated) '可以重写得更完整',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _relations(ReadingTheme t, CastGraph g, int sel) {
    final p = g.people[sel];
    final background = _backgroundOf(p);
    final edges = g.edges.where((e) => e.a == sel || e.b == sel).toList()
      ..sort((x, y) => y.weight.compareTo(x.weight));
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${p.name}${p.aliases.isEmpty ? '' : '（${p.aliases.join('、')}）'}',
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${p.mentions} 次 · ${p.chapters} 章',
              style: TextStyle(color: t.muted, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Who they are comes before who they know: a reader who taps a half-
        // remembered name wants the person, and the edges are the answer to a
        // second question.
        if (background != null) ...[
          const SizedBox(height: 4),
          InkWell(
            onTap: () => _person(t, p, background),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      background,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 13,
                        height: 1.65,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.chevron_right, size: 16, color: t.muted),
                  ),
                ],
              ),
            ),
          ),
          if (_sourceLine(p) case final line?)
            Text(line, style: TextStyle(color: t.muted, fontSize: 10.5)),
          const SizedBox(height: 6),
          Divider(height: 1, color: t.muted.withValues(alpha: 0.12)),
          const SizedBox(height: 8),
        ],
        if (edges.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '无同场关系',
              style: TextStyle(color: t.muted, fontSize: 12),
            ),
          ),
        ...edges.map((e) {
          final other = g.people[e.a == sel ? e.b : e.a].name;
          final summary = _labelOf(e);
          return InkWell(
            onTap: () => _evidence(t, g, e, other),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          other,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          summary ?? '还没总结',
                          style: TextStyle(
                            color: t.muted,
                            fontSize: 12,
                            height: 1.5,
                            fontStyle: summary == null
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      '同场 ${e.weight}',
                      style: TextStyle(color: t.muted, fontSize: 11),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: t.muted),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  /// The background, with the sentences it was written from underneath it. The
  /// model is small and reads only a sample, so anything it says has to remain
  /// checkable against the book in one tap.
  void _person(ReadingTheme t, CastPerson p, String background) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.background,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${p.name}${p.aliases.isEmpty ? '' : '（${p.aliases.join('、')}）'}',
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                background,
                style: TextStyle(color: t.text, fontSize: 13.5, height: 1.7),
              ),
              if (_sourceLine(p) case final line?) ...[
                const SizedBox(height: 6),
                Text(line, style: TextStyle(color: t.muted, fontSize: 11)),
              ],
              const SizedBox(height: 16),
              Text(
                '原文摘句 · ${p.evidence.length} 句',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              ...p.evidence.map(
                (ev) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '第 ${ev.chapter + 1} 章',
                        style: TextStyle(color: t.muted, fontSize: 11),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        ev.text,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13,
                          height: 1.7,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _evidence(ReadingTheme t, CastGraph g, CastRelation e, String other) {
    final summary = _labelOf(e);
    showModalBottomSheet(
      context: context,
      backgroundColor: t.background,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${g.people[e.a].name} ↔ ${g.people[e.b].name}',
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                summary ?? '未总结',
                style: TextStyle(
                  color: summary == null ? t.muted : t.text,
                  fontSize: 13.5,
                  height: 1.7,
                  fontStyle: summary == null
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
              if (e.hints.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '称谓：${e.hints.join('  ')}',
                  style: TextStyle(color: t.muted, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              Text('原文依据', style: TextStyle(color: t.muted, fontSize: 12)),
              const SizedBox(height: 8),
              if (e.evidence.isEmpty)
                Text('无', style: TextStyle(color: t.muted, fontSize: 12))
              else
                ...e.evidence.map(
                  (ev) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第 ${ev.chapter + 1} 章',
                          style: TextStyle(color: t.muted, fontSize: 11),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          ev.text,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 13,
                            height: 1.7,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── painting ────────────────────────────────────────────────────────────────

Rect _canvasRect(Size size) => Rect.fromLTWH(
  40,
  34,
  math.max(size.width - 80, 1),
  math.max(size.height - 80, 1),
);

Offset _scaled(Offset unit, Rect r) =>
    Offset(r.left + unit.dx * r.width, r.top + unit.dy * r.height);

double _nodeRadius(CastGraph g, int i) {
  final maxM = g.people.fold<int>(1, (m, p) => math.max(m, p.mentions));
  final f = math.sqrt(g.people[i].mentions / maxM);
  return 7 + 19 * f;
}

class _GraphPainter extends CustomPainter {
  final CastGraph graph;
  final List<Offset> pos;
  final String? Function(CastRelation) labelOf;
  final int? selected;
  final ReadingTheme theme;

  _GraphPainter({
    required this.graph,
    required this.pos,
    required this.labelOf,
    required this.selected,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (pos.length != graph.people.length) return;
    final rect = _canvasRect(size);
    final maxW = graph.edges.fold<int>(1, (m, e) => math.max(m, e.weight));

    // Edges first, under the nodes.
    for (final e in graph.edges) {
      final incident = selected == null || e.a == selected || e.b == selected;
      final a = _scaled(pos[e.a], rect);
      final b = _scaled(pos[e.b], rect);
      final label = labelOf(e);
      final base = theme.muted;
      final alpha = incident ? (0.30 + 0.55 * (e.weight / maxW)) : 0.06;
      final paint = Paint()
        ..color = base.withValues(alpha: alpha.clamp(0.05, 0.9))
        ..strokeWidth = (1.0 + 3.0 * (e.weight / maxW)) * (incident ? 1 : 0.6)
        ..strokeCap = StrokeCap.round;
      if (label == null) {
        _dashedLine(canvas, a, b, paint);
      } else {
        canvas.drawLine(a, b, paint);
      }
    }

    // Nodes and names.
    for (var i = 0; i < graph.people.length; i++) {
      final c = _scaled(pos[i], rect);
      final r = _nodeRadius(graph, i);
      final isSel = selected == i;
      final dim = selected != null && !isSel && !_isNeighbor(i, selected!);
      final fill = theme.text.withValues(alpha: dim ? 0.18 : 0.9);
      canvas.drawCircle(c, r, Paint()..color = theme.background);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = fill
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSel ? 3 : 1.6,
      );
      canvas.drawCircle(
        c,
        r - 2,
        Paint()..color = theme.text.withValues(alpha: dim ? 0.05 : 0.10),
      );

      final tp = TextPainter(
        text: TextSpan(
          text: graph.people[i].name,
          style: TextStyle(
            color: theme.text.withValues(alpha: dim ? 0.3 : 1),
            fontSize: 12,
            fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy + r + 3));
    }
  }

  bool _isNeighbor(int i, int sel) => graph.edges.any(
    (e) => (e.a == sel && e.b == i) || (e.b == sel && e.a == i),
  );

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 6.0, gap = 5.0;
    final total = (b - a).distance;
    if (total < 1) return;
    final dir = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final s = a + dir * t;
      final e = a + dir * math.min(t + dash, total);
      canvas.drawLine(s, e, paint);
      t += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.selected != selected ||
      old.pos != pos ||
      old.graph != graph ||
      old.theme != theme;
}
