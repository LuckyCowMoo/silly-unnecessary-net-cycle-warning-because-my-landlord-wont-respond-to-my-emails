# Open the spike timeline website. While the page is open, the server probes STUN
# in-memory (no disk recorder). Close the tab to pause; stop this server to quit.
param(
  [string]$RunDir = "",
  [int]$Port = 8765
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { throw "Python not found on PATH. Install Python 3, then retry." }

# free port if a previous viewer is still bound
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

$args = @("-u", (Join-Path $here "Serve-SpikeTimeline.py"), "--port", "$Port")
if ($RunDir) { $args += @("--run-dir", $RunDir) }

Write-Host "Opening spike timeline..." -ForegroundColor Cyan
if ($RunDir) {
  Write-Host "  History replay: $RunDir"
} else {
  Write-Host "  Live mode: records in memory while the browser tab is open."
}
Write-Host "  http://127.0.0.1:$Port/"
Write-Host "Close this window to stop the local server."

Start-Process -FilePath $py.Source -ArgumentList $args -WorkingDirectory $here
