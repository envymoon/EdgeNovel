//! Print the coarse narrative-focus labels for local books.
//!
//! Usage: focusprobe <book.txt> [book.txt...]

use novel_core::{book, decode, fingerprint, focus};
use std::path::Path;

fn main() {
    let paths: Vec<String> = std::env::args().skip(1).collect();
    assert!(
        !paths.is_empty(),
        "usage: focusprobe <book.txt> [book.txt...]"
    );
    for path in paths {
        let raw = std::fs::read(&path).expect("read book");
        let decoded = decode::decode(&raw);
        let fp = fingerprint::fingerprint(decoded.encoding, &decoded.text);
        let parsed = book::build(&decoded.text, &fp);
        let result = focus::analyze(&decoded.text, &parsed.chapters);
        let name = Path::new(&path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(&path);
        println!(
            "{name}\t事业线={}\t感情线={}\t升级线={}",
            result.career.zh(),
            result.romance.zh(),
            result.growth.zh()
        );
    }
}
