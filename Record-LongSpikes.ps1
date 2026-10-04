<#
.SYNOPSIS
  Headless 5-hour UDP spike recorder. Safe to leave running without a window.
#>
[CmdletBinding()]
param(
  [string[]]$Servers = @("stun.l.google.com:19302", "stun1.l.google.com:19302", "stun.cloudflare.com:3478"),
  [double]$DurationHours = 5,
  [int]$RateHz = 20,
  [int]$TimeoutMs = 1000,
  [int]$SpikeMs = 100,
  [int]$LargeSpikeMs = 200,
  [int]$ContextBeforeSec = 5,
  [int]$ContextAfterSec = 5,
  [string]$Label = "long5h",
  [string]$RunDir = ""
)

# Don't abort the 5h run on a single file I/O blip (viewer/AV locking live.json, etc.)
$ErrorActionPreference = "Continue"
try { (Get-Process -Id $PID).PriorityClass = "High" } catch {}

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

if (-not $RunDir) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $RunDir = Join-Path $PSScriptRoot ("logs\long-{0}-{1}" -f $Label, $stamp)
}
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$contextDir = Join-Path $RunDir "contexts"
New-Item -ItemType Directory -Force -Path $contextDir | Out-Null
$spikeCsv = Join-Path $RunDir "spikes.csv"
$sampleCsv = Join-Path $RunDir "samples.csv"
$clumpCsv = Join-Path $RunDir "clumps.csv"
$statusFile = Join-Path $RunDir "status.txt"
$liveFile = Join-Path $RunDir "live.json"
$hudFile = Join-Path $RunDir "hud.json"
$eventFile = Join-Path $RunDir "events.log"
$stopFile = Join-Path $RunDir "STOP"
$anchorFile = Join-Path $RunDir "cycle-anchor.txt"

"timestamp,flow,rtt_ms,large" | Set-Content $spikeCsv -Encoding UTF8
"timestamp,flow,rtt_ms,ok" | Set-Content $sampleCsv -Encoding UTF8
"start,end,duration_ms,max_rtt_ms,count,large" | Set-Content $clumpCsv -Encoding UTF8
Set-Content (Join-Path $RunDir "rundir.txt") $RunDir -Encoding UTF8

$flows = @()
foreach ($s in $Servers) {
  $p = $s -split ":"
  try {
    $addr = ([System.Net.Dns]::GetHostAddresses($p[0]) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1)
    if (-not $addr) { continue }
    $c = [System.Net.Sockets.UdpClient]::new(0)
    $c.Client.ReceiveTimeout = 1
    $c.Connect($addr, [int]$p[1])
    $flows += [pscustomobject]@{ Name = $p[0]; Client = $c; Pending = @{} }
  } catch {}
}
if ($flows.Count -eq 0) { throw "no STUN servers reachable" }

$durationSec = [int][math]::Round($DurationHours * 3600)
$intervalMs = [int](1000 / $RateHz)
$ringKeepMs = ($ContextBeforeSec + 1) * 1000
$ring = New-Object System.Collections.Generic.Queue[object]
$activeContexts = New-Object System.Collections.Generic.List[hashtable]
$recentSpikes = New-Object System.Collections.Generic.List[object]
$recentSamples = New-Object System.Collections.Generic.List[object]
$lastRtt = @{}
$openClump = $null
$clumpGapMs = 400
$cycleAnchor = $null

$start = Get-Date
$end = $start.AddSeconds($durationSec)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sent = 0; $slow = 0; $large = 0
$tick = 0
$sampleEvery = [math]::Max(1, [int]($RateHz / 2)) # denser samples for GUI (~10/s/flow)
$lastLive = [datetime]::MinValue
$lastHud = [datetime]::MinValue
$lastStatus = [datetime]::MinValue

function Close-Clump($clump) {
  if (-not $clump) { return }
  $dur = [math]::Round(($clump.End - $clump.Start).TotalMilliseconds, 1)
  Add-Content $clumpCsv ("{0},{1},{2},{3},{4},{5}" -f $clump.Start.ToString("o"), $clump.End.ToString("o"), $dur, $clump.Max, $clump.Count, [int]$clump.Large)
}

function Write-Live {
  $obj = [ordered]@{
    status = "recording"
    started = $start.ToString("o")
    end = $end.ToString("o")
    now = (Get-Date).ToString("o")
    elapsed_s = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    left_s = [math]::Round([math]::Max(0, ($end - (Get-Date)).TotalSeconds), 1)
    sent = $sent
    slow = $slow
    large = $large
    last_rtt = $lastRtt
    spikes = @($recentSpikes | Select-Object -Last 400 | ForEach-Object {
      [ordered]@{ t = $_.Time.ToString("o"); flow = $_.Flow; rtt = $_.Rtt; large = [bool]$_.Large }
    })
    samples = @($recentSamples | Select-Object -Last 1200 | ForEach-Object {
      [ordered]@{ t = $_.Time.ToString("o"); flow = $_.Flow; rtt = $_.Rtt }
    })
  }
  ($obj | ConvertTo-Json -Depth 6 -Compress) | Set-Content $liveFile -Encoding UTF8
}

$exitReason = "completed"
try {
  while ((Get-Date) -lt $end) {
    if (Test-Path $stopFile) { $exitReason = "stop-file"; break }
    try {
      $loopStart = $sw.Elapsed.TotalMilliseconds
      $now = Get-Date
      $tick++

      $doneCtx = @()
      foreach ($ctx in @($activeContexts)) {
        if ($now -ge $ctx.Until) { $doneCtx += $ctx; [void]$activeContexts.Remove($ctx) }
      }
      foreach ($ctx in $doneCtx) {
        try {
          $path = Join-Path $contextDir ("large-{0:yyyyMMdd-HHmmss-fff}-{1}.csv" -f $ctx.TriggerTime, ($ctx.Flow -replace '[^a-zA-Z0-9.-]', '_'))
          $lines = New-Object System.Collections.Generic.List[string]
          $lines.Add("timestamp,flow,rtt_ms,ok,phase")
          foreach ($r in $ctx.Before) { $lines.Add(("{0},{1},{2},{3},before" -f $r.Time.ToString("o"), $r.Flow, $r.Rtt, [int]$r.Ok)) }
          $lines.Add(("{0},{1},{2},1,trigger" -f $ctx.TriggerTime.ToString("o"), $ctx.Flow, $ctx.Rtt))
          foreach ($r in $ctx.After) { $lines.Add(("{0},{1},{2},{3},after" -f $r.Time.ToString("o"), $r.Flow, $r.Rtt, [int]$r.Ok)) }
          $lines | Set-Content $path -Encoding UTF8
          Add-Content $eventFile ("{0}  wrote context {1}" -f (Get-Date).ToString("HH:mm:ss"), (Split-Path $path -Leaf))
        } catch {
          Add-Content $eventFile ("{0}  context-write error: {1}" -f (Get-Date).ToString("HH:mm:ss"), $_.Exception.Message)
        }
      }

      foreach ($f in $flows) {
        try {
          $req = New-StunRequest
          [void]$f.Client.Send($req.Packet, 20)
          $f.Pending[$req.Tid] = $sw.Elapsed.TotalMilliseconds
          $sent++
        } catch {}

        while ($f.Client.Available -gt 0) {
          try {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $data = $f.Client.Receive([ref]$ep)
            $tid = Get-StunTid $data
            if (-not $tid -or -not $f.Pending.ContainsKey($tid)) { continue }
            $rtt = [math]::Round($sw.Elapsed.TotalMilliseconds - $f.Pending[$tid], 1)
            $f.Pending.Remove($tid)
            $lastRtt[$f.Name] = $rtt
            $sample = [pscustomobject]@{ Time = $now; Flow = $f.Name; Rtt = $rtt; Ok = $true }

            $ring.Enqueue($sample)
            while ($ring.Count -gt 0 -and (($now - $ring.Peek().Time).TotalMilliseconds -gt $ringKeepMs)) { [void]$ring.Dequeue() }
            foreach ($ctx in $activeContexts) { $ctx.After.Add($sample) }

            $wroteSample = $false
            if (($tick % $sampleEvery) -eq 0) {
              Add-Content $sampleCsv ("{0},{1},{2},1" -f $now.ToString("o"), $f.Name, $rtt)
              $recentSamples.Add($sample)
              while ($recentSamples.Count -gt 2500) { $recentSamples.RemoveAt(0) }
              $wroteSample = $true
            }

            if ($rtt -ge $SpikeMs) {
              $isLarge = $rtt -ge $LargeSpikeMs
              $slow++
              if ($isLarge) { $large++ }
              # Always keep samples.csv in sync with spike peaks (sampleEvery can skip these ticks).
              if (-not $wroteSample) {
                Add-Content $sampleCsv ("{0},{1},{2},1" -f $now.ToString("o"), $f.Name, $rtt)
                $recentSamples.Add($sample)
                while ($recentSamples.Count -gt 2500) { $recentSamples.RemoveAt(0) }
              }
              $spike = [pscustomobject]@{ Time = $now; Flow = $f.Name; Rtt = $rtt; Large = $isLarge }
              $recentSpikes.Add($spike)
              while ($recentSpikes.Count -gt 2000) { $recentSpikes.RemoveAt(0) }
              Add-Content $spikeCsv ("{0},{1},{2},{3}" -f $now.ToString("o"), $f.Name, $rtt, [int]$isLarge)
              Add-Content $eventFile ("{0}  {1}  {2}ms{3}" -f $now.ToString("HH:mm:ss.fff"), $f.Name, $rtt, $(if ($isLarge) { "  LARGE" } else { "" }))

              if ($openClump -and (($now - $openClump.End).TotalMilliseconds -le $clumpGapMs)) {
                $openClump.End = $now
                $openClump.Count++
                if ($rtt -gt $openClump.Max) { $openClump.Max = $rtt }
                if ($isLarge) { $openClump.Large = $true }
              } else {
                if ($openClump) { Close-Clump $openClump }
                $openClump = @{ Start = $now; End = $now; Max = $rtt; Count = 1; Large = $isLarge }
              }

              if ($isLarge -and -not $cycleAnchor) {
                $cycleAnchor = $now
                Set-Content $anchorFile $cycleAnchor.ToString("o") -Encoding UTF8
              }

              if ($isLarge) {
                $before = New-Object System.Collections.Generic.List[object]
                foreach ($r in $ring) { $before.Add($r) }
                $activeContexts.Add(@{
                  TriggerTime = $now
                  Flow = $f.Name
                  Rtt = $rtt
                  Until = $now.AddSeconds($ContextAfterSec)
                  Before = $before
                  After = (New-Object System.Collections.Generic.List[object])
                })
              }
            } else {
              if ($openClump -and (($now - $openClump.End).TotalMilliseconds -gt $clumpGapMs)) {
                Close-Clump $openClump
                $openClump = $null
              }
            }
          } catch { break }
        }

        $nowMs = $sw.Elapsed.TotalMilliseconds
        foreach ($k in @($f.Pending.Keys | Where-Object { ($nowMs - $f.Pending[$_]) -gt $TimeoutMs })) {
          $f.Pending.Remove($k)
        }
      }

      if (((Get-Date) - $lastLive).TotalMilliseconds -ge 500) {
        $lastLive = Get-Date
        try { Write-Live } catch {
          Add-Content $eventFile ("{0}  live-write error: {1}" -f (Get-Date).ToString("HH:mm:ss"), $_.Exception.Message)
        }
      }
      if (((Get-Date) - $lastHud).TotalMilliseconds -ge 250) {
        $lastHud = Get-Date
        try {
          $anchorStr = if ($cycleAnchor) { $cycleAnchor.ToString("o") } else { "" }
          $lastSpike = if ($recentSpikes.Count) { $recentSpikes[$recentSpikes.Count - 1].Time.ToString("o") } else { "" }
          (@{
            t = (Get-Date).ToString("o")
            status = "recording"
            sent = $sent
            slow = $slow
            large = $large
            left_s = [math]::Round([math]::Max(0, ($end - (Get-Date)).TotalSeconds), 1)
            cycle_anchor = $anchorStr
            last_spike = $lastSpike
            last_rtt = $lastRtt
          } | ConvertTo-Json -Compress) | Set-Content $hudFile -Encoding UTF8
        } catch {}
      }
      if (((Get-Date) - $lastStatus).TotalSeconds -ge 5) {
        $lastStatus = Get-Date
        try {
          Set-Content $statusFile @"
status=recording
started=$($start.ToString('o'))
elapsed_s=$([math]::Round(((Get-Date)-$start).TotalSeconds,1))
left_s=$([math]::Round([math]::Max(0,($end-(Get-Date)).TotalSeconds),1))
sent=$sent
slow=$slow
large=$large
rundir=$RunDir
"@ -Encoding UTF8
        } catch {}
      }

      $sleep = $intervalMs - ($sw.Elapsed.TotalMilliseconds - $loopStart)
      if ($sleep -gt 1) { Start-Sleep -Milliseconds ([int]$sleep) }
    } catch {
      # Survive transient errors; do not end the 5h capture.
      try { Add-Content $eventFile ("{0}  loop error (continuing): {1}" -f (Get-Date).ToString("HH:mm:ss"), $_.Exception.Message) } catch {}
      Start-Sleep -Milliseconds 50
    }
  }
} catch {
  $exitReason = "fatal: $($_.Exception.Message)"
  try { Add-Content $eventFile ("{0}  fatal: {1}" -f (Get-Date).ToString("HH:mm:ss"), $_.Exception.Message) } catch {}
} finally {
  if ($openClump) { try { Close-Clump $openClump } catch {} }
  foreach ($f in $flows) { try { $f.Client.Close(); $f.Client.Dispose() } catch {} }
  try { Add-Content $eventFile ("{0}  recorder exit: {1}" -f (Get-Date).ToString("HH:mm:ss"), $exitReason) } catch {}
  Set-Content $statusFile @"
status=finished
started=$($start.ToString('o'))
elapsed_s=$([math]::Round(((Get-Date)-$start).TotalSeconds,1))
exit=$exitReason
sent=$sent
slow=$slow
large=$large
rundir=$RunDir
"@ -Encoding UTF8
  $live = Get-Content $liveFile -Raw -ErrorAction SilentlyContinue
  if ($live) {
    $live = $live -replace '"status":"recording"', '"status":"finished"'
    Set-Content $liveFile $live -Encoding UTF8
  }
}
