//! Which test killed which frequent candidate, across a corpus. A threshold in
//! `cast::select` is only as good as the corpus it was measured on; before one
//! moves, this lists everyone it currently kills and everyone it would let in.
//!
//! Usage: castverdict <corpus-dir> [chapters] [min-count]

use novel_core::{book, cast, decode, fingerprint::fingerprint};

fn pct(a: u32, b: u32) -> f32 {
    a as f32 * 100.0 / b.max(1) as f32
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args
        .next()
        .expect("usage: castverdict <corpus-dir> [chapters] [min-count]");
    let upto: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(usize::MAX);
    let floor: u32 = args.next().and_then(|a| a.parse().ok()).unwrap_or(120);

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
        let mut rows = cast::verdicts(&d.text, &b.chapters, upto);
        rows.retain(|r| r.count >= floor && r.variety && r.island);
        rows.sort_by(|x, y| y.count.cmp(&x.count));
        println!("== {}", path.file_name().unwrap().to_string_lossy());
        for r in rows {
            let verdict = if r.acted_upon { "活" } else { "死" };
            println!(
                "  {verdict} {:<8} {:>6} 次 · 独立 {:>6} · 左边界 {:>5.1}% · 右边界 {:>5.1}% · 受事 {:>5.1}%{}",
                r.name,
                r.count,
                r.standalone,
                pct(r.boundary, r.count),
                pct(r.boundary_r, r.standalone),
                pct(r.object, r.standalone),
                if r.full_name_shaped { " · 全名形" } else { "" }
            );
        }
    }
}
