<#
.SYNOPSIS
  Disambiguates the ~21s stall: real network stall vs gateway ICMP rate-limit
  artifact vs local system stall.

.DESCRIPTION
  Probes several targets at a LOW rate (so gateway ICMP policing can't be
  mistaken for loss), samples the gateway ARP/neighbour state, watches NIC
  discard counters, and measures loop overshoot to detect process/system
  freezes. Classifies every event.

  Key discriminators:
    * gateway loses AND external loses at same instant -> real forwarding stall
    * only gateway loses                               -> gateway ICMP handling
    * loop overshoot at same instant                   -> local system stall
    * ARP state leaves Reachable at same instant       -> ARP/NUD stall
#>
[CmdletBinding()]
param(
  [string]$Gateway = "",
  [string[]]$External = @("1.1.1.1", "8.8.8.8"),
  [int]$IntervalMs = 500,
  [int]$TimeoutMs = 900,
  [int]$OvershootMs = 150,
  [int]$DurationSec = 300,
  [string]$Label = "correlated",
  [string]$Adapter = "Ethernet"
)

$ErrorActionPreference = "Stop"
if (-not $Gateway) {
  $Gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
    Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).NextHop
}
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csv = Join-Path $logDir ("corr-{0}-{1}.csv" -f $Label, $stamp)
$sum = Join-Path $logDir ("corr-summary-{0}-{1}.txt" -f $Label, $stamp)

try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

# Deadlock / game endpoints, if the game is running
$gameTargets = @()
$game = Get-Process -Name deadlock -ErrorAction SilentlyContinue
if ($game) {
  $eps = Get-NetUDPEndpoint -OwningProcess $game.Id -ErrorAction SilentlyContinue
  $conns = Get-NetTCPConnection -OwningProcess $game.Id -State Established -ErrorAction SilentlyContinue
  $gameTargets = @($conns.RemoteAddress) | Where-Object { $_ -and $_ -notmatch '^(127\.|0\.0\.0\.0|::)' } | Select-Object -Unique -First 2
  Write-Host ("Deadlock running (pid {0}): {1} UDP sockets, probing {2}" -f $game.Id, @($eps).Count, ($gameTargets -join ', ')) -ForegroundColor Cyan
}

$targets = @([pscustomobject]@{ Name = 'gw'; Addr = $Gateway })
$i = 1
foreach ($e in $External) { $targets += [pscustomobject]@{ Name = ("ext{0}" -f $i); Addr = $e }; $i++ }
$i = 1
foreach ($g in $gameTargets) { $targets += [pscustomobject]@{ Name = ("game{0}" -f $i); Addr = $g }; $i++ }

function Get-NicSnap([string]$Name) {
  $n = Get-NetAdapterStatistics -Name $Name -ErrorAction SilentlyContinue
  if (-not $n) { return $null }
  [pscustomobject]@{
    RxDisc = [int64]$n.ReceivedDiscardedPackets
    RxErr  = [int64]$n.ReceivedPacketErrors
    TxDisc = [int64]$n.OutboundDiscardedPackets
    TxErr  = [int64]$n.OutboundPacketErrors
  }
}

$hdr = @('timestamp', 'overshoot_ms', 'arp_state')
foreach ($t in $targets) { $hdr += ("{0}_ok" -f $t.Name); $hdr += ("{0}_ms" -f $t.Name) }
$hdr += @('rx_disc_d', 'rx_err_d', 'tx_disc_d', 'tx_err_d', 'classification')
($hdr -join ',') | Set-Content $csv -Encoding UTF8

Write-Host ""
Write-Host "=== Correlated stall detector ===" -ForegroundColor Cyan
Write-Host ("Targets: {0}" -f (($targets | ForEach-Object { "$($_.Name)=$($_.Addr)" }) -join '  '))
Write-Host ("Probe rate: every {0}ms per target (low, avoids ICMP policing)" -f $IntervalMs)
Write-Host ("Duration: {0}s   Label: {1}" -f $DurationSec, $Label)
Write-Host ""

$ping = [System.Net.NetworkInformation.Ping]::new()
$prevNic = Get-NicSnap $Adapter
$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastTick = $sw.Elapsed.TotalMilliseconds
$events = New-Object System.Collections.Generic.List[object]
$counts = @{ real = 0; gwonly = 0; systemstall = 0; extonly = 0; arp = 0 }
$totals = @{}
$losses = @{}
foreach ($t in $targets) { $totals[$t.Name] = 0; $losses[$t.Name] = 0 }
$probe = 0

try {
  while ((Get-Date) -lt $end) {
    $probe++
    $tickStart = $sw.Elapsed.TotalMilliseconds
    $overshoot = [math]::Round($tickStart - $lastTick - $IntervalMs, 0)
    if ($overshoot -lt 0) { $overshoot = 0 }
    $ts = Get-Date

    $arp = (Get-NetNeighbor -IPAddress $Gateway -InterfaceAlias $Adapter -ErrorAction SilentlyContinue | Select-Object -First 1).State
    if (-not $arp) { $arp = 'None' }

    $res = @{}
    foreach ($t in $targets) {
      try {
        $r = $ping.Send($t.Addr, $TimeoutMs)
        if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
          $res[$t.Name] = [pscustomobject]@{ Ok = $true; Ms = [double]$r.RoundtripTime }
        } else {
          $res[$t.Name] = [pscustomobject]@{ Ok = $false; Ms = $null }
        }
      } catch {
        $res[$t.Name] = [pscustomobject]@{ Ok = $false; Ms = $null }
      }
      $totals[$t.Name]++
      if (-not $res[$t.Name].Ok) { $losses[$t.Name]++ }
    }

    $nic = Get-NicSnap $Adapter
    $rxD = 0; $rxE = 0; $txD = 0; $txE = 0
    if ($nic -and $prevNic) {
      $rxD = $nic.RxDisc - $prevNic.RxDisc
      $rxE = $nic.RxErr - $prevNic.RxErr
      $txD = $nic.TxDisc - $prevNic.TxDisc
      $txE = $nic.TxErr - $prevNic.TxErr
    }
    if ($nic) { $prevNic = $nic }

    $gwLost = -not $res['gw'].Ok
    $extNames = @($targets | Where-Object { $_.Name -like 'ext*' } | ForEach-Object { $_.Name })
    $extLost = @($extNames | Where-Object { -not $res[$_].Ok }).Count
    $anyExtLost = $extLost -gt 0
    $allExtLost = ($extNames.Count -gt 0) -and ($extLost -eq $extNames.Count)

    $class = ''
    if ($overshoot -ge $OvershootMs) { $class = 'SYSTEM-STALL'; $counts.systemstall++ }
    elseif ($gwLost -and $anyExtLost) { $class = 'REAL-NETWORK-STALL'; $counts.real++ }
    elseif ($gwLost -and -not $anyExtLost) { $class = 'GATEWAY-ICMP-ONLY'; $counts.gwonly++ }
    elseif ($allExtLost -and -not $gwLost) { $class = 'UPSTREAM-ONLY'; $counts.extonly++ }
    if ($arp -ne 'Reachable' -and $arp -ne 'Permanent') {
      $class = ($class + '+ARP-' + $arp).TrimStart('+')
      $counts.arp++
    }

    if ($class) {
      $detail = (($targets | ForEach-Object { "{0}={1}" -f $_.Name, $(if ($res[$_.Name].Ok) { "$($res[$_.Name].Ms)ms" } else { 'LOSS' }) }) -join '  ')
      $events.Add([pscustomobject]@{ Time = $ts; Class = $class; Overshoot = $overshoot; Arp = $arp; Detail = $detail })
      Write-Host ("[{0}] {1}  overshoot={2}ms arp={3}  {4}" -f $ts.ToString('HH:mm:ss.fff'), $class, $overshoot, $arp, $detail) -ForegroundColor Red
    } elseif (($probe % 20) -eq 0) {
      $detail = (($targets | ForEach-Object { "{0}={1}" -f $_.Name, $(if ($res[$_.Name].Ok) { "$($res[$_.Name].Ms)" } else { 'X' }) }) -join ' ')
      Write-Host ("[{0}] ok  {1}  arp={2}" -f $ts.ToString('HH:mm:ss'), $detail, $arp) -ForegroundColor DarkGray
    }

    $row = @($ts.ToString('o'), $overshoot, $arp)
    foreach ($t in $targets) { $row += [int]$res[$t.Name].Ok; $row += $res[$t.Name].Ms }
    $row += @($rxD, $rxE, $txD, $txE, $class)
    Add-Content $csv ($row -join ',')

    $lastTick = $tickStart
    $sleep = $IntervalMs - ($sw.Elapsed.TotalMilliseconds - $tickStart)
    if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int]$sleep) }
  }
} finally {
  $ping.Dispose()
  $lossLines = foreach ($t in $targets) {
    "  {0,-6} {1,-16} loss {2}/{3} ({4}%)" -f $t.Name, $t.Addr, $losses[$t.Name], $totals[$t.Name],
      [math]::Round(100.0 * $losses[$t.Name] / [math]::Max(1, $totals[$t.Name]), 2)
  }
  $text = @"
Correlated stall summary
Label:    $Label
Started:  $($start.ToString('o'))
Elapsed:  $([math]::Round(((Get-Date) - $start).TotalSeconds,1)) s
Gateway:  $Gateway

Per-target loss:
$($lossLines -join "`n")

Event classification:
  REAL-NETWORK-STALL (gw + external lost together) : $($counts.real)
  GATEWAY-ICMP-ONLY  (only gw lost, internet fine) : $($counts.gwonly)
  UPSTREAM-ONLY      (external lost, gw fine)      : $($counts.extonly)
  SYSTEM-STALL       (our own loop froze)          : $($counts.systemstall)
  ARP not Reachable at event time                  : $($counts.arp)

CSV: $csv

Events:
$(($events | Select-Object -Last 40 | ForEach-Object { "  {0}  {1}  overshoot={2}ms arp={3}  {4}" -f $_.Time.ToString('HH:mm:ss.fff'), $_.Class, $_.Overshoot, $_.Arp, $_.Detail }) -join "`n")
"@
  Set-Content $sum $text -Encoding UTF8
  Write-Host ""
  Write-Host $text
}
