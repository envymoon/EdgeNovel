"""Voice backends.

Each one is a thin adapter over somebody else's model: load it, list what it can
sound like, turn a sentence into samples. Keeping the interface this small is
what lets a better model arrive as one new file, with no change to the server,
the protocol, or the app.

Shipped:
  f5      F5-TTS. Zero-shot cloning — a voice is a few seconds of reference
          audio you drop in `voices/`, which is also how per-character casting
          works. Best Chinese of the three; wants a GPU.
  kokoro  Kokoro 82M. Small and fast enough on CPU. The fallback quality tier.
  edge    Microsoft Edge's neural voices. Excellent and free, but it is a
          network call to Microsoft — the sentence leaves the machine. Never the
          default, and the server says so out loud when you pick it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import numpy as np


@dataclass(frozen=True)
class Voice:
    id: str
    label: str


class Backend(Protocol):
    name: str
    device: str

    def voices(self) -> list[Voice]:
        ...

    def speak(self, text: str, voice: str | None, speed: float) -> tuple[np.ndarray, int]:
        """Returns (float32 samples in [-1, 1], sample rate)."""
        ...


def load_backend(name: str, *, voices_dir: str) -> Backend:
    name = name.lower().strip()
    if name == "f5":
        from .f5 import F5Backend

        return F5Backend(voices_dir)
    if name == "kokoro":
        from .kokoro import KokoroBackend

        return KokoroBackend()
    if name == "edge":
        from .edge import EdgeBackend

        print("注意：edge 后端会把待朗读的文字发送到微软的服务器。"
              "介意的话请改用 f5 或 kokoro。", flush=True)
        return EdgeBackend()
    raise SystemExit(f"未知后端 {name}，可选：f5 / kokoro / edge")
