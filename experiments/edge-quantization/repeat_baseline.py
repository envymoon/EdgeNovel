from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


def load_matrix_module():
    source = Path(__file__).with_name("run_matrix.py")
    spec = importlib.util.spec_from_file_location("edge_quant_matrix", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-dir", type=Path, required=True)
    parser.add_argument("--q8", type=Path, required=True)
    parser.add_argument("--books-dir", type=Path, required=True)
    parser.add_argument("--matrix-results", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    matrix = load_matrix_module()
    prior = json.loads(args.matrix_results.read_text(encoding="utf-8"))
    baseline = prior["profiles"][0]["quality"]
    profile = matrix.Profile("q8_f16kv_repeat", "Q8_0", args.q8.resolve(), "f16")
    log = args.out.with_suffix(".server.log")
    with matrix.Server(args.engine_dir.resolve(), profile, 18837, log) as server:
        quality = matrix.profile_quality(server, matrix.excerpts(args.books_dir), baseline)

    result = {
        "profile": profile.name,
        "summary_baseline_similarity": quality["summary_baseline_similarity"],
        "mood_baseline_agreement": quality["mood_baseline_agreement"],
        "relation_baseline_agreement": quality["relation_baseline_agreement"],
        "relation_accuracy": quality["relation_accuracy"],
        "name_accuracy": quality["name_accuracy"],
        "long_context_accuracy": quality["long_context_accuracy"],
        "median_prompt_tokens_per_second": quality["median_prompt_tokens_per_second"],
        "median_generation_tokens_per_second": quality["median_generation_tokens_per_second"],
        "quality": quality,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "quality"}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
