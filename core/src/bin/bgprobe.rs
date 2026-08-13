//! Measuring bench for 人物背景: what the scan actually hands the model.
//!
//! The background summary can only be as good as the forty sentences it is
//! written from, and those are picked by a word list ([`BACKGROUND_CUES`]).
//! A word list is a guess until you read what it caught — so print it, before
//! blaming the model for a summary that says nothing.
//!
//! Usage: bgprobe <book.txt> [chapters] [人名]

use novel_core::{book, cast, decode, fingerprint::fingerprint};

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args
        .next()
        .expect("usage: bgprobe <book.txt> [chapters] [人名]");
    let upto: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(300);
    let only = args.next();

    let raw = std::fs::read(&path).expect("read file");
    let d = decode::decode(&raw);
    let fp = fingerprint(d.encoding, &d.text);
    let b = book::build(&d.text, &fp);
    let n = upto.min(b.chapters.len());
    let c = cast::scan(&d.text, &b.chapters, n);

    for p in &c.people {
        if only.as_deref().is_some_and(|want| want != p.name) {
            continue;
        }
        println!(
            "== {} · {} 次 · 采到 {} 句",
            p.name,
            p.mentions,
            p.evidence.len()
        );
        for (ci, sent) in &p.evidence {
            println!("  [{:>4}] {sent}", ci + 1);
        }
        println!();
    }
}
