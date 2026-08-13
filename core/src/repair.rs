//! Hard-wrap repair: old TXT exports break every paragraph into fixed-width
//! physical lines. The repair happens where paragraphs are *presented*, never
//! in the text itself — byte offsets into the decoded text stay valid, and the
//! original file is never touched.

/// Characters that end a Chinese paragraph with confidence. Narrower than the
/// fingerprint's PARAGRAPH_END on purpose: a colon or a dash mid-paragraph is
/// common, and treating it as an end would shred rewrapped paragraphs at every
/// line of dialogue.
pub const STRONG_END: &[char] = &['。', '！', '？', '…', '”', '’', '』', '」', '）', '】'];

/// Does this physical line continue on the next one? Only a line that was cut
/// by the wrap width says yes: it runs the full width and stops without a
/// paragraph-ending character. A short line ended because the paragraph did.
pub fn continues(line: &str, width: usize) -> bool {
    let t = line.trim_end();
    let n = t.chars().count();
    n + 1 >= width && !t.chars().last().is_some_and(|c| STRONG_END.contains(&c))
}

/// Append a continuation to a paragraph. Chinese joins seamlessly; two ASCII
/// words meeting at the cut need the space the wrap swallowed.
pub fn join(para: &mut String, next: &str) {
    let a = para
        .chars()
        .last()
        .is_some_and(|c| c.is_ascii_alphanumeric());
    let b = next
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric());
    if a && b {
        para.push(' ');
    }
    para.push_str(next);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_width_line_without_terminator_continues() {
        // A line cut mid-sentence at exactly the wrap width.
        let l = "他望着远处的山峦，心中忽然涌起一股说不出的情绪，仿佛那些年少时的梦";
        assert!(continues(l, l.chars().count()));
    }

    #[test]
    fn short_line_is_a_paragraph_end() {
        assert!(!continues("想又回来了", 35));
    }

    #[test]
    fn full_width_line_with_terminator_ends() {
        let l = "他望着远处的山峦，心中忽然涌起一股说不出的情绪，仿佛那些梦回来了。";
        assert!(!continues(l, l.chars().count()));
    }

    #[test]
    fn off_by_one_width_still_continues() {
        // Mixed ASCII makes wrapped lines land one short of the mode width.
        let l = "他打开了那台老旧的IBM电脑，屏幕上闪过一行行绿色的字符，那是他第一";
        assert!(continues(l, l.chars().count() + 1));
    }

    #[test]
    fn join_inserts_space_only_between_ascii_words() {
        let mut p = String::from("梦");
        join(&mut p, "想");
        assert_eq!(p, "梦想");
        let mut p = String::from("the old IBM");
        join(&mut p, "machine");
        assert_eq!(p, "the old IBM machine");
    }
}
