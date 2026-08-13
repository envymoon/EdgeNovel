"""A text-to-speech server for the novel reader, speaking OpenAI's audio API.

Why this exists: the phone (or thin laptop) doing the reading cannot run a voice
worth listening to for six hours, but a desktop sitting idle in the next room
can. This puts the synthesis there and nothing else — the reader sends one
sentence, gets back a WAV, and keeps nothing.

Why OpenAI's shape (`POST /v1/audio/speech`): it is what every self-hosted TTS
project already speaks. That means this server is the convenient option and not
the required one — point the app at kokoro-fastapi, GPT-SoVITS, Fish-Speech or
anything else with the same endpoint and it works — and a better model next year
is a backend file here, not an app release.

Run it with start.ps1 / start.sh, which set the environment up first.
"""

from __future__ import annotations

import argparse
import io
import os
import socket
import wave

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from backends import Backend, load_backend

app = FastAPI(title="novel-tts")

_backend: Backend | None = None


def backend() -> Backend:
    if _backend is None:  # pragma: no cover - startup order guarantees this
        raise HTTPException(503, "语音后端尚未就绪")
    return _backend


class SpeechRequest(BaseModel):
    """OpenAI's request body. `model` is advisory here — the backend was chosen
    at startup — and everything but `input` is optional, because clients differ
    in how much of the spec they bother to send."""

    input: str
    model: str = ""
    voice: str = ""
    speed: float = 1.0
    response_format: str = "wav"


@app.get("/health")
def health() -> dict:
    b = backend()
    return {"status": "ok", "backend": b.name, "device": b.device}


@app.get("/v1/models")
def models() -> dict:
    b = backend()
    return {"object": "list", "data": [{"id": b.name, "object": "model"}]}


@app.get("/v1/audio/voices")
def voices() -> dict:
    """Not part of OpenAI's spec, but kokoro-fastapi established it and the
    reader uses it to offer a picker instead of a text box. Labels are separate
    from ids so a cloned voice can be called 主角 in the app while staying a
    filename here."""
    return {"voices": [{"id": v.id, "label": v.label} for v in backend().voices()]}


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest) -> Response:
    text = req.input.strip()
    if not text:
        raise HTTPException(400, "input 为空")
    if req.response_format not in ("wav", "pcm", ""):
        # Refusing beats silently returning a WAV labelled as mp3: a client that
        # asked for mp3 will try to decode it as one.
        raise HTTPException(400, f"暂不支持 {req.response_format}，请用 wav")

    b = backend()
    try:
        audio, rate = b.speak(text, voice=req.voice or None, speed=req.speed)
    except KeyError as e:
        raise HTTPException(400, f"没有这个音色：{e}") from e
    except Exception as e:  # backend failures are the common case worth naming
        raise HTTPException(500, f"合成失败：{type(e).__name__}: {e}") from e

    if req.response_format == "pcm":
        return Response(audio.tobytes(), media_type="audio/pcm")
    return Response(to_wav(audio, rate), media_type="audio/wav")


def to_wav(audio, rate: int) -> bytes:
    """Float samples in [-1, 1] to 16-bit mono WAV bytes."""
    import numpy as np

    clipped = np.clip(np.asarray(audio, dtype="float32"), -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def lan_address() -> str:
    """The address to type into the phone. `gethostbyname(gethostname())` lies on
    machines with several adapters, so ask the routing table which interface
    would be used to leave this host — no packet is actually sent."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main() -> None:
    p = argparse.ArgumentParser(description="小说朗读服务端")
    p.add_argument("--host", default="0.0.0.0",
                   help="默认监听全部网卡，手机才连得上")
    p.add_argument("--port", type=int, default=8880)
    p.add_argument("--backend", default=os.environ.get("TTS_BACKEND", "f5"),
                   help="f5 | kokoro | edge")
    p.add_argument("--voices-dir", default="voices",
                   help="音色参考音频目录（f5 后端用）")
    args = p.parse_args()

    global _backend
    print(f"正在加载后端 {args.backend} …（首次启动要下模型，可能要几分钟）", flush=True)
    _backend = load_backend(args.backend, voices_dir=args.voices_dir)

    vs = _backend.voices()
    print()
    print("=" * 58)
    print(f"  后端      {_backend.name}  ({_backend.device})")
    print(f"  音色      {len(vs)} 个" + (f"：{', '.join(v.id for v in vs[:6])}"
                                        + (" …" if len(vs) > 6 else "") if vs else ""))
    print()
    print("  在 App 的「听书服务」里填这个地址：")
    print(f"      http://{lan_address()}:{args.port}")
    print("=" * 58)
    print(flush=True)

    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
