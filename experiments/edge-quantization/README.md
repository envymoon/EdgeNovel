# Edge inference quantization experiment

This lab compares the reader's fixed production baseline with weight and KV-cache
quantization candidates. It never writes to the application's AI directory.

## Comparable profiles

| Profile | Weights | Weight calibration | KV cache |
|---|---|---|---|
| `q8_f16kv` | Q8_0 | none | F16 |
| `q8_q8kv` | Q8_0 | none | Q8_0 |
| `imatrix_q4_f16kv` | Q4_K_M | novel-specific llama.cpp importance matrix | F16 |
| `imatrix_q4_q8kv` | Q4_K_M | novel-specific llama.cpp importance matrix | Q8_0 |
| `awq_q4_f16kv` | Q4_K_M | AutoAWQ activation-aware scaling before GGUF quantization | F16 |
| `awq_q4_q8kv` | Q4_K_M | AutoAWQ activation-aware scaling before GGUF quantization | Q8_0 |

AWQ and importance-matrix Q4 are alternative weight calibration methods. They
are not independent switches, so `AWQ + imatrix Q4` and `Q8 + AWQ` are invalid
profiles rather than missing measurements.

The production model remains Qwen3 0.6B Q8_0 with an 8192-token context and F16
KV cache. Generated models, downloaded source weights, calibration text, and raw
results live in `.quant-lab/`, which is ignored by Git.

## Quality gates

- acceptance is based on labelled capability accuracy and new hallucination or
  false-positive risk; speed is informational and never compensates for a
  quality regression;
- current chapter summary prompt: valid one-line output and similarity to baseline;
- current closed-set mood prompt: parse rate and agreement with baseline;
- relationship evidence classification: accuracy on labelled adversarial cases;
- long-context fact recall: exact result from evidence placed deep in the 8K window;
- runtime: cold start, prompt processing, token generation, RAM and VRAM;
- storage: exact model bytes and the saving relative to the Q8 baseline.

`run_matrix.py` writes machine-readable JSON plus `report.md`. A candidate is not
eligible for the app merely because it is smaller: it must pass the output gates
and later be repeated on actual Android and iOS hardware.

For a release decision, run the full matrix at least three times and pass every
`results.json` to `aggregate_results.py`. The aggregate report includes averages,
ranges, semantic agreement with the unchanged Q8 baseline, and a conservative
relationship false-positive check. `repeat_baseline.py` is a shorter control for
checking whether the baseline itself remains deterministic on the current host.

`validate_q8_kv_quality.py` is the expanded paired quality gate for the only
remaining candidate. It deliberately excludes speed from acceptance and tests
relationship false positives plus unsupported factual answers at multiple
positions inside the unchanged 8K context. The current decision and mobile
release boundary are recorded in `Q8_KV_VALIDATION.md`.
