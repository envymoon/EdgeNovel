//! 文本整理: what the rules can find in a book that is not the book — a site's
//! address and furniture, its mark in brackets, a line pasted under chapter
//! after chapter — gathered into groups for the reader to look over before any
//! of it goes.
//!
//! Nothing here touches the file. What the reader removes is kept as [`Cuts`]
//! beside the book, byte ranges of the decoded original, and laid over it each
//! time the book is opened. Going back to the original is forgetting the cuts.
//!
//! The site rules are the ones the downloader used to apply silently
//! (`source::tidy`); here they say what they would remove instead.

use crate::book::Chapter;
use crate::source::tidy::{
    ADDR, ASIDE, BYLINE, CUT, FURNITURE, GAP, GLUED, MARKUP, SIGN_OFF, WATERMARK,
};
use regex::Regex;
use std::collections::HashMap;
use std::ops::Range;
use std::sync::LazyLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    Address,
    SiteNotice,
    Watermark,
    Markup,
    AuthorNote,
    Repeated,
    Phrase,
}

impl Kind {
    pub fn zh(self) -> &'static str {
        match self {
            Kind::Address => "网址",
            Kind::SiteNotice => "网站提示",
            Kind::Watermark => "站名水印",
            Kind::Markup => "网页代码",
            Kind::AuthorNote => "作者的话",
            Kind::Repeated => "反复出现",
            Kind::Phrase => "自定义",
        }
    }
}

/// One line of the book with something in it to remove: the whole line, or
/// pieces of it. `cuts` are byte ranges of the text; a whole line's takes its
/// line break with it.
#[derive(Debug, Clone)]
pub struct Finding {
    pub chapter: usize,
    pub line: Range<usize>,
    pub whole: bool,
    pub cuts: Vec<Range<usize>>,
}

#[derive(Debug, Clone)]
pub struct Group {
    pub kind: Kind,
    /// The kind's name, or for a repeated line the line itself.
    pub label: String,
    /// Ticked when the page opens.
    pub checked: bool,
    pub items: Vec<Finding>,
}

/// An author asking for votes or thanking readers. That is the book, so it is
/// offered unticked. Only the asking: 「打赏」「月票」 alone are words a story
/// uses too.
static AUTHOR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"求(?:月票|推荐票|红票|推荐|收藏|订阅|打赏|保底|票)|(?:投|砸|给).{0,4}(?:月票|推荐票|红票)|(?:月票|推荐票|红票).{0,4}(?:投|砸|给)|保底月票|加更(?:[^加多新]|$)|作者有话说|作者的话|书友群|^[（(【]?\s*(?:PS|ps|Ps|P\.S\.?)\s*[:：.，,]|^[（(【]?\s*第[一二三四五六七八九十0-9]{1,3}更",
    )
    .unwrap()
});

/// What a site says about itself, as against a story that mentions a website.
static AD_STRONG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)本站|首发|最新|最快|手机版|阅读网址|记住|永久|备用|访问|下载|电子书|提供|来源|txt|小说|书友|免费|无弹窗|更新",
    )
    .unwrap()
});

/// Words that make a line repeated across the book an advert rather than a
/// refrain, so its group starts ticked.
static AD_HINT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)小说|阅读|书友|免费|下载|app|公众号|微信|qq|群号|关注|更新|无弹窗|笔趣|首发|追书|书城|书架|网站|网址|网页|手机版|手机站|中文网|喜欢本书|喜欢这本书|红包|支付宝|淘宝|广告|vip",
    )
    .unwrap()
});

/// HTML a site left in, by the tags pages are made of. 「<We will rock you>」
/// in a story is not one.
static TAG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)</?(?:p|br|a|font|b|i|u|s|div|span|img|td|tr|th|table|tbody|strong|em|h[1-6]|li|ul|ol|center|script|style|hr|sup|sub|iframe|ins|del|small|big|dd|dt|dl|section|article|blockquote|pre|code)(?:\s[^<>]{0,200})?\s*/?>|^\s*[A-Za-z]+\s*/>\s*$",
    )
    .unwrap()
});

/// A chapter or volume heading, whether or not the split took it as one.
static HEADING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^第\s*[0-9０-９零〇一二两三四五六七八九十百千万]+\s*[章节回卷部集篇]").unwrap()
});

/// What every rule needs at least one of. Most lines are the story and have
/// none, and one look for it saves running all the rules on them.
static TRIGGER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"[A-Za-z0-9０-９<>（()【\[]|最新|本章|下一页|-->>|转码|手打|刷新|作者|上一章|章节|记住|收藏|书签|二维码|弹窗|手机|翻页|方向键|最快|首发|本站|未完待续|域名|网址|地址|求|票|加更|书友|第.{1,3}更",
    )
    .unwrap()
});

/// Everything the rules find, a group to each kind and to each repeated line.
pub fn find(text: &str, chapters: &[Chapter]) -> Vec<Group> {
    let all = lines(text, chapters);
    let mut fixed: HashMap<Kind, Vec<Finding>> = HashMap::new();
    // The lines no rule took, by the hash of their shape: how many there are,
    // in how many chapters. Most are counted once and never looked at again.
    let mut free: Vec<(usize, u64)> = Vec::new();
    let mut count: HashMap<u64, (usize, usize, usize)> = HashMap::new();
    for (i, l) in all.iter().enumerate() {
        if l.title {
            continue;
        }
        let s = &text[l.range.clone()];
        let found = classify(s, l.opening);
        if !found.is_empty() {
            for (kind, whole, cuts) in found {
                fixed.entry(kind).or_default().push(finding(text, l, whole, cuts));
            }
            continue;
        }
        let t = s.trim();
        // Running heads of a volume are the book's structure, not an advert.
        if t.len() > 600 || HEADING.is_match(t) {
            continue;
        }
        if let Some(h) = shape_hash(t) {
            let e = count.entry(h).or_insert((0, 0, usize::MAX));
            e.0 += 1;
            if e.2 != l.chapter {
                e.1 += 1;
                e.2 = l.chapter;
            }
            free.push((i, h));
        }
    }

    let mut out = Vec::new();
    for kind in [Kind::Address, Kind::SiteNotice, Kind::Watermark, Kind::Markup, Kind::AuthorNote] {
        if let Some(items) = fixed.remove(&kind) {
            out.push(Group {
                kind,
                label: kind.zh().to_string(),
                checked: kind != Kind::AuthorNote,
                items,
            });
        }
    }

    // A sentence the story repeats now and then is not this: an advert is
    // pasted into a good part of the book.
    let need = (chapters.len() / 30).max(8);
    let enough = |e: &(usize, usize, usize)| {
        let spread = if chapters.len() >= 20 { e.1 } else { e.0 };
        spread >= need
    };
    let mut by_shape: HashMap<u64, Vec<&Line>> = HashMap::new();
    for (i, h) in free {
        if count.get(&h).is_some_and(|e| enough(e)) {
            by_shape.entry(h).or_default().push(&all[i]);
        }
    }
    let mut repeated: Vec<Group> = by_shape
        .into_values()
        .map(|seen| {
            let mut tally: HashMap<&str, usize> = HashMap::new();
            for l in &seen {
                *tally.entry(text[l.range.clone()].trim()).or_default() += 1;
            }
            let label = tally
                .iter()
                .max_by_key(|(line, n)| (**n, std::cmp::Reverse(*line)))
                .map(|(line, _)| line.to_string())
                .unwrap_or_default();
            let checked = seen.iter().take(8).any(|l| {
                let s = &text[l.range.clone()];
                AD_HINT.is_match(s) || ADDR.is_match(s) || AD_HINT.is_match(&skeleton(s))
            });
            Group {
                kind: Kind::Repeated,
                label,
                checked,
                items: seen
                    .into_iter()
                    .map(|l| Finding {
                        chapter: l.chapter,
                        cuts: vec![line_cut(text, &l.range)],
                        line: l.range.clone(),
                        whole: true,
                    })
                    .collect(),
            }
        })
        .collect();
    repeated.sort_by(|a, b| b.items.len().cmp(&a.items.len()).then(a.label.cmp(&b.label)));
    repeated.truncate(50);
    out.extend(repeated);
    out
}

/// The hash of a line's [`skeleton`], without building it; `None` for a line
/// of fewer than eight Chinese characters, too short to tell an advert from a
/// line of dialogue.
fn shape_hash(line: &str) -> Option<u64> {
    let mut h: u64 = 0xcbf29ce484222325;
    let mut words = 0;
    let mut letters = false;
    let mut eat = |c: char| {
        for b in (c as u32).to_le_bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
    };
    for c in line.chars() {
        let c = narrow(c);
        if is_han(c) {
            eat(c);
            words += 1;
            letters = false;
        } else if c.is_ascii_alphanumeric() {
            if !letters {
                eat('#');
                letters = true;
            }
        }
    }
    (words >= 8).then_some(h)
}

fn narrow(c: char) -> char {
    match c {
        '\u{ff01}'..='\u{ff5e}' => char::from_u32(c as u32 - 0xfee0).unwrap_or(c),
        _ => c,
    }
}

fn is_han(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c) || ('\u{3400}'..='\u{4dbf}').contains(&c)
}

/// Every place the reader's own phrase appears: the phrase itself inside a
/// line, the whole line when that is all it says, and lines that are the same
/// words with another address or number in them.
pub fn find_phrase(text: &str, chapters: &[Chapter], phrase: &str) -> Group {
    let phrase = phrase.trim();
    let key = skeleton(phrase);
    let by_shape = key.chars().filter(|c| *c != '#').count() >= 4;
    let mut items = Vec::new();
    if !phrase.is_empty() {
        for l in lines(text, chapters) {
            if l.title {
                continue;
            }
            let s = &text[l.range.clone()];
            let lead = s.len() - s.trim_start().len();
            let t = s.trim();
            if by_shape && skeleton(t) == key {
                items.push(finding(text, &l, true, Vec::new()));
                continue;
            }
            let cuts: Vec<Range<usize>> = t
                .match_indices(phrase)
                .map(|(i, m)| lead + i..lead + i + m.len())
                .collect();
            if cuts.is_empty() {
                continue;
            }
            let rest = without(t, &cuts.iter().map(|r| r.start - lead..r.end - lead).collect::<Vec<_>>());
            let whole = !rest.chars().any(|c| c.is_alphanumeric());
            items.push(finding(text, &l, whole, cuts));
        }
    }
    Group {
        kind: Kind::Phrase,
        label: phrase.to_string(),
        checked: true,
        items,
    }
}

/// A line reduced to its words, so the same advert with another address or
/// another number in it is the same line.
pub fn skeleton(line: &str) -> String {
    let mut out = String::new();
    let mut letters = false;
    for c in line.chars().map(narrow) {
        if is_han(c) {
            out.push(c);
            letters = false;
        } else if c.is_ascii_alphanumeric() {
            if !letters {
                out.push('#');
                letters = true;
            }
        }
    }
    out
}

struct Line {
    range: Range<usize>,
    chapter: usize,
    title: bool,
    /// Among the first two lines under a chapter's title, where a site puts
    /// its 「作者：」 header.
    opening: bool,
}

fn lines(text: &str, chapters: &[Chapter]) -> Vec<Line> {
    let mut out = Vec::new();
    let mut ch = 0usize;
    let mut seen = 0usize;
    let mut was: Option<usize> = None;
    let mut off = 0usize;
    for l in text.split('\n') {
        let start = off;
        let end = off + l.len();
        off = end + 1;
        while ch + 1 < chapters.len() && chapters[ch + 1].span.start <= start {
            ch += 1;
        }
        let c = chapters.get(ch).filter(|c| start >= c.span.start);
        if was != c.map(|c| c.index) {
            was = c.map(|c| c.index);
            seen = 0;
        }
        if l.trim().is_empty() {
            continue;
        }
        let title = c.is_some_and(|c| start == c.span.start && c.body_start > c.span.start);
        // Not the book's first chapter: its 「作者：」 is the book's own.
        let opening = !title && c.is_some_and(|c| c.index > 0) && seen < 2;
        if !title {
            seen += 1;
        }
        out.push(Line {
            range: start..end,
            chapter: c.map_or(0, |c| c.index),
            title,
            opening,
        });
    }
    out
}

fn finding(text: &str, l: &Line, whole: bool, cuts: Vec<Range<usize>>) -> Finding {
    let at = l.range.start;
    Finding {
        chapter: l.chapter,
        line: l.range.clone(),
        whole,
        cuts: if whole {
            vec![line_cut(text, &l.range)]
        } else {
            cuts.into_iter().map(|r| at + r.start..at + r.end).collect()
        },
    }
}

/// A whole line, with the line break that ends it, or for the last line the
/// one before it.
fn line_cut(text: &str, r: &Range<usize>) -> Range<usize> {
    if text.as_bytes().get(r.end) == Some(&b'\n') {
        r.start..r.end + 1
    } else if r.start > 0 {
        r.start - 1..r.end
    } else {
        r.clone()
    }
}

/// The line with the markup taken out, and the line's byte each of its bytes
/// came from.
struct View {
    text: String,
    from: Vec<usize>,
}

impl View {
    fn new(line: &str, marks: &[Range<usize>]) -> Self {
        let mut text = String::new();
        let mut from = Vec::new();
        let mut at = 0;
        for m in marks.iter().chain(std::iter::once(&(line.len()..line.len()))) {
            text.push_str(&line[at..m.start]);
            from.extend(at..m.start);
            at = m.end;
        }
        View { text, from }
    }

    /// A range of the view as a range of the line. Any markup between its
    /// ends goes with it.
    fn back(&self, r: &Range<usize>) -> Range<usize> {
        self.from[r.start]..self.from[r.end - 1] + 1
    }
}

/// What the rules make of one line: its kind, whether all of it goes, and the
/// pieces of it (byte ranges of the line) when only those do. Usually one
/// finding or none; two when the line is an author's note with the site's
/// words in it.
fn classify(line: &str, opening: bool) -> Vec<(Kind, bool, Vec<Range<usize>>)> {
    if !TRIGGER.is_match(line) {
        return Vec::new();
    }
    let marks: Vec<Range<usize>> = TAG.find_iter(line).map(|m| m.range()).collect();
    let v = View::new(line, &marks);
    let lead = v.text.len() - v.text.trim_start().len();
    let t = v.text.trim();
    // A line that is one tag of a page's own: 「<Book {"book_id":…} >」.
    if t.is_empty() || (marks.is_empty() && MARKUP.find(t).is_some_and(|m| m.len() == t.len())) {
        return vec![(Kind::Markup, true, Vec::new())];
    }
    let heading = HEADING.is_match(t);
    // Someone speaking. A site's notice is never in quotes; a character can
    // talk about a website, or scan a code.
    let quoted = t.contains(['“', '”', '「', '」']);

    let mut cuts: Vec<(Range<usize>, Kind)> = Vec::new();
    for m in ASIDE.find_iter(t) {
        let a = m.as_str();
        let inner = a.trim_matches(['（', '(', '【', '[', '）', ')', '】', ']']);
        if ADDR.is_match(a) {
            cuts.push((m.range(), Kind::Address));
        } else if WATERMARK.is_match(a) {
            cuts.push((m.range(), Kind::Watermark));
        } else if FURNITURE.is_match(a) || FURNITURE.is_match(inner) {
            cuts.push((m.range(), Kind::SiteNotice));
        }
    }
    for re in [&*SIGN_OFF, &*GLUED, &*BARE_SIGN_OFF] {
        if let Some(m) = re.find(t) {
            // 「(未完待续。第二十章提醒（900票加更）」: the next chapter's title
            // came glued on after the sign-off, and stays.
            let end = NEXT_TITLE
                .find(&t[m.start()..m.end()])
                .map_or(m.end(), |n| m.start() + n.start());
            cuts.push((m.start()..end, Kind::SiteNotice));
        }
    }
    for m in CUT.find_iter(t) {
        cuts.push((m.range(), Kind::SiteNotice));
    }
    for m in GLUED_AD.find_iter(t) {
        cuts.push((m.range(), Kind::SiteNotice));
    }
    // The site's words, and whether each could be glued onto a sentence of the
    // story that should stay: 「……价值都尚可。浏览器搜索最快更新」.
    let furniture: Vec<(Range<usize>, bool)> = if quoted || heading {
        Vec::new()
    } else {
        FURNITURE
            .find_iter(t)
            .filter(|m| !cuts.iter().any(|(r, _)| r.contains(&m.start())))
            .map(|m| glued(t, m.range()))
            .collect()
    };
    cuts.extend(furniture.iter().map(|(r, _)| (r.clone(), Kind::SiteNotice)));
    for m in ADDR.find_iter(t) {
        let end = address_end(t, m.start());
        // 「第11章 夜谈www.5du5.com」: the address goes, the heading stays.
        // 「…排队了。www.niubb.ｎｅｔ牛ｂｂ小说网每个都有…」: the site signed the
        // middle of a paragraph.
        if heading || AD_STRONG.is_match(&t[m.start()..end]) {
            cuts.push((m.start()..end, Kind::Address));
            continue;
        }
        // A paragraph is the story, but a short clause of it can be the
        // site's: 「…请记住本站网址 www.x.com，…」.
        if t.chars().count() < 60 {
            continue;
        }
        let start = t[..m.start()]
            .rfind(['。', '！', '？', '!', '?'])
            .map_or(0, |i| i + t[i..].chars().next().map_or(1, char::len_utf8));
        let end = t[m.end()..]
            .find(['。', '！', '？', '!', '?'])
            .map_or(t.len(), |i| {
                m.end() + i + t[m.end() + i..].chars().next().map_or(1, char::len_utf8)
            });
        let clause = &t[start..end];
        if clause.chars().count() <= 50 && AD_STRONG.is_match(clause) && !clause.contains(['“', '”']) {
            cuts.push((start..end, Kind::Address));
        }
    }
    let words = |s: &str| s.chars().filter(|c| is_han(*c)).count();
    // 「…陈汉升也用了一点这个套路。首发https://」: a sentence of the story,
    // then the site, to the end of the line.
    if !quoted && !heading && t.chars().count() < 150 {
        if let Some(m) = ADDR.find(t) {
            let head = &t[..m.start()];
            let tail = &t[m.start()..];
            if let Some(at) = head.rfind(['。', '！', '？', '”']) {
                let at = at + head[at..].chars().next().map_or(1, char::len_utf8);
                if words(&head[..at]) >= 4 && words(&ADDR.replace_all(tail, "")) < 6 {
                    cuts.push((at..t.len(), Kind::Address));
                }
            }
        }
    }
    cuts.sort_by_key(|(r, _)| (r.start, r.end));
    let ranges: Vec<Range<usize>> = cuts.iter().map(|(r, _)| r.clone()).collect();
    let rest = without(t, &ranges);
    let rest = rest.trim();
    let n = rest.chars().count();
    let kind = cuts.iter().map(|(_, k)| *k).min();

    // Too little left to be the story's: 「访问」. A short sentence is enough:
    // 「回到了外界。」.
    let scraps = |s: &str| {
        let n = words(s);
        n < 6 && !(n >= 3 && s.ends_with(['。', '！', '？', '…', '”']))
    };
    let whole = if rest.is_empty() {
        Some(kind.unwrap_or(Kind::Markup))
    } else if heading {
        None
    } else if n < 80 && GAP.is_match(rest) {
        Some(Kind::SiteNotice)
    } else if !quoted && n < 150 && SITE_LINE.is_match(rest) {
        Some(Kind::SiteNotice)
    } else if n <= 150 && AUTHOR.is_match(rest) {
        Some(Kind::AuthorNote)
    // A short line the site's words could not be cut cleanly out of goes
    // whole; in a long paragraph they go and the story stays.
    } else if !furniture.is_empty()
        && ((t.chars().count() < 80 && furniture.iter().any(|(_, ok)| !ok)) || scraps(rest))
    {
        Some(if ADDR.is_match(t) { Kind::Address } else { Kind::SiteNotice })
    } else if !quoted && n < 150 && ADDR.is_match(rest) && {
        let words = words(&ADDR.replace_all(rest, ""));
        words < 6 || (n < 60 && AD_STRONG.is_match(rest))
    } {
        Some(Kind::Address)
    } else if opening && BYLINE.is_match(rest) {
        Some(Kind::SiteNotice)
    } else {
        None
    };
    let mut pieces: Vec<Range<usize>> = ranges
        .iter()
        .filter(|r| r.start < r.end)
        .map(|r| v.back(&(lead + r.start..lead + r.end)))
        .chain(marks)
        .collect();
    pieces.sort_by_key(|r| (r.start, r.end));
    let pieces = (!pieces.is_empty()).then(|| (kind.unwrap_or(Kind::Markup), false, merge(pieces)));
    match whole {
        // An author asking for votes under the site's sign-off: the sign-off
        // is the site's, the asking the reader's to decide on. Both ticked,
        // the line goes.
        Some(Kind::AuthorNote) => pieces.into_iter().chain([(Kind::AuthorNote, true, Vec::new())]).collect(),
        Some(kind) => vec![(kind, true, Vec::new())],
        None => pieces.into_iter().collect(),
    }
}

/// Adverts sites glue onto the end of a sentence, word for word the same.
static GLUED_AD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"自从知道用.{0,10}搜索.{0,30}?最快更新了?").unwrap()
});

/// The old platform's sign-off without its bracket: 「…心里才踏实。未完待续。
/// 如果您喜欢这部作品，欢迎您来…」, to the end of the line.
static BARE_SIGN_OFF: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:未完待续[。.，,]?\s*)?如果您喜欢这部作品.*$").unwrap()
});

/// A chapter's title inside a line.
static NEXT_TITLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"第\s*[0-9０-９零〇一二两三四五六七八九十百千万]+\s*[章节回]|番外").unwrap()
});

/// Lines that are a site's or a download's own, all of them.
static SITE_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"欢迎广大书友光临阅读|本书由.{0,30}提供|更多电子书请访问|更多精校小说尽在|本书下载自",
    )
    .unwrap()
});

/// How far the site's words found at `m` reach: the symbols they are padded
/// with, a name of a few characters in front (「圣堂最新章节」), and characters
/// spaced out by stars (「浏*览*器*搜*索」). And whether the story can be what
/// is left on either side: the words start a line or a sentence, or come
/// spaced out, which is never the story's own writing.
fn glued(t: &str, m: Range<usize>) -> (Range<usize>, bool) {
    const PAD: &str = "…*＊@&.．·~～-_#:： 　";
    let veil = |c: Option<char>| c.is_some_and(|c| "*＊·".contains(c));
    let before = |i: usize| t[..i].chars().next_back();
    let mut end = m.end;
    for c in t[end..].chars() {
        if PAD.contains(c) || "!！了".contains(c) {
            end += c.len_utf8();
        } else {
            break;
        }
    }
    let mut start = m.start;
    let mut name = 0;
    let mut veiled = false;
    while let Some(c) = before(start) {
        let at = start - c.len_utf8();
        if PAD.contains(c) {
            start = at;
        } else if is_han(c) && (veil(before(at)) || veil(t[start..].chars().next())) {
            start = at;
            veiled = true;
        } else if is_han(c) && !veiled && name < 6 {
            start = at;
            name += 1;
        } else {
            break;
        }
    }
    let ok = veiled || start == 0 || before(start).is_some_and(|c| "。！？!?”」".contains(c));
    (start..end, ok)
}

/// A site's name right after its address: 「牛ｂｂ小说网」.
static SITE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[^，。！？、\s“”]{0,6}?(?:小说网|中文网|文学网|书网|书屋|书城|书吧|小说)").unwrap()
});

/// Where an address [`ADDR`] found at `start` ends: its last letter, full
/// width ones too, and the site's name when that follows.
fn address_end(t: &str, start: usize) -> usize {
    let letter = |c: char| {
        c.is_ascii_alphanumeric()
            || "./:_-?=&%~#".contains(c)
            || matches!(c, '\u{ff10}'..='\u{ff19}' | '\u{ff21}'..='\u{ff3a}' | '\u{ff41}'..='\u{ff5a}' | '．')
    };
    let end = t[start..].find(|c: char| !letter(c)).map_or(t.len(), |i| start + i);
    end + SITE.find(&t[end..]).map_or(0, |m| m.end())
}

/// `t` with the ranges taken out.
fn without(t: &str, ranges: &[Range<usize>]) -> String {
    let mut out = String::new();
    let mut at = 0;
    for r in merge(ranges.to_vec()) {
        if r.start > at {
            out.push_str(&t[at..r.start]);
        }
        at = at.max(r.end);
    }
    out.push_str(&t[at.min(t.len())..]);
    out
}

fn merge(mut v: Vec<Range<usize>>) -> Vec<Range<usize>> {
    v.retain(|r| r.start < r.end);
    v.sort_by_key(|r| (r.start, r.end));
    let mut out: Vec<Range<usize>> = Vec::with_capacity(v.len());
    for r in v {
        match out.last_mut() {
            Some(last) if r.start <= last.end => last.end = last.end.max(r.end),
            _ => out.push(r),
        }
    }
    out
}

/// What has been taken out of a book: sorted byte ranges of the original,
/// none touching another.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cuts(Vec<Range<usize>>);

impl Cuts {
    pub fn new(v: Vec<Range<usize>>) -> Self {
        Cuts(merge(v))
    }

    pub fn ranges(&self) -> &[Range<usize>] {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Every range must fall on character boundaries of `text`.
    pub fn fits(&self, text: &str) -> bool {
        self.0.iter().all(|r| {
            r.end <= text.len() && text.is_char_boundary(r.start) && text.is_char_boundary(r.end)
        })
    }

    pub fn apply(&self, text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        let mut at = 0;
        for r in &self.0 {
            out.push_str(&text[at..r.start]);
            at = r.end;
        }
        out.push_str(&text[at..]);
        out
    }

    /// Where a byte of the original is in the cut text. One inside a cut
    /// lands where the cut was.
    pub fn forward(&self, x: usize) -> usize {
        let mut removed = 0;
        for r in &self.0 {
            if r.end <= x {
                removed += r.len();
            } else if r.start < x {
                return r.start - removed;
            } else {
                break;
            }
        }
        x - removed
    }

    /// Where a byte of the cut text is in the original. One where a cut was
    /// lands after it, on the text that followed.
    pub fn back(&self, y: usize) -> usize {
        let mut x = y;
        for r in &self.0 {
            if r.start <= x {
                x += r.len();
            } else {
                break;
            }
        }
        x
    }

    /// These cuts and ranges of the text they leave, as one set of cuts of
    /// the original.
    pub fn and(&self, more: &[Range<usize>]) -> Cuts {
        let mut v = self.0.clone();
        v.extend(more.iter().filter(|r| r.start < r.end).map(|r| {
            let start = self.back(r.start);
            start..start + (self.back(r.end - 1) + 1 - start)
        }));
        Cuts::new(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::Span;
    use crate::source::tidy::scrub;

    /// The text as one chapter, not the book's first: its opening lines are
    /// where a site's header would be.
    fn whole_book(text: &str) -> Vec<Chapter> {
        vec![Chapter {
            index: 1,
            number: None,
            title: String::new(),
            span: Span { start: 0, end: text.len() },
            body_start: 0,
        }]
    }

    fn ticked(text: &str) -> String {
        let cuts = find(text, &whole_book(text))
            .into_iter()
            .filter(|g| g.checked)
            .flat_map(|g| g.items.into_iter().flat_map(|f| f.cuts))
            .collect();
        Cuts::new(cuts).apply(text)
    }

    /// What the downloader used to take out, the ticked groups take out.
    #[test]
    fn the_site_rules_find_what_the_download_scrub_removed() {
        for raw in [
            "萧炎抬起头。\n请记住本书首发域名：www.rulianshi.cc。手机版阅读网址：m.rulianshi.cc\n\
             最新网址：m.rulianshi.cc\n上一章返回目录下一章\n\
             加入书签温馨提示：方向键左右(← →)前后翻页\nread3();\n\
             弟兄们，请将月票投给土豆！\n他笑了。",
            "将黑暗彻底驱逐。(飞速小说网 www／feisuxs.com)\n（他笑了）",
            "庆余年 作者:猫腻\n范闲笑了。(三七中文et)\n\
             <font color=red>笔趣阁</font>已启用最新域名： ，请大家牢记最新域名并相互转告，谢谢！</p>\n\
             手机浏览器扫描二维码访问\nbr />\n他盘膝坐下了！(未完待续，如欲知后事如何，请登陆<a href=\n(本章完)",
            "笔趣阁已启用最新域名：萧炎等人皆是连忙抬头。\n“终于要现身了么”\n未完待续:",
            "夜的命名术 第96节\n作者：未知\n庆尘笑了。",
            "他走了。\n他笑了。\n作者：今天请假一天",
            "他打开电脑，在搜索框里输入了www.baidu.com。\n他按下方向键，角色向前冲去。",
            "新人相拥，（本章未完，请翻页）",
            "“明白了，嗯，从南阳一路过来……”\n……\n转码失败！请您使用右上换源切换源站阅读或者直接前往源网站进行阅读！\n时过三更，南召县北侧的黑虎庙附近。",
        ] {
            assert_eq!(ticked(raw), scrub(raw).0, "{raw}");
        }
    }

    /// Lines of stories on the shelf that read like the site but are not.
    #[test]
    fn the_story_may_mention_a_website_or_a_tip() {
        for prose in [
            "炎黄在线的网址非常霸气，www.chinese.com，这个域名起码就值100万元。",
            "她一边嘟囔着，一边扫描二维码，并告诉我：“我叫杨思思，你可以备注一下。”",
            "“la violence.la barbarie.pas intelligent.”",
            "陈二狗很欠揍地拖了一个长长尾音，道：“打赏你多少钱了，值得你大老远跑南京来当说客？”",
            "真要让谢晚山知道自己还只是十六岁的高中生，大概会对谢晚晴施加更加的压力吧。",
            "坐电车用的是通勤月票。",
            "\"那有空带我去趟教堂，见识以下。\"陈浮生微笑道。<Wewillrockyou>",
            "ThreeThousandDollars(3,000.00)",
        ] {
            assert!(find(prose, &whole_book(prose)).is_empty(), "{prose}");
        }
        // The site's part goes, the story's stays.
        for (raw, kept) in [
            ("8月2日，中午11点30。（uc书盟最快更新）", "8月2日，中午11点30。"),
            ("第11章 夜谈www.5du5.com", "第11章 夜谈"),
            (
                "甚至和郑观媞的交往中，陈汉升也用了一点这个套路。首发https://https://",
                "甚至和郑观媞的交往中，陈汉升也用了一点这个套路。",
            ),
            ("回到了外界。浏*览*器*搜*索：@……最快更新……", "回到了外界。"),
            (
                "【今天实在是对不住各位书友了，先补上一章，下一章明天补上。】",
                "【今天实在是对不住各位书友了，先补上一章，下一章明天补上。】",
            ),
            (
                "已经有好几个孕妇在排队了。www.NIUBB.ｎｅｔ牛ｂｂ小说网每个都有自己的另一半陪在身边。",
                "已经有好几个孕妇在排队了。每个都有自己的另一半陪在身边。",
            ),
            (
                "这让丁雪与顾沐清都很警惕的同时，毕竟给予的礼物，价值都尚可。浏览器搜索最快更新",
                "这让丁雪与顾沐清都很警惕的同时，毕竟给予的礼物，价值都尚可。",
            ),
            (
                "其中没有鼻子的第七尸祖，七血瞳不要浏*览*器*搜*索：@……最快更新……",
                "其中没有鼻子的第七尸祖，七血瞳不要",
            ),
            (
                "火光更是滔天而起。浏*览*器*搜*索：@精华书阁……最快更新……",
                "火光更是滔天而起。",
            ),
            (
                "唤辛雷和费贺炜进去。&*.最快更新＊＊两人进了书房，就见夏浔正将一封书信封好火漆。",
                "唤辛雷和费贺炜进去。两人进了书房，就见夏浔正将一封书信封好火漆。",
            ),
            (
                "孙陆便乖乖地站住，朱高煦站起身来，大摇大摆地走出去。圣堂最新章节",
                "孙陆便乖乖地站住，朱高煦站起身来，大摇大摆地走出去。",
            ),
            (
                "秦东元几乎隔上三五年就会进一次三界山。自从知道用百度搜索眼快，妈妈再也不用担心我追不到最快更新了",
                "秦东元几乎隔上三五年就会进一次三界山。",
            ),
            (
                "陆为民侃侃而谈的观点，让袁振峰和欧振国都禁不住耳目一新。(未完待续。如果您喜欢这部作品，欢迎您来投推荐票、月票，您的支持，就是我最大的动力。)",
                "陆为民侃侃而谈的观点，让袁振峰和欧振国都禁不住耳目一新。",
            ),
            (
                "惭愧中，总要把前天那差的一更补上心里才踏实。未完待续。如果您喜欢这部作品，欢迎您来520投推荐票、月票，您的支持，就是我最大的动力。",
                "惭愧中，总要把前天那差的一更补上心里才踏实。",
            ),
            (
                "孟奇收回了目光。(未完待续。第二十章提醒（900票加更）",
                "孟奇收回了目光。第二十章提醒（900票加更）",
            ),
            (
                "肖艾将自己的手机和赵牧的手机靠在了一起，然后用扫描二维码的方式添加了赵牧的微信。",
                "肖艾将自己的手机和赵牧的手机靠在了一起，然后用扫描二维码的方式添加了赵牧的微信。",
            ),
            // The author's asking stays unless the reader ticks it too.
            (
                "求月票！(未完待续。如果您喜欢这部作品，欢迎您来起点（）投推荐票、月票，您的支持，就是我最大的动力。手机用户请到m.阅读。)",
                "求月票！",
            ),
        ] {
            assert_eq!(ticked(raw), kept);
        }
    }

    #[test]
    fn an_authors_note_is_offered_unticked() {
        let text = "他笑了。\n弟兄们，请将月票投给土豆！\nPS：今天还有一更。";
        let groups = find(text, &whole_book(text));
        let note = groups.iter().find(|g| g.kind == Kind::AuthorNote).unwrap();
        assert!(!note.checked);
        assert_eq!(note.items.len(), 2);
    }

    fn chapters(n: usize, body: impl Fn(usize) -> String) -> (String, Vec<Chapter>) {
        let mut text = String::new();
        let mut out = Vec::new();
        for i in 0..n {
            let start = text.len();
            text.push_str(&format!("第{}章\n", i + 1));
            let body_start = text.len();
            text.push_str(&body(i));
            out.push(Chapter {
                index: i,
                number: Some(i as u64 + 1),
                title: format!("第{}章", i + 1),
                span: Span { start, end: text.len() },
                body_start,
            });
        }
        (text, out)
    }

    #[test]
    fn a_line_pasted_into_most_chapters_is_found_whatever_its_number() {
        let (text, ch) = chapters(40, |i| {
            format!(
                "他抬起头来，看着远处的山。\n喜欢本书的朋友请到某某读书免费追更第{i}章\n他深深地吸了一口气，没有说话。\n{}\n",
                if i % 9 == 0 { "这一句只出现在少数几章里面而已。" } else { "风吹过来。" }
            )
        });
        let groups = find(&text, &ch);
        let ad = groups.iter().find(|g| g.label.contains("追更")).unwrap();
        assert_eq!((ad.kind, ad.items.len(), ad.checked), (Kind::Repeated, 40, true));
        // A refrain of the story's own is offered, not ticked.
        let refrain = groups.iter().find(|g| g.label.contains("吸了一口气")).unwrap();
        assert!(!refrain.checked);
        assert!(!groups.iter().any(|g| g.label.contains("少数几章")));
        // Titles are never a finding.
        assert!(!groups.iter().any(|g| g.label.starts_with('第')));
        let cut = Cuts::new(groups.iter().filter(|g| g.checked).flat_map(|g| g.items.iter().flat_map(|f| f.cuts.clone())).collect());
        let out = cut.apply(&text);
        assert!(!out.contains("追更") && out.contains("第40章\n他抬起头来"));
    }

    #[test]
    fn the_readers_phrase_goes_inside_a_line_and_takes_a_line_of_its_own() {
        let (text, ch) = chapters(3, |i| format!("他笑了。【书友群号{i}23】她也笑了。\n【书友群号{i}23】\n"));
        // The phrase itself where it is written, and a line of the same words
        // with another number wherever one stands alone.
        let g = find_phrase(&text, &ch, "【书友群号123】");
        assert_eq!(g.items.len(), 4);
        assert_eq!(g.items.iter().filter(|f| f.whole).count(), 3);
        let out = Cuts::new(g.items.iter().flat_map(|f| f.cuts.clone()).collect()).apply(&text);
        assert!(out.contains("第2章\n他笑了。她也笑了。\n第3章"));
    }

    #[test]
    fn cuts_map_both_ways() {
        let text = "甲乙\n广告\n丙丁\n广告\n戊";
        let ad = |n: usize| {
            let at = text.match_indices("广告").nth(n).unwrap().0;
            at..at + "广告\n".len()
        };
        let cuts = Cuts::new(vec![ad(1), ad(0)]);
        let out = cuts.apply(text);
        assert_eq!(out, "甲乙\n丙丁\n戊");
        // The start of 丙 in the cut text is the start of 丙 in the original.
        assert_eq!(cuts.back(out.find('丙').unwrap()), text.find('丙').unwrap());
        assert_eq!(cuts.forward(text.find('丙').unwrap()), out.find('丙').unwrap());
        // A byte inside a cut lands where the cut was.
        assert_eq!(cuts.forward(ad(0).start + 3), ad(0).start);
        // A second round of cuts, given in the cut text, joins the first.
        let at = out.find('丙').unwrap();
        let more = cuts.and(&[at..at + "丙丁\n".len()]);
        assert_eq!(more.apply(text), "甲乙\n戊");
        assert_eq!(more.ranges().len(), 1);
    }
}
