//! Chinese text to the phonemes the small 听书 voice reads: the original's
//! own front end (misaki 1.1 zh: cn2an's numbers, jieba's words and parts of
//! speech, pypinyin's readings, its tone sandhi and erhua), followed step by
//! step so the result is the same string. The dictionaries and models come
//! from `experiments/kokoro/export_zh.py` as one file.
//!
//! Strings are worked on as `Vec<char>` where the original indexes by
//! character.

use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

const UNK: &str = "❓";
const MIN_FLOAT: f64 = -3.14e100;

pub struct Zh {
    // jieba: its dictionary (sorted), the sum of its counts.
    words: Vec<Box<str>>,
    freq: Vec<u32>,
    tag: Vec<u16>,
    tags: Vec<String>,
    log_total: f64,
    // jieba's HMM for unknown words: B M E S.
    fs_start: [f64; 4],
    fs_trans: [[f64; 4]; 4],
    fs_emit: [HashMap<char, f64>; 4],
    // posseg's HMM.
    ps_states: Vec<(char, String)>,
    ps_start: Vec<f64>,
    ps_trans: Vec<HashMap<u16, f64>>,
    ps_trans_any: Vec<Vec<u16>>,
    ps_emit: Vec<HashMap<char, f64>>,
    ps_char: HashMap<char, Vec<u16>>,
    // pypinyin.
    syllables: Vec<(String, String)>,
    chars: HashMap<char, u16>,
    phrases: Vec<Box<str>>,
    phrase_syl: Vec<Vec<u16>>,
    hans: Vec<(u32, u32)>,
    numeric: Vec<(u32, u32)>,
    spaces: Vec<(u32, u32)>,
    digits: Vec<(u32, u32)>,
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        if self.at + n > self.b.len() {
            return Err("发音数据不完整".into());
        }
        let s = &self.b[self.at..self.at + n];
        self.at += n;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, String> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn f64(&mut self) -> Result<f64, String> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn str(&mut self) -> Result<String, String> {
        let n = self.u16()? as usize;
        String::from_utf8(self.take(n)?.to_vec()).map_err(|e| e.to_string())
    }
    fn ch(&mut self) -> Result<char, String> {
        char::from_u32(self.u32()?).ok_or_else(|| "发音数据有误".to_string())
    }
    fn ranges(&mut self) -> Result<Vec<(u32, u32)>, String> {
        let n = self.u32()?;
        (0..n).map(|_| Ok((self.u32()?, self.u32()?))).collect()
    }
}

fn in_ranges(r: &[(u32, u32)], c: char) -> bool {
    let c = c as u32;
    let i = r.partition_point(|&(_, b)| b < c);
    i < r.len() && r[i].0 <= c
}

/// The first of [sorted] at or after [key], and whether one starts with it.
fn lower(sorted: &[Box<str>], key: &str) -> usize {
    sorted.partition_point(|w| w.as_bytes() < key.as_bytes())
}

fn is_han_detail(c: char) -> bool {
    ('\u{4E00}'..='\u{9FD5}').contains(&c)
}

fn is_han_internal(c: char) -> bool {
    is_han_detail(c) || c.is_ascii_alphanumeric() || "+#&._".contains(c)
}

fn is_han_default(c: char) -> bool {
    is_han_internal(c) || c == '%' || c == '-'
}

fn s(chars: &[char]) -> String {
    chars.iter().collect()
}

/// Python's `max` over `(value, key)` pairs: the larger value, then the
/// larger key.
fn better(a: (f64, usize), b: (f64, usize)) -> bool {
    a.0 > b.0 || (a.0 == b.0 && a.1 > b.1)
}

impl Zh {
    pub fn load(bytes: &[u8]) -> Result<Zh, String> {
        let mut r = Reader { b: bytes, at: 0 };
        if r.take(4)? != b"KZH1" {
            return Err("不是发音数据".into());
        }
        let mut sections: HashMap<[u8; 4], &[u8]> = HashMap::new();
        while r.at < bytes.len() {
            let tag: [u8; 4] = r.take(4)?.try_into().unwrap();
            let n = r.u32()? as usize;
            sections.insert(tag, r.take(n)?);
        }
        let get = |t: &[u8; 4]| -> Result<Reader, String> {
            sections
                .get(t)
                .map(|b| Reader { b, at: 0 })
                .ok_or_else(|| format!("发音数据缺 {}", String::from_utf8_lossy(t)))
        };

        let mut d = get(b"JDCT")?;
        let total = d.u64()?;
        let ntags = d.u32()?;
        let tags = (0..ntags).map(|_| d.str()).collect::<Result<Vec<_>, _>>()?;
        let n = d.u32()? as usize;
        let (mut words, mut freq, mut tag) = (Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n));
        for _ in 0..n {
            words.push(d.str()?.into_boxed_str());
            freq.push(d.u32()?);
            tag.push(d.u16()?);
        }

        let mut f = get(b"FSEG")?;
        let mut fs_start = [0.0; 4];
        for v in &mut fs_start {
            *v = f.f64()?;
        }
        let mut fs_trans = [[0.0; 4]; 4];
        for row in &mut fs_trans {
            for v in row.iter_mut() {
                *v = f.f64()?;
            }
        }
        let mut fs_emit: [HashMap<char, f64>; 4] = Default::default();
        for m in &mut fs_emit {
            let n = f.u32()?;
            for _ in 0..n {
                let c = f.ch()?;
                m.insert(c, f.f64()?);
            }
        }

        let mut p = get(b"PSEG")?;
        let n = p.u32()? as usize;
        let mut ps_states = Vec::with_capacity(n);
        let mut ps_start = Vec::with_capacity(n);
        for _ in 0..n {
            let a = p.str()?;
            let b = p.str()?;
            ps_states.push((a.chars().next().unwrap_or('S'), b));
            ps_start.push(p.f64()?);
        }
        let mut ps_trans = Vec::with_capacity(n);
        let mut ps_trans_any = Vec::with_capacity(n);
        for _ in 0..n {
            let k = p.u32()?;
            let mut m = HashMap::new();
            let mut order = Vec::new();
            for _ in 0..k {
                let y = p.u16()?;
                m.insert(y, p.f64()?);
                order.push(y);
            }
            ps_trans.push(m);
            ps_trans_any.push(order);
        }
        let mut ps_emit = Vec::with_capacity(n);
        for _ in 0..n {
            let k = p.u32()?;
            let mut m = HashMap::with_capacity(k as usize);
            for _ in 0..k {
                let c = p.ch()?;
                m.insert(c, p.f64()?);
            }
            ps_emit.push(m);
        }
        let k = p.u32()?;
        let mut ps_char = HashMap::with_capacity(k as usize);
        for _ in 0..k {
            let c = p.ch()?;
            let m = p.u16()?;
            let v = (0..m).map(|_| p.u16()).collect::<Result<Vec<_>, _>>()?;
            ps_char.insert(c, v);
        }

        let mut y = get(b"PINY")?;
        let n = y.u32()?;
        let syllables = (0..n)
            .map(|_| Ok((y.str()?, y.str()?)))
            .collect::<Result<Vec<_>, String>>()?;
        let n = y.u32()?;
        let mut chars = HashMap::with_capacity(n as usize);
        for _ in 0..n {
            let c = y.ch()?;
            chars.insert(c, y.u16()?);
        }
        let n = y.u32()? as usize;
        let (mut phrases, mut phrase_syl) = (Vec::with_capacity(n), Vec::with_capacity(n));
        for _ in 0..n {
            phrases.push(y.str()?.into_boxed_str());
            let k = y.u8()?;
            phrase_syl.push((0..k).map(|_| y.u16()).collect::<Result<Vec<_>, _>>()?);
        }

        Ok(Zh {
            words,
            freq,
            tag,
            tags,
            log_total: (total as f64).ln(),
            fs_start,
            fs_trans,
            fs_emit,
            ps_states,
            ps_start,
            ps_trans,
            ps_trans_any,
            ps_emit,
            ps_char,
            syllables,
            chars,
            phrases,
            phrase_syl,
            hans: get(b"HANS")?.ranges()?,
            numeric: get(b"NUMC")?.ranges()?,
            spaces: get(b"SPAC")?.ranges()?,
            digits: get(b"DIGT")?.ranges()?,
        })
    }

    fn is_space(&self, c: char) -> bool {
        in_ranges(&self.spaces, c)
    }

    fn is_numeric(&self, c: char) -> bool {
        in_ranges(&self.numeric, c)
    }

    fn is_hans(&self, c: char) -> bool {
        in_ranges(&self.hans, c)
    }

    fn is_digit(&self, c: char) -> bool {
        in_ranges(&self.digits, c)
    }

    // ---- jieba's dictionary -------------------------------------------------

    /// `FREQ.get(w)`: None when not even a prefix of a word.
    fn freq(&self, w: &str) -> Option<u32> {
        let i = lower(&self.words, w);
        let hit = self.words.get(i)?;
        if &**hit == w {
            Some(self.freq[i])
        } else if hit.starts_with(w) {
            Some(0)
        } else {
            None
        }
    }

    fn word_tag(&self, w: &str) -> Option<&str> {
        let i = lower(&self.words, w);
        match self.words.get(i) {
            Some(hit) if &**hit == w && self.tag[i] != 0xFFFF => Some(&self.tags[self.tag[i] as usize]),
            _ => None,
        }
    }

    fn dag(&self, s: &[char]) -> Vec<Vec<usize>> {
        let n = s.len();
        (0..n)
            .map(|k| {
                let mut list = Vec::new();
                let mut i = k;
                let mut frag = s[k].to_string();
                while i < n {
                    match self.freq(&frag) {
                        None => break,
                        Some(f) => {
                            if f > 0 {
                                list.push(i);
                            }
                        }
                    }
                    i += 1;
                    if i < n {
                        frag.push(s[i]);
                    }
                }
                if list.is_empty() {
                    list.push(k);
                }
                list
            })
            .collect()
    }

    /// jieba's best path through the DAG: for each start, where its word ends.
    fn route(&self, s: &[char]) -> Vec<usize> {
        let dag = self.dag(s);
        let n = s.len();
        let mut route = vec![(0.0f64, 0usize); n + 1];
        for idx in (0..n).rev() {
            let mut best: Option<(f64, usize)> = None;
            for &x in &dag[idx] {
                let f = self.freq(&self::s(&s[idx..=x])).filter(|&f| f > 0).unwrap_or(1);
                let v = ((f as f64).ln() - self.log_total + route[x + 1].0, x);
                if best.is_none_or(|b| better(v, b)) {
                    best = Some(v);
                }
            }
            route[idx] = best.unwrap();
        }
        route.into_iter().map(|r| r.1).collect()
    }

    // ---- jieba.cut (accurate, HMM), for cut_for_search ----------------------

    fn finalseg_viterbi(&self, obs: &[char]) -> Vec<u8> {
        // B M E S as 0 1 2 3.
        const PREV: [[usize; 2]; 4] = [[2, 3], [1, 0], [0, 1], [3, 2]];
        // B: ES, M: MB, E: BM, S: SE.
        const NAME: [char; 4] = ['B', 'M', 'E', 'S'];
        let em = |y: usize, c: char| *self.fs_emit[y].get(&c).unwrap_or(&MIN_FLOAT);
        let mut v: Vec<[f64; 4]> = Vec::with_capacity(obs.len());
        let mut path: [Vec<u8>; 4] = Default::default();
        let mut first = [0.0; 4];
        for y in 0..4 {
            first[y] = self.fs_start[y] + em(y, obs[0]);
            path[y] = vec![y as u8];
        }
        v.push(first);
        for t in 1..obs.len() {
            let mut row = [0.0; 4];
            let mut newpath: [Vec<u8>; 4] = Default::default();
            for y in 0..4 {
                let e = em(y, obs[t]);
                let mut best: Option<(f64, usize)> = None;
                for &y0 in &PREV[y] {
                    let p = v[t - 1][y0] + self.fs_trans[y0][y] + e;
                    // Ties go to the later state name.
                    let cand = (p, y0);
                    if best.is_none_or(|b| p > b.0 || (p == b.0 && NAME[y0] > NAME[b.1])) {
                        best = Some(cand);
                    }
                }
                let (p, st) = best.unwrap();
                row[y] = p;
                let mut np = path[st].clone();
                np.push(y as u8);
                newpath[y] = np;
            }
            v.push(row);
            path = newpath;
        }
        let last = v.last().unwrap();
        // max over E then S, ties to the later name ('S').
        let st = if last[3] >= last[2] { 3 } else { 2 };
        path[st].clone()
    }

    fn finalseg_hmm_cut(&self, s: &[char], out: &mut Vec<String>) {
        let pos = self.finalseg_viterbi(s);
        let (mut begin, mut next) = (0, 0);
        for i in 0..s.len() {
            match pos[i] {
                0 => begin = i,
                2 => {
                    out.push(self::s(&s[begin..=i]));
                    next = i + 1;
                }
                3 => {
                    out.push(s[i].to_string());
                    next = i + 1;
                }
                _ => {}
            }
        }
        if next < s.len() {
            out.push(self::s(&s[next..]));
        }
    }

    fn finalseg_cut(&self, s: &[char], out: &mut Vec<String>) {
        for (han, blk) in runs(s, is_han_detail) {
            if han {
                self.finalseg_hmm_cut(blk, out);
            } else {
                // re_skip: [a-zA-Z0-9]+(?:\.\d+)?%?
                let mut i = 0;
                let mut start = 0;
                while i < blk.len() {
                    if blk[i].is_ascii_alphanumeric() {
                        let mut j = i;
                        while j < blk.len() && blk[j].is_ascii_alphanumeric() {
                            j += 1;
                        }
                        if j + 1 < blk.len() && blk[j] == '.' && self.is_digit(blk[j + 1]) {
                            j += 1;
                            while j < blk.len() && self.is_digit(blk[j]) {
                                j += 1;
                            }
                        }
                        if j < blk.len() && blk[j] == '%' {
                            j += 1;
                        }
                        if start < i {
                            out.push(self::s(&blk[start..i]));
                        }
                        out.push(self::s(&blk[i..j]));
                        i = j;
                        start = j;
                    } else {
                        i += 1;
                    }
                }
                if start < blk.len() {
                    out.push(self::s(&blk[start..]));
                }
            }
        }
    }

    fn cut_dag_hmm(&self, s: &[char], out: &mut Vec<String>) {
        let route = self.route(s);
        let n = s.len();
        let mut buf: Vec<char> = Vec::new();
        let flush = |buf: &mut Vec<char>, out: &mut Vec<String>| {
            if buf.is_empty() {
                return;
            }
            if buf.len() == 1 {
                out.push(self::s(buf));
            } else if self.freq(&self::s(buf)).unwrap_or(0) == 0 {
                self.finalseg_cut(buf, out);
            } else {
                out.extend(buf.iter().map(|c| c.to_string()));
            }
            buf.clear();
        };
        let mut x = 0;
        while x < n {
            let y = route[x] + 1;
            if y - x == 1 {
                buf.push(s[x]);
            } else {
                flush(&mut buf, out);
                out.push(self::s(&s[x..y]));
            }
            x = y;
        }
        flush(&mut buf, out);
    }

    fn jieba_cut(&self, s: &[char]) -> Vec<String> {
        let mut out = Vec::new();
        for (han, blk) in runs(s, is_han_default) {
            if han {
                self.cut_dag_hmm(blk, &mut out);
            } else {
                for piece in self.skip_split(blk) {
                    match piece {
                        Ok(sep) => out.push(sep),
                        Err(text) => out.extend(text.iter().map(|c| c.to_string())),
                    }
                }
            }
        }
        out
    }

    fn cut_for_search(&self, s: &[char]) -> Vec<String> {
        let mut out = Vec::new();
        for w in self.jieba_cut(s) {
            let c: Vec<char> = w.chars().collect();
            if c.len() > 2 {
                for i in 0..c.len() - 1 {
                    let g = self::s(&c[i..i + 2]);
                    if self.freq(&g).unwrap_or(0) > 0 {
                        out.push(g);
                    }
                }
            }
            if c.len() > 3 {
                for i in 0..c.len() - 2 {
                    let g = self::s(&c[i..i + 3]);
                    if self.freq(&g).unwrap_or(0) > 0 {
                        out.push(g);
                    }
                }
            }
            out.push(w);
        }
        out
    }

    /// `re.split("(\r\n|\s)", blk)`: separators as Ok, the text between as
    /// Err (possibly empty).
    fn skip_split<'b>(&self, blk: &'b [char]) -> Vec<Result<String, &'b [char]>> {
        let mut out = Vec::new();
        let (mut i, mut start) = (0, 0);
        while i < blk.len() {
            let sep = if blk[i] == '\r' && blk.get(i + 1) == Some(&'\n') {
                2
            } else if self.is_space(blk[i]) {
                1
            } else {
                0
            };
            if sep > 0 {
                out.push(Err(&blk[start..i]));
                out.push(Ok(self::s(&blk[i..i + sep])));
                i += sep;
                start = i;
            } else {
                i += 1;
            }
        }
        out.push(Err(&blk[start..]));
        out
    }

    // ---- jieba.posseg -------------------------------------------------------

    fn ps_viterbi(&self, obs: &[char]) -> Vec<u16> {
        let all: Vec<u16> = (0..self.ps_states.len() as u16).collect();
        let em = |y: u16, c: char| *self.ps_emit[y as usize].get(&c).unwrap_or(&MIN_FLOAT);
        let mut v: Vec<HashMap<u16, f64>> = Vec::with_capacity(obs.len());
        let mut mem: Vec<HashMap<u16, u16>> = Vec::with_capacity(obs.len());
        let first_states = self.ps_char.get(&obs[0]).unwrap_or(&all);
        let mut v0 = HashMap::new();
        let mut m0 = HashMap::new();
        for &y in first_states {
            v0.insert(y, self.ps_start[y as usize] + em(y, obs[0]));
            m0.insert(y, u16::MAX);
        }
        v.push(v0);
        mem.push(m0);
        for t in 1..obs.len() {
            let prev: Vec<u16> = mem[t - 1]
                .keys()
                .copied()
                .filter(|&x| !self.ps_trans_any[x as usize].is_empty())
                .collect();
            let expect: HashSet<u16> =
                prev.iter().flat_map(|&x| self.ps_trans_any[x as usize].iter().copied()).collect();
            let here = self.ps_char.get(&obs[t]).unwrap_or(&all);
            let mut obs_states: Vec<u16> = here.iter().copied().filter(|y| expect.contains(y)).collect();
            if obs_states.is_empty() {
                obs_states = if expect.is_empty() { all.clone() } else { expect.iter().copied().collect() };
            }
            let mut vt = HashMap::new();
            let mut mt = HashMap::new();
            for &y in &obs_states {
                let e = em(y, obs[t]);
                let mut best: Option<(f64, u16)> = None;
                for &y0 in &prev {
                    let tr = *self.ps_trans[y0 as usize].get(&y).unwrap_or(&f64::NEG_INFINITY);
                    let p = v[t - 1][&y0] + tr + e;
                    // States are numbered in Python's tuple order.
                    if best.is_none_or(|b| p > b.0 || (p == b.0 && y0 > b.1)) {
                        best = Some((p, y0));
                    }
                }
                if let Some((p, y0)) = best {
                    vt.insert(y, p);
                    mt.insert(y, y0);
                }
            }
            v.push(vt);
            mem.push(mt);
        }
        let lastv = v.last().unwrap();
        let mut state = u16::MAX;
        let mut bp = f64::NEG_INFINITY;
        for &y in mem.last().unwrap().keys() {
            let p = lastv[&y];
            if state == u16::MAX || p > bp || (p == bp && y > state) {
                bp = p;
                state = y;
            }
        }
        let mut route = vec![0u16; obs.len()];
        for i in (0..obs.len()).rev() {
            route[i] = state;
            state = mem[i][&state];
        }
        route
    }

    fn ps_hmm_cut(&self, s: &[char], out: &mut Vec<(String, String)>) {
        let pos = self.ps_viterbi(s);
        let st = |i: usize| &self.ps_states[pos[i] as usize];
        let (mut begin, mut next) = (0, 0);
        for i in 0..s.len() {
            match st(i).0 {
                'B' => begin = i,
                'E' => {
                    out.push((self::s(&s[begin..=i]), st(i).1.clone()));
                    next = i + 1;
                }
                'S' => {
                    out.push((s[i].to_string(), st(i).1.clone()));
                    next = i + 1;
                }
                _ => {}
            }
        }
        if next < s.len() {
            out.push((self::s(&s[next..]), st(next).1.clone()));
        }
    }

    fn ps_cut_detail(&self, s: &[char], out: &mut Vec<(String, String)>) {
        for (han, blk) in runs(s, is_han_detail) {
            if han {
                self.ps_hmm_cut(blk, out);
                continue;
            }
            // re_skip_detail: ([\.0-9]+|[a-zA-Z0-9]+)
            let num = |c: char| c == '.' || c.is_ascii_digit();
            let mut pieces: Vec<&[char]> = Vec::new();
            let (mut i, mut start) = (0, 0);
            while i < blk.len() {
                let j = if num(blk[i]) {
                    let mut j = i;
                    while j < blk.len() && num(blk[j]) {
                        j += 1;
                    }
                    j
                } else if blk[i].is_ascii_alphanumeric() {
                    let mut j = i;
                    while j < blk.len() && blk[j].is_ascii_alphanumeric() {
                        j += 1;
                    }
                    j
                } else {
                    i += 1;
                    continue;
                };
                pieces.push(&blk[start..i]);
                pieces.push(&blk[i..j]);
                i = j;
                start = j;
            }
            pieces.push(&blk[start..]);
            for x in pieces {
                if x.is_empty() {
                    continue;
                }
                let tag = if num(x[0]) {
                    "m"
                } else if x[0].is_ascii_alphanumeric() {
                    "eng"
                } else {
                    "x"
                };
                out.push((self::s(x), tag.into()));
            }
        }
    }

    fn tag_or_x(&self, w: &str) -> String {
        self.word_tag(w).unwrap_or("x").to_string()
    }

    fn ps_cut_dag(&self, s: &[char], out: &mut Vec<(String, String)>) {
        let route = self.route(s);
        let n = s.len();
        let mut buf: Vec<char> = Vec::new();
        let flush = |buf: &mut Vec<char>, out: &mut Vec<(String, String)>| {
            if buf.is_empty() {
                return;
            }
            let w = self::s(buf);
            if buf.len() == 1 {
                out.push((w.clone(), self.tag_or_x(&w)));
            } else if self.freq(&w).unwrap_or(0) == 0 {
                self.ps_cut_detail(buf, out);
            } else {
                for c in buf.iter() {
                    let e = c.to_string();
                    let t = self.tag_or_x(&e);
                    out.push((e, t));
                }
            }
            buf.clear();
        };
        let mut x = 0;
        while x < n {
            let y = route[x] + 1;
            if y - x == 1 {
                buf.push(s[x]);
            } else {
                flush(&mut buf, out);
                let w = self::s(&s[x..y]);
                let t = self.tag_or_x(&w);
                out.push((w, t));
            }
            x = y;
        }
        flush(&mut buf, out);
    }

    /// `jieba.posseg.lcut`.
    pub fn posseg(&self, text: &str) -> Vec<(String, String)> {
        let s: Vec<char> = text.chars().collect();
        let mut out = Vec::new();
        for (han, blk) in runs(&s, is_han_internal) {
            if han {
                self.ps_cut_dag(blk, &mut out);
                continue;
            }
            for piece in self.skip_split(blk) {
                match piece {
                    Ok(sep) => out.push((sep, "x".into())),
                    Err(text) => {
                        for &c in text {
                            let tag = if c == '.' || c.is_ascii_digit() {
                                "m"
                            } else if text[0].is_ascii_alphanumeric() {
                                "eng"
                            } else {
                                "x"
                            };
                            out.push((c.to_string(), tag.into()));
                        }
                    }
                }
            }
        }
        out
    }

    // ---- pypinyin -----------------------------------------------------------

    fn phrase(&self, w: &str) -> Option<usize> {
        let i = lower(&self.phrases, w);
        (self.phrases.get(i).map(|p| &**p) == Some(w)).then_some(i)
    }

    fn phrase_prefix(&self, w: &str) -> bool {
        let i = lower(&self.phrases, w);
        self.phrases.get(i).is_some_and(|p| p.starts_with(w))
    }

    /// pypinyin's mmseg with `no_non_phrases`.
    fn mmseg(&self, text: &[char]) -> Vec<Vec<char>> {
        let mut out = Vec::new();
        let mut remain = text;
        'outer: while !remain.is_empty() {
            let mut last_valid = 0;
            let mut word = String::new();
            for index in 0..remain.len() {
                word.push(remain[index]);
                if self.phrase_prefix(&word) {
                    if self.phrase(&word).is_some() {
                        last_valid = index + 1;
                    }
                } else {
                    if last_valid > 0 {
                        out.push(remain[..last_valid].to_vec());
                        remain = &remain[last_valid..];
                    } else {
                        out.push(vec![remain[0]]);
                        remain = &remain[1..];
                    }
                    continue 'outer;
                }
            }
            if last_valid > 0 {
                out.push(remain[..last_valid].to_vec());
                remain = &remain[last_valid..];
            } else {
                if self.phrase(&s(remain)).is_none() {
                    out.extend(remain.iter().map(|&c| vec![c]));
                } else {
                    out.push(remain.to_vec());
                }
                break;
            }
        }
        out
    }

    /// `lazy_pinyin(word, neutral_tone_with_five=True)` in the INITIALS and
    /// FINALS_TONE3 styles, together.
    fn lazy_pinyin(&self, word: &[char]) -> Vec<(String, String)> {
        let mut out = Vec::new();
        for (han, run) in runs(word, |c| self.is_hans(c)) {
            if !han {
                let t = s(run);
                out.push((t.clone(), t));
                continue;
            }
            for piece in self.mmseg(run) {
                let syl: Vec<u16> = match self.phrase(&s(&piece)) {
                    Some(i) if piece.len() > 1 && !self.phrase_syl[i].is_empty() => self.phrase_syl[i].clone(),
                    Some(i) if piece.len() == 1 && !self.phrase_syl[i].is_empty() => self.phrase_syl[i].clone(),
                    _ => piece.iter().map(|c| self.chars.get(c).copied().unwrap_or(u16::MAX)).collect(),
                };
                for (k, i) in syl.into_iter().enumerate() {
                    out.push(match self.syllables.get(i as usize) {
                        Some(p) => p.clone(),
                        None => {
                            let t = piece[k.min(piece.len() - 1)].to_string();
                            (t.clone(), t)
                        }
                    });
                }
            }
        }
        out
    }

    fn finals(&self, word: &[char]) -> Vec<String> {
        let mut f: Vec<String> = self.lazy_pinyin(word).into_iter().map(|p| p.1).collect();
        fix_en(word, &mut f);
        f
    }
}

/// `嗯` reads n2.
fn fix_en(word: &[char], finals: &mut [String]) {
    for (i, &c) in word.iter().enumerate() {
        if c == '嗯' && i < finals.len() {
            finals[i] = "n2".into();
        }
    }
}

/// Runs of characters that are, and are not, in a class, in order.
fn runs(s: &[char], class: impl Fn(char) -> bool) -> Vec<(bool, &[char])> {
    let mut out = Vec::new();
    let mut start = 0;
    for i in 1..=s.len() {
        if i == s.len() || class(s[i]) != class(s[start]) {
            if start < s.len() {
                out.push((class(s[start]), &s[start..i]));
            }
            start = i;
        }
    }
    out
}

// ---- tone sandhi ------------------------------------------------------------

fn last(x: &str) -> Option<char> {
    x.chars().last()
}

/// `x[:-1] + t`.
fn retone(x: &mut String, t: &str) {
    x.pop();
    x.push_str(t);
}

fn all_three(f: &[String]) -> bool {
    f.iter().all(|x| last(x) == Some('3'))
}

fn is_x_eng(pos: &str) -> bool {
    pos == "x" || pos == "eng"
}

struct Sandhi {
    must_neural: HashSet<&'static str>,
    must_not_neural: HashSet<&'static str>,
}

fn sandhi() -> &'static Sandhi {
    static S: OnceLock<Sandhi> = OnceLock::new();
    S.get_or_init(|| Sandhi {
        must_neural: MUST_NEURAL.split(' ').collect(),
        must_not_neural: MUST_NOT_NEURAL.split(' ').collect(),
    })
}

const PUNC_SANDHI: &str = "、：，；。？！“”‘’':,;.?!";

fn tail2(w: &[char]) -> String {
    s(&w[w.len().saturating_sub(2)..])
}

impl Zh {
    fn split_word(&self, word: &[char]) -> (Vec<char>, Vec<char>) {
        let mut list = self.cut_for_search(word);
        list.sort_by_key(|w| w.chars().count());
        let first: Vec<char> = list[0].chars().collect();
        let begin = find(word, &first);
        if begin == Some(0) {
            (first.clone(), word[first.len().min(word.len())..].to_vec())
        } else {
            (word[..word.len().saturating_sub(first.len())].to_vec(), first)
        }
    }

    fn neural_sandhi(&self, word: &[char], pos: &str, mut finals: Vec<String>) -> Vec<String> {
        let sd = sandhi();
        let w = s(word);
        if sd.must_not_neural.contains(w.as_str()) {
            return finals;
        }
        let p0 = pos.chars().next();
        for j in 1..word.len() {
            if word[j] == word[j - 1] && matches!(p0, Some('n' | 'v' | 'a')) {
                if let Some(f) = finals.get_mut(j) {
                    retone(f, "5");
                }
            }
        }
        let ge = word.iter().position(|&c| c == '个');
        let lastc = word.last().copied();
        let n = word.len();
        let set_last = |f: &mut Vec<String>| {
            if let Some(x) = f.last_mut() {
                retone(x, "5");
            }
        };
        if lastc.is_some_and(|c| "吧呢啊呐噻嘛吖嗨呐哦哒滴哩哟喽啰耶喔诶".contains(c)) {
            set_last(&mut finals);
        } else if lastc.is_some_and(|c| "的地得".contains(c)) {
            set_last(&mut finals);
        } else if n == 1 && "了着过".contains(word[0]) && matches!(pos, "ul" | "uz" | "ug") {
            set_last(&mut finals);
        } else if n > 1 && "们子".contains(word[n - 1]) && matches!(pos, "r" | "n") {
            set_last(&mut finals);
        } else if n > 1 && "上下".contains(word[n - 1]) && matches!(pos, "s" | "l" | "f") {
            set_last(&mut finals);
        } else if n > 1 && "来去".contains(word[n - 1]) && "上下进出回过起开".contains(word[n - 2]) {
            set_last(&mut finals);
        } else if ge.is_some_and(|g| {
            g >= 1 && (self.is_numeric(word[g - 1]) || "几有两半多各整每做是".contains(word[g - 1]))
        }) || w == "个"
        {
            let g = ge.unwrap();
            if let Some(f) = finals.get_mut(g) {
                retone(f, "5");
            }
        } else if sd.must_neural.contains(w.as_str()) || sd.must_neural.contains(tail2(word).as_str()) {
            set_last(&mut finals);
        }

        let (a, b) = self.split_word(word);
        let cut = a.len().min(finals.len());
        let mut parts = [finals[..cut].to_vec(), finals[cut..].to_vec()];
        for (i, sub) in [a, b].iter().enumerate() {
            let sw = s(sub);
            if sd.must_neural.contains(sw.as_str()) || sd.must_neural.contains(tail2(sub).as_str()) {
                if let Some(x) = parts[i].last_mut() {
                    retone(x, "5");
                }
            }
        }
        let [x, y] = parts;
        [x, y].concat()
    }

    fn bu_sandhi(&self, word: &[char], mut finals: Vec<String>) -> Vec<String> {
        if word.len() == 3 && word[1] == '不' {
            if let Some(f) = finals.get_mut(1) {
                retone(f, "5");
            }
        } else {
            for i in 0..word.len() {
                if word[i] == '不' && i + 1 < word.len() && finals.get(i + 1).and_then(|f| last(f)) == Some('4') {
                    retone(&mut finals[i], "2");
                }
            }
        }
        finals
    }

    fn yi_sandhi(&self, word: &[char], mut finals: Vec<String>) -> Vec<String> {
        if word.contains(&'一') && word.iter().filter(|&&c| c != '一').all(|&c| self.is_numeric(c)) {
            return finals;
        }
        if word.len() == 3 && word[1] == '一' && word[0] == word[2] {
            if let Some(f) = finals.get_mut(1) {
                retone(f, "5");
            }
        } else if word.starts_with(&['第', '一']) {
            if let Some(f) = finals.get_mut(1) {
                retone(f, "1");
            }
        } else {
            for i in 0..word.len() {
                if word[i] == '一' && i + 1 < word.len() {
                    let next = finals.get(i + 1).and_then(|f| last(f));
                    if matches!(next, Some('4' | '5')) {
                        retone(&mut finals[i], "2");
                    } else if !PUNC_SANDHI.contains(word[i + 1]) {
                        retone(&mut finals[i], "4");
                    }
                }
            }
        }
        finals
    }

    fn three_sandhi(&self, word: &[char], mut finals: Vec<String>) -> Vec<String> {
        let n = word.len();
        if n == 2 && all_three(&finals) {
            retone(&mut finals[0], "2");
        } else if n == 3 {
            let (a, _) = self.split_word(word);
            if all_three(&finals) {
                if a.len() == 2 {
                    retone(&mut finals[0], "2");
                    retone(&mut finals[1], "2");
                } else if a.len() == 1 {
                    retone(&mut finals[1], "2");
                }
            } else {
                let cut = a.len().min(finals.len());
                let mut parts = [finals[..cut].to_vec(), finals[cut..].to_vec()];
                for i in 0..2 {
                    if all_three(&parts[i]) && parts[i].len() == 2 {
                        retone(&mut parts[i][0], "2");
                    } else if i == 1
                        && !all_three(&parts[1])
                        && parts[1].first().and_then(|f| last(f)) == Some('3')
                        && parts[0].last().and_then(|f| last(f)) == Some('3')
                    {
                        let l = parts[0].len() - 1;
                        retone(&mut parts[0][l], "2");
                    }
                    finals = parts.concat();
                }
            }
        } else if n == 4 {
            let mut out = Vec::new();
            let cut = 2.min(finals.len());
            for mut sub in [finals[..cut].to_vec(), finals[cut..].to_vec()] {
                if all_three(&sub) {
                    if let Some(f) = sub.first_mut() {
                        retone(f, "2");
                    }
                }
                out.extend(sub);
            }
            finals = out;
        }
        finals
    }

    fn modified_tone(&self, word: &[char], pos: &str, finals: Vec<String>) -> Vec<String> {
        let f = self.bu_sandhi(word, finals);
        let f = self.yi_sandhi(word, f);
        let f = self.neural_sandhi(word, pos, f);
        self.three_sandhi(word, f)
    }

    fn pre_merge(&self, seg: Vec<(String, String)>) -> Vec<(String, String)> {
        // _merge_bu
        let mut out: Vec<(String, String)> = Vec::new();
        for i in 0..seg.len() {
            let (mut word, pos) = seg[i].clone();
            if !is_x_eng(&pos) && i > 0 && seg[i - 1].0 == "不" {
                word = format!("不{word}");
            }
            let next_pos = seg.get(i + 1).map(|x| x.1.as_str());
            if word != "不" || next_pos.is_none() || next_pos.is_some_and(is_x_eng) {
                out.push((word, pos));
            }
        }
        let seg = out;

        // _merge_yi
        let mut out: Vec<(String, String)> = Vec::new();
        let mut skip = false;
        for i in 0..seg.len() {
            if skip {
                skip = false;
                continue;
            }
            let (word, pos) = &seg[i];
            if i >= 1
                && word == "一"
                && i + 1 < seg.len()
                && seg[i - 1].0 == seg[i + 1].0
                && seg[i - 1].1 == "v"
                && !is_x_eng(&seg[i + 1].1)
            {
                let l = out.len() - 1;
                out[l].0 = format!("{}一{}", out[l].0, seg[i + 1].0);
                skip = true;
            } else {
                out.push((word.clone(), pos.clone()));
            }
        }
        let seg = out;
        let mut out: Vec<(String, String)> = Vec::new();
        for (word, pos) in seg {
            if out.last().is_some_and(|l| l.0 == "一") && !is_x_eng(&pos) {
                out.last_mut().unwrap().0.push_str(&word);
            } else {
                out.push((word, pos));
            }
        }
        let seg = out;

        // _merge_reduplication
        let mut out: Vec<(String, String)> = Vec::new();
        for (word, pos) in seg {
            if out.last().is_some_and(|l| l.0 == word) && !is_x_eng(&pos) {
                out.last_mut().unwrap().0.push_str(&word);
            } else {
                out.push((word, pos));
            }
        }
        let seg = out;

        let seg = self.merge_three(seg, false);
        let seg = self.merge_three(seg, true);

        // _merge_er
        let mut out: Vec<(String, String)> = Vec::new();
        for (i, (word, pos)) in seg.into_iter().enumerate() {
            if i >= 1 && word == "儿" && !is_x_eng(&out.last().unwrap().1) {
                out.last_mut().unwrap().0.push_str(&word);
            } else {
                out.push((word, pos));
            }
        }
        out
    }

    /// `_merge_continuous_three_tones` (and its `_2`: by the last and first
    /// syllables only).
    fn merge_three(&self, seg: Vec<(String, String)>, edges: bool) -> Vec<(String, String)> {
        let finals: Vec<Vec<String>> = seg
            .iter()
            .map(|(w, p)| {
                if is_x_eng(p) {
                    vec!["0".to_string()]
                } else {
                    let c: Vec<char> = w.chars().collect();
                    self.finals(&c)
                }
            })
            .collect();
        let redup = |w: &str| {
            let c: Vec<char> = w.chars().collect();
            c.len() == 2 && c[0] == c[1]
        };
        let mut out: Vec<(String, String)> = Vec::new();
        let mut merged = vec![false; seg.len()];
        for i in 0..seg.len() {
            let (word, pos) = &seg[i];
            let threes = i >= 1
                && !is_x_eng(pos)
                && if edges {
                    finals[i - 1].last().and_then(|f| last(f)) == Some('3')
                        && finals[i].first().and_then(|f| last(f)) == Some('3')
                } else {
                    all_three(&finals[i - 1]) && all_three(&finals[i])
                }
                && !merged[i - 1];
            if threes
                && !redup(&seg[i - 1].0)
                && seg[i - 1].0.chars().count() + word.chars().count() <= 3
            {
                out.last_mut().unwrap().0.push_str(word);
                merged[i] = true;
            } else {
                out.push((word.clone(), pos.clone()));
            }
        }
        out
    }
}

fn find(hay: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

// ---- the front end ----------------------------------------------------------

const MUST_ERHUA: &str = "小院儿 胡同儿 范儿 老汉儿 撒欢儿 寻老礼儿 妥妥儿 媳妇儿";
const NOT_ERHUA: &str = "虐儿 为儿 护儿 瞒儿 救儿 替儿 有儿 一儿 我儿 俺儿 妻儿 拐儿 聋儿 乞儿 患儿 幼儿 孤儿 婴儿 婴幼儿 连体儿 脑瘫儿 流浪儿 体弱儿 混血儿 蜜雪儿 舫儿 祖儿 美儿 应采儿 可儿 侄儿 孙儿 侄孙儿 女儿 男儿 红孩儿 花儿 虫儿 马儿 鸟儿 猪儿 猫儿 狗儿 少儿";
const PUNC: &str = ";:,.!?—…\"()“”";

fn zh_map(p: &str) -> Option<&'static str> {
    static M: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    M.get_or_init(|| {
        let mut m: HashMap<&'static str, &'static str> = [
            ("b", "ㄅ"), ("p", "ㄆ"), ("m", "ㄇ"), ("f", "ㄈ"), ("d", "ㄉ"), ("t", "ㄊ"), ("n", "ㄋ"),
            ("l", "ㄌ"), ("g", "ㄍ"), ("k", "ㄎ"), ("h", "ㄏ"), ("j", "ㄐ"), ("q", "ㄑ"), ("x", "ㄒ"),
            ("zh", "ㄓ"), ("ch", "ㄔ"), ("sh", "ㄕ"), ("r", "ㄖ"), ("z", "ㄗ"), ("c", "ㄘ"), ("s", "ㄙ"),
            ("a", "ㄚ"), ("o", "ㄛ"), ("e", "ㄜ"), ("ie", "ㄝ"), ("ai", "ㄞ"), ("ei", "ㄟ"), ("ao", "ㄠ"),
            ("ou", "ㄡ"), ("an", "ㄢ"), ("en", "ㄣ"), ("ang", "ㄤ"), ("eng", "ㄥ"), ("er", "ㄦ"),
            ("i", "ㄧ"), ("u", "ㄨ"), ("v", "ㄩ"), ("ii", "ㄭ"), ("iii", "十"), ("ve", "月"), ("ia", "压"),
            ("ian", "言"), ("iang", "阳"), ("iao", "要"), ("in", "阴"), ("ing", "应"), ("iong", "用"),
            ("iou", "又"), ("ong", "中"), ("ua", "穵"), ("uai", "外"), ("uan", "万"), ("uang", "王"),
            ("uei", "为"), ("uen", "文"), ("ueng", "瓮"), ("uo", "我"), ("van", "元"), ("vn", "云"),
        ]
        .into_iter()
        .collect();
        for p in [";", ":", ",", ".", "!", "?", "/", "—", "…", "\"", "(", ")", "“", "”", " ", "1", "2", "3", "4", "5", "R"] {
            m.insert(p, p);
        }
        m
    })
    .get(p)
    .copied()
}

struct Token {
    tag: String,
    phonemes: Option<String>,
    whitespace: String,
}

impl Zh {
    fn initials_finals(&self, word: &[char]) -> (Vec<String>, Vec<String>) {
        let py = self.lazy_pinyin(word);
        let mut ini: Vec<String> = py.iter().map(|p| p.0.clone()).collect();
        let mut fin: Vec<String> = py.into_iter().map(|p| p.1).collect();
        fix_en(word, &mut fin);
        let n = ini.len().min(fin.len());
        ini.truncate(n);
        fin.truncate(n);
        for (c, v) in ini.iter().zip(fin.iter_mut()) {
            let mut it = v.chars();
            if it.next() == Some('i') && it.next().is_some_and(|d| d.is_ascii_digit()) {
                if matches!(c.as_str(), "z" | "c" | "s") {
                    *v = v.replace('i', "ii");
                } else if matches!(c.as_str(), "zh" | "ch" | "sh" | "r") {
                    *v = v.replace('i', "iii");
                }
            }
        }
        (ini, fin)
    }

    fn erhua(&self, mut ini: Vec<String>, mut fin: Vec<String>, word: &[char], pos: &str) -> (Vec<String>, Vec<String>) {
        let n = fin.len();
        if n > 0 && word.get(n - 1) == Some(&'儿') && fin[n - 1] == "er1" {
            fin[n - 1] = "er2".into();
        }
        let w = s(word);
        let must = MUST_ERHUA.split(' ').any(|x| x == w);
        let not = |x: &str| NOT_ERHUA.split(' ').any(|y| y == x);
        if !must && (not(&w) || matches!(pos, "a" | "j" | "nr")) {
            return (ini, fin);
        }
        if fin.len() != word.len() {
            return (ini, fin);
        }
        let (mut ni, mut nf): (Vec<String>, Vec<String>) = (Vec::new(), Vec::new());
        for i in 0..fin.len() {
            if i == fin.len() - 1
                && word[i] == '儿'
                && (fin[i] == "er2" || fin[i] == "er5")
                && !not(&tail2(word))
                && !nf.is_empty()
            {
                let l: &mut String = nf.last_mut().unwrap();
                let t = l.pop();
                l.push('R');
                if let Some(t) = t {
                    l.push(t);
                }
            } else {
                ni.push(std::mem::take(&mut ini[i]));
                nf.push(std::mem::take(&mut fin[i]));
            }
        }
        (ni, nf)
    }

    /// `ZHFrontend.__call__`: Chinese (no Latin letters) to phonemes.
    fn frontend(&self, text: &str) -> String {
        let seg = self.pre_merge(self.posseg(text));
        let mut tokens: Vec<Token> = Vec::new();
        for (word, mut pos) in seg {
            let wc: Vec<char> = word.chars().collect();
            let is_punc = wc.len() == 1 && PUNC.contains(wc[0]);
            if pos == "x"
                && wc.iter().min().is_some_and(|&c| c >= '\u{4E00}')
                && wc.iter().max().is_some_and(|&c| c <= '\u{9FFF}')
            {
                pos = "X".into();
            } else if pos != "x" && is_punc {
                pos = "x".into();
            }
            if pos == "x" || pos == "eng" {
                if !(!wc.is_empty() && wc.iter().all(|&c| self.is_space(c))) {
                    let phonemes = (pos == "x" && is_punc).then(|| word.clone());
                    tokens.push(Token { tag: pos, phonemes, whitespace: String::new() });
                } else if let Some(t) = tokens.last_mut() {
                    t.whitespace.push_str(&word);
                }
                continue;
            } else if let Some(t) = tokens.last_mut() {
                if t.tag != "x" && t.tag != "eng" && t.whitespace.is_empty() {
                    t.whitespace = "/".into();
                }
            }

            let (ini, fin) = self.initials_finals(&wc);
            let fin = self.modified_tone(&wc, &pos, fin);
            let (ini, fin) = self.erhua(ini, fin, &wc, &pos);

            let mut phones: Vec<String> = Vec::new();
            for (c, v) in ini.iter().zip(fin.iter()) {
                if !c.is_empty() {
                    phones.push(c.clone());
                }
                let v_punc = v.chars().count() == 1 && PUNC.contains(v.as_str());
                if !v.is_empty() && (!v_punc || v != c) {
                    phones.push(v.clone());
                }
            }
            let joined = phones.join("_").replace("_eR", "_er").replace('R', "_R");
            let mut spaced = String::new();
            for ch in joined.chars() {
                if self.is_digit(ch) {
                    spaced.push('_');
                }
                spaced.push(ch);
            }
            let ph: String = spaced.split('_').map(|p| zh_map(p).unwrap_or(UNK)).collect();
            tokens.push(Token { tag: pos, phonemes: Some(ph), whitespace: String::new() });
        }
        tokens
            .into_iter()
            .map(|t| format!("{}{}", t.phonemes.as_deref().unwrap_or(UNK), t.whitespace))
            .collect()
    }

    fn strip<'b>(&self, t: &'b str) -> &'b str {
        t.trim_matches(|c| self.is_space(c))
    }

    /// `ZHG2P(version='1.1')(text)`, without an English voice: Latin words
    /// become the unknown mark.
    pub fn phonemes(&self, text: &str) -> String {
        if self.strip(text).is_empty() {
            return String::new();
        }
        let text = self.an2cn(text);
        let text = map_punctuation(&text);
        let text = self.strip(&text).to_string();
        static SPLIT: OnceLock<Regex> = OnceLock::new();
        let split = SPLIT.get_or_init(|| Regex::new(r"([A-Za-z '\-]*[A-Za-z][A-Za-z '\-]*)|([^A-Za-z]+)").unwrap());
        let mut segments = Vec::new();
        for c in split.captures_iter(&text) {
            let en = c.get(1).map(|m| self.strip(m.as_str())).unwrap_or("");
            let zh = c.get(2).map(|m| self.strip(m.as_str())).unwrap_or("");
            if !zh.is_empty() {
                segments.push(self.frontend(zh));
            } else {
                let _ = en;
                segments.push(UNK.to_string());
            }
        }
        segments.join(" ")
    }
}

fn map_punctuation(t: &str) -> String {
    t.replace('、', ", ")
        .replace('，', ", ")
        .replace('。', ". ")
        .replace('．', ". ")
        .replace('！', "! ")
        .replace('：', ": ")
        .replace('；', "; ")
        .replace('？', "? ")
        .replace('«', " “")
        .replace('»', "” ")
        .replace('《', " “")
        .replace('》', "” ")
        .replace('「', " “")
        .replace('」', "” ")
        .replace('【', " “")
        .replace('】', "” ")
        .replace('（', " (")
        .replace('）', ") ")
}

// ---- cn2an: numbers read out ------------------------------------------------

const MEASURE: &str = "斤|克|千克|公斤|吨|米|厘米|毫米|公里|升|毫升|元|角|分|个|只|条|张|块|瓶|杯|份|本|辆|台|匹|头|位|亩|小时|分钟|秒|天|半";
const LOW: [char; 10] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
const UNITS: [&str; 16] = ["", "十", "百", "千", "万", "十", "百", "千", "亿", "十", "百", "千", "万", "十", "百", "千"];

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap()
}

/// `preprocess(full_angle_to_half_angle)` then the check: ASCII digits, `.`
/// and `-` only.
fn an_clean(t: &str) -> Option<String> {
    let s: String = t
        .chars()
        .map(|c| match c as u32 {
            0x3000 => ' ',
            0xFF01..=0xFF5E => char::from_u32(c as u32 - 0xFEE0).unwrap(),
            _ => c,
        })
        .collect();
    s.chars().all(|c| c.is_ascii_digit() || c == '.' || c == '-').then_some(s)
}

fn integer_low(d: &str) -> Option<String> {
    let d = d.trim_start_matches('0');
    let d = if d.is_empty() { "0" } else { d };
    let n = d.len();
    if n > UNITS.len() {
        return None;
    }
    let mut out = String::new();
    for (i, c) in d.chars().enumerate() {
        let v = c.to_digit(10)? as usize;
        let u = n - i - 1;
        if v != 0 {
            out.push(LOW[v]);
            out.push_str(UNITS[u]);
        } else {
            if u % 4 == 0 {
                out.push(LOW[0]);
                out.push_str(UNITS[u]);
            }
            if i > 0 && !out.ends_with('零') {
                out.push(LOW[0]);
            }
        }
    }
    let out = out.replace("零零", "零").replace("零万", "万").replace("零亿", "亿").replace("亿万", "亿");
    let out = out.trim_matches('零').to_string();
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| re("([万亿])零([一二三四五六七八九壹贰叁肆伍陆柒捌玖][千仟])"));
    let mut out = r.replace_all(&out, "$1$2").into_owned();
    if out.starts_with("一十") {
        out = out.chars().skip(1).collect();
    }
    if out.is_empty() {
        out = "零".into();
    }
    Some(out)
}

/// `An2Cn().an2cn(t, "low")`, None where it would fail.
fn an2cn_low(t: &str) -> Option<String> {
    if t.is_empty() {
        return None;
    }
    let t = an_clean(t)?;
    let (sign, t) = match t.strip_prefix('-') {
        Some(r) => ("负", r.to_string()),
        None => ("", t),
    };
    let parts: Vec<&str> = t.split('.').collect();
    let body = match parts.as_slice() {
        [i] => integer_low(i)?,
        [i, d] => {
            let mut s = integer_low(i)?;
            let d: String = d.chars().take(16).collect();
            if !d.is_empty() {
                s.push('点');
                for c in d.chars() {
                    s.push(LOW[c.to_digit(10)? as usize]);
                }
            }
            s
        }
        _ => return None,
    };
    Some(format!("{sign}{body}"))
}

fn an2cn_direct(t: &str) -> Option<String> {
    if t.is_empty() {
        return None;
    }
    let t = an_clean(t)?;
    let (sign, t) = match t.strip_prefix('-') {
        Some(r) => ("负", r.to_string()),
        None => ("", t),
    };
    let mut s = String::from(sign);
    for c in t.chars() {
        if c == '.' {
            s.push('点');
        } else {
            s.push(LOW[c.to_digit(10)? as usize]);
        }
    }
    Some(s)
}

impl Zh {
    /// `cn2an.transform(text, "an2cn")`.
    fn an2cn(&self, text: &str) -> String {
        if !text.bytes().any(|b| b.is_ascii_digit()) {
            return text.to_string();
        }
        struct Res {
            range: Regex,
            date: Regex,
            year: Regex,
            num: Regex,
            frac: Regex,
            pct: Regex,
            cel: Regex,
            number: Regex,
        }
        static R: OnceLock<Res> = OnceLock::new();
        let r = R.get_or_init(|| Res {
            range: re(&format!(r"(\d+(\.\d+)?-\d+(\.\d+)?)({MEASURE})")),
            date: re(r"(\d{2,4}年)?(\d{1,2}月)?(\d{1,2}日)?"),
            year: re(r"\d+年"),
            num: re(r"\d+"),
            frac: re(r"\d+/\d+"),
            pct: re(r"-?(\d+\.)?\d+%"),
            cel: re(r"\d+℃"),
            number: re(r"-?(\d+\.)?\d+"),
        });
        // A sub whose conversion fails keeps the text.
        let t = r.range.replace_all(text, |c: &regex::Captures| {
            let m = &c[1];
            let conv = || -> Option<String> {
                let parts: Vec<&str> = m.split('-').collect();
                if parts.len() != 2 {
                    return None;
                }
                Some(format!("{}到{}", an2cn_low(parts[0])?, an2cn_low(parts[1])?))
            };
            format!("{}{}", conv().unwrap_or_else(|| m.to_string()), &c[4])
        });
        let t = r.date.replace_all(&t, |c: &regex::Captures| {
            let m = &c[0];
            if m.is_empty() {
                return String::new();
            }
            let conv = || -> Option<String> {
                let mut fail = false;
                let y = r.year.replace_all(m, |c: &regex::Captures| {
                    let d = c[0].trim_end_matches('年');
                    match an2cn_direct(d) {
                        Some(v) => format!("{v}年"),
                        None => {
                            fail = true;
                            c[0].to_string()
                        }
                    }
                });
                let out = r.num.replace_all(&y, |c: &regex::Captures| match an2cn_low(&c[0]) {
                    Some(v) => v,
                    None => {
                        fail = true;
                        c[0].to_string()
                    }
                });
                (!fail).then(|| out.into_owned())
            };
            conv().unwrap_or_else(|| m.to_string())
        });
        let t = r.frac.replace_all(&t, |c: &regex::Captures| {
            let m = &c[0];
            let (a, b) = m.split_once('/').unwrap();
            match (an2cn_low(a), an2cn_low(b)) {
                (Some(a), Some(b)) => format!("{b}分之{a}"),
                _ => m.to_string(),
            }
        });
        let t = r.pct.replace_all(&t, |c: &regex::Captures| {
            let m = &c[0];
            match an2cn_low(m.trim_end_matches('%')) {
                Some(v) => format!("百分之{v}"),
                None => m.to_string(),
            }
        });
        let t = r.cel.replace_all(&t, |c: &regex::Captures| {
            let m = &c[0];
            match an2cn_low(m.trim_end_matches('℃')) {
                Some(v) => format!("{v}摄氏度"),
                None => m.to_string(),
            }
        });
        let t = r.number.replace_all(&t, |c: &regex::Captures| an2cn_low(&c[0]).unwrap_or_else(|| c[0].to_string()));
        t.into_owned()
    }
}

const MUST_NEURAL: &str = "麻烦 麻利 鸳鸯 高粱 骨头 骆驼 马虎 首饰 馒头 馄饨 风筝 难为 队伍 阔气 闺女 门道 锄头 铺盖 铃铛 铁匠 钥匙 里脊 里头 部分 那么 道士 造化 迷糊 连累 这么 这个 运气 过去 软和 转悠 踏实 跳蚤 跟头 趔趄 财主 豆腐 讲究 记性 记号 认识 规矩 见识 裁缝 补丁 衣裳 衣服 衙门 街坊 行李 行当 蛤蟆 蘑菇 薄荷 葫芦 葡萄 萝卜 荸荠 苗条 苗头 苍蝇 芝麻 舒服 舒坦 舌头 自在 膏药 脾气 脑袋 脊梁 能耐 胳膊 胭脂 胡萝 胡琴 胡同 聪明 耽误 耽搁 耷拉 耳朵 老爷 老实 老婆 戏弄 将军 翻腾 罗嗦 罐头 编辑 结实 红火 累赘 糨糊 糊涂 精神 粮食 簸箕 篱笆 算计 算盘 答应 笤帚 笑语 笑话 窟窿 窝囊 窗户 稳当 稀罕 称呼 秧歌 秀气 秀才 福气 祖宗 砚台 码头 石榴 石头 石匠 知识 眼睛 眯缝 眨巴 眉毛 相声 盘算 白净 痢疾 痛快 疟疾 疙瘩 疏忽 畜生 生意 甘蔗 琵琶 琢磨 琉璃 玻璃 玫瑰 玄乎 狐狸 状元 特务 牲口 牙碜 牌楼 爽快 爱人 热闹 烧饼 烟筒 烂糊 点心 炊帚 灯笼 火候 漂亮 滑溜 溜达 温和 清楚 消息 浪头 活泼 比方 正经 欺负 模糊 槟榔 棺材 棒槌 棉花 核桃 栅栏 柴火 架势 枕头 枇杷 机灵 本事 木头 木匠 朋友 月饼 月亮 暖和 明白 时候 新鲜 故事 收拾 收成 提防 挖苦 挑剔 指甲 指头 拾掇 拳头 拨弄 招牌 招呼 抬举 护士 折腾 扫帚 打量 打算 打扮 打听 打发 扎实 扁担 戒指 懒得 意识 意思 悟性 怪物 思量 怎么 念头 念叨 别人 快活 忙活 志气 心思 得罪 张罗 弟兄 开通 应酬 庄稼 干事 帮手 帐篷 希罕 师父 师傅 巴结 巴掌 差事 工夫 岁数 屁股 尾巴 少爷 小气 小伙 将就 对头 对付 寡妇 家伙 客气 实在 官司 学问 字号 嫁妆 媳妇 媒人 婆家 娘家 委屈 姑娘 姐夫 妯娌 妥当 妖精 奴才 女婿 头发 太阳 大爷 大方 大意 大夫 多少 多么 外甥 壮实 地道 地方 在乎 困难 嘴巴 嘱咐 嘟囔 嘀咕 喜欢 喇嘛 喇叭 商量 唾沫 哑巴 哈欠 哆嗦 咳嗽 和尚 告诉 告示 含糊 吓唬 后头 名字 名堂 合同 吆喝 叫唤 口袋 厚道 厉害 千斤 包袱 包涵 匀称 勤快 动静 动弹 功夫 力气 前头 刺猬 刺激 别扭 利落 利索 利害 分析 出息 凑合 凉快 冷战 冤枉 冒失 养活 关系 先生 兄弟 便宜 使唤 佩服 作坊 体面 位置 似的 伙计 休息 什么 人家 亲戚 亲家 交情 云彩 事情 买卖 主意 丫头 丧气 两口 东西 东家 世故 不由 下水 下巴 上头 上司 丈夫 丈人 一辈 那个 菩萨 父亲 母亲 咕噜 邋遢 费用 冤家 甜头 介绍 荒唐 大人 泥鳅 幸福 熟悉 计划 扑腾 蜡烛 姥爷 照顾 喉咙 吉他 弄堂 蚂蚱 凤凰 拖沓 寒碜 糟蹋 倒腾 报复 逻辑 盘缠 喽啰 牢骚 咖喱 扫把 惦记";
const MUST_NOT_NEURAL: &str = "男子 女子 分子 原子 量子 莲子 石子 瓜子 电子 人人 虎虎 幺幺 干嘛 学子 哈哈 数数 袅袅 局地 以下 娃哈哈 花花草草 留得 耕地 想想 熙熙 攘攘 卵子 死死 冉冉 恳恳 佼佼 吵吵 打打 考考 整整 莘莘 落地 算子 家家户户 青青";
