<#
.SYNOPSIS
  High-frequency network microstutter detector (ICMP + TCP + NIC counters).

.DESCRIPTION
  Probes gateway/external hosts and watches Realtek NIC discard/error counters.
  Flags stutter on packet loss, relative RTT spikes, elevated jitter, or rising
  NIC discards/errors. Logs CSV for A/B comparisons.

.EXAMPLE
  .\Detect-NetStutter.ps1 -DurationSec 120 -Label baseline

.EXAMPLE
  .\Detect-NetStutter.ps1 -DurationSec 0 -Label live   # until Ctrl+C
#>
[CmdletBinding()]
param(
  [string]$Gateway = "",
  [string]$External = "1.1.1.1",
  [string]$TcpHost = "1.1.1.1",
  [int]$TcpPort = 443,
  [string]$Adapter = "Ethernet",
  [int]$IntervalMs = 200,
  [int]$TimeoutMs = 1000,
  [int]$WindowSize = 50,
  [double]$SpikeDeltaMs = 20,
  [double]$GwSpikeAbsMs = 15,
  [double]$JitterAlertMs = 8,
  [double]$LossAlertPct = 2,
  [int]$WarmupSamples = 8,
  [int]$DurationSec = 0,
  [string]$Label = "live",
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

function Get-DefaultGateway {
  $r = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1
  if (-not $r) { throw "No default gateway found." }
  return $r.NextHop
}

function New-Rolling {
  param([int]$Size)
  return [pscustomobject]@{
    Size   = $Size
    Values = New-Object System.Collections.Generic.Queue[double]
  }
}

function Add-Sample {
  param($Roll, [nullable[double]]$RttMs, [bool]$Lost)
  $val = if ($Lost -or $null -eq $RttMs) { -1.0 } else { [double]$RttMs }
  $Roll.Values.Enqueue($val)
  while ($Roll.Values.Count -gt $Roll.Size) { [void]$Roll.Values.Dequeue() }
}

function Get-WindowStats {
  param($Roll)
  $ok = @($Roll.Values | Where-Object { $_ -ge 0 })
  $winTotal = $Roll.Values.Count
  $winLost = @($Roll.Values | Where-Object { $_ -lt 0 }).Count
  $lossPct = if ($winTotal -gt 0) { 100.0 * $winLost / $winTotal } else { 0 }
  $avg = if ($ok.Count) { ($ok | Measure-Object -Average).Average } else { $null }
  $median = $null
  if ($ok.Count) {
    $sorted = $ok | Sort-Object
    $mid = [int]([math]::Floor(($sorted.Count - 1) / 2))
    if (($sorted.Count % 2) -eq 0 -and $sorted.Count -gt 1) {
      $median = ($sorted[$mid] + $sorted[$mid + 1]) / 2.0
    } else {
      $median = $sorted[$mid]
    }
  }
  $jitter = $null
  if ($ok.Count -ge 2 -and $null -ne $avg) {
    $sum = 0.0
    foreach ($v in $ok) { $sum += [math]::Abs($v - $avg) }
    $jitter = $sum / $ok.Count
  }
  $max = if ($ok.Count) { ($ok | Measure-Object -Maximum).Maximum } else { $null }
  return [pscustomobject]@{
    LossPct = [math]::Round($lossPct, 1)
    AvgMs   = if ($null -ne $avg) { [math]::Round($avg, 1) } else { $null }
    Median  = if ($null -ne $median) { [math]::Round($median, 1) } else { $null }
    Jitter  = if ($null -ne $jitter) { [math]::Round($jitter, 1) } else { $null }
    MaxMs   = if ($null -ne $max) { [math]::Round($max, 1) } else { $null }
    Samples = $winTotal
    Ok      = $ok.Count
  }
}

function Test-RelativeSpike {
  param(
    $Stats,
    [nullable[double]]$Ms,
    [bool]$Ok,
    [double]$DeltaMs,
    [double]$AbsFloorMs = 0
  )
  if (-not $Ok -or $null -eq $Ms) { return $false }
  if ($AbsFloorMs -gt 0 -and $Ms -ge $AbsFloorMs) { return $true }
  if ($null -eq $Stats.Median) { return $false }
  return ($Ms - $Stats.Median) -ge $DeltaMs
}

function Test-IcmpOnce {
  param([string]$Target, [int]$Timeout)
  $ping = [System.Net.NetworkInformation.Ping]::new()
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $reply = $ping.Send($Target, $Timeout)
    $sw.Stop()
    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
      $ms = [double]$reply.RoundtripTime
      if ($ms -le 0) { $ms = [math]::Max(0.1, $sw.Elapsed.TotalMilliseconds) }
      return [pscustomobject]@{ Ok = $true; Ms = $ms; Status = "Success" }
    }
    return [pscustomobject]@{ Ok = $false; Ms = $null; Status = [string]$reply.Status }
  } catch {
    return [pscustomobject]@{ Ok = $false; Ms = $null; Status = $_.Exception.Message }
  } finally {
    $ping.Dispose()
  }
}

function Test-TcpOnce {
  param([string]$Target, [int]$Port, [int]$Timeout)
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $iar = $client.BeginConnect($Target, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($Timeout)
    $sw.Stop()
    if (-not $ok) {
      return [pscustomobject]@{ Ok = $false; Ms = $null; Status = "Timeout" }
    }
    try { $client.EndConnect($iar) } catch {
      return [pscustomobject]@{ Ok = $false; Ms = $null; Status = "ConnectFail" }
    }
    return [pscustomobject]@{ Ok = $true; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Status = "Success" }
  } catch {
    return [pscustomobject]@{ Ok = $false; Ms = $null; Status = $_.Exception.Message }
  } finally {
    $client.Close()
    $client.Dispose()
  }
}

function Get-NicSnap {
  param([string]$Name)
  $n = Get-NetAdapterStatistics -Name $Name -ErrorAction SilentlyContinue
  if (-not $n) { return $null }
  return [pscustomobject]@{
    RxDiscard = [int64]$n.ReceivedDiscardedPackets
    RxError   = [int64]$n.ReceivedPacketErrors
    TxDiscard = [int64]$n.OutboundDiscardedPackets
    TxError   = [int64]$n.OutboundPacketErrors
    RxBytes   = [int64]$n.ReceivedBytes
    TxBytes   = [int64]$n.SentBytes
  }
}

function Format-Ms([nullable[double]]$Ms, [bool]$Ok) {
  if (-not $Ok) { return " LOSS" }
  return ("{0,5:N1}" -f $Ms)
}

if (-not $Gateway) { $Gateway = Get-DefaultGateway }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "logs" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $OutDir ("stutter-{0}-{1}.csv" -f $Label, $stamp)
$summaryPath = Join-Path $OutDir ("summary-{0}-{1}.txt" -f $Label, $stamp)

$gwRoll = New-Rolling -Size $WindowSize
$extRoll = New-Rolling -Size $WindowSize
$tcpRoll = New-Rolling -Size $WindowSize

$events = New-Object System.Collections.Generic.List[object]
$stutterBursts = 0
$inStutter = $false
$start = Get-Date
$end = if ($DurationSec -gt 0) { $start.AddSeconds($DurationSec) } else { [datetime]::MaxValue }
$prevNic = Get-NicSnap -Name $Adapter

"timestamp,label,gw_ok,gw_ms,ext_ok,ext_ms,tcp_ok,tcp_ms,gw_loss_pct,gw_jitter_ms,ext_loss_pct,ext_jitter_ms,tcp_loss_pct,tcp_jitter_ms,rx_disc_delta,rx_err_delta,tx_disc_delta,tx_err_delta,stutter,reason" |
  Set-Content -Path $csvPath -Encoding UTF8

Write-Host ""
Write-Host "=== Net stutter detector ===" -ForegroundColor Cyan
Write-Host ("Label: {0}" -f $Label)
Write-Host ("Adapter: {0} | Gateway: {1}" -f $Adapter, $Gateway)
Write-Host ("External ICMP: {0} | TCP: {1}:{2}" -f $External, $TcpHost, $TcpPort)
Write-Host ("Interval: {0}ms | Timeout: {1}ms | Window: {2} | Warmup: {3}" -f $IntervalMs, $TimeoutMs, $WindowSize, $WarmupSamples)
Write-Host ("Alerts: relative spike>+{0}ms | gateway abs>={1}ms | jitter>{2}ms | loss>{3}% | NIC discard/error deltas" -f `
  $SpikeDeltaMs, $GwSpikeAbsMs, $JitterAlertMs, $LossAlertPct)
Write-Host ("CSV: {0}" -f $csvPath)
if ($DurationSec -gt 0) { Write-Host ("Duration: {0}s" -f $DurationSec) } else { Write-Host "Duration: until Ctrl+C" }
Write-Host "Tip: leave Deadlock/Discord open so traffic matches real stutter conditions."
Write-Host ""

$probe = 0
$lifetimeLostGw = 0; $lifetimeTotalGw = 0
$lifetimeLostExt = 0; $lifetimeTotalExt = 0
$lifetimeLostTcp = 0; $lifetimeTotalTcp = 0
$nicEventCount = 0
$spikeCount = 0

try {
  while ((Get-Date) -lt $end) {
    $probe++
    $ts = Get-Date
    $gw = Test-IcmpOnce -Target $Gateway -Timeout $TimeoutMs
    $ext = Test-IcmpOnce -Target $External -Timeout $TimeoutMs
    $tcp = Test-TcpOnce -Target $TcpHost -Port $TcpPort -Timeout $TimeoutMs

    Add-Sample -Roll $gwRoll -RttMs $gw.Ms -Lost (-not $gw.Ok)
    Add-Sample -Roll $extRoll -RttMs $ext.Ms -Lost (-not $ext.Ok)
    Add-Sample -Roll $tcpRoll -RttMs $tcp.Ms -Lost (-not $tcp.Ok)

    $lifetimeTotalGw++; if (-not $gw.Ok) { $lifetimeLostGw++ }
    $lifetimeTotalExt++; if (-not $ext.Ok) { $lifetimeLostExt++ }
    $lifetimeTotalTcp++; if (-not $tcp.Ok) { $lifetimeLostTcp++ }

    $gs = Get-WindowStats $gwRoll
    $es = Get-WindowStats $extRoll
    $tsStats = Get-WindowStats $tcpRoll

    $nic = Get-NicSnap -Name $Adapter
    $rxDiscDelta = 0; $rxErrDelta = 0; $txDiscDelta = 0; $txErrDelta = 0
    if ($nic -and $prevNic) {
      $rxDiscDelta = [int64]($nic.RxDiscard - $prevNic.RxDiscard)
      $rxErrDelta  = [int64]($nic.RxError - $prevNic.RxError)
      $txDiscDelta = [int64]($nic.TxDiscard - $prevNic.TxDiscard)
      $txErrDelta  = [int64]($nic.TxError - $prevNic.TxError)
    }
    if ($nic) { $prevNic = $nic }

    $warm = $probe -ge $WarmupSamples
    $reasons = New-Object System.Collections.Generic.List[string]

    if (-not $gw.Ok) { $reasons.Add("gw-loss") }
    if (-not $ext.Ok) { $reasons.Add("ext-loss") }
    if (-not $tcp.Ok) { $reasons.Add("tcp-loss") }

    if ($warm) {
      if (Test-RelativeSpike -Stats $gs -Ms $gw.Ms -Ok $gw.Ok -DeltaMs $SpikeDeltaMs -AbsFloorMs $GwSpikeAbsMs) {
        $reasons.Add("gw-spike"); $spikeCount++
      }
      if (Test-RelativeSpike -Stats $es -Ms $ext.Ms -Ok $ext.Ok -DeltaMs $SpikeDeltaMs) {
        $reasons.Add("ext-spike"); $spikeCount++
      }
      if (Test-RelativeSpike -Stats $tsStats -Ms $tcp.Ms -Ok $tcp.Ok -DeltaMs $SpikeDeltaMs) {
        $reasons.Add("tcp-spike"); $spikeCount++
      }
      if ($gs.LossPct -ge $LossAlertPct) { $reasons.Add("gw-win-loss") }
      if ($es.LossPct -ge $LossAlertPct) { $reasons.Add("ext-win-loss") }
      if ($tsStats.LossPct -ge $LossAlertPct) { $reasons.Add("tcp-win-loss") }
      if ($null -ne $gs.Jitter -and $gs.Jitter -ge $JitterAlertMs) { $reasons.Add("gw-jitter") }
      if ($null -ne $es.Jitter -and $es.Jitter -ge $JitterAlertMs) { $reasons.Add("ext-jitter") }
      if ($null -ne $tsStats.Jitter -and $tsStats.Jitter -ge $JitterAlertMs) { $reasons.Add("tcp-jitter") }
    }

    if (($rxDiscDelta + $rxErrDelta + $txDiscDelta + $txErrDelta) -gt 0) {
      $reasons.Add("nic-counters")
      $nicEventCount++
    }

    $stutterNow = $reasons.Count -gt 0
    $reasonTxt = if ($reasons.Count) { ($reasons -join "|") } else { "" }

    if ($stutterNow -and -not $inStutter) {
      $inStutter = $true
      $stutterBursts++
      $events.Add([pscustomobject]@{
        Time = $ts; Reason = $reasonTxt; GwMs = $gw.Ms; ExtMs = $ext.Ms; TcpMs = $tcp.Ms
      })
      Write-Host ""
      Write-Host ("[{0}] STUTTER  reason={1}  gw={2}  ext={3}  tcp={4}  nic dRx/eRx/dTx/eTx={5}/{6}/{7}/{8}" -f `
        $ts.ToString("HH:mm:ss.fff"), $reasonTxt,
        $(if ($gw.Ok) { "{0:N1}ms" -f $gw.Ms } else { "LOSS" }),
        $(if ($ext.Ok) { "{0:N1}ms" -f $ext.Ms } else { "LOSS" }),
        $(if ($tcp.Ok) { "{0:N1}ms" -f $tcp.Ms } else { "LOSS" }),
        $rxDiscDelta, $rxErrDelta, $txDiscDelta, $txErrDelta
      ) -ForegroundColor Red
      try { [console]::Beep(880, 80) } catch {}
    } elseif (-not $stutterNow) {
      $inStutter = $false
    }

    $line = "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16},{17},{18},{19}" -f `
      $ts.ToString("o"), $Label,
      ([int]$gw.Ok), $gw.Ms, ([int]$ext.Ok), $ext.Ms, ([int]$tcp.Ok), $tcp.Ms,
      $gs.LossPct, $gs.Jitter, $es.LossPct, $es.Jitter, $tsStats.LossPct, $tsStats.Jitter,
      $rxDiscDelta, $rxErrDelta, $txDiscDelta, $txErrDelta,
      ([int]$stutterNow), $reasonTxt
    Add-Content -Path $csvPath -Value $line

    if (($probe % 5) -eq 0) {
      $color = if ($stutterNow) { "Red" } else { "Green" }
      Write-Host ("[{0}] gw {1}  ext {2}  tcp {3} | loss {4,4}%/{5,4}%/{6,4}%  jit {7}/{8}/{9} | nic+{10} bursts {11}" -f `
        $ts.ToString("HH:mm:ss"),
        (Format-Ms $gw.Ms $gw.Ok), (Format-Ms $ext.Ms $ext.Ok), (Format-Ms $tcp.Ms $tcp.Ok),
        $gs.LossPct, $es.LossPct, $tsStats.LossPct,
        $gs.Jitter, $es.Jitter, $tsStats.Jitter,
        ($rxDiscDelta + $rxErrDelta + $txDiscDelta + $txErrDelta),
        $stutterBursts
      ) -ForegroundColor $color
    }

    Start-Sleep -Milliseconds $IntervalMs
  }
} finally {
  $elapsed = ((Get-Date) - $start).TotalSeconds
  $summary = @"
Net stutter summary
Label:          $Label
Started:        $($start.ToString("o"))
ElapsedSec:     $([math]::Round($elapsed, 1))
Adapter:        $Adapter
Gateway:        $Gateway
External:       $External
TCP:            ${TcpHost}:$TcpPort

Lifetime loss %:    gw=$([math]::Round(100.0*$lifetimeLostGw/[math]::Max(1,$lifetimeTotalGw),2))  ext=$([math]::Round(100.0*$lifetimeLostExt/[math]::Max(1,$lifetimeTotalExt),2))  tcp=$([math]::Round(100.0*$lifetimeLostTcp/[math]::Max(1,$lifetimeTotalTcp),2))
Relative spikes: $spikeCount
NIC counter hits: $nicEventCount
Stutter bursts: $stutterBursts
CSV:            $csvPath

Recent events:
$(($events | Select-Object -Last 25 | ForEach-Object { "  {0}  {1}  gw={2} ext={3} tcp={4}" -f $_.Time.ToString("HH:mm:ss.fff"), $_.Reason, $_.GwMs, $_.ExtMs, $_.TcpMs }) -join "`n")
"@
  Set-Content -Path $summaryPath -Value $summary -Encoding UTF8
  Write-Host ""
  Write-Host $summary
  Write-Host ("Summary written: {0}" -f $summaryPath) -ForegroundColor Cyan
}
