import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/book.dart';
import 'src/rust/api/stats.dart';
import 'theme.dart';

/// Reading statistics, built entirely from the reading log. Everything here is
/// arithmetic over recorded sessions — no AI, no estimates, nothing invented.
class StatsPage extends StatefulWidget {
  final ReadingSettings settings;

  const StatsPage({super.key, required this.settings});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

const _weeks = 26;

class _Stats {
  /// Seconds read per local day, keyed by days-since-epoch of the local date.
  final Map<int, int> byDay;
  final List<BookTime> byBook;
  final ReadingInsights insights;

  _Stats(this.byDay, this.byBook, this.insights);
}

/// Local-date day number. Deliberately not epoch-based: dividing a local
/// midnight's epoch by 86400s shifts the boundary by the UTC offset, and the
/// round-trip lands on the wrong calendar day.
int _dayKey(DateTime local) => DateTime(
  local.year,
  local.month,
  local.day,
).difference(DateTime(2020, 1, 1)).inDays;

/// Inverse of [_dayKey]; the constructor normalizes the overflowing day.
DateTime _dayDate(int key) => DateTime(2020, 1, 1 + key);

int get _tzSecs => DateTime.now().timeZoneOffset.inSeconds;

class _StatsPageState extends State<StatsPage> {
  _Stats? _stats;
  String? _error;

  /// The 阅读画像 — the counted facts, woven into two short paragraphs by
  /// hand-written templates. Instant and model-free, so it is written as soon
  /// as the page opens; 换一篇 draws a new seed, which picks other facts and
  /// other phrasings.
  String? _portrait;
  String? _portraitError;
  bool _portraitBusy = false;
  final _random = math.Random();

  /// Speed in intense vs calm chapters. Decodes books from disk, so it is
  /// asked for once, after the rest, and the portrait waits for it briefly.
  PaceSpeed? _pace;
  Future<void>? _paceAsked;

  @override
  void initState() {
    super.initState();
    _load();
    _genPortrait();
  }

  Future<void> _askPace() => _paceAsked ??= () async {
    try {
      final p = await paceSpeed().timeout(const Duration(seconds: 8));
      if (mounted) setState(() => _pace = p);
    } catch (_) {
      // Too slow or a book would not decode: the page simply goes without.
    }
  }();

  Future<void> _genPortrait() async {
    if (_portraitBusy) return;
    setState(() {
      _portraitBusy = true;
      _portraitError = null;
    });
    try {
      await _askPace();
      final text = await readerPortrait(
        angle: _random.nextInt(1 << 31),
        tzSecs: _tzSecs,
      );
      if (mounted) setState(() => _portrait = text.trim());
    } catch (e) {
      if (mounted) setState(() => _portraitError = '$e');
    } finally {
      if (mounted) setState(() => _portraitBusy = false);
    }
  }

  Future<void> _load() async {
    try {
      final since = DateTime.now().subtract(
        const Duration(days: _weeks * 7 + 7),
      );
      final events = await listEvents(
        since: since.millisecondsSinceEpoch ~/ 1000,
      );
      final byBook = await timePerBook();
      final insights = await readingInsights(tzSecs: _tzSecs);

      final byDay = <int, int>{};
      for (final e in events) {
        // A session is credited to the day it started. Sessions crossing
        // midnight are rare and short; splitting them buys nothing.
        final day = _dayKey(
          DateTime.fromMillisecondsSinceEpoch(e.started * 1000),
        );
        byDay[day] = (byDay[day] ?? 0) + (e.ended - e.started);
      }
      if (mounted) setState(() => _stats = _Stats(byDay, byBook, insights));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('阅读数据', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: t.muted)),
            )
          : _stats == null
          ? Center(child: Bloom(color: t.muted, size: 34))
          : _body(_stats!, t),
    );
  }

  Widget _body(_Stats s, ReadingTheme t) {
    final i = s.insights;
    final today = _dayKey(DateTime.now());
    final total = s.byDay.values.fold(0, (a, b) => a + b);
    final week = List.generate(
      7,
      (i) => s.byDay[today - i] ?? 0,
    ).fold(0, (a, b) => a + b);

    var streak = 0;
    // Today counts if read, but a quiet today doesn't break yesterday's streak.
    for (
      var d = s.byDay.containsKey(today) ? today : today - 1;
      s.byDay.containsKey(d);
      d--
    ) {
      streak++;
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _portraitSection(t),
            const SizedBox(height: 28),
            Divider(color: t.muted.withValues(alpha: 0.16), height: 1),
            const SizedBox(height: 28),
            Row(
              children: [
                _metric(t, _fmtDuration(total), '总时长'),
                _metric(t, _fmtDuration(week), '近 7 天'),
                _metric(t, '$streak 天', '连续阅读'),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                _metric(
                  t,
                  i.speed == null ? '—' : '${_cpm(i.speed!)} 字/分',
                  '阅读速度',
                ),
                _metric(t, '${i.chaptersFinished} 章', '读完章节'),
                _metric(t, '${i.bestStreak} 天', '最长连续'),
              ],
            ),
            const SizedBox(height: 28),
            _label(t, '过去半年'),
            const SizedBox(height: 10),
            _Heatmap(byDay: s.byDay, today: today, theme: t),
            if (i.hours.any((h) => h.toInt() > 0)) ...[
              const SizedBox(height: 28),
              _label(t, '一天中的阅读时段'),
              const SizedBox(height: 10),
              _Bars(
                values: i.hours.map((v) => v.toInt()).toList(),
                labels: {
                  for (final h in [0, 6, 12, 18, 23]) h: '$h',
                },
                tooltip: (h, v) => '$h:00 · ${_fmtDuration(v)}',
                theme: t,
              ),
              const SizedBox(height: 18),
              _label(t, '一周七天'),
              const SizedBox(height: 10),
              _Bars(
                values: i.weekdays.map((v) => v.toInt()).toList(),
                labels: {
                  for (var d = 0; d < 7; d++)
                    d: const ['一', '二', '三', '四', '五', '六', '日'][d],
                },
                tooltip: (d, v) => _fmtDuration(v),
                theme: t,
                height: 44,
              ),
            ],
            const SizedBox(height: 28),
            _speedSection(i, t),
            const SizedBox(height: 28),
            _label(t, '书架'),
            const SizedBox(height: 12),
            Row(
              children: [
                _metric(t, '${i.booksFinished} 本', '读完'),
                _metric(t, '${i.booksReading} 本', '在读'),
                _metric(t, '${i.booksShelved} 本', '搁置'),
                _metric(t, '${i.booksUnopened} 本', '没翻开'),
              ],
            ),
            const SizedBox(height: 28),
            _label(t, '纪录'),
            const SizedBox(height: 6),
            if (i.longestSitting > 0)
              _row(t, '单次最长', _fmtDuration(i.longestSitting.toInt())),
            if (i.typicalSitting != null)
              _row(t, '通常一次', _fmtDuration(i.typicalSitting!.toInt())),
            if (i.topDay case final d?)
              _row(
                t,
                '读得最多的一天',
                _fmtDuration(d.secs.toInt()),
                note: '${d.year}/${d.month}/${d.day}',
              ),
            if (i.chaptersFinished > 0)
              _row(
                t,
                '累计读完',
                '${i.chaptersFinished} 章',
                note: '约 ${_wan(i.charsFinished.toInt())} 万字',
              ),
            if (i.annotations > 0) _row(t, '标注', '${i.annotations} 条'),
            const SizedBox(height: 28),
            if (s.byBook.isNotEmpty) ...[
              _label(t, '各书时长'),
              const SizedBox(height: 4),
              for (final b in s.byBook.take(10)) _bookRow(b, s.byBook.first, t),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(ReadingTheme t, String text) =>
      Text(text, style: TextStyle(color: t.muted, fontSize: 12));

  Widget _speedSection(ReadingInsights i, ReadingTheme t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed, color: t.muted, size: 18),
              const SizedBox(width: 8),
              Text(
                '阅读速度',
                style: TextStyle(
                  color: t.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (i.speed == null) ...[
            _row(t, '已记录', '${i.speedMinutes} 分钟'),
            _row(t, '需要', _fmtDuration(10 * 60)),
          ] else ...[
            Text(
              '${_cpm(i.speed!)} 字/分',
              style: TextStyle(
                color: t.text,
                fontSize: 26,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _row(t, '有效阅读', _fmtDuration(i.speedMinutes.toInt() * 60)),
            if (i.recentSpeed != null && i.earlierSpeed != null) ...[
              _row(t, '近 30 天', '${_cpm(i.recentSpeed!)} 字/分'),
              _row(t, '更早', '${_cpm(i.earlierSpeed!)} 字/分'),
            ],
            if (_pace case final p?) ...[
              _row(t, '激烈章节', '${_cpm(p.intenseCpm)} 字/分'),
              _row(t, '平缓章节', '${_cpm(p.calmCpm)} 字/分'),
            ],
            if (i.fastestBook case final f?)
              _row(t, '读得最快', '${_cpm(f.cpm)} 字/分', book: f.title),
            if (i.slowestBook case final s?)
              _row(t, '读得最慢', '${_cpm(s.cpm)} 字/分', book: s.title),
            _row(t, '快速划过', '${(i.skimShare * 100).round()}%'),
          ],
        ],
      ),
    );
  }

  /// A label and its number, with an optional date, book or aside after it.
  Widget _row(
    ReadingTheme t,
    String label,
    String value, {
    String? note,
    String? book,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Text(label, style: TextStyle(color: t.muted, fontSize: 13)),
        const SizedBox(width: 8),
        Expanded(
          child: book == null
              ? const SizedBox.shrink()
              : Text(
                  '《$book》',
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 13),
                ),
        ),
        if (note != null) ...[
          Text(note, style: TextStyle(color: t.muted, fontSize: 12)),
          const SizedBox(width: 10),
        ],
        Text(value, style: TextStyle(color: t.text, fontSize: 13)),
      ],
    ),
  );

  Widget _portraitSection(ReadingTheme t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined, color: t.muted, size: 18),
              const SizedBox(width: 8),
              Text(
                '阅读画像',
                style: TextStyle(
                  color: t.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_portrait != null && _portrait!.isNotEmpty && !_portraitBusy)
                TextButton(
                  onPressed: _genPortrait,
                  child: const Text('换一篇', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_portraitError != null) ...[
            Text(
              _portraitError!,
              style: const TextStyle(color: Color(0xFFB3574D), fontSize: 13),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _genPortrait, child: const Text('重试')),
          ] else if (_portraitBusy || _portrait == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Bloom(color: t.muted, size: 30)),
            )
          else if (_portrait!.isEmpty)
            Text('还没有足够的阅读记录', style: TextStyle(color: t.muted, fontSize: 13))
          else
            Text(
              _portrait!,
              translate: false,
              style: TextStyle(color: t.text, fontSize: 15, height: 1.7),
            ),
        ],
      ),
    );
  }

  Widget _metric(ReadingTheme t, String value, String label) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: t.text,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: t.muted, fontSize: 12)),
      ],
    ),
  );

  Widget _bookRow(BookTime b, BookTime top, ReadingTheme t) {
    final share = top.seconds > 0 ? b.seconds / top.seconds : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.title,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 13),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 4,
                    backgroundColor: t.muted.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation(
                      t.text.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _fmtDuration(b.seconds),
            style: TextStyle(color: t.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Speeds to the nearest ten: 617 字/分 claims a precision the windows do not
/// have.
String _cpm(double cpm) => '${(cpm / 10).round() * 10}';

String _wan(int chars) {
  final w = chars / 10000;
  return w >= 100 ? '${w.round()}' : w.toStringAsFixed(1);
}

String _fmtDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final m = seconds ~/ 60;
  if (m < 60) return '$m 分钟';
  final h = m / 60;
  if (h >= 10) return '${h.round()} 小时';
  final tenths = (h * 10).round();
  return tenths % 10 == 0 ? '${tenths ~/ 10} 小时' : '${h.toStringAsFixed(1)} 小时';
}

Color _ink(ReadingTheme theme) =>
    theme.isDark ? theme.text : const Color(0xFF2E7D32);

/// A row of bars, tallest one solid, with a few labels underneath.
class _Bars extends StatelessWidget {
  final List<int> values;
  final Map<int, String> labels;
  final String Function(int index, int value) tooltip;
  final ReadingTheme theme;
  final double height;

  const _Bars({
    required this.values,
    required this.labels,
    required this.tooltip,
    required this.theme,
    this.height = 64,
  });

  @override
  Widget build(BuildContext context) {
    final top = values.fold<int>(0, math.max);
    final ink = _ink(theme);
    return Column(
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++)
                Expanded(
                  child: Tooltip(
                    waitDuration: const Duration(milliseconds: 300),
                    message: tooltip(i, values[i]),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      height: top == 0
                          ? 2
                          : math.max(2.0, height * values[i] / top),
                      decoration: BoxDecoration(
                        color: values[i] == top && top > 0
                            ? ink.withValues(alpha: 0.85)
                            : values[i] == 0
                            ? theme.muted.withValues(alpha: 0.12)
                            : ink.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Text(
                  labels[i] ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.muted, fontSize: 10),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// GitHub-style grid: one column per week, one row per weekday, intensity by
/// minutes read. Scrolls horizontally if the window is narrow.
class _Heatmap extends StatelessWidget {
  final Map<int, int> byDay;
  final int today;
  final ReadingTheme theme;

  const _Heatmap({
    required this.byDay,
    required this.today,
    required this.theme,
  });

  Color _cell(int seconds) {
    if (seconds == 0) return theme.muted.withValues(alpha: 0.12);
    final alpha = switch (seconds) {
      < 10 * 60 => 0.3,
      < 30 * 60 => 0.5,
      < 60 * 60 => 0.75,
      _ => 1.0,
    };
    return _ink(theme).withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    // Monday-first columns; the current week is the rightmost column.
    final weekday = DateTime.now().weekday; // 1=Mon..7=Sun
    final thisMonday = today - (weekday - 1);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true, // land on the present, not half a year ago
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var w = _weeks - 1; w >= 0; w--)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: _day(thisMonday - w * 7 + d),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('少 ', style: TextStyle(color: theme.muted, fontSize: 10)),
              for (final s in [0, 5 * 60, 15 * 60, 45 * 60, 90 * 60])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: _swatch(_cell(s)),
                ),
              Text(' 多', style: TextStyle(color: theme.muted, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _day(int day) {
    if (day > today) return const SizedBox(width: 12, height: 12);
    final seconds = byDay[day] ?? 0;
    final date = _dayDate(day);
    return Tooltip(
      waitDuration: const Duration(milliseconds: 400),
      message:
          '${date.month}/${date.day} · ${seconds == 0 ? '未阅读' : _fmtDuration(seconds)}',
      child: _swatch(_cell(seconds)),
    );
  }

  Widget _swatch(Color c) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: c,
      borderRadius: BorderRadius.circular(2.5),
    ),
  );
}
