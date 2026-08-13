//! Conservative whole-book relationship structure.
//!
//! This module does not ask a small model to guess whether a novel is 单女主,
//! 多女主 or 后宫. It keeps a ledger of sentences whose grammar binds the
//! protagonist and one specific candidate to a relationship predicate. Missing
//! evidence remains “无法判断”; every positive result carries source text.

use crate::cast::{Edge, Person};
use regex::Regex;
use std::collections::{HashMap, HashSet};

pub const RELATIONSHIP_VERSION: u32 = 3;

const ROMANTIC_ROLES: &[&str] = &[
    "妻子",
    "丈夫",
    "夫君",
    "娘子",
    "相公",
    "老婆",
    "老公",
    "媳妇",
    "未婚妻",
    "未婚夫",
    "女朋友",
    "男朋友",
    "女友",
    "男友",
    "恋人",
    "爱人",
    "道侣",
    "伴侣",
    "情郎",
    "心上人",
    "意中人",
];
const COMMIT_ACTIONS: &[&str] = &[
    "成亲",
    "成婚",
    "结婚",
    "完婚",
    "大婚",
    "拜堂",
    "结为夫妻",
    "结为道侣",
    "确定关系",
    "正式交往",
    "在一起了",
];
const LOVE_ACTIONS: &[&str] = &[
    "喜欢", "爱上", "爱慕", "倾心", "钟情", "心悦", "暗恋", "迷恋",
];
const INTIMATE_ACTIONS: &[&str] = &[
    "搂住",
    "搂入怀",
    "抱在怀",
    "牵起",
    "牵住",
    "同床",
    "洞房",
    "云雨",
    "双修",
];
const ROMANTIC_INTIMATE_ACTIONS: &[&str] = &["亲吻", "接吻", "吻住", "吻了", "拥吻", "十指相扣"];
const SEXUAL_ACTIONS: &[&str] = &[
    "入洞房",
    "洞房",
    "圆房",
    "同床共枕",
    "云雨",
    "肌肤之亲",
    "发生关系",
];
const ROMANTIC_TENSION_CUES: &[&str] = &[
    "脸红",
    "红了脸",
    "吃醋",
    "醋意",
    "约会",
    "不讨厌",
    "形影不离",
    "最喜欢的人",
    "那份爱",
];
const EMOTIONAL_COMFORT_ACTIONS: &[&str] = &[
    "抱住", "搂住", "搂着", "搂紧", "依偎", "靠在", "靠着", "枕在",
];
const EMOTIONAL_COMFORT_CONTEXT: &[&str] = &[
    "怀里", "胸膛", "胸口", "肩膀", "肩上", "枕头", "床上", "睡着", "入睡", "踏实", "安心", "哭泣",
    "眼泪", "脸红", "温柔", "约会", "发香", "腰肢",
];
const TRAP_CUES: &[&str] = &[
    "梦见",
    "做梦",
    "梦中",
    "假扮",
    "冒充",
    "假装",
    "演戏",
    "玩笑",
    "开玩笑",
    "误会",
    "谣言",
    "传闻",
    "如果",
    "假如",
    "差点",
    "险些",
    "并没有",
    "并不是",
    "并未",
    "从未",
    "不曾",
    "不可能",
    "不喜欢",
    "并不喜欢",
    "不爱",
    "没有喜欢",
    "拒绝",
];
const GROUP_CUES: &[&str] = &[
    "平等的爱",
    "都已经在一起",
    "全都在一起",
    "都是他的女朋友",
    "都是她的女朋友",
    "都是他的妻子",
    "都是她的妻子",
    "同时交往",
    "共同嫁给",
    "一起嫁给",
    "后宫之主",
];
const NON_ROMANCE_LABELS: &[&str] = &["师徒", "亲子", "兄弟姐妹", "同门", "朋友", "上下级", "敌对"];
const DIALOGUE_SPEECH_CUES: &[&str] = &[
    "张口就问",
    "笑着说",
    "轻声说",
    "低声说",
    "说道",
    "问道",
    "答道",
    "回道",
    "回答",
    "反问",
    "接道",
    "续道",
    "笑道",
    "轻声道",
    "低声道",
    "说",
    "问",
    "答",
    "喊",
    "叫",
];
const DIALOGUE_HARD_TRAPS: &[&str] = &[
    "梦见",
    "做梦",
    "梦中",
    "假扮",
    "冒充",
    "假装",
    "演戏",
    "玩笑",
    "开玩笑",
    "误会",
    "谣言",
    "传闻",
    "如果",
    "假如",
    "要是",
    "差点",
    "险些",
];
const DIALOGUE_PROPOSAL_CUES: &[&str] = &["愿意", "要不要", "能不能", "可不可以", "想不想"];
const DIALOGUE_NON_ASSERTION_CUES: &[&str] = &[
    "是不是",
    "是否",
    "怎么会",
    "难道",
    "问她",
    "问他",
    "让你",
    "让我",
    "要让",
    "想让",
    "希望",
    "为了",
    "直接说",
    "应该说",
    "台词",
];
const DIALOGUE_NEGATION_CUES: &[&str] = &[
    "并没有",
    "并未",
    "从未",
    "不曾",
    "不会",
    "不可能",
    "没有",
    "没",
    "不",
];
const DATING_ASPECT_CUES: &[&str] = &[
    "为什么还要",
    "为什么还",
    "明明还在",
    "明明在",
    "已经",
    "正在",
    "一直",
    "还在",
    "仍然",
];

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RelationshipEvidence {
    /// Zero-based chapter index. API/UI converts this to a human chapter number.
    pub chapter: usize,
    pub person: String,
    pub kind: String,
    pub strength: u32,
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RelationshipPerson {
    pub name: String,
    pub status: String,
    pub score: i32,
    pub confirmed: bool,
    pub sustained: bool,
    pub possible: bool,
    pub evidence: Vec<RelationshipEvidence>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RelationshipReport {
    pub label: String,
    pub reason: String,
    /// 0 = insufficient, 1 = weak, 2 = useful, 3 = direct hard evidence.
    pub confidence: u32,
    pub protagonist: String,
    pub analyzed_chapters: usize,
    /// Internal candidates checked. This is deliberately independent from the
    /// ten people shown by the graph UI.
    pub candidate_count: usize,
    pub people: Vec<RelationshipPerson>,
    pub group_evidence: Vec<RelationshipEvidence>,
    pub version: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Kind {
    Explicit,
    Sexual,
    SexualCultivation,
    Mutual,
    Love,
    RomanticIntimate,
    Intimate,
    RomanticTension,
    EmotionalComfort,
}

impl Kind {
    fn zh(self) -> &'static str {
        match self {
            Self::Explicit => "明确关系",
            Self::Sexual => "性关系",
            Self::SexualCultivation => "性双修",
            Self::Mutual => "双向感情",
            Self::Love => "喜欢",
            Self::RomanticIntimate => "浪漫亲密",
            Self::Intimate => "亲密",
            Self::RomanticTension => "暧昧信号",
            Self::EmotionalComfort => "亲密依赖",
        }
    }
}

struct Rule {
    regex: Regex,
    strength: u32,
    kind: Kind,
    direction: &'static str,
}

#[derive(Default)]
struct Ledger {
    evidence: Vec<(Kind, &'static str, RelationshipEvidence)>,
    seen: HashSet<(usize, Kind, String)>,
}

struct DialogueTurn {
    chapter: usize,
    position: usize,
    speaker: usize,
    quote: String,
    text: String,
}

fn variants(person: &Person) -> Vec<&str> {
    let mut out: Vec<&str> = std::iter::once(person.name.as_str())
        .chain(person.aliases.iter().map(String::as_str))
        .filter(|name| name.chars().count() >= 2)
        .collect();
    out.sort_by_key(|name| std::cmp::Reverse(name.chars().count()));
    out.dedup();
    out
}

fn alt(words: &[&str]) -> String {
    format!(
        "(?:{})",
        words
            .iter()
            .map(|word| regex::escape(word))
            .collect::<Vec<_>>()
            .join("|")
    )
}

fn person_alt(person: &Person) -> String {
    alt(&variants(person))
}

fn relation_rules(a: &Person, b: &Person) -> Vec<Rule> {
    let aa = person_alt(a);
    let bb = person_alt(b);
    let role = alt(ROMANTIC_ROLES);
    let commit = alt(COMMIT_ACTIONS);
    let love = alt(LOVE_ACTIONS);
    let intimate = alt(INTIMATE_ACTIONS);
    let romantic_intimate = alt(ROMANTIC_INTIMATE_ACTIONS);
    let sexual = alt(SEXUAL_ACTIONS);
    let tension = alt(ROMANTIC_TENSION_CUES);
    let comfort = alt(EMOTIONAL_COMFORT_ACTIONS);
    let c = |n: usize| format!(r#"[^，,。！？!?；;：“”"（）()]{{0,{n}}}"#);
    let soft = |n: usize| format!(r#"[^。！？!?；;]{{0,{n}}}"#);
    let c6 = c(6);
    let c8 = c(8);
    let c12 = c(12);
    let c16 = c(16);
    let soft10 = soft(10);
    let soft20 = soft(20);
    let soft30 = soft(30);
    let adv = r"(?:也|很|最|真的|一直|渐渐|渐渐地|早就|还是|特别|更|其实|已经|逐渐|似乎|可能|却|只|只是|就|都){0,3}";
    let love_tail = r"(?:上|上了|着|的(?:人)?(?:是)?|的是|的就是)?(?:和|跟|与)?";
    let specs: Vec<(String, u32, Kind, &'static str)> = vec![
        (
            format!("{bb}(?:是|乃是|便是|成为|成了|当了)?{aa}的{role}"),
            10,
            Kind::Explicit,
            "B→A",
        ),
        (
            format!("{aa}(?:是|乃是|便是|成为|成了|当了)?{bb}的{role}"),
            10,
            Kind::Explicit,
            "A→B",
        ),
        (
            format!("{aa}的{role}(?:是|叫|名叫)?{bb}"),
            10,
            Kind::Explicit,
            "A→B",
        ),
        (
            format!("{bb}的{role}(?:是|叫|名叫)?{aa}"),
            10,
            Kind::Explicit,
            "B→A",
        ),
        (
            format!("{aa}{c8}(?:迎娶|娶了|娶|纳了|纳为){c6}{bb}"),
            10,
            Kind::Explicit,
            "A→B",
        ),
        (
            format!("{bb}{c8}(?:嫁给|嫁了|迎娶|娶了|娶){c6}{aa}"),
            10,
            Kind::Explicit,
            "B→A",
        ),
        (
            format!("{aa}(?:与|和|跟){bb}{c16}{commit}"),
            9,
            Kind::Explicit,
            "双向",
        ),
        (
            format!("{bb}(?:与|和|跟){aa}{c16}{commit}"),
            9,
            Kind::Explicit,
            "双向",
        ),
        (
            format!("{commit}{c12}{aa}(?:与|和|跟){bb}"),
            9,
            Kind::Explicit,
            "双向",
        ),
        (
            format!("{commit}{c12}{bb}(?:与|和|跟){aa}"),
            9,
            Kind::Explicit,
            "双向",
        ),
        (
            format!("{aa}{adv}{love}{love_tail}{bb}"),
            5,
            Kind::Love,
            "A→B",
        ),
        (
            format!("{bb}{adv}{love}{love_tail}{aa}"),
            5,
            Kind::Love,
            "B→A",
        ),
        (
            format!("{aa}(?:与|和|跟){bb}{c16}(?:两情相悦|互相喜欢|彼此喜欢|相爱)"),
            7,
            Kind::Mutual,
            "双向",
        ),
        (
            format!("{bb}(?:与|和|跟){aa}{c16}(?:两情相悦|互相喜欢|彼此喜欢|相爱)"),
            7,
            Kind::Mutual,
            "双向",
        ),
        (format!("{aa}{c8}{sexual}{c8}{bb}"), 8, Kind::Sexual, "双向"),
        (format!("{bb}{c8}{sexual}{c8}{aa}"), 8, Kind::Sexual, "双向"),
        (
            format!("{aa}{c8}(?:和|与|跟){bb}{c8}{sexual}"),
            8,
            Kind::Sexual,
            "双向",
        ),
        (
            format!("{bb}{c8}(?:和|与|跟){aa}{c8}{sexual}"),
            8,
            Kind::Sexual,
            "双向",
        ),
        (
            format!("{aa}{c8}(?:和|与|跟){bb}{c8}双修"),
            8,
            Kind::SexualCultivation,
            "双向",
        ),
        (
            format!("{bb}{c8}(?:和|与|跟){aa}{c8}双修"),
            8,
            Kind::SexualCultivation,
            "双向",
        ),
        (
            format!("{aa}{c8}{romantic_intimate}{c8}{bb}"),
            6,
            Kind::RomanticIntimate,
            "A→B",
        ),
        (
            format!("{bb}{c8}{romantic_intimate}{c8}{aa}"),
            6,
            Kind::RomanticIntimate,
            "B→A",
        ),
        (
            format!("{aa}(?:与|和|跟){bb}{c12}{romantic_intimate}"),
            6,
            Kind::RomanticIntimate,
            "双向",
        ),
        (
            format!("{bb}(?:与|和|跟){aa}{c12}{romantic_intimate}"),
            6,
            Kind::RomanticIntimate,
            "双向",
        ),
        (
            format!("{aa}{c8}{intimate}{c8}{bb}"),
            4,
            Kind::Intimate,
            "A→B",
        ),
        (
            format!("{bb}{c8}{intimate}{c8}{aa}"),
            4,
            Kind::Intimate,
            "B→A",
        ),
        (
            format!("{aa}(?:与|和|跟){bb}{c12}{intimate}"),
            4,
            Kind::Intimate,
            "双向",
        ),
        (
            format!("{bb}(?:与|和|跟){aa}{c12}{intimate}"),
            4,
            Kind::Intimate,
            "双向",
        ),
        (
            format!("{aa}{soft20}{tension}{soft20}{bb}"),
            3,
            Kind::RomanticTension,
            "双向",
        ),
        (
            format!("{bb}{soft20}{tension}{soft20}{aa}"),
            3,
            Kind::RomanticTension,
            "双向",
        ),
        (
            format!("{aa}{soft20}{bb}{soft10}{tension}"),
            3,
            Kind::RomanticTension,
            "双向",
        ),
        (
            format!("{bb}{soft20}{aa}{soft10}{tension}"),
            3,
            Kind::RomanticTension,
            "双向",
        ),
        (
            format!("{aa}{soft30}{comfort}{soft10}{bb}"),
            3,
            Kind::EmotionalComfort,
            "A→B",
        ),
        (
            format!("{bb}{soft30}{comfort}{soft10}{aa}"),
            3,
            Kind::EmotionalComfort,
            "B→A",
        ),
    ];
    specs
        .into_iter()
        .filter_map(|(pattern, strength, kind, direction)| {
            Regex::new(&pattern).ok().map(|regex| Rule {
                regex,
                strength,
                kind,
                direction,
            })
        })
        .collect()
}

fn compact(text: &str) -> String {
    text.chars().filter(|c| !c.is_whitespace()).collect()
}

fn clip(text: &str, limit: usize) -> String {
    let mut clipped: String = text.chars().take(limit).collect();
    if text.chars().count() > limit {
        clipped.push('…');
    }
    clipped
}

fn has_any(text: &str, words: &[&str]) -> bool {
    words.iter().any(|word| text.contains(word))
}

fn has_romance_cue(text: &str) -> bool {
    [
        ROMANTIC_ROLES,
        COMMIT_ACTIONS,
        LOVE_ACTIONS,
        INTIMATE_ACTIONS,
        ROMANTIC_INTIMATE_ACTIONS,
        SEXUAL_ACTIONS,
        ROMANTIC_TENSION_CUES,
        EMOTIONAL_COMFORT_ACTIONS,
    ]
    .into_iter()
    .flatten()
    .any(|word| text.contains(word))
        || [
            "表白", "告白", "情意", "醋意", "吃醋", "暧昧", "婚约", "婚事",
        ]
        .iter()
        .any(|word| text.contains(word))
}

fn candidate_usable(person: &Person) -> bool {
    let density = person.mentions as f32 / person.chapters.max(1) as f32;
    density >= 1.5
        && ![
            "母亲", "父亲", "妈妈", "爸爸", "老师", "同学", "太太", "先生", "小姐", "学姐", "学妹",
            "学长", "学弟",
        ]
        .iter()
        .any(|role| person.name.ends_with(role))
}

fn group_candidate_usable(person: &Person) -> bool {
    let density = person.mentions as f32 / person.chapters.max(1) as f32;
    density >= 1.5
        && !["母亲", "父亲", "妈妈", "爸爸"]
            .iter()
            .any(|role| person.name.ends_with(role))
}

fn canonical_group_name<'a>(person: &'a Person, candidates: &[(usize, &'a Person)]) -> &'a str {
    if candidate_usable(person) {
        return person.name.as_str();
    }
    let stem = [
        "老师", "同学", "太太", "先生", "小姐", "学姐", "学妹", "学长", "学弟",
    ]
    .iter()
    .find_map(|role| person.name.strip_suffix(role))
    .unwrap_or(person.name.as_str());
    if stem.chars().count() < 2 {
        return person.name.as_str();
    }
    candidates
        .iter()
        .map(|(_, candidate)| *candidate)
        .find(|candidate| variants(candidate).iter().any(|name| name.contains(stem)))
        .map(|candidate| candidate.name.as_str())
        .unwrap_or(person.name.as_str())
}

fn sentence_windows(paras: &[(usize, &str)]) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut previous: Option<(usize, String)> = None;
    for &(chapter, line) in paras {
        for sentence in line.split_inclusive(['。', '！', '？', '!', '?', '；', ';']) {
            let sentence = compact(sentence);
            if sentence.chars().count() < 4 {
                continue;
            }
            out.push((chapter, sentence.clone()));
            if let Some((prev_chapter, prev)) = &previous {
                if *prev_chapter == chapter
                    && prev.chars().count() + sentence.chars().count() <= 360
                {
                    out.push((chapter, format!("{prev}{sentence}")));
                }
            }
            previous = Some((chapter, sentence));
        }
    }
    out
}

fn head_chars(text: &str, count: usize) -> String {
    text.chars().take(count).collect()
}

fn tail_chars(text: &str, count: usize) -> String {
    let start = text
        .char_indices()
        .rev()
        .nth(count.saturating_sub(1))
        .map(|(index, _)| index)
        .unwrap_or(0);
    text[start..].to_string()
}

fn attributed_speaker(attribution: &str, people: &[&Person]) -> Option<usize> {
    let mut hits = HashSet::new();
    for (index, person) in people.iter().enumerate() {
        for name in variants(person) {
            for (position, _) in attribution.match_indices(name) {
                let tail = head_chars(&attribution[position + name.len()..], 48);
                if has_any(&tail, DIALOGUE_SPEECH_CUES) {
                    hits.insert(index);
                    break;
                }
            }
        }
    }
    (hits.len() == 1).then(|| *hits.iter().next().unwrap())
}

fn dialogue_turns(paras: &[(usize, &str)], people: &[&Person]) -> Vec<DialogueTurn> {
    let mut turns = Vec::new();
    let mut seen = HashSet::new();
    for (position, &(chapter, raw_line)) in paras.iter().enumerate() {
        let line = compact(raw_line);
        let mut cursor = 0;
        while let Some(open_rel) = line[cursor..].find('“') {
            let open = cursor + open_rel;
            let quote_start = open + '“'.len_utf8();
            let Some(close_rel) = line[quote_start..].find('”') else {
                break;
            };
            let close = quote_start + close_rel;
            let quote = line[quote_start..close].to_string();
            if quote.chars().count() >= 2 && quote.chars().count() <= 260 {
                let before = tail_chars(&line[..open], 90);
                let after_start = close + '”'.len_utf8();
                let after = head_chars(&line[after_start..], 120);
                let speaker = attributed_speaker(&after, people)
                    .or_else(|| attributed_speaker(&before, people));
                if let Some(speaker) = speaker {
                    let key = (chapter, speaker, quote.clone());
                    if seen.insert(key) {
                        turns.push(DialogueTurn {
                            chapter,
                            position,
                            speaker,
                            quote,
                            text: clip(
                                &format!(
                                    "{}“{}”{}",
                                    tail_chars(&before, 50),
                                    &line[quote_start..close],
                                    head_chars(&after, 80)
                                ),
                                320,
                            ),
                        });
                    }
                }
            }
            cursor = close + '”'.len_utf8();
        }
    }
    turns.sort_by_key(|turn| (turn.chapter, turn.position));
    turns
}

fn dialogue_pair_is_bound(
    turn: &DialogueTurn,
    other: usize,
    turns: &[DialogueTurn],
    paras: &[(usize, &str)],
    people: &[&Person],
) -> bool {
    let nearby: Vec<&DialogueTurn> = turns
        .iter()
        .filter(|nearby| {
            nearby.chapter == turn.chapter
                && nearby.speaker != turn.speaker
                && nearby.position.abs_diff(turn.position) <= 3
        })
        .collect();
    if !nearby.is_empty() {
        let nearest = nearby
            .iter()
            .map(|nearby| nearby.position.abs_diff(turn.position))
            .min()
            .unwrap();
        let nearest_speakers: HashSet<usize> = nearby
            .into_iter()
            .filter(|nearby| nearby.position.abs_diff(turn.position) == nearest)
            .map(|nearby| nearby.speaker)
            .collect();
        return nearest_speakers.len() == 1 && nearest_speakers.contains(&other);
    }

    let left = turn.position.saturating_sub(1);
    let right = (turn.position + 2).min(paras.len());
    let context = compact(
        &paras[left..right]
            .iter()
            .filter(|(chapter, _)| *chapter == turn.chapter)
            .map(|(_, text)| *text)
            .collect::<String>(),
    );
    let named_others: HashSet<usize> = people
        .iter()
        .enumerate()
        .filter(|(index, person)| {
            *index != turn.speaker && variants(person).iter().any(|name| context.contains(name))
        })
        .map(|(index, _)| index)
        .collect();
    named_others.len() == 1 && named_others.contains(&other)
}

fn predicate_is_negated(text: &str, predicate_start: usize) -> bool {
    let prefix = tail_chars(&text[..predicate_start], 8);
    DIALOGUE_NEGATION_CUES
        .iter()
        .any(|cue| prefix.ends_with(cue))
}

fn dialogue_dating_fact(quote: &str) -> bool {
    for (predicate_start, _) in quote.match_indices("谈恋爱") {
        let prefix = tail_chars(&quote[..predicate_start], 28);
        if !has_any(&prefix, DATING_ASPECT_CUES)
            || !has_any(&prefix, &["我", "你"])
            || has_any(&prefix, DIALOGUE_HARD_TRAPS)
            || has_any(&prefix, DIALOGUE_PROPOSAL_CUES)
            || predicate_is_negated(quote, predicate_start)
        {
            continue;
        }
        return true;
    }
    false
}

fn cognition_about_third_person(text: &str) -> bool {
    let cognition = ["想", "觉得", "认为", "知道", "听说"]
        .iter()
        .filter_map(|word| text.find(word))
        .min();
    let third = ["她", "他", "别人", "某人"]
        .iter()
        .filter_map(|word| text.find(word))
        .min();
    matches!((cognition, third), (Some(cognition), Some(third)) if cognition < third)
}

fn direct_dialogue_love(quote: &str, start: usize, end: usize, matched: &str) -> bool {
    let prefix = tail_chars(&quote[..start], 16);
    let suffix = head_chars(&quote[end..], 4);
    let local = format!("{prefix}{matched}{suffix}");
    if matched.contains("你们")
        || has_any(&local, DIALOGUE_NON_ASSERTION_CUES)
        || has_any(&local, DIALOGUE_HARD_TRAPS)
        || has_any(&local, DIALOGUE_PROPOSAL_CUES)
        || has_any(&suffix, &["？", "?"])
        || cognition_about_third_person(matched)
    {
        return false;
    }
    let predicate_start = ["喜欢上", "喜欢着", "爱上", "爱着", "喜欢", "爱"]
        .iter()
        .filter_map(|word| matched.find(word))
        .min();
    predicate_start.is_some_and(|predicate_start| !predicate_is_negated(matched, predicate_start))
}

fn add_dialogue_evidence(paras: &[(usize, &str)], all_people: &[&Person], ledgers: &mut [Ledger]) {
    let turns = dialogue_turns(paras, all_people);
    let i_love_you =
        Regex::new(r"我[^。！？!?；;]{0,10}(?:喜欢(?:上|着)?|爱上|爱着|爱)(?:了)?你").unwrap();
    let you_love_me =
        Regex::new(r"你[^。！？!?；;]{0,10}(?:喜欢(?:上|着)?|爱上|爱着|爱)(?:了)?我").unwrap();

    for (candidate_position, ledger) in ledgers.iter_mut().enumerate() {
        let candidate = candidate_position + 1;
        for turn in &turns {
            if turn.speaker != 0 && turn.speaker != candidate {
                continue;
            }
            let other = if turn.speaker == 0 { candidate } else { 0 };
            if !dialogue_pair_is_bound(turn, other, &turns, paras, all_people) {
                continue;
            }
            if dialogue_dating_fact(&turn.quote) {
                let matched = format!("对话既成关系：{}", clip(&turn.quote, 90));
                if ledger.seen.insert((turn.chapter, Kind::Explicit, matched)) {
                    ledger.evidence.push((
                        Kind::Explicit,
                        "双向",
                        RelationshipEvidence {
                            chapter: turn.chapter,
                            person: all_people[candidate].name.clone(),
                            kind: Kind::Explicit.zh().to_string(),
                            strength: 9,
                            text: turn.text.clone(),
                        },
                    ));
                }
            }
            for found in i_love_you.find_iter(&turn.quote) {
                if !direct_dialogue_love(&turn.quote, found.start(), found.end(), found.as_str()) {
                    continue;
                }
                let direction = if turn.speaker == 0 { "A→B" } else { "B→A" };
                let matched = found.as_str().to_string();
                if ledger.seen.insert((turn.chapter, Kind::Love, matched)) {
                    ledger.evidence.push((
                        Kind::Love,
                        direction,
                        RelationshipEvidence {
                            chapter: turn.chapter,
                            person: all_people[candidate].name.clone(),
                            kind: Kind::Love.zh().to_string(),
                            strength: 5,
                            text: turn.text.clone(),
                        },
                    ));
                }
            }
            for found in you_love_me.find_iter(&turn.quote) {
                if !direct_dialogue_love(&turn.quote, found.start(), found.end(), found.as_str()) {
                    continue;
                }
                let direction = if other == 0 { "A→B" } else { "B→A" };
                let matched = found.as_str().to_string();
                if ledger.seen.insert((turn.chapter, Kind::Love, matched)) {
                    ledger.evidence.push((
                        Kind::Love,
                        direction,
                        RelationshipEvidence {
                            chapter: turn.chapter,
                            person: all_people[candidate].name.clone(),
                            kind: Kind::Love.zh().to_string(),
                            strength: 5,
                            text: turn.text.clone(),
                        },
                    ));
                }
            }
        }
    }
}

fn cast_context(edges: &[Edge], protagonist: usize, candidate: usize) -> (Option<&str>, u32) {
    let Some(edge) = edges.iter().find(|edge| {
        (edge.a == protagonist && edge.b == candidate)
            || (edge.a == candidate && edge.b == protagonist)
    }) else {
        return (None, 0);
    };
    let hints = edge
        .hints
        .iter()
        .filter(|(word, _)| ROMANTIC_ROLES.contains(&word.as_str()))
        .map(|(_, count)| *count)
        .sum();
    (edge.label.as_deref(), hints)
}

fn summarize(
    person: &Person,
    ledger: Ledger,
    cast_label: Option<&str>,
    romantic_hints: u32,
) -> RelationshipPerson {
    let mut counts: HashMap<Kind, HashSet<usize>> = HashMap::new();
    let mut directions = HashSet::new();
    for (kind, direction, evidence) in &ledger.evidence {
        counts.entry(*kind).or_default().insert(evidence.chapter);
        if *kind == Kind::Love || *kind == Kind::Mutual {
            directions.insert(*direction);
        }
    }
    let count = |kind| counts.get(&kind).map(HashSet::len).unwrap_or(0) as i32;
    let explicit = count(Kind::Explicit);
    let sexual = count(Kind::Sexual);
    let sexual_cultivation = count(Kind::SexualCultivation);
    let mutual = count(Kind::Mutual);
    let love = count(Kind::Love);
    let romantic_intimate = count(Kind::RomanticIntimate);
    let intimate = count(Kind::Intimate);
    let tension = count(Kind::RomanticTension);
    let comfort = count(Kind::EmotionalComfort);
    let nonromance = cast_label.is_some_and(|label| NON_ROMANCE_LABELS.contains(&label));
    let confirmed = explicit >= 1 || sexual >= 1 || sexual_cultivation >= 1;
    let directional_mutual = directions.contains("A→B") && directions.contains("B→A");
    let conventional_sustained = confirmed
        || mutual >= 1
        || (love >= 2 && (directional_mutual || intimate >= 2))
        || (love >= 1 && intimate >= 2)
        || (directional_mutual && love >= 1 && intimate >= 1)
        || romantic_intimate >= 2
        || (intimate >= 3 && romantic_hints >= 2);
    let ambiguous_sustained = comfort >= 2;
    let mut sustained = conventional_sustained || ambiguous_sustained;
    let mut possible = sustained
        || love >= 2
        || romantic_intimate >= 1
        || intimate >= 2
        || tension >= 2
        || comfort >= 2
        || romantic_hints >= 2;
    let repeated_romance_override =
        love >= 2 || romantic_intimate >= 2 || (love >= 1 && intimate >= 2);
    if nonromance && !confirmed && mutual == 0 && !repeated_romance_override {
        sustained = false;
        possible = false;
    }
    let score = explicit * 12
        + sexual * 10
        + sexual_cultivation * 10
        + mutual * 8
        + love * 3
        + romantic_intimate * 4
        + intimate * 2
        + tension * 3
        + comfort * 3
        + (romantic_hints.min(6) as i32)
        - if nonromance && !confirmed { 4 } else { 0 };
    let status = if confirmed {
        "已确认伴侣"
    } else if sustained {
        if ambiguous_sustained && !conventional_sustained {
            "持续暧昧关系"
        } else {
            "持续双向关系"
        }
    } else if possible {
        "可能感情对象"
    } else {
        "没有成对证据"
    };
    let mut evidence: Vec<RelationshipEvidence> = ledger
        .evidence
        .into_iter()
        .map(|(_, _, evidence)| evidence)
        .collect();
    evidence.sort_by_key(|evidence| std::cmp::Reverse(evidence.strength));
    evidence.truncate(10);
    RelationshipPerson {
        name: person.name.clone(),
        status: status.to_string(),
        score,
        confirmed,
        sustained,
        possible,
        evidence,
    }
}

fn merge_same_identity(
    mut rows: Vec<RelationshipPerson>,
    candidates: &[(usize, &Person)],
    windows: &[(usize, String)],
) -> Vec<RelationshipPerson> {
    let mut parent: Vec<usize> = (0..rows.len()).collect();
    fn root(parent: &mut [usize], mut index: usize) -> usize {
        while parent[index] != index {
            parent[index] = parent[parent[index]];
            index = parent[index];
        }
        index
    }
    let identity_windows: Vec<&str> = windows
        .iter()
        .map(|(_, window)| window.as_str())
        .filter(|window| has_any(window, &["副人格", "第二人格", "主人格"]))
        .collect();
    for a in 0..rows.len() {
        for b in a + 1..rows.len() {
            let phrases: Vec<String> = ["副人格", "第二人格", "主人格"]
                .iter()
                .flat_map(|kind| {
                    [
                        format!("{}的{kind}{}", rows[a].name, rows[b].name),
                        format!("{}的{kind}{}", rows[b].name, rows[a].name),
                        format!("{}是{}的{kind}", rows[a].name, rows[b].name),
                        format!("{}是{}的{kind}", rows[b].name, rows[a].name),
                    ]
                })
                .collect();
            let same = identity_windows
                .iter()
                .any(|window| phrases.iter().any(|phrase| window.contains(phrase)));
            if same {
                let ra = root(&mut parent, a);
                let rb = root(&mut parent, b);
                if ra != rb {
                    parent[rb] = ra;
                }
            }
        }
    }
    let mention_count = |name: &str| {
        candidates
            .iter()
            .find(|(_, person)| person.name == name)
            .map(|(_, person)| person.mentions)
            .unwrap_or(0)
    };
    let mut groups: HashMap<usize, Vec<RelationshipPerson>> = HashMap::new();
    for index in 0..rows.len() {
        let r = root(&mut parent, index);
        groups.entry(r).or_default().push(std::mem::replace(
            &mut rows[index],
            RelationshipPerson {
                name: String::new(),
                status: String::new(),
                score: 0,
                confirmed: false,
                sustained: false,
                possible: false,
                evidence: Vec::new(),
            },
        ));
    }
    let mut merged = Vec::with_capacity(groups.len());
    for mut members in groups.into_values() {
        members.sort_by_key(|member| std::cmp::Reverse(mention_count(&member.name)));
        if members.len() == 1 {
            merged.push(members.pop().unwrap());
            continue;
        }
        let name = members
            .iter()
            .map(|member| member.name.as_str())
            .collect::<Vec<_>>()
            .join(" / ");
        let confirmed = members.iter().any(|member| member.confirmed);
        let mut sustained = members.iter().any(|member| member.sustained);
        let mut possible = members.iter().any(|member| member.possible);
        let score = members.iter().map(|member| member.score).sum();
        let mut evidence: Vec<_> = members
            .into_iter()
            .flat_map(|member| member.evidence)
            .collect();
        evidence.sort_by_key(|item| std::cmp::Reverse(item.strength));
        evidence.dedup_by(|a, b| a.chapter == b.chapter && a.kind == b.kind && a.text == b.text);
        let comfort_chapters: HashSet<usize> = evidence
            .iter()
            .filter(|item| item.kind == Kind::EmotionalComfort.zh())
            .map(|item| item.chapter)
            .collect();
        if comfort_chapters.len() >= 2 {
            sustained = true;
            possible = true;
        }
        evidence.truncate(10);
        merged.push(RelationshipPerson {
            name,
            status: if confirmed {
                "已确认伴侣"
            } else if sustained {
                "持续暧昧关系"
            } else if possible {
                "可能感情对象"
            } else {
                "没有成对证据"
            }
            .into(),
            score,
            confirmed,
            sustained,
            possible,
            evidence,
        });
    }
    merged
}

fn classify(
    rows: &[RelationshipPerson],
    romance_focus: &str,
    group_evidence: &[RelationshipEvidence],
) -> (String, String, u32) {
    let confirmed: Vec<_> = rows.iter().filter(|row| row.confirmed).collect();
    let sustained: Vec<_> = rows.iter().filter(|row| row.sustained).collect();
    let possible: Vec<_> = rows.iter().filter(|row| row.possible).collect();
    if !group_evidence.is_empty() {
        return (
            "后宫".into(),
            "发现主角与多名对象同时维持关系的直接原文".into(),
            3,
        );
    }
    if confirmed.len() >= 2 {
        return (
            "后宫".into(),
            format!("找到 {} 名分别与主角建立明确关系的对象", confirmed.len()),
            3,
        );
    }
    if sustained.len() >= 2 {
        return (
            "多女主".into(),
            format!(
                "找到 {} 名持续感情对象，但不足以确认多段正式关系",
                sustained.len()
            ),
            2,
        );
    }
    if sustained.len() == 1 && possible.len() == 1 {
        return (
            "单女主".into(),
            format!("当前只找到 {} 一条持续关系链", sustained[0].name),
            2,
        );
    }
    if sustained.len() == 1 && possible.len() > 1 {
        return (
            "无法判断".into(),
            "有一个持续对象，但还有未排除的竞争感情对象".into(),
            1,
        );
    }
    if possible.is_empty() && matches!(romance_focus, "很少" | "较少") {
        return (
            "未发现明确感情线".into(),
            "全书关系扫描无成对证据，且感情线规则估计较低".into(),
            2,
        );
    }
    if possible.len() >= 2 {
        return (
            "无法判断".into(),
            "存在多个可能对象，但证据不足以区分多女主与普通暧昧".into(),
            1,
        );
    }
    if possible.len() == 1 {
        return (
            "无法判断".into(),
            "只发现单向或零散亲密证据，不能据此判为单女主".into(),
            1,
        );
    }
    (
        "无法判断".into(),
        "未找到关系不等于能够证明全书没有感情线".into(),
        0,
    )
}

/// Analyze the full ranked cast before the graph UI trims it to ten people.
pub fn analyze(
    paras: &[(usize, &str)],
    people: &[Person],
    edges: &[Edge],
    analyzed_chapters: usize,
    romance_focus: &str,
) -> RelationshipReport {
    let Some(protagonist) = people.first() else {
        return RelationshipReport {
            label: "无法判断".into(),
            reason: "没有识别到可用的主角人物".into(),
            confidence: 0,
            protagonist: String::new(),
            analyzed_chapters,
            candidate_count: 0,
            people: Vec::new(),
            group_evidence: Vec::new(),
            version: RELATIONSHIP_VERSION,
        };
    };
    let candidates: Vec<(usize, &Person)> = people
        .iter()
        .enumerate()
        .skip(1)
        .filter(|(_, person)| candidate_usable(person))
        .collect();
    // Direct group statements often use forms such as “某某学姐” or
    // “某某老师”. They are too noisy for per-person scoring, but remain valid
    // named participants when a strict multi-partner sentence binds them.
    let group_candidates: Vec<&Person> = people
        .iter()
        .skip(1)
        .filter(|person| group_candidate_usable(person))
        .collect();
    let windows = sentence_windows(paras);
    let protagonist_variants = variants(protagonist);
    let all_people: Vec<&Person> = std::iter::once(protagonist)
        .chain(candidates.iter().map(|(_, person)| *person))
        .collect();
    let mut ledgers: Vec<Ledger> = (0..candidates.len()).map(|_| Ledger::default()).collect();
    let rules: Vec<Vec<Rule>> = candidates
        .iter()
        .map(|(_, candidate)| relation_rules(protagonist, candidate))
        .collect();

    for (chapter, window) in &windows {
        if !protagonist_variants
            .iter()
            .any(|name| window.contains(name))
            || !has_romance_cue(window)
        {
            continue;
        }
        let present: HashSet<usize> = all_people
            .iter()
            .enumerate()
            .filter(|(_, person)| variants(person).iter().any(|name| window.contains(name)))
            .map(|(index, _)| index)
            .collect();
        for (candidate_pos, (_, candidate)) in candidates.iter().enumerate() {
            if !variants(candidate).iter().any(|name| window.contains(name)) {
                continue;
            }
            let third_person = present
                .iter()
                .any(|index| *index != 0 && *index != candidate_pos + 1);
            for rule in &rules[candidate_pos] {
                let Some(found) = rule.regex.find(window) else {
                    continue;
                };
                // Candidate position N corresponds to all_people position N+1.
                if third_person && rule.strength < 9 {
                    continue;
                }
                let local_start = window[..found.start()]
                    .char_indices()
                    .rev()
                    .nth(29)
                    .map(|(index, _)| index)
                    .unwrap_or(0);
                let local_end = window[found.end()..]
                    .char_indices()
                    .nth(11)
                    .map(|(index, _)| found.end() + index)
                    .unwrap_or(window.len());
                if has_any(&window[local_start..local_end], TRAP_CUES) {
                    continue;
                }
                if matches!(rule.kind, Kind::RomanticTension | Kind::EmotionalComfort)
                    && has_any(window, TRAP_CUES)
                {
                    continue;
                }
                if rule.kind == Kind::SexualCultivation
                    && !has_any(
                        window,
                        &[
                            "元阴",
                            "元阳",
                            "合欢",
                            "欢愉",
                            "欲火",
                            "情欲",
                            "阴阳交泰",
                            "交合",
                        ],
                    )
                {
                    continue;
                }
                if rule.kind == Kind::EmotionalComfort
                    && (!has_any(window, EMOTIONAL_COMFORT_CONTEXT)
                        || has_any(
                            window,
                            &[
                                "妹妹", "哥哥", "姐姐", "弟弟", "兄弟", "父女", "母女", "父子",
                                "母子",
                            ],
                        ))
                {
                    continue;
                }
                let matched = found.as_str().to_string();
                let ledger = &mut ledgers[candidate_pos];
                if !ledger.seen.insert((*chapter, rule.kind, matched)) {
                    continue;
                }
                ledger.evidence.push((
                    rule.kind,
                    rule.direction,
                    RelationshipEvidence {
                        chapter: *chapter,
                        person: candidate.name.clone(),
                        kind: rule.kind.zh().to_string(),
                        strength: rule.strength,
                        text: clip(window, 300),
                    },
                ));
            }
        }
    }
    add_dialogue_evidence(paras, &all_people, &mut ledgers);

    let rows: Vec<RelationshipPerson> = candidates
        .iter()
        .enumerate()
        .map(|(position, (original_index, candidate))| {
            let (label, hints) = cast_context(edges, 0, *original_index);
            summarize(
                candidate,
                std::mem::take(&mut ledgers[position]),
                label,
                hints,
            )
        })
        .collect();
    let mut rows = merge_same_identity(rows, &candidates, &windows);
    rows.sort_by(|a, b| b.score.cmp(&a.score).then(a.name.cmp(&b.name)));

    // Adjacent-sentence windows intentionally overlap. Keep the richest window
    // for each chapter so one scene appears once, with all named partners that
    // its nearby context can recover.
    let mut group_by_chapter: HashMap<usize, (usize, RelationshipEvidence)> = HashMap::new();
    for (chapter, window) in &windows {
        if !protagonist_variants
            .iter()
            .any(|name| window.contains(name))
            || !has_any(window, GROUP_CUES)
        {
            continue;
        }
        let present: Vec<&str> = group_candidates
            .iter()
            .filter(|person| variants(person).iter().any(|name| window.contains(name)))
            .map(|person| canonical_group_name(person, &candidates))
            .collect();
        let unique: HashSet<&str> = present.iter().copied().collect();
        if unique.len() < 2 {
            continue;
        }
        let mut names: Vec<_> = unique.into_iter().collect();
        names.sort_unstable();
        let evidence = RelationshipEvidence {
            chapter: *chapter,
            person: names.join("、"),
            kind: "多段关系同时存在".into(),
            strength: 10,
            text: clip(window, 420),
        };
        let richness = present.len() * 1000 + window.chars().count();
        match group_by_chapter.get(chapter) {
            Some((old_richness, _)) if *old_richness >= richness => {}
            _ => {
                group_by_chapter.insert(*chapter, (richness, evidence));
            }
        }
    }
    let mut group_evidence: Vec<_> = group_by_chapter
        .into_values()
        .map(|(_, evidence)| evidence)
        .collect();
    group_evidence.sort_by_key(|evidence| evidence.chapter);
    group_evidence.truncate(5);

    let (label, reason, confidence) = classify(&rows, romance_focus, &group_evidence);
    rows.retain(|row| row.confirmed || row.sustained || row.possible);
    rows.truncate(12);
    RelationshipReport {
        label,
        reason,
        confidence,
        protagonist: protagonist.name.clone(),
        analyzed_chapters,
        candidate_count: candidates.len(),
        people: rows,
        group_evidence,
        version: RELATIONSHIP_VERSION,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn person(name: &str) -> Person {
        Person {
            name: name.into(),
            aliases: Vec::new(),
            mentions: 100,
            chapters: 10,
            first_chapter: 0,
            uncertain: false,
            evidence: Vec::new(),
        }
    }

    fn run(text: &str, names: &[&str], focus: &str) -> RelationshipReport {
        let people: Vec<Person> = names.iter().map(|name| person(name)).collect();
        analyze(&[(0, text)], &people, &[], 1, focus)
    }

    #[test]
    fn two_explicit_relations_are_harem() {
        let report = run(
            "顾昭迎娶沈青，大婚当夜结为夫妻。十年后顾昭与叶红结为道侣。",
            &["顾昭", "沈青", "叶红"],
            "中等",
        );
        assert_eq!(report.label, "后宫");
    }

    #[test]
    fn side_character_marriage_does_not_pollute_protagonist() {
        let report = run(
            "谢安和柳青参加赵山的婚礼，赵山迎娶钱月。谢安祝福新人。",
            &["谢安", "柳青", "赵山", "钱月"],
            "中等",
        );
        assert_eq!(report.label, "无法判断");
    }

    #[test]
    fn dream_and_fake_wife_do_not_confirm() {
        let report = run(
            "秦野梦见自己和方雪成亲，醒来才知是幻境。方雪假扮秦野的妻子。",
            &["秦野", "方雪"],
            "中等",
        );
        assert_eq!(report.label, "无法判断");
    }

    #[test]
    fn single_explicit_chain_is_single_heroine() {
        let report = run(
            "苏晚是林川的妻子，两人已经结婚多年。",
            &["林川", "苏晚"],
            "中等",
        );
        assert_eq!(report.label, "单女主");
    }

    #[test]
    fn low_focus_without_pair_evidence_is_reported_cautiously() {
        let report = run(
            "陆明每日练剑。周叔的妻子陈娘来送饭。",
            &["陆明", "周叔", "陈娘"],
            "较少",
        );
        assert_eq!(report.label, "未发现明确感情线");
    }

    #[test]
    fn direct_group_statement_is_harem() {
        let report = run(
            "在三人之间，渡边彻最喜欢九条美姬，但麻衣学姐也好，小泉老师也好，既然已经在一起，他会付出平等的爱。",
            &["渡边彻", "九条美姬", "麻衣学姐", "小泉老师"],
            "很多",
        );
        assert_eq!(report.label, "后宫");
        assert!(!report.group_evidence.is_empty());
    }

    #[test]
    fn repeated_emotional_closeness_can_recover_an_implicit_romance() {
        let people = vec![person("高阳"), person("青翎")];
        let report = analyze(
            &[
                (0, "高阳从身后抱住青翎纤细的腰肢，能闻到她头发的清香。"),
                (8, "青翎直扑过去抱住高阳，脸埋进他的胸膛哭泣。"),
            ],
            &people,
            &[],
            9,
            "中等",
        );
        assert_eq!(report.label, "单女主");
        assert_eq!(report.people[0].status, "持续暧昧关系");
    }

    #[test]
    fn one_embrace_or_a_fake_couple_scene_does_not_decide_the_book() {
        let people = vec![person("高阳"), person("青翎")];
        let report = analyze(
            &[
                (0, "青翎在害怕时抱住高阳，脸埋进他的胸膛哭泣。"),
                (1, "青翎抱住高阳的手臂，假装成正在早恋的学生。"),
            ],
            &people,
            &[],
            2,
            "中等",
        );
        assert_eq!(report.label, "无法判断");
    }

    #[test]
    fn directly_named_alternate_personality_is_one_relationship_object() {
        let people = vec![person("高阳"), person("青灵"), person("青翎")];
        let report = analyze(
            &[
                (0, "高阳反应过来，青翎是青灵的副人格。"),
                (1, "高阳抱住青灵，能闻到她的发香。"),
                (2, "青翎抱住高阳，脸埋进他的胸膛哭泣。"),
            ],
            &people,
            &[],
            3,
            "中等",
        );
        assert_eq!(report.people.len(), 1);
        assert_eq!(report.people[0].name, "青灵 / 青翎");
    }

    #[test]
    fn attributed_dialogue_pronouns_recover_an_existing_relationship() {
        let people = vec![person("封不觉"), person("若雨")];
        let report = analyze(
            &[
                (0, "若雨看向封不觉，问他是否早已知道。"),
                (
                    0,
                    "“你知道我没有爱上你、也不会爱上你，为什么还要跟我谈恋爱？”若雨张口就问。",
                ),
                (0, "“我喜欢上你的时候，并不知道这件事。”封不觉平静地回道。"),
            ],
            &people,
            &[],
            1,
            "较少",
        );
        assert_eq!(report.label, "单女主");
        assert_eq!(report.people[0].name, "若雨");
        assert!(report.people[0].confirmed);
        assert!(report.people[0]
            .evidence
            .iter()
            .any(|evidence| evidence.kind == "明确关系"));
    }

    #[test]
    fn dialogue_hypotheses_questions_and_negation_are_not_relationship_facts() {
        let people = vec![person("林川"), person("苏晚")];
        let report = analyze(
            &[
                (0, "林川看向苏晚，没有说话。"),
                (0, "“如果跟你谈恋爱，我会很累。”苏晚说道。"),
                (0, "“你愿意跟我谈恋爱吗？”苏晚问道。"),
                (0, "“我并不喜欢你。”苏晚说道。"),
                (0, "“你喜欢我？”苏晚问道。"),
                (0, "“我要让你爱上我。”苏晚说道。"),
            ],
            &people,
            &[],
            1,
            "中等",
        );
        assert_eq!(report.label, "无法判断");
        assert!(report.people.is_empty());
    }

    #[test]
    fn dialogue_reports_about_third_people_and_plural_objects_are_rejected() {
        let people = vec![person("林川"), person("苏晚")];
        let report = analyze(
            &[
                (0, "林川看向苏晚，等她解释。"),
                (0, "“我想她不是喜欢猫，是喜欢你。”苏晚认真地说道。"),
                (0, "“我也喜欢你们俩。”苏晚继续说道。"),
            ],
            &people,
            &[],
            1,
            "中等",
        );
        assert_eq!(report.label, "无法判断");
        assert!(report.people.is_empty());
    }

    #[test]
    fn nearby_side_character_dialogue_does_not_bind_the_protagonist() {
        let people = vec![
            person("林川"),
            person("苏晚"),
            person("赵山"),
            person("钱月"),
        ];
        let report = analyze(
            &[
                (0, "林川和苏晚坐在旁边。"),
                (0, "“我一直喜欢你。”赵山说道。"),
                (0, "“我也喜欢你。”钱月回答。"),
            ],
            &people,
            &[],
            1,
            "中等",
        );
        assert_eq!(report.label, "无法判断");
        assert!(report.people.is_empty());
    }
}
