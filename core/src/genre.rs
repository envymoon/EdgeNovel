//! What kind of book is this? — answered by counting words, not by asking a model.
//!
//! This was calibrated against a model and the model lost, badly. Qwen3-0.6B,
//! shown seven chapters from each of eight real books and the thirteen 起点
//! categories to choose from, answered 仙侠 for nearly all of them — including a
//! Japanese-style school light novel. It is the same failure the landmine probe
//! found: a small model facing a wide closed choice stops reading and emits a
//! constant. The lexicon below got all eight right on the same evidence.
//!
//! So genre tagging needs no model, no download and no engine. It runs on a book
//! imported thirty seconds ago, offline, in the time it takes to read the file.
//!
//! The words are chosen to *discriminate*, not to describe. 修炼 appears in every
//! 玄幻 and every 仙侠 alike and is therefore worthless here; 金丹 and 渡劫 are
//! worth everything. Anything generic enough to show up in all of them (少女,
//! 同学, 大人) was measured polluting a real book's score and taken out.

/// The thirteen categories the Chinese web-novel world actually uses.
const LEXICON: &[(&str, &[&str])] = &[
    (
        "玄幻",
        &[
            "斗气",
            "武魂",
            "魂力",
            "源气",
            "神魂",
            "帝境",
            "圣境",
            "真元",
            "法则之力",
            "大帝",
            "本源",
        ],
    ),
    (
        "奇幻",
        &[
            "魔法",
            "法师",
            "骑士",
            "精灵",
            "矮人",
            "教廷",
            "德鲁伊",
            "魔王",
            "龙王",
            "血统",
            "屠龙",
            "炼金术",
        ],
    ),
    (
        "武侠",
        &[
            "江湖",
            "内力",
            "武林",
            "掌门",
            "轻功",
            "剑客",
            "内功",
            "镖局",
            "侠客",
            "武林盟主",
        ],
    ),
    (
        "仙侠",
        &[
            "修真", "筑基", "金丹", "元婴", "渡劫", "灵根", "道友", "洞府", "仙人", "法宝", "真人",
            "仙气", "飞升",
        ],
    ),
    (
        "都市",
        &[
            "手机", "微信", "公司", "老板", "小区", "地铁", "股票", "警局", "上班", "短信", "电梯",
            "总裁",
        ],
    ),
    (
        "现实",
        &[
            "工地",
            "打工",
            "下岗",
            "房贷",
            "工厂",
            "村支书",
            "农民工",
            "流水线",
        ],
    ),
    (
        "历史",
        &[
            "皇帝",
            "朝廷",
            "奏折",
            "太子",
            "丞相",
            "天子",
            "圣旨",
            "县令",
            "陛下",
            "将军府",
        ],
    ),
    (
        "军事",
        &[
            "部队",
            "连长",
            "步枪",
            "战场",
            "指挥部",
            "师长",
            "坦克",
            "特种兵",
            "子弹",
            "营长",
        ],
    ),
    (
        "游戏",
        &[
            "副本",
            "玩家",
            "装备",
            "公会",
            "技能栏",
            "属性面板",
            "经验值",
            "NPC",
            "刷怪",
            "爆装",
            "等级提升",
        ],
    ),
    (
        "体育",
        &[
            "比赛", "教练", "球队", "进球", "联赛", "球场", "赛季", "球迷",
        ],
    ),
    (
        "科幻",
        &[
            "星舰",
            "机甲",
            "星际",
            "赛博",
            "义体",
            "纳米",
            "人工智能",
            "基因",
            "虫族",
            "飞船",
            "智能核心",
            "改造人",
        ],
    ),
    (
        "悬疑灵异",
        &[
            "尸体", "凶手", "命案", "鬼魂", "阴气", "诡异", "灵异", "凶案", "法医", "冤魂",
        ],
    ),
    (
        "轻小说",
        &[
            "学园",
            "社团",
            "前辈",
            "学姐",
            "东京",
            "漫画",
            "轻音",
            "便当",
            "部长",
            "女仆",
            "校门口",
        ],
    ),
];

/// Below this rate the "winner" is noise: a handful of stray words in a million
/// characters says nothing about what the book is.
const FLOOR: f32 = 30.0;

/// A runner-up this close to the winner is not a runner-up. 龙族 is a school
/// story about monster hunters and scores 都市 544 / 奇幻 512 — calling it one or
/// the other would be picking a side the book itself does not pick.
const SECOND_SHARE: f32 = 0.5;

/// Every category, scored by hits per million characters — so a four-million
/// character epic cannot out-vote a short book on sheer volume.
pub fn scores(text: &str) -> Vec<(&'static str, f32)> {
    let chars = text.chars().count().max(1) as f32;
    let mut out: Vec<(&'static str, f32)> = LEXICON
        .iter()
        .map(|(g, words)| {
            let hits: usize = words.iter().map(|w| text.matches(w).count()).sum();
            (*g, hits as f32 * 1_000_000.0 / chars)
        })
        .collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1));
    out
}

/// One tag, or two when the book really is two things, or none when the text
/// does not say. Never more: a book that is "everything" is a book the reader
/// learns nothing about.
pub fn tags(text: &str) -> Vec<&'static str> {
    let scored = scores(text);
    let top = scored.first().map(|(_, s)| *s).unwrap_or(0.0);
    if top < FLOOR {
        return Vec::new();
    }
    scored
        .into_iter()
        .take(2)
        .filter(|(_, s)| *s >= (top * SECOND_SHARE).max(FLOOR))
        .map(|(g, _)| g)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clear_book_gets_one_tag() {
        let text = "他盘膝而坐，金丹已成，只待渡劫飞升。洞府外道友来访，取出法宝相赠。".repeat(20);
        assert_eq!(tags(&text), vec!["仙侠"]);
    }

    /// Two genres, genuinely. The real case is 龙族: a school story whose pupils
    /// hunt dragons.
    #[test]
    fn a_book_that_is_two_things_keeps_both() {
        let text = "他掏出手机，坐地铁去公司见老板。".repeat(20)
            + &"魔法与骑士的血统，屠龙者走进教廷。".repeat(20);
        let t = tags(&text);
        assert_eq!(t.len(), 2);
        assert!(t.contains(&"都市") && t.contains(&"奇幻"), "{t:?}");
    }

    /// Silence is an answer. A book whose words say nothing gets no tag rather
    /// than the least-bad guess — a wrong genre on the shelf is worse than none.
    #[test]
    fn text_that_says_nothing_gets_no_tag() {
        let text = "今天天气不错，他出门散步，看见一只猫。".repeat(50);
        assert!(tags(&text).is_empty());
    }

    /// Rates, not counts: a long book must not win on volume alone.
    #[test]
    fn a_long_book_does_not_outscore_a_short_one_on_length() {
        let short = "金丹渡劫飞升。".repeat(10);
        let long = short.clone() + &"今天天气不错，他出门散步。".repeat(500);
        let s = scores(&short)[0].1;
        let l = scores(&long)[0].1;
        assert!(l < s, "长书 {l} 应当被稀释，而不是压过短书 {s}");
    }
}
