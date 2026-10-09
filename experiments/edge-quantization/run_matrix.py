from __future__ import annotations

import argparse
import difflib
import json
import re
import statistics
import subprocess
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import psutil


MOODS = ["轻松", "紧张", "热血", "悲伤", "温馨", "悬疑", "平静", "压抑"]
RELATION_LABELS = ["正式或性关系", "双向感情", "单向感情", "暧昧亲密", "非恋爱", "证据不足"]

SUMMARY_SYSTEM = (
    "你是小说章节摘要工具。用一句简体中文陈述句概括这一章发生的主要情节，"
    "不超过40个字。只输出这一句话：不要前缀、不要引号、不要解释、不要换行。"
)
MOOD_SYSTEM = (
    "你是小说章节氛围分类工具。从这些词中选出最贴合这一章氛围的一个："
    "轻松、紧张、热血、悲伤、温馨、悬疑、平静、压抑。只输出这一个词，不要解释。"
)
RELATION_SYSTEM = """你是中文网文“指定人物对”的局部证据核验器。只判断【主角】与【对象】这两个人，
不得把句中第三人的婚姻、恋爱、评价或行为套给他们。

从下列六项中只选一项：
正式或性关系：两人明确是夫妻、恋人、未婚夫妻、道侣，或原文明写两人已经发生性关系。
双向感情：两人互相喜欢，有双向事实，但尚无正式或性关系。
单向感情：只明确一方喜欢另一方。
暧昧亲密：亲吻、牵手、吃醋等信号存在，但方向或关系未确认。
非恋爱：朋友、亲属、师徒、敌人、普通救助、普通偏好，或证据实际属于第三人。
证据不足：梦境、假扮、传闻、提问、猜测、否认、未来愿望，无法证明现实中的关系。

“喜欢他的做事方式”“喜欢和他说话”不是爱情；搂肩、扶伤员也不是爱情。
每条证据可能来自不同章节。先逐条核对主语、宾语、否定与真假，最后单独一行输出一个选项。"""
NAME_SYSTEM = """你在读一本中文网络小说。给你一个词，判断它是这本书里某个人物的称呼，
还是一个普通词语。人物包括姓名、外号、代称（例如 陈平安、青衣小童、杨老头）。
普通词语包括动作、时间、指代（例如 伸手、回头、后者、先前、比如）。
想清楚后，最后只回答「人物」或「词语」两个词之一。"""


@dataclass(frozen=True)
class Profile:
    name: str
    weight: str
    model: Path
    kv: str


RELATION_CASES = [
    ("明确妻子", "林川", "苏晚", "正式或性关系", ["苏晚是林川的妻子，两人三年前成亲。"]),
    ("明确洞房", "顾昭", "叶红", "正式或性关系", ["叶红昨晚与顾昭入洞房，清晨才起身。"]),
    ("双向喜欢", "江临", "白芷", "双向感情", ["白芷喜欢江临。", "江临也承认自己喜欢白芷。"]),
    ("单向喜欢", "许河", "唐果", "单向感情", ["唐果暗恋许河，许河对此并不知情。"]),
    ("普通偏好", "吕树", "聂廷", "非恋爱", ["吕树更喜欢聂廷这种干脆的做事方式。"]),
    ("师徒救助", "沈舟", "云岚", "非恋爱", ["师父云岚抱住受伤的沈舟，把弟子送回房间疗伤。"]),
    ("第三人婚礼", "谢安", "柳青", "非恋爱", ["谢安和柳青参加赵山的婚礼，赵山迎娶钱月。"]),
    ("否定喜欢", "郑风", "陈安", "非恋爱", ["郑风不喜欢陈安，陈安也讨厌郑风。"]),
    ("梦中成亲", "秦野", "方雪", "证据不足", ["秦野梦见自己和方雪成亲，醒来后才知是幻境。"]),
    ("假扮妻子", "秦野", "方雪", "证据不足", ["为了混进宴席，方雪假扮秦野的妻子。"]),
    ("旁人提问", "许令", "红鸾", "证据不足", ["旁人笑问许令：你是不是喜欢红鸾？许令没有回答。"]),
    ("一次主动亲吻", "薛牧", "夏侯荻", "暧昧亲密", ["薛牧低头亲吻夏侯荻的脖颈，她没有推开。"]),
]

NAME_CASES = [
    ("陈平安", "陈平安抬头望向城头，握住了剑。", "人物"),
    ("青衣小童", "青衣小童跟在老爷身后，小声嘀咕。", "人物"),
    ("杨老头", "杨老头坐在药铺门口抽旱烟。", "人物"),
    ("宁姚", "宁姚收起飞剑，转身离开。", "人物"),
    ("伸手", "他伸手推开木门。", "词语"),
    ("回头", "少女回头看了一眼。", "词语"),
    ("后者", "前者沉默，后者点了点头。", "词语"),
    ("先前", "先前发生的事情无人再提。", "词语"),
    ("比如", "比如这座城中就有三家客栈。", "词语"),
    ("大人", "大人有大量，别与小的计较。", "词语"),
]


def decode(path: Path) -> str:
    raw = path.read_bytes()
    for encoding in ("utf-8-sig", "gb18030", "big5"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            pass
    return raw.decode("utf-8", errors="replace")


def request_json(port: int, path: str, body: dict[str, Any] | None = None, timeout: int = 300) -> dict[str, Any]:
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def healthy(port: int) -> bool:
    try:
        request_json(port, "/health", timeout=2)
        return True
    except Exception:
        return False


def gpu_used_mib() -> int | None:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits", "-i", "0"],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        return int(result.stdout.strip().splitlines()[0])
    except Exception:
        return None


class Server:
    def __init__(self, engine_dir: Path, profile: Profile, port: int, log: Path):
        self.engine_dir = engine_dir
        self.profile = profile
        self.port = port
        self.log = log
        self.proc: subprocess.Popen[bytes] | None = None
        self.log_handle = None
        self.start_seconds = 0.0
        self.idle_rss_mib = 0.0
        self.idle_private_mib = 0.0
        self.gpu_delta_mib: int | None = None

    def __enter__(self) -> "Server":
        before_gpu = gpu_used_mib()
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.log_handle = self.log.open("wb")
        cmd = [
            str(self.engine_dir / "llama-server.exe"),
            "-m", str(self.profile.model),
            "--port", str(self.port), "--host", "127.0.0.1",
            "-ngl", "99", "-t", "2", "-tb", "2", "-np", "1",
            "--poll", "0", "--poll-batch", "0", "--prio", "-1",
            "--no-webui", "-c", "8192", "--jinja", "--flash-attn", "auto",
            "--cache-type-k", self.profile.kv, "--cache-type-v", self.profile.kv,
        ]
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
        started = time.perf_counter()
        self.proc = subprocess.Popen(
            cmd,
            cwd=self.engine_dir,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=self.log_handle,
            creationflags=flags,
        )
        deadline = time.time() + 120
        while time.time() < deadline:
            if healthy(self.port):
                break
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.profile.name}: server exited {self.proc.returncode}; see {self.log}")
            time.sleep(0.1)
        else:
            raise TimeoutError(f"{self.profile.name}: server startup timed out")
        self.start_seconds = time.perf_counter() - started
        time.sleep(1)
        memory = psutil.Process(self.proc.pid).memory_info()
        self.idle_rss_mib = memory.rss / 1024**2
        self.idle_private_mib = getattr(memory, "private", memory.rss) / 1024**2
        after_gpu = gpu_used_mib()
        if before_gpu is not None and after_gpu is not None:
            self.gpu_delta_mib = max(0, after_gpu - before_gpu)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        if self.log_handle is not None:
            self.log_handle.close()

    def chat(self, system: str, user: str, max_tokens: int, temperature: float = 0.0, seed: int = 1234) -> dict[str, Any]:
        started = time.perf_counter()
        response = request_json(
            self.port,
            "/v1/chat/completions",
            {
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "temperature": temperature,
                "seed": seed,
                "max_tokens": max_tokens,
            },
        )
        wall = time.perf_counter() - started
        return {
            "text": response.get("choices", [{}])[0].get("message", {}).get("content", ""),
            "wall_seconds": wall,
            "usage": response.get("usage", {}),
            "timings": response.get("timings", {}),
        }

    def tokenize(self, text: str) -> int:
        response = request_json(self.port, "/tokenize", {"content": text})
        return len(response.get("tokens", []))


def cleaned(text: str) -> str:
    tail = text.rsplit("</think>", 1)[-1]
    return re.sub(r"\s+", " ", tail).strip().strip("。.!！；;：:\"“”")


def last_label(text: str, labels: list[str]) -> str | None:
    tail = text.rsplit("</think>", 1)[-1]
    found = [(tail.rfind(label), label) for label in labels if label in tail]
    return max(found, default=(-1, None))[1]


def excerpts(books_dir: Path, limit: int = 8, chars: int = 1400) -> list[dict[str, str]]:
    books = sorted(p for p in books_dir.glob("*.txt") if p.stat().st_size > 100_000)[:4]
    rows: list[dict[str, str]] = []
    for book in books:
        text = decode(book).replace("\x00", "")
        for fraction in (0.18, 0.67):
            offset = int(max(0, len(text) - chars) * fraction)
            start = max(0, text.rfind("\n", max(0, offset - 200), offset + 1))
            rows.append({
                "id": f"{book.stem}@{fraction:.2f}",
                "book": book.stem,
                "excerpt": text[start : start + chars].strip(),
            })
    return rows[:limit]


def long_context_cases(server: Server) -> list[tuple[str, str]]:
    filler = "第七码头的值守记录显示风平浪静，巡夜人依次检查仓门与灯火，没有发现异常。"
    facts = [
        ("赵行舟把唯一的青铜密钥交给了白砚，随后独自离港。", "赵行舟把青铜密钥交给谁？", "白砚"),
        ("宁秋把封存的赤纹地图托付给顾遥，旁人并不知情。", "宁秋把赤纹地图托付给谁？", "顾遥"),
        ("沈墨最终将黑檀木匣留给了陆迟，自己带走空箱。", "沈墨把黑檀木匣留给谁？", "陆迟"),
        ("叶蓁确认银色令牌由周渡保管，其余人只拿到木牌。", "银色令牌由谁保管？", "周渡"),
    ]
    target_tokens = 7000
    repeat = 64
    while repeat < 512:
        probe = (filler + "\n") * repeat
        if server.tokenize(probe) >= target_tokens:
            break
        repeat *= 2
    base = [(filler + "\n") for _ in range(repeat)]
    rows = []
    for index, (fact, question, expected) in enumerate(facts):
        position = [0.08, 0.35, 0.68, 0.90][index]
        parts = list(base)
        parts.insert(int(len(parts) * position), fact + "\n")
        content = "".join(parts)
        while server.tokenize(content) > 7600 and len(parts) > 32:
            parts.pop()
            content = "".join(parts)
        rows.append((f"以下是按顺序保存的记录：\n{content}\n请只回答：{question}/no_think", expected))
    return rows


def median_timing(rows: list[dict[str, Any]], key: str) -> float | None:
    values = [float(row["timings"].get(key, 0)) for row in rows if float(row["timings"].get(key, 0)) > 0]
    return statistics.median(values) if values else None


def profile_quality(server: Server, samples: list[dict[str, str]], baseline: dict[str, Any] | None) -> dict[str, Any]:
    summaries = []
    moods = []
    for sample in samples:
        summary = server.chat(SUMMARY_SYSTEM, f"{sample['excerpt']}\n\n用一句话（不超过40字）概括本章情节。/no_think", 120)
        mood = server.chat(MOOD_SYSTEM, f"{sample['excerpt']}\n\n本章氛围是哪一个词？/no_think", 32)
        summaries.append({"id": sample["id"], "book": sample["book"], **summary, "clean": cleaned(summary["text"])[:60]})
        moods.append({"id": sample["id"], "book": sample["book"], **mood, "label": last_label(mood["text"], MOODS)})

    relations = []
    for name, protagonist, other, expected, evidence in RELATION_CASES:
        marked = [text.replace(protagonist, "【主角】").replace(other, "【对象】") for text in evidence]
        user = "待核验原文：\n" + "\n".join(f"{i}. {text}" for i, text in enumerate(marked, 1))
        response = server.chat(RELATION_SYSTEM, user, 520, temperature=0.0)
        label = last_label(response["text"], RELATION_LABELS)
        relations.append({"case": name, "expected": expected, "label": label, "correct": label == expected, **response})

    names = []
    for word, sentence, expected in NAME_CASES:
        response = server.chat(NAME_SYSTEM, f"词：{word}\n原文例句：{sentence}\n它是人物还是词语？", 256, temperature=0.0)
        label = last_label(response["text"], ["人物", "词语"])
        names.append({"case": word, "expected": expected, "label": label, "correct": label == expected, **response})

    recall = []
    recall_system = "你是原文事实查询工具。只依据给出的记录回答，不解释，不补充。"
    for index, (user, expected) in enumerate(long_context_cases(server), 1):
        response = server.chat(recall_system, user, 32, temperature=0.0)
        answer = cleaned(response["text"])
        recall.append({"case": index, "expected": expected, "answer": answer, "correct": expected in answer, **response})

    result: dict[str, Any] = {
        "summaries": summaries,
        "moods": moods,
        "relations": relations,
        "names": names,
        "long_context": recall,
        "summary_valid_rate": sum(bool(row["clean"]) and "\n" not in row["clean"] for row in summaries) / len(summaries),
        "mood_parse_rate": sum(row["label"] is not None for row in moods) / len(moods),
        "relation_accuracy": sum(row["correct"] for row in relations) / len(relations),
        "relation_parse_rate": sum(row["label"] is not None for row in relations) / len(relations),
        "name_accuracy": sum(row["correct"] for row in names) / len(names),
        "long_context_accuracy": sum(row["correct"] for row in recall) / len(recall),
        "median_prompt_tokens_per_second": median_timing(summaries + moods + relations + names + recall, "prompt_per_second"),
        "median_generation_tokens_per_second": median_timing(summaries + moods + relations + names + recall, "predicted_per_second"),
    }
    if baseline is not None:
        base_summaries = {row["id"]: row["clean"] for row in baseline["summaries"]}
        similarities = [
            difflib.SequenceMatcher(None, base_summaries.get(row["id"], ""), row["clean"]).ratio()
            for row in summaries
        ]
        base_moods = {row["id"]: row["label"] for row in baseline["moods"]}
        base_relations = {row["case"]: row["label"] for row in baseline["relations"]}
        result["summary_baseline_similarity"] = statistics.mean(similarities)
        result["mood_baseline_agreement"] = sum(row["label"] == base_moods.get(row["id"]) for row in moods) / len(moods)
        result["relation_baseline_agreement"] = sum(row["label"] == base_relations.get(row["case"]) for row in relations) / len(relations)
    else:
        result["summary_baseline_similarity"] = 1.0
        result["mood_baseline_agreement"] = 1.0
        result["relation_baseline_agreement"] = 1.0
    return result


def parse_kv_mib(log: Path) -> float | None:
    text = log.read_text(encoding="utf-8", errors="replace")
    matches = re.findall(r"KV buffer size\s*=\s*([0-9.]+)\s*MiB", text)
    return sum(float(value) for value in matches) if matches else None


def qwen3_06b_kv_mib(cache_type: str, context: int = 8192) -> float:
    """Exact allocated K+V payload for Qwen3-0.6B's 28x8x128 KV shape."""
    values = 28 * context * 8 * 128 * 2
    bytes_per_value = 2.0 if cache_type == "f16" else 34 / 32
    return values * bytes_per_value / 1024**2


def report(data: dict[str, Any]) -> str:
    baseline = data["profiles"][0]
    base_bytes = baseline["model_bytes"]
    base_prompt = baseline["quality"].get("median_prompt_tokens_per_second") or 0
    base_generation = baseline["quality"].get("median_generation_tokens_per_second") or 0
    lines = [
        "# Edge quantization comparison",
        "",
        f"Generated: {data['generated_at']}",
        f"Engine: {data['engine_version']}",
        "Context: 8192 tokens; GPU offload; 1 slot; Flash Attention auto.",
        "",
        "## Resources and speed",
        "",
        "| Profile | Model MiB | Disk saved | KV MiB | Model + KV MiB | GPU delta MiB | Private RAM MiB | Cold start s | Prompt tok/s (change) | Gen tok/s (change) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in data["profiles"]:
        q = row["quality"]
        saved = 1 - row["model_bytes"] / base_bytes
        kv_mib = row.get("kv_mib") or 0
        prompt = q.get("median_prompt_tokens_per_second") or 0
        generation = q.get("median_generation_tokens_per_second") or 0
        prompt_change = (prompt / base_prompt - 1) if base_prompt else 0
        generation_change = (generation / base_generation - 1) if base_generation else 0
        lines.append(
            f"| {row['name']} | {row['model_bytes'] / 1024**2:.1f} | {saved:.1%} | "
            f"{kv_mib:.1f} | {row['model_bytes'] / 1024**2 + kv_mib:.1f} | "
            f"{row.get('gpu_delta_mib') or 0:.0f} | {row.get('idle_private_mib') or 0:.0f} | {row['cold_start_seconds']:.2f} | "
            f"{prompt:.1f} ({prompt_change:+.1%}) | {generation:.1f} ({generation_change:+.1%}) |"
        )
    lines += [
        "",
        "## Behaviour checks",
        "",
        "| Profile | Relation accuracy | Name accuracy | Mood agreement | Summary similarity | 8K recall |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in data["profiles"]:
        q = row["quality"]
        lines.append(
            f"| {row['name']} | {q['relation_accuracy']:.1%} | {q['name_accuracy']:.1%} | "
            f"{q['mood_baseline_agreement']:.1%} | {q['summary_baseline_similarity']:.1%} | "
            f"{q['long_context_accuracy']:.1%} |"
        )
    lines += [
        "",
        "## Interpretation limits",
        "",
        "- AWQ and importance-matrix Q4 are alternative 4-bit weight calibration methods, not additive switches.",
        "- Model + KV is a comparable capacity figure, not total process memory.",
        "- GPU memory is the observed total NVIDIA allocation delta and can move with other desktop activity.",
        "- Similarity and baseline agreement detect regressions; they are not independent human quality scores.",
        "- Windows RTX results select candidates only. Android Vulkan/CPU and iOS Metal must be measured on devices before release.",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-dir", type=Path, required=True)
    parser.add_argument("--q8", type=Path, required=True)
    parser.add_argument("--imatrix-q4", type=Path, required=True)
    parser.add_argument("--awq-q4", type=Path, required=True)
    parser.add_argument("--books-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    profiles = [
        Profile("q8_f16kv", "Q8_0", args.q8.resolve(), "f16"),
        Profile("q8_q8kv", "Q8_0", args.q8.resolve(), "q8_0"),
        Profile("imatrix_q4_f16kv", "imatrix Q4_K_M", args.imatrix_q4.resolve(), "f16"),
        Profile("imatrix_q4_q8kv", "imatrix Q4_K_M", args.imatrix_q4.resolve(), "q8_0"),
        Profile("awq_q4_f16kv", "AWQ-scaled Q4_K_M", args.awq_q4.resolve(), "f16"),
        Profile("awq_q4_q8kv", "AWQ-scaled Q4_K_M", args.awq_q4.resolve(), "q8_0"),
    ]
    for profile in profiles:
        if not profile.model.is_file():
            raise SystemExit(f"Missing model: {profile.model}")

    args.out.mkdir(parents=True, exist_ok=True)
    version_result = subprocess.run(
        [str(args.engine_dir / "llama-server.exe"), "--version"],
        capture_output=True, text=True, check=True,
    )
    version = (version_result.stdout or version_result.stderr).strip().replace("\n", " / ")
    samples = excerpts(args.books_dir)
    output: dict[str, Any] = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "engine_version": version,
        "profiles": [],
        "invalid_combinations": [
            "Q8 + AWQ: AWQ is a 4-bit weight-quantization route, not an independent Q8 switch.",
            "imatrix Q4 + AWQ Q4: both transform the same weights and cannot be stacked without destructive requantization.",
        ],
    }
    baseline_quality = None
    for index, profile in enumerate(profiles):
        print(f"[{index + 1}/{len(profiles)}] {profile.name}", flush=True)
        log = args.out / f"{profile.name}.server.log"
        with Server(args.engine_dir.resolve(), profile, 18837, log) as server:
            quality = profile_quality(server, samples, baseline_quality)
            if baseline_quality is None:
                baseline_quality = quality
            row = {
                "name": profile.name,
                "weight": profile.weight,
                "kv": profile.kv,
                "model": str(profile.model),
                "model_bytes": profile.model.stat().st_size,
                "cold_start_seconds": server.start_seconds,
                "idle_rss_mib": server.idle_rss_mib,
                "idle_private_mib": server.idle_private_mib,
                "gpu_delta_mib": server.gpu_delta_mib,
                "quality": quality,
            }
        row["kv_mib"] = parse_kv_mib(log) or qwen3_06b_kv_mib(profile.kv)
        row["kv_mib_source"] = "server log" if parse_kv_mib(log) else "architecture calculation"
        output["profiles"].append(row)
        (args.out / "results.partial.json").write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

    (args.out / "results.json").write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.out / "report.md").write_text(report(output), encoding="utf-8")
    print(args.out / "report.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
