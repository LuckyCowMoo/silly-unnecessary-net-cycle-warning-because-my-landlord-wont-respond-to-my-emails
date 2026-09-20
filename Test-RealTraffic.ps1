<#
.SYNOPSIS
  Measures loss/latency using REAL UDP (DNS queries) and TCP, not just ICMP.

.DESCRIPTION
  Routers commonly deprioritise or rate-limit ICMP, so ping loss can overstate
  or understate what a game actually experiences. Games use UDP. This sends
  genuine UDP DNS queries (unique names, so nothing is cached) plus TCP
  connects, and reports loss and latency per method per target.
#>
[CmdletBinding()]
param(
  [string[]]$UdpTargets = @("1.1.1.1", "8.8.8.8", "9.9.9.9"),
  [string]$TcpTarget = "1.1.1.1",
  [int]$TcpPort = 443,
  [int]$IntervalMs = 250,
  [int]$TimeoutMs = 1000,
  [int]$DurationSec = 240,
  [string]$Label = "realtraffic"
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csv = Join-Path $logDir ("real-{0}-{1}.csv" -f $Label, $stamp)
$sum = Join-Path $logDir ("real-summary-{0}-{1}.txt" -f $Label, $stamp)

try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

function New-DnsQuery([string]$Name) {
  $rnd = [byte[]]@((Get-Random -Minimum 0 -Maximum 256), (Get-Random -Minimum 0 -Maximum 256))
  $bytes = New-Object System.Collections.Generic.List[byte]
  $bytes.AddRange($rnd)                                   # transaction id
  $bytes.AddRange([byte[]]@(0x01, 0x00))                  # standard query, RD
  $bytes.AddRange([byte[]]@(0x00, 0x01))                  # QDCOUNT = 1
  $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
  foreach ($label in $Name.Split('.')) {
    $bytes.Add([byte]$label.Length)
    $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($label))
  }
  $bytes.Add(0x00)
  $bytes.AddRange([byte[]]@(0x00, 0x01))                  # QTYPE A
  $bytes.AddRange([byte[]]@(0x00, 0x01))                  # QCLASS IN
  return @{ Packet = $bytes.ToArray(); Id = $rnd }
}

function Test-UdpDns([string]$Server, [int]$Timeout) {
  # Unique name each time so no resolver cache can serve it
  $name = ("t{0}.example.com" -f ([guid]::NewGuid().ToString('N').Substring(0, 10)))
  $q = New-DnsQuery $name
  $client = [System.Net.Sockets.UdpClient]::new()
  try {
    $client.Client.ReceiveTimeout = $Timeout
    $client.Connect($Server, 53)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$client.Send($q.Packet, $q.Packet.Length)
    $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    try {
      $resp = $client.Receive([ref]$remote)
      $sw.Stop()
      if ($resp.Length -ge 2 -and $resp[0] -eq $q.Id[0] -and $resp[1] -eq $q.Id[1]) {
        return [pscustomobject]@{ Ok = $true; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
      }
      return [pscustomobject]@{ Ok = $false; Ms = $null }
    } catch {
      return [pscustomobject]@{ Ok = $false; Ms = $null }
    }
  } catch {
    return [pscustomobject]@{ Ok = $false; Ms = $null }
  } finally {
    $client.Close(); $client.Dispose()
  }
}

function Test-TcpConnect([string]$Target, [int]$Port, [int]$Timeout) {
  $c = [System.Net.Sockets.TcpClient]::new()
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $iar = $c.BeginConnect($Target, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($Timeout)) { return [pscustomobject]@{ Ok = $false; Ms = $null } }
    try { $c.EndConnect($iar) } catch { return [pscustomobject]@{ Ok = $false; Ms = $null } }
    $sw.Stop()
    return [pscustomobject]@{ Ok = $true; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
  } catch {
    return [pscustomobject]@{ Ok = $false; Ms = $null }
  } finally { $c.Close(); $c.Dispose() }
}

$ping = [System.Net.NetworkInformation.Ping]::new()
$stats = @{}
foreach ($t in $UdpTargets) {
  $stats["udp:$t"] = @{ n = 0; lost = 0; rtt = New-Object System.Collections.Generic.List[double] }
  $stats["icmp:$t"] = @{ n = 0; lost = 0; rtt = New-Object System.Collections.Generic.List[double] }
}
$stats["tcp:$TcpTarget"] = @{ n = 0; lost = 0; rtt = New-Object System.Collections.Generic.List[double] }

$hdr = @('timestamp')
foreach ($t in $UdpTargets) { $hdr += "udp_${t}_ok"; $hdr += "udp_${t}_ms"; $hdr += "icmp_${t}_ok"; $hdr += "icmp_${t}_ms" }
$hdr += @('tcp_ok', 'tcp_ms')
$csvRows = New-Object System.Collections.Generic.List[string]
$csvRows.Add($hdr -join ',')

Write-Host ""
Write-Host "=== Real-traffic loss test (UDP DNS + ICMP + TCP) ===" -ForegroundColor Cyan
Write-Host ("UDP/ICMP targets: {0}" -f ($UdpTargets -join ', '))
Write-Host ("TCP target: {0}:{1}" -f $TcpTarget, $TcpPort)
Write-Host ("Duration {0}s, one round every {1}ms" -f $DurationSec, $IntervalMs)
Write-Host ""

$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$round = 0
$burstEvents = New-Object System.Collections.Generic.List[object]

try {
  while ((Get-Date) -lt $end) {
    $round++
    $ts = Get-Date
    $row = @($ts.ToString('o'))
    $lostThisRound = @()

    foreach ($t in $UdpTargets) {
      $u = Test-UdpDns -Server $t -Timeout $TimeoutMs
      $stats["udp:$t"].n++
      if ($u.Ok) { $stats["udp:$t"].rtt.Add($u.Ms) } else { $stats["udp:$t"].lost++; $lostThisRound += "udp:$t" }
      $row += [int]$u.Ok; $row += $u.Ms

      $i = $null
      try {
        $r = $ping.Send($t, $TimeoutMs)
        $i = [pscustomobject]@{ Ok = ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success); Ms = [double]$r.RoundtripTime }
      } catch { $i = [pscustomobject]@{ Ok = $false; Ms = $null } }
      $stats["icmp:$t"].n++
      if ($i.Ok) { $stats["icmp:$t"].rtt.Add($i.Ms) } else { $stats["icmp:$t"].lost++; $lostThisRound += "icmp:$t" }
      $row += [int]$i.Ok; $row += $i.Ms
    }

    $tcp = Test-TcpConnect -Target $TcpTarget -Port $TcpPort -Timeout $TimeoutMs
    $stats["tcp:$TcpTarget"].n++
    if ($tcp.Ok) { $stats["tcp:$TcpTarget"].rtt.Add($tcp.Ms) } else { $stats["tcp:$TcpTarget"].lost++; $lostThisRound += "tcp" }
    $row += @([int]$tcp.Ok, $tcp.Ms)

    $csvRows.Add($row -join ',')

    $udpLost = @($lostThisRound | Where-Object { $_ -like 'udp:*' }).Count
    if ($udpLost -ge 2) {
      $burstEvents.Add([pscustomobject]@{ Time = $ts; What = ($lostThisRound -join ' ') })
      Write-Host ("[{0}] MULTI-TARGET UDP LOSS: {1}" -f $ts.ToString('HH:mm:ss.fff'), ($lostThisRound -join ' ')) -ForegroundColor Red
    } elseif ($lostThisRound.Count -gt 0) {
      Write-Host ("[{0}] loss: {1}" -f $ts.ToString('HH:mm:ss.fff'), ($lostThisRound -join ' ')) -ForegroundColor Yellow
    } elseif (($round % 40) -eq 0) {
      $d = (($UdpTargets | ForEach-Object { "{0}:udp={1}ms" -f $_, $(if ($stats["udp:$_"].rtt.Count) { [math]::Round($stats["udp:$_"].rtt[-1], 0) } else { '-' }) }) -join '  ')
      Write-Host ("[{0}] ok  {1}" -f $ts.ToString('HH:mm:ss'), $d) -ForegroundColor DarkGray
    }

    Start-Sleep -Milliseconds $IntervalMs
  }
} finally {
  $ping.Dispose()
  try { $csvRows | Set-Content $csv -Encoding UTF8 } catch { Write-Host "csv write failed: $($_.Exception.Message)" }
  $rows = foreach ($k in ($stats.Keys | Sort-Object)) {
    $s = $stats[$k]
    $arr = @($s.rtt)
    $avg = if ($arr.Count) { [math]::Round(($arr | Measure-Object -Average).Average, 1) } else { $null }
    $p95 = if ($arr.Count -gt 1) { $sorted = $arr | Sort-Object; [math]::Round($sorted[[int][math]::Floor($sorted.Count * 0.95)], 1) } else { $null }
    $mx = if ($arr.Count) { [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1) } else { $null }
    "  {0,-16} probes {1,4}  loss {2,3} ({3,5}%)  avg {4,7}ms  p95 {5,7}ms  max {6,7}ms" -f `
      $k, $s.n, $s.lost, [math]::Round(100.0 * $s.lost / [math]::Max(1, $s.n), 2), $avg, $p95, $mx
  }
  $text = @"
Real-traffic loss summary
Label:   $Label
Started: $($start.ToString('o'))
Elapsed: $([math]::Round(((Get-Date) - $start).TotalSeconds,1)) s

$($rows -join "`n")

Rounds where 2+ UDP targets lost simultaneously (real path loss): $($burstEvents.Count)
$(($burstEvents | Select-Object -Last 25 | ForEach-Object { "  {0}  {1}" -f $_.Time.ToString('HH:mm:ss.fff'), $_.What }) -join "`n")

CSV: $csv
"@
  Set-Content $sum $text -Encoding UTF8
  Write-Host ""
  Write-Host $text
}
