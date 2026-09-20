@echo off
title Net stutter detector - validation
cd /d "%~dp0"
echo.
echo Open Deadlock (or Discord) so the stutter is happening, then press a key.
pause >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Detect-NetStutter.ps1" -DurationSec 90 -Label "user-validate" -IntervalMs 200
echo.
echo Done. Share whether red STUTTER lines matched what you felt.
pause
