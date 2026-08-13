"""Kokoro 82M — the small, fast, CPU-viable tier.

It is the same family the app bundles locally, so it is not why you would stand
a server up. It is here because a machine without a GPU should still be able to
serve *something*, and because it loads in seconds when you are testing that the
link works at all.
"""

from __future__ import annotations

import numpy as np

from . import Voice

# The Chinese speakers, named the way the app's own list names them so a user
# switching between local and remote hears roughly what they expect.
_LABELS = {
    "zm_yunjian": "云健 · 男声旁白",
    "zm_yunxi": "云希 · 男声",
    "zm_yunyang": "云扬 · 男声",
    "zm_yunxia": "云夏 · 男声",
    "zf_xiaoxiao": "晓晓 · 女声",
    "zf_xiaobei": "晓贝 · 女声",
    "zf_xiaoni": "晓妮 · 女声",
    "zf_xiaoyi": "晓伊 · 女声",
}


class KokoroBackend:
    name = "kokoro"

    def __init__(self):
        import torch
        from kokoro import KPipeline

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        # 'z' is the Mandarin pipeline; it pulls its own G2P on first use.
        self._pipe = KPipeline(lang_code="z", device=self.device)

    def voices(self) -> list[Voice]:
        return [Voice(k, v) for k, v in _LABELS.items()]

    def speak(self, text: str, voice: str | None, speed: float):
        v = voice or "zm_yunjian"
        if v not in _LABELS:
            raise KeyError(v)
        chunks = [
            np.asarray(r.audio, dtype="float32")
            for r in self._pipe(text, voice=v, speed=float(speed))
        ]
        if not chunks:
            return np.zeros(0, dtype="float32"), 24000
        return np.concatenate(chunks), 24000
