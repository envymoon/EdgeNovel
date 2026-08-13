@rem Double-clickable entry point. Windows opens .ps1 files in an editor rather
@rem than running them, so this is the file to double-click; it just hands off.
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
pause
