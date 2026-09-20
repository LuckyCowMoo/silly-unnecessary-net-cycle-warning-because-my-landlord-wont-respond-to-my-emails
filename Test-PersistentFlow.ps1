<#
.SYNOPSIS
  Tests a long-lived UDP flow the way a game or voice call actually uses one.

.DESCRIPTION
  Earlier tests opened a fresh socket per probe, so every packet was a brand-new
  flow and always succeeded. Games and Discord hold ONE flow (fixed source port)
  open for the whole session. If a NAT/conntrack table evicts or rebinds that
  flow, only long-lived traffic breaks - exactly the reported symptom.

  Uses STUN binding requests, which:
    * public STUN servers accept at high rate without rate-limiting
    * return the observed public IP:port, so a NAT rebind is directly visible

  Reports loss, burst outages (consecutive losses), and any mapping change.
#>
[CmdletBinding()]
param(
  [string[]]$Servers = @("stun.l.google.com:19302", "stun1.l.google.com:19302", "stun.cloudflare.com:3478"),
  [int]$RateHz = 20,
  [int]$TimeoutMs = 1000,
  [int]$DurationSec = 300,
  [int]$BurstThreshold = 3,
  [string]$Label = "persistent"
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$sum = Join-Path $logDir ("persistflow-{0}-{1}.txt" -f $Label, $stamp)
$csv = Join-Path $logDir ("persistflow-{0}-{1}.csv" -f $Label, $stamp)
try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

$MAGIC = [byte[]]@(0x21, 0x12, 0xA4, 0x42)

function New-StunRequest {
  $b = [byte[]]::new(20)
  $b[0] = 0x00; $b[1] = 0x01          # Binding Request
  $b[2] = 0x00; $b[3] = 0x00          # length 0
  [Array]::Copy($MAGIC, 0, $b, 4, 4)  # magic cookie
  for ($i = 8; $i -lt 20; $i++) { $b[$i] = [byte](Get-Random -Minimum 0 -Maximum 256) }
  $tid = [System.BitConverter]::ToString($b[8..19])
  return @{ Packet = $b; Tid = $tid }
}

function Read-StunResponse([byte[]]$b) {
  if ($b.Length -lt 20) { return $null }
  $tid = [System.BitConverter]::ToString($b[8..19])
  $len = ($b[2] -shl 8) -bor $b[3]
  $off = 20
  $mapped = $null
  while (($off + 4) -le (20 + $len) -and ($off + 4) -le $b.Length) {
    $at = ($b[$off] -shl 8) -bor $b[$off + 1]
    $al = ($b[$off + 2] -shl 8) -bor $b[$off + 3]
    $v = $off + 4
    if (($at -eq 0x0020 -or $at -eq 0x0001) -and ($v + 7) -lt $b.Length) {
      $fam = $b[$v + 1]
      if ($at -eq 0x0020) {
        $port = ((($b[$v + 2] -shl 8) -bor $b[$v + 3]) -bxor 0x2112)
        if ($fam -eq 1) {
          $ip = @(); for ($i = 0; $i -lt 4; $i++) { $ip += ($b[$v + 4 + $i] -bxor $MAGIC[$i]) }
          $mapped = ("{0}:{1}" -f ($ip -join '.'), $port)
        }
      } else {
        $port = (($b[$v + 2] -shl 8) -bor $b[$v + 3])
        if ($fam -eq 1) { $mapped = ("{0}:{1}" -f (($b[$v + 4..($v + 7)]) -join '.'), $port) }
      }
    }
    $off += 4 + $al
    if ($al % 4 -ne 0) { $off += (4 - ($al % 4)) }
  }
  return @{ Tid = $tid; Mapped = $mapped }
}

# One persistent socket per server, fixed local port - this is the whole point
$flows = @()
foreach ($s in $Servers) {
  $parts = $s -split ':'
  $host_ = $parts[0]; $port = [int]$parts[1]
  try {
    $addr = ([System.Net.Dns]::GetHostAddresses($host_) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
    if (-not $addr) { Write-Host "skip $s (no A record)" -ForegroundColor Yellow; continue }
    $c = [System.Net.Sockets.UdpClient]::new(0)   # ephemeral local port, held for the whole run
    $c.Client.ReceiveTimeout = 1
    $c.Connect($addr, $port)
    $lp = ([System.Net.IPEndPoint]$c.Client.LocalEndPoint).Port
    $flows += [pscustomobject]@{
      Name = $host_; Addr = $addr.ToString(); Port = $port; Client = $c; LocalPort = $lp
      Pending = @{}; Sent = 0; Recv = 0; Lost = 0
      Rtts = (New-Object System.Collections.Generic.List[double])
      ConsecLost = 0; Mapped = $null; MapChanges = 0
      Bursts = (New-Object System.Collections.Generic.List[object])
    }
    Write-Host ("flow: {0} ({1}:{2})  local port {3}" -f $host_, $addr, $port, $lp) -ForegroundColor Cyan
  } catch {
    Write-Host ("skip {0}: {1}" -f $s, $_.Exception.Message) -ForegroundColor Yellow
  }
}
if ($flows.Count -eq 0) { Write-Host "no usable STUN servers" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "=== Persistent UDP flow test (game-like) ===" -ForegroundColor Cyan
Write-Host ("Rate {0} pkt/s per flow, duration {1}s, timeout {2}ms" -f $RateHz, $DurationSec, $TimeoutMs)
Write-Host "Each flow keeps ONE socket and ONE source port for the entire run." -ForegroundColor Gray
Write-Host "Play normally. Outages of 3+ consecutive packets are flagged." -ForegroundColor Yellow
Write-Host ""

$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('timestamp,flow,event,detail')
$intervalMs = [int](1000 / $RateHz)
$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$sw = [System.Diagnostics.Stopwatch]::StartNew()

try {
  while ((Get-Date) -lt $end) {
    $loopStart = $sw.Elapsed.TotalMilliseconds

    foreach ($f in $flows) {
      # send
      try {
        $r = New-StunRequest
        [void]$f.Client.Send($r.Packet, 20)
        $f.Pending[$r.Tid] = $sw.Elapsed.TotalMilliseconds
        $f.Sent++
      } catch {}

      # drain responses
      while ($f.Client.Available -gt 0) {
        try {
          $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
          $data = $f.Client.Receive([ref]$ep)
          $resp = Read-StunResponse $data
          if ($resp -and $f.Pending.ContainsKey($resp.Tid)) {
            $rtt = $sw.Elapsed.TotalMilliseconds - $f.Pending[$resp.Tid]
            $f.Rtts.Add($rtt)
            $f.Pending.Remove($resp.Tid)
            $f.Recv++
            if ($f.ConsecLost -ge $BurstThreshold) {
              $ts = Get-Date
              $f.Bursts.Add([pscustomobject]@{ Time = $ts; Count = $f.ConsecLost; Ms = [math]::Round($f.ConsecLost * $intervalMs) })
              Write-Host ("[{0}] OUTAGE {1}: {2} consecutive lost (~{3}ms)" -f $ts.ToString('HH:mm:ss.fff'), $f.Name, $f.ConsecLost, ($f.ConsecLost * $intervalMs)) -ForegroundColor Red
              $rows.Add(("{0},{1},outage,{2} pkts ~{3}ms" -f $ts.ToString('o'), $f.Name, $f.ConsecLost, ($f.ConsecLost * $intervalMs)))
            }
            $f.ConsecLost = 0
            if ($resp.Mapped) {
              if ($f.Mapped -and $resp.Mapped -ne $f.Mapped) {
                $f.MapChanges++
                $ts = Get-Date
                Write-Host ("[{0}] *** NAT REBIND {1}: {2} -> {3}" -f $ts.ToString('HH:mm:ss.fff'), $f.Name, $f.Mapped, $resp.Mapped) -ForegroundColor Magenta
                $rows.Add(("{0},{1},nat_rebind,{2} -> {3}" -f $ts.ToString('o'), $f.Name, $f.Mapped, $resp.Mapped))
              }
              $f.Mapped = $resp.Mapped
            }
          }
        } catch { break }
      }

      # expire
      $now = $sw.Elapsed.TotalMilliseconds
      $expired = @($f.Pending.Keys | Where-Object { ($now - $f.Pending[$_]) -gt $TimeoutMs })
      foreach ($k in $expired) {
        $f.Pending.Remove($k)
        $f.Lost++
        $f.ConsecLost++
      }
    }

    $elapsed = $sw.Elapsed.TotalMilliseconds - $loopStart
    $sleep = $intervalMs - $elapsed
    if ($sleep -gt 1) { Start-Sleep -Milliseconds ([int]$sleep) }
  }
} finally {
  foreach ($f in $flows) { try { $f.Client.Close(); $f.Client.Dispose() } catch {} }
  try { $rows | Set-Content $csv -Encoding UTF8 } catch {}

  $lines = foreach ($f in $flows) {
    $arr = @($f.Rtts)
    $avg = if ($arr.Count) { [math]::Round(($arr | Measure-Object -Average).Average, 1) } else { 0 }
    $p99 = if ($arr.Count -gt 1) { $s2 = $arr | Sort-Object; [math]::Round($s2[[int][math]::Floor($s2.Count * 0.99)], 1) } else { 0 }
    $mx = if ($arr.Count) { [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    @"
  $($f.Name) (local port $($f.LocalPort) held for whole run)
    sent $($f.Sent)  recv $($f.Recv)  lost $($f.Lost)  ($([math]::Round(100.0*$f.Lost/[math]::Max(1,$f.Sent),2))%)
    rtt avg ${avg}ms  p99 ${p99}ms  max ${mx}ms
    outages (>=$BurstThreshold consecutive): $($f.Bursts.Count)
    NAT mapping: $($f.Mapped)   rebinds observed: $($f.MapChanges)
$(($f.Bursts | Select-Object -First 25 | ForEach-Object { "      {0}  {1} pkts (~{2}ms)" -f $_.Time.ToString('HH:mm:ss.fff'), $_.Count, $_.Ms }) -join "`n")
"@
  }

  $allBursts = @()
  foreach ($f in $flows) { foreach ($b in $f.Bursts) { $allBursts += [pscustomobject]@{ Time = $b.Time; Flow = $f.Name; Ms = $b.Ms } } }
  $sortedB = $allBursts | Sort-Object Time
  $simul = 0
  for ($i = 0; $i -lt $sortedB.Count; $i++) {
    for ($j = $i + 1; $j -lt $sortedB.Count; $j++) {
      if (($sortedB[$j].Time - $sortedB[$i].Time).TotalMilliseconds -lt 1500 -and $sortedB[$j].Flow -ne $sortedB[$i].Flow) { $simul++; break }
    }
  }

  $text = @"
Persistent UDP flow summary
Label:   $Label
Started: $($start.ToString('o'))
Elapsed: $([math]::Round(((Get-Date)-$start).TotalSeconds,1)) s
Rate:    $RateHz pkt/s per flow

$($lines -join "`n")

Outages hitting 2+ flows within 1.5s (true path outage, not server-side): $simul
Total outages across all flows: $($sortedB.Count)

Timeline of all outages:
$(($sortedB | Select-Object -First 60 | ForEach-Object { "  {0}  {1,-24} ~{2}ms" -f $_.Time.ToString('HH:mm:ss.fff'), $_.Flow, $_.Ms }) -join "`n")

CSV: $csv
"@
  Set-Content $sum $text -Encoding UTF8
  Write-Host ""
  Write-Host $text
}
