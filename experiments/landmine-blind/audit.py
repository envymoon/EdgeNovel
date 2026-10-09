"""Read-only, local candidate audit. Never writes book text or database rows."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "landmine-pipeline"))
from probe import chain_from_cast, decoded_utf8  # noqa: E402


PATTERNS = {
    "past": re.compile(
        r"非处|不是处[女子]?|已非处|处子之身|完璧|落红|失身|破身|守宫砂|"
        r"初夜|初次.{0,8}(?:给|交给)|第一次.{0,8}(?:给|交给)|"
        r"(?:曾经|以前|过去|早已).{0,18}(?:同房|圆房|发生.{0,3}关系)"
    ),
    "mental": re.compile(
        r"羞辱|屈辱|背叛|抛弃|欺骗|利用|玩弄|折磨|绝望|崩溃|"
        r"心如死灰|心死|痛不欲生|不想活|求死|自责|愧疚|"
        r"精神.{0,4}(?:伤害|摧残|折磨)|强迫.{0,12}(?:选择|决定)"
    ),
}


def inspect(db_path: Path, book_id: int, kind: str, limit: int, include_text: bool,
            cue_filter: str = "", name_filter: str = "") -> dict:
    with sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True) as db:
        book = db.execute(
            "SELECT title,path,encoding,total_bytes FROM books WHERE id=?", (book_id,)
        ).fetchone()
        if book is None:
            raise ValueError(f"unknown book id: {book_id}")
        cast_row = db.execute("SELECT json FROM cast_cache WHERE book_id=?", (book_id,)).fetchone()
        chapters = db.execute(
            "SELECT idx,body_start,end FROM chapters WHERE book_id=? ORDER BY idx", (book_id,)
        ).fetchall()
    title, source, encoding, total_bytes = book
    chain = chain_from_cast(json.loads(cast_row[0])) if cast_row else None
    protagonist = chain.protagonist if chain else ()
    heroines = tuple(n for h in chain.heroines for n in h.names) if chain else ()
    raw = decoded_utf8(Path(source).read_bytes(), encoding)
    if len(raw) != total_bytes:
        raise ValueError("source text does not match cached chapter offsets")
    pattern = PATTERNS[kind]
    found = []
    for chapter, start, end in chapters:
        body = raw[start:end].decode("utf-8")
        for match in pattern.finditer(body):
            if cue_filter and cue_filter not in match.group():
                continue
            around = body[max(0, match.start() - 100):min(len(body), match.end() + 100)]
            if name_filter and name_filter not in around:
                continue
            score = 0
            if kind == "past":
                score += 5 if any(n in around for n in heroines) else 0
                score += 2 if any(n in around for n in protagonist) else 0
            else:
                score += 5 if any(n in around for n in protagonist) else 0
            score += 1 if len(match.group()) > 2 else 0
            offset = start + len(body[:match.start()].encode("utf-8"))
            found.append((score, chapter + 1, offset, match.group(), around))
    found.sort(key=lambda item: (-item[0], item[1], item[2]))
    # Diverse chapters; avoid filling the output with one repeated scene.
    selected = []
    seen_chapters = set()
    for score, chapter, offset, cue, context in found:
        if chapter in seen_chapters:
            continue
        selected.append({
            "chapter": chapter, "byte_offset": offset, "cue": cue, "score": score,
            **({"context": context.replace("\n", " ")[:220]} if include_text else {}),
        })
        seen_chapters.add(chapter)
        if len(selected) >= limit:
            break
    return {
        "book_id": book_id, "book": title, "kind": kind,
        "protagonist": protagonist, "heroine_candidates": heroines,
        "raw_cue_count": len(found), "chapters_with_cues": len({item[1] for item in found}),
        "sample": selected,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--book-id", type=int, required=True)
    parser.add_argument("--kind", choices=PATTERNS, required=True)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--show-context", action="store_true")
    parser.add_argument("--cue-filter", default="")
    parser.add_argument("--name-filter", default="")
    args = parser.parse_args()
    print(json.dumps(inspect(args.db, args.book_id, args.kind, args.limit, args.show_context,
                             args.cue_filter, args.name_filter),
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
