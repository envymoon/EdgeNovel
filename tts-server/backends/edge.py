"""Microsoft Edge's neural voices.

They sound better than anything you can run on a CPU and cost nothing to use,
which is a real option for someone with no GPU. The price is the one thing this
project otherwise never does: the sentence being read is sent to Microsoft. That
is why it is never the default and why the server prints a warning when it is
chosen — the trade is the user's to make knowingly, not one to make for them.

It also means this backend needs the *server* to be online, though the reader
still only ever talks to the address its owner typed.
"""

from __future__ import annotations

import asyncio
import io

import numpy as np

from . import Voice

_VOICES = {
    "zh-CN-YunjianNeural": "云健 · 男声 · 体育解说腔，讲书有劲",
    "zh-CN-YunxiNeural": "云希 · 男声 · 少年感",
    "zh-CN-YunyangNeural": "云扬 · 男声 · 播音腔",
    "zh-CN-YunxiaNeural": "云夏 · 男声 · 偏年轻",
    "zh-CN-XiaoxiaoNeural": "晓晓 · 女声 · 通用",
    "zh-CN-XiaoyiNeural": "晓伊 · 女声 · 偏活泼",
    "zh-CN-liaoning-XiaobeiNeural": "晓北 · 女声 · 东北话",
    "zh-CN-shaanxi-XiaoniNeural": "晓妮 · 女声 · 陕西话",
}


class EdgeBackend:
    name = "edge-tts"
    device = "remote"

    def __init__(self):
        import edge_tts  # noqa: F401  (imported here so the error is at startup)
        import soundfile  # noqa: F401

    def voices(self) -> list[Voice]:
        return [Voice(k, v) for k, v in _VOICES.items()]

    def speak(self, text: str, voice: str | None, speed: float):
        v = voice or "zh-CN-YunjianNeural"
        if v not in _VOICES:
            raise KeyError(v)
        # Edge takes pace as a percentage delta, not a multiplier.
        rate = f"{round((float(speed) - 1.0) * 100):+d}%"
        mp3 = asyncio.run(_fetch(text, v, rate))

        import soundfile as sf

        audio, sr = sf.read(io.BytesIO(mp3), dtype="float32", always_2d=False)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        return np.asarray(audio, dtype="float32"), int(sr)


async def _fetch(text: str, voice: str, rate: str) -> bytes:
    import edge_tts

    out = bytearray()
    async for chunk in edge_tts.Communicate(text, voice, rate=rate).stream():
        if chunk["type"] == "audio":
            out.extend(chunk["data"])
    return bytes(out)
