<#
.SYNOPSIS
  Long-duration continuous monitor. Logs every lost packet with a timestamp so a
  stutter you notice can be matched to the exact moment in the log.

.DESCRIPTION
  Holds persistent UDP flows open (like a game does), records every single loss
  and every burst, samples NIC counters and link state, and detects local
  process stalls. Writes incrementally so the log can be read while running.

  Tell the agent the clock time whenever you feel a stutter.
#>
[CmdletBinding()]
param(
  [string[]]$Servers = @("stun.l.google.com:19302", "stun1.l.google.com:19302", "stun.cloudflare.com:3478"),
  [int]$RateHz = 25,
  [int]$TimeoutMs = 800,
  [int]$DurationMin = 45,
  [string]$Adapter = "",
  [string]$Label = "long"
)

$ErrorActionPreference = "Stop"
if (-not $Adapter) {
  $Adapter = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1).InterfaceAlias
  if (-not $Adapter) { $Adapter = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name }
}
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$live = Join-Path $logDir ("LIVE-{0}-{1}.log" -f $Label, $stamp)
try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

$MAGIC = [byte[]]@(0x21, 0x12, 0xA4, 0x42)
function New-StunRequest {
  $b = [byte[]]::new(20)
  $b[1] = 0x01
  [Array]::Copy($MAGIC, 0, $b, 4, 4)
  for ($i = 8; $i -lt 20; $i++) { $b[$i] = [byte](Get-Random -Minimum 0 -Maximum 256) }
  return @{ Packet = $b; Tid = [System.BitConverter]::ToString($b[8..19]) }
}
function Get-StunTid([byte[]]$b) {
  if ($b.Length -lt 20) { return $null }
  return [System.BitConverter]::ToString($b[8..19])
}

$writer = [System.IO.StreamWriter]::new($live, $true)
$writer.AutoFlush = $true
function Log([string]$m) {
  $line = "{0}  {1}" -f (Get-Date).ToString('HH:mm:ss.fff'), $m
  $writer.WriteLine($line)
  return $line
}

$flows = @()
foreach ($s in $Servers) {
  $p = $s -split ':'
  try {
    $addr = ([System.Net.Dns]::GetHostAddresses($p[0]) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
    if (-not $addr) { continue }
    $c = [System.Net.Sockets.UdpClient]::new(0)
    $c.Client.ReceiveTimeout = 1
    $c.Connect($addr, [int]$p[1])
    $flows += [pscustomobject]@{
      Name = $p[0].Replace('.l.google.com', '-goog').Replace('stun.cloudflare.com', 'cloudflare')
      Client = $c; Pending = @{}; Sent = 0; Lost = 0; ConsecLost = 0; Bursts = 0
      LastLossTs = $null
    }
  } catch {}
}
if ($flows.Count -eq 0) { Write-Host "no STUN servers reachable" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "=== LONG MONITOR ===" -ForegroundColor Cyan
Write-Host ("Flows: {0}   rate {1}/s each   duration {2} min" -f ($flows.Name -join ', '), $RateHz, $DurationMin)
Write-Host ("Live log: {0}" -f $live) -ForegroundColor Gray
Write-Host ""
Write-Host "PLAY NORMALLY. Note the clock time whenever you feel a stutter." -ForegroundColor Yellow
Write-Host ""
Log ("MONITOR START flows={0} rate={1}/s" -f ($flows.Name -join '+'), $RateHz) | Out-Null

$intervalMs = [int](1000 / $RateHz)
$start = Get-Date
$end = $start.AddMinutes($DurationMin)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastNic = Get-NetAdapterStatistics -Name $Adapter -ErrorAction SilentlyContinue
$lastSecond = [datetime]::MinValue
$lastStatus = Get-Date
$lastTick = 0.0
$totalSent = 0; $totalLost = 0; $simulEvents = 0

try {
  while ((Get-Date) -lt $end) {
    $loopStart = $sw.Elapsed.TotalMilliseconds
    $overshoot = $loopStart - $lastTick - $intervalMs
    if ($lastTick -gt 0 -and $overshoot -ge 150) {
      Write-Host (Log ("SYSTEM-STALL local process froze {0}ms" -f [math]::Round($overshoot))) -ForegroundColor DarkYellow
    }
    $lastTick = $loopStart
    $nowLost = @()

    foreach ($f in $flows) {
      try {
        $r = New-StunRequest
        [void]$f.Client.Send($r.Packet, 20)
        $f.Pending[$r.Tid] = $sw.Elapsed.TotalMilliseconds
        $f.Sent++; $totalSent++
      } catch {}

      while ($f.Client.Available -gt 0) {
        try {
          $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
          $data = $f.Client.Receive([ref]$ep)
          $tid = Get-StunTid $data
          if ($tid -and $f.Pending.ContainsKey($tid)) {
            $f.Pending.Remove($tid)
            if ($f.ConsecLost -ge 2) {
              $f.Bursts++
              Write-Host (Log ("OUTAGE {0}: {1} consecutive lost (~{2}ms of silence)" -f $f.Name, $f.ConsecLost, ($f.ConsecLost * $intervalMs))) -ForegroundColor Red
            }
            $f.ConsecLost = 0
          }
        } catch { break }
      }

      $now = $sw.Elapsed.TotalMilliseconds
      foreach ($k in @($f.Pending.Keys | Where-Object { ($now - $f.Pending[$_]) -gt $TimeoutMs })) {
        $f.Pending.Remove($k)
        $f.Lost++; $totalLost++; $f.ConsecLost++
        $f.LastLossTs = Get-Date
        $nowLost += $f.Name
      }
    }

    if ($nowLost.Count -ge 2) {
      $simulEvents++
      Write-Host (Log ("SIMULTANEOUS LOSS on {0}  <-- real path event" -f ($nowLost -join '+'))) -ForegroundColor Magenta
    }

    $nowDt = Get-Date
    if (($nowDt - $lastSecond).TotalMilliseconds -ge 1000) {
      $lastSecond = $nowDt
      $nic = Get-NetAdapterStatistics -Name $Adapter -ErrorAction SilentlyContinue
      if ($nic -and $lastNic) {
        $dd = $nic.ReceivedDiscardedPackets - $lastNic.ReceivedDiscardedPackets
        $de = $nic.ReceivedPacketErrors - $lastNic.ReceivedPacketErrors
        $od = $nic.OutboundDiscardedPackets - $lastNic.OutboundDiscardedPackets
        if ($dd -gt 0 -or $de -gt 0 -or $od -gt 0) {
          Write-Host (Log ("NIC rx_discard=+{0} rx_err=+{1} tx_discard=+{2}" -f $dd, $de, $od)) -ForegroundColor Yellow
        }
      }
      if ($nic) { $lastNic = $nic }
    }

    if (($nowDt - $lastStatus).TotalSeconds -ge 60) {
      $lastStatus = $nowDt
      $pct = [math]::Round(100.0 * $totalLost / [math]::Max(1, $totalSent), 2)
      $per = ($flows | ForEach-Object { "{0} {1}%" -f $_.Name, [math]::Round(100.0 * $_.Lost / [math]::Max(1, $_.Sent), 2) }) -join '  '
      $msg = "STATUS {0}min  loss {1}%  ({2})  bursts={3}  simultaneous={4}" -f `
        [math]::Round(($nowDt - $start).TotalMinutes, 1), $pct, $per, (($flows | Measure-Object -Property Bursts -Sum).Sum), $simulEvents
      Write-Host (Log $msg) -ForegroundColor Cyan
    }

    $sleep = $intervalMs - ($sw.Elapsed.TotalMilliseconds - $loopStart)
    if ($sleep -gt 1) { Start-Sleep -Milliseconds ([int]$sleep) }
  }
} finally {
  foreach ($f in $flows) { try { $f.Client.Close(); $f.Client.Dispose() } catch {} }
  $pct = [math]::Round(100.0 * $totalLost / [math]::Max(1, $totalSent), 2)
  $final = @"
FINAL  elapsed $([math]::Round(((Get-Date)-$start).TotalMinutes,1)) min
  sent $totalSent  lost $totalLost  ($pct%)
  bursts (2+ consecutive): $(($flows | Measure-Object -Property Bursts -Sum).Sum)
  simultaneous multi-flow losses: $simulEvents
$(($flows | ForEach-Object { "  {0,-12} sent {1,6} lost {2,4} ({3}%)  bursts {4}" -f $_.Name, $_.Sent, $_.Lost, [math]::Round(100.0*$_.Lost/[math]::Max(1,$_.Sent),2), $_.Bursts }) -join "`n")
"@
  Log $final | Out-Null
  Write-Host ""
  Write-Host $final -ForegroundColor Green
  Write-Host ("Live log: {0}" -f $live)
  $writer.Close()
}
