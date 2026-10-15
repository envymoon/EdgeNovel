"""Merge a kohya LoRA into an SD1.5 checkpoint. With scheme f16 that is all it
does; that is how the cover model's Hyper-SD 4-step LoRA was baked in.

The other schemes then round-trip chosen weights through ggml's q8_0 / q5_0 /
q4_0, so stock sd.cpp (running f16) shows what a fully quantized model would
look like. That is how quantizing the UNet's convolutions was judged worth
patching sd.cpp for, before the patch existed.

usage: merge_lora.py <base.safetensors> <lora.safetensors|-> <out.safetensors> <scheme>
scheme: f16 | full_q8 | full_q5 | full_q4 | conv_q8_attn_q4
"""
import re
import sys

import numpy as np
from safetensors import safe_open
from safetensors.numpy import save_file


def q8_0(x):
    b = x.reshape(-1, 32)
    amax = np.abs(b).max(1, keepdims=True)
    d = (amax / 127).astype(np.float16).astype(np.float32)
    inv = np.where(amax > 0, 127 / np.where(amax > 0, amax, 1), 0)
    q = np.round(b * inv)
    return (q * d).reshape(x.shape)


def q_signed(x, half):
    # q4_0 (half=8) and q5_0 (half=16): scale from the value of largest magnitude.
    b = x.reshape(-1, 32)
    idx = np.abs(b).argmax(1)
    mx = b[np.arange(len(b)), idx][:, None]
    d = mx / -half
    inv = np.where(d != 0, 1 / np.where(d != 0, d, 1), 0)
    q = np.minimum(2 * half - 1, np.trunc(b * inv + half + 0.5))
    d16 = d.astype(np.float16).astype(np.float32)
    return ((q - half) * d16).reshape(x.shape)


QUANT = {
    "q8": q8_0,
    "q5": lambda x: q_signed(x, 16),
    "q4": lambda x: q_signed(x, 8),
}

RESNET = {
    "in_layers.0": "norm1",
    "in_layers.2": "conv1",
    "emb_layers.1": "time_emb_proj",
    "out_layers.0": "norm2",
    "out_layers.3": "conv2",
    "skip_connection": "conv_shortcut",
}


def resnet(rest):
    for k, v in RESNET.items():
        if rest.startswith(k):
            return v + rest[len(k):]
    raise KeyError(rest)


def diffusers_name(key):
    """LDM unet key (without model.diffusion_model.) -> diffusers module path."""
    m = re.match(r"input_blocks\.(\d+)\.(\d+)\.(.*)", key)
    if m:
        n, s, rest = int(m[1]), int(m[2]), m[3]
        if n == 0:
            return "conv_in." + rest
        if n % 3 == 0:
            return f"down_blocks.{n // 3 - 1}.downsamplers.0.conv." + rest.removeprefix("op.")
        i, j = (n - 1) // 3, (n - 1) % 3
        if s == 0:
            return f"down_blocks.{i}.resnets.{j}." + resnet(rest)
        return f"down_blocks.{i}.attentions.{j}." + rest
    m = re.match(r"middle_block\.(\d)\.(.*)", key)
    if m:
        s, rest = int(m[1]), m[2]
        if s == 1:
            return "mid_block.attentions.0." + rest
        return f"mid_block.resnets.{s // 2}." + resnet(rest)
    m = re.match(r"output_blocks\.(\d+)\.(\d+)\.(.*)", key)
    if m:
        n, s, rest = int(m[1]), int(m[2]), m[3]
        i, j = n // 3, n % 3
        if s == 0:
            return f"up_blocks.{i}.resnets.{j}." + resnet(rest)
        if rest.startswith("conv."):
            return f"up_blocks.{i}.upsamplers.0." + rest
        return f"up_blocks.{i}.attentions.{j}." + rest
    for a, b in [("time_embed.0", "time_embedding.linear_1"), ("time_embed.2", "time_embedding.linear_2"),
                 ("out.0", "conv_norm_out"), ("out.2", "conv_out")]:
        if key.startswith(a + "."):
            return b + key[len(a):]
    raise KeyError(key)


def kohya(key):
    d = diffusers_name(key).removesuffix(".weight")
    return "lora_unet_" + d.replace(".", "_")


def main():
    base, lora_path, out, scheme = sys.argv[1:5]
    f = safe_open(base, "np")
    lora = safe_open(lora_path, "np") if lora_path != "-" else None
    lkeys = set(lora.keys()) if lora else set()
    used = set()
    tensors = {}
    stats = {}
    for key in f.keys():
        w = f.get_tensor(key)
        unet = key.startswith("model.diffusion_model.")
        clip = key.startswith("cond_stage_model.")
        x = w.astype(np.float32)
        if unet and key.endswith(".weight") and w.ndim >= 2 and lora:
            name = kohya(key[len("model.diffusion_model."):])
            if name + ".lora_down.weight" in lkeys:
                down = lora.get_tensor(name + ".lora_down.weight").astype(np.float32)
                up = lora.get_tensor(name + ".lora_up.weight").astype(np.float32)
                r = down.shape[0]
                alpha = float(lora.get_tensor(name + ".alpha")) if name + ".alpha" in lkeys else r
                if down.ndim == 4 and down.shape[2:] != (1, 1):
                    # 3x3 conv lora: up is 1x1
                    delta = up.reshape(up.shape[0], r) @ down.reshape(r, -1)
                else:
                    delta = up.reshape(up.shape[0], -1) @ down.reshape(r, -1)
                x = x + (alpha / r) * delta.reshape(x.shape)
                used.add(name)
        kind = None
        if scheme != "f16" and key.endswith(".weight") and w.ndim >= 2:
            row = int(np.prod(w.shape[1:]))
            if unet and row % 32 == 0:
                if scheme == "conv_q8_attn_q4":
                    kind = "q8" if w.ndim == 4 else "q4"
                else:
                    kind = scheme.split("_")[1]
            elif clip and w.ndim == 2 and row % 32 == 0 and "embedding" not in key:
                kind = "q8" if scheme == "conv_q8_attn_q4" else scheme.split("_")[1]
        if kind:
            x = QUANT[kind](x.reshape(w.shape[0], -1)).reshape(w.shape)
            err = np.abs(x - w.astype(np.float32)).mean() / (np.abs(w.astype(np.float32)).mean() + 1e-12)
            stats.setdefault(kind, []).append(err)
        part = "unet" if unet else "clip" if clip else "vae" if key.startswith("first_stage_model.") else "other"
        nbytes = {"q8": 34 / 32, "q5": 22 / 32, "q4": 18 / 32}.get(kind, 2) * w.size
        stats.setdefault("bytes_" + part, [0])[0] += nbytes
        tensors[key] = x.astype(np.float16)
    if lora:
        missing = {k.rsplit(".", 2)[0] for k in lkeys if k.endswith("lora_down.weight")} - used
        print("lora modules merged", len(used), "unmatched", len(missing), sorted(missing)[:5])
    for k, v in stats.items():
        if k.startswith("bytes_"):
            print(k, f"{v[0] / 2**20:.0f} MB")
        else:
            print(k, "tensors", len(v), "mean rel err", f"{np.mean(v):.4f}")
    save_file(tensors, out)


if __name__ == "__main__":
    main()
