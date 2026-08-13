use crate::is_indented;
use std::collections::HashMap;

/// How the book separates paragraphs. Every downstream repair decision branches
/// on this, so it is computed once for the whole book before any line is judged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParagraphStyle {
    /// Full-width double-space indent. One line = one paragraph.
    Indent,
    /// Blank lines between paragraphs.
    BlankLine,
    /// Neither: paragraphs must be reconstructed.
    Wall,
}

/// Characters that legitimately end a Chinese paragraph. Wider than "sentence
/// end": a colon introducing dialogue and a closing quote are both normal
/// paragraph terminators in web fiction, and treating them as breaks would
/// make a clean book look like it needs rewrapping.
const PARAGRAPH_END: &[char] = &[
    '。', '！', '？', '…', '”', '’', '』', '」', '）', '】', '：', '—', '.', '!', '?', ':',
];

#[derive(Debug)]
pub struct Fingerprint {
    pub encoding: &'static str,
    pub total_lines: usize,
    pub blank_lines: usize,
    pub nonblank_lines: usize,
    pub indented_lines: usize,
    pub flush_lines: usize,
    pub style: ParagraphStyle,
    /// Some(w) when line lengths spike at a fixed width, i.e. the text was
    /// hard-wrapped by a web layout and needs rejoining.
    pub hard_wrap_width: Option<usize>,
    pub median_len: usize,
    pub p90_len: usize,
    pub max_len: usize,
    pub paragraph_end_ratio: f64,
}

pub fn fingerprint(encoding: &'static str, text: &str) -> Fingerprint {
    let lines: Vec<&str> = text.split('\n').collect();
    let total_lines = lines.len();
    let nonblank: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|l| !l.trim().is_empty())
        .collect();
    let blank_lines = total_lines - nonblank.len();
    let nonblank_lines = nonblank.len().max(1);

    let indented_lines = nonblank.iter().filter(|l| is_indented(l)).count();
    let flush_lines = nonblank.len() - indented_lines;

    let indent_ratio = indented_lines as f64 / nonblank_lines as f64;
    let blank_ratio = blank_lines as f64 / total_lines.max(1) as f64;
    let style = if indent_ratio > 0.5 {
        ParagraphStyle::Indent
    } else if blank_ratio > 0.15 {
        ParagraphStyle::BlankLine
    } else {
        ParagraphStyle::Wall
    };

    let mut lens: Vec<usize> = nonblank
        .iter()
        .map(|l| l.trim_end().chars().count())
        .collect();
    let mut hist: HashMap<usize, usize> = HashMap::new();
    for &l in &lens {
        *hist.entry(l).or_default() += 1;
    }
    lens.sort_unstable();
    let pick = |q: f64| {
        lens.get((lens.len() as f64 * q) as usize)
            .copied()
            .unwrap_or(0)
    };

    // A hard-wrapped book piles lines at one width. An indent-styled book never
    // needs rewrapping, so we do not even look.
    let hard_wrap_width = if style == ParagraphStyle::Indent {
        None
    } else {
        hist.iter()
            .max_by_key(|(_, &c)| c)
            .filter(|(&w, &c)| w >= 20 && c as f64 / nonblank_lines as f64 > 0.05)
            .map(|(&w, _)| w)
    };

    let ends_ok = nonblank
        .iter()
        .filter(|l| {
            l.trim_end()
                .chars()
                .last()
                .is_some_and(|c| PARAGRAPH_END.contains(&c))
        })
        .count();

    Fingerprint {
        encoding,
        total_lines,
        blank_lines,
        nonblank_lines: nonblank.len(),
        indented_lines,
        flush_lines,
        style,
        hard_wrap_width,
        median_len: pick(0.5),
        p90_len: pick(0.9),
        max_len: lens.last().copied().unwrap_or(0),
        paragraph_end_ratio: ends_ok as f64 / nonblank_lines as f64,
    }
}
