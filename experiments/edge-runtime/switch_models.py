"""Isolated A/B for concurrent versus mutually exclusive model residency."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path

from dual_models import CHAT_PORT, EMBED_PORT, memory, post, ready, stop
from measure import task


def response_hash(value: object) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def start(args: list[str], ai_dir: Path, log: Path) -> tuple[subprocess.Popen, object, float]:
    handle = log.open("wb")
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(
        subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0
    )
    started = time.perf_counter()
    try:
        child = subprocess.Popen(
            args, cwd=ai_dir, stdout=subprocess.DEVNULL, stderr=handle,
            stdin=subprocess.DEVNULL, creationflags=flags,
        )
    except BaseException:
        handle.close()
        raise
    try:
        port = int(args[args.index("--port") + 1])
        ready(port, child)
        return child, handle, time.perf_counter() - started
    except BaseException:
        stop(child)
        handle.close()
        raise


def chat() -> str:
    result = post(CHAT_PORT, "/v1/chat/completions", task())
    return response_hash(result["choices"][0]["message"]["content"])


def embed() -> str:
    result = post(EMBED_PORT, "/v1/embeddings", {
        "model": "embedding", "input": ["林舟在旧城找到一本账册。"],
    })
    return response_hash(result["data"][0]["embedding"])


def run_variant(
    name: str, round_index: int, ai_dir: Path, out: Path,
    chat_args: list[str], embed_args: list[str],
) -> dict:
    for port in (CHAT_PORT, EMBED_PORT):
        try:
            post(port, "/health")
        except (OSError, ValueError):
            pass
        else:
            raise RuntimeError(f"Port {port} is already occupied")
    children: list[tuple[subprocess.Popen, object]] = []
    starts: list[float] = []
    peak_private = 0.0
    peak_rss = 0.0

    def launch(args: list[str], label: str) -> subprocess.Popen:
        child, handle, duration = start(args, ai_dir, out / f"{name}-{round_index}-{label}.log")
        children.append((child, handle))
        starts.append(duration)
        return child

    def retire(child: subprocess.Popen) -> None:
        stop(child)
        for current, handle in children:
            if current is child:
                handle.close()
                children.remove((current, handle))
                break

    def sample() -> None:
        nonlocal peak_private, peak_rss
        current = [memory(child.pid) for child, _ in children]
        peak_private = max(peak_private, sum(item["private_mib"] for item in current))
        peak_rss = max(peak_rss, sum(item["rss_mib"] for item in current))

    started = time.perf_counter()
    try:
        chat_child = launch(chat_args, "chat-first")
        first_hash = chat()
        sample()
        if name == "exclusive":
            retire(chat_child)
        embed_child = launch(embed_args, "embed")
        embedding_hash = embed()
        sample()
        if name == "exclusive":
            retire(embed_child)
            chat_child = launch(chat_args, "chat-second")
        second_hash = chat()
        sample()
        return {
            "variant": name,
            "round": round_index,
            "peak_private_mib_snapshot": round(peak_private, 1),
            "peak_rss_mib_snapshot": round(peak_rss, 1),
            "start_seconds": [round(value, 3) for value in starts],
            "sequence_seconds": round(time.perf_counter() - started, 3),
            "chat_first_sha256": first_hash,
            "chat_second_sha256": second_hash,
            "embedding_sha256": embedding_hash,
            "same_chat_result": first_hash == second_hash,
        }
    finally:
        for child, handle in children:
            stop(child)
            handle.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ai-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--gpu-layers", type=int, default=99)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    ai_dir = args.ai_dir.resolve()
    engine = ai_dir / "llama-server.exe"
    q8 = ai_dir / "Qwen3-0.6B-Q8_0.gguf"
    bge = ai_dir / "bge-small-zh-v1.5-f16.gguf"
    for path in (engine, q8, bge):
        if not path.is_file():
            raise FileNotFoundError(path)
    args.out.mkdir(parents=True, exist_ok=True)
    common = [
        "--host", "127.0.0.1", "-ngl", str(args.gpu_layers), "-t", "2", "-tb", "2",
        "-np", "1", "--poll", "0", "--poll-batch", "0", "--prio", "-1", "--no-webui",
    ]
    chat_args = [
        str(engine), "-m", str(q8), "--port", str(CHAT_PORT), *common,
        "-c", "8192", "--jinja", "--cache-type-k", "q8_0",
        "--cache-type-v", "q8_0", "--flash-attn", "auto",
    ]
    embed_args = [
        str(engine), "-m", str(bge), "--port", str(EMBED_PORT), *common,
        "--embeddings", "--pooling", "cls", "-c", "512", "-b", "512", "-ub", "512",
    ]
    payload = {"runs": [], "note": "Process-memory snapshots; no battery or thermal measurement."}
    for round_index in range(1, args.rounds + 1):
        # Alternate order to avoid giving the second variant all OS file-cache benefit.
        order = ("concurrent", "exclusive") if round_index % 2 else ("exclusive", "concurrent")
        for variant in order:
            print(f"{variant} {round_index}/{args.rounds}", flush=True)
            payload["runs"].append(
                run_variant(variant, round_index, ai_dir, args.out, chat_args, embed_args)
            )
            (args.out / "results.json").write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
            )
    print(args.out / "results.json")


if __name__ == "__main__":
    main()
