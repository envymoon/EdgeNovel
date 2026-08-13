//! Who is in this book, and who stands with whom — by counting, not by asking
//! a model to read it.
//!
//! The one truly regular structure in a web novel is dialogue attribution:
//! 「……」吕树说道。 Names are seeded from whatever stands before a speech
//! verb, then validated against the whole text by statistics — a real name
//! recurs, and it recurs in varied company, while a fragment like 树笑 cut out
//! of 吕树笑道 has 吕 welded to its left forever. Relationships are sentence
//! co-occurrence counts, with appellation words (师父、夫人、哥哥) collected as
//! typed hints, and every edge keeps its evidence sentences verbatim. A model
//! may later turn one edge's evidence into a label picked from a closed set;
//! nothing in this module asks a model anything.

use crate::book::Chapter;
use std::collections::{HashMap, HashSet};

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Person {
    pub name: String,
    /// Shorter forms folded into this person (吕小鱼 ← 小鱼). Conservative:
    /// only the bare given name, and only when exactly one full name claims it.
    pub aliases: Vec<String>,
    pub mentions: u32,
    /// Distinct chapters the person appears in — spread is what separates a
    /// lead from a one-arc walk-on with the same total count.
    pub chapters: u32,
    pub first_chapter: usize,
    /// Statistics put this one in the band where they stop discriminating, and
    /// a model should be asked whether it is a person at all. See [`DENSITY_SURE`].
    pub uncertain: bool,
    /// (chapter, sentence) — a sample of this person's own sentences, spread
    /// across the scanned range and ranked toward the ones that say who they
    /// are. The raw material 人物背景 is written from, and shown to the reader
    /// beside it. See [`BACKGROUND_CUES`].
    #[serde(default)]
    pub evidence: Vec<(usize, String)>,
}

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Edge {
    /// Indices into [`Cast::people`].
    pub a: usize,
    pub b: usize,
    /// Sharing a sentence counts double sharing a paragraph.
    pub weight: u32,
    /// Appellation words seen in the pair's shared sentences, with counts.
    pub hints: Vec<(String, u32)>,
    /// The relationship label the hints settle on their own (师徒, 夫妻恋人…),
    /// or None when the hints are absent, ambiguous, or split — those are the
    /// edges the model earns its keep on. See [`crate::relation`].
    pub label: Option<String>,
    /// (chapter, sentence) — the raw material any claim about this pair rests
    /// on. Shown to the reader, and later handed to the labelling model.
    pub evidence: Vec<(usize, String)>,
}

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Cast {
    pub people: Vec<Person>,
    pub edges: Vec<Edge>,
    /// Whole-book relationship structure computed from the larger internal
    /// roster before the graph UI trims it to ten people.
    #[serde(default)]
    pub relationship: Option<crate::romance::RelationshipReport>,
    /// The [`SCAN_VERSION`] that produced this. A cache reader compares it and
    /// rebuilds on mismatch. `#[serde(default)]` reads pre-versioning rows as 0.
    #[serde(default)]
    pub version: u32,
}

/// Mentions per chapter-appeared-in. A character is met repeatedly inside the
/// chapters they are in; a stray common word is sprinkled thinly across the
/// whole book. Measured over 剑来 and 元尊:
///
/// | 伸手 2.05 | 比如 1.72 | 后者 1.56 | 回头 1.39 | 先前 2.17 | 自言自语 1.00 |
/// | 稚圭 3.66 | 杨老头 4.53 | 吕松长老 2.50 | 苏婉 3.25 | 陈平安 39.8 |
///
/// The worst impostor (先前, 2.17) and the thinnest real character (吕松长老,
/// 2.50) are 0.33 apart, which is far too narrow to put a verdict on. So the
/// numbers only decide the easy ends: below [`DENSITY_FLOOR`] nothing real has
/// ever landed, above [`DENSITY_SURE`] no impostor has. The band between them is
/// handed to the model, one closed yes/no per candidate.
const DENSITY_FLOOR: f32 = 1.2;
const DENSITY_SURE: f32 = 4.0;

const MIN_MENTIONS: u32 = 6;
const MAX_CAST: usize = 40;
const MIN_EDGE: u32 = 3;
const MAX_EDGES: usize = 80;
/// A single edge keeps up to this many co-occurrence sentences. The rules only
/// ever read the first few, but the labelling model is handed the whole set and
/// judges them together in one pass — thin context was what left half the graph
/// 不明, and reading them a batch at a time made it misread evolving bonds.
///
/// Sized against the engine's window rather than guessed. Measured on the real
/// engine (Qwen3-0.6B-Q8_0, `-c 8192`): Chinese runs 1.32 chars per token, and
/// forty sampled sentences made a 2221-token prompt — 44% of the window, with
/// 1400 reserved for the answer. The budget for evidence is therefore about
/// 6200 tokens; at the worst case every sentence hits the 110-char clip and
/// costs ~87, so seventy of them still fit with room to spare. Feeding more is
/// nearly free besides: the engine reads a prompt at ~10k tokens/s and writes at
/// ~150, so tripling the evidence cost about a second per summary. Forty was
/// leaving the window three-fifths empty, and a sample that thin is why a
/// character read as "局部片段".
const MAX_EVIDENCE: usize = 70;

/// The graph a reader sees: the few leads whose relationships are worth building
/// well, not everyone the scan can name. Kept small on purpose — with a handful
/// of pairs the model can afford to read dozens of scenes per pair.
pub const TOP_CAST: usize = 10;

/// Of the [`TOP_CAST`] slots, this many go to the highest whole-book mention
/// counts — the perennial leads. The rest are reserved for the opening cast (see
/// [`prune`]): the most-mentioned characters who *debut early*. The reserve was
/// four, from a time when the extraction missed 齐静春 entirely and only his
/// 首现第12章 could rescue him; once the cast is extracted properly he is 6th by
/// count on his own, and four reserved slots stop being a rescue and start being
/// a tax — on 剑来 they seated 白衣 (357) over 李宝瓶 (691), and on 元尊 they
/// seated 柳溪 (129) over 顾红衣 (374). Two still covers the martyr-mentor case
/// and costs no lead: measured across `bad/`, going 6→8 only ever traded a minor
/// early character for a more-mentioned one.
const PRIMARY_BY_COUNT: usize = 8;

/// A character debuts "in the opening" if their first chapter is within this
/// fraction of the book (1/20 = the first 5%), floored so short books still get a
/// usable window. The opening arc is where a story installs the cast a reader
/// bonds with; a martyr-mentor like 齐静春 lives entirely there.
const EARLY_FRACTION: usize = 20;
const EARLY_FLOOR: usize = 40;

/// Bumped whenever a scan-shape change (cast size, evidence depth, fields) makes
/// an older cached `Cast` wrong to reuse. `scan_cached` treats a mismatch as a
/// miss and rebuilds, so a new binary never serves a graph built by the old one.
pub const SCAN_VERSION: u32 = 10;

/// Verbs that attribute speech. The name stands directly before the verb
/// cluster; manner characters that slip into the run (吕树笑道) are cleaned up
/// by the statistics, not by enumerating adverbs.
const SPEECH: &[char] = &[
    '说', '道', '问', '喊', '叫', '骂', '答', '叹', '喝', '吼', '嚷',
];

/// Words whose object is a person: 和X、对X、找X、陪X. A person is something
/// other people act upon; a gesture or manner word (抬手, 偏头, 含笑) never is.
/// This is the one feature measured to separate them cleanly — see
/// [`OBJECT_FLOOR`].
const OBJECT_CUE: &[char] = &[
    '和', '与', '跟', '对', '给', '被', '让', '向', '替', '找', '问', '同', '陪',
];

/// Mentions a candidate needs before the person test in [`select`] is allowed to
/// judge it. The test is a *rate*, and a rate needs a sample: at 3% a genuine
/// minor character can easily miss twenty tosses in a row. Set where the words
/// that actually damage a graph live — the ones frequent enough to take a top
/// slot (抬手 567, 不知 363, 神色 296, 不必 186, 偏头 169) — and below it the
/// island and variety filters decide alone, as they did before.
const OBJECT_FLOOR: u32 = 120;

/// 知道、听说、请问、天道… — compounds where the verb char is not speech.
fn false_friend(pre: char, verb: char) -> bool {
    match verb {
        '道' => "知难街味力报频赛轨管大天正邪古王霸".contains(pre),
        '说' => "听据传小述诉胡瞎乱虽".contains(pre),
        '问' => "请询疑学访慰顾".contains(pre),
        '叫' => "惨尖嚎".contains(pre),
        _ => false,
    }
}

/// What may follow the verb for it to read as attribution. 吕树道： yes,
/// 吕树道破 no.
fn after_ok(c: Option<char>) -> bool {
    match c {
        None => true,
        Some(c) => "：:，。！？；…、\"“”「」『』‘’'—\n）)".contains(c),
    }
}

fn is_cjk(c: char) -> bool {
    matches!(c, '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}')
}

/// Common surnames — used only to decide whether a longer candidate is shaped
/// like a full name (for alias folding), never to find names: plenty of real
/// characters (白兔, 罐头, 大王) carry no surname at all.
const SURNAMES: &str = "李王张刘陈杨赵黄周吴徐孙胡朱高林何郭马罗梁宋郑谢韩唐冯于董萧程曹袁邓许\
傅沈曾彭吕苏卢蒋蔡贾丁魏薛叶阎余潘杜戴夏钟汪田任姜范方石姚谭廖邹熊金陆郝孔白崔康毛邱秦江史顾\
侯邵孟龙万段雷钱汤尹黎易常武乔贺赖龚文洪庄严牛温季莫翟安路姬秋楚燕冷宁凌霍虞柳祁纪管卫花柯房\
夜风云顾墨聂沐齐";

const COMPOUND_SURNAMES: &[&str] = &[
    "慕容", "欧阳", "上官", "司马", "诸葛", "东方", "西门", "独孤", "南宫", "夏侯", "皇甫", "尉迟",
    "令狐", "长孙", "宇文", "轩辕", "百里", "呼延", "端木", "司徒", "司空", "公孙", "北堂", "东郭",
    "申屠",
];

/// Honorifics that attach to a surname to name a person indirectly (齐先生,
/// 苏姑娘). A candidate ending in one of these, whose surname matches exactly one
/// full name, is that person under a courtesy title — not a separate character.
const TITLES: &[&str] = &[
    "先生", "公子", "姑娘", "老爷", "少爷", "大人", "前辈", "夫人", "娘子", "道长", "真人", "大师",
    "掌柜", "师傅", "老板", "老祖", "宗主", "掌门",
];

/// 苏如雪 is shaped like a full name; 请继续 is not — and only something
/// shaped like a full name may claim a shorter candidate's occurrences.
fn full_name_shaped(name: &str) -> bool {
    match name.chars().count() {
        3 => name.chars().next().is_some_and(|c| SURNAMES.contains(c)),
        4 => COMPOUND_SURNAMES.iter().any(|s| name.starts_with(s)),
        _ => false,
    }
}

/// Two-character Chinese names are too common a shape to accept on spelling
/// alone, but a very frequent candidate that repeatedly stands by itself, is
/// acted upon, and ends cleanly is still a person. This recovers names such as
/// 张雅 without admitting prose fragments such as 张开.
fn strong_two_char_name(name: &str, st: &Stat, standalone: u32) -> bool {
    let mut chars = name.chars();
    let Some(surname) = chars.next() else {
        return false;
    };
    chars.next().is_some()
        && chars.next().is_none()
        && SURNAMES.contains(surname)
        && standalone >= OBJECT_FLOOR
        && st.boundary * 3 >= standalone
        && st.boundary_r * 10 >= standalone
        && st.object * 20 >= standalone
}

/// Characters that occur inside running prose constantly and inside names
/// essentially never. Precision-first: a char earns its place here only if the
/// flood of fragments it would admit costs more than the rare name it costs us
/// (so 然 and 如 are absent — 安然 and 如雪 are real names).
///
/// 不 was here and cost us a whole book: 世子很凶's lead 许不令 (18085 mentions)
/// never became a candidate, so the graph was built out of gesture words. Names
/// carrying 不 are a common 网文 shape (许不令, 楚不凡, 令狐不败) and the fragments
/// 不 admits are caught downstream by the island test — measured across the seven
/// books in `bad/`, removing it changed nothing except rescuing 许不令.
const NEVER_IN_A_NAME: &str = "我你他她它您咱谁的了着过吧吗呢啊呀哦嘛么和与或及被把将向对从却便就\
才刚这那哪每某各都也又还再很更最只太是有在来去到会能要让没别一二两三四五六七八九十百千万几\
人声里中时候什怎为因所虽当随";

/// Common translated-Japanese surname forms that legitimately begin with a
/// number. Numerals stay in [`NEVER_IN_A_NAME`] because admitting every
/// two-to-four-character phrase containing 一/三/九 floods the seed table with
/// quantities and chapter prose. This narrow escape hatch keeps names such as
/// 九条美姬、四宫辉夜 and 五十岚清 without weakening the general noise filter.
///
/// The downstream island, accessor-variety and acted-upon tests still have to
/// accept the candidate; a matching prefix is permission to be measured, not a
/// verdict that the phrase is a person.
const NUMERIC_SURNAME_PREFIXES: &[&str] = &[
    "一之濑",
    "一条",
    "一色",
    "二宫",
    "二阶堂",
    "三浦",
    "三上",
    "三宅",
    "四宫",
    "四月一日",
    "五十岚",
    "五月",
    "六道",
    "七海",
    "七濑",
    "八神",
    "八坂",
    "九条",
    "九十九",
    "十六夜",
];

fn allowed_numeric_name(name: &str) -> bool {
    let n = name.chars().count();
    (3..=6).contains(&n)
        && ![
            "太太", "母亲", "父亲", "妈妈", "爸爸", "同学", "老师", "小姐", "先生",
        ]
        .iter()
        .any(|role| name.ends_with(role))
        && NUMERIC_SURNAME_PREFIXES
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

/// Words that pass every statistical test and are still not people: generic
/// person-nouns, narrative formulas, and bare role words. A book whose POV only
/// ever says 师父 does have such a character — but a role word names a slot,
/// not a person, and would weld different books' scenes together.
const NOT_A_NAME: &[&str] = &[
    // generic person-nouns. These refer to whoever is on stage — 剑来's narrator
    // calls both 陈平安 and 宋集薪 「少年」, both 陈平安 and 顾粲 「孩子」 — so they
    // name no one, yet 孩子 (207 mentions, density 6.1) sails past every
    // statistical test. A word that points at different people scene to scene is
    // definitionally not a name.
    "老者",
    "青年",
    "少年",
    "少女",
    "姑娘",
    "丫头",
    "小子",
    "家伙",
    "老头",
    "老太",
    "老头子",
    "老太太",
    "老爷子",
    "汉子",
    "女侠",
    "大侠",
    "对方",
    "自己",
    "大家",
    "孩子",
    "男人",
    "女人",
    "妇人",
    "老人",
    "男子",
    "女子",
    "小孩",
    "男孩",
    "女孩",
    // narrative formulas that stand before speech verbs
    "突然",
    "忽然",
    "果然",
    "居然",
    "竟然",
    "依然",
    "仍然",
    "显然",
    "既然",
    "自然",
    "当然",
    "猛然",
    "蓦然",
    "赫然",
    "悄然",
    "淡然",
    "漠然",
    "茫然",
    "愕然",
    "如果",
    "如今",
    "如此",
    "淡淡",
    "缓缓",
    "慢慢",
    "匆匆",
    "悄悄",
    "默默",
    "徐徐",
    "连连",
    "喃喃",
    "哈哈",
    "嘿嘿",
    "嘻嘻",
    "呵呵",
    "急忙",
    "连忙",
    "赶忙",
    "顿时",
    "随即",
    "然后",
    "然而",
    "不过",
    "旋即",
    "开口",
    "闻言",
    "点头",
    "摇头",
    "转头",
    "皱眉",
    "咬牙",
    "冷笑",
    "微笑",
    "大笑",
    "苦笑",
    "狂笑",
    "轻笑",
    "淡笑",
    "一笑",
    "点点头",
    "摇摇头",
    "笑眯眯",
    "此刻",
    "刚才",
    "今天",
    "明天",
    "昨天",
    "东西",
    "地方",
    "事情",
    "样子",
    "感觉",
    "目光",
    "眼神",
    "脸色",
    "表情",
    "语气",
    "身影",
    "身体",
    "脑海",
    "心头",
    "心底",
    // closed-class words: adverbs, modals, discourse markers, states. These
    // can pass every statistical test in a dialogue-heavy book (「放心，…」
    // fakes a left boundary), but no book uses them as a name — unlike
    // open-class nouns (白虎, 罐头), which do get to be characters and are
    // deliberately absent here.
    "可以",
    "应该",
    "必须",
    "至少",
    "放心",
    "确认",
    "直接",
    "简单",
    "好好",
    "已经",
    "立刻",
    "立即",
    "马上",
    "赶紧",
    "终于",
    "总算",
    "几乎",
    "大概",
    "也许",
    "或许",
    "可能",
    "恐怕",
    "似乎",
    "好像",
    "仿佛",
    "明明",
    "分明",
    "反正",
    "干脆",
    "索性",
    "毕竟",
    "难怪",
    "究竟",
    "到底",
    "无法",
    "明白",
    "清楚",
    "需要",
    "觉得",
    "认为",
    "希望",
    "打算",
    "准备",
    "决定",
    "开始",
    "结束",
    "发现",
    "想起",
    "记得",
    "忘记",
    "高兴",
    "生气",
    "愤怒",
    "激动",
    "紧张",
    "害怕",
    "恐惧",
    "惊讶",
    "吃惊",
    "震惊",
    "无奈",
    "尴尬",
    "犹豫",
    "沉默",
    "安静",
    "冷静",
    "平静",
    "认真",
    "仔细",
    "小心",
    "注意",
    "拜托",
    "谢谢",
    "多谢",
    "抱歉",
    "奇怪",
    "正常",
    "特别",
    "非常",
    "相当",
    "稍微",
    "顺便",
    "成功",
    "失败",
    "努力",
    "加油",
    "坚持",
    "其实",
    "确实",
    "总之",
    "另外",
    "后来",
    "从此",
    "慌忙",
    "急切",
    "焦急",
    "无语",
    "疑惑",
    "好奇",
    "郑重",
    "严肃",
    "温柔",
    "得意",
    "满意",
    "失望",
    "绝望",
    "兴奋",
    "咆哮",
    "牙疼",
    "等等",
    "尽管",
    "无论",
    "除非",
    "即便",
    "假如",
    "起码",
    "甚至",
    "何况",
    "反而",
    "老实",
    "眨眼",
    "转眼",
    // Book-scale offenders. On a 50-chapter probe these stay small, but across
    // all 1275 chapters of 剑来 they pile up into the top cast: 轻轻 4525×,
    // 依旧 3438×, 曾经 3146×, 双方 2781×, 左右 1979× (density 4.5 — above the
    // model-vetting gate!), 可惜 1634×. All closed-class, none ever a name.
    "轻轻",
    "依旧",
    "曾经",
    "双方",
    "左右",
    "可惜",
    // Narrative verbs and deictics that stand where a name stands (陈平安伸手道)
    // and so pass the speech-attribution anchor. Measured on 剑来 and 元尊, where
    // 伸手, 比如, 回头, 后者, 先前 all made the top-40 cast.
    "伸手",
    "比如",
    "回头",
    "后者",
    "前者",
    "先前",
    "以后",
    "以前",
    "后来者",
    "抬头",
    "低头",
    "转身",
    "起身",
    "上前",
    "开头",
    "半晌",
    "良久",
    "片刻",
    "这时",
    "那时",
    "一旁",
    "身后",
    "身前",
    "眼下",
    "自言自语",
    "不由自主",
    // role words and self-references
    "师父",
    "师尊",
    "师傅",
    "师兄",
    "师姐",
    "师妹",
    "师弟",
    "弟子",
    "徒弟",
    "哥哥",
    "姐姐",
    "妹妹",
    "弟弟",
    "爸爸",
    "妈妈",
    "爷爷",
    "奶奶",
    "叔叔",
    "舅舅",
    "老爸",
    "老妈",
    "夫人",
    "公子",
    "小姐",
    "大人",
    "陛下",
    "殿下",
    "将军",
    "队长",
    "老板",
    "老师",
    "医生",
    "大夫",
    "护士",
    "警官",
    "前辈",
    "晚辈",
    "皇上",
    "皇帝",
    "太子",
    "公主",
    "属下",
    "卑职",
    "微臣",
    "老夫",
    "老子",
    "本座",
    "本王",
    "贫道",
    "本官",
    "本宫",
];

/// Appellations worth carrying as relationship hints. The word itself is the
/// hint — mapping words to a closed label set is the model layer's job, and
/// keeping the raw word lets a human check the rules without one.
const APPELLATION: &[&str] = &[
    "师父",
    "师尊",
    "师傅",
    "恩师",
    "徒弟",
    "徒儿",
    "弟子",
    // 娘 and 妈 are absent on purpose: 骂娘, 老娘, 娘娘腔, 婆婆妈妈, 姑娘 bury the
    // handful of real uses, and they never voted anyway (see relation::word_label).
    "爹",
    "父亲",
    "母亲",
    "爸",
    "儿子",
    "女儿",
    "闺女",
    "爷爷",
    "奶奶",
    "外公",
    "外婆",
    "叔叔",
    "舅舅",
    "姑姑",
    "哥哥",
    "大哥",
    "二哥",
    "兄长",
    "老哥",
    "弟弟",
    "老弟",
    "姐姐",
    "妹妹",
    "兄弟",
    "姐妹",
    "堂兄",
    "表哥",
    "表妹",
    "夫人",
    "娘子",
    "相公",
    "丈夫",
    "妻子",
    "媳妇",
    "老婆",
    "老公",
    "夫君",
    "未婚妻",
    "未婚夫",
    "男朋友",
    "女朋友",
    "男友",
    "女友",
    "恋人",
    "师兄",
    "师弟",
    "师姐",
    "师妹",
    "师叔",
    "师伯",
    "同门",
    "同窗",
    "同学",
    "同事",
    "战友",
    "队友",
    "搭档",
    "朋友",
    "好友",
    "知己",
    "陛下",
    "殿下",
    "王爷",
    "主公",
    "主人",
    "大人",
    "属下",
    "部下",
    "卑职",
    "微臣",
    "少爷",
    "小姐",
    "老爷",
    "公子",
    "前辈",
    "晚辈",
    "长老",
    "掌门",
    "宗主",
    "队长",
    "组长",
    "老板",
    "上司",
    "老大",
    "仇人",
    "仇家",
    "死敌",
    "对手",
    "敌人",
];

/// Words that mark a sentence as *saying something about a bond*, used only to
/// rank which co-occurrence sentences are worth showing the model — not to label
/// anything. Recall over precision: a sentence with 道侣 or 抱住 reveals the
/// relationship; 「陈平安、宁姚、齐廷济五位剑修」 (a battle roster) reveals nothing,
/// yet both are equal co-occurrences. Uniform sampling drowns the first 40 spouse
/// markers under a thousand neutral co-locations, and the model then reads mostly
/// noise. Unlike [`APPELLATION`], these need not be *bound* to the pair — a loose
/// 道侣 in the sentence is still a strong hint the model can weigh. Kept to
/// unambiguous relationship words and specific two-body actions; generic verbs
/// (教, 救, 抱) are avoided because they fire on everything.
const RELATION_CUES: &[&str] = &[
    // romance / marriage
    "道侣",
    "媳妇",
    "夫妻",
    "夫君",
    "娘子",
    "相公",
    "恋人",
    "情郎",
    "心上人",
    "意中人",
    "未婚妻",
    "未婚夫",
    "成亲",
    "成婚",
    "完婚",
    "定情",
    "白头",
    "私奔",
    "倾心",
    "情意",
    "拥抱",
    "抱住",
    "搂住",
    "亲吻",
    "接吻",
    "牵手",
    "携手",
    "并肩",
    "脸红",
    "吃醋",
    "情郎",
    // master / disciple
    "师父",
    "师傅",
    "师尊",
    "恩师",
    "弟子",
    "徒弟",
    "徒儿",
    "亲传",
    "收徒",
    "拜师",
    "传授",
    "授业",
    "教导",
    "衣钵",
    "门下",
    "开山大弟子",
    // kin
    "父亲",
    "母亲",
    "娘亲",
    "亲娘",
    "亲爹",
    "儿子",
    "女儿",
    "闺女",
    "骨肉",
    "血脉",
    "亲生",
    "认亲",
    "爷爷",
    "奶奶",
    "外公",
    "外婆",
    // siblings / sworn
    "兄长",
    "大哥",
    "姐姐",
    "哥哥",
    "弟弟",
    "妹妹",
    "结拜",
    "义兄",
    "义弟",
    "手足",
    "兄妹",
    // friends
    "朋友",
    "好友",
    "知己",
    "挚友",
    "至交",
    "生死之交",
    "相依为命",
    "患难",
    "过命",
    // enmity
    "仇人",
    "死敌",
    "世仇",
    "血仇",
    "报仇",
    "杀父",
    "弑",
    "不共戴天",
    "你死我活",
    "宿敌",
    "仇敌",
    "深仇",
    "血海深仇",
    // specific two-body actions that carry a bond
    "背着",
    "背起",
    "抱起",
    "搀扶",
    "救下",
    "护住",
    "舍命",
    "磕头",
    "下跪",
];

/// Does this sentence carry any relationship signal? See [`RELATION_CUES`].
fn has_cue(sent: &str) -> bool {
    RELATION_CUES.iter().any(|w| sent.contains(w))
}

/// Words that mark a sentence as *saying who someone is* rather than merely
/// showing them doing something. Same job [`RELATION_CUES`] does for edges, and
/// the same doctrine: this only ranks which of a person's thousands of sentences
/// are worth handing to the model, and never labels anything.
///
/// A lead appears in nine thousand sentences and all but a few dozen are
/// 「陈平安点点头」. Uniform sampling hands the model forty nods; these words are
/// what pull the handful that carry an origin, a station, a look or a turn of
/// fate to the front. Generic copulas (是, 乃) are left out on purpose — a cue
/// that fires on every sentence ranks nothing.
const BACKGROUND_CUES: &[&str] = &[
    // origin and identity
    "出身",
    "身份",
    "来历",
    "本名",
    "名叫",
    "原名",
    "外号",
    "绰号",
    "人称",
    "自称",
    "祖上",
    "家世",
    "世家",
    "家族",
    "族人",
    "老家",
    "故乡",
    "遗孤",
    "孤儿",
    "血脉",
    "传人",
    // the past, told in passing
    "自幼",
    "从小",
    "当年",
    "早年",
    "昔日",
    "从前",
    "原本",
    "本是",
    "原是",
    "曾是",
    "曾经",
    "十年前",
    "年幼",
    "小时候",
    "生前",
    "长大",
    // station and rank
    "掌门",
    "宗主",
    "家主",
    "族长",
    "长老",
    "首座",
    "堂主",
    "门主",
    "城主",
    "帮主",
    "少主",
    "少爷",
    "小姐",
    "公子",
    "将军",
    "元帅",
    "皇帝",
    "太子",
    "王爷",
    "国主",
    "总管",
    "老板",
    "队长",
    "社长",
    "会长",
    "班长",
    "教授",
    "医生",
    "警官",
    "弟子",
    "亲传",
    "记名",
    "散修",
    "散人",
    // what they can do
    "天赋",
    "资质",
    "根骨",
    "天资",
    "修为",
    "境界",
    "突破",
    "剑术",
    "武功",
    "本事",
    "手段",
    "成名",
    "闻名",
    "名声",
    "名气",
    "威名",
    // what they are like
    "性子",
    "性格",
    "脾气",
    "为人",
    "生性",
    "向来",
    "从不",
    "最恨",
    "最爱",
    "心愿",
    "志向",
    "立志",
    "发誓",
    "执念",
    // what they look like
    "生得",
    "相貌",
    "容貌",
    "模样",
    "身形",
    "个子",
    "眉眼",
    "一袭",
    "身穿",
    "穿着",
    "打扮",
    "年纪",
    "岁上下",
    "少年",
    "少女",
    "青年",
    "老者",
    "妇人",
    "汉子",
    "书生",
    // turning points
    "死了",
    "战死",
    "身亡",
    "重伤",
    "废了",
    "拜师",
    "入门",
    "叛出",
    "逐出",
    "背叛",
    "失踪",
    "回来",
    "醒来",
    "重生",
    "穿越",
];

/// Does this sentence say anything about who the person is? See [`BACKGROUND_CUES`].
fn has_background(sent: &str) -> bool {
    BACKGROUND_CUES.iter().any(|w| sent.contains(w))
}

/// Where an appellation sits decides whether it says anything about *this* pair.
/// A sentence merely containing 爹 says nothing: 「李槐他爹」 is a third party and
/// 「杨家铺子的杨爷爷」 is a stranger — both of which used to label their pair 亲子.
/// Only three positions carry a bond, and everything else is dropped.
/// `crowd` is how many of the cast share this sentence — direct address only
/// speaks about a pair when the pair is alone in it.
fn bound_hints(
    sent: &str,
    present: &[&'static str],
    names: &[&str],
    crowd: usize,
) -> Vec<&'static str> {
    present
        .iter()
        .copied()
        .filter(|w| {
            sent.match_indices(w)
                .any(|(s, _)| bound_here(sent, s, w, names, crowd))
        })
        .collect()
}

fn bound_here(sent: &str, s: usize, w: &str, names: &[&str], crowd: usize) -> bool {
    // A possessive hands the appellation to whoever owns it — 崔瀺的爷爷 is the
    // grandfather, not 崔瀺 — and Chinese drops the 的 freely (宁姚爹娘), so a
    // name sitting immediately to the left is a possessive too, not an
    // apposition. Either way it only speaks about the pair when a copula makes
    // the other member that person: 郑大风是杨老头的嫡传弟子.
    if let Some(p) = possessive_before(sent, s) {
        return copula_rescue(sent, p, names);
    }
    if let Some(n) = names.iter().find(|n| sent[..s].ends_with(*n)) {
        return copula_rescue(sent, s - n.len(), names);
    }
    // Apposition (大徒弟刘羡阳) is deliberately not accepted. It does establish
    // that 刘羡阳 is a 徒弟 — but of 老姚, who is not in the pair. A role word
    // tells you what one person is; only the two positions below tell you what
    // the two are *to each other*.
    //
    // Direct address — 「师父，……」 — with nobody else in the sentence to be
    // talking to.
    if crowd != 2 {
        return false;
    }
    let e = s + w.len();
    let opens = sent[..s]
        .chars()
        .next_back()
        .is_none_or(|c| "「“\"'，,：:（(".contains(c));
    let closes = sent[e..]
        .chars()
        .next()
        .is_none_or(|c| "」”\"'，,！!？?。.、".contains(c));
    if !(opens && closes) {
        return false;
    }
    // Whoever is named *inside* the speech is being talked about, not talked to.
    // 剑来 ch.171 — 李槐 says 「爹，…以前跟陈平安在一起的时候…」: he is addressing
    // his own father, who is not in the cast at all, while 陈平安 is merely
    // mentioned. Read as address, that labelled the two of them 亲子.
    match sent[..s].rfind(['「', '“', '"']) {
        Some(q) => !names.iter().any(|n| sent[q..].contains(n)),
        None => true,
    }
}

/// The 的/他/她 that hands an appellation to an owner, if one stands just before
/// it. Modifiers may intervene (杨老头的嫡传弟子), punctuation may not.
fn possessive_before(sent: &str, s: usize) -> Option<usize> {
    for (i, c) in sent[..s].char_indices().rev().take(4) {
        if "，,。！？「」“”".contains(c) {
            return None;
        }
        if "的他她其".contains(c) {
            return Some(i);
        }
    }
    None
}

/// `<other member>是 … <owner>的<appellation>` — the copula makes the possessive
/// a statement about the pair after all. Kept to the clause so a stray 是 from
/// earlier narration cannot rescue an unrelated possessive.
fn copula_rescue(sent: &str, p: usize, names: &[&str]) -> bool {
    let head = &sent[..p];
    let clause = match head.rfind(['，', ',', '：', '“', '「']) {
        Some(i) => &head[i..],
        None => head,
    };
    names.iter().any(|n| {
        clause
            .match_indices(n)
            .any(|(i, _)| clause[i + n.len()..].contains('是'))
    })
}

/// The raw candidate table, for probes: (candidate, count, anchored, boundary).
/// Tuning the filters against a real book requires seeing what they saw.
pub fn candidate_stats(
    text: &str,
    chapters: &[Chapter],
    upto: usize,
) -> Vec<(String, u32, u32, u32, u32)> {
    let n = upto.min(chapters.len());
    let mut paras: Vec<(usize, &str)> = Vec::new();
    for ch in chapters.iter().take(n) {
        for line in text[ch.body_start..ch.span.end].split('\n') {
            let line = line.trim();
            if !line.is_empty() {
                paras.push((ch.index, line));
            }
        }
    }
    candidates(&paras)
        .into_iter()
        .map(|(name, st)| (name, st.count, st.anchored, st.boundary, st.boundary_r))
        .collect()
}

pub fn scan(text: &str, chapters: &[Chapter], upto: usize) -> Cast {
    let n = upto.min(chapters.len());
    let mut paras: Vec<(usize, &str)> = Vec::new();
    for ch in chapters.iter().take(n) {
        for line in text[ch.body_start..ch.span.end].split('\n') {
            let line = line.trim();
            if !line.is_empty() {
                paras.push((ch.index, line));
            }
        }
    }
    let cands = candidates(&paras);
    let members = select(&cands);
    let (people, edges, n_chapters) = graph(&paras, members);
    let romance_focus = crate::focus::analyze(text, &chapters[..n]).romance.zh();
    let relationship = crate::romance::analyze(&paras, &people, &edges, n_chapters, romance_focus);
    let mut cast = prune(people, edges, n_chapters);
    cast.relationship = Some(relationship);
    cast
}

/// Diagnostic: the full ranked cast *before* [`prune`] trims it to [`TOP_CAST`],
/// so a probe can see where a missed lead fell — its count, chapters, density,
/// and debut — instead of just vanishing from the pruned graph.
pub fn scan_ranked(text: &str, chapters: &[Chapter], upto: usize) -> Vec<Person> {
    let n = upto.min(chapters.len());
    let mut paras: Vec<(usize, &str)> = Vec::new();
    for ch in chapters.iter().take(n) {
        for line in text[ch.body_start..ch.span.end].split('\n') {
            let line = line.trim();
            if !line.is_empty() {
                paras.push((ch.index, line));
            }
        }
    }
    let cands = candidates(&paras);
    let members = select(&cands);
    graph(&paras, members).0
}

#[derive(Default)]
struct Stat {
    count: u32,
    left: HashSet<char>,
    right: HashSet<char>,
    /// Times this stood before a speech verb with a clean left boundary
    /// (「」吕树说道). Diagnostics only: it looked like the strongest signal,
    /// but subject-omitted formulas (继续道：) anchor more than most names do.
    anchored: u32,
    /// Occurrences whose left neighbour is not a CJK char. A name is a
    /// referential island: it follows punctuation, quotes, or a paragraph
    /// start. A common word is glued into prose (一口气, 的同学, 就可以) —
    /// frequency and accessor variety cannot tell those from names; this can.
    boundary: u32,
    /// Same, for the right neighbour. An utterance-opening word (「放心，…)
    /// fakes the left boundary in dialogue-heavy books; both at once is what
    /// only a vocative or a bare subject — a name — manages regularly.
    boundary_r: u32,
    /// Occurrences standing right after an [`OBJECT_CUE`] — 和许不令、找张翔.
    /// The island test asks whether a candidate stands alone; this asks whether
    /// anyone ever does anything *to* it, which is what a gesture word standing
    /// alone after a comma (，抬手道：) cannot fake.
    object: u32,
}

/// Seed name candidates from dialogue attribution, then count each across the
/// whole range together with its neighbour characters.
fn candidates(paras: &[(usize, &str)]) -> Vec<(String, Stat)> {
    let mut seeds: HashSet<String> = HashSet::new();
    let mut anchored: HashMap<String, u32> = HashMap::new();
    for &(_, line) in paras {
        let cs: Vec<char> = line.chars().collect();
        for i in 0..cs.len() {
            if !SPEECH.contains(&cs[i]) {
                continue;
            }
            // Anchor at the end of the verb cluster (the 道 of 说道), with
            // punctuation or end-of-line after it.
            if cs.get(i + 1).is_some_and(|c| SPEECH.contains(c)) {
                continue;
            }
            if !after_ok(cs.get(i + 1).copied()) {
                continue;
            }
            let mut j = i;
            while j > 0 && SPEECH.contains(&cs[j - 1]) {
                j -= 1;
            }
            if j > 0 && false_friend(cs[j - 1], cs[j]) {
                continue;
            }
            let mut k = j;
            while k > 0 && j - k < 6 && is_cjk(cs[k - 1]) && !SPEECH.contains(&cs[k - 1]) {
                k -= 1;
            }
            // Every suffix of the run is a candidate: the run may open with
            // narrative (这时吕树) — statistics keep the name and drop the rest.
            for l in 2..=(j - k).min(4) {
                seeds.insert(cs[j - l..j].iter().collect());
            }
            // A whole run with punctuation on its left is a clean anchor: the
            // speaker and nothing else stands before the verb.
            if (2..=4).contains(&(j - k)) && (k == 0 || !is_cjk(cs[k - 1])) {
                *anchored.entry(cs[k..j].iter().collect()).or_default() += 1;
            }
        }
        // Second seed source: whoever stands right after an interaction word
        // (和宁玉合、找陈思凝). Speech attribution alone is at the mercy of the
        // author's habit — 世子很凶 writes 轻声道／含笑道 almost every time and
        // names its speaker almost never, so that harvest returned three people
        // for a book with twenty. Being acted upon is a habit of the story, not
        // of the prose, so it finds the supporting cast the other source misses.
        for i in 0..cs.len() {
            if !OBJECT_CUE.contains(&cs[i]) {
                continue;
            }
            let mut e = i + 1;
            while e < cs.len() && e - i <= 3 && is_cjk(cs[e]) {
                e += 1;
            }
            for l in 2..=(e - i - 1).min(3) {
                seeds.insert(cs[i + 1..=i + l].iter().collect());
            }
        }
    }
    seeds.retain(|s| {
        (!s.chars().any(|c| NEVER_IN_A_NAME.contains(c)) || allowed_numeric_name(s))
            && !NOT_A_NAME.contains(&s.as_str())
    });

    let mut names: Vec<String> = seeds.into_iter().collect();
    names.sort();
    let mut stats: Vec<Stat> = names
        .iter()
        .map(|n| Stat {
            anchored: anchored.get(n).copied().unwrap_or(0),
            ..Stat::default()
        })
        .collect();
    let mut by_first: HashMap<char, Vec<usize>> = HashMap::new();
    for (i, name) in names.iter().enumerate() {
        by_first
            .entry(name.chars().next().unwrap())
            .or_default()
            .push(i);
    }
    for &(_, line) in paras {
        let mut prev = '\n';
        for (o, c) in line.char_indices() {
            if let Some(ids) = by_first.get(&c) {
                for &i in ids {
                    let name = &names[i];
                    if line[o..].starts_with(name.as_str()) {
                        let st = &mut stats[i];
                        st.count += 1;
                        if !is_cjk(prev) {
                            st.boundary += 1;
                        }
                        if OBJECT_CUE.contains(&prev) {
                            st.object += 1;
                        }
                        if st.left.len() < 4 {
                            st.left.insert(prev);
                        }
                        let right = line[o + name.len()..].chars().next().unwrap_or('\n');
                        if !is_cjk(right) {
                            st.boundary_r += 1;
                        }
                        if st.right.len() < 4 {
                            st.right.insert(right);
                        }
                    }
                }
            }
            prev = c;
        }
    }
    names.into_iter().zip(stats).collect()
}

struct Member {
    name: String,
    aliases: Vec<String>,
    mentions: u32,
}

fn select(cands: &[(String, Stat)]) -> Vec<Member> {
    let frequent: Vec<usize> = (0..cands.len())
        .filter(|&i| cands[i].1.count >= MIN_MENTIONS)
        .collect();
    let island = |st: &Stat, standalone: u32| st.boundary * 5 >= standalone * 2;
    // How much of a candidate's ink is really a longer candidate's (如雪
    // inside 苏如雪). Those occurrences never touch a boundary — the surname
    // is glued to their left — so the island test must not count them. Only a
    // full-name-shaped island may claim ink: otherwise any frequent fragment
    // (想继续, 请继续) quietly rescues the common word it ends with.
    let overlap: Vec<u32> = frequent
        .iter()
        .map(|&i| {
            frequent
                .iter()
                .filter(|&&j| {
                    j != i
                        // Both ends: the speech harvest only ever produced
                        // suffixes (如雪 out of 苏如雪), but a cue harvest cuts
                        // names short too (许不 out of 和许不令), and a fragment
                        // must be judged on its standalone ink either way.
                        && (cands[j].0.ends_with(cands[i].0.as_str())
                            || cands[j].0.starts_with(cands[i].0.as_str()))
                        && full_name_shaped(&cands[j].0)
                        && island(&cands[j].1, cands[j].1.count)
                })
                .map(|&j| cands[j].1.count)
                .max()
                .unwrap_or(0)
        })
        .collect();

    // Accessor variety: a name is met in varied company on both sides; a
    // crossing fragment (树笑) is stuck to the same neighbour forever.
    let alive: Vec<usize> = frequent
        .iter()
        .zip(&overlap)
        .filter(|&(&i, &over)| {
            let st = &cands[i].1;
            let need = if st.count >= 15 { 3 } else { 2 };
            // Frequency and accessor variety admit any common word; what they
            // cannot fake is being a referential island: standing against
            // punctuation, a quote, or a paragraph start instead of glued into
            // prose (一口气, 的同学, 就可以). Measured on 大王饶命 and
            // 异兽迷城: real names 42–77%, common words at most 37% — even
            // 继续, which anchors 继续道： constantly, stays at 35%.
            let standalone = st.count.saturating_sub(over);
            let ok = island(st, standalone) || strong_two_char_name(&cands[i].0, st, standalone);
            // A frequent word nobody ever acts upon is a gesture, not a person.
            // Judged on standalone ink only: a given name living inside a full
            // name (静春 in 齐静春, 烈阳 in 风烈阳) is rarely addressed alone, and
            // killing it here would cost the full name its alias.
            // Seeding from the cue means junk arrives pre-supplied with a few
            // hits (对整个, 和真正), so the bar is a rate, not a single hit —
            // and both halves must hold. Being acted upon says a person is
            // meant; ending a clause says a whole referent is meant, not the
            // head of a phrase. Junk fails one or the other every time (年轻
            // 受事 5% but 右边界 1%; 今日 右边界 26% but 受事 1%), while every
            // real name in the corpus clears 受事 ≥ 2.6% and 右边界 ≥ 3%.
            let acted_upon = standalone < OBJECT_FLOOR
                || (st.object * 50 >= standalone && st.boundary_r * 33 >= standalone);
            st.count >= MIN_MENTIONS
                && st.left.len() >= need
                && st.right.len() >= need
                && ok
                && acted_upon
        })
        .map(|(&i, _)| i)
        .collect();
    // 吕树笑 out of 吕树笑道: an extension far rarer than the name it extends
    // is an adverb stuck to it, not a longer name.
    let alive: Vec<usize> = alive
        .iter()
        .copied()
        .filter(|&b| {
            !alive.iter().any(|&a| {
                a != b
                    && cands[b].0.contains(cands[a].0.as_str())
                    && cands[b].1.count < cands[a].1.count / 8
            })
        })
        .collect();

    // Fold a bare given name into its full name when exactly one claims it.
    let full_of = |g: &str| -> Option<usize> {
        let mut it = alive
            .iter()
            .copied()
            .filter(|&f| cands[f].0.ends_with(g) && full_name_shaped(&cands[f].0));
        match (it.next(), it.next()) {
            (Some(f), None) => Some(f),
            _ => None,
        }
    };
    let mut folded: HashMap<usize, Vec<usize>> = HashMap::new();
    let mut taken: HashSet<usize> = HashSet::new();
    // The mirror case: a fragment cut off the *front* of a name (许不 out of
    // 许不令, 渡边 out of 渡边彻, 小野 out of 小野美月/美花). The island test
    // cannot see these — the punctuation before 「，许不令」 is a clean left
    // boundary for 许不 as well — so they are caught by their ink instead: a
    // candidate that almost never appears outside a longer name is that name,
    // folded in when only one name could be meant and dropped when several
    // could (小野 is not a person; 小野美月 and 小野美花 are).
    let prefix_hosts = |g: usize| -> Vec<usize> {
        alive
            .iter()
            .copied()
            .filter(|&f| f != g && cands[f].0.starts_with(cands[g].0.as_str()))
            .collect()
    };
    for &g in &alive {
        if cands[g].0.chars().count() != 2 {
            continue;
        }
        if let Some(f) = full_of(&cands[g].0) {
            folded.entry(f).or_default().push(g);
            taken.insert(g);
            continue;
        }
        let hosts = prefix_hosts(g);
        let inside: u32 = hosts.iter().map(|&f| cands[f].1.count).sum();
        if inside * 4 >= cands[g].1.count * 3 {
            if let [f] = hosts[..] {
                folded.entry(f).or_default().push(g);
            }
            taken.insert(g);
        }
    }

    // Fold a 姓+尊称 form (齐先生, 苏姑娘) into the one full name that shares its
    // surname. Unlike a given name, an honorific shares no ink with the full
    // name — 齐先生 and 齐静春 are separate strings — so its whole count adds.
    // Only fires when exactly one full-name member could be meant, so 王先生 in
    // a book with two 王s stays its own node rather than guessing.
    let host_of = |t: &str, taken: &HashSet<usize>| -> Option<usize> {
        let surname = TITLES.iter().find_map(|suf| t.strip_suffix(suf))?;
        if surname.is_empty() {
            return None;
        }
        // The host is the one detected name that extends this surname (齐 →
        // 齐静春). Not required to be surname-table-shaped: 齐 need not be in the
        // list for 齐静春 to be the obvious referent, and the uniqueness guard
        // below is what keeps the fold honest.
        let mut it = alive.iter().copied().filter(|&f| {
            !taken.contains(&f)
                && cands[f].0.starts_with(surname)
                && cands[f].0.chars().count() > surname.chars().count()
                // A real name, not another honorific on the same surname — else
                // 齐先生 and 齐姑娘 would each veto the other's fold into 齐静春.
                && !TITLES.iter().any(|suf| cands[f].0.ends_with(suf))
        });
        match (it.next(), it.next()) {
            (Some(f), None) => Some(f),
            _ => None,
        }
    };
    let mut titled: HashMap<usize, Vec<usize>> = HashMap::new();
    for &t in &alive {
        if taken.contains(&t) {
            continue;
        }
        if let Some(f) = host_of(&cands[t].0, &taken) {
            titled.entry(f).or_default().push(t);
            taken.insert(t);
        }
    }

    let mut members: Vec<Member> = alive
        .iter()
        .copied()
        .filter(|i| !taken.contains(i))
        .map(|f| {
            let mut mentions = cands[f].1.count;
            let mut aliases = Vec::new();
            for &g in folded.get(&f).map(Vec::as_slice).unwrap_or(&[]) {
                // A given-name hit inside the full name is the same ink; only
                // standalone uses add.
                mentions += cands[g].1.count.saturating_sub(cands[f].1.count);
                aliases.push(cands[g].0.clone());
            }
            for &t in titled.get(&f).map(Vec::as_slice).unwrap_or(&[]) {
                mentions += cands[t].1.count;
                aliases.push(cands[t].0.clone());
            }
            Member {
                name: cands[f].0.clone(),
                aliases,
                mentions,
            }
        })
        .collect();
    members.sort_by(|x, y| y.mentions.cmp(&x.mentions).then(x.name.cmp(&y.name)));
    members.truncate(MAX_CAST);
    members
}

fn graph(paras: &[(usize, &str)], members: Vec<Member>) -> (Vec<Person>, Vec<Edge>, usize) {
    let mut people: Vec<Person> = members
        .iter()
        .map(|m| Person {
            name: m.name.clone(),
            aliases: m.aliases.clone(),
            mentions: m.mentions,
            chapters: 0,
            first_chapter: 0,
            uncertain: false,
            evidence: Vec::new(),
        })
        .collect();

    let mut pats: Vec<(String, usize)> = Vec::new();
    for (pid, m) in members.iter().enumerate() {
        pats.push((m.name.clone(), pid));
        for a in &m.aliases {
            pats.push((a.clone(), pid));
        }
    }
    let mut by_first: HashMap<char, Vec<usize>> = HashMap::new();
    for (i, (p, _)) in pats.iter().enumerate() {
        by_first
            .entry(p.chars().next().unwrap())
            .or_default()
            .push(i);
    }

    #[derive(Default)]
    struct Acc {
        weight: u32,
        hints: HashMap<&'static str, u32>,
        /// Two reservoirs, so the few relationship-revealing sentences aren't
        /// drowned by neutral co-locations. `strong` holds sentences with a bound
        /// appellation or a [`RELATION_CUES`] word; `weak` holds the rest. The
        /// model is handed strong first, weak only to top up. See [`add_evidence`].
        strong: Reservoir,
        weak: Reservoir,
    }
    let mut edges: HashMap<(usize, usize), Acc> = HashMap::new();
    let mut last_seen: Vec<Option<usize>> = vec![None; people.len()];
    let mut first_seen: Vec<Option<usize>> = vec![None; people.len()];
    // Per person, the same two-tier sample the edges keep, for the same reason:
    // a lead's sentences are overwhelmingly 「他点点头」, and a uniform draw of
    // forty of those tells the model nothing about who he is.
    let mut solo: Vec<(Reservoir, Reservoir)> =
        (0..people.len()).map(|_| Default::default()).collect();

    for &(ci, line) in paras {
        // Longest match wins and overlaps are dropped, so 李青 inside 李青山
        // does not put the wrong person in the scene.
        let mut hits: Vec<(usize, usize, usize)> = Vec::new(); // start, end, pid
        for (o, c) in line.char_indices() {
            if let Some(ids) = by_first.get(&c) {
                for &i in ids {
                    let (p, pid) = &pats[i];
                    if line[o..].starts_with(p.as_str()) {
                        hits.push((o, o + p.len(), *pid));
                    }
                }
            }
        }
        hits.sort_by(|x, y| x.0.cmp(&y.0).then(y.1.cmp(&x.1)));
        let mut kept: Vec<(usize, usize, usize)> = Vec::new();
        let mut end = 0;
        for h in hits {
            if h.0 >= end {
                end = h.1;
                kept.push(h);
            }
        }
        if kept.is_empty() {
            continue;
        }

        for &(_, _, pid) in &kept {
            if last_seen[pid] != Some(ci) {
                last_seen[pid] = Some(ci);
                people[pid].chapters += 1;
                first_seen[pid].get_or_insert(ci);
            }
        }

        let mut bounds: Vec<usize> = vec![0];
        for (o, c) in line.char_indices() {
            if "。！？；".contains(c) {
                bounds.push(o + c.len_utf8());
            }
        }
        if *bounds.last().unwrap() < line.len() {
            bounds.push(line.len());
        }

        for w in bounds.windows(2) {
            let (s0, s1) = (w[0], w[1]);
            let mut pids: Vec<usize> = kept
                .iter()
                .filter(|h| h.0 >= s0 && h.0 < s1)
                .map(|h| h.2)
                .collect();
            pids.sort_unstable();
            pids.dedup();
            let sent = line[s0..s1].trim();
            // Every person in the sentence banks it, alone or not: a scene with
            // two people in it still says something about each of them.
            let tells = has_background(sent);
            for &pid in &pids {
                let r = if tells {
                    &mut solo[pid].0
                } else {
                    &mut solo[pid].1
                };
                r.push(ci, sent);
            }
            if pids.len() < 2 {
                continue;
            }
            let present: Vec<&'static str> = APPELLATION
                .iter()
                .copied()
                .filter(|w| sent.contains(w))
                .collect();
            for x in 0..pids.len() {
                for y in x + 1..pids.len() {
                    let (pa, pb) = (pids[x], pids[y]);
                    // Bound to *these two*, not merely present in the sentence.
                    let hinted = if present.is_empty() {
                        Vec::new()
                    } else {
                        let mut names: Vec<&str> = Vec::new();
                        for &pid in &[pa, pb] {
                            names.push(members[pid].name.as_str());
                            names.extend(members[pid].aliases.iter().map(String::as_str));
                        }
                        bound_hints(sent, &present, &names, pids.len())
                    };
                    let acc = edges.entry((pa, pb)).or_default();
                    acc.weight += 2;
                    for &word in &hinted {
                        *acc.hints.entry(word).or_default() += 1;
                    }
                    // A sentence earns the strong reservoir if it says anything
                    // about the bond — a bound appellation, or a loose cue word.
                    if !hinted.is_empty() || has_cue(sent) {
                        acc.strong.push(ci, sent);
                    } else {
                        acc.weak.push(ci, sent);
                    }
                }
            }
        }

        let mut para_pids: Vec<usize> = kept.iter().map(|h| h.2).collect();
        para_pids.sort_unstable();
        para_pids.dedup();
        for x in 0..para_pids.len() {
            for y in x + 1..para_pids.len() {
                edges
                    .entry((para_pids[x], para_pids[y]))
                    .or_default()
                    .weight += 1;
            }
        }
    }

    for (pid, p) in people.iter_mut().enumerate() {
        p.first_chapter = first_seen[pid].unwrap_or(0);
        // Telling sentences first, neutral ones only to fill; then chronological,
        // so the model reads a life in the order it was lived.
        let (strong, weak) = std::mem::take(&mut solo[pid]);
        let mut ev = strong.items;
        if ev.len() < MAX_EVIDENCE {
            let need = MAX_EVIDENCE - ev.len();
            ev.extend(weak.items.into_iter().take(need));
        }
        ev.sort_by_key(|&(ci, _)| ci);
        p.evidence = ev;
    }
    let n_chapters = paras.iter().map(|&(c, _)| c).max().map_or(0, |c| c + 1);

    let mut out: Vec<Edge> = edges
        .into_iter()
        .filter(|(_, acc)| acc.weight >= MIN_EDGE)
        .map(|((a, b), acc)| {
            let mut hints: Vec<(String, u32)> = acc
                .hints
                .into_iter()
                .map(|(w, c)| (w.to_string(), c))
                .collect();
            hints.sort_by(|x, y| y.1.cmp(&x.1).then(x.0.cmp(&y.0)));
            let label = crate::relation::from_hints(&hints).map(str::to_string);
            // Relationship-bearing sentences first; fill the rest with neutral
            // co-locations only if there is room, so the model reads mostly
            // signal. Then chronological order, so it can judge how the bond
            // *ends up* — friends who become lovers read as lovers.
            let mut evidence = acc.strong.items;
            if evidence.len() < MAX_EVIDENCE {
                let need = MAX_EVIDENCE - evidence.len();
                evidence.extend(acc.weak.items.into_iter().take(need));
            }
            evidence.sort_by_key(|&(ci, _)| ci);
            Edge {
                a,
                b,
                weight: acc.weight,
                hints,
                label,
                evidence,
            }
        })
        .collect();
    out.sort_by(|x, y| y.weight.cmp(&x.weight).then((x.a, x.b).cmp(&(y.a, y.b))));
    out.truncate(MAX_EDGES);

    (people, out, n_chapters)
}

/// Reduce the scan to the graph a reader sees: drop everyone below the density
/// floor, then fill [`TOP_CAST`] slots as two unioned rosters — the perennial
/// leads and the opening cast — mark the uncertain band, and renumber the edges.
///
/// `people` arrives sorted by mention count (see [`select`]). The leads are the
/// first [`PRIMARY_BY_COUNT`] survivors: the characters who carry the whole book.
/// The remaining slots are reserved for the most-mentioned characters who *debut
/// early* — that is what rescues a founder like 齐静春 whom a running total
/// buries under a thousand later chapters. Any slots the opening cast leaves
/// unfilled (a short book, a late-starting story) fall back to raw count.
fn prune(people: Vec<Person>, edges: Vec<Edge>, n_chapters: usize) -> Cast {
    let density = |p: &Person| p.mentions as f32 / p.chapters.max(1) as f32;
    let alive: Vec<usize> = (0..people.len())
        .filter(|&i| density(&people[i]) >= DENSITY_FLOOR)
        .collect();
    // The leads: the first survivors in count order (people are count-sorted).
    let mut chosen: HashSet<usize> = alive.iter().take(PRIMARY_BY_COUNT).copied().collect();
    // The opening cast: highest-count survivors debuting in the first 5%. `alive`
    // is count-sorted, so this filter keeps count order — take until full.
    let early_cut = (n_chapters / EARLY_FRACTION).max(EARLY_FLOOR);
    let opening: Vec<usize> = alive
        .iter()
        .copied()
        .filter(|&i| !chosen.contains(&i) && people[i].first_chapter <= early_cut)
        .take(TOP_CAST.saturating_sub(chosen.len()))
        .collect();
    chosen.extend(opening);
    // Any slots still open (few early characters) fall back to raw count.
    for &i in &alive {
        if chosen.len() >= TOP_CAST {
            break;
        }
        chosen.insert(i);
    }
    // Rebuild in count order so the graph's node order stays stable.
    let mut remap = vec![usize::MAX; people.len()];
    let mut kept: Vec<Person> = Vec::new();
    for (i, mut p) in people.into_iter().enumerate() {
        if !chosen.contains(&i) {
            continue;
        }
        p.uncertain = density(&p) < DENSITY_SURE;
        remap[i] = kept.len();
        kept.push(p);
    }
    let edges = edges
        .into_iter()
        .filter(|e| remap[e.a] != usize::MAX && remap[e.b] != usize::MAX)
        .map(|e| Edge {
            a: remap[e.a],
            b: remap[e.b],
            ..e
        })
        .collect();
    Cast {
        people: kept,
        edges,
        relationship: None,
        version: SCAN_VERSION,
    }
}

/// A cheap integer scramble (SplitMix64 finaliser, truncated) — a deterministic
/// stand-in for a random draw so a rescan reproduces the same evidence set,
/// which the cache relies on.
fn scramble(mut x: u64) -> u64 {
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d049bb133111eb);
    x ^ (x >> 31)
}

fn clip110(s: &str) -> String {
    let mut t: String = s.chars().take(110).collect();
    if t.len() < s.len() {
        t.push('…');
    }
    t
}

/// A uniform sample of at most [`MAX_EVIDENCE`] sentences by reservoir sampling.
/// The first [`MAX_EVIDENCE`] fill it; each later sentence replaces a
/// random-but-deterministic slot with the correct probability, so the kept set
/// spreads across the whole book — an evolving bond is seen from its first scene
/// to its last, not just the opening run the collector meets first. `seen` is the
/// running count of distinct sentences considered (the sampling denominator).
#[derive(Default)]
struct Reservoir {
    items: Vec<(usize, String)>,
    seen: u32,
}

impl Reservoir {
    fn push(&mut self, ci: usize, sent: &str) {
        let sent = clip110(sent);
        if self.items.iter().any(|(_, t)| *t == sent) {
            return;
        }
        let j = self.seen;
        self.seen += 1;
        if self.items.len() < MAX_EVIDENCE {
            self.items.push((ci, sent));
            return;
        }
        let r = (scramble(j as u64) % (j as u64 + 1)) as usize;
        if r < MAX_EVIDENCE {
            self.items[r] = (ci, sent);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::book::Span;

    fn story() -> String {
        let block = concat!(
            "　　「师妹，前面有妖兽。」林远说道。\n",
            "　　苏如雪答道：「师兄放心，如雪省得。」\n",
            "　　林远道：「小心。」\n",
            "　　「知道了。」苏如雪笑道。\n",
            "　　老者道：「小辈滚出去！」\n",
            "　　林远淡淡道:「前辈息怒。」\n",
            "　　苏如雪看着林远问道：「疼吗？」\n",
            "　　听见这话，苏如雪问道：「当真？」\n",
            "　　如雪道：「嗯。」\n",
            "　　林远把苏如雪拉到身后，说道：「师妹，退后。」\n",
        );
        block.repeat(4)
    }

    /// Two chapters built by hand: the chapter detector needs a real book's
    /// worth of titles to commit, and this test is about the cast, not about
    /// title detection.
    fn scan_story() -> Cast {
        let half = story();
        let text = half.repeat(2);
        let chapters: Vec<Chapter> = (0..2)
            .map(|i| Chapter {
                index: i,
                number: None,
                title: format!("第{}章", i + 1),
                span: Span {
                    start: i * half.len(),
                    end: (i + 1) * half.len(),
                },
                body_start: i * half.len(),
            })
            .collect();
        scan(&text, &chapters, 2)
    }

    #[test]
    fn dialogue_names_survive_and_formulas_do_not() {
        let cast = scan_story();
        let names: Vec<&str> = cast.people.iter().map(|p| p.name.as_str()).collect();
        assert!(names.contains(&"林远"), "got {names:?}");
        assert!(names.contains(&"苏如雪"), "got {names:?}");
        // 老者 is a role, 淡淡 is an adverb, 远淡淡 is a crossing fragment,
        // and no pronoun ever speaks its way into the cast.
        for bad in ["老者", "淡淡", "远淡淡", "他", "林远淡淡"] {
            assert!(
                !names.contains(&bad),
                "{bad} should not be a person: {names:?}"
            );
        }
    }

    #[test]
    fn a_given_name_folds_into_its_full_name() {
        let cast = scan_story();
        let su = cast
            .people
            .iter()
            .find(|p| p.name == "苏如雪")
            .expect("苏如雪");
        assert_eq!(su.aliases, vec!["如雪".to_string()]);
        // And the bare name is not a second person.
        assert!(!cast.people.iter().any(|p| p.name == "如雪"));
    }

    #[test]
    fn who_stands_with_whom_carries_evidence_and_appellation() {
        let cast = scan_story();
        let lin = cast.people.iter().position(|p| p.name == "林远").unwrap();
        let su = cast.people.iter().position(|p| p.name == "苏如雪").unwrap();
        let e = cast
            .edges
            .iter()
            .find(|e| (e.a == lin && e.b == su) || (e.a == su && e.b == lin))
            .expect("edge 林远-苏如雪");
        assert!(e.weight > 0);
        assert!(
            e.hints.iter().any(|(w, _)| w == "师妹"),
            "hints: {:?}",
            e.hints
        );
        assert!(!e.evidence.is_empty());
        // 师妹/师兄 are same-sect terms: the rules label this edge with no model.
        assert_eq!(e.label.as_deref(), Some("同门"), "hints: {:?}", e.hints);
    }

    #[test]
    fn presence_is_tracked_per_chapter() {
        let cast = scan_story();
        let lin = cast.people.iter().find(|p| p.name == "林远").unwrap();
        assert_eq!(lin.chapters, 2);
        assert_eq!(lin.first_chapter, 0);
    }

    #[test]
    fn frequent_two_character_name_can_survive_a_slightly_weak_island_rate() {
        let real_name = Stat {
            count: 1000,
            boundary: 350,
            boundary_r: 120,
            object: 80,
            ..Stat::default()
        };
        assert!(strong_two_char_name("张雅", &real_name, 1000));

        let prose_fragment = Stat {
            count: 1000,
            boundary: 350,
            boundary_r: 120,
            object: 5,
            ..Stat::default()
        };
        assert!(!strong_two_char_name("张开", &prose_fragment, 1000));
    }
}

#[cfg(test)]
mod binding {
    use super::*;

    fn bind(sent: &str, names: &[&str]) -> Vec<&'static str> {
        bind_n(sent, names, 2)
    }

    fn bind_n(sent: &str, names: &[&str], crowd: usize) -> Vec<&'static str> {
        let present: Vec<&'static str> = APPELLATION
            .iter()
            .copied()
            .filter(|w| sent.contains(w))
            .collect();
        bound_hints(sent, &present, names, crowd)
    }

    #[test]
    fn a_possessive_names_a_third_party_not_the_pair() {
        // 剑来 ch.222 — this one sentence labelled 崔瀺 ↔ 李槐 亲子, because the
        // old bag-of-words counted 爹 and 爷爷 as if the two were kin to *each
        // other*. They are each kin to someone absent.
        let s = "就还有李槐他爹，更别提还有崔瀺的爷爷";
        assert!(bind(s, &["崔瀺", "李槐"]).is_empty());
    }

    #[test]
    fn a_stranger_in_a_possessive_says_nothing_either() {
        // 剑来 ch.55 — 爷爷 belongs to 杨家铺子, and this labelled the book's two
        // leads 亲子.
        let s = "很小的时候，杨家铺子的杨爷爷就曾经叮嘱过我";
        assert!(bind(s, &["陈平安", "宁姚"]).is_empty());
    }

    #[test]
    fn a_copula_makes_a_possessive_speak_about_the_pair() {
        // 剑来 ch.365 — the possessive is 杨老头的, but 郑大风是 makes it a claim
        // about the two of them, and this is a correct 师徒.
        let s = "郑大风是杨老头的嫡传弟子！";
        assert_eq!(bind(s, &["郑大风", "杨老头"]), vec!["弟子"]);
    }

    #[test]
    fn direct_address_is_the_strongest_position() {
        assert_eq!(bind("“师父，我错了。", &["陈平安", "裴钱"]), vec!["师父"]);
    }

    #[test]
    fn apposition_says_what_one_person_is_not_what_the_two_are() {
        // 剑来 ch.2 — 刘羡阳 really is a 徒弟, of 老姚, who is not in this pair.
        // Reading apposition as a pair bond made 陈平安 his master.
        let s = "嫌弃少年没有悟性，远远不如大徒弟刘羡阳";
        assert!(bind(s, &["陈平安", "刘羡阳"]).is_empty());
    }

    #[test]
    fn a_dropped_de_is_still_a_possessive() {
        // 剑来 ch.288 — 宁姚爹娘 is 宁姚's parents. Read as apposition it made the
        // book's two leads 亲子.
        let s = "陈平安同样一句无心之言，是对宁姚爹娘说的那句";
        assert!(bind(s, &["陈平安", "宁姚"]).is_empty());
    }

    #[test]
    fn address_needs_the_pair_to_be_alone_in_the_sentence() {
        // With a third person present there is no telling who is being called
        // 师父, and the hint would be handed to all three pairs at once.
        let s = "“师父，我错了。";
        assert_eq!(bind_n(s, &["陈平安", "裴钱"], 2), vec!["师父"]);
        assert!(bind_n(s, &["陈平安", "裴钱"], 3).is_empty());
    }

    #[test]
    fn a_loose_appellation_in_the_prose_is_dropped() {
        // 朋友 floating in narration, bound to neither — exactly what used to
        // flood every edge in a dialogue-heavy book.
        let s = "两人在街角分开，稚圭接过水桶去往泥瓶巷，朋友之间总是如此";
        assert!(bind(s, &["稚圭", "刘羡阳"]).is_empty());
    }

    #[test]
    fn a_compound_never_fakes_an_address() {
        // 姑娘 must not read as a vocative 娘, and 骂娘 must not read as kin.
        // Both are why 娘 left APPELLATION, but the binding holds regardless.
        for s in ["“姑娘，请留步。", "阮邛莫名其妙骂娘起来"] {
            assert!(!bind(s, &["阮邛", "齐静春"]).iter().any(|w| *w == "娘"));
        }
    }
}
