//! The Chinese front end of the small 听书 voice, line by line, to compare
//! with the original's: `zhprobe <zh.bin> <text file>` prints each line's
//! phonemes; `--seg` prints jieba's words and tags instead.
use novel_core::zh_g2p::Zh;
use std::io::Write;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let zh = Zh::load(&std::fs::read(&args[1]).expect("data")).expect("load");
    let text = std::fs::read_to_string(&args[2]).expect("text");
    let seg = args.iter().any(|a| a == "--seg");
    let out = std::io::stdout();
    let mut out = out.lock();
    for line in text.lines() {
        if seg {
            let words: Vec<String> = zh.posseg(line).into_iter().map(|(w, t)| format!("{w}/{t}")).collect();
            writeln!(out, "{}", words.join(" ")).unwrap();
        } else {
            writeln!(out, "{}", zh.phonemes(line)).unwrap();
        }
    }
}
