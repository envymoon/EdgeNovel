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
  static const _repeatCooldownPerEgg = Duration(minutes: 20);
  static const _repeatChance = 0.22;

  static const List<EasterEggDef> catalog = [
    // 时间与作息
    EasterEggDef(id: 'night_owl', title: '深夜修仙者', icon: Icons.nights_stay_outlined),
    EasterEggDef(id: 'night_marathon', title: '不眠夜', icon: Icons.bedtime_outlined),
    EasterEggDef(id: 'early_bird', title: '晨读卷王', icon: Icons.wb_twilight_outlined),
    EasterEggDef(id: 'midnight_cross', title: '跨夜人', icon: Icons.dark_mode_outlined),
    EasterEggDef(id: 'lunch_escape', title: '午休摸鱼王', icon: Icons.lunch_dining_outlined),
    EasterEggDef(id: 'weekend_binge', title: '周末废寝忘食', icon: Icons.weekend_outlined),
    EasterEggDef(id: 'friday_night', title: '周五夜解放', icon: Icons.celebration_outlined),
    EasterEggDef(id: 'commute_reader', title: '通勤摸鱼人', icon: Icons.directions_transit_outlined),
    EasterEggDef(id: 'sunset_read', title: '黄昏漫读', icon: Icons.wb_sunny_outlined),
    // 沉浸与时长
    EasterEggDef(id: 'time_vanish', title: '时间消失术', icon: Icons.hourglass_bottom_outlined),
    EasterEggDef(id: 'iron_eyes', title: '铁打的眼眶', icon: Icons.visibility_outlined),
    EasterEggDef(id: 'marathon_pages', title: '翻页永动机', icon: Icons.auto_stories_outlined),
    EasterEggDef(id: 'five_chapters', title: '停不下来', icon: Icons.fast_forward_outlined),
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
    EasterEggDef(id: 'tic_bingo', title: '文风雷达', icon: Icons.radar_outlined),
    EasterEggDef(id: 'high_energy', title: '肾上腺素', icon: Icons.local_fire_department_outlined),
    EasterEggDef(id: 'calm_harbor', title: '岁月静好', icon: Icons.spa_outlined),
    EasterEggDef(id: 'cliffhanger_victim', title: '断章受害者', icon: Icons.anchor_outlined),
    EasterEggDef(id: 'battle_frenzy', title: '燃起来了', icon: Icons.whatshot_outlined),
    EasterEggDef(id: 'mystery_chill', title: '脊背发凉', icon: Icons.visibility_off_outlined),
    EasterEggDef(id: 'laugh_out_loud', title: '嘴角失守', icon: Icons.sentiment_very_satisfied_outlined),
    EasterEggDef(id: 'dialogue_storm', title: '嘴炮现场', icon: Icons.forum_outlined),
    // 探索与交互
    EasterEggDef(id: 'book_hopper', title: '书荒巡逻兵', icon: Icons.explore_outlined),
    EasterEggDef(id: 'halfway_mark', title: '过半里程碑', icon: Icons.flag_outlined),
    EasterEggDef(id: 'book_finisher', title: '通关撒花', icon: Icons.emoji_events_outlined),
    EasterEggDef(id: 'night_audio', title: '枕边听书', icon: Icons.headphones_outlined),
    EasterEggDef(id: 'day_audio', title: '白日听书', icon: Icons.record_voice_over_outlined),
    EasterEggDef(id: 'deep_reader', title: '入戏太深', icon: Icons.menu_book_outlined),
    // 稀有偶遇
    EasterEggDef(id: 'exact_minute', title: '整点报时员', icon: Icons.schedule_outlined),
    EasterEggDef(id: 'lucky_time', title: '叠字时刻', icon: Icons.auto_awesome_outlined),
    EasterEggDef(id: 'hundred_club', title: '百章俱乐部', icon: Icons.military_tech_outlined),
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

  /// High-action battle words for `battle_frenzy`.
  static const _battleWords = [
    '剑气', '轰鸣', '血战', '暴喝', '杀意', '刀光', '震碎', '决一死战',
    '横扫', '剑芒', '炸裂', '一剑斩', '鲜血飞溅', '气息暴涨',
  ];

  /// Suspense / horror words for `mystery_chill`.
  static const _mysteryWords = [
    '诡异', '阴冷', '黑影', '血迹', '毛骨悚然', '脚步声', '低语',
    '门缝', '冷汗', '阴森', '森寒', '不寒而栗', '头皮发麻',
  ];

  /// Comedy / light-hearted words for `laugh_out_loud`.
  static const _laughWords = [
    '哈哈哈哈', '噗嗤', '忍俊不禁', '翻了个白眼', '啼笑皆非',
    '哭笑不得', '嘴角抽了抽', '哑然失笑', '笑喷', '捧腹',
  ];

  /// Classic signature web-novel tics for `tic_bingo`.
  static const _ticBingoWords = [
    '倒吸一口凉气', '恐怖如斯', '微微一笑', '淡淡道', '皱了皱眉', '瞳孔骤缩',
    '嘴角勾起', '冷笑一声', '深吸一口气', '浑身一震', '不敢置信', '话音未落',
    '就在这时', '心中暗道', '脸色大变', '点了点头', '摇了摇头',
  ];

  static const _palindromeChapters = {
    111, 222, 333, 444, 555, 666, 777, 888, 999, 1001, 1111, 1221, 1331,
  };

  static const _hundredChapters = {100, 200, 300, 500, 800, 1000, 1500, 2000};

  final math.Random _rng = math.Random();
  Map<String, EasterEggRecord> _unlocked = {};
  bool _loaded = false;
  final Map<String, DateTime> _lastTriggeredPerEgg = {};

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
  DateTime? _dayTtsStart;
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
    _dayTtsStart = null;
    _deepPonderCount = 0;

    _recentBooks.removeWhere((e) => now.difference(e.$2).inMinutes > 30);
    if (_recentBooks.every((e) => e.$1 != bookId)) {
      _recentBooks.add((bookId, now));
    }
    if (_recentBooks.length >= 3) {
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
      _backTurns.removeWhere((t) => now.difference(t).inSeconds > 35);
      if (_backTurns.length >= 5) {
        _backTurns.clear();
        _tryTrigger(
          id: 'rewind_memory',
          detail: '刚刚连续往回翻了 5 页，是不是漏了什么伏笔？',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
      return;
    }

    _forwardPages++;
    if (_forwardPages >= 100) {
      _forwardPages = 0;
      if (_tryTrigger(
        id: 'marathon_pages',
        detail: '这一口气已经连续翻了 100 页，手指不酸吗？',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Exact top-of-the-hour coincidence (xx:00) after >= 8 mins of reading.
    final mins = _sessionStart == null
        ? 0
        : now.difference(_sessionStart!).inMinutes;
    if (now.minute == 0 && mins >= 8) {
      if (_tryTrigger(
        id: 'exact_minute',
        detail: '刚好在 ${now.hour.toString().padLeft(2, '0')}:00 整翻过这一页',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Lucky repeating time (e.g. 11:11, 22:22, 12:12, 20:20, 23:23).
    if (now.hour == now.minute && now.hour >= 10 && mins >= 5) {
      final hh = now.hour.toString().padLeft(2, '0');
      if (_tryTrigger(
        id: 'lucky_time',
        detail: '刚好在 $hh:$hh 翻过这一页，时间都替你凑了个对子',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Text-driven page eggs.
    if (visibleText.length >= 100) {
      // Tic bingo: >= 2 distinct classic tics packed onto a single page.
      final hits = <String>[];
      for (final w in _ticBingoWords) {
        if (visibleText.contains(w)) hits.add(w);
        if (hits.length >= 3) break;
      }
      if (hits.length >= 2) {
        if (_tryTrigger(
          id: 'tic_bingo',
          detail: '这一页凑齐了「${hits.join(' / ')}」',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      // Battle frenzy: >= 3 distinct high-action combat cues on one page.
      var battleHits = 0;
      for (final w in _battleWords) {
        if (visibleText.contains(w)) battleHits++;
        if (battleHits >= 3) break;
      }
      if (battleHits >= 3) {
        if (_tryTrigger(
          id: 'battle_frenzy',
          detail: '这一页刀光剑影，战意拉满',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      // Laugh out loud: >= 2 distinct comedy cues on one page.
      var laughHits = 0;
      for (final w in _laughWords) {
        if (visibleText.contains(w)) laughHits++;
        if (laughHits >= 2) break;
      }
      if (laughHits >= 2) {
        if (_tryTrigger(
          id: 'laugh_out_loud',
          detail: '这一段有点好笑，嘴角是不是没压住？',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      // Dialogue storm: >= 12 opening/closing quote marks on one page.
      var quotes = 0;
      for (var i = 0; i < visibleText.length; i++) {
        final cu = visibleText.codeUnitAt(i);
        if (cu == 0x201C || cu == 0x201D || cu == 0x300C || cu == 0x300D) {
          quotes++;
        }
      }
      if (quotes >= 12) {
        if (_tryTrigger(
          id: 'dialogue_storm',
          detail: '这一页全是唇枪舌剑，信息量拉满',
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
              : 10.0;

      // Shy moment: >= 2 distinct intimate keywords AND slowed dwell.
      if (dwell >= 12 && dwell <= 180 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _shyWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 2) break;
        }
        if (hits >= 2 && dwell >= expectedSecs * 1.25) {
          _tryTrigger(
            id: 'shy_moment',
            detail: '检测到这一页停留了 $dwell 秒，看得格外仔细哦',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Tears moment: >= 2 distinct tragic keywords AND slowed dwell.
      if (dwell >= 14 && dwell <= 200 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _tearWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 2) break;
        }
        if (hits >= 2) {
          _tryTrigger(
            id: 'tears_moment',
            detail: '这一段刀子有点狠，你静静停了 $dwell 秒',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Mystery chill: >= 2 suspense/horror words AND dwell >= 12s.
      if (dwell >= 12 && dwell <= 200 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _mysteryWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 2) break;
        }
        if (hits >= 2) {
          _tryTrigger(
            id: 'mystery_chill',
            detail: '这一段气氛有点诡异，回头看看身后？',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Deep ponder: stayed on a single page 35s..240s.
      if (dwell >= 35 && dwell <= 240) {
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

    // 1) Speed demon: 2 consecutive fast windows (>2.1x baseline and >=1250 cpm).
    final fastThreshold =
        baselineCharsPerMin != null && baselineCharsPerMin > 200
            ? math.max(baselineCharsPerMin * 2.1, 1250.0)
            : 1450.0;
    if (cpm >= fastThreshold && cpm < 8000) {
      _fastWindows++;
      if (_fastWindows >= 2) {
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

    // 2) Turtle savor: 3 consecutive very slow active windows (<0.5x baseline).
    if (baselineCharsPerMin != null &&
        baselineCharsPerMin >= 320 &&
        cpm >= 60 &&
        cpm <= baselineCharsPerMin * 0.5) {
      _slowWindows++;
      if (_slowWindows >= 3) {
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
        start.minute <= 52 &&
        hour == 0 &&
        minute >= 3 &&
        mins >= 10) {
      if (_tryTrigger(
        id: 'midnight_cross',
        detail: '从昨天一直看到零点以后，不知不觉跨了一天',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if ((hour == 1 && minute >= 15) || (hour >= 2 && hour < 5)) {
      if (mins >= 35) {
        _tryTrigger(
          id: 'night_marathon',
          detail:
              '凌晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}，已连续看了 $mins 分钟',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
      if (mins >= 10) {
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

    if ((hour == 5 && minute >= 30) || hour == 6 || (hour == 7 && minute <= 30)) {
      if (mins >= 8) {
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

    // Friday night release (Fri 20:00..23:59, >= 18 mins).
    if (now.weekday == DateTime.friday && hour >= 20 && mins >= 18) {
      if (_tryTrigger(
        id: 'friday_night',
        detail: '周五晚上已经沉浸看书 $mins 分钟，周末正式开启',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Weekday commute window (7:30-9:30 or 17:30-19:30, >= 10 mins).
    if (now.weekday <= 5 &&
        (((hour == 7 && minute >= 30) || hour == 8 || (hour == 9 && minute <= 30)) ||
            ((hour == 17 && minute >= 30) || hour == 18 || (hour == 19 && minute <= 30))) &&
        mins >= 10) {
      if (_tryTrigger(
        id: 'commute_reader',
        detail: '通勤路上连看 $mins 分钟，小心别坐过站哦',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Weekday lunch break reading.
    if (now.weekday <= 5 &&
        ((hour == 12) || (hour == 13 && minute <= 30)) &&
        mins >= 12) {
      if (_tryTrigger(
        id: 'lunch_escape',
        detail: '午休已经沉浸看了 $mins 分钟，充电完毕',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Sunset reading (17:00..19:00, >= 15 mins).
    if (hour >= 17 && hour < 19 && mins >= 15) {
      if (_tryTrigger(
        id: 'sunset_read',
        detail: '傍晚时分静静读了 $mins 分钟，日落刚好配好书',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Weekend binge (>= 60 mins).
    if (now.weekday >= 6 && mins >= 60) {
      if (_tryTrigger(
        id: 'weekend_binge',
        detail: '周末一口气连看 $mins 分钟，这才是放假的正确打开方式',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if (mins >= 90) {
      _tryTrigger(
        id: 'iron_eyes',
        detail: '已经连续读了 $mins 分钟，记得远眺歇歇眼',
        bookTitle: bookTitle,
        enabled: enabled,
      );
      return;
    }

    if (mins >= 45) {
      _tryTrigger(
        id: 'time_vanish',
        detail: '不知不觉已经连续看了 $mins 分钟',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called on TTS playback ticks so listeners can unlock `night_audio` / `day_audio`.
  void onTtsState({
    required bool playing,
    required String bookTitle,
    required bool enabled,
  }) {
    if (!playing) {
      _nightTtsStart = null;
      _dayTtsStart = null;
      return;
    }
    final now = DateTime.now();
    final isLate = (now.hour == 22 && now.minute >= 30) ||
        now.hour == 23 ||
        now.hour < 5;
    if (isLate) {
      _dayTtsStart = null;
      _nightTtsStart ??= now;
      final mins = now.difference(_nightTtsStart!).inMinutes;
      if (mins >= 12) {
        _nightTtsStart = now;
        _tryTrigger(
          id: 'night_audio',
          detail: '深夜听书已陪伴你 $mins 分钟，晚安好梦',
          bookTitle: bookTitle,
          enabled: enabled,
        );
      }
    } else {
      _nightTtsStart = null;
      _dayTtsStart ??= now;
      final mins = now.difference(_dayTtsStart!).inMinutes;
      if (mins >= 15) {
        _dayTtsStart = now;
        _tryTrigger(
          id: 'day_audio',
          detail: '解放双手听书 $mins 分钟，耳朵也跟着入戏了',
          bookTitle: bookTitle,
          enabled: enabled,
        );
      }
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

    // Halfway mark: crossed the exact 50% chapter of a >= 30 chapter book.
    if (totalChapters >= 30 && chapterIndex == totalChapters ~/ 2) {
      if (_tryTrigger(
        id: 'halfway_mark',
        detail: '已经读到全书正中间（第 $chNum / $totalChapters 章），下半场开启',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Round hundred-chapter milestone.
    if (_hundredChapters.contains(chNum)) {
      if (_tryTrigger(
        id: 'hundred_club',
        detail: '恭喜抵达第 $chNum 章整，长篇马拉松新里程碑',
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
    if (jump.abs() >= 20) {
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
      if (_sequentialChapters == 5) {
        if (_tryTrigger(
          id: 'five_chapters',
          detail: '已经一口气连追 5 章，节奏正好',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }
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
        if (_nightChapters >= 4) {
          _nightChapters = 0;
          if (_tryTrigger(
            id: 'cliffhanger_victim',
            detail: '凌晨连追 4 章，“看完这章就睡”的含金量还在上升',
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

    final existing = _unlocked[id];
    final firstTime = existing == null;
    if (!firstTime) {
      final last = _lastTriggeredPerEgg[id];
      if (last != null && now.difference(last) < _repeatCooldownPerEgg) {
        return false;
      }
      if (_rng.nextDouble() > _repeatChance) {
        return false;
      }
    }

    _lastTriggeredPerEgg[id] = now;
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
    _lastTriggeredPerEgg.clear();
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
    _dayTtsStart = null;
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
