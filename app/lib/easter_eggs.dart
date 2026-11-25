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
/// - 40 distinct, high-threshold, low-frequency eggs across habits, pacing,
///   text moments, milestones, reader tools, and rare coincidences.
/// - Every egg unlocks at most once; already-unlocked eggs never re-trigger.
/// - No artificial global cooldown: rarity comes naturally from high thresholds.
/// - Controlled by a single master toggle in settings.
class EasterEggEngine extends ChangeNotifier {
  static final instance = EasterEggEngine._();
  EasterEggEngine._();

  static const _prefsKey = 'easterEggsUnlocked';
  static const _statsKey = 'easterEggStats';

  static const List<EasterEggDef> catalog = [
    // 作息与时段
    EasterEggDef(id: 'night_marathon', title: '不眠夜', icon: Icons.bedtime_outlined),
    EasterEggDef(id: 'dawn_survivor', title: '破晓战神', icon: Icons.wb_sunny_outlined),
    EasterEggDef(id: 'early_bird', title: '晨读卷王', icon: Icons.wb_twilight_outlined),
    EasterEggDef(id: 'midnight_cross', title: '跨夜人', icon: Icons.dark_mode_outlined),
    EasterEggDef(id: 'weekend_binge', title: '周末废寝忘食', icon: Icons.weekend_outlined),
    // 沉浸与里程碑
    EasterEggDef(id: 'iron_eyes', title: '铁打的眼眶', icon: Icons.visibility_outlined),
    EasterEggDef(id: 'marathon_pages', title: '翻页永动机', icon: Icons.auto_stories_outlined),
    EasterEggDef(id: 'ten_chapters', title: '十连抽', icon: Icons.layers_outlined),
    EasterEggDef(id: 'million_words', title: '字海百万', icon: Icons.menu_book_outlined),
    EasterEggDef(id: 'tome_conqueror', title: '巨著征服者', icon: Icons.castle_outlined),
    EasterEggDef(id: 'loyal_reader', title: '专一党', icon: Icons.favorite_outline),
    // 阅读节奏与习惯
    EasterEggDef(id: 'speed_demon', title: '匆忙的人', icon: Icons.bolt_outlined),
    EasterEggDef(id: 'turtle_savor', title: '逐字品鉴家', icon: Icons.coffee_outlined),
    EasterEggDef(id: 'deep_ponder', title: '陷入沉思', icon: Icons.psychology_outlined),
    EasterEggDef(id: 'rewind_memory', title: '记忆回溯', icon: Icons.history_outlined),
    EasterEggDef(id: 'big_leap', title: '时空跳跃', icon: Icons.rocket_launch_outlined),
    EasterEggDef(id: 'chapter_bounce', title: '反复横跳', icon: Icons.swap_horiz_outlined),
    EasterEggDef(id: 'archaeologist', title: '考古学家', icon: Icons.travel_explore_outlined),
    // 剧情与文本
    EasterEggDef(id: 'shy_moment', title: '羞羞', icon: Icons.favorite_border),
    EasterEggDef(id: 'tears_moment', title: '破防瞬间', icon: Icons.water_drop_outlined),
    EasterEggDef(id: 'tic_bingo', title: '文风雷达', icon: Icons.radar_outlined),
    EasterEggDef(id: 'high_energy', title: '肾上腺素', icon: Icons.local_fire_department_outlined),
    EasterEggDef(id: 'mood_coaster', title: '情绪过山车', icon: Icons.show_chart_outlined),
    EasterEggDef(id: 'cliffhanger_victim', title: '断章受害者', icon: Icons.anchor_outlined),
    EasterEggDef(id: 'mystery_chill', title: '脊背发凉', icon: Icons.visibility_off_outlined),
    EasterEggDef(id: 'laugh_out_loud', title: '嘴角失守', icon: Icons.sentiment_very_satisfied_outlined),
    // 探索与工具
    EasterEggDef(id: 'book_hopper', title: '书荒巡逻兵', icon: Icons.explore_outlined),
    EasterEggDef(id: 'digital_hamster', title: '电子仓鼠', icon: Icons.inventory_2_outlined),
    EasterEggDef(id: 'long_reunion', title: '久别重逢', icon: Icons.handshake_outlined),
    EasterEggDef(id: 'halfway_mark', title: '过半里程碑', icon: Icons.flag_outlined),
    EasterEggDef(id: 'book_finisher', title: '通关撒花', icon: Icons.emoji_events_outlined),
    EasterEggDef(id: 'night_audio', title: '枕边听书', icon: Icons.headphones_outlined),
    EasterEggDef(id: 'clean_freak', title: '文字洁癖', icon: Icons.cleaning_services_outlined),
    EasterEggDef(id: 'bug_hunter', title: '捉虫大师', icon: Icons.pest_control_outlined),
    EasterEggDef(id: 'word_collector', title: '词海拾贝', icon: Icons.translate_outlined),
    // 稀有偶遇
    EasterEggDef(id: 'insomnia_404', title: '404 失眠者', icon: Icons.nights_stay_outlined),
    EasterEggDef(id: 'new_year_keeper', title: '岁末守书人', icon: Icons.celebration_outlined),
    EasterEggDef(id: 'lucky_time', title: '叠字时刻', icon: Icons.auto_awesome_outlined),
    EasterEggDef(id: 'thousand_club', title: '千章俱乐部', icon: Icons.military_tech_outlined),
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

  static const _palindromeChapters = {666, 888, 999, 1111, 1221, 1331, 2222};
  static const _thousandChapters = {1000, 2000, 3000};

  Map<String, EasterEggRecord> _unlocked = {};
  bool _loaded = false;
  Future<void>? _loadFuture;
  bool _ttsPlaying = false;

  // Persisted cumulative stats for long-term eggs.
  int _totalReadChars = 0;
  int _totalAdsCleaned = 0;
  int _totalManualAds = 0;
  int? _loyalBookId;
  final List<String> _loyalDays = [];
  final Map<String, int> _bookLastOpenedMs = {};

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
  final List<double> _recentPaces = [];
  int? _lastChapter;
  DateTime? _nightTtsStart;
  int _bookTotalChars = 0;
  bool _reunionPending = false;
  int _sessionDictLookups = 0;

  /// Latest banner to show; listeners (reader page) display and clear it.
  final ValueNotifier<EasterEggEvent?> activeBanner = ValueNotifier(null);

  Map<String, EasterEggRecord> get unlocked => Map.unmodifiable(_unlocked);
  int get unlockedCount => _unlocked.length;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _doLoad();
  }

  Future<void> _doLoad() async {
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
      final rawStats = prefs.getString(_statsKey);
      if (rawStats != null && rawStats.isNotEmpty) {
        final m = jsonDecode(rawStats) as Map<String, dynamic>;
        _totalReadChars = (m['totalReadChars'] as num?)?.toInt() ?? 0;
        _totalAdsCleaned = (m['totalAdsCleaned'] as num?)?.toInt() ?? 0;
        _totalManualAds = (m['totalManualAds'] as num?)?.toInt() ?? 0;
        _loyalBookId = (m['loyalBookId'] as num?)?.toInt();
        _loyalDays
          ..clear()
          ..addAll(
            (m['loyalDays'] as List?)?.whereType<String>() ?? const [],
          );
        final opened = m['bookLastOpenedMs'];
        if (opened is Map) {
          _bookLastOpenedMs
            ..clear()
            ..addAll({
              for (final e in opened.entries)
                if (e.value is num) '${e.key}': (e.value as num).toInt(),
            });
        }
      }
    } catch (_) {
    } finally {
      _loaded = true;
      _loadFuture = null;
    }
    notifyListeners();
  }

  Future<void> _save() async {
    if (!_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode({
        for (final e in _unlocked.entries) e.key: e.value.toJson(),
      });
      await prefs.setString(_prefsKey, encoded);
    } catch (_) {}
  }

  Future<void> _saveStats() async {
    if (!_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _statsKey,
        jsonEncode({
          'totalReadChars': _totalReadChars,
          'totalAdsCleaned': _totalAdsCleaned,
          'totalManualAds': _totalManualAds,
          'loyalBookId': _loyalBookId,
          'loyalDays': _loyalDays,
          'bookLastOpenedMs': _bookLastOpenedMs,
        }),
      );
    } catch (_) {}
  }

  /// Export unlocked easter eggs and cumulative counters for LAN sync.
  Map<String, dynamic> exportSyncData() => {
    'unlocked': {
      for (final e in _unlocked.entries) e.key: e.value.toJson(),
    },
    'stats': {
      'totalReadChars': _totalReadChars,
      'totalAdsCleaned': _totalAdsCleaned,
      'totalManualAds': _totalManualAds,
    },
  };

  /// CRDT union merge of remote easter eggs: keeps all unlocked eggs (taking
  /// the earlier unlock timestamp if unlocked on both devices) and takes max
  /// on cumulative counters. Never drops any locally unlocked egg.
  Future<int> mergeSyncData(Map<String, dynamic> remote) async {
    await ensureLoaded();
    var added = 0;
    final rawUnlocked = remote['unlocked'];
    if (rawUnlocked is Map) {
      for (final entry in rawUnlocked.entries) {
        if (entry.value is! Map) continue;
        try {
          final rec = EasterEggRecord.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          final existing = _unlocked[rec.id];
          if (existing == null) {
            _unlocked[rec.id] = rec;
            added++;
          } else if (rec.unlockedAtMs > 0 &&
              (existing.unlockedAtMs == 0 ||
                  rec.unlockedAtMs < existing.unlockedAtMs)) {
            _unlocked[rec.id] = EasterEggRecord(
              id: existing.id,
              unlockedAtMs: rec.unlockedAtMs,
              count: math.max(existing.count, rec.count),
              lastDetail: existing.lastDetail.isNotEmpty
                  ? existing.lastDetail
                  : rec.lastDetail,
              bookTitle: existing.bookTitle.isNotEmpty
                  ? existing.bookTitle
                  : rec.bookTitle,
            );
          }
        } catch (_) {}
      }
    }
    final stats = remote['stats'];
    if (stats is Map) {
      _totalReadChars = math.max(
        _totalReadChars,
        (stats['totalReadChars'] as num?)?.toInt() ?? 0,
      );
      _totalAdsCleaned = math.max(
        _totalAdsCleaned,
        (stats['totalAdsCleaned'] as num?)?.toInt() ?? 0,
      );
      _totalManualAds = math.max(
        _totalManualAds,
        (stats['totalManualAds'] as num?)?.toInt() ?? 0,
      );
    }
    await _save();
    await _saveStats();
    notifyListeners();
    return added;
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Called when the bookshelf loads so `digital_hamster` can be evaluated.
  void onShelfLoaded({
    required List<({int chapters, int lastChapter})> books,
    required bool enabled,
  }) {
    if (!enabled || books.length < 20) return;
    if (!_loaded) {
      unawaited(
        ensureLoaded().then((_) {
          onShelfLoaded(books: books, enabled: enabled);
        }),
      );
      return;
    }
    var untouched = 0;
    for (final b in books) {
      final pct = b.chapters <= 0 ? 0.0 : b.lastChapter / b.chapters;
      if (b.lastChapter <= 0 || pct < 0.01) untouched++;
    }
    if (untouched >= 15) {
      _tryTrigger(
        id: 'digital_hamster',
        detail: '书架囤了 ${books.length} 本书，其中 $untouched 本还停在开头没动过',
        bookTitle: '书架',
        enabled: enabled,
      );
    }
  }

  void _resetSessionTrackers(DateTime? now) {
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
    _recentPaces.clear();
    _sessionDictLookups = 0;
    if (!_ttsPlaying) {
      _nightTtsStart = null;
    }
  }

  /// Called when a book is opened in the reader.
  void onBookOpen({
    required int bookId,
    required String bookTitle,
    required bool enabled,
    int totalChars = 0,
    int currentChapter = 0,
  }) {
    unawaited(ensureLoaded());
    final now = DateTime.now();
    _resetSessionTrackers(now);
    _lastChapter = null;
    _nightTtsStart = null;
    _bookTotalChars = totalChars;

    // Long reunion: reopened a book untouched for >= 30 days.
    final prevMs = _bookLastOpenedMs['$bookId'];
    _reunionPending =
        prevMs != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(prevMs)).inDays >= 30;
    _bookLastOpenedMs['$bookId'] = now.millisecondsSinceEpoch;

    // Loyal reader: 7 consecutive calendar days reading the same book only.
    final today = _dayKey(now);
    if (_loyalBookId != bookId) {
      _loyalBookId = bookId;
      _loyalDays
        ..clear()
        ..add(today);
    } else if (_loyalDays.isEmpty || _loyalDays.last != today) {
      if (_loyalDays.isNotEmpty) {
        final prevDate = DateTime.tryParse(_loyalDays.last);
        final todayDate = DateTime(now.year, now.month, now.day);
        if (prevDate == null || todayDate.difference(prevDate).inDays != 1) {
          _loyalDays.clear();
        }
      }
      _loyalDays.add(today);
      if (_loyalDays.length >= 7) {
        _tryTrigger(
          id: 'loyal_reader',
          detail: '连续 7 天只追《$bookTitle》这一本书，绝对真爱粉',
          bookTitle: bookTitle,
          enabled: enabled,
        );
      }
    }
    unawaited(_saveStats());

    if (totalChars >= 5000000 && currentChapter >= 50) {
      _tryTrigger(
        id: 'tome_conqueror',
        detail: '已深入这本 ${(totalChars / 10000).round()} 万字超长篇巨著',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }

    _recentBooks.removeWhere((e) => now.difference(e.$2).inMinutes > 20);
    if (_recentBooks.every((e) => e.$1 != bookId)) {
      _recentBooks.add((bookId, now));
    }
    if (_recentBooks.length >= 8) {
      _tryTrigger(
        id: 'book_hopper',
        detail: '20 分钟内连试了 ${_recentBooks.length} 本书，还在找电子榨菜？',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called when the app goes to background or the screen locks, resetting all
  /// continuous-session trackers so off-screen time is never accumulated.
  void onBackground() {
    _resetSessionTrackers(null);
  }

  /// Called when the app returns to foreground so background time is never
  /// counted as single-page dwell or continuous session time.
  void onResume() {
    final now = DateTime.now();
    _sessionStart ??= now;
    _pageEnteredAt = now;
  }

  /// Called when text cleanup removes ads/watermarks.
  void onTextCleaned({
    required int removedCount,
    required String bookTitle,
    required bool enabled,
  }) {
    if (removedCount <= 0) return;
    _totalAdsCleaned += removedCount;
    unawaited(_saveStats());
    if (_totalAdsCleaned >= 500) {
      _tryTrigger(
        id: 'clean_freak',
        detail: '累计用文本整理清除了 $_totalAdsCleaned 条广告与水印，版面一尘不染',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called when the reader manually marks selected text as an ad.
  void onAdMarked({
    required String bookTitle,
    required bool enabled,
  }) {
    _totalManualAds++;
    unawaited(_saveStats());
    if (_totalManualAds >= 10) {
      _tryTrigger(
        id: 'bug_hunter',
        detail: '已亲手揪出并标记 $_totalManualAds 条漏网广告，火眼金睛',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called when the offline dictionary returns a result during reading.
  void onDictionaryLookup({
    required String bookTitle,
    required bool enabled,
  }) {
    _sessionDictLookups++;
    if (_sessionDictLookups >= 5) {
      _tryTrigger(
        id: 'word_collector',
        detail: '本次阅读已查词 $_sessionDictLookups 次，看书还不忘涨知识',
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
    bool ttsPlaying = false,
  }) {
    final now = DateTime.now();
    final prevAt = _pageEnteredAt;
    _pageEnteredAt = now;

    if (ttsPlaying || _ttsPlaying) {
      // Auto-following TTS turns pages slowly; never count as manual dwell/pace.
      return;
    }

    if (backward) {
      _backTurns.add(now);
      _backTurns.removeWhere((t) => now.difference(t).inSeconds > 45);
      if (_backTurns.length >= 12) {
        _backTurns.clear();
        _tryTrigger(
          id: 'rewind_memory',
          detail: '刚刚连续往回翻了 12 页，是不是漏了关键伏笔？',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
      return;
    }

    if (visibleText.isNotEmpty) {
      _totalReadChars += visibleText.length.clamp(80, 700);
      if (_forwardPages % 20 == 0) unawaited(_saveStats());
      if (_totalReadChars >= 1000000) {
        _tryTrigger(
          id: 'million_words',
          detail: '你在挚阅累计读完了一百万字，书海长征新里程碑',
          bookTitle: bookTitle,
          enabled: enabled,
        );
      }
    }

    _forwardPages++;
    if (_forwardPages >= 300) {
      _forwardPages = 0;
      if (_tryTrigger(
        id: 'marathon_pages',
        detail: '这一口气已经连续翻了 300 页，手指不酸吗？',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // 404 Insomnia: flipped a page at 04:04 AM.
    if (now.hour == 4 && now.minute == 4) {
      if (_tryTrigger(
        id: 'insomnia_404',
        detail: '04:04 Not Found，你的睡眠已走丢',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // New Year Keeper: reading across Dec 31 23:55 .. Jan 1 00:05.
    if ((now.month == 12 &&
            now.day == 31 &&
            now.hour == 23 &&
            now.minute >= 55) ||
        (now.month == 1 && now.day == 1 && now.hour == 0 && now.minute <= 5)) {
      if (_tryTrigger(
        id: 'new_year_keeper',
        detail: '跨年钟声敲响的那一刻，你正沉浸在书里',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Lucky repeating time: only 11:11 or 22:22 after >= 20 mins of reading.
    final mins = _sessionStart == null
        ? 0
        : now.difference(_sessionStart!).inMinutes;
    if (((now.hour == 11 && now.minute == 11) ||
            (now.hour == 22 && now.minute == 22)) &&
        mins >= 20) {
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
    if (visibleText.length >= 120) {
      // Tic bingo: >= 5 distinct classic tics packed onto a single page.
      final hits = <String>[];
      for (final w in _ticBingoWords) {
        if (visibleText.contains(w)) hits.add(w);
        if (hits.length >= 5) break;
      }
      if (hits.length >= 5) {
        if (_tryTrigger(
          id: 'tic_bingo',
          detail: '这一页一口气凑齐了「${hits.take(3).join(' / ')}」等 5 个经典口癖',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      // Laugh out loud: >= 4 distinct comedy cues on one page.
      var laughHits = 0;
      for (final w in _laughWords) {
        if (visibleText.contains(w)) laughHits++;
        if (laughHits >= 4) break;
      }
      if (laughHits >= 4) {
        if (_tryTrigger(
          id: 'laugh_out_loud',
          detail: '这一段笑点太密，嘴角是不是没压住？',
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

      // Shy moment: >= 4 distinct intimate keywords AND slowed dwell >= 30s.
      if (dwell >= 30 && dwell <= 200 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _shyWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 4) break;
        }
        if (hits >= 4 && dwell >= expectedSecs * 1.6) {
          _tryTrigger(
            id: 'shy_moment',
            detail: '检测到这一页停留了 $dwell 秒，看得格外仔细哦',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Tears moment: >= 4 distinct tragic keywords AND dwell >= 30s.
      if (dwell >= 30 && dwell <= 240 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _tearWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 4) break;
        }
        if (hits >= 4) {
          _tryTrigger(
            id: 'tears_moment',
            detail: '这一段刀子有点狠，你静静停了 $dwell 秒',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Mystery chill: late night (00:00..04:59) + >= 4 horror cues + dwell >= 25s.
      if (now.hour < 5 && dwell >= 25 && dwell <= 240 && visibleText.isNotEmpty) {
        var hits = 0;
        for (final w in _mysteryWords) {
          if (visibleText.contains(w)) hits++;
          if (hits >= 4) break;
        }
        if (hits >= 4) {
          _tryTrigger(
            id: 'mystery_chill',
            detail: '凌晨读到这么诡异的一段，回头看看身后？',
            bookTitle: bookTitle,
            enabled: enabled,
          );
          return;
        }
      }

      // Deep ponder: stayed on a single page 120s..300s.
      if (dwell >= 120 && dwell <= 300) {
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
    bool ttsPlaying = false,
  }) {
    if (secs <= 0 || chars <= 0) return;
    if (ttsPlaying || _ttsPlaying) {
      _fastWindows = 0;
      _slowWindows = 0;
      return;
    }
    final now = DateTime.now();
    final cpm = chars / secs * 60.0;

    // 1) Speed demon: 5 consecutive fast windows (>2.5x baseline and >=1800 cpm).
    final fastThreshold =
        baselineCharsPerMin != null && baselineCharsPerMin > 200
            ? math.max(baselineCharsPerMin * 2.5, 1800.0)
            : 1800.0;
    if (cpm >= fastThreshold && cpm < 8000) {
      _fastWindows++;
      if (_fastWindows >= 5) {
        _fastWindows = 0;
        _tryTrigger(
          id: 'speed_demon',
          detail: '持续飙到了 ${cpm.round()} 字/分，真正的一目十行',
          bookTitle: bookTitle,
          enabled: enabled,
        );
        return;
      }
    } else {
      _fastWindows = 0;
    }

    // 2) Turtle savor: 8 consecutive very slow active windows (<=0.4x baseline).
    if (baselineCharsPerMin != null &&
        baselineCharsPerMin >= 320 &&
        cpm >= 60 &&
        cpm <= baselineCharsPerMin * 0.4) {
      _slowWindows++;
      if (_slowWindows >= 8) {
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

    // Dawn survivor: started before 02:00 and read continuously past 06:00.
    if (start != null && mins >= 240 && hour >= 6 && hour < 10) {
      final startedLateNight =
          (start.day == now.day && start.hour < 2) ||
          (start.day != now.day && start.hour >= 22);
      if (startedLateNight) {
        if (_tryTrigger(
          id: 'dawn_survivor',
          detail: '从深夜一路看到天亮（连续 $mins 分钟），真正的破晓战神',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }
    }

    // Crossed midnight: started <= 23:30, now >= 00:30, >= 60 mins.
    if (start != null &&
        start.day != now.day &&
        start.hour == 23 &&
        start.minute <= 30 &&
        hour == 0 &&
        minute >= 30 &&
        mins >= 60) {
      if (_tryTrigger(
        id: 'midnight_cross',
        detail: '从昨天一直看到零点半以后，不知不觉跨了一天',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if (hour >= 2 && hour < 5 && mins >= 90) {
      _tryTrigger(
        id: 'night_marathon',
        detail:
            '凌晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}，已连续看了 $mins 分钟',
        bookTitle: bookTitle,
        enabled: enabled,
      );
      return;
    }

    if ((hour == 5 || (hour == 6 && minute <= 30)) && mins >= 45) {
      _tryTrigger(
        id: 'early_bird',
        detail:
            '清晨 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} 就已连读 $mins 分钟',
        bookTitle: bookTitle,
        enabled: enabled,
      );
      return;
    }

    // Weekend binge (>= 180 mins).
    if (now.weekday >= 6 && mins >= 180) {
      if (_tryTrigger(
        id: 'weekend_binge',
        detail: '周末一口气连看 $mins 分钟，这才是放假的正确打开方式',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    if (mins >= 180) {
      _tryTrigger(
        id: 'iron_eyes',
        detail: '已经连续读了 $mins 分钟，记得远眺歇歇眼',
        bookTitle: bookTitle,
        enabled: enabled,
      );
    }
  }

  /// Called on TTS playback ticks so listeners can unlock `night_audio`.
  void onTtsState({
    required bool playing,
    required String bookTitle,
    required bool enabled,
  }) {
    if (_ttsPlaying != playing) {
      _ttsPlaying = playing;
      // Reset page dwell timer whenever TTS starts or stops so TTS pacing
      // never bleeds into manual dwell eggs like `deep_ponder`.
      _pageEnteredAt = DateTime.now();
      _fastWindows = 0;
      _slowWindows = 0;
    }
    if (!playing) {
      _nightTtsStart = null;
      return;
    }
    final now = DateTime.now();
    final isLate = now.hour == 23 || now.hour < 5;
    if (isLate) {
      _nightTtsStart ??= now;
      final mins = now.difference(_nightTtsStart!).inMinutes;
      if (mins >= 45) {
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

    // Tome conqueror: >= 5M chars and past chapter 50.
    if (_bookTotalChars >= 5000000 && chapterIndex >= 50) {
      if (_tryTrigger(
        id: 'tome_conqueror',
        detail: '已深入这本 ${(_bookTotalChars / 10000).round()} 万字超长篇巨著',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Book finisher: reached the last chapter of a book with >= 100 chapters.
    if (totalChapters >= 100 && chapterIndex == totalChapters - 1) {
      if (_tryTrigger(
        id: 'book_finisher',
        detail: '抵达全书最终章（第 $totalChapters 章），完结撒花！',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Halfway mark: crossed the exact 50% chapter of a >= 200 chapter book.
    if (totalChapters >= 200 && chapterIndex == totalChapters ~/ 2) {
      if (_tryTrigger(
        id: 'halfway_mark',
        detail: '已经读到全书正中间（第 $chNum / $totalChapters 章），下半场开启',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Thousand-chapter milestone.
    if (_thousandChapters.contains(chNum)) {
      if (_tryTrigger(
        id: 'thousand_club',
        detail: '恭喜抵达第 $chNum 章整，超长篇马拉松新里程碑',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    // Palindrome / repeating chapter number coincidence.
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

    // Archaeologist: jumped from chapter >= 300 back into the first 10 chapters.
    if (prev >= 299 && chapterIndex < 10) {
      if (_tryTrigger(
        id: 'archaeologist',
        detail: '从第 ${prev + 1} 章一下翻回第 $chNum 章，回开头挖大伏笔了？',
        bookTitle: bookTitle,
        enabled: enabled,
      )) {
        return;
      }
    }

    final jump = chapterIndex - prev;
    if (jump.abs() >= 100) {
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
      if (_chapterJumps.length >= 8) {
        _chapterJumps.clear();
        if (_tryTrigger(
          id: 'chapter_bounce',
          detail: '两分钟内在章节间来回跳转了 8 次，在核对线索吗？',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }
    }

    if (jump == 1) {
      _sequentialChapters++;

      if (_reunionPending && _sequentialChapters >= 3) {
        _reunionPending = false;
        if (_tryTrigger(
          id: 'long_reunion',
          detail: '时隔三十多天重新拾起《$bookTitle》，一下又连追了 3 章',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      if (_sequentialChapters >= 20) {
        _sequentialChapters = 0;
        if (_tryTrigger(
          id: 'ten_chapters',
          detail: '一口气连推 20 章不停歇，根本停不下来',
          bookTitle: bookTitle,
          enabled: enabled,
        )) {
          return;
        }
      }

      if (now.hour >= 1 && now.hour < 5) {
        _nightChapters++;
        if (_nightChapters >= 10) {
          _nightChapters = 0;
          if (_tryTrigger(
            id: 'cliffhanger_victim',
            detail: '凌晨连追 10 章，“看完这章就睡”的含金量还在上升',
            bookTitle: bookTitle,
            enabled: enabled,
          )) {
            return;
          }
        }
      }

      if (paceScores != null && prev >= 0 && prev < paceScores.length) {
        final v = paceScores[prev];
        if (v != null) {
          _recentPaces.add(v);
          if (_recentPaces.length > 3) _recentPaces.removeAt(0);
          if (_recentPaces.length == 3) {
            final lo = _recentPaces.reduce(math.min);
            final hi = _recentPaces.reduce(math.max);
            if (lo <= -0.8 && hi >= 1.6) {
              _recentPaces.clear();
              if (_tryTrigger(
                id: 'mood_coaster',
                detail: '短短三章内剧情从极度舒缓飙到极限高能，情绪过山车坐稳了',
                bookTitle: bookTitle,
                enabled: enabled,
              )) {
                return;
              }
            }
          }
          if (v >= 1.2) {
            _consecutiveHighPace++;
            if (_consecutiveHighPace >= 8) {
              _consecutiveHighPace = 0;
              _tryTrigger(
                id: 'high_energy',
                detail: '连看 8 章高能剧情，手心出汗了吗？',
                bookTitle: bookTitle,
                enabled: enabled,
              );
              return;
            }
          } else {
            _consecutiveHighPace = 0;
          }
        }
      }
    } else {
      _sequentialChapters = 0;
      _nightChapters = 0;
      _consecutiveHighPace = 0;
      _recentPaces.clear();
    }
  }

  bool _tryTrigger({
    required String id,
    required String detail,
    required String bookTitle,
    required bool enabled,
  }) {
    if (!enabled || !_loaded) return false;
    final def = _byId[id];
    if (def == null) return false;
    // Once unlocked, an easter egg never triggers again.
    if (_unlocked.containsKey(id)) return false;

    final now = DateTime.now();
    _unlocked[id] = EasterEggRecord(
      id: id,
      unlockedAtMs: now.millisecondsSinceEpoch,
      count: 1,
      lastDetail: detail,
      bookTitle: bookTitle,
    );
    unawaited(_save());
    notifyListeners();
    activeBanner.value = EasterEggEvent(
      def: def,
      detail: detail,
      firstTime: true,
    );
    return true;
  }

  void dismissBanner() {
    if (activeBanner.value != null) {
      activeBanner.value = null;
    }
  }

  @visibleForTesting
  void backdateSessionForTest(Duration ago) {
    _sessionStart = DateTime.now().subtract(ago);
  }

  @visibleForTesting
  void resetForTest({bool loaded = true}) {
    _unlocked.clear();
    _loadFuture = null;
    _ttsPlaying = false;
    _totalReadChars = 0;
    _totalAdsCleaned = 0;
    _totalManualAds = 0;
    _loyalBookId = null;
    _loyalDays.clear();
    _bookLastOpenedMs.clear();
    _recentBooks.clear();
    _backTurns.clear();
    _chapterJumps.clear();
    _fastWindows = 0;
    _slowWindows = 0;
    _forwardPages = 0;
    _sequentialChapters = 0;
    _nightChapters = 0;
    _consecutiveHighPace = 0;
    _recentPaces.clear();
    _lastChapter = null;
    _nightTtsStart = null;
    _bookTotalChars = 0;
    _reunionPending = false;
    _sessionDictLookups = 0;
    activeBanner.value = null;
    _loaded = loaded;
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
    _onBanner();
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
