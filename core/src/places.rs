//! Where a book happens — by counting, like [`crate::cast`], not by asking a
//! model to read it.
//!
//! A place name in a novel has a regular shape the way a speaker does: it
//! ends in a generic place word (城、宗、山、学院、客栈…) and it turns up after
//! the verbs that move people about (来到、前往、回到、离开…). Names are seeded
//! from there, then counted across the whole text.
//!
//! Places differ from people in how they relate. Two people share a sentence;
//! two places rarely do — the story is in one, then it goes to another. So
//! the links here are not co-occurrence but *succession*: each chapter is given
//! the place it is set in, and the graph is the trips between them. A second,
//! rarer link is *belonging*: 云岚宗后山, 加玛帝国的帝都 — a place named inside
//! another. And the book as a whole is cut into stages, the maps a web novel
//! changes as its hero moves up (镇 → 学院 → 城 → 域 → 大陆).

use crate::book::Chapter;
use std::collections::{HashMap, HashSet};

/// Generic place words a name ends in, with how big a place they make.
/// Rank only orders belonging (a 城 is inside a 国, not the other way).
const SUFFIX_LONG: &[(&str, u8)] = &[
    ("大陆", 6), ("世界", 6), ("天下", 6), ("星域", 6), ("海域", 5), ("星球", 6), ("帝国", 5),
    ("王朝", 5), ("王国", 5), ("山脉", 3), ("森林", 2), ("秘境", 2), ("遗迹", 2), ("学院", 2),
    ("大学", 2), ("中学", 2), ("小学", 2), ("高中", 2), ("书院", 2), ("学府", 2), ("宗门", 2),
    ("圣地", 2), ("禁地", 2), ("洞府", 1), ("山庄", 2), ("客栈", 1), ("酒楼", 1), ("酒店", 1),
    ("茶楼", 1), ("公司", 2), ("集团", 2), ("医院", 2), ("广场", 1), ("公园", 1), ("小区", 2),
    ("大厦", 1), ("车站", 1), ("机场", 1), ("监狱", 2), ("古城", 3), ("皇城", 3), ("皇宫", 1),
    ("王府", 1), ("山谷", 2), ("峡谷", 2), ("草原", 3), ("沙漠", 3), ("雪山", 2), ("平原", 3),
    ("古镇", 2), ("胡同", 1), ("大街", 1), ("码头", 1), ("渡口", 1), ("部落", 2), ("要塞", 2),
    ("基地", 2), ("研究所", 2), ("地区", 4),
];
const SUFFIX_ONE: &[(&str, u8)] = &[
    ("界", 6), ("洲", 6), ("域", 5), ("国", 5), ("州", 4), ("省", 4), ("郡", 4), ("城", 3),
    ("市", 3), ("县", 3), ("镇", 2), ("村", 2), ("宗", 2), ("派", 2), ("门", 2), ("宫", 1),
    ("殿", 1), ("阁", 1), ("寺", 1), ("观", 1), ("庙", 1), ("山", 2), ("岛", 2), ("谷", 2),
    ("关", 2), ("海", 3), ("湖", 2), ("江", 2), ("河", 2), ("林", 2), ("原", 3), ("漠", 3),
    ("峰", 1), ("崖", 1), ("洞", 1), ("塔", 1), ("楼", 1), ("院", 1), ("堂", 1), ("府", 1),
    ("庄", 2), ("寨", 2), ("坊", 1), ("街", 1), ("巷", 1), ("路", 1), ("区", 2), ("馆", 1),
    ("园", 1), ("坡", 1), ("岭", 1), ("岗", 1), ("湾", 1), ("滩", 1), ("泉", 1), ("潭", 1),
    ("渊", 1), ("台", 1),
];

/// What moves someone somewhere, or says where they are.
const CUES: &[&str] = &[
    "来到", "到了", "抵达", "到达", "前往", "赶往", "去往", "赶去", "返回", "回到", "回了", "离开",
    "进入", "进了", "走进", "踏入", "踏进", "飞往", "飞向", "奔赴", "驶向", "驶入", "出了", "住进",
    "搬到", "搬进", "赶到", "赶回", "逃到", "逃往", "逃离", "途经", "路过", "来自", "出身", "位于",
    "身在", "远赴", "去了", "到", "去", "往", "在", "于", "从",
];

/// Characters a place name never holds — they end the window read after a cue.
const STOP: &str = "我你他她它您咱谁的了着过吧吗呢啊呀哦嘛么和与或及被把将向对从却便就才刚这那哪每某各\
都也又还再很更最只太是有在来去到会能要让没别个时候什怎为因所虽当随说道看想";

/// A place word with one of these before it is a common noun (这座城, 一片林).
const DETERMINER: &str = "这那一座个间片条此该每各整某几处名位";

/// Ordinals and numbers make floors and rooms (二楼, 三号院), not places.
const NUMERAL: &str = "一二三四五六七八九十百千万两零〇0123456789";

/// Place words that every book has: 大门, 医院, 山洞, 世界. Measured as the
/// candidates found in five or more of 161 books, real geography taken out.
const GENERIC: &str = include_str!("places_generic.txt");
/// Real geography: countries, provinces, cities, rivers, the old 州 and states.
/// These are places wherever they appear, suffix or not.
const GEO: &str = include_str!("places_geo.txt");

/// What follows a person's name and never a place's.
const ACTS: &[&str] = &[
    "道", "说", "笑", "问", "叹", "喝", "点头", "摇头", "皱眉", "眉头", "脸色", "目光", "嘴角",
    "心中", "身体", "身形", "冷笑", "淡淡", "微微", "轻声", "沉声", "苦笑", "怒", "闻言", "一愣",
    "大人",
];
/// What follows a rank: 斗宗强者, 斗皇巅峰.
const RANK_TAILS: &[&str] = &[
    "强者", "巅峰", "初期", "中期", "后期", "级别", "级", "阶", "之境", "境界", "高手", "实力",
    "层次", "修为", "大圆满",
];
/// Two characters that are a move and a place word: 入宫, 出山, 回村, 本村.
const MOVE_HEAD: &str = "入出回进上下本此该全满离返登过归";
const ACTS_SHARE: f32 = 0.04;
/// What follows a place: 城里, 宗内, 学院附近.
const LOCATIVES: &[&str] = &[
    "里", "中", "内", "外", "上空", "附近", "一带", "方向", "门口", "深处", "之中", "之内", "境内",
    "城外", "周围", "四周", "所在", "那边", "这边",
];
/// Before a door: 打开, 推开, 关上, 敲.
const OPENS: &str = "开关推敲撞踹砸锁";
/// A degree word before it makes it an adjective: 一丝淡漠, 很端庄.
const DEGREE: &str = "很些丝分得更太极颇";
/// Verbs a seed can carry on its front: 回上海, 于中国, 离楚华大学.
const GLUE_HEADS: &[&str] = &[
    "打开", "推开", "突破", "前往", "回", "离", "于", "去", "到", "在", "进", "出", "入", "开", "上",
    "下", "过", "从", "往", "向", "返", "归", "奔", "赴", "至", "抵", "飞", "逃", "住", "搬",
];
/// Common words the corpus list missed.
const EXTRA_GENERIC: &[&str] = &[
    "城府", "端庄", "灭门", "辟谷", "右派", "修庙", "扫街", "辅导学院", "举国", "治国", "列国", "邦国",
    "知州", "知县", "知府", "反派", "渡河", "爬坡", "开山", "球台",
];
/// Place words that end in a common word when they follow one more
/// character: 思路, 宏观, 分区, 淡漠.
const SHORT_UNSAFE: &str = "路观区漠";
const GENERIC_TAILS: &[&str] = &[
    "领域", "疆域", "区域", "地域", "值观", "生观", "界观", "景观", "上市", "开门", "推门", "参观", "之路",
    "奇观", "江湖",
];
/// A name never starts with these: 自己公司, 整条商业街, 其原.
const NOT_A_HEAD: &[&str] = &["自己", "整条", "整座", "整个", "其"];
/// Single-character place words that also end given names: 谭青山, 韩重山,
/// 龙清泉. A surname-led name of this shape must be followed by a locative
/// now and then, or it is a person.
const NAME_TAILS: &str = "山峰林海泉堂江河国城崖湖岭石原观";
/// Surnames the cast list leaves out, seen leading such names.
const MORE_SURNAMES: &str = "瞿靳曲屈";
const LOCATED_SHARE: f32 = 0.08;
/// …unless it is gone to and stood in often enough: 夏海 is a city.
const SEEDED_SHARE: f32 = 0.15;
const RANK_SHARE: f32 = 0.15;

const MAX_LEN: usize = 8;
const MIN_MENTIONS: u32 = 8;
const MIN_CHAPTERS: u32 = 2;
const MIN_SEEDED: u32 = 2;
/// One character after the name taking this share of its mentions means the
/// name is the front of a longer word (魂殿殿|主, 胡大学|士, 斗宗|强者).
const WELDED_RIGHT: f32 = 0.5;
const MAX_DETERMINED: f32 = 0.15;
pub const MAX_PLACES: usize = 60;
/// Bumped whenever the rules change, so a cached atlas from older rules is
/// built again rather than served.
pub const PLACE_VERSION: u32 = 1;

fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c)
}

fn rank(s: &str, geo: &HashSet<&str>) -> Option<u8> {
    for (w, r) in SUFFIX_LONG {
        if s.ends_with(w) && s.len() > w.len() {
            return Some(*r);
        }
    }
    for (w, r) in SUFFIX_ONE {
        if s.ends_with(w) && s.len() > w.len() {
            return Some(*r);
        }
    }
    if geo.contains(s) {
        return Some(4);
    }
    None
}

#[derive(Default, Clone, Debug)]
pub struct Stat {
    pub seeded: u32,
    pub count: u32,
    pub chapters: u32,
    pub determined: u32,
    pub lefts: u32,
    pub right_top: u32,
    /// Followed by what a person does (道、笑、点头…): a name, not a place.
    pub acts: u32,
    /// Followed by what a rank takes (强者、巅峰、初期…): 斗宗 is reached, not visited.
    pub ranked: u32,
    /// Followed by a locative (里、中、附近…): what a place takes.
    pub located: u32,
    /// After 打开、推开、关上: a door, not a sect.
    pub opened: u32,
    pub first_chapter: usize,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Place {
    pub name: String,
    pub mentions: u32,
    pub chapters: u32,
    pub first_chapter: usize,
    pub rank: u8,
    /// Index into [`Atlas::places`] of the place this one is named inside.
    pub parent: Option<usize>,
    /// Chapters this place is where the story is.
    pub settings: u32,
    /// Cast members seen most in the chapters set here.
    pub people: Vec<(String, u32)>,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Trip {
    pub from: usize,
    pub to: usize,
    pub count: u32,
    /// First chapter the trip is made in.
    pub first: usize,
}

/// A run of chapters spent in one area — one "map" of the book.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Stage {
    pub from: usize,
    pub to: usize,
    pub area: usize,
    /// Places the story stood in during this stage, by chapters.
    pub spots: Vec<(usize, u32)>,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, Default)]
pub struct Atlas {
    pub places: Vec<Place>,
    pub trips: Vec<Trip>,
    pub stages: Vec<Stage>,
    /// Per chapter: where it is set, if anywhere could be told.
    pub setting: Vec<Option<usize>>,
}

fn paragraphs<'a>(text: &'a str, chapters: &[Chapter], n: usize) -> Vec<(usize, &'a str)> {
    let mut paras = Vec::new();
    for ch in chapters.iter().take(n) {
        for line in text[ch.body_start..ch.span.end].split('\n') {
            let line = line.trim();
            if !line.is_empty() {
                paras.push((ch.index, line));
            }
        }
    }
    paras
}

/// Every suffix-ending run read after a cue, with how often it was read so,
/// per chapter.
fn seeds(paras: &[(usize, &str)], geo: &HashSet<&str>) -> HashMap<String, HashMap<usize, u32>> {
    let cues: Vec<Vec<char>> = CUES.iter().map(|c| c.chars().collect()).collect();
    let heads: HashSet<char> = cues.iter().map(|c| c[0]).collect();
    let mut out: HashMap<String, HashMap<usize, u32>> = HashMap::new();
    for (ch, p) in paras {
        let chars: Vec<char> = p.chars().collect();
        for i in 0..chars.len() {
            if !heads.contains(&chars[i]) {
                continue;
            }
            let Some(cue) = cues.iter().find(|c| chars[i..].starts_with(c)) else {
                continue;
            };
            let mut j = i + cue.len();
            if j < chars.len() && "了过".contains(chars[j]) {
                j += 1;
            }
            let mut s = String::new();
            let mut k = j;
            while k < chars.len() && k - j < MAX_LEN {
                let c = chars[k];
                if !is_cjk(c) || STOP.contains(c) {
                    break;
                }
                s.push(c);
                k += 1;
                if k - j >= 2 && rank(&s, geo).is_some() {
                    *out.entry(s.clone()).or_default().entry(*ch).or_default() += 1;
                }
            }
        }
    }
    out
}

fn raw_stats(
    paras: &[(usize, &str)],
    names: &HashSet<String>,
) -> HashMap<String, Stat> {
    let mut stats: HashMap<String, Stat> = names
        .iter()
        .map(|n| (n.clone(), Stat { first_chapter: usize::MAX, ..Default::default() }))
        .collect();
    let mut last_ch: HashMap<&str, usize> = HashMap::new();
    let mut lefts: HashMap<&str, HashSet<char>> = HashMap::new();
    let mut rights: HashMap<&str, HashMap<char, u32>> = HashMap::new();
    let heads: HashSet<char> = names.iter().filter_map(|n| n.chars().next()).collect();
    for (ch, p) in paras {
        let idx: Vec<(usize, char)> = p.char_indices().collect();
        for a in 0..idx.len() {
            if !heads.contains(&idx[a].1) {
                continue;
            }
            for len in 2..=MAX_LEN {
                if a + len > idx.len() {
                    break;
                }
                let end = if a + len == idx.len() { p.len() } else { idx[a + len].0 };
                let w = &p[idx[a].0..end];
                let Some((key, _)) = names.get(w).map(|k| (k.as_str(), ())) else {
                    continue;
                };
                let e = stats.get_mut(key).unwrap();
                e.count += 1;
                let left = if a > 0 { idx[a - 1].1 } else { '^' };
                if DETERMINER.contains(left) {
                    e.determined += 1;
                }
                if last_ch.get(key) != Some(ch) {
                    last_ch.insert(key, *ch);
                    e.chapters += 1;
                    e.first_chapter = e.first_chapter.min(*ch);
                }
                lefts.entry(key).or_default().insert(left);
                let rest = &p[end..];
                if ACTS.iter().any(|w| rest.starts_with(w)) {
                    e.acts += 1;
                }
                if RANK_TAILS.iter().any(|w| rest.starts_with(w)) {
                    e.ranked += 1;
                }
                if LOCATIVES.iter().any(|w| rest.starts_with(w)) {
                    e.located += 1;
                }
                if OPENS.contains(left) {
                    e.opened += 1;
                }
                if DEGREE.contains(left) {
                    e.determined += 1;
                }
                if a + len < idx.len() {
                    *rights.entry(key).or_default().entry(idx[a + len].1).or_default() += 1;
                }
            }
        }
    }
    for (k, v) in stats.iter_mut() {
        v.lefts = lefts.get(k.as_str()).map_or(0, |s| s.len() as u32);
        v.right_top = rights.get(k.as_str()).and_then(|r| r.values().max().copied()).unwrap_or(0);
    }
    stats
}

/// Diagnostic: every seeded candidate with its raw counts.
pub fn candidate_stats(text: &str, chapters: &[Chapter], upto: usize) -> Vec<(String, Stat)> {
    let geo: HashSet<&str> = GEO.split_whitespace().collect();
    let paras = paragraphs(text, chapters, upto.min(chapters.len()));
    let seeded = seeds(&paras, &geo);
    let names: HashSet<String> = seeded.keys().cloned().collect();
    let mut stats = raw_stats(&paras, &names);
    for (k, v) in &seeded {
        stats.get_mut(k).unwrap().seeded = v.values().sum();
    }
    let mut out: Vec<(String, Stat)> = stats.into_iter().collect();
    out.sort_by(|a, b| b.1.count.cmp(&a.1.count));
    out
}

/// Why a candidate was turned away, or None when it is a place.
pub fn reject(name: &str, st: &Stat, people: &[String], generic: &HashSet<&str>, geo: &HashSet<&str>) -> Option<&'static str> {
    let is_geo = geo.contains(name);
    let len = name.chars().count();
    let head = name.chars().next().unwrap_or(' ');
    let tail = &name[head.len_utf8()..];
    if !is_geo {
        if generic.contains(name) || EXTRA_GENERIC.contains(&name) || GENERIC_TAILS.iter().any(|t| name.ends_with(t)) {
            return Some("常见词");
        }
        if len == 2 && SHORT_UNSAFE.contains(tail) && !"东西南北".contains(head) {
            return Some("常见词");
        }
        if name.chars().any(|c| NUMERAL.contains(c)) {
            return Some("数字");
        }
        if NOT_A_HEAD.iter().any(|h| name.starts_with(h)) {
            return Some("常见词");
        }
        if len == 2 && name.chars().all(|c| SUFFIX_ONE.iter().any(|(w, _)| w.starts_with(c))) {
            return Some("常见词");
        }
        if let Some((_, rest)) = name.split_once('开') {
            if SUFFIX_LONG.iter().any(|(w, _)| *w == rest) || generic.contains(rest) {
                return Some("动词");
            }
        }
        if CUES.iter().any(|c| c.chars().count() >= 2 && name.starts_with(c))
            || (MOVE_HEAD.contains(head)
                && (tail.chars().count() == 1
                    || generic.contains(tail)
                    || SUFFIX_LONG.iter().any(|(w, _)| *w == tail)))
        {
            return Some("动词");
        }
        if RANK_TAILS.iter().any(|w| name.ends_with(w)) {
            return Some("境界");
        }
    }
    if people.iter().any(|p| p == name || p.contains(name) || name.contains(p.as_str())) {
        return Some("人名");
    }
    if is_geo {
        return None;
    }
    if st.count < MIN_MENTIONS || st.chapters < MIN_CHAPTERS || st.seeded < MIN_SEEDED {
        return Some("太少");
    }
    if st.right_top as f32 > st.count as f32 * WELDED_RIGHT {
        return Some("粘右");
    }
    if st.determined as f32 > st.count as f32 * MAX_DETERMINED {
        return Some("泛指");
    }
    if st.acts as f32 > st.count as f32 * ACTS_SHARE {
        return Some("像人");
    }
    let compound = crate::cast::COMPOUND_SURNAMES.iter().any(|c| name.starts_with(c));
    if ((len == 2 || len == 3) && (crate::cast::SURNAMES.contains(head) || MORE_SURNAMES.contains(head))
        || len == 4 && compound)
        && name.chars().last().is_some_and(|c| NAME_TAILS.contains(c))
        && (st.located as f32) < st.count as f32 * LOCATED_SHARE
        && (st.seeded as f32) < st.count as f32 * SEEDED_SHARE
    {
        return Some("像人");
    }
    if st.ranked as f32 > st.count as f32 * RANK_SHARE {
        return Some("境界");
    }
    if name.ends_with('门') && st.opened as f32 > st.count as f32 * 0.1 {
        return Some("门");
    }
    None
}

/// A seed with a verb still on its front (回上海) when the rest is a seed of
/// its own said at least twice as often.
fn glued(name: &str, stats: &HashMap<String, Stat>) -> bool {
    let me = stats.get(name).map_or(0, |s| s.count);
    GLUE_HEADS.iter().any(|h| {
        name.strip_prefix(h)
            .filter(|rest| rest.chars().count() >= 2)
            .and_then(|rest| stats.get(rest))
            .is_some_and(|s| s.count >= 2 * me)
    })
}

pub fn scan(text: &str, chapters: &[Chapter], upto: usize) -> Atlas {
    let n = upto.min(chapters.len());
    let ranked: Vec<(String, Vec<String>)> = crate::cast::scan_ranked(text, chapters, n)
        .into_iter()
        .map(|p| (p.name, p.aliases))
        .collect();
    scan_ranked(text, chapters, n, &ranked)
}

/// How many of the cast are looked for in the chapters set at each place.
const LEADS: usize = 20;

/// [`scan`], given the cast's ranked people (name and aliases, most mentioned
/// first) — as a cached [`crate::cast::Cast`] keeps them — so the cast is not
/// scanned a second time.
pub fn scan_ranked(text: &str, chapters: &[Chapter], upto: usize, ranked: &[(String, Vec<String>)]) -> Atlas {
    let n = upto.min(chapters.len());
    let people: Vec<String> = ranked
        .iter()
        .flat_map(|(name, aliases)| std::iter::once(name.clone()).chain(aliases.iter().cloned()))
        .filter(|s| s.chars().count() >= 2)
        .collect();
    let leads: Vec<String> = ranked.iter().take(LEADS).map(|(name, _)| name.clone()).collect();
    scan_with(text, chapters, n, &people, &leads)
}

pub fn scan_with(text: &str, chapters: &[Chapter], n: usize, people: &[String], leads: &[String]) -> Atlas {
    let geo: HashSet<&str> = GEO.split_whitespace().collect();
    let generic: HashSet<&str> = GENERIC.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let paras = paragraphs(text, chapters, n);
    let seeded = seeds(&paras, &geo);
    let names: HashSet<String> = seeded.keys().cloned().collect();
    let mut stats = raw_stats(&paras, &names);
    for (k, v) in &seeded {
        stats.get_mut(k).unwrap().seeded = v.values().sum();
    }
    if std::env::var("PLACE_RAW").is_ok() {
        let mut all: Vec<(&String, &Stat)> = stats.iter().filter(|(_, v)| v.seeded >= 2 && v.count >= 8).collect();
        all.sort_by(|a, b| b.1.count.cmp(&a.1.count));
        for (k, v) in all.iter().take(150) {
            let why = if glued(k, &stats) { Some("粘动词") } else { reject(k, v, people, &generic, &geo) };
            eprintln!(
                "{:<8} {:>5} 引{:>4} 限{:>3} 人{:>3} 位{:>3} 开{:>3} {}",
                k, v.count, v.seeded, v.determined, v.acts, v.located, v.opened, why.unwrap_or("✓")
            );
        }
    }
    let glue: HashSet<String> = stats.keys().filter(|k| glued(k, &stats)).cloned().collect();
    let mut kept: Vec<(String, Stat)> = stats
        .into_iter()
        .filter(|(k, v)| !glue.contains(k) && reject(k, v, people, &generic, &geo).is_none())
        .collect();
    kept.sort_by(|a, b| b.1.count.cmp(&a.1.count).then(a.0.cmp(&b.0)));

    // Own mentions: a mention inside a longer kept name is that name's
    // (黄原 inside 黄原城), read greedily left to right.
    let kept_names: HashMap<&str, usize> = kept.iter().enumerate().map(|(i, (k, _))| (k.as_str(), i)).collect();
    let mut own = vec![0u32; kept.len()];
    let mut per_ch: Vec<HashMap<usize, u32>> = vec![HashMap::new(); kept.len()];
    let mut chs: Vec<HashSet<usize>> = vec![HashSet::new(); kept.len()];
    // (outer, inner) adjacent pairs: 云岚宗后山, 加玛帝国的帝都.
    let mut pairs: HashMap<(usize, usize), u32> = HashMap::new();
    let mut ch_people: Vec<HashMap<usize, u32>> = vec![HashMap::new(); n.max(1)];
    let heads: HashSet<char> = kept.iter().filter_map(|(k, _)| k.chars().next()).collect();
    for (ch, p) in &paras {
        let idx: Vec<(usize, char)> = p.char_indices().collect();
        let mut a = 0;
        let mut prev: Option<(usize, usize)> = None; // (place, end char index)
        while a < idx.len() {
            let mut hit = None;
            for len in (2..=MAX_LEN).rev() {
                if !heads.contains(&idx[a].1) {
                    break;
                }
                if a + len > idx.len() {
                    continue;
                }
                let end = if a + len == idx.len() { p.len() } else { idx[a + len].0 };
                if let Some(&i) = kept_names.get(&p[idx[a].0..end]) {
                    hit = Some((i, len));
                    break;
                }
            }
            if let Some((i, len)) = hit {
                own[i] += 1;
                *per_ch[i].entry(*ch).or_default() += 1;
                chs[i].insert(*ch);
                if let Some((pi, pend)) = prev {
                    let gap: String = idx[pend..a].iter().map(|x| x.1).collect();
                    if pi != i && matches!(gap.as_str(), "" | "的" | "之" | "中的" | "内的" | "里的" | "之中的") {
                        *pairs.entry((pi, i)).or_default() += 1;
                    }
                }
                prev = Some((i, a + len));
                a += len;
            } else {
                a += 1;
            }
        }
        for (pi, lead) in leads.iter().enumerate() {
            if p.contains(lead.as_str()) {
                *ch_people[*ch].entry(pi).or_default() += 1;
            }
        }
    }
    let geo_rank = |s: &str| rank(s, &geo).unwrap_or(1);
    let mut order: Vec<usize> = (0..kept.len())
        .filter(|&i| own[i] >= MIN_MENTIONS && chs[i].len() as u32 >= MIN_CHAPTERS)
        .collect();
    order.sort_by(|&a, &b| own[b].cmp(&own[a]));
    order.truncate(MAX_PLACES);
    let mut places: Vec<Place> = order
        .iter()
        .map(|&i| Place {
            name: kept[i].0.clone(),
            mentions: own[i],
            chapters: chs[i].len() as u32,
            first_chapter: chs[i].iter().min().copied().unwrap_or(0),
            rank: geo_rank(&kept[i].0),
            parent: None,
            settings: 0,
            people: Vec::new(),
        })
        .collect();

    // Belonging: named inside another at least twice, and the outer one is
    // the bigger kind of place, or the inner name starts with the outer one.
    for (j, pl) in places.clone().iter().enumerate() {
        let mut best: Option<(usize, u32)> = None;
        for (k, outer) in places.iter().enumerate() {
            if k == j {
                continue;
            }
            let named_in = pl.name.starts_with(outer.name.as_str()) && pl.name.len() > outer.name.len();
            let c = pairs.get(&(order[k], order[j])).copied().unwrap_or(0);
            let ok = named_in || (c >= 2 && outer.rank > pl.rank);
            let score = if named_in { c + 1000 } else { c };
            if ok && best.is_none_or(|(_, s)| score > s) {
                best = Some((k, score));
            }
        }
        places[j].parent = best.map(|b| b.0);
    }
    // No cycles: a parent chain that comes back drops its last link.
    for j in 0..places.len() {
        let mut seen = HashSet::new();
        let mut at = j;
        while let Some(p) = places[at].parent {
            if !seen.insert(at) {
                places[at].parent = None;
                break;
            }
            at = p;
        }
    }

    // Setting per chapter: the place mentioned most, a cue mention counting
    // three; under three points the story stays where it was.
    let mut setting: Vec<Option<usize>> = vec![None; n];
    let mut current = None;
    for c in 0..n {
        let mut best: Option<(usize, u32)> = None;
        for (new, &old) in order.iter().enumerate() {
            if places[new].rank >= 5 {
                continue;
            }
            let m = per_ch[old].get(&c).copied().unwrap_or(0);
            if m == 0 {
                continue;
            }
            let cue = seeded.get(&kept[old].0).and_then(|s| s.get(&c)).copied().unwrap_or(0);
            let score = m + 2 * cue;
            if best.is_none_or(|(_, s)| score > s) {
                best = Some((new, score));
            }
        }
        if let Some((p, s)) = best {
            if s >= 3 {
                current = Some(p);
            }
        }
        setting[c] = current;
    }
    for c in 0..n {
        if let Some(p) = setting[c] {
            places[p].settings += 1;
        }
    }

    // Trips: the setting changing from one place to another.
    let mut trips: HashMap<(usize, usize), (u32, usize)> = HashMap::new();
    let mut last = None;
    for (c, s) in setting.iter().enumerate() {
        if let Some(p) = *s {
            if let Some(q) = last {
                if q != p {
                    let e = trips.entry((q, p)).or_insert((0, c));
                    e.0 += 1;
                }
            }
            last = Some(p);
        }
    }
    let mut trips: Vec<Trip> = trips
        .into_iter()
        .map(|((from, to), (count, first))| Trip { from, to, count, first })
        .collect();
    trips.sort_by(|a, b| a.first.cmp(&b.first));

    // People: who is around in the chapters set in each place.
    for (p, pl) in places.iter_mut().enumerate() {
        let mut tally: HashMap<usize, u32> = HashMap::new();
        for c in 0..n {
            if setting[c] == Some(p) {
                for (who, k) in &ch_people[c] {
                    *tally.entry(*who).or_default() += k;
                }
            }
        }
        // Ties go to the higher-ranked lead, so a rescan says the same.
        let mut v: Vec<(usize, u32)> = tally.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v.truncate(5);
        pl.people = v.into_iter().map(|(w, k)| (leads[w].clone(), k)).collect();
    }

    let counts: Vec<Vec<u32>> = order
        .iter()
        .map(|&old| (0..n).map(|c| per_ch[old].get(&c).copied().unwrap_or(0)).collect())
        .collect();
    let stages = stages(&counts, &setting, n);
    Atlas { places, trips, stages, setting }
}

/// Stages: where the book changes maps. Places do not share sentences the way
/// people do; what a map change looks like instead is the whole mix of place
/// names turning over — the old ones stop being said and new ones take over.
/// So a cut is put where the mentions in the chapters before a point look
/// least like those after it (TextTiling, run on place names): the window is
/// a fraction of the book, and cuts are kept a window apart.
const STAGE_WINDOWS: usize = 25;
const MIN_WINDOW: usize = 4;
const MAX_WINDOW: usize = 40;
/// Below this cosine between the two sides, the map has changed.
const CUT_SIMILARITY: f32 = 0.35;

fn stages(counts: &[Vec<u32>], setting: &[Option<usize>], n: usize) -> Vec<Stage> {
    let w = (n / STAGE_WINDOWS).clamp(MIN_WINDOW, MAX_WINDOW);
    let k = counts.len();
    if k == 0 || n == 0 {
        return Vec::new();
    }
    // Damped so one place said fifty times in a chapter does not drown the
    // rest, and weighted by how few chapters say it at all: the place a book
    // never leaves (庆国, 监察院) says nothing about where a map ends.
    let idf: Vec<f32> = counts
        .iter()
        .map(|row| {
            let present = row.iter().filter(|&&m| m > 0).count().max(1);
            (n as f32 / present as f32).ln()
        })
        .collect();
    let v = |c: usize, p: usize| (counts[p][c] as f32).sqrt() * idf[p];
    let mut prefix = vec![vec![0f32; k]; n + 1];
    for c in 0..n {
        for p in 0..k {
            prefix[c + 1][p] = prefix[c][p] + v(c, p);
        }
    }
    let side = |a: usize, b: usize| -> Vec<f32> { (0..k).map(|p| prefix[b][p] - prefix[a][p]).collect() };
    let cos = |x: &[f32], y: &[f32]| {
        let d: f32 = x.iter().zip(y).map(|(a, b)| a * b).sum();
        let nx: f32 = x.iter().map(|a| a * a).sum::<f32>().sqrt();
        let ny: f32 = y.iter().map(|a| a * a).sum::<f32>().sqrt();
        if nx == 0.0 || ny == 0.0 { 1.0 } else { d / (nx * ny) }
    };
    let mut gaps: Vec<(usize, f32)> = Vec::new();
    if n >= 2 * w {
        for b in w..=n - w {
            gaps.push((b, cos(&side(b - w, b), &side(b, b + w))));
        }
    }
    gaps.sort_by(|a, b| a.1.total_cmp(&b.1));
    let mut cuts: Vec<usize> = Vec::new();
    for (b, sim) in gaps {
        if sim >= CUT_SIMILARITY {
            break;
        }
        if cuts.iter().all(|&c| c.abs_diff(b) >= w) {
            cuts.push(b);
        }
    }
    cuts.sort();
    let mut bounds = vec![0];
    bounds.extend(cuts);
    bounds.push(n);
    bounds
        .windows(2)
        .map(|r| {
            let (from, to) = (r[0], r[1]);
            // Named by what is said most here and least elsewhere.
            let mut score: Vec<(usize, f32, u32)> = (0..k)
                .map(|p| {
                    let here: u32 = counts[p][from..to].iter().sum();
                    let all: u32 = counts[p].iter().sum();
                    (p, here as f32 * here as f32 / all.max(1) as f32, here)
                })
                .filter(|x| x.2 > 0)
                .collect();
            score.sort_by(|a, b| b.1.total_cmp(&a.1));
            let spots: Vec<(usize, u32)> = score.iter().take(6).map(|x| (x.0, x.2)).collect();
            let mut tally: HashMap<usize, u32> = HashMap::new();
            for s in setting[from..to].iter().flatten() {
                *tally.entry(*s).or_default() += 1;
            }
            let area = spots.first().map(|x| x.0).unwrap_or(0);
            Stage { from, to: to - 1, area, spots }
        })
        .collect()
}
