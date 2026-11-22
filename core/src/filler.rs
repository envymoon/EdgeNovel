//! 注水度 — how much padding / repetition each chapter carries, measured
//! without a model from information-theoretic and web-novel signals.
//!
//! Each chapter (with at least [`MIN_CHARS`] characters) receives a score in
//! `0.0..=1.0`, where higher means more repetitive, cliché-heavy, or stagnant:
//!
//! 1. **Windowed bigram repetition** (250-CJK sliding segments, length-invariant)
//! 2. **4-gram recurrence** (repeated phrases / recycled descriptions inside a chapter)
//! 3. **Web-novel filler cliché density** (stock phrases per 1,000 chars)
//! 4. **Cross-chapter stagnation** (share of this chapter's bigrams already seen
//!    in the previous 3 chapters)

use crate::book::Chapter;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::OnceLock;

/// Chapters shorter than this (author notes, stubs) return `None`.
pub const MIN_CHARS: usize = 500;
const WINDOW: usize = 250;

/// Stock padding / filler phrases common in padded web-novel chapters.
const CLICHES: &[&str] = &[
    "不由得", "微微一笑", "点了点头", "摇了摇头", "深吸一口气", "倒吸一口凉气", "恐怖如斯",
    "淡淡道", "冷笑一声", "皱了皱眉", "沉默了片刻", "眼中闪过", "嘴角微微", "心中暗道",
    "浑身一震", "脸色大变", "不敢置信", "不可思议", "缓缓说道", "沉声道", "轻笑一声",
    "叹了口气", "与此同时", "就在这时", "话音未落", "下一刻", "突然间", "刹那间",
    "不由分说", "毫无疑问", "毋庸置疑", "说实话", "老实说", "事实上", "总而言之",
    "微微一愣", "忍不住", "下意识", "紧接着", "紧随其后", "面色一变", "目光一闪",
    "淡淡的道", "轻叹一声", "冷哼一声", "嘴角勾起", "瞳孔骤缩", "倒抽一口凉气",
    "仿佛", "竟然", "居然", "不禁", "顿时", "连忙", "急忙", "随即", "旋即",
];

fn cliche_matcher() -> &'static (HashMap<char, Vec<(&'static str, usize)>>, usize) {
    static M: OnceLock<(HashMap<char, Vec<(&'static str, usize)>>, usize)> = OnceLock::new();
    M.get_or_init(|| {
        let mut map: HashMap<char, Vec<(&'static str, usize)>> = HashMap::new();
        for (id, &w) in CLICHES.iter().enumerate() {
            let first = w.chars().next().unwrap();
            map.entry(first).or_default().push((w, id));
        }
        (map, CLICHES.len())
    })
}

#[inline]
fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c)
}

#[inline]
fn pack2(a: char, b: char) -> u32 {
    ((a as u32) << 16) | (b as u32 & 0xffff)
}

#[inline]
fn pack4(a: char, b: char, c: char, d: char) -> u64 {
    ((a as u64) << 48)
        | (((b as u64) & 0xffff) << 32)
        | (((c as u64) & 0xffff) << 16)
        | ((d as u64) & 0xffff)
}

#[inline]
fn norm(x: f64, lo: f64, hi: f64) -> f64 {
    if hi <= lo {
        return 0.5;
    }
    ((x - lo) / (hi - lo)).clamp(0.0, 1.0)
}

struct RawMetrics {
    rep_bigram: f64,
    rep_4gram: f64,
    cliche_per_k: f64,
    bigrams: HashSet<u32>,
}

fn measure(body: &str) -> Option<RawMetrics> {
    let total_chars = body.chars().count();
    if total_chars < MIN_CHARS {
        return None;
    }

    // 1) Stock filler cliché density per 1,000 chars.
    let (map, n_words) = cliche_matcher();
    let mut next = vec![0usize; *n_words];
    let mut cliche_hits = 0usize;
    for (pos, ch) in body.char_indices() {
        if let Some(cands) = map.get(&ch) {
            for &(w, id) in cands {
                if pos >= next[id] && body[pos..].starts_with(w) {
                    cliche_hits += 1;
                    next[id] = pos + w.len();
                }
            }
        }
    }
    let cliche_per_k = cliche_hits as f64 / (total_chars as f64 / 1000.0);

    // Extract CJK stream for length-invariant n-gram statistics.
    let cjk: Vec<char> = body.chars().filter(|&c| is_cjk(c)).collect();
    if cjk.len() < 200 {
        return None;
    }

    // 2) Windowed bigram repetition (mean over 250-CJK segments).
    let mut win_reps = Vec::new();
    let mut all_bigrams: HashSet<u32> = HashSet::with_capacity(cjk.len() / 2);
    for chunk in cjk.chunks(WINDOW) {
        if chunk.len() < 80 && !win_reps.is_empty() {
            break;
        }
        let mut seen: HashSet<u32> = HashSet::with_capacity(chunk.len());
        let total = chunk.len().saturating_sub(1);
        for w in chunk.windows(2) {
            let bg = pack2(w[0], w[1]);
            seen.insert(bg);
            all_bigrams.insert(bg);
        }
        if total > 0 {
            win_reps.push(1.0 - (seen.len() as f64 / total as f64));
        }
    }
    let rep_bigram = if win_reps.is_empty() {
        0.0
    } else {
        win_reps.iter().sum::<f64>() / win_reps.len() as f64
    };

    // 3) 4-gram recurrence across the chapter.
    let mut fg_counts: HashMap<u64, u32> = HashMap::with_capacity(cjk.len());
    let total_4 = cjk.len().saturating_sub(3);
    for w in cjk.windows(4) {
        *fg_counts.entry(pack4(w[0], w[1], w[2], w[3])).or_default() += 1;
    }
    let repeated_4: u32 = fg_counts.values().filter(|&&c| c >= 2).map(|&c| c - 1).sum();
    let rep_4gram = if total_4 > 0 {
        repeated_4 as f64 / total_4 as f64
    } else {
        0.0
    };

    Some(RawMetrics {
        rep_bigram,
        rep_4gram,
        cliche_per_k,
        bigrams: all_bigrams,
    })
}

/// One filler/padding score per chapter in `0.0..=1.0` (higher = more padded),
/// or `None` for chapters shorter than [`MIN_CHARS`].
pub fn scores(text: &str, chapters: &[Chapter]) -> Vec<Option<f64>> {
    let mut prev_windows: VecDeque<HashSet<u32>> = VecDeque::with_capacity(3);
    let mut out = Vec::with_capacity(chapters.len());

    for ch in chapters {
        let body = text[ch.body_start.min(ch.span.end)..ch.span.end].trim();
        let Some(m) = measure(body) else {
            out.push(None);
            continue;
        };

        // 4) Cross-chapter stagnation: fraction of unique bigrams seen in last 3 chapters.
        let stagnation = if prev_windows.is_empty() || m.bigrams.is_empty() {
            0.35
        } else {
            let shared = m
                .bigrams
                .iter()
                .filter(|bg| prev_windows.iter().any(|w| w.contains(bg)))
                .count();
            shared as f64 / m.bigrams.len() as f64
        };

        if prev_windows.len() == 3 {
            prev_windows.pop_front();
        }
        prev_windows.push_back(m.bigrams);

        // Calibrated against typical Chinese web-novel prose:
        // - rep_bigram: tight literary prose ~0.07, padded serial ~0.26+
        // - rep_4gram: tight ~0.01, recycled padding ~0.12+
        // - cliche_per_k: tight ~1.5, heavy cliché padding ~14+
        // - stagnation: fresh arc ~0.22, treading water ~0.58+
        let s_bi = norm(m.rep_bigram, 0.06, 0.28);
        let s_4g = norm(m.rep_4gram, 0.008, 0.13);
        let s_cl = norm(m.cliche_per_k, 1.0, 14.0);
        let s_st = norm(stagnation, 0.20, 0.60);

        let score = (0.35 * s_bi + 0.25 * s_4g + 0.20 * s_cl + 0.20 * s_st).clamp(0.0, 1.0);
        out.push(Some(score));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::Span;

    fn mk_chapter(index: usize, start: usize, end: usize) -> Chapter {
        Chapter {
            index,
            number: Some(index as u64 + 1),
            title: format!("第{}章", index + 1),
            span: Span { start, end },
            body_start: start,
        }
    }

    #[test]
    fn padded_repetition_scores_higher_than_varied_prose() {
        let padded = "他不由得微微一笑，点了点头，深吸一口气，倒吸一口凉气，心中暗道恐怖如斯。".repeat(30);
        let varied = concat!(
            "暮春细雨敲打青瓦，城南渡口泊着三艘乌篷船。老艄公解开缆绳，竹篙点水，雾气在河面缓缓散开。",
            "茶肆门前挂着褪色布幡，伙计拎着铜壶穿梭于桌案之间，蒸笼里飘出糯米与桂花的清香。",
            "西市铁匠铺风箱呼啸，火星溅落青石板，学徒擦去额角汗珠，将烧红的马蹄铁浸入冷水槽中滋滋作响。",
            "城楼鼓声三响，商队驼铃由远及近，押镖头目勒住枣红马，翻身下鞍向守门校尉递交路引文书。",
            "书院后山松涛阵阵，石阶覆满苍苔，几名青衫学子捧卷疾行，议论着今岁秋闱策论的冷门题目。",
            "药铺掌柜低头拨弄算盘，伙计按方抓齐当归黄芪与茯苓，用油纸包得方正齐整递给候诊妇人。",
            "傍晚霞光染红城垣，归巢寒鸦掠过古塔飞檐，街巷陆续亮起灯笼，更夫敲着竹梆沿长街缓步巡夜。",
            "码头酒家二楼临窗雅座，两位行商举杯对饮，谈及岭南丝绸行市涨跌与北地盐引官票的周转难题。",
            "夜深露重，竹林深处溪水潺潺，石桥畔一盏孤灯随风摇曳，映照着岸边半截残碑上模糊的篆刻铭文。",
            "晓鸡初啼，早市菜农挑着竹筐陆续进城，嫩绿菠菜与带泥春笋码放整齐，喧闹市声唤醒沉睡的坊市。",
        )
        .repeat(2);
        let text = format!("{padded}{varied}");
        let chapters = vec![
            mk_chapter(0, 0, padded.len()),
            mk_chapter(1, padded.len(), text.len()),
        ];
        let s = scores(&text, &chapters);
        let p = s[0].unwrap();
        let v = s[1].unwrap();
        assert!(p > v + 0.35, "expected padded ({p:.3}) >> varied ({v:.3})");
    }
}
