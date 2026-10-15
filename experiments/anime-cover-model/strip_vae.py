"""Copy an SD checkpoint without its VAE (first_stage_model.*), for use with TAESD.

usage: strip_vae.py <in.safetensors> <out.safetensors>
"""
import sys

from safetensors import safe_open
from safetensors.numpy import save_file

src, dst = sys.argv[1:3]
f = safe_open(src, "np")
kept = {k: f.get_tensor(k) for k in f.keys() if not k.startswith("first_stage_model.")}
print("kept", len(kept), "of", len(list(f.keys())))
save_file(kept, dst)
