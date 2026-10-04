# Open the live spike timeline website (in-memory STUN while the tab is open).
# Kept as a convenience launcher; no separate disk recorder is started.
param(
  [int]$Port = 8765
)

& (Join-Path $PSScriptRoot "Open-SpikeTimeline.ps1") -Port $Port
