# Edge runtime experiments

Isolated Windows baseline. The runner reads the installed Q8 model and engine,
but writes only to its chosen output directory. It never opens the reader's
database in write mode. The optional library audit reports aggregate counts,
not novel text or titles.

The baseline matches the quiet Windows profile: Q8 weights, Q8 K/V, 8K context,
two threads, one slot, Flash Attention auto, and the requested GPU layer count.
`exact_cache` is a lab-only identical-response replay. `ubatch256`, `ubatch128`
and `ubatch64` change just the physical microbatch size. Each profile starts a
fresh engine process. The runner does **not** change the shipping application.

Run from the repository root with Python 3 and `psutil`:

```powershell
python experiments/edge-runtime/measure.py --ai-dir "$env:APPDATA/com.novel/novel/ai" --library-db "$env:APPDATA/com.novel/novel/library.db" --out .runtime-lab/windows --rounds 3
```

This synthetic probe measures only duplicate summary requests and process
memory. Its output hashes are not a release quality gate. Person graph,
chapter summaries, relationship structure, landmine candidates, and semantic
search must receive separate three-round regression checks before any profile
can move to the app. Android CPU ISA, GPU offload and iOS/NPU require actual
supported devices and are not inferred from Windows results.

For microbatch trials, use a long factual-recall prompt so the physical batch
limit actually applies:

```powershell
python experiments/edge-runtime/measure.py --ai-dir "$env:APPDATA/com.novel/novel/ai" --out .runtime-lab/microbatch --profiles baseline ubatch256 ubatch128 ubatch64 --rounds 3 --prompt-tokens 5500
```

Add `--quality` for eight synthetic relationship/character cases per run.
Acceptance requires no newly wrong cases relative to the baseline, then a
larger test over the app's actual chapter and retrieval workflows. The small
smoke suite cannot prove that a profile preserves all novel-analysis quality.

The independent dual-process probe compares chat-only, chat-plus-embedder,
and embedder-only point-in-time memory. It is intentionally not an automatic
app change; unloading on every task could increase load time and energy:

```powershell
python experiments/edge-runtime/dual_models.py --ai-dir "$env:APPDATA/com.novel/novel/ai" --out .runtime-lab/dual-models
```

The switch experiment runs `chat → embed → chat` either with both engines
resident or with only one resident at a time. It records the reload penalty
and checks output hashes, without changing the app:

```powershell
python experiments/edge-runtime/switch_models.py --ai-dir "$env:APPDATA/com.novel/novel/ai" --out .runtime-lab/switch --rounds 3
```
