"""Read-only prototype for heroine-bound, evidence-first landmine scanning.

This is deliberately outside the Flutter/Rust app. It reads the existing book,
cast cache and chunk index, but never writes to them or launches a model. An
already-running localhost embedder can be supplied for a baseline comparison. No
copyrighted passages are saved in the experiment directory.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import urllib.request
from dataclasses import dataclass, replace
from pathlib import Path


EVENT_CUES = {
    "ntr": ("偷情", "私通", "出轨", "发生关系"),
    "past_relationship": ("非处", "处子", "完璧", "发生关系", "同房", "圆房"),
    "progress": ("确定关系", "正式交往", "结婚", "成亲", "圆房", "发生关系"),
}
LEGACY_QUERIES = {
    "ntr": (
        "她背着自己的男人和别人上了床",
        "妻子与其他男人私通、偷情",
        "他的女人被别的男人夺走、占有",
        "得知妻子出轨后他愤怒屈辱",
    ),
    "past_relationship": (
        "她已经不是处子之身，早就被别的男人碰过",
        "她向他坦白自己曾与他人有过关系",
        "他发现她并非完璧之身",
        "她的第一次给了另一个男人",
    ),
}
QUERY_PREFIX = "为这个句子生成表示以用于检索相关文章："
UNCERTAIN_CUES = (
    "听说", "传闻", "据说", "谣言", "误会", "梦见", "梦中", "假装", "演戏",
    "如果", "可能", "似乎", "怀疑", "否认", "并没有", "从未", "不是", "没有",
    "还没", "未曾", "尚未", "不曾", "等",
    "打算", "准备", "计划", "预计", "将来", "以后", "不出意外",
)
SENTENCE_SPLIT = re.compile(r"(?<=[。！？\n])")


@dataclass(frozen=True)
class Heroine:
    names: tuple[str, ...]
    confirmed_from: int | None
    status: str


@dataclass(frozen=True)
class Chain:
    protagonist: tuple[str, ...]
    heroines: tuple[Heroine, ...]


@dataclass(frozen=True)
class Passage:
    chapter: int
    start: int
    end: int
    text: str


@dataclass(frozen=True)
class Finding:
    kind: str
    verdict: str  # explicit, clue, unbound, unrelated; never a book-wide safe verdict
    heroine: str | None
    chapter: int
    start: int
    evidence: str
    reason: str
    stage: str | None = None


def _variants(value: str) -> tuple[str, ...]:
    return tuple(dict.fromkeys(x.strip() for x in value.split("/") if x.strip()))


def chain_from_cast(cast: dict) -> Chain:
    relationship = cast.get("relationship") or {}
    protagonist = relationship.get("protagonist") or (cast.get("people") or [{}])[0].get("name", "")
    cast_people = cast.get("people") or []
    lead = next((p for p in cast_people if p.get("name") == protagonist), {})
    lead_names = tuple(dict.fromkeys((protagonist, *(lead.get("aliases") or []))))
    heroines = []
    for person in relationship.get("people") or []:
        if not (person.get("confirmed") or person.get("sustained") or person.get("possible")):
            continue
        names = list(_variants(person.get("name", "")))
        for member in cast_people:
            if member.get("name") in names:
                names.extend(member.get("aliases") or [])
        names = list(dict.fromkeys(n for n in names if len(n) >= 2))
        if not names:
            continue
        # Both 性关系 (from 同床共枕) and 明确关系 (from hypothetical future
        # marriage) have false-positive cached examples. Never use either to
        # date the relationship. A separate original-text pass is required.
        heroines.append(Heroine(tuple(names), None, person.get("status", "")))
    return Chain(tuple(n for n in lead_names if n), tuple(heroines))


def _contains_name(text: str, names: tuple[str, ...]) -> bool:
    return any(name in text for name in names)


def _progress_pair(sentence: str, heroine: Heroine, chain: Chain) -> bool:
    h = "(?:" + "|".join(re.escape(n) for n in heroine.names) + ")"
    p = "(?:" + "|".join(re.escape(n) for n in chain.protagonist) + ")"
    if not h or not p:
        return False
    return bool(re.search(rf"(?:{h}.{{0,8}}(?:和|与|跟){p}|{p}.{{0,8}}(?:和|与|跟){h}).{{0,14}}(?:确定关系|正式交往|结婚|成亲|圆房|发生关系)", sentence))


def _third_party_pair(sentence: str, heroine: Heroine, chain: Chain, actions: str) -> bool:
    h = "(?:" + "|".join(re.escape(n) for n in heroine.names) + ")"
    pattern = rf"{h}.{{0,12}}(?:和|与)(?P<third>[^，。！？\s]{{2,8}}?)(?:{actions})"
    match = re.search(pattern, sentence)
    return bool(match and not _contains_name(match.group("third"), chain.protagonist))


def _relevant_to_heroine(sentence: str, heroine: Heroine, chain: Chain, kind: str) -> bool:
    if kind == "progress":
        return _progress_pair(sentence, heroine, chain)
    if kind == "ntr":
        return any(x in sentence for x in ("偷情", "私通", "出轨")) or _third_party_pair(
            sentence, heroine, chain, "发生关系")
    # '同房' and '圆房' with the protagonist are not evidence of prior history.
    h = "(?:" + "|".join(re.escape(n) for n in heroine.names) + ")"
    if re.search(rf"{h}.{{0,12}}(?:非处|不是处子|并非完璧)", sentence):
        return True
    return bool(re.search(rf"{h}.{{0,12}}(?:曾经|以前|过去|早已).{{0,12}}(?:和|与)", sentence)
                and _third_party_pair(sentence, heroine, chain,
                                      "发生过关系|发生关系|同房|圆房"))


def _direct_event(sentence: str, kind: str, heroine: Heroine, chain: Chain, chapter: int) -> bool:
    if any(cue in sentence for cue in UNCERTAIN_CUES) or any(mark in sentence for mark in "“”\"‘’"):
        return False
    hnames = "|".join(re.escape(n) for n in heroine.names)
    pnames = "|".join(re.escape(n) for n in chain.protagonist)
    if not hnames or not pnames:
        return False
    h = rf"(?:{hnames})"
    p = rf"(?:{pnames})"
    if kind == "ntr":
        if heroine.confirmed_from is None or chapter <= heroine.confirmed_from:
            return False
        patterns = (
            rf"{h}.{{0,12}}(?:背着|瞒着){p}.{{0,18}}(?:和|与)(?P<third>[^，。！？\s]{{2,8}}?)(?:偷情|私通|发生关系)",
            rf"{p}.{{0,8}}(?:发现|撞见){h}.{{0,12}}(?:和|与)(?P<third>[^，。！？\s]{{2,8}}?)(?:偷情|私通|发生关系)",
        )
        for pattern in patterns:
            match = re.search(pattern, sentence)
            if match and not _contains_name(match.group("third"), chain.protagonist):
                return True
    elif kind == "past_relationship":
        # A heroine's history may predate her relationship with the protagonist.
        pattern = rf"{h}.{{0,12}}(?:曾经|以前|过去|早已).{{0,12}}(?:和|与)(?P<third>[^，。！？\s]{{2,8}}?)(?:发生过关系|发生关系|同房|圆房)"
        match = re.search(pattern, sentence)
        return bool(match and not _contains_name(match.group("third"), chain.protagonist))
    elif kind == "progress":
        return _progress_pair(sentence, heroine, chain)
    return False


def verify_event(passage: Passage, chain: Chain, kind: str, *, context: str = "") -> Finding:
    if kind not in EVENT_CUES:
        raise ValueError(kind)
    # A 250-character chunk may contain a side-character event *before* the
    # heroine's actual event. Judging only its first keyword silently loses the
    # latter. Every event-bearing sentence must be inspected independently.
    candidates = [s.strip() for s in SENTENCE_SPLIT.split(passage.text)
                  if any(c in s for c in EVENT_CUES[kind])]
    if not candidates:
        return Finding(kind, "unrelated", None, passage.chapter, passage.start, "", "无事件词")
    findings = [_verify_sentence(candidate, passage, chain, kind, context) for candidate in candidates]
    return max(findings, key=lambda f: {"explicit": 3, "clue": 2, "unbound": 1, "unrelated": 0}[f.verdict])


def _verify_sentence(candidate: str, passage: Passage, chain: Chain, kind: str,
                     context: str) -> Finding:
    sentence_index = passage.text.find(candidate)
    sentence_start = passage.start + len(passage.text[:sentence_index].encode("utf-8")) if sentence_index >= 0 else passage.start
    # Names outside the event sentence can help recall, but cannot prove who
    # performed the action. Pronouns/aliases need a separate coreference check.
    matched = [h for h in chain.heroines if _contains_name(candidate, h.names)]
    if not matched:
        # Even '她' can refer to a different woman in the preceding line. Keep
        # it in an internal unresolved bucket, never as heroine evidence.
        verdict = "unbound" if "她" in candidate and any(
            _contains_name(context, h.names) for h in chain.heroines) else "unrelated"
        return Finding(kind, verdict, None, passage.chapter, sentence_start,
                       candidate, "事件句未明确绑定女主")
    if len(matched) > 1:
        return Finding(kind, "unbound", None, passage.chapter, sentence_start,
                       candidate, "同句出现多位女主候选，角色归属未核实")
    heroine = matched[0]
    stage = None
    if kind == "progress":
        if "圆房" in candidate or "发生关系" in candidate:
            stage = "明确性关系"
        elif "结婚" in candidate or "成亲" in candidate:
            stage = "成婚"
        elif "确定关系" in candidate or "正式交往" in candidate:
            stage = "确认关系"
    if _direct_event(candidate, kind, heroine, chain, passage.chapter):
        return Finding(kind, "explicit", heroine.names[0], passage.chapter, sentence_start,
                       candidate, "原文明确、主角关系与事件时间可核对", stage)
    if not _relevant_to_heroine(candidate, heroine, chain, kind):
        return Finding(kind, "unrelated", None, passage.chapter, sentence_start,
                       candidate, "事件未绑定女主与非主角对象")
    return Finding(kind, "clue", heroine.names[0], passage.chapter, sentence_start,
                   candidate, "女主相关，但身份、时间或事件确定性不足", stage)


def aggregate_findings(findings: list[Finding], chain: Chain, chapters: int,
                       covered: set[int]) -> list[dict]:
    """Summarize evidence, never invert missing evidence into a clean-book claim."""
    summaries = []
    for heroine in chain.heroines:
        name = heroine.names[0]
        related = [f for f in findings if f.heroine == name]
        # Multiple nearby chunks can repeat one scene. For reporting, one
        # heroine/label/chapter is one event; the original findings retain all
        # source offsets for manual inspection.
        unique: dict[tuple[str, int], Finding] = {}
        for finding in related:
            key = (finding.kind, finding.chapter)
            if key not in unique or (finding.verdict == "explicit" and unique[key].verdict != "explicit"):
                unique[key] = finding
        events = sorted(unique.values(), key=lambda f: (f.chapter, f.start))
        direct = [f for f in events if f.verdict == "explicit"]
        clues = [f for f in events if f.verdict == "clue"]
        stages: dict[str, int] = {}
        for event in direct:
            if event.stage:
                stages[event.stage] = min(stages.get(event.stage, event.chapter + 1), event.chapter + 1)
        summaries.append({
            "heroine": name,
            "relationship_status": heroine.status,
            "report": "有可核对原文" if direct else "仅有待核线索" if clues else "未检出可核对证据（不等于不存在）",
            "coverage": f"{len(covered)}/{chapters} 章",
            "explicit_events": len(direct),
            "clue_events": len(clues),
            "milestones": stages,
            "chapters": [f.chapter + 1 for f in events],
        })
    return summaries


def infer_relationship_timeline(rows: list[Passage], chain: Chain) -> Chain:
    """Date only explicit, already-happened relationship/marriage sentences."""
    starts: dict[str, int] = {}
    for row in rows:
        if not any(cue in row.text for cue in ("确定关系", "正式交往", "结婚", "成亲")):
            continue
        # This scans all indexed passages, not only a capped candidate list.
        finding = verify_event(row, chain, "progress")
        if finding.verdict == "explicit" and finding.stage in {"确认关系", "成婚"}:
            starts[finding.heroine] = min(starts.get(finding.heroine, row.chapter), row.chapter)
    return replace(chain, heroines=tuple(replace(h, confirmed_from=starts.get(h.names[0]))
                                        for h in chain.heroines))


def recall(rows: list[Passage], chain: Chain, kind: str, *, semantic: list[Passage] | None = None,
           segment_size: int = 100, per_segment: int = 12) -> list[tuple[Passage, set[str]]]:
    """Union independent channels with chapter-segment quotas, not global top 80.

    The optional semantic input can be the app's current rank_multi hits. This
    probe intentionally does not load the production embedding model itself.
    """
    if kind not in EVENT_CUES:
        raise ValueError(kind)
    by_span: dict[tuple[int, int], tuple[Passage, set[str], int]] = {}
    names = tuple(n for h in chain.heroines for n in h.names)
    for row in rows:
        event = sum(cue in row.text for cue in EVENT_CUES[kind])
        person = int(_contains_name(row.text, names))
        protagonist = int(_contains_name(row.text, chain.protagonist))
        if not event and not (person and protagonist):
            continue
        channels = set()
        if event:
            channels.add("event")
        if person and protagonist:
            channels.add("relationship")
        if event and person:
            channels.add("event+heroine")
        by_span[(row.chapter, row.start)] = (row, channels, event * 2 + person * 2 + protagonist)
    for row in semantic or []:
        key = (row.chapter, row.start)
        if key in by_span:
            by_span[key][1].add("semantic")
        else:
            by_span[key] = (row, {"semantic"}, 1)
    groups: dict[int, list[tuple[Passage, set[str], int]]] = {}
    for row, channels, score in by_span.values():
        if "semantic" in channels:
            continue
        groups.setdefault(row.chapter // segment_size, []).append((row, channels, score))
    # The existing 80-hit semantic list is a guaranteed superset, not a rival
    # fighting the extra channels for 12 slots per 100 chapters.
    picked = [(row, by_span[(row.chapter, row.start)][1]) for row in semantic or []]
    for segment in sorted(groups):
        ranked = sorted(groups[segment], key=lambda item: (-item[2], item[0].chapter, item[0].start))
        picked.extend((row, channels) for row, channels, _ in ranked[:per_segment])
    return picked


def legacy_semantic_hits(rows: list[Passage], packed: list[bytes], kind: str,
                         embed_url: str) -> list[Passage]:
    """Reproduce rank_multi's top-80/2-per-chapter over the existing i8 index."""
    if kind not in LEGACY_QUERIES:
        return []
    import numpy as np

    request = urllib.request.Request(
        embed_url.rstrip("/") + "/v1/embeddings",
        data=json.dumps({"input": [QUERY_PREFIX + q for q in LEGACY_QUERIES[kind]],
                         "model": "embedding"}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        data = json.load(response)["data"]
    queries = []
    for item in data:
        vector = item["embedding"]
        if vector and isinstance(vector[0], list):
            vector = np.asarray(vector, dtype=np.float32).mean(axis=0)
        vector = np.asarray(vector, dtype=np.float32)
        queries.append(vector / np.linalg.norm(vector))
    vectors = np.stack([np.frombuffer(vec, dtype=np.int8).astype(np.float32) / 127 for vec in packed])
    query_matrix = np.stack(queries)
    if vectors.shape[1] != query_matrix.shape[1]:
        raise ValueError("embedding dimension does not match stored index")
    scores = (vectors @ query_matrix.T).max(axis=1)
    ranked = np.argsort(-scores, kind="stable")
    per_chapter: dict[int, int] = {}
    selected = []
    for i in ranked:
        row = rows[int(i)]
        if per_chapter.get(row.chapter, 0) >= 2:
            continue
        per_chapter[row.chapter] = per_chapter.get(row.chapter, 0) + 1
        selected.append(row)
        if len(selected) == 80:
            break
    return selected


def raw_paragraphs(raw: bytes, chapters: list[tuple[int, int, int]]) -> list[Passage]:
    """Read-only fallback for a book with no chunk index; lexical probe only."""
    rows = []
    for chapter, start, end in chapters:
        off = start
        for line in raw[start:end].split(b"\n"):
            if line.strip():
                rows.append(Passage(chapter, off, off + len(line), line.decode("utf-8")))
            off += len(line) + 1
    return rows


def decoded_utf8(raw: bytes, encoding: str) -> bytes:
    """Recreate decoded offsets only for encodings we can verify byte-for-byte."""
    label = encoding.upper()
    if label == "UTF-8":
        raw = raw.removeprefix(b"\xef\xbb\xbf")
        text = raw.decode("utf-8")
    elif label in {"GBK", "GB18030"}:
        text = raw.decode(label.lower())
    else:
        raise ValueError(f"unsupported decoded offset encoding: {encoding}")
    return text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")


def findings_around(rows: list[Passage], pos: int, chain: Chain, kind: str) -> list[Finding]:
    hit = rows[pos]
    neighbors = [row for row in rows[max(0, pos - 1):pos + 2] if row.chapter == hit.chapter]
    context = "\n".join(row.text for row in neighbors)
    return [finding for row in neighbors
            if (finding := verify_event(row, chain, kind, context=context)).verdict in {"clue", "explicit"}]


def inspect_book(db_path: Path, book_id: int, kind: str, embed_url: str | None = None,
                 show_evidence: bool = False, raw_fallback: bool = False,
                 per_segment: int = 12) -> dict:
    # Read-only mode also sees the live WAL; no schema migration, cache update,
    # engine start or write to the user's book directory is possible here.
    uri = f"file:{db_path.as_posix()}?mode=ro"
    with sqlite3.connect(uri, uri=True) as db:
        row = db.execute("SELECT title,path,encoding,total_bytes,chapter_count FROM books WHERE id=?", (book_id,)).fetchone()
        if row is None:
            raise ValueError(f"unknown book id {book_id}")
        title, source, encoding, total_bytes, chapters = row
        cast_row = db.execute("SELECT json FROM cast_cache WHERE book_id=?", (book_id,)).fetchone()
        if cast_row is None:
            raise ValueError("no cached cast; prototype does not generate one")
        chain = chain_from_cast(json.loads(cast_row[0]))
        spans = db.execute("SELECT chapter,start,end,vec FROM chunks WHERE book_id=? ORDER BY chapter,start", (book_id,)).fetchall()
        chapter_spans = db.execute("SELECT idx,body_start,end FROM chapters WHERE book_id=? ORDER BY idx", (book_id,)).fetchall()
    # Mirror core::decode: offsets address normalized decoded UTF-8, not the
    # original CRLF/BOM or legacy-encoded bytes on disk.
    raw = decoded_utf8(Path(source).read_bytes(), encoding)
    if len(raw) != total_bytes:
        raise ValueError("source size differs from cached offsets")
    indexed = {chapter for chapter, _, _, _ in spans}
    rows = []
    for chapter, start, end, _ in spans:
        try:
            text = raw[start:end].decode("utf-8")
        except UnicodeDecodeError:
            raise ValueError("index offsets do not match UTF-8 source") from None
        rows.append(Passage(chapter, start, end, text))
    candidate_source = "indexed_chunks"
    if not rows and raw_fallback:
        rows = raw_paragraphs(raw, chapter_spans)
        candidate_source = "raw_paragraphs_no_semantic_index"
    chain = infer_relationship_timeline(rows, chain)
    semantic = legacy_semantic_hits(rows, [v for _, _, _, v in spans], kind, embed_url) if embed_url and spans else []
    selected = recall(rows, chain, kind, semantic=semantic, per_segment=per_segment)
    found_by_span: dict[tuple[str, int, int, str], tuple[Finding, set[str]]] = {}
    positions = {(row.chapter, row.start): pos for pos, row in enumerate(rows)}
    for passage, channels in selected:
        pos = positions[(passage.chapter, passage.start)]
        # Inspect both adjacent chunks, but only within the same chapter. The
        # direct-evidence gate still requires a named heroine in the event
        # sentence itself; proximity alone cannot certify the event.
        for finding in findings_around(rows, pos, chain, kind):
            key = (finding.kind, finding.chapter, finding.start, finding.heroine or "")
            if key in found_by_span:
                found_by_span[key][1].update(channels)
            else:
                found_by_span[key] = (finding, set(channels))
    findings = [(finding, sorted(channels)) for finding, channels in found_by_span.values()]
    findings.sort(key=lambda item: (item[0].chapter, item[0].start))
    report_coverage = indexed if candidate_source == "indexed_chunks" else {c for c, _, _ in chapter_spans}
    return {
        "book": title,
        "chapters": chapters,
        "indexed_chapters": len(indexed),
        "last_indexed_chapter": max(indexed) + 1 if indexed else 0,
        "candidate_source": candidate_source,
        "heroine_candidates": [dict(names=h.names, status=h.status,
                                     confirmed_from=(h.confirmed_from + 1 if h.confirmed_from is not None else None))
                               for h in chain.heroines],
        "analysis_state": "no_heroine_candidate; cannot_assess" if not chain.heroines else "candidate_roster_available",
        "candidate_count": len(selected),
        "legacy_semantic_count": len(semantic),
        "new_candidate_count": len(selected) - len(semantic),
        "clues": sum(f.verdict == "clue" for f, _ in findings),
        "explicit": sum(f.verdict == "explicit" for f, _ in findings),
        "legacy_related": sum("semantic" in channels for f, channels in findings),
        "new_related": sum("semantic" not in channels for f, channels in findings),
        "report": aggregate_findings([f for f, _ in findings], chain, chapters, report_coverage),
        "preview": [dict(chapter=f.chapter + 1, heroine=f.heroine, verdict=f.verdict,
                         reason=f.reason, channels=c, stage=f.stage,
                         **({"excerpt": f.evidence[:260]} if show_evidence else {}))
                    for f, c in findings[:20]],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--book-id", type=int, required=True)
    parser.add_argument("--kind", choices=EVENT_CUES, required=True)
    parser.add_argument("--embed-url", help="optional, already-running local embedding server")
    parser.add_argument("--show-evidence", action="store_true", help="print short local excerpts to stdout; never saved")
    parser.add_argument("--raw-fallback", action="store_true", help="when unindexed, read local paragraphs without generating a real index")
    parser.add_argument("--per-segment", type=int, default=12)
    args = parser.parse_args()
    print(json.dumps(inspect_book(args.db, args.book_id, args.kind, args.embed_url,
                                  args.show_evidence, args.raw_fallback,
                                  args.per_segment), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
