//! Local storage. Everything the reader remembers lives here, and nothing else
//! does: the original TXT is never modified, and the decoded text is never
//! persisted (it is cheap to rebuild and expensive to keep in sync).
//!
//! Three decisions are baked into the schema, because a schema is the hardest
//! thing to change — code ships once, a migration runs on every user's data.
//!
//! 1. The AI columns exist now and are NULL. Summaries, mood tags and entities
//!    are decoration on a reader that works without them. Adding the columns
//!    later would mean migrating every library in the field.
//! 2. Reading progress is a byte offset into the decoded text, never a paragraph
//!    index. Segmentation will improve; byte offsets will not move.
//! 3. `reading_events` records from the first day. The heatmap, the emotion
//!    curve and the re-entry briefing are all built from history, and history
//!    cannot be backfilled.

use rusqlite::{params, Connection, OptionalExtension, Result};
use std::path::Path;

pub struct Store {
    conn: Connection,
}

#[derive(Debug, Clone)]
pub struct BookRecord {
    pub id: i64,
    pub path: String,
    pub title: String,
    pub author: Option<String>,
    pub encoding: String,
    pub style: String,
    pub total_bytes: i64,
    pub chapter_count: i64,
    pub added_at: i64,
    pub last_opened_at: Option<i64>,
    /// Chapter index and byte offset of where the reader stopped.
    pub last_chapter: i64,
    pub last_offset: i64,
    /// Comma-separated 类型标签, computed once from the text by `genre::tags`.
    /// None means nobody has looked yet; an empty string means we looked and the
    /// book did not say — those are different, and only the first is retried.
    pub genre_tags: Option<String>,
    /// When the user pinned this book to the top of the shelf, if they did.
    pub pinned_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct ChapterRecord {
    pub index: i64,
    pub number: Option<i64>,
    pub title: String,
    pub start: i64,
    pub end: i64,
    pub body_start: i64,
    /// Hash of the chapter's opening text, punctuation stripped. Lets us find
    /// where the reader was after they replace the file with another edition of
    /// the same book, where every byte offset has shifted.
    pub text_hash: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BookmarkRecord {
    pub book_id: i64,
    pub chapter: i64,
    pub offset: i64,
    pub comment: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// A private note anchored to an exact byte range in the source text.
///
/// `visibility` and `sync_id` are intentionally present before community
/// annotations ship. Local notes always use `private` and no sync id today;
/// adding sharing later will not require changing the durable anchor format.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotationRecord {
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

/// A stored rule sheet. `json` is the user's file, untouched — we hand it back
/// to the engine to parse, and never rewrite it.
#[derive(Debug, Clone)]
pub struct SourceRecord {
    pub url: String,
    pub name: String,
    pub group: Option<String>,
    pub json: String,
    pub enabled: bool,
    /// None until tested. Some(false) sources are kept, greyed out, not deleted:
    /// a site that is down today may be up tomorrow.
    pub ok: Option<bool>,
    pub note: Option<String>,
}

/// One book's derived data, counted. Not the book: the file on disk is never
/// ours to touch, and nothing here is a loss if it goes.
#[derive(Debug, Clone)]
pub struct BookStorage {
    pub book_id: i64,
    pub title: String,
    pub chapter_count: i64,
    pub summaries: i64,
    pub summary_bytes: i64,
    pub chunks: i64,
    pub chunk_bytes: i64,
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS books (
    id            INTEGER PRIMARY KEY,
    path          TEXT NOT NULL UNIQUE,
    title         TEXT NOT NULL,
    author        TEXT,
    encoding      TEXT NOT NULL,
    style         TEXT NOT NULL,
    total_bytes   INTEGER NOT NULL,
    chapter_count INTEGER NOT NULL,
    added_at      INTEGER NOT NULL,
    last_opened_at INTEGER,
    last_chapter  INTEGER NOT NULL DEFAULT 0,
    last_offset   INTEGER NOT NULL DEFAULT 0,
    -- Filled by a single whole-book inference the first time the book is opened.
    genre_tags    TEXT,
    -- Set when the user overrides encoding detection. Consulted before decoding.
    encoding_override TEXT
);

CREATE TABLE IF NOT EXISTS chapters (
    book_id    INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    number     INTEGER,
    title      TEXT NOT NULL,
    start      INTEGER NOT NULL,
    end        INTEGER NOT NULL,
    body_start INTEGER NOT NULL,
    text_hash  INTEGER NOT NULL,
    -- NULL until the enrichment pass reaches this chapter. Every UI path must
    -- render correctly when these are NULL; none may assume a summary exists.
    summary    TEXT,
    mood       TEXT,
    entities   TEXT,
    model_tag  TEXT,
    PRIMARY KEY (book_id, idx)
);

-- One row per reading session. Written on pause, close, and chapter change.
CREATE TABLE IF NOT EXISTS reading_events (
    id           INTEGER PRIMARY KEY,
    book_id      INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    started_at   INTEGER NOT NULL,
    ended_at     INTEGER NOT NULL,
    start_offset INTEGER NOT NULL,
    end_offset   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_book ON reading_events(book_id, started_at);

-- Reading speed, from 2026-10. The reader page cuts a sitting into windows of
-- about 30 seconds and records how many characters went by in each. Written
-- raw, every window: which ones were a reader looking away or hunting through
-- pages is decided when counting (`reading_stats`), so a better rule later
-- re-reads the whole history instead of only what comes after it.
CREATE TABLE IF NOT EXISTS reading_windows (
    book_id    INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter    INTEGER NOT NULL,
    started_at INTEGER NOT NULL,
    secs       INTEGER NOT NULL,
    chars      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_windows_time ON reading_windows(started_at);
CREATE INDEX IF NOT EXISTS idx_windows_book ON reading_windows(book_id);

-- One bookmark per chapter. The byte offset returns to the exact reading
-- position, while the chapter key gives long novels a stable, scannable mark.
-- A short optional comment belongs to the bookmark; free-range text
-- annotations are a separate product decision and deliberately not mixed in.
CREATE TABLE IF NOT EXISTS bookmarks (
    book_id    INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter    INTEGER NOT NULL,
    offset     INTEGER NOT NULL,
    comment    TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (book_id, chapter)
);
CREATE INDEX IF NOT EXISTS idx_bookmarks_book ON bookmarks(book_id, chapter);

-- Reader annotations are independent of bookmarks: a chapter may contain any
-- number of notes and every note stays attached to the original byte range.
-- The sharing columns remain dormant until an account/community layer exists.
CREATE TABLE IF NOT EXISTS annotations (
    id         INTEGER PRIMARY KEY,
    book_id    INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter    INTEGER NOT NULL,
    start      INTEGER NOT NULL,
    end        INTEGER NOT NULL,
    quote      TEXT NOT NULL,
    body       TEXT NOT NULL,
    visibility TEXT NOT NULL DEFAULT 'private',
    sync_id    TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_annotations_book_position
    ON annotations(book_id, chapter, start);

-- Completion is an explicit event, never inferred from the latest chapter.
-- This prevents jumping to chapter 500 from marking chapters 1..499 as read.
CREATE TABLE IF NOT EXISTS completed_chapters (
    book_id      INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter      INTEGER NOT NULL,
    completed_at INTEGER NOT NULL,
    PRIMARY KEY (book_id, chapter)
);
CREATE INDEX IF NOT EXISTS idx_completed_chapters_book
    ON completed_chapters(book_id, chapter);

-- The semantic index: one row per retrieval chunk, holding the byte span it
-- covers and its embedding (unit vector, one i8 per dimension). Built by an
-- offline pass; absent until the reader asks for it, and a book without one
-- simply has no semantic search.
CREATE TABLE IF NOT EXISTS chunks (
    id      INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter INTEGER NOT NULL,
    start   INTEGER NOT NULL,
    end     INTEGER NOT NULL,
    vec     BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_book ON chunks(book_id, chapter);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 书源: one rule sheet per site, exactly as the user imported it. We keep the
-- original JSON rather than our parse of it, because the format has fields we
-- do not understand yet and throwing them away would corrupt the user's file.
-- `ok` is NULL until the source has been tested against a live site: a sheet
-- that parses is not a sheet that works.
-- 人物图谱, whole. Scanning 剑来 (41 MB, 1275 chapters) is not something to make
-- the reader wait through twice, so the built graph is kept verbatim and only
-- rebuilt when the book is re-indexed (`chapters` stops matching).
CREATE TABLE IF NOT EXISTS cast_cache (
    book_id  INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
    upto     INTEGER NOT NULL,
    chapters INTEGER NOT NULL,
    json     TEXT NOT NULL,
    built_at INTEGER NOT NULL
);

-- Coarse narrative focus. It scans the full decoded book, so the result is
-- cached and rebuilt only when the rule version or basic book shape changes.
CREATE TABLE IF NOT EXISTS narrative_focus (
    book_id     INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
    version     INTEGER NOT NULL,
    total_bytes INTEGER NOT NULL,
    chapters    INTEGER NOT NULL,
    career      TEXT NOT NULL,
    romance     TEXT NOT NULL,
    growth      TEXT NOT NULL,
    built_at    INTEGER NOT NULL
);

-- What the model decided about a candidate that the statistics could not place
-- (是人名 / 不是). Kept out of cast_cache so a rebuild does not throw away
-- judgements the reader already paid for.
CREATE TABLE IF NOT EXISTS name_verdicts (
    book_id   INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    name      TEXT NOT NULL,
    is_person INTEGER NOT NULL,
    PRIMARY KEY (book_id, name)
);

-- The model's prose summary of how a pair get on, keyed by the pair's names. A
-- closed-set label proved too lossy for the small model to pick stably (师徒 vs
-- 同门, and pairs that are both), so it writes a sentence instead. Same reasoning
-- as before: these outlive a rescan, and are keyed by name rather than row index
-- so they survive the cast shifting around.
CREATE TABLE IF NOT EXISTS relation_summaries (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    a       TEXT NOT NULL,
    b       TEXT NOT NULL,
    summary TEXT NOT NULL,
    PRIMARY KEY (book_id, a, b)
);

-- The model's prose account of who a character is, keyed by name. Same
-- reasoning as relation_summaries, and the same lifetime: written from the
-- person's own sampled sentences, kept out of cast_cache so a rescan does not
-- discard inference the reader already waited for.
CREATE TABLE IF NOT EXISTS person_summaries (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    name    TEXT NOT NULL,
    summary TEXT NOT NULL,
    PRIMARY KEY (book_id, name)
);

CREATE TABLE IF NOT EXISTS sources (
    url        TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    grp        TEXT,
    json       TEXT NOT NULL,
    enabled    INTEGER NOT NULL DEFAULT 1,
    ok         INTEGER,
    note       TEXT,
    checked_at INTEGER,
    added_at   INTEGER NOT NULL
);
"#;

/// When the same text is split differently, keep what is stored by chapter number
/// on the text it was about. `was` only holds chapters of a file of the same path
/// and size, so a byte still means the same byte. Chapters can merge as well as
/// divide, so two rows can want one chapter; none is dropped for that.
fn follow_split(
    tx: &rusqlite::Transaction,
    id: i64,
    was: &[(i64, i64, i64)],
    now: &[ChapterRecord],
) -> Result<Vec<(i64, i64)>> {
    let starts: Vec<i64> = now.iter().map(|c| c.start).collect();
    if was.is_empty()
        || (was.len() == now.len() && was.iter().zip(&starts).all(|((_, s, _), n)| s == n))
    {
        return Ok(Vec::new());
    }
    // The chapter holding a byte: the last one starting at or before it.
    let at = |offset: i64| starts.partition_point(|s| *s <= offset).saturating_sub(1) as i64;
    let shifted = |old: i64| (old + now.len() as i64 - was.len() as i64).max(0);
    let holding = |offset: i64, old: i64| {
        let span = was.iter().find(|(idx, _, _)| *idx == old);
        match span {
            Some((_, start, end)) if offset >= *start && offset < *end => at(offset),
            Some((_, start, _)) => at(*start),
            None => shifted(old),
        }
    };

    // Set aside first: rows move both ways now, and could land on one not yet moved.
    let mut marks: Vec<(i64, i64)> = {
        let mut st = tx.prepare("SELECT chapter, offset FROM bookmarks WHERE book_id = ?1")?;
        let rows = st.query_map([id], |r| {
            let (chapter, offset): (i64, i64) = (r.get(0)?, r.get(1)?);
            Ok((holding(offset, chapter), chapter))
        })?;
        rows.collect::<Result<_>>()?
    };
    tx.execute(
        "UPDATE bookmarks SET chapter = -1 - chapter WHERE book_id = ?1",
        [id],
    )?;
    marks.sort_unstable();
    // One bookmark to a chapter: a second one wanting it takes the next free one.
    // It still opens at its own offset.
    let mut taken = -1;
    for (wanted, old) in marks {
        taken = wanted.max(taken + 1);
        tx.execute(
            "UPDATE bookmarks SET chapter = ?3 WHERE book_id = ?1 AND chapter = -1 - ?2",
            params![id, old, taken],
        )?;
    }

    // A note and a chunk say which bytes they are about.
    for table in ["annotations", "chunks"] {
        tx.execute(
            &format!(
                "UPDATE {table} SET chapter = COALESCE(
                     (SELECT MAX(c.idx) FROM chapters c
                      WHERE c.book_id = ?1 AND c.start <= {table}.start), chapter)
                 WHERE book_id = ?1"
            ),
            [id],
        )?;
    }

    // A finished chapter is finished in all its parts.
    let done: Vec<(i64, i64)> = {
        let mut st = tx.prepare(
            "SELECT chapter, completed_at FROM completed_chapters WHERE book_id = ?1",
        )?;
        let rows = st.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<Result<_>>()?
    };
    tx.execute("DELETE FROM completed_chapters WHERE book_id = ?1", [id])?;
    for (old, when) in done {
        let parts: Vec<i64> = match was.iter().find(|(idx, _, _)| *idx == old) {
            Some((_, start, end)) => {
                let inside = starts.partition_point(|s| s < start)..starts.partition_point(|s| s < end);
                // Merged into the chapter before it: nothing of its own to mark.
                if inside.is_empty() {
                    vec![at(*start)]
                } else {
                    inside.map(|i| i as i64).collect()
                }
            }
            None => vec![shifted(old)],
        };
        for chapter in parts {
            tx.execute(
                "INSERT OR IGNORE INTO completed_chapters (book_id, chapter, completed_at)
                 VALUES (?1, ?2, ?3)",
                params![id, chapter, when],
            )?;
        }
    }

    // Reading stats keep their chapter by where the old one began.
    tx.execute(
        "UPDATE reading_windows SET chapter = -1 - chapter WHERE book_id = ?1",
        [id],
    )?;
    for (old, start, _) in was {
        tx.execute(
            "UPDATE reading_windows SET chapter = ?3 WHERE book_id = ?1 AND chapter = -1 - ?2",
            params![id, old, at(*start)],
        )?;
    }
    tx.execute(
        "UPDATE reading_windows SET chapter = -1 - chapter WHERE book_id = ?1 AND chapter < 0",
        [id],
    )?;

    Ok(was
        .iter()
        .map(|(old, _, end)| (*old, at(end - 1)))
        .filter(|(old, new)| old != new)
        .collect())
}

/// FNV-1a over the letters of a chapter's opening, ignoring punctuation and
/// whitespace so that a re-typeset edition of the same book still matches.
pub fn text_hash(body: &str) -> i64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for c in body.chars().filter(|c| c.is_alphanumeric()).take(120) {
        for b in (c as u32).to_le_bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
    }
    h as i64
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.execute_batch(SCHEMA)?;
        // Migration for libraries created before the column existed. SQLite has
        // no ADD COLUMN IF NOT EXISTS; the duplicate-column error is the signal
        // that there is nothing to do.
        let _ = conn.execute("ALTER TABLE books ADD COLUMN encoding_override TEXT", []);
        let _ = conn.execute("ALTER TABLE books ADD COLUMN custom_title TEXT", []);
        let _ = conn.execute("ALTER TABLE books ADD COLUMN pinned_at INTEGER", []);
        // Like custom_title: an override that survives re-import and, when cleared,
        // falls back to what the file itself said. cover_path points at an image
        // the reader chose; None means the generated glyph cover is used.
        let _ = conn.execute("ALTER TABLE books ADD COLUMN custom_author TEXT", []);
        let _ = conn.execute("ALTER TABLE books ADD COLUMN cover_path TEXT", []);
        // What a character background was written from ('summaries', 'mixed' or
        // 'sentences'; NULL for ones written before this was recorded) and how
        // many chapters had a summary at the time. Together they say when a
        // background could now be written from better material.
        let _ = conn.execute("ALTER TABLE person_summaries ADD COLUMN source TEXT", []);
        let _ = conn.execute("ALTER TABLE person_summaries ADD COLUMN basis INTEGER", []);
        // 前情提要 was removed from the product. Its old generated paragraphs
        // lived in settings as recap:<book>:<chapter>; discard that unreachable
        // cache during migration instead of leaving stale AI text behind.
        let _ = conn.execute("DELETE FROM settings WHERE key LIKE 'recap:%'", []);

        // Older reader builds could run a delayed scroll save after closing a
        // book. The chapter field had already been reset to zero while the
        // offset still pointed at the real reading position. Recover the narrow
        // "just closed, then reset" case once from the durable session log.
        let progress_repaired: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = 'progress_repair_v1'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        if progress_repaired.is_none() {
            let candidates: Vec<(i64, i64)> = {
                let mut st = conn.prepare(
                    "SELECT b.id, e.end_offset
                     FROM books b
                     JOIN reading_events e ON e.id = (
                         SELECT newest.id FROM reading_events newest
                         WHERE newest.book_id = b.id
                         ORDER BY newest.ended_at DESC, newest.id DESC LIMIT 1
                     )
                     WHERE b.last_chapter = 0 AND b.last_offset = 0
                       AND e.end_offset > 0
                       AND b.last_opened_at IS NOT NULL
                       AND b.last_opened_at - e.ended_at BETWEEN 0 AND 60",
                )?;
                let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                rows.collect::<Result<_>>()?
            };
            for (book_id, offset) in candidates {
                let chapter: Option<i64> = conn
                    .query_row(
                        "SELECT idx FROM chapters
                         WHERE book_id = ?1 AND start <= ?2
                         ORDER BY start DESC LIMIT 1",
                        params![book_id, offset],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(chapter) = chapter.filter(|chapter| *chapter > 0) {
                    conn.execute(
                        "UPDATE books SET last_chapter = ?2, last_offset = ?3 WHERE id = ?1",
                        params![book_id, chapter, offset],
                    )?;
                }
            }

            // Offset is the canonical reading anchor. Repair every older row
            // whose redundant chapter number disagrees with that anchor.
            let anchored: Vec<(i64, i64, i64)> = {
                let mut st = conn.prepare(
                    "SELECT id, last_chapter, last_offset FROM books
                     WHERE last_offset > 0",
                )?;
                let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
                rows.collect::<Result<_>>()?
            };
            for (book_id, saved_chapter, offset) in anchored {
                let actual_chapter: Option<i64> = conn
                    .query_row(
                        "SELECT idx FROM chapters
                         WHERE book_id = ?1 AND start <= ?2
                         ORDER BY start DESC LIMIT 1",
                        params![book_id, offset],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(actual_chapter) =
                    actual_chapter.filter(|chapter| *chapter != saved_chapter)
                {
                    conn.execute(
                        "UPDATE books SET last_chapter = ?2 WHERE id = ?1",
                        params![book_id, actual_chapter],
                    )?;
                }
            }
            conn.execute(
                "INSERT INTO settings (key, value) VALUES ('progress_repair_v1', 'done')",
                [],
            )?;
        }
        Ok(Store { conn })
    }

    /// Re-importing a book keeps its id, and therefore its reading history and
    /// its progress. Chapters are replaced wholesale, since the pipeline that
    /// produced them may have improved.
    /// Enrichment results (summaries etc.) survive the wholesale replacement by
    /// riding on `text_hash`: a chapter whose opening text is unchanged keeps
    /// what the model wrote for it, whatever its new index or offsets are. But
    /// not when a re-split of the same text cut it to under three quarters: what
    /// was written describes the whole of what it was, and starts it over.
    pub fn upsert_book(&mut self, b: &BookRecord, chapters: &[ChapterRecord]) -> Result<i64> {
        self.upsert_book_moved(b, chapters).map(|(id, _)| id)
    }

    /// [`Self::upsert_book`], also saying which chapter each old chapter's end
    /// now falls in when a better split cut old chapters up: (old, new), empty
    /// when the chapters did not move. What is stored by chapter number moves
    /// with them here; the caller moves what lives outside the database.
    pub fn upsert_book_moved(
        &mut self,
        b: &BookRecord,
        chapters: &[ChapterRecord],
    ) -> Result<(i64, Vec<(i64, i64)>)> {
        let tx = self.conn.transaction()?;
        let was: Vec<(i64, i64, i64)> = {
            let mut st = tx.prepare(
                "SELECT c.idx, c.start, c.end FROM chapters c JOIN books k ON k.id = c.book_id
                 WHERE k.path = ?1 AND k.total_bytes = ?2 ORDER BY c.idx",
            )?;
            let rows = st.query_map(params![b.path, b.total_bytes], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })?;
            rows.collect::<Result<_>>()?
        };
        tx.execute(
            "INSERT INTO books (path, title, author, encoding, style, total_bytes, chapter_count, added_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(path) DO UPDATE SET
                title=excluded.title, author=excluded.author, encoding=excluded.encoding,
                style=excluded.style, total_bytes=excluded.total_bytes,
                chapter_count=excluded.chapter_count",
            params![b.path, b.title, b.author, b.encoding, b.style, b.total_bytes, b.chapter_count, b.added_at],
        )?;
        let id: i64 = tx.query_row("SELECT id FROM books WHERE path = ?1", [&b.path], |r| {
            r.get(0)
        })?;

        let enriched: Vec<(
            i64,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            i64,
        )> = {
            let mut st = tx.prepare(
                "SELECT text_hash, summary, mood, entities, model_tag, end - body_start FROM chapters
                 WHERE book_id = ?1 AND (summary IS NOT NULL OR mood IS NOT NULL)",
            )?;
            let rows = st.query_map([id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))
            })?;
            rows.collect::<Result<_>>()?
        };

        tx.execute("DELETE FROM chapters WHERE book_id = ?1", [id])?;
        {
            let mut st = tx.prepare(
                "INSERT INTO chapters (book_id, idx, number, title, start, end, body_start, text_hash)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            )?;
            for c in chapters {
                st.execute(params![
                    id,
                    c.index,
                    c.number,
                    c.title,
                    c.start,
                    c.end,
                    c.body_start,
                    c.text_hash
                ])?;
            }
        }
        {
            let mut st = tx.prepare(
                "UPDATE chapters SET summary = ?3, mood = ?4, entities = ?5, model_tag = ?6
                 WHERE book_id = ?1 AND text_hash = ?2 AND summary IS NULL
                   AND (end - body_start) * 4 >= ?7 * 3",
            )?;
            // Another edition's lengths say nothing: only the same text is compared.
            for (hash, summary, mood, entities, tag, len) in &enriched {
                let was_len = if was.is_empty() { 0 } else { *len };
                st.execute(params![id, hash, summary, mood, entities, tag, was_len])?;
            }
        }
        let moved = follow_split(&tx, id, &was, chapters)?;
        tx.commit()?;
        Ok((id, moved))
    }

    pub fn library(&self) -> Result<Vec<BookRecord>> {
        let mut st = self.conn.prepare(
            "SELECT id, path, COALESCE(custom_title, title), COALESCE(custom_author, author), encoding, style, total_bytes, chapter_count,
                    added_at, last_opened_at, last_chapter, last_offset, pinned_at, genre_tags
             FROM books
             ORDER BY (pinned_at IS NULL), pinned_at DESC, COALESCE(last_opened_at, added_at) DESC",
        )?;
        let rows = st.query_map([], |r| {
            Ok(BookRecord {
                id: r.get(0)?,
                path: r.get(1)?,
                title: r.get(2)?,
                author: r.get(3)?,
                encoding: r.get(4)?,
                style: r.get(5)?,
                total_bytes: r.get(6)?,
                chapter_count: r.get(7)?,
                added_at: r.get(8)?,
                last_opened_at: r.get(9)?,
                last_chapter: r.get(10)?,
                last_offset: r.get(11)?,
                pinned_at: r.get(12)?,
                genre_tags: r.get(13)?,
            })
        })?;
        rows.collect()
    }

    /// What the lexicon made of this book. Written once — the text does not
    /// change under us, and re-scanning forty megabytes on every open would be
    /// paying for the same answer over and over.
    pub fn genre_tags(&self, book_id: i64) -> Result<Option<String>> {
        self.conn.query_row(
            "SELECT genre_tags FROM books WHERE id = ?1",
            [book_id],
            |r| r.get(0),
        )
    }

    /// Forget what we decided, so the next open decides again — used when the
    /// text itself changes under us, which happens exactly once: when the reader
    /// overrides the encoding.
    pub fn clear_genre_tags(&self, book_id: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET genre_tags = NULL WHERE id = ?1",
            [book_id],
        )?;
        Ok(())
    }

    pub fn set_genre_tags(&self, book_id: i64, tags: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET genre_tags = ?2 WHERE id = ?1",
            params![book_id, tags],
        )?;
        Ok(())
    }

    /// The pinned zone in user-dragged order: first id lands on top. Rewrites
    /// pinned_at as a descending rank 1..N, which keeps the zone a single
    /// ORDER BY — and a later 置顶 (stamped with now(), astronomically larger)
    /// still enters above everything hand-placed.
    pub fn set_pin_order(&mut self, ids: &[i64]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut st = tx.prepare("UPDATE books SET pinned_at = ?2 WHERE id = ?1")?;
            for (i, id) in ids.iter().enumerate() {
                st.execute(params![id, (ids.len() - i) as i64])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Pinned books hold the top of the shelf; recency sorts everything else
    /// underneath. The newest pin lands highest, which doubles as manual
    /// ordering: re-pin a book to lift it.
    pub fn set_pinned(&self, book_id: i64, pinned: bool) -> Result<()> {
        let at = pinned.then(now);
        self.conn.execute(
            "UPDATE books SET pinned_at = ?2 WHERE id = ?1",
            params![book_id, at],
        )?;
        Ok(())
    }

    /// User-chosen display name. The parsed title keeps living in `title`, so
    /// clearing the override restores it, and re-imports never clobber the choice
    /// (upsert only touches `title`).
    pub fn rename_book(&self, book_id: i64, custom: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET custom_title = ?2 WHERE id = ?1",
            params![book_id, custom],
        )?;
        Ok(())
    }

    pub fn custom_title(&self, book_id: i64) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT custom_title FROM books WHERE id = ?1",
                [book_id],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    /// User-chosen author, on the same terms as [`rename_book`]: the parsed
    /// author stays in `author`, so clearing the override restores it.
    pub fn set_author(&self, book_id: i64, custom: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET custom_author = ?2 WHERE id = ?1",
            params![book_id, custom],
        )?;
        Ok(())
    }

    /// Path to a reader-chosen cover image, or None to fall back to the generated
    /// cover. The image itself lives under the data dir; this only stores where.
    pub fn set_cover(&self, book_id: i64, path: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET cover_path = ?2 WHERE id = ?1",
            params![book_id, path],
        )?;
        Ok(())
    }

    pub fn custom_author(&self, book_id: i64) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT custom_author FROM books WHERE id = ?1",
                [book_id],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    pub fn cover_path(&self, book_id: i64) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT cover_path FROM books WHERE id = ?1",
                [book_id],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    /// Where the reader stopped, for one book.
    pub fn progress(&self, book_id: i64) -> Result<(i64, i64)> {
        self.conn.query_row(
            "SELECT last_chapter, last_offset FROM books WHERE id = ?1",
            [book_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
    }

    pub fn chapter_title(&self, book_id: i64, idx: i64) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT title FROM chapters WHERE book_id = ?1 AND idx = ?2",
                params![book_id, idx],
                |r| r.get(0),
            )
            .optional()
    }

    /// Resolve a durable byte position back to its chapter. The offset is the
    /// stronger anchor: it survives parser and paragraph-layout changes.
    pub fn chapter_at_offset(&self, book_id: i64, offset: i64) -> Result<Option<i64>> {
        self.conn
            .query_row(
                "SELECT idx FROM chapters
                 WHERE book_id = ?1 AND start <= ?2
                 ORDER BY start DESC LIMIT 1",
                params![book_id, offset],
                |r| r.get(0),
            )
            .optional()
    }

    /// Correct only the redundant chapter number without making the repair
    /// look like a new reading action.
    pub fn repair_progress_chapter(&self, book_id: i64, chapter: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET last_chapter = ?2 WHERE id = ?1",
            params![book_id, chapter],
        )?;
        Ok(())
    }

    pub fn save_progress(&self, book_id: i64, chapter: i64, offset: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET last_chapter = ?2, last_offset = ?3, last_opened_at = ?4 WHERE id = ?1",
            params![book_id, chapter, offset, now()],
        )?;
        Ok(())
    }

    pub fn bookmarks(&self, book_id: i64) -> Result<Vec<BookmarkRecord>> {
        let mut st = self.conn.prepare(
            "SELECT book_id, chapter, offset, comment, created_at, updated_at
             FROM bookmarks WHERE book_id = ?1 ORDER BY chapter",
        )?;
        let rows = st.query_map([book_id], |r| {
            Ok(BookmarkRecord {
                book_id: r.get(0)?,
                chapter: r.get(1)?,
                offset: r.get(2)?,
                comment: r.get(3)?,
                created_at: r.get(4)?,
                updated_at: r.get(5)?,
            })
        })?;
        rows.collect()
    }

    pub fn save_bookmark(
        &self,
        book_id: i64,
        chapter: i64,
        offset: i64,
        comment: Option<&str>,
    ) -> Result<()> {
        let now = now();
        self.conn.execute(
            "INSERT INTO bookmarks
                (book_id, chapter, offset, comment, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5)
             ON CONFLICT(book_id, chapter) DO UPDATE SET
                offset = excluded.offset,
                comment = excluded.comment,
                updated_at = excluded.updated_at",
            params![book_id, chapter, offset, comment, now],
        )?;
        Ok(())
    }

    pub fn delete_bookmark(&self, book_id: i64, chapter: i64) -> Result<()> {
        self.conn.execute(
            "DELETE FROM bookmarks WHERE book_id = ?1 AND chapter = ?2",
            params![book_id, chapter],
        )?;
        Ok(())
    }

    pub fn annotations(&self, book_id: i64) -> Result<Vec<AnnotationRecord>> {
        let mut st = self.conn.prepare(
            "SELECT id, book_id, chapter, start, end, quote, body, visibility,
                    sync_id, created_at, updated_at
             FROM annotations WHERE book_id = ?1
             ORDER BY chapter, start, created_at",
        )?;
        let rows = st.query_map([book_id], |r| {
            Ok(AnnotationRecord {
                id: r.get(0)?,
                book_id: r.get(1)?,
                chapter: r.get(2)?,
                start: r.get(3)?,
                end: r.get(4)?,
                quote: r.get(5)?,
                body: r.get(6)?,
                visibility: r.get(7)?,
                sync_id: r.get(8)?,
                created_at: r.get(9)?,
                updated_at: r.get(10)?,
            })
        })?;
        rows.collect()
    }

    pub fn save_annotation(
        &self,
        id: Option<i64>,
        book_id: i64,
        chapter: i64,
        start: i64,
        end: i64,
        quote: &str,
        body: &str,
    ) -> Result<i64> {
        let now = now();
        if let Some(id) = id {
            self.conn.execute(
                "UPDATE annotations SET body = ?3, updated_at = ?4
                 WHERE id = ?1 AND book_id = ?2",
                params![id, book_id, body, now],
            )?;
            return Ok(id);
        }
        self.conn.execute(
            "INSERT INTO annotations
                (book_id, chapter, start, end, quote, body, visibility,
                 sync_id, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'private', NULL, ?7, ?7)",
            params![book_id, chapter, start, end, quote, body, now],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn delete_annotation(&self, book_id: i64, annotation_id: i64) -> Result<()> {
        self.conn.execute(
            "DELETE FROM annotations WHERE id = ?1 AND book_id = ?2",
            params![annotation_id, book_id],
        )?;
        Ok(())
    }

    pub fn completed_chapters(&self, book_id: i64) -> Result<Vec<i64>> {
        let mut st = self.conn.prepare(
            "SELECT chapter FROM completed_chapters
             WHERE book_id = ?1 ORDER BY chapter",
        )?;
        let rows = st.query_map([book_id], |r| r.get(0))?;
        rows.collect()
    }

    pub fn mark_chapter_completed(&self, book_id: i64, chapter: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO completed_chapters (book_id, chapter, completed_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(book_id, chapter) DO UPDATE SET
                completed_at = excluded.completed_at",
            params![book_id, chapter, now()],
        )?;
        Ok(())
    }

    pub fn log_event(
        &self,
        book_id: i64,
        started: i64,
        ended: i64,
        from: i64,
        to: i64,
    ) -> Result<()> {
        // A session with no movement is a session where the reader walked away.
        if ended <= started || to == from {
            return Ok(());
        }
        self.conn.execute(
            "INSERT INTO reading_events (book_id, started_at, ended_at, start_offset, end_offset)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![book_id, started, ended, from, to],
        )?;
        Ok(())
    }

    pub fn remove_book(&self, book_id: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM books WHERE id = ?1", [book_id])?;
        Ok(())
    }

    /// The same book, now read from another file: everything hangs off the id,
    /// so only the path changes.
    pub fn move_book(&self, book_id: i64, path: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET path = ?2 WHERE id = ?1",
            params![book_id, path],
        )?;
        Ok(())
    }

    /// The TXT this book was read from. Needed to delete a book properly: the
    /// row goes with a cascade, the file has to be gone after by hand.
    pub fn book_path(&self, book_id: i64) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT path FROM books WHERE id = ?1", [book_id], |r| {
                r.get(0)
            })
            .optional()?)
    }

    /// Where the reader was, translated onto a freshly imported edition of the
    /// same book whose byte offsets have all moved. Matches the chapter by the
    /// hash of its opening text; falls back to the chapter index.
    pub fn realign(&self, book_id: i64, old_hash: i64, old_index: i64) -> Result<Option<i64>> {
        let by_hash: Option<i64> = self
            .conn
            .query_row(
                "SELECT idx FROM chapters WHERE book_id = ?1 AND text_hash = ?2 LIMIT 1",
                params![book_id, old_hash],
                |r| r.get(0),
            )
            .optional()?;
        Ok(by_hash.or(Some(old_index)))
    }

    /// Raw sessions since a cutoff. Day-bucketing happens in the UI, which knows
    /// the local timezone; unix seconds do not.
    pub fn events_since(&self, since: i64) -> Result<Vec<(i64, i64, i64)>> {
        let mut st = self.conn.prepare(
            "SELECT book_id, started_at, ended_at FROM reading_events
             WHERE started_at >= ?1 ORDER BY started_at",
        )?;
        let rows = st.query_map([since], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }

    /// One window of reading speed. Kept as written, idle and hunting included —
    /// see the table's comment.
    pub fn log_window(
        &self,
        book_id: i64,
        chapter: i64,
        started: i64,
        secs: i64,
        chars: i64,
    ) -> Result<()> {
        if secs <= 0 {
            return Ok(());
        }
        self.conn.execute(
            "INSERT INTO reading_windows (book_id, chapter, started_at, secs, chars)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![book_id, chapter, started, secs, chars.max(0)],
        )?;
        Ok(())
    }

    pub fn windows_since(&self, since: i64) -> Result<Vec<crate::reading_stats::Window>> {
        let mut st = self.conn.prepare(
            "SELECT book_id, chapter, started_at, secs, chars FROM reading_windows
             WHERE started_at >= ?1 ORDER BY started_at",
        )?;
        let rows = st.query_map([since], |r| {
            Ok(crate::reading_stats::Window {
                book_id: r.get(0)?,
                chapter: r.get(1)?,
                started: r.get(2)?,
                secs: r.get(3)?,
                chars: r.get(4)?,
            })
        })?;
        rows.collect()
    }

    /// Chapters the reader finished — seen from first line to last, see
    /// `completed_chapters` — and the bytes of body text in them.
    pub fn finished_chapters(&self) -> Result<(i64, i64)> {
        self.conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(c.end - c.body_start), 0)
             FROM completed_chapters d
             JOIN chapters c ON c.book_id = d.book_id AND c.idx = d.chapter",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
    }

    pub fn annotation_count(&self) -> Result<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM annotations", [], |r| r.get(0))
    }

    /// Total reading time per book, most-read first.
    pub fn time_per_book(&self) -> Result<Vec<(String, i64)>> {
        let mut st = self.conn.prepare(
            "SELECT COALESCE(b.custom_title, b.title), SUM(e.ended_at - e.started_at) AS t
             FROM reading_events e JOIN books b ON b.id = e.book_id
             GROUP BY e.book_id ORDER BY t DESC",
        )?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect()
    }

    /// The user's encoding choice for this file, if they made one. Keyed by path
    /// because it is needed *before* the book is decoded and upserted.
    pub fn encoding_override(&self, path: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT encoding_override FROM books WHERE path = ?1",
                [path],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
    }

    pub fn set_encoding_override(&self, book_id: i64, encoding: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE books SET encoding_override = ?2 WHERE id = ?1",
            params![book_id, encoding],
        )?;
        Ok(())
    }

    /// Chapters the enrichment pass has not finished, in reading order, with
    /// which pieces are still missing — a re-run only pays for those.
    /// Tuple: (idx, title, needs_summary, needs_mood). A missing mood only
    /// counts as unfinished while the pass still writes moods (`with_mood`);
    /// otherwise every summarised chapter would be revisited forever.
    pub fn chapters_needing_enrich(
        &self,
        book_id: i64,
        with_mood: bool,
    ) -> Result<Vec<(i64, String, bool, bool)>> {
        let mut st = self.conn.prepare(
            "SELECT idx, title, summary IS NULL, mood IS NULL FROM chapters
             WHERE book_id = ?1 AND (summary IS NULL OR (?2 AND mood IS NULL)) ORDER BY idx",
        )?;
        let rows = st.query_map(params![book_id, with_mood], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?;
        rows.collect()
    }

    /// Write whichever enrichment pieces this pass produced. A `None` leaves
    /// the stored value alone, so summary and mood can arrive in different
    /// runs without erasing each other.
    pub fn set_chapter_ai(
        &self,
        book_id: i64,
        idx: i64,
        summary: Option<&str>,
        mood: Option<&str>,
        model_tag: &str,
    ) -> Result<()> {
        self.conn.execute(
            "UPDATE chapters SET summary = COALESCE(?3, summary), mood = COALESCE(?4, mood),
                    model_tag = ?5
             WHERE book_id = ?1 AND idx = ?2",
            params![book_id, idx, summary, mood, model_tag],
        )?;
        Ok(())
    }

    pub fn chapter_summaries(&self, book_id: i64) -> Result<Vec<(i64, String)>> {
        let mut st = self.conn.prepare(
            "SELECT idx, summary FROM chapters
             WHERE book_id = ?1 AND summary IS NOT NULL ORDER BY idx",
        )?;
        let rows = st.query_map([book_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect()
    }

    pub fn chapter_moods(&self, book_id: i64) -> Result<Vec<(i64, String)>> {
        let mut st = self.conn.prepare(
            "SELECT idx, mood FROM chapters
             WHERE book_id = ?1 AND mood IS NOT NULL ORDER BY idx",
        )?;
        let rows = st.query_map([book_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect()
    }

    pub fn chapter_summary(&self, book_id: i64, idx: i64) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT summary FROM chapters WHERE book_id = ?1 AND idx = ?2",
                params![book_id, idx],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
    }

    /// Chapters that already carry index chunks. Indexing a long book takes
    /// minutes; knowing what is done makes it resumable, and a re-run after a
    /// crash picks up where it stopped instead of re-embedding the whole book.
    pub fn indexed_chapters(&self, book_id: i64) -> Result<Vec<i64>> {
        let mut st = self
            .conn
            .prepare("SELECT DISTINCT chapter FROM chunks WHERE book_id = ?1 ORDER BY chapter")?;
        let rows = st.query_map([book_id], |r| r.get(0))?;
        rows.collect()
    }

    /// Replace one chapter's chunks. Per chapter, not per book, so that an
    /// interrupted index leaves finished chapters intact rather than half a
    /// chapter's worth of vectors behind.
    pub fn set_chunks(
        &mut self,
        book_id: i64,
        chapter: i64,
        rows: &[(i64, i64, Vec<u8>)],
    ) -> Result<()> {
        let tx = self.conn.transaction()?;
        tx.execute(
            "DELETE FROM chunks WHERE book_id = ?1 AND chapter = ?2",
            params![book_id, chapter],
        )?;
        {
            let mut st = tx.prepare(
                "INSERT INTO chunks (book_id, chapter, start, end, vec) VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;
            for (start, end, vec) in rows {
                st.execute(params![book_id, chapter, start, end, vec])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Every indexed chunk up to and including chapter `up_to`.
    pub fn chunk_vectors(&self, book_id: i64, up_to: i64) -> Result<Vec<(i64, i64, i64, Vec<u8>)>> {
        let mut st = self.conn.prepare(
            "SELECT chapter, start, end, vec FROM chunks
             WHERE book_id = ?1 AND chapter <= ?2",
        )?;
        let rows = st.query_map(params![book_id, up_to], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?;
        rows.collect()
    }

    pub fn drop_index(&self, book_id: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM chunks WHERE book_id = ?1", [book_id])?;
        Ok(())
    }

    /// The cached 人物图谱, if one was built for this many chapters. A mismatch
    /// means the book was re-indexed under it and the graph is stale.
    pub fn cast_cache(&self, book_id: i64, upto: i64, chapters: i64) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT json FROM cast_cache
                 WHERE book_id = ?1 AND upto = ?2 AND chapters = ?3",
                params![book_id, upto, chapters],
                |r| r.get(0),
            )
            .optional()
    }

    pub fn set_cast_cache(&self, book_id: i64, upto: i64, chapters: i64, json: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO cast_cache (book_id, upto, chapters, json, built_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(book_id) DO UPDATE SET
                 upto = ?2, chapters = ?3, json = ?4, built_at = ?5",
            params![book_id, upto, chapters, json, now()],
        )?;
        Ok(())
    }

    pub fn narrative_focus(
        &self,
        book_id: i64,
        version: i64,
        total_bytes: i64,
        chapters: i64,
    ) -> Result<Option<(String, String, String)>> {
        self.conn
            .query_row(
                "SELECT career, romance, growth FROM narrative_focus
                 WHERE book_id = ?1 AND version = ?2
                   AND total_bytes = ?3 AND chapters = ?4",
                params![book_id, version, total_bytes, chapters],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()
    }

    pub fn set_narrative_focus(
        &self,
        book_id: i64,
        version: i64,
        total_bytes: i64,
        chapters: i64,
        career: &str,
        romance: &str,
        growth: &str,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO narrative_focus
                (book_id, version, total_bytes, chapters, career, romance, growth, built_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(book_id) DO UPDATE SET
                 version = ?2, total_bytes = ?3, chapters = ?4,
                 career = ?5, romance = ?6, growth = ?7, built_at = ?8",
            params![
                book_id,
                version,
                total_bytes,
                chapters,
                career,
                romance,
                growth,
                now()
            ],
        )?;
        Ok(())
    }

    /// Model verdicts on borderline candidates: name → is it a person.
    pub fn name_verdicts(&self, book_id: i64) -> Result<Vec<(String, bool)>> {
        let mut st = self
            .conn
            .prepare("SELECT name, is_person FROM name_verdicts WHERE book_id = ?1")?;
        let rows = st.query_map([book_id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? != 0))
        })?;
        rows.collect()
    }

    pub fn set_name_verdict(&self, book_id: i64, name: &str, is_person: bool) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO name_verdicts (book_id, name, is_person)
             VALUES (?1, ?2, ?3)",
            params![book_id, name, i64::from(is_person)],
        )?;
        Ok(())
    }

    /// Model-written relationship summaries, keyed by the pair's names.
    pub fn relation_summaries(&self, book_id: i64) -> Result<Vec<(String, String, String)>> {
        let mut st = self
            .conn
            .prepare("SELECT a, b, summary FROM relation_summaries WHERE book_id = ?1")?;
        let rows = st.query_map([book_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }

    pub fn set_relation_summary(
        &self,
        book_id: i64,
        a: &str,
        b: &str,
        summary: &str,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO relation_summaries (book_id, a, b, summary) VALUES (?1, ?2, ?3, ?4)",
            params![book_id, a, b, summary],
        )?;
        Ok(())
    }

    /// Model-written character backgrounds, keyed by name.
    pub fn person_summaries(&self, book_id: i64) -> Result<Vec<(String, String)>> {
        let mut st = self
            .conn
            .prepare("SELECT name, summary FROM person_summaries WHERE book_id = ?1")?;
        let rows = st.query_map([book_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect()
    }

    /// What each background was written from: (name, source, basis). See the
    /// migration in [`Store::open`].
    pub fn person_summary_sources(
        &self,
        book_id: i64,
    ) -> Result<Vec<(String, Option<String>, Option<i64>)>> {
        let mut st = self
            .conn
            .prepare("SELECT name, source, basis FROM person_summaries WHERE book_id = ?1")?;
        let rows = st.query_map([book_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }

    pub fn set_person_summary(
        &self,
        book_id: i64,
        name: &str,
        summary: &str,
        source: &str,
        basis: i64,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO person_summaries (book_id, name, summary, source, basis)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![book_id, name, summary, source, basis],
        )?;
        Ok(())
    }

    /// Throw away everything derived for one book's graph — the reader's 重置.
    pub fn drop_cast(&self, book_id: i64) -> Result<()> {
        for t in [
            "cast_cache",
            "name_verdicts",
            "relation_summaries",
            "person_summaries",
        ] {
            self.conn
                .execute(&format!("DELETE FROM {t} WHERE book_id = ?1"), [book_id])?;
        }
        Ok(())
    }

    /// Forget everything the model wrote about a book, keeping the book. The
    /// chapters themselves stay: they are the cut, not the AI's opinion of it.
    pub fn drop_summaries(&self, book_id: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE chapters SET summary = NULL, mood = NULL, entities = NULL, model_tag = NULL
             WHERE book_id = ?1",
            [book_id],
        )?;
        Ok(())
    }

    /// The reading log — the one thing here that cannot be rebuilt. Summaries
    /// and vectors can be recomputed from the file; a session that happened last
    /// March cannot.
    pub fn clear_events(&self) -> Result<()> {
        self.conn.execute("DELETE FROM reading_events", [])?;
        self.conn.execute("DELETE FROM reading_windows", [])?;
        Ok(())
    }

    /// What each book has cost in derived data. The user paid minutes of CPU for
    /// it and it is theirs to throw away, so the page offering to delete it has
    /// to be able to say how much there is.
    pub fn storage(&self) -> Result<Vec<BookStorage>> {
        let mut st = self.conn.prepare(
            "SELECT b.id, COALESCE(b.custom_title, b.title), b.chapter_count,
                    (SELECT COUNT(*) FROM chapters c WHERE c.book_id = b.id AND c.summary IS NOT NULL),
                    (SELECT COALESCE(SUM(LENGTH(c.summary)), 0) FROM chapters c WHERE c.book_id = b.id),
                    (SELECT COUNT(*) FROM chunks k WHERE k.book_id = b.id),
                    (SELECT COALESCE(SUM(LENGTH(k.vec)), 0) FROM chunks k WHERE k.book_id = b.id)
             FROM books b
             ORDER BY COALESCE(b.last_opened_at, b.added_at) DESC",
        )?;
        let rows = st.query_map([], |r| {
            Ok(BookStorage {
                book_id: r.get(0)?,
                title: r.get(1)?,
                chapter_count: r.get(2)?,
                summaries: r.get(3)?,
                summary_bytes: r.get(4)?,
                chunks: r.get(5)?,
                chunk_bytes: r.get(6)?,
            })
        })?;
        rows.collect()
    }

    /// Reclaim the pages a deletion freed. SQLite keeps them for reuse
    /// otherwise, so the file on disk would not shrink and the number the
    /// settings page just quoted would be a lie.
    pub fn vacuum(&self) -> Result<()> {
        self.conn.execute_batch("VACUUM")?;
        Ok(())
    }

    /// Store a rule sheet, keeping any test verdict a previous import earned.
    pub fn upsert_source(&self, s: &SourceRecord) -> Result<()> {
        self.conn.execute(
            "INSERT INTO sources (url, name, grp, json, enabled, added_at)
             VALUES (?1, ?2, ?3, ?4, 1, ?5)
             ON CONFLICT(url) DO UPDATE SET
                 name = excluded.name, grp = excluded.grp, json = excluded.json",
            params![s.url, s.name, s.group, s.json, now()],
        )?;
        Ok(())
    }

    pub fn sources(&self) -> Result<Vec<SourceRecord>> {
        let mut st = self.conn.prepare(
            "SELECT url, name, grp, json, enabled, ok, note FROM sources
             ORDER BY (ok IS NOT 1), name",
        )?;
        let rows = st.query_map([], |r| {
            Ok(SourceRecord {
                url: r.get(0)?,
                name: r.get(1)?,
                group: r.get(2)?,
                json: r.get(3)?,
                enabled: r.get::<_, i64>(4)? != 0,
                ok: r.get(5)?,
                note: r.get(6)?,
            })
        })?;
        rows.collect()
    }

    pub fn set_source_enabled(&self, url: &str, on: bool) -> Result<()> {
        self.conn.execute(
            "UPDATE sources SET enabled = ?2 WHERE url = ?1",
            params![url, on as i64],
        )?;
        Ok(())
    }

    /// What happened when we last made the source prove itself.
    pub fn set_source_test(&self, url: &str, ok: bool, note: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE sources SET ok = ?2, note = ?3, checked_at = ?4 WHERE url = ?1",
            params![url, ok as i64, note, now()],
        )?;
        Ok(())
    }

    pub fn delete_source(&self, url: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM sources WHERE url = ?1", [url])?;
        Ok(())
    }

    /// Delete many. One statement per row would be one transaction per row, and
    /// the lists people delete from are thousands long.
    pub fn delete_sources(&self, urls: &[String]) -> Result<usize> {
        let tx = self.conn.unchecked_transaction()?;
        let mut n = 0;
        {
            let mut st = tx.prepare("DELETE FROM sources WHERE url = ?1")?;
            for u in urls {
                n += st.execute([u])?;
            }
        }
        tx.commit()?;
        Ok(n)
    }

    pub fn clear_sources(&self) -> Result<usize> {
        Ok(self.conn.execute("DELETE FROM sources", [])?)
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        self.conn
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem() -> Store {
        Store::open(Path::new(":memory:")).unwrap()
    }

    fn book(path: &str) -> BookRecord {
        BookRecord {
            id: 0,
            path: path.into(),
            title: "书".into(),
            author: None,
            encoding: "UTF-8".into(),
            style: "Indent".into(),
            total_bytes: 100,
            chapter_count: 2,
            added_at: 1,
            last_opened_at: None,
            last_chapter: 0,
            last_offset: 0,
            pinned_at: None,
            genre_tags: None,
        }
    }

    #[test]
    fn the_index_never_returns_chapters_the_reader_has_not_reached() {
        let mut s = mem();
        let id = s
            .upsert_book(&book("/a.txt"), &[chapter(0, 1), chapter(1, 2)])
            .unwrap();
        s.set_chunks(id, 0, &[(0, 10, vec![1, 2])]).unwrap();
        s.set_chunks(id, 5, &[(50, 60, vec![3, 4])]).unwrap();

        let seen = s.chunk_vectors(id, 0).unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].0, 0);
        assert_eq!(s.chunk_vectors(id, 5).unwrap().len(), 2);
        assert_eq!(s.indexed_chapters(id).unwrap(), vec![0, 5]);
    }

    #[test]
    fn reindexing_a_chapter_replaces_only_that_chapter() {
        let mut s = mem();
        let id = s.upsert_book(&book("/a.txt"), &[chapter(0, 1)]).unwrap();
        s.set_chunks(id, 0, &[(0, 10, vec![1]), (10, 20, vec![2])])
            .unwrap();
        s.set_chunks(id, 1, &[(20, 30, vec![3])]).unwrap();
        s.set_chunks(id, 0, &[(0, 20, vec![9])]).unwrap();

        let all = s.chunk_vectors(id, 9).unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all.iter().filter(|c| c.0 == 0).count(), 1);
        assert_eq!(all.iter().filter(|c| c.0 == 1).count(), 1);
    }

    fn chapter(idx: i64, hash: i64) -> ChapterRecord {
        ChapterRecord {
            index: idx,
            number: None,
            title: format!("第{idx}章"),
            start: idx * 10,
            end: idx * 10 + 10,
            body_start: idx * 10 + 2,
            text_hash: hash,
        }
    }

    /// 陈二狗's shape: chapter 1 turns out to hold five more. What was stored by
    /// chapter number stays on the same text, and a later chapter's rows follow.
    #[test]
    fn a_finer_split_keeps_everything_on_the_same_text() {
        let span = |index, start, end| ChapterRecord {
            index,
            number: None,
            title: format!("{start}"),
            start,
            end,
            body_start: start,
            text_hash: start,
        };
        let mut s = mem();
        let old = [span(0, 0, 10), span(1, 10, 70), span(2, 70, 100)];
        let id = s.upsert_book(&book("/a.txt"), &old).unwrap();
        s.save_bookmark(id, 1, 45, None).unwrap();
        s.save_bookmark(id, 2, 75, None).unwrap();
        s.mark_chapter_completed(id, 1).unwrap();
        s.mark_chapter_completed(id, 2).unwrap();
        s.log_window(id, 2, 100, 30, 300).unwrap();
        let note = s.save_annotation(None, id, 2, 80, 85, "原文", "批注").unwrap();
        s.conn
            .execute(
                "INSERT INTO chunks (book_id, chapter, start, end, vec) VALUES (?1, 1, 50, 60, x'00')",
                [id],
            )
            .unwrap();

        let new = [
            span(0, 0, 10),
            span(1, 10, 30),
            span(2, 30, 40),
            span(3, 40, 60),
            span(4, 60, 70),
            span(5, 70, 100),
        ];
        let (same, moved) = s.upsert_book_moved(&book("/a.txt"), &new).unwrap();
        assert_eq!(same, id);
        assert_eq!(moved, vec![(1, 4), (2, 5)]);

        let marks: Vec<(i64, i64)> = s
            .bookmarks(id)
            .unwrap()
            .iter()
            .map(|b| (b.chapter, b.offset))
            .collect();
        assert_eq!(marks, vec![(3, 45), (5, 75)]);
        assert_eq!(s.completed_chapters(id).unwrap(), vec![1, 2, 3, 4, 5]);
        assert_eq!(s.windows_since(0).unwrap()[0].chapter, 5);
        let notes = s.annotations(id).unwrap();
        assert_eq!((notes[0].id, notes[0].chapter), (note, 5));
        let chunk: i64 = s
            .conn
            .query_row("SELECT chapter FROM chunks WHERE book_id = ?1", [id], |r| r.get(0))
            .unwrap();
        assert_eq!(chunk, 3);

        // Opening it again changes nothing.
        assert!(s.upsert_book_moved(&book("/a.txt"), &new).unwrap().1.is_empty());
        assert_eq!(s.completed_chapters(id).unwrap(), vec![1, 2, 3, 4, 5]);

        // The other way, chapters merging, everything comes back.
        s.upsert_book_moved(&book("/a.txt"), &old).unwrap();
        let marks: Vec<(i64, i64)> = s
            .bookmarks(id)
            .unwrap()
            .iter()
            .map(|b| (b.chapter, b.offset))
            .collect();
        assert_eq!(marks, vec![(1, 45), (2, 75)]);
        assert_eq!(s.completed_chapters(id).unwrap(), vec![1, 2]);
        assert_eq!(s.windows_since(0).unwrap()[0].chapter, 2);
        assert_eq!(s.annotations(id).unwrap()[0].chapter, 2);
    }

    /// 冬日重现's 53 KB chapter cut to 10 KB kept the sentence written about all of
    /// it, and with a summary there nothing would ever write another.
    #[test]
    fn a_summary_does_not_stay_on_a_chapter_cut_short() {
        let span = |index: i64, start: i64, end: i64| ChapterRecord {
            index,
            number: None,
            title: format!("{index}"),
            start,
            end,
            body_start: start,
            text_hash: start,
        };
        let summary = |s: &Store, id: i64, idx: i64| -> Option<String> {
            s.conn
                .query_row(
                    "SELECT summary FROM chapters WHERE book_id = ?1 AND idx = ?2",
                    params![id, idx],
                    |r| r.get(0),
                )
                .unwrap()
        };
        let mut s = mem();
        let old = [span(0, 0, 100), span(1, 100, 200), span(2, 200, 300)];
        let id = s.upsert_book(&book("/a.txt"), &old).unwrap();
        for idx in 0..3 {
            s.set_chapter_ai(id, idx, Some("概览"), None, "m").unwrap();
        }

        // The first is cut to a fifth, the second loses a little, the third stays.
        let new = [span(0, 0, 20), span(1, 20, 100), span(2, 100, 180), span(3, 200, 300)];
        s.upsert_book(&book("/a.txt"), &new).unwrap();
        assert_eq!(summary(&s, id, 0), None);
        assert_eq!(summary(&s, id, 2).as_deref(), Some("概览"));
        assert_eq!(summary(&s, id, 3).as_deref(), Some("概览"));
        assert_eq!(s.chapters_needing_enrich(id, false).unwrap().len(), 2);

        // Another edition: lengths differ for no reason to do with the chapter.
        let mut other = book("/a.txt");
        other.total_bytes += 1;
        let shorter = [span(0, 0, 20), span(1, 20, 50), span(2, 100, 110), span(3, 200, 210)];
        s.upsert_book(&other, &shorter).unwrap();
        assert_eq!(summary(&s, id, 2).as_deref(), Some("概览"));
    }

    /// A chapter merged away and a chapter split in the same re-split, with a
    /// bookmark on each of the two that become one. Neither may be lost.
    #[test]
    fn a_split_that_is_no_refinement_keeps_every_row() {
        let span = |index: i64, start: i64, end: i64| ChapterRecord {
            index,
            number: None,
            title: format!("{index}"),
            start,
            end,
            body_start: start,
            text_hash: start,
        };
        let mut s = mem();
        let old = [span(0, 0, 50), span(1, 50, 60), span(2, 60, 100)];
        let id = s.upsert_book(&book("/a.txt"), &old).unwrap();
        s.save_bookmark(id, 0, 20, None).unwrap();
        s.save_bookmark(id, 1, 55, None).unwrap();
        s.save_bookmark(id, 2, 90, None).unwrap();
        s.mark_chapter_completed(id, 1).unwrap();
        s.mark_chapter_completed(id, 2).unwrap();

        // 1 merges into 0; 2 is cut in two.
        let new = [span(0, 0, 60), span(1, 60, 80), span(2, 80, 100)];
        let (_, moved) = s.upsert_book_moved(&book("/a.txt"), &new).unwrap();
        assert_eq!(moved, vec![(1, 0)]);
        let marks: Vec<(i64, i64)> = s
            .bookmarks(id)
            .unwrap()
            .iter()
            .map(|b| (b.chapter, b.offset))
            .collect();
        assert_eq!(marks, vec![(0, 20), (1, 55), (2, 90)]);
        assert_eq!(s.completed_chapters(id).unwrap(), vec![0, 1, 2]);
    }

    #[test]
    fn speed_windows_are_kept_raw_and_go_with_the_book_or_the_clear_button() {
        let mut s = mem();
        let a = s.upsert_book(&book("/a.txt"), &[chapter(0, 1)]).unwrap();
        let b = s.upsert_book(&book("/b.txt"), &[chapter(0, 2)]).unwrap();
        s.log_window(a, 0, 100, 30, 300).unwrap();
        s.log_window(a, 0, 130, 600, 4).unwrap(); // idle is written too
        s.log_window(b, 0, 200, 30, 250).unwrap();
        s.log_window(b, 0, 230, 0, 10).unwrap(); // no time, nothing to keep
        assert_eq!(s.windows_since(0).unwrap().len(), 3);
        assert_eq!(s.windows_since(150).unwrap().len(), 1);

        s.remove_book(a).unwrap();
        let left = s.windows_since(0).unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].book_id, b);

        s.clear_events().unwrap();
        assert!(s.windows_since(0).unwrap().is_empty());
    }

    #[test]
    fn finished_chapters_count_their_body_text() {
        let mut s = mem();
        let id = s
            .upsert_book(&book("/a.txt"), &[chapter(0, 1), chapter(1, 2)])
            .unwrap();
        assert_eq!(s.finished_chapters().unwrap(), (0, 0));
        s.mark_chapter_completed(id, 1).unwrap();
        assert_eq!(s.finished_chapters().unwrap(), (1, 8));
    }

    #[test]
    fn a_byte_offset_resolves_the_real_chapter_for_progress_repair() {
        let mut s = mem();
        let id = s
            .upsert_book(
                &book("a.txt"),
                &[chapter(0, 11), chapter(1, 22), chapter(2, 33)],
            )
            .unwrap();

        assert_eq!(s.chapter_at_offset(id, 0).unwrap(), Some(0));
        assert_eq!(s.chapter_at_offset(id, 19).unwrap(), Some(1));
        assert_eq!(s.chapter_at_offset(id, 20).unwrap(), Some(2));

        s.save_progress(id, 0, 25).unwrap();
        s.repair_progress_chapter(id, 2).unwrap();
        assert_eq!(s.progress(id).unwrap(), (2, 25));
    }

    #[test]
    fn backgrounds_written_before_sources_were_recorded_survive_the_migration() {
        let path =
            std::env::temp_dir().join(format!("novel-store-migration-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        {
            let old = Connection::open(&path).unwrap();
            old.execute_batch(
                "CREATE TABLE person_summaries (
                     book_id INTEGER NOT NULL, name TEXT NOT NULL,
                     summary TEXT NOT NULL, PRIMARY KEY (book_id, name));
                 INSERT INTO person_summaries VALUES (1, '克莱恩', '旧的背景');",
            )
            .unwrap();
        }
        let mut s = Store::open(&path).unwrap();
        let id = s.upsert_book(&book("a.txt"), &[chapter(0, 1)]).unwrap();
        assert_eq!(id, 1);
        assert_eq!(
            s.person_summaries(id).unwrap(),
            vec![("克莱恩".to_string(), "旧的背景".to_string())]
        );
        assert_eq!(
            s.person_summary_sources(id).unwrap(),
            vec![("克莱恩".to_string(), None, None)]
        );

        s.set_person_summary(id, "克莱恩", "新的背景", "summaries", 1392)
            .unwrap();
        assert_eq!(
            s.person_summary_sources(id).unwrap(),
            vec![(
                "克莱恩".to_string(),
                Some("summaries".to_string()),
                Some(1392)
            )]
        );
        drop(s);
        for ext in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{ext}", path.display()));
        }
    }

    #[test]
    fn summaries_survive_reimport() {
        let mut s = mem();
        let id = s
            .upsert_book(&book("a.txt"), &[chapter(0, 111), chapter(1, 222)])
            .unwrap();
        s.set_chapter_ai(id, 0, Some("主角进山采药遇险"), Some("紧张"), "qwen3-0.6b")
            .unwrap();

        // Re-import: chapter 0's opening text unchanged (same hash) but shifted;
        // chapter 1 was re-segmented into different text (new hash).
        let id2 = s
            .upsert_book(&book("a.txt"), &[chapter(0, 111), chapter(1, 999)])
            .unwrap();
        assert_eq!(id, id2, "same path keeps its id");
        assert_eq!(
            s.chapter_summary(id, 0).unwrap().as_deref(),
            Some("主角进山采药遇险")
        );
        assert_eq!(s.chapter_moods(id).unwrap(), vec![(0, "紧张".to_string())]);
        assert_eq!(s.chapter_summary(id, 1).unwrap(), None);
        assert_eq!(s.chapters_needing_enrich(id, true).unwrap().len(), 1);
    }

    #[test]
    fn partial_enrich_keeps_the_other_half() {
        let mut s = mem();
        let id = s.upsert_book(&book("a.txt"), &[chapter(0, 111)]).unwrap();
        s.set_chapter_ai(id, 0, Some("摘要"), None, "m").unwrap();
        s.set_chapter_ai(id, 0, None, Some("轻松"), "m").unwrap();
        assert_eq!(s.chapter_summary(id, 0).unwrap().as_deref(), Some("摘要"));
        assert_eq!(s.chapter_moods(id).unwrap(), vec![(0, "轻松".to_string())]);
        assert!(s.chapters_needing_enrich(id, true).unwrap().is_empty());
    }

    #[test]
    fn a_missing_mood_alone_is_not_unfinished_once_moods_are_off() {
        let mut s = mem();
        let id = s
            .upsert_book(&book("a.txt"), &[chapter(0, 111), chapter(1, 222)])
            .unwrap();
        s.set_chapter_ai(id, 0, Some("摘要"), None, "m").unwrap();
        let todo = s.chapters_needing_enrich(id, false).unwrap();
        assert_eq!(todo.iter().map(|t| t.0).collect::<Vec<_>>(), vec![1]);
        assert_eq!(s.chapters_needing_enrich(id, true).unwrap().len(), 2);
    }

    #[test]
    fn narrative_focus_cache_is_invalidated_by_rules_or_book_shape() {
        let mut s = mem();
        let id = s.upsert_book(&book("a.txt"), &[chapter(0, 111)]).unwrap();
        s.set_narrative_focus(id, 1, 100, 1, "较少", "中等", "很多")
            .unwrap();

        assert_eq!(
            s.narrative_focus(id, 1, 100, 1).unwrap(),
            Some(("较少".into(), "中等".into(), "很多".into()))
        );
        assert!(s.narrative_focus(id, 2, 100, 1).unwrap().is_none());
        assert!(s.narrative_focus(id, 1, 101, 1).unwrap().is_none());
        assert!(s.narrative_focus(id, 1, 100, 2).unwrap().is_none());
    }

    #[test]
    fn a_chapter_bookmark_keeps_one_position_and_optional_comment() {
        let mut s = mem();
        let id = s
            .upsert_book(&book("a.txt"), &[chapter(0, 111), chapter(1, 222)])
            .unwrap();

        s.save_bookmark(id, 1, 14, Some("重要转折")).unwrap();
        let first = s.bookmarks(id).unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].chapter, 1);
        assert_eq!(first[0].offset, 14);
        assert_eq!(first[0].comment.as_deref(), Some("重要转折"));

        s.save_bookmark(id, 1, 18, None).unwrap();
        let edited = s.bookmarks(id).unwrap();
        assert_eq!(edited.len(), 1, "saving the same chapter edits its mark");
        assert_eq!(edited[0].offset, 18);
        assert_eq!(edited[0].comment, None);

        s.delete_bookmark(id, 1).unwrap();
        assert!(s.bookmarks(id).unwrap().is_empty());
    }

    #[test]
    fn annotations_allow_multiple_notes_in_one_chapter_and_edit_by_id() {
        let mut s = mem();
        let id = s
            .upsert_book(&book("a.txt"), &[chapter(0, 111), chapter(1, 222)])
            .unwrap();

        let first = s
            .save_annotation(None, id, 1, 12, 18, "原文一", "想法一")
            .unwrap();
        let second = s
            .save_annotation(None, id, 1, 21, 29, "原文二", "想法二")
            .unwrap();
        assert_ne!(first, second);
        assert_eq!(s.annotations(id).unwrap().len(), 2);

        s.save_annotation(Some(first), id, 1, 12, 18, "原文一", "修改后")
            .unwrap();
        let notes = s.annotations(id).unwrap();
        assert_eq!(notes[0].body, "修改后");
        assert_eq!(notes[1].body, "想法二");

        s.delete_annotation(id, first).unwrap();
        assert_eq!(s.annotations(id).unwrap().len(), 1);
    }

    #[test]
    fn completed_chapters_are_explicit_and_never_fill_the_gap() {
        let mut s = mem();
        let id = s
            .upsert_book(
                &book("a.txt"),
                &[chapter(0, 11), chapter(1, 22), chapter(2, 33)],
            )
            .unwrap();

        s.mark_chapter_completed(id, 2).unwrap();
        assert_eq!(s.completed_chapters(id).unwrap(), vec![2]);
        s.mark_chapter_completed(id, 0).unwrap();
        assert_eq!(s.completed_chapters(id).unwrap(), vec![0, 2]);
    }

    #[test]
    fn shelf_summary_is_scoped_to_one_book_and_one_chapter() {
        let mut s = mem();
        let a = s
            .upsert_book(&book("a.txt"), &[chapter(0, 11), chapter(1, 22)])
            .unwrap();
        let b = s.upsert_book(&book("b.txt"), &[chapter(0, 11)]).unwrap();
        s.set_chapter_ai(a, 1, Some("第二章的介绍"), None, "test")
            .unwrap();
        assert_eq!(
            s.chapter_summary(a, 1).unwrap().as_deref(),
            Some("第二章的介绍")
        );
        assert_eq!(s.chapter_summary(a, 0).unwrap(), None);
        assert_eq!(s.chapter_summary(b, 0).unwrap(), None);
        assert_eq!(s.chapter_summary(a, 99).unwrap(), None);
        s.drop_summaries(a).unwrap();
        assert_eq!(s.chapter_summary(a, 1).unwrap(), None);
    }

    #[test]
    fn drag_order_rules_the_pinned_zone() {
        let mut s = mem();
        let a = s.upsert_book(&book("a.txt"), &[]).unwrap();
        let b = s.upsert_book(&book("b.txt"), &[]).unwrap();
        let c = s.upsert_book(&book("c.txt"), &[]).unwrap();
        s.save_progress(c, 1, 10).unwrap(); // c is the recent, unpinned one
        s.set_pin_order(&[b, a]).unwrap();
        let ids: Vec<i64> = s.library().unwrap().iter().map(|r| r.id).collect();
        assert_eq!(ids, vec![b, a, c], "dragged order on top, recency below");
    }

    #[test]
    fn pinned_books_stay_on_top() {
        let mut s = mem();
        let a = s.upsert_book(&book("a.txt"), &[]).unwrap();
        let b = s.upsert_book(&book("b.txt"), &[]).unwrap();
        // b was read last, so it leads — until a is pinned.
        s.save_progress(b, 1, 10).unwrap();
        assert_eq!(s.library().unwrap()[0].id, b);
        s.set_pinned(a, true).unwrap();
        assert_eq!(s.library().unwrap()[0].id, a);
        s.set_pinned(a, false).unwrap();
        assert_eq!(s.library().unwrap()[0].id, b);
    }
}
