<#
.SYNOPSIS
  Long-running UDP spike recorder with a live WPF timeline GUI.

.DESCRIPTION
  Holds persistent STUN flows, logs every slow packet, and when a large spike
  occurs writes a high-resolution context dump of the seconds before and after.
  A simple timeline window updates while the run is in progress.
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
  [int]$TimelineMinutes = 15,
  [string]$Label = "long5h"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

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

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $PSScriptRoot ("logs\long-{0}-{1}" -f $Label, $stamp)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$spikeCsv = Join-Path $runDir "spikes.csv"
$sampleCsv = Join-Path $runDir "samples.csv"
$statusFile = Join-Path $runDir "status.txt"
$contextDir = Join-Path $runDir "contexts"
New-Item -ItemType Directory -Force -Path $contextDir | Out-Null

"timestamp,flow,rtt_ms,large" | Set-Content $spikeCsv -Encoding UTF8
"timestamp,flow,rtt_ms,ok" | Set-Content $sampleCsv -Encoding UTF8

$state = [hashtable]::Synchronized(@{
  Running = $true
  Started = $null
  End = $null
  Sent = 0
  Slow = 0
  Large = 0
  LastRtt = @{}
  Spikes = (New-Object System.Collections.Generic.List[object])
  Samples = (New-Object System.Collections.Generic.List[object])
  Events = (New-Object System.Collections.Generic.List[string])
  Status = "starting"
  Error = ""
})

# Ring buffer of recent samples for pre-spike context
$ring = [System.Collections.Generic.Queue[object]]::new()
$ringLock = [object]::new()
$activeContexts = [System.Collections.Generic.List[hashtable]]::new()
$ctxLock = [object]::new()

$durationSec = [int]([math]::Round($DurationHours * 3600))
$intervalMs = [int](1000 / $RateHz)
$ringKeepMs = ($ContextBeforeSec + 1) * 1000

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network spike timeline" Width="1100" Height="640"
        Background="#111418" Foreground="#E8EEF5">
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock x:Name="TitleText" FontSize="20" FontWeight="SemiBold" Text="Recording..." />
      <TextBlock x:Name="StatsText" Margin="0,6,0,0" FontFamily="Consolas" FontSize="13" TextWrapping="Wrap" />
      <TextBlock x:Name="HintText" Margin="0,4,0,0" Foreground="#9AA7B5" FontSize="12"
                 Text="Red = large spike (>=200ms). Orange = slow (>=100ms). Grey line = recent RTT. Context dumps are written under logs\long-..." />
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Height="150" BorderBrush="#2A3340" BorderThickness="1" Margin="0,10,0,0" Padding="8">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBlock x:Name="EventText" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" />
      </ScrollViewer>
    </Border>
    <Border BorderBrush="#2A3340" BorderThickness="1" Background="#0B0E12">
      <Canvas x:Name="Timeline" ClipToBounds="True" />
    </Border>
  </DockPanel>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$timeline = $window.FindName("Timeline")
$titleText = $window.FindName("TitleText")
$statsText = $window.FindName("StatsText")
$eventText = $window.FindName("EventText")

$probeScript = {
  param($Servers, $RateHz, $TimeoutMs, $SpikeMs, $LargeSpikeMs, $ContextAfterSec, $durationSec, $intervalMs, $ringKeepMs, $state, $ring, $ringLock, $activeContexts, $ctxLock, $spikeCsv, $sampleCsv, $statusFile, $contextDir)

  $ErrorActionPreference = "Stop"
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
  if ($flows.Count -eq 0) {
    $state.Error = "no STUN servers reachable"
    $state.Running = $false
    return
  }

  $start = Get-Date
  $end = $start.AddSeconds($durationSec)
  $state.Started = $start
  $state.End = $end
  $state.Status = "recording"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $sampleEvery = [math]::Max(1, [int]($RateHz / 4)) # ~4 sample writes/sec/flow
  $tick = 0
  $lastStatusWrite = [datetime]::MinValue

  try {
    while ($state.Running -and ((Get-Date) -lt $end)) {
      $loopStart = $sw.Elapsed.TotalMilliseconds
      $now = Get-Date
      $tick++

      # close finished post-spike contexts
      $doneCtx = @()
      [System.Threading.Monitor]::Enter($ctxLock)
      try {
        foreach ($ctx in @($activeContexts)) {
          if ($now -ge $ctx.Until) { $doneCtx += $ctx; [void]$activeContexts.Remove($ctx) }
        }
      } finally { [System.Threading.Monitor]::Exit($ctxLock) }
      foreach ($ctx in $doneCtx) {
        $path = Join-Path $contextDir ("large-{0:yyyyMMdd-HHmmss-fff}-{1}.csv" -f $ctx.TriggerTime, ($ctx.Flow -replace '[^a-zA-Z0-9.-]', '_'))
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("timestamp,flow,rtt_ms,ok,phase")
        foreach ($r in $ctx.Before) { $lines.Add(("{0},{1},{2},{3},before" -f $r.Time.ToString("o"), $r.Flow, $r.Rtt, [int]$r.Ok)) }
        $lines.Add(("{0},{1},{2},1,trigger" -f $ctx.TriggerTime.ToString("o"), $ctx.Flow, $ctx.Rtt))
        foreach ($r in $ctx.After) { $lines.Add(("{0},{1},{2},{3},after" -f $r.Time.ToString("o"), $r.Flow, $r.Rtt, [int]$r.Ok)) }
        $lines | Set-Content $path -Encoding UTF8
        $state.Events.Insert(0, ("{0}  wrote context {1}" -f (Get-Date).ToString("HH:mm:ss"), (Split-Path $path -Leaf)))
      }

      foreach ($f in $flows) {
        try {
          $req = New-StunRequest
          [void]$f.Client.Send($req.Packet, 20)
          $f.Pending[$req.Tid] = $sw.Elapsed.TotalMilliseconds
          $state.Sent++
        } catch {}

        while ($f.Client.Available -gt 0) {
          try {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $data = $f.Client.Receive([ref]$ep)
            $tid = Get-StunTid $data
            if (-not $tid -or -not $f.Pending.ContainsKey($tid)) { continue }
            $rtt = [math]::Round($sw.Elapsed.TotalMilliseconds - $f.Pending[$tid], 1)
            $f.Pending.Remove($tid)
            $state.LastRtt[$f.Name] = $rtt
            $sample = [pscustomobject]@{ Time = $now; Flow = $f.Name; Rtt = $rtt; Ok = $true }

            [System.Threading.Monitor]::Enter($ringLock)
            try {
              $ring.Enqueue($sample)
              while ($ring.Count -gt 0 -and (($now - $ring.Peek().Time).TotalMilliseconds -gt $ringKeepMs)) { [void]$ring.Dequeue() }
            } finally { [System.Threading.Monitor]::Exit($ringLock) }

            [System.Threading.Monitor]::Enter($ctxLock)
            try {
              foreach ($ctx in $activeContexts) { $ctx.After.Add($sample) }
            } finally { [System.Threading.Monitor]::Exit($ctxLock) }

            if (($tick % $sampleEvery) -eq 0) {
              Add-Content $sampleCsv ("{0},{1},{2},1" -f $now.ToString("o"), $f.Name, $rtt)
              $state.Samples.Add($sample)
              while ($state.Samples.Count -gt 20000) { $state.Samples.RemoveAt(0) }
            }

            if ($rtt -ge $SpikeMs) {
              $large = $rtt -ge $LargeSpikeMs
              $state.Slow++
              if ($large) { $state.Large++ }
              $spike = [pscustomobject]@{ Time = $now; Flow = $f.Name; Rtt = $rtt; Large = $large }
              $state.Spikes.Add($spike)
              while ($state.Spikes.Count -gt 5000) { $state.Spikes.RemoveAt(0) }
              Add-Content $spikeCsv ("{0},{1},{2},{3}" -f $now.ToString("o"), $f.Name, $rtt, [int]$large)
              $state.Events.Insert(0, ("{0}  {1}  {2}ms{3}" -f $now.ToString("HH:mm:ss.fff"), $f.Name, $rtt, $(if ($large) { "  LARGE" } else { "" })))
              while ($state.Events.Count -gt 200) { $state.Events.RemoveAt($state.Events.Count - 1) }

              if ($large) {
                $before = New-Object System.Collections.Generic.List[object]
                [System.Threading.Monitor]::Enter($ringLock)
                try { foreach ($r in $ring) { $before.Add($r) } }
                finally { [System.Threading.Monitor]::Exit($ringLock) }
                $ctx = @{
                  TriggerTime = $now
                  Flow = $f.Name
                  Rtt = $rtt
                  Until = $now.AddSeconds($ContextAfterSec)
                  Before = $before
                  After = (New-Object System.Collections.Generic.List[object])
                }
                [System.Threading.Monitor]::Enter($ctxLock)
                try { $activeContexts.Add($ctx) }
                finally { [System.Threading.Monitor]::Exit($ctxLock) }
              }
            }
          } catch { break }
        }

        $nowMs = $sw.Elapsed.TotalMilliseconds
        foreach ($k in @($f.Pending.Keys | Where-Object { ($nowMs - $f.Pending[$_]) -gt $TimeoutMs })) {
          $f.Pending.Remove($k)
        }
      }

      if (((Get-Date) - $lastStatusWrite).TotalSeconds -ge 5) {
        $lastStatusWrite = Get-Date
        $left = [math]::Max(0, ($end - (Get-Date)).TotalSeconds)
        $txt = @"
started=$($start.ToString('o'))
elapsed_s=$([math]::Round(((Get-Date)-$start).TotalSeconds,1))
left_s=$([math]::Round($left,1))
sent=$($state.Sent)
slow=$($state.Slow)
large=$($state.Large)
status=$($state.Status)
"@
        Set-Content $statusFile $txt -Encoding UTF8
      }

      $sleep = $intervalMs - ($sw.Elapsed.TotalMilliseconds - $loopStart)
      if ($sleep -gt 1) { Start-Sleep -Milliseconds ([int]$sleep) }
    }
  } catch {
    $state.Error = $_.Exception.Message
  } finally {
    foreach ($f in $flows) { try { $f.Client.Close(); $f.Client.Dispose() } catch {} }
    $state.Status = $(if ($state.Error) { "error" } else { "finished" })
    $state.Running = $false
    Set-Content $statusFile ("status=$($state.Status)`nerror=$($state.Error)`nsent=$($state.Sent)`nslow=$($state.Slow)`nlarge=$($state.Large)") -Encoding UTF8
  }
}

$ps = [powershell]::Create()
[void]$ps.AddScript($probeScript).AddArgument($Servers).AddArgument($RateHz).AddArgument($TimeoutMs).AddArgument($SpikeMs).AddArgument($LargeSpikeMs).AddArgument($ContextAfterSec).AddArgument($durationSec).AddArgument($intervalMs).AddArgument($ringKeepMs).AddArgument($state).AddArgument($ring).AddArgument($ringLock).AddArgument($activeContexts).AddArgument($ctxLock).AddArgument($spikeCsv).AddArgument($sampleCsv).AddArgument($statusFile).AddArgument($contextDir)
$handle = $ps.BeginInvoke()

function Draw-Timeline {
  $timeline.Children.Clear()
  $w = [math]::Max(100.0, $timeline.ActualWidth)
  $h = [math]::Max(100.0, $timeline.ActualHeight)
  if ($w -lt 50 -or $h -lt 50) { return }

  $now = Get-Date
  $windowStart = $now.AddMinutes(-$TimelineMinutes)
  $maxRtt = 400.0

  # grid
  foreach ($ms in @(0, 63, 100, 200, 300, 400)) {
    $y = $h - 20 - (($ms / $maxRtt) * ($h - 40))
    $line = New-Object System.Windows.Shapes.Line
    $line.X1 = 40; $line.X2 = $w - 10; $line.Y1 = $y; $line.Y2 = $y
    $line.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#243041")
    $line.StrokeThickness = 1
    [void]$timeline.Children.Add($line)
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = "${ms}ms"
    $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6B7C8F")
    $lbl.FontSize = 10
    [System.Windows.Controls.Canvas]::SetLeft($lbl, 2)
    [System.Windows.Controls.Canvas]::SetTop($lbl, $y - 7)
    [void]$timeline.Children.Add($lbl)
  }

  $samples = @($state.Samples | Where-Object { $_.Time -ge $windowStart })
  $spikes = @($state.Spikes | Where-Object { $_.Time -ge $windowStart })

  # sample polyline (max of flows per ~200ms bucket for clarity)
  if ($samples.Count -gt 1) {
    $pts = New-Object System.Windows.Media.PointCollection
    $bucketMs = 200
    $groups = $samples | Group-Object { [int]([math]::Floor(($_.Time - $windowStart).TotalMilliseconds / $bucketMs)) }
    foreach ($g in ($groups | Sort-Object { [int]$_.Name })) {
      $max = ($g.Group | Measure-Object -Property Rtt -Maximum).Maximum
      $tMid = $windowStart.AddMilliseconds(([int]$g.Name + 0.5) * $bucketMs)
      $x = 40 + ((($tMid - $windowStart).TotalMinutes / $TimelineMinutes) * ($w - 50))
      $y = $h - 20 - (([math]::Min($maxRtt, $max) / $maxRtt) * ($h - 40))
      $pts.Add([System.Windows.Point]::new($x, $y))
    }
    if ($pts.Count -gt 1) {
      $poly = New-Object System.Windows.Shapes.Polyline
      $poly.Points = $pts
      $poly.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#4A90A4")
      $poly.StrokeThickness = 1.2
      $poly.Opacity = 0.85
      [void]$timeline.Children.Add($poly)
    }
  }

  foreach ($s in $spikes) {
    $x = 40 + ((($s.Time - $windowStart).TotalMinutes / $TimelineMinutes) * ($w - 50))
    $y = $h - 20 - (([math]::Min($maxRtt, $s.Rtt) / $maxRtt) * ($h - 40))
    $ell = New-Object System.Windows.Shapes.Ellipse
    $ell.Width = $(if ($s.Large) { 8 } else { 5 })
    $ell.Height = $ell.Width
    $ell.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($s.Large) { "#E85D4C" } else { "#E0A14A" }))
    [System.Windows.Controls.Canvas]::SetLeft($ell, $x - $ell.Width / 2)
    [System.Windows.Controls.Canvas]::SetTop($ell, $y - $ell.Height / 2)
    [void]$timeline.Children.Add($ell)

    if ($s.Large) {
      $mark = New-Object System.Windows.Shapes.Line
      $mark.X1 = $x; $mark.X2 = $x; $mark.Y1 = 10; $mark.Y2 = $h - 10
      $mark.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E85D4C")
      $mark.StrokeThickness = 1
      $mark.Opacity = 0.25
      [void]$timeline.Children.Add($mark)
    }
  }

  # time axis labels
  for ($m = 0; $m -le $TimelineMinutes; $m += [math]::Max(1, [int]($TimelineMinutes / 5))) {
    $t = $windowStart.AddMinutes($m)
    $x = 40 + (($m / $TimelineMinutes) * ($w - 50))
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $t.ToString("HH:mm:ss")
    $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6B7C8F")
    $lbl.FontSize = 10
    [System.Windows.Controls.Canvas]::SetLeft($lbl, $x - 20)
    [System.Windows.Controls.Canvas]::SetTop($lbl, $h - 16)
    [void]$timeline.Children.Add($lbl)
  }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
  $elapsed = if ($state.Started) { ((Get-Date) - $state.Started).TotalSeconds } else { 0 }
  $left = if ($state.End) { [math]::Max(0, ($state.End - (Get-Date)).TotalSeconds) } else { $durationSec }
  $titleText.Text = if ($state.Running) {
    "Recording  |  {0:n1} h left  |  {1}" -f ($left / 3600.0), $runDir
  } else {
    "Finished  |  {0}  |  {1}" -f $state.Status, $runDir
  }
  $rttBits = @($state.LastRtt.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}={1}ms" -f ($_.Key -replace '\.l\.google\.com','-g' -replace 'stun\.cloudflare\.com','cf'), $_.Value }) -join "  "
  $statsText.Text = ("elapsed {0:hh\:mm\:ss}   sent {1}   slow(>=100) {2}   large(>=200) {3}   live {4}" -f ([TimeSpan]::FromSeconds($elapsed)), $state.Sent, $state.Slow, $state.Large, $rttBits)
  if ($state.Error) { $statsText.Text += "   ERROR: $($state.Error)" }
  $eventText.Text = (@($state.Events | Select-Object -First 40) -join "`r`n")
  Draw-Timeline
  if (-not $state.Running -and $ps.InvocationStateInfo.State -ne "Running") {
    # keep window open after finish
  }
})
$timer.Start()

$window.Add_Closing({
  $state.Running = $false
  $timer.Stop()
  try { $ps.EndInvoke($handle) } catch {}
  $ps.Dispose()
})

$titleText.Text = "Starting recorder..."
$statsText.Text = "Writing to $runDir"
[void]$window.ShowDialog()
