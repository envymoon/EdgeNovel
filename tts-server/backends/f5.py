"""F5-TTS: the good one.

A voice here is a reference recording, not a fixed speaker baked into the model,
which is why this is the backend worth deploying: casting a character is
dropping a few seconds of audio into `voices/` and naming the file. Nothing is
trained and nothing is uploaded.

Layout of `voices/`:

    voices/
      narrator.wav      the reference audio, 5–12 seconds, clean, one speaker
      narrator.txt      exactly what is said in that wav (helps a lot)
      主角.wav
      主角.txt

The `.txt` is optional — without it F5 transcribes the reference itself, which
costs a few seconds at load and is slightly less accurate. With no `voices/` at
all the model's own default reference is used, so the server still works out of
the box.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np

from . import Voice

_AUDIO_EXT = (".wav", ".mp3", ".flac", ".ogg", ".m4a")


class F5Backend:
    name = "f5-tts"

    def __init__(self, voices_dir: str):
        import torch
        from f5_tts.api import F5TTS

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        if self.device == "cpu":
            print("警告：没检测到 CUDA，F5 在 CPU 上合成一句要好几秒，"
                  "听起来会一直在缓冲。这台机器没有显卡的话建议改用 kokoro 后端。",
                  flush=True)
        self._tts = F5TTS(device=self.device)
        self._dir = Path(voices_dir)
        self._refs = self._scan()

    def _scan(self) -> dict[str, tuple[str, str]]:
        """name -> (audio path, transcript). Rescanned on every listing so voices
        can be added while the server runs."""
        out: dict[str, tuple[str, str]] = {}
        if not self._dir.is_dir():
            return out
        for f in sorted(self._dir.iterdir()):
            if f.suffix.lower() not in _AUDIO_EXT:
                continue
            txt = f.with_suffix(".txt")
            transcript = txt.read_text(encoding="utf-8").strip() if txt.exists() else ""
            out[f.stem] = (str(f), transcript)
        return out

    def voices(self) -> list[Voice]:
        self._refs = self._scan()
        if not self._refs:
            return [Voice("default", "默认（未放参考音频）")]
        return [Voice(k, k) for k in self._refs]

    def speak(self, text: str, voice: str | None, speed: float):
        ref_audio, ref_text = "", ""
        if voice and voice != "default":
            if voice not in self._refs:
                self._refs = self._scan()  # maybe it was just added
            if voice not in self._refs:
                raise KeyError(voice)
            ref_audio, ref_text = self._refs[voice]

        wav, sr, _ = self._tts.infer(
            ref_file=ref_audio,
            ref_text=ref_text,
            gen_text=text,
            speed=float(speed),
            remove_silence=False,
            show_info=lambda *_: None,
        )
        return np.asarray(wav, dtype="float32"), int(sr)
