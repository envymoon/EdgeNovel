"""Reference run of the original Kokoro 1.1-zh: phonemes, every intermediate,
and the audio, with the source noise turned off so a port can be compared
number for number.  usage: ref.py <out dir> <voice> <text file> [--noise]"""
import json
import os
import sys

import numpy as np
import soundfile as sf
import torch

import kokoro.istftnet as ist
from kokoro.model import KModel
from misaki import zh

out, voice, textfile = sys.argv[1:4]
MODEL = os.environ.get('KOKORO_DIR', 'C:/kok/m')
noise = '--noise' in sys.argv
os.makedirs(out, exist_ok=True)
torch.set_num_threads(8)

if not noise:
    ist.torch.randn_like = lambda x, **k: torch.zeros_like(x)
    ist.torch.rand = lambda *a, **k: torch.zeros(*a, device=k.get('device'))

model = KModel(repo_id='hexgrad/Kokoro-82M-v1.1-zh', config=MODEL + '/config.json',
               model=MODEL + '/kokoro-v1_1-zh.pth').eval()
g2p = zh.ZHG2P(version='1.1')
pack = torch.load(f'{MODEL}/voices/{voice}.pt', weights_only=True)

caught = {}


def hook(name):
    def f(mod, inp, outp):
        caught[name] = (outp[0] if isinstance(outp, tuple) else outp).detach().numpy().copy()
    return f


model.bert.register_forward_hook(hook('bert'))
model.predictor.text_encoder.register_forward_hook(hook('dur_enc'))
model.text_encoder.register_forward_hook(hook('t_en'))
model.decoder.generator.conv_post.register_forward_hook(hook('post'))
model.decoder.encode.register_forward_hook(hook('dec_encode'))


def gen_in(mod, args):
    caught['gen_x'] = args[0].detach().numpy().copy()
    caught['gen_f0'] = args[2].detach().numpy().copy()


model.decoder.generator.register_forward_pre_hook(gen_in)
gen = model.decoder.generator
for i in range(2):
    gen.noise_convs[i].register_forward_hook(hook(f'noise_conv{i}'))
    gen.noise_res[i].register_forward_hook(hook(f'noise_res{i}'))
    gen.ups[i].register_forward_hook(hook(f'ups{i}'))
orig_tf = gen.stft.transform


def tf(x):
    a, b = orig_tf(x)
    caught['har'] = torch.cat([a, b], dim=1).detach().numpy().copy()
    return a, b


gen.stft.transform = tf

orig_f0n = model.predictor.F0Ntrain


def f0n(x, s):
    caught['en'] = x.detach().numpy().copy()
    F0, N = orig_f0n(x, s)
    caught['F0'] = F0.detach().numpy().copy()
    caught['N'] = N.detach().numpy().copy()
    return F0, N


model.predictor.F0Ntrain = f0n
orig_src = model.decoder.generator.m_source.forward


def src(x):
    a, b, c = orig_src(x)
    caught['har_source'] = a.detach().numpy().copy()
    return a, b, c


model.decoder.generator.m_source.forward = src

lines = [l.strip() for l in open(textfile, encoding='utf-8') if l.strip()]
index = []
for i, line in enumerate(lines):
    ps, _ = g2p(line)
    ids = [model.vocab[p] for p in ps if p in model.vocab]
    ref_s = pack[len(ps) - 1]
    caught.clear()
    o = model(ps, ref_s, 1.0, return_output=True)
    audio = o.audio.numpy()
    sf.write(f'{out}/{i}.wav', audio, 24000)
    np.savez(f'{out}/{i}.npz', ids=np.array([0, *ids, 0], np.int32), ref_s=ref_s.numpy(),
             dur=o.pred_dur.numpy().astype(np.int32), audio=audio, **caught)
    index.append({'text': line, 'ps': ps, 'n': len(ids), 'seconds': len(audio) / 24000})
    print(i, len(ps), round(len(audio) / 24000, 2), ps)
json.dump(index, open(f'{out}/index.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
