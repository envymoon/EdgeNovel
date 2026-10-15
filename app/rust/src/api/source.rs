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
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::Duration;

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
                            // Read one chapter from the middle — the cheapest
                            // question that separates a library from a wall of
                            // ciphertext or a row of teasers. Chapter one is
                            // too often a notice to tell.
                            let i = toc.len() / 2;
                            let after = toc.get(i + 1).map(|c| c.url.as_str());
                            match source::chapter(&src, &toc[i].url, after) {
                                Ok(c) if c.whole => p.readable = true,
                                Ok(c) if c.text.is_empty() => p.note = "正文是空的".into(),
                                Ok(_) => p.note = "正文不全".into(),
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
    /// Chapters no site would give us whole — missing, or only part of them. A
    /// handful is normal; a lot means the book will have holes, and the UI says
    /// so rather than pretending the download succeeded.
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
///
/// `alternates` are the other sites offering the same book, best first. Any
/// chapter the chosen site will not give us whole — a hole, a teaser, a first
/// page with no second — is looked up by title on the next site and taken from
/// there. Most books need none of this, some need it for a handful of chapters,
/// and a site that serves teasers throughout simply turns into a download from
/// one that does not.
pub fn download_book(
    source_url: String,
    book_url: String,
    title: String,
    author: String,
    alternates: Vec<Offer>,
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

    let bodies: Vec<Mutex<Option<source::Chapter>>> =
        (0..toc.len()).map(|_| Mutex::new(None)).collect();
    let jobs: Vec<Job> = (0..toc.len())
        .map(|i| Job {
            slot: i,
            url: toc[i].url.clone(),
            after: toc.get(i + 1).map(|c| c.url.clone()),
        })
        .collect();
    let done = AtomicU32::new(0);
    let failed = AtomicU32::new(0);
    fetch_into(&src, &jobs, &bodies, &|slot, whole, gap| {
        let d = done.fetch_add(1, Ordering::SeqCst) + 1;
        if !whole {
            failed.fetch_add(1, Ordering::SeqCst);
        }
        say(
            &if gap.is_zero() {
                format!("正在抓取正文 · {}", toc[slot].title)
            } else {
                // Say it out loud. A download that has quietly slowed to a
                // crawl looks broken; one that says why looks careful.
                format!("站点限速，正在放慢（每章 {} 毫秒）", gap.as_millis())
            },
            d,
            total,
            failed.load(Ordering::SeqCst),
            None,
        );
    });

    let whole = |i: usize| bodies[i].lock().unwrap().as_ref().is_some_and(|c| c.whole);
    let mut missing: Vec<usize> = (0..toc.len()).filter(|&i| !whole(i)).collect();
    for alt in alternates
        .iter()
        .filter(|o| o.source_url != source_url)
        .take(MAX_ALTERNATES)
    {
        if missing.is_empty() || CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
            break;
        }
        let Ok(alt_src) = load(&alt.source_url) else {
            continue;
        };
        let phase = format!("正在从「{}」补抓", alt_src.book_source_name);
        say(&phase, total, total, missing.len() as u32, None);
        let Ok(alt_toc) = source::toc(&alt_src, &alt.book_url) else {
            continue;
        };
        let jobs = match_chapters(&toc, &missing, &alt_toc);
        let left = AtomicU32::new(missing.len() as u32);
        fetch_into(&alt_src, &jobs, &bodies, &|_, whole, _| {
            if whole {
                left.fetch_sub(1, Ordering::SeqCst);
            }
            say(&phase, total, total, left.load(Ordering::SeqCst), None);
        });
        missing.retain(|&i| !whole(i));
    }

    if CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
        return Err("已停止".into());
    }

    let failed = missing.len() as u32;
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
            Some(c) => {
                let mut lines = c.text.lines().map(str::trim).filter(|l| !l.is_empty()).peekable();
                // Many sites open the text with the chapter's own heading,
                // which the file has just written.
                if lines.peek().is_some_and(|l| repeats_title(l, &entry.title)) {
                    lines.next();
                }
                for line in lines {
                    out.push_str("　　");
                    out.push_str(line);
                    out.push('\n');
                }
                // Part of a chapter is kept — it is still the story — but said
                // to be part, so nobody takes the cut for the author's.
                if !c.whole {
                    out.push_str("　　（本章不全）\n");
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

/// How many other sites a download will try for the chapters the chosen one
/// would not give whole. Each costs a table of contents before any chapter.
const MAX_ALTERNATES: usize = 4;

/// One chapter to fetch: where it goes in the book, and where the next chapter
/// starts on that site, so a page-turn link cannot run on into it.
struct Job {
    slot: usize,
    url: String,
    after: Option<String>,
}

/// Fetch `jobs` from one site into `bodies`, four at a time.
///
/// Plenty of sites tolerate four threads for eighty chapters and then start
/// answering 429 to everything, which used to end a download with the first
/// eighty chapters and a thousand holes. The pacer is what turns "the site is
/// sick of us" into "the site is read slowly" instead of into data loss.
///
/// What comes back only displaces what a slot already holds if it is better:
/// something where there was nothing, whole where there was a part. `report`
/// hears about every job as it finishes — its slot, whether that slot now holds
/// a whole chapter, and the pace the site is being read at.
fn fetch_into(
    src: &BookSource,
    jobs: &[Job],
    bodies: &[Mutex<Option<source::Chapter>>],
    report: &(dyn Fn(usize, bool, Duration) + Sync),
) {
    let next = Mutex::new(0usize);
    let pacer = source::Pacer::new(src);
    std::thread::scope(|scope| {
        let (next, pacer) = (&next, &pacer);
        for _ in 0..4.min(jobs.len()) {
            scope.spawn(move || loop {
                if CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
                    return;
                }
                let job = {
                    let mut n = next.lock().unwrap();
                    if *n >= jobs.len() {
                        return;
                    }
                    *n += 1;
                    &jobs[*n - 1]
                };

                // Five goes at it, backing off further each time the site says
                // it has had enough. A refusal to be hurried is not a missing
                // chapter and must not be recorded as one.
                let mut got: Result<source::Chapter, String> = Err("没抓到".into());
                let mut slowed = false;
                for attempt in 0..5u32 {
                    if CANCEL_DOWNLOAD.load(Ordering::SeqCst) {
                        return;
                    }
                    pacer.wait();
                    got = source::chapter(src, &job.url, job.after.as_deref());
                    match &got {
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

                let whole = {
                    let mut slot = bodies[job.slot].lock().unwrap();
                    if let Ok(c) = got {
                        if !slowed {
                            pacer.ease();
                        }
                        let better = match slot.as_ref() {
                            None => !c.text.is_empty(),
                            Some(old) => c.whole && !old.whole,
                        };
                        if better {
                            *slot = Some(c);
                        }
                    }
                    slot.as_ref().is_some_and(|c| c.whole)
                };
                report(job.slot, whole, pacer.interval());
            });
        }
    });
}

/// Where our missing chapters sit in another site's list: matched by name, see
/// [`source::pair_chapters`].
fn match_chapters(
    toc: &[source::TocEntry],
    missing: &[usize],
    other: &[source::TocEntry],
) -> Vec<Job> {
    source::pair_chapters(toc, missing, other)
        .into_iter()
        .map(|(i, j)| Job {
            slot: i,
            url: other[j].url.clone(),
            after: other.get(j + 1).map(|c| c.url.clone()),
        })
        .collect()
}

/// A line that is the chapter's heading again: 「第103章奖励：雇佣圆珠笔」
/// under 「第103章 奖励：雇佣圆珠笔」.
fn repeats_title(line: &str, title: &str) -> bool {
    let name = source::chapter_name(title);
    !name.is_empty()
        && source::chapter_name(line) == name
        && line.chars().count() <= title.chars().count() + 12
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

#[cfg(test)]
mod tests {
    use super::*;
    use novel_core::source::TocEntry;

    fn toc(titles: &[&str], site: &str) -> Vec<TocEntry> {
        titles
            .iter()
            .enumerate()
            .map(|(i, t)| TocEntry {
                title: t.to_string(),
                url: format!("https://{site}/{i}.html"),
            })
            .collect()
    }

    #[test]
    fn a_heading_repeated_in_the_text_is_known() {
        assert!(repeats_title("第103章奖励：雇佣圆珠笔（二更）", "第103章 奖励：雇佣圆珠笔（二更）"));
        assert!(repeats_title("第四百二十四章 震动", "第424章 震动"));
        assert!(!repeats_title("震动从脚下传来，越来越近，像是有什么东西正在醒来。", "第424章 震动"));
    }

    /// Two sites number the same book differently; the chapter is found by its
    /// name all the same.
    #[test]
    fn missing_chapters_are_found_on_another_site() {
        let ours = toc(&["第一章 陨落的天才（求收藏）", "第二章 斗气大陆", "第三章 客人"], "a");
        let theirs = toc(&["序", "第1章 陨落的天才", "第2章 斗气大陆", "第4章 客人！"], "b");
        let jobs = match_chapters(&ours, &[0, 2], &theirs);
        let got: Vec<(usize, &str, Option<&str>)> = jobs
            .iter()
            .map(|j| (j.slot, j.url.as_str(), j.after.as_deref()))
            .collect();
        assert_eq!(
            got,
            [
                (0, "https://b/1.html", Some("https://b/2.html")),
                (2, "https://b/3.html", None),
            ]
        );
    }
}
