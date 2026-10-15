//! 阅读数据 — numbers counted from the reading log by fixed rules. Nothing here
//! guesses, and nothing calls a model.
//!
//! Two logs feed it. `reading_events` holds one row per sitting (open → the app
//! loses focus), recorded since the first version, so everything about *when*
//! someone reads works on their whole history. `reading_windows` holds the
//! reading speed: the reader page cuts each sitting into windows of about 30
//! seconds and writes how many characters scrolled past in each. It only exists
//! from 2026-10 on, so speed starts from zero for everyone.
//!
//! A window is not trusted as written. A reader who walks away with the book
//! open, or who flicks through forty pages hunting for a name, leaves windows
//! that are not reading at all. Those are recognised by their speed and set
//! aside — the walk-aways dropped, the hunting counted as 跳读 — and the
//! slowest and fastest 5% of what remains are trimmed before any average.

use std::collections::{BTreeSet, HashMap};

/// Slower than this, nobody was reading: a window of 30 seconds in which fewer
/// than 30 characters went by is a reader who looked away.
pub const IDLE_CPM: f64 = 60.0;
/// Faster than this is hunting for a passage, not reading it: 50 characters a
/// second is a full page every ten seconds, for the whole window.
pub const SKIM_CPM: f64 = 3000.0;
/// Each end of the reading windows dropped, by speed, before averaging.
pub const TRIM: f64 = 0.05;
/// No speed is quoted from less reading than this. Ten minutes is a chapter or
/// three — enough that one odd window cannot carry the number.
pub const MIN_SPEED_SECS: i64 = 600;

/// One stretch of the reader moving forward through a chapter.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Window {
    pub book_id: i64,
    pub chapter: i64,
    pub started: i64,
    pub secs: i64,
    pub chars: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Reading,
    /// Too slow: the reader was away.
    Idle,
    /// Too fast: flicking through, not reading.
    Skim,
}

impl Window {
    pub fn cpm(&self) -> f64 {
        if self.secs <= 0 {
            return 0.0;
        }
        self.chars as f64 * 60.0 / self.secs as f64
    }

    pub fn kind(&self) -> Kind {
        if self.secs <= 0 || self.chars <= 0 {
            return Kind::Idle;
        }
        let cpm = self.cpm();
        if cpm < IDLE_CPM {
            Kind::Idle
        } else if cpm > SKIM_CPM {
            Kind::Skim
        } else {
            Kind::Reading
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Speed {
    /// Characters per minute.
    pub cpm: f64,
    /// The reading the number stands on, after the trim.
    pub secs: i64,
    pub chars: i64,
}

/// Reading speed over these windows: walk-aways and hunting set aside, the
/// slowest and fastest [TRIM] of the rest dropped, then total characters over
/// total time — so a long steady window weighs more than a short one. None
/// below [MIN_SPEED_SECS] of reading.
pub fn speed<'a>(windows: impl IntoIterator<Item = &'a Window>) -> Option<Speed> {
    speed_over(windows, MIN_SPEED_SECS)
}

pub fn speed_over<'a>(
    windows: impl IntoIterator<Item = &'a Window>,
    min_secs: i64,
) -> Option<Speed> {
    let mut reading: Vec<&Window> = windows
        .into_iter()
        .filter(|w| w.kind() == Kind::Reading)
        .collect();
    if reading.iter().map(|w| w.secs).sum::<i64>() < min_secs {
        return None;
    }
    reading.sort_by(|a, b| a.cpm().total_cmp(&b.cpm()));
    let cut = (reading.len() as f64 * TRIM).floor() as usize;
    let kept = &reading[cut..reading.len() - cut];
    let secs: i64 = kept.iter().map(|w| w.secs).sum();
    let chars: i64 = kept.iter().map(|w| w.chars).sum();
    if secs <= 0 {
        return None;
    }
    Some(Speed {
        cpm: chars as f64 * 60.0 / secs as f64,
        secs,
        chars,
    })
}

/// Share of the characters that went by too fast to have been read. 0 when
/// nothing has been recorded.
pub fn skim_share<'a>(windows: impl IntoIterator<Item = &'a Window>) -> f64 {
    let (mut skim, mut read) = (0i64, 0i64);
    for w in windows {
        match w.kind() {
            Kind::Skim => skim += w.chars,
            Kind::Reading => read += w.chars,
            Kind::Idle => {}
        }
    }
    if skim + read == 0 {
        0.0
    } else {
        skim as f64 / (skim + read) as f64
    }
}

/// One sitting from `reading_events`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Session {
    pub book_id: i64,
    pub started: i64,
    pub ended: i64,
}

impl Session {
    pub fn secs(&self) -> i64 {
        (self.ended - self.started).max(0)
    }
}

/// Local day number (days since 1970-01-01 on the reader's clock).
pub fn local_day(ts: i64, tz_secs: i64) -> i64 {
    (ts + tz_secs).div_euclid(86400)
}

/// 0 = Monday … 6 = Sunday. Day 0 (1970-01-01) was a Thursday.
pub fn weekday(day: i64) -> usize {
    (day + 3).rem_euclid(7) as usize
}

/// Seconds read in each hour of the local day and on each weekday. A sitting
/// that runs from 23:40 to 00:20 gives twenty minutes to each side, rather than
/// crediting the whole hour to where it started.
pub fn clock(sessions: &[Session], tz_secs: i64) -> ([i64; 24], [i64; 7]) {
    let mut hours = [0i64; 24];
    let mut days = [0i64; 7];
    for s in sessions {
        let mut t = s.started + tz_secs;
        let end = s.ended + tz_secs;
        while t < end {
            let next = (t.div_euclid(3600) + 1) * 3600;
            let piece = next.min(end) - t;
            hours[(t.rem_euclid(86400) / 3600) as usize] += piece;
            days[weekday(t.div_euclid(86400))] += piece;
            t = next;
        }
    }
    (hours, days)
}

/// Longest run of consecutive days with any reading.
pub fn best_streak(days: &BTreeSet<i64>) -> i64 {
    let (mut best, mut run, mut prev) = (0i64, 0i64, None::<i64>);
    for &d in days {
        run = if prev == Some(d - 1) { run + 1 } else { 1 };
        best = best.max(run);
        prev = Some(d);
    }
    best
}

/// The current run: ending today, or yesterday — a quiet morning does not
/// break last night's streak.
pub fn current_streak(days: &BTreeSet<i64>, today: i64) -> i64 {
    let mut d = if days.contains(&today) { today } else { today - 1 };
    let mut n = 0;
    while days.contains(&d) {
        n += 1;
        d -= 1;
    }
    n
}

/// Seconds read per local day.
pub fn by_day(sessions: &[Session], tz_secs: i64) -> HashMap<i64, i64> {
    let mut m = HashMap::new();
    for s in sessions {
        *m.entry(local_day(s.started, tz_secs)).or_insert(0) += s.secs();
    }
    m
}

/// Sessions closer than this read as one sitting.
pub const JOIN_GAP: i64 = 300;

/// Sittings, as a reader would count them. On a desktop a session ends every
/// time the window loses focus, so one evening's reading arrives as a dozen
/// sessions with a glance at another window between each; anything resumed
/// within [JOIN_GAP] is the same sitting, whichever book it was in.
pub fn sittings(sessions: &[Session]) -> Vec<Session> {
    let mut sorted = sessions.to_vec();
    sorted.sort_by_key(|s| s.started);
    let mut out: Vec<Session> = Vec::new();
    for s in sorted {
        match out.last_mut() {
            Some(last) if s.started - last.ended <= JOIN_GAP => {
                last.ended = last.ended.max(s.ended);
            }
            _ => out.push(s),
        }
    }
    out
}

/// The middle sitting, ignoring ones under a minute — opening a book to check
/// where you were is not a sitting.
pub fn typical_sitting(sessions: &[Session]) -> Option<i64> {
    let mut v: Vec<i64> = sessions.iter().map(|s| s.secs()).filter(|&s| s >= 60).collect();
    if v.is_empty() {
        return None;
    }
    v.sort_unstable();
    Some(v[v.len() / 2])
}

/// Within-book quartiles of the 节奏 score: chapters at or above the upper one
/// are the book's most intense quarter, at or below the lower its calmest.
pub fn pace_quartiles(scores: &[Option<f64>]) -> Option<(f64, f64)> {
    let mut v: Vec<f64> = scores.iter().flatten().copied().collect();
    if v.len() < 8 {
        return None;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
    Some((at(0.25), at(0.75)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(secs: i64, chars: i64) -> Window {
        Window {
            book_id: 1,
            chapter: 0,
            started: 0,
            secs,
            chars,
        }
    }

    #[test]
    fn windows_are_sorted_into_reading_idle_and_hunting() {
        assert_eq!(w(30, 300).kind(), Kind::Reading); // 600 字/分
        assert_eq!(w(30, 20).kind(), Kind::Idle); // looked away
        assert_eq!(w(30, 0).kind(), Kind::Idle);
        assert_eq!(w(30, 4000).kind(), Kind::Skim); // 8000 字/分
    }

    #[test]
    fn speed_ignores_walk_aways_and_hunting() {
        let mut ws: Vec<Window> = (0..40).map(|_| w(30, 300)).collect();
        ws.push(w(600, 10)); // ten minutes away from the screen
        ws.push(w(30, 9000)); // dragged the scrollbar
        let s = speed(&ws).unwrap();
        assert!((s.cpm - 600.0).abs() < 1e-9, "{s:?}");
    }

    #[test]
    fn the_extremes_of_real_reading_are_trimmed() {
        // 38 steady windows, one crawling and one racing — both still "reading".
        let mut ws: Vec<Window> = (0..38).map(|_| w(30, 300)).collect();
        ws.push(w(30, 40)); // 80 字/分
        ws.push(w(30, 1400)); // 2800 字/分
        let s = speed(&ws).unwrap();
        assert!((s.cpm - 600.0).abs() < 1e-9, "{s:?}");
    }

    #[test]
    fn no_speed_from_a_few_minutes() {
        let ws: Vec<Window> = (0..10).map(|_| w(30, 300)).collect();
        assert_eq!(speed(&ws), None);
    }

    #[test]
    fn skim_share_counts_characters_not_windows() {
        let ws = [w(30, 300), w(30, 300), w(10, 2400), w(600, 5)];
        assert!((skim_share(&ws) - 0.8).abs() < 1e-9);
        assert_eq!(skim_share(&[]), 0.0);
    }

    #[test]
    fn a_sitting_across_midnight_is_split_between_the_days() {
        // 23:40 → 00:20 UTC on Sunday 2026-10-11 → Monday.
        let start = 1_791_676_800 + 23 * 3600 + 40 * 60; // 2026-10-11 00:00 UTC + 23:40
        let s = Session {
            book_id: 1,
            started: start,
            ended: start + 40 * 60,
        };
        let (hours, days) = clock(&[s], 0);
        assert_eq!(hours[23], 20 * 60);
        assert_eq!(hours[0], 20 * 60);
        assert_eq!(days[6], 20 * 60, "Sunday");
        assert_eq!(days[0], 20 * 60, "Monday");
    }

    #[test]
    fn the_clock_follows_the_readers_timezone() {
        let s = Session {
            book_id: 1,
            started: 1_791_676_800, // 00:00 UTC
            ended: 1_791_676_800 + 600,
        };
        let (hours, _) = clock(&[s], 8 * 3600);
        assert_eq!(hours[8], 600);
    }

    #[test]
    fn weekdays_start_on_monday() {
        assert_eq!(weekday(0), 3); // 1970-01-01, a Thursday
        assert_eq!(weekday(local_day(1_791_676_800, 0)), 6); // 2026-10-11, a Sunday
    }

    #[test]
    fn streaks() {
        let days: BTreeSet<i64> = [1, 2, 3, 7, 8, 10].into_iter().collect();
        assert_eq!(best_streak(&days), 3);
        assert_eq!(current_streak(&days, 10), 1);
        assert_eq!(current_streak(&days, 9), 2, "yesterday still counts");
        assert_eq!(current_streak(&days, 12), 0);
        assert_eq!(best_streak(&BTreeSet::new()), 0);
    }

    #[test]
    fn a_typical_sitting_ignores_glances() {
        let s = |secs| Session {
            book_id: 1,
            started: 0,
            ended: secs,
        };
        assert_eq!(typical_sitting(&[s(5), s(10), s(600), s(1200), s(1800)]), Some(1200));
        assert_eq!(typical_sitting(&[s(5)]), None);
    }

    #[test]
    fn focus_flickers_do_not_split_a_sitting() {
        let s = |started, ended| Session {
            book_id: 1,
            started,
            ended,
        };
        let joined = sittings(&[s(800, 1600), s(0, 600), s(1700, 2000), s(2400, 2500)]);
        // 0–600, back 200 s later, on to 2000; 400 s away is a new sitting.
        assert_eq!(joined, vec![s(0, 2000), s(2400, 2500)]);
        assert_eq!(sittings(&[]), vec![]);
    }

    #[test]
    fn pace_quartiles_need_enough_chapters() {
        let few: Vec<Option<f64>> = vec![Some(1.0); 5];
        assert_eq!(pace_quartiles(&few), None);
        let many: Vec<Option<f64>> = (0..9).map(|i| Some(i as f64)).chain([None]).collect();
        assert_eq!(pace_quartiles(&many), Some((2.0, 6.0)));
    }
}
