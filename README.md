# Silly unnecessary net cycle warning because my landlord won’t respond to my emails

A local STUN latency timeline with a 31‑second cycle clock, binary hit/miss strip, and optional pre‑spike beeps — built because the building network stutters on a schedule and emailing the landlord did nothing.

## Quick start (native app — recommended)

1. Build once: `powershell -File Build-Native.ps1` (needs .NET 8 SDK; installs to `%LOCALAPPDATA%\dotnet` is fine)
2. Run `dist\NetStutter.exe` — probing starts immediately at **60 Hz** (same STUN servers / thresholds as the Python probe)
3. Optional: shortcut that exe into your Startup folder so it launches at login

Detection matches `Serve-SpikeTimeline.py` (3 UDP STUN flows, max-RTT per tick, 75 ms minors / 200 ms majors, 31 s cycle).

## Quick start (browser / Python)

1. Install [Python 3](https://www.python.org/downloads/)
2. Double‑click `Open-SpikeTimeline.bat`  
   (or: `powershell -File Open-SpikeTimeline.ps1`)
3. Browser opens at `http://127.0.0.1:8765/` — probing runs **in memory** while the tab is open

No disk recorder required. Close the tab to pause probing; close the server window to stop.

## GitHub Pages UI

The static UI is on GitHub Pages. Browsers block public HTTPS sites from talking to localhost unless the local probe allows it — run an up-to-date `Open-SpikeTimeline.bat` (CORS + private-network headers), leave it open, then reload the Pages tab.

**Most reliable:** use `http://127.0.0.1:8765/` from the bat file (same machine, no cross-origin).

## Controls

| Key | Action |
|-----|--------|
| **L** | Live window (−1.5 min / +45 s) |
| **T** | Scroll with time (keep zoom/pan, slide forward) |
| **S** | Sound warning (3 countdown beeps + hit/miss tones) |
| **R** | Fit all |
| Wheel / drag | Zoom / pan |

## What’s in the box

- `native/NetStutter/` — WinForms app + STUN probe (build → `dist/NetStutter.exe`)
- `Build-Native.ps1` — publish single-file exe
- `Serve-SpikeTimeline.py` — local HTTP + UDP STUN probe (browser path)
- `timeline-web/` — canvas UI (clock, chart, binary slots, sound)
- `Open-SpikeTimeline.ps1` / `.bat` — browser launcher
