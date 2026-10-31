use crate::fingerprint::{Fingerprint, ParagraphStyle};
use crate::is_indented;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Template {
    /// 第N章 / 第N节 / 第N卷 …
    Ordinal,
    /// A bare number on its own line.
    BareNumber,
    /// N.标题 / N、标题
    NumberDot,
    /// 楔子 / 序章 / 番外 / 大结局 …
    Named,
}

/// `第三卷` and `第三章` look alike and mean different things. Merging them puts
/// volume headers in the chapter list and, worse, feeds volume numbers into the
/// chapter numbering check, where a book's third volume looks like a wild jump
/// backwards from its 900th chapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Volume,
    Chapter,
}

#[derive(Debug, Clone)]
pub struct Candidate {
    pub line_idx: usize,
    pub text: String,
    pub template: Template,
    pub level: Level,
    pub number: Option<u64>,
    /// Where in the line the chapter starts. Zero but for a title glued to the end
    /// of the sentence before it; that sentence stays with the chapter it ended.
    pub in_line: usize,
}

/// Lines that are not body text. In an indent-styled book this is exact: body
/// paragraphs are indented, everything else (titles, ads, author notes) is flush.
fn structural_lines<'a>(text: &'a str, fp: &Fingerprint) -> Vec<(usize, &'a str)> {
    text.split('\n')
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty())
        .filter(|(_, l)| match fp.style {
            ParagraphStyle::Indent => !is_indented(l),
            _ => l.trim().chars().count() <= 40,
        })
        .collect()
}

fn cn_numeral(s: &str) -> Option<u64> {
    const DIGITS: [(char, u64); 13] = [
        ('〇', 0),
        ('零', 0),
        ('一', 1),
        ('二', 2),
        ('两', 2),
        ('三', 3),
        ('四', 4),
        ('五', 5),
        ('六', 6),
        ('七', 7),
        ('八', 8),
        ('九', 9),
        ('十', 10),
    ];
    let digit = |c: char| DIGITS.iter().find(|(d, _)| *d == c).map(|(_, v)| *v);

    // 第一零二章 is written digit by digit, and is not chapter 2.
    if s.chars().count() > 1 && !s.contains(['十', '百', '千', '万']) {
        return s.chars().try_fold(0u64, |n, c| Some(n * 10 + digit(c)?));
    }

    let (mut total, mut section, mut current, mut saw) = (0u64, 0u64, 0u64, false);
    for c in s.chars() {
        match c {
            '万' => {
                total += (section + current) * 10_000;
                section = 0;
                current = 0;
            }
            '千' => {
                section += current.max(1) * 1000;
                current = 0;
            }
            '百' => {
                section += current.max(1) * 100;
                current = 0;
            }
            '十' => {
                section += current.max(1) * 10;
                current = 0;
            }
            _ => current = digit(c)?,
        }
        saw = true;
    }
    saw.then(|| total + section + current)
}

fn parse_number(s: &str) -> Option<u64> {
    if s.is_empty() {
        return None;
    }
    if s.chars().all(|c| c.is_ascii_digit()) {
        return s.parse().ok();
    }
    if s.chars().all(|c| c.is_ascii_digit() || is_wide_digit(c)) {
        let narrow: String = s
            .chars()
            .map(|c| if is_wide_digit(c) { (c as u32 - 0xFEE0) as u8 as char } else { c })
            .collect();
        return narrow.parse().ok();
    }
    cn_numeral(s)
}

const NAMED: &[&str] = &[
    "楔子",
    "序章",
    "序言",
    "引子",
    "尾声",
    "后记",
    "番外",
    "大结局",
    "终章",
];

const CHAPTER_UNITS: &str = "章节節回幕";
const VOLUME_UNITS: &str = "卷部篇集";

/// 宰执天下's 第１１章.
fn is_wide_digit(c: char) -> bool {
    ('０'..='９').contains(&c)
}

fn is_numeral_char(c: char) -> bool {
    c.is_ascii_digit() || is_wide_digit(c) || "〇零一二两三四五六七八九十百千万".contains(c)
}

/// A chapter title that names its volume first: 许仙志's 第六卷 伊人倚红妆 第五章
/// 地府, 官道无疆's 第二卷东方欲晓第一百零五节魔怔, 最长的一梦's 第三卷过去时现在时181周日.
/// Read as volume headers, every chapter of those books vanished into whatever
/// chapter came before them.
fn chapter_after_volume(chars: &[char]) -> Option<(Template, Level, Option<u64>)> {
    if chars[0] != '第' {
        return None;
    }
    let unit = chars[1..].iter().position(|c| !is_numeral_char(*c))? + 1;
    if unit == 1 || !VOLUME_UNITS.contains(*chars.get(unit)?) {
        return None;
    }
    let name_start = unit + 1;
    // 独游's 第十卷一百二十三：我要换队友（下）, a chapter number with neither 第 nor 章.
    let bare = chars[name_start..].iter().take_while(|c| is_numeral_char(**c)).count();
    if bare > 0 && matches!(chars.get(name_start + bare), Some('：' | ':')) {
        let num: String = chars[name_start..name_start + bare].iter().collect();
        return Some((Template::Ordinal, Level::Chapter, parse_number(&num)));
    }
    let name_len = chars[name_start..]
        .iter()
        .position(|c| c.is_ascii_digit() || *c == '第')?;
    if name_len > 14 || chars[name_start..name_start + name_len].iter().any(|c| "，。！？；：,.!?;:".contains(*c)) {
        return None;
    }
    let at = name_start + name_len;
    if chars[at] == '第' {
        let digits = chars[at + 1..].iter().position(|c| !is_numeral_char(*c))? + at + 1;
        if digits == at + 1 || !CHAPTER_UNITS.contains(*chars.get(digits)?) {
            return None;
        }
        let num: String = chars[at + 1..digits].iter().collect();
        return Some((Template::Ordinal, Level::Chapter, parse_number(&num)));
    }
    let digits = chars[at..].iter().take_while(|c| c.is_ascii_digit()).count();
    // 超神机械师's 第四卷 1.0降临者 is a volume with a version number in its name.
    let version = chars[at + digits..].len() > 1 && chars[at + digits] == '.' && chars[at + digits + 1].is_ascii_digit();
    if name_len == 0 || !(1..=4).contains(&digits) || at + digits >= chars.len() || version {
        return None;
    }
    let num: String = chars[at..at + digits].iter().collect();
    Some((Template::Ordinal, Level::Chapter, num.parse().ok()))
}

/// A site's 正文 in front of the title: 正文730十年一梦今日醒, 正文 第五章 标题.
fn chapter_after_site_label(s: &str) -> Option<(Template, Level, Option<u64>)> {
    let rest = s.strip_prefix("正文")?.trim_start();
    let digits = rest.chars().take_while(|c| c.is_ascii_digit()).count();
    if (1..=4).contains(&digits) && rest.chars().count() > digits {
        return Some((Template::Ordinal, Level::Chapter, rest[..digits].parse().ok()));
    }
    classify(rest).filter(|(_, level, _)| *level == Level::Chapter)
}

/// A part's name in front of a bare chapter: 微酸学园ABC's 哈里.萊特篇 豪奢的单人旅行 第一章.
fn chapter_after_part_name(s: &str) -> Option<(Template, Level, Option<u64>)> {
    let (name, last) = s.rsplit_once(char::is_whitespace)?;
    let chars: Vec<char> = last.chars().collect();
    if name.chars().count() > 20 || name.contains(['，', '。', '！', '？', '；', '：', ',', '!', '?', ';', ':']) {
        return None;
    }
    let (&first, &end) = (chars.first()?, chars.last()?);
    if first != '第' || !CHAPTER_UNITS.contains(end) || chars.len() < 3 {
        return None;
    }
    let digits = &chars[1..chars.len() - 1];
    if !digits.iter().all(|c| is_numeral_char(*c)) {
        return None;
    }
    let num: String = digits.iter().collect();
    Some((Template::Ordinal, Level::Chapter, parse_number(&num)))
}

/// The last 第N章标题 at the end of a line with something in front of it: where it
/// starts, and its number. 一世之尊 lost its line breaks before every title:
/// PS：求推荐第二百二十五章一马平川. A title with a sentence's punctuation in it is the
/// sentence, 修订前面一个笔误，第三百六十九章“两剑合璧”是人仙，不是地仙。
fn title_at_line_end(line: &str) -> Option<(usize, Option<u64>)> {
    if !line.contains('章') {
        return None;
    }
    let s = line.trim_end();
    let from = s.char_indices().rev().nth(39).map_or(0, |(i, _)| i);
    for (i, _) in s[from..].rmatch_indices('第') {
        let at = from + i;
        let rest = &s[at + '第'.len_utf8()..];
        let digits = rest.find(|c| !is_numeral_char(c)).unwrap_or(rest.len());
        let Some(title) = rest[digits..].strip_prefix('章') else {
            continue;
        };
        if digits == 0 {
            continue;
        }
        if s[..at].trim().is_empty()
            || title.is_empty()
            || title.chars().count() > 24
            || title.contains(['，', '。', '！', '？', '；', '：', '“', '”', ',', '!', '?', ';', ':', '"'])
        {
            return None;
        }
        return Some((at, parse_number(&rest[..digits])));
    }
    None
}

fn classify(line: &str) -> Option<(Template, Level, Option<u64>)> {
    let s = line.trim();
    let chars: Vec<char> = s.chars().collect();
    if chars.is_empty() || chars.len() > 40 {
        return None;
    }

    // 魔道祖师's ☆、泼野第二2 and ☆、第25章阴鸷第六3.
    if let Some(rest) = s.strip_prefix("☆、") {
        return classify(rest)
            .filter(|(_, level, _)| *level == Level::Chapter)
            .or(Some((Template::Named, Level::Chapter, None)));
    }

    if let Some(found) = chapter_after_volume(&chars)
        .or_else(|| chapter_after_site_label(s))
        .or_else(|| chapter_after_part_name(s))
    {
        return Some(found);
    }

    if chars[0] == '第' {
        // 第<number><unit>: numerals immediately after 第, then the unit.
        // Scanning for a unit *anywhere* in the line once matched
        // "第二天早上，…赶着回家…" through the 回 of 回家.
        let num_end = chars[1..]
            .iter()
            .position(|c| !is_numeral_char(*c))
            .map_or(chars.len(), |i| i + 1);
        if num_end > 1 && num_end < chars.len() {
            let unit = chars[num_end];
            // 第二幕。他们遇到兽潮。 is the second act of something in the prose.
            let sentence = unit == '幕' && chars.get(num_end + 1).is_some_and(|c| "。，！？".contains(*c));
            if !sentence && (CHAPTER_UNITS.contains(unit) || VOLUME_UNITS.contains(unit)) {
                let level = if VOLUME_UNITS.contains(unit) {
                    Level::Volume
                } else {
                    Level::Chapter
                };
                let num: String = chars[1..num_end].iter().collect();
                return Some((Template::Ordinal, level, parse_number(&num)));
            }
        }
    }

    if chars.iter().all(|c| c.is_ascii_digit()) {
        return Some((Template::BareNumber, Level::Chapter, parse_number(s)));
    }

    // 12.标题 / 12、标题 / 12 标题 — a short number, a separator, then a real
    // title. A space is a separator too: source sites write "01 穿越", and the
    // sequence election below keeps "3 个月后" from qualifying as a chapter.
    let digits = chars.iter().take_while(|c| c.is_ascii_digit()).count();
    if (1..=4).contains(&digits)
        && digits + 1 < chars.len()
        && matches!(chars[digits], '.' | '、' | '．' | ' ' | '\u{3000}')
    {
        let num: String = chars[..digits].iter().collect();
        return Some((Template::NumberDot, Level::Chapter, num.parse().ok()));
    }

    // 天才医生's 313章、莫名其妙的功劳！, the 第 lost.
    if (1..=4).contains(&digits)
        && chars.get(digits) == Some(&'章')
        && matches!(chars.get(digits + 1), Some('、' | '：' | ':' | ' ' | '\u{3000}'))
    {
        let num: String = chars[..digits].iter().collect();
        return Some((Template::Ordinal, Level::Chapter, num.parse().ok()));
    }

    if NAMED.iter().any(|n| s.starts_with(n)) {
        return Some((Template::Named, Level::Chapter, None));
    }

    None
}

pub fn candidates(text: &str, fp: &Fingerprint) -> Vec<Candidate> {
    let mut found: Vec<Candidate> = structural_lines(text, fp)
        .into_iter()
        .filter_map(|(line_idx, l)| {
            classify(l).map(|(template, level, number)| Candidate {
                line_idx,
                text: l.trim().to_string(),
                template,
                level,
                number,
                in_line: 0,
            })
        })
        .collect();
    let heads = titles_with_a_running_head(text, &found);
    found.extend(without_echoes(heads, &found));
    let glued = titles_at_line_ends(text, &found);
    found.extend(without_echoes(glued, &found));
    found.sort_by_key(|c| c.line_idx);
    found
}

/// 斗破苍穹 prints a chapter's title twice, 第279章 and then 斗破苍穹 第两百七十九章, and
/// the second one would leave the first an empty chapter.
fn without_echoes(mut new: Vec<Candidate>, found: &[Candidate]) -> Vec<Candidate> {
    new.sort_by_key(|c| c.line_idx);
    let mut seen: Vec<(usize, Option<u64>)> = found.iter().map(|c| (c.line_idx, c.number)).collect();
    new.retain(|c| {
        let echo = seen
            .iter()
            .any(|(line, number)| *number == c.number && line.abs_diff(c.line_idx) <= 10);
        if !echo {
            seen.push((c.line_idx, c.number));
        }
        !echo
    });
    new
}

/// A chapter title found partway through a line. `from` is where its text starts
/// and `in_line` where its chapter does.
fn title_in_line(line_idx: usize, l: &str, from: usize, number: Option<u64>, in_line: usize) -> Candidate {
    Candidate {
        line_idx,
        text: l[from..].trim().to_string(),
        template: Template::Ordinal,
        level: Level::Chapter,
        number,
        in_line,
    }
}

/// The same few words in front of the chapter, again and again: 茅山后裔's
/// 兰亭集序第一部逐咒开罗第四章布袋中的诅咒, 雪中悍刀行's 雪中悍刀行16第一章万里剑叩关北凉.
/// Once could be a sentence, three times is a running head.
fn titles_with_a_running_head(text: &str, found: &[Candidate]) -> Vec<Candidate> {
    let known: std::collections::HashSet<usize> = found.iter().map(|c| c.line_idx).collect();
    let mut heads: std::collections::HashMap<String, Vec<(usize, &str, Option<u64>)>> = Default::default();
    for (i, l) in text.split('\n').enumerate() {
        if known.contains(&i) || l.trim().chars().count() > 40 {
            continue;
        }
        if let Some((at, number)) = title_at_line_end(l) {
            let head: String = l[..at].trim().chars().filter(|c| !c.is_ascii_digit()).collect();
            if head.chars().count() <= 20
                && !head.contains(['，', '。', '！', '？', '；', '：', '“', '”', ',', '.', '!', '?', ';', ':', '~', '^', '('])
            {
                heads.entry(head).or_default().push((i, l, number));
            }
        }
    }
    heads
        .into_iter()
        .filter(|(_, lines)| lines.len() >= 3)
        .flat_map(|(_, lines)| lines)
        .map(|(i, l, number)| title_in_line(i, l, 0, number, 0))
        .collect()
}

/// Titles glued to the end of the line before them. Only for a book that has lost
/// its line breaks, where these outnumber its proper titles many times over; in
/// any other book a line that happens to end this way is prose.
fn titles_at_line_ends(text: &str, found: &[Candidate]) -> Vec<Candidate> {
    let known: std::collections::HashSet<usize> = found.iter().map(|c| c.line_idx).collect();
    let glued: Vec<Candidate> = text
        .split('\n')
        .enumerate()
        .filter(|(i, _)| !known.contains(i))
        .filter_map(|(i, l)| {
            let (at, number) = title_at_line_end(l)?;
            Some(title_in_line(i, l, at, number, at))
        })
        .collect();
    let keep = increasing_run(&glued);
    let proper = found.iter().filter(|c| c.level == Level::Chapter && c.number.is_some()).count();
    if keep.len() < 50 || keep.len() <= proper * 3 {
        return Vec::new();
    }
    glued.into_iter().filter(|c| keep.contains(&c.line_idx)).collect()
}

/// Longer than any chapter an author meant: look inside for the titles that were
/// passed over. 大秦帝国's chapters run to 280 KB with sections inside them, so
/// its 一、 sections are only read as chapters from [`OVERSIZE`] up.
const LUMP: usize = 150 * 1024;
const OVERSIZE: usize = 300 * 1024;
/// A title and the next this close are a table of contents or a list.
const MIN_CHAPTER: usize = 2 * 1024;

/// A title the first pass may not take: indented, or glued to a sentence, or out of
/// order, or wearing a book's name. On its own such a line could be prose, so it
/// only counts inside a lump, and only with others climbing after it.
fn title_in_lump(line: &str, loose: bool) -> Option<(Option<u64>, usize, usize)> {
    let s = line.trim();
    if s.ends_with(['。', '！', '？', '…', '”', '"', '；', '：', '，', '、', '.', '!', '?']) {
        return None;
    }
    if loose {
        return numeral_title(s).map(|n| (Some(n), 0, 0));
    }
    let from = line.find(s).unwrap_or(0);
    if let Some((_, Level::Chapter, number @ Some(_))) = classify(s) {
        // 第三节课, 第二回合.
        let chars: Vec<char> = s.chars().collect();
        let unit = chars.iter().position(|c| CHAPTER_UNITS.contains(*c));
        return match unit.and_then(|u| chars.get(u + 1)) {
            Some('课' | '合') => None,
            _ => Some((number, from, 0)),
        };
    }
    // Whatever is in front stays with the chapter before: 草房子's 杜小康也朝桑桑摇了摇手第六章细马.
    let (at, number) = title_at_line_end(line).or_else(|| title_after_short_head(s).map(|(at, n)| (from + at, n)))?;
    Some((number, at, at))
}

/// 雪中悍刀行16第一章万里剑叩关北凉，徐凤年凌虚御敌: a head in front, and a comma
/// that would make any other line a sentence.
fn title_after_short_head(s: &str) -> Option<(usize, Option<u64>)> {
    let at = s.find('第')?;
    let rest = &s[at + '第'.len_utf8()..];
    let digits = rest.find(|c| !is_numeral_char(c)).unwrap_or(rest.len());
    if digits == 0 || !rest[digits..].starts_with('章') || s.chars().count() > 40 {
        return None;
    }
    if s[..at].contains(['，', '。', '！', '？', '；', '：', '“', '”', ',', '!', '?', ';', ':']) {
        return None;
    }
    Some((at, parse_number(&rest[..digits])))
}

/// 十五 on its own line, 一、伊娃•西京城. Nothing says these are titles but the count.
fn numeral_title(s: &str) -> Option<u64> {
    let digits = s.find(|c| !is_numeral_char(c)).unwrap_or(s.len());
    let (num, rest) = s.split_at(digits);
    if num.is_empty() || num.chars().count() > 6 || num.chars().any(|c| c.is_ascii_digit()) {
        return None;
    }
    if !rest.is_empty() && (!rest.starts_with('、') || rest.chars().count() > 30) {
        return None;
    }
    cn_numeral(num)
}

/// Runs of numbers that climb in small steps, far enough apart to be chapters.
/// Word counts printed after each chapter (小时代's 3666, 3195) never make a run.
fn climbing_titles(found: &[(Candidate, usize)]) -> Vec<usize> {
    let cands: Vec<Candidate> = found.iter().map(|(c, _)| c.clone()).collect();
    let keep = increasing_run(&cands);
    let kept: Vec<usize> = (0..found.len()).filter(|i| keep.contains(&found[*i].0.line_idx)).collect();

    let mut runs: Vec<Vec<usize>> = Vec::new();
    for i in kept {
        let (n, last) = (found[i].0.number, runs.last().and_then(|r| r.last()));
        let near = last.is_some_and(|j| {
            let (a, b) = (found[*j].0.number.unwrap_or(0), n.unwrap_or(0));
            b <= 3 || (b > a && b <= a + 5)
        });
        match (near, runs.last_mut()) {
            (true, Some(run)) => run.push(i),
            _ => runs.push(vec![i]),
        }
    }
    let mut out: Vec<usize> = Vec::new();
    for run in runs.into_iter().filter(|r| r.len() >= 3) {
        let mut next: Option<usize> = None;
        let mut part: Vec<usize> = Vec::new();
        for &i in run.iter().rev() {
            if next.map_or(true, |n| n >= found[i].1 + MIN_CHAPTER) {
                next = Some(found[i].1);
                part.push(i);
            }
        }
        if part.len() >= 3 {
            out.extend(part);
        }
    }
    out
}

/// Find the chapters inside any span too long to be one. Everything already a
/// chapter stays one, so this only ever adds.
pub fn fill_lumps(text: &str, chapters: &mut Vec<Candidate>) {
    for (loose, size) in [(false, LUMP), (true, OVERSIZE)] {
        let mut starts = Vec::new();
        let mut at = 0;
        for l in text.split('\n') {
            starts.push(at);
            at += l.len() + 1;
        }
        let mut edges: Vec<(usize, usize)> = vec![(0, 0)];
        edges.extend(chapters.iter().map(|c| (c.line_idx + 1, starts[c.line_idx] + c.in_line)));
        edges.push((starts.len(), text.len()));

        let lines: Vec<&str> = text.split('\n').collect();
        let mut added = Vec::new();
        for pair in edges.windows(2) {
            let ((first, from), (_, to)) = (pair[0], pair[1]);
            if to.saturating_sub(from) < size {
                continue;
            }
            let last = pair[1].0.saturating_sub(if to == text.len() { 0 } else { 1 });
            let found: Vec<(Candidate, usize)> = (first..last)
                .filter_map(|i| {
                    let (number, title_at, in_line) = title_in_lump(lines[i], loose)?;
                    let c = title_in_line(i, lines[i], title_at, number, in_line);
                    Some((c, starts[i] + in_line))
                })
                .collect();
            added.extend(climbing_titles(&found).into_iter().map(|i| found[i].0.clone()));
        }
        chapters.extend(added);
        chapters.sort_by_key(|c| c.line_idx);
    }
}

pub struct Validation {
    pub chapters: Vec<Candidate>,
    /// Volume headers, in order. They divide the table of contents; they are not
    /// entries in it.
    pub volumes: Vec<Candidate>,
    pub rejected: Vec<Candidate>,
    /// Numbering that does not climb. Real books contain these — authors
    /// misnumber chapters — so they are reported, never silently dropped.
    pub anomalies: Vec<String>,
    /// The numbering templates this book was found to use. Usually one; real
    /// books mix them.
    pub templates: Vec<Template>,
}

/// Length of the longest strictly increasing subsequence.
fn lis_len(nums: &[u64]) -> usize {
    let mut tails: Vec<u64> = Vec::new();
    for &n in nums {
        match tails.binary_search(&n) {
            Ok(_) => {} // equal value: cannot extend a *strictly* increasing run
            Err(i) => {
                if i == tails.len() {
                    tails.push(n);
                } else {
                    tails[i] = n;
                }
            }
        }
    }
    tails.len()
}

/// Pick the numbering templates the book uses — plural, because real books mix
/// them: a source site formats most chapters as "N.标题" and a stretch in the
/// middle as "第N章", and both are chapters.
///
/// A bare number on its own line is indistinguishable from a year, a page number
/// or a phone number in an ad — *as one line*. As a set it is unmistakable:
/// hundreds of them, starting near 1, climbing almost perfectly, spread across
/// the whole book. So templates are elected once, from the shape of the whole
/// candidate set, and lines are only judged afterwards. A template that fails
/// the election contributes no chapters at all, rather than a few wrong ones.
fn elect(cands: &[Candidate], total_lines: usize) -> Vec<Template> {
    let of = |t: Template| -> Vec<&Candidate> {
        cands
            .iter()
            .filter(|c| c.template == t && c.level == Level::Chapter)
            .collect()
    };

    let mut admitted = Vec::new();

    // "第N章" names itself. A handful is already proof.
    let ordinal = of(Template::Ordinal);
    if ordinal.len() >= 5 {
        admitted.push(Template::Ordinal);
    }

    // A number without a unit only earns admission as a sequence — one that
    // climbs and blankets the region it claims. That region is usually the
    // whole book, but a real book can open with "NN 标题" and switch to 第N章
    // partway (异兽迷城 does for its first 255 chapters): when the whole
    // sequence sits before the first 第N章, it only claims that prefix, and
    // demanding it span the book would silently lump 255 chapters into one.
    for t in [Template::NumberDot, Template::BareNumber] {
        let set = of(t);
        let nums: Vec<u64> = set.iter().filter_map(|c| c.number).collect();
        let spread = match (set.first(), set.last()) {
            (Some(f), Some(l)) => {
                let mut region = total_lines;
                if admitted.contains(&Template::Ordinal) {
                    let first_ord = ordinal
                        .iter()
                        .map(|c| c.line_idx)
                        .min()
                        .unwrap_or(usize::MAX);
                    if l.line_idx < first_ord {
                        region = first_ord;
                    }
                }
                (l.line_idx - f.line_idx) as f64 / region.max(1) as f64
            }
            _ => 0.0,
        };
        if nums.len() >= 10
            && nums[0] <= 3
            && lis_len(&nums) as f64 / nums.len() as f64 > 0.9
            && spread > 0.5
        {
            admitted.push(t);
        }
    }
    admitted
}

/// Candidates of the elected template are chapters; everything else is not.
///
/// In an indent-styled book, sitting flush against the margin already proves a
/// line is not body text, so the elected template is enough and numbering is
/// only a sanity check. Without that signal we must earn precision instead: a
/// real chapter sequence climbs, so keep the longest strictly increasing run and
/// discard candidates that break it.
pub fn validate(cands: &[Candidate], fp: &Fingerprint) -> Validation {
    let templates = elect(cands, fp.total_lines);

    // A volume header is a volume header whatever the chapter template turns out
    // to be, so it is set aside before the election is applied.
    let (volumes, rest): (Vec<Candidate>, Vec<Candidate>) = cands
        .iter()
        .cloned()
        .partition(|c| c.level == Level::Volume);

    let elected = |c: &Candidate| c.template == Template::Named || templates.contains(&c.template);
    let (mut chapters, mut rejected): (Vec<Candidate>, Vec<Candidate>) =
        rest.into_iter().partition(elected);

    // Compare against the immediate predecessor, not the running maximum. One
    // misnumbered chapter leaves every chapter after it below the maximum until
    // the sequence catches up, so a running-maximum check reports the same
    // mistake once per chapter. The drop itself happens exactly once.
    let mut anomalies = vec![];
    let mut prev: Option<u64> = None;
    for c in chapters.iter().filter(|c| c.number.is_some()) {
        let n = c.number.unwrap();
        if let Some(p) = prev.filter(|p| n <= *p) {
            anomalies.push(format!("{} 紧随 第{p}章 之后，章号未递增", c.text));
        }
        prev = Some(n);
    }

    if fp.style != ParagraphStyle::Indent {
        let keep = increasing_run(&chapters);
        let (kept, dropped) = chapters
            .into_iter()
            .partition(|c| c.number.is_none() || keep.contains(&c.line_idx));
        chapters = kept;
        rejected.extend(dropped);
    }

    Validation {
        chapters,
        volumes,
        rejected,
        anomalies,
        templates,
    }
}

/// Line indices of the chapters that climb. Numbering may start over at a new
/// volume — 陈二狗的妖孽人生 goes 第070章 → 第一章, and with only the longest run
/// kept the 1.6 MB after it was one chapter — so each restart is climbed on its
/// own. A restart is a low number that the next few titles carry on from: a stray
/// 第二节课下课。 or 第一回充当起婚礼司仪 in the prose is followed by chapter 18.
///
/// The longest run over the whole book stays in, so the same text only ever
/// gains chapters. [`crate::store`] relies on that to move bookmarks and notes.
fn increasing_run(cands: &[Candidate]) -> std::collections::HashSet<usize> {
    // 宰执天下's 第九章闹市纷纷人不宁（上） and （下） are one number on two chapters.
    let mut numbered: Vec<&Candidate> = Vec::new();
    let mut parts: Vec<(usize, usize)> = Vec::new();
    for c in cands.iter().filter(|c| c.number.is_some()) {
        match numbered.last() {
            Some(p) if p.number == c.number && same_chapter_in_parts(&p.text, &c.text) => {
                parts.push((p.line_idx, c.line_idx))
            }
            _ => numbered.push(c),
        }
    }
    let mut keep = longest_run(&numbered);
    let number = |i: usize| numbered[i].number.unwrap();
    let climbs = |i: usize| {
        let next = &numbered[i + 1..(i + 6).min(numbered.len())];
        let mut last = number(i);
        let climbing = next
            .iter()
            .filter(|c| {
                let n = c.number.unwrap();
                let step = n > last && n <= last + 3;
                if step {
                    last = n;
                }
                step
            })
            .count();
        climbing >= 3
    };
    let mut restarts = Vec::new();
    let mut peak = numbered.first().map_or(0, |c| c.number.unwrap());
    for i in 1..numbered.len() {
        // Far enough below the part so far: 河边的错误's 第1章 / 1 / 第2章 / 2 repeats,
        // it does not restart.
        if number(i) <= 3 && number(i) + 3 <= peak && climbs(i) {
            restarts.push(i);
            peak = number(i);
        } else {
            peak = peak.max(number(i));
        }
    }
    let mut from = 0;
    for &to in restarts.iter().chain(std::iter::once(&numbered.len())) {
        keep.extend(longest_run(&numbered[from..to]));
        from = to;
    }
    for (whole, part) in parts {
        if keep.contains(&whole) {
            keep.insert(part);
        }
    }
    keep
}

/// 标题（上） and 标题（下）, the same title with a different ending in brackets.
fn same_chapter_in_parts(a: &str, b: &str) -> bool {
    fn before(s: &str) -> Option<&str> {
        let s = s.trim_end();
        if !s.ends_with(['）', ')']) {
            return None;
        }
        s.rfind(['（', '(']).map(|at| &s[..at])
    }
    a != b && before(a).is_some() && before(a) == before(b)
}

/// Line indices of the longest strictly increasing run of chapter numbers.
fn longest_run(numbered: &[&Candidate]) -> std::collections::HashSet<usize> {
    let n = numbered.len();
    if n == 0 {
        return Default::default();
    }
    let (mut len, mut prev) = (vec![1usize; n], vec![usize::MAX; n]);
    for i in 1..n {
        for j in 0..i {
            if numbered[j].number < numbered[i].number && len[j] + 1 > len[i] {
                len[i] = len[j] + 1;
                prev[i] = j;
            }
        }
    }
    let mut i = (0..n).max_by_key(|&i| len[i]).unwrap();
    let mut keep = std::collections::HashSet::new();
    loop {
        keep.insert(numbered[i].line_idx);
        if prev[i] == usize::MAX {
            break;
        }
        i = prev[i];
    }
    keep
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fingerprint::fingerprint;

    fn fp_of(text: &str) -> Fingerprint {
        fingerprint("UTF-8", text)
    }

    /// A book whose titles are bare numbers, with an ad line that also happens to
    /// be a bare number. The template is elected, so 400 climbing numbers win and
    /// the stray one joins them harmlessly — it is inside the run.
    #[test]
    fn bare_numbers_elected_when_they_form_a_sequence() {
        let mut t = String::new();
        for i in 1..=400 {
            t.push_str(&format!("{i}\n\u{3000}\u{3000}正文。\n"));
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.templates, vec![Template::BareNumber]);
        assert_eq!(v.chapters.len(), 400);
    }

    /// The 异兽迷城 shape: the first arc titled "NN 标题", the rest 第N章. The
    /// number-space sequence owns only the prefix, and must still be elected —
    /// rejecting it lumped 255 real chapters into one.
    #[test]
    fn number_space_prefix_then_ordinal_titles() {
        let mut t = String::new();
        for i in 1..=30 {
            t.push_str(&format!("{i:02} 标题\n"));
            t.push_str(&"\u{3000}\u{3000}正文段落，写了一些字。\n".repeat(30));
        }
        for i in 31..=300 {
            t.push_str(&format!("第{i}章 标题\n"));
            t.push_str(&"\u{3000}\u{3000}正文段落，写了一些字。\n".repeat(30));
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 300, "templates: {:?}", v.templates);
    }

    /// The same lone number in a book with no numeric titles at all must not
    /// become a chapter. Before template election it did.
    #[test]
    fn lone_bare_number_is_not_a_chapter() {
        let mut t = String::from("2017\n\u{3000}\u{3000}广告。\n");
        for i in 1..=50 {
            t.push_str(&format!("第{i}章 标题\n\u{3000}\u{3000}正文。\n"));
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.templates, vec![Template::Ordinal]);
        assert_eq!(v.chapters.len(), 50);
        assert_eq!(v.rejected.len(), 1);
        assert_eq!(v.rejected[0].text, "2017");
    }

    /// Scattered years in a book with no chapter template at all. Electing
    /// BareNumber here would shred the book into nonsense chapters.
    #[test]
    fn scattered_numbers_elect_nothing() {
        let mut t = String::new();
        for y in [1998, 2003, 2017, 2021] {
            t.push_str(&format!("{y}\n\u{3000}\u{3000}正文。\n"));
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert!(v.templates.is_empty());
        assert!(v.chapters.is_empty());
    }

    /// Volume headers must not enter the chapter list, and their numbers must
    /// not enter the chapter-numbering check: "第二卷" after "第900章" is not a
    /// book whose numbering fell off a cliff.
    #[test]
    fn volumes_are_not_chapters() {
        let mut t = String::new();
        for v in 1..=3 {
            t.push_str(&format!("第{v}卷 风起\n"));
            for c in 1..=20 {
                let n = (v - 1) * 20 + c;
                t.push_str(&format!("第{n}章 标题\n\u{3000}\u{3000}正文。\n"));
            }
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 60);
        assert_eq!(v.volumes.len(), 3);
        assert!(v.anomalies.is_empty(), "{:?}", v.anomalies);
    }

    /// A body sentence starting with "第二天" used to become a chapter because
    /// the unit scan found the 回 of 回家 twelve characters later.
    #[test]
    fn body_sentence_is_not_an_ordinal() {
        assert_eq!(classify("第二天早上，他赶着回家换校服。"), None);
        assert_eq!(
            classify("第三节课课间。"),
            Some((Template::Ordinal, Level::Chapter, Some(3)))
        );
    }

    /// One book, two templates: a site formats most chapters as "N.标题" and a
    /// stretch in the middle as "第N章". Both are chapters; electing exactly one
    /// template silently dropped the other's.
    #[test]
    fn mixed_number_dot_and_ordinal() {
        let mut t = String::new();
        for i in 1..=30 {
            if (10..15).contains(&i) {
                t.push_str(&format!("第{i}章 标题\n"));
            } else {
                t.push_str(&format!("{i}.标题\n"));
            }
            t.push_str("　　正文。\n");
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 30);
        assert!(v.anomalies.is_empty(), "{:?}", v.anomalies);
        assert!(v.templates.contains(&Template::NumberDot));
        assert!(v.templates.contains(&Template::Ordinal));
    }

    /// ASCII-space indentation carries the same signal as ideographic spaces:
    /// four spaces is body, one space is a title.
    #[test]
    fn ascii_space_indent() {
        use crate::is_indented;
        assert!(is_indented("    正文段落。"));
        assert!(is_indented("　　正文段落。"));
        assert!(!is_indented(" 1.十五年后的开始游戏"));
        assert!(!is_indented("第1章 标题"));
    }

    #[test]
    fn chapter_title_may_name_its_volume_first() {
        assert_eq!(
            classify("第六卷 伊人倚红妆 第五章 地府"),
            Some((Template::Ordinal, Level::Chapter, Some(5)))
        );
        assert_eq!(
            classify("第二卷东方欲晓第一百零五节魔怔（求推荐票！）"),
            Some((Template::Ordinal, Level::Chapter, Some(105)))
        );
        assert_eq!(
            classify("第三卷过去时现在时181周日"),
            Some((Template::Ordinal, Level::Chapter, Some(181)))
        );
        assert_eq!(
            classify("正文730十年一梦今日醒（二）"),
            Some((Template::Ordinal, Level::Chapter, Some(730)))
        );
        assert_eq!(
            classify("正文 第五章 标题"),
            Some((Template::Ordinal, Level::Chapter, Some(5)))
        );
        assert_eq!(
            classify("第十卷一百二十三：我要换队友（下）"),
            Some((Template::Ordinal, Level::Chapter, Some(123)))
        );
        assert_eq!(
            classify("哈里.萊特篇 豪奢的单人旅行 第十二章"),
            Some((Template::Ordinal, Level::Chapter, Some(12)))
        );
        assert_eq!(
            classify("第一卷蝴蝶扇了一下翅膀的那个夏天4.Reset的那个下午"),
            Some((Template::Ordinal, Level::Chapter, Some(4)))
        );
        assert!(matches!(classify("第四卷 1.0降临者！崛起海蓝星"), Some((_, Level::Volume, _))));
        assert_eq!(classify("他翻开书，看到了 第一章"), None);
        for volume in ["第三卷", "第三卷 风起", "第一部分", "第二集，第三天"] {
            assert!(
                !matches!(classify(volume), Some((_, Level::Chapter, _))),
                "{volume}"
            );
        }
    }

    /// Numbering that starts over at a new volume, in a book with no indent
    /// signal. All of it is chapters; the stray 第一 in the prose is not.
    #[test]
    fn numbering_may_restart_at_a_volume() {
        let mut t = String::new();
        for i in 1..=70 {
            t.push_str(&format!("第{i}章 标题\n正文，写了一些字。\n"));
        }
        t.push_str("第一回充当起婚礼司仪。\n正文，写了一些字。\n");
        for i in 71..=75 {
            t.push_str(&format!("第{i}章 标题\n正文，写了一些字。\n"));
        }
        for i in 1..=46 {
            t.push_str(&format!("第{i}章 标题\n正文，写了一些字。\n"));
        }
        let fp = fp_of(&t);
        assert_ne!(fp.style, ParagraphStyle::Indent);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 75 + 46);
        assert!(v.rejected.iter().any(|c| c.text.starts_with("第一回")));
    }

    #[test]
    fn titles_in_other_dress() {
        let ordinal = |n| Some((Template::Ordinal, Level::Chapter, Some(n)));
        assert_eq!(classify("第１１章安得良策援南土（一）"), ordinal(11));
        assert_eq!(classify("313章、莫名其妙的功劳！"), ordinal(313));
        assert_eq!(classify("第四幕 悬赏"), ordinal(4));
        assert_eq!(classify("☆、第25章阴鸷第六3"), ordinal(25));
        assert_eq!(classify("☆、泼野第二2"), Some((Template::Named, Level::Chapter, None)));
        assert_eq!(classify("3章书看完了，他才睡。"), None);
        assert_eq!(classify("第二幕。他们遇到兽潮。"), None);
    }

    #[test]
    fn a_title_printed_twice_is_one_chapter() {
        let mut t = String::new();
        for i in 1..=6 {
            t.push_str(&format!("第{i}章\n斗破苍穹 第{i}章 标题\n正文，写了一些字。\n"));
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 6);
        assert_eq!(v.chapters[0].text, "第1章");
    }

    /// One number on three chapters, and numbering that starts over behind them.
    #[test]
    fn a_chapter_may_come_in_parts() {
        let mut t = String::new();
        for round in 0..2 {
            for i in 1..=8 {
                for part in ["上", "中", "下"] {
                    t.push_str(&format!("第{i}章 标题{round}{i}（{part}）\n正文，写了一些字。\n"));
                }
            }
        }
        let fp = fp_of(&t);
        assert_ne!(fp.style, ParagraphStyle::Indent);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 48);
    }

    #[test]
    fn a_repeated_head_is_not_a_sentence() {
        let mut t = String::new();
        for i in 1..=6 {
            t.push_str(&format!("兰亭集序第一部逐咒开罗第{i}章 标题\n正文，写了一些字。\n"));
        }
        t.push_str("他翻到第七章讲义\n正文，写了一些字。\n");
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 6);
    }

    fn filled(t: &str) -> Vec<Candidate> {
        let fp = fp_of(t);
        let mut chapters = validate(&candidates(t, &fp), &fp).chapters;
        fill_lumps(t, &mut chapters);
        chapters
    }

    /// 雪中悍刀行: the first title flush, the rest indented like the prose.
    #[test]
    fn a_lump_gives_up_its_indented_titles() {
        let body = "\u{3000}\u{3000}正文段落，写了一些字，又写了一些字，还写了一些字。\n".repeat(150);
        let mut t = String::from("第一章 开始\n");
        t.push_str(&body);
        for i in 2..=30 {
            t.push_str(&format!("\u{3000}\u{3000}第{i}章 标题，还有后半句\n"));
            t.push_str(&body);
        }
        assert_eq!(filled(&t).len(), 30);
    }

    /// The same lines in a book of ordinary chapters are prose.
    #[test]
    fn indented_titles_outside_a_lump_are_prose() {
        let mut t = String::new();
        for i in 1..=30 {
            t.push_str(&format!("第{i}章 标题\n\u{3000}\u{3000}他翻开书。\n\u{3000}\u{3000}第{i}章 讲义\n"));
        }
        assert_eq!(filled(&t).len(), 30);
    }

    /// A list and a table of contents climb too, but too close together.
    #[test]
    fn a_list_inside_a_lump_is_not_chapters() {
        let body = "\u{3000}\u{3000}正文段落，写了一些字，又写了一些字，还写了一些字。\n".repeat(4000);
        let mut t = String::from("第一章 开始\n");
        t.push_str(&body);
        t.push_str("\u{3000}\u{3000}第1节 活动时间\n\u{3000}\u{3000}第2节 活动地点\n\u{3000}\u{3000}第3节 活动流程\n");
        t.push_str(&body);
        assert!(filled(&t).iter().all(|c| !c.text.contains("活动")));
    }

    /// Only an oversized span is read for bare numerals, and word counts stay out.
    #[test]
    fn bare_numerals_only_in_an_oversized_span() {
        let body = "\u{3000}\u{3000}正文段落，写了一些字，又写了一些字，还写了一些字。\n".repeat(400);
        let mut t = String::new();
        for n in ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二", "十三", "十四", "十五"] {
            t.push_str(&format!("{n}\n{body}"));
        }
        assert!(t.len() > OVERSIZE);
        assert_eq!(filled(&t).len(), 15);

        let mut counts = String::new();
        for n in [3666, 3195, 4058, 4145, 3976, 3277, 3285, 3669, 4012, 3923, 3213, 3940] {
            counts.push_str(&format!("{body}{body}{n}\n"));
        }
        assert!(counts.len() > OVERSIZE);
        assert_eq!(filled(&counts).len(), 0);
    }

    /// Titles run on from the sentence before them only count in bulk, and the
    /// sentence is not part of the title.
    #[test]
    fn titles_glued_to_the_line_before() {
        let mut t = String::from("第一章 开始\n正文，写了一些字。\n");
        for i in 2..=60 {
            t.push_str(&format!("正文，写了一些字。第{i}章 标题\n"));
        }
        let fp = fp_of(&t);
        let v = validate(&candidates(&t, &fp), &fp);
        assert_eq!(v.chapters.len(), 60);
        let c = &v.chapters[1];
        assert_eq!(c.text, "第2章 标题");
        assert_eq!(c.in_line, "正文，写了一些字。".len());

        let few = "第一章 开始\n他翻到了第二章 开始\n第二章 开始\n正文。\n";
        let fp = fp_of(few);
        assert!(candidates(few, &fp).iter().all(|c| c.in_line == 0));
    }

    #[test]
    fn cn_numerals() {
        assert_eq!(cn_numeral("一百零九"), Some(109));
        assert_eq!(cn_numeral("三千二百"), Some(3200));
        assert_eq!(cn_numeral("十"), Some(10));
        assert_eq!(cn_numeral("二十一"), Some(21));
        assert_eq!(cn_numeral("一万零五"), Some(10005));
        assert_eq!(cn_numeral("abc"), None);
        assert_eq!(cn_numeral("一零二"), Some(102));
        assert_eq!(cn_numeral("一八六"), Some(186));
        assert_eq!(cn_numeral("二零"), Some(20));
    }
}
