# One command from a clean machine to a working listening server.
#
# Everything lands in .venv beside this file — nothing is installed system-wide
# and deleting this folder removes all of it. Re-running is cheap: pip skips
# what is already there, so this is the normal way to start the server, not just
# the first-time setup.
#
#   .\start.ps1                 # F5-TTS, the good voices
#   .\start.ps1 -Backend kokoro # small and CPU-friendly
#   .\start.ps1 -Backend edge   # best quality with no GPU, but goes via Microsoft
#   .\start.ps1 -Port 9000

param(
    [string]$Backend = "f5",
    [int]$Port = 8880
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Host "找不到 python。请先装 Python 3.10+：https://www.python.org/downloads/" -ForegroundColor Red
    Read-Host "回车退出"
    exit 1
}

if (-not (Test-Path ".venv")) {
    Write-Host "首次运行：正在建立 Python 环境…" -ForegroundColor Cyan
    python -m venv .venv
}

$pip = ".\.venv\Scripts\pip.exe"
$python = ".\.venv\Scripts\python.exe"

& $pip install -q --upgrade pip
& $pip install -q -r requirements.txt
& $pip install -q -r "requirements-$Backend.txt"

& $python server.py --backend $Backend --port $Port
