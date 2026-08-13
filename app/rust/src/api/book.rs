//! The only surface Dart sees. Everything below this line is `novel-core`,
//! which knows nothing about Flutter and must stay that way.
//!
//! The decoded text lives here, in Rust, exactly once. Dart asks for a chapter
//! and gets back that chapter's paragraphs; it never holds the book. A 15 MB
//! novel handed to Dart is a 15 MB copy in the Dart heap, re-sliced on every
//! page turn, for no benefit.

use novel_core::book::{self, LineKind};
use novel_core::fingerprint::ParagraphStyle;
use novel_core::store::{self, BookRecord, ChapterRecord, Store};
use novel_core::{chunk, decode, fingerprint, focus, genre, meta, repair};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock, RwLock};

struct Loaded {
    /// The parsed structure returned to Flutter. Keeping it beside the text
    /// makes a second open cheap, while still allowing a full reload after the
    /// cache has deliberately been released.
    info: BookInfo,
    text: String,
    style: ParagraphStyle,
    /// Fixed wrap width when the file was hard-wrapped by its source. Paragraphs
    /// are rejoined at display time; the text and its offsets never change.
    hard_wrap: Option<usize>,
    chapters: Vec<book::Chapter>,
    /// Byte offsets of volume-header lines, so a chapter's paragraphs can name
    /// one when it falls inside their span.
    volume_starts: std::collections::HashSet<usize>,
}

fn cache() -> &'static RwLock<HashMap<String, Loaded>> {
    static C: OnceLock<RwLock<HashMap<String, Loaded>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

pub(crate) fn store() -> &'static Mutex<Option<Store>> {
    static S: OnceLock<Mutex<Option<Store>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

macro_rules! with_store {
    ($s:ident => $body:expr) => {{
        let mut guard = store().lock().unwrap();
        let $s = guard.as_mut().ok_or("数据库未初始化")?;
        $body.map_err(|e| format!("{e}"))
    }};
}

/// Called once at startup with a directory Flutter obtained from the platform.
/// Rust must not guess where an app may write: it differs on every OS, and on
/// Android and iOS it differs per install.
pub fn init_store(dir: String) -> Result<(), String> {
    let mut p = PathBuf::from(dir);
    std::fs::create_dir_all(&p).map_err(|e| format!("建目录失败: {e}"))?;
    p.push("library.db");
    let s = Store::open(&p).map_err(|e| format!("打开数据库失败: {e}"))?;
    *store().lock().unwrap() = Some(s);
    let _ = db_path().set(p);
    Ok(())
}

/// Where the library lives, so the settings page can weigh it.
fn db_path() -> &'static OnceLock<PathBuf> {
    static P: OnceLock<PathBuf> = OnceLock::new();
    &P
}

/// The directory Flutter gave us at startup. Rust must not guess where an app
/// may write — it differs on every OS — so everything that needs a place to put
/// a file asks here.
pub(crate) fn data_dir() -> Result<PathBuf, String> {
    db_path()
        .get()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .ok_or_else(|| "数据库未初始化".to_string())
}

/// What one book has cost us in AI output, and what deleting it would win back.
#[derive(Debug, Clone)]
pub struct CacheEntry {
    pub book_id: i64,
    pub title: String,
    pub chapter_count: i64,
    /// Chapters that carry a summary — the enrichment pass is resumable, so this
    /// is routinely less than the whole book.
    pub summaries: i64,
    pub summary_bytes: i64,
    pub chunks: i64,
    pub chunk_bytes: i64,
}

#[derive(Debug, Clone)]
pub struct CacheUsage {
    pub books: Vec<CacheEntry>,
    /// The whole library file, which holds the rows above plus the chapter cut,
    /// the reading log and the settings. Always bigger than the sum of the parts.
    pub db_bytes: i64,
}

pub fn cache_usage() -> Result<CacheUsage, String> {
    let books = with_store!(s => s.storage())?
        .into_iter()
        .map(|b| CacheEntry {
            book_id: b.book_id,
            title: b.title,
            chapter_count: b.chapter_count,
            summaries: b.summaries,
            summary_bytes: b.summary_bytes,
            chunks: b.chunks,
            chunk_bytes: b.chunk_bytes,
        })
        .collect();
    let db_bytes = db_path()
        .get()
        .and_then(|p| std::fs::metadata(p).ok())
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    Ok(CacheUsage { books, db_bytes })
}

/// Throw away every summary and mood for a book. The book, its chapters and the
/// reading progress stay: this deletes the model's opinion, not the reader's.
pub fn drop_summaries(book_id: i64) -> Result<(), String> {
    with_store!(s => s.drop_summaries(book_id))?;
    with_store!(s => s.vacuum())
}

/// Both, in one go, for the "清空这本书的 AI 数据" button.
pub fn drop_book_cache(book_id: i64) -> Result<(), String> {
    with_store!(s => s.drop_summaries(book_id))?;
    with_store!(s => s.drop_index(book_id))?;
    with_store!(s => s.vacuum())
}

/// The reading log. Unlike summaries and vectors this cannot be recomputed, so
/// the button that calls it says so.
pub fn clear_reading_events() -> Result<(), String> {
    with_store!(s => s.clear_events())?;
    with_store!(s => s.vacuum())
}

#[derive(Debug, Clone)]
pub struct ChapterInfo {
    pub index: u32,
    /// What the author numbered it. Absent, repeated, and out of order in real
    /// books, so never use it as a key — `index` is the key.
    pub number: Option<i64>,
    pub title: String,
    pub start: i64,
    pub end: i64,
    /// One-sentence summary written by the enrichment pass, if it has reached
    /// this chapter. Every UI must render correctly when this is None.
    pub summary: Option<String>,
    /// One-word mood label from the same pass, from a fixed vocabulary. Same
    /// rule: absent until enrichment has been here, and absence must render fine.
    pub mood: Option<String>,
}

#[derive(Debug, Clone)]
pub struct VolumeInfo {
    pub title: String,
    pub first_chapter: u32,
}

#[derive(Debug, Clone)]
pub struct BookInfo {
    pub id: i64,
    pub path: String,
    pub title: String,
    pub author: Option<String>,
    pub encoding: String,
    pub style: String,
    pub total_bytes: i64,
    pub chapters: Vec<ChapterInfo>,
    pub volumes: Vec<VolumeInfo>,
    pub interstitial_count: u32,
    /// Numbering that does not climb. Shown to the user as a hint, never acted on.
    pub anomalies: Vec<String>,
    pub last_chapter: i64,
    pub last_offset: i64,
    pub cover_path: Option<String>,
    /// Coarse, independent estimates. Never percentages: one scene may advance
    /// several lines, and rules cannot honestly measure exact page share.
    pub career_focus: String,
    pub romance_focus: String,
    pub growth_focus: String,
}

/// What the shelf shows. Deliberately not `BookInfo`: the shelf must not pay for
/// 1500 chapter titles per book.
#[derive(Debug, Clone)]
pub struct ShelfItem {
    pub id: i64,
    pub path: String,
    pub title: String,
    pub author: Option<String>,
    pub chapter_count: i64,
    pub last_chapter: i64,
    pub last_offset: i64,
    pub total_bytes: i64,
    pub last_opened_at: Option<i64>,
    /// What the file decoded as, so the user can tell a wrong guess at a glance.
    pub encoding: String,
    /// Stable per title, so a book keeps its cover colour forever.
    pub cover_hue: u32,
    /// The chapter the reader stopped in. Empty for a book never opened.
    pub last_chapter_title: String,
    /// Pinned books hold the top of the shelf, above recency.
    pub pinned: bool,
    /// 类型标签 (玄幻, 都市…), at most two. Empty when the text does not say, or
    /// when the book has not been decoded yet — it is computed on first open,
    /// and it is a lexicon, not a model: no engine, no download, no waiting.
    pub genre_tags: Vec<String>,
    /// A reader-chosen cover image on disk. None means show the generated cover.
    pub cover_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParaKind {
    Body,
    Title,
    /// A volume header. Divides the story; belongs to no chapter.
    Volume,
    /// Author's note or site ad. Rendered, but set apart, and never in the TOC.
    Interstitial,
}

#[derive(Debug, Clone)]
pub struct Paragraph {
    pub kind: ParaKind,
    pub text: String,
    /// Byte offsets into the decoded book. Reading progress, bookmarks and
    /// highlights anchor to these — not to paragraph indices, which move
    /// whenever segmentation improves.
    pub start: i64,
    pub end: i64,
}

/// Decode, structure and register a book. Idempotent: opening a book already on
/// the shelf keeps its id, and therefore its progress and its reading history.
pub fn open_book(path: String) -> Result<BookInfo, String> {
    // The detail page has already decoded most books before the reader opens.
    // Reuse that work when it is still available; if a background task released
    // the cache, fall through to the normal, reliable disk path below.
    if let Some(mut info) = cache()
        .read()
        .unwrap()
        .get(&path)
        .map(|loaded| loaded.info.clone())
    {
        let (mut last_chapter, last_offset) = with_store!(s => s.progress(info.id))?;
        if last_offset > 0 {
            if let Some(actual_chapter) =
                with_store!(s => s.chapter_at_offset(info.id, last_offset))?
            {
                if actual_chapter != last_chapter {
                    with_store!(s => s.repair_progress_chapter(info.id, actual_chapter))?;
                    last_chapter = actual_chapter;
                }
            }
        }
        let summaries: HashMap<i64, String> = with_store!(s => s.chapter_summaries(info.id))?
            .into_iter()
            .collect();
        let moods: HashMap<i64, String> = with_store!(s => s.chapter_moods(info.id))?
            .into_iter()
            .collect();
        for chapter in &mut info.chapters {
            chapter.summary = summaries.get(&(chapter.index as i64)).cloned();
            chapter.mood = moods.get(&(chapter.index as i64)).cloned();
        }
        info.last_chapter = last_chapter;
        info.last_offset = last_offset;
        return Ok(info);
    }

    let raw = std::fs::read(&path).map_err(|e| format!("读取失败: {e}"))?;
    let forced = with_store!(s => s.encoding_override(&path))?;
    let d = match forced {
        Some(label) => {
            decode::decode_as(&raw, &label).ok_or_else(|| format!("未知编码: {label}"))?
        }
        None => decode::decode(&raw),
    };
    let fp = fingerprint::fingerprint(d.encoding, &d.text);
    let b = book::build(&d.text, &fp);
    let m = meta::extract(&path, &d.text);

    let chapter_records: Vec<ChapterRecord> = b
        .chapters
        .iter()
        .map(|c| ChapterRecord {
            index: c.index as i64,
            number: c.number.map(|n| n as i64),
            title: c.title.clone(),
            start: c.span.start as i64,
            end: c.span.end as i64,
            body_start: c.body_start as i64,
            text_hash: store::text_hash(&d.text[c.body_start..c.span.end]),
        })
        .collect();

    let record = BookRecord {
        id: 0,
        path: path.clone(),
        title: m.title.clone(),
        author: m.author.clone(),
        encoding: d.encoding.to_string(),
        style: format!("{:?}", fp.style),
        total_bytes: d.text.len() as i64,
        chapter_count: b.chapters.len() as i64,
        added_at: store::now(),
        last_opened_at: None,
        last_chapter: 0,
        last_offset: 0,
        pinned_at: None,
        genre_tags: None,
    };

    let id = with_store!(s => s.upsert_book(&record, &chapter_records))?;

    // Tag the book the first time we ever decode it, and never again: the
    // lexicon reads the whole text, which is fast but not free, and the text
    // does not change. A stored empty string is a real answer — "we looked and
    // it does not say" — and is not retried.
    if with_store!(s => s.genre_tags(id))?.is_none() {
        let tags = genre::tags(&d.text).join("、");
        with_store!(s => s.set_genre_tags(id, &tags))?;
    }
    let (mut last_chapter, last_offset) = with_store!(s => s.progress(id))?;
    if last_offset > 0 {
        if let Some(actual_chapter) = with_store!(s => s.chapter_at_offset(id, last_offset))? {
            if actual_chapter != last_chapter {
                with_store!(s => s.repair_progress_chapter(id, actual_chapter))?;
                last_chapter = actual_chapter;
            }
        }
    }
    let summaries: HashMap<i64, String> = with_store!(s => s.chapter_summaries(id))?
        .into_iter()
        .collect();
    let moods: HashMap<i64, String> = with_store!(s => s.chapter_moods(id))?.into_iter().collect();
    let display_title = with_store!(s => s.custom_title(id))?.unwrap_or(m.title);
    let display_author = with_store!(s => s.custom_author(id))?.or(m.author);
    let cover = with_store!(s => s.cover_path(id))?;

    let shape = (d.text.len() as i64, b.chapters.len() as i64);
    let narrative_labels = with_store!(s => s.narrative_focus(
        id,
        focus::FOCUS_VERSION,
        shape.0,
        shape.1
    ))?;
    let (career_focus, romance_focus, growth_focus) = match narrative_labels {
        Some(labels) => labels,
        None => {
            let narrative = focus::analyze(&d.text, &b.chapters);
            let labels = (
                narrative.career.zh().to_string(),
                narrative.romance.zh().to_string(),
                narrative.growth.zh().to_string(),
            );
            with_store!(s => s.set_narrative_focus(
                id,
                focus::FOCUS_VERSION,
                shape.0,
                shape.1,
                &labels.0,
                &labels.1,
                &labels.2
            ))?;
            labels
        }
    };
    let info = BookInfo {
        id,
        path: path.clone(),
        title: display_title,
        author: display_author,
        encoding: d.encoding.to_string(),
        style: format!("{:?}", fp.style),
        total_bytes: d.text.len() as i64,
        chapters: b
            .chapters
            .iter()
            .map(|c| ChapterInfo {
                index: c.index as u32,
                number: c.number.map(|n| n as i64),
                title: c.title.clone(),
                start: c.span.start as i64,
                end: c.span.end as i64,
                summary: summaries.get(&(c.index as i64)).cloned(),
                mood: moods.get(&(c.index as i64)).cloned(),
            })
            .collect(),
        volumes: b
            .volumes
            .iter()
            .map(|v| VolumeInfo {
                title: v.title.clone(),
                first_chapter: v.first_chapter as u32,
            })
            .collect(),
        interstitial_count: b.interstitials.len() as u32,
        anomalies: b.anomalies.clone(),
        last_chapter,
        last_offset,
        cover_path: cover,
        career_focus,
        romance_focus,
        growth_focus,
    };

    cache().write().unwrap().insert(
        path,
        Loaded {
            info: info.clone(),
            volume_starts: b.volumes.iter().map(|v| v.span.start).collect(),
            text: d.text,
            style: fp.style,
            hard_wrap: fp.hard_wrap_width,
            chapters: b.chapters,
        },
    );
    Ok(info)
}

/// Re-parse a book with a user-chosen encoding (`None` returns to detection).
/// The choice persists, so the book decodes correctly on every future open.
pub fn set_book_encoding(
    book_id: i64,
    path: String,
    encoding: Option<String>,
) -> Result<BookInfo, String> {
    with_store!(s => s.set_encoding_override(book_id, encoding.as_deref()))?;
    close_book(path.clone());
    // The old tags were computed from the old decoding — which, if the user is
    // here, was mojibake. Clear them so the re-open re-tags from the real text.
    with_store!(s => s.clear_genre_tags(book_id))?;
    open_book(path)
}

pub fn chapter_paragraphs(path: String, index: u32) -> Result<Vec<Paragraph>, String> {
    let guard = cache().read().unwrap();
    let l = guard.get(&path).ok_or("书未打开")?;
    let c = l.chapters.get(index as usize).ok_or("章节不存在")?;

    let mut out: Vec<Paragraph> = Vec::new();
    let mut off = c.span.start;
    // Was the previous physical line cut by a fixed wrap width? Then this line
    // is its continuation, not a new paragraph.
    let mut carry = false;
    for line in l.text[c.span.start..c.span.end].split('\n') {
        let (start, end) = (off, off + line.len());
        off = end + 1;
        if line.trim().is_empty() {
            carry = false; // a blank line ends a paragraph whatever the widths say
            continue;
        }
        let is_title = start == c.span.start && c.body_start > c.span.start;
        let kind = if l.volume_starts.contains(&start) {
            ParaKind::Volume
        } else {
            match book::line_kind(line, is_title, l.style) {
                LineKind::ChapterTitle => ParaKind::Title,
                LineKind::Interstitial => ParaKind::Interstitial,
                LineKind::Body => ParaKind::Body,
            }
        };
        // Strip the indent for display: it is a structural marker, and the
        // renderer applies its own first-line indent from user settings.
        let text = line.trim().to_string();

        match out.last_mut() {
            Some(last) if carry && kind == ParaKind::Body && last.kind == ParaKind::Body => {
                repair::join(&mut last.text, &text);
                last.end = end as i64;
            }
            _ => out.push(Paragraph {
                kind,
                text,
                start: start as i64,
                end: end as i64,
            }),
        }
        carry = kind == ParaKind::Body && l.hard_wrap.is_some_and(|w| repair::continues(line, w));
    }
    Ok(out)
}

/// Tag every book that has never been tagged, and say how many were.
///
/// Books already on the shelf when this feature landed have no tags, and a book
/// is only tagged when it is decoded — which for an unopened book is never. So
/// the shelf asks for a backfill once on startup. It reads and decodes each
/// untagged file, which is why it runs on the Rust worker pool and not on the
/// way to painting a frame.
pub fn backfill_genres() -> Result<u32, String> {
    let todo: Vec<(i64, String)> = {
        let s = store().lock().unwrap();
        let s = s.as_ref().ok_or("数据库未初始化")?;
        s.library()
            .map_err(|e| format!("{e}"))?
            .into_iter()
            .filter(|b| b.genre_tags.is_none())
            .map(|b| (b.id, b.path))
            .collect()
    };

    let mut done = 0;
    for (id, path) in todo {
        // A file that has moved or gone is not an error here — it will report
        // itself the moment the reader taps it. Skip and carry on.
        let Ok(raw) = std::fs::read(&path) else {
            continue;
        };
        let forced = with_store!(s => s.encoding_override(&path))?;
        let d = match forced {
            Some(label) => match decode::decode_as(&raw, &label) {
                Some(d) => d,
                None => continue,
            },
            None => decode::decode(&raw),
        };
        let tags = genre::tags(&d.text).join("、");
        with_store!(s => s.set_genre_tags(id, &tags))?;
        done += 1;
    }
    Ok(done)
}

pub fn list_books() -> Result<Vec<ShelfItem>, String> {
    let mut guard = store().lock().unwrap();
    let s = guard.as_mut().ok_or("数据库未初始化")?;
    let books = s.library().map_err(|e| format!("{e}"))?;
    Ok(books
        .into_iter()
        .map(|b| ShelfItem {
            cover_hue: meta::cover_hue(&b.title) as u32,
            last_chapter_title: s
                .chapter_title(b.id, b.last_chapter)
                .ok()
                .flatten()
                .unwrap_or_default(),
            id: b.id,
            path: b.path,
            title: b.title,
            author: b.author,
            encoding: b.encoding,
            chapter_count: b.chapter_count,
            last_chapter: b.last_chapter,
            last_offset: b.last_offset,
            total_bytes: b.total_bytes,
            last_opened_at: b.last_opened_at,
            pinned: b.pinned_at.is_some(),
            genre_tags: b
                .genre_tags
                .unwrap_or_default()
                .split('、')
                .filter(|t| !t.is_empty())
                .map(str::to_string)
                .collect(),
            cover_path: s.cover_path(b.id).ok().flatten(),
        })
        .collect())
}

pub fn save_progress(book_id: i64, chapter: i64, offset: i64) -> Result<(), String> {
    let actual_chapter = with_store!(s => s.chapter_at_offset(book_id, offset))?.unwrap_or(chapter);
    with_store!(s => s.save_progress(book_id, actual_chapter, offset))
}

#[derive(Debug, Clone)]
pub struct BookAnnotation {
    pub id: i64,
    pub book_id: i64,
    pub chapter: i64,
    pub start: i64,
    pub end: i64,
    pub quote: String,
    pub body: String,
    pub visibility: String,
    pub sync_id: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub fn list_annotations(book_id: i64) -> Result<Vec<BookAnnotation>, String> {
    let rows = with_store!(s => s.annotations(book_id))?;
    Ok(rows
        .into_iter()
        .map(|a| BookAnnotation {
            id: a.id,
            book_id: a.book_id,
            chapter: a.chapter,
            start: a.start,
            end: a.end,
            quote: a.quote,
            body: a.body,
            visibility: a.visibility,
            sync_id: a.sync_id,
            created_at: a.created_at,
            updated_at: a.updated_at,
        })
        .collect())
}

pub fn save_annotation(
    annotation_id: Option<i64>,
    book_id: i64,
    chapter: i64,
    start: i64,
    end: i64,
    quote: String,
    body: String,
) -> Result<i64, String> {
    let body = body.trim();
    if body.is_empty() {
        return Err("标注内容不能为空".to_string());
    }
    if end < start {
        return Err("标注位置无效".to_string());
    }
    with_store!(s => s.save_annotation(
        annotation_id,
        book_id,
        chapter,
        start,
        end,
        quote.trim(),
        body
    ))
}

pub fn delete_annotation(book_id: i64, annotation_id: i64) -> Result<(), String> {
    with_store!(s => s.delete_annotation(book_id, annotation_id))
}

pub fn list_completed_chapters(book_id: i64) -> Result<Vec<i64>, String> {
    with_store!(s => s.completed_chapters(book_id))
}

pub fn mark_chapter_completed(book_id: i64, chapter: i64) -> Result<(), String> {
    with_store!(s => s.mark_chapter_completed(book_id, chapter))
}

/// One reading session. Never fabricated: a session with no movement is not
/// written, so the heatmap counts reading, not idling with the app open.
pub fn log_event(book_id: i64, started: i64, ended: i64, from: i64, to: i64) -> Result<(), String> {
    with_store!(s => s.log_event(book_id, started, ended, from, to))
}

#[derive(Debug, Clone)]
pub struct ReadingEvent {
    pub book_id: i64,
    pub started: i64,
    pub ended: i64,
}

/// Sessions since a cutoff, oldest first. The UI buckets them into local days;
/// unix timestamps know no timezone.
pub fn list_events(since: i64) -> Result<Vec<ReadingEvent>, String> {
    let rows = with_store!(s => s.events_since(since))?;
    Ok(rows
        .into_iter()
        .map(|(book_id, started, ended)| ReadingEvent {
            book_id,
            started,
            ended,
        })
        .collect())
}

#[derive(Debug, Clone)]
pub struct BookTime {
    pub title: String,
    pub seconds: i64,
}

/// Total reading time per book, most-read first.
pub fn time_per_book() -> Result<Vec<BookTime>, String> {
    let rows = with_store!(s => s.time_per_book())?;
    Ok(rows
        .into_iter()
        .map(|(title, seconds)| BookTime { title, seconds })
        .collect())
}

pub fn remove_book(book_id: i64) -> Result<(), String> {
    if let Some(cover) = with_store!(s => s.cover_path(book_id))? {
        let _ = std::fs::remove_file(&cover);
    }
    with_store!(s => s.remove_book(book_id))
}

/// Delete a book and everything the app ever made of it: chapters, summaries,
/// moods, the semantic index, the reading log, the progress. The `books` row is
/// the root of all of it and the schema cascades, so one DELETE takes the lot.
///
/// The file goes too — but only if it is a file we made. A book downloaded from
/// a source lives in our own books directory and is ours to remove; a TXT the
/// reader imported from their own disk is theirs, sits wherever they keep it,
/// and is not ours to delete no matter what button they pressed in here.
pub fn delete_book(book_id: i64) -> Result<(), String> {
    let path = with_store!(s => s.book_path(book_id))?;
    if let Some(cover) = with_store!(s => s.cover_path(book_id))? {
        let _ = std::fs::remove_file(&cover);
    }
    with_store!(s => s.remove_book(book_id))?;
    if let Some(path) = path {
        let ours = data_dir()?.join("books");
        let path = PathBuf::from(path);
        if path.starts_with(&ours) {
            let _ = std::fs::remove_file(&path);
        }
    }
    Ok(())
}

/// Change how a book is titled everywhere in the app. The TXT file itself is
/// never touched. An empty (or blank) name clears the override and the title
/// parsed from the file comes back.
pub fn rename_book(book_id: i64, title: String) -> Result<(), String> {
    let t = title.trim();
    with_store!(s => s.rename_book(book_id, (!t.is_empty()).then_some(t)))
}

/// Change a book's author everywhere in the app. Like [`rename_book`], the TXT is
/// never touched, and a blank value clears the override so the parsed author
/// returns.
pub fn set_book_author(book_id: i64, author: String) -> Result<(), String> {
    let a = author.trim();
    with_store!(s => s.set_author(book_id, (!a.is_empty()).then_some(a)))
}

/// Adopt a chosen image as this book's cover. We copy it into our own data dir
/// rather than referencing it in place, so the cover survives the original being
/// moved or deleted — the same principle as never depending on the TXT's path
/// for anything but reading it.
pub fn set_book_cover(book_id: i64, src: String) -> Result<(), String> {
    let dir = data_dir()?.join("covers");
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建封面目录失败: {e}"))?;
    let ext = std::path::Path::new(&src)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("img")
        .to_lowercase();
    let dest = dir.join(format!("{book_id}.{ext}"));
    let dest_str = dest.to_string_lossy().to_string();
    // A previous cover in a different format would otherwise be orphaned.
    if let Some(old) = with_store!(s => s.cover_path(book_id))? {
        if old != dest_str {
            let _ = std::fs::remove_file(&old);
        }
    }
    std::fs::copy(&src, &dest).map_err(|e| format!("复制封面失败: {e}"))?;
    with_store!(s => s.set_cover(book_id, Some(&dest_str)))
}

/// Drop the custom cover and fall back to the generated one, deleting our copy.
pub fn clear_book_cover(book_id: i64) -> Result<(), String> {
    if let Some(old) = with_store!(s => s.cover_path(book_id))? {
        let _ = std::fs::remove_file(&old);
    }
    with_store!(s => s.set_cover(book_id, None))
}

/// Pin a book to the top of the shelf, or release it back into recency order.
pub fn set_book_pinned(book_id: i64, pinned: bool) -> Result<(), String> {
    with_store!(s => s.set_pinned(book_id, pinned))
}

/// Persist a drag-and-drop ordering of the pinned zone; first id ends on top.
/// Books not in `ids` that were pinned stay pinned — pass the complete zone.
pub fn set_pin_order(ids: Vec<i64>) -> Result<(), String> {
    with_store!(s => s.set_pin_order(&ids))
}

pub fn close_book(path: String) {
    cache().write().unwrap().remove(&path);
}

pub(crate) fn is_loaded(path: &str) -> bool {
    cache().read().unwrap().contains_key(path)
}

/// Decode and cut the book if this run has not already. Everything that reaches
/// into a book's text — titles, chunks, snippets — needs it in the cache first,
/// and features reachable from the shelf run against books nobody has opened.
/// Cheap when it is already there, which is the common case.
pub(crate) fn ensure_loaded(path: &str) -> Result<(), String> {
    if !is_loaded(path) {
        open_book(path.to_string())?;
    }
    Ok(())
}

/// One place in the book, found by either search. `score` is 1.0 for a literal
/// match — it either says the words or it does not — and the cosine for a
/// semantic one.
#[derive(Debug, Clone)]
pub struct SearchHit {
    pub chapter: u32,
    pub title: String,
    /// Byte offset in the decoded text: where the reader is sent.
    pub start: i64,
    pub text: String,
    pub score: f32,
}

/// Literal search: the words, exactly as typed. No model, no index, nothing to
/// install — it works on a book imported thirty seconds ago.
///
/// Bounded by the same spoiler line as the semantic one: text the reader has not
/// reached is not searched. Finding the murderer's name in chapter 900 by
/// searching for it in chapter 20 is still a spoiler, however it was found.
pub fn search_text(
    path: String,
    query: String,
    up_to_chapter: i64,
    k: u32,
) -> Result<Vec<SearchHit>, String> {
    let q = query.trim();
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let guard = cache().read().unwrap();
    let l = guard.get(&path).ok_or("书未打开")?;

    let last = (up_to_chapter.max(0) as usize).min(l.chapters.len().saturating_sub(1));
    let end = l.chapters.get(last).map(|c| c.span.end).unwrap_or(0);

    let mut out = Vec::new();
    for (pos, _) in l.text[..end].match_indices(q) {
        // Which chapter holds this byte? The spans are sorted and contiguous.
        let ch = l
            .chapters
            .partition_point(|c| c.span.start <= pos)
            .saturating_sub(1);
        out.push(SearchHit {
            chapter: ch as u32,
            title: l
                .chapters
                .get(ch)
                .map(|c| c.title.clone())
                .unwrap_or_default(),
            start: pos as i64,
            text: around(&l.text, pos, q.len(), 20, 60),
            score: 1.0,
        });
        if out.len() == k as usize {
            break;
        }
    }
    Ok(out)
}

/// The match with enough of its sentence around it to be recognizable.
fn around(text: &str, pos: usize, len: usize, before: usize, after: usize) -> String {
    let mut s = pos;
    for _ in 0..before {
        match text[..s].char_indices().next_back() {
            Some((i, c)) if c != '\n' => s = i,
            _ => break,
        }
    }
    let mut e = (pos + len).min(text.len());
    while e < text.len() && !text.is_char_boundary(e) {
        e += 1;
    }
    for _ in 0..after {
        match text[e..].chars().next() {
            Some(c) if c != '\n' => e += c.len_utf8(),
            _ => break,
        }
    }
    text[s..e].trim().to_string()
}

/// One chapter cut into retrieval chunks, each carrying the byte span it covers.
pub(crate) fn chapter_chunks(path: &str, index: u32) -> Result<Vec<chunk::Chunk>, String> {
    let guard = cache().read().unwrap();
    let l = guard.get(path).ok_or("书未打开")?;
    let c = l.chapters.get(index as usize).ok_or("章节不存在")?;
    Ok(chunk::chunk_body(
        &l.text,
        c.body_start,
        c.span.end,
        chunk::TARGET_CHARS,
    ))
}

pub(crate) fn chapter_titles(path: &str) -> Result<Vec<String>, String> {
    let guard = cache().read().unwrap();
    let l = guard.get(path).ok_or("书未打开")?;
    Ok(l.chapters.iter().map(|c| c.title.clone()).collect())
}

/// The text behind a byte span, for showing a search hit in its own words.
/// Clamped to char boundaries: the span came from an index that may have been
/// built against a different decoding of the same file.
pub(crate) fn snippet(
    path: &str,
    start: i64,
    end: i64,
    max_chars: usize,
) -> Result<String, String> {
    let guard = cache().read().unwrap();
    let l = guard.get(path).ok_or("书未打开")?;
    let (mut s, mut e) = (start.max(0) as usize, (end as usize).min(l.text.len()));
    if s >= e {
        return Ok(String::new());
    }
    while s < e && !l.text.is_char_boundary(s) {
        s += 1;
    }
    while e > s && !l.text.is_char_boundary(e) {
        e -= 1;
    }
    let body: String = l.text[s..e]
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    Ok(match body.char_indices().nth(max_chars) {
        Some((i, _)) => format!("{}…", &body[..i]),
        None => body,
    })
}

/// The slice of a chapter the summarizer reads: the opening carries the scene,
/// the closing carries the outcome; the middle is where the token budget dies.
pub(crate) fn chapter_excerpt(
    path: &str,
    index: u32,
    head_chars: usize,
    tail_chars: usize,
) -> Result<String, String> {
    let guard = cache().read().unwrap();
    let l = guard.get(path).ok_or("书未打开")?;
    let c = l.chapters.get(index as usize).ok_or("章节不存在")?;
    let body = l.text[c.body_start..c.span.end].trim();

    let n = body.chars().count();
    if n <= head_chars + tail_chars {
        return Ok(body.to_string());
    }
    let head_end = body
        .char_indices()
        .nth(head_chars)
        .map(|(i, _)| i)
        .unwrap_or(body.len());
    let tail_start = body
        .char_indices()
        .rev()
        .nth(tail_chars - 1)
        .map(|(i, _)| i)
        .unwrap_or(0);
    Ok(format!(
        "{}\n……\n{}",
        &body[..head_end],
        &body[tail_start..]
    ))
}

// ── 人物图谱 ─────────────────────────────────────────────────────────────────
//
// Who is in the book and who stands with whom — the whole thing built by
// counting (novel_core::cast), not by asking a model to read. The one place a
// model earns its keep is turning an edge with no decisive appellation into one
// relationship label from a closed set, and that lives in `ai.rs`; here the
// graph comes out with the labels the rules could settle on their own, and the
// rest marked None for the model to fill (or to stay 不明).
//
// Capped at the reader's progress, like everything else that reaches into a
// book except 排雷: the graph of the first fifty chapters must not draw an edge
// that only exists because of chapter six hundred.

#[derive(Debug, Clone)]
pub struct CastPerson {
    pub name: String,
    /// Shorter forms folded in (吕小鱼 ← 小鱼).
    pub aliases: Vec<String>,
    pub mentions: u32,
    /// Distinct chapters the person appears in, within the scanned range.
    pub chapters: u32,
    pub first_chapter: u32,
    /// The statistics could not tell whether this is a person; the model has not
    /// ruled on it yet. Shown dimmed, and it is what 校对人物 asks about.
    pub uncertain: bool,
    /// The model's prose account of who this character is, or None until it has
    /// written one. Every UI must render correctly when this is None.
    pub background: Option<String>,
    /// The sentences that account rests on — shown to the reader, so a claim
    /// about a character can always be traced back to the book.
    pub evidence: Vec<RelEvidence>,
}

#[derive(Debug, Clone)]
pub struct RelEvidence {
    pub chapter: u32,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct CastRelation {
    /// Indices into [`CastGraph::people`].
    pub a: u32,
    pub b: u32,
    /// Sharing a sentence counts double sharing a paragraph.
    pub weight: u32,
    /// The model's prose summary of how the pair get on, or None until it has
    /// written one. (Field kept named `label` to avoid a bridge regeneration; it
    /// carries a sentence now, not a category.)
    pub label: Option<String>,
    /// Pre-formatted appellation chips ("同学×5"), for the evidence panel.
    pub hints: Vec<String>,
    pub evidence: Vec<RelEvidence>,
}

#[derive(Debug, Clone)]
pub struct CastGraph {
    pub people: Vec<CastPerson>,
    pub edges: Vec<CastRelation>,
    /// Chapters actually scanned — the spoiler cap — so the UI can say "up to
    /// chapter N" instead of implying it read the whole book.
    pub upto: u32,
}

#[derive(Debug, Clone)]
pub struct RelationshipEvidenceInfo {
    pub chapter: u32,
    pub person: String,
    pub kind: String,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct RelationshipPersonInfo {
    pub name: String,
    pub status: String,
    pub evidence: Vec<RelationshipEvidenceInfo>,
}

#[derive(Debug, Clone)]
pub struct RelationshipStructureInfo {
    pub label: String,
    pub reason: String,
    pub confidence: u32,
    pub protagonist: String,
    pub analyzed_chapters: u32,
    pub candidate_count: u32,
    pub people: Vec<RelationshipPersonInfo>,
    pub group_evidence: Vec<RelationshipEvidenceInfo>,
}

/// Number of chapters to scan for a reader sitting in `up_to_chapter`: that
/// chapter and everything before it, never past. A book never opened sits at 0,
/// so it scans its first chapter and no more.
fn scan_span(l: &Loaded, up_to_chapter: i64) -> usize {
    ((up_to_chapter.max(0) as usize) + 1).min(l.chapters.len())
}

/// Scan once, then never again: the built graph is stored against the book and
/// the chapter count it was built from. 剑来 is 41 MB and 1275 chapters, and the
/// reader should wait for that exactly one time.
pub(crate) fn scan_cached(
    path: &str,
    book_id: i64,
    up_to_chapter: i64,
) -> Result<(novel_core::cast::Cast, usize), String> {
    let (upto, total) = {
        let guard = cache().read().unwrap();
        let l = guard.get(path).ok_or("书未打开")?;
        (scan_span(l, up_to_chapter), l.chapters.len() as i64)
    };
    let hit = with_store!(s => s.cast_cache(book_id, upto as i64, total))
        .ok()
        .flatten();
    if let Some(json) = hit {
        // A graph built by an older scan (fewer people, thinner evidence) is
        // wrong to reuse — the version guards against a new binary serving it.
        if let Ok(cast) = serde_json::from_str::<novel_core::cast::Cast>(&json) {
            if cast.version == novel_core::cast::SCAN_VERSION {
                return Ok((cast, upto));
            }
        }
    }
    let guard = cache().read().unwrap();
    let l = guard.get(path).ok_or("书未打开")?;
    let cast = novel_core::cast::scan(&l.text, &l.chapters, upto);
    if let Ok(json) = serde_json::to_string(&cast) {
        let _ = with_store!(s => s.set_cast_cache(book_id, upto as i64, total, &json));
    }
    Ok((cast, upto))
}

/// Scan the cast and relationships. Pure rules, no engine, no download —
/// then whatever the model has already ruled on for this book is laid over the
/// top: candidates it rejected are dropped along with their edges, and labels it
/// picked fill in the ones the rules left open.
pub fn cast_graph(path: String, book_id: i64, up_to_chapter: i64) -> Result<CastGraph, String> {
    ensure_loaded(&path)?;
    let (cast, upto) = scan_cached(&path, book_id, up_to_chapter)?;

    let verdicts: HashMap<String, bool> = with_store!(s => s.name_verdicts(book_id))
        .unwrap_or_default()
        .into_iter()
        .collect();
    let summaries: HashMap<(String, String), String> =
        with_store!(s => s.relation_summaries(book_id))
            .unwrap_or_default()
            .into_iter()
            .map(|(a, b, l)| ((a, b), l))
            .collect();
    let backgrounds: HashMap<String, String> = with_store!(s => s.person_summaries(book_id))
        .unwrap_or_default()
        .into_iter()
        .collect();

    // Renumber around anyone the model threw out.
    let keep: Vec<bool> = cast
        .people
        .iter()
        .map(|p| *verdicts.get(&p.name).unwrap_or(&true))
        .collect();
    let mut remap = vec![usize::MAX; cast.people.len()];
    let mut people: Vec<CastPerson> = Vec::new();
    for (i, p) in cast.people.iter().enumerate() {
        if !keep[i] {
            continue;
        }
        remap[i] = people.len();
        people.push(CastPerson {
            name: p.name.clone(),
            aliases: p.aliases.clone(),
            mentions: p.mentions,
            chapters: p.chapters,
            first_chapter: p.first_chapter as u32,
            // A verdict of "yes" settles it; only an unjudged one stays dim.
            uncertain: p.uncertain && !verdicts.contains_key(&p.name),
            background: backgrounds.get(&p.name).cloned(),
            evidence: p
                .evidence
                .iter()
                .map(|(ch, t)| RelEvidence {
                    chapter: *ch as u32,
                    text: t.clone(),
                })
                .collect(),
        });
    }
    let edges = cast
        .edges
        .iter()
        .filter(|e| keep[e.a] && keep[e.b])
        .map(|e| {
            let (na, nb) = (&cast.people[e.a].name, &cast.people[e.b].name);
            CastRelation {
                a: remap[e.a] as u32,
                b: remap[e.b] as u32,
                weight: e.weight,
                // The model's prose summary, or None until it has written one. The
                // rule-layer's one-word label is no longer surfaced — every edge
                // now gets a full summary, whether or not the rules could guess.
                label: summaries.get(&(na.clone(), nb.clone())).cloned(),
                hints: e.hints.iter().map(|(w, c)| format!("{w}×{c}")).collect(),
                evidence: e
                    .evidence
                    .iter()
                    .map(|(ch, t)| RelEvidence {
                        chapter: *ch as u32,
                        text: t.clone(),
                    })
                    .collect(),
            }
        })
        .collect();
    Ok(CastGraph {
        people,
        edges,
        upto: upto as u32,
    })
}

/// The pre-reading relationship structure always scans the whole available
/// book. It uses the same cached cast pass as the graph, but reads the larger
/// internal roster before the graph UI trims it to ten people.
pub fn relationship_structure(
    path: String,
    book_id: i64,
) -> Result<RelationshipStructureInfo, String> {
    ensure_loaded(&path)?;
    let last_chapter = {
        let guard = cache().read().unwrap();
        guard
            .get(&path)
            .map(|loaded| loaded.chapters.len().saturating_sub(1) as i64)
            .ok_or("书未打开")?
    };
    let (cast, _) = scan_cached(&path, book_id, last_chapter)?;
    let report = cast
        .relationship
        .ok_or_else(|| "关系结构尚未生成".to_string())?;
    let evidence = |evidence: novel_core::romance::RelationshipEvidence| RelationshipEvidenceInfo {
        chapter: evidence.chapter as u32,
        person: evidence.person,
        kind: evidence.kind,
        text: evidence.text,
    };
    Ok(RelationshipStructureInfo {
        label: report.label,
        reason: report.reason,
        confidence: report.confidence,
        protagonist: report.protagonist,
        analyzed_chapters: report.analyzed_chapters as u32,
        candidate_count: report.candidate_count as u32,
        people: report
            .people
            .into_iter()
            .map(|person| RelationshipPersonInfo {
                name: person.name,
                status: person.status,
                evidence: person.evidence.into_iter().map(evidence).collect(),
            })
            .collect(),
        group_evidence: report.group_evidence.into_iter().map(evidence).collect(),
    })
}

/// Candidates sitting in the density band, with a sentence apiece — what the
/// model is asked to rule on. Already-judged names are not asked about twice.
pub(crate) fn unjudged_names(
    path: &str,
    book_id: i64,
    up_to_chapter: i64,
) -> Result<Vec<(String, String)>, String> {
    let (cast, _) = scan_cached(path, book_id, up_to_chapter)?;
    let judged: HashMap<String, bool> = with_store!(s => s.name_verdicts(book_id))
        .unwrap_or_default()
        .into_iter()
        .collect();
    Ok(cast
        .people
        .iter()
        .filter(|p| p.uncertain && !judged.contains_key(&p.name))
        .map(|p| {
            let sample = cast
                .edges
                .iter()
                .find(|e| {
                    (cast.people[e.a].name == p.name || cast.people[e.b].name == p.name)
                        && !e.evidence.is_empty()
                })
                .map(|e| e.evidence[0].1.clone())
                .unwrap_or_default();
            (p.name.clone(), sample)
        })
        .collect())
}

/// Every edge the model has not summarized yet, each with its two names and
/// evidence sentences — exactly what the summarizer needs and nothing it does
/// not. Unlike the old label pass, this returns *all* top edges (the rules'
/// one-word guess is no longer a shortcut): each pair earns a full summary.
/// Recomputed from the same scan so the model layer never trusts a stale graph
/// handed across the bridge.
pub(crate) fn residual_relations(
    path: &str,
    book_id: i64,
    up_to_chapter: i64,
) -> Result<Vec<(String, String, Vec<(usize, String)>)>, String> {
    let (cast, _) = scan_cached(path, book_id, up_to_chapter)?;
    let done: HashMap<(String, String), String> = with_store!(s => s.relation_summaries(book_id))
        .unwrap_or_default()
        .into_iter()
        .map(|(a, b, l)| ((a, b), l))
        .collect();
    Ok(cast
        .edges
        .iter()
        .filter(|e| {
            !done.contains_key(&(cast.people[e.a].name.clone(), cast.people[e.b].name.clone()))
        })
        .map(|e| {
            (
                cast.people[e.a].name.clone(),
                cast.people[e.b].name.clone(),
                e.evidence.iter().map(|(c, t)| (*c, t.clone())).collect(),
            )
        })
        .collect())
}

/// Every character the model has not written a background for, each with their
/// aliases and their sampled sentences — what the summarizer needs and nothing
/// more. Recomputed from the same scan, so the model layer never works off a
/// graph handed across the bridge and gone stale.
pub(crate) fn residual_people(
    path: &str,
    book_id: i64,
    up_to_chapter: i64,
) -> Result<Vec<(String, Vec<String>, Vec<(usize, String)>)>, String> {
    let (cast, _) = scan_cached(path, book_id, up_to_chapter)?;
    let done: HashMap<String, String> = with_store!(s => s.person_summaries(book_id))
        .unwrap_or_default()
        .into_iter()
        .collect();
    // Anyone the model has already thrown out is not worth a biography.
    let verdicts: HashMap<String, bool> = with_store!(s => s.name_verdicts(book_id))
        .unwrap_or_default()
        .into_iter()
        .collect();
    Ok(cast
        .people
        .iter()
        .filter(|p| !done.contains_key(&p.name) && *verdicts.get(&p.name).unwrap_or(&true))
        .map(|p| {
            (
                p.name.clone(),
                p.aliases.clone(),
                p.evidence.iter().map(|(c, t)| (*c, t.clone())).collect(),
            )
        })
        .collect())
}

/// Persist one model-written character background.
pub(crate) fn remember_person(book_id: i64, name: &str, summary: &str) -> Result<(), String> {
    with_store!(s => s.set_person_summary(book_id, name, summary))
        .map_err(|e| format!("保存人物背景失败: {e}"))
}

/// Persist one model-written relationship summary.
pub(crate) fn remember_relation(
    book_id: i64,
    a: &str,
    b: &str,
    summary: &str,
) -> Result<(), String> {
    with_store!(s => s.set_relation_summary(book_id, a, b, summary))
        .map_err(|e| format!("保存关系总结失败: {e}"))
}

/// Persist one model verdict on whether a candidate is a person at all.
pub(crate) fn remember_name(book_id: i64, name: &str, is_person: bool) -> Result<(), String> {
    with_store!(s => s.set_name_verdict(book_id, name, is_person))
        .map_err(|e| format!("保存人名判定失败: {e}"))
}

/// Drop the cached graph and every model verdict attached to this book.
pub fn forget_cast(book_id: i64) -> Result<(), String> {
    with_store!(s => s.drop_cast(book_id)).map_err(|e| format!("清除图谱缓存失败: {e}"))
}
