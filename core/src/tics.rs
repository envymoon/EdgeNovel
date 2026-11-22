//! 作者口癖 — author writing habits, signature tics, and stylistic fingerprint.
//!
//! Pure-Rust, model-free analysis over the whole book:
//! 1. **Style fingerprint**: dialogue share, average sentence length, exclamation /
//!    ellipsis / question density per 10,000 CJK chars, and concise style tags.
//! 2. **Signature tics**: ~165 curated high-signal Chinese novel writing habits
//!    grouped into 5 categories (`神态动作`, `说话腔调`, `转折推进`, `夸张惊叹`,
//!    `口头禅`). Each tic carries total count, per-10k density, chapter coverage,
//!    peak chapter, a real sample sentence from the book, and a 24-bucket
//!    distribution sparkline across the book.

use crate::book::Chapter;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Number of equal-chapter buckets for the per-tic distribution sparkline.
pub const BUCKETS: usize = 24;

#[derive(Debug, Clone)]
pub struct TicItem {
    pub phrase: String,
    pub category: String,
    pub count: usize,
    pub per_10k: f64,
    pub chapter_hits: usize,
    pub peak_chapter: usize,
    pub peak_count: usize,
    pub sample: String,
    pub sample_chapter: usize,
    pub buckets: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct AuthorTics {
    pub total_chars: usize,
    pub chapter_count: usize,
    pub dialogue_ratio: f64,
    pub avg_sentence_len: f64,
    pub exclam_per_10k: f64,
    pub ellipsis_per_10k: f64,
    pub question_per_10k: f64,
    pub style_tags: Vec<String>,
    pub items: Vec<TicItem>,
}

/// Curated Chinese novel author tics grouped by category.
const LEXICON: &[(&str, &str)] = &[
    // 神态动作
    ("倒吸一口凉气", "神态动作"),
    ("倒抽一口凉气", "神态动作"),
    ("深吸一口气", "神态动作"),
    ("吸了一口气", "神态动作"),
    ("嘴角微微上扬", "神态动作"),
    ("嘴角微微勾起", "神态动作"),
    ("嘴角抽了抽", "神态动作"),
    ("嘴角勾起", "神态动作"),
    ("微微一笑", "神态动作"),
    ("微微颔首", "神态动作"),
    ("点了点头", "神态动作"),
    ("摇了摇头", "神态动作"),
    ("皱了皱眉", "神态动作"),
    ("挑了挑眉", "神态动作"),
    ("眯了眯眼", "神态动作"),
    ("眨了眨眼", "神态动作"),
    ("瞳孔骤缩", "神态动作"),
    ("眼中闪过", "神态动作"),
    ("目光一凝", "神态动作"),
    ("目光一闪", "神态动作"),
    ("脸色大变", "神态动作"),
    ("面色一变", "神态动作"),
    ("浑身一震", "神态动作"),
    ("心头一震", "神态动作"),
    ("心神剧震", "神态动作"),
    ("心中暗道", "神态动作"),
    ("微微一愣", "神态动作"),
    ("愣了一下", "神态动作"),
    ("沉默了片刻", "神态动作"),
    ("沉默片刻", "神态动作"),
    ("沉默了会儿", "神态动作"),
    ("想了想", "神态动作"),
    ("顿了顿", "神态动作"),
    ("叹了口气", "神态动作"),
    ("轻叹一声", "神态动作"),
    ("冷哼一声", "神态动作"),
    ("冷笑一声", "神态动作"),
    ("轻笑一声", "神态动作"),
    ("苦笑一声", "神态动作"),
    ("耸了耸肩", "神态动作"),
    ("摸了摸鼻子", "神态动作"),
    ("翻了个白眼", "神态动作"),
    ("咬了咬牙", "神态动作"),
    ("握紧拳头", "神态动作"),
    ("摆了摆手", "神态动作"),
    ("撇了撇嘴", "神态动作"),
    ("眯起眼睛", "神态动作"),
    ("瞪大眼睛", "神态动作"),
    ("头皮发麻", "神态动作"),
    ("背脊发凉", "神态动作"),
    ("面无表情", "神态动作"),
    ("不动声色", "神态动作"),
    ("负手而立", "神态动作"),
    ("背负双手", "神态动作"),
    ("双手插兜", "神态动作"),
    ("盘膝而坐", "神态动作"),
    ("端起茶杯", "神态动作"),
    ("喝了口茶", "神态动作"),
    ("抽了口烟", "神态动作"),
    ("若无其事", "神态动作"),
    ("波澜不惊", "神态动作"),
    ("古井无波", "神态动作"),
    // 说话腔调
    ("淡淡的道", "说话腔调"),
    ("淡淡道", "说话腔调"),
    ("沉声道", "说话腔调"),
    ("冷声道", "说话腔调"),
    ("轻声道", "说话腔调"),
    ("苦笑道", "说话腔调"),
    ("轻笑道", "说话腔调"),
    ("冷笑道", "说话腔调"),
    ("摇头道", "说话腔调"),
    ("缓缓说道", "说话腔调"),
    ("平静说道", "说话腔调"),
    ("笑着说道", "说话腔调"),
    ("开口道", "说话腔调"),
    ("似笑非笑", "说话腔调"),
    ("意味深长", "说话腔调"),
    ("若有所思", "说话腔调"),
    ("一本正经", "说话腔调"),
    ("漫不经心", "说话腔调"),
    ("毫不在意", "说话腔调"),
    ("不以为意", "说话腔调"),
    ("斩钉截铁", "说话腔调"),
    ("阴阳怪气", "说话腔调"),
    // 转折推进
    ("与此同时", "转折推进"),
    ("就在这时", "转折推进"),
    ("话音未落", "转折推进"),
    ("念及此处", "转折推进"),
    ("下一刻", "转折推进"),
    ("刹那间", "转折推进"),
    ("突然间", "转折推进"),
    ("紧接着", "转折推进"),
    ("紧随其后", "转折推进"),
    ("片刻之后", "转折推进"),
    ("一时间", "转折推进"),
    ("不知不觉", "转折推进"),
    ("自然而然", "转折推进"),
    ("下意识", "转折推进"),
    ("不由得", "转折推进"),
    ("忍不住", "转折推进"),
    ("不自觉", "转折推进"),
    ("潜意识", "转折推进"),
    ("半晌", "转折推进"),
    ("良久", "转折推进"),
    ("旋即", "转折推进"),
    ("随即", "转折推进"),
    ("顿时", "转折推进"),
    ("连忙", "转折推进"),
    ("急忙", "转折推进"),
    ("不禁", "转折推进"),
    ("仿佛", "转折推进"),
    ("宛如", "转折推进"),
    ("竟然", "转折推进"),
    ("居然", "转折推进"),
    ("果然", "转折推进"),
    ("毕竟", "转折推进"),
    ("终究", "转折推进"),
    // 夸张惊叹
    ("恐怖如斯", "夸张惊叹"),
    ("不敢置信", "夸张惊叹"),
    ("不可思议", "夸张惊叹"),
    ("难以置信", "夸张惊叹"),
    ("骇人听闻", "夸张惊叹"),
    ("毛骨悚然", "夸张惊叹"),
    ("匪夷所思", "夸张惊叹"),
    ("瞠目结舌", "夸张惊叹"),
    ("目瞪口呆", "夸张惊叹"),
    ("鸦雀无声", "夸张惊叹"),
    ("鸡皮疙瘩", "夸张惊叹"),
    ("骇然", "夸张惊叹"),
    ("愕然", "夸张惊叹"),
    ("悚然", "夸张惊叹"),
    // 口头禅
    ("说实话", "口头禅"),
    ("老实说", "口头禅"),
    ("事实上", "口头禅"),
    ("老实讲", "口头禅"),
    ("讲道理", "口头禅"),
    ("说白了", "口头禅"),
    ("换句话说", "口头禅"),
    ("某种意义上", "口头禅"),
    ("某种程度上", "口头禅"),
    ("毫无疑问", "口头禅"),
    ("毋庸置疑", "口头禅"),
    ("总而言之", "口头禅"),
    ("不管怎么说", "口头禅"),
    ("无论如何", "口头禅"),
    ("开什么玩笑", "口头禅"),
    ("这怎么可能", "口头禅"),
    ("怎么可能", "口头禅"),
    ("有意思", "口头禅"),
    ("果然如此", "口头禅"),
    ("果不其然", "口头禅"),
    ("不出所料", "口头禅"),
    ("原来如此", "口头禅"),
    ("莫名其妙", "口头禅"),
    ("理所当然", "口头禅"),
    ("习以为常", "口头禅"),
    ("一如既往", "口头禅"),
    ("显而易见", "口头禅"),
    ("顺理成章", "口头禅"),
    ("不知为何", "口头禅"),
    ("没有任何", "口头禅"),
    ("没有什么", "口头禅"),
];

struct LexIndex {
    by_first: HashMap<char, Vec<(usize, &'static str)>>,
}

fn lex_index() -> &'static LexIndex {
    static IDX: OnceLock<LexIndex> = OnceLock::new();
    IDX.get_or_init(|| {
        let mut by_first: HashMap<char, Vec<(usize, &'static str)>> = HashMap::new();
        for (id, &(phrase, _)) in LEXICON.iter().enumerate() {
            let first = phrase.chars().next().unwrap();
            by_first.entry(first).or_default().push((id, phrase));
        }
        for list in by_first.values_mut() {
            list.sort_by(|a, b| b.1.len().cmp(&a.1.len()));
        }
        LexIndex { by_first }
    })
}

#[inline]
fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c)
}

#[inline]
fn is_sentence_end(c: char) -> bool {
    matches!(c, '。' | '！' | '？' | '!' | '?' | '；' | ';')
}

/// Extract a clean ~48-char sentence snippet around `byte_pos` inside `body`.
fn extract_sample(body: &str, byte_pos: usize, phrase_len: usize) -> String {
    let before = &body[..byte_pos];
    let after = &body[byte_pos + phrase_len..];

    let mut start = byte_pos;
    let mut back_chars = 0usize;
    for (idx, ch) in before.char_indices().rev() {
        if matches!(ch, '\n' | '\r' | '。' | '！' | '？' | '!' | '?') {
            break;
        }
        start = idx;
        back_chars += 1;
        if back_chars >= 22 {
            break;
        }
    }

    let mut end = byte_pos + phrase_len;
    let mut fwd_chars = 0usize;
    for (rel, ch) in after.char_indices() {
        if matches!(ch, '\n' | '\r') {
            break;
        }
        end = byte_pos + phrase_len + rel + ch.len_utf8();
        fwd_chars += 1;
        if is_sentence_end(ch) || fwd_chars >= 28 {
            break;
        }
    }

    let raw = body[start..end].trim();
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

struct LexAcc {
    total: usize,
    chapter_hits: usize,
    peak_chapter: usize,
    peak_count: usize,
    sample: String,
    sample_chapter: usize,
    buckets: [u32; BUCKETS],
}

impl LexAcc {
    fn new() -> Self {
        Self {
            total: 0,
            chapter_hits: 0,
            peak_chapter: 0,
            peak_count: 0,
            sample: String::new(),
            sample_chapter: 0,
            buckets: [0; BUCKETS],
        }
    }
}

/// Analyze author writing habits and signature tics across the whole book in a
/// single pass.
pub fn analyze(text: &str, chapters: &[Chapter]) -> AuthorTics {
    let n_ch = chapters.len();
    let idx = lex_index();
    let mut lex_acc: Vec<LexAcc> = (0..LEXICON.len()).map(|_| LexAcc::new()).collect();
    let mut ch_counts: Vec<u32> = vec![0; LEXICON.len()];
    let mut touched: Vec<usize> = Vec::with_capacity(32);

    let mut total_cjk = 0usize;
    let mut dialogue_cjk = 0usize;
    let mut sentence_count = 0usize;
    let mut exclam_count = 0usize;
    let mut ellipsis_count = 0usize;
    let mut question_count = 0usize;

    for (ci, ch) in chapters.iter().enumerate() {
        let body = text[ch.body_start.min(ch.span.end)..ch.span.end].trim();
        if body.is_empty() {
            continue;
        }
        let bucket = if n_ch == 0 {
            0
        } else {
            (ci * BUCKETS / n_ch).min(BUCKETS - 1)
        };

        let mut in_quote = false;
        let mut cur_sent_cjk = 0usize;
        let mut prev_dot = 0u8;
        let mut prev_ellip = false;
        let mut skip_until = 0usize;
        touched.clear();

        // Single linear pass for both style metrics and lexicon matching.
        for (pos, c) in body.char_indices() {
            match c {
                '“' | '「' | '『' => in_quote = true,
                '”' | '」' | '』' => in_quote = false,
                '"' => in_quote = !in_quote,
                '！' | '!' => {
                    exclam_count += 1;
                    if cur_sent_cjk >= 2 {
                        sentence_count += 1;
                        cur_sent_cjk = 0;
                    }
                }
                '？' | '?' => {
                    question_count += 1;
                    if cur_sent_cjk >= 2 {
                        sentence_count += 1;
                        cur_sent_cjk = 0;
                    }
                }
                '。' | '；' | ';' => {
                    if cur_sent_cjk >= 2 {
                        sentence_count += 1;
                        cur_sent_cjk = 0;
                    }
                }
                '…' => {
                    if !prev_ellip {
                        ellipsis_count += 1;
                    }
                }
                '.' => {
                    prev_dot = prev_dot.saturating_add(1);
                    if prev_dot == 3 {
                        ellipsis_count += 1;
                    }
                }
                '\n' => {
                    in_quote = false;
                    if cur_sent_cjk >= 2 {
                        sentence_count += 1;
                        cur_sent_cjk = 0;
                    }
                }
                _ => {
                    if is_cjk(c) {
                        total_cjk += 1;
                        cur_sent_cjk += 1;
                        if in_quote {
                            dialogue_cjk += 1;
                        }
                        if pos >= skip_until {
                            if let Some(cands) = idx.by_first.get(&c) {
                                let tail = &body[pos..];
                                for &(id, phrase) in cands {
                                    if tail.starts_with(phrase) {
                                        if ch_counts[id] == 0 {
                                            touched.push(id);
                                        }
                                        ch_counts[id] += 1;
                                        if lex_acc[id].sample.is_empty() {
                                            lex_acc[id].sample =
                                                extract_sample(body, pos, phrase.len());
                                            lex_acc[id].sample_chapter = ci;
                                        }
                                        skip_until = pos + phrase.len();
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if c != '.' {
                prev_dot = 0;
            }
            prev_ellip = c == '…';
        }
        if cur_sent_cjk >= 2 {
            sentence_count += 1;
        }
        for &id in &touched {
            let cnt = ch_counts[id] as usize;
            ch_counts[id] = 0;
            let acc = &mut lex_acc[id];
            acc.total += cnt;
            acc.chapter_hits += 1;
            acc.buckets[bucket] += cnt as u32;
            if cnt > acc.peak_count {
                acc.peak_count = cnt;
                acc.peak_chapter = ci;
            }
        }
    }

    let denom_10k = (total_cjk as f64 / 10_000.0).max(0.01);
    let dialogue_ratio = if total_cjk > 0 {
        (dialogue_cjk as f64 / total_cjk as f64).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let avg_sentence_len = if sentence_count > 0 {
        total_cjk as f64 / sentence_count as f64
    } else {
        0.0
    };
    let exclam_per_10k = exclam_count as f64 / denom_10k;
    let ellipsis_per_10k = ellipsis_count as f64 / denom_10k;
    let question_per_10k = question_count as f64 / denom_10k;

    let min_hits = if total_cjk > 100_000 { 5 } else { 2 };
    let mut items: Vec<TicItem> = Vec::new();
    for (id, acc) in lex_acc.into_iter().enumerate() {
        if acc.total < min_hits {
            continue;
        }
        let (phrase, cat) = LEXICON[id];
        items.push(TicItem {
            phrase: phrase.to_string(),
            category: cat.to_string(),
            count: acc.total,
            per_10k: acc.total as f64 / denom_10k,
            chapter_hits: acc.chapter_hits,
            peak_chapter: acc.peak_chapter,
            peak_count: acc.peak_count,
            sample: acc.sample,
            sample_chapter: acc.sample_chapter,
            buckets: acc.buckets.to_vec(),
        });
    }

    items.sort_by(|a, b| b.count.cmp(&a.count));
    items.truncate(36);

    let style_tags = build_style_tags(
        dialogue_ratio,
        avg_sentence_len,
        exclam_per_10k,
        ellipsis_per_10k,
        &items,
    );

    AuthorTics {
        total_chars: total_cjk,
        chapter_count: n_ch,
        dialogue_ratio,
        avg_sentence_len,
        exclam_per_10k,
        ellipsis_per_10k,
        question_per_10k,
        style_tags,
        items,
    }
}

fn build_style_tags(
    dialogue_ratio: f64,
    avg_sentence_len: f64,
    exclam_per_10k: f64,
    ellipsis_per_10k: f64,
    items: &[TicItem],
) -> Vec<String> {
    let mut tags = Vec::new();
    if dialogue_ratio >= 0.42 {
        tags.push("对话密集".to_string());
    } else if dialogue_ratio <= 0.18 {
        tags.push("叙述流".to_string());
    } else {
        tags.push("叙议均衡".to_string());
    }

    if avg_sentence_len > 0.0 {
        if avg_sentence_len <= 17.5 {
            tags.push("短句疾风".to_string());
        } else if avg_sentence_len >= 27.0 {
            tags.push("长句绵密".to_string());
        }
    }

    if exclam_per_10k >= 85.0 {
        tags.push("叹号狂魔".to_string());
    } else if ellipsis_per_10k >= 25.0 {
        tags.push("省略号爱好者".to_string());
    }

    let mut cat_sum: HashMap<&str, usize> = HashMap::new();
    for it in items.iter().take(12) {
        *cat_sum.entry(it.category.as_str()).or_insert(0) += it.count;
    }
    if let Some((&top_cat, &cnt)) = cat_sum.iter().max_by_key(|(_, &v)| v) {
        if cnt >= 20 {
            match top_cat {
                "神态动作" => tags.push("微表情控".to_string()),
                "说话腔调" => tags.push("腔调派".to_string()),
                "夸张惊叹" => tags.push("震惊体".to_string()),
                "口头禅" => tags.push("碎碎念".to_string()),
                _ => {}
            }
        }
    }
    tags.truncate(4);
    tags
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
    fn detects_signature_tics_and_style_metrics() {
        let ch_body = "“这怎么可能！”他不由得微微一笑，倒吸一口凉气，淡淡道：“说实话，简直恐怖如斯……”\n"
            .repeat(12);
        let mut text = String::new();
        let mut chapters = Vec::new();
        for i in 0..10 {
            let start = text.len();
            text.push_str(&ch_body);
            let end = text.len();
            chapters.push(mk_chapter(i, start, end));
        }

        let res = analyze(&text, &chapters);
        assert!(res.total_chars > 1000);
        assert!(res.dialogue_ratio > 0.35, "dialogue_ratio={}", res.dialogue_ratio);
        assert!(res.exclam_per_10k > 50.0);
        assert!(res.ellipsis_per_10k > 50.0);
        assert!(res.items.iter().any(|it| it.phrase == "倒吸一口凉气" && it.count == 120));
        assert!(res.items.iter().any(|it| it.phrase == "微微一笑" && it.count == 120));
        assert!(res.items.iter().any(|it| it.phrase == "淡淡道" && it.count == 120));
        assert!(!res.items[0].sample.is_empty());
        assert_eq!(res.items[0].buckets.len(), BUCKETS);
    }
}
