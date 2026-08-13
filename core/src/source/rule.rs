//! The rule engine: legado's little selector language, minus the parts that
//! need a JavaScript runtime.
//!
//! A rule is a string like `class.odd.0@tag.a.0@text`, or `@css:.item h3@text`,
//! or `$.data[*].title`, optionally with a `##pattern##replacement` tail. It is
//! evaluated against an [`Item`] — an element of an HTML page, a node of a JSON
//! reply, or a row of regex captures — and produces a string.
//!
//! Where we cannot honour a rule we say so ([`Unsupported`]) instead of quietly
//! returning nothing. A source that silently yields empty chapters is worse than
//! a source that refuses to load: the first one wastes an hour of downloading
//! and leaves a book full of blank pages.

use scraper::{ElementRef, Html, Node, Selector};
use serde_json::Value;
use std::fmt;

#[derive(Debug, Clone)]
pub struct Unsupported(pub String);

impl fmt::Display for Unsupported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ---------------------------------------------------------------- URL + fetch

/// A URL and the manner of asking for it. legado writes both in one string:
/// `"/search?q={{key}},{\"method\":\"POST\",\"charset\":\"gbk\"}"`.
#[derive(Debug, Clone, Default)]
pub struct UrlSpec {
    pub url: String,
    pub method: String,
    pub body: Option<String>,
    pub charset: Option<String>,
    pub headers: Vec<(String, String)>,
}

impl UrlSpec {
    pub fn plain(url: &str) -> Self {
        UrlSpec {
            url: sanitize_url(url),
            method: "GET".into(),
            ..Default::default()
        }
    }

    /// Interpolate the search terms and split off the options blob.
    pub fn parse(spec: &str, base: &str, key: &str, page: u32) -> Result<Self, String> {
        // A URL that is computed by a script is not a URL we can build. Say so
        // here, or the script text goes to the HTTP client as if it were an
        // address and comes back as an unreadable "invalid uri character".
        if spec.contains("<js>") || spec.contains("@js:") {
            return Err(Unsupported(
                "这个书源的搜索地址是 JavaScript 拼出来的，本机引擎跑不了".into(),
            )
            .0);
        }
        let (raw_url, opts) = split_options(spec);
        // The charset has to be read *before* the keyword is interpolated: a GBK
        // site wants 剑 as %BD%A3, and handing it %E5%89%91 is how you search a
        // Chinese site for a word it has never heard of and conclude it is dead.
        let charset = opts
            .as_deref()
            .and_then(|o| parse_relaxed(o).ok())
            .and_then(|v| v.get("charset").and_then(Value::as_str).map(str::to_string));
        let url = interpolate(raw_url, key, page, base, charset.as_deref())?;
        let mut out = UrlSpec {
            url: sanitize_url(&absolute(base, url.trim())),
            method: "GET".into(),
            ..Default::default()
        };
        if let Some(o) = opts {
            let v: Value = parse_relaxed(&interpolate(&o, key, page, base, charset.as_deref())?)
                .map_err(|e| format!("书源的请求参数不是合法 JSON：{e}"))?;
            if let Some(m) = v.get("method").and_then(Value::as_str) {
                out.method = m.to_uppercase();
            }
            if let Some(b) = v.get("body") {
                out.body = Some(match b {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                });
            }
            if let Some(c) = v.get("charset").and_then(Value::as_str) {
                out.charset = Some(c.to_string());
            }
            if v.get("webView").and_then(Value::as_bool) == Some(true) {
                return Err(Unsupported("这个书源要用浏览器内核（webView）".into()).0);
            }
            if let Some(Value::Object(h)) = v.get("headers") {
                for (k, val) in h {
                    if let Some(s) = val.as_str() {
                        out.headers.push((k.clone(), s.to_string()));
                    }
                }
            }
        }
        Ok(out)
    }
}

/// Find the `,{...}` tail, if the string has one. Splitting on the last `,{`
/// that leaves valid JSON behind, because a query string may well contain
/// commas and braces of its own.
fn split_options(spec: &str) -> (&str, Option<String>) {
    let mut at = None;
    for (i, _) in spec.match_indices(",{") {
        if parse_relaxed(&spec[i + 1..]).is_ok() {
            at = Some(i);
            break;
        }
    }
    match at {
        Some(i) => (&spec[..i], Some(spec[i + 1..].to_string())),
        None => (spec, None),
    }
}

/// legado sheets are written by hand and half of them quote with `'`, which is
/// not JSON and which their Android host accepts anyway. Rejecting those costs
/// the reader a working source over a punctuation mark, so: try it as JSON, and
/// if that fails, try it again with the single quotes read as string delimiters.
fn parse_relaxed(s: &str) -> Result<Value, serde_json::Error> {
    match serde_json::from_str::<Value>(s) {
        Ok(v) => Ok(v),
        Err(e) => {
            if !s.contains('\'') {
                return Err(e);
            }
            serde_json::from_str(&requote(s))
        }
    }
}

/// Swap `'…'` for `"…"`, leaving anything already inside double quotes alone.
fn requote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    let mut in_double = false;
    let mut in_single = false;
    let mut escaped = false;
    for c in s.chars() {
        if escaped {
            out.push(c);
            escaped = false;
            continue;
        }
        match c {
            '\\' => {
                out.push(c);
                escaped = true;
            }
            '"' if in_single => out.push_str("\\\""),
            '"' => {
                in_double = !in_double;
                out.push(c);
            }
            '\'' if !in_double => {
                in_single = !in_single;
                out.push('"');
            }
            _ => out.push(c),
        }
    }
    out
}

/// `{{key}}` and `{{page}}` we can do. Anything else between double braces is
/// JavaScript, and we do not have a JavaScript engine.
fn interpolate(
    s: &str,
    key: &str,
    page: u32,
    base: &str,
    charset: Option<&str>,
) -> Result<String, String> {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find("{{") {
        out.push_str(&rest[..i]);
        let after = &rest[i + 2..];
        let Some(j) = after.find("}}") else {
            out.push_str(&rest[i..]);
            return Ok(out);
        };
        match after[..j].trim() {
            "key" | "searchKey" => out.push_str(&urlencode(key, charset)),
            "page" | "searchPage" => out.push_str(&page.to_string()),
            "baseUrl" => out.push_str(base),
            // `{{page-1}}`, `{{(page-1)*15}}` — sheets say this constantly. It is
            // arithmetic, not JavaScript, and refusing to do arithmetic would be
            // a poor excuse for losing a source.
            other => match arithmetic(other, page) {
                Some(n) => out.push_str(&n.to_string()),
                None => {
                    return Err(Unsupported(format!(
                        "这个书源用了脚本（{{{{{other}}}}}），本机引擎跑不了"
                    ))
                    .0)
                }
            },
        }
        rest = &after[j + 2..];
    }
    out.push_str(rest);
    Ok(out)
}

/// Integer arithmetic over `page`, and nothing else. No identifiers, no calls —
/// if it is not made of numbers, `page`, `+ - * /` and brackets, it is a script
/// and we do not run scripts.
fn arithmetic(expr: &str, page: u32) -> Option<i64> {
    let src = expr.replace("page", &page.to_string());
    if src.is_empty()
        || !src
            .chars()
            .all(|c| c.is_ascii_digit() || "+-*/() ".contains(c))
    {
        return None;
    }
    let bytes: Vec<char> = src.chars().filter(|c| !c.is_whitespace()).collect();
    let mut at = 0usize;
    let v = expr_bp(&bytes, &mut at, 0)?;
    (at == bytes.len()).then_some(v)
}

/// Precedence climbing: `+ -` bind loosest, then `* /`, then brackets.
fn expr_bp(c: &[char], at: &mut usize, min_bp: u8) -> Option<i64> {
    let mut lhs = match c.get(*at)? {
        '(' => {
            *at += 1;
            let v = expr_bp(c, at, 0)?;
            (c.get(*at) == Some(&')')).then_some(())?;
            *at += 1;
            v
        }
        '-' => {
            *at += 1;
            -expr_bp(c, at, 3)?
        }
        d if d.is_ascii_digit() => {
            let start = *at;
            while c.get(*at).is_some_and(char::is_ascii_digit) {
                *at += 1;
            }
            c[start..*at].iter().collect::<String>().parse().ok()?
        }
        _ => return None,
    };
    while let Some(&op) = c.get(*at) {
        let bp = match op {
            '+' | '-' => 1,
            '*' | '/' => 2,
            _ => break,
        };
        if bp < min_bp {
            break;
        }
        *at += 1;
        let rhs = expr_bp(c, at, bp + 1)?;
        lhs = match op {
            '+' => lhs + rhs,
            '-' => lhs - rhs,
            '*' => lhs * rhs,
            '/' => lhs.checked_div(rhs)?,
            _ => unreachable!(),
        };
    }
    Some(lhs)
}

/// Percent-encode the keyword in whatever encoding the site actually reads. A
/// great many Chinese novel sites are still GBK, and they do not answer to UTF-8.
fn urlencode(s: &str, charset: Option<&str>) -> String {
    let encoded;
    let bytes: &[u8] = match charset
        .map(str::trim)
        .filter(|c| !c.eq_ignore_ascii_case("utf-8") && !c.eq_ignore_ascii_case("utf8"))
        .and_then(|c| encoding_rs::Encoding::for_label(c.as_bytes()))
    {
        Some(enc) => {
            encoded = enc.encode(s).0.into_owned();
            &encoded
        }
        None => s.as_bytes(),
    };
    let mut out = String::new();
    for b in bytes {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Sheets write Chinese and spaces straight into a path — `/搜索/剑.html` — which
/// a browser silently encodes and an HTTP client refuses. Encode the bytes that
/// cannot appear in a URI and leave the punctuation that means something (`/?&=#`)
/// exactly where it is. An existing `%XX` is left alone rather than encoded twice.
pub fn sanitize_url(u: &str) -> String {
    let b = u.as_bytes();
    let mut out = String::with_capacity(u.len());
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        let already_escaped = c == b'%'
            && i + 2 < b.len()
            && b[i + 1].is_ascii_hexdigit()
            && b[i + 2].is_ascii_hexdigit();
        if already_escaped {
            out.push_str(&u[i..i + 3]);
            i += 3;
            continue;
        }
        if c.is_ascii_graphic() && !br#"%"<>\^`{|}"#.contains(&c) {
            out.push(c as char);
        } else {
            out.push_str(&format!("%{c:02X}"));
        }
        i += 1;
    }
    out
}

/// Are these two links the same page? Used to recognise the moment a chapter's
/// "next page" button has quietly become its "next chapter" button. Compares
/// loosely on purpose: a table of contents lists `/book/1/2.html` while the
/// page-turn link may say `/book/1/2.html#top`, or differ by a trailing slash,
/// and both are the same page to everyone except a string comparison.
pub fn same_page(a: &str, b: &str) -> bool {
    fn key(u: &str) -> String {
        let u = u.split('#').next().unwrap_or(u);
        let u = u.strip_suffix('/').unwrap_or(u);
        u.trim().to_lowercase()
    }
    !a.is_empty() && key(a) == key(b)
}

/// Apply the sheet's `replaceRegex` — the author's own list of things this site
/// glues to its chapters and no reader wants: 「一秒记住笔趣阁」, 「(第 2/3 页)」,
/// the domain-of-the-week advert.
///
/// The syntax is legado's: `##pattern##replacement`, replacement optional, and
/// the pattern is a regex whose alternatives are separated by `|`. Some sheets
/// interpolate JavaScript into the pattern (`{{chapter.title}}`) or replace the
/// whole field with a `<js>` block; we cannot run either, and a script we cannot
/// run must not take the plain regexes down with it — so the JS parts are cut
/// out and whatever regex remains is still applied.
pub fn apply_replace(text: &str, spec: Option<&str>) -> String {
    let Some(spec) = spec.map(str::trim).filter(|s| !s.is_empty()) else {
        return text.to_string();
    };
    if spec.contains("<js>") || spec.starts_with("@js:") {
        return text.to_string();
    }
    let spec = spec.strip_prefix("##").unwrap_or(spec);
    let mut it = spec.splitn(2, "##");
    let pattern = it.next().unwrap_or_default();
    let replacement = it.next().unwrap_or_default();

    // Drop `{{…}}` alternatives, then the empty alternatives they leave behind —
    // an empty branch in an alternation matches everywhere and would blank the
    // chapter.
    let pattern = strip_braces(pattern);
    let pattern = pattern
        .split('|')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("|");
    if pattern.is_empty() {
        return text.to_string();
    }
    let Ok(re) = regex::Regex::new(&pattern) else {
        return text.to_string();
    };
    let out = re.replace_all(text, replacement);
    out.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Remove every `{{…}}` span, brace-counted so a JS block full of braces goes
/// out whole.
fn strip_braces(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find("{{") {
        out.push_str(&rest[..i]);
        let mut depth = 0usize;
        let mut end = None;
        let bytes: Vec<char> = rest[i..].chars().collect();
        let mut j = 0;
        while j < bytes.len() {
            if bytes[j] == '{' {
                depth += 1;
            } else if bytes[j] == '}' {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    end = Some(j + 1);
                    break;
                }
            }
            j += 1;
        }
        match end {
            None => return out,
            Some(e) => rest = &rest[i + bytes[..e].iter().map(|c| c.len_utf8()).sum::<usize>()..],
        }
    }
    out.push_str(rest);
    out
}

/// Resolve a link against the page it was found on. No `url` crate: the four
/// cases below are the four cases that occur.
pub fn absolute(base: &str, rel: &str) -> String {
    if rel.is_empty() {
        return base.to_string();
    }
    if rel.starts_with("http://") || rel.starts_with("https://") {
        return rel.to_string();
    }
    let scheme_end = base.find("://").map(|i| i + 3).unwrap_or(0);
    if let Some(r) = rel.strip_prefix("//") {
        let scheme = if scheme_end == 0 {
            "https"
        } else {
            &base[..scheme_end - 3]
        };
        return format!("{scheme}://{r}");
    }
    let origin_end = base[scheme_end..]
        .find('/')
        .map(|i| scheme_end + i)
        .unwrap_or(base.len());
    let origin = &base[..origin_end];
    if rel.starts_with('/') {
        return format!("{origin}{rel}");
    }
    let dir = match base[origin_end..].rfind('/') {
        Some(i) => &base[..origin_end + i],
        None => origin,
    };
    format!("{dir}/{rel}")
}

/// A fetched page, parsed once. HTML or JSON — decided by what came back, not by
/// what the rule claims, so a site that answers a JSON endpoint with an error
/// page does not turn into a stream of empty strings.
pub struct Doc {
    pub url: String,
    pub html: Option<Html>,
    pub json: Option<Value>,
}

const MAX_BODY: u64 = 8 * 1024 * 1024;

pub fn fetch(
    agent: &ureq::Agent,
    spec: &UrlSpec,
    header_json: Option<&str>,
) -> Result<Doc, String> {
    let mut headers: Vec<(String, String)> = vec![(
        "User-Agent".into(),
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) \
         Chrome/124.0 Safari/537.36"
            .into(),
    )];
    if let Some(h) = header_json {
        if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(h.trim()) {
            for (k, v) in map {
                if let Some(s) = v.as_str() {
                    headers.retain(|(hk, _)| !hk.eq_ignore_ascii_case(&k));
                    headers.push((k, s.to_string()));
                }
            }
        }
    }
    headers.extend(spec.headers.iter().cloned());

    let mut resp = if spec.method == "POST" {
        let mut req = agent.post(&spec.url);
        for (k, v) in &headers {
            req = req.header(k, v);
        }
        req = req.header("Content-Type", "application/x-www-form-urlencoded");
        req.send(spec.body.clone().unwrap_or_default())
            .map_err(|e| format!("请求失败：{e}"))?
    } else {
        let mut req = agent.get(&spec.url);
        for (k, v) in &headers {
            req = req.header(k, v);
        }
        req.call().map_err(|e| format!("请求失败：{e}"))?
    };

    let raw = resp
        .body_mut()
        .with_config()
        .limit(MAX_BODY)
        .read_to_vec()
        .map_err(|e| format!("读取失败：{e}"))?;

    // The charset the rule sheet declares wins; otherwise the same detector the
    // book importer uses, which exists precisely because Chinese pages lie about
    // their encoding.
    let text = match spec.charset.as_deref() {
        Some(cs) => crate::decode::decode_as(&raw, cs)
            .map(|d| d.text)
            .unwrap_or_else(|| crate::decode::decode(&raw).text),
        None => crate::decode::decode(&raw).text,
    };

    let trimmed = text.trim_start();
    let json = if trimmed.starts_with('{') || trimmed.starts_with('[') {
        serde_json::from_str::<Value>(trimmed).ok()
    } else {
        None
    };
    Ok(Doc {
        url: spec.url.clone(),
        html: if json.is_none() {
            Some(Html::parse_document(&text))
        } else {
            None
        },
        json,
    })
}

// ------------------------------------------------------------------ selection

/// One row to evaluate field rules against.
pub enum Item<'a> {
    Element(ElementRef<'a>),
    Json(&'a Value),
    /// A row of regex captures, from an `:pattern` list rule. `$1` reaches them.
    Caps(Vec<String>),
}

impl<'a> Item<'a> {
    pub fn whole(doc: &'a Doc) -> Item<'a> {
        match (&doc.html, &doc.json) {
            (Some(h), _) => Item::Element(h.root_element()),
            (_, Some(j)) => Item::Json(j),
            _ => Item::Caps(Vec::new()),
        }
    }
}

/// Split a list rule off the document. The three worlds — HTML, JSON, raw regex
/// — each have their own way of saying "these are the rows".
pub fn select_list<'a>(doc: &'a Doc, rule: &str) -> Result<Vec<Item<'a>>, String> {
    let rule = rule.trim();
    if let Some(pat) = rule.strip_prefix(':') {
        // AllInOne: the pattern's captures *are* the row.
        let re = regex::Regex::new(pat).map_err(|e| format!("正则不对：{e}"))?;
        let hay = doc
            .html
            .as_ref()
            .map(|h| h.root_element().html())
            .or_else(|| doc.json.as_ref().map(|j| j.to_string()))
            .unwrap_or_default();
        return Ok(re
            .captures_iter(&hay)
            .map(|c| {
                Item::Caps(
                    c.iter()
                        .map(|m| m.map(|m| m.as_str().to_string()).unwrap_or_default())
                        .collect(),
                )
            })
            .collect());
    }

    if let Some(j) = &doc.json {
        let path = rule.strip_prefix("@json:").unwrap_or(rule);
        return Ok(json_query(j, path)?.into_iter().map(Item::Json).collect());
    }

    let Some(html) = &doc.html else {
        return Ok(Vec::new());
    };
    let root = html.root_element();
    Ok(select_elements(root, rule)?
        .into_iter()
        .map(Item::Element)
        .collect())
}

fn json_query<'a>(v: &'a Value, path: &str) -> Result<Vec<&'a Value>, String> {
    use serde_json_path::JsonPath;
    let path = path.trim();
    let path = if path.starts_with('$') {
        path.to_string()
    } else {
        format!("$.{path}")
    };
    let p =
        JsonPath::parse(&normalize_jsonpath(&path)).map_err(|e| format!("JSONPath 不对：{e}"))?;
    Ok(p.query(v).all())
}

/// RFC 9535 only lets a bare `.name` hold a lowercase-ish identifier, but the
/// APIs these sheets talk to answer with `Name`, `BookStatus`, `书名`. Those are
/// perfectly good keys — they just have to be spelled `['Name']`. And legado
/// writes filters the old way, `[?(@.x)]`, where the modern grammar wants `[?@.x]`.
fn normalize_jsonpath(path: &str) -> String {
    let path = path.replace("[?(", "[?").replace(")]", "]");
    let c: Vec<char> = path.chars().collect();
    let mut out = String::with_capacity(path.len());
    let mut i = 0;
    while i < c.len() {
        // Bracket selections are already explicit; copy them through untouched.
        if c[i] == '[' {
            let mut depth = 0;
            while i < c.len() {
                if c[i] == '[' {
                    depth += 1;
                } else if c[i] == ']' {
                    depth -= 1;
                }
                out.push(c[i]);
                i += 1;
                if depth == 0 {
                    break;
                }
            }
            continue;
        }
        if c[i] != '.' {
            out.push(c[i]);
            i += 1;
            continue;
        }
        out.push('.');
        i += 1;
        if i < c.len() && c[i] == '.' {
            out.push('.');
            i += 1;
        }
        let start = i;
        while i < c.len() && !"[.".contains(c[i]) {
            i += 1;
        }
        let name: String = c[start..i].iter().collect();
        let plain = !name.is_empty()
            && name != "*"
            && name
                .chars()
                .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
            && !name.chars().next().is_some_and(|ch| ch.is_ascii_digit());
        if plain || name.is_empty() || name == "*" {
            out.push_str(&name);
        } else {
            // `.Name` → `['Name']`: drop the dot we just wrote.
            out.pop();
            out.push_str(&format!("['{}']", name.replace('\'', "\\'")));
        }
    }
    out
}

/// Elements matching a selector rule, in either dialect. `||` offers
/// alternatives — the first one that finds anything wins.
fn select_elements<'a>(root: ElementRef<'a>, rule: &str) -> Result<Vec<ElementRef<'a>>, String> {
    let rule = rule.trim();
    if rule.starts_with("//") || rule.starts_with("@XPath:") || rule.starts_with("@xpath:") {
        return Err(Unsupported("这个书源用了 XPath 规则，暂不支持".into()).0);
    }
    if rule.contains("<js>") || rule.contains("@js:") {
        return Err(Unsupported("这个书源的规则里嵌了 JavaScript，本机引擎跑不了".into()).0);
    }
    for alt in rule.split("||") {
        let got = select_chain(root, alt.trim())?;
        if !got.is_empty() {
            return Ok(got);
        }
    }
    Ok(Vec::new())
}

fn select_chain<'a>(root: ElementRef<'a>, rule: &str) -> Result<Vec<ElementRef<'a>>, String> {
    if let Some(css) = rule.strip_prefix("@css:") {
        let sel =
            Selector::parse(css.trim()).map_err(|_| format!("CSS 选择器不对：{}", css.trim()))?;
        return Ok(root.select(&sel).collect());
    }
    let mut current = vec![root];
    for seg in rule.split('@') {
        let mut next = Vec::new();
        for el in &current {
            next.extend(select_segment(*el, seg.trim())?);
        }
        current = next;
        if current.is_empty() {
            break;
        }
    }
    Ok(current)
}

const KINDS: [&str; 5] = ["class", "id", "tag", "text", "children"];

/// One step of a chain: either legado's `class.odd.0`, or — and this is most of
/// the sheets in the wild — a plain CSS selector with legado's index syntax stuck
/// on the end (`a.0`, `.sc-time span.1`, `tr!0`). Both dialects are written into
/// the same field by the same people, often in the same file, so both are read.
fn select_segment<'a>(el: ElementRef<'a>, seg: &str) -> Result<Vec<ElementRef<'a>>, String> {
    if seg.is_empty() {
        return Ok(vec![el]);
    }
    let mut parts = seg.splitn(3, '.');
    let kind = parts.next().unwrap_or_default();

    let (got, index) = if KINDS.contains(&kind) {
        let name = parts.next().unwrap_or_default();
        let index = parts.next().unwrap_or_default();
        // `tag.tr!0` puts the index on the name, not after a dot. Peel it, or the
        // exclusion goes to the CSS parser as part of the tag name.
        let (name, index) = if index.is_empty() {
            split_index(name)
        } else {
            (name, index)
        };
        let got: Vec<ElementRef<'a>> = match kind {
            "class" => sel(&format!(".{name}"), el)?,
            "id" => sel(&format!("#{name}"), el)?,
            "tag" => sel(name, el)?,
            "children" => el.children().filter_map(ElementRef::wrap).collect(),
            _ => sel("*", el)?
                .into_iter()
                .filter(|e| e.text().collect::<String>().contains(name))
                .collect(),
        };
        (got, index)
    } else {
        let (css, index) = split_index(seg);
        (
            sel(css, el).map_err(|_| format!("看不懂的规则片段：{seg}"))?,
            index,
        )
    };
    Ok(apply_index(got, index))
}

/// Peel legado's index off the end of a CSS selector. Only when it is
/// unmistakably an index: `a[href]` is an attribute selector, not element zero of
/// `a`, and `.v-title` is a class, not element "title" of nothing.
fn split_index(seg: &str) -> (&str, &str) {
    let numeric = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_digit() || c == '-' || c == ',' || c == ' ')
            && s.chars().any(|c| c.is_ascii_digit())
    };
    if let Some(i) = seg.find('!') {
        if numeric(&seg[i + 1..]) {
            return (&seg[..i], &seg[i..]);
        }
    }
    if let Some(i) = seg.rfind('[') {
        if seg.ends_with(']') && numeric(&seg[i + 1..seg.len() - 1]) {
            return (&seg[..i], &seg[i..]);
        }
    }
    if let Some(i) = seg.rfind('.') {
        let tail = &seg[i + 1..];
        if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit() || c == '-') {
            return (&seg[..i], tail);
        }
    }
    (seg, "")
}

fn apply_index<'a>(got: Vec<ElementRef<'a>>, index: &str) -> Vec<ElementRef<'a>> {
    if index.is_empty() {
        return got;
    }
    let n = got.len() as i64;
    let pick = |i: i64| -> Option<usize> {
        let i = if i < 0 { n + i } else { i };
        (i >= 0 && i < n).then_some(i as usize)
    };
    if let Some(list) = index.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
        let mut out = Vec::new();
        for tok in list.split(',') {
            if let Ok(i) = tok.trim().parse::<i64>() {
                if let Some(i) = pick(i) {
                    out.push(got[i]);
                }
            }
        }
        out
    } else if let Some(ex) = index.strip_prefix('!') {
        let drop: Vec<usize> = ex
            .split(',')
            .filter_map(|t| t.trim().parse::<i64>().ok())
            .filter_map(pick)
            .collect();
        got.into_iter()
            .enumerate()
            .filter(|(i, _)| !drop.contains(i))
            .map(|(_, e)| e)
            .collect()
    } else if let Ok(i) = index.parse::<i64>() {
        pick(i).map(|i| vec![got[i]]).unwrap_or_default()
    } else {
        got
    }
}

fn sel<'a>(css: &str, el: ElementRef<'a>) -> Result<Vec<ElementRef<'a>>, String> {
    let s = Selector::parse(css).map_err(|_| format!("选择器不对：{css}"))?;
    Ok(el.select(&s).collect())
}

// ----------------------------------------------------------------- evaluation

/// Evaluate one field rule against one row. An empty rule yields an empty
/// string: a source that does not tell us the author is not broken, it just does
/// not tell us the author.
pub fn eval(item: &Item<'_>, rule: &str) -> Result<String, String> {
    let rule = rule.trim();
    if rule.is_empty() {
        return Ok(String::new());
    }
    if rule.contains("<js>") || rule.starts_with("@js:") || rule.contains("@js:") {
        return Err(Unsupported("这个书源的规则里嵌了 JavaScript，本机引擎跑不了".into()).0);
    }

    // `rule##pattern##replacement` — the tail rewrites whatever the head found.
    let (head, subst) = match rule.split_once("##") {
        Some((h, tail)) => {
            let tail = tail.trim_end_matches('#');
            let mut it = tail.splitn(2, "##");
            let pat = it.next().unwrap_or_default().to_string();
            let rep = it.next().unwrap_or_default().to_string();
            (h.trim(), Some((pat, rep)))
        }
        None => (rule, None),
    };

    // `||` takes the first alternative that says anything; `&&` takes them all.
    let mut value = String::new();
    for alt in head.split("||") {
        let mut parts = Vec::new();
        for one in alt.split("&&") {
            let v = eval_one(item, one.trim())?;
            if !v.is_empty() {
                parts.push(v);
            }
        }
        if !parts.is_empty() {
            value = parts.join("\n");
            break;
        }
    }

    if let Some((pat, rep)) = subst {
        if !pat.is_empty() {
            let re = regex::Regex::new(&pat).map_err(|e| format!("正则不对：{e}"))?;
            value = re.replace_all(&value, rep.as_str()).into_owned();
        }
    }
    Ok(value)
}

fn eval_one(item: &Item<'_>, rule: &str) -> Result<String, String> {
    if rule.is_empty() {
        return Ok(String::new());
    }
    match item {
        Item::Caps(caps) => Ok(capture_ref(caps, rule)),
        Item::Json(v) => {
            let path = rule.strip_prefix("@json:").unwrap_or(rule);
            Ok(json_query(v, path)?
                .into_iter()
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    Value::Null => String::new(),
                    other => other.to_string(),
                })
                .collect::<Vec<_>>()
                .join("\n"))
        }
        Item::Element(el) => {
            let (selector, content) = split_content(rule);
            let targets: Vec<ElementRef> = if selector.is_empty() {
                vec![*el]
            } else {
                select_elements(*el, selector)?
            };
            let mut out = Vec::new();
            for t in targets {
                let v = extract(t, content);
                if !v.trim().is_empty() {
                    out.push(v);
                }
            }
            Ok(out.join("\n"))
        }
    }
}

/// `$1`-style references into a regex row, with any surrounding literal text.
fn capture_ref(caps: &[String], rule: &str) -> String {
    let mut out = String::new();
    let mut chars = rule.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if c == '$' {
            let rest = &rule[i + 1..];
            let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
            if !digits.is_empty() {
                for _ in 0..digits.len() {
                    chars.next();
                }
                if let Ok(n) = digits.parse::<usize>() {
                    out.push_str(caps.get(n).map(String::as_str).unwrap_or_default());
                }
                continue;
            }
        }
        out.push(c);
    }
    out
}

/// Peel the content spec off the end of a selector rule: `.item h3@text` →
/// (`.item h3`, `text`). A rule that is *only* a content spec (`text`, `href`)
/// selects nothing and reads the row itself.
fn split_content(rule: &str) -> (&str, &str) {
    const CONTENT: &[&str] = &[
        "text",
        "textNodes",
        "ownText",
        "html",
        "all",
        "href",
        "src",
        "content",
        "value",
    ];
    let css = rule.strip_prefix("@css:").unwrap_or(rule);
    if let Some((sel, last)) = css.rsplit_once('@') {
        if CONTENT.contains(&last) || (!last.contains('.') && last.contains('-')) {
            let sel = if rule.starts_with("@css:") {
                &rule[..rule.len() - last.len() - 1]
            } else {
                sel
            };
            return (sel, last);
        }
    }
    if CONTENT.contains(&css) {
        return ("", css);
    }
    (rule, "text")
}

fn extract(el: ElementRef<'_>, content: &str) -> String {
    match content {
        "text" | "" => element_text(el),
        "ownText" => el
            .children()
            .filter_map(|n| n.value().as_text().map(|t| t.to_string()))
            .collect::<String>()
            .trim()
            .to_string(),
        "textNodes" => el
            .descendants()
            .filter_map(|n| n.value().as_text().map(|t| t.trim().to_string()))
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        "html" | "all" => el.inner_html(),
        attr => el.value().attr(attr).unwrap_or_default().to_string(),
    }
}

/// Text with the paragraph breaks kept. `Element::text()` glues every fragment
/// together, which for a chapter body means the whole thing arrives as one
/// enormous line — and the reader would then be paginating a single paragraph.
pub fn element_text(el: ElementRef<'_>) -> String {
    fn walk(node: ego_tree::NodeRef<'_, Node>, out: &mut String) {
        match node.value() {
            Node::Text(t) => out.push_str(&t.text),
            Node::Element(e) => {
                let tag = e.name();
                if matches!(tag, "script" | "style") {
                    return;
                }
                let block = matches!(
                    tag,
                    "br" | "p" | "div" | "li" | "tr" | "h1" | "h2" | "h3" | "h4" | "section"
                );
                if block && !out.ends_with('\n') && !out.is_empty() {
                    out.push('\n');
                }
                for c in node.children() {
                    walk(c, out);
                }
                if block && !out.ends_with('\n') {
                    out.push('\n');
                }
            }
            _ => {}
        }
    }
    let mut s = String::new();
    walk(*el, &mut s);
    s.lines()
        .map(|l| l.trim().replace('\u{a0}', " "))
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Chapter bodies often arrive as a lump of HTML (`@content@html`). Turn it back
/// into paragraphs — `<br>` is where the author put a line break.
pub fn html_to_text(html: &str) -> String {
    let frag = Html::parse_fragment(html);
    element_text(frag.root_element())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(html: &str) -> Doc {
        Doc {
            url: "https://x.example/a/b.html".into(),
            html: Some(Html::parse_document(html)),
            json: None,
        }
    }

    const PAGE: &str = r#"<html><body>
      <div class="item"><h3><a href="/book/1.html">剑来</a></h3><span class="au">烽火</span></div>
      <div class="item"><h3><a href="/book/2.html">元尊</a></h3><span class="au">天蚕土豆</span></div>
    </body></html>"#;

    #[test]
    fn css_list_and_fields() {
        let d = doc(PAGE);
        let rows = select_list(&d, "@css:.item").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(eval(&rows[0], "@css:h3 a@text").unwrap(), "剑来");
        assert_eq!(eval(&rows[0], "@css:h3 a@href").unwrap(), "/book/1.html");
        assert_eq!(eval(&rows[1], "@css:.au@text").unwrap(), "天蚕土豆");
    }

    /// The dialect that most sheets in the wild are actually written in.
    #[test]
    fn legado_default_dialect() {
        let d = doc(PAGE);
        let rows = select_list(&d, "class.item").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(eval(&rows[0], "tag.a.0@text").unwrap(), "剑来");
        assert_eq!(eval(&rows[0], "tag.a.0@href").unwrap(), "/book/1.html");
    }

    #[test]
    fn index_picks_and_negative_index() {
        let d = doc(PAGE);
        let rows = select_list(&d, "class.item.1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(eval(&rows[0], "tag.a.0@text").unwrap(), "元尊");
        let last = select_list(&d, "class.item.-1").unwrap();
        assert_eq!(eval(&last[0], "tag.a.0@text").unwrap(), "元尊");
    }

    #[test]
    fn regex_tail_rewrites_the_value() {
        let d = doc(PAGE);
        let rows = select_list(&d, "@css:.item").unwrap();
        let v = eval(&rows[0], "@css:h3 a@href##/book/(\\d+)\\.html##$1").unwrap();
        assert_eq!(v, "1");
    }

    #[test]
    fn fallback_takes_the_first_alternative_that_says_something() {
        let d = doc(PAGE);
        let rows = select_list(&d, "@css:.item").unwrap();
        assert_eq!(
            eval(&rows[0], "@css:.nope@text||@css:.au@text").unwrap(),
            "烽火"
        );
    }

    #[test]
    fn json_pages_are_read_as_json() {
        let d = Doc {
            url: "https://x.example/api".into(),
            html: None,
            json: Some(serde_json::json!({"books":[{"t":"剑来","u":"/b/1"}]})),
        };
        let rows = select_list(&d, "$.books[*]").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(eval(&rows[0], "$.t").unwrap(), "剑来");
    }

    #[test]
    fn allinone_regex_rows_expose_captures() {
        let d = doc(PAGE);
        let rows = select_list(&d, r#":href="([^"]*)">([^<]*)<"#).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(eval(&rows[0], "$2").unwrap(), "剑来");
        assert_eq!(eval(&rows[0], "$1").unwrap(), "/book/1.html");
    }

    /// The whole point of refusing loudly: an unrunnable source must fail at
    /// import, not produce a book full of blank chapters at 3am.
    #[test]
    fn javascript_and_xpath_are_refused_not_ignored() {
        let d = doc(PAGE);
        let rows = select_list(&d, "@css:.item").unwrap();
        assert!(eval(&rows[0], "@js:foo()").is_err());
        assert!(select_list(&d, "//div[@class='item']").is_err());
        assert!(UrlSpec::parse("/s?q={{java.ajax(x)}}", "https://x.example", "k", 1).is_err());
    }

    #[test]
    fn urls_resolve_against_the_page_they_came_from() {
        let base = "https://x.example/a/b.html";
        assert_eq!(absolute(base, "/c/d.html"), "https://x.example/c/d.html");
        assert_eq!(absolute(base, "e.html"), "https://x.example/a/e.html");
        assert_eq!(absolute(base, "//y.example/f"), "https://y.example/f");
        assert_eq!(absolute(base, "https://z.example/g"), "https://z.example/g");
    }

    #[test]
    fn search_url_carries_method_and_charset() {
        let u = UrlSpec::parse(
            r#"/search,{"method":"POST","body":"key={{key}}","charset":"gbk"}"#,
            "https://x.example",
            "剑来",
            1,
        )
        .unwrap();
        assert_eq!(u.url, "https://x.example/search");
        assert_eq!(u.method, "POST");
        assert_eq!(u.charset.as_deref(), Some("gbk"));
        // GBK in, GBK out: 剑来 is %BD%A3%C0%B4, not its UTF-8 spelling.
        assert_eq!(u.body.as_deref(), Some("key=%BD%A3%C0%B4"));
    }

    /// Most sheets in the wild do not write legado's dialect at all — they write
    /// plain CSS into the same fields. Refusing that is refusing most of the web.
    #[test]
    fn plain_css_works_without_the_css_prefix() {
        let d = doc(PAGE);
        let rows = select_list(&d, ".item").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(eval(&rows[0], "h3 a@text").unwrap(), "剑来");
        assert_eq!(eval(&rows[0], "a.0@href").unwrap(), "/book/1.html");
        assert_eq!(eval(&rows[1], ".au@text").unwrap(), "天蚕土豆");
    }

    /// `a.0` is element zero of `a`; `a[href]` is an attribute selector. Telling
    /// them apart is the whole job of the index peeler.
    #[test]
    fn an_attribute_selector_is_not_an_index() {
        let d = doc(PAGE);
        let rows = select_list(&d, "div[class]").unwrap();
        assert_eq!(rows.len(), 2);
        let excl = select_list(&d, ".item!0").unwrap();
        assert_eq!(excl.len(), 1);
        assert_eq!(eval(&excl[0], "h3 a@text").unwrap(), "元尊");
    }

    /// `tag.tr!0` — a table whose first row is the header. The exclusion is stuck
    /// to the tag name, and it must not reach the CSS parser.
    #[test]
    fn an_index_may_sit_on_the_tag_name() {
        let d = doc(r#"<table class="grid"><tr><th>书名</th></tr>
            <tr><td><a href="/b/1">剑来</a></td></tr>
            <tr><td><a href="/b/2">元尊</a></td></tr></table>"#);
        let rows = select_list(&d, "class.grid@tag.tr!0").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(eval(&rows[0], "tag.a.0@text").unwrap(), "剑来");
    }

    /// A path with Chinese in it is a path a browser encodes and an HTTP client
    /// rejects. Encode it, and leave the punctuation that means something alone.
    #[test]
    fn chinese_paths_are_encoded_not_rejected() {
        let u = UrlSpec::parse("/搜索/{{key}}.html?p=1", "https://x.example", "剑", 1).unwrap();
        assert_eq!(
            u.url,
            "https://x.example/%E6%90%9C%E7%B4%A2/%E5%89%91.html?p=1"
        );
        // Already-escaped stays escaped, exactly once.
        assert_eq!(
            sanitize_url("https://x.example/a%20b?c=1&d=2"),
            "https://x.example/a%20b?c=1&d=2"
        );
    }

    #[test]
    fn a_list_rule_may_offer_alternatives() {
        let d = doc(PAGE);
        let rows = select_list(&d, ".nothing-here||.item").unwrap();
        assert_eq!(rows.len(), 2);
    }

    /// Half the sheets quote their request options with `'`. Their Android host
    /// takes it, so a source must not die here over a punctuation mark.
    #[test]
    fn single_quoted_options_are_read() {
        let u = UrlSpec::parse(
            "/search/,{'method': 'POST','body': 'keyword={{key}}'}",
            "https://x.example",
            "剑",
            1,
        )
        .unwrap();
        assert_eq!(u.method, "POST");
        assert_eq!(u.body.as_deref(), Some("keyword=%E5%89%91"));
    }

    /// A GBK site wants 剑 as %BD%A3. Send it %E5%89%91 and it will truthfully
    /// tell you it has never heard of that book.
    #[test]
    fn the_keyword_is_encoded_in_the_sites_own_charset() {
        let u = UrlSpec::parse(
            r#"/s?k={{key}},{"charset":"gbk"}"#,
            "https://x.example",
            "剑",
            1,
        )
        .unwrap();
        assert_eq!(u.url, "https://x.example/s?k=%BD%A3");

        let utf8 = UrlSpec::parse("/s?k={{key}}", "https://x.example", "剑", 1).unwrap();
        assert_eq!(utf8.url, "https://x.example/s?k=%E5%89%91");
    }

    /// `{{page-1}}` is arithmetic, not a script.
    #[test]
    fn page_arithmetic_is_not_a_script() {
        let u = UrlSpec::parse(
            "/list?s={{(page-1)*15}}&p={{page}}",
            "https://x.example",
            "k",
            3,
        )
        .unwrap();
        assert_eq!(u.url, "https://x.example/list?s=30&p=3");
        // Still not a script engine, and still says so.
        assert!(UrlSpec::parse("/s?x={{java.ajax(u)}}", "https://x.example", "k", 1).is_err());
    }

    /// The APIs these sheets talk to answer with `Name`, `BookStatus`, `书名`.
    /// Those are keys, not syntax errors.
    #[test]
    fn json_keys_may_be_capitalised_or_chinese() {
        let d = Doc {
            url: "https://x.example/api".into(),
            html: None,
            json: Some(serde_json::json!({"data":[{"Name":"剑来","书名":"剑来"}]})),
        };
        let rows = select_list(&d, "$.data[*]").unwrap();
        assert_eq!(eval(&rows[0], "$.Name").unwrap(), "剑来");
        assert_eq!(eval(&rows[0], "$.书名").unwrap(), "剑来");
    }

    /// A chapter body is paragraphs. Losing the `<br>`s turns a chapter into one
    /// unbroken line, and the reader would be paginating a single paragraph.
    #[test]
    fn chapter_html_keeps_its_line_breaks() {
        let t = html_to_text("　　第一段。<br/><br/>　　第二段。<p>第三段。</p>");
        assert_eq!(t.lines().count(), 3);
        assert!(t.contains("第二段。"));
    }

    /// The end of a chapter and the start of the next one are the same link on
    /// half these sites; a `#` or a trailing slash must not hide that.
    #[test]
    fn a_page_is_the_same_page_despite_punctuation() {
        assert!(same_page(
            "http://a.com/1/2.html",
            "http://a.com/1/2.html#top"
        ));
        assert!(same_page("http://a.com/1/2/", "http://a.com/1/2"));
        assert!(!same_page("http://a.com/1/2.html", "http://a.com/1/3.html"));
        assert!(!same_page("", ""));
    }

    #[test]
    fn replace_regex_strips_what_the_sheet_says_to_strip() {
        let text = "第一段。\n一秒记住笔趣阁www.x.com无弹窗免费阅读！\n第二段。";
        let out = apply_replace(&text.to_string(), Some("一秒记住.*无弹窗免费阅读！"));
        assert_eq!(out, "第一段。\n第二段。");
    }

    /// A pattern that is half JavaScript still has a working half, and the
    /// working half is the one that deletes 「(第2/3页)」.
    #[test]
    fn a_script_in_the_pattern_does_not_disarm_the_rest() {
        let spec = "##{{try{chapter.title}catch(e){\"\"} }}|\\(第\\d+/\\d+页\\)";
        let out = apply_replace("正文。\n(第2/3页)", Some(spec));
        assert_eq!(out, "正文。");
    }

    /// …but a pattern that is *only* JavaScript must leave the chapter alone,
    /// not match the empty string and erase it.
    #[test]
    fn a_pattern_that_is_all_script_changes_nothing() {
        assert_eq!(apply_replace("正文。", Some("<js>whatever</js>")), "正文。");
        assert_eq!(apply_replace("正文。", Some("{{cover}}")), "正文。");
    }
}
