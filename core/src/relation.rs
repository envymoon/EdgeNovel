//! Turning an edge's raw appellation hints into one relationship label from a
//! closed set — the rule half of the label layer.
//!
//! An appellation the text actually uses (师父, 老婆, 仇人) fixes a relationship
//! with more certainty than a 0.6B reading the scene ever could, and it costs
//! nothing. So the rules label every edge whose hints agree, and the model is
//! spent only on the residue: edges with no usable appellation, or a genuine
//! split. The label set is closed on purpose — the model, when it runs, must
//! answer with one of these or be discarded, exactly like moods and genres: a
//! missing label degrades to [`UNKNOWN`], a hallucinated one lies forever.

use std::collections::HashMap;

/// The closed relationship vocabulary. Coarse by design: a graph edge wants the
/// one bucket a reader would name at a glance, not a kinship-chart's precision.
pub const LABELS: &[&str] = &[
    "师徒",
    "亲子",
    "兄弟姐妹",
    "夫妻恋人",
    "同门",
    "朋友",
    "上下级",
    "敌对",
];

/// Not in [`LABELS`]: the answer for an edge nothing could decide. A real,
/// honest state — "they share scenes, the relationship isn't spelled out" — and
/// the graph renders it plainly rather than guessing.
pub const UNKNOWN: &str = "不明";

/// Which label an appellation implies, or None when the word is too ambiguous to
/// vote. Precision-first, and two kinds of ambiguity are silenced:
///
/// - Sworn vs blood / role vs courtesy: 兄弟 and 姐妹 mean sworn brotherhood as
///   often as blood (好兄弟, 好姐妹); 大哥 is an elder brother or a gang boss;
///   大人/公子/小姐/前辈 name a rank in one book and mere courtesy in another.
/// - Absolute-rank titles: 殿下/陛下/王爷 mark the *addressee's* station, which
///   pervades every scene that person is in — a lover, a rival and a servant all
///   say 殿下 to the prince. Measured on 元尊: a love interest's 殿下×10 buried
///   her 女友×2 and mislabelled the romance 上下级. So the pure titles stay
///   silent; only the position a subordinate names *of the pair* (属下, 卑职,
///   队长, 掌门) votes 上下级.
fn word_label(w: &str) -> Option<&'static str> {
    Some(match w {
        "师父" | "师尊" | "师傅" | "恩师" | "徒弟" | "徒儿" | "弟子" => "师徒",
        // 娘 and 妈 are excluded on purpose: as single chars they leak out of
        // 姑娘/娘子/老娘 and 妈的/妈呀 constantly (measured on 异兽迷城, where a
        // stray 妈×1 mislabelled two pairs of classmates 亲子). 爹/爸 barely
        // compound, so they stay.
        "爹" | "父亲" | "母亲" | "爸" | "儿子" | "女儿" | "闺女" | "爷爷" | "奶奶" | "外公"
        | "外婆" | "叔叔" | "舅舅" | "姑姑" => "亲子",
        "哥哥" | "二哥" | "兄长" | "弟弟" | "老弟" | "姐姐" | "妹妹" | "堂兄" | "表哥" | "表妹" => {
            "兄弟姐妹"
        }
        "夫人" | "娘子" | "相公" | "丈夫" | "妻子" | "媳妇" | "老婆" | "老公" | "夫君"
        | "未婚妻" | "未婚夫" | "男朋友" | "女朋友" | "男友" | "女友" | "恋人" => {
            "夫妻恋人"
        }
        "师兄" | "师弟" | "师姐" | "师妹" | "师叔" | "师伯" | "同门" | "同窗" => {
            "同门"
        }
        "同学" | "同事" | "战友" | "队友" | "搭档" | "朋友" | "好友" | "知己" => {
            "朋友"
        }
        "主公" | "主人" | "属下" | "部下" | "卑职" | "微臣" | "长老" | "掌门" | "宗主" | "队长"
        | "组长" | "老板" | "上司" | "老大" => "上下级",
        "仇人" | "仇家" | "死敌" | "对手" | "敌人" => "敌对",
        // 殿下 陛下 王爷 大人 少爷 老爷 公子 前辈 晚辈 小姐 大哥 兄弟 姐妹 老哥 …:
        // ambiguous (absolute rank, or sworn-vs-blood).
        _ => return None,
    })
}

/// Resolve an edge's appellation hints to one label, or None when they are
/// absent, all ambiguous, or genuinely split.
///
/// `hints` is (word, count). A label wins only on a clear majority of the
/// decisive weight: a 2-vs-2 split between 亲子 and 上下级 is not one
/// relationship stated two ways, it is two relationships in the same scenes, and
/// the rules must not pick. Those, and the hintless edges, are the model's job.
pub fn from_hints(hints: &[(String, u32)]) -> Option<&'static str> {
    let mut tally: HashMap<&'static str, u32> = HashMap::new();
    for (w, c) in hints {
        if let Some(l) = word_label(w) {
            *tally.entry(l).or_default() += *c;
        }
    }
    let total: u32 = tally.values().sum();
    if total == 0 {
        return None;
    }
    let (label, top) = tally.into_iter().max_by_key(|&(_, c)| c).unwrap();
    // Two guards, both re-measured on 剑来 after binding landed:
    //   · top >= 2 — one address still is not a relationship. Relaxing this to 1
    //     put 亲子 on the book's two leads (a single 爹), on a master and his
    //     servant, and on two childhood friends.
    //   · strict majority — a near-tie is two relationships, not one.
    (top >= 2 && top * 2 > total).then_some(label)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(pairs: &[(&str, u32)]) -> Vec<(String, u32)> {
        pairs.iter().map(|(w, c)| (w.to_string(), *c)).collect()
    }

    #[test]
    fn a_clear_appellation_decides() {
        assert_eq!(from_hints(&h(&[("师父", 3)])), Some("师徒"));
        assert_eq!(from_hints(&h(&[("老婆", 2)])), Some("夫妻恋人"));
        assert_eq!(from_hints(&h(&[("仇人", 2)])), Some("敌对"));
        assert_eq!(from_hints(&h(&[("师兄", 4)])), Some("同门"));
    }

    #[test]
    fn a_single_appellation_is_too_thin_to_fire() {
        // Binding (cast::bound_hints) cut the third-party leaks that used to
        // reach here, and it was tempting to relax this guard afterwards.
        // Measured on 剑来, relaxing it labelled the two leads 亲子 off one 爹,
        // a master and his servant 亲子, and two childhood friends 师徒. One
        // address is evidence; it is not yet a relationship.
        assert_eq!(from_hints(&h(&[("老婆", 1)])), None);
        assert_eq!(from_hints(&h(&[("同学", 1), ("朋友", 1)])), Some("朋友"));
    }

    #[test]
    fn leaky_single_char_kin_never_votes() {
        // 妈×1 + 娘×1 mislabelled two classmates 亲子; both are silenced now.
        assert_eq!(from_hints(&h(&[("妈", 1), ("娘", 1)])), None);
        // Non-leaky kin still decide.
        assert_eq!(from_hints(&h(&[("父亲", 2)])), Some("亲子"));
    }

    #[test]
    fn noise_is_outvoted_not_obeyed() {
        // 娘 leaks out of 姑娘/娘子; a wall of sibling terms still wins.
        assert_eq!(
            from_hints(&h(&[("哥哥", 5), ("妹妹", 3), ("娘", 1)])),
            Some("兄弟姐妹")
        );
    }

    #[test]
    fn a_real_tie_is_left_to_the_model() {
        // 亲子 2 vs 上下级 2: two relationships, not one. Rules abstain.
        assert_eq!(from_hints(&h(&[("爹", 2), ("队长", 2)])), None);
    }

    #[test]
    fn ambiguous_words_never_vote() {
        // 兄弟 (brotherhood vs blood), 大人 (rank vs courtesy): no rule label.
        assert_eq!(from_hints(&h(&[("兄弟", 3)])), None);
        assert_eq!(from_hints(&h(&[("大人", 4)])), None);
        assert_eq!(from_hints(&[]), None);
    }

    #[test]
    fn an_absolute_title_does_not_settle_a_relationship() {
        // 元尊: an attendant-love-interest's 殿下×10 must not bury 女友×2 into
        // 上下级. With the title silenced, the romance shows through.
        assert_eq!(
            from_hints(&h(&[("殿下", 10), ("女友", 2), ("朋友", 1)])),
            Some("夫妻恋人")
        );
        // A named subordinate position still votes 上下级.
        assert_eq!(from_hints(&h(&[("属下", 3)])), Some("上下级"));
    }

    #[test]
    fn every_rule_label_is_in_the_closed_set() {
        for w in ["师父", "爹", "哥哥", "老婆", "师兄", "朋友", "队长", "仇人"] {
            let l = word_label(w).unwrap();
            assert!(LABELS.contains(&l), "{w} → {l} not in LABELS");
        }
        assert!(!LABELS.contains(&UNKNOWN));
    }
}
