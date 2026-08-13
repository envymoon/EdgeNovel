//! Why do chapters fail? Download reports a count, not a reason, and a count
//! cannot tell rate-limiting from a dead site from a rule that only works on
//! chapter one. This walks a real book on a real source with the real fetcher
//! and prints what every failure actually said.
//!
//! Usage: chapterprobe <library.db> <title> [source-name-substring] [how-many]

use novel_core::source::{self, BookSource};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Mutex,
};

fn main() {
    let mut args = std::env::args().skip(1);
    let db = args
        .next()
        .expect("usage: chapterprobe <db> <title> [source] [n]");
    let title = args
        .next()
        .expect("usage: chapterprobe <db> <title> [source] [n]");
    let want_src = args.next().unwrap_or_default();
    let sample: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(40);

    let conn = rusqlite::Connection::open(&db).expect("open db");
    let mut st = conn
        .prepare("SELECT name, json FROM sources WHERE ok IS NOT 0")
        .unwrap();
    let rows: Vec<(String, String)> = st
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|(n, _): &(String, String)| want_src.is_empty() || n.contains(&want_src))
        .collect();

    for (name, json) in rows {
        let Ok(src) = serde_json::from_str::<BookSource>(&json) else {
            continue;
        };
        let Ok(hits) = source::search(&src, &title) else {
            continue;
        };
        let Some(hit) = hits.iter().find(|h| h.name.trim() == title.trim()) else {
            continue;
        };
        let Ok(toc) = source::toc(&src, &hit.book_url) else {
            continue;
        };
        if toc.len() < 2 {
            continue;
        }

        println!("\n══ {name} · {} 章 · {}", toc.len(), hit.book_url);

        // Two different questions, two different samples. Spread across the book
        // asks "does this rule work everywhere" — it catches a site whose deep
        // chapters are paywalled. Consecutive, at download speed, asks "does
        // this site get sick of us" — and that one cannot be answered by a
        // gentle sample, because throttling only appears under load.
        let seq = std::env::args().any(|a| a == "seq");
        let picks: Vec<usize> = if seq {
            (0..sample.min(toc.len())).collect()
        } else {
            let step = (toc.len() / sample).max(1);
            (0..toc.len()).step_by(step).take(sample).collect()
        };
        let first_fail = Mutex::new(usize::MAX);

        let reasons: Mutex<HashMap<String, usize>> = Mutex::new(HashMap::new());
        let ok = AtomicUsize::new(0);
        let queue = Mutex::new(picks.clone());
        let started = std::time::Instant::now();

        // Four threads and a pacer: exactly what the downloader does. If a site
        // throttles, it has to be met at the same pace to be seen — and the
        // pacer's whole job is to make that stop mattering.
        let pacer = source::Pacer::new(&src);
        let raw = std::env::args().any(|a| a == "raw");
        std::thread::scope(|s| {
            for _ in 0..4 {
                s.spawn(|| loop {
                    let Some(i) = queue.lock().unwrap().pop() else {
                        return;
                    };
                    let after = toc.get(i + 1).map(|c| c.url.as_str());

                    let mut text = Err("没抓到".to_string());
                    for attempt in 0..5u32 {
                        if !raw {
                            pacer.wait();
                        }
                        text = match source::content_next(&src, &toc[i].url, after) {
                            Ok(t) if t.chars().count() >= 50 => Ok(t),
                            Ok(_) => Err("正文是空的".into()),
                            Err(e) => Err(e),
                        };
                        // `raw` reproduces the old, rude downloader: one try, no
                        // pacing. It is how the before/after gets measured.
                        if raw {
                            break;
                        }
                        match &text {
                            Ok(_) => break,
                            Err(e) if !source::is_throttled(e) => break,
                            Err(_) => {
                                let wait = pacer.back_off();
                                std::thread::sleep(wait * (attempt + 1));
                            }
                        }
                    }
                    match text {
                        Ok(_) => {
                            ok.fetch_add(1, Ordering::Relaxed);
                            pacer.ease();
                        }
                        Err(e) => {
                            *reasons.lock().unwrap().entry(e).or_default() += 1;
                            let mut f = first_fail.lock().unwrap();
                            *f = (*f).min(i);
                        }
                    }
                });
            }
        });

        let good = ok.load(Ordering::Relaxed);
        println!(
            "   抽查 {} 章：成功 {}，失败 {}（{:.1}s）",
            picks.len(),
            good,
            picks.len() - good,
            started.elapsed().as_secs_f32()
        );
        let f = first_fail.into_inner().unwrap();
        if f != usize::MAX {
            println!("   最早失败在第 {} 章「{}」", f + 1, toc[f].title);
        }
        let mut rs: Vec<(String, usize)> = reasons.into_inner().unwrap().into_iter().collect();
        rs.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
        for (r, n) in rs {
            println!("   {n:>3} × {r}");
        }
    }
}
