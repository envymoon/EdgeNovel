//! Coarse narrative focus for the pre-reading report.
//!
//! This deliberately returns five words, never percentages. A romance scene can
//! also advance a mission and a power breakthrough, so the three dimensions are
//! independent rather than slices of a pie. Rules count explicit local events;
//! both repetition and chapter spread matter, which stops one glossary-heavy
//! chapter from making a whole book look upgrade-heavy.

use crate::book::Chapter;
use crate::chunk;

/// Bump when rules or level thresholds change so stored estimates are rebuilt.
pub const FOCUS_VERSION: i64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusLevel {
    VeryLittle,
    Little,
    Medium,
    Much,
    VeryMuch,
}

impl FocusLevel {
    pub fn zh(self) -> &'static str {
        match self {
            Self::VeryLittle => "很少",
            Self::Little => "较少",
            Self::Medium => "中等",
            Self::Much => "较多",
            Self::VeryMuch => "很多",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NarrativeFocus {
    pub career: FocusLevel,
    pub romance: FocusLevel,
    pub growth: FocusLevel,
}

#[derive(Default)]
struct SignalCount {
    events: usize,
    active_chapters: usize,
}

fn any(text: &str, words: &[&str]) -> bool {
    words.iter().any(|word| text.contains(word))
}

fn false_romance(text: &str) -> bool {
    any(
        text,
        &[
            "喜欢吃",
            "爱吃",
            "爱喝",
            "夫妻肺片",
            "亲吻大地",
            "爱情小说",
            "爱情电影",
        ],
    )
}

fn romance_event(text: &str) -> bool {
    let direct = any(
        text,
        &[
            "表白",
            "告白",
            "求婚",
            "成亲",
            "成婚",
            "婚礼",
            "退婚",
            "悔婚",
            "分手",
            "失恋",
            "亲吻",
            "接吻",
            "拥吻",
            "牵手",
            "十指相扣",
            "依偎",
            "吃醋",
            "心动",
            "暗恋",
            "倾心",
            "钟情",
        ],
    );
    let relation = any(
        text,
        &[
            "未婚妻",
            "未婚夫",
            "恋人",
            "情侣",
            "夫妻",
            "道侣",
            "心上人",
            "意中人",
            "感情",
        ],
    );
    let change = any(
        text,
        &[
            "喜欢",
            "爱上",
            "嫁给",
            "娶她",
            "娶你",
            "暧昧",
            "争吵",
            "误会",
            "确认关系",
            "在一起",
        ],
    );
    (direct || (relation && change)) && !(false_romance(text) && !direct)
}

fn growth_event(text: &str) -> bool {
    let false_hit = any(
        text,
        &["突破房门", "突破重围", "系统升级维护", "升级版", "高级酒店"],
    );
    let direct = any(
        text,
        &[
            "破境",
            "晋级",
            "进阶",
            "升阶",
            "修为提升",
            "修为大涨",
            "实力大增",
            "实力提升",
            "战力提升",
            "等级提升",
            "境界提升",
            "获得新技能",
            "觉醒能力",
            "觉醒异能",
            "炼化成功",
            "修炼有成",
        ],
    );
    let power = any(
        text,
        &[
            "修炼",
            "闭关",
            "境界",
            "修为",
            "功法",
            "灵力",
            "异能",
            "技能",
            "等级",
            "品阶",
            "战力",
            "经验值",
            "属性点",
            "天赋",
            "血脉",
            "剑意",
            "神通",
        ],
    );
    let progress = any(
        text,
        &[
            "突破", "提升", "增长", "精进", "变强", "掌握", "获得", "领悟", "觉醒", "炼化", "修成",
            "升级", "晋升",
        ],
    );
    direct || (power && progress && !false_hit)
}

fn career_event(text: &str) -> bool {
    if any(text, &["创业", "升职", "夺冠", "登基", "破案", "结案"]) {
        return true;
    }
    let organization = any(
        text,
        &[
            "公司", "集团", "企业", "生意", "店铺", "商会", "项目", "合同", "订单", "投资", "组织",
            "势力", "宗门", "军队", "团队", "领地", "城池", "基地",
        ],
    );
    let organization_action = any(
        text,
        &[
            "经营", "管理", "创建", "创办", "组建", "建立", "发展", "扩张", "建设", "治理", "招募",
            "训练", "整顿", "率领", "签订", "谈成", "拿下", "推进",
        ],
    );
    let mission = any(
        text,
        &[
            "任务", "计划", "战略", "行动", "调查", "案件", "真相", "凶手", "线索", "政务", "比赛",
            "作品", "电影", "专辑",
        ],
    );
    let mission_action = any(
        text,
        &[
            "执行", "完成", "推进", "部署", "调查", "追查", "侦查", "负责", "拍摄", "执导", "出版",
            "发布", "赢得",
        ],
    );
    let false_hit = any(
        text,
        &["公司楼下", "路过公司", "宗门遗址", "听说过这个组织"],
    );
    ((organization && organization_action) || (mission && mission_action)) && !false_hit
}

fn level_for(count: &SignalCount, chapters: usize) -> FocusLevel {
    if chapters == 0 || count.events == 0 {
        return FocusLevel::VeryLittle;
    }
    let chapters = chapters as f32;
    let events_per_chapter = count.events as f32 / chapters;
    let spread = count.active_chapters as f32 / chapters;
    // Repetition without spread is often a glossary or one isolated side arc;
    // spread without repetition is a handful of incidental mentions. Their
    // geometric mean requires both before a line earns a high label.
    let intensity = (events_per_chapter * spread).sqrt();
    if intensity < 0.025 {
        FocusLevel::VeryLittle
    } else if intensity < 0.07 {
        FocusLevel::Little
    } else if intensity < 0.15 {
        FocusLevel::Medium
    } else if intensity < 0.30 {
        FocusLevel::Much
    } else {
        FocusLevel::VeryMuch
    }
}

pub fn analyze(text: &str, chapters: &[Chapter]) -> NarrativeFocus {
    let mut career = SignalCount::default();
    let mut romance = SignalCount::default();
    let mut growth = SignalCount::default();

    for chapter in chapters {
        let chunks = chunk::chunk_body(text, chapter.body_start, chapter.span.end, 500);
        let mut chapter_career = false;
        let mut chapter_romance = false;
        let mut chapter_growth = false;
        for chunk in chunks {
            if career_event(&chunk.text) {
                career.events += 1;
                chapter_career = true;
            }
            if romance_event(&chunk.text) {
                romance.events += 1;
                chapter_romance = true;
            }
            if growth_event(&chunk.text) {
                growth.events += 1;
                chapter_growth = true;
            }
        }
        career.active_chapters += usize::from(chapter_career);
        romance.active_chapters += usize::from(chapter_romance);
        growth.active_chapters += usize::from(chapter_growth);
    }

    NarrativeFocus {
        career: level_for(&career, chapters.len()),
        romance: level_for(&romance, chapters.len()),
        growth: level_for(&growth, chapters.len()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_events_are_found_without_keyword_traps() {
        assert!(career_event("他组建团队并推进调查任务。"));
        assert!(romance_event("她终于向他表白，两人牵手离开。"));
        assert!(growth_event("闭关之后，他的修为提升并突破瓶颈。"));

        assert!(!career_event("他们只是路过公司楼下。"));
        assert!(!romance_event("她喜欢吃夫妻肺片。"));
        assert!(!growth_event("他突破房门冲了出去。"));
    }

    #[test]
    fn high_levels_require_repetition_and_spread() {
        assert_eq!(
            level_for(
                &SignalCount {
                    events: 1,
                    active_chapters: 1,
                },
                100
            ),
            FocusLevel::VeryLittle
        );
        assert_eq!(
            level_for(
                &SignalCount {
                    events: 50,
                    active_chapters: 40,
                },
                100
            ),
            FocusLevel::VeryMuch
        );
    }
}
