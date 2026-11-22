import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// Definition of one local reading easter egg (Steam achievement + CS2 MVP
/// round-end banner feel). Unseen eggs appear as `???` in the collection until
/// triggered organically during reading.
class EasterEggDef {
  final String id;
  final String title;
  final IconData icon;

  const EasterEggDef({
    required this.id,
    required this.title,
    required this.icon,
  });
}

/// Stored record of an unlocked easter egg, kept strictly on-device in
/// SharedPreferences.
class EasterEggRecord {
  final String id;
  final int unlockedAtMs;
  final int count;
  final String lastDetail;
  final String bookTitle;

  const EasterEggRecord({
    required this.id,
    required this.unlockedAtMs,
    required this.count,
    required this.lastDetail,
    required this.bookTitle,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'unlockedAtMs': unlockedAtMs,
    'count': count,
    'lastDetail': lastDetail,
    'bookTitle': bookTitle,
  };

  factory EasterEggRecord.fromJson(Map<String, dynamic> m) => EasterEggRecord(
    id: m['id'] as String,
    unlockedAtMs: (m['unlockedAtMs'] as num?)?.toInt() ?? 0,
    count: (m['count'] as num?)?.toInt() ?? 1,
    lastDetail: (m['lastDetail'] as String?) ?? '',
    bookTitle: (m['bookTitle'] as String?) ?? '',
  );
}

/// An active banner event waiting to be shown inside the reader.
class EasterEggEvent {
  final EasterEggDef def;
  final String detail;
  final bool firstTime;

  const EasterEggEvent({
    required this.def,
    required this.detail,
    required this.firstTime,
  });
}

/// Local-only, low-frequency reading easter egg registry & trigger engine.
///
/// Designed to feel rare and surprising:
/// - Strict cooldown (at least 30 minutes between popups, max 1 per session)
/// - First unlock of an egg always fires once its hard threshold is met;
///   repeat triggers only fire with low probability (15%) after cooldown.
/// - Can be turned off completely with a single master toggle in settings.
class EasterEggEngine extends ChangeNotifier {
  static final instance = EasterEggEngine._();
  EasterEggEngine._();

  static const _prefsKey = 'easterEggsUnlocked';
  static const _cooldown = Duration(minutes: 30);
  static const _repeatChance = 0.15;

  static const List<EasterEggDef> catalog = [
    EasterEggDef(id: 'night_owl', title: '深夜修仙者', icon: Icons.nights_stay_outlined),
    EasterEggDef(id: 'early_bird', title: '晨读卷王', icon: Icons.wb_twilight_outlined),
    EasterEggDef(id: 'time_vanish', title: '时间消失术', icon: Icons.hourglass_bottom_outlined),
    EasterEggDef(id: 'speed_demon', title: '匆忙的人', icon: Icons.bolt_outlined),
    EasterEggDef(id: 'deep_ponder', title: '陷入沉思', icon: Icons.psychology_outlined),
    EasterEggDef(id: 'rewind_memory', title: '记忆回溯', icon: Icons.history_outlined),
    EasterEggDef(id: 'dodge_filler', title: '精准避水', icon: Icons.waves_outlined),
    EasterEggDef(id: 'water_tank', title: '抗水达人', icon: Icons.shield_outlined),
    EasterEggDef(id: 'shy_moment', title: '羞羞', icon: Icons.favorite_border),
    EasterEggDef(id: 'book_hopper', title: '书荒巡逻兵', icon: Icons.explore_outlined),
    EasterEggDef(id: 'high_energy', title: '肾上腺素', icon: Icons.local_fire_department_outlined),
    EasterEggDef(id: 'night_marathon', title: '不眠夜', icon: Icons.bedtime_outlined),
  ];

  static final Map<String, EasterEggDef> _byId = {
    for (final d in catalog) d.id: d,
  };

  /// Conservative intimate/romantic keyword set for the `shy_moment` egg
  /// (requires >= 3 distinct hits on the same page plus slowed reading).
  static const _shyWords = [
    '吻', '亲吻', '唇瓣', '轻喘', '喘息', '衣衫', '解开', '贴近', '缠绵',
    '滚烫', '耳垂', '锁骨', '拥入怀', '脸颊通红', '呼吸急促', '暧昧', '红晕',
  ];

  final math.Random _rng = math.Random();
  Map<String, EasterEggRecord> _unlocked = {};
  bool _loaded = false;
  DateTime? _lastPopupAt;
  int _sessionPopups = 0;

  // Cross-book hop tracker (bookId -> timestamp).
  final List<(int, DateTime)> _recentBooks = [];

  // Per-session reader trackers.
  DateTime? _sessionStart;
  DateTime? _pageEnteredAt;
  int _fastWindows = 0;
  final List<DateTime> _backTurns = [];
  int _consecutiveFiller = 0;
  int _consecutiveHighPace = 0;
  int? _lastChapter;

  /// Latest banner to show; listeners (reader page) display and clear it.
  final ValueNotifier<EasterEggEvent?> activeBanner = ValueNotifier(null);

  Map<String, EasterEggRecord> get unlocked => Map.unmodifiable(_unlocked);
  int get unlockedCount => _unlocked.length;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _unlocked = {
          for (final e in decoded.entries)
            if (e.value is Map<String, dynamic> && _byId.containsKey(e.key))
              e.key: EasterEggRecord.fromJson(e.value as Map<String, dynamic>),
        };
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode({
        for (final e in _unlocked.entries) e.key: e.value.toJson(),
      });
      await prefs.setString(_prefsKey, encoded);
    } catch (_) {}
  }

  /// Called when a book is opened in the reader.
  void onBookOpen({
    required int bookId,
    required String bookTitle,
    required bool enabled,
  }) {
    unawaited(ensureLoaded());
    final now = DateTime.now();
    _sessionStart = now;
    _pageEnteredAt = now;
    _sessionPopups = 0;
    _fastWindows = 0;
    _backTurns.clear();
    _consecutiveFiller = 0;
    _consecutiveHighPace = 0;
    _lastChapter = null;

    _recentBooks.removeWhere((e) => now.difference(e.$2).inMinutes > 30);
    if (_recentBooks.every((e) => e.$1 != bookId)) {
      _recentBooks.add((bookId, now));
    }
    if (_recentBooks.length >= 4) {
      _tryTrigger(
        id: 'book_hopper',
        detail: '半小时内连试了 ${_recentBooks.length} 本书，还在找电子榨菜？',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called on each page turn (forward or backward).
  void onPageTurn({
    required bool backward,
    required String visibleText,
    required double? baselineCharsPerMin,
    required String bookTitle,
    required bool enabled,
  }) {
    final now = DateTime.now();
    final prevAt = _pageEnteredAt;
    _pageEnteredAt = now;

    if (backward) {
      _backTurns.add(now);
      _backTurns.removeWhere((t) => now.difference(t).inSeconds > 30);
      if (_backTurns.length >= 6) {
        _backTurns.clear();
        _tryTrigger(
          id: 'rewind_memory',
          detail: '刚刚连续往回翻了 6 页，是不是漏了什么伏笔？',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    }

    if (prevAt != null && !backward) {
      final dwell = now.difference(prevAt).inSeconds;
      // Check shy_moment: >=3 distinct intimate keywords AND slowed dwell.
      if (dwell >= 18 && dwell <= 180 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _shyWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 3) break;
        }
        final expectedSecs = baselineCharsPerMin != null && baselineCharsPerMin > 100
            ? (visibleText.length / baselineCharsPerMin * 60)
            : 12.0;
        if (hits >= 3 && dwell >= expectedSecs * 1.45) {
          _tryTrigger(
            id: 'shy_moment',
            detail: '检测到这一页停留了 $dwell 秒，看得格外仔细哦',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }
      // Deep ponder: stayed on a single page 45s..240s.
      if (dwell >= 45 && dwell <= 240) {
        _tryTrigger(
          id: 'deep_ponder',
          detail: '刚才那一页让你足足停了 $dwell 秒',
          bookTitle: bookTitle,
          enabled: enabled,
        );
      }
    }
  }

  /// Called on each ~30s reading speed window.
  void onSpeedWindow({
    required int chars,
    required int secs,
    required double? baselineCharsPerMin,
    required String bookTitle,
    required bool enabled,
  }) {
    if (secs <= 0 || chars <= 0) return;
    final now = DateTime.now();
    final cpm = chars / secs * 60.0;

    // 1) Speed demon: 3 consecutive fast windows (>2.4x baseline and >=1400 cpm).
    final fastThreshold = baselineCharsPerMin != null && baselineCharsPerMin > 200
        ? math.max(baselineCharsPerMin * 2.4, 1400.0)
        : 1600.0;
    if (cpm >= fastThreshold && cpm < 8000) {
      _fastWindows++;
      if (_fastWindows >= 3) {
        _fastWindows = 0;
        _tryTrigger(
          id: 'speed_demon',
          detail: '刚才飙到了 ${cpm.round()} 字/分，一目十行',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    } else {
      _fastWindows = 0;
    }

    // 2) Session duration & late-night / early-morning eggs.
    final mins = _sessionStart == null
        ? 0
        : now.difference(_sessionStart!).inMinutes;
    final hour = now.hour;
    final minute = now.minute;

    if ((hour == 1 && minute >= 30) || (hour >= 2 && hour < 5)) {
      if (mins >= 45) {
        _tryTrigger(
          id: 'night_marathon',
          detail: '凌晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}，已连续看了 $mins 分钟',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
      if (mins >= 15) {
        _tryTrigger(
          id: 'night_owl',
          detail: '凌晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} 还在书海里修仙',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    }

    if ((hour == 5 && minute >= 30) || hour == 6) {
      if (mins >= 10) {
        _tryTrigger(
          id: 'early_bird',
          detail: '清晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} 就已经开卷了',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    }

    if (mins >= 60) {
      _tryTrigger(
        id: 'time_vanish',
        detail: '不知不觉已经连续看了 $mins 分钟',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called when the reader advances or jumps to a new chapter.
  void onChapterChanged({
    required int chapterIndex,
    required List<double?>? fillerScores,
    required List<double?>? paceScores,
    required String bookTitle,
    required bool enabled,
  }) {
    final prev = _lastChapter;
    _lastChapter = chapterIndex;
    if (prev == null || prev == chapterIndex) return;

    final jump = chapterIndex - prev;
    if (jump >= 4 && fillerScores != null) {
      // Skipped >= 3 chapters: check if they were padded!
      final skipped = <double>[];
      for (var c = prev + 1; c < chapterIndex && c < fillerScores.length; c++) {
        final v = fillerScores[c];
        if (v != null) skipped.add(v);
      }
      if (skipped.length >= 3) {
        final avg = skipped.reduce((a, b) => a + b) / skipped.length;
        if (avg >= 0.62) {
          _tryTrigger(
            id: 'dodge_filler',
            detail: '刚刚精准绕过了 ${skipped.length} 章高水分剧情',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }
    }

    if (jump == 1) {
      // Sequential read: track consecutive padded or high-pace chapters.
      if (fillerScores != null &&
          prev >= 0 &&
          prev < fillerScores.length &&
          (fillerScores[prev] ?? 0) >= 0.65) {
        _consecutiveFiller++;
        if (_consecutiveFiller >= 4) {
          _consecutiveFiller = 0;
          _tryTrigger(
            id: 'water_tank',
            detail: '你居然一字不漏扛完了连续 4 章高注水剧情',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      } else {
        _consecutiveFiller = 0;
      }

      if (paceScores != null &&
          prev >= 0 &&
          prev < paceScores.length &&
          (paceScores[prev] ?? 0) >= 1.2) {
        _consecutiveHighPace++;
        if (_consecutiveHighPace >= 3) {
          _consecutiveHighPace = 0;
          _tryTrigger(
            id: 'high_energy',
            detail: '连看 3 章高能剧情，手心出汗了吗？',
            bookTitle: bookTitle,
            enabled: enabled,
          );
        }
      } else {
        _consecutiveHighPace = 0;
      }
    } else {
      _consecutiveFiller = 0;
      _consecutiveHighPace = 0;
    }
  }

  bool _tryTrigger({
    required String id,
    required String detail,
    required String bookTitle,
    required bool enabled,
  }) {
    if (!enabled) return false;
    final def = _byId[id];
    if (def == null) return false;
    final now = DateTime.now();

    // Hard budget: max 1 popup per session, >= 30 min global cooldown.
    if (_sessionPopups >= 1) return false;
    if (_lastPopupAt != null && now.difference(_lastPopupAt!) < _cooldown) {
      return false;
    }

    final existing = _unlocked[id];
    final firstTime = existing == null;
    if (!firstTime && _rng.nextDouble() > _repeatChance) {
      return false;
    }

    _lastPopupAt = now;
    _sessionPopups++;
    _unlocked[id] = EasterEggRecord(
      id: id,
      unlockedAtMs: existing?.unlockedAtMs ?? now.millisecondsSinceEpoch,
      count: (existing?.count ?? 0) + 1,
      lastDetail: detail,
      bookTitle: bookTitle,
    );
    unawaited(_save());
    notifyListeners();
    activeBanner.value = EasterEggEvent(
      def: def,
      detail: detail,
      firstTime: firstTime,
    );
    return true;
  }

  void dismissBanner() {
    if (activeBanner.value != null) {
      activeBanner.value = null;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _unlocked.clear();
    _lastPopupAt = null;
    _sessionPopups = 0;
    _recentBooks.clear();
    _backTurns.clear();
    _fastWindows = 0;
    _consecutiveFiller = 0;
    _consecutiveHighPace = 0;
    _lastChapter = null;
    activeBanner.value = null;
    _loaded = true;
  }
}

/// Swipe-away top banner shown inside the reader when an easter egg fires.
class EasterEggBannerOverlay extends StatefulWidget {
  final ReadingTheme theme;

  const EasterEggBannerOverlay({super.key, required this.theme});

  @override
  State<EasterEggBannerOverlay> createState() => _EasterEggBannerOverlayState();
}

class _EasterEggBannerOverlayState extends State<EasterEggBannerOverlay> {
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    EasterEggEngine.instance.activeBanner.addListener(_onBanner);
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    EasterEggEngine.instance.activeBanner.removeListener(_onBanner);
    super.dispose();
  }

  void _onBanner() {
    _autoHide?.cancel();
    if (EasterEggEngine.instance.activeBanner.value != null) {
      _autoHide = Timer(const Duration(milliseconds: 4500), () {
        EasterEggEngine.instance.dismissBanner();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return ValueListenableBuilder<EasterEggEvent?>(
      valueListenable: EasterEggEngine.instance.activeBanner,
      builder: (context, event, _) {
        if (event == null) return const SizedBox.shrink();
        final topPad = MediaQuery.paddingOf(context).top;
        return Positioned(
          top: topPad + 10,
          left: 16,
          right: 16,
          child: Dismissible(
            key: ValueKey('${event.def.id}_${event.detail}'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) => EasterEggEngine.instance.dismissBanner(),
            child: GestureDetector(
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -100) {
                  EasterEggEngine.instance.dismissBanner();
                }
              },
              child: Material(
                color: t.raisedSurface,
                elevation: 6,
                shadowColor: Colors.black38,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: t.muted.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: t.text.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(event.def.icon, color: t.text, size: 19),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  event.def.title,
                                  style: TextStyle(
                                    color: t.text,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (event.firstTime) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: t.text.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '新彩蛋',
                                      style: TextStyle(
                                        color: t.text,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              event.detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: t.muted,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
