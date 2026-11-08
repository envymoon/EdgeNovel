//! What 文本整理 finds in every book of a folder: each group, how many lines,
//! whether it starts ticked, and a few of its lines. For judging a rule by the
//! whole shelf rather than one book.
//!
//! Usage: cleanprobe <corpus-dir> [samples]

use novel_core::{book, cleanup, decode, fingerprint::fingerprint};

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args.next().expect("cleanprobe <corpus-dir> [samples]");
    let samples: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or(3);
    let mut books: Vec<std::path::PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("读不到 {dir}：{e}"))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "txt"))
        .collect();
    books.sort();
    for path in books {
        let raw = std::fs::read(&path).expect("read file");
        let d = decode::decode(&raw);
        let fp = fingerprint(d.encoding, &d.text);
        let b = book::build(&d.text, &fp);
        let t = std::time::Instant::now();
        let groups = cleanup::find(&d.text, &b.chapters);
        println!(
            "== {} · {} 章 · {} ms",
            path.file_name().unwrap().to_string_lossy(),
            b.chapters.len(),
            t.elapsed().as_millis()
        );
        for g in &groups {
            println!(
                "  [{}] {} · {} · {} 处",
                if g.checked { "x" } else { " " },
                g.kind.zh(),
                g.label.chars().take(40).collect::<String>(),
                g.items.len()
            );
            let step = (g.items.len() / samples.max(1)).max(1);
            for f in g.items.iter().step_by(step).take(samples) {
                let line = &d.text[f.line.clone()];
                let shown = if f.whole {
                    format!("整行 {}", line.trim())
                } else {
                    let cut: Vec<&str> = f.cuts.iter().map(|r| &d.text[r.clone()]).collect();
                    format!("删 {:?} ← {}", cut, line.trim())
                };
                println!("      {}", shown.chars().take(120).collect::<String>());
            }
        }
    }
}
