#!/usr/bin/env bash
# One command from a clean machine to a working listening server.
#
# Everything lands in .venv beside this file — nothing is installed system-wide
# and deleting this folder removes all of it. Re-running is cheap, so this is the
# normal way to start the server, not just the first-time setup.
#
#   ./start.sh                  # F5-TTS, the good voices
#   ./start.sh kokoro           # small and CPU-friendly
#   ./start.sh edge             # best quality with no GPU, but goes via Microsoft
#   PORT=9000 ./start.sh
set -euo pipefail
cd "$(dirname "$0")"

BACKEND="${1:-f5}"
PORT="${PORT:-8880}"

command -v python3 >/dev/null || { echo "找不到 python3，请先安装 Python 3.10+"; exit 1; }

[ -d .venv ] || { echo "首次运行：正在建立 Python 环境…"; python3 -m venv .venv; }

./.venv/bin/pip install -q --upgrade pip
./.venv/bin/pip install -q -r requirements.txt
./.venv/bin/pip install -q -r "requirements-$BACKEND.txt"

exec ./.venv/bin/python server.py --backend "$BACKEND" --port "$PORT"
