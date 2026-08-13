//! Turns decoded text into the structure the reader renders from.
//!
//! Every position here is a byte offset into the *decoded* text, never a line
//! or paragraph index. Decoding is deterministic and is the one stage we do not
//! expect to change; paragraph segmentation is not and will. Anchoring reading
//! progress to paragraph indices would silently shift every bookmark in the
//! library the day we improve segmentation.

use crate::chapters::{self, Candidate};
use crate::fingerprint::{Fingerprint, ParagraphStyle};
use crate::is_indented;

/// What a non-blank line is. The distinction that matters to the reader is
/// `Interstitial`: an author's note ("请假一天", "万订啦！谢谢大家！") sits flush
/// against the margin exactly like a chapter title does, so a naive title matcher
/// puts it in the table of contents. It is not a chapter — but it is also not
/// noise to be deleted. Readers followed these books for years; the notes are
/// part of what they read. So: shown in the body, absent from the table of
/// contents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    Body,
    ChapterTitle,
    Interstitial,
}

#[derive(Debug, Clone)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone)]
pub struct Chapter {
    /// Position in the table of contents, always dense and climbing from 0,
    /// regardless of what the author numbered the chapter.
    pub index: usize,
    /// The number the author wrote, when there was one. Not a key: real books
    /// repeat and skip these.
    pub number: Option<u64>,
    pub title: String,
    /// Title line plus body, up to the next chapter title.
    pub span: Span,
    /// Where the body starts, i.e. just past the title line.
    pub body_start: usize,
}

#[derive(Debug, Clone)]
pub struct Interstitial {
    pub span: Span,
    pub text: String,
}

/// A volume divides the table of contents. It is not an entry in it, and it has
/// no text of its own — only a title and the chapter it opens.
#[derive(Debug, Clone)]
pub struct Volume {
    pub title: String,
    pub span: Span,
    /// Index of the first chapter under this volume.
    pub first_chapter: usize,
}

#[derive(Debug)]
pub struct Book {
    pub chapters: Vec<Chapter>,
    pub volumes: Vec<Volume>,
    /// Author notes, ads, front matter. Rendered inline, never in the TOC.
    pub interstitials: Vec<Interstitial>,
    pub anomalies: Vec<String>,
}

struct Line<'a> {
    start: usize,
    end: usize,
    text: &'a str,
}

fn lines(text: &str) -> Vec<Line<'_>> {
    let mut out = Vec::new();
    let mut start = 0;
    for l in text.split('\n') {
        let end = start + l.len();
        out.push(Line {
            start,
            end,
            text: l,
        });
        start = end + 1; // skip the '\n'
    }
    out
}

/// A chapter that exists only to hold the text before the first real title:
/// cover blurb, source-site banner, author foreword. Losing it would lose text.
const FRONT_MATTER: &str = "开篇";

/// Target size of one virtual chapter, in bytes of decoded UTF-8 (~8k Chinese
/// characters — a normal web-novel chapter).
const VIRTUAL_SPAN: usize = 24 * 1024;

/// No chapter markers at all. Renderers assume a chapter fits in memory and in
/// a layout pass; one 15 MB "chapter" breaks both. Slice the book into parts by
/// length, cutting at paragraph ends so no part opens mid-sentence.
fn virtual_book(text: &str, ls: &[Line]) -> Book {
    fn part(i: usize, start: usize, end: usize) -> Chapter {
        Chapter {
            index: i,
            number: None,
            title: format!("第 {} 部分", i + 1),
            span: Span { start, end },
            body_start: start,
        }
    }

    let mut chapters: Vec<Chapter> = Vec::new();
    let mut start = 0usize;
    for l in ls {
        let len = l.end - start;
        if len < VIRTUAL_SPAN {
            continue;
        }
        let clean = l.text.trim().is_empty()
            || l.text
                .trim_end()
                .chars()
                .last()
                .is_some_and(|c| crate::repair::STRONG_END.contains(&c));
        // Hold out for a clean break, but not forever: a wall of text with no
        // punctuation still has to be cut somewhere.
        if clean || len >= VIRTUAL_SPAN * 3 / 2 {
            let end = (l.end + 1).min(text.len());
            chapters.push(part(chapters.len(), start, end));
            start = end;
        }
    }
    if start < text.len() {
        chapters.push(part(chapters.len(), start, text.len()));
    }

    Book {
        chapters,
        volumes: Vec::new(),
        interstitials: Vec::new(),
        anomalies: vec!["未识别到章节标记，已按篇幅虚拟分章".to_string()],
    }
}

pub fn build(text: &str, fp: &Fingerprint) -> Book {
    let cands = chapters::candidates(text, fp);
    let v = chapters::validate(&cands, fp);
    let ls = lines(text);

    if v.chapters.is_empty() && text.len() > VIRTUAL_SPAN * 2 {
        return virtual_book(text, &ls);
    }

    let title_at: std::collections::HashMap<usize, &Candidate> =
        v.chapters.iter().map(|c| (c.line_idx, c)).collect();

    // Boundaries first: a chapter runs from its title line to the next one.
    let mut starts: Vec<(usize, Option<&Candidate>)> = v
        .chapters
        .iter()
        .map(|c| (ls[c.line_idx].start, Some(c)))
        .collect();
    if starts.first().map_or(true, |(s, _)| *s > 0) {
        starts.insert(0, (0, None));
    }

    let mut chapters = Vec::with_capacity(starts.len());
    for (i, (start, cand)) in starts.iter().enumerate() {
        let end = starts.get(i + 1).map_or(text.len(), |(s, _)| *s);
        let (title, number, body_start) = match cand {
            Some(c) => (c.text.clone(), c.number, ls[c.line_idx].end.min(end)),
            None => (FRONT_MATTER.to_string(), None, *start),
        };
        chapters.push(Chapter {
            index: i,
            number,
            title,
            span: Span { start: *start, end },
            body_start,
        });
    }

    // A volume header opens the first chapter that starts after it.
    let volumes: Vec<Volume> = v
        .volumes
        .iter()
        .map(|vol| {
            let l = &ls[vol.line_idx];
            Volume {
                title: vol.text.clone(),
                span: Span {
                    start: l.start,
                    end: l.end,
                },
                first_chapter: chapters
                    .iter()
                    .position(|c| c.span.start >= l.end)
                    .unwrap_or(chapters.len().saturating_sub(1)),
            }
        })
        .collect();
    let volume_at: std::collections::HashSet<usize> =
        v.volumes.iter().map(|c| c.line_idx).collect();

    // Interstitials are only identifiable where the indent signal exists: in an
    // indent-styled book a flush line is provably not body text, so a flush line
    // that is not a title is an author's note or an ad. Without that signal we
    // cannot tell a note from a paragraph, and guessing would corrupt the body.
    let interstitials = if fp.style == ParagraphStyle::Indent {
        ls.iter()
            .enumerate()
            .filter(|(i, l)| {
                !l.text.trim().is_empty()
                    && !is_indented(l.text)
                    && !title_at.contains_key(i)
                    && !volume_at.contains(i)
            })
            .map(|(_, l)| Interstitial {
                span: Span {
                    start: l.start,
                    end: l.end,
                },
                text: l.text.trim().to_string(),
            })
            .collect()
    } else {
        Vec::new()
    };

    Book {
        chapters,
        volumes,
        interstitials,
        anomalies: v.anomalies,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fingerprint::fingerprint;

    /// A big book with no chapter markers must come back sliced into parts that
    /// tile the whole text, not as one unrenderable chapter.
    #[test]
    fn markerless_book_gets_virtual_chapters() {
        let para = "他走在长街上，雨落了下来，人群散去，灯一盏一盏地熄灭了。\n";
        let text = para.repeat(2000); // ~170 KB
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);

        assert!(
            b.chapters.len() > 3,
            "expected multiple parts, got {}",
            b.chapters.len()
        );
        assert_eq!(b.chapters[0].title, "第 1 部分");
        let mut cursor = 0;
        for c in &b.chapters {
            assert_eq!(c.span.start, cursor, "parts must tile the text");
            cursor = c.span.end;
        }
        assert_eq!(cursor, text.len());
        assert!(!b.anomalies.is_empty());
    }

    /// A small file with no markers stays a single 开篇 chapter — slicing a
    /// short story into "parts" would be noise.
    #[test]
    fn small_markerless_file_stays_whole() {
        let text = "一个很短的故事。\n就这样结束了。\n";
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);
        assert_eq!(b.chapters.len(), 1);
        assert_eq!(b.chapters[0].title, FRONT_MATTER);
    }

    /// A book with real titles must never fall into the virtual path.
    #[test]
    fn real_titles_win_over_virtual_slicing() {
        let mut text = String::new();
        for i in 1..=30 {
            text.push_str(&format!("第{i}章 标题\n"));
            text.push_str(&"　　正文段落，写了一些字。\n".repeat(100));
        }
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);
        assert_eq!(b.chapters.len(), 30);
        assert!(b.chapters.iter().all(|c| !c.title.contains("部分")));
    }
}

/// Classify one line for rendering. `Interstitial` only where the indent signal
/// is trustworthy, i.e. where a flush line provably is not body text.
pub fn line_kind(line: &str, is_title: bool, style: ParagraphStyle) -> LineKind {
    if is_title {
        LineKind::ChapterTitle
    } else if style == ParagraphStyle::Indent && !is_indented(line) && !line.trim().is_empty() {
        LineKind::Interstitial
    } else {
        LineKind::Body
    }
}
