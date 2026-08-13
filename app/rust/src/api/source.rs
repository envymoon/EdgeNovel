//! 书源 — finding a book on the open web and bringing it home as a TXT.
//!
//! The one architectural rule here: **a downloaded book is not a new kind of
//! book.** The far end of this module is a plain UTF-8 text file in the app's
//! books directory, which then goes through the ordinary importer. Byte offsets,
//! chapter cutting, progress anchoring, the semantic index, summaries, moods,
//! genre tags, 排雷 — every one of them keeps working without knowing this
//! module exists. Reading over the network was never worth forking all of that.
//!
//! We ship no sources and no site list. The user imports their own rule sheets;
//! this is an engine, not a directory.

use crate::api::book;
use crate::frb_generated::StreamSink;
use novel_core::source::{self, BookSource};
use novel_core::store::{SourceRecord, Store};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

static CANCEL_DOWNLOAD: AtomicBool = AtomicBool::new(false);
static CANCEL_SEARCH: AtomicBool = AtomicBool::new(false);
static CANCEL_TEST: AtomicBool = AtomicBool::new(false);
static CANCEL_PROBE: AtomicBool = AtomicBool::new(false);

fn with_store<T, E: std::fmt::Display>(
    f: impl FnOnce(&mut Store) -> Result<T, E>,
) -> Result<T, String> {
    let mut guard = book::store().lock().unwrap();
    let s = guard.as_mut().ok_or("数据库未初始化")?;
    f(s).map_err(|e| format!("{e}"))
}

fn parse(rec: &SourceRecord) -> Result<BookSource, String> {
    source::parse_sources(&rec.json)?
        .into_iter()
        .next()
        .ok_or_else(|| "书源已损坏".to_string())
}

fn load(url: &str) -> Result<BookSource, String> {
    let all = with_store(|s| s.sources())?;
    let rec = all
        .into_iter()
        .find(|s| s.url == url)
        .ok_or("找不到这个书源")?;
    parse(&rec)
}

/// A rule sheet as the manager shows it.
#[derive(Debug, Clone)]
pub struct SourceItem {
    pub url: String,
    pub name: String,
    pub group: String,
    pub enabled: bool,
    /// None = never tested. False = validation ruled it out for good. True = it
    /// survived — which means "not known to be dead", not "proved to work".
    pub ok: Option<bool>,
    pub note: String,
}

/// Import a legado export — one sheet or a thousand. Returns how many landed.
/// Their rules are stored verbatim: we keep the user's file, not our reading of
/// it, because the format has corners we do not implement and dropping them
/// would quietly damage a sheet that works elsewhere.
pub fn import_sources(json: String) -> Result<u32, String> {
    let list = source::parse_sources_raw(&json)?;
    if list.is_empty() {
        return Err("这份文件里没有书源".into());
    }
    let mut n = 0;
    for (s, one) in &list {
        with_store(|st| {
            st.upsert_source(&SourceRecord {
                url: s.book_source_url.clone(),
                name: if s.book_source_name.trim().is_empty() {
                    s.book_source_url.clone()
                } else {
                    s.book_source_name.clone()
                },
                group: s.book_source_group.clone(),
                json: one.clone(),
                enabled: true,
                ok: None,
                note: None,
            })
        })?;
        n += 1;
    }
    Ok(n)
}

/// The same, from a link — which is how rule sheets actually circulate.
pub fn import_sources_from_url(url: String) -> Result<u32, String> {
    import_sources(source::fetch_text(&url)?)
}

pub fn list_sources() -> Result<Vec<SourceItem>, String> {
    Ok(with_store(|s| s.sources())?
        .into_iter()
        .map(|s| SourceItem {
            url: s.url,
            name: s.name,
            group: s.group.unwrap_or_default(),
            enabled: s.enabled,
            ok: s.ok,
            note: s.note.unwrap_or_default(),
        })
        .collect())
}

pub fn set_source_enabled(url: String, enabled: bool) -> Result<(), String> {
    with_store(|s| s.set_source_enabled(&url, enabled))
}

pub fn delete_source(url: String) -> Result<(), String> {
    with_store(|s| s.delete_source(&url))
}

/// Delete a batch — however the manager happened to have them filtered. Returns
/// how many rows actually went.
pub fn delete_sources(urls: Vec<String>) -> Result<u32, String> {
    Ok(with_store(|s| s.delete_sources(&urls))? as u32)
}

pub fn delete_all_sources() -> Result<u32, String> {
    Ok(with_store(|s| s.clear_sources())? as u32)
}

#[derive(Debug, Clone)]
pub struct SourceTest {
    pub url: String,
    pub ok: bool,
    pub message: String,
}

/// Take a source to the live site and see whether it is dead. It is dead if the
/// site will not talk to us, or if the sheet needs something we refuse to run;
/// anything short of that, it keeps its place. See `source::TestResult`.
///
/// There is deliberately no keyword to pass. Whether a source can find *one
/// particular book* is not the question, so the words it is asked are the
/// engine's business (`source::TEST_KEYS`), not a setting: letting the caller
/// pick the word is exactly how a source that stocks no wuxia gets recorded as
/// broken.
pub fn test_source(url: String) -> Result<SourceTest, String> {
    let src = load(&url)?;
    let r = source::test(&src);
    with_store(|s| s.set_source_test(&url, r.ok, &r.message))?;
    Ok(SourceTest {
        url,
        ok: r.ok,
        message: r.message,
    })
}

/// How a whole-list validation is going, as it goes.
#[derive(Debug, Clone)]
pub struct TestFeed {
    pub done: u32,
    pub total: u32,
    pub ok: u32,
    pub failed: u32,
    /// The source that just answered, and what it said.
    pub source_name: String,
    pub message: String,
}

pub fn cancel_tests() {
    CANCEL_TEST.store(true, Ordering::SeqCst);
}

/// Validate the whole list, many sites at once.
///
/// A legado export is not a handful of sources, it is thousands, and most of
/// them are dead. Testing them one after another means an afternoon of waiting,
/// so this fans out and streams verdicts as they land — and each verdict is
/// written to the database the moment it arrives, so closing the page costs you
/// nothing but the sources still in flight.
///
/// `only_untested` is the default because the list is long and re-proving the
/// sources that already work is how you turn ten minutes into an hour.
pub fn test_sources(only_untested: bool, sink: StreamSink<TestFeed>) -> Result<(), String> {
    CANCEL_TEST.store(false, Ordering::SeqCst);
    let recs: Vec<SourceRecord> = with_store(|s| s.sources())?
        .into_iter()
        .filter(|s| !only_untested || s.ok.is_none())
        .collect();
    if recs.is_empty() {
        return Err("没有需要校验的书源".into());
    }
    let total = recs.len() as u32;
    let counts = Mutex::new((0u32, 0u32, 0u32)); // done, ok, failed
    let queue = Mutex::new(recs);

    std::thread::scope(|scope| {
        let sink = &sink;
        let counts = &counts;
        let queue = &queue;
        // Validation is almost entirely waiting on strangers' servers, most of
        // which will never answer. Twenty threads is not twenty CPUs busy, it is
        // twenty sockets idle — and it turns half an hour of dead sites into ten
        // minutes.
        for _ in 0..20.min(total) {
            scope.spawn(move || loop {
                if CANCEL_TEST.load(Ordering::SeqCst) {
                    return;
                }
                let Some(rec) = queue.lock().unwrap().pop() else {
                    return;
                };
                let r = match parse(&rec) {
                    Ok(src) => source::test(&src),
                    Err(e) => source::TestResult {
                        ok: false,
                        message: e,
                        found: 0,
                        sample_chars: 0,
                    },
                };
                // Recorded before it is reported: the verdict must survive the
                // user walking away mid-pass.
                let _ = with_store(|s| s.set_source_test(&rec.url, r.ok, &r.message));

                let (done, ok, failed) = {
                    let mut c = counts.lock().unwrap();
                    c.0 += 1;
                    if r.ok {
                        c.1 += 1;
                    } else {
                        c.2 += 1;
                    }
                    *c
                };
                let feed = TestFeed {
                    done,
                    total,
                    ok,
                    failed,
                    source_name: rec.name.clone(),
                    message: r.message,
                };
                if sink.add(feed).is_err() {
                    return;
                }
            });
        }
    });
    Ok(())
}

#[derive(Debug, Clone)]
pub struct FoundBookItem {
    pub source_url: String,
    pub source_name: String,
    pub name: String,
    pub author: String,
    pub kind: String,
    pub word_count: String,
    pub last_chapter: String,
    pub intro: String,
    pub book_url: String,
}

/// Results as they land, source by source, plus how far along we are.
#[derive(Debug, Clone)]
pub struct SearchFeed {
    pub done: u32,
    pub total: u32,
    /// Which source just answered — the label under the progress bar.
    pub source_name: String,
    pub hits: Vec<FoundBookItem>,
}

pub fn cancel_search() {
    CANCEL_SEARCH.store(true, Ordering::SeqCst);
}

/// Search every enabled source at once. Sources answer at wildly different
/// speeds and some never answer at all, so results stream: the first site to
/// come back is on screen while the slow ones are still dialling.
///
/// `exact` throws away every hit whose title is not the word you typed. It is a
/// filter on the answers, not a different question: these sites have no exact-
/// match mode, and half of them return their whole catalogue for a short word.
pub fn search_sources(
    key: String,
    exact: bool,
    sink: StreamSink<SearchFeed>,
) -> Result<(), String> {
    CANCEL_SEARCH.store(false, Ordering::SeqCst);
    let all = with_store(|s| s.sources())?;
    if all.is_empty() {
        return Err("还没有导入任何书源。".into());
    }
    // Once anything has proved itself, searching is *only* the proved ones —
    // otherwise a two-thousand-source export means every search drags a
    // graveyard of dead sites behind it. Before the first validation there is
    // nothing to prefer, so untested sources get their chance.
    let proved: Vec<SourceRecord> = all
        .iter()
        .filter(|s| s.enabled && s.ok == Some(true))
        .cloned()
        .collect();
    let recs: Vec<SourceRecord> = if proved.is_empty() {
        all.into_iter()
            .filter(|s| s.enabled && s.ok.is_none())
            .collect()
    } else {
        proved
    };
    if recs.is_empty() {
        return Err("所有书源都校验失败了，或者都被停用了。".into());
    }
    let total = recs.len() as u32;
    let done = Mutex::new(0u32);
    let queue = Mutex::new(recs);

    std::thread::scope(|scope| {
        let sink = &sink;
        let done = &done;
        let queue = &queue;
        let key = &key;
        for _ in 0..12.min(total) {
            scope.spawn(move || loop {
                if CANCEL_SEARCH.load(Ordering::SeqCst) {
                    return;
                }
                let Some(rec) = queue.lock().unwrap().pop() else {
                    return;
                };
                let mut hits = parse(&rec)
                    .and_then(|src| source::search(&src, key))
                    .unwrap_or_default();
                if exact {
                    let want = key.trim();
                    hits.retain(|h| h.name.trim().eq_ignore_ascii_case(want));
                }
                let mut d = done.lock().unwrap();
                *d += 1;
                let feed = SearchFeed {
                    done: *d,
                    total,
                    source_name: rec.name.clone(),
                    hits: hits
                        .into_iter()
                        .map(|h| FoundBookItem {
                            source_url: h.source_url,
                            source_name: h.source_name,
                            name: h.name,
                            author: h.author,
                            kind: h.kind,
                            word_count: h.word_count,
                            last_chapter: h.last_chapter,
                            intro: h.intro,
                            book_url: h.book_url,
                        })
                        .collect(),
                };
                if sink.add(feed).is_err() {
                    return;
                }
            });
        }
    });
    Ok(())
}

/// One site's offer of one book: everything needed to go and measure it.
#[derive(Debug, Clone)]
pub struct Offer {
    pub source_url: String,
    pub book_url: String,
}

/// What a site is really offering, found out by opening the book.
///
/// Search results lie by omission. Every site says it has 《异兽迷城》; one has
/// 1303 chapters of clean prose, the next has a 50-chapter abridgement whose
/// text is ciphertext only a browser can decrypt. Nothing in the search result
/// distinguishes them — you have to open the table of contents and read a
/// chapter, which is exactly what this does.
#[derive(Debug, Clone)]
pub struct OfferProbe {
    pub source_url: String,
    pub chapters: u32,
    pub last_title: String,
    /// Did a chapter of actual prose come back? A big table of contents in front
    /// of unreadable text is worth nothing, and must not win the comparison.
    pub readable: bool,
    /// Empty when all is well; otherwise why this source is a bad bet.
    pub note: String,
}

pub fn cancel_probe() {
    CANCEL_PROBE.store(true, Ordering::SeqCst);
}

/// Open every site's copy of one book and report how long it is and whether it
/// can be read. Results stream: the fast sites are on screen while the slow ones
/// are still counting.
pub fn probe_offers(offers: Vec<Offer>, sink: StreamSink<OfferProbe>) -> Result<(), String> {
    CANCEL_PROBE.store(false, Ordering::SeqCst);
    let all = with_store(|s| s.sources())?;
    let total = offers.len();
    let queue = Mutex::new(offers);

    std::thread::scope(|scope| {
        let (sink, queue, all) = (&sink, &queue, &all);
        for _ in 0..8.min(total) {
            scope.spawn(move || {
                loop {
                    if CANCEL_PROBE.load(Ordering::SeqCst) {
                        return;
                    }
                    let Some(offer) = queue.lock().unwrap().pop() else {
                        return;
                    };
                    let mut p = OfferProbe {
                        source_url: offer.source_url.clone(),
                        chapters: 0,
                        last_title: String::new(),
                        readable: false,
                        note: String::new(),
                    };
                    let src = all
                        .iter()
                        .find(|s| s.url == offer.source_url)
                        .ok_or_else(|| "书源不见了".to_string())
                        .and_then(parse);
                    match src
                        .and_then(|src| source::toc(&src, &offer.book_url).map(|toc| (src, toc)))
                    {
                        Err(e) => p.note = e,
                        Ok((_, toc)) if toc.is_empty() => p.note = "目录是空的".into(),
                        Ok((src, toc)) => {
                            p.chapters = toc.len() as u32;
                            p.last_title = toc.last().map(|c| c.title.clone()).unwrap_or_default();
                            // Read one chapter — the cheapest question that
                            // separates a library from a wall of ciphertext.
                            let after = toc.get(1).map(|c| c.url.as_str());
                            match source::content_next(&src, &toc[0].url, after) {
                                Ok(t) if t.chars().count() >= 50 => p.readable = true,
                                Ok(_) => p.note = "正文是空的".into(),
                                Err(e) => p.note = e,
                            }
                        }
                    }
                    if sink.add(p).is_err() {
                        return;
                    }
                }
            });
        }
    });
    Ok(())
}

#[derive(Debug, Clone)]
pub struct DownloadProgress {
    pub phase: String,
    pub done: u32,
    pub total: u32,
    /// Chapters the site would not give us. A handful is normal; a lot means the
    /// source is bad and the book will have holes — the UI says so rather than
    /// pretending the download succeeded.
    pub failed: u32,
    /// Set exactly once, on the final event: the TXT that is now on disk.
    pub path: Option<String>,
}

pub fn cancel_download() {
    CANCEL_DOWNLOAD.store(true, Ordering::SeqCst);
}

/// Fetch a whole book and write it as one TXT. Chapters are fetched a few at a
/// time — enough to not take an hour, few enough to not hammer a stranger's
/// server — and written strictly in order, because the file *is* the book and
/// its byte offsets are what every other feature anchors to.
pub fn download_book(
    source_url: String,
    book_url: String,
    title: String,
    author: String,
    sink: StreamSink<DownloadProgress>,
) -> Result<(), String> {
    CANCEL_DOWNLOAD.store(false, Ordering::SeqCst);
    let src = load(&source_url)?;

    let say = |phase: &str, done: u32, total: u32, failed: u32, path: Option<String>| {
        let _ = sink.add(DownloadProgress {
            phase: phase.to_string(),
            done,
            total,
            failed,
            path,
        });
    };

    say("正在读取目录…", 0, 0, 0, None);
    let toc = source::toc(&src, &book_url)?;
    if toc.is_empty() {
        return Err("目录是空的，这个书源抓不到这本书".into());
    }
    let total = toc.len() as u32;

    let bodies: Vec<Mutex<Option<String>>> = (0..toc.len()).map(|_| Mutex::new(None)).collect();
    let next = Mutex::new(0usize);
    let done = Mutex::new(0u32);
    let failed = Mutex::new(0u32);
    // Plenty of sites tolerate four threads for eighty chapters and then start
    // answering 429 to everything, which used to end a download with the first
    // eighty chapters and a thousand holes. The pacer is what turns "the site is
    // sick of us" into "the site is read slowly" instead of into data loss.
    let pacer = source::Pacer::new(&src);

    std::thread::scope(|scope| {
        let (src, toc, bodies) = (&src, &toc, &bodies);
        let (next, done, failed) = (&next, &done, &failed);
        let (sink, pacer) = (&sink, &pacer);
        for _ in 0..4 {
            scope.spawn(move || loop {
                if CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
                    return;
                }
                let i = {
                    let mut n = next.lock().unwrap();
                    if *n >= toc.len() {
                        return;
                    }
                    let i = *n;
                    *n += 1;
                    i
                };
                // Where the next chapter begins, so this one knows where to stop:
                // on a great many sites the "下一页" link at the end of a chapter
                // is the "下一章" link, and without this the book comes down with
                // chapter one holding the first twenty chapters and no error to
                // show for it.
                let after = toc.get(i + 1).map(|c| c.url.as_str());

                // Five goes at it, backing off further each time the site says it
                // has had enough. A refusal to be hurried is not a missing
                // chapter and must not be recorded as one.
                let mut text: Result<String, String> = Err("没抓到".into());
                let mut slowed = false;
                for attempt in 0..5u32 {
                    if CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
                        return;
                    }
                    pacer.wait();
                    text = match source::content_next(src, &toc[i].url, after) {
                        Ok(t) if !t.trim().is_empty() => Ok(t),
                        Ok(_) => Err("正文是空的".into()),
                        Err(e) => Err(e),
                    };
                    match &text {
                        Ok(_) => break,
                        // A real failure — a dead link, a rule that does not fit
                        // this page. Asking again more politely changes nothing.
                        Err(e) if !source::is_throttled(e) => break,
                        Err(_) => {
                            slowed = true;
                            let wait = pacer.back_off();
                            std::thread::sleep(wait * (attempt + 1));
                        }
                    }
                }

                match text {
                    Ok(t) => {
                        *bodies[i].lock().unwrap() = Some(t);
                        if !slowed {
                            pacer.ease();
                        }
                    }
                    Err(_) => *failed.lock().unwrap() += 1,
                }
                let d = {
                    let mut d = done.lock().unwrap();
                    *d += 1;
                    *d
                };
                let f = *failed.lock().unwrap();
                let gap = pacer.interval();
                let _ = sink.add(DownloadProgress {
                    phase: if gap.is_zero() {
                        format!("正在抓取正文 · {}", toc[i].title)
                    } else {
                        // Say it out loud. A download that has quietly slowed to
                        // a crawl looks broken; one that says why looks careful.
                        format!("站点限速，正在放慢（每章 {} 毫秒）", gap.as_millis())
                    },
                    done: d,
                    total,
                    failed: f,
                    path: None,
                });
            });
        }
    });

    if CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
        return Err("已停止".into());
    }

    let failed = *failed.lock().unwrap();
    say("正在写入文件…", total, total, failed, None);

    let mut out = String::new();
    if !title.trim().is_empty() {
        out.push_str(title.trim());
        out.push('\n');
        if !author.trim().is_empty() {
            out.push_str(&format!("作者：{}\n", author.trim()));
        }
        out.push('\n');
    }
    for (i, entry) in toc.iter().enumerate() {
        let body = bodies[i].lock().unwrap().take();
        out.push_str(entry.title.trim());
        out.push_str("\n\n");
        match body {
            Some(t) => {
                for line in t.lines().map(str::trim).filter(|l| !l.is_empty()) {
                    out.push_str("　　");
                    out.push_str(line);
                    out.push('\n');
                }
            }
            // A hole, named. Silently dropping the chapter would renumber the
            // book and make the gap invisible; this way the reader can see what
            // the source failed to give them.
            None => out.push_str("　　（本章抓取失败）\n"),
        }
        out.push('\n');
    }

    let path = write_book(&title, &author, &out)?;
    say("完成", total, total, failed, Some(path.clone()));
    Ok(())
}

/// Write into the app's own books directory. The user's other files are none of
/// our business, and a download must never land on top of something they own.
fn write_book(title: &str, author: &str, text: &str) -> Result<String, String> {
    let dir = books_dir()?;
    let safe: String = title
        .chars()
        .map(|c| if r#"\/:*?"<>|"#.contains(c) { '_' } else { c })
        .collect();
    let safe = safe.trim();
    let stem = if safe.is_empty() { "未命名" } else { safe };
    let author = author.trim();
    let base = if author.is_empty() {
        stem.to_string()
    } else {
        format!("{stem}－{author}")
    };
    let mut path = dir.join(format!("{base}.txt"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{base} ({n}).txt"));
        n += 1;
    }
    std::fs::write(&path, text).map_err(|e| format!("写入失败：{e}"))?;
    Ok(path.display().to_string())
}

fn books_dir() -> Result<PathBuf, String> {
    let dir = book::data_dir()?.join("books");
    std::fs::create_dir_all(&dir).map_err(|e| format!("建目录失败：{e}"))?;
    Ok(dir)
}
