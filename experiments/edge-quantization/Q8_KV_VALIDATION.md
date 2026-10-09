# Q8 KV-cache expanded validation

Date: 2026-09-03  
Engine: llama.cpp b9957 (`c4ae9a88f`) on Windows/Vulkan  
Model: unchanged Qwen3-0.6B Q8_0  
Context: unchanged 8192 tokens

## Decision

Q8_0 KV cache passes the current Windows quality and hallucination gate. It is
eligible to become a low-memory runtime option. It should not replace F16 KV on
mobile by default until Android Vulkan/CPU and iOS Metal device tests pass.

Speed was recorded in the earlier matrix but was not used for this decision.

## Expanded paired validation

Two variants of the 8K-context corpus were used:

- adversarial repeated records: three independent cold-start rounds;
- neutral records without sentences that conflict with the inserted evidence:
  two independent cold-start rounds.

Each profile processed 168 labelled scenarios per round:

- 48 short relationship-evidence cases;
- 48 relationship cases embedded near five positions in an 8K window;
- 48 answerable facts embedded near five positions in an 8K window;
- 24 absent-fact cases designed to expose unsupported answers.

This produced 840 paired outputs for F16 KV and Q8_0 KV.

| Corpus | Rounds | Paired outputs | Output differences | Regressions | Improvements | New relationship hallucinations | New absent-fact hallucinations |
|---|---:|---:|---:|---:|---:|---:|---:|
| Adversarial records | 3 | 504 | 0 | 0 | 0 | 0 | 0 |
| Neutral records | 2 | 336 | 4 repeated / 2 unique | 2 repeated / 1 unique | 2 repeated / 1 unique | 0 | 0 |
| Total | 5 | 840 | 4 (0.48%) | 2 | 2 | 0 | 0 |

The two neutral-record differences were stable across both rounds. One boundary
relationship case moved from correct to incorrect and another moved from
incorrect to correct, leaving aggregate accuracy unchanged. Neither difference
asserted an unsupported romantic relationship.

The earlier compact suite had shown a one-case relationship accuracy change
(5/12 to 4/12), unchanged name filtering and 8K recall, and no increase in its
high-risk relationship false-positive count. That result triggered this larger
paired validation rather than being ignored.

## Memory result

| Measurement | F16 KV | Q8_0 KV | Saving |
|---|---:|---:|---:|
| Allocated K+V payload at 8192 context | 896 MiB | 476 MiB | 420 MiB (46.9%) |
| Mean private process memory | 1765 MiB | 1338 MiB | about 427 MiB (24.2%) |
| Mean observed NVIDIA memory delta | 1538 MiB | 1124 MiB | about 414 MiB (26.9%) |

The K+V payload is calculated from Qwen3-0.6B's 28 layers, 8 KV heads and
128-dimensional heads. Process and GPU measurements are the means from the
three-run resource matrix. Mobile devices use different allocators and often
unified memory, so the exact on-device reduction must be measured rather than
assumed.

## Release boundary

- Keep the model weights at Q8_0 and context at 8192.
- Quantize both K and V cache to Q8_0 together.
- Expose this first as a low-memory option with F16 KV retained as fallback.
- Require an automatic fallback when the backend cannot create Q8_0 KV cache.
- Re-run annotation, chapter overview, relationship graph, background recovery
  and a full-book task on Android and iOS before changing the mobile default.
