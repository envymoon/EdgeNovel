//! 节奏 — how hard each chapter drives, counted from its own text.
//!
//! Plan A (2026-11): combines structural pacing signals (short-sentence burst
//! ratio, average sentence contraction, question/exclamation cadence),
//! de-noised cross-genre lexicons (zero ambiguous 1-char matches, covering
//! danger, physical & verbal/urban conflict, physiological tension cues,
//! suspense, strong grief, and warmth/comedy counter-weights), intra-chapter
//! peak windowing (4 chunks blended mean+max so late-chapter climaxes are not
//! diluted), and robust per-book standardization (median + IQR).
//!
//! No AI model is involved: ~60-80ms for a 1500-chapter book, zero RAM/thermal
//! overhead on mobile, and each chapter also gets 1-2 concise driver tags.

use crate::book::Chapter;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Cross-genre de-noised word families (2-4 chars, no ambiguous 1-char terms).
const DANGER: &[&str] = &[
    "危险", "危机", "致命", "生死", "性命", "追杀", "逃跑", "逃命", "逃离", "逃窜", "撤离",
    "来不及", "千钧一发", "危急", "警报", "失控", "坍塌", "垮塌", "毁灭", "末日", "偷袭",
    "围堵", "伏击", "陷阱", "毒素", "下毒", "求救", "惨叫", "哀嚎", "血肉", "尸体", "死亡",
    "杀意", "杀了", "必死", "活命", "命悬一线", "毛骨悚然", "惊恐", "恐惧", "恐怖", "骇然",
    "恐慌", "惊慌", "慌乱", "糟糕", "糟了", "不妙", "惨烈", "重伤", "见血", "鲜血", "流血",
    "危机四伏", "危在旦夕", "生死攸关", "绝境", "险境", "遇险", "丧命", "殒命", "逼近",
];

const CONFLICT: &[&str] = &[
    "激战", "恶战", "交手", "动手", "反击", "爆发", "轰鸣", "轰隆", "炸开", "爆炸", "斩杀",
    "劈斩", "击飞", "砸去", "贯穿", "撕裂", "焚烧", "怒吼", "咆哮", "嘶吼", "喝道", "大喊",
    "对峙", "质问", "逼问", "威胁", "警告", "摊牌", "翻脸", "撕破脸", "僵持", "刁难", "拷问",
    "铐回去", "抓捕", "强硬", "死缠烂打", "冷笑", "阴谋", "陷害", "背叛", "出卖", "暴露",
    "恼火", "大怒", "暴怒", "愤怒", "发狠", "拼命", "死战", "血战", "围攻", "压制", "失手",
    "争执", "争吵", "冲突", "碰撞", "交锋", "对抗", "剑拔弩张", "杀气", "搏杀", "厮杀",
];

const PHYSIO: &[&str] = &[
    "冷汗", "屏住呼吸", "心跳", "心猛地", "攥紧", "紧绷", "绷紧", "瞳孔", "眸光", "收缩",
    "煞白", "铁青", "骤然一沉", "脸色大变", "面色一变", "目光一凝", "心一沉", "心往下一沉",
    "冰凉", "发颤", "颤抖", "发抖", "哆嗦", "僵住", "倒吸", "骤停", "窒息", "失态",
    "咬牙", "捏紧", "握紧", "背脊发凉", "头皮发麻", "呼吸急促", "青筋", "面色阴沉",
];

const SUSPENSE: &[&str] = &[
    "线索", "秘密", "真相", "诡异", "怪异", "奇诡", "谜团", "谜底", "调查", "推测", "猜测",
    "怀疑", "不对劲", "隐藏", "难道", "究竟", "漏洞", "规则", "异常", "潜入", "窃听", "监视",
    "防备", "戒备", "警觉", "警惕", "诡计", "圈套", "幕后", "破绽", "疑点", "暗中", "蹊跷",
];

const GRIEF: &[&str] = &[
    "痛哭", "哭泣", "泣不成声", "抽泣", "哽咽", "绝望", "崩溃", "心痛", "心碎", "悲痛",
    "哀恸", "陨落", "气绝", "死不瞑目", "悲伤", "痛苦", "嘶哑", "泪水", "眼泪", "泪流",
    "眼眶红", "双目通红", "自责", "愧疚", "悔恨", "凄凉", "惨痛", "泪落", "失声痛哭",
];

const WARM_COMEDY: &[&str] = &[
    "温暖", "温柔", "微笑", "拥抱", "陪伴", "照顾", "安心", "幸福", "礼物", "生日", "吃饭",
    "早饭", "午饭", "晚饭", "泡脚", "被窝", "甜蜜", "恬然", "娇嗔", "愉快", "相谈甚欢",
    "开心", "高兴", "哈哈", "哈哈哈", "乐呵呵", "笑嘻嘻", "打了个哈哈", "搞笑", "吐槽",
    "无奈", "翻白眼", "开玩笑", "闲聊", "休假", "逛街", "蛋糕", "咖啡厅", "求月票",
    "笑出声", "忍俊不禁", "打趣", "玩笑", "惬意", "悠闲", "日常",
];

const FAM_DANGER: usize = 0;
const FAM_CONFLICT: usize = 1;
const FAM_PHYSIO: usize = 2;
const FAM_SUSPENSE: usize = 3;
const FAM_GRIEF: usize = 4;
const FAM_WARM: usize = 5;
const FAMILIES: usize = 6;

/// Bodies shorter than this — author's notes, leave requests, a stub — have no
/// score: a 200-character note with two exclamation marks would otherwise skew
/// the curve.
pub const MIN_CHARS: usize = 500;

/// Per-chapter pacing result: standardized score (0 = book median, higher =
/// more intense) and 1-2 concise Chinese driver tags.
#[derive(Debug, Clone, PartialEq)]
pub struct ChapterPace {
    pub score: Option<f64>,
    pub tags: Vec<&'static str>,
}

/// First character -> (word, family, word id), so each chunk is scanned once.
fn matcher() -> &'static (HashMap<char, Vec<(&'static str, usize, usize)>>, usize) {
    static M: OnceLock<(HashMap<char, Vec<(&'static str, usize, usize)>>, usize)> =
        OnceLock::new();
    M.get_or_init(|| {
        let mut map: HashMap<char, Vec<(&'static str, usize, usize)>> = HashMap::new();
        let mut id = 0;
        let families = [
            (FAM_DANGER, DANGER),
            (FAM_CONFLICT, CONFLICT),
            (FAM_PHYSIO, PHYSIO),
            (FAM_SUSPENSE, SUSPENSE),
            (FAM_GRIEF, GRIEF),
            (FAM_WARM, WARM_COMEDY),
        ];
        for (family, words) in families {
            for w in words {
                let first = w.chars().next().unwrap();
                map.entry(first).or_default().push((w, family, id));
                id += 1;
            }
        }
        (map, id)
    })
}

#[derive(Debug, Clone, Copy, Default)]
struct ChunkStats {
    raw: f64,
    danger: f64,
    conflict: f64,
    physio: f64,
    suspense: f64,
    grief: f64,
    warm: f64,
    struct_pace: f64,
}

fn score_chunk(chunk: &str) -> ChunkStats {
    let chars = chunk.chars().count();
    if chars == 0 {
        return ChunkStats::default();
    }
    let (map, words) = matcher();
    let mut counts = [0f64; FAMILIES];
    let mut next = vec![0usize; *words];
    let mut bang = 0f64;
    let mut bang_q = 0f64;

    // Sentence segmentation metrics in the same single pass.
    let mut sent_len = 0usize;
    let mut sent_count = 0usize;
    let mut short_sents = 0usize;
    let mut total_sent_chars = 0usize;

    let mut prev_ch = '\0';
    for (pos, ch) in chunk.char_indices() {
        if ch == '！' || ch == '!' {
            bang += 1.0;
            if prev_ch == '？' || prev_ch == '?' {
                bang_q += 1.0;
            }
        } else if (ch == '？' || ch == '?') && (prev_ch == '！' || prev_ch == '!') {
            bang_q += 1.0;
        }

        if matches!(ch, '。' | '！' | '？' | '!' | '?' | '；' | ';' | '\n' | '\r') {
            if sent_len >= 2 {
                sent_count += 1;
                total_sent_chars += sent_len;
                if sent_len <= 18 {
                    short_sents += 1;
                }
            }
            sent_len = 0;
        } else if !ch.is_whitespace() {
            sent_len += 1;
        }

        if let Some(cands) = map.get(&ch) {
            for &(w, family, id) in cands {
                if pos >= next[id] && chunk[pos..].starts_with(w) {
                    counts[family] += 1.0;
                    next[id] = pos + w.len();
                }
            }
        }
        prev_ch = ch;
    }
    if sent_len >= 2 {
        sent_count += 1;
        total_sent_chars += sent_len;
        if sent_len <= 18 {
            short_sents += 1;
        }
    }

    let k = (chars as f64 / 1000.0).max(0.05);
    let d_danger = counts[FAM_DANGER] / k;
    let d_conflict = counts[FAM_CONFLICT] / k;
    let d_physio = counts[FAM_PHYSIO] / k;
    let d_suspense = counts[FAM_SUSPENSE] / k;
    let d_grief = counts[FAM_GRIEF] / k;
    let d_warm = counts[FAM_WARM] / k;

    let d_bang_q = bang_q / k;
    let d_bang = (bang / k).ln_1p();

    let (short_ratio, avg_sent) = if sent_count > 0 {
        (
            short_sents as f64 / sent_count as f64,
            total_sent_chars as f64 / sent_count as f64,
        )
    } else {
        (0.0, 30.0)
    };
    let struct_pace = ((short_ratio - 0.35) * 2.5).clamp(0.0, 1.5)
        + ((28.0 - avg_sent) / 18.0).clamp(0.0, 1.0);

    let c_danger = (d_danger / 4.0).tanh();
    let c_conflict = (d_conflict / 4.0).tanh();
    let c_physio = (d_physio / 3.0).tanh();
    let c_suspense = (d_suspense / 4.0).tanh();
    let c_grief = (d_grief / 3.0).tanh();
    let c_warm = (d_warm / 3.5).tanh();

    let raw = 1.2 * c_danger
        + 1.3 * c_conflict
        + 1.0 * c_physio
        + 0.6 * c_suspense
        + 0.7 * c_grief
        + 0.4 * (d_bang_q / 2.0).tanh()
        + 0.25 * (d_bang / 2.5).tanh()
        + 0.55 * struct_pace
        - 1.0 * c_warm;

    ChunkStats {
        raw,
        danger: c_danger,
        conflict: c_conflict,
        physio: c_physio,
        suspense: c_suspense,
        grief: c_grief,
        warm: c_warm,
        struct_pace,
    }
}

/// Split `body` into `n` roughly equal slices along UTF-8 char boundaries.
fn split_chunks(body: &str, n: usize) -> Vec<&str> {
    let total_chars = body.chars().count();
    if n <= 1 || total_chars < n * 2 {
        return vec![body];
    }
    let mut bounds = Vec::with_capacity(n + 1);
    bounds.push(0usize);
    let mut next_chunk = 1usize;
    let mut target = total_chars / n;
    for (ci, (bi, _)) in body.char_indices().enumerate() {
        if ci == target && next_chunk < n {
            bounds.push(bi);
            next_chunk += 1;
            target = total_chars * next_chunk / n;
        }
    }
    bounds.push(body.len());
    bounds.windows(2).map(|w| &body[w[0]..w[1]]).collect()
}

fn measure_chapter(body: &str) -> Option<ChunkStats> {
    let chars = body.chars().count();
    if chars < MIN_CHARS {
        return None;
    }
    let n_chunks = if chars >= 1600 { 4 } else { 2 };
    let chunks = split_chunks(body, n_chunks);
    let stats: Vec<ChunkStats> = chunks.into_iter().map(score_chunk).collect();
    let n = stats.len() as f64;
    let mean_raw = stats.iter().map(|s| s.raw).sum::<f64>() / n;
    let max_raw = stats
        .iter()
        .map(|s| s.raw)
        .fold(f64::NEG_INFINITY, f64::max);
    let blend = |f: fn(&ChunkStats) -> f64| -> f64 {
        let m = stats.iter().map(f).sum::<f64>() / n;
        let mx = stats.iter().map(f).fold(0.0f64, f64::max);
        0.5 * m + 0.5 * mx
    };
    Some(ChunkStats {
        raw: 0.55 * mean_raw + 0.45 * max_raw,
        danger: blend(|s| s.danger),
        conflict: blend(|s| s.conflict),
        physio: blend(|s| s.physio),
        suspense: blend(|s| s.suspense),
        grief: blend(|s| s.grief),
        warm: blend(|s| s.warm),
        struct_pace: blend(|s| s.struct_pace),
    })
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let pos = ((sorted.len() - 1) as f64 * p).clamp(0.0, (sorted.len() - 1) as f64);
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
    }
}

fn robust_scale(xs: &[f64]) -> (f64, f64) {
    if xs.is_empty() {
        return (0.0, 0.0);
    }
    let mut s = xs.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    let med = percentile(&s, 0.5);
    let iqr = percentile(&s, 0.75) - percentile(&s, 0.25);
    // 1.349 maps normal IQR to 1 standard deviation.
    let scale = if iqr > 1e-6 {
        iqr / 1.349
    } else {
        let n = xs.len() as f64;
        let mean = xs.iter().sum::<f64>() / n;
        let var = xs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n;
        var.sqrt()
    };
    (med, scale)
}

fn pick_tags(st: &ChunkStats, z_score: f64, med: &ChunkStats) -> Vec<&'static str> {
    let mut tags: Vec<&'static str> = Vec::with_capacity(2);
    // Rank positive tension drivers by how clearly they stand out above both
    // an absolute floor and the book's own median.
    let mut drivers: [(&'static str, f64); 5] = [
        ("冲突", (st.conflict - med.conflict * 0.7).max(0.0) * 1.15),
        ("危机", (st.danger - med.danger * 0.7).max(0.0) * 1.15),
        ("悬疑", (st.suspense - med.suspense * 0.7).max(0.0) * 0.95),
        (
            "情绪",
            ((st.grief - med.grief * 0.6).max(0.0) * 1.1
                + (st.physio - med.physio * 0.7).max(0.0) * 0.65),
        ),
        ("快节奏", ((st.struct_pace - med.struct_pace) * 0.55).max(0.0)),
    ];
    drivers.sort_by(|a, b| b.1.total_cmp(&a.1));

    if z_score >= 0.35 {
        for &(label, val) in &drivers {
            if val >= 0.22 && tags.len() < 2 {
                tags.push(label);
            }
        }
        if tags.is_empty() {
            tags.push("升温");
        }
    } else if z_score <= -0.35 {
        if st.warm >= 0.32 && st.warm >= med.warm {
            tags.push("日常");
        } else {
            tags.push("铺垫");
        }
        if st.suspense >= 0.45 && st.suspense > med.suspense + 0.15 {
            tags.push("悬疑");
        } else if st.warm >= 0.48 && !tags.contains(&"日常") {
            tags.push("轻松");
        }
    } else {
        if st.warm >= 0.42 && st.warm > med.warm + 0.12 {
            tags.push("日常");
        } else if drivers[0].1 >= 0.28 {
            tags.push(drivers[0].0);
        } else {
            tags.push("推进");
        }
        if tags.len() < 2 && drivers[0].0 != tags[0] && drivers[0].1 >= 0.32 {
            tags.push(drivers[0].0);
        }
    }
    tags
}

/// Full per-chapter pacing analysis: standardized intensity score + 1-2 tags.
pub fn analyze(text: &str, chapters: &[Chapter]) -> Vec<ChapterPace> {
    let measured: Vec<Option<ChunkStats>> = chapters
        .iter()
        .map(|c| measure_chapter(text[c.body_start.min(c.span.end)..c.span.end].trim()))
        .collect();
    let valid: Vec<ChunkStats> = measured.iter().flatten().copied().collect();
    if valid.is_empty() {
        return chapters
            .iter()
            .map(|_| ChapterPace {
                score: None,
                tags: Vec::new(),
            })
            .collect();
    }

    let raws: Vec<f64> = valid.iter().map(|s| s.raw).collect();
    let (med_raw, scale_raw) = robust_scale(&raws);

    let med_field = |f: fn(&ChunkStats) -> f64| -> f64 {
        let mut xs: Vec<f64> = valid.iter().map(f).collect();
        xs.sort_by(|a, b| a.total_cmp(b));
        percentile(&xs, 0.5)
    };
    let med = ChunkStats {
        raw: med_raw,
        danger: med_field(|s| s.danger),
        conflict: med_field(|s| s.conflict),
        physio: med_field(|s| s.physio),
        suspense: med_field(|s| s.suspense),
        grief: med_field(|s| s.grief),
        warm: med_field(|s| s.warm),
        struct_pace: med_field(|s| s.struct_pace),
    };

    measured
        .into_iter()
        .map(|m| match m {
            None => ChapterPace {
                score: None,
                tags: Vec::new(),
            },
            Some(st) => {
                let z = if scale_raw > 1e-6 {
                    (st.raw - med_raw) / scale_raw
                } else {
                    0.0
                };
                let tags = pick_tags(&st, z, &med);
                ChapterPace {
                    score: Some(z),
                    tags,
                }
            }
        })
        .collect()
}

/// One score per chapter, in table-of-contents order. 0 is this book's median;
/// positive is more intense than the book usually is. None where the chapter
/// is too short to say.
pub fn scores(text: &str, chapters: &[Chapter]) -> Vec<Option<f64>> {
    analyze(text, chapters).into_iter().map(|c| c.score).collect()
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
                span: Span {
                    start,
                    end: text.len(),
                },
                body_start,
            });
        }
        (text, chapters)
    }

    fn filler(n: usize) -> String {
        "他走在路上，想着今天的事情，街道上风很轻，行人不紧不慢地走过。".repeat(n)
    }

    #[test]
    fn a_fight_outscores_a_family_dinner() {
        let fight = format!(
            "{}他怒吼一声，正面交手，轰鸣炸开！生死危机，快逃命！{}",
            filler(12),
            filler(12)
        );
        let dinner = format!(
            "{}一家人吃饭，微笑着照顾彼此，很温暖，开心闲聊。{}",
            filler(12),
            filler(12)
        );
        let plain = filler(26);
        let (text, chapters) = book(&[&fight, &dinner, &plain]);
        let s = scores(&text, &chapters);
        let (f, d, p) = (s[0].unwrap(), s[1].unwrap(), s[2].unwrap());
        assert!(f > p && p > d, "fight {f}, plain {p}, dinner {d}");
    }

    #[test]
    fn stubs_have_no_score_and_do_not_skew_the_rest() {
        let note = "请假一天！！！明天补上！！！";
        let a = format!("{}生死危机，警报响起！{}", filler(12), filler(12));
        let b = filler(26);
        let (text, chapters) = book(&[&a, note, &b]);
        let s = scores(&text, &chapters);
        assert_eq!(s[1], None);
        assert!(s[0].unwrap() > s[2].unwrap());
    }

    #[test]
    fn quiet_urban_confrontation_rises_above_daily_chatter() {
        let tense = format!(
            "{}他冷笑一声，当面摊牌质问。对方脸色大变，心一沉，额头渗出冷汗，气氛剑拔弩张。{}",
            filler(12),
            filler(12)
        );
        let comedy = format!(
            "{}大家哈哈大笑，吐槽不断，开玩笑说今天吃饭太开心了！哈哈！{}",
            filler(12),
            filler(12)
        );
        let plain = filler(26);
        let (text, chapters) = book(&[&tense, &comedy, &plain, &plain, &plain]);
        let res = analyze(&text, &chapters);
        assert!(
            res[0].score.unwrap() > res[2].score.unwrap(),
            "tense {:?}",
            res
        );
        assert!(
            res[1].score.unwrap() < res[0].score.unwrap(),
            "comedy {:?}",
            res
        );
        assert!(!res[0].tags.is_empty());
    }

    #[test]
    fn late_chapter_climax_is_not_diluted_by_calm_opening() {
        let climax = format!(
            "{}突然警报拉响！对方翻脸威胁，阴谋暴露，杀意沸腾！他瞳孔收缩，立刻反击！",
            filler(30)
        );
        let plain = filler(32);
        let (text, chapters) = book(&[&climax, &plain, &plain, &plain]);
        let s = scores(&text, &chapters);
        assert!(s[0].unwrap() > s[1].unwrap(), "{:?}", s);
    }

    #[test]
    fn a_flat_book_is_flat() {
        let b = filler(26);
        let (text, chapters) = book(&[&b, &b, &b]);
        assert!(scores(&text, &chapters).iter().all(|s| *s == Some(0.0)));
    }
}
