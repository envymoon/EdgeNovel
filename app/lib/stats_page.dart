import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'src/rust/api/ai.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

/// Reading statistics, built entirely from reading_events. Everything here is
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

  _Stats(this.byDay, this.byBook);
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

class _StatsPageState extends State<StatsPage> {
  _Stats? _stats;
  String? _error;

  /// The generated 阅读画像 — the counted facts above, woven into a paragraph.
  /// On-demand: nothing runs the model until the reader asks, and 换一篇 rotates
  /// the angle so it reads differently each time rather than being cached.
  String? _portrait;
  String? _portraitError;
  bool _portraitBusy = false;
  int _angle = math.Random().nextInt(5);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _genPortrait() async {
    if (_portraitBusy) return;
    setState(() {
      _portraitBusy = true;
      _portraitError = null;
    });
    try {
      final text = await readerPortrait(
        angle: _angle,
        tzSecs: DateTime.now().timeZoneOffset.inSeconds,
      );
      if (mounted) {
        setState(() {
          _portrait = text.trim();
          // Move the lens on for next time, so 换一篇 is a new read, not a reword.
          _angle = (_angle + 1 + math.Random().nextInt(4)) % 5;
        });
      }
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

      final byDay = <int, int>{};
      for (final e in events) {
        // A session is credited to the day it started. Sessions crossing
        // midnight are rare and short; splitting them buys nothing.
        final day = _dayKey(
          DateTime.fromMillisecondsSinceEpoch(e.started * 1000),
        );
        byDay[day] = (byDay[day] ?? 0) + (e.ended - e.started);
      }
      setState(() => _stats = _Stats(byDay, byBook));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
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

    return ListView(
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
        const SizedBox(height: 28),
        Text('过去半年', style: TextStyle(color: t.muted, fontSize: 12)),
        const SizedBox(height: 10),
        _Heatmap(byDay: s.byDay, today: today, theme: t),
        const SizedBox(height: 28),
        if (s.byBook.isNotEmpty) ...[
          Text('各书时长', style: TextStyle(color: t.muted, fontSize: 12)),
          const SizedBox(height: 4),
          for (final b in s.byBook.take(10)) _bookRow(b, s.byBook.first, t),
        ],
      ],
    );
  }

  Widget _portraitSection(ReadingTheme t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.muted.withValues(alpha: 0.06),
        border: Border.all(color: t.muted.withValues(alpha: 0.16)),
        borderRadius: BorderRadius.circular(12),
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
              if (_portrait != null && !_portraitBusy)
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
          ] else if (_portraitBusy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Bloom(color: t.muted, size: 30)),
            )
          else if (_portrait == null) ...[
            Text(
              '让本地 AI 根据阅读记录，整理一份只属于你的阅读观察。',
              style: TextStyle(color: t.muted, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _genPortrait,
              icon: const Icon(Icons.auto_awesome, size: 17),
              label: const Text('生成阅读画像'),
            ),
          ] else if (_portrait!.isEmpty)
            Text('还没有足够的阅读记录', style: TextStyle(color: t.muted, fontSize: 13))
          else
            Text(
              _portrait!,
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

String _fmtDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final m = seconds ~/ 60;
  if (m < 60) return '$m 分钟';
  final h = m / 60;
  return h >= 10 ? '${h.round()} 小时' : '${h.toStringAsFixed(1)} 小时';
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
    final base = theme.isDark ? theme.text : const Color(0xFF2E7D32);
    return base.withValues(alpha: alpha);
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
