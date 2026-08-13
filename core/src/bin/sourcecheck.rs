//! Re-run the source engine over the library's own rule sheets and report what
//! it says now. This exists to keep engine work honest: the only thing that
//! settles whether a rule dialect is supported "well enough" is a real export of
//! real sheets pointed at the real web.
//!
//! Usage: sourcecheck <library.db> [how-many] [--failed-only]

use novel_core::source;
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Mutex,
};

fn main() {
    let mut args = std::env::args().skip(1);
    let db = args
        .next()
        .expect("usage: sourcecheck <library.db> [n] [--failed-only]");
    let rest: Vec<String> = args.collect();
    let want: usize = rest.iter().find_map(|a| a.parse().ok()).unwrap_or(200);
    let failed_only = rest.iter().any(|a| a == "--failed-only");
    // Re-run exactly the sources that failed for one particular reason. This is
    // how a change to the verdict is measured without sampling noise: same
    // sheets, same complaint, only the rule moved.
    let note = rest
        .iter()
        .position(|a| a == "--note")
        .and_then(|i| rest.get(i + 1))
        .cloned();

    let conn = rusqlite::Connection::open(&db).expect("open db");
    // Random, because the head of an import file is not a sample of it: the
    // sheets people put at the top are the ones they care about, not the ones
    // that work.
    let sql = match (&note, failed_only) {
        (Some(_), _) => {
            "SELECT name, json FROM sources WHERE ok = 0 AND note LIKE ?1 ORDER BY RANDOM()"
        }
        (None, true) => {
            "SELECT name, json FROM sources WHERE ok = 0 AND ?1 IS NOT NULL ORDER BY RANDOM()"
        }
        (None, false) => "SELECT name, json FROM sources WHERE ?1 IS NOT NULL ORDER BY RANDOM()",
    };
    let bind = note.clone().unwrap_or_else(|| "x".into());
    let mut st = conn.prepare(sql).unwrap();
    let rows: Vec<(String, String)> = st
        .query_map([&bind], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .filter_map(Result::ok)
        .take(want)
        .collect();

    println!(
        "重新校验 {} 个书源（之前的结论：{}）\n",
        rows.len(),
        match (&note, failed_only) {
            (Some(n), _) => format!("失败，且原因像「{n}」"),
            (None, true) => "失败".into(),
            (None, false) => "全部".into(),
        }
    );

    let queue = Mutex::new(rows);
    let notes: Mutex<HashMap<String, usize>> = Mutex::new(HashMap::new());
    let wins: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let done = AtomicUsize::new(0);
    let slow_wins = AtomicUsize::new(0);

    std::thread::scope(|scope| {
        for _ in 0..20 {
            scope.spawn(|| loop {
                let Some((name, json)) = queue.lock().unwrap().pop() else {
                    return;
                };
                let Some(src) = source::parse_sources(&json)
                    .ok()
                    .and_then(|v| v.into_iter().next())
                else {
                    *notes
                        .lock()
                        .unwrap()
                        .entry("书源已损坏".into())
                        .or_default() += 1;
                    done.fetch_add(1, Ordering::SeqCst);
                    continue;
                };
                let mut r = source::test(&src);
                // Was the eight-second fuse too short, or is the site dead? The
                // only way to know is to ask again with a longer one.
                if !r.ok && r.message.contains("timeout") {
                    let slow = source::test_with_timeout(&src, 25);
                    if slow.ok {
                        slow_wins.fetch_add(1, Ordering::SeqCst);
                    }
                    r = slow;
                }
                let n = done.fetch_add(1, Ordering::SeqCst) + 1;
                if n % 25 == 0 {
                    eprintln!("  …{n}");
                }
                if r.ok {
                    wins.lock().unwrap().push(name.trim().to_string());
                } else {
                    // Group by shape, not by the exact URL that failed.
                    let key: String = r.message.chars().take(28).collect();
                    *notes.lock().unwrap().entry(key).or_default() += 1;
                }
            });
        }
    });

    let wins = wins.into_inner().unwrap();
    let notes = notes.into_inner().unwrap();
    let total = done.load(Ordering::SeqCst);
    println!(
        "\n可用 {} / {}（其中 {} 个是把超时放宽到 25 秒才救回来的）",
        wins.len(),
        total,
        slow_wins.load(Ordering::SeqCst)
    );
    for w in wins.iter().take(40) {
        println!("  ✓ {w}");
    }
    println!("\n失败原因：");
    let mut v: Vec<_> = notes.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1));
    for (k, n) in v.iter().take(20) {
        println!("  {n:>4} | {k}");
    }
}
