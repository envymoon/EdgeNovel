//! Measuring bench for one proposed feature: is a candidate ever the *object*
//! of an interaction? A person can be found, asked, talked with, given to; a
//! gesture word (抬手, 偏头) never is. Prints, for every member of the current
//! cast of every book in a corpus folder, how often it stands right after an
//! interaction preposition and right before 的 — so a threshold can be picked
//! from the corpus instead of from one book.
//!
//! Usage: castfeat <corpus-dir> [chapters]

use novel_core::{book, cast, decode, fingerprint::fingerprint};

/// Words that can only take a person (or a person-like thing) as their object.
const OBJECT_CUE: &[char] = &[
    '和', '与', '跟', '对', '给', '被', '让', '向', '替', '找', '问', '同', '陪',
];

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args
        .next()
        .expect("usage: castfeat <corpus-dir> [chapters]");
    let upto: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(300);

    let mut books: Vec<std::path::PathBuf> = std::fs::read_dir(&dir)
        .expect("read dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "txt"))
        .collect();
    books.sort();

    for path in books {
        let raw = std::fs::read(&path).expect("read file");
        let d = decode::decode(&raw);
        let fp = fingerprint(d.encoding, &d.text);
        let b = book::build(&d.text, &fp);
        let n = upto.min(b.chapters.len());
        let c = cast::scan(&d.text, &b.chapters, n);
        let body: String = b.chapters[..n]
            .iter()
            .map(|ch| &d.text[ch.body_start..ch.span.end])
            .collect::<Vec<_>>()
            .join("\n");

        println!("== {}", path.file_name().unwrap().to_string_lossy());
        for p in &c.people {
            let cjk = |c: char| ('\u{4e00}'..='\u{9fff}').contains(&c);
            let (mut total, mut obj, mut de, mut rb) = (0u32, 0u32, 0u32, 0u32);
            for (i, _) in body.match_indices(p.name.as_str()) {
                total += 1;
                if body[..i]
                    .chars()
                    .next_back()
                    .is_some_and(|c| OBJECT_CUE.contains(&c))
                {
                    obj += 1;
                }
                let right = body[i + p.name.len()..].chars().next().unwrap_or('\n');
                if right == '的' {
                    de += 1;
                }
                if !cjk(right) {
                    rb += 1;
                }
            }
            let pct = |x: u32| x * 100 / total.max(1);
            println!(
                "  {:<10} {:>6} 次 · 受事 {:>4} ({:>2}%) · 后接的 {:>2}% · 右边界 {:>3}%",
                p.name,
                total,
                obj,
                pct(obj),
                pct(de),
                pct(rb)
            );
        }
        println!();
    }
}
