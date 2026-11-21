//! 字典: characters, words and idioms, looked up from the 标注 dialog.
//!
//! Nothing is bundled. The app downloads the three JSON files of
//! pwxcoo/chinese-xinhua (MIT) and `build` turns them into one SQLite file;
//! the JSON is then thrown away.

use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    /// One character, with its readings.
    Zi,
    /// A word.
    Ci,
    /// An idiom.
    Chengyu,
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub kind: Kind,
    pub word: String,
    pub pinyin: String,
    /// Lines; a line that is a reading on its own (`行xíng`) starts a section.
    pub body: String,
    /// Idioms only: where it comes from, and an example.
    pub source: String,
    pub example: String,
}

#[derive(Deserialize)]
struct RawZi {
    word: String,
    #[serde(default)]
    pinyin: String,
    #[serde(default)]
    explanation: String,
    #[serde(default)]
    more: String,
}

#[derive(Deserialize)]
struct RawCi {
    ci: String,
    #[serde(default)]
    explanation: String,
}

#[derive(Deserialize)]
struct RawIdiom {
    word: String,
    #[serde(default)]
    pinyin: String,
    #[serde(default)]
    explanation: String,
    #[serde(default)]
    derivation: String,
    #[serde(default)]
    example: String,
}

fn is_han(c: char) -> bool {
    ('\u{3400}'..='\u{9fff}').contains(&c) || ('\u{f900}'..='\u{faff}').contains(&c)
}

fn is_pinyin(s: &str) -> bool {
    !s.is_empty()
        && s.chars().all(|c| {
            c.is_ascii_alphabetic() || c == ' ' || c == '\'' || c == '－' || c == '-' || (!is_han(c) && c.is_alphabetic())
        })
}

/// The data writes some g's as ɡ.
fn fix_pinyin(s: &str) -> String {
    s.replace('ɡ', "g").replace('ɑ', "a").trim().to_string()
}

const ENUMS: &str = "⒈⒉⒊⒋⒌⒍⒎⒏⒐⒑⒒⒓⒔⒕⒖⒗⒘⒙⒚⒛①②③④⑤⑥⑦⑧⑨⑩";

/// A character's explanation: the modern readings when there are any (the
/// classical notes before them are long and unordered), without the empty
/// numbered lines the data is full of.
fn clean_zi(word: &str, text: &str) -> String {
    let pieces: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|p| !p.is_empty() && !p.chars().all(|c| ENUMS.contains(c) || c.is_whitespace()))
        .collect();
    let start = (0..pieces.len())
        .find(|&i| {
            reading(word, pieces[i]).is_some()
                && pieces.get(i + 1).is_some_and(|n| n.starts_with('⒈'))
        })
        .unwrap_or(0);
    pieces[start..]
        .iter()
        .map(|p| fix_pinyin_header(word, p))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The pinyin of a line that is a reading on its own: `行xíng`, `惊（驚）jīng`.
fn reading<'a>(word: &str, p: &'a str) -> Option<&'a str> {
    let mut rest = p.strip_prefix(word)?;
    if let Some(r) = rest.strip_prefix('（') {
        rest = r.split_once('）')?.1;
    }
    let rest = rest.trim();
    (rest.len() < 16 && is_pinyin(rest)).then_some(rest)
}

fn fix_pinyin_header(word: &str, p: &str) -> String {
    match reading(word, p) {
        Some(py) => format!("{word}{}", fix_pinyin(py)),
        None => p.to_string(),
    }
}

/// Words and their pinyin, from the longer notes of each character: a line of
/// characters, then a line of pinyin.
fn word_pinyin(more: &str, into: &mut HashMap<String, String>) {
    let lines: Vec<&str> = more.lines().map(str::trim).collect();
    for w in lines.windows(2) {
        let (word, py) = (w[0], w[1]);
        if word.chars().count() >= 2 && word.chars().all(is_han) && is_pinyin(py) && py.len() < 60 {
            into.entry(word.to_string()).or_insert_with(|| fix_pinyin(py));
        }
    }
}

fn read<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<Vec<T>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// Builds the dictionary at `out` from the downloaded files. Written beside it
/// first, so a stopped build never leaves a half dictionary under its name.
pub fn build(zi: &Path, ci: &Path, idiom: &Path, out: &Path) -> Result<(), String> {
    let tmp = out.with_extension("building");
    let _ = std::fs::remove_file(&tmp);
    let e = |e: rusqlite::Error| e.to_string();
    {
        let mut db = Connection::open(&tmp).map_err(e)?;
        db.execute_batch(
            "PRAGMA journal_mode=OFF;
             CREATE TABLE zi(word TEXT PRIMARY KEY, pinyin TEXT, body TEXT) WITHOUT ROWID;
             CREATE TABLE ci(word TEXT PRIMARY KEY, pinyin TEXT, body TEXT) WITHOUT ROWID;
             CREATE TABLE chengyu(word TEXT PRIMARY KEY, pinyin TEXT, body TEXT, source TEXT, example TEXT) WITHOUT ROWID;",
        )
        .map_err(e)?;
        let tx = db.transaction().map_err(e)?;
        let mut pinyin = HashMap::new();
        {
            let mut put = tx.prepare("INSERT OR IGNORE INTO zi VALUES(?1, ?2, ?3)").map_err(e)?;
            for z in read::<RawZi>(zi)? {
                word_pinyin(&z.more, &mut pinyin);
                let body = clean_zi(&z.word, &z.explanation);
                if body.is_empty() {
                    continue;
                }
                put.execute(params![z.word, fix_pinyin(&z.pinyin), body]).map_err(e)?;
            }
        }
        {
            let mut words: Vec<(String, String)> = Vec::new();
            let mut at: HashMap<String, usize> = HashMap::new();
            for c in read::<RawCi>(ci)? {
                let (w, b) = (c.ci.trim().to_string(), c.explanation.trim().to_string());
                if w.is_empty() || b.is_empty() {
                    continue;
                }
                match at.get(&w) {
                    Some(&i) => {
                        if !words[i].1.contains(&b) {
                            words[i].1.push('\n');
                            words[i].1.push_str(&b);
                        }
                    }
                    None => {
                        at.insert(w.clone(), words.len());
                        words.push((w, b));
                    }
                }
            }
            let mut put = tx.prepare("INSERT INTO ci VALUES(?1, ?2, ?3)").map_err(e)?;
            for (w, b) in words {
                let py = pinyin.get(&w).cloned().unwrap_or_default();
                put.execute(params![w, py, b]).map_err(e)?;
            }
        }
        {
            let mut put = tx
                .prepare("INSERT OR IGNORE INTO chengyu VALUES(?1, ?2, ?3, ?4, ?5)")
                .map_err(e)?;
            for i in read::<RawIdiom>(idiom)? {
                let word = i.word.trim();
                let none = |s: &str| {
                    let s = s.trim();
                    if s == "无" { String::new() } else { s.replace('～', word) }
                };
                put.execute(params![
                    word,
                    fix_pinyin(&i.pinyin),
                    i.explanation.trim(),
                    none(&i.derivation),
                    none(&i.example)
                ])
                .map_err(e)?;
            }
        }
        tx.commit().map_err(e)?;
        db.execute_batch("VACUUM;").map_err(e)?;
    }
    std::fs::rename(&tmp, out).map_err(|e| e.to_string())
}

/// What the dictionary says about a selection: the idiom or word it is, or
/// for one character, the character; a short selection it does not know is
/// looked up character by character.
pub fn lookup(db: &Path, text: &str) -> Result<Vec<Entry>, String> {
    let text: String = text.chars().filter(|c| is_han(*c)).collect();
    let n = text.chars().count();
    if n == 0 || n > 12 {
        return Ok(Vec::new());
    }
    let conn = Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| e.to_string())?;
    let e = |e: rusqlite::Error| e.to_string();
    let chengyu = conn
        .query_row(
            "SELECT pinyin, body, source, example FROM chengyu WHERE word = ?1",
            [&text],
            |r| {
                Ok(Entry {
                    kind: Kind::Chengyu,
                    word: text.clone(),
                    pinyin: r.get(0)?,
                    body: r.get(1)?,
                    source: r.get(2)?,
                    example: r.get(3)?,
                })
            },
        )
        .optional()
        .map_err(e)?;
    if let Some(c) = chengyu {
        return Ok(vec![c]);
    }
    // One character is the character, not the odd word that is one too.
    let ci = if n == 1 {
        None
    } else {
        conn.query_row("SELECT pinyin, body FROM ci WHERE word = ?1", [&text], |r| {
            Ok(Entry {
                kind: Kind::Ci,
                word: text.clone(),
                pinyin: r.get(0)?,
                body: r.get(1)?,
                source: String::new(),
                example: String::new(),
            })
        })
        .optional()
        .map_err(e)?
    };
    if let Some(c) = ci {
        return Ok(vec![c]);
    }
    if n > 4 {
        return Ok(Vec::new());
    }
    let mut out: Vec<Entry> = Vec::new();
    for ch in text.chars() {
        let w = ch.to_string();
        if out.iter().any(|x| x.word == w) {
            continue;
        }
        if let Some(z) = conn
            .query_row("SELECT pinyin, body FROM zi WHERE word = ?1", [&w], |r| {
                Ok(Entry {
                    kind: Kind::Zi,
                    word: w.clone(),
                    pinyin: r.get(0)?,
                    body: r.get(1)?,
                    source: String::new(),
                    example: String::new(),
                })
            })
            .optional()
            .map_err(e)?
        {
            out.push(z);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_and_looks_up() {
        let dir = std::env::temp_dir().join(format!("dict_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let zi = dir.join("word.json");
        let ci = dir.join("ci.json");
        let idiom = dir.join("idiom.json");
        std::fs::write(
            &zi,
            r#"[{"word":"行","pinyin":"xínɡ","explanation":"行〈名〉\n\n 古义\n\n 行háng\n\n ⒈排，队列。\n\n ⒍\n\n 行xíng\n\n ⒈走。","more":"行帮\nhángbāng\n旧时团体"},
                {"word":"走","pinyin":"zǒu","explanation":"走zǒu\n\n ⒈行。","more":""}]"#,
        )
        .unwrap();
        std::fs::write(&ci, r#"[{"ci":"行帮","explanation":"旧时团体。"},{"ci":"行帮","explanation":"又一义。"}]"#).unwrap();
        std::fs::write(
            &idiom,
            r#"[{"word":"行云流水","pinyin":"xíng yún liú shuǐ","explanation":"比喻自然。","derivation":"无","example":"文章如～。"}]"#,
        )
        .unwrap();
        let db = dir.join("dict.db");
        build(&zi, &ci, &idiom, &db).unwrap();

        let z = lookup(&db, "行").unwrap();
        assert_eq!(z.len(), 1);
        assert_eq!(z[0].pinyin, "xíng");
        assert_eq!(z[0].body, "行háng\n⒈排，队列。\n行xíng\n⒈走。");

        let c = lookup(&db, "「行帮」").unwrap();
        assert_eq!(c[0].kind, Kind::Ci);
        assert_eq!(c[0].pinyin, "hángbāng");
        assert_eq!(c[0].body, "旧时团体。\n又一义。");

        let y = lookup(&db, "行云流水").unwrap();
        assert_eq!(y[0].kind, Kind::Chengyu);
        assert_eq!(y[0].source, "");
        assert_eq!(y[0].example, "文章如行云流水。");

        let each = lookup(&db, "行走").unwrap();
        assert_eq!(each.iter().map(|e| e.word.as_str()).collect::<Vec<_>>(), ["行", "走"]);
        assert!(lookup(&db, "这是一段很长很长很长的话呀").unwrap().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
