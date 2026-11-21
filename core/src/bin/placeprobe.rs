//! Place-graph bench: what the place rules find in each book of a folder.
//!
//! Usage: placeprobe <file-or-dir> [chapters]
//!   DF=1    one line per book: every seeded candidate (for the generic list)
//!   RAW=1   the candidates with their counts and why each was turned away
//!   JSON=dir  write one <book>.json per book for the viewer
//!   TIME=1  how long the cast and the places took

use novel_core::{book, decode, fingerprint::fingerprint, places};

fn main() {
    let mut args = std::env::args().skip(1);
    let target = args.next().expect("usage: placeprobe <file-or-dir> [chapters]");
    let upto: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(100000);
    let p = std::path::PathBuf::from(&target);
    let mut books: Vec<std::path::PathBuf> = if p.is_dir() {
        std::fs::read_dir(&p)
            .expect("read dir")
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "txt"))
            .collect()
    } else {
        vec![p]
    };
    books.sort();
    for path in books {
        let title = path.file_stem().unwrap().to_string_lossy().to_string();
        let raw = std::fs::read(&path).expect("read file");
        let d = decode::decode(&raw);
        let fp = fingerprint(d.encoding, &d.text);
        let b = book::build(&d.text, &fp);
        let n = upto.min(b.chapters.len());
        if std::env::var("DF").is_ok() {
            let c = places::candidate_stats(&d.text, &b.chapters, n);
            let names: Vec<&str> = c
                .iter()
                .filter(|(_, s)| s.seeded >= 2 && s.count >= 5)
                .map(|(n, _)| n.as_str())
                .collect();
            println!("{}", names.join(" "));
            continue;
        }
        let t0 = std::time::Instant::now();
        let ranked: Vec<(String, Vec<String>)> = novel_core::cast::scan_ranked(&d.text, &b.chapters, n)
            .into_iter()
            .map(|p| (p.name, p.aliases))
            .collect();
        let t1 = t0.elapsed();
        let atlas = places::scan_ranked(&d.text, &b.chapters, n, &ranked);
        if std::env::var("TIME").is_ok() {
            eprintln!("cast {:?} places {:?}", t1, t0.elapsed() - t1);
        }
        if let Ok(dir) = std::env::var("JSON") {
            let titles: Vec<&str> = b.chapters[..n].iter().map(|c| c.title.as_str()).collect();
            let v = serde_json::json!({ "book": title, "chapters": titles, "atlas": atlas });
            std::fs::write(format!("{dir}/{title}.json"), v.to_string()).expect("write json");
        }
        println!("== {title} · {n} 章 · {} 处", atlas.places.len());
        let name = |i: usize| atlas.places[i].name.as_str();
        for (i, pl) in atlas.places.iter().enumerate().take(25) {
            println!(
                "{:>2}. {:<8} 提及{:>5} 章{:>4} 场景{:>4} 首{:>4}{}",
                i + 1,
                pl.name,
                pl.mentions,
                pl.chapters,
                pl.settings,
                pl.first_chapter + 1,
                pl.parent.map(|p| format!(" · 属 {}", name(p))).unwrap_or_default()
            );
        }
        println!("-- 阶段");
        for s in &atlas.stages {
            let spots: Vec<String> = s.spots.iter().map(|(p, k)| format!("{}{}", name(*p), k)).collect();
            println!("第{:>4}–{:>4}章 {:<8} {}", s.from + 1, s.to + 1, name(s.area), spots.join(" "));
        }
        println!();
    }
}
