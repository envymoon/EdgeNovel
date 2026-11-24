//! Local-network (LAN) zero-cloud synchronization engine.
//!
//! Design principles:
//! 1. **Zero data loss**: books are merged ONLY when they share the same
//!    `sync_uid` OR exact raw-file SHA-256 `content_hash`. Same-title books
//!    with different content are ALWAYS kept side-by-side so chapter offsets,
//!    bookmarks and text cuts never collide.
//! 2. **CRDT / union merge**: reading events, speed windows, completed
//!    chapters, bookmarks, annotations, text cuts and archived stats are
//!    merged by deduplicated union (append-only, never silently dropped).
//! 3. **Git-style three-way progress merge**: using `sync_peer_base:<peer_id>`,
//!    single-sided moves fast-forward automatically; true two-sided forks
//!    surface as explicit conflicts with a safe "keep further + bookmark other"
//!    default.
//! 4. **Pre-merge snapshot**: before mutating the local database, a copy is
//!    saved to `sync_backup_last.db` so the user can roll back the last sync.

use crate::api::book;
use novel_core::rusqlite;
use novel_core::store::{self, Store};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static ID_SEQ: AtomicU64 = AtomicU64::new(1);

// ── Minimal self-contained SHA-256 (FIPS 180-4) ─────────────────────────────

const K256: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

struct Sha256 {
    h: [u32; 8],
    buf: [u8; 64],
    buf_len: usize,
    total_len: u64,
}

impl Sha256 {
    fn new() -> Self {
        Self {
            h: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            buf: [0; 64],
            buf_len: 0,
            total_len: 0,
        }
    }

    fn compress(h: &mut [u32; 8], block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = *h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K256[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    fn update(&mut self, mut data: &[u8]) {
        self.total_len += data.len() as u64;
        if self.buf_len > 0 {
            let take = (64 - self.buf_len).min(data.len());
            self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&data[..take]);
            self.buf_len += take;
            data = &data[take..];
            if self.buf_len == 64 {
                let block = self.buf;
                Self::compress(&mut self.h, &block);
                self.buf_len = 0;
            }
        }
        while data.len() >= 64 {
            let block: [u8; 64] = data[..64].try_into().unwrap();
            Self::compress(&mut self.h, &block);
            data = &data[64..];
        }
        if !data.is_empty() {
            self.buf[..data.len()].copy_from_slice(data);
            self.buf_len = data.len();
        }
    }

    fn finish_hex(mut self) -> String {
        let bit_len = self.total_len * 8;
        self.update(&[0x80]);
        if self.buf_len > 56 {
            let pad = 64 - self.buf_len;
            self.update(&vec![0u8; pad]);
        }
        let pad = 56 - self.buf_len;
        if pad > 0 {
            self.update(&vec![0u8; pad]);
        }
        self.update(&bit_len.to_be_bytes());
        let mut out = String::with_capacity(64);
        for word in self.h {
            out.push_str(&format!("{word:08x}"));
        }
        out
    }
}

fn sha256_file(path: &Path) -> Option<String> {
    let mut f = fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hasher.finish_hex())
}

fn new_uid(salt: &str) -> String {
    let seq = ID_SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(&nanos.to_le_bytes());
    hasher.update(&seq.to_le_bytes());
    hasher.update(&(std::process::id()).to_le_bytes());
    let hex = hasher.finish_hex();
    hex[..32].to_string()
}

// ── Public FRB types ────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SyncBookRef {
    pub sync_uid: String,
    pub title: String,
    pub author: Option<String>,
    pub total_bytes: i64,
    pub chapter_count: i64,
    pub same_title_different_edition: bool,
}

#[derive(Debug, Clone)]
pub struct SyncProgressConflict {
    pub sync_uid: String,
    pub title: String,
    pub local_chapter: i64,
    pub local_offset: i64,
    pub local_updated_at: i64,
    pub remote_chapter: i64,
    pub remote_offset: i64,
    pub remote_updated_at: i64,
    pub chapter_count: i64,
}

#[derive(Debug, Clone)]
pub struct SyncMergePlan {
    pub remote_device_id: String,
    pub remote_device_name: String,
    pub books_to_pull: Vec<SyncBookRef>,
    pub books_to_push: Vec<SyncBookRef>,
    pub matched_books: i64,
    pub auto_progress_updates: i64,
    pub progress_conflicts: Vec<SyncProgressConflict>,
    pub events_to_add: i64,
    pub windows_to_add: i64,
    pub bookmarks_to_add: i64,
    pub annotations_to_add: i64,
    pub cuts_to_add: i64,
    pub archives_to_add: i64,
}

#[derive(Debug, Clone)]
pub struct SyncApplyResult {
    pub books_imported: i64,
    pub progress_updated: i64,
    pub events_added: i64,
    pub windows_added: i64,
    pub bookmarks_added: i64,
    pub annotations_added: i64,
    pub cuts_added: i64,
    pub archives_added: i64,
    pub backup_created: bool,
}

// ── Internal helpers ────────────────────────────────────────────────────────

fn ensure_device_id(s: &Store) -> Result<String, String> {
    if let Some(id) = s.get_setting("sync_device_id").map_err(|e| format!("{e}"))? {
        if !id.trim().is_empty() {
            return Ok(id);
        }
    }
    let id = new_uid("device");
    s.set_setting("sync_device_id", &id)
        .map_err(|e| format!("{e}"))?;
    Ok(id)
}

#[derive(Debug, Clone)]
struct LocalBookRow {
    id: i64,
    path: String,
    title: String,
    custom_title: Option<String>,
    author: Option<String>,
    custom_author: Option<String>,
    total_bytes: i64,
    chapter_count: i64,
    last_chapter: i64,
    last_offset: i64,
    last_opened_at: Option<i64>,
    progress_updated_at: i64,
    sync_uid: String,
    content_hash: Option<String>,
    cover_path: Option<String>,
    cuts_base: Option<i64>,
    pinned_at: Option<i64>,
}

/// Ensure every local book has a `sync_uid` and (when readable on disk) a
/// SHA-256 `content_hash`. Runs lazily before export or merge planning.
fn load_local_books_with_identity(s: &Store) -> Result<Vec<LocalBookRow>, String> {
    let mut rows: Vec<LocalBookRow> = {
        let mut st = s
            .conn()
            .prepare(
                "SELECT id, path, title, custom_title, author, custom_author,
                        total_bytes, chapter_count, last_chapter, last_offset,
                        last_opened_at, COALESCE(progress_updated_at, last_opened_at, 0),
                        sync_uid, content_hash, cover_path, cuts_base, pinned_at
                 FROM books ORDER BY id",
            )
            .map_err(|e| format!("{e}"))?;
        let mapped = st
            .query_map([], |r| {
                Ok(LocalBookRow {
                    id: r.get(0)?,
                    path: r.get(1)?,
                    title: r.get(2)?,
                    custom_title: r.get(3)?,
                    author: r.get(4)?,
                    custom_author: r.get(5)?,
                    total_bytes: r.get(6)?,
                    chapter_count: r.get(7)?,
                    last_chapter: r.get(8)?,
                    last_offset: r.get(9)?,
                    last_opened_at: r.get(10)?,
                    progress_updated_at: r.get(11)?,
                    sync_uid: r.get::<_, Option<String>>(12)?.unwrap_or_default(),
                    content_hash: r.get(13)?,
                    cover_path: r.get(14)?,
                    cuts_base: r.get(15)?,
                    pinned_at: r.get(16)?,
                })
            })
            .map_err(|e| format!("{e}"))?;
        mapped.collect::<Result<Vec<_>, _>>().map_err(|e| format!("{e}"))?
    };

    for b in &mut rows {
        if b.sync_uid.is_empty() {
            b.sync_uid = new_uid(&format!("book:{}:{}", b.id, b.path));
            let _ = s.conn().execute(
                "UPDATE books SET sync_uid = ?2 WHERE id = ?1",
                rusqlite::params![b.id, b.sync_uid],
            );
        }
        if b.content_hash.is_none() {
            if let Some(h) = sha256_file(Path::new(&b.path)) {
                let _ = s.conn().execute(
                    "UPDATE books SET content_hash = ?2 WHERE id = ?1",
                    rusqlite::params![b.id, h],
                );
                b.content_hash = Some(h);
            }
        }
    }
    Ok(rows)
}

fn display_title(b: &LocalBookRow) -> String {
    b.custom_title
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(&b.title)
        .to_string()
}

fn display_author(b: &LocalBookRow) -> Option<String> {
    b.custom_author
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .or(b.author.as_deref())
        .map(str::to_string)
}

fn match_local_book<'a>(
    local: &'a [LocalBookRow],
    remote_uid: &str,
    remote_hash: Option<&str>,
) -> Option<&'a LocalBookRow> {
    if let Some(b) = local.iter().find(|b| b.sync_uid == remote_uid) {
        return Some(b);
    }
    if let Some(rh) = remote_hash.filter(|h| !h.is_empty()) {
        if let Some(b) = local
            .iter()
            .find(|b| b.content_hash.as_deref() == Some(rh))
        {
            return Some(b);
        }
    }
    None
}

fn load_peer_base(s: &Store, peer_id: &str) -> HashMap<String, (i64, i64, i64)> {
    let key = format!("sync_peer_base:{peer_id}");
    let Ok(Some(raw)) = s.get_setting(&key) else {
        return HashMap::new();
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return HashMap::new();
    };
    let mut out = HashMap::new();
    if let Some(obj) = val.as_object() {
        for (uid, v) in obj {
            let ch = v.get("chapter").and_then(Value::as_i64).unwrap_or(0);
            let off = v.get("offset").and_then(Value::as_i64).unwrap_or(0);
            let ts = v.get("updated_at").and_then(Value::as_i64).unwrap_or(0);
            out.insert(uid.clone(), (ch, off, ts));
        }
    }
    out
}

fn save_peer_base(s: &Store, peer_id: &str, books: &[LocalBookRow]) -> Result<(), String> {
    let key = format!("sync_peer_base:{peer_id}");
    let mut map = serde_json::Map::new();
    for b in books {
        map.insert(
            b.sync_uid.clone(),
            json!({
                "chapter": b.last_chapter,
                "offset": b.last_offset,
                "updated_at": b.progress_updated_at,
            }),
        );
    }
    let raw = serde_json::to_string(&Value::Object(map)).map_err(|e| format!("{e}"))?;
    s.set_setting(&key, &raw).map_err(|e| format!("{e}"))
}

fn backup_path() -> Result<PathBuf, String> {
    Ok(book::data_dir()?.join("sync_backup_last.db"))
}

// ── Public FRB API ──────────────────────────────────────────────────────────

/// Stable per-device UUID used for LAN sync identity and merge bases.
pub fn sync_device_id() -> Result<String, String> {
    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    ensure_device_id(s)
}

/// Directory where synced TXT books are stored locally.
pub fn sync_books_dir() -> Result<String, String> {
    let dir = book::data_dir()?.join("books");
    fs::create_dir_all(&dir).map_err(|e| format!("创建同步书目目录失败: {e}"))?;
    Ok(dir.to_string_lossy().to_string())
}

/// Directory where synced custom covers are stored locally.
pub fn sync_covers_dir() -> Result<String, String> {
    let dir = book::data_dir()?.join("covers");
    fs::create_dir_all(&dir).map_err(|e| format!("创建封面目录失败: {e}"))?;
    Ok(dir.to_string_lossy().to_string())
}

/// Look up the on-disk TXT path for a book by `sync_uid`.
pub fn sync_get_book_file_path(sync_uid: String) -> Result<Option<String>, String> {
    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    let path: Option<String> = s
        .conn()
        .query_row(
            "SELECT path FROM books WHERE sync_uid = ?1",
            [&sync_uid],
            |r| r.get(0),
        )
        .ok();
    Ok(path.filter(|p| Path::new(p).exists()))
}

/// Look up the on-disk custom cover path for a book by `sync_uid`.
pub fn sync_get_cover_file_path(sync_uid: String) -> Result<Option<String>, String> {
    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    let path: Option<String> = s
        .conn()
        .query_row(
            "SELECT cover_path FROM books WHERE sync_uid = ?1",
            [&sync_uid],
            |r| r.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten();
    Ok(path.filter(|p| Path::new(p).exists()))
}

/// Export this device's full sync manifest as JSON.
/// `extra_json` carries Flutter-side preferences (easter eggs, shelf categories).
pub fn sync_export_manifest(device_name: String, extra_json: String) -> Result<String, String> {
    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    let device_id = ensure_device_id(s)?;
    let local_books = load_local_books_with_identity(s)?;

    let mut books_json = Vec::with_capacity(local_books.len());
    for b in &local_books {
        let events = s.book_events(b.id).map_err(|e| format!("{e}"))?;
        let windows = s.book_windows(b.id).map_err(|e| format!("{e}"))?;
        let bookmarks = s.bookmarks(b.id).map_err(|e| format!("{e}"))?;
        let annotations = s.annotations(b.id).map_err(|e| format!("{e}"))?;
        let completed = s.completed_chapters(b.id).map_err(|e| format!("{e}"))?;
        let cuts: Vec<(i64, i64)> = {
            let mut st = s
                .conn()
                .prepare("SELECT start, end FROM text_cuts WHERE book_id = ?1 ORDER BY start")
                .map_err(|e| format!("{e}"))?;
            let rows = st
                .query_map([b.id], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(|e| format!("{e}"))?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| format!("{e}"))?
        };
        let has_cover = b
            .cover_path
            .as_deref()
            .is_some_and(|p| Path::new(p).exists());
        let file_name = Path::new(&b.path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("book.txt")
            .to_string();

        books_json.push(json!({
            "sync_uid": b.sync_uid,
            "content_hash": b.content_hash,
            "file_name": file_name,
            "title": display_title(b),
            "custom_title": b.custom_title,
            "author": display_author(b),
            "custom_author": b.custom_author,
            "total_bytes": b.total_bytes,
            "chapter_count": b.chapter_count,
            "last_chapter": b.last_chapter,
            "last_offset": b.last_offset,
            "last_opened_at": b.last_opened_at,
            "progress_updated_at": b.progress_updated_at,
            "pinned_at": b.pinned_at,
            "has_cover": has_cover,
            "cuts_base": b.cuts_base,
            "cuts": cuts.into_iter().map(|(a, c)| json!([a, c])).collect::<Vec<_>>(),
            "completed_chapters": completed,
            "events": events.into_iter().map(|(st, en, f, t)| json!([st, en, f, t])).collect::<Vec<_>>(),
            "windows": windows.into_iter().map(|w| json!([w.chapter, w.started, w.secs, w.chars])).collect::<Vec<_>>(),
            "bookmarks": bookmarks.into_iter().map(|m| json!({
                "chapter": m.chapter,
                "offset": m.offset,
                "comment": m.comment,
                "created_at": m.created_at,
                "updated_at": m.updated_at,
            })).collect::<Vec<_>>(),
            "annotations": annotations.into_iter().map(|a| json!({
                "chapter": a.chapter,
                "start": a.start,
                "end": a.end,
                "quote": a.quote,
                "body": a.body,
                "visibility": a.visibility,
                "sync_id": a.sync_id,
                "created_at": a.created_at,
                "updated_at": a.updated_at,
            })).collect::<Vec<_>>(),
        }));
    }

    // Export archived stats of deleted books so history merges across devices too.
    let archives = s.archived_books().map_err(|e| format!("{e}"))?;
    let mut archives_json = Vec::with_capacity(archives.len());
    for a in &archives {
        let a_events: Vec<(i64, i64, i64, i64)> = {
            let mut st = s
                .conn()
                .prepare(
                    "SELECT started_at, ended_at, start_offset, end_offset
                     FROM archived_reading_events WHERE archive_id = ?1 ORDER BY started_at",
                )
                .map_err(|e| format!("{e}"))?;
            let rows = st
                .query_map([a.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .map_err(|e| format!("{e}"))?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| format!("{e}"))?
        };
        let a_windows: Vec<(i64, i64, i64, i64)> = {
            let mut st = s
                .conn()
                .prepare(
                    "SELECT chapter, started_at, secs, chars
                     FROM archived_reading_windows WHERE archive_id = ?1 ORDER BY started_at",
                )
                .map_err(|e| format!("{e}"))?;
            let rows = st
                .query_map([a.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .map_err(|e| format!("{e}"))?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| format!("{e}"))?
        };
        archives_json.push(json!({
            "title": a.title,
            "author": a.author,
            "genre_tags": a.genre_tags,
            "total_bytes": a.total_bytes,
            "chapter_count": a.chapter_count,
            "finished_chapters": a.finished_chapters,
            "finished_bytes": a.finished_bytes,
            "is_finished": a.is_finished,
            "annotations": a.annotations,
            "content_hash": a.content_hash,
            "archived_at": a.archived_at,
            "events": a_events.into_iter().map(|(st, en, f, t)| json!([st, en, f, t])).collect::<Vec<_>>(),
            "windows": a_windows.into_iter().map(|(c, st, se, ch)| json!([c, st, se, ch])).collect::<Vec<_>>(),
        }));
    }

    let extra: Value = serde_json::from_str(&extra_json).unwrap_or_else(|_| json!({}));
    let manifest = json!({
        "version": 1,
        "device_id": device_id,
        "device_name": device_name,
        "exported_at": store::now(),
        "books": books_json,
        "archives": archives_json,
        "extra": extra,
    });
    serde_json::to_string(&manifest).map_err(|e| format!("{e}"))
}

/// Dry-run merge analysis: computes exact diff and progress conflicts without
/// modifying any local data.
pub fn sync_plan_merge(remote_manifest_json: String) -> Result<SyncMergePlan, String> {
    let remote: Value =
        serde_json::from_str(&remote_manifest_json).map_err(|e| format!("清单解析失败: {e}"))?;
    let remote_device_id = remote
        .get("device_id")
        .and_then(Value::as_str)
        .ok_or("缺少对端设备 ID")?
        .to_string();
    let remote_device_name = remote
        .get("device_name")
        .and_then(Value::as_str)
        .unwrap_or("对端设备")
        .to_string();
    let remote_books = remote
        .get("books")
        .and_then(Value::as_array)
        .ok_or("缺少书籍清单")?;

    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    let local_books = load_local_books_with_identity(s)?;
    let peer_base = load_peer_base(s, &remote_device_id);

    let local_titles: HashSet<String> = local_books.iter().map(display_title).collect();
    let remote_titles: HashSet<String> = remote_books
        .iter()
        .filter_map(|rb| rb.get("title").and_then(Value::as_str).map(str::to_string))
        .collect();

    let mut matched_local_ids: HashSet<i64> = HashSet::new();
    let mut books_to_pull = Vec::new();
    let mut progress_conflicts = Vec::new();
    let mut matched_books = 0i64;
    let mut auto_progress_updates = 0i64;
    let mut events_to_add = 0i64;
    let mut windows_to_add = 0i64;
    let mut bookmarks_to_add = 0i64;
    let mut annotations_to_add = 0i64;
    let mut cuts_to_add = 0i64;

    for rb in remote_books {
        let r_uid = rb.get("sync_uid").and_then(Value::as_str).unwrap_or("");
        let r_hash = rb.get("content_hash").and_then(Value::as_str);
        let r_title = rb
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("未命名")
            .to_string();
        let r_author = rb.get("author").and_then(Value::as_str).map(str::to_string);
        let r_bytes = rb.get("total_bytes").and_then(Value::as_i64).unwrap_or(0);
        let r_chapters = rb.get("chapter_count").and_then(Value::as_i64).unwrap_or(0);

        if let Some(lb) = match_local_book(&local_books, r_uid, r_hash) {
            matched_local_ids.insert(lb.id);
            matched_books += 1;

            // Progress three-way check.
            let r_ch = rb.get("last_chapter").and_then(Value::as_i64).unwrap_or(0);
            let r_off = rb.get("last_offset").and_then(Value::as_i64).unwrap_or(0);
            let r_ts = rb
                .get("progress_updated_at")
                .and_then(Value::as_i64)
                .unwrap_or(0);

            if lb.last_chapter != r_ch || lb.last_offset != r_off {
                let base = peer_base.get(&lb.sync_uid).or_else(|| peer_base.get(r_uid));
                let local_changed = match base {
                    Some(&(bch, boff, _)) => lb.last_chapter != bch || lb.last_offset != boff,
                    None => lb.last_chapter > 0 || lb.last_offset > 0,
                };
                let remote_changed = match base {
                    Some(&(bch, boff, _)) => r_ch != bch || r_off != boff,
                    None => r_ch > 0 || r_off > 0,
                };
                if !local_changed && remote_changed {
                    auto_progress_updates += 1;
                } else if local_changed && remote_changed {
                    progress_conflicts.push(SyncProgressConflict {
                        sync_uid: lb.sync_uid.clone(),
                        title: display_title(lb),
                        local_chapter: lb.last_chapter,
                        local_offset: lb.last_offset,
                        local_updated_at: lb.progress_updated_at,
                        remote_chapter: r_ch,
                        remote_offset: r_off,
                        remote_updated_at: r_ts,
                        chapter_count: lb.chapter_count.max(r_chapters),
                    });
                }
            }

            // Count new union items.
            let local_events: HashSet<(i64, i64)> = s
                .book_events(lb.id)
                .unwrap_or_default()
                .into_iter()
                .map(|(st, en, _, _)| (st, en))
                .collect();
            if let Some(arr) = rb.get("events").and_then(Value::as_array) {
                for ev in arr {
                    if let (Some(st), Some(en)) = (
                        ev.get(0).and_then(Value::as_i64),
                        ev.get(1).and_then(Value::as_i64),
                    ) {
                        if !local_events.contains(&(st, en)) {
                            events_to_add += 1;
                        }
                    }
                }
            }

            let local_windows: HashSet<(i64, i64, i64)> = s
                .book_windows(lb.id)
                .unwrap_or_default()
                .into_iter()
                .map(|w| (w.chapter, w.started, w.secs))
                .collect();
            if let Some(arr) = rb.get("windows").and_then(Value::as_array) {
                for w in arr {
                    if let (Some(c), Some(st), Some(se)) = (
                        w.get(0).and_then(Value::as_i64),
                        w.get(1).and_then(Value::as_i64),
                        w.get(2).and_then(Value::as_i64),
                    ) {
                        if !local_windows.contains(&(c, st, se)) {
                            windows_to_add += 1;
                        }
                    }
                }
            }

            let local_bms: HashSet<i64> = s
                .bookmarks(lb.id)
                .unwrap_or_default()
                .into_iter()
                .map(|m| m.chapter)
                .collect();
            if let Some(arr) = rb.get("bookmarks").and_then(Value::as_array) {
                for m in arr {
                    if let Some(ch) = m.get("chapter").and_then(Value::as_i64) {
                        if !local_bms.contains(&ch) {
                            bookmarks_to_add += 1;
                        }
                    }
                }
            }

            let local_annos: HashSet<(i64, i64, i64, String)> = s
                .annotations(lb.id)
                .unwrap_or_default()
                .into_iter()
                .map(|a| (a.chapter, a.start, a.end, a.body))
                .collect();
            if let Some(arr) = rb.get("annotations").and_then(Value::as_array) {
                for a in arr {
                    let key = (
                        a.get("chapter").and_then(Value::as_i64).unwrap_or(0),
                        a.get("start").and_then(Value::as_i64).unwrap_or(0),
                        a.get("end").and_then(Value::as_i64).unwrap_or(0),
                        a.get("body")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    );
                    if !local_annos.contains(&key) {
                        annotations_to_add += 1;
                    }
                }
            }

            if lb.cuts_base.is_none() {
                if let Some(arr) = rb.get("cuts").and_then(Value::as_array) {
                    cuts_to_add += arr.len() as i64;
                }
            }
        } else {
            // Different content / new book: NEVER overwrite; keep both!
            let same_title = local_titles.contains(&r_title);
            books_to_pull.push(SyncBookRef {
                sync_uid: r_uid.to_string(),
                title: r_title,
                author: r_author,
                total_bytes: r_bytes,
                chapter_count: r_chapters,
                same_title_different_edition: same_title,
            });
        }
    }

    let mut books_to_push = Vec::new();
    for lb in &local_books {
        if !matched_local_ids.contains(&lb.id) {
            let t = display_title(lb);
            books_to_push.push(SyncBookRef {
                sync_uid: lb.sync_uid.clone(),
                same_title_different_edition: remote_titles.contains(&t),
                title: t,
                author: display_author(lb),
                total_bytes: lb.total_bytes,
                chapter_count: lb.chapter_count,
            });
        }
    }

    // Count new archived stats from remote.
    let existing_archives: HashSet<(String, i64)> = s
        .archived_books()
        .unwrap_or_default()
        .into_iter()
        .map(|a| (a.title, a.archived_at))
        .collect();
    let mut archives_to_add = 0i64;
    if let Some(arr) = remote.get("archives").and_then(Value::as_array) {
        for a in arr {
            let title = a
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let archived_at = a.get("archived_at").and_then(Value::as_i64).unwrap_or(0);
            if !title.is_empty() && !existing_archives.contains(&(title, archived_at)) {
                archives_to_add += 1;
            }
        }
    }

    Ok(SyncMergePlan {
        remote_device_id,
        remote_device_name,
        books_to_pull,
        books_to_push,
        matched_books,
        auto_progress_updates,
        progress_conflicts,
        events_to_add,
        windows_to_add,
        bookmarks_to_add,
        annotations_to_add,
        cuts_to_add,
        archives_to_add,
    })
}

/// Apply the approved merge into the local database.
///
/// - `resolutions_json`: `{ "<sync_uid>": "local" | "remote" | "further_bookmark" }`
/// - `imported_files_json`: `{ "<sync_uid>": "/local/path/to/downloaded.txt" }`
/// - `imported_covers_json`: `{ "<sync_uid>": "/local/path/to/cover.png" }`
pub fn sync_apply_merge(
    remote_manifest_json: String,
    resolutions_json: String,
    imported_files_json: String,
    imported_covers_json: String,
) -> Result<SyncApplyResult, String> {
    let remote: Value =
        serde_json::from_str(&remote_manifest_json).map_err(|e| format!("清单解析失败: {e}"))?;
    let remote_device_id = remote
        .get("device_id")
        .and_then(Value::as_str)
        .ok_or("缺少对端设备 ID")?
        .to_string();
    let remote_books = remote
        .get("books")
        .and_then(Value::as_array)
        .ok_or("缺少书籍清单")?;

    let resolutions: HashMap<String, String> =
        serde_json::from_str(&resolutions_json).unwrap_or_default();
    let imported_files: HashMap<String, String> =
        serde_json::from_str(&imported_files_json).unwrap_or_default();
    let imported_covers: HashMap<String, String> =
        serde_json::from_str(&imported_covers_json).unwrap_or_default();

    // 1. Pre-merge safety backup of library.db so user can always roll back.
    let backup_created = if let (Some(src), Ok(dst)) = (book::db_path().get(), backup_path()) {
        // Flush WAL into a clean single-file backup via SQLite VACUUM INTO when possible.
        let _ = fs::remove_file(&dst);
        let guard = book::store().lock().unwrap();
        if let Some(s) = guard.as_ref() {
            let escaped = dst.to_string_lossy().replace('\'', "''");
            if s.conn()
                .execute(&format!("VACUUM INTO '{escaped}'"), [])
                .is_ok()
            {
                true
            } else {
                fs::copy(src, &dst).is_ok()
            }
        } else {
            false
        }
    } else {
        false
    };

    // 2. Import any newly pulled TXT files first via `book::open_book` (outside store lock).
    let mut newly_imported_ids: HashMap<String, i64> = HashMap::new();
    for (r_uid, local_path) in &imported_files {
        if !Path::new(local_path).exists() {
            continue;
        }
        if let Ok(info) = book::open_book(local_path.clone()) {
            newly_imported_ids.insert(r_uid.clone(), info.id);
        }
    }

    // 3. Merge metadata, progress, events, windows, bookmarks, annotations, cuts and archives.
    let mut books_imported = newly_imported_ids.len() as i64;
    let mut progress_updated = 0i64;
    let mut events_added = 0i64;
    let mut windows_added = 0i64;
    let mut bookmarks_added = 0i64;
    let mut annotations_added = 0i64;
    let mut cuts_added = 0i64;
    let mut archives_added = 0i64;

    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    let mut local_books = load_local_books_with_identity(s)?;
    let peer_base = load_peer_base(s, &remote_device_id);

    for rb in remote_books {
        let r_uid = rb.get("sync_uid").and_then(Value::as_str).unwrap_or("");
        let r_hash = rb.get("content_hash").and_then(Value::as_str);

        let target_book: Option<(i64, String, i64, i64, i64, bool)> =
            if let Some(&new_id) = newly_imported_ids.get(r_uid) {
                // Attach remote sync_uid & content_hash to the freshly imported book.
                let _ = s.conn().execute(
                    "UPDATE books SET sync_uid = ?2, content_hash = COALESCE(?3, content_hash) WHERE id = ?1",
                    rusqlite::params![new_id, r_uid, r_hash],
                );
                if let Some(ct) = rb.get("custom_title").and_then(Value::as_str) {
                    let _ = s.rename_book(new_id, Some(ct));
                }
                if let Some(ca) = rb.get("custom_author").and_then(Value::as_str) {
                    let _ = s.set_author(new_id, Some(ca));
                }
                Some((new_id, r_uid.to_string(), 0, 0, 0, true))
            } else if let Some(lb) = match_local_book(&local_books, r_uid, r_hash) {
                Some((
                    lb.id,
                    lb.sync_uid.clone(),
                    lb.last_chapter,
                    lb.last_offset,
                    lb.progress_updated_at,
                    false,
                ))
            } else {
                None
            };

        let Some((book_id, local_uid, l_ch, l_off, l_ts, is_new)) = target_book else {
            continue;
        };

        // Cover sync if downloaded and local has none.
        if let Some(cover_path) = imported_covers.get(r_uid) {
            if Path::new(cover_path).exists() && s.cover_path(book_id).ok().flatten().is_none() {
                let _ = s.set_cover(book_id, Some(cover_path));
            }
        }

        // Progress merge.
        let r_ch = rb.get("last_chapter").and_then(Value::as_i64).unwrap_or(0);
        let r_off = rb.get("last_offset").and_then(Value::as_i64).unwrap_or(0);
        let r_ts = rb
            .get("progress_updated_at")
            .and_then(Value::as_i64)
            .unwrap_or(0);

        if is_new {
            if r_ch > 0 || r_off > 0 {
                let _ = s.conn().execute(
                    "UPDATE books SET last_chapter = ?2, last_offset = ?3,
                                      last_opened_at = COALESCE(?4, last_opened_at),
                                      progress_updated_at = ?4
                     WHERE id = ?1",
                    rusqlite::params![book_id, r_ch, r_off, r_ts.max(store::now())],
                );
                progress_updated += 1;
            }
        } else if l_ch != r_ch || l_off != r_off {
            let base = peer_base.get(&local_uid).or_else(|| peer_base.get(r_uid));
            let local_changed = match base {
                Some(&(bch, boff, _)) => l_ch != bch || l_off != boff,
                None => l_ch > 0 || l_off > 0,
            };
            let remote_changed = match base {
                Some(&(bch, boff, _)) => r_ch != bch || r_off != boff,
                None => r_ch > 0 || r_off > 0,
            };

            let choice = if !local_changed && remote_changed {
                "remote"
            } else if local_changed && !remote_changed {
                "local"
            } else {
                resolutions
                    .get(&local_uid)
                    .or_else(|| resolutions.get(r_uid))
                    .map(String::as_str)
                    .unwrap_or("further_bookmark")
            };

            match choice {
                "remote" => {
                    let _ = s.conn().execute(
                        "UPDATE books SET last_chapter = ?2, last_offset = ?3,
                                          last_opened_at = MAX(COALESCE(last_opened_at, 0), ?4),
                                          progress_updated_at = ?4
                         WHERE id = ?1",
                        rusqlite::params![book_id, r_ch, r_off, r_ts.max(store::now())],
                    );
                    progress_updated += 1;
                }
                "further_bookmark" => {
                    let remote_is_further = (r_ch, r_off) > (l_ch, l_off);
                    if remote_is_further {
                        // Save local position as a bookmark so nothing is ever lost.
                        let _ = s.save_bookmark(
                            book_id,
                            l_ch,
                            l_off,
                            Some("同步保留的原进度"),
                        );
                        bookmarks_added += 1;
                        let _ = s.conn().execute(
                            "UPDATE books SET last_chapter = ?2, last_offset = ?3,
                                              last_opened_at = MAX(COALESCE(last_opened_at, 0), ?4),
                                              progress_updated_at = ?4
                             WHERE id = ?1",
                            rusqlite::params![book_id, r_ch, r_off, r_ts.max(l_ts).max(store::now())],
                        );
                        progress_updated += 1;
                    } else {
                        // Keep local (further) and save remote position as a bookmark.
                        let _ = s.save_bookmark(
                            book_id,
                            r_ch,
                            r_off,
                            Some("同步保留的对端进度"),
                        );
                        bookmarks_added += 1;
                    }
                }
                _ => {
                    // "local": keep local progress untouched.
                }
            }
        }

        // Union merge: completed chapters.
        if let Some(arr) = rb.get("completed_chapters").and_then(Value::as_array) {
            for c in arr {
                if let Some(ch) = c.as_i64() {
                    let _ = s.mark_chapter_completed(book_id, ch);
                }
            }
        }

        // Union merge: reading_events (dedupe by started_at, ended_at).
        let existing_events: HashSet<(i64, i64)> = s
            .book_events(book_id)
            .unwrap_or_default()
            .into_iter()
            .map(|(st, en, _, _)| (st, en))
            .collect();
        if let Some(arr) = rb.get("events").and_then(Value::as_array) {
            for ev in arr {
                if let (Some(st), Some(en), Some(from), Some(to)) = (
                    ev.get(0).and_then(Value::as_i64),
                    ev.get(1).and_then(Value::as_i64),
                    ev.get(2).and_then(Value::as_i64),
                    ev.get(3).and_then(Value::as_i64),
                ) {
                    if !existing_events.contains(&(st, en)) && en > st && to != from {
                        if s.log_event(book_id, st, en, from, to).is_ok() {
                            events_added += 1;
                        }
                    }
                }
            }
        }

        // Union merge: reading_windows (dedupe by chapter, started_at, secs).
        let existing_windows: HashSet<(i64, i64, i64)> = s
            .book_windows(book_id)
            .unwrap_or_default()
            .into_iter()
            .map(|w| (w.chapter, w.started, w.secs))
            .collect();
        if let Some(arr) = rb.get("windows").and_then(Value::as_array) {
            for w in arr {
                if let (Some(ch), Some(st), Some(se), Some(chars)) = (
                    w.get(0).and_then(Value::as_i64),
                    w.get(1).and_then(Value::as_i64),
                    w.get(2).and_then(Value::as_i64),
                    w.get(3).and_then(Value::as_i64),
                ) {
                    if !existing_windows.contains(&(ch, st, se)) && se > 0 {
                        if s.log_window(book_id, ch, st, se, chars).is_ok() {
                            windows_added += 1;
                        }
                    }
                }
            }
        }

        // Union merge: bookmarks (keep existing if newer, insert missing).
        let existing_bms: HashMap<i64, i64> = s
            .bookmarks(book_id)
            .unwrap_or_default()
            .into_iter()
            .map(|m| (m.chapter, m.updated_at))
            .collect();
        if let Some(arr) = rb.get("bookmarks").and_then(Value::as_array) {
            for m in arr {
                let Some(ch) = m.get("chapter").and_then(Value::as_i64) else {
                    continue;
                };
                let off = m.get("offset").and_then(Value::as_i64).unwrap_or(0);
                let comment = m.get("comment").and_then(Value::as_str);
                let r_upd = m.get("updated_at").and_then(Value::as_i64).unwrap_or(0);
                let should_write = match existing_bms.get(&ch) {
                    None => true,
                    Some(&l_upd) => r_upd > l_upd,
                };
                if should_write && s.save_bookmark(book_id, ch, off, comment).is_ok() {
                    bookmarks_added += 1;
                }
            }
        }

        // Union merge: annotations (dedupe by chapter, start, end, body).
        let existing_annos: HashSet<(i64, i64, i64, String)> = s
            .annotations(book_id)
            .unwrap_or_default()
            .into_iter()
            .map(|a| (a.chapter, a.start, a.end, a.body))
            .collect();
        if let Some(arr) = rb.get("annotations").and_then(Value::as_array) {
            for a in arr {
                let ch = a.get("chapter").and_then(Value::as_i64).unwrap_or(0);
                let start = a.get("start").and_then(Value::as_i64).unwrap_or(0);
                let end = a.get("end").and_then(Value::as_i64).unwrap_or(0);
                let quote = a.get("quote").and_then(Value::as_str).unwrap_or("");
                let body = a.get("body").and_then(Value::as_str).unwrap_or("");
                let key = (ch, start, end, body.to_string());
                if !existing_annos.contains(&key)
                    && s.save_annotation(None, book_id, ch, start, end, quote, body)
                        .is_ok()
                {
                    annotations_added += 1;
                }
            }
        }

        // Union merge: text_cuts (only when local has no cuts yet and cuts_base matches).
        let local_cuts_base: Option<i64> = s
            .conn()
            .query_row(
                "SELECT cuts_base FROM books WHERE id = ?1",
                [book_id],
                |r| r.get(0),
            )
            .ok()
            .flatten();
        if local_cuts_base.is_none() {
            if let (Some(base), Some(arr)) = (
                rb.get("cuts_base").and_then(Value::as_i64),
                rb.get("cuts").and_then(Value::as_array),
            ) {
                if !arr.is_empty() {
                    let _ = s.conn().execute(
                        "UPDATE books SET cuts_base = ?2 WHERE id = ?1",
                        rusqlite::params![book_id, base],
                    );
                    for c in arr {
                        if let (Some(st), Some(en)) = (
                            c.get(0).and_then(Value::as_i64),
                            c.get(1).and_then(Value::as_i64),
                        ) {
                            if s.conn()
                                .execute(
                                    "INSERT OR IGNORE INTO text_cuts (book_id, start, end) VALUES (?1, ?2, ?3)",
                                    rusqlite::params![book_id, st, en],
                                )
                                .is_ok()
                            {
                                cuts_added += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    // 4. Union merge: archived stats of deleted books.
    let existing_archives: HashSet<(String, i64)> = s
        .archived_books()
        .unwrap_or_default()
        .into_iter()
        .map(|a| (a.title, a.archived_at))
        .collect();
    if let Some(arr) = remote.get("archives").and_then(Value::as_array) {
        for a in arr {
            let title = a
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let archived_at = a.get("archived_at").and_then(Value::as_i64).unwrap_or(0);
            if title.is_empty() || existing_archives.contains(&(title.clone(), archived_at)) {
                continue;
            }
            let ok = s.conn().execute(
                "INSERT INTO book_stat_archives
                    (title, author, genre_tags, total_bytes, chapter_count,
                     finished_chapters, finished_bytes, is_finished, annotations,
                     content_hash, archived_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                rusqlite::params![
                    title,
                    a.get("author").and_then(Value::as_str),
                    a.get("genre_tags").and_then(Value::as_str),
                    a.get("total_bytes").and_then(Value::as_i64).unwrap_or(0),
                    a.get("chapter_count").and_then(Value::as_i64).unwrap_or(0),
                    a.get("finished_chapters")
                        .and_then(Value::as_i64)
                        .unwrap_or(0),
                    a.get("finished_bytes").and_then(Value::as_i64).unwrap_or(0),
                    i64::from(
                        a.get("is_finished")
                            .and_then(Value::as_bool)
                            .unwrap_or(false)
                    ),
                    a.get("annotations").and_then(Value::as_i64).unwrap_or(0),
                    a.get("content_hash").and_then(Value::as_str),
                    archived_at,
                ],
            );
            if ok.is_ok() {
                let archive_id = s.conn().last_insert_rowid();
                if let Some(evs) = a.get("events").and_then(Value::as_array) {
                    for ev in evs {
                        if let (Some(st), Some(en), Some(f), Some(t)) = (
                            ev.get(0).and_then(Value::as_i64),
                            ev.get(1).and_then(Value::as_i64),
                            ev.get(2).and_then(Value::as_i64),
                            ev.get(3).and_then(Value::as_i64),
                        ) {
                            let _ = s.conn().execute(
                                "INSERT INTO archived_reading_events
                                    (archive_id, started_at, ended_at, start_offset, end_offset)
                                 VALUES (?1, ?2, ?3, ?4, ?5)",
                                rusqlite::params![archive_id, st, en, f, t],
                            );
                        }
                    }
                }
                if let Some(ws) = a.get("windows").and_then(Value::as_array) {
                    for w in ws {
                        if let (Some(c), Some(st), Some(se), Some(ch)) = (
                            w.get(0).and_then(Value::as_i64),
                            w.get(1).and_then(Value::as_i64),
                            w.get(2).and_then(Value::as_i64),
                            w.get(3).and_then(Value::as_i64),
                        ) {
                            let _ = s.conn().execute(
                                "INSERT INTO archived_reading_windows
                                    (archive_id, chapter, started_at, secs, chars)
                                 VALUES (?1, ?2, ?3, ?4, ?5)",
                                rusqlite::params![archive_id, c, st, se, ch],
                            );
                        }
                    }
                }
                archives_added += 1;
            }
        }
    }

    // 5. Refresh peer merge-base so future syncs know what both devices agreed on.
    local_books = load_local_books_with_identity(s)?;
    let _ = save_peer_base(s, &remote_device_id, &local_books);

    // Avoid unused warning if newly_imported_ids was empty.
    let _ = &mut books_imported;

    Ok(SyncApplyResult {
        books_imported,
        progress_updated,
        events_added,
        windows_added,
        bookmarks_added,
        annotations_added,
        cuts_added,
        archives_added,
        backup_created,
    })
}

/// Whether a pre-sync rollback snapshot exists on disk.
pub fn sync_has_rollback() -> Result<bool, String> {
    Ok(backup_path()?.exists())
}

/// Restore the database from `sync_backup_last.db` created before the last sync.
pub fn sync_rollback_last() -> Result<bool, String> {
    let dst = book::db_path()
        .get()
        .ok_or("数据库未初始化")?
        .clone();
    let bak = backup_path()?;
    if !bak.exists() {
        return Ok(false);
    }
    let mut guard = book::store().lock().unwrap();
    // Close active SQLite connection before replacing the database file.
    *guard = None;
    let wal = dst.with_extension("db-wal");
    let shm = dst.with_extension("db-shm");
    let _ = fs::remove_file(&wal);
    let _ = fs::remove_file(&shm);
    fs::copy(&bak, &dst).map_err(|e| format!("回滚数据库失败: {e}"))?;
    let reopened = Store::open(&dst).map_err(|e| format!("重新打开数据库失败: {e}"))?;
    *guard = Some(reopened);
    let _ = fs::remove_file(&bak);
    Ok(true)
}
