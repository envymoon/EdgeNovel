//! 节奏 — how hard each chapter drives, counted from its own words.
//!
//! This replaced the model's eight mood labels (2026-10). On 80 hand-labelled
//! chapters from four books, the 0.6B model's label was right no more often than
//! answering 轻松 for every chapter, and its labels, read as intensity, told
//! fight-and-danger chapters from calm ones barely better than a coin
//! (AUC 0.60). Counting these words over the whole chapter reached 0.89 on the
//! same chapters, and held up on a held-out half the rule was never tuned on.
//!
//! What it measures is intensity, not feeling: 悲伤 and 悬疑 chapters sit in a
//! fuzzy middle, so nothing here names a mood. And it is relative to the book —
//! each count is a density per thousand characters, standardised across this
//! book's own chapters — so a battle-heavy xianxia and a slice-of-life comedy
//! each get their own highs and lows.

use crate::book::Chapter;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Word families, each counted as a density. The lists are generic on purpose:
/// written before looking at any chapter's score, and not tuned per genre.
const TENSE: &[&str] = &[
    "危险", "小心", "快跑", "冷汗", "屏住呼吸", "心跳", "惊恐", "恐惧", "慌", "千钧一发",
    "追杀", "逃", "糟了", "来不及", "致命", "生死", "毛骨悚然",
];
const FIERCE: &[&str] = &[
    "怒吼", "爆发", "战意", "斩", "轰", "击飞", "激战", "燃烧", "气势", "剑气", "刀芒", "突破",
    "杀意", "咆哮",
];
const MYSTERY: &[&str] = &[
    "线索", "秘密", "真相", "疑惑", "奇怪", "诡异", "谜", "调查", "推测", "猜测", "怀疑",
    "不对劲", "隐藏", "难道", "究竟",
];
const WARM: &[&str] = &[
    "温暖", "温柔", "微笑", "拥抱", "陪伴", "关心", "照顾", "妈妈", "母亲", "家人", "安心",
    "幸福", "礼物", "生日", "吃饭",
];

/// Danger, fighting, half of the mysteries and the exclamation marks push a
/// chapter up; domestic warmth pulls it down.
const WEIGHTS: [f64; 5] = [1.0, 1.0, 0.5, 0.5, -1.0];
const BANG: usize = 3;

/// Bodies shorter than this — author's notes, leave requests, a stub — have no
/// score: a 200-character note with two exclamation marks would otherwise be
/// the book's climax.
pub const MIN_CHARS: usize = 500;

/// First character → (word, family, word id), so a chapter is read once rather
/// than once per word.
fn matcher() -> &'static (HashMap<char, Vec<(&'static str, usize, usize)>>, usize) {
    static M: OnceLock<(HashMap<char, Vec<(&'static str, usize, usize)>>, usize)> =
        OnceLock::new();
    M.get_or_init(|| {
        let mut map: HashMap<char, Vec<(&'static str, usize, usize)>> = HashMap::new();
        let mut id = 0;
        for (family, words) in [(0, TENSE), (1, FIERCE), (2, MYSTERY), (4, WARM)] {
            for w in words {
                let first = w.chars().next().unwrap();
                map.entry(first).or_default().push((w, family, id));
                id += 1;
            }
        }
        (map, id)
    })
}

/// Per-thousand-character counts of each family, or None for a stub.
fn densities(body: &str) -> Option<[f64; 5]> {
    let chars = body.chars().count();
    if chars < MIN_CHARS {
        return None;
    }
    let (map, words) = matcher();
    let mut counts = [0f64; 5];
    // Non-overlapping per word ("哈哈哈" is one 哈哈), the way str.count reads.
    let mut next = vec![0usize; *words];
    for (pos, ch) in body.char_indices() {
        if ch == '！' || ch == '!' {
            counts[BANG] += 1.0;
            continue;
        }
        let Some(cands) = map.get(&ch) else { continue };
        for &(w, family, id) in cands {
            if pos >= next[id] && body[pos..].starts_with(w) {
                counts[family] += 1.0;
                next[id] = pos + w.len();
            }
        }
    }
    let k = chars as f64 / 1000.0;
    Some(counts.map(|c| c / k))
}

/// One score per chapter, in table-of-contents order. 0 is this book's
/// average; positive is more intense than the book usually is. None where the
/// chapter is too short to say.
pub fn scores(text: &str, chapters: &[Chapter]) -> Vec<Option<f64>> {
    let dens: Vec<Option<[f64; 5]>> = chapters
        .iter()
        .map(|c| densities(text[c.body_start.min(c.span.end)..c.span.end].trim()))
        .collect();
    let measured: Vec<&[f64; 5]> = dens.iter().flatten().collect();
    if measured.is_empty() {
        return vec![None; chapters.len()];
    }
    let n = measured.len() as f64;
    let mut mean = [0f64; 5];
    let mut sd = [0f64; 5];
    for f in 0..5 {
        mean[f] = measured.iter().map(|d| d[f]).sum::<f64>() / n;
        let var = measured.iter().map(|d| (d[f] - mean[f]).powi(2)).sum::<f64>() / n;
        sd[f] = var.sqrt();
    }
    dens.iter()
        .map(|d| {
            d.map(|d| {
                (0..5)
                    .filter(|&f| sd[f] > 0.0)
                    .map(|f| WEIGHTS[f] * (d[f] - mean[f]) / sd[f])
                    .sum()
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::{Chapter, Span};

    fn book(bodies: &[&str]) -> (String, Vec<Chapter>) {
        let mut text = String::new();
        let mut chapters = Vec::new();
        for (i, b) in bodies.iter().enumerate() {
            let start = text.len();
            text.push_str(&format!("第{}章\n", i + 1));
            let body_start = text.len();
            text.push_str(b);
            text.push('\n');
            chapters.push(Chapter {
                index: i,
                number: Some(i as u64 + 1),
                title: format!("第{}章", i + 1),
                span: Span { start, end: text.len() },
                body_start,
            });
        }
        (text, chapters)
    }

    fn filler(n: usize) -> String {
        "他走在路上，想着今天的事情。".repeat(n)
    }

    #[test]
    fn a_fight_outscores_a_family_dinner() {
        let fight = format!("{}他怒吼一声，剑气纵横，轰！危险！快跑！{}", filler(20), filler(20));
        let dinner = format!("{}一家人吃饭，妈妈微笑着照顾他，很温暖。{}", filler(20), filler(20));
        let plain = filler(45);
        let (text, chapters) = book(&[&fight, &dinner, &plain]);
        let s = scores(&text, &chapters);
        let (f, d, p) = (s[0].unwrap(), s[1].unwrap(), s[2].unwrap());
        assert!(f > p && p > d, "fight {f}, plain {p}, dinner {d}");
    }

    #[test]
    fn stubs_have_no_score_and_do_not_skew_the_rest() {
        let note = "请假一天！！！明天补上！！！";
        let a = format!("{}危险！{}", filler(20), filler(20));
        let b = filler(45);
        let (text, chapters) = book(&[&a, note, &b]);
        let s = scores(&text, &chapters);
        assert_eq!(s[1], None);
        assert!(s[0].unwrap() > s[2].unwrap());
    }

    #[test]
    fn repeated_letters_count_once_per_occurrence() {
        let d = densities(&format!("逃逃逃{}", filler(40))).unwrap();
        let chars = format!("逃逃逃{}", filler(40)).chars().count() as f64;
        assert!((d[0] - 3.0 / (chars / 1000.0)).abs() < 1e-9);
    }

    #[test]
    fn a_flat_book_is_flat() {
        let b = filler(45);
        let (text, chapters) = book(&[&b, &b, &b]);
        assert!(scores(&text, &chapters).iter().all(|s| *s == Some(0.0)));
    }
}
