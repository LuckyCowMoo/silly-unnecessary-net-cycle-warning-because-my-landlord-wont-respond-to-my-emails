# Silly unnecessary net cycle warning because my landlord won’t respond to my emails

A local STUN latency timeline with a 31‑second cycle clock, binary hit/miss strip, and optional pre‑spike beeps — built because the building network stutters on a schedule and emailing the landlord did nothing.

## Quick start (live monitoring)

1. Install [Python 3](https://www.python.org/downloads/)
2. Double‑click `Open-SpikeTimeline.bat`  
   (or: `powershell -File Open-SpikeTimeline.ps1`)
3. Browser opens at `http://127.0.0.1:8765/` — probing runs **in memory** while the tab is open

No disk recorder required. Close the tab to pause probing; close the server window to stop.

## GitHub Pages UI

The static UI is on GitHub Pages. For live STUN data, also run the local probe (`Open-SpikeTimeline.bat`). The page will talk to `http://127.0.0.1:8765` when hosted on `github.io`.

## Controls

| Key | Action |
|-----|--------|
| **L** | Live window (−1.5 min / +45 s) |
| **T** | Scroll with time (keep zoom/pan, slide forward) |
| **S** | Sound warning (3 countdown beeps + hit/miss tones) |
| **R** | Fit all |
| Wheel / drag | Zoom / pan |

## What’s in the box

- `Serve-SpikeTimeline.py` — local HTTP + UDP STUN probe
- `timeline-web/` — canvas UI (clock, chart, binary slots, sound)
- `Open-SpikeTimeline.ps1` / `.bat` — launcher
