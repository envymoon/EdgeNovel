import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'bloom.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// 地点图 — where the book happens, counted from the text (novel_core::places).
///
/// Places are linked by the story moving between them, not by sharing a
/// sentence: each chapter is set somewhere, and a change of setting is a
/// trip. The strip on top is the book cut where its maps change; a stage
/// picked there narrows the graph to its own chapters.
class PlaceGraphPage extends StatefulWidget {
  final ShelfItem book;
  final ReadingSettings settings;

  const PlaceGraphPage({super.key, required this.book, required this.settings});

  @override
  State<PlaceGraphPage> createState() => _PlaceGraphPageState();
}

class _Trip {
  final int a, b;
  final int count;
  const _Trip(this.a, this.b, this.count);
}

class _Group {
  final String name;
  final List<int> members;
  const _Group(this.name, this.members);
}

class _PlaceGraphPageState extends State<PlaceGraphPage> {
  PlaceAtlas? _atlas;
  String? _error;

  /// The stage picked on the strip, or null for the whole book.
  int? _stage;

  /// The place picked, by index into the atlas's places.
  int? _selected;

  // What the graph shows for the current range.
  List<int> _nodes = const [];
  Map<int, int> _here = const {};
  List<_Trip> _allTrips = const [];
  List<_Trip> _trips = const [];
  List<_Trip> _belong = const [];
  List<_Group> _groups = const [];
  List<Offset> _pos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await placeAtlas(
        path: widget.book.path,
        bookId: widget.book.id,
        upToChapter: widget.book.chapterCount,
      );
      if (!mounted) return;
      setState(() {
        _atlas = a;
        _error = null;
        if (_stage != null && _stage! >= a.stages.length) _stage = null;
        if (_selected != null && _selected! >= a.places.length) {
          _selected = null;
        }
        _build();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _setRemoved(String name, bool removed) async {
    try {
      await removePlace(
        bookId: widget.book.id,
        name: name,
        removed: removed,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    setState(() => _selected = null);
    await _load();
  }

  (int, int) get _range {
    final a = _atlas!;
    final s = _stage;
    if (s == null) return (0, math.max(a.setting.length - 1, 0));
    return (a.stages[s].from, a.stages[s].to);
  }

  /// Trips made within chapters [from]..[to]: the setting changing from one
  /// place to another, either way round counted as one route.
  List<_Trip> _tripsIn(int from, int to) {
    final setting = _atlas!.setting;
    final m = <(int, int), int>{};
    var last = -1;
    for (var c = 0; c < setting.length; c++) {
      final p = setting[c];
      if (p < 0) continue;
      if (last >= 0 && last != p && c >= from && c <= to) {
        final k = (math.min(last, p), math.max(last, p));
        m[k] = (m[k] ?? 0) + 1;
      }
      last = p;
    }
    return [for (final e in m.entries) _Trip(e.key.$1, e.key.$2, e.value)];
  }

  /// Keep the backbone routes (max spanning forest + strongest secondary edges)
  /// so the graph reads as a map instead of a hairball.
  List<_Trip> _pruneTrips(int n, List<_Trip> all) {
    if (n <= 5 || all.length <= n) return all;
    final sorted = [...all]..sort((x, y) => y.count.compareTo(x.count));
    final parent = List<int>.generate(n, (i) => i);
    int find(int x) => parent[x] == x ? x : parent[x] = find(parent[x]);

    final kept = <_Trip>[];
    final deg = List<int>.filled(n, 0);
    final used = List<bool>.filled(sorted.length, false);

    // 1) Maximum spanning forest preserves connectivity along primary routes.
    for (var i = 0; i < sorted.length; i++) {
      final e = sorted[i];
      final ra = find(e.a), rb = find(e.b);
      if (ra != rb) {
        parent[ra] = rb;
        kept.add(e);
        deg[e.a]++;
        deg[e.b]++;
        used[i] = true;
      }
    }
    // 2) Add strongest repeated routes up to a clean edge budget.
    final cap = math.max(n, (n * 1.25).round());
    for (var i = 0; i < sorted.length && kept.length < cap; i++) {
      if (used[i]) continue;
      final e = sorted[i];
      if (e.count < 2) break;
      if (deg[e.a] < 3 && deg[e.b] < 3) {
        kept.add(e);
        deg[e.a]++;
        deg[e.b]++;
      }
    }
    return kept;
  }

  /// The places the story stands in within the range, the most chapters
  /// first, and the pruned routes and area groups among them.
  void _build() {
    final a = _atlas!;
    final (from, to) = _range;
    final here = <int, int>{};
    for (var c = from; c <= to && c < a.setting.length; c++) {
      final p = a.setting[c];
      if (p >= 0) here[p] = (here[p] ?? 0) + 1;
    }
    final ranked = here.keys.toList()
      ..sort((x, y) => here[y]!.compareTo(here[x]!));
    var nodes = ranked.take(_stage == null ? 14 : 11).toList();
    if (nodes.length < 3 && _stage != null) {
      nodes = {...nodes, ...a.stages[_stage!].spots}.take(8).toList();
    }
    final idx = {for (var i = 0; i < nodes.length; i++) nodes[i]: i};
    final allTrips = [
      for (final t in _tripsIn(from, to))
        if (idx.containsKey(t.a) && idx.containsKey(t.b))
          _Trip(idx[t.a]!, idx[t.b]!, t.count),
    ];
    final trips = _pruneTrips(nodes.length, allTrips);

    // Group nodes that share a parent region (even if that parent is a macro
    // region like 深层世界 or 中国 that does not appear as a node itself).
    final byParent = <int, List<int>>{};
    for (var i = 0; i < nodes.length; i++) {
      final p = a.places[nodes[i]].parent;
      if (p != null && p < a.places.length) {
        byParent.putIfAbsent(p, () => []).add(i);
      }
    }
    final groups = <_Group>[];
    final groupedNodes = <int>{};
    for (final entry in byParent.entries) {
      final members = [...entry.value];
      final parentNodeIdx = idx[entry.key];
      if (parentNodeIdx != null && !members.contains(parentNodeIdx)) {
        members.add(parentNodeIdx);
      }
      if (members.length >= 2) {
        groups.add(_Group(a.places[entry.key].name, members));
        groupedNodes.addAll(members);
      }
    }

    // Only draw dashed belonging lines when not already enclosed by a group box.
    final belong = [
      for (final p in nodes)
        if (a.places[p].parent case final parent? when idx.containsKey(parent))
          if (!(groupedNodes.contains(idx[p]!) &&
              groupedNodes.contains(idx[parent]!)))
            _Trip(idx[p]!, idx[parent]!, 1),
    ];

    _nodes = nodes;
    _here = here;
    _allTrips = allTrips;
    _trips = trips;
    _belong = belong;
    _groups = groups;
    _pos = _layout(nodes.length, [...trips, ...belong], groups);
  }

  void _setStage(int? k) => setState(() {
    _stage = (_stage == k) ? null : k;
    _selected = null;
    _build();
  });

  // ── grouped force-directed layout + overlap separation ───────────────────
  List<Offset> _layout(int n, List<_Trip> edges, List<_Group> groups) {
    if (n == 0) return const [];
    if (n == 1) return const [Offset(0.5, 0.5)];
    final rnd = math.Random(7);
    final groupOf = List<int>.filled(n, -1);
    for (var g = 0; g < groups.length; g++) {
      for (final m in groups[g].members) {
        if (groupOf[m] < 0) groupOf[m] = g;
      }
    }
    // Seed nodes grouped by area around the circle so clusters start together.
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => groupOf[a].compareTo(groupOf[b]));
    final pos = List<Offset>.filled(n, Offset.zero);
    for (var slot = 0; slot < n; slot++) {
      final i = order[slot];
      final a = 2 * math.pi * slot / n;
      pos[i] = Offset(
        0.5 + 0.36 * math.cos(a) + (rnd.nextDouble() - 0.5) * 0.02,
        0.5 + 0.36 * math.sin(a) + (rnd.nextDouble() - 0.5) * 0.02,
      );
    }

    final k = 0.95 / math.sqrt(n);
    var temp = 0.10;
    for (var iter = 0; iter < 300; iter++) {
      final disp = List<Offset>.filled(n, Offset.zero);
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          var d = pos[i] - pos[j];
          var dist = d.distance;
          if (dist < 1e-4) {
            d = Offset(rnd.nextDouble() - 0.5, rnd.nextDouble() - 0.5);
            dist = d.distance;
          }
          final sameGroup = groupOf[i] >= 0 && groupOf[i] == groupOf[j];
          // Repel other-group nodes harder so group boxes stay apart.
          final repScale = sameGroup ? 0.8 : 1.25;
          final u = d / dist * (k * k / dist * repScale);
          disp[i] += u;
          disp[j] -= u;
          if (sameGroup) {
            final pull = d / dist * (dist * dist / k * 0.35);
            disp[i] -= pull;
            disp[j] += pull;
          }
        }
      }
      for (final e in edges) {
        final d = pos[e.a] - pos[e.b];
        final dist = math.max(d.distance, 1e-3);
        final f = dist * dist / k * (0.55 + 0.45 * math.min(e.count, 5) / 5);
        final u = d / dist * f;
        disp[e.a] -= u;
        disp[e.b] += u;
      }
      for (var i = 0; i < n; i++) {
        var dd = disp[i] + (const Offset(0.5, 0.5) - pos[i]) * 0.05;
        final dl = dd.distance;
        if (dl > temp) dd = dd / dl * temp;
        pos[i] += dd;
      }
      temp *= 0.985;
    }

    List<Offset> normalize(List<Offset> pts) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = -double.infinity, maxY = -double.infinity;
      for (final p in pts) {
        minX = math.min(minX, p.dx);
        minY = math.min(minY, p.dy);
        maxX = math.max(maxX, p.dx);
        maxY = math.max(maxY, p.dy);
      }
      final w = math.max(maxX - minX, 1e-3), h = math.max(maxY - minY, 1e-3);
      return [for (final p in pts) Offset((p.dx - minX) / w, (p.dy - minY) / h)];
    }

    var norm = normalize(pos);
    // Final collision pass so circles and labels never pile on top of each other.
    final minDist = (0.22 - 0.004 * n).clamp(0.14, 0.20);
    for (var pass = 0; pass < 24; pass++) {
      var moved = false;
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          var d = norm[i] - norm[j];
          var dist = d.distance;
          if (dist < minDist) {
            if (dist < 1e-4) {
              d = const Offset(0.01, 0.01);
              dist = d.distance;
            }
            final push = d / dist * ((minDist - dist) * 0.5);
            norm[i] += push;
            norm[j] -= push;
            moved = true;
          }
        }
      }
      if (!moved) break;
    }
    return normalize(norm);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final a = _atlas;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text(
          '地点图 · ${widget.book.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 17),
        ),
      ),
      body: a == null ? _opening(t) : _content(t, a),
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
              Text('正在扫描地点…', style: TextStyle(color: t.muted, fontSize: 13)),
            ],
          ),
  );

  Widget _content(ReadingTheme t, PlaceAtlas a) {
    if (a.places.isEmpty || _nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '还没认出足够的地点',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.muted, fontSize: 13, height: 1.8),
              ),
              if (a.removed.isNotEmpty) ...[
                const SizedBox(height: 12),
                _removedSection(t, a),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        _bar(t, a),
        Expanded(
          child: LayoutBuilder(
            builder: (_, box) => GestureDetector(
              onTapUp: (d) => _tap(d.localPosition, box.biggest),
              child: CustomPaint(
                size: Size.infinite,
                painter: _PlacePainter(
                  names: [for (final p in _nodes) a.places[p].name],
                  ranks: [for (final p in _nodes) a.places[p].rank],
                  size: [for (final p in _nodes) _here[p] ?? 1],
                  trips: _trips,
                  allTrips: _allTrips,
                  belong: _belong,
                  groups: _groups,
                  pos: _pos,
                  selected: _selectedNode,
                  theme: t,
                ),
              ),
            ),
          ),
        ),
        _panel(t, a),
      ],
    );
  }

  int? get _selectedNode {
    final s = _selected;
    if (s == null) return null;
    final i = _nodes.indexOf(s);
    return i < 0 ? null : i;
  }

  Widget _bar(ReadingTheme t, PlaceAtlas a) {
    final (from, to) = _range;
    final routes = _tripsIn(0, a.setting.length - 1).length;
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
                  _stage == null
                      ? '全书 ${a.upto} 章 · ${a.places.length} 处 · '
                            '${a.stages.length} 段地图 · $routes 条路线'
                      : '第 ${from + 1}–${to + 1} 章 · ${_nodes.length} 处 · '
                            '${_allTrips.length} 条路线',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: 12),
                ),
              ),
              if (_stage != null)
                GestureDetector(
                  onTap: () => _setStage(null),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      '返回全书',
                      style: TextStyle(
                        color: t.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (a.stages.length > 1) ...[
            const SizedBox(height: 8),
            _strip(t, a),
          ],
        ],
      ),
    );
  }

  /// Fixed "全书" pill on the left + the book as its maps, each as wide as its
  /// chapters; tapping 全书 always returns to the full-book graph.
  Widget _strip(ReadingTheme t, PlaceAtlas a) {
    final n = math.max(a.setting.length, 1);
    final floor = math.max(n ~/ 150, 1);
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setStage(null),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _stage == null
                    ? t.text
                    : t.muted.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '全书',
                style: TextStyle(
                  color: _stage == null ? t.background : t.muted,
                  fontSize: 11,
                  fontWeight: _stage == null ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  for (var k = 0; k < a.stages.length; k++) ...[
                    if (k > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: math.max(
                        a.stages[k].to - a.stages[k].from + 1,
                        floor,
                      ),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _setStage(k),
                        child: Container(
                          alignment: Alignment.center,
                          color: _stage == k
                              ? t.text
                              : t.muted.withValues(alpha: 0.14),
                          child:
                              (a.stages[k].to - a.stages[k].from + 1) / n > 0.08
                              ? Text(
                                  a.places[a.stages[k].area].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  softWrap: false,
                                  style: TextStyle(
                                    color: _stage == k ? t.background : t.muted,
                                    fontSize: 11,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _tap(Offset p, Size size) {
    final rect = _canvasRect(size);
    int? hit;
    var best = double.infinity;
    for (var i = 0; i < _nodes.length; i++) {
      final c = _scaled(_pos[i], rect);
      final r = _radius(_sizes, i, _atlas!.places[_nodes[i]].rank);
      final d = (c - p).distance;
      if (d <= r + 8 && d < best) {
        best = d;
        hit = i;
      }
    }
    final place = hit == null ? null : _nodes[hit];
    setState(() => _selected = place == _selected ? null : place);
  }

  List<int> get _sizes => [for (final p in _nodes) _here[p] ?? 1];

  Widget _panel(ReadingTheme t, PlaceAtlas a) {
    final sel = _selected;
    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.muted.withValues(alpha: 0.12))),
      ),
      child: sel == null ? _overview(t, a) : _place(t, a, sel),
    );
  }

  /// With nothing picked: the maps in order, then every place, then removed.
  Widget _overview(ReadingTheme t, PlaceAtlas a) {
    final small = TextStyle(color: t.muted, fontSize: 12);
    final byScenes = List<int>.generate(a.places.length, (i) => i)
      ..sort((x, y) => a.places[y].settings.compareTo(a.places[x].settings));
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 18),
      children: [
        if (a.stages.length > 1) ...[
          for (var k = 0; k < a.stages.length; k++)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _setStage(k),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: _stage == k ? t.muted.withValues(alpha: 0.14) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        '第 ${a.stages[k].from + 1}–${a.stages[k].to + 1} 章',
                        style: small,
                      ),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: a.places[a.stages[k].area].name,
                              style: TextStyle(
                                color: t.text,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: [
                                '',
                                for (final s in a.stages[k].spots.skip(1).take(4))
                                  a.places[s].name,
                              ].join(' · '),
                              style: TextStyle(color: t.muted),
                            ),
                          ],
                        ),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (final i in byScenes)
                InkWell(
                  onTap: () => setState(() => _selected = i),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: a.places[i].name,
                          style: TextStyle(color: t.text),
                        ),
                        TextSpan(
                          text: ' ${a.places[i].settings}',
                          style: TextStyle(color: t.muted),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 12.5, height: 1.6),
                  ),
                ),
            ],
          ),
        ),
        if (a.removed.isNotEmpty) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _removedSection(t, a),
          ),
        ],
      ],
    );
  }

  Widget _removedSection(ReadingTheme t, PlaceAtlas a) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '已移除 ${a.removed.length} 处（点击恢复）',
        style: TextStyle(color: t.muted, fontSize: 11.5),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final name in a.removed)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _setRemoved(name, false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.muted.withValues(alpha: 0.25)),
                ),
                child: Text(
                  '+ $name',
                  style: TextStyle(color: t.muted, fontSize: 11.5),
                ),
              ),
            ),
        ],
      ),
    ],
  );

  Widget _place(ReadingTheme t, PlaceAtlas a, int sel) {
    final p = a.places[sel];
    final (from, to) = _range;
    final routes =
        [
          for (final e in _tripsIn(from, to))
            if (e.a == sel || e.b == sel) (e.a == sel ? e.b : e.a, e.count),
        ]..sort((x, y) => y.$2.compareTo(x.$2));
    final chapters = [
      for (var c = from; c <= to && c < a.setting.length; c++)
        if (a.setting[c] == sel) c + 1,
    ];
    final body = TextStyle(color: t.text, fontSize: 13, height: 1.65);
    final small = TextStyle(color: t.muted, fontSize: 11.5, height: 1.6);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                p.name,
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _setRemoved(p.name, true),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                '移除',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _selected = null),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 18, color: t.muted),
            ),
          ],
        ),
        Text(
          [
            '首次出现第 ${p.firstChapter + 1} 章',
            '提及 ${p.mentions} 次',
            '故事在这里 ${chapters.length} 章',
            if (p.parent case final parent?) '属于 ${a.places[parent].name}',
          ].join(' · '),
          style: small,
        ),
        if (routes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '来往：${routes.map((r) => '${a.places[r.$1].name} ${r.$2} 次').join('、')}',
            style: body,
          ),
        ],
        if (p.people.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('常在这里的人：${p.people.join('、')}', style: body),
        ],
        if (chapters.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '章节：${chapters.take(30).join('、')}${chapters.length > 30 ? '…' : ''}',
            style: small,
          ),
        ],
      ],
    );
  }
}

// ── painting ────────────────────────────────────────────────────────────────

Rect _canvasRect(Size size) => Rect.fromLTWH(
  48,
  36,
  math.max(size.width - 96, 1),
  math.max(size.height - 80, 1),
);

Offset _scaled(Offset unit, Rect r) =>
    Offset(r.left + unit.dx * r.width, r.top + unit.dy * r.height);

double _radius(List<int> size, int i, int rank) {
  final most = size.fold<int>(1, math.max);
  final base = 6.5 + 14.5 * math.sqrt(size[i] / most);
  if (rank >= 4) return base + 2.5;
  if (rank <= 1) return math.max(5.5, base - 1.5);
  return base;
}

class _PlacePainter extends CustomPainter {
  final List<String> names;
  final List<int> ranks;
  final List<int> size;
  final List<_Trip> trips;
  final List<_Trip> allTrips;
  final List<_Trip> belong;
  final List<_Group> groups;
  final List<Offset> pos;
  final int? selected;
  final ReadingTheme theme;

  _PlacePainter({
    required this.names,
    required this.ranks,
    required this.size,
    required this.trips,
    required this.allTrips,
    required this.belong,
    required this.groups,
    required this.pos,
    required this.selected,
    required this.theme,
  });

  List<_Trip> get _activeTrips => selected == null
      ? trips
      : [
          for (final e in allTrips)
            if (e.a == selected || e.b == selected) e,
        ];

  bool _touches(_Trip e) =>
      selected == null || e.a == selected || e.b == selected;

  bool _near(int i) =>
      selected == null ||
      i == selected ||
      [..._activeTrips, ...belong].any(
        (e) => (e.a == selected && e.b == i) || (e.b == selected && e.a == i),
      );

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (pos.length != names.length) return;
    final rect = _canvasRect(canvasSize);
    final drawnTrips = _activeTrips;
    final most = drawnTrips.fold<int>(1, (m, e) => math.max(m, e.count));

    // 1) Region group frames behind everything.
    for (final g in groups) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = -double.infinity, maxY = -double.infinity;
      for (final m in g.members) {
        final c = _scaled(pos[m], rect);
        final r = _radius(size, m, ranks[m]);
        minX = math.min(minX, c.dx - r - 20);
        minY = math.min(minY, c.dy - r - 14);
        maxX = math.max(maxX, c.dx + r + 20);
        maxY = math.max(maxY, c.dy + r + 24);
      }
      final box = RRect.fromLTRBR(
        minX,
        minY - 12,
        maxX,
        maxY,
        const Radius.circular(14),
      );
      final groupActive =
          selected == null || g.members.any((m) => _near(m));
      canvas.drawRRect(
        box,
        Paint()
          ..color = theme.muted.withValues(alpha: groupActive ? 0.06 : 0.025),
      );
      canvas.drawRRect(
        box,
        Paint()
          ..color = theme.muted.withValues(alpha: groupActive ? 0.24 : 0.08)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      final label = TextPainter(
        text: TextSpan(
          text: g.name,
          style: TextStyle(
            color: theme.muted.withValues(alpha: groupActive ? 0.85 : 0.3),
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(minX + 8, minY - 9));
    }

    // 2) Routes: pruned backbone when idle, full routes for selected node.
    for (final e in drawnTrips) {
      final on = _touches(e);
      canvas.drawLine(
        _scaled(pos[e.a], rect),
        _scaled(pos[e.b], rect),
        Paint()
          ..color = theme.muted.withValues(
            alpha: on ? 0.26 + 0.52 * e.count / most : 0.06,
          )
          ..strokeWidth = (1.0 + 2.6 * e.count / most) * (on ? 1 : 0.6)
          ..strokeCap = StrokeCap.round,
      );
    }

    // 3) Unboxed belonging links: dashed.
    for (final e in belong) {
      _dashed(
        canvas,
        _scaled(pos[e.a], rect),
        _scaled(pos[e.b], rect),
        Paint()
          ..color = theme.muted.withValues(alpha: _touches(e) ? 0.5 : 0.08)
          ..strokeWidth = 1.1,
      );
    }

    // 4) Nodes, styled by scale (rank).
    for (var i = 0; i < names.length; i++) {
      final c = _scaled(pos[i], rect);
      final r = _radius(size, i, ranks[i]);
      final isSel = selected == i;
      final dim = !_near(i);
      final isMacro = ranks[i] >= 4;
      final isSpot = ranks[i] <= 1;

      canvas.drawCircle(c, r, Paint()..color = theme.background);
      if (isMacro) {
        // Double ring marks macro regions / provinces / countries.
        canvas.drawCircle(
          c,
          r + 3,
          Paint()
            ..color = theme.text.withValues(alpha: dim ? 0.10 : 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
      }
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = theme.text.withValues(alpha: dim ? 0.18 : (isSpot ? 0.72 : 0.92))
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSel ? 2.8 : (isSpot ? 1.2 : 1.7),
      );
      canvas.drawCircle(
        c,
        math.max(r - 2, 1),
        Paint()
          ..color = theme.text.withValues(
            alpha: dim ? 0.04 : (isMacro ? 0.14 : 0.09),
          ),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: names[i],
          style: TextStyle(
            color: theme.text.withValues(alpha: dim ? 0.28 : 1),
            fontSize: isMacro ? 12.5 : (isSpot ? 11.2 : 11.8),
            fontWeight: isSel || isMacro ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy + r + (isMacro ? 5 : 3)));
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 6.0, gap = 5.0;
    final total = (b - a).distance;
    if (total < 1) return;
    final dir = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      canvas.drawLine(
        a + dir * t,
        a + dir * math.min(t + dash, total),
        paint,
      );
      t += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_PlacePainter old) =>
      old.selected != selected ||
      old.pos != pos ||
      old.trips != trips ||
      old.theme != theme;
}
