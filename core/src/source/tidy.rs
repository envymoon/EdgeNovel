//! What the rules extract is what the site printed, and sites print more than
//! the book: their own address glued under every chapter, a "本章未完" where the
//! second page should have been, a "最新章节" block stacked on top of every page
//! of the table of contents. The sheet's `replaceRegex` catches some of it when
//! its author bothered. This catches the kinds that every site does the same way.
//!
//! The rule for prose is: whole lines only, and only lines that cannot be the
//! book. An author's 求月票 is the book, however much it reads like an advert.

use super::rule::page_key;
use super::TocEntry;
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// A web address, or a bare domain on one of the endings these sites live on.
static ADDR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)https?://|www\.|\b[a-z0-9][a-z0-9-]*\.(com|net|org|cc|la|info|pw|me|xyz|top|vip|cn|tw|io|co|so|biz|site|club|tv|cx|in|us|wang|ink|link|online|live|app|work|fun|icu|cyou|lol)\b",
    )
    .unwrap()
});

/// Words that turn a long line with an address in it into an advert.
static AD_WORDS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"网址|域名|地址|网站|本站|书签|收藏|手机版|最新章节|最快更新|首发|访问|浏览器").unwrap()
});

/// Lines every site of a kind prints the same way: page furniture, not prose.
static FURNITURE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"加入书签|方向键.{0,12}翻页|上一章.{0,10}下一章|章节报错|章节错误|一秒记住|记住本站|收藏本站|本站地址|最新网址|首发域名|最新域名|最快更新|无弹窗|请记住本书|手机用户请|手机版阅读|扫描二维码|二维码访问|最新章节[！!]?$|最新章节全网首发|^未完待续\W*$|^[（(]本章完[)）]$|^[A-Za-z_][A-Za-z0-9_]*\(.*\);?$",
    )
    .unwrap()
});

/// "There is a next page" — said by a page whose next page we did not read.
static CUT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[（(]?\s*(本章未完|本章没完)[^）)\n]{0,12}[）)]?|[（(]?\s*(请)?点击下一页继续阅读[）)]?|-->>")
        .unwrap()
});

/// The site's own notice spliced into the text where a piece of it failed:
/// 「转码失败！请您使用右上换源切换源站阅读」 between two scenes.
static GAP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"转码失败|正在手打中|内容更新后[，,]?\s*请重新刷新|请重新刷新页面").unwrap()
});

/// Cleaned text, and whether the site told us there was more of it — a "本章未
/// 完" on the last line means the page that follows is one we never read, and
/// a 「转码失败」 between two scenes is a piece of the chapter it did not send.
pub fn scrub(text: &str) -> (String, bool) {
    let mut gap = false;
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| strip_asides(MARKUP.replace_all(l, "").trim()))
        .map(|l| SIGN_OFF.replace(&l, "").trim().to_string())
        .map(|l| GLUED.replace(&l, "").to_string())
        .filter(|l| {
            let notice = l.chars().count() < 80 && GAP.is_match(l);
            gap |= notice;
            !notice
        })
        .filter(|l| !l.is_empty() && !is_furniture(l))
        .collect();
    // 「庆余年 作者:猫腻」「作者：未知」 heading the chapter is the site's
    // header. Only at the top: further down 「作者：」 may be the author talking.
    let mut i = 0;
    while i < lines.len().min(2) {
        if BYLINE.is_match(&lines[i]) {
            lines.remove(i);
        } else {
            i += 1;
        }
    }
    let cut = lines.last().is_some_and(|l| CUT.is_match(l));
    let out = lines
        .iter()
        .map(|l| CUT.replace_all(l, "").trim().to_string())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    (out, cut || gap)
}

/// A bracketed aside, short enough to be a signature.
static ASIDE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[（(【\[][^（()）【】\[\]]{1,60}[)）】\]]").unwrap());

/// Markup the text came wrapped in: 「<font color=red>」, a stray 「br />」.
static MARKUP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"</?[A-Za-z][A-Za-z0-9]*(?:\s[^<>]{0,80})?\s*/?>|^\s*[A-Za-z]+\s*/>\s*$").unwrap()
});

/// The old platform sign-off glued to the last sentence: 「(未完待续，如欲知后事
/// 如何，请登陆…」. Not a page we missed: the chapter ends there.
static SIGN_OFF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[（(]\s*未完待续.*$").unwrap());

/// The site's address header glued to the front of a paragraph, its address
/// already gone: 「笔趣阁已启用最新域名：萧炎蝎山等人皆是连忙抬头」.
static GLUED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[^，。！？“”\s]{0,10}?(已启用)?最新(域名|网址)[:：]\s*").unwrap()
});

/// A site's header line: the book and its author, or just the author.
static BYLINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\S{0,20}\s*作者[:：]\s*\S{0,12}$").unwrap());

/// A site's mark in brackets: 「(三七中文et)」.
static WATERMARK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(小说|中文|文学|书屋|书库|书吧|书城)[网站]?\s*[A-Za-z]{1,8}\s*[)）】\]]$").unwrap()
});

/// 「…驱逐。(飞速小说网 www／feisuxs.com)」: the site signs a sentence of the
/// story. The brackets with an address or a site's name in them go; the
/// sentence stays.
fn strip_asides(line: &str) -> String {
    ASIDE
        .replace_all(line, |c: &regex::Captures| {
            if ADDR.is_match(&c[0]) || WATERMARK.is_match(&c[0]) {
                String::new()
            } else {
                c[0].to_string()
            }
        })
        .trim()
        .to_string()
}

fn is_furniture(line: &str) -> bool {
    let n = line.chars().count();
    // An address inside a sentence of the story stays; an address that is the
    // whole line, or comes with "网址"/"收藏" around it, is the site talking.
    if n < 150 && ADDR.is_match(line) {
        let words = ADDR
            .replace_all(line, "")
            .chars()
            .filter(|c| ('\u{4e00}'..='\u{9fff}').contains(c))
            .count();
        if words < 6 || AD_WORDS.is_match(line) {
            return true;
        }
    }
    n < 80 && FURNITURE.is_match(line)
}

/// A teaser, not a chapter: a few lines trailing off into "...". Sites that
/// keep the full text behind a login or a script serve exactly this to us.
pub fn is_preview(text: &str) -> bool {
    let t = text.trim_end();
    t.chars().count() < 500 && (t.ends_with("...") || t.ends_with('…'))
}

/// What a site says instead of a chapter, in the chapter's place.
static NOTICE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"转码失败|换源|源站|正在手打|手打中|稍等片刻|稍后再试|刷新页面|重新刷新|内容更新后|加载失败|访问过于频繁|登录后|订阅后|购买本章|VIP章节",
    )
    .unwrap()
});

/// A notice, not a chapter: 「转码失败！请您使用右上换源切换源站阅读」「正在手打
/// 中，请稍等片刻，内容更新后，请重新刷新页面」. Short, and saying so. An author's
/// short note says something else.
pub fn is_notice(text: &str) -> bool {
    text.chars().count() < 200 && NOTICE.is_match(text)
}

static CHAPTER_NO: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"第\s*([0-9０-９零〇一二两三四五六七八九十百千万]+)\s*[章回节]").unwrap()
});

/// 「1、庙会」「0003. 倒计时」: the number up front, set off by punctuation, the
/// way many sites write what others write as 第一章.
static LEADING_NO: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*([0-9０-９]+)\s*[、.．:：]\s*").unwrap());

/// The number in 「第一千零三章」, 「第1003章」 or 「1003、」.
pub fn chapter_number(title: &str) -> Option<u64> {
    let m = CHAPTER_NO.captures(title).or_else(|| LEADING_NO.captures(title))?;
    let s: String = m[1]
        .chars()
        .map(|c| match c {
            '０'..='９' => char::from(b'0' + (c as u32 - '０' as u32) as u8),
            _ => c,
        })
        .collect();
    if let Ok(n) = s.parse() {
        return Some(n);
    }
    let digit = |c| match c {
        '零' | '〇' => Some(0),
        '两' => Some(2),
        _ => "一二三四五六七八九".chars().position(|d| d == c).map(|i| i as u64 + 1),
    };
    let (mut total, mut section, mut num) = (0u64, 0u64, 0u64);
    for c in s.chars() {
        if let Some(d) = digit(c) {
            num = d;
            continue;
        }
        let unit = match c {
            '十' => 10,
            '百' => 100,
            '千' => 1000,
            '万' => 10000,
            _ => return None,
        };
        if unit == 10000 {
            total += (section + num) * 10000;
            section = 0;
        } else {
            section += (if num == 0 { 1 } else { num }) * unit;
        }
        num = 0;
    }
    Some(total + section + num)
}

static BRACKETED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"（[^）]*）|\([^)]*\)|【[^】]*】|\[[^\]]*\]").unwrap());

/// 「（上）」「（三）」「(10)」: a bracket that says which part, and is part of
/// the name; every other bracket (求月票, 第二更, 修) is decoration.
static PART: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9０-９零〇一二两三四五六七八九十百上中下]+$").unwrap());

/// The words a chapter is called by, with its number and decoration taken off.
/// What follows 第N章 is the name, and what comes before it a volume; a title
/// with nothing after the number (「书名 第12节」) has only the before.
fn name_words(title: &str) -> Vec<String> {
    let t = BRACKETED.replace_all(title, |c: &regex::Captures| {
        let inner: String = {
            let mut cs = c[0].chars();
            cs.next();
            cs.next_back();
            cs.as_str().trim().to_string()
        };
        if PART.is_match(&inner) {
            inner
        } else {
            String::new()
        }
    });
    let alnum = |s: &str| s.chars().any(char::is_alphanumeric);
    let part = if let Some(m) = CHAPTER_NO.find(&t) {
        if alnum(&t[m.end()..]) {
            &t[m.end()..]
        } else {
            &t[..m.start()]
        }
    } else if let Some(m) = LEADING_NO.find(&t) {
        &t[m.end()..]
    } else {
        &t
    };
    part.split_whitespace()
        .map(|w| {
            w.chars()
                .filter(|c| c.is_alphanumeric())
                .flat_map(char::to_lowercase)
                .collect::<String>()
        })
        .filter(|w| !w.is_empty())
        .collect()
}

/// What a chapter is called, so that one site's 「第176章 神秘的残破图片（求收
/// 藏）」, another's 「176、神秘的残破图片」 and a third's 「第三卷 风起 第一百七
/// 十五章 神秘的残破图片？」 come out the same, while 「户部之事（上）」 and
/// 「（下）」 stay two. The number is left out on purpose: sites number the same
/// book differently, and on a real book matching by the number alone took 「交
/// 换」 for 「神秘的残破图片」.
pub fn chapter_name(title: &str) -> String {
    name_words(title).concat()
}

/// The last word of the name: what is left when a site puts the volume after
/// the number — 「第639章 名震一方 灵眼之树」 is another site's 「第六百一十五章
/// 灵眼之树」. Only a word that is more than a number or a single character.
fn last_word(title: &str) -> Option<String> {
    let w = name_words(title).pop()?;
    (w.chars().filter(|c| !c.is_ascii_digit()).count() >= 2).then_some(w)
}

/// Where chapters `wanted` of `ours` sit in another site's list `theirs`, as
/// (ours, theirs) index pairs. By name when the name is one chapter on both
/// sites; a name that repeats (番外, 求月票), or is a single character, also
/// needs its number to agree. Failing both, by the last word of the name, if
/// that is one chapter on both sites and sits at about the same place in both.
/// Never by number alone: sites number the same book differently, and a wrong
/// chapter in the right place is worse than a hole that says it is one.
pub fn pair_chapters(ours: &[TocEntry], wanted: &[usize], theirs: &[TocEntry]) -> Vec<(usize, usize)> {
    fn index(list: &[TocEntry], key: impl Fn(&str) -> Option<String>) -> HashMap<String, Option<usize>> {
        let mut m: HashMap<String, Option<usize>> = HashMap::new();
        for (j, c) in list.iter().enumerate() {
            if let Some(k) = key(&c.title) {
                m.entry(k).and_modify(|v| *v = None).or_insert(Some(j));
            }
        }
        m
    }
    let full = |t: &str| Some(chapter_name(t)).filter(|k| k.chars().count() >= 2);
    let (our_names, their_names) = (index(ours, full), index(theirs, full));
    let (our_last, their_last) = (index(ours, last_word), index(theirs, last_word));
    let mut numbered: HashMap<(u64, String), usize> = HashMap::new();
    for (j, c) in theirs.iter().enumerate() {
        if let Some(n) = chapter_number(&c.title) {
            numbered.entry((n, chapter_name(&c.title))).or_insert(j);
        }
    }
    let unique = |mine: &HashMap<String, Option<usize>>, other: &HashMap<String, Option<usize>>, k: &str| {
        match mine.get(k) {
            Some(Some(_)) => other.get(k).copied().flatten(),
            _ => None,
        }
    };
    // Lists of one book differ by prefaces, notes and a few renumbered
    // stretches, not by a tenth of the book.
    let near = |i: usize, j: usize| {
        let (a, b) = (i as f64 / ours.len() as f64, j as f64 / theirs.len().max(1) as f64);
        (a - b).abs() < 0.1
    };
    wanted
        .iter()
        .filter_map(|&i| {
            let t = &ours[i].title;
            // 「第七章 休！」: a one-character name is too common to go by
            // alone, but with its number agreeing it is still that chapter.
            let name = chapter_name(t);
            if name.is_empty() {
                return None;
            }
            let j = unique(&our_names, &their_names, &name)
                .or_else(|| numbered.get(&(chapter_number(t)?, name)).copied())
                .or_else(|| unique(&our_last, &their_last, &last_word(t)?).filter(|&j| near(i, j)))?;
            Some((i, j))
        })
        .collect()
}

/// The pages of a paginated table of contents, joined in page order.
///
/// Pages are found by following links, and a pagination bar shows a window of
/// them — 「1 2 3 4 5 … 13」 — so the order they are found in is not the
/// order of the book: one site's lists came back 1–300, 1200–1211, 301–400,
/// 900–1199… Pages are put in the order of the numbers in their addresses,
/// but only when that makes the chapter numbers run in order more often than
/// the order they were found in; a site whose addresses say nothing keeps it.
pub fn in_page_order(mut pages: Vec<(String, Vec<TocEntry>)>) -> Vec<TocEntry> {
    let descents = |pages: &[(String, Vec<TocEntry>)]| {
        let nums: Vec<u64> = pages.iter().flat_map(|(_, e)| e).filter_map(|c| chapter_number(&c.title)).collect();
        nums.windows(2).filter(|w| w[1] < w[0]).count()
    };
    if pages.len() > 2 {
        let key = |u: &str| -> Vec<u64> {
            u.split(|c: char| !c.is_ascii_digit())
                .filter(|s| !s.is_empty())
                .map(|s| s.get(s.len().saturating_sub(18)..).unwrap_or(s).parse().unwrap_or(0))
                .collect()
        };
        let mut sorted = pages.clone();
        sorted.sort_by(|(a, _), (b, _)| {
            let (a, b) = (key(a), key(b));
            (0..a.len().max(b.len()))
                .map(|i| a.get(i).unwrap_or(&0).cmp(b.get(i).unwrap_or(&0)))
                .find(|o| o.is_ne())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        if descents(&sorted) < descents(&pages) {
            pages = sorted;
        }
    }
    pages.into_iter().flat_map(|(_, e)| e).collect()
}

/// The longest run of entries at the top of the list that the site repeats, if
/// it looks like a "最新章节" block rather than the book.
const MAX_BLOCK: usize = 30;

/// A table of contents in reading order, each chapter once.
///
/// Three things sites do to it, all measured on real lists:
/// - a block of the newest chapters, newest first, on top of *every page* of a
///   paginated list, so a 1669-chapter book came back with 2509 entries;
/// - the same block on top of a single-page list, so the book opens on its
///   final chapter;
/// - the list newest-first, or the last page linking back to the first.
pub fn tidy_toc(list: Vec<TocEntry>) -> Vec<TocEntry> {
    let list = drop_page_headers(list);
    let list = drop_latest_block(list);
    let mut seen = HashSet::new();
    let mut out: Vec<TocEntry> = list
        .into_iter()
        .filter(|c| seen.insert(page_key(&c.url)))
        .collect();
    if runs_backwards(&out) {
        out.reverse();
    }
    out
}

/// A block that heads every page: the entries at the top that occur three
/// times or more. Every verbatim copy goes; the chapters themselves are still
/// listed in their proper place further down, in a different order.
fn drop_page_headers(list: Vec<TocEntry>) -> Vec<TocEntry> {
    let keys: Vec<String> = list.iter().map(|c| page_key(&c.url)).collect();
    let mut count: HashMap<&str, usize> = HashMap::new();
    for k in &keys {
        *count.entry(k).or_default() += 1;
    }
    let k = keys.iter().take_while(|u| count[u.as_str()] >= 3).count();
    if k == 0 || k > MAX_BLOCK {
        return list;
    }
    let block = &keys[..k];
    let mut covered = vec![false; keys.len()];
    let mut copies = Vec::new();
    let mut i = 0;
    while i + k <= keys.len() {
        if keys[i..i + k] == *block {
            copies.push(i);
            covered[i..i + k].iter_mut().for_each(|c| *c = true);
            i += k;
        } else {
            i += 1;
        }
    }
    let elsewhere: HashSet<&str> = keys
        .iter()
        .zip(&covered)
        .filter(|(_, c)| !**c)
        .map(|(k, _)| k.as_str())
        .collect();
    // If the block is the only place some chapter is listed, its last copy is
    // where that chapter lives.
    if !block.iter().all(|u| elsewhere.contains(u.as_str())) {
        if let Some(&last) = copies.last() {
            covered[last..last + k].iter_mut().for_each(|c| *c = false);
        }
    }
    list.into_iter()
        .zip(covered)
        .filter(|(_, c)| !c)
        .map(|(e, _)| e)
        .collect()
}

/// A block of the newest chapters on top of a one-page list. Told apart from a
/// list that merely repeats itself by its numbers: every numbered entry in it is
/// past the chapter that follows it.
fn drop_latest_block(list: Vec<TocEntry>) -> Vec<TocEntry> {
    let keys: Vec<String> = list.iter().map(|c| page_key(&c.url)).collect();
    let mut count: HashMap<&str, usize> = HashMap::new();
    for k in &keys {
        *count.entry(k).or_default() += 1;
    }
    let k = keys.iter().take_while(|u| count[u.as_str()] >= 2).count();
    if k == 0 || k > MAX_BLOCK || k * 3 > count.len() {
        return list;
    }
    let Some(next) = list[k..].iter().find_map(|c| chapter_number(&c.title)) else {
        return list;
    };
    let nums: Vec<u64> = list[..k].iter().filter_map(|c| chapter_number(&c.title)).collect();
    if nums.is_empty() || nums.iter().any(|&n| n <= next) {
        return list;
    }
    list.into_iter().skip(k).collect()
}

/// Newest first: numbered neighbours go down far more often than up.
fn runs_backwards(list: &[TocEntry]) -> bool {
    let nums: Vec<u64> = list.iter().filter_map(|c| chapter_number(&c.title)).collect();
    let down = nums.windows(2).filter(|w| w[1] < w[0]).count();
    let up = nums.windows(2).filter(|w| w[1] > w[0]).count();
    down >= 5 && down > up * 3
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toc(rows: &[(&str, &str)]) -> Vec<TocEntry> {
        rows.iter()
            .map(|(t, u)| TocEntry {
                title: t.to_string(),
                url: format!("https://a.example/{u}.html"),
            })
            .collect()
    }

    fn titles(v: &[TocEntry]) -> Vec<&str> {
        v.iter().map(|c| c.title.as_str()).collect()
    }

    #[test]
    fn site_adverts_go_and_prose_stays() {
        let raw = "萧炎抬起头。\n请记住本书首发域名：www.rulianshi.cc。手机版阅读网址：m.rulianshi.cc\n\
                   最新网址：m.rulianshi.cc\n上一章返回目录下一章\n\
                   加入书签温馨提示：方向键左右(← →)前后翻页\nread3();\n\
                   弟兄们，请将月票投给土豆！\n他笑了。";
        let (out, cut) = scrub(raw);
        assert_eq!(out, "萧炎抬起头。\n弟兄们，请将月票投给土豆！\n他笑了。");
        assert!(!cut);

        let (out, _) = scrub("将黑暗彻底驱逐。(飞速小说网 www／feisuxs.com)\n（他笑了）");
        assert_eq!(out, "将黑暗彻底驱逐。\n（他笑了）");

        let raw = "庆余年 作者:猫腻\n范闲笑了。(三七中文et)\n\
                   <font color=red>笔趣阁</font>已启用最新域名： ，请大家牢记最新域名并相互转告，谢谢！</p>\n\
                   手机浏览器扫描二维码访问\nbr />\n他盘膝坐下了！(未完待续，如欲知后事如何，请登陆<a href=\n(本章完)";
        assert_eq!(scrub(raw).0, "范闲笑了。\n他盘膝坐下了！");
        let raw = "笔趣阁已启用最新域名：萧炎等人皆是连忙抬头。\n“终于要现身了么”\n未完待续:";
        assert_eq!(scrub(raw), ("萧炎等人皆是连忙抬头。\n“终于要现身了么”".into(), false));
        assert_eq!(scrub("夜的命名术 第96节\n作者：未知\n庆尘笑了。").0, "夜的命名术 第96节\n庆尘笑了。");
        // Further down, 「作者：」 is the author talking.
        let note = "他走了。\n他笑了。\n作者：今天请假一天";
        assert_eq!(scrub(note).0, note);

        // The story is allowed to mention the internet.
        let prose = "他打开电脑，在搜索框里输入了www.baidu.com。\n他按下方向键，角色向前冲去。";
        assert_eq!(scrub(prose).0, prose);
    }

    #[test]
    fn a_page_that_says_it_continues_is_cut() {
        let (out, cut) = scrub("新人相拥，（本章未完，请翻页）");
        assert_eq!(out, "新人相拥，");
        assert!(cut);
        // The same words in the middle are a page we did read past.
        let (_, cut) = scrub("第一页（本章未完，请翻页）\n第二页的内容在这里，已经接上了，没有断，后面还有很长很长很长很长很长很长很长很长很长很长的一段话。");
        assert!(!cut);
    }

    #[test]
    fn a_teaser_is_not_a_chapter() {
        assert!(is_preview("其他人看着金银二老的动作，头..."));
        assert!(!is_preview("心爱之人，天各一方，唯有一轮明月，静寄相思。"));
    }

    #[test]
    fn a_notice_is_not_a_chapter() {
        assert!(is_notice("转码失败！请您使用右上换源切换源站阅读或者直接前往源网站进行阅读！"));
        assert!(is_notice("本章想法 《冬日重现》八月番外 正在手打中，请稍等片刻，内容更新后，请重新刷新页面"));
        assert!(!is_notice("请假一天，明天两更补上。"));
    }

    /// The same notice between two scenes: the line goes, and the chapter is
    /// short of whatever it stood in for.
    #[test]
    fn a_notice_inside_the_text_is_a_gap() {
        let (out, gap) = scrub("“明白了，嗯，从南阳一路过来……”\n……\n转码失败！请您使用右上换源切换源站阅读或者直接前往源网站进行阅读！\n时过三更，南召县北侧的黑虎庙附近。");
        assert_eq!(out, "“明白了，嗯，从南阳一路过来……”\n……\n时过三更，南召县北侧的黑虎庙附近。");
        assert!(gap);
        let (_, gap) = scrub("“请稍等片刻。”侍女福了一福，转身进了内院。");
        assert!(!gap);
    }

    #[test]
    fn chapter_numbers_in_both_scripts() {
        assert_eq!(chapter_number("第一千五百九十三章 古帝洞府所在"), Some(1593));
        assert_eq!(chapter_number("第1593章 古帝洞府所在"), Some(1593));
        assert_eq!(chapter_number("第十章 借钱"), Some(10));
        assert_eq!(chapter_number("第一百零三章"), Some(103));
        assert_eq!(chapter_number("感言。"), None);
        assert_eq!(chapter_number("1003、后记（完）"), Some(1003));
        assert_eq!(chapter_number("0003. 倒计时"), Some(3));
        assert_eq!(chapter_number("1984"), None);
        assert_eq!(chapter_name("第1章 陨落的天才（求收藏）"), "陨落的天才");
        assert_eq!(chapter_name("第一章  陨落的天才！"), "陨落的天才");
        assert_eq!(chapter_name("332、好消息与坏消息（第三更）"), "好消息与坏消息");
        assert_eq!(chapter_name("第四卷北海雾　第十二章　科场弊案"), "科场弊案");
        assert_eq!(chapter_name("夜的命名术 第12节"), "夜的命名术");
    }

    fn names(titles: &[&str], site: &str) -> Vec<TocEntry> {
        titles
            .iter()
            .enumerate()
            .map(|(i, t)| TocEntry {
                title: t.to_string(),
                url: format!("https://{site}/{i}.html"),
            })
            .collect()
    }

    /// Two sites number the same book differently; the chapter is found by its
    /// name all the same.
    #[test]
    fn chapters_pair_up_by_name() {
        let ours = names(&["第一章 陨落的天才（求收藏）", "第二章 斗气大陆", "第三章 客人"], "a");
        let theirs = names(&["序", "第1章 陨落的天才", "第2章 斗气大陆", "第4章 客人！"], "b");
        assert_eq!(pair_chapters(&ours, &[0, 2], &theirs), [(0, 1), (2, 3)]);
    }

    /// The same number with a different name is a different chapter.
    #[test]
    fn a_number_alone_is_not_a_match() {
        let ours = names(&["第一百七十六章 神秘的残破图片？"], "a");
        let theirs = names(&["第一百七十六章 交换"], "b");
        assert!(pair_chapters(&ours, &[0], &theirs).is_empty());
    }

    /// 「休」 is too short to trust alone, and fine with its number agreeing.
    #[test]
    fn a_one_character_name_needs_its_number() {
        let ours = names(&["第七章 休！", "第九章 装"], "a");
        let theirs = names(&["第7章 休", "第10章 装"], "b");
        assert_eq!(pair_chapters(&ours, &[0, 1], &theirs), [(0, 0)]);
    }

    /// Which half is part of the name: 上 and 下 are two chapters, on sites
    /// that number them 130 and 131 alike.
    #[test]
    fn halves_stay_apart() {
        let ours = names(&["第一百三十章 户部之事（上）", "第一百三十一章 户部之事（下）（求月票）"], "a");
        let theirs = names(&["第131章 户部之事（上）", "第132章 户部之事（下）"], "b");
        assert_eq!(pair_chapters(&ours, &[0, 1], &theirs), [(0, 0), (1, 1)]);
    }

    /// A volume name after the number: the last word of the name still finds
    /// the chapter, where it sits at about the same place.
    #[test]
    fn a_volume_after_the_number_falls_back_to_the_last_word() {
        let ours = names(&["第1章 山边小村", "第639章 名震一方 灵眼之树", "第640章 名震一方 再见"], "a");
        let theirs = names(&["第一章 山边小村", "第六百一十五章 灵眼之树", "第六百一十六章 再见"], "b");
        assert_eq!(pair_chapters(&ours, &[0, 1, 2], &theirs), [(0, 0), (1, 1), (2, 2)]);
        // Far from where it should be, it is some other chapter.
        let far = names(&["第一章 灵眼之树", "第二章 甲", "第三章 乙", "第四章 丙", "第五章 丁", "第六章 戊"], "c");
        assert!(pair_chapters(&ours, &[1], &far).is_empty());
    }

    /// A name that repeats is told apart by its number.
    #[test]
    fn a_repeated_name_needs_its_number() {
        let ours = names(&["第10章 番外", "第20章 番外"], "a");
        let theirs = names(&["第20章 番外", "第10章 番外"], "b");
        assert_eq!(pair_chapters(&ours, &[0, 1], &theirs), [(0, 1), (1, 0)]);
    }

    /// Pages found through a windowed pagination bar go back in page order;
    /// pages whose addresses do not help keep the order they came in.
    #[test]
    fn pages_go_back_in_page_order() {
        let page = |u: &str, from: u32| {
            let e = (from..from + 2)
                .map(|n| TocEntry { title: format!("第{n}章 某{n}"), url: format!("https://a.example/c/{n}.html") })
                .collect::<Vec<_>>();
            (format!("https://a.example/book/7/{u}"), e)
        };
        let found = vec![page("", 1), page("index_2.html", 3), page("index_13.html", 25), page("index_3.html", 5)];
        let nums: Vec<u64> = in_page_order(found).iter().filter_map(|c| chapter_number(&c.title)).collect();
        assert_eq!(nums, [1, 2, 3, 4, 5, 6, 25, 26]);

        // Addresses that would put the pages out of order are not believed.
        let found = vec![page("p9", 1), page("p3", 3), page("p5", 5)];
        let nums: Vec<u64> = in_page_order(found).iter().filter_map(|c| chapter_number(&c.title)).collect();
        assert_eq!(nums, [1, 2, 3, 4, 5, 6]);
    }

    /// The shape 森林文学 serves: every page opens with the same newest-first
    /// block, and the real entries for those chapters sit on the last page.
    #[test]
    fn a_block_on_every_page_goes() {
        let list = toc(&[
            ("第三章", "3"), ("第二章", "2"),
            ("第一章", "1"),
            ("第三章", "3"), ("第二章", "2"),
            ("第二章", "2"), ("第三章", "3"),
            ("第三章", "3"), ("第二章", "2"),
        ]);
        assert_eq!(titles(&tidy_toc(list)), ["第一章", "第二章", "第三章"]);
    }

    /// The shape 35小说网 serves: one page, the newest chapters on top.
    #[test]
    fn a_latest_block_on_one_page_goes() {
        let list = toc(&[
            ("第九章", "9"), ("第八章", "8"),
            ("第一章", "1"), ("第二章", "2"), ("第三章", "3"), ("第四章", "4"),
            ("第五章", "5"), ("第六章", "6"), ("第七章", "7"),
            ("第八章", "8"), ("第九章", "9"),
        ]);
        assert_eq!(
            titles(&tidy_toc(list)),
            ["第一章", "第二章", "第三章", "第四章", "第五章", "第六章", "第七章", "第八章", "第九章"]
        );
    }

    /// A list that repeats itself from the start is not a latest block: the
    /// first copy is the book.
    #[test]
    fn a_list_that_wraps_around_keeps_its_start() {
        let list = toc(&[
            ("第一章", "1"), ("第二章", "2"), ("第三章", "3"), ("第四章", "4"),
            ("第五章", "5"), ("第六章", "6"), ("第七章", "7"),
            ("第一章", "1"), ("第二章", "2"),
        ]);
        assert_eq!(
            titles(&tidy_toc(list)),
            ["第一章", "第二章", "第三章", "第四章", "第五章", "第六章", "第七章"]
        );
    }

    #[test]
    fn newest_first_is_turned_round() {
        let list = toc(&[
            ("第七章", "7"), ("第六章", "6"), ("第五章", "5"), ("第四章", "4"),
            ("第三章", "3"), ("第二章", "2"), ("第一章", "1"),
        ]);
        assert_eq!(titles(&tidy_toc(list))[0], "第一章");
    }
}
