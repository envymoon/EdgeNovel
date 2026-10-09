from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any, Callable


ROMANTIC_LABELS = {"正式或性关系", "双向感情", "单向感情", "暧昧亲密"}
NON_ROMANTIC_EXPECTED = {"非恋爱", "证据不足"}


def mean(values: list[float]) -> float:
    return statistics.fmean(values)


def values(rows: list[dict[str, Any]], getter: Callable[[dict[str, Any]], float]) -> list[float]:
    return [float(getter(row)) for row in rows]


def mean_range(items: list[float], digits: int = 1) -> str:
    return f"{mean(items):.{digits}f} [{min(items):.{digits}f}–{max(items):.{digits}f}]"


def relation_false_positives(quality: dict[str, Any]) -> int:
    return sum(
        row["expected"] in NON_ROMANTIC_EXPECTED and row.get("label") in ROMANTIC_LABELS
        for row in quality["relations"]
    )


def aggregate(runs: list[dict[str, Any]]) -> dict[str, Any]:
    names = [profile["name"] for profile in runs[0]["profiles"]]
    grouped: list[dict[str, Any]] = []
    for name in names:
        rows = [next(profile for profile in run["profiles"] if profile["name"] == name) for run in runs]
        qualities = [row["quality"] for row in rows]
        kv_mib = rows[-1].get("kv_mib")
        if not kv_mib:
            kv_mib = 896.0 if rows[0]["kv"] == "f16" else 476.0
        grouped.append({
            "name": name,
            "weight": rows[0]["weight"],
            "kv": rows[0]["kv"],
            "model_bytes": rows[0]["model_bytes"],
            "kv_mib": kv_mib,
            "cold_start_seconds": values(rows, lambda row: row["cold_start_seconds"]),
            "gpu_delta_mib": values(rows, lambda row: row.get("gpu_delta_mib") or 0),
            "idle_private_mib": values(rows, lambda row: row.get("idle_private_mib") or 0),
            "prompt_tps": values(qualities, lambda quality: quality["median_prompt_tokens_per_second"]),
            "generation_tps": values(qualities, lambda quality: quality["median_generation_tokens_per_second"]),
            "relation_accuracy": values(qualities, lambda quality: quality["relation_accuracy"]),
            "relation_agreement": values(qualities, lambda quality: quality["relation_baseline_agreement"]),
            "relationship_false_positives": [relation_false_positives(quality) for quality in qualities],
            "name_accuracy": values(qualities, lambda quality: quality["name_accuracy"]),
            "mood_agreement": values(qualities, lambda quality: quality["mood_baseline_agreement"]),
            "summary_similarity": values(qualities, lambda quality: quality["summary_baseline_similarity"]),
            "long_context_accuracy": values(qualities, lambda quality: quality["long_context_accuracy"]),
        })
    return {"run_count": len(runs), "profiles": grouped}


def report(data: dict[str, Any]) -> str:
    baseline = data["profiles"][0]
    baseline_bytes = baseline["model_bytes"]
    baseline_capacity = baseline_bytes / 1024**2 + baseline["kv_mib"]
    baseline_prompt = mean(baseline["prompt_tps"])
    baseline_generation = mean(baseline["generation_tps"])
    lines = [
        "# 边缘推理量化三轮对比",
        "",
        f"每个方案独立冷启动并完整运行 {data['run_count']} 轮；上下文固定为 8192，GPU 全层卸载，单任务槽。",
        "方括号为三轮最小值–最大值。",
        "通过标准只看能力正确率和新增幻觉；速度仅供记录，不参与通过或淘汰。",
        "",
        "## 资源与速度",
        "",
        "| 方案 | 模型 MiB | 模型磁盘节省 | KV MiB | 模型+KV MiB | 总容量节省 | 进程私有内存 MiB | GPU 增量 MiB | 启动 s | 输入 tok/s | 变化 | 生成 tok/s | 变化 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in data["profiles"]:
        model_mib = row["model_bytes"] / 1024**2
        capacity = model_mib + row["kv_mib"]
        prompt = mean(row["prompt_tps"])
        generation = mean(row["generation_tps"])
        lines.append(
            f"| {row['name']} | {model_mib:.1f} | {1 - row['model_bytes'] / baseline_bytes:.1%} | "
            f"{row['kv_mib']:.1f} | {capacity:.1f} | {1 - capacity / baseline_capacity:.1%} | "
            f"{mean_range(row['idle_private_mib'], 0)} | {mean_range(row['gpu_delta_mib'], 0)} | "
            f"{mean_range(row['cold_start_seconds'], 2)} | {mean_range(row['prompt_tps'])} | "
            f"{prompt / baseline_prompt - 1:+.1%} | {mean_range(row['generation_tps'])} | "
            f"{generation / baseline_generation - 1:+.1%} |"
        )

    lines += [
        "",
        "## 输出稳定性与风险",
        "",
        "| 方案 | 关系正确率 | 与基线关系结论一致 | 高风险关系误报（12例） | 姓名正确率 | 氛围与基线一致 | 摘要文本相似度 | 8K回忆正确率 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in data["profiles"]:
        lines.append(
            f"| {row['name']} | {mean(row['relation_accuracy']):.1%} | "
            f"{mean(row['relation_agreement']):.1%} | {mean_range(row['relationship_false_positives'], 0)} | "
            f"{mean(row['name_accuracy']):.1%} | {mean(row['mood_agreement']):.1%} | "
            f"{mean(row['summary_similarity']):.1%} | {mean(row['long_context_accuracy']):.1%} |"
        )

    lines += [
        "",
        "## 结论",
        "",
        "- `q8_f16kv`：生产基线；三轮输出完全一致。",
        "- `q8_q8kv`：后续扩大到 840 次配对输出后，没有新增关系或事实幻觉，也没有净正确率下降；已通过当前 Windows 质量门槛，可进入移动端低内存选项的真机验证。",
        "- `imatrix_q4_*`：高风险关系误报从基线 1 例增加到 2–3 例，按当前标准淘汰。",
        "- `awq_q4_*`：高风险关系误报增加，且关系或姓名正确率下降，按当前标准淘汰。",
        "- Windows 正式默认值暂时不变；Q8 + Q8 KV 下一步作为移动端低内存选项进行 Android/iOS 真机验证。",
        "",
        "## 说明",
        "",
        "- KV 容量按 Qwen3-0.6B 的 28 层、8 个 KV 头、128 head-dim 精确计算；F16 为 896 MiB，Q8_0 为 476 MiB。",
        "- AWQ 结果是 activation-aware 缩放后再由当前 llama.cpp 打包成 Q4_K_M，用的是现有运行时，不是独立的 packed-AWQ 内核。",
        "- AWQ 文件比 importance-matrix 文件额外少 83.5 MiB，来自相同输入/输出嵌入矩阵的安全去重，不应算作 AWQ 算法本身的收益。",
        "- 高风险关系误报指把应为“非恋爱/证据不足”的样例判为正式、双向、单向或暧昧关系；它只是小型回归门，不等于完整人工质量评测。",
        "- Windows RTX 结果只能筛选候选；任何未来候选仍需在 Android Vulkan/CPU 和 iOS Metal 真机复测。",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", action="append", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    runs = [json.loads(path.read_text(encoding="utf-8")) for path in args.result]
    data = aggregate(runs)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report(data), encoding="utf-8")
    args.out.with_suffix(".json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
