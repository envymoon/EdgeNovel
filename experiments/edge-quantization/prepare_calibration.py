from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


SEPARATOR = "\n\n<|novel_calibration_sample|>\n\n"


def decode(path: Path) -> str:
    raw = path.read_bytes()
    for encoding in ("utf-8-sig", "gb18030", "big5"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            pass
    return raw.decode("utf-8", errors="replace")


def clean(text: str) -> str:
    text = text.replace("\x00", "")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def distributed_samples(text: str, count: int, chars: int) -> list[str]:
    if len(text) <= chars:
        return [text]
    usable = len(text) - chars
    offsets = [round(usable * (i + 0.5) / count) for i in range(count)]
    samples: list[str] = []
    for offset in offsets:
        start = max(0, text.rfind("\n", max(0, offset - 200), offset + 1))
        sample = clean(text[start : start + chars])
        if len(sample) >= chars // 2:
            samples.append(sample)
    return samples


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--books-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=96)
    parser.add_argument("--chars", type=int, default=1800)
    args = parser.parse_args()

    books = sorted(p for p in args.books_dir.glob("*.txt") if p.stat().st_size > 100_000)
    if not books:
        raise SystemExit(f"No usable TXT books in {args.books_dir}")

    per_book = max(1, (args.samples + len(books) - 1) // len(books))
    rows: list[str] = []
    for book in books:
        title = book.stem
        for sample in distributed_samples(clean(decode(book)), per_book, args.chars):
            rows.append(f"书名：{title}\n{sample}")
    rows = rows[: args.samples]

    # Exercise the same instruction vocabulary used by the application, while
    # keeping the copyrighted source text local and out of version control.
    prompts = [
        "你是小说章节摘要工具。用一句简体中文陈述句概括主要情节，不超过40个字。",
        "从轻松、紧张、热血、悲伤、温馨、悬疑、平静、压抑中选择章节氛围。",
        "依据原文概括人物的身份来历、性情为人和重要转折，不编造情节。",
        "依据按时间排列的原文，概括两个人物之间发生的来往，不贴关系标签。",
        "判断一个中文词是小说人物称呼还是普通词语。",
    ]
    rows.extend(prompts)
    payload = SEPARATOR.join(rows) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(payload, encoding="utf-8")
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    print(f"samples={len(rows)} chars={len(payload)} sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

