"""Kokoro 1.1-zh (hexgrad/Kokoro-82M-v1.1-zh) -> one GGUF for the engine in
app/rust/ios_tts/kokoro: weights with weight norm folded in, the phoneme
vocabulary, and the voices.

usage: convert.py <model dir> <out.gguf> [--f16] [voice ...]
  model dir holds config.json, kokoro-v1_1-zh.pth and voices/*.pt
  no voice named = every zf_/zm_ voice found
"""
import json
import os
import sys

import gguf
import numpy as np
import torch

src, out = sys.argv[1], sys.argv[2]
f16 = '--f16' in sys.argv
voices = [a for a in sys.argv[3:] if not a.startswith('--')]

config = json.load(open(os.path.join(src, 'config.json'), encoding='utf-8'))
sd = torch.load(os.path.join(src, 'kokoro-v1_1-zh.pth'), map_location='cpu', weights_only=True)

w = gguf.GGUFWriter(out, 'kokoro')
w.add_name('kokoro-82m-v1.1-zh')
w.add_uint32('kokoro.n_token', config['n_token'])
w.add_uint32('kokoro.hidden_dim', config['hidden_dim'])
w.add_uint32('kokoro.style_dim', config['style_dim'])
w.add_uint32('kokoro.n_layer', config['n_layer'])
w.add_uint32('kokoro.max_dur', config['max_dur'])
pl = config['plbert']
w.add_uint32('kokoro.bert.hidden', pl['hidden_size'])
w.add_uint32('kokoro.bert.heads', pl['num_attention_heads'])
w.add_uint32('kokoro.bert.ff', pl['intermediate_size'])
w.add_uint32('kokoro.bert.layers', pl['num_hidden_layers'])
w.add_uint32('kokoro.bert.ctx', pl['max_position_embeddings'])
symbols = list(config['vocab'].keys())
w.add_array('kokoro.vocab.symbols', symbols)
w.add_array('kokoro.vocab.ids', [int(config['vocab'][s]) for s in symbols])


def short(name):
    name = name.replace('module.', '', 1)
    name = name.replace('encoder.albert_layer_groups.0.albert_layers.0.', 'layer.')
    return name


def folded(state):
    """weight_g/weight_v pairs -> weight = g * v / |v| (norm over all but dim 0)."""
    out = {}
    for k, v in state.items():
        if k.endswith('.weight_v'):
            continue
        if k.endswith('.weight_g'):
            base = k[:-len('.weight_g')]
            vv = state[base + '.weight_v'].double()
            norm = vv.reshape(vv.shape[0], -1).norm(dim=1).reshape(-1, *[1] * (vv.dim() - 1))
            out[base + '.weight'] = (v.double() * vv / norm).float()
        else:
            out[k] = v.float()
    return out


count = 0
for key, state in sd.items():
    for k, t in folded(state).items():
        name = short(f'{key}.{k}')
        if 'pooler' in name or 'position_ids' in name:
            continue
        a = t.numpy()
        if name.endswith('.pool.weight'):
            # Depthwise [C, 1, 3] -> [3][C]: one row per tap.
            a = np.ascontiguousarray(a[:, 0, :].T)
        # Matrices and kernels in half precision; everything small, and the
        # recurrent weights the CPU runs, in full.
        half = f16 and a.ndim >= 2 and a.size >= 4096 and 'lstm' not in name and 'shared' not in name
        a = a.astype(np.float16 if half else np.float32)
        assert len(name) < 64, name
        w.add_tensor(name, a)
        count += 1

vdir = os.path.join(src, 'voices')
if not voices:
    voices = sorted(f[:-3] for f in os.listdir(vdir) if f.endswith('.pt') and f[:2] in ('zf', 'zm'))
for v in voices:
    pack = torch.load(os.path.join(vdir, v + '.pt'), weights_only=True).float().reshape(-1, 256)
    w.add_tensor('voice.' + v, pack.numpy())
w.add_array('kokoro.voices', voices)

w.write_header_to_file()
w.write_kv_data_to_file()
w.write_tensors_to_file()
w.close()
print(f'{count} tensors, {len(voices)} voices -> {out} ({os.path.getsize(out) / 1e6:.1f} MB)')
