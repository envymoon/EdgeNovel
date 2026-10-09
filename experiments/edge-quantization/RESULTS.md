# Quantization results (2026-09-03)

Host: Windows, NVIDIA RTX 4060 Laptop GPU, llama.cpp b9957 (`c4ae9a88f`).
Each profile was cold-started and ran the complete suite three times with an
8192-token context, full GPU offload, and one inference slot. Every profile was
internally deterministic across all three runs.

The release gate is capability and hallucination risk. Speed is reported only
as operational information and is not used to accept or reject a candidate.

## Resources and speed

Ranges show the minimum and maximum result across three runs.

| Profile | Model MiB | Disk saved | KV MiB | Model + KV saved | Private RAM MiB | GPU delta MiB | Prompt tok/s | Change | Generation tok/s | Change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `q8_f16kv` | 609.8 | 0.0% | 896 | 0.0% | 1765 [1763–1768] | 1538 [1529–1543] | 3357.7 [3304.7–3404.9] | +0.0% | 251.6 [249.6–254.8] | +0.0% |
| `q8_q8kv` | 609.8 | 0.0% | 476 | 27.9% | 1338 [1337–1338] | 1124 [1120–1133] | 3123.7 [3024.0–3186.9] | -7.0% | 239.9 [239.3–241.1] | -4.7% |
| `imatrix_q4_f16kv` | 461.8 | 24.3% | 896 | 9.8% | 1534 [1532–1535] | 1267 [1237–1311] | 3361.0 [3317.2–3430.7] | +0.1% | 306.6 [304.1–309.5] | +21.8% |
| `imatrix_q4_q8kv` | 461.8 | 24.3% | 476 | 37.7% | 1107 [1107–1107] | 884 [876–888] | 3063.0 [3015.9–3099.9] | -8.8% | 290.0 [288.4–291.6] | +15.2% |
| `awq_q4_f16kv` | 378.3 | 38.0% | 896 | 15.4% | 1531 [1531–1532] | 1312 [1311–1313] | 3380.6 [3345.7–3402.1] | +0.7% | 307.1 [306.0–307.8] | +22.0% |
| `awq_q4_q8kv` | 378.3 | 38.0% | 476 | 43.3% | 1107 [1106–1108] | 888 [888–888] | 3107.8 [3049.2–3189.8] | -7.4% | 289.5 [289.4–289.6] | +15.0% |

## Behaviour checks

| Profile | Relation accuracy | Relation agreement with baseline | High-risk relationship false positives (12 cases) | Name accuracy | Mood agreement | Summary similarity | 8K recall |
|---|---:|---:|---:|---:|---:|---:|---:|
| `q8_f16kv` | 41.7% | 100.0% | 1 | 70.0% | 100.0% | 100.0% | 50.0% |
| `q8_q8kv` | 33.3% | 33.3% | 1 | 70.0% | 87.5% | 77.3% | 50.0% |
| `imatrix_q4_f16kv` | 41.7% | 41.7% | 2 | 80.0% | 50.0% | 45.1% | 50.0% |
| `imatrix_q4_q8kv` | 41.7% | 41.7% | 3 | 70.0% | 50.0% | 44.7% | 50.0% |
| `awq_q4_f16kv` | 25.0% | 50.0% | 2 | 60.0% | 50.0% | 54.2% | 50.0% |
| `awq_q4_q8kv` | 33.3% | 41.7% | 2 | 70.0% | 50.0% | 52.7% | 50.0% |

## Decision

- Keep `q8_f16kv` as the production default.
- `q8_q8kv` passed the subsequent expanded Windows gate: across 840 paired
  outputs it produced no new relationship or absent-fact hallucinations and no
  net accuracy loss. It is eligible to become a low-memory option, subject to
  Android and iOS device validation. See `Q8_KV_VALIDATION.md`.
- Reject both 4-bit routes for the current release. They generated faster, but
  increased risky relationship false positives from one baseline case to two
  or three cases. AWQ also reduced relationship and name accuracy.
- The measured speed changes do not affect these decisions.

The AWQ path applies activation-aware scaling and then exports through the
current GGUF Q4_K_M runtime. It is not packed-AWQ kernel inference. Its extra
83.5 MiB disk advantage over the importance-matrix model comes from removing a
duplicate tied output embedding tensor, not from AWQ itself.

This is a model-layer regression gate, not a full reader end-to-end evaluation.
Any future candidate still needs a larger golden corpus and Android Vulkan/CPU
and iOS Metal device testing before it can become a user-facing option.
