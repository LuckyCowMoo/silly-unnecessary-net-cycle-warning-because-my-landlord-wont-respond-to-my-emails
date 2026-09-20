<#
.SYNOPSIS
  Correlates UDP ephemeral-port bursts with actual packet loss.

.DESCRIPTION
  Windows logs Tcpip event 4266 when the global UDP ephemeral port space is
  exhausted. Exhaustion breaks send AND receive for every application at once,
  which matches a "whole PC stutters everywhere" symptom.

  This samples the UDP socket count quickly (cheap .NET call), snapshots which
  process is responsible whenever the count spikes, and simultaneously probes
  real UDP so a burst can be lined up against measured loss.
#>
[CmdletBinding()]
param(
  [int]$DurationSec = 240,
  [int]$SampleMs = 150,
  [int]$BurstDelta = 25,
  [string]$ProbeTarget = "8.8.8.8",
  [int]$ProbeEveryMs = 500,
  [int]$ProbeTimeoutMs = 800,
  [string]$Label = "udpburst"
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csv = Join-Path $logDir ("udpburst-{0}-{1}.csv" -f $Label, $stamp)
$sum = Join-Path $logDir ("udpburst-summary-{0}-{1}.txt" -f $Label, $stamp)
try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

function Get-UdpCount {
  try { return ([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners()).Count }
  catch { return -1 }
}
function Get-UdpByProcess {
  $r = @{}
  try {
    Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Group-Object OwningProcess | ForEach-Object {
      $p = Get-Process -Id $_.Name -ErrorAction SilentlyContinue
      $n = if ($p) { $p.ProcessName } else { "pid$($_.Name)" }
      $r[$n] = $_.Count
    }
  } catch {}
  return $r
}
function Test-UdpDns([string]$Server, [int]$Timeout) {
  $rnd = [byte[]]@((Get-Random -Max 256), (Get-Random -Max 256))
  $b = New-Object System.Collections.Generic.List[byte]
  $b.AddRange($rnd); $b.AddRange([byte[]]@(0x01, 0x00)); $b.AddRange([byte[]]@(0x00, 0x01))
  $b.AddRange([byte[]]@(0, 0, 0, 0, 0, 0))
  foreach ($l in (("t" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".example.com").Split('.'))) {
    $b.Add([byte]$l.Length); $b.AddRange([System.Text.Encoding]::ASCII.GetBytes($l))
  }
  $b.Add(0); $b.AddRange([byte[]]@(0, 1)); $b.AddRange([byte[]]@(0, 1))
  $pkt = $b.ToArray()
  $c = [System.Net.Sockets.UdpClient]::new()
  try {
    $c.Client.ReceiveTimeout = $Timeout
    $c.Connect($Server, 53)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$c.Send($pkt, $pkt.Length)
    $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    $resp = $c.Receive([ref]$ep)
    $sw.Stop()
    return [pscustomobject]@{ Ok = $true; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Err = '' }
  } catch {
    return [pscustomobject]@{ Ok = $false; Ms = $null; Err = $_.Exception.Message }
  } finally { $c.Close(); $c.Dispose() }
}

$baseline = Get-UdpCount
$peak = $baseline
$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('timestamp,udp_count,delta,probe_ok,probe_ms,note')
$events = New-Object System.Collections.Generic.List[object]
$probeN = 0; $probeLost = 0
$bindFailures = 0

Write-Host ""
Write-Host "=== UDP burst / port-exhaustion watch ===" -ForegroundColor Cyan
Write-Host ("Baseline UDP sockets: {0}   burst threshold: +{1}" -f $baseline, $BurstDelta)
Write-Host ("Duration {0}s, sampling every {1}ms, UDP probe to {2} every {3}ms" -f $DurationSec, $SampleMs, $ProbeTarget, $ProbeEveryMs)
Write-Host "Play the game now. Note the clock time when you feel a stutter." -ForegroundColor Yellow
Write-Host ""

$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$lastProbe = [datetime]::MinValue
$prev = $baseline

try {
  while ((Get-Date) -lt $end) {
    $ts = Get-Date
    $count = Get-UdpCount
    if ($count -gt $peak) { $peak = $count }
    $delta = $count - $prev
    $note = ''
    $probeOk = ''; $probeMs = ''

    if ((($ts - $lastProbe).TotalMilliseconds) -ge $ProbeEveryMs) {
      $lastProbe = $ts
      $p = Test-UdpDns -Server $ProbeTarget -Timeout $ProbeTimeoutMs
      $probeN++
      $probeOk = [int]$p.Ok
      $probeMs = $p.Ms
      if (-not $p.Ok) {
        $probeLost++
        if ($p.Err -match 'address|bind|buffer|resource|10048|10055') { $bindFailures++; $note = 'BIND-FAILURE' }
        $snap = Get-UdpByProcess
        $top = ($snap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        $events.Add([pscustomobject]@{ Time = $ts; Kind = 'UDP-PROBE-LOSS'; Count = $count; Top = $top; Err = $p.Err })
        Write-Host ("[{0}] UDP LOSS  sockets={1}  top: {2}" -f $ts.ToString('HH:mm:ss.fff'), $count, $top) -ForegroundColor Red
        if ($p.Err) { Write-Host ("           err: {0}" -f $p.Err) -ForegroundColor DarkRed }
      }
    }

    if ($delta -ge $BurstDelta) {
      $snap = Get-UdpByProcess
      $top = ($snap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
      $note = ($note + '|BURST').Trim('|')
      $events.Add([pscustomobject]@{ Time = $ts; Kind = 'SOCKET-BURST'; Count = $count; Top = $top; Err = "+$delta" })
      Write-Host ("[{0}] BURST +{1} -> {2} sockets  top: {3}" -f $ts.ToString('HH:mm:ss.fff'), $delta, $count, $top) -ForegroundColor Magenta
    }

    $rows.Add(("{0},{1},{2},{3},{4},{5}" -f $ts.ToString('o'), $count, $delta, $probeOk, $probeMs, $note))
    $prev = $count
    Start-Sleep -Milliseconds $SampleMs
  }
} finally {
  try { $rows | Set-Content $csv -Encoding UTF8 } catch {}
  $ev4266 = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 4266; StartTime = $start } -ErrorAction SilentlyContinue)
  $text = @"
UDP burst / exhaustion summary
Label:    $Label
Started:  $($start.ToString('o'))
Elapsed:  $([math]::Round(((Get-Date) - $start).TotalSeconds,1)) s

UDP sockets: baseline $baseline, peak $peak
UDP probes:  $probeN sent, $probeLost lost ($([math]::Round(100.0*$probeLost/[math]::Max(1,$probeN),2))%)
Local socket bind failures (port exhaustion signature): $bindFailures
Tcpip 4266 events during this run: $($ev4266.Count)

Events:
$(($events | Select-Object -Last 40 | ForEach-Object { "  {0}  {1,-15} sockets={2,-4} {3}  {4}" -f $_.Time.ToString('HH:mm:ss.fff'), $_.Kind, $_.Count, $_.Top, $_.Err }) -join "`n")

CSV: $csv
"@
  Set-Content $sum $text -Encoding UTF8
  Write-Host ""
  Write-Host $text
}
