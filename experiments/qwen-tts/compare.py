"""The 听书 speed experiments side by side (app/rust/src/api/tts.rs, mod
experiment): every setting's WAVs against the plain setting's first round.

With the same seed a setting that only changes how the codec is scheduled
(chunk16, chunk32, thread) is handed the same codes, so its sound must match
the plain one to the rounding: the SNR is the check. The codec on the CPU
(cpu2, cpu4) gets the same codes too, and differs from the GPU's codec only
by its arithmetic. A setting that batches
sentences (b2, b4, b6: two, four and six at once) runs the talker on several at once
and may sample codes of its own, so it is checked by what a speech recogniser
hears (CER against the text) and by the spectrum: a muffled voice shows as the
top end going quiet. The talker in 4 bits (q4, q4b4, q4b6) samples codes of its
own too, and is checked the same way.

    python compare.py <experiment dir> [paraformer dir]

The recogniser (sherpa-onnx with a Chinese paraformer) is optional.
"""

import glob
import os
import re
import sys
import wave

import numpy as np

PUNCT = re.compile(r"[\s，。、：；！？“”‘’（）《》,.:;!?\"'()\-—…]")


def load(path):
    with wave.open(path) as w:
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        return pcm.astype(np.float32) / 32768.0, w.getframerate()


def snr(ref, x):
    if len(ref) != len(x):
        return None
    noise = float(np.sum((ref.astype(np.float64) - x) ** 2))
    if noise == 0:
        return float("inf")
    return 10 * np.log10(float(np.sum(ref.astype(np.float64) ** 2)) / noise)


def bands(x, rate):
    """Long-term spectrum in 24 log-spaced bands, 100 Hz to 11 kHz, in dB."""
    n, hop = 1024, 256
    if len(x) < n:
        x = np.pad(x, (0, n - len(x)))
    frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * np.hanning(n)
    power = (np.abs(np.fft.rfft(frames, axis=1)) ** 2).mean(axis=0)
    freqs = np.fft.rfftfreq(n, 1 / rate)
    edges = np.geomspace(100, 11000, 25)
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        sel = (freqs >= lo) & (freqs < hi)
        out.append(10 * np.log10(power[sel].mean() + 1e-12))
    high = power[freqs >= 4000].sum() / max(power.sum(), 1e-12)
    return np.array(out), float(high)


def cer(ref, hyp):
    ref, hyp = PUNCT.sub("", ref), PUNCT.sub("", hyp)
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[len(hyp)] / max(len(ref), 1)


def recogniser(model_dir):
    import sherpa_onnx

    models = sorted(glob.glob(os.path.join(model_dir, "**", "model*.onnx"), recursive=True))
    models.sort(key=lambda p: "int8" not in p)
    tokens = glob.glob(os.path.join(model_dir, "**", "tokens.txt"), recursive=True)
    if not models or not tokens:
        raise SystemExit(f"no paraformer in {model_dir}")
    rec = sherpa_onnx.OfflineRecognizer.from_paraformer(
        paraformer=models[0], tokens=tokens[0], num_threads=2, sample_rate=16000,
        feature_dim=80, decoding_method="greedy_search")

    def hear(x, rate):
        s = rec.create_stream()
        s.accept_waveform(rate, x)
        rec.decode_stream(s)
        return s.result.text

    return hear


def main():
    out = sys.argv[1]
    hear = recogniser(sys.argv[2]) if len(sys.argv) > 2 else None
    lines = open(os.path.join(out, "lines.txt"), encoding="utf-8").read().split("\n")
    lines = [l for l in lines if l]
    clips = {}
    for path in glob.glob(os.path.join(out, "*-r*-*.wav")):
        m = re.match(r"(.+)-r(\d+)-(\d+)\.wav$", os.path.basename(path))
        if m:
            clips[(m[1], int(m[2]), int(m[3]))] = path
    order = ["base", "basefast", "b2", "b4", "b4fast", "b6", "q4", "q4b4", "q4b6", "chunk16", "chunk32", "thread", "batch2", "cpu2", "cpu4"]
    settings = sorted({k[0] for k in clips}, key=lambda s: (order.index(s) if s in order else len(order), s))

    speed = {}
    results = os.path.join(out, "results.txt")
    if os.path.exists(results):
        for row in open(results, encoding="utf-8"):
            m = re.match(r"\[(\S+) r(\d+)\] 载入 ([\d.]+) 秒 .* RTF ([\d.]+) · 内存最高 (\d+) MB", row)
            if m:
                speed.setdefault(m[1], []).append((float(m[3]), float(m[4]), int(m[5])))

    ref = {}
    for i in range(1, len(lines) + 1):
        if ("base", 1, i) in clips:
            x, rate = load(clips[("base", 1, i)])
            ref[i] = (x, rate, *bands(x, rate))

    print("设置       RTF   载入  内存MB  同长  SNR中位  SNR最低  频谱差dB  高频占比  削波  CER")
    flagged = []
    for name in settings:
        snrs, same, total, diffs, highs, clipped, cers = [], 0, 0, [], [], 0, []
        for (n, r, i), path in sorted(clips.items()):
            if n != name or i not in ref:
                continue
            x, rate = load(path)
            rx, _, rbands, _ = ref[i]
            total += 1
            s = snr(rx, x)
            if s is not None:
                same += 1
                snrs.append(s)
            b, high = bands(x, rate)
            diff = float(np.abs(b - rbands).mean())
            diffs.append(diff)
            highs.append(high)
            clip = float(np.mean(np.abs(x) > 0.999))
            clipped += clip > 0.001
            c = None
            if hear:
                text = hear(x, rate)
                c = cer(lines[i - 1], text)
                cers.append(c)
            if (name != "base" or r != 1) and ((s is not None and s < 30) or diff > 3 or (c is not None and c > 0.15)):
                flagged.append(f"  {name} r{r} 第{i}句: SNR {'-' if s is None else f'{s:.1f}'} · 频谱差 {diff:.2f}"
                               + ("" if c is None else f" · CER {c:.2f} 「{text}」"))
        sp = speed.get(name, [])
        rtf = f"{np.mean([s[1] for s in sp]):.2f}" if sp else "-"
        load_s = f"{np.mean([s[0] for s in sp]):.1f}" if sp else "-"
        mem = f"{max(s[2] for s in sp)}" if sp else "-"
        fin = [s for s in snrs if np.isfinite(s)]
        # inf: the same samples exactly.
        med = f"{np.median(fin):.1f}" if fin else ("相同" if snrs else "-")
        low = f"{min(fin):.1f}" if fin else ("相同" if snrs else "-")
        print(f"{name:9s} {rtf:>5s} {load_s:>5s} {mem:>6s}  {same:>2d}/{total:<2d} {med:>7s} {low:>7s} "
              f"{np.mean(diffs):9.2f} {np.mean(highs):9.3f} {clipped:4d}  "
              + (f"{np.mean(cers):.3f}" if cers else "-"))
    if flagged:
        print("\n需要听一下的：")
        print("\n".join(flagged))
    else:
        print("\n没有异常的句子。")


if __name__ == "__main__":
    main()
