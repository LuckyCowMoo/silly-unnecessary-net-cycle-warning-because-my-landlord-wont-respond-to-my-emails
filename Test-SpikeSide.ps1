<#
.SYNOPSIS
  When an internet packet is slow, record whether the gateway was slow too and
  whether this script itself froze.

  Gateway fast + loop on time  -> delay is past the router
  Gateway slow or loop froze   -> delay is on this PC or the link to the router
#>
[CmdletBinding()]
param(
  [string[]]$Servers = @("stun.l.google.com:19302", "stun1.l.google.com:19302", "stun.cloudflare.com:3478"),
  [int]$RateHz = 20,
  [int]$DurationSec = 300,
  [int]$SpikeMs = 100,
  [int]$GatewayTimeoutMs = 40,
  [string]$Label = "spikeside",
  [bool]$SyncToFiveMin = $true
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$sum = Join-Path $logDir ("spikeside-{0}-{1}.txt" -f $Label, $stamp)
try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

$gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
  Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
  Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).NextHop
if (-not $gateway) { Write-Host "no gateway"; exit 1 }

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

$flows = @()
foreach ($s in $Servers) {
  $p = $s -split ':'
  try {
    $addr = ([System.Net.Dns]::GetHostAddresses($p[0]) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
    if (-not $addr) { continue }
    $c = [System.Net.Sockets.UdpClient]::new(0)
    $c.Client.ReceiveTimeout = 1
    $c.Connect($addr, [int]$p[1])
    $flows += [pscustomobject]@{ Name = $p[0]; Client = $c; Pending = @{}; Sent = 0; Slow = 0 }
    Write-Host ("flow: {0}" -f $p[0]) -ForegroundColor Cyan
  } catch {
    Write-Host ("skip {0}: {1}" -f $s, $_.Exception.Message) -ForegroundColor Yellow
  }
}
if ($flows.Count -eq 0) { Write-Host "no STUN servers"; exit 1 }

Write-Host ""
Write-Host "=== Spike side test ===" -ForegroundColor Cyan
Write-Host ("Gateway {0}    duration {1} min    slow if internet RTT >= {2}ms" -f $gateway, ([math]::Round($DurationSec / 60, 1)), $SpikeMs)
Write-Host "A slow internet packet is classified using the gateway ping and whether this script froze." -ForegroundColor Gray
Write-Host ""

if ($SyncToFiveMin) {
  $now = Get-Date
  $minuteFloor = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute $now.Minute -Second 0 -Millisecond 0
  $mod = $minuteFloor.Minute % 5
  if ($mod -eq 0 -and $now.Second -le 2) { $boundary = $minuteFloor }
  else {
    $add = if ($mod -eq 0) { 5 } else { 5 - $mod }
    $boundary = $minuteFloor.AddMinutes($add)
  }
  if ($boundary -gt (Get-Date)) {
    Write-Host ("Waiting for the next 5-minute mark: {0:HH:mm:ss}" -f $boundary) -ForegroundColor Yellow
    while ((Get-Date) -lt $boundary.AddMilliseconds(-200)) {
      $left = [math]::Ceiling(($boundary - (Get-Date)).TotalSeconds)
      if ($left -lt 0) { $left = 0 }
      Write-Host ("  {0:HH:mm:ss}  starts in {1}s" -f (Get-Date), $left) -ForegroundColor DarkGray
      $sleep = [math]::Min(1, [math]::Max(0.05, ($boundary - (Get-Date)).TotalSeconds - 0.2))
      Start-Sleep -Milliseconds ([int]($sleep * 1000))
    }
    while ((Get-Date) -lt $boundary) { }
  }
  Write-Host ("Starting on 5-minute mark {0:HH:mm:ss.fff}" -f (Get-Date)) -ForegroundColor Green
}

$ping = [System.Net.NetworkInformation.Ping]::new()
$intervalMs = [int](1000 / $RateHz)
$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastTick = 0.0
$events = New-Object System.Collections.Generic.List[object]
$gwSamples = 0
$gwSlow = 0
$localStalls = 0

try {
  while ((Get-Date) -lt $end) {
    $loopStart = $sw.Elapsed.TotalMilliseconds
    $overshoot = 0.0
    if ($lastTick -gt 0) { $overshoot = $loopStart - $lastTick - $intervalMs }
    if ($overshoot -lt 0) { $overshoot = 0 }
    $lastTick = $loopStart
    if ($overshoot -ge $SpikeMs) { $localStalls++ }

    $gwMs = $null
    $gwOk = $false
    try {
      $r = $ping.Send($gateway, $GatewayTimeoutMs)
      $gwSamples++
      if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
        $gwOk = $true
        $gwMs = [double]$r.RoundtripTime
        if ($gwMs -ge 20) { $gwSlow++ }
      }
    } catch {}

    foreach ($f in $flows) {
      try {
        $req = New-StunRequest
        [void]$f.Client.Send($req.Packet, 20)
        $f.Pending[$req.Tid] = $sw.Elapsed.TotalMilliseconds
        $f.Sent++
      } catch {}

      while ($f.Client.Available -gt 0) {
        try {
          $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
          $data = $f.Client.Receive([ref]$ep)
          $tid = Get-StunTid $data
          if ($tid -and $f.Pending.ContainsKey($tid)) {
            $rtt = $sw.Elapsed.TotalMilliseconds - $f.Pending[$tid]
            $f.Pending.Remove($tid)
            if ($rtt -ge $SpikeMs) {
              $f.Slow++
              $side = 'past-router'
              if ($overshoot -ge 80) { $side = 'this-pc-froze' }
              elseif (-not $gwOk -or ($null -ne $gwMs -and $gwMs -ge 20)) { $side = 'gateway-or-link' }
              $ev = [pscustomobject]@{
                Time = Get-Date
                Flow = $f.Name
                Rtt = [math]::Round($rtt, 1)
                Gw = $(if ($gwOk) { [math]::Round($gwMs, 1) } else { $null })
                GwOk = $gwOk
                Overshoot = [math]::Round($overshoot, 1)
                Side = $side
              }
              $events.Add($ev)
              $gwTxt = if ($gwOk) { "$($ev.Gw)ms" } else { "timeout" }
              Write-Host ("[{0}] SLOW {1} {2}ms  gateway {3}  loop +{4}ms  => {5}" -f $ev.Time.ToString('HH:mm:ss.fff'), $f.Name, $ev.Rtt, $gwTxt, $ev.Overshoot, $side) -ForegroundColor Yellow
            }
          }
        } catch { break }
      }

      $nowMs = $sw.Elapsed.TotalMilliseconds
      foreach ($k in @($f.Pending.Keys | Where-Object { ($nowMs - $f.Pending[$_]) -gt 1000 })) {
        $f.Pending.Remove($k)
      }
    }

    $sleep = $intervalMs - ($sw.Elapsed.TotalMilliseconds - $loopStart)
    if ($sleep -gt 1) { Start-Sleep -Milliseconds ([int]$sleep) }
  }
} finally {
  foreach ($f in $flows) { try { $f.Client.Close(); $f.Client.Dispose() } catch {} }
  $ping.Dispose()

  $groups = @{}
  foreach ($e in $events) { $groups[$e.Side] = 1 + [int]$groups[$e.Side] }
  $lines = $events | ForEach-Object {
    $gwTxt = if ($_.GwOk) { "$($_.Gw)ms" } else { "timeout" }
    "  {0}  {1,-24} {2,7}ms  gw {3,8}  loop +{4,6}ms  {5}" -f $_.Time.ToString('HH:mm:ss.fff'), $_.Flow, $_.Rtt, $gwTxt, $_.Overshoot, $_.Side
  }
  $text = @"
Spike side summary
Label:    $Label
Started:  $($start.ToString('o'))
Elapsed:  $([math]::Round(((Get-Date)-$start).TotalSeconds,1)) s
Gateway:  $gateway
Gateway probes: $gwSamples   gateway RTT >= 20ms: $gwSlow
Loop freezes (>= ${SpikeMs}ms): $localStalls

Slow internet packets: $($events.Count)
  past-router:     $(if ($groups['past-router']) { $groups['past-router'] } else { 0 })
  gateway-or-link: $(if ($groups['gateway-or-link']) { $groups['gateway-or-link'] } else { 0 })
  this-pc-froze:   $(if ($groups['this-pc-froze']) { $groups['this-pc-froze'] } else { 0 })

$($lines -join "`n")
"@
  Set-Content $sum $text -Encoding UTF8
  Write-Host ""
  Write-Host $text
}
