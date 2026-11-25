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

/// The web-novel categories plus a literary fallback (`文学`).
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
            "灵力",
            "灵诀",
            "灵阵",
            "玄力",
            "玄气",
            "灵脉",
            "至尊",
            "妖兽",
            "灵兽",
            "神境",
            "圣者",
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
            "血统",
            "屠龙",
            "炼金术",
            "魔导师",
            "圣骑士",
            "魔杖",
            "巫师",
            "魔力",
            "龙族",
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
            "招式",
            "点穴",
        ],
    ),
    (
        "仙侠",
        &[
            "修真", "筑基", "金丹", "元婴", "渡劫", "灵根", "道友", "洞府", "仙人", "法宝", "真人",
            "仙气", "飞升", "化神", "结丹", "修士",
        ],
    ),
    (
        "都市",
        &[
            "手机", "微信", "公司", "老板", "小区", "地铁", "股票", "警局", "上班", "短信", "电梯",
            "总裁", "银行卡", "咖啡厅", "写字楼",
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
            "微臣",
            "臣妾",
            "御史",
            "翰林",
            "太监",
            "锦衣卫",
        ],
    ),
    (
        "军事",
        &[
            "部队",
            "连长",
            "步枪",
            "指挥部",
            "师长",
            "坦克",
            "特种兵",
            "营长",
            "手榴弹",
            "机枪",
            "军区",
            "冲锋枪",
            "炮弹",
            "团长",
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
            "血条",
            "技能点",
        ],
    ),
    (
        "体育",
        &[
            "比赛", "教练", "球队", "进球", "联赛", "球场", "赛季", "球迷", "裁判", "半场", "禁区",
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
            "光甲",
            "师士",
            "战舰",
            "星系",
            "激光",
            "能量罩",
        ],
    ),
    (
        "悬疑灵异",
        &[
            "凶手", "命案", "鬼魂", "阴气", "灵异", "凶案", "法医", "冤魂", "厉鬼", "案发现场",
            "尸检", "邪祟", "阴森", "鬼怪",
        ],
    ),
    (
        "轻小说",
        &[
            "学园",
            "社团",
            "学姐",
            "东京",
            "漫画",
            "轻音",
            "便当",
            "女仆",
            "二次元",
            "动漫",
            "秋叶原",
            "轻小说",
            "吐槽",
            "社长",
            "galgame",
            "攻略",
        ],
    ),
];

/// High-precision secondary subgenres. Evaluated independently from the 14
/// primary categories so they refine a book (e.g. `都市、官场`, `都市、鉴宝`,
/// `奇幻、克苏鲁`, `文学、青春校园`) without stealing primary votes.
const SUBGENRES: &[(&str, &[&str])] = &[
    (
        "官场",
        &[
            "市委", "县委", "省委", "常委会", "纪委", "组织部", "政绩", "副市长", "省长", "县长",
            "书记", "市长", "厅长", "干部",
        ],
    ),
    (
        "鉴宝",
        &[
            "古玩", "青花瓷", "捡漏", "翡翠", "赌石", "潘家园", "字画", "拍卖行", "瓷器", "真品",
            "赝品", "古董", "玉石", "鉴宝",
        ],
    ),
    (
        "医道",
        &[
            "门诊", "手术室", "急诊", "中医", "针灸", "病历", "脉象", "主治医师", "科室", "病房",
            "病人", "诊所", "药方", "医术",
        ],
    ),
    (
        "商战",
        &[
            "融资", "股权", "并购", "风投", "上市公司", "估值", "董事会", "IPO", "财报", "投资人",
            "资本", "控股", "市值", "风控",
        ],
    ),
    (
        "文娱",
        &[
            "票房", "导演", "剧本", "片场", "唱片", "专辑", "影帝", "综艺", "娱乐圈", "开机",
            "杀青", "剧组", "配角", "试镜",
        ],
    ),
    (
        "末世",
        &[
            "丧尸", "幸存者", "避难所", "基地市", "变异体", "晶核", "末日", "尸潮", "安全区",
            "进化者", "异能者", "感染者",
        ],
    ),
    (
        "诸天无限",
        &[
            "主神", "轮回者", "位面", "任务世界", "主线任务", "支线任务", "奖励点", "主神空间",
            "轮回空间", "穿梭",
        ],
    ),
    (
        "刑侦推理",
        &[
            "刑警", "嫌疑人", "尸检", "不在场证明", "案发现场", "重案组", "审讯室", "作案动机",
            "凶器", "刑侦", "法医", "目击者",
        ],
    ),
    (
        "克苏鲁",
        &[
            "非凡者", "序列", "旧日", "呓语", "不可名状", "邪神", "魔药", "失控", "诡秘",
            "占卜家", "非凡特性", "污染",
        ],
    ),
    (
        "青春校园",
        &[
            "高考", "高三", "晚自习", "班主任", "宿舍", "军训", "课间", "同学录", "教室", "操场",
            "月考", "同桌", "食堂",
        ],
    ),
    (
        "年代",
        &[
            "供销社", "粮票", "知青", "插队", "生产队", "公社", "大队长", "拖拉机", "国营厂",
            "布票", "工分", "下乡",
        ],
    ),
    (
        "古言宅斗",
        &[
            "嫡女", "庶女", "侯府", "后宅", "嫁妆", "夫君", "世子妃", "选秀", "侧妃", "姨娘",
            "祖母", "主母", "聘礼",
        ],
    ),
];

/// Literary / rural / era prose markers used only when no web-novel genre
/// crosses the floor — so 《草房子》《红瓦黑瓦》《青铜葵花》《黄金时代》 are
/// recognized as `文学` rather than misclassified by stray words.
const LITERARY_WORDS: &[&str] = &[
    "麦田",
    "芦苇",
    "炊烟",
    "田埂",
    "茅草",
    "知青",
    "插队",
    "生产队",
    "公社",
    "煤油灯",
    "瓦房",
    "河滩",
    "桑树",
    "稻田",
    "乡下",
    "暮色",
    "黄昏",
    "童年",
    "岁月",
    "村庄",
    "集市",
    "河堤",
    "草垛",
    "柳树",
    "院子",
    "胡同",
];

/// Cap each individual word's contribution (per million chars) so one
/// overloaded term (e.g. 太子 in 太子党, or 部长 in 官场) cannot drown out
/// a genre that matches many distinct discriminators.
const WORD_CAP: f32 = 160.0;

/// Below this effective score the "winner" is noise.
const FLOOR: f32 = 120.0;

/// Strict floor for secondary subgenres so stray mentions never attach a tag.
const SUB_FLOOR: f32 = 300.0;

/// A runner-up this close to the winner is kept as a genuine second tag.
const SECOND_SHARE: f32 = 0.55;

fn score_lexicon(
    text: &str,
    lexicon: &[(&'static str, &[&str])],
    min_distinct: usize,
    allow_two_cap: f32,
) -> Vec<(&'static str, f32)> {
    let chars = text.chars().count().max(1) as f32;
    let mut out: Vec<(&'static str, f32)> = lexicon
        .iter()
        .map(|(g, words)| {
            let mut capped = 0.0f32;
            let mut distinct = 0usize;
            for w in *words {
                let c = text.matches(w).count();
                if c > 0 {
                    let rate = c as f32 * 1_000_000.0 / chars;
                    capped += rate.min(WORD_CAP);
                    if rate >= 3.0 {
                        distinct += 1;
                    }
                }
            }
            let eff = if distinct < 2 || (distinct < min_distinct && capped < allow_two_cap) {
                0.0
            } else {
                capped * (0.55 + 0.1 * distinct.min(8) as f32)
            };
            (*g, eff)
        })
        .collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1));
    out
}

/// Every primary category, scored with per-word saturation and distinct-word
/// breadth so neither book length nor a single overloaded word can dominate.
pub fn scores(text: &str) -> Vec<(&'static str, f32)> {
    score_lexicon(text, LEXICON, 3, 260.0)
}

/// One or two tags: primary genre(s) (or `文学` fallback), refined with a
/// high-confidence subgenre when clearly present.
pub fn tags(text: &str) -> Vec<&'static str> {
    let scored = scores(text);
    let top = scored.first().map(|(_, s)| *s).unwrap_or(0.0);
    let mut primary: Vec<&'static str> = if top < FLOOR {
        let chars = text.chars().count().max(1) as f32;
        let mut lit_capped = 0.0f32;
        let mut lit_distinct = 0usize;
        for w in LITERARY_WORDS {
            let c = text.matches(w).count();
            if c > 0 {
                let rate = c as f32 * 1_000_000.0 / chars;
                lit_capped += rate.min(WORD_CAP);
                if rate >= 5.0 {
                    lit_distinct += 1;
                }
            }
        }
        if lit_distinct >= 3 && lit_capped >= 60.0 {
            vec!["文学"]
        } else {
            Vec::new()
        }
    } else {
        scored
            .iter()
            .take(2)
            .filter(|(_, s)| *s >= (top * SECOND_SHARE).max(FLOOR))
            .map(|(g, _)| *g)
            .collect()
    };

    let sub = score_lexicon(text, SUBGENRES, 3, f32::INFINITY);
    if let Some((sg, sg_score)) = sub.first().copied().filter(|(_, s)| *s >= SUB_FLOOR) {
        if primary.is_empty() {
            primary.push(sg);
        } else if primary.len() == 1 {
            primary.push(sg);
        } else if scored.get(1).map(|(_, s)| sg_score > *s).unwrap_or(false) {
            primary[1] = sg;
        }
    }
    primary
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
        let long = short.clone() + &"今天天气不错，他出门散步。".repeat(10_000);
        let s = scores(&short)[0].1;
        let l = scores(&long)[0].1;
        assert!(l < s, "长书 {l} 应当被稀释，而不是压过短书 {s}");
    }

    /// One overloaded word (e.g. 太子 in 太子党) must not beat a real genre
    /// supported by many distinct discriminators.
    #[test]
    fn single_overloaded_word_cannot_hijack_genre() {
        let text = "太子党的人聚在一起。".repeat(200)
            + &"他掏出手机发微信，坐地铁去公司找老板，小区电梯坏了，总裁在写字楼等他。".repeat(15);
        assert_eq!(tags(&text), vec!["都市"]);
    }

    /// Rural / era literary prose with stray words like 连长 or 球场 gets 文学,
    /// not 军事 or 轻小说.
    #[test]
    fn literary_prose_gets_literature_tag() {
        let filler = "村里的日子很安静，风吹过田野，人们沿着河边慢慢走回家。".repeat(400);
        let text = filler
            + "黄昏时分，麦田和芦苇荡飘起炊烟，知青插队在生产队住瓦房、点煤油灯，童年岁月留在村庄的河滩与院子里。".repeat(8).as_str()
            + "连长来过一次，孩子们在校门口和球场玩。";
        assert_eq!(tags(&text), vec!["文学", "年代"]);
    }

    #[test]
    fn high_confidence_subgenre_refines_primary_tag() {
        let urban_official = "他掏出手机发微信，坐地铁去公司找老板，写字楼电梯里偶遇总裁。".repeat(20)
            + &"市委常委会结束后，县委书记和副市长在组织部讨论政绩与纪委巡查。".repeat(20);
        assert_eq!(tags(&urban_official), vec!["都市", "官场"]);

        let lovecraft = "骑士和法师在教廷研究魔法与炼金术。".repeat(20)
            + &"非凡者服下魔药晋升序列，耳边响起旧日邪神的呓语，险些失控。".repeat(20);
        assert_eq!(tags(&lovecraft), vec!["奇幻", "克苏鲁"]);
    }
}
