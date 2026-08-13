//! Guessing a book's title and author from a file that was never meant to say.
//!
//! Downloaded Chinese TXT files are named things like
//! `元尊(精校版全本)TXT下载_爱下电子书.txt`. Nothing here needs a model: the
//! noise is a small, closed set of site names and format words, and the signal
//! is what survives removing them.

use crate::is_indented;

/// Bracketed asides and the site-boilerplate words inside them. Removing the
/// brackets first is what makes the word list short enough to be honest.
const NOISE: &[&str] = &[
    "精校版",
    "精校",
    "校对版",
    "全本",
    "全集",
    "完本",
    "完结",
    "下载",
    "免费",
    "TXT",
    "txt",
    "Txt",
    "电子书",
    "小说网",
    "手打",
    "整理",
    "分享",
    "最新章节",
    "无弹窗",
    "在线阅读",
    "未删减",
    "修订版",
    "典藏版",
];

fn strip_noise(mut s: String) -> String {
    // Anything inside brackets in a downloaded file name is site decoration.
    for (open, close) in [
        ('(', ')'),
        ('（', '）'),
        ('[', ']'),
        ('【', '】'),
        ('《', '》'),
    ] {
        while let (Some(a), Some(z)) = (s.find(open), s.find(close)) {
            if a < z && open != '《' {
                s.replace_range(a..z + close.len_utf8(), "");
            } else {
                break;
            }
        }
    }
    for n in NOISE {
        s = s.replace(n, "");
    }
    s.trim_matches(|c: char| c.is_whitespace() || "_-·—、,，.".contains(c))
        .to_string()
}

fn from_filename(path: &str) -> String {
    let stem = path
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
        .rsplit_once('.')
        .map(|(a, _)| a)
        .unwrap_or(path);
    // `作者：xxx` and `by xxx` sometimes ride along in the file name.
    let cut = stem.split(['_', '-']).next().unwrap_or(stem);
    let cleaned = strip_noise(cut.to_string());
    if cleaned.is_empty() {
        strip_noise(stem.to_string())
    } else {
        cleaned
    }
}

/// `作者：季越人` / `作者:天蚕土豆` / `『元尊/作者:天蚕土豆』`
fn author_from(line: &str) -> Option<String> {
    let i = line.find("作者")?;
    let rest = &line[i + "作者".len()..];
    // A label, not a mention: "作者" must be followed by a separator. Without
    // this, "正文没有作者字样" yields an author named 字样.
    if !rest.starts_with([':', '：', ' ', '\u{3000}']) {
        return None;
    }
    let rest = rest.trim_start_matches([':', '：', ' ', '\u{3000}']);
    let name: String = rest
        .chars()
        .take_while(|c| !"』」】）)/\\|,，、 \u{3000}".contains(*c))
        .collect();
    let name = name.trim();
    (!name.is_empty() && name.chars().count() <= 20).then(|| name.to_string())
}

pub struct Meta {
    pub title: String,
    pub author: Option<String>,
}

/// The first flush lines of a book are its front matter, where the title and
/// author usually are. Body text is indented, so it is excluded for free.
pub fn extract(path: &str, text: &str) -> Meta {
    let head: Vec<&str> = text
        .split('\n')
        .take(40)
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();

    let author = head.iter().find_map(|l| author_from(l));

    // Prefer a title stated in the file over one inferred from the file name,
    // but only when the file name agrees — otherwise the reader renamed the file
    // on purpose and we should respect that.
    let from_file = from_filename(path);
    let title = text
        .split('\n')
        .take(40)
        .filter(|l| !is_indented(l))
        .map(|l| l.trim())
        .find(|l| !l.is_empty() && from_file.contains(*l) && l.chars().count() >= 2)
        .map(|l| l.to_string())
        .unwrap_or(from_file);

    Meta { title, author }
}

/// A stable colour for a text-only cover. Same book, same colour, forever.
/// Hue from the title; the muted saturation and lightness are fixed, because a
/// bookshelf of randomly saturated covers looks like a warning screen.
pub fn cover_hue(title: &str) -> u16 {
    let mut h: u32 = 2166136261;
    for b in title.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    (h % 360) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_download_site_names() {
        assert_eq!(
            from_filename(r"C:\books\元尊(精校版全本)TXT下载.txt"),
            "元尊"
        );
        assert_eq!(from_filename("/x/玄鉴仙族.txt"), "玄鉴仙族");
        assert_eq!(from_filename("斗破苍穹【完结】_爱下电子书.txt"), "斗破苍穹");
    }

    #[test]
    fn finds_author() {
        assert_eq!(
            author_from("『元尊/作者:天蚕土豆』").as_deref(),
            Some("天蚕土豆")
        );
        assert_eq!(author_from("作者：季越人").as_deref(), Some("季越人"));
        assert_eq!(author_from("正文没有作者字样"), None);
    }

    #[test]
    fn title_from_file_content_when_it_agrees() {
        let m = extract(
            "/x/元尊(全本).txt",
            "元尊\n作者：天蚕土豆\n\u{3000}\u{3000}正文\n",
        );
        assert_eq!(m.title, "元尊");
        assert_eq!(m.author.as_deref(), Some("天蚕土豆"));
    }
}
