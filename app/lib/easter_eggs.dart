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

/// Local-only, surprise reading easter egg registry & trigger engine.
///
/// Each individual egg has a deliberately high bar so it feels earned and
/// unexpected, while a broad catalog (28 eggs across time, pace, habits,
/// text moments, audio, and rare coincidences) makes organic encounters more
/// rewarding over time.
/// - Global cooldown: at least 25 minutes between popups (max 2 per session).
/// - First unlock fires once its threshold is met; repeat triggers only fire
///   with low probability (15%) after cooldown.
/// - Controlled by a single master toggle in settings.
class EasterEggEngine extends ChangeNotifier {
  static final instance = EasterEggEngine._();
  EasterEggEngine._();

  static const _prefsKey = 'easterEggsUnlocked';
  static const _cooldown = Duration(minutes: 25);
  static const _maxSessionPopups = 2;
  static const _repeatChance = 0.15;

  static const List<EasterEggDef> catalog = [
    // 时间与作息
    EasterEggDef(id: 'night_owl', title: '深夜修仙者', icon: Icons.nights_stay_outlined),
    EasterEggDef(id: 'night_marathon', title: '不眠夜', icon: Icons.bedtime_outlined),
    EasterEggDef(id: 'early_bird', title: '晨读卷王', icon: Icons.wb_twilight_outlined),
    EasterEggDef(id: 'midnight_cross', title: '跨夜人', icon: Icons.dark_mode_outlined),
    EasterEggDef(id: 'lunch_escape', title: '午休摸鱼王', icon: Icons.lunch_dining_outlined),
    EasterEggDef(id: 'weekend_binge', title: '周末废寝忘食', icon: Icons.weekend_outlined),
    // 沉浸与时长
    EasterEggDef(id: 'time_vanish', title: '时间消失术', icon: Icons.hourglass_bottom_outlined),
    EasterEggDef(id: 'iron_eyes', title: '铁打的眼眶', icon: Icons.visibility_outlined),
    EasterEggDef(id: 'marathon_pages', title: '翻页永动机', icon: Icons.auto_stories_outlined),
    EasterEggDef(id: 'ten_chapters', title: '十连抽', icon: Icons.layers_outlined),
    // 阅读节奏与习惯
    EasterEggDef(id: 'speed_demon', title: '匆忙的人', icon: Icons.bolt_outlined),
    EasterEggDef(id: 'turtle_savor', title: '逐字品鉴家', icon: Icons.coffee_outlined),
    EasterEggDef(id: 'deep_ponder', title: '陷入沉思', icon: Icons.psychology_outlined),
    EasterEggDef(id: 'rewind_memory', title: '记忆回溯', icon: Icons.history_outlined),
    EasterEggDef(id: 'big_leap', title: '时空跳跃', icon: Icons.rocket_launch_outlined),
    EasterEggDef(id: 'chapter_bounce', title: '反复横跳', icon: Icons.swap_horiz_outlined),
    // 剧情与文本彩蛋
    EasterEggDef(id: 'shy_moment', title: '羞羞', icon: Icons.favorite_border),
    EasterEggDef(id: 'tears_moment', title: '破防瞬间', icon: Icons.water_drop_outlined),
    EasterEggDef(id: 'tic_bingo', title: '作者口癖雷达', icon: Icons.radar_outlined),
    EasterEggDef(id: 'high_energy', title: '肾上腺素', icon: Icons.local_fire_department_outlined),
    EasterEggDef(id: 'calm_harbor', title: '岁月静好', icon: Icons.spa_outlined),
    EasterEggDef(id: 'cliffhanger_victim', title: '断章受害者', icon: Icons.anchor_outlined),
    // 探索与交互
    EasterEggDef(id: 'book_hopper', title: '书荒巡逻兵', icon: Icons.explore_outlined),
    EasterEggDef(id: 'book_finisher', title: '通关撒花', icon: Icons.emoji_events_outlined),
    EasterEggDef(id: 'night_audio', title: '枕边听书', icon: Icons.headphones_outlined),
    EasterEggDef(id: 'deep_reader', title: '入戏太深', icon: Icons.menu_book_outlined),
    // 稀有偶遇
    EasterEggDef(id: 'exact_minute', title: '整点报时员', icon: Icons.schedule_outlined),
    EasterEggDef(id: 'palindrome_ch', title: '对称强迫症', icon: Icons.filter_vintage_outlined),
  ];

  static final Map<String, EasterEggDef> _byId = {
    for (final d in catalog) d.id: d,
  };

  /// Conservative intimate/romantic keyword set for `shy_moment`.
  static const _shyWords = [
    '吻', '亲吻', '唇瓣', '轻喘', '喘息', '衣衫', '解开', '贴近', '缠绵',
    '滚烫', '耳垂', '锁骨', '拥入怀', '脸颊通红', '呼吸急促', '暧昧', '红晕',
  ];

  /// Tear-jerker / tragic keyword set for `tears_moment`.
  static const _tearWords = [
    '眼泪', '泪水', '哽咽', '泣不成声', '诀别', '永别', '牺牲', '闭上眼',
    '泪流满面', '嚎啕大哭', '墓碑', '遗言', '再也回不来', '生离死别',
  ];

  /// Classic signature web-novel tics for `tic_bingo` (>=3 distinct hits on one page).
  static const _ticBingoWords = [
    '倒吸一口凉气', '恐怖如斯', '微微一笑', '淡淡道', '皱了皱眉', '瞳孔骤缩',
    '嘴角勾起', '冷笑一声', '深吸一口气', '浑身一震', '不敢置信', '话音未落',
    '就在这时', '心中暗道', '脸色大变', '点了点头', '摇了摇头',
  ];

  static const _palindromeChapters = {
    111, 222, 333, 444, 555, 666, 777, 888, 999, 1001, 1111, 1221, 1331,
  };

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
  int _slowWindows = 0;
  int _forwardPages = 0;
  int _sequentialChapters = 0;
  int _nightChapters = 0;
  final List<DateTime> _backTurns = [];
  final List<DateTime> _chapterJumps = [];
  int _consecutiveHighPace = 0;
  int _consecutiveCalmPace = 0;
  int? _lastChapter;
  DateTime? _nightTtsStart;
  int _deepPonderCount = 0;

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
    _slowWindows = 0;
    _forwardPages = 0;
    _sequentialChapters = 0;
    _nightChapters = 0;
    _backTurns.clear();
    _chapterJumps.clear();
    _consecutiveHighPace = 0;
    _consecutiveCalmPace = 0;
    _lastChapter = null;
    _nightTtsStart = null;
    _deepPonderCount = 0;

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
      return;
    }

    _forwardPages++;
    if (_forwardPages >= 150) {
      _forwardPages = 0;
      if (_tryTrigger(
        id: 'marathon_pages',
        detail: '这一口气已经连续翻了 150 页，手指不酸吗？',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Exact top-of-the-hour coincidence (xx:00) after >= 15 mins of reading.
    final mins = _sessionStart == null
        ? 0
        : now.difference(_sessionStart!).inMinutes;
    if (now.minute == 0 && mins >= 15) {
      if (_tryTrigger(
        id: 'exact_minute',
        detail: '刚好在 ${now.hour.toString().padLeft(2, '0')}:00 整翻过这一页',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Tic bingo: >= 3 distinct classic author tics packed onto a single page.
    if (visibleText.length >= 120) {
      final hits = <String>[];
      for (final w in _ticBingoWords) {
        if (visibleText.contains(w)) hits.add(w);
        if (hits.length >= 3) break;
      }
      if (hits.length >= 3) {
        if (_tryTrigger(
          id: 'tic_bingo',
          detail: '这一页一口气凑齐了「${hits.join(' / ')}」',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }
    }

    if (prevAt != null) {
      final dwell = now.difference(prevAt).inSeconds;
      final expectedSecs =
          baselineCharsPerMin != null && baselineCharsPerMin > 100
              ? (visibleText.length / baselineCharsPerMin * 60)
              : 12.0;

      // Shy moment: >= 3 distinct intimate keywords AND slowed dwell.
      if (dwell >= 18 && dwell <= 180 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _shyWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 3) break;
        }
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

      // Tears moment: >= 3 distinct tragic keywords AND slowed dwell.
      if (dwell >= 20 && dwell <= 200 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _tearWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 3) break;
        }
        if (hits >= 3) {
          _tryTrigger(
            id: 'tears_moment',
            detail: '这一段刀子有点狠，你静静停了 $dwell 秒',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Deep ponder: stayed on a single page 45s..240s.
      if (dwell >= 45 && dwell <= 240) {
        _deepPonderCount++;
        if (_deepPonderCount >= 3) {
          _deepPonderCount = 0;
          if (_tryTrigger(
            id: 'deep_reader',
            detail: '已经连续多次在单页驻足细读，完全沉浸进去了',
            bookTitle: bookTitle,
            enabled: enabled,
          )) {
            return;
          }
        }
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
    final fastThreshold =
        baselineCharsPerMin != null && baselineCharsPerMin > 200
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

    // 2) Turtle savor: 4 consecutive very slow active windows (<0.45x baseline).
    if (baselineCharsPerMin != null &&
        baselineCharsPerMin >= 350 &&
        cpm >= 60 &&
        cpm <= baselineCharsPerMin * 0.45) {
      _slowWindows++;
      if (_slowWindows >= 4) {
        _slowWindows = 0;
        _tryTrigger(
          id: 'turtle_savor',
          detail: '放慢到 ${cpm.round()} 字/分细细品读，这卷写得很对胃口吧',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    } else {
      _slowWindows = 0;
    }

    // 3) Session duration & time-of-day eggs.
    final start = _sessionStart;
    final mins = start == null ? 0 : now.difference(start).inMinutes;
    final hour = now.hour;
    final minute = now.minute;

    // Crossed midnight in one continuous session.
    if (start != null &&
        start.day != now.day &&
        start.hour == 23 &&
        start.minute <= 50 &&
        hour == 0 &&
        minute >= 5 &&
        mins >= 15) {
      if (_tryTrigger(
        id: 'midnight_cross',
        detail: '从昨天一直看到零点以后，不知不觉跨了一天',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if ((hour == 1 && minute >= 30) || (hour >= 2 && hour < 5)) {
      if (mins >= 45) {
        _tryTrigger(
          id: 'night_marathon',
          detail:
              '凌晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}，已连续看了 $mins 分钟',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
      if (mins >= 15) {
        _tryTrigger(
          id: 'night_owl',
          detail:
              '凌晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} 还在书海里修仙',
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
          detail:
              '清晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} 就已经开卷了',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    }

    // Weekday lunch break reading.
    if (now.weekday <= 5 &&
        ((hour == 12) || (hour == 13 && minute <= 30)) &&
        mins >= 20) {
      if (_tryTrigger(
        id: 'lunch_escape',
        detail: '午休已经沉浸看了 $mins 分钟，充电完毕',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Weekend binge (>= 90 mins).
    if (now.weekday >= 6 && mins >= 90) {
      if (_tryTrigger(
        id: 'weekend_binge',
        detail: '周末一口气连看 $mins 分钟，这才是放假的正确打开方式',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if (mins >= 120) {
      _tryTrigger(
        id: 'iron_eyes',
        detail: '已经连续读满 2 小时（$mins 分钟），记得远眺歇歇眼',
        bookTitle: bookTitle,
        enabled: enabled,
      );
      return;
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

  /// Called on TTS playback ticks so late-night listeners can unlock `night_audio`.
  void onTtsState({
    required bool playing,
    required String bookTitle,
    required bool enabled,
  }) {
    final now = DateTime.now();
    final isLate = (now.hour == 22 && now.minute >= 30) ||
        now.hour == 23 ||
        now.hour < 5;
    if (!playing || !isLate) {
      _nightTtsStart = null;
      return;
    }
    _nightTtsStart ??= now;
    final mins = now.difference(_nightTtsStart!).inMinutes;
    if (mins >= 20) {
      _nightTtsStart = now;
      _tryTrigger(
        id: 'night_audio',
        detail: '深夜听书已陪伴你 $mins 分钟，晚安好梦',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called when the reader advances or jumps to a new chapter.
  void onChapterChanged({
    required int chapterIndex,
    required int totalChapters,
    required List<double?>? paceScores,
    required String bookTitle,
    required bool enabled,
  }) {
    final prev = _lastChapter;
    _lastChapter = chapterIndex;
    if (prev == null || prev == chapterIndex) return;

    final now = DateTime.now();
    final chNum = chapterIndex + 1;

    // Book finisher: reached the last chapter of a book with >= 20 chapters.
    if (totalChapters >= 20 && chapterIndex == totalChapters - 1) {
      if (_tryTrigger(
        id: 'book_finisher',
        detail: '抵达全书最终章（第 $totalChapters 章），完结撒花！',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Palindrome chapter number coincidence.
    if (_palindromeChapters.contains(chNum)) {
      if (_tryTrigger(
        id: 'palindrome_ch',
        detail: '正好翻到第 $chNum 章，对称感拉满',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    final jump = chapterIndex - prev;
    if (jump.abs() >= 30) {
      if (_tryTrigger(
        id: 'big_leap',
        detail: '一次跨过 ${jump.abs()} 章，直接瞬移到第 $chNum 章',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if (jump.abs() >= 2) {
      _chapterJumps.add(now);
      _chapterJumps.removeWhere((t) => now.difference(t).inSeconds > 120);
      if (_chapterJumps.length >= 4) {
        _chapterJumps.clear();
        if (_tryTrigger(
          id: 'chapter_bounce',
          detail: '两分钟内在章节间来回跳转了 4 次，在核对线索吗？',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }
    }

    if (jump == 1) {
      _sequentialChapters++;
      if (_sequentialChapters >= 10) {
        _sequentialChapters = 0;
        if (_tryTrigger(
          id: 'ten_chapters',
          detail: '一口气连推 10 章不停歇，根本停不下来',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      if (now.hour < 5) {
        _nightChapters++;
        if (_nightChapters >= 5) {
          _nightChapters = 0;
          if (_tryTrigger(
            id: 'cliffhanger_victim',
            detail: '凌晨连追 5 章，“看完这章就睡”的含金量还在上升',
            bookTitle: bookTitle,
            enabled: enabled,
          )) {
            return;
          }
        }
      }

      if (paceScores != null && prev >= 0 && prev < paceScores.length) {
        final v = paceScores[prev];
        if (v != null && v >= 1.2) {
          _consecutiveHighPace++;
          _consecutiveCalmPace = 0;
          if (_consecutiveHighPace >= 3) {
            _consecutiveHighPace = 0;
            _tryTrigger(
              id: 'high_energy',
              detail: '连看 3 章高能剧情，手心出汗了吗？',
              bookTitle: bookTitle,
              enabled: enabled,
            );
            return;
          }
        } else if (v != null && v <= -0.6) {
          _consecutiveCalmPace++;
          _consecutiveHighPace = 0;
          if (_consecutiveCalmPace >= 4) {
            _consecutiveCalmPace = 0;
            _tryTrigger(
              id: 'calm_harbor',
              detail: '连读 4 章舒缓日常，享受难得的宁静片刻',
              bookTitle: bookTitle,
              enabled: enabled,
            );
            return;
          }
        } else {
          _consecutiveHighPace = 0;
          _consecutiveCalmPace = 0;
        }
      }
    } else {
      _sequentialChapters = 0;
      _nightChapters = 0;
      _consecutiveHighPace = 0;
      _consecutiveCalmPace = 0;
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

    if (_sessionPopups >= _maxSessionPopups) return false;
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
    _chapterJumps.clear();
    _fastWindows = 0;
    _slowWindows = 0;
    _forwardPages = 0;
    _sequentialChapters = 0;
    _nightChapters = 0;
    _consecutiveHighPace = 0;
    _consecutiveCalmPace = 0;
    _lastChapter = null;
    _nightTtsStart = null;
    _deepPonderCount = 0;
    activeBanner.value = null;
    _loaded = true;
  }
}

/// High-visibility, swipe-away achievement-style top banner shown inside the
/// reader when an easter egg fires.
class EasterEggBannerOverlay extends StatefulWidget {
  final ReadingTheme theme;

  const EasterEggBannerOverlay({super.key, required this.theme});

  @override
  State<EasterEggBannerOverlay> createState() => _EasterEggBannerOverlayState();
}

class _EasterEggBannerOverlayState extends State<EasterEggBannerOverlay> {
  static const _displayDuration = Duration(milliseconds: 7500);
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
      _autoHide = Timer(_displayDuration, () {
        EasterEggEngine.instance.dismissBanner();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    // High-contrast achievement palette: warm obsidian + amber gold so the
    // banner pops clearly over both light paper and dark night themes.
    final isDark = t.background.computeLuminance() < 0.35;
    final cardBg = isDark ? const Color(0xFF23201B) : const Color(0xFF1F1D1A);
    final titleColor = const Color(0xFFFFF6E5);
    final subColor = const Color(0xFFD5CBB8);
    const gold = Color(0xFFE5B35A);

    return ValueListenableBuilder<EasterEggEvent?>(
      valueListenable: EasterEggEngine.instance.activeBanner,
      builder: (context, event, _) {
        if (event == null) return const SizedBox.shrink();
        final topPad = MediaQuery.paddingOf(context).top;
        final bannerKey = '${event.def.id}_${event.detail}';
        return Positioned(
          top: topPad + 12,
          left: 14,
          right: 14,
          child: TweenAnimationBuilder<double>(
            key: ValueKey('anim_$bannerKey'),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutBack,
            builder: (context, v, child) => Opacity(
              opacity: v.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, (1 - v) * -28),
                child: child,
              ),
            ),
            child: Dismissible(
              key: ValueKey(bannerKey),
              direction: DismissDirection.horizontal,
              onDismissed: (_) => EasterEggEngine.instance.dismissBanner(),
              child: GestureDetector(
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < -100) {
                    EasterEggEngine.instance.dismissBanner();
                  }
                },
                child: Material(
                  color: cardBg,
                  elevation: 12,
                  shadowColor: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: gold.withValues(alpha: 0.72),
                        width: 1.4,
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          cardBg,
                          Color.lerp(cardBg, gold, 0.09)!,
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 10, 11),
                          child: Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      gold.withValues(alpha: 0.32),
                                      gold.withValues(alpha: 0.12),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: gold.withValues(alpha: 0.55),
                                  ),
                                ),
                                child: Icon(
                                  event.def.icon,
                                  color: gold,
                                  size: 22,
                                ),
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
                                          event.firstTime
                                              ? '✦ 发现新彩蛋'
                                              : '✦ 阅读彩蛋',
                                          style: const TextStyle(
                                            color: gold,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.6,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      event.def.title,
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      event.detail,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: subColor,
                                        fontSize: 12.5,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                                icon: Icon(
                                  Icons.close,
                                  size: 16,
                                  color: subColor.withValues(alpha: 0.7),
                                ),
                                onPressed: EasterEggEngine.instance.dismissBanner,
                              ),
                            ],
                          ),
                        ),
                        // Subtle bottom countdown bar so reader knows it will fade.
                        TweenAnimationBuilder<double>(
                          key: ValueKey('bar_$bannerKey'),
                          tween: Tween(begin: 1.0, end: 0.0),
                          duration: _displayDuration,
                          builder: (_, frac, _) => Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: frac.clamp(0.0, 1.0),
                              child: Container(
                                height: 2.5,
                                color: gold.withValues(alpha: 0.8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
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
