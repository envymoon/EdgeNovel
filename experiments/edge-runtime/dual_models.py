"""Measure chat + embedding engine residency without touching app state."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import urllib.request
from pathlib import Path

import psutil


MIB = 1024 * 1024
CHAT_PORT = 18853
EMBED_PORT = 18854


def post(port: int, path: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=data,
        headers={"Content-Type": "application/json"},
        method="POST" if payload is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read())


def memory(pid: int) -> dict:
    info = psutil.Process(pid).memory_info()
    return {
        "rss_mib": round(info.rss / MIB, 1),
        "private_mib": round(getattr(info, "private", 0) / MIB, 1),
    }


def ready(port: int, child: subprocess.Popen) -> None:
    for _ in range(120):
        if child.poll() is not None:
            raise RuntimeError(f"Engine on {port} exited with {child.returncode}")
        try:
            post(port, "/health")
            return
        except (OSError, ValueError):
            time.sleep(0.25)
    raise TimeoutError(f"Engine on {port} failed to start")


def stop(child: subprocess.Popen) -> None:
    child.terminate()
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ai-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--gpu-layers", type=int, default=99)
    args = parser.parse_args()
    ai_dir = args.ai_dir.resolve()
    engine = ai_dir / "llama-server.exe"
    q8 = ai_dir / "Qwen3-0.6B-Q8_0.gguf"
    embed = ai_dir / "bge-small-zh-v1.5-f16.gguf"
    for item in (engine, q8, embed):
        if not item.is_file():
            raise FileNotFoundError(item)
    args.out.mkdir(parents=True, exist_ok=True)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(
        subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0
    )
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
        str(engine), "-m", str(embed), "--port", str(EMBED_PORT), *common,
        "--embeddings", "--pooling", "cls", "-c", "512", "-b", "512", "-ub", "512",
    ]
    chat_child = None
    embed_child = None
    with (args.out / "chat.log").open("wb") as chat_log, (
        args.out / "embed.log"
    ).open("wb") as embed_log:
        try:
            chat_child = subprocess.Popen(
                chat_args, cwd=ai_dir, stdout=subprocess.DEVNULL, stderr=chat_log,
                stdin=subprocess.DEVNULL, creationflags=flags,
            )
            ready(CHAT_PORT, chat_child)
            chat_only = memory(chat_child.pid)
            embed_child = subprocess.Popen(
                embed_args, cwd=ai_dir, stdout=subprocess.DEVNULL, stderr=embed_log,
                stdin=subprocess.DEVNULL, creationflags=flags,
            )
            ready(EMBED_PORT, embed_child)
            # Exercise the embedder, because load-time allocation alone can miss
            # its working buffer. Do not send any user novel text.
            response = post(EMBED_PORT, "/v1/embeddings", {
                "model": "embedding", "input": ["林舟在旧城找到一本账册。"],
            })
            if not response.get("data"):
                raise RuntimeError("Embedding request returned no vector")
            both_chat = memory(chat_child.pid)
            both_embed = memory(embed_child.pid)
            both = {
                "rss_mib": round(both_chat["rss_mib"] + both_embed["rss_mib"], 1),
                "private_mib": round(both_chat["private_mib"] + both_embed["private_mib"], 1),
            }
            stop(chat_child)
            chat_child = None
            embed_only = memory(embed_child.pid)
            result = {
                "chat_only": chat_only,
                "both_chat": both_chat,
                "both_embed": both_embed,
                "both_total": both,
                "embed_only_after_chat_stop": embed_only,
                "note": "Point-in-time process memory; not OS-wide peak or battery use.",
            }
            (args.out / "results.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            print(args.out / "results.json")
        finally:
            if chat_child is not None:
                stop(chat_child)
            if embed_child is not None:
                stop(embed_child)


if __name__ == "__main__":
    main()
