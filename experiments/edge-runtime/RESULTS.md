# Edge runtime: first isolated measurements

Date: 2026-09-23. These are **Windows-only synthetic probes**, not an Android
or iOS release decision. The reader's installed engine/model were read in
place; no application data, binary, prompt, or model was modified. Raw run
logs and measurements are in ignored `.runtime-lab/`.

Fixed configuration: Qwen3 0.6B Q8_0, Q8_0 K/V cache, context 8192, llama.cpp
b9957, one slot, two threads, Flash Attention auto, Vulkan GPU offload. The
same synthetic input and model were used across profiles. Three independent
engine starts per profile. Windows process private committed memory is not
Android total RAM; `nvidia-smi` GPU deltas are approximate and cannot be
added to process private memory as if they were disjoint.

## Existing duplicate work and exact replay

The pinned engine reports prompt caching **enabled by default**. On a repeated
short chapter-summary request, the second request averaged 0.145 s rather than
the first request's 4.688 s, because the engine reused the prompt prefix. An
isolated exact-response memo reduced the repeated request to 0.0003 s but did
not change resident private memory (1560.4 versus 1560.0 MiB, within noise).
All three runs returned identical output, and a changed input missed the lab
cache. This is not sufficient reason to add a general persistent cache to the
app: chapter enrichment, character and relation results already persist.

Source audit found an additional zero-work opportunity: `enrich_book`,
`describe_people`, and `label_relations` currently prepare/load the chat engine
*before* checking whether any chapters, people, or edges remain to process.
Moving that check ahead of engine startup could avoid an entire cold load when
everything is already cached. It has not been changed in the shipping app yet.
The existing person/relation cache keys use names, not the complete evidence;
they must not be mistaken for exact-result caching when chapters are added.

## Physical microbatch (long-context smoke gate)

Each run answered the same 5.6K-token synthetic factual question and eight
labelled relationship/character cases. The factual answer was correct and its
output hash identical in all 12 runs. The labelled cases were **not** stable:

| Profile | Private peak mean | Change | Correct cases per round | New wrong cases versus paired baseline |
|---|---:|---:|---:|---:|
| Default physical batch | 2075.9 MiB | baseline | 7/8, 7/8, 7/8 | 0 |
| 256 | 1943.1 MiB | -132.8 MiB | 4/8, 4/8, 4/8 | 3 each round |
| 128 | 1942.3 MiB | -133.6 MiB | 3/8, 3/8, 3/8 | 4 each round |
| 64 | 1935.3 MiB | -140.6 MiB | 3/8, 3/8, 3/8 | 4 each round |

The legacy labelled suite is only a smoke test, not the reader's complete
current production pipeline. Nevertheless, the reproducible new errors fail
the no-regression gate. **Do not adopt any of these three microbatch settings
in the app on these results.** A single unchanged factual answer had masked
the regression in the earlier resource-only probe.

## Mutually exclusive model residency

With chat and BGE loaded together, the BGE process added about 204 MiB of
private committed memory (three point-in-time measurements: 203.8–205.0 MiB).
The complete `chat → embed → chat` comparison gave:

| Policy | Peak private snapshot mean | Sequence time mean | Output |
|---|---:|---:|---|
| Both resident | 1763.7 MiB | 10.18 s | Chat and embedding hashes stable |
| One resident at a time | 1560.4 MiB | 17.85 s | Same hashes in all three rounds |

Exclusivity saved ~203 MiB in this sequence but added ~7.67 s by reloading
the chat model and losing its in-memory prompt state. Total energy and thermal
effects were not measured. It may be useful as an **optional low-memory mode**
when a device would otherwise fail, but it is not justified as a default or
as an energy-saving claim.

## Next gates

1. Repeat accepted candidates on the app's actual chapter overview, character
   graph/description, relationship structure, landmine retrieval and semantic
   search using fixed local book fixtures. None may increase hallucinations or
   remove relevant evidence. Do not reuse private book text in committed logs.
2. Android ARM CPU instruction-set adaptation needs an ARM64 device. The
   available emulator image is x86_64, so it cannot measure DOTPROD/I8MM or
   handset thermal/battery behavior. The pinned llama.cpp supports CPU backend
   variants, but current APK statically links a generic ARMv8-A CPU backend;
   packaging variants is a separate, reversible build experiment.
3. Only after the CPU baseline is verified on a real device, isolate GPU
   offload as its own candidate. NPU conversion remains a separate project.

No runtime candidate was merged into the Windows or Android application.
