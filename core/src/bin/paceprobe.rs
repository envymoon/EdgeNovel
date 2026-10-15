//! Print the 节奏 score of every chapter, the way the app computes it, so the
//! curve can be checked against hand-labelled chapters or eyeballed for a book
//! that looks wrong.
//!
//! Usage: paceprobe <book.txt | corpus-dir>
//! Output: one line per chapter — file, index, score (or "-"), title.

use novel_core::{book, decode, fingerprint::fingerprint, pace};

fn main() {
    let arg = std::env::args().nth(1).expect("usage: paceprobe <book.txt | dir>");
    let path = std::path::PathBuf::from(&arg);
    let mut files: Vec<std::path::PathBuf> = if path.is_dir() {
        std::fs::read_dir(&path)
            .expect("read dir")
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "txt"))
            .collect()
    } else {
        vec![path]
    };
    files.sort();

    for f in files {
        let raw = std::fs::read(&f).expect("read file");
        let d = decode::decode(&raw);
        let fp = fingerprint(d.encoding, &d.text);
        let b = book::build(&d.text, &fp);
        let started = std::time::Instant::now();
        let s = pace::scores(&d.text, &b.chapters);
        let name = f.file_name().unwrap().to_string_lossy();
        eprintln!("{name}: {} 章，{:?}", b.chapters.len(), started.elapsed());
        for (c, s) in b.chapters.iter().zip(&s) {
            let score = s.map_or("-".to_string(), |v| format!("{v:.3}"));
            println!("{name}\t{}\t{score}\t{}", c.index, c.title.trim());
        }
    }
}
