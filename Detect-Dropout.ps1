<#
.SYNOPSIS
  Detect ~0.5s complete network dropouts and measure interval between them.
#>
[CmdletBinding()]
param(
  [string]$Target = "",
  [int]$IntervalMs = 50,
  [int]$TimeoutMs = 400,
  [int]$DropoutMs = 300,
  [int]$DurationSec = 180,
  [string]$Label = "dropout",
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
if (-not $Target) {
  $Target = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).NextHop
}
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "logs" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csv = Join-Path $OutDir ("dropout-{0}-{1}.csv" -f $Label, $stamp)
$summary = Join-Path $OutDir ("dropout-summary-{0}-{1}.txt" -f $Label, $stamp)

"timestamp,ok,rtt_ms,status,in_dropout" | Set-Content $csv -Encoding UTF8

Write-Host "=== Dropout detector ===" -ForegroundColor Cyan
Write-Host "Target gateway/next-hop: $Target"
Write-Host "Probe every ${IntervalMs}ms, timeout ${TimeoutMs}ms, dropout if gap/fail >= ${DropoutMs}ms"
Write-Host "Duration: ${DurationSec}s  Label: $Label"
Write-Host ""

$ping = [System.Net.NetworkInformation.Ping]::new()
$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$dropouts = New-Object System.Collections.Generic.List[object]
$inDrop = $false
$dropStart = $null
$lastOk = Get-Date
$total = 0
$lost = 0

try {
  while ((Get-Date) -lt $end) {
    $total++
    $now = Get-Date
    try {
      $reply = $ping.Send($Target, $TimeoutMs)
      $ok = $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
      $ms = if ($ok) { [double]$reply.RoundtripTime } else { $null }
      $status = [string]$reply.Status
    } catch {
      $ok = $false; $ms = $null; $status = $_.Exception.Message
    }
    if (-not $ok) { $lost++ }

    $gapMs = ($now - $lastOk).TotalMilliseconds
    $dropNow = (-not $ok) -or ($ok -and $gapMs -ge $DropoutMs -and $inDrop)

    if (-not $ok) {
      if (-not $inDrop) {
        $inDrop = $true
        $dropStart = $now
        Write-Host ("[{0}] DROPOUT START (fail={1})" -f $now.ToString("HH:mm:ss.fff"), $status) -ForegroundColor Red
        try { [console]::Beep(660, 60) } catch {}
      }
    } else {
      if ($inDrop) {
        $dur = ($now - $dropStart).TotalMilliseconds
        $sincePrev = if ($dropouts.Count) { ($dropStart - $dropouts[-1].Start).TotalSeconds } else { $null }
        $dropouts.Add([pscustomobject]@{ Start = $dropStart; End = $now; DurMs = [math]::Round($dur,0); GapSec = if ($null -ne $sincePrev) { [math]::Round($sincePrev,1) } else { $null } })
        Write-Host ("[{0}] DROPOUT END  duration={1:N0}ms  interval_from_prev={2}" -f $now.ToString("HH:mm:ss.fff"), $dur, $(if ($null -ne $sincePrev) { "{0:N1}s" -f $sincePrev } else { "n/a" })) -ForegroundColor Yellow
        $inDrop = $false
      }
      $lastOk = $now
    }

    Add-Content $csv ("{0},{1},{2},{3},{4}" -f $now.ToString("o"), [int]$ok, $ms, $status, [int]$inDrop)
    if (($total % 40) -eq 0 -and -not $inDrop) {
      Write-Host ("[{0}] ok rtt={1}ms  lost={2}/{3}  dropouts={4}" -f $now.ToString("HH:mm:ss"), $ms, $lost, $total, $dropouts.Count) -ForegroundColor Green
    }
    Start-Sleep -Milliseconds $IntervalMs
  }
} finally {
  $ping.Dispose()
  $gaps = @($dropouts | Where-Object { $null -ne $_.GapSec } | ForEach-Object { $_.GapSec })
  $avgGap = if ($gaps.Count) { [math]::Round(($gaps | Measure-Object -Average).Average, 1) } else { $null }
  $text = @"
Dropout summary
Label:     $Label
Target:    $Target
Elapsed:   $DurationSec s
Probes:    $total
Lost:      $lost ($([math]::Round(100.0*$lost/[math]::Max(1,$total),2))%)
Dropouts:  $($dropouts.Count)
Avg interval between dropouts: $avgGap s
CSV: $csv

Events:
$(($dropouts | ForEach-Object { "  {0}  dur={1}ms  gap={2}s" -f $_.Start.ToString("HH:mm:ss.fff"), $_.DurMs, $_.GapSec }) -join "`n")
"@
  Set-Content $summary $text -Encoding UTF8
  Write-Host ""
  Write-Host $text
}
