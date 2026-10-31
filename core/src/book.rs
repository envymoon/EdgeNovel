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

/// Whether a part `len` bytes long may end at this line. It holds out for a clean
/// break, but not forever: a wall of text with no punctuation still has to be cut
/// somewhere.
fn clean_break(l: &Line, len: usize) -> bool {
    if len < VIRTUAL_SPAN {
        return false;
    }
    let clean = l.text.trim().is_empty()
        || l.text
            .trim_end()
            .chars()
            .last()
            .is_some_and(|c| crate::repair::STRONG_END.contains(&c));
    clean || len >= VIRTUAL_SPAN * 3 / 2
}

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
        if clean_break(l, l.end - start) {
            let end = (l.end + 1).min(text.len());
            chapters.push(part(chapters.len(), start, end));
            start = end;
        }
    }
    if start < text.len() {
        match chapters.last_mut() {
            Some(last) if text[start..].trim().len() < EMPTY_BODY => last.span.end = text.len(),
            _ => chapters.push(part(chapters.len(), start, text.len())),
        }
    }

    Book {
        chapters,
        volumes: Vec::new(),
        interstitials: Vec::new(),
        anomalies: vec!["未识别到章节标记，已按篇幅虚拟分章".to_string()],
    }
}

/// Under this many bytes below its title, a title has nothing to open: a printed
/// table of contents, a heading whose text the source lost, 第二节课，睡觉。 in the
/// prose. The line stays where it is, at the end of the chapter before it.
const EMPTY_BODY: usize = 120;

/// This many empty titles in a row before a title may be a printed contents.
const CONTENTS_RUN: usize = 3;

/// Under this, what follows a printed contents is an epigraph, no chapter of its own.
const EPIGRAPH: usize = 4 * 1024;

/// What a book may really open with, once a printed contents has hidden its title.
const OPENINGS: &[&str] = &["序幕", "序章", "序言", "前言", "楔子", "引子"];

/// A contents that lists sections under each chapter: 第四章 寻羊冒险记Ⅰ, then
/// 1. 奇妙来客·序, 2. 奇妙来客. Nothing but numbered short lines is no chapter's text.
fn only_a_list(body: &str) -> bool {
    let mut count = 0;
    for l in body.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let numbered = l.starts_with('第') || l.starts_with(|c: char| c.is_ascii_digit() || ('０'..='９').contains(&c));
        if !numbered || l.chars().count() > 60 {
            return false;
        }
        count += 1;
    }
    count >= 3
}

/// 九州缥缈录 ends each volume on a link back to the chapter it just finished:
/// 第五章 斩狼(四)>>. 夏至未至's 第十章 …短松冈>> is a chapter, and follows 第九章.
fn is_link_to(before: &str, title: &str) -> bool {
    title.strip_suffix(">>") == Some(before)
}

fn without_empty_chapters(text: &str, ls: &[Line], chapters: &mut Vec<Candidate>) {
    let start = |c: &Candidate| ls[c.line_idx].start + c.in_line;
    let empty: Vec<bool> = chapters
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let end = chapters.get(i + 1).map_or(text.len(), |n| start(n));
            let body = ls[c.line_idx].end.min(end);
            let link = i > 0 && is_link_to(&chapters[i - 1].text, &c.text);
            text[body..end].trim().len() < EMPTY_BODY || link || only_a_list(&text[body..end])
        })
        .collect();
    // Mostly this short is how the book is written: a collection of poems.
    if empty.iter().filter(|e| **e).count() * 2 > chapters.len() {
        return;
    }
    let mut kept = Vec::with_capacity(chapters.len());
    for (i, c) in chapters.iter().enumerate() {
        if empty[i] {
            continue;
        }
        let run = empty[..i].iter().rev().take_while(|e| **e).count();
        let next = (i + 1..chapters.len()).find(|&n| !empty[n]).map(|n| &chapters[n]);
        let contents_end = run >= CONTENTS_RUN
            && next.is_some_and(|n| !matches!((c.number, n.number), (Some(a), Some(b)) if b > a));
        let Some(next) = next.filter(|_| contents_end) else {
            kept.push(c.clone());
            continue;
        };
        // The last line of a printed contents: all it holds is what the book prints
        // before its first title. 冬日重现's 375, after four empty chapters, goes on to
        // 376 and stays. 龙族's 第十九幕 is followed by 第一幕.
        let (from, to) = (ls[c.line_idx].end, start(next));
        let opening = ls[c.line_idx + 1..]
            .iter()
            .enumerate()
            .take_while(|(_, l)| l.start < to && l.start < from + EPIGRAPH)
            .find(|(_, l)| {
                let name: String = l.text.split_whitespace().collect();
                OPENINGS.contains(&name.as_str())
            });
        if let Some((at, l)) = opening {
            let name: String = l.text.split_whitespace().collect();
            kept.push(Candidate { line_idx: c.line_idx + 1 + at, text: name, number: None, in_line: 0, ..c.clone() });
        } else if to - from >= EPIGRAPH {
            kept.push(Candidate { text: FRONT_MATTER.to_string(), number: None, ..c.clone() });
        }
    }
    *chapters = kept;
}

pub fn build(text: &str, fp: &Fingerprint) -> Book {
    let cands = chapters::candidates(text, fp);
    let mut v = chapters::validate(&cands, fp);
    let ls = lines(text);
    chapters::fill_lumps(text, &mut v.chapters);
    without_empty_chapters(text, &ls, &mut v.chapters);

    if v.chapters.is_empty() && text.len() > VIRTUAL_SPAN * 2 {
        return virtual_book(text, &ls);
    }

    let title_at: std::collections::HashMap<usize, &Candidate> =
        v.chapters.iter().map(|c| (c.line_idx, c)).collect();

    // Boundaries first: a chapter runs from its title line to the next one.
    let mut starts: Vec<(usize, Option<&Candidate>)> = v
        .chapters
        .iter()
        .map(|c| (ls[c.line_idx].start + c.in_line, Some(c)))
        .collect();
    match starts.first_mut() {
        Some((s, _)) if *s == 0 => {}
        // A line or two before the first title is no chapter of its own.
        Some((s, _)) if text[..*s].trim().len() < EMPTY_BODY => *s = 0,
        _ => starts.insert(0, (0, None)),
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
                    .position(|c| c.body_start >= l.end)
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

    /// A title glued to the sentence before it opens its chapter at the title; the
    /// sentence stays at the end of the chapter it finishes, and nothing is lost.
    #[test]
    fn a_glued_title_leaves_the_sentence_behind() {
        let mut text = String::from("第一章 开始\n");
        for i in 2..=60 {
            text.push_str(&format!("他走了。第{i}章 标题\n正文。\n"));
        }
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);
        assert_eq!(b.chapters.len(), 60);
        let c = &b.chapters[1];
        assert_eq!(c.title, "第2章 标题");
        assert!(text[c.span.start..c.body_start].starts_with("第2章"));
        assert!(text[b.chapters[0].span.start..b.chapters[0].span.end].ends_with("他走了。"));
        let mut cursor = 0;
        for c in &b.chapters {
            assert_eq!(c.span.start, cursor, "chapters must tile the text");
            cursor = c.span.end;
        }
        assert_eq!(cursor, text.len());
    }

    /// A printed table of contents opens nothing. Its lines stay in the text, and
    /// the chapters they name open where the text does.
    #[test]
    fn a_table_of_contents_is_not_chapters() {
        let mut text = String::from("前言\n");
        for i in 1..=8 {
            text.push_str(&format!("第{i}章 标题{i}\n"));
        }
        for i in 1..=8 {
            text.push_str(&format!("第{i}章 标题{i}\n"));
            text.push_str(&"正文段落，写了一些字。\n".repeat(30));
        }
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);
        assert_eq!(b.chapters.len(), 9);
        assert_eq!(b.chapters[0].title, FRONT_MATTER);
        assert!(text[b.chapters[0].span.start..b.chapters[0].span.end].contains("第8章 标题8"));
        let mut cursor = 0;
        for c in &b.chapters {
            assert_eq!(c.span.start, cursor, "chapters must tile the text");
            assert!(c.span.end - c.body_start >= 120, "{}", c.title);
            cursor = c.span.end;
        }
        assert_eq!(cursor, text.len());
    }

    /// A volume header and a line of blurb are no 开篇. The first chapter takes them,
    /// and is still the one the volume opens.
    #[test]
    fn a_line_before_the_first_title_is_not_a_chapter() {
        let mut text = String::from("第一卷 风起\n\n");
        for i in 1..=8 {
            text.push_str(&format!("第{i}章 标题\n"));
            text.push_str(&"正文段落，写了一些字。\n".repeat(30));
        }
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);
        assert_eq!(b.chapters.len(), 8);
        assert_eq!(b.chapters[0].span.start, 0);
        assert_eq!(b.chapters[0].title, "第1章 标题");
        assert_eq!(b.volumes[0].first_chapter, 0);
    }

    fn book_with_contents(between: &str) -> String {
        let mut text = String::from("第一章 上一本\n");
        text.push_str(&"上一本的正文，写了一些字。\n".repeat(100));
        for i in 2..=6 {
            text.push_str(&format!("第{i}章 上一本\n"));
            text.push_str(&"上一本的正文，写了一些字。\n".repeat(100));
        }
        for i in 1..=6 {
            text.push_str(&format!("第{i}章 下一本\n"));
        }
        text.push_str(between);
        for i in 1..=6 {
            text.push_str(&format!("第{i}章 下一本\n"));
            text.push_str(&"下一本的正文，写了一些字。\n".repeat(100));
        }
        text
    }

    /// The last line of a printed contents names no chapter, whatever follows it.
    #[test]
    fn the_last_line_of_a_contents_is_no_title() {
        let tiles = |b: &Book, text: &str| {
            let mut cursor = 0;
            for (i, c) in b.chapters.iter().enumerate() {
                assert_eq!(c.index, i);
                assert_eq!(c.span.start, cursor, "chapters must tile the text");
                cursor = c.span.end;
            }
            assert_eq!(cursor, text.len());
        };

        // A real opening under it: named for what it is.
        let mut between = "每个人年少的时候，心中都有一个孤独的少年。\n".repeat(10);
        between.push_str("序 幕\n");
        between.push_str(&"序幕的正文，写了一些字。\n".repeat(400));
        let text = book_with_contents(&between);
        let b = build(&text, &fingerprint("UTF-8", &text));
        let names: Vec<&str> = b.chapters.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(names.iter().filter(|t| **t == "第6章 下一本").count(), 1, "{names:?}");
        assert_eq!(names[6], "序幕", "{names:?}");
        assert!(text[b.chapters[6].body_start..].starts_with("\n序幕的正文") || text[b.chapters[6].body_start..].starts_with("序幕的正文"));
        tiles(&b, &text);

        // A long preface with no name of its own.
        let between = "译者的话，写了一些字。\n".repeat(400);
        let text = book_with_contents(&between);
        let b = build(&text, &fingerprint("UTF-8", &text));
        let names: Vec<&str> = b.chapters.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(names[6], "开篇", "{names:?}");
        assert_eq!(names[7], "第1章 下一本", "{names:?}");
        tiles(&b, &text);

        // An epigraph: not worth a chapter.
        let between = "命运这种东西，生来就是要被踏于足下的。\n".repeat(10);
        let text = book_with_contents(&between);
        let b = build(&text, &fingerprint("UTF-8", &text));
        let names: Vec<&str> = b.chapters.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(names.len(), 12, "{names:?}");
        assert_eq!(names[6], "第1章 下一本", "{names:?}");
        tiles(&b, &text);
    }

    /// A contents with sections under each line, and a link at the end of a volume.
    #[test]
    fn section_lists_and_links_are_no_chapters() {
        assert!(only_a_list("1. 奇妙来客·序\n2. 奇妙来客\n\n3. “先生”\n"));
        assert!(!only_a_list("1. 奇妙来客\n2. 奇妙来客\n"));
        assert!(!only_a_list("1. 奇妙来客\n他走进房间，坐了下来。\n3. “先生”\n"));

        assert!(is_link_to("第五章 斩狼(四)", "第五章 斩狼(四)>>"));
        assert!(!is_link_to("第九章 旋涡", "第十章 短松冈>>"));
        assert!(!is_link_to("第五章 斩狼(四)", "第五章 斩狼(四)"));
    }

    /// Chapters the source lost are no contents: the numbering goes on after them.
    #[test]
    fn a_chapter_after_lost_chapters_keeps_its_title() {
        let mut text = String::new();
        for i in 1..=12 {
            text.push_str(&format!("第{i}章 标题\n"));
            if !(5..=8).contains(&i) {
                text.push_str(&"正文段落，写了一些字。\n".repeat(100));
            }
        }
        let b = build(&text, &fingerprint("UTF-8", &text));
        let names: Vec<&str> = b.chapters.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(names.len(), 8, "{names:?}");
        assert_eq!(names[4], "第9章 标题", "{names:?}");
    }

    /// Long, and no title to be found inside: that is the chapter the book has.
    #[test]
    fn a_long_chapter_stays_whole() {
        let mut text = String::from("第一章 开始\n");
        text.push_str(&"正文段落，写了一些字，又写了一些字。\n".repeat(8000));
        for i in 2..=8 {
            text.push_str(&format!("第{i}章 标题\n"));
            text.push_str(&"正文段落，写了一些字。\n".repeat(100));
        }
        let fp = fingerprint("UTF-8", &text);
        let b = build(&text, &fp);
        assert_eq!(b.chapters.len(), 8);
        assert_eq!(b.chapters[0].title, "第一章 开始");
        assert_eq!(b.chapters[1].title, "第2章 标题");
        let mut cursor = 0;
        for (i, c) in b.chapters.iter().enumerate() {
            assert_eq!(c.index, i);
            assert_eq!(c.span.start, cursor, "chapters must tile the text");
            cursor = c.span.end;
        }
        assert_eq!(cursor, text.len());
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
