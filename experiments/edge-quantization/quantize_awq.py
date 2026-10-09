from __future__ import annotations

import argparse
from pathlib import Path


SEPARATOR = "<|novel_calibration_sample|>"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--calibration", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=96)
    parser.add_argument("--sequence-length", type=int, default=1024)
    args = parser.parse_args()

    import torch
    from awq import AutoAWQForCausalLM
    from transformers import AutoTokenizer

    calibration = [
        row.strip()
        for row in args.calibration.read_text(encoding="utf-8").split(SEPARATOR)
        if row.strip()
    ][: args.samples]
    if not calibration:
        raise SystemExit("Calibration corpus is empty")

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=False)
    model = AutoAWQForCausalLM.from_pretrained(
        args.model,
        torch_dtype=torch.float16,
        trust_remote_code=False,
        device_map="auto",
        low_cpu_mem_usage=True,
        use_cache=False,
    )
    quant_config = {
        "zero_point": True,
        "q_group_size": 128,
        "w_bit": 4,
        "version": "GEMM",
    }
    # export_compatible applies AWQ's activation-aware scales but intentionally
    # leaves the tensors unpacked. llama.cpp can then convert this checkpoint to
    # F16 GGUF and perform its native Q4_K_M packing for the production runtime.
    model.quantize(
        tokenizer,
        quant_config=quant_config,
        calib_data=calibration,
        max_calib_samples=len(calibration),
        max_calib_seq_len=args.sequence_length,
        n_parallel_calib_samples=4,
        max_chunk_memory=512 * 1024 * 1024,
        export_compatible=True,
    )
    args.out.mkdir(parents=True, exist_ok=True)
    model.save_quantized(str(args.out))
    tokenizer.save_pretrained(args.out)
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
