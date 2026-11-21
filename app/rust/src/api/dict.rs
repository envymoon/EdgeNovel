//! 字典, looked up from the 标注 dialog; see `novel_core::dict`.

use novel_core::dict;
use std::path::Path;

pub enum DictKind {
    Zi,
    Ci,
    Chengyu,
}

pub struct DictEntry {
    pub kind: DictKind,
    pub word: String,
    pub pinyin: String,
    pub body: String,
    pub source: String,
    pub example: String,
}

/// Turns the downloaded `word.json`, `ci.json` and `idiom.json` in `dir` into
/// `dir/dict.db`, then deletes them.
pub fn dict_build(dir: String) -> Result<(), String> {
    let d = Path::new(&dir);
    let files = ["word.json", "ci.json", "idiom.json"].map(|f| d.join(f));
    dict::build(&files[0], &files[1], &files[2], &d.join("dict.db"))?;
    for f in files {
        let _ = std::fs::remove_file(f);
    }
    Ok(())
}

pub fn dict_lookup(path: String, text: String) -> Result<Vec<DictEntry>, String> {
    Ok(dict::lookup(Path::new(&path), &text)?
        .into_iter()
        .map(|e| DictEntry {
            kind: match e.kind {
                dict::Kind::Zi => DictKind::Zi,
                dict::Kind::Ci => DictKind::Ci,
                dict::Kind::Chengyu => DictKind::Chengyu,
            },
            word: e.word,
            pinyin: e.pinyin,
            body: e.body,
            source: e.source,
            example: e.example,
        })
        .collect())
}
