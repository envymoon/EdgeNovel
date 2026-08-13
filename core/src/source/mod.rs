//! 书源 — a book source is a JSON rule sheet describing how to read one website.
//!
//! The format is legado's, because that is the format the rule sheets in the
//! wild are written in and we are not going to invent a dialect nobody writes.
//! We are a *consumer* of those files, not a curator of them: this module ships
//! no sources and knows no sites. The user brings their own JSON.
//!
//! What comes out the far end is a plain TXT file on disk, and from that moment
//! the book is an ordinary book — same byte offsets, same chapters, same index,
//! same everything. The source engine is a way to get a file, not a second kind
//! of book. That is the whole reason it costs so little architecture.
//!
//! Not everything in legado's rule language is implementable without a browser:
//! sources that embed JavaScript (`<js>`, `@js:`) or demand a WebView are
//! rejected, loudly, by [`test`] rather than half-working at midnight in the
//! middle of a download. XPath is not in yet either. A rule sheet that leans on
//! any of those is simply not usable here, and the manager greys it out.

mod rule;

pub use rule::{html_to_text, Unsupported};

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// One website's rule sheet, in legado's field names so their files parse as-is.
/// Everything but the URL is optional: sheets in the wild omit whatever they do
/// not need, and a missing rule is a normal state, not an error.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BookSource {
    pub book_source_url: String,
    pub book_source_name: String,
    pub book_source_group: Option<String>,
    /// 0 文本, 1 音频, 2 图片, 3 文件. We only read 0.
    pub book_source_type: i64,
    pub enabled: Option<bool>,
    /// May be a bare path, may carry a `,{...}` options blob. See [`rule::UrlSpec`].
    pub search_url: Option<String>,
    /// A JSON object as a *string*, legado-style: {"User-Agent": "..."}
    pub header: Option<String>,
    /// How fast the sheet's author says this site may be read: `"1500"` for a
    /// 1.5-second gap, `"3/1000"` for three requests a second. Almost always
    /// absent, which is why [`Pacer`] learns the rate instead of trusting it.
    pub concurrent_rate: Option<String>,
    pub rule_search: Option<SearchRule>,
    pub rule_book_info: Option<BookInfoRule>,
    pub rule_toc: Option<TocRule>,
    pub rule_content: Option<ContentRule>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SearchRule {
    pub book_list: Option<String>,
    pub name: Option<String>,
    pub author: Option<String>,
    pub kind: Option<String>,
    pub word_count: Option<String>,
    pub last_chapter: Option<String>,
    pub intro: Option<String>,
    pub cover_url: Option<String>,
    pub book_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BookInfoRule {
    pub name: Option<String>,
    pub author: Option<String>,
    pub kind: Option<String>,
    pub word_count: Option<String>,
    pub last_chapter: Option<String>,
    pub intro: Option<String>,
    pub cover_url: Option<String>,
    pub toc_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TocRule {
    pub chapter_list: Option<String>,
    pub chapter_name: Option<String>,
    pub chapter_url: Option<String>,
    pub next_toc_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ContentRule {
    pub content: Option<String>,
    pub next_content_url: Option<String>,
    /// The site's own ad-scrubber: regexes the sheet's author wrote after
    /// reading a chapter and seeing what junk the site glues to it. Ignoring
    /// this field is how "一秒记住笔趣阁" ends up in a downloaded book.
    pub replace_regex: Option<String>,
}

/// Was this refusal a "go away for now", or a "go away"?
///
/// A site that is sick of us says 429, or 503, or simply hangs up. None of these
/// mean the chapter is unavailable — they mean we asked too fast, and the same
/// request will work in a second. Counting them as failures is how a download
/// ends with the first eighty chapters and a thousand holes.
pub fn is_throttled(err: &str) -> bool {
    err.contains("429")
        || err.contains("503")
        || err.contains("Too Many")
        || err.contains("timeout")
        || err.contains("forcibly closed")
        || err.contains("Peer disconnected")
}

/// The pace we are allowed to read a site at, learned by being told off.
///
/// Almost nobody fills in legado's `concurrentRate` — 7 sheets out of 3203 in a
/// real export — so the polite interval cannot be looked up; it has to be
/// discovered. Start at full speed, and the first time a site answers 429, slow
/// down and keep slowing until it stops complaining. When it has been happy for
/// a while, speed back up: most books are on sites that do not throttle at all
/// and must not be punished for the ones that do.
///
/// One pacer is shared by every thread of one download, and it serialises them:
/// with an interval set, the four workers take turns rather than storming the
/// site in parallel, which is the behaviour that got us banned in the first
/// place.
pub struct Pacer {
    inner: Mutex<PacerState>,
    floor: Duration,
}

struct PacerState {
    interval: Duration,
    next: Instant,
    good_streak: u32,
}

/// Where backing off stops. Beyond this a book would take longer than a reader
/// will wait, and the honest thing is to fail and say the site is throttling.
const MAX_INTERVAL: Duration = Duration::from_millis(4000);
/// The first step out of full speed. Small enough to barely notice, large enough
/// that a site rate-limiting at a few requests a second is satisfied.
const FIRST_STEP: Duration = Duration::from_millis(300);
/// Successes in a row before we try being quicker again.
const STREAK_TO_EASE: u32 = 40;

impl Pacer {
    /// The sheet's own `concurrentRate`, if its author bothered: `"1500"` is a
    /// minimum gap in milliseconds, `"3/1000"` is three requests per second.
    /// That figure becomes the floor — we never go faster than the person who
    /// knows the site said we could.
    pub fn new(src: &BookSource) -> Self {
        let floor = src
            .concurrent_rate
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .and_then(|s| match s.split_once('/') {
                Some((n, per)) => {
                    let n: u64 = n.trim().parse().ok()?;
                    let per: u64 = per.trim().parse().ok()?;
                    (n > 0).then(|| Duration::from_millis(per / n))
                }
                None => s.parse().ok().map(Duration::from_millis),
            })
            .unwrap_or(Duration::ZERO)
            .min(MAX_INTERVAL);
        Pacer {
            inner: Mutex::new(PacerState {
                interval: floor,
                next: Instant::now(),
                good_streak: 0,
            }),
            floor,
        }
    }

    /// Block until it is this thread's turn to make a request.
    pub fn wait(&self) {
        let sleep_for = {
            let mut st = self.inner.lock().unwrap();
            let now = Instant::now();
            let at = st.next.max(now);
            st.next = at + st.interval;
            at.saturating_duration_since(now)
        };
        if !sleep_for.is_zero() {
            std::thread::sleep(sleep_for);
        }
    }

    /// The site complained. Slow down, and report the new interval.
    pub fn back_off(&self) -> Duration {
        let mut st = self.inner.lock().unwrap();
        st.good_streak = 0;
        st.interval = if st.interval.is_zero() {
            FIRST_STEP
        } else {
            (st.interval * 2).min(MAX_INTERVAL)
        };
        // Give the site a moment to forgive us before anyone asks again.
        st.next = Instant::now() + st.interval;
        st.interval
    }

    /// A chapter came back fine. After enough of those, try going faster.
    pub fn ease(&self) {
        let mut st = self.inner.lock().unwrap();
        st.good_streak += 1;
        if st.good_streak >= STREAK_TO_EASE && st.interval > self.floor {
            st.good_streak = 0;
            st.interval = (st.interval * 3 / 4).max(self.floor);
        }
    }

    pub fn interval(&self) -> Duration {
        self.inner.lock().unwrap().interval
    }
}

/// A book as a search result: enough to choose between two sites offering the
/// same title, and no more.
#[derive(Debug, Clone)]
pub struct FoundBook {
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

#[derive(Debug, Clone)]
pub struct TocEntry {
    pub title: String,
    pub url: String,
}

/// Read a legado export: one object, an array of them, or the whole thing
/// wrapped in a JSON string (which some export buttons produce).
pub fn parse_sources(json: &str) -> Result<Vec<BookSource>, String> {
    Ok(parse_sources_raw(json)?
        .into_iter()
        .map(|(s, _)| s)
        .collect())
}

/// The same, but each sheet also comes back as the text the user actually gave
/// us. Store *that*, never our re-serialization: this struct models only the
/// fields we read, so round-tripping a sheet through it quietly deletes
/// everything else in the file — and the day we implement one of those fields,
/// the data to use it with would already be gone.
pub fn parse_sources_raw(json: &str) -> Result<Vec<(BookSource, String)>, String> {
    let v: serde_json::Value =
        serde_json::from_str(json.trim()).map_err(|e| format!("不是合法的 JSON：{e}"))?;
    let v = match v {
        serde_json::Value::String(s) => {
            serde_json::from_str(&s).map_err(|e| format!("不是合法的 JSON：{e}"))?
        }
        other => other,
    };
    let items: Vec<serde_json::Value> = match v {
        serde_json::Value::Array(a) => a,
        obj @ serde_json::Value::Object(_) => vec![obj],
        _ => return Err("书源应当是一个对象或一组对象".into()),
    };
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let src: BookSource =
            serde_json::from_value(item.clone()).map_err(|e| format!("书源格式不对：{e}"))?;
        if src.book_source_url.trim().is_empty() {
            continue;
        }
        out.push((src, item.to_string()));
    }
    Ok(out)
}

fn agent() -> ureq::Agent {
    agent_with(Duration::from_secs(20))
}

/// Reading a book you asked for is worth waiting twenty seconds; auditing two
/// thousand strangers' rule sheets is not. Validation gets a short fuse, because
/// with a list this long the dead sites are the bulk of the bill.
fn agent_with(timeout: Duration) -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        // A site that answers a search in a megabyte of HTML is answering; one
        // that answers in fifty is something else, and we are not reading it.
        .max_response_header_size(64 * 1024)
        .build()
        .into()
}

/// Pull a rule sheet off the web, because that is how people share them: a link
/// in a group chat, not a file. The bytes are decoded with the same detector the
/// book importer uses — plenty of these files are served as GBK.
pub fn fetch_text(url: &str) -> Result<String, String> {
    let doc = rule::fetch(&agent(), &rule::UrlSpec::plain(url), None)?;
    match doc.json {
        Some(j) => Ok(j.to_string()),
        None => Err("这个网址返回的不是书源 JSON".into()),
    }
}

/// Search one source. Returns whatever the site offered, which may be nothing —
/// an empty list is an answer, not a failure.
pub fn search(src: &BookSource, key: &str) -> Result<Vec<FoundBook>, String> {
    search_with(&agent(), src, key)
}

pub fn search_with(
    ag: &ureq::Agent,
    src: &BookSource,
    key: &str,
) -> Result<Vec<FoundBook>, String> {
    let spec = src.search_url.as_deref().unwrap_or_default();
    if spec.trim().is_empty() {
        return Err("这个书源没有搜索规则".into());
    }
    let r = src.rule_search.clone().unwrap_or_default();
    let list_rule = r.book_list.as_deref().unwrap_or_default();
    if list_rule.is_empty() {
        return Err("这个书源没有 bookList 规则".into());
    }

    let url = rule::UrlSpec::parse(spec, &src.book_source_url, key, 1)?;
    let doc = rule::fetch(ag, &url, src.header.as_deref())?;

    let mut out = Vec::new();
    for item in rule::select_list(&doc, list_rule)? {
        let book_url = rule::eval(&item, r.book_url.as_deref().unwrap_or_default())?;
        if book_url.trim().is_empty() {
            continue;
        }
        let name = rule::eval(&item, r.name.as_deref().unwrap_or_default())?;
        if name.trim().is_empty() {
            continue;
        }
        out.push(FoundBook {
            source_url: src.book_source_url.clone(),
            source_name: src.book_source_name.clone(),
            name: name.trim().to_string(),
            author: rule::eval(&item, r.author.as_deref().unwrap_or_default())?
                .trim()
                .to_string(),
            kind: rule::eval(&item, r.kind.as_deref().unwrap_or_default())?
                .trim()
                .to_string(),
            word_count: rule::eval(&item, r.word_count.as_deref().unwrap_or_default())?
                .trim()
                .to_string(),
            last_chapter: rule::eval(&item, r.last_chapter.as_deref().unwrap_or_default())?
                .trim()
                .to_string(),
            intro: rule::eval(&item, r.intro.as_deref().unwrap_or_default())?
                .trim()
                .to_string(),
            book_url: rule::absolute(&doc.url, book_url.trim()),
        });
    }
    Ok(out)
}

/// The chapter list. Follows `nextTocUrl` while it keeps pointing somewhere new,
/// because a great many sites paginate their tables of contents.
pub fn toc(src: &BookSource, book_url: &str) -> Result<Vec<TocEntry>, String> {
    toc_with(&agent(), src, book_url)
}

pub fn toc_with(
    ag: &ureq::Agent,
    src: &BookSource,
    book_url: &str,
) -> Result<Vec<TocEntry>, String> {
    let r = src.rule_toc.clone().unwrap_or_default();
    let list_rule = r
        .chapter_list
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or("这个书源没有目录规则")?;

    // A book page may point at a separate TOC page; when it does not, it is the
    // TOC page itself.
    let mut page = book_url.to_string();
    if let Some(info) = &src.rule_book_info {
        if let Some(toc_rule) = info.toc_url.as_deref().filter(|s| !s.is_empty()) {
            let doc = rule::fetch(ag, &rule::UrlSpec::plain(&page), src.header.as_deref())?;
            let found = rule::eval(&rule::Item::whole(&doc), toc_rule)?;
            if !found.trim().is_empty() {
                page = rule::absolute(&page, found.trim());
            }
        }
    }

    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    // `nextTocUrl` says one of two different things depending on how many URLs
    // it hands back. One URL is a chain — "after this page, that one" — and is
    // followed hop by hop. Many URLs at once is the whole atlas: sites that
    // paginate a table of contents almost always put every page in a <select>,
    // and `option@value` scrapes the lot. Treating that list as a chain and
    // walking only its first entry is how a 1300-chapter book arrives with 100
    // chapters and no error anywhere.
    let mut queue: std::collections::VecDeque<String> = std::collections::VecDeque::new();
    queue.push_back(page.clone());

    while let Some(page) = queue.pop_front() {
        if !seen.insert(page.clone()) {
            continue;
        }
        if seen.len() > 400 {
            break;
        }
        let doc = rule::fetch(ag, &rule::UrlSpec::plain(&page), src.header.as_deref())?;
        for item in rule::select_list(&doc, list_rule)? {
            let url = rule::eval(&item, r.chapter_url.as_deref().unwrap_or_default())?;
            let title = rule::eval(&item, r.chapter_name.as_deref().unwrap_or_default())?;
            if url.trim().is_empty() || title.trim().is_empty() {
                continue;
            }
            out.push(TocEntry {
                title: title.trim().to_string(),
                url: rule::absolute(&doc.url, url.trim()),
            });
        }
        let Some(nr) = r.next_toc_url.as_deref().filter(|s| !s.is_empty()) else {
            continue;
        };
        let next = rule::eval(&rule::Item::whole(&doc), nr)?;
        for n in next.lines().map(str::trim).filter(|s| !s.is_empty()) {
            queue.push_back(rule::absolute(&doc.url, n));
        }
    }
    Ok(out)
}

/// One chapter's text, following `nextContentUrl` for sites that split a chapter
/// across pages.
pub fn content(src: &BookSource, chapter_url: &str) -> Result<String, String> {
    content_with(&agent(), src, chapter_url, None)
}

/// The same, told where the *next chapter* lives.
///
/// This is not a nicety. Half the sheets in the wild write their page-turn rule
/// as `text.下一@href`, and on these sites the "下一页" button on the last page
/// of a chapter is the "下一章" button — same anchor, same rule, different
/// meaning. Chase it blindly and chapter one swallows the twenty chapters after
/// it, which is not an error anyone sees: the download succeeds, the book is
/// just wrong. The only thing that can tell the two apart is knowing where the
/// next chapter starts, and the table of contents already knows.
pub fn content_next(
    src: &BookSource,
    chapter_url: &str,
    next_chapter: Option<&str>,
) -> Result<String, String> {
    content_with(&agent(), src, chapter_url, next_chapter)
}

pub fn content_with(
    ag: &ureq::Agent,
    src: &BookSource,
    chapter_url: &str,
    next_chapter: Option<&str>,
) -> Result<String, String> {
    let r = src.rule_content.clone().unwrap_or_default();
    let rule_str = r
        .content
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or("这个书源没有正文规则")?;

    let mut page = chapter_url.to_string();
    let mut seen = std::collections::HashSet::new();
    let mut text = String::new();
    for _ in 0..20 {
        if !seen.insert(page.clone()) {
            break;
        }
        let doc = rule::fetch(ag, &rule::UrlSpec::plain(&page), src.header.as_deref())?;
        // Chapter bodies come back as HTML far more often than not — `@html`
        // hands over the raw markup, ad scripts and all. Nobody wants to read a
        // <script> tag, so the markup stops here, at the edge of the engine.
        let part = rule::html_to_text(&rule::eval(&rule::Item::whole(&doc), rule_str)?);
        if !part.trim().is_empty() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(part.trim());
        }
        let next = match r.next_content_url.as_deref().filter(|s| !s.is_empty()) {
            None => break,
            Some(nr) => rule::eval(&rule::Item::whole(&doc), nr)?,
        };
        let next = match next.lines().next().map(str::trim).filter(|s| !s.is_empty()) {
            None => break,
            Some(n) => rule::absolute(&doc.url, n),
        };
        if next_chapter.is_some_and(|c| rule::same_page(&next, c)) {
            break;
        }
        page = next;
    }
    let text = rule::apply_replace(&text, r.replace_regex.as_deref());
    if !text.trim().is_empty() && !readable(&text) {
        return Err("正文是加密的，本机引擎读不了（这个站要浏览器解密）".into());
    }
    Ok(text)
}

/// Is this prose, or is it a blob?
///
/// A growing number of sites ship the chapter body as ciphertext inside the page
/// and decrypt it with JavaScript in the browser. Our rules extract it happily —
/// the selector matches, the bytes are there, nothing errors — and what lands in
/// the book is line after line of `�`. That is worse than a failure, because a
/// failure is visible and this is not: it is a book you only discover is ruined
/// while reading it. So the engine reads what it extracted and refuses to call
/// it a chapter unless it mostly looks like writing.
fn readable(text: &str) -> bool {
    let mut sane = 0usize;
    let mut total = 0usize;
    for c in text.chars().take(4000) {
        total += 1;
        let ok = c.is_alphanumeric()
            || c.is_whitespace()
            || c.is_ascii_punctuation()
            || matches!(c, '\u{3000}'..='\u{303f}' | '\u{ff00}'..='\u{ffef}' | '…' | '—' | '·');
        // The replacement character is the tell: it is what a decoder leaves
        // behind when it is handed bytes that were never text.
        if ok && c != '\u{fffd}' {
            sane += 1;
        }
    }
    total == 0 || sane * 100 / total >= 80
}

/// What a source can actually do, found out by making it do it.
///
/// Validation only *rejects*; it does not certify. In a list where fewer than
/// one source in forty proves itself end to end, a verdict of "unproven" is not
/// worth what it costs: throw those away and there is nothing left to search
/// with. So `ok` means **not known to be dead** — the site answered, and the
/// engine can speak to it. What it doesn't mean is that a search will find your
/// book; a source that answers but returns nothing stays in the pool, because it
/// costs one request to ask it and it might have the next book you want.
///
/// The disqualifications are only the ones that cannot come out differently
/// tomorrow's search: no search rule at all, rules we refuse to run (JavaScript,
/// webView), a site that is not text, or a site that would not talk to us.
#[derive(Debug, Clone)]
pub struct TestResult {
    pub ok: bool,
    /// What happened, in one line, for the source manager to show — the reason it
    /// was rejected, or how far it got when it wasn't.
    pub message: String,
    pub found: u32,
    /// Characters of the chapter we managed to read, if we got that far. Zero
    /// with `ok` is normal now: it means unproven, not broken.
    pub sample_chars: u32,
}

pub fn test(src: &BookSource) -> TestResult {
    test_with_timeout(src, DEFAULT_TEST_TIMEOUT)
}

/// How long a source gets to answer during validation. Not a taste question: it
/// decides how much of a list survives, so it was measured against a real export
/// rather than guessed. See `sourcecheck`.
pub const DEFAULT_TEST_TIMEOUT: u64 = 8;

/// What validation searches for. The question it has to answer is "can this
/// source find books and read them out", not "does this source stock any
/// particular book", so it asks in three registers before giving up: a wuxia
/// word, a romance word (a large share of these sites are women's-fiction sites
/// and hold nothing with 「剑」 in it at all), and a title so common that a live
/// library nearly has to carry it. One hit anywhere is enough.
pub const TEST_KEYS: [&str; 3] = ["剑", "总裁", "斗破苍穹"];

/// How many search hits we open before blaming the source. The first is often an
/// ad slot, or a book that happens to be broken.
const HITS_TO_TRY: usize = 3;

/// How many chapters we open. Chapter one is routinely a notice, a preface or a
/// picture, none of which is evidence that the source is dead.
const CHAPTERS_TO_TRY: usize = 3;

pub fn test_with_timeout(src: &BookSource, secs: u64) -> TestResult {
    let dead = |message: String, found: u32| TestResult {
        ok: false,
        message,
        found,
        sample_chars: 0,
    };
    let alive = |message: String, found: u32, chars: u32| TestResult {
        ok: true,
        message,
        found,
        sample_chars: chars,
    };

    if src.book_source_type != 0 {
        return dead("不是文本书源".into(), 0);
    }
    let ag = agent_with(Duration::from_secs(secs));

    // Search. This is the only step that can disqualify: an error here is either
    // the site refusing to talk (timeout, 403, 404, no such host, refused) or a
    // sheet we cannot run at all (no search rule, JavaScript, webView). Neither
    // gets better with another word, so we stop at the first one.
    let mut hits = Vec::new();
    for key in TEST_KEYS {
        match search_with(&ag, src, key) {
            Err(e) => return dead(e, 0),
            Ok(h) if h.is_empty() => continue,
            Ok(h) => {
                hits = h;
                break;
            }
        }
    }
    // The site answered and the engine understood it — it just had nothing for
    // the words we happened to try. That is not a dead source, and in a list this
    // thin we cannot afford to treat it as one.
    if hits.is_empty() {
        return alive("站是活的，但这几个词搜不到书".into(), 0, 0);
    }
    let found = hits.len() as u32;

    // Everything below is a bonus round: it decides what the note says, never
    // whether the source lives. A broken chapter rule is worth knowing about
    // before you download a book, but it is not grounds for deletion — the site
    // may serve some books fine, and the search still works either way.
    let mut trouble = String::new();
    for hit in hits.iter().take(HITS_TO_TRY) {
        let chapters = match toc_with(&ag, src, &hit.book_url) {
            Err(e) => {
                trouble = e;
                continue;
            }
            Ok(c) if c.is_empty() => {
                trouble = "目录是空的".into();
                continue;
            }
            Ok(c) => c,
        };
        for (i, ch) in chapters.iter().take(CHAPTERS_TO_TRY).enumerate() {
            let after = chapters.get(i + 1).map(|c| c.url.as_str());
            match content_with(&ag, src, &ch.url, after) {
                Err(e) => trouble = e,
                Ok(t) if t.chars().count() < 50 => trouble = "正文抓下来是空的".into(),
                Ok(t) => {
                    return alive(
                        format!("{} 个结果 · 目录 {} 章", found, chapters.len()),
                        found,
                        t.chars().count() as u32,
                    );
                }
            }
        }
    }
    alive(
        format!("{found} 个结果，但正文没读出来（{trouble}）"),
        found,
        0,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_legado_array() {
        let json = r#"[
          {"bookSourceUrl":"https://a.example","bookSourceName":"甲",
           "searchUrl":"/s?q={{key}}",
           "ruleSearch":{"bookList":"@css:.item","name":"@css:h3@text","bookUrl":"@css:a@href"},
           "ruleToc":{"chapterList":"@css:#list a","chapterName":"text","chapterUrl":"href"},
           "ruleContent":{"content":"@css:#content@html"}}
        ]"#;
        let s = parse_sources(json).unwrap();
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].book_source_name, "甲");
        assert_eq!(
            s[0].rule_content.as_ref().unwrap().content.as_deref(),
            Some("@css:#content@html")
        );
    }

    /// Sheets in the wild carry fields we have never heard of. Ignoring them is
    /// the point: an unknown key must not cost the user a working source.
    #[test]
    fn unknown_fields_are_ignored() {
        let json = r#"{"bookSourceUrl":"https://a.example","bookSourceName":"甲",
                       "weirdFutureField":{"x":1},"customOrder":7}"#;
        assert_eq!(parse_sources(json).unwrap().len(), 1);
    }

    #[test]
    fn a_source_without_a_url_is_not_a_source() {
        let json = r#"[{"bookSourceUrl":"","bookSourceName":"空"}]"#;
        assert!(parse_sources(json).unwrap().is_empty());
    }

    fn sheet(rate: Option<&str>) -> BookSource {
        BookSource {
            concurrent_rate: rate.map(str::to_string),
            ..Default::default()
        }
    }

    #[test]
    fn a_sheet_that_states_its_rate_is_believed() {
        assert_eq!(
            Pacer::new(&sheet(Some("1500"))).interval(),
            Duration::from_millis(1500)
        );
        // Three requests per second is a gap of a third of a second.
        assert_eq!(
            Pacer::new(&sheet(Some("3/1000"))).interval(),
            Duration::from_millis(333)
        );
        assert_eq!(Pacer::new(&sheet(None)).interval(), Duration::ZERO);
        assert_eq!(
            Pacer::new(&sheet(Some("nonsense"))).interval(),
            Duration::ZERO
        );
    }

    /// The shape of the whole thing: full speed until told off, then slower and
    /// slower, then — once the site has been happy for a while — quicker again.
    #[test]
    fn the_pace_is_learned_from_being_told_off() {
        let p = Pacer::new(&sheet(None));
        assert_eq!(p.interval(), Duration::ZERO);
        p.back_off();
        assert_eq!(p.interval(), FIRST_STEP);
        p.back_off();
        assert_eq!(p.interval(), FIRST_STEP * 2);
        for _ in 0..10 {
            p.back_off();
        }
        assert_eq!(
            p.interval(),
            MAX_INTERVAL,
            "backing off has to stop somewhere"
        );

        for _ in 0..STREAK_TO_EASE {
            p.ease();
        }
        assert!(
            p.interval() < MAX_INTERVAL,
            "a site that behaves gets its speed back"
        );
    }

    /// A sheet's declared rate is a floor: we never talk ourselves into going
    /// faster than the person who knows the site said we may.
    #[test]
    fn easing_never_goes_below_the_declared_rate() {
        let p = Pacer::new(&sheet(Some("1000")));
        p.back_off();
        for _ in 0..STREAK_TO_EASE * 20 {
            p.ease();
        }
        assert_eq!(p.interval(), Duration::from_millis(1000));
    }

    #[test]
    fn being_rate_limited_is_not_a_missing_chapter() {
        assert!(is_throttled("请求失败：http status: 429"));
        assert!(is_throttled("请求失败：timeout: global"));
        assert!(!is_throttled("请求失败：http status: 404"));
        assert!(!is_throttled("这个书源没有正文规则"));
    }

    /// Real prose passes; the encrypted blob a JS-decrypting site serves does
    /// not. The blob below is what one of these sites actually hands over.
    #[test]
    fn ciphertext_is_not_mistaken_for_a_chapter() {
        assert!(readable(
            "今天是高阳穿越的第十二个年头。\n穿越前，高阳是个孤儿。"
        ));
        assert!(readable(
            "Chapter One\n\nIt was a bright cold day in April."
        ));
        assert!(!readable("(\u{fffd}/\u{fffd}d\u{fffd}U\u{fffd}\u{fffd}1;0'@6\u{fffd}I\u{fffd};\u{fffd}\u{fffd}0\u{3bb}\u{fffd}\u{fffd}G\u{fffd}\u{fffd}6\"\u{fffd}\u{fffd}Jd\u{fffd}I.%\u{fffd}y\u{fffd}m\u{6de}\u{fffd}\u{fffd}Kw\u{fffd}\u{fffd}Oj\u{fffd}\u{fffd}"));
    }
}
