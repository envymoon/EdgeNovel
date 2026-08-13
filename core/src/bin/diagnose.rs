use novel_core::{book, chapters, decode, fingerprint};

fn main() {
    for path in std::env::args().skip(1) {
        let raw = std::fs::read(&path).expect("read");
        let d = decode::decode(&raw);
        let fp = fingerprint::fingerprint(d.encoding, &d.text);

        let name = path.rsplit(['/', '\\']).next().unwrap_or(&path);
        println!(
            "\n{}\n{name}  {:.1} MB",
            "=".repeat(74),
            raw.len() as f64 / 1e6
        );
        println!("编码 {}   分段方式 {:?}", fp.encoding, fp.style);
        println!(
            "行 {} (空 {})   缩进 {}   顶格 {}",
            fp.total_lines, fp.blank_lines, fp.indented_lines, fp.flush_lines
        );
        println!(
            "行长 中位 {} / p90 {} / 最长 {}   段末标点率 {:.1}%",
            fp.median_len,
            fp.p90_len,
            fp.max_len,
            fp.paragraph_end_ratio * 100.0
        );
        match fp.hard_wrap_width {
            Some(w) => println!("⚠ 疑似固定宽度硬换行，宽度≈{w} → 需要换行修复"),
            None => println!("✓ 无硬换行"),
        }

        let cands = chapters::candidates(&d.text, &fp);
        let v = chapters::validate(&cands, &fp);
        let kept = &v.chapters;

        println!(
            "\n章节候选 {}  → 采纳 {}  (剔除 {})",
            cands.len(),
            kept.len(),
            v.rejected.len()
        );
        for c in kept.iter().take(3) {
            println!("    ✓ {:?} {}", c.template, c.text);
        }
        for c in v.rejected.iter().take(3) {
            println!("    ✗ {}", c.text);
        }
        for a in v.anomalies.iter().take(3) {
            println!("    ⚠ {a}");
        }

        let b = book::build(&d.text, &fp);
        println!(
            "\n目录 {} 章   插页 {} 条",
            b.chapters.len(),
            b.interstitials.len()
        );
        for c in b.chapters.iter().take(3) {
            println!(
                "    [{}] {}  ({}..{})",
                c.index, c.title, c.span.start, c.span.end
            );
        }
        for i in b.interstitials.iter().take(5) {
            println!("    · {}", i.text.chars().take(50).collect::<String>());
        }

        // No byte of the book may fall outside a chapter, and no byte may belong
        // to two. A silent violation here means text vanished from the reader.
        let mut cursor = 0;
        let mut gap = None;
        for c in &b.chapters {
            if c.span.start != cursor {
                gap = Some((cursor, c.span.start));
                break;
            }
            cursor = c.span.end;
        }
        match gap {
            Some((a, z)) => println!("    ✗ 章节区间不连续: {a}..{z}"),
            None if cursor == d.text.len() => println!("    ✓ 章节区间完整覆盖全文，无丢失"),
            None => println!("    ✗ 结尾缺失 {} 字节", d.text.len() - cursor),
        }
    }
}
