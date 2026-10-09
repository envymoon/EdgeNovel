"""Isolated Q8/8K runtime probe. Never modifies the reader or its model directory."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import psutil


PORT = 18851
MIB = 1024 * 1024


def gpu_used_mib() -> int | None:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits", "-i", "0"],
            capture_output=True, text=True, timeout=3, check=True,
        )
        return int(result.stdout.strip().splitlines()[0])
    except (OSError, ValueError, subprocess.SubprocessError, IndexError):
        return None


def request(path: str, body: dict | None = None, timeout: float = 300) -> dict:
    payload = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST" if payload is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read())


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def read_only_library_counts(db: Path | None) -> dict | None:
    if db is None:
        return None
    # Explicit read-only URI: even a schema migration must not touch user data.
    conn = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        queries = {
            "chapters": "SELECT COUNT(*) FROM chapters",
            "summaries_present": "SELECT COUNT(*) FROM chapters WHERE summary IS NOT NULL",
            "moods_present": "SELECT COUNT(*) FROM chapters WHERE mood IS NOT NULL",
            "indexed_chunks": "SELECT COUNT(*) FROM chunks",
            "cast_caches": "SELECT COUNT(*) FROM cast_cache",
            "person_summaries": "SELECT COUNT(*) FROM person_summaries",
            "relation_summaries": "SELECT COUNT(*) FROM relation_summaries",
            "name_verdicts": "SELECT COUNT(*) FROM name_verdicts",
        }
        return {key: conn.execute(sql).fetchone()[0] for key, sql in queries.items()}
    finally:
        conn.close()


class MemorySampler:
    def __init__(self, pid: int, initial_gpu_mib: int | None):
        self.process = psutil.Process(pid)
        self.stop_event = threading.Event()
        self.peak_rss = 0
        self.peak_private = 0
        self.peak_gpu_mib = initial_gpu_mib
        self.samples = 0
        self.thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self) -> None:
        next_gpu_sample = 0.0
        while not self.stop_event.is_set():
            try:
                memory = self.process.memory_info()
                self.peak_rss = max(self.peak_rss, memory.rss)
                self.peak_private = max(self.peak_private, getattr(memory, "private", 0))
                self.samples += 1
            except psutil.Error:
                break
            if time.monotonic() >= next_gpu_sample:
                used = gpu_used_mib()
                if used is not None:
                    self.peak_gpu_mib = max(self.peak_gpu_mib or 0, used)
                next_gpu_sample = time.monotonic() + 0.5
            self.stop_event.wait(0.05)

    def __enter__(self) -> "MemorySampler":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop_event.set()
        self.thread.join(timeout=2)


def task() -> dict:
    # A synthetic chapter avoids copying or publishing the user's novels.
    excerpt = (
        "林舟在旧城收到一封没有署名的信。信中写明北塔钟声停下时，"
        "藏在药铺的账册会被取走。他先到药铺确认账册还在，随后与顾宁"
        "商量守住后门。夜里钟声停了，两人发现取走账册的是值守人周越。"
        "周越解释账册记录了伪造的药材交易，带走它是为了交给城中的调查者。"
        "林舟核对了账册和信件，决定与两人一起公开证据。"
    )
    return {
        "messages": [
            {
                "role": "system",
                "content": "你是小说章节摘要工具。用一句简体中文陈述句概括这一章发生的主要情节，不超过40个字。只输出这一句话：不要前缀、不要引号、不要解释、不要换行。",
            },
            {"role": "user", "content": f"{excerpt}\n\n用一句话（不超过40字）概括本章情节。/no_think"},
        ],
        "temperature": 0.0,
        "max_tokens": 120,
    }


def long_task(target_tokens: int) -> tuple[dict, int]:
    if not 1000 <= target_tokens <= 7000:
        raise ValueError("target_tokens must be between 1000 and 7000")
    filler = (
        "巡夜人沿石板路经过庭院，记录灯火、钟声、风向和水位。"
        "核对无误后，他合上册子，走向下一处院门。\n"
    )
    paragraphs = [filler] * 20
    while True:
        evidence = "周越把唯一的青铜账册交给顾宁保管，其他人没有接触。\n"
        midpoint = len(paragraphs) // 2
        content = "".join(paragraphs[:midpoint]) + evidence + "".join(paragraphs[midpoint:])
        body = {
            "messages": [
                {"role": "system", "content": "你是原文事实查询工具。只能依据给出的记录回答；未提及就回答未提及。"},
                {"role": "user", "content": f"以下是按顺序保存的记录：\n{content}\n问题：青铜账册最后交给谁保管？\n/no_think"},
            ],
            "temperature": 0.0,
            "max_tokens": 32,
        }
        token_count = len(request("/tokenize", {"content": content})["tokens"])
        if token_count >= target_tokens:
            return body, token_count
        paragraphs.extend([filler] * max(5, min(40, (target_tokens - token_count) // 28)))


def chat(body: dict, expected: str | None = None) -> dict:
    started = time.perf_counter()
    response = request("/v1/chat/completions", body)
    content = response["choices"][0]["message"]["content"]
    return {
        "sha256": sha256(content),
        "seconds": round(time.perf_counter() - started, 3),
        "prompt_tokens": response.get("usage", {}).get("prompt_tokens"),
        "completion_tokens": response.get("usage", {}).get("completion_tokens"),
        "expected_present": expected in content if expected else None,
    }


def cache_key(body: dict, model: Path, engine_digest: str, runtime_config: dict) -> str:
    identity = model.stat()
    material = {
        "engine_sha256": engine_digest,
        "model_path": str(model.resolve()),
        "model_bytes": identity.st_size,
        "model_mtime_ns": identity.st_mtime_ns,
        "runtime_config": runtime_config,
        "request": body,
    }
    return sha256(json.dumps(material, sort_keys=True, ensure_ascii=False, separators=(",", ":")))


def quality_probe() -> list[dict]:
    # Reuse the repository's existing labelled synthetic relationship cases.
    # These are a smoke gate, not a substitute for whole-book app regression.
    source = Path(__file__).resolve().parents[1] / "edge-quantization" / "run_matrix.py"
    spec = importlib.util.spec_from_file_location("edge_quant_matrix_runtime", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import {source}")
    matrix = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = matrix
    spec.loader.exec_module(matrix)
    cases: list[dict] = []
    for index in (0, 2, 4, 6, 8, 11):
        name, protagonist, other, expected, evidence = matrix.RELATION_CASES[index]
        marked = [
            text.replace(protagonist, "【主角】").replace(other, "【对象】")
            for text in evidence
        ]
        prompt = "待核验原文：\n" + "\n".join(
            f"{position}. {text}" for position, text in enumerate(marked, 1)
        )
        body = {
            "messages": [
                {"role": "system", "content": matrix.RELATION_SYSTEM},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.0, "seed": 1234, "max_tokens": 520,
        }
        response = request("/v1/chat/completions", body)
        content = response["choices"][0]["message"]["content"]
        label = matrix.last_label(content, matrix.RELATION_LABELS)
        cases.append({
            "id": name, "category": "relationship", "expected": expected,
            "label": label, "correct": label == expected, "sha256": sha256(content),
        })
    for index in (0, 4):
        word, sentence, expected = matrix.NAME_CASES[index]
        body = {
            "messages": [
                {"role": "system", "content": matrix.NAME_SYSTEM},
                {"role": "user", "content": f"词：{word}\n原文例句：{sentence}\n它是人物还是词语？/no_think"},
            ],
            "temperature": 0.0, "seed": 1234, "max_tokens": 48,
        }
        response = request("/v1/chat/completions", body)
        content = response["choices"][0]["message"]["content"]
        label = matrix.last_label(content, ["人物", "词语"])
        cases.append({
            "id": word, "category": "character", "expected": expected,
            "label": label, "correct": label == expected, "sha256": sha256(content),
        })
    return cases


def run_once(
    ai_dir: Path, out: Path, profile: str, round_index: int,
    gpu_layers: int, prompt_tokens: int, quality: bool,
) -> dict:
    if profile not in {"baseline", "exact_cache", "ubatch256", "ubatch128", "ubatch64"}:
        raise ValueError(profile)
    if request_port_occupied():
        raise RuntimeError(f"Port {PORT} is occupied; refusing to attach to another server")
    model = ai_dir / "Qwen3-0.6B-Q8_0.gguf"
    engine = ai_dir / "llama-server.exe"
    if not model.is_file() or not engine.is_file():
        raise FileNotFoundError("Q8 model or Windows engine not found")
    engine_digest = hashlib.sha256(engine.read_bytes()).hexdigest()
    args = [
        str(engine), "-m", str(model), "--port", str(PORT), "--host", "127.0.0.1",
        "-ngl", str(gpu_layers), "-t", "2", "-tb", "2", "-np", "1",
        "--poll", "0", "--poll-batch", "0", "--prio", "-1", "--no-webui",
        "-c", "8192", "--jinja", "--cache-type-k", "q8_0",
        "--cache-type-v", "q8_0", "--flash-attn", "auto",
    ]
    if profile.startswith("ubatch"):
        args.extend(["-ub", profile.removeprefix("ubatch")])
    log = out / f"{profile}-{round_index}.server.log"
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(
        subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0
    )
    before_gpu = gpu_used_mib()
    with log.open("wb") as stderr:
        process = subprocess.Popen(
            args, cwd=ai_dir, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=stderr, creationflags=flags,
        )
        try:
            with MemorySampler(process.pid, before_gpu) as memory:
                started = time.perf_counter()
                deadline = started + 120
                while time.perf_counter() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"Server exited; inspect {log}")
                    try:
                        request("/health", timeout=1)
                        break
                    except (OSError, ValueError):
                        time.sleep(0.1)
                else:
                    raise TimeoutError(f"Server startup timed out; inspect {log}")
                startup = time.perf_counter() - started
                idle = psutil.Process(process.pid).memory_info()
                body, actual_tokens = long_task(prompt_tokens) if prompt_tokens else (task(), None)
                runtime_config = {
                    "context": 8192, "kv": "q8_0", "gpu_layers": gpu_layers,
                    "ubatch": int(profile.removeprefix("ubatch")) if profile.startswith("ubatch") else 512,
                }
                first = chat(body, "顾宁" if prompt_tokens else None)
                if profile == "exact_cache":
                    # Lab-only memoization. This is not wired into the reader.
                    key = cache_key(body, model, engine_digest, runtime_config)
                    cached = {key: first}
                    lookup_started = time.perf_counter()
                    second = {
                        **cached[cache_key(body, model, engine_digest, runtime_config)],
                        "seconds": round(time.perf_counter() - lookup_started, 6),
                        "cache_hit": True,
                    }
                    changed = json.loads(json.dumps(body, ensure_ascii=False))
                    changed["messages"][-1]["content"] += "\n补充问题。"
                    changed_prompt_misses = (
                        cache_key(changed, model, engine_digest, runtime_config) not in cached
                    )
                else:
                    second = {**chat(body, "顾宁" if prompt_tokens else None), "cache_hit": False}
                    changed_prompt_misses = None
                cases = quality_probe() if quality else None
                result = {
                    "profile": profile,
                    "round": round_index,
                    "engine_sha256": engine_digest,
                    "model_bytes": model.stat().st_size,
                    "context": 8192,
                    "kv": "q8_0",
                    "gpu_layers": gpu_layers,
                    "gpu_before_mib": before_gpu,
                    "gpu_peak_delta_mib": (
                        max(0, memory.peak_gpu_mib - before_gpu)
                        if before_gpu is not None and memory.peak_gpu_mib is not None else None
                    ),
                    "long_context_tokens": actual_tokens,
                    "startup_seconds": round(startup, 3),
                    "idle_rss_mib": round(idle.rss / MIB, 1),
                    "idle_private_mib": round(getattr(idle, "private", 0) / MIB, 1),
                    "peak_rss_mib": round(memory.peak_rss / MIB, 1),
                    "peak_private_mib": round(memory.peak_private / MIB, 1),
                    "memory_samples": memory.samples,
                    "first": first,
                    "second": second,
                    "same_output": first["sha256"] == second["sha256"],
                    "changed_prompt_misses": changed_prompt_misses,
                    "quality_probe": cases,
                }
                return result
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def request_port_occupied() -> bool:
    try:
        request("/health", timeout=0.5)
        return True
    except (OSError, ValueError):
        return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ai-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--library-db", type=Path)
    parser.add_argument("--profiles", nargs="+", default=["baseline", "exact_cache"])
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--gpu-layers", type=int, default=99)
    parser.add_argument("--prompt-tokens", type=int, default=0)
    parser.add_argument("--quality", action="store_true")
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    args.out.mkdir(parents=True, exist_ok=True)
    payload = {
        "library_counts": read_only_library_counts(args.library_db),
        "runs": [],
        "note": "Synthetic summary probe only; not a full feature-quality regression.",
    }
    for profile in args.profiles:
        for round_index in range(1, args.rounds + 1):
            print(f"{profile} {round_index}/{args.rounds}", flush=True)
            payload["runs"].append(
                run_once(
                    args.ai_dir.resolve(), args.out, profile, round_index,
                    args.gpu_layers, args.prompt_tokens, args.quality,
                )
            )
            (args.out / "results.json").write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
            )
    print(args.out / "results.json")


if __name__ == "__main__":
    main()
