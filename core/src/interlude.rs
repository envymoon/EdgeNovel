//! 章间立绘: every few chapters, a picture of something the book has just
//! been dwelling on, shown between two chapters the way a light novel puts its
//! plates.
//!
//! Like the cover ([`crate::cover`]) it is drawn from fixed vocabulary, never
//! written freehand; only where the cues come from differs. The text is read
//! in order, so a plate knows only what comes before it.
//!
//! What a plate shows is drawn by lot from what its stretch dwells on. A
//! thing or a sight ([`crate::sights`]: a pencil case, a dark tunnel, a
//! lighthouse) is dwelt on when one passage names it again and again, far more
//! than the book usually does; it is drawn alone, in the light and the place
//! of that passage. A lead is dwelt on when the stretch keeps naming them; for
//! each the scan keeps a running tally of what the text says about them —
//! hair, eyes, clothes, what they carry — and whether it calls them 他 or 她.
//! A lead gets one plate in four when there is anything else to draw; the
//! same face is not drawn twice running, nor the same thing within five.
//!
//! A lead keeps one seed for the whole book, so the same tags draw the same
//! person each time.

use crate::book::Chapter;
use crate::cover::{Kind, Word, VOCABULARY};
use crate::sights;
use std::collections::HashMap;

/// Who a plate shows: a lead, by index into the leads [`plan`] was given, or
/// no one, when it shows its first cue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Who {
    Girl(usize),
    Boy(usize),
    Nobody,
}

#[derive(Debug)]
pub struct Plate {
    /// Shown after this chapter, before the next.
    pub chapter: usize,
    pub who: Who,
    /// What it shows: for a person, at most one of each [`Group`], and one
    /// place, one sky and a motif; for no one, the thing or the sight, then
    /// the place and the light around it.
    pub cues: Vec<&'static Word>,
    pub seed: u32,
}

/// Looks fall into groups, one of each per person: two hair colours on one
/// head draws a gradient, not the one the text meant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    HairColour,
    Eyes,
    Hair,
    Outfit,
}

pub fn group(w: &Word) -> Option<Group> {
    if w.kind != Kind::Look {
        return None;
    }
    Some(if w.tags.ends_with(" hair") && !matches!(w.label, "长发" | "短发") {
        Group::HairColour
    } else if w.tags.contains("eyes") || w.label == "异瞳" {
        Group::Eyes
    } else if matches!(w.label, "长发" | "短发" | "马尾" | "双马尾") {
        Group::Hair
    } else {
        Group::Outfit
    })
}

const GROUPS: [Group; 4] = [Group::HairColour, Group::Eyes, Group::Outfit, Group::Hair];

/// Someone other than the lead the sentence names: a look in the same clause
/// is theirs (白衣少女看了眼陈平安).
const OTHERS: &[&str] = &[
    "少女", "少年", "男子", "女子", "老人", "老者", "姑娘", "青年", "女人", "男人", "孩子",
    "妇人", "汉子", "中年", "年轻人", "老头", "女孩", "男孩", "女生", "男生", "丫头", "小孩",
    "老妪", "大汉", "公子", "小姐", "女修", "男修", "道人", "和尚", "对方", "女士", "老翁",
    "童子",
];

/// What follows a look that makes it someone's epithet: 长发男, 红发女.
const EPITHET: &str = "男女人者汉客仔妹姐哥妞娘翁童老";

/// Past one of these, a sentence describes what the lead sees, not the lead:
/// 青山理扭头看去，极具光泽的美丽金发…
const SEEING: &[&str] = &["看", "望", "瞧", "盯", "瞥", "见", "注视", "打量", "凝视", "目光", "眼中", "眼里"];

/// Looks a boy is far likelier to be standing next to than to have: the
/// girls around a male lead lend him their long hair otherwise.
const HERS: &[&str] = &["长发", "马尾", "双马尾", "旗袍"];

/// What a lead is called right after their name says which they are:
/// 奥黛丽小姐, 克莱恩先生.
const HER: &[&str] = &[
    "小姐", "姑娘", "女士", "夫人", "师姐", "师妹", "姐姐", "妹妹", "公主", "仙子", "阿姨",
];
const HIM: &[&str] = &[
    "先生", "公子", "少爷", "师兄", "师弟", "哥哥", "大哥", "老爷", "大叔", "道长", "少侠", "老弟",
];

/// And what they are called right before it: 少年陈平安, 少女宁姚.
const SHE_IS: &[&str] = &["少女", "女子", "姑娘", "女人", "女孩", "丫头", "妇人", "女修", "美人"];
const HE_IS: &[&str] = &["少年", "男子", "青年", "男人", "男孩", "小子", "汉子", "书生", "道士", "老者"];

/// How often a lead is named in a stretch before they can be its plate.
const PRESENT: u32 = 5;
/// How often a place or a sky is named, per chapter of the stretch, before it
/// is the stretch's own; a motif needs twice that.
const SCENE_RATE: f32 = 0.5;
const SCENE_MIN: u32 = 3;

/// About a page, in bytes: mentions this close together are one passage.
const PASSAGE: usize = 3000;
/// Mentions in one passage before it is dwelling on a thing, and how many
/// times the book's usual for a passage that must be.
const DWELL: u32 = 3;
const UNUSUAL: f32 = 3.0;
/// A lead's share of plates when the stretch dwells on anything else: they
/// would take every plate otherwise.
const PERSON_ONE_IN: u32 = 4;
/// How many plates back a thing is not drawn again.
const RECENT: usize = 5;

/// Motifs that sit behind a person. An animal or a coffin takes the picture
/// over, so a person is drawn without them.
const BEHIND: &[&str] = &[
    "灯笼", "烛火", "樱花", "桃花", "梅花", "杏花", "荷花", "落叶", "柳树", "蝴蝶",
];
/// A thing carried this often is the lead's own (剑来's 陈平安 and his sword).
const ITEM_MIN: u32 = 3;

/// Trigger words by first character, so the text is walked once rather than
/// searched once per word.
struct Triggers {
    words: Vec<&'static Word>,
    by_first: HashMap<char, Vec<(&'static str, usize)>>,
}

impl Triggers {
    /// Indices are into `words`; those `keep` turns down are never found.
    fn new(words: Vec<&'static Word>, keep: impl Fn(&Word) -> bool) -> Self {
        let mut by_first: HashMap<char, Vec<(&'static str, usize)>> = HashMap::new();
        for (i, w) in words.iter().enumerate() {
            if !keep(w) {
                continue;
            }
            for t in w.triggers {
                // Single characters (剑, 刀, 弓, 伞) are only safe for what a
                // person carries; elsewhere they sit inside other words.
                if t.chars().count() < 2 && w.kind != Kind::Item {
                    continue;
                }
                let first = t.chars().next().unwrap();
                by_first.entry(first).or_default().push((t, i));
            }
        }
        Triggers { words, by_first }
    }

    /// Each word named in `s`, once per place it is named, with the text that
    /// follows it; the longest trigger at a position wins, so 长剑 is not also 剑.
    fn each<'s>(&self, s: &'s str, mut f: impl FnMut(usize, &'s str)) {
        let mut skip_to = 0;
        for (at, c) in s.char_indices() {
            if at < skip_to {
                continue;
            }
            let Some(list) = self.by_first.get(&c) else { continue };
            let rest = &s[at..];
            if let Some((t, i)) = list
                .iter()
                .filter(|(t, _)| rest.starts_with(t))
                .max_by_key(|(t, _)| t.len())
            {
                f(*i, &s[at + t.len()..]);
                skip_to = at + t.len();
            }
        }
    }
}

#[derive(Default)]
struct Lead {
    looks: HashMap<usize, u32>,
    items: HashMap<usize, u32>,
    /// Read off the whole book first: being a girl is no spoiler, and the
    /// hints are thin enough that a lead needs all of them.
    girl: Option<bool>,
    /// Sentences naming them in the current stretch.
    here: u32,
    /// The plate they were last drawn on.
    drawn: Option<usize>,
}

impl Lead {
    /// The best-attested look of each group.
    fn looks(&self) -> Vec<&'static Word> {
        GROUPS
            .iter()
            .filter_map(|g| {
                self.looks
                    .iter()
                    .filter(|(i, _)| group(&VOCABULARY[**i]) == Some(*g))
                    .filter(|(i, _)| self.girl != Some(false) || !HERS.contains(&VOCABULARY[**i].label))
                    // Ties go to the word listed first, so a plan is stable.
                    .max_by_key(|(i, n)| (**n, std::cmp::Reverse(**i)))
                    .map(|(i, _)| &VOCABULARY[*i])
            })
            .collect()
    }

    fn item(&self) -> Option<&'static Word> {
        self.items
            .iter()
            .filter(|(_, n)| **n >= ITEM_MIN)
            .max_by_key(|(i, n)| (**n, std::cmp::Reverse(**i)))
            .map(|(i, _)| &VOCABULARY[*i])
    }
}

fn fnv(s: &str) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

fn sentences(para: &str) -> impl Iterator<Item = &str> {
    para.split(['。', '！', '？', '!', '?', '…']).filter(|s| !s.trim().is_empty())
}

fn clauses(sent: &str) -> impl Iterator<Item = &str> {
    // Not at 、: 酒红长发、深棕眼眸的女孩 is one description.
    sent.split(['，', ',', '；', ';', '：', ':']).filter(|s| !s.is_empty())
}

/// 他 or 她 opening the clause right after one the lead opens, with no one
/// else in between: 宁姚点点头，她知道… Anything looser counts the people a
/// lead talks to — 陈平安's sentences are full of 她.
fn pronoun(sent: &str, name_at: usize, name: &str) -> Option<bool> {
    let before = sent[..name_at].rsplit(['，', ',', '；', '：']).next().unwrap_or("");
    if !before.trim_matches(|c: char| c.is_whitespace() || "　“”\"「」".contains(c)).is_empty() {
        return None;
    }
    let mut rest = sent[name_at + name.len()..].splitn(2, '，');
    let own = rest.next()?;
    let next = rest.next()?;
    // Speech, or something seen, and the pronoun is likely someone else:
    // 陈平安看到一个熟悉背影，她个子不高.
    if own.contains(['他', '她', '“', '”', '：'])
        || OTHERS.iter().any(|o| own.contains(o))
        || SEEING.iter().any(|w| own.contains(w))
    {
        return None;
    }
    let mut cs = next.chars();
    match (cs.next(), cs.next()) {
        (_, Some('们')) => None,
        (Some('他'), _) => Some(false),
        (Some('她'), _) => Some(true),
        _ => None,
    }
}

/// Plan the plates for a book: one after every `every` chapters, for those
/// stretches that have something to draw. `leads` are each lead's name and
/// aliases, most important first.
pub fn plan(text: &str, chapters: &[Chapter], leads: &[Vec<String>], every: usize) -> Vec<Plate> {
    let every = every.max(1);
    let personal = Triggers::new(VOCABULARY.iter().collect(), |w| matches!(w.kind, Kind::Look | Kind::Item));
    let scenic = Triggers::new(VOCABULARY.iter().chain(sights::all()).collect(), |w| {
        matches!(w.kind, Kind::Place | Kind::Sky | Kind::Motif)
    });
    let mut state: Vec<Lead> = sexes(text, chapters, leads)
        .into_iter()
        .map(|girl| Lead {
            girl,
            ..Lead::default()
        })
        .collect();

    // How often a passage of this book names each thing, to tell a passage
    // dwelling on it from the book's usual. Not a spoiler: only how often.
    let mut named = vec![0u32; scenic.words.len()];
    let mut length = 0;
    for ch in chapters {
        let body = body(text, ch);
        length += body.len();
        scenic.each(body, |i, _| named[i] += 1);
    }
    let usual: Vec<f32> = named
        .iter()
        .map(|&n| n as f32 * PASSAGE as f32 / length.max(1) as f32)
        .collect();

    // Where in the text each thing is named, in this stretch.
    let mut hits: Vec<(usize, usize)> = Vec::new();
    let mut plates = Vec::new();
    let mut slot = 0;
    let mut recent: Vec<Subject> = Vec::new();

    for ch in chapters {
        for para in body(text, ch).split('\n') {
            let at = para.as_ptr() as usize - text.as_ptr() as usize;
            scenic.each(para, |i, after| hits.push((at + para.len() - after.len(), i)));
            for sent in sentences(para) {
                read_sentence(sent, leads, &mut state, &personal);
            }
        }
        if (ch.index + 1) % every != 0 {
            continue;
        }
        let stretch = Stretch {
            chapter: ch.index,
            slot,
            every,
            hits: &hits,
            words: &scenic.words,
            usual: &usual,
        };
        if let Some((p, subject)) = draw(&stretch, leads, &mut state, &recent) {
            plates.push(p);
            recent.push(subject);
        }
        slot += 1;
        hits.clear();
        for l in &mut state {
            l.here = 0;
        }
    }
    plates
}

fn body<'t>(text: &'t str, ch: &Chapter) -> &'t str {
    &text[ch.body_start.min(ch.span.end)..ch.span.end]
}

/// The one lead a sentence names, where its name is and which of their names
/// it is, and every lead it names.
fn named<'l>(sent: &str, leads: &'l [Vec<String>]) -> (Vec<usize>, Option<(usize, usize, &'l str)>) {
    let mut all = Vec::new();
    let mut first = None;
    for (i, names) in leads.iter().enumerate() {
        if let Some((at, name)) = names
            .iter()
            .filter_map(|n| sent.find(n.as_str()).map(|at| (at, n.as_str())))
            .min()
        {
            all.push(i);
            first.get_or_insert((i, at, name));
        }
    }
    // Two leads in one sentence: whose hair is whose is anyone's guess.
    let sole = if all.len() == 1 { first } else { None };
    (all, sole)
}

/// Whether each lead is a girl, a boy, or the book never says clearly.
fn sexes(text: &str, chapters: &[Chapter], leads: &[Vec<String>]) -> Vec<Option<bool>> {
    let mut count = vec![(0u32, 0u32); leads.len()];
    for ch in chapters {
        for sent in body(text, ch).split('\n').flat_map(sentences) {
            let (_, Some((i, at, name))) = named(sent, leads) else { continue };
            let (he, she) = &mut count[i];
            match pronoun(sent, at, name) {
                Some(true) => *she += 1,
                Some(false) => *he += 1,
                None => {}
            }
            for (at, _) in sent.match_indices(name) {
                let (before, after) = (&sent[..at], &sent[at + name.len()..]);
                if HER.iter().any(|t| after.starts_with(t)) || SHE_IS.iter().any(|t| before.ends_with(t)) {
                    *she += 1;
                } else if HIM.iter().any(|t| after.starts_with(t)) || HE_IS.iter().any(|t| before.ends_with(t)) {
                    *he += 1;
                }
            }
        }
    }
    count
        .into_iter()
        .map(|(he, she)| {
            if he + she < 3 {
                None
            } else if she >= he * 2 {
                Some(true)
            } else if he >= she * 2 {
                Some(false)
            } else {
                None
            }
        })
        .collect()
}

fn read_sentence(sent: &str, leads: &[Vec<String>], state: &mut [Lead], personal: &Triggers) {
    let (all, sole) = named(sent, leads);
    for &i in &all {
        state[i].here += 1;
    }
    let Some((i, _, name)) = sole else { return };
    let lead = &mut state[i];
    let girl = lead.girl;
    // Someone else in it (bar 少年陈平安, who is the lead), or a pronoun of the
    // other sex: the sentence is not all about the lead, so only the clause
    // that names them is.
    let other = |s: &str| {
        OTHERS.iter().any(|o| s.match_indices(o).any(|(k, _)| !s[k + o.len()..].starts_with(name)))
            || (girl == Some(true) && s.contains('他'))
            || (girl == Some(false) && s.contains('她'))
    };
    let crowded = other(sent);
    for clause in clauses(sent) {
        let seen = SEEING.iter().filter_map(|w| clause.find(w)).min();
        let part = &clause[..seen.unwrap_or(clause.len())];
        let own = part.contains(name);
        if !(crowded && (!own || other(part))) {
            personal.each(part, |w, after| {
                // 长发男, 白发苍苍的老管事: the look is someone's epithet,
                // unless the someone is the lead (一身白衣的宁姚).
                if after.starts_with(|c| EPITHET.contains(c))
                    || after
                        .find('的')
                        .is_some_and(|k| !after[k + '的'.len_utf8()..].starts_with(name))
                {
                    return;
                }
                let map = if VOCABULARY[w].kind == Kind::Item {
                    &mut lead.items
                } else {
                    &mut lead.looks
                };
                *map.entry(w).or_default() += 1;
            });
        }
        if seen.is_some() {
            break;
        }
    }
}

/// What a stretch between two plates named, and where.
struct Stretch<'a> {
    /// The plate's chapter, and how many plates come before it.
    chapter: usize,
    slot: usize,
    every: usize,
    /// (byte offset in the text, index into `words`), in reading order.
    hits: &'a [(usize, usize)],
    words: &'a [&'static Word],
    /// How often the book names each word in a passage.
    usual: &'a [f32],
}

/// What a plate is of, so the next is of something else: a lead's index or a
/// word's label.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Subject {
    Lead(usize),
    Thing(&'static str),
}

/// A thing a passage dwells on: the word, how many more times than usual the
/// passage names it, and where the passage starts.
struct Dwelt {
    word: usize,
    more: f32,
    from: usize,
}

impl Stretch<'_> {
    fn word(&self, i: usize) -> &'static Word {
        self.words[i]
    }

    /// Each thing or sight some passage of the stretch dwells on, in the
    /// order the text gets to it.
    fn dwelt(&self) -> Vec<Dwelt> {
        let mut at: HashMap<usize, Vec<usize>> = HashMap::new();
        for &(pos, i) in self.hits {
            if matches!(self.word(i).kind, Kind::Place | Kind::Motif) {
                at.entry(i).or_default().push(pos);
            }
        }
        let mut found: Vec<Dwelt> = at
            .into_iter()
            .filter_map(|(word, pos)| {
                // The most mentions within one passage, and where it starts.
                let mut best = (0, 0);
                let mut start = 0;
                for end in 0..pos.len() {
                    while pos[end] - pos[start] > PASSAGE {
                        start += 1;
                    }
                    if end + 1 - start > best.0 {
                        best = (end + 1 - start, pos[start]);
                    }
                }
                let (n, from) = (best.0 as u32, best.1);
                let usual = self.usual[word];
                (n >= DWELL && n as f32 >= UNUSUAL * usual).then(|| Dwelt {
                    word,
                    more: n as f32 - usual,
                    from,
                })
            })
            .collect();
        found.sort_by_key(|d| (d.from, d.word));
        found
    }

    /// The most named word of `kind` in and around a passage, if any.
    fn around(&self, from: usize, kind: Kind) -> Option<&'static Word> {
        let mut counts: HashMap<usize, u32> = HashMap::new();
        for &(pos, i) in self.hits {
            if pos + PASSAGE >= from && pos <= from + 2 * PASSAGE && self.word(i).kind == kind {
                *counts.entry(i).or_default() += 1;
            }
        }
        counts
            .into_iter()
            .max_by_key(|(i, n)| (*n, std::cmp::Reverse(*i)))
            .map(|(i, _)| self.word(i))
    }

    /// The words of `kind` the whole stretch names at least `min` times, most
    /// named first.
    fn named(&self, kind: Kind, min: u32, take: usize, keep: &dyn Fn(&Word) -> bool) -> Vec<&'static Word> {
        let mut counts: HashMap<usize, u32> = HashMap::new();
        for &(_, i) in self.hits {
            if self.word(i).kind == kind && keep(self.word(i)) {
                *counts.entry(i).or_default() += 1;
            }
        }
        let mut v: Vec<(usize, u32)> = counts.into_iter().filter(|(_, n)| *n >= min).collect();
        v.sort_by_key(|(i, n)| (std::cmp::Reverse(*n), *i));
        v.into_iter().take(take).map(|(i, _)| self.word(i)).collect()
    }
}

fn draw(
    stretch: &Stretch,
    leads: &[Vec<String>],
    state: &mut [Lead],
    recent: &[Subject],
) -> Option<(Plate, Subject)> {
    let chapter = stretch.chapter;
    let min = SCENE_MIN.max((stretch.every as f32 * SCENE_RATE) as u32);
    // Nothing drawn in the last few plates, while there is something else.
    let lately = &recent[recent.len().saturating_sub(RECENT)..];
    let fresh = |d: &Dwelt| !lately.contains(&Subject::Thing(stretch.word(d.word).label));
    let mut things = stretch.dwelt();
    if things.iter().any(fresh) {
        things.retain(fresh);
    }
    let last = recent.last().copied();

    // Whoever has gone longest without a plate, then whoever this stretch
    // is most about; not the same face twice running if there is anything
    // else.
    let lead = state
        .iter()
        .enumerate()
        .filter(|(_, l)| l.here >= PRESENT && l.girl.is_some() && !l.looks.is_empty())
        .min_by_key(|(i, l)| (l.drawn.map_or(-1, |d| d as i64), std::cmp::Reverse(l.here), *i))
        .map(|(i, _)| i)
        .filter(|&i| things.is_empty() || last != Some(Subject::Lead(i)));

    // The lot is the chapter's, so planning again draws the same plates.
    let lot = fnv(&format!("{chapter}"));
    let person = lead.filter(|_| things.is_empty() || lot % PERSON_ONE_IN == 0);

    if let Some(i) = person {
        let lead = &mut state[i];
        lead.drawn = Some(stretch.slot);
        let mut cues = lead.looks();
        cues.extend(lead.item());
        // Set where the stretch mostly is: a room or a corridor is too close
        // to draw someone whole in.
        cues.extend(stretch.named(Kind::Place, min, 1, &|w| !sights::is_sight(w)));
        cues.extend(stretch.named(Kind::Sky, min, 1, &|_| true));
        cues.extend(stretch.named(Kind::Motif, min * 2, 1, &|w| BEHIND.contains(&w.label)));
        let plate = Plate {
            chapter,
            who: if lead.girl == Some(true) {
                Who::Girl(i)
            } else {
                Who::Boy(i)
            },
            cues,
            seed: fnv(&leads[i][0]),
        };
        return Some((plate, Subject::Lead(i)));
    }

    let (focus, from) = if things.is_empty() {
        // Nothing dwelt on: where the stretch mostly is, if anywhere.
        let place = *stretch.named(Kind::Place, min, 1, &|_| true).first()?;
        (place, None)
    } else {
        let total: f32 = things.iter().map(|d| d.more).sum();
        let mut roll = (lot / PERSON_ONE_IN % 1000) as f32 / 1000.0 * total;
        let d = things
            .iter()
            .find(|d| {
                roll -= d.more;
                roll < 0.0
            })
            .unwrap_or(&things[things.len() - 1]);
        (stretch.word(d.word), Some(d.from))
    };
    let mut cues = vec![focus];
    match from {
        Some(from) => {
            if focus.kind == Kind::Motif {
                cues.extend(stretch.around(from, Kind::Place));
            }
            cues.extend(stretch.around(from, Kind::Sky));
        }
        None => cues.extend(stretch.named(Kind::Sky, min, 1, &|_| true)),
    }
    let plate = Plate {
        chapter,
        who: Who::Nobody,
        cues,
        seed: fnv(focus.label) ^ chapter as u32,
    };
    Some((plate, Subject::Thing(focus.label)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::Span;

    fn book(chs: &[&str]) -> (String, Vec<Chapter>) {
        let mut text = String::new();
        let mut chapters = Vec::new();
        for (i, body) in chs.iter().enumerate() {
            let start = text.len();
            text.push_str(&format!("第{}章\n", i + 1));
            let body_start = text.len();
            text.push_str(body);
            text.push('\n');
            chapters.push(Chapter {
                index: i,
                number: None,
                title: format!("第{}章", i + 1),
                span: Span {
                    start,
                    end: text.len(),
                },
                body_start,
            });
        }
        (text, chapters)
    }

    fn labels(p: &Plate) -> Vec<&'static str> {
        p.cues.iter().map(|w| w.label).collect()
    }

    fn leads(names: &[&str]) -> Vec<Vec<String>> {
        names.iter().map(|n| vec![n.to_string()]).collect()
    }

    #[test]
    fn a_lead_is_drawn_as_the_text_describes_them() {
        let ch = "宁姚一袭白衣，长发及腰，她站在竹林里。宁姚笑了笑，她没有说话。\
                  宁姚转过身，她看向远处。宁姚握紧了手中的长剑，她向前走去。\
                  宁姚拔出长剑。宁姚收起长剑。竹林里起了雾，竹林很深，竹林很静。";
        let (text, chapters) = book(&[ch, ch]);
        let plates = plan(&text, &chapters, &leads(&["宁姚"]), 2);
        assert_eq!(plates.len(), 1);
        let p = &plates[0];
        assert_eq!(p.chapter, 1);
        assert_eq!(p.who, Who::Girl(0));
        assert_eq!(labels(p), ["白衣", "长发", "剑", "竹林"]);
        assert_eq!(p.seed, fnv("宁姚"));
    }

    #[test]
    fn someone_else_in_the_clause_keeps_their_own_clothes() {
        // A girl he sees, a man named by his hair, an old man's white hair,
        // and what he looks at: none of it is his.
        let ch = "陈平安看见一个白衣少女。长发男看向陈平安。满头白发的老儒士走向陈平安。\
                  陈平安扭头看去，极具光泽的美丽金发。少年陈平安点点头，他转身离开。\
                  陈平安叹了口气，他走了。陈平安笑了，他很开心。陈平安穿着草鞋。";
        let (text, chapters) = book(&[ch]);
        let plates = plan(&text, &chapters, &leads(&["陈平安"]), 1);
        assert_eq!(plates[0].who, Who::Boy(0));
        assert_eq!(labels(&plates[0]), ["草鞋"]);
    }

    #[test]
    fn leads_take_turns_and_nobody_gets_the_place() {
        let a = "林夕一袭红衣，她笑着。林夕点头，她走了。林夕看书，她很安静。林夕睡了。林夕醒了。";
        let b = "苏白穿着黑袍，他沉默。苏白点头，他走了。苏白看书，他很安静。苏白睡了。苏白醒了。";
        let quiet = "海边的风很大。海边没有人。海边只有浪。";
        let (text, chapters) = book(&[&format!("{a}{b}"), &format!("{a}{b}"), quiet]);
        let plates = plan(&text, &chapters, &leads(&["林夕", "苏白"]), 1);
        let who: Vec<Who> = plates.iter().map(|p| p.who).collect();
        assert_eq!(who, [Who::Girl(0), Who::Boy(1), Who::Nobody]);
        assert_eq!(labels(&plates[2]), ["大海"]);
    }

    #[test]
    fn a_passage_dwelling_on_a_thing_draws_it_in_its_light() {
        let filler = "今天天气不错。".repeat(200);
        let dwelling = "她打开铅笔盒。铅笔盒里很乱。漆黑的铅笔盒上贴着贴纸。他合上铅笔盒。";
        let (text, chapters) = book(&[&filler, &filler, &filler, dwelling]);
        let plates = plan(&text, &chapters, &[], 4);
        assert_eq!(plates[0].who, Who::Nobody);
        assert_eq!(labels(&plates[0]), ["铅笔盒", "黑暗"]);

        // Named as often everywhere, it is only what the book is always about.
        let every = format!("{filler}{dwelling}");
        let (text, chapters) = book(&[&every, &every, &every, &every]);
        assert!(plan(&text, &chapters, &[], 4).is_empty());
    }

    #[test]
    fn a_stretch_with_nothing_to_draw_has_no_plate() {
        let (text, chapters) = book(&["今天天气不错。", "他说了几句话。"]);
        assert!(plan(&text, &chapters, &leads(&["林夕"]), 1).is_empty());
    }
}
