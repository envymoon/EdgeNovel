"""Engine intermediates (kokoro-cli --debug) against the original's (ref.py).
usage: compare.py <ref dir> <engine out dir>"""
import json
import os
import sys

import numpy as np

ref_dir, out_dir = sys.argv[1:3]
n = len(json.load(open(os.path.join(ref_dir, 'index.json'), encoding='utf-8')))


def snr(a, b):
    a = a.astype(np.float64).ravel()
    b = b.astype(np.float64).ravel()
    if a.shape != b.shape:
        return f'shape {a.shape} vs {b.shape}'
    err = np.sum((a - b) ** 2)
    return f'{10 * np.log10(np.sum(a ** 2) / max(err, 1e-30)):6.1f} dB  max|d| {np.max(np.abs(a - b)):.2e}'


for i in range(n):
    r = np.load(os.path.join(ref_dir, f'{i}.npz'))
    d = os.path.join(out_dir, str(i))

    def mine(name):
        return np.fromfile(os.path.join(d, name + '.f32'), np.float32)

    T = len(r['ids'])
    print(f'--- {i}: {T} tokens, {len(r["audio"]) / 24000:.2f} s')
    print('  bert      ', snr(r['bert'], mine('bert')))
    print('  dur_enc   ', snr(r['dur_enc'], mine('dur_enc')))
    dur = mine('dur').astype(np.int32)
    print('  dur        same' if np.array_equal(dur, r['dur']) else f'  dur        DIFFER at {np.nonzero(dur != r["dur"])[0][:10]}')
    print('  t_en      ', snr(r['t_en'][0], mine('t_en').reshape(T, -1).T))
    print('  F0        ', snr(r['F0'], mine('F0')))
    print('  N         ', snr(r['N'], mine('N')))
    print('  har_source', snr(r['har_source'], mine('har_source')))
    print('  post      ', snr(r['post'], mine('post')))
    print('  audio     ', snr(r['audio'], mine('audio')))
