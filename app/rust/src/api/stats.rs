//! 阅读数据 and 阅读画像: the reading log, counted by `novel_core::reading_stats`,
//! and written up as a short second-person portrait.
//!
//! No model is involved anywhere here. A 0.6B can't hold a second-person 唯美
//! register steady, and these are the reader's own numbers — they have to be
//! right every time, not occasionally. Every sentence of the portrait is written
//! below by hand; the rules choose which facts are worth saying and which
//! phrasing says them, so the same data reads differently each time.

use crate::api::book;
use novel_core::reading_stats::{self as rs, Session, Window};
use std::collections::{BTreeSet, HashMap};
use std::sync::{Mutex, OnceLock};

/// One window of reading speed from the reader page. Written raw, idle and
/// hunting included; `reading_stats` sorts them out when counting.
pub fn log_reading_window(
    book_id: i64,
    chapter: i64,
    started: i64,
    secs: i64,
    chars: i64,
) -> Result<(), String> {
    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    s.log_window(book_id, chapter, started, secs, chars)
        .map_err(|e| format!("{e}"))
}

#[derive(Debug, Clone)]
pub struct BookSpeed {
    pub title: String,
    /// Characters per minute.
    pub cpm: f64,
}

#[derive(Debug, Clone)]
pub struct DayRecord {
    pub year: i64,
    pub month: i64,
    pub day: i64,
    pub secs: i64,
}

#[derive(Debug, Clone)]
pub struct ReadingInsights {
    /// Seconds read in each hour of the local day, 0 to 23.
    pub hours: Vec<i64>,
    /// Seconds read on each weekday, Monday first.
    pub weekdays: Vec<i64>,
    pub best_streak: i64,
    pub longest_sitting: i64,
    /// The middle sitting, ignoring ones under a minute. None before any.
    pub typical_sitting: Option<i64>,
    pub top_day: Option<DayRecord>,
    pub chapters_finished: i64,
    /// Characters in the finished chapters — counted from bytes, so roughly.
    pub chars_finished: i64,
    pub books_finished: i64,
    /// Opened in the last 30 days and not finished.
    pub books_reading: i64,
    /// Opened once, not finished, untouched for 30 days.
    pub books_shelved: i64,
    pub books_unopened: i64,
    pub annotations: i64,
    /// Characters per minute; None until there is enough reading to say.
    pub speed: Option<f64>,
    /// Minutes of real reading recorded so far, whether or not that is enough.
    pub speed_minutes: i64,
    /// Share of characters that went by too fast to have been read.
    pub skim_share: f64,
    /// Last 30 days and everything before, when both have enough reading.
    pub recent_speed: Option<f64>,
    pub earlier_speed: Option<f64>,
    pub fastest_book: Option<BookSpeed>,
    pub slowest_book: Option<BookSpeed>,
}

/// Speed through each book's most and least intense chapters (its own top and
/// bottom quarter by 节奏 score), pooled over the most-read books.
#[derive(Debug, Clone)]
pub struct PaceSpeed {
    pub intense_cpm: f64,
    pub calm_cpm: f64,
    pub books: i64,
}

const DAY: i64 = 86400;
const RECENT: i64 = 30 * DAY;

fn now() -> i64 {
    novel_core::store::now()
}

/// Everything both the page and the portrait are made of, counted once.
struct Facts {
    total_secs: i64,
    active_days: i64,
    first_ts: Option<i64>,
    streak: i64,
    best_streak: i64,
    longest_sitting: i64,
    typical_sitting: Option<i64>,
    hours: [i64; 24],
    weekdays: [i64; 7],
    top_day: Option<(i64, i64)>,
    chapters_finished: i64,
    chars_finished: i64,
    books_finished: i64,
    books_reading: i64,
    books_shelved: i64,
    books_unopened: i64,
    annotations: i64,
    speed: Option<rs::Speed>,
    speed_minutes: i64,
    skim_share: f64,
    recent_speed: Option<f64>,
    earlier_speed: Option<f64>,
    fastest_book: Option<BookSpeed>,
    slowest_book: Option<BookSpeed>,
    /// (title, seconds, characters in the book)
    top_book: Option<(String, i64, i64)>,
    top_genres: Vec<String>,
    top_authors: Vec<String>,
    tz_secs: i64,
}

/// UTF-8 bytes of Chinese prose, to characters: almost every character is three
/// bytes, and the odd newline or ASCII digit makes this a slight undercount.
fn chars_from_bytes(bytes: i64) -> i64 {
    bytes / 3
}

fn gather(tz_secs: i64) -> Result<Facts, String> {
    let (events, windows, books, (chapters_finished, finished_bytes), annotations) = {
        let guard = book::store().lock().unwrap();
        let s = guard.as_ref().ok_or("数据库未初始化")?;
        (
            s.events_since(0).map_err(|e| format!("{e}"))?,
            s.windows_since(0).map_err(|e| format!("{e}"))?,
            s.library().map_err(|e| format!("{e}"))?,
            s.finished_chapters().map_err(|e| format!("{e}"))?,
            s.annotation_count().map_err(|e| format!("{e}"))?,
        )
    };
    let now = now();
    let sessions: Vec<Session> = events
        .iter()
        .map(|&(book_id, started, ended)| Session {
            book_id,
            started,
            ended,
        })
        .collect();

    let total_secs: i64 = sessions.iter().map(|s| s.secs()).sum();
    let sittings = rs::sittings(&sessions);
    let by_day = rs::by_day(&sessions, tz_secs);
    let days: BTreeSet<i64> = by_day.keys().copied().collect();
    let (hours, weekdays) = rs::clock(&sessions, tz_secs);
    let top_day = by_day
        .iter()
        .max_by_key(|(d, s)| (**s, **d))
        .map(|(d, s)| (*d, *s));

    let mut by_book: HashMap<i64, i64> = HashMap::new();
    for s in &sessions {
        *by_book.entry(s.book_id).or_default() += s.secs();
    }

    // The shelf, as it stands.
    let title: HashMap<i64, &str> = books.iter().map(|b| (b.id, b.title.as_str())).collect();
    let (mut finished, mut reading, mut shelved, mut unopened) = (0, 0, 0, 0);
    let mut genre_secs: HashMap<String, i64> = HashMap::new();
    let mut author_secs: HashMap<String, i64> = HashMap::new();
    let mut top_book: Option<(String, i64, i64)> = None;
    for b in &books {
        if b.chapter_count > 0 && b.last_chapter + 1 >= b.chapter_count {
            finished += 1;
        } else {
            match b.last_opened_at {
                None => unopened += 1,
                Some(t) if now - t <= RECENT => reading += 1,
                Some(_) => shelved += 1,
            }
        }
        let secs = by_book.get(&b.id).copied().unwrap_or(0);
        if secs == 0 {
            continue;
        }
        if top_book.as_ref().is_none_or(|(_, t, _)| secs > *t) {
            top_book = Some((b.title.clone(), secs, chars_from_bytes(b.total_bytes)));
        }
        for g in b
            .genre_tags
            .iter()
            .flat_map(|t| t.split(&[',', '，', '、', ' '][..]))
            .map(str::trim)
            .filter(|g| !g.is_empty())
        {
            *genre_secs.entry(g.to_string()).or_default() += secs;
        }
        if let Some(a) = b.author.as_deref().map(str::trim) {
            if !a.is_empty() && a != "佚名" && a != "未知" {
                *author_secs.entry(a.to_string()).or_default() += secs;
            }
        }
    }
    let top_n = |m: HashMap<String, i64>, n: usize| -> Vec<String> {
        let mut v: Vec<(String, i64)> = m.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v.into_iter().take(n).map(|(k, _)| k).collect()
    };

    // Speed.
    let reading_secs: i64 = windows
        .iter()
        .filter(|w| w.kind() == rs::Kind::Reading)
        .map(|w| w.secs)
        .sum();
    let speed = rs::speed(&windows);
    let recent: Vec<&Window> = windows.iter().filter(|w| now - w.started <= RECENT).collect();
    let earlier: Vec<&Window> = windows.iter().filter(|w| now - w.started > RECENT).collect();
    let (recent_speed, earlier_speed) =
        match (rs::speed(recent.iter().copied()), rs::speed(earlier.iter().copied())) {
            (Some(r), Some(e)) => (Some(r.cpm), Some(e.cpm)),
            _ => (None, None),
        };
    let mut per_book: HashMap<i64, Vec<&Window>> = HashMap::new();
    for w in &windows {
        per_book.entry(w.book_id).or_default().push(w);
    }
    let mut book_speeds: Vec<BookSpeed> = per_book
        .iter()
        .filter_map(|(id, ws)| {
            let s = rs::speed(ws.iter().copied())?;
            Some(BookSpeed {
                title: title.get(id)?.to_string(),
                cpm: s.cpm,
            })
        })
        .collect();
    book_speeds.sort_by(|a, b| b.cpm.total_cmp(&a.cpm));
    // Only worth saying when the books really differ.
    let (fastest_book, slowest_book) = match (book_speeds.first(), book_speeds.last()) {
        (Some(f), Some(s)) if book_speeds.len() >= 2 && f.cpm >= s.cpm * 1.15 => {
            (Some(f.clone()), Some(s.clone()))
        }
        _ => (None, None),
    };

    Ok(Facts {
        total_secs,
        active_days: days.len() as i64,
        first_ts: sessions.iter().map(|s| s.started).min(),
        streak: rs::current_streak(&days, rs::local_day(now, tz_secs)),
        best_streak: rs::best_streak(&days),
        longest_sitting: sittings.iter().map(|s| s.secs()).max().unwrap_or(0),
        typical_sitting: rs::typical_sitting(&sittings),
        hours,
        weekdays,
        top_day,
        chapters_finished,
        chars_finished: chars_from_bytes(finished_bytes),
        books_finished: finished,
        books_reading: reading,
        books_shelved: shelved,
        books_unopened: unopened,
        annotations,
        speed,
        speed_minutes: reading_secs / 60,
        skim_share: rs::skim_share(&windows),
        recent_speed,
        earlier_speed,
        fastest_book,
        slowest_book,
        top_book,
        top_genres: top_n(genre_secs, 3),
        top_authors: top_n(author_secs, 2),
        tz_secs,
    })
}

/// Civil date from a day number (days since 1970-01-01), no chrono dependency
/// (Howard Hinnant's days→y/m/d).
fn ymd(day: i64) -> (i64, i64, i64) {
    let z = day + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// The numbers for the 阅读数据 page.
pub fn reading_insights(tz_secs: i64) -> Result<ReadingInsights, String> {
    let f = gather(tz_secs)?;
    Ok(ReadingInsights {
        hours: f.hours.to_vec(),
        weekdays: f.weekdays.to_vec(),
        best_streak: f.best_streak,
        longest_sitting: f.longest_sitting,
        typical_sitting: f.typical_sitting,
        top_day: f.top_day.map(|(d, secs)| {
            let (year, month, day) = ymd(d);
            DayRecord {
                year,
                month,
                day,
                secs,
            }
        }),
        chapters_finished: f.chapters_finished,
        chars_finished: f.chars_finished,
        books_finished: f.books_finished,
        books_reading: f.books_reading,
        books_shelved: f.books_shelved,
        books_unopened: f.books_unopened,
        annotations: f.annotations,
        speed: f.speed.map(|s| s.cpm),
        speed_minutes: f.speed_minutes,
        skim_share: f.skim_share,
        recent_speed: f.recent_speed,
        earlier_speed: f.earlier_speed,
        fastest_book: f.fastest_book,
        slowest_book: f.slowest_book,
    })
}

/// Last answer of [pace_speed], keyed by how many windows it was counted from:
/// it decodes whole books, so it is worked out again only when there is new
/// reading to count.
fn pace_cache() -> &'static Mutex<Option<(usize, Option<PaceSpeed>)>> {
    static C: OnceLock<Mutex<Option<(usize, Option<PaceSpeed>)>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// Does the reader speed up when the story does? Up to three of the books
/// with the most recorded reading, each split by its own 节奏 quartiles. Slow —
/// it reads those books from disk — so the page asks for it after the rest.
/// None until both kinds of chapter have five minutes of reading behind them.
pub fn pace_speed() -> Result<Option<PaceSpeed>, String> {
    let (windows, paths) = {
        let guard = book::store().lock().unwrap();
        let s = guard.as_ref().ok_or("数据库未初始化")?;
        let windows = s.windows_since(0).map_err(|e| format!("{e}"))?;
        let paths: HashMap<i64, String> = s
            .library()
            .map_err(|e| format!("{e}"))?
            .into_iter()
            .map(|b| (b.id, b.path))
            .collect();
        (windows, paths)
    };
    if let Some((n, cached)) = pace_cache().lock().unwrap().as_ref() {
        if *n == windows.len() {
            return Ok(cached.clone());
        }
    }

    let mut per_book: HashMap<i64, Vec<&Window>> = HashMap::new();
    for w in &windows {
        per_book.entry(w.book_id).or_default().push(w);
    }
    let mut ranked: Vec<(i64, i64)> = per_book
        .iter()
        .filter_map(|(id, ws)| rs::speed(ws.iter().copied()).map(|s| (*id, s.secs)))
        .collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1));

    let (mut intense, mut calm) = (Vec::new(), Vec::new());
    let mut used = 0i64;
    for (id, _) in ranked.into_iter().take(3) {
        let Some(path) = paths.get(&id) else { continue };
        // A book that has moved or no longer decodes just sits this one out.
        let Ok(scores) = book::pace_scores_quietly(path) else {
            continue;
        };
        let Some((lo, hi)) = rs::pace_quartiles(&scores) else {
            continue;
        };
        used += 1;
        for w in &per_book[&id] {
            match scores.get(w.chapter as usize).copied().flatten() {
                Some(s) if s >= hi => intense.push(*w),
                Some(s) if s <= lo => calm.push(*w),
                _ => {}
            }
        }
    }
    let answer = match (
        rs::speed_over(intense.iter().copied(), 300),
        rs::speed_over(calm.iter().copied(), 300),
    ) {
        (Some(i), Some(c)) => Some(PaceSpeed {
            intense_cpm: i.cpm,
            calm_cpm: c.cpm,
            books: used,
        }),
        _ => None,
    };
    *pace_cache().lock().unwrap() = Some((windows.len(), answer.clone()));
    Ok(answer)
}

// ── 阅读画像 ─────────────────────────────────────────────────────────────────

/// splitmix64: each slot of the portrait draws its own number, so changing the
/// seed by one reshuffles everything rather than shifting every slot in step.
struct Dice(u64);

impl Dice {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn pick<'a>(&mut self, pool: &[&'a str]) -> &'a str {
        pool[(self.next() % pool.len() as u64) as usize]
    }

    fn chance(&mut self, p: f64) -> bool {
        (self.next() % 10_000) as f64 / 10_000.0 < p
    }

    /// Up to `n` of these, in their original order.
    fn some(&mut self, items: Vec<String>, n: usize) -> Vec<String> {
        let mut keyed: Vec<(u64, usize, String)> = items
            .into_iter()
            .enumerate()
            .map(|(i, s)| (self.next(), i, s))
            .collect();
        keyed.sort_by_key(|k| k.0);
        keyed.truncate(n);
        keyed.sort_by_key(|k| k.1);
        keyed.into_iter().map(|k| k.2).collect()
    }
}

fn fmt_dur(secs: i64) -> String {
    if secs < 3600 {
        format!("{} 分钟", (secs / 60).max(1))
    } else {
        let h = secs as f64 / 3600.0;
        let tenths = (h * 10.0).round() as i64;
        if h >= 10.0 {
            format!("{} 小时", h.round() as i64)
        } else if tenths % 10 == 0 {
            format!("{} 小时", tenths / 10)
        } else {
            format!("{h:.1} 小时")
        }
    }
}

fn fmt_wan(chars: i64) -> String {
    let w = chars as f64 / 10_000.0;
    if w >= 100.0 {
        format!("{}", w.round() as i64)
    } else {
        format!("{w:.1}")
    }
}

/// Speeds are quoted to the nearest ten: 617 字/分 claims a precision the
/// windows do not have.
fn fmt_cpm(cpm: f64) -> String {
    (((cpm / 10.0).round() as i64) * 10).to_string()
}

fn pct(ratio: f64) -> String {
    format!("{}", ((ratio - 1.0).abs() * 100.0).round() as i64)
}

fn hour_bucket(h: usize) -> &'static str {
    match h {
        5..=7 => "清晨",
        8..=11 => "上午",
        12..=13 => "中午",
        14..=17 => "下午",
        18..=21 => "晚上",
        _ => "深夜",
    }
}

const WEEKDAY: [&str; 7] = ["一", "二", "三", "四", "五", "六", "日"];

impl Facts {
    fn night_share(&self) -> f64 {
        let night: i64 = self
            .hours
            .iter()
            .enumerate()
            .filter(|(h, _)| !(5..=21).contains(h))
            .map(|(_, s)| s)
            .sum();
        night as f64 / self.total_secs.max(1) as f64
    }

    fn dominant_bucket(&self) -> &'static str {
        let mut by: HashMap<&'static str, i64> = HashMap::new();
        for (h, s) in self.hours.iter().enumerate() {
            *by.entry(hour_bucket(h)).or_default() += s;
        }
        by.into_iter()
            .max_by_key(|(k, v)| (*v, *k))
            .map(|(k, _)| k)
            .unwrap_or("深夜")
    }

    fn compose(&self, pace: Option<&PaceSpeed>, seed: u64) -> String {
        let mut r = Dice(seed);
        let now_year = ymd(rs::local_day(now(), self.tz_secs)).0;

        // ── 第一段：从哪天开始，读了多久，什么时候读，怎么读 ──
        let mut first = String::new();
        if let Some(ts) = self.first_ts {
            let (y, m, d) = ymd(rs::local_day(ts, self.tz_secs));
            let date = if y == now_year {
                format!("{m} 月 {d} 日")
            } else {
                format!("{y} 年 {m} 月 {d} 日")
            };
            first.push_str(
                &r.pick(&[
                    "从 {D}翻开第一页起，你便与这里的故事有了牵绊。",
                    "故事要从 {D}说起——那天，你在这里读下了第一行字。",
                    "{D}，你合上现实，翻开了这里的第一个故事。",
                    "如果给你的阅读写一部编年史，第一页会写着：{D}，开卷。",
                    "{D}本是个寻常日子，直到你在这里读完了第一页。",
                    "你和这里的初次相遇，发生在 {D}。",
                    "自 {D}起，这里多了一位认真的读者。",
                ])
                .replace("{D}", &date),
            );
        }

        let mut total_pool = vec![
            "至今，你已在字里行间停留了 {T}，散落在 {N} 个有书相伴的日子里。",
            "到今天，你交给阅读的光阴累计有 {T}，落在 {N} 个日子之中。",
            "算下来，你已读了 {T}，这些时光分布在 {N} 天里。",
            "{N} 个日子，{T}——这是你和书一起走过的路。",
            "把零零碎碎的时间攒起来，一共是 {T}，横跨 {N} 天。",
        ];
        if self.total_secs >= 4 * 3600 {
            total_pool.push("这 {T}的阅读，够看 {Mv} 部两小时的电影，可你把它们都给了文字。");
        }
        if self.total_secs >= 24 * 3600 {
            total_pool.push("累计 {T}，相当于不吃不睡地读了 {Dd} 天。");
        }
        first.push_str(
            &r.pick(&total_pool)
                .replace("{T}", &fmt_dur(self.total_secs))
                .replace("{N}", &self.active_days.to_string())
                .replace("{Mv}", &(self.total_secs / 7200).to_string())
                .replace("{Dd}", &format!("{:.1}", self.total_secs as f64 / DAY as f64)),
        );

        let mut habits: Vec<String> = Vec::new();

        // 什么时候读。
        let bucket = if self.night_share() >= 0.4 {
            "深夜"
        } else {
            self.dominant_bucket()
        };
        let mut when = r
            .pick(match bucket {
                "清晨" => &[
                    "你是清晨的读者，天刚亮，故事就醒了。",
                    "别人还在赖床时，你已经在书里走了好几里路。",
                    "清晨的第一缕光，常常照在你的书页上。",
                ][..],
                "上午" => &[
                    "上午是你和书相处最多的时候，头脑清醒，读得也专注。",
                    "你喜欢趁上午的好精神，读上几章。",
                    "上午的阳光和你的书页，好像总是一起出现。",
                ][..],
                "中午" => &[
                    "午休的那一小段时光，被你悄悄留给了故事。",
                    "你最常在中午翻开书——一顿饭的工夫，也能读上好几页。",
                    "中午是你的读书时间，忙里偷闲，最是快活。",
                ][..],
                "下午" => &[
                    "你偏爱在下午读书，一杯茶的工夫，一章就过去了。",
                    "下午的时光慢，正好配一本好书。",
                    "午后是你读得最多的时候，懒洋洋，也甜丝丝。",
                ][..],
                "晚上" => &[
                    "晚上是你的读书时间，一天的忙碌，都在翻页声里放下。",
                    "你习惯在晚饭后翻开书，让故事给一天收个尾。",
                    "夜幕降临，你的另一段生活才刚刚开始。",
                ][..],
                _ => &[
                    "你偏爱在夜深时读书，万籁俱寂，故事才刚刚醒来。",
                    "夜色是你读书的底色——旁人入睡时，你正翻到最要紧的那一页。",
                    "你是不折不扣的夜读派，不少章节是在零点之后读完的。",
                    "深夜的屏幕光里，藏着你最投入的阅读时光。",
                ][..],
            })
            .to_string();
        // The busiest hour, but only when it falls inside the part of the day
        // just named — "mostly at noon; above all at 8 pm" contradicts itself.
        let peak = (0..24).max_by_key(|&h| (self.hours[h], h)).unwrap_or(22);
        let peak_fits = hour_bucket(peak) == bucket;
        if self.hours[peak] > 0 && peak_fits && r.chance(0.5) {
            when.push_str(
                &r.pick(&[
                    "尤其是 {H} 点前后，几乎是你雷打不动的读书时间。",
                    "其中 {H} 点那一个钟头，你读得最多。",
                    "要是有人找你，{H} 点前后多半会发现你在看书。",
                ])
                .replace("{H}", &peak.to_string()),
            );
        }
        habits.push(when);

        // 一周里的哪几天。
        let week: i64 = self.weekdays.iter().sum();
        if week >= 3 * 3600 {
            let weekend = (self.weekdays[5] + self.weekdays[6]) as f64 / week as f64;
            if weekend >= 0.45 {
                habits.push(
                    r.pick(&[
                        "周末是属于书的——你将近一半的阅读，都发生在星期六和星期天。",
                        "你是周末型读者，平日攒下的念想，都留到周末一口气读完。",
                        "一到周末，你就钻进书里不出来了。",
                    ])
                    .to_string(),
                );
            } else if weekend <= 0.12 {
                habits.push(
                    r.pick(&[
                        "你的阅读大多发生在工作日，书是你忙碌日子里的喘息。",
                        "比起周末，你更常在工作日的缝隙里读书。",
                    ])
                    .to_string(),
                );
            } else {
                let top = (0..7).max_by_key(|&d| (self.weekdays[d], d)).unwrap_or(0);
                if self.weekdays[top] as f64 / week as f64 >= 0.25 {
                    habits.push(
                        r.pick(&[
                            "星期{W}是你读得最多的一天，像是和书约好了似的。",
                            "一周七天里，你最常在星期{W}读书。",
                        ])
                        .replace("{W}", WEEKDAY[top]),
                    );
                }
            }
        }

        // 坚持。
        if self.streak >= 3 {
            habits.push(
                r.pick(&[
                    "最近这 {S} 天，你一天也不曾落下。",
                    "连着 {S} 天，你都没有错过与书的约定。",
                    "已经连续 {S} 天了，阅读成了你每天的习惯。",
                    "{S} 天不间断——这份坚持，书都记得。",
                ])
                .replace("{S}", &self.streak.to_string()),
            );
        } else if self.best_streak >= 5 {
            habits.push(
                r.pick(&[
                    "你最长曾连续读了 {S} 天，那是你和书形影不离的一段日子。",
                    "你的纪录是连续 {S} 天，说不定哪天就会被你自己打破。",
                    "曾有 {S} 天，你每天都翻开了书。",
                ])
                .replace("{S}", &self.best_streak.to_string()),
            );
        }

        // 一次读多久。
        if let Some(ty) = self.typical_sitting {
            let pool: &[&str] = if ty < 10 * 60 {
                &[
                    "你习惯见缝插针地读，一次几分钟，积少成多。",
                    "你的阅读是碎片式的——排队、通勤、睡前，几页几页地读。",
                    "通常一次只读 {Ty}，却从不间断，这是属于你的节奏。",
                ]
            } else if ty >= 40 * 60 {
                &[
                    "你一坐下来就是好久，通常一次要读 {Ty}。",
                    "你不爱浅尝辄止，一次读书往往就是 {Ty}。",
                    "对你来说，读书是一次完整的沉浸——通常 {Ty}起步。",
                ]
            } else {
                &[
                    "你一次通常读 {Ty}，不长不短，刚好一两章。",
                    "{Ty}，是你一次读书的寻常长度。",
                ]
            };
            habits.push(r.pick(pool).replace("{Ty}", &fmt_dur(ty)));
        }
        if self.longest_sitting >= 45 * 60 {
            habits.push(
                r.pick(&[
                    "有一回，你一口气读了 {L}，舍不得停下。",
                    "你曾一头扎进故事里 {L}，浑然忘了时间。",
                    "你最长的一次阅读持续了 {L}——那一定是个让人放不下的故事。",
                    "一坐 {L}不挪窝，是你目前的最长纪录。",
                ])
                .replace("{L}", &fmt_dur(self.longest_sitting)),
            );
        }
        if let Some((day, secs)) = self.top_day.filter(|(_, s)| *s >= 3600) {
            let (_, m, d) = ymd(day);
            habits.push(
                r.pick(&[
                    "{M} 月 {D} 日那天，你读了整整 {T}，是至今读得最多的一天。",
                    "要说最痴迷的一天，是 {M} 月 {D} 日——那天你读了 {T}。",
                    "{M} 月 {D} 日，你在书里待了 {T}，大概是被哪个情节牢牢抓住了。",
                ])
                .replace("{M}", &m.to_string())
                .replace("{D}", &d.to_string())
                .replace("{T}", &fmt_dur(secs)),
            );
        }
        for h in r.some(habits, 3) {
            first.push_str(&h);
        }

        // ── 第二段：读些什么，读得多快 ──
        let mut taste: Vec<String> = Vec::new();
        if !self.top_genres.is_empty() {
            taste.push(
                r.pick(&[
                    "你的偏爱写在书目里——{G}，是你一次次回去的地方。",
                    "翻得最多的，是{G}这样的故事。",
                    "论口味，你是{G}的忠实读者。",
                    "{G}，大概就是你的舒适区。",
                    "书架不会说谎：你对{G}情有独钟。",
                ])
                .replace("{G}", &self.top_genres.join("、")),
            );
        }
        if !self.top_authors.is_empty() {
            taste.push(
                r.pick(&[
                    "{A}的字，你读得格外投入。",
                    "遇上{A}，你总愿意多留一会儿。",
                    "在所有作者里，你给{A}的时间最多。",
                ])
                .replace("{A}", &self.top_authors.join("、")),
            );
        }
        if let Some((title, secs, _)) = &self.top_book {
            taste.push(
                r.pick(&[
                    "在所有故事里，《{Bk}》是你的心头好，你为它停留了 {Bt}。",
                    "《{Bk}》大概是你的宝藏——{Bt}的陪伴，别的书都比不上。",
                    "若要挑一本珍藏，那一定是《{Bk}》，你在它身上花了 {Bt}。",
                    "《{Bk}》独占了你 {Bt}的时光，是名副其实的头号心头好。",
                    "你和《{Bk}》共度了 {Bt}，这份交情不浅。",
                ])
                .replace("{Bk}", title)
                .replace("{Bt}", &fmt_dur(*secs)),
            );
        }
        if self.chapters_finished >= 10 {
            let mut line = r
                .pick(&[
                    "你已完整读完 {C} 章，约 {W} 万字。",
                    "一章一章读下来，已经有 {C} 章、约 {W} 万字被你收入囊中。",
                    "{C} 章、约 {W} 万字——这是你从头读到尾的分量。",
                ])
                .replace("{C}", &self.chapters_finished.to_string())
                .replace("{W}", &fmt_wan(self.chars_finished));
            if let Some((title, _, book_chars)) = &self.top_book {
                let times = self.chars_finished as f64 / (*book_chars).max(1) as f64;
                if times >= 1.2 && r.chance(0.6) {
                    line.push_str(
                        &"这些字，够把《{Bk}》从头到尾读上 {X} 遍。"
                            .replace("{Bk}", title)
                            .replace("{X}", &format!("{times:.1}")),
                    );
                }
            }
            taste.push(line);
        }
        if self.annotations >= 5 {
            taste.push(
                r.pick(&[
                    "你还留下了 {An} 条标注，那些让你停下来的句子，都被好好收着。",
                    "{An} 条标注，是你和作者隔空的对话。",
                ])
                .replace("{An}", &self.annotations.to_string()),
            );
        }
        if self.books_unopened >= 3 {
            taste.push(
                r.pick(&[
                    "书架上还有 {U} 本书没翻开，它们正耐心排着队。",
                    "你囤下的书里，有 {U} 本还在等第一次翻开——不着急，好书不怕等。",
                ])
                .replace("{U}", &self.books_unopened.to_string()),
            );
        }
        if self.books_shelved >= 3 {
            taste.push(
                r.pick(&[
                    "也有 {Sh} 本书被你读到一半放下了，有缘再续。",
                    "{Sh} 本书暂时被搁在了半路，或许哪天你又会想起它们。",
                ])
                .replace("{Sh}", &self.books_shelved.to_string()),
            );
        }
        if self.books_finished > 0 {
            taste.push(
                r.pick(&[
                    "你已读完 {F} 本书，每一本都是一段完整的旅程。",
                    "到目前为止，你读完了 {F} 本，剩下的故事，还在等你。",
                ])
                .replace("{F}", &self.books_finished.to_string()),
            );
        }

        let mut fast: Vec<String> = Vec::new();
        if let Some(s) = self.speed {
            let v = fmt_cpm(s.cpm);
            let pool: &[&str] = if s.cpm < 300.0 {
                &[
                    "你读得不急，每分钟约 {V} 字，字字都看得真切。",
                    "每分钟 {V} 字左右——你是细品派，不放过任何一处伏笔。",
                    "你读书像品茶，每分钟约 {V} 字，慢有慢的滋味。",
                ]
            } else if s.cpm < 600.0 {
                &[
                    "你每分钟大约读 {V} 字，稳稳当当，不疾不徐。",
                    "按你每分钟约 {V} 字的步子，故事总是不紧不慢地展开。",
                    "每分钟 {V} 字上下，是一位从容读者的速度。",
                ]
            } else if s.cpm < 1000.0 {
                &[
                    "你读得很快，每分钟约 {V} 字，翻页声几乎没停过。",
                    "每分钟 {V} 字左右——故事刚铺开，你已经追到了下一章。",
                    "以每分钟约 {V} 字的速度，你在故事里一路疾行。",
                ]
            } else {
                &[
                    "每分钟约 {V} 字，你几乎是一目十行。",
                    "你的阅读速度约每分钟 {V} 字，快得让人怀疑你提前看过剧透。",
                    "每分钟 {V} 字左右，说是“扫书”也不为过。",
                ]
            };
            let mut line = r.pick(pool).replace("{V}", &v);
            if r.chance(0.4) {
                line.push_str(
                    &"照这个速度，一本 100 万字的长篇，你大约 {Hr} 小时就能读完。"
                        .replace("{Hr}", &format!("{}", (1_000_000.0 / s.cpm / 60.0).round() as i64)),
                );
            }
            fast.push(line);

            if self.skim_share >= 0.15 {
                fast.push(
                    r.pick(&[
                        "约有 {P}% 的文字被你快速划过——想必你很清楚哪里该细读、哪里可以跳过。",
                        "你有 {P}% 的内容是一扫而过的，跳读这门手艺，你练得很熟。",
                    ])
                    .replace("{P}", &format!("{}", (self.skim_share * 100.0).round() as i64)),
                );
            } else if self.skim_share <= 0.03 {
                fast.push(
                    r.pick(&[
                        "你几乎从不跳读，每一行都老老实实地读过。",
                        "跳读？不存在的。你一行一行，全都读了。",
                    ])
                    .to_string(),
                );
            }
            if let (Some(now_v), Some(then_v)) = (self.recent_speed, self.earlier_speed) {
                let ratio = now_v / then_v;
                if ratio >= 1.08 {
                    fast.push(
                        r.pick(&[
                            "最近一个月，你比以前读得快了 {Q}%，渐入佳境。",
                            "近 30 天你的速度提升了 {Q}%，看来越读越顺手。",
                        ])
                        .replace("{Q}", &pct(ratio)),
                    );
                } else if ratio <= 0.92 {
                    fast.push(
                        r.pick(&[
                            "最近你读得慢了 {Q}%，也许是遇到了值得细细咀嚼的书。",
                            "近 30 天你放慢了 {Q}%，慢下来，也是一种享受。",
                        ])
                        .replace("{Q}", &pct(ratio)),
                    );
                }
            }
            if let Some(p) = pace {
                let ratio = p.intense_cpm / p.calm_cpm;
                let line = if ratio >= 1.05 {
                    r.pick(&[
                        "读到激烈的章节时，你会不自觉地加快 {Q}%——心跟着情节一起跑。",
                        "打斗和危机一来，你的翻页速度就快了 {Q}%。",
                        "情节越紧，你翻得越快：激烈章节比平缓章节快了 {Q}%。",
                    ])
                } else if ratio <= 0.95 {
                    r.pick(&[
                        "越是激烈的章节，你读得越慢（慢了 {Q}%），一招一式都不想错过。",
                        "情节一紧张，你反而放慢了 {Q}%，生怕漏掉什么。",
                    ])
                } else {
                    r.pick(&[
                        "无论情节是紧是缓，你都保持着差不多的速度，稳得很。",
                        "刀光剑影也好，家长里短也罢，你的速度几乎不变。",
                    ])
                };
                fast.push(line.replace("{Q}", &pct(ratio)));
            }
            if let (Some(f), Some(s)) = (&self.fastest_book, &self.slowest_book) {
                fast.push(
                    r.pick(&[
                        "你读得最快的是《{Fb}》，每分钟约 {Fv} 字；最慢的是《{Sb}》，约 {Sv} 字。",
                        "同样是读书，《{Fb}》你一路小跑，《{Sb}》却一字一句慢慢读。",
                    ])
                    .replace("{Fb}", &f.title)
                    .replace("{Fv}", &fmt_cpm(f.cpm))
                    .replace("{Sb}", &s.title)
                    .replace("{Sv}", &fmt_cpm(s.cpm)),
                );
            }
        }

        let mut second = String::new();
        for t in r.some(taste, 3) {
            second.push_str(&t);
        }
        for f in r.some(fast, 2) {
            second.push_str(&f);
        }
        let mut closing: Vec<&str> = vec![
            "还有很多故事在等你翻开，慢慢来，不必着急。",
            "长夜与好书都还很长，愿你读得尽兴。",
            "愿下一本书，也能让你舍不得合上。",
            "书页还长，未完待续。",
            "下一个故事，已经在书架上等你了。",
            "愿你永远有书可读，也永远有时间去读。",
        ];
        if bucket == "深夜" {
            closing.extend([
                "不过，夜深了记得早点休息——故事明天还在。",
                "熬夜读书虽好，眼睛也要爱惜。",
            ]);
        }
        second.push_str(r.pick(&closing));

        format!("{first}\n\n{second}")
    }
}

/// A 阅读画像, grounded entirely in counted facts. `angle` is any number; each
/// one gives a different choice of facts and phrasings. `tz_secs` is the
/// reader's UTC offset, so times and dates land on their own clock. Uses the
/// last [pace_speed] answer if there is one. Empty when nothing has been read.
pub fn reader_portrait(angle: i32, tz_secs: i64) -> Result<String, String> {
    let facts = gather(tz_secs)?;
    if facts.total_secs == 0 {
        return Ok(String::new());
    }
    let pace = pace_cache()
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|(_, p)| p.clone());
    Ok(facts.compose(pace.as_ref(), angle as u32 as u64))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts() -> Facts {
        let mut hours = [0i64; 24];
        hours[23] = 30 * 3600;
        hours[13] = 5 * 3600;
        Facts {
            total_secs: 35 * 3600,
            active_days: 40,
            first_ts: Some(1_780_000_000),
            streak: 6,
            best_streak: 12,
            longest_sitting: 3 * 3600,
            typical_sitting: Some(50 * 60),
            hours,
            weekdays: [3600, 3600, 3600, 3600, 3600, 15 * 3600, 15 * 3600],
            top_day: Some((20_500, 5 * 3600)),
            chapters_finished: 420,
            chars_finished: 1_300_000,
            books_finished: 2,
            books_reading: 1,
            books_shelved: 4,
            books_unopened: 5,
            annotations: 12,
            speed: Some(rs::Speed {
                cpm: 734.0,
                secs: 9000,
                chars: 110_000,
            }),
            speed_minutes: 150,
            skim_share: 0.2,
            recent_speed: Some(800.0),
            earlier_speed: Some(600.0),
            fastest_book: Some(BookSpeed {
                title: "快书".into(),
                cpm: 900.0,
            }),
            slowest_book: Some(BookSpeed {
                title: "慢书".into(),
                cpm: 500.0,
            }),
            top_book: Some(("大王饶命".into(), 20 * 3600, 4_000_000)),
            top_genres: vec!["都市".into(), "玄幻".into()],
            top_authors: vec!["会说话的肘子".into()],
            tz_secs: 8 * 3600,
        }
    }

    #[test]
    fn every_slot_fills_its_placeholders() {
        let pace = PaceSpeed {
            intense_cpm: 800.0,
            calm_cpm: 650.0,
            books: 2,
        };
        for seed in 0..500 {
            let text = facts().compose(Some(&pace), seed);
            assert!(!text.contains('{') && !text.contains('}'), "{seed}: {text}");
            assert!(text.contains("\n\n"), "{text}");
        }
    }

    #[test]
    fn different_seeds_tell_it_differently() {
        let texts: BTreeSet<String> = (0..200).map(|s| facts().compose(None, s)).collect();
        assert!(texts.len() > 150, "only {} distinct portraits", texts.len());
    }

    #[test]
    fn a_reader_with_little_history_still_gets_whole_sentences() {
        let mut hours = [0i64; 24];
        hours[20] = 300;
        let f = Facts {
            total_secs: 300,
            active_days: 1,
            first_ts: Some(1_780_000_000),
            streak: 1,
            best_streak: 1,
            longest_sitting: 300,
            typical_sitting: Some(300),
            hours,
            weekdays: [0, 0, 300, 0, 0, 0, 0],
            top_day: Some((20_500, 300)),
            chapters_finished: 0,
            chars_finished: 0,
            books_finished: 0,
            books_reading: 1,
            books_shelved: 0,
            books_unopened: 0,
            annotations: 0,
            speed: None,
            speed_minutes: 3,
            skim_share: 0.0,
            recent_speed: None,
            earlier_speed: None,
            fastest_book: None,
            slowest_book: None,
            top_book: None,
            top_genres: vec![],
            top_authors: vec![],
            tz_secs: 0,
        };
        for seed in 0..100 {
            let text = f.compose(None, seed);
            assert!(!text.contains('{'), "{text}");
            assert!(!text.contains("字/分") && !text.contains("每分钟"), "{text}");
            assert!(text.ends_with('。'), "{text}");
        }
    }

    /// Read a handful aloud before changing the pools:
    ///   cargo test --lib portrait_samples -- --ignored --nocapture
    #[test]
    #[ignore]
    fn portrait_samples() {
        let pace = PaceSpeed {
            intense_cpm: 800.0,
            calm_cpm: 650.0,
            books: 2,
        };
        for seed in 0..4 {
            println!("── {seed}\n{}\n", facts().compose(Some(&pace), seed));
        }
    }

    #[test]
    fn dates_come_out_on_the_civil_calendar() {
        assert_eq!(ymd(0), (1970, 1, 1));
        assert_eq!(ymd(20_737), (2026, 10, 11));
    }
}
