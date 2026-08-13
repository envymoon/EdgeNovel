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

const CHAPTER_UNITS: &str = "章节節回";
const VOLUME_UNITS: &str = "卷部篇集";

fn is_numeral_char(c: char) -> bool {
    c.is_ascii_digit() || "〇零一二两三四五六七八九十百千万".contains(c)
}

fn classify(line: &str) -> Option<(Template, Level, Option<u64>)> {
    let s = line.trim();
    let chars: Vec<char> = s.chars().collect();
    if chars.is_empty() || chars.len() > 40 {
        return None;
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
            if CHAPTER_UNITS.contains(unit) || VOLUME_UNITS.contains(unit) {
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

    if NAMED.iter().any(|n| s.starts_with(n)) {
        return Some((Template::Named, Level::Chapter, None));
    }

    None
}

pub fn candidates(text: &str, fp: &Fingerprint) -> Vec<Candidate> {
    structural_lines(text, fp)
        .into_iter()
        .filter_map(|(line_idx, l)| {
            classify(l).map(|(template, level, number)| Candidate {
                line_idx,
                text: l.trim().to_string(),
                template,
                level,
                number,
            })
        })
        .collect()
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

/// Line indices of the longest strictly increasing run of chapter numbers.
fn increasing_run(cands: &[Candidate]) -> std::collections::HashSet<usize> {
    let numbered: Vec<&Candidate> = cands.iter().filter(|c| c.number.is_some()).collect();
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
    fn cn_numerals() {
        assert_eq!(cn_numeral("一百零九"), Some(109));
        assert_eq!(cn_numeral("三千二百"), Some(3200));
        assert_eq!(cn_numeral("十"), Some(10));
        assert_eq!(cn_numeral("二十一"), Some(21));
        assert_eq!(cn_numeral("一万零五"), Some(10005));
        assert_eq!(cn_numeral("abc"), None);
    }
}
