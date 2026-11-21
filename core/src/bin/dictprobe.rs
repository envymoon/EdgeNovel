//! Builds the dictionary from a chinese-xinhua data folder and looks words up:
//! `dictprobe <data dir> <out.db> [word...]`.
use novel_core::dict;
use std::path::Path;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (data, out) = (Path::new(&a[1]), Path::new(&a[2]));
    if !out.exists() {
        let t = std::time::Instant::now();
        dict::build(&data.join("word.json"), &data.join("ci.json"), &data.join("idiom.json"), out).unwrap();
        eprintln!("built in {:?}, {} bytes", t.elapsed(), std::fs::metadata(out).unwrap().len());
    }
    for w in &a[3..] {
        for e in dict::lookup(out, w).unwrap() {
            println!("== {:?} {} [{}]\n{}\n-- {}\n-- {}", e.kind, e.word, e.pinyin, e.body, e.source, e.example);
        }
    }
}
