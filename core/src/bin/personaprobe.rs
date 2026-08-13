//! What the rule layer sees in a book: the cast, ranked, and who stands with
//! whom, with evidence. The tool for judging name extraction on a real book
//! before any model is allowed near the result.
//!
//! Usage: personaprobe <book.txt> [chapters]

use novel_core::{book, cast, decode, fingerprint::fingerprint};

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args
        .next()
        .expect("usage: personaprobe <book.txt> [chapters]");
    let upto: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(50);

    let raw = std::fs::read(&path).expect("read file");
    let d = decode::decode(&raw);
    let fp = fingerprint(d.encoding, &d.text);
    let b = book::build(&d.text, &fp);
    let n = upto.min(b.chapters.len());

    // personaprobe <txt> <chapters> 查 名字,名字 — why did these live or die?
    if args.next().as_deref() == Some("查") {
        let names: Vec<String> = args
            .next()
            .unwrap_or_default()
            .split(',')
            .map(str::to_string)
            .collect();
        for (name, count, anchored, left, right) in cast::candidate_stats(&d.text, &b.chapters, n) {
            if names.iter().any(|q| *q == name) {
                println!(
                    "{name}: 共 {count} 次 · 干净锚定 {anchored} · 左边界 {}% · 右边界 {}%",
                    left * 100 / count.max(1),
                    right * 100 / count.max(1)
                );
            }
        }
        return;
    }

    // personaprobe <txt> <chapters> 全 — the full ranked cast *before* prune, so
    // we can see where a missed lead fell (count rank, density, debut chapter).
    if std::env::args().nth(3).as_deref() == Some("全") {
        let mut ranked = cast::scan_ranked(&d.text, &b.chapters, n);
        ranked.sort_by(|x, y| y.mentions.cmp(&x.mentions));
        println!("全体候选 {} 人（未裁剪，按次数排序）：", ranked.len());
        for (i, p) in ranked.iter().enumerate() {
            let density = p.mentions as f32 / p.chapters.max(1) as f32;
            println!(
                "{:>3}. {:<8} {:>5} 次 · {:>4} 章 · 密度 {:>4.1} · 首现第 {:>4} 章",
                i + 1,
                p.name,
                p.mentions,
                p.chapters,
                density,
                p.first_chapter + 1
            );
        }
        return;
    }

    let t0 = std::time::Instant::now();
    let cast = cast::scan(&d.text, &b.chapters, n);
    let ms = t0.elapsed().as_millis();

    // personaprobe <txt> <chapters> 关系 — the conservative whole-book label
    // and every source fragment that contributed to it.
    if std::env::args().nth(3).as_deref() == Some("关系") {
        if let Some(report) = &cast.relationship {
            println!(
                "{}：{}（置信 {}/3）\n主角 {} · 后台核对 {} 人 · {} 章",
                report.label,
                report.reason,
                report.confidence,
                report.protagonist,
                report.candidate_count,
                report.analyzed_chapters
            );
            for evidence in &report.group_evidence {
                println!(
                    "  第{}章 · {} · {}",
                    evidence.chapter + 1,
                    evidence.person,
                    evidence.text
                );
            }
            for person in &report.people {
                println!(
                    "  {}：{} · 分数 {}",
                    person.name, person.status, person.score
                );
                for evidence in person.evidence.iter().take(3) {
                    println!(
                        "    第{}章 · {} · {}",
                        evidence.chapter + 1,
                        evidence.kind,
                        evidence.text
                    );
                }
            }
        }
        return;
    }

    // personaprobe <txt> <chapters> 对 名字,名字 — dump the exact evidence set the
    // model is handed for that pair, so we can see whether the fragments carry the
    // relationship at all.
    if std::env::args().nth(3).as_deref() == Some("对") {
        let names: Vec<String> = std::env::args()
            .nth(4)
            .unwrap_or_default()
            .split(',')
            .map(str::to_string)
            .collect();
        let idx = |q: &str| cast.people.iter().position(|p| p.name == q);
        if let (Some(a), Some(b)) = (
            names.first().and_then(|q| idx(q)),
            names.get(1).and_then(|q| idx(q)),
        ) {
            let e = cast
                .edges
                .iter()
                .find(|e| (e.a == a && e.b == b) || (e.a == b && e.b == a));
            match e {
                Some(e) => {
                    println!(
                        "{} ↔ {}  同现 {} · 证据 {} 段：",
                        cast.people[a].name,
                        cast.people[b].name,
                        e.weight,
                        e.evidence.len()
                    );
                    for (ch, s) in &e.evidence {
                        println!("  第{}章：{}", ch + 1, s);
                    }
                }
                None => println!("这对没有边"),
            }
        } else {
            println!("找不到人物");
        }
        return;
    }

    println!(
        "扫前 {n} 章（共 {} 章，{}）· {} 毫秒\n",
        b.chapters.len(),
        d.encoding,
        ms
    );

    println!("人物 {} 个：", cast.people.len());
    for (i, p) in cast.people.iter().enumerate() {
        let alias = if p.aliases.is_empty() {
            String::new()
        } else {
            format!(" · 别名 {}", p.aliases.join("、"))
        };
        println!(
            "{:>3}. {:<8} {:>5} 次 · {:>4} 章 · 首现第 {:>4} 章{}",
            i + 1,
            p.name,
            p.mentions,
            p.chapters,
            p.first_chapter + 1,
            alias
        );
    }

    let decided = cast.edges.iter().filter(|e| e.label.is_some()).count();
    println!(
        "\n关系 {} 条（规则已定标签 {} 条 · 待模型 {} 条）：",
        cast.edges.len(),
        decided,
        cast.edges.len() - decided
    );
    for e in &cast.edges {
        let hints = if e.hints.is_empty() {
            String::new()
        } else {
            let h: Vec<String> = e
                .hints
                .iter()
                .take(4)
                .map(|(w, c)| format!("{w}×{c}"))
                .collect();
            format!(" · 称谓 {}", h.join(" "))
        };
        // The label the rules settled, or a placeholder for the ones the model
        // would be asked about — the whole point of the probe is seeing which.
        let label = e.label.as_deref().unwrap_or("？待模型");
        println!(
            "  [{label}] {} ↔ {}  同现 {}{}",
            cast.people[e.a].name, cast.people[e.b].name, e.weight, hints
        );
        for (ch, s) in e.evidence.iter().take(2) {
            println!("      第{}章：{}", ch + 1, s);
        }
    }
}
