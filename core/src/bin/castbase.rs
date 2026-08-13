//! The regression harness for name extraction: every book in a corpus folder,
//! its pruned top cast, frozen as one text file.
//!
//! Judging a rule change by staring at one book is how the rule layer got a
//! blocklist that deleted a protagonist. Any change to `cast.rs` gets run
//! through here first: if a book's cast moves, it has to be a move we can
//! defend, name by name.
//!
//! Usage:
//!   castbase <corpus-dir> [chapters]        — print the snapshot
//!   castbase <corpus-dir> [chapters] 校验   — diff against the frozen one
//!
//! Freeze it with:  castbase bad 300 > core/baseline/cast-top10.txt

use novel_core::{book, cast, decode, fingerprint::fingerprint};

const FROZEN: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/baseline/cast-top10.txt");

fn snapshot(dir: &str, upto: usize) -> String {
    let mut books: Vec<std::path::PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("读不到 {dir}：{e}"))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "txt"))
        .collect();
    books.sort();

    let mut out = String::new();
    for path in books {
        let raw = std::fs::read(&path).expect("read file");
        let d = decode::decode(&raw);
        let fp = fingerprint(d.encoding, &d.text);
        let b = book::build(&d.text, &fp);
        let n = upto.min(b.chapters.len());
        let c = cast::scan(&d.text, &b.chapters, n);

        out.push_str(&format!(
            "== {} · 前 {n} 章 · {} 人\n",
            path.file_name().unwrap().to_string_lossy(),
            c.people.len()
        ));
        for (i, p) in c.people.iter().enumerate() {
            let alias = if p.aliases.is_empty() {
                String::new()
            } else {
                format!(" · 别名 {}", p.aliases.join("、"))
            };
            out.push_str(&format!(
                "{:>3}. {:<10} {:>6} 次 · {:>4} 章 · 首现第 {:>4} 章{alias}\n",
                i + 1,
                p.name,
                p.mentions,
                p.chapters,
                p.first_chapter + 1
            ));
        }
        out.push('\n');
    }
    out
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args
        .next()
        .expect("usage: castbase <corpus-dir> [chapters] [校验]");
    let upto: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(300);
    let check = args.next().as_deref() == Some("校验");

    let now = snapshot(&dir, upto);
    if !check {
        print!("{now}");
        return;
    }

    let Ok(then) = std::fs::read_to_string(FROZEN) else {
        eprintln!("还没有基线：先跑 castbase {dir} {upto} > {FROZEN}");
        std::process::exit(2);
    };
    if then == now {
        println!("基线一致 ✓");
        return;
    }
    // Per-book, not per-line: one book losing a name shifts every line after it,
    // and a line-aligned diff would then report the whole corpus as changed.
    // What we need to judge a rule change is exactly "who left, who arrived".
    println!("基线有变：");
    let (a, b) = (by_book(&then), by_book(&now));
    for (title, was) in &a {
        let now = b.get(title).cloned().unwrap_or_default();
        let gone: Vec<&String> = was.iter().filter(|n| !now.contains(n)).collect();
        let came: Vec<&String> = now.iter().filter(|n| !was.contains(n)).collect();
        if gone.is_empty() && came.is_empty() {
            continue;
        }
        println!("  {title}  {} 人 → {} 人", was.len(), now.len());
        if !gone.is_empty() {
            println!(
                "    - {}",
                gone.iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join("、")
            );
        }
        if !came.is_empty() {
            println!(
                "    + {}",
                came.iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join("、")
            );
        }
    }
    std::process::exit(1);
}

/// Book title → the cast lines' name column (name plus any aliases, so an alias
/// quietly falling off a character still shows up as a change).
fn by_book(snap: &str) -> std::collections::BTreeMap<String, Vec<String>> {
    let mut out = std::collections::BTreeMap::new();
    let mut cur = String::new();
    for line in snap.lines() {
        if let Some(rest) = line.strip_prefix("== ") {
            cur = rest.split(" · ").next().unwrap_or(rest).to_string();
            out.entry(cur.clone()).or_insert_with(Vec::new);
        } else if let Some((_, rest)) = line.trim().split_once(". ") {
            let name = rest.split_whitespace().next().unwrap_or("").to_string();
            let alias = line
                .split_once("别名 ")
                .map(|(_, a)| format!("（{a}）"))
                .unwrap_or_default();
            out.entry(cur.clone())
                .or_insert_with(Vec::new)
                .push(format!("{name}{alias}"));
        }
    }
    out
}
