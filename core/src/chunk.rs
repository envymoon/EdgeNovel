//! Retrieval chunks: the unit of semantic search.
//!
//! A chapter is too coarse to search — "那个卖丹药的老头" lives in one paragraph
//! of three thousand characters, and a hit that only says "somewhere in chapter
//! 412" hands the reader back the problem they came with. So the body is cut
//! into paragraph-aligned windows, each carrying the byte span it covers: a hit
//! is a place, not a chapter.
//!
//! Nothing here talks to a model. The model's only job is turning text into a
//! vector; deciding what to embed, how to store it, and what ranks highest is
//! arithmetic, and arithmetic belongs in core where it can be tested.

/// One window of a chapter's body.
#[derive(Debug, Clone, PartialEq)]
pub struct Chunk {
    /// Byte offsets into the decoded book text — the same coordinates progress
    /// is anchored in, so a search hit is somewhere the reader can be sent.
    pub start: usize,
    pub end: usize,
    pub text: String,
}

/// Long enough to hold a scene, short enough that the vector still points at
/// one thing. Chinese prose at ~250 characters is a paragraph or three.
pub const TARGET_CHARS: usize = 250;

/// Cut a chapter body into windows of about `target` characters.
///
/// Paragraphs are never split across chunks — a paragraph is the smallest unit
/// that means anything on its own — except for the pathological one that is
/// longer than a whole window, which is cut on character boundaries.
pub fn chunk_body(text: &str, start: usize, end: usize, target: usize) -> Vec<Chunk> {
    fn flush(
        out: &mut Vec<Chunk>,
        buf: &mut String,
        chars: &mut usize,
        span: &mut Option<(usize, usize)>,
    ) {
        if let Some((s, e)) = span.take() {
            if !buf.trim().is_empty() {
                out.push(Chunk {
                    start: s,
                    end: e,
                    text: buf.trim().to_string(),
                });
            }
        }
        buf.clear();
        *chars = 0;
    }

    let mut out = Vec::new();
    let mut buf = String::new();
    let mut chars = 0usize;
    let mut span: Option<(usize, usize)> = None;
    let mut off = start;

    for line in text[start..end].split('\n') {
        let (ls, le) = (off, off + line.len());
        off = le + 1; // the '\n' we split on

        let t = line.trim();
        if t.is_empty() {
            continue;
        }

        // A paragraph longer than the whole window: cut it on character
        // boundaries, and keep the byte spans exact so the jump still lands.
        if t.chars().count() > target {
            flush(&mut out, &mut buf, &mut chars, &mut span);
            let base = ls + (line.len() - line.trim_start().len());
            let mut piece_start = 0usize; // byte offset within `t`
            let mut n = 0usize;
            for (i, c) in t.char_indices() {
                if n == target {
                    out.push(Chunk {
                        start: base + piece_start,
                        end: base + i,
                        text: t[piece_start..i].to_string(),
                    });
                    piece_start = i;
                    n = 0;
                }
                n += 1;
                let _ = c;
            }
            if piece_start < t.len() {
                out.push(Chunk {
                    start: base + piece_start,
                    end: base + t.len(),
                    text: t[piece_start..].to_string(),
                });
            }
            continue;
        }

        if !buf.is_empty() {
            buf.push('\n');
        }
        buf.push_str(t);
        chars += t.chars().count();
        span = Some((span.map_or(ls, |(s, _)| s), le));

        if chars >= target {
            flush(&mut out, &mut buf, &mut chars, &mut span);
        }
    }
    flush(&mut out, &mut buf, &mut chars, &mut span);
    out
}

/// Scale everything to unit length so that a dot product *is* the cosine.
pub fn normalize(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n > 0.0 {
        for x in v.iter_mut() {
            *x /= n;
        }
    }
}

/// A normalized vector, packed one byte per dimension.
///
/// A 1300-chapter book is ~13k chunks; at f32 that is 26 MB of vectors to read
/// on every query. Quantizing a unit vector to i8 costs a cosine error around
/// 0.002 — far below the gap between a real hit and a near miss — and buys a
/// 4× smaller index that a brute-force scan can chew through in milliseconds.
pub fn quantize(v: &[f32]) -> Vec<u8> {
    v.iter()
        .map(|x| ((x * 127.0).round().clamp(-127.0, 127.0) as i8) as u8)
        .collect()
}

/// Cosine between a normalized query vector and a packed chunk vector.
/// A dimension mismatch (the index was built with another model) scores 0
/// rather than panicking — a stale index should look empty, not crash.
pub fn cosine(query: &[f32], packed: &[u8]) -> f32 {
    if query.len() != packed.len() {
        return 0.0;
    }
    query
        .iter()
        .zip(packed)
        .map(|(q, p)| q * (*p as i8) as f32 / 127.0)
        .sum()
}

/// A ranked hit: where it is, and how close it was.
#[derive(Debug, Clone)]
pub struct Hit {
    pub chapter: i64,
    pub start: i64,
    pub end: i64,
    pub score: f32,
}

/// Rank against several phrasings of the same question, scoring each chunk by
/// its *best* match rather than its average. One sentence is one point in the
/// space: 出轨, 私通, 失身 and 被夺 are near-misses of each other, and a passage
/// that nails one of them should not be penalized for missing the rest.
///
/// There is no score floor here, deliberately. Measured on real books, the top
/// cosine for a landmine query is 0.503 on a novel that has none and 0.504 on
/// one that does — the absolute score carries no evidence, so a threshold would
/// only launder noise into a verdict. This returns the closest passages and
/// says nothing about whether they mean anything; a human decides that.
pub fn rank_multi(
    queries: &[Vec<f32>],
    rows: &[(i64, i64, i64, Vec<u8>)],
    k: usize,
    per_chapter: usize,
) -> Vec<Hit> {
    let mut scored: Vec<Hit> = rows
        .iter()
        .map(|(chapter, start, end, v)| Hit {
            chapter: *chapter,
            start: *start,
            end: *end,
            score: queries
                .iter()
                .map(|q| cosine(q, v))
                .fold(f32::MIN, f32::max),
        })
        .collect();
    scored.sort_by(|a, b| b.score.total_cmp(&a.score));
    cap_per_chapter(scored, k, per_chapter)
}

/// The `k` closest chunks, best first, at most `per_chapter` from any one
/// chapter — a scene the author dwelt on for five paragraphs would otherwise
/// take the whole result list and hide every other place the answer lives.
pub fn rank(
    query: &[f32],
    rows: &[(i64, i64, i64, Vec<u8>)],
    k: usize,
    per_chapter: usize,
    floor: f32,
) -> Vec<Hit> {
    let mut scored: Vec<Hit> = rows
        .iter()
        .map(|(chapter, start, end, v)| Hit {
            chapter: *chapter,
            start: *start,
            end: *end,
            score: cosine(query, v),
        })
        .filter(|h| h.score >= floor)
        .collect();
    scored.sort_by(|a, b| b.score.total_cmp(&a.score));
    cap_per_chapter(scored, k, per_chapter)
}

fn cap_per_chapter(scored: Vec<Hit>, k: usize, per_chapter: usize) -> Vec<Hit> {
    let mut taken = std::collections::HashMap::new();
    let mut out = Vec::with_capacity(k);
    for h in scored {
        let n = taken.entry(h.chapter).or_insert(0usize);
        if *n < per_chapter {
            *n += 1;
            out.push(h);
            if out.len() == k {
                break;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A chunk that matches one phrasing of the question and not the others must
    /// rank on its best match. Averaging would bury exactly the passage the
    /// extra phrasings were added to find.
    #[test]
    fn a_chunk_is_scored_by_its_best_phrasing_not_its_average() {
        let a: Vec<f32> = vec![1.0, 0.0];
        let b: Vec<f32> = vec![0.0, 1.0];
        // Matches query b closely, query a not at all.
        let rows = vec![(0i64, 0i64, 10i64, quantize(&b))];
        let hits = rank_multi(&[a, b], &rows, 5, 2);
        assert_eq!(hits.len(), 1);
        assert!(hits[0].score > 0.99, "got {}", hits[0].score);
    }

    /// No floor: the scan returns the closest passages whatever they score,
    /// because the absolute score was measured to carry no information.
    #[test]
    fn rank_multi_keeps_weak_matches_rather_than_inventing_a_threshold() {
        let q: Vec<f32> = vec![1.0, 0.0];
        let far: Vec<f32> = vec![0.0, 1.0];
        let rows = vec![(3i64, 0i64, 10i64, quantize(&far))];
        assert_eq!(rank_multi(&[q], &rows, 5, 2).len(), 1);
    }

    #[test]
    fn chunks_cover_their_bytes() {
        let text = "标题\n第一段。\n第二段。\n\n第三段。\n";
        let body = 4 * 3; // past "标题\n"
        let chunks = chunk_body(text, body + 1, text.len(), 4);
        assert!(!chunks.is_empty());
        for c in &chunks {
            // The span must point at the text it claims to be.
            assert_eq!(
                text[c.start..c.end].trim(),
                c.text.replace('\n', "\n").trim()
            );
        }
    }

    #[test]
    fn short_paragraphs_merge_until_the_window_fills() {
        let text = "一二三。\n四五六。\n七八九。\n";
        let chunks = chunk_body(text, 0, text.len(), 8);
        // 4 + 4 chars fills a window of 8; the last paragraph is its own.
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].text, "一二三。\n四五六。");
        assert_eq!(chunks[1].text, "七八九。");
    }

    #[test]
    fn an_overlong_paragraph_is_cut_on_char_boundaries() {
        let text: String = "字".repeat(25);
        let chunks = chunk_body(&text, 0, text.len(), 10);
        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].text.chars().count(), 10);
        assert_eq!(chunks[2].text.chars().count(), 5);
        // Byte spans stay exact and contiguous.
        assert_eq!(chunks[0].start, 0);
        assert_eq!(chunks[2].end, text.len());
        for c in &chunks {
            assert_eq!(&text[c.start..c.end], c.text);
        }
    }

    #[test]
    fn quantized_cosine_tracks_the_real_one() {
        let mut a: Vec<f32> = (0..64).map(|i| (i as f32 * 0.37).sin()).collect();
        let mut b: Vec<f32> = (0..64).map(|i| (i as f32 * 0.41).cos()).collect();
        normalize(&mut a);
        normalize(&mut b);
        let exact: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum();
        let approx = cosine(&a, &quantize(&b));
        assert!(
            (exact - approx).abs() < 0.01,
            "exact {exact}, approx {approx}"
        );
        // A vector against itself is 1.
        assert!((cosine(&a, &quantize(&a)) - 1.0).abs() < 0.01);
    }

    #[test]
    fn a_mismatched_dimension_scores_zero_instead_of_panicking() {
        assert_eq!(cosine(&[1.0, 0.0], &quantize(&[1.0, 0.0, 0.0])), 0.0);
    }

    #[test]
    fn rank_caps_how_much_of_the_list_one_chapter_can_take() {
        let v = |x: f32| quantize(&[x, (1.0 - x * x).sqrt()]);
        let rows = vec![
            (1, 0, 10, v(0.99)),
            (1, 10, 20, v(0.98)),
            (1, 20, 30, v(0.97)),
            (2, 0, 10, v(0.96)),
        ];
        let hits = rank(&[1.0, 0.0], &rows, 10, 2, 0.0);
        assert_eq!(hits.len(), 3);
        assert_eq!(hits.iter().filter(|h| h.chapter == 1).count(), 2);
        assert_eq!(hits[2].chapter, 2);
    }

    #[test]
    fn the_floor_keeps_junk_out_of_an_empty_result() {
        let rows = vec![(1, 0, 10, quantize(&[0.0, 1.0]))];
        assert!(rank(&[1.0, 0.0], &rows, 10, 2, 0.3).is_empty());
    }
}
