//! What 章间立绘 would draw for a book: one line per plate.
//!
//! Usage: plateprobe <book.txt> [every] [leads]

use novel_core::{book, cast, decode, fingerprint::fingerprint, interlude};

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: plateprobe <book.txt> [every] [leads]");
    let every: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(10);
    let n_leads: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(8);

    let raw = std::fs::read(&path).expect("read file");
    let d = decode::decode(&raw);
    let fp = fingerprint(d.encoding, &d.text);
    let b = book::build(&d.text, &fp);
    let t = std::time::Instant::now();
    let c = cast::scan(&d.text, &b.chapters, b.chapters.len());
    let scanned = t.elapsed();
    let leads: Vec<Vec<String>> = c
        .people
        .iter()
        .take(n_leads)
        .map(|p| std::iter::once(p.name.clone()).chain(p.aliases.iter().cloned()).collect())
        .collect();
    let t = std::time::Instant::now();
    let plates = interlude::plan(&d.text, &b.chapters, &leads, every);
    println!(
        "{} 章 · 人物 {:?} · 扫人物 {:?} · 规划 {:?} · {} 张",
        b.chapters.len(),
        leads.iter().map(|l| l[0].as_str()).collect::<Vec<_>>(),
        scanned,
        t.elapsed(),
        plates.len()
    );
    for p in &plates {
        let who = match p.who {
            interlude::Who::Girl(i) => format!("女 {}", leads[i][0]),
            interlude::Who::Boy(i) => format!("男 {}", leads[i][0]),
            interlude::Who::Nobody => "无人".into(),
        };
        let cues: Vec<&str> = p.cues.iter().map(|w| w.label).collect();
        println!("[{:>4}] {who:<10} {}", p.chapter + 1, cues.join(" "));
    }
}
