//! Chase one book through every source that claims to have it, and print what
//! the engine actually got: how many chapters, and what the text looks like
//! before anyone cleans it up.
//!
//! This is the tool for the question "is the book broken, is the site broken, or
//! are we broken" — the only three possibilities, and they are told apart by
//! looking at the bytes, not by reasoning about the rules.
//!
//! Usage: bookprobe <library.db> <title> [how-many-sources]

use novel_core::source::{self, BookSource};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Mutex,
};

fn main() {
    let mut args = std::env::args().skip(1);
    let db = args
        .next()
        .expect("usage: bookprobe <library.db> <title> [n]");
    let title = args
        .next()
        .expect("usage: bookprobe <library.db> <title> [n]");
    let want: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(400);

    let conn = rusqlite::Connection::open(&db).expect("open db");
    let mut st = conn
        .prepare("SELECT name, json FROM sources WHERE ok IS NOT 0 ORDER BY RANDOM()")
        .unwrap();
    let rows: Vec<(String, String)> = st
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .filter_map(Result::ok)
        .take(want)
        .collect();

    println!("搜「{}」，{} 个未被淘汰的书源\n", title, rows.len());

    let queue = Mutex::new(rows.into_iter().collect::<Vec<_>>());
    let done = AtomicUsize::new(0);
    let out = Mutex::new(Vec::<String>::new());

    std::thread::scope(|s| {
        for _ in 0..16 {
            s.spawn(|| loop {
                let Some((name, json)) = queue.lock().unwrap().pop() else {
                    return;
                };
                done.fetch_add(1, Ordering::Relaxed);
                let Ok(src) = serde_json::from_str::<BookSource>(&json) else {
                    continue;
                };

                let hits = match source::search(&src, &title) {
                    Err(_) => continue,
                    Ok(h) => h,
                };
                // Only the book we asked for. A site that answers a search for
                // 异兽迷城 with 300 other books has not found it.
                let Some(hit) = hits.iter().find(|h| h.name.trim() == title.trim()) else {
                    continue;
                };

                let toc = match source::toc(&src, &hit.book_url) {
                    Err(e) => {
                        out.lock()
                            .unwrap()
                            .push(format!("── {name}\n   目录失败：{e}"));
                        continue;
                    }
                    Ok(t) => t,
                };
                let mut report = format!(
                    "── {name}\n   {} · 目录 {} 章 · 最新「{}」\n   书页 {}",
                    hit.author,
                    toc.len(),
                    toc.last().map(|c| c.title.as_str()).unwrap_or("-"),
                    hit.book_url,
                );
                if let Some(first) = toc.first() {
                    let after = toc.get(1).map(|c| c.url.as_str());
                    match source::content_next(&src, &first.url, after) {
                        Err(e) => report.push_str(&format!("\n   正文失败：{e}")),
                        Ok(t) => {
                            let sample: String = t.chars().take(220).collect();
                            report.push_str(&format!(
                                "\n   首章「{}」{} 字\n   ┃ {}",
                                first.title,
                                t.chars().count(),
                                sample.replace('\n', "\n   ┃ ")
                            ));
                        }
                    }
                }
                out.lock().unwrap().push(report);
            });
        }
    });

    let mut reports = out.into_inner().unwrap();
    reports.sort();
    for r in &reports {
        println!("{r}\n");
    }
    println!(
        "=== {} 个源里，{} 个真的有这本书",
        done.load(Ordering::Relaxed),
        reports.len()
    );
}
