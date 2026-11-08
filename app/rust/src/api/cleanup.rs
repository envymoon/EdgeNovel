//! 文本整理, for Dart. The rules are `novel_core::cleanup`; this runs them over
//! the book as it reads now, hands Dart what they found, and when the reader
//! says what to remove, moves the book onto the text that leaves.

use crate::api::book;
use novel_core::cleanup::{self, Finding};

/// A byte range of the book's text as it reads now.
#[derive(Debug, Clone)]
pub struct TextCut {
    pub start: i64,
    pub end: i64,
}

/// A run of a line as shown: the part that would go, or the story around it.
#[derive(Debug, Clone)]
pub struct CleanupPiece {
    pub text: String,
    pub removed: bool,
}

#[derive(Debug, Clone)]
pub struct CleanupItem {
    pub chapter: u32,
    pub chapter_title: String,
    pub whole: bool,
    pub cuts: Vec<TextCut>,
    pub pieces: Vec<CleanupPiece>,
}

#[derive(Debug, Clone)]
pub struct CleanupGroup {
    /// 网址, 网站提示, 反复出现…
    pub kind: String,
    /// The kind again, or for a repeated line the line.
    pub label: String,
    pub checked: bool,
    pub items: Vec<CleanupItem>,
}

#[derive(Debug, Clone)]
pub struct CleanupReport {
    /// Length of the text the cuts are about. A text of another length is
    /// another text, and its cuts are refused.
    pub total_bytes: i64,
    /// Something was taken out before, and the original can come back.
    pub restorable: bool,
    pub groups: Vec<CleanupGroup>,
}

pub fn find_cleanup(path: String) -> Result<CleanupReport, String> {
    book::ensure_loaded(&path)?;
    let (total_bytes, groups) = book::read_quietly(&path, |text, chapters| {
        let groups = cleanup::find(text, chapters)
            .into_iter()
            .map(|g| group(text, chapters, g))
            .collect();
        (text.len() as i64, groups)
    })?;
    Ok(CleanupReport {
        total_bytes,
        restorable: book::is_cut(&path)?,
        groups,
    })
}

/// Where the reader's own phrase appears: in the reader they marked it as an
/// advert, or typed it on the page.
pub fn find_cleanup_phrase(path: String, phrase: String) -> Result<CleanupGroup, String> {
    book::ensure_loaded(&path)?;
    book::read_quietly(&path, |text, chapters| {
        group(text, chapters, cleanup::find_phrase(text, chapters, &phrase))
    })
}

/// Take the ranges out. They are of the text as it reads now, which must still
/// be `total_bytes` long; earlier cuts stay.
pub fn apply_cleanup(
    path: String,
    book_id: i64,
    total_bytes: i64,
    cuts: Vec<TextCut>,
) -> Result<(), String> {
    book::ensure_loaded(&path)?;
    let ranges: Vec<std::ops::Range<usize>> = cuts
        .iter()
        .filter(|c| c.start < c.end && c.start >= 0)
        .map(|c| c.start as usize..c.end as usize)
        .collect();
    let fits = book::read_quietly(&path, |text, _| {
        text.len() as i64 == total_bytes && cleanup::Cuts::new(ranges.clone()).fits(text)
    })?;
    if !fits {
        return Err("书的内容变了，请重新查找".into());
    }
    book::recut_book(&path, book_id, |original, old| {
        if old.apply(original).len() as i64 != total_bytes {
            return Err("书的内容变了，请重新查找".into());
        }
        Ok(old.and(&ranges))
    })
}

/// Put back everything 文本整理 ever took out.
pub fn restore_original_text(path: String, book_id: i64) -> Result<(), String> {
    book::recut_book(&path, book_id, |_, _| Ok(cleanup::Cuts::default()))
}

fn group(text: &str, chapters: &[novel_core::book::Chapter], g: cleanup::Group) -> CleanupGroup {
    CleanupGroup {
        kind: g.kind.zh().to_string(),
        label: g.label,
        checked: g.checked,
        items: g
            .items
            .iter()
            .map(|f| CleanupItem {
                chapter: f.chapter as u32,
                chapter_title: chapters
                    .get(f.chapter)
                    .map(|c| c.title.clone())
                    .unwrap_or_default(),
                whole: f.whole,
                cuts: f
                    .cuts
                    .iter()
                    .map(|r| TextCut {
                        start: r.start as i64,
                        end: r.end as i64,
                    })
                    .collect(),
                pieces: pieces(text, f),
            })
            .collect(),
    }
}

/// The line as the page shows it: the whole of a short line, and around a cut
/// in a long one a few dozen characters of the story on either side.
fn pieces(text: &str, f: &Finding) -> Vec<CleanupPiece> {
    const AROUND: usize = 30;
    const LONGEST: usize = 200;
    let piece = |s: &str, removed: bool| CleanupPiece {
        text: s.to_string(),
        removed,
    };
    let line = f.line.clone();
    if f.whole {
        let t = text[line].trim();
        let shown: String = t.chars().take(LONGEST).collect();
        let more = if shown.len() < t.len() { "…" } else { "" };
        return vec![piece(&format!("{shown}{more}"), true)];
    }
    let (Some(first), Some(last)) = (f.cuts.first(), f.cuts.last()) else {
        return vec![piece(text[line].trim(), false)];
    };
    let from = text[..first.start]
        .char_indices()
        .rev()
        .nth(AROUND - 1)
        .map_or(0, |(i, _)| i)
        .max(line.start);
    let to = text[last.end..]
        .char_indices()
        .nth(AROUND)
        .map_or(text.len(), |(i, _)| last.end + i)
        .min(line.end);
    let mut out = Vec::new();
    if from > line.start {
        out.push(piece("…", false));
    }
    let mut at = from;
    for c in &f.cuts {
        let (start, end) = (c.start.max(at), c.end.min(to));
        if start >= end {
            continue;
        }
        if at < start {
            out.push(piece(&text[at..start], false));
        }
        out.push(piece(&text[start..end], true));
        at = end;
    }
    if at < to {
        out.push(piece(&text[at..to], false));
    }
    if to < line.end {
        out.push(piece("…", false));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole of 文本整理 in a library of its own: find, remove with the
    /// reader part way through the book, and back to the original. The file
    /// is never written.
    #[test]
    fn removing_and_restoring_keep_the_readers_place() {
        let data = std::env::temp_dir().join(format!("novel_cleanup_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&data);
        book::init_store(data.display().to_string()).unwrap();
        let mut text = String::new();
        for i in 1..=30 {
            text.push_str(&format!("第{i}章 风起\n"));
            text.push_str("　　他抬起头来，看着远处的山，山上的雪还没有化。\n");
            text.push_str("　　天才一秒记住本站地址：www.example.com\n");
            text.push_str(&format!("　　第{i}个夜晚，风从山口吹进来，吹灭了桌上的灯。\n"));
            text.push_str("　　他没有再点，就那样坐在黑暗里，听着外面的风声。\n");
            text.push_str("　　直到天快亮的时候，他才慢慢地睡着了。\n");
        }
        let path = data.join("书.txt");
        std::fs::write(&path, &text).unwrap();
        let path = path.display().to_string();
        let id = book::open_book(path.clone()).unwrap().id;
        let place = text.find("第20个夜晚").unwrap();
        book::save_progress(id, 19, place as i64).unwrap();

        let report = find_cleanup(path.clone()).unwrap();
        assert!(!report.restorable);
        let cuts: Vec<TextCut> = report
            .groups
            .iter()
            .filter(|g| g.checked)
            .flat_map(|g| g.items.iter().flat_map(|i| i.cuts.clone()))
            .collect();
        assert_eq!(cuts.len(), 30);
        apply_cleanup(path.clone(), id, report.total_bytes, cuts).unwrap();

        let info = book::open_book(path.clone()).unwrap();
        assert_eq!((info.chapters.len(), info.last_chapter), (30, 19));
        let now = book::read_quietly(&path, |t, _| t.to_string()).unwrap();
        assert!(!now.contains("example"));
        assert!(now[info.last_offset as usize..].starts_with("第20个夜晚"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        assert!(find_cleanup(path.clone()).unwrap().restorable);

        restore_original_text(path.clone(), id).unwrap();
        let info = book::open_book(path.clone()).unwrap();
        assert_eq!(info.last_offset as usize, place);
        assert!(!find_cleanup(path.clone()).unwrap().restorable);
        book::close_book(path);
        let _ = std::fs::remove_dir_all(&data);
    }
}
