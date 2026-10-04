<#
.SYNOPSIS
  View-only spike timeline: ~5 minute window, spike markers only.
  Paints to a frozen bitmap (no per-marker Shape tree) so WPF stays responsive.
#>
[CmdletBinding()]
param(
  [string]$RunDir = "",
  [double]$CycleSec = 31.0,
  [int]$LargeSpikeMs = 200,
  [double]$WindowMin = 5.0,
  [double]$LiveAheadSec = 45.0
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not $RunDir) {
  $latest = Get-ChildItem (Join-Path $PSScriptRoot "logs\long-*") -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { throw "No long-* folders found. Pass -RunDir." }
  $RunDir = $latest.FullName
}
if (-not (Test-Path $RunDir)) { throw "RunDir not found: $RunDir" }

$spikeCsv = Join-Path $RunDir "spikes.csv"
$anchorFile = Join-Path $RunDir "cycle-anchor.txt"
$statusFile = Join-Path $RunDir "status.txt"
$eventFile = Join-Path $RunDir "events.log"

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Spike timeline (view)" Width="1100" Height="620"
        Background="#111418" Foreground="#E8EEF5"
        SnapsToDevicePixels="True" UseLayoutRounding="True">
  <DockPanel Margin="10">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <DockPanel>
        <Button x:Name="LiveBtn" DockPanel.Dock="Right" Content="Live (5 min)" Padding="12,4"
                Margin="12,0,0,0" VerticalAlignment="Top"
                Background="#1E8449" Foreground="#E8EEF5" BorderBrush="#2A3340" Cursor="Hand" />
        <StackPanel>
          <TextBlock x:Name="TitleText" FontSize="15" FontWeight="SemiBold" Text="Loading..." />
          <TextBlock x:Name="StatsText" Margin="0,3,0,0" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" />
          <TextBlock x:Name="NextText" Margin="0,3,0,0" FontFamily="Consolas" FontSize="12" Foreground="#7DCEA0" />
          <TextBlock Margin="0,4,0,0" Foreground="#9AA7B5" FontSize="11"
                     Text="5-min window, spike markers only. Drag=pan. Wheel=zoom a little. L=live. Pan/zoom leaves follow." />
        </StackPanel>
      </DockPanel>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Height="64" BorderBrush="#2A3340" BorderThickness="1" Margin="0,8,0,0" Padding="8">
      <TextBlock x:Name="EventText" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap" />
    </Border>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="*" />
        <RowDefinition Height="44" />
      </Grid.RowDefinitions>
      <Border Grid.Row="0" BorderBrush="#2A3340" BorderThickness="1" Background="#0B0E12" Margin="0,0,0,6" ClipToBounds="True">
        <Grid>
          <Image x:Name="MainImage" Stretch="Fill" IsHitTestVisible="False" />
          <Canvas x:Name="Overlay" Background="Transparent" />
        </Grid>
      </Border>
      <Border Grid.Row="1" BorderBrush="#2A3340" BorderThickness="1" Background="#0B0E12" ClipToBounds="True">
        <DockPanel>
          <TextBlock DockPanel.Dock="Left" Width="40" VerticalAlignment="Center" Margin="4,0,0,0"
                     Foreground="#9AA7B5" FontSize="11" Text="31s" />
          <Image x:Name="BinaryImage" Stretch="Fill" />
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$mainImage = $window.FindName("MainImage")
$binaryImage = $window.FindName("BinaryImage")
$overlay = $window.FindName("Overlay")
$titleText = $window.FindName("TitleText")
$statsText = $window.FindName("StatsText")
$nextText = $window.FindName("NextText")
$eventText = $window.FindName("EventText")
$liveBtn = $window.FindName("LiveBtn")

$tip = New-Object System.Windows.Controls.ToolTip
[System.Windows.Controls.ToolTipService]::SetToolTip($overlay, $tip)

function New-FrozenBrush([string]$hex) {
  $b = ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($hex)
  $b.Freeze(); return $b
}
function New-FrozenPen($brush, [double]$thickness, [double]$opacity = 1.0) {
  $pb = $brush
  if ($opacity -lt 1) {
    $pb = $brush.Clone(); $pb.Opacity = $opacity; $pb.Freeze()
  }
  $p = New-Object System.Windows.Media.Pen($pb, $thickness)
  $p.Freeze(); return $p
}

$Br = @{
  Ink = New-FrozenBrush "#0B0E12"
  Grid = New-FrozenBrush "#243041"
  Mute = New-FrozenBrush "#6B7C8F"
  Red = New-FrozenBrush "#E85D4C"
  Orange = New-FrozenBrush "#E0A14A"
  Green = New-FrozenBrush "#1E8449"
  DarkRed = New-FrozenBrush "#C0392B"
  Mint = New-FrozenBrush "#7DCEA0"
  White = New-FrozenBrush "#FFFFFF"
  Dim = New-FrozenBrush "#2A3340"
}
$Pen = @{
  Grid = New-FrozenPen $Br.Grid 1
  Red = New-FrozenPen $Br.White 0.8
  Orange = New-FrozenPen $Br.White 0.8
  Mint = New-FrozenPen $Br.Mint 2
  Now = New-FrozenPen $Br.White 1 0.35
}
$typeface = New-Object System.Windows.Media.Typeface("Consolas")
$culture = [System.Globalization.CultureInfo]::InvariantCulture

$D = @{
  SpikeT = New-Object System.Collections.Generic.List[double]
  SpikeRtt = New-Object System.Collections.Generic.List[double]
  SpikeLarge = New-Object System.Collections.Generic.List[bool]
  SpikeByte = 0L
  SpikePartial = ""
  AnchorOA = [double]::NaN
  Status = ""
  Dirty = $true
}
$V = @{
  V0 = 0.0; V1 = 1.0
  Live = $true
  Drag = $false; DragX = 0.0; DragV0 = 0.0; DragV1 = 0.0
  Hits = New-Object System.Collections.Generic.List[object]
}
$ui = @{ Busy = $false; Tick = 0 }
$winDays = $WindowMin / 1440.0
$aheadDays = $LiveAheadSec / 86400.0
$leftPad = 36.0

function Open-SharedRead([string]$path) {
  return [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
}

function Add-SpikeLine([string]$line) {
  if ([string]::IsNullOrWhiteSpace($line)) { return }
  if ($line.StartsWith("timestamp")) { return }
  $p = $line.Split(",")
  if ($p.Length -lt 3) { return }
  try {
    $t = [datetime]::Parse($p[0]).ToOADate()
    $rtt = [double]$p[2]
    $large = ($p.Length -ge 4 -and $p[3] -eq "1") -or ($rtt -ge $LargeSpikeMs)
    $D.SpikeT.Add($t); $D.SpikeRtt.Add($rtt); $D.SpikeLarge.Add($large)
    if ([double]::IsNaN($D.AnchorOA) -and $large) { $D.AnchorOA = $t }
  } catch {}
}

function Sync-Spikes {
  if (-not (Test-Path $spikeCsv)) { return }
  $before = $D.SpikeT.Count
  try {
    $fs = Open-SharedRead $spikeCsv
    try {
      if ($D.SpikeByte -gt $fs.Length) {
        $D.SpikeByte = 0L; $D.SpikePartial = ""
        $D.SpikeT.Clear(); $D.SpikeRtt.Clear(); $D.SpikeLarge.Clear()
      }
      if ($fs.Length -le $D.SpikeByte) { return }
      $fs.Position = $D.SpikeByte
      $need = [int][math]::Min(($fs.Length - $D.SpikeByte), 512L * 1024L)
      $buf = New-Object byte[] $need
      $got = $fs.Read($buf, 0, $need)
      if ($got -le 0) { return }
      $D.SpikeByte += $got
      $text = $D.SpikePartial + [Text.Encoding]::UTF8.GetString($buf, 0, $got)
      $parts = $text -split "`r?`n", -1
      if (-not ($text.EndsWith("`n") -or $text.EndsWith("`r"))) {
        $D.SpikePartial = $parts[$parts.Length - 1]
        $limit = $parts.Length - 1
      } else {
        $D.SpikePartial = ""
        $limit = $parts.Length
      }
      for ($i = 0; $i -lt $limit; $i++) { Add-SpikeLine $parts[$i] }
    } finally { $fs.Dispose() }
  } catch {
    $statsText.Text = "sync: $($_.Exception.Message)"
    return
  }
  if ((Test-Path $anchorFile) -and [double]::IsNaN($D.AnchorOA)) {
    try {
      $raw = [IO.File]::ReadAllText($anchorFile).Trim()
      if ($raw) { $D.AnchorOA = [datetime]::Parse($raw).ToOADate() }
    } catch {}
  }
  if (Test-Path $statusFile) {
    try { $D.Status = [IO.File]::ReadAllText($statusFile) } catch {}
  }
  if ($D.SpikeT.Count -ne $before) { $D.Dirty = $true }
}

function Get-AnchorOA {
  if (-not [double]::IsNaN($D.AnchorOA)) { return $D.AnchorOA }
  if ($D.SpikeT.Count) { return $D.SpikeT[0] }
  return (Get-Date).ToOADate()
}

function Get-NextExpected {
  $anchor = Get-AnchorOA
  $now = (Get-Date).ToOADate()
  $cycleDays = $CycleSec / 86400.0
  if ($cycleDays -le 0) { return $null }
  $k = [math]::Ceiling(($now - $anchor) / $cycleDays)
  if (($now - $anchor) -lt 0) { $k = 0 }
  $next = $anchor + ($k * $cycleDays)
  if (($next - $now) * 86400.0 -lt -0.05) { $next += $cycleDays }
  return @{ Next = $next; Seconds = ($next - $now) * 86400.0 }
}

function XOf([double]$oa, [double]$v0, [double]$v1, [double]$width) {
  $span = $v1 - $v0
  if ($span -le 0) { return $leftPad }
  return $leftPad + ((($oa - $v0) / $span) * ($width - $leftPad - 8.0))
}

function OAOf([double]$x, [double]$v0, [double]$v1, [double]$width) {
  $span = $v1 - $v0
  $frac = ($x - $leftPad) / [math]::Max(1.0, ($width - $leftPad - 8.0))
  return $v0 + ($frac * $span)
}

function Find-FirstAtOrAfter([double]$oa) {
  $lo = 0; $hi = $D.SpikeT.Count
  while ($lo -lt $hi) {
    # IMPORTANT: PowerShell [int](x.5) rounds — use Floor so mid can never equal hi.
    $mid = $lo + [int][math]::Floor(($hi - $lo) / 2)
    if ($D.SpikeT[$mid] -lt $oa) { $lo = $mid + 1 } else { $hi = $mid }
  }
  return $lo
}

function New-Text([string]$text, [double]$size) {
  return New-Object System.Windows.Media.FormattedText(
    $text, $culture, [System.Windows.FlowDirection]::LeftToRight,
    $typeface, $size, $Br.Mute)
}

function Render-Bitmap([scriptblock]$paint, [int]$w, [int]$h) {
  if ($w -lt 2) { $w = 2 }; if ($h -lt 2) { $h = 2 }
  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  try { & $paint $dc $w $h } finally { $dc.Close() }
  $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $bmp.Render($dv)
  $bmp.Freeze()
  return $bmp
}

function Update-LiveButton {
  if ($V.Live) {
    $liveBtn.Content = "Live (5 min) ON"
    $liveBtn.Background = $Br.Green
  } else {
    $liveBtn.Content = "Live (5 min)"
    $liveBtn.Background = $Br.Dim
  }
}

function Set-LiveWindow {
  $now = (Get-Date).ToOADate()
  $n1 = $now + $aheadDays
  $n0 = $n1 - $winDays
  if (([math]::Abs($n0 - $V.V0) * 86400.0) -lt 1.0) { return }
  $V.V0 = $n0; $V.V1 = $n1
  $D.Dirty = $true
}

function Enter-Live {
  $V.Live = $true
  $now = (Get-Date).ToOADate()
  $V.V1 = $now + $aheadDays
  $V.V0 = $V.V1 - $winDays
  $D.Dirty = $true
  Update-LiveButton
}

function Leave-Live {
  if (-not $V.Live) { return }
  $V.Live = $false
  Update-LiveButton
}

function Draw-Charts {
  $mw = [math]::Max(40, [int]$mainImage.ActualWidth)
  $mh = [math]::Max(40, [int]$mainImage.ActualHeight)
  $bw = [math]::Max(40, [int]$binaryImage.ActualWidth)
  $bh = [math]::Max(20, [int]$binaryImage.ActualHeight)
  if ($mw -lt 40) { $mw = [int]$overlay.ActualWidth }
  if ($mh -lt 40) { $mh = [int]$overlay.ActualHeight }
  if ($mw -lt 40) { $mw = 1000 }
  if ($mh -lt 40) { $mh = 400 }

  $V.Hits.Clear()
  $st = @{ Shown = 0; Vis = 0 }

  # Precompute marker list outside RenderOpen.
  $marks = New-Object System.Collections.Generic.List[object]
  if ($D.SpikeT.Count -gt 0 -and $V.V1 -gt $V.V0) {
    $i0 = Find-FirstAtOrAfter $V.V0
    for ($i = $i0; $i -lt $D.SpikeT.Count; $i++) {
      if ($D.SpikeT[$i] -gt $V.V1) { break }
      $st.Vis++
    }
    $step = 1
    if ($st.Vis -gt 50) { $step = [int][math]::Ceiling($st.Vis / 50.0) }
    $vi = 0
    for ($i = $i0; $i -lt $D.SpikeT.Count; $i++) {
      $t = $D.SpikeT[$i]
      if ($t -gt $V.V1) { break }
      $large = $D.SpikeLarge[$i]
      $take = $large -or (($vi % $step) -eq 0)
      $vi++
      if (-not $take) { continue }
      if ($marks.Count -ge 50) { break }
      $marks.Add([pscustomobject]@{ T = $t; Rtt = $D.SpikeRtt[$i]; Large = $large; Idx = $i })
    }
  }

  $mainImage.Source = Render-Bitmap ({
    param($dc, $w, $h)
    $dc.DrawRectangle($Br.Ink, $null, [System.Windows.Rect]::new(0, 0, $w, $h))
    $maxRtt = 400.0
    $plotH = $h - 36.0
    foreach ($ms in @(0.0, 100.0, 200.0, 300.0, 400.0)) {
      $y = $h - 18 - (($ms / $maxRtt) * $plotH)
      $dc.DrawLine($Pen.Grid, [System.Windows.Point]::new($leftPad, $y), [System.Windows.Point]::new($w - 8, $y))
    }
    foreach ($m in $marks) {
      $x = XOf ([double]$m.T) $V.V0 $V.V1 $w
      $y = $h - 18 - (([math]::Min($maxRtt, [double]$m.Rtt) / $maxRtt) * $plotH)
      $rad = $(if ($m.Large) { 4.5 } else { 3.0 })
      $fill = $(if ($m.Large) { $Br.Red } else { $Br.Orange })
      $dc.DrawEllipse($fill, $null, [System.Windows.Point]::new($x, $y), $rad, $rad)
      $V.Hits.Add([pscustomobject]@{ X = $x; Y = $y; R = ($rad + 5); Idx = $m.Idx })
      $st.Shown++
    }
    $now = (Get-Date).ToOADate()
    if ($now -ge $V.V0 -and $now -le $V.V1) {
      $x = XOf $now $V.V0 $V.V1 $w
      $dc.DrawLine($Pen.Now, [System.Windows.Point]::new($x, 0), [System.Windows.Point]::new($x, $h))
    }
  }) $mw $mh

  # simple binary strip without text
  $slots = New-Object System.Collections.Generic.List[object]
  if ($D.SpikeT.Count -gt 0) {
    $anchor = Get-AnchorOA
    $cycleDays = $CycleSec / 86400.0
    if ($cycleDays -le 0) { $cycleDays = 31 / 86400.0 }
    $slot0 = $anchor + [math]::Floor(($V.V0 - $anchor) / $cycleDays) * $cycleDays
    $spikeIdx = Find-FirstAtOrAfter ([math]::Min($slot0, $V.V0))
    $n = $D.SpikeT.Count
    $k = 0
    for ($s = $slot0; ($s -lt $V.V1 + $cycleDays) -and ($k -lt 16); $s += $cycleDays) {
      $k++
      $s1 = $s + $cycleDays
      if ($s1 -lt $V.V0 -or $s -gt $V.V1) { continue }
      while ($spikeIdx -lt $n -and $D.SpikeT[$spikeIdx] -lt $s) { $spikeIdx++ }
      $hit = ($spikeIdx -lt $n -and $D.SpikeT[$spikeIdx] -lt $s1)
      $slots.Add([pscustomobject]@{ S = $s; S1 = $s1; Hit = $hit })
    }
  }

  $binaryImage.Source = Render-Bitmap ({
    param($dc, $w, $h)
    $dc.DrawRectangle($Br.Ink, $null, [System.Windows.Rect]::new(0, 0, $w, $h))
    foreach ($sl in $slots) {
      $x1 = XOf ([math]::Max([double]$sl.S, $V.V0)) $V.V0 $V.V1 $w
      $x2 = XOf ([math]::Min([double]$sl.S1, $V.V1)) $V.V0 $V.V1 $w
      $rw = [math]::Max(1.0, $x2 - $x1)
      $dc.DrawRectangle($(if ($sl.Hit) { $Br.DarkRed } else { $Br.Green }), $null, [System.Windows.Rect]::new($x1, 4, $rw, $h - 8))
    }
  }) $bw $bh

  $mode = $(if ($V.Live) { "LIVE" } else { "PAUSED" })
  $titleText.Text = ("{0}  |  {1:HH:mm:ss} - {2:HH:mm:ss}" -f $mode, [datetime]::FromOADate($V.V0), [datetime]::FromOADate($V.V1))
  $statsText.Text = ("markers {0} / {1} in window  |  total spikes {2}" -f $st.Shown, $st.Vis, $D.SpikeT.Count)
  $D.Dirty = $false
}

function Update-Hud([bool]$events) {
  $exp = Get-NextExpected
  if ($exp) {
    $until = $exp.Seconds
    $when = [datetime]::FromOADate($exp.Next)
    if ($until -ge 0) {
      $nextText.Text = ("Next expected: {0:HH:mm:ss.fff}  in {1:n1}s" -f $when, $until)
      $nextText.Foreground = $Br.Mint
    } else {
      $nextText.Text = ("Overdue {0:n1}s  next {1:HH:mm:ss.fff}" -f (-$until), $when)
      $nextText.Foreground = $Br.Orange
    }
  } else { $nextText.Text = "Waiting for cycle anchor..." }

  if ($events -and (Test-Path $eventFile)) {
    try {
      $fs = Open-SharedRead $eventFile
      try {
        $len = $fs.Length
        $take = [int][math]::Min($len, 2500L)
        if ($take -le 0) { return }
        $fs.Position = $len - $take
        $buf = New-Object byte[] $take
        $got = $fs.Read($buf, 0, $take)
        $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
        $lines = @($txt -split "`r?`n" | Where-Object { $_ })
        if ($lines.Count -gt 12) { $lines = $lines[($lines.Count - 12)..($lines.Count - 1)] }
        $eventText.Text = ($lines -join "`r`n")
      } finally { $fs.Dispose() }
    } catch {}
  }
}

function Zoom-At([double]$x, [double]$factor) {
  Leave-Live
  $w = [math]::Max(40.0, $overlay.ActualWidth)
  $anchor = OAOf $x $V.V0 $V.V1 $w
  $span = $V.V1 - $V.V0
  $newSpan = $span * $factor
  $minSpan = 20.0 / 86400.0
  $maxSpan = 20.0 / 1440.0
  if ($newSpan -lt $minSpan) { $newSpan = $minSpan }
  if ($newSpan -gt $maxSpan) { $newSpan = $maxSpan }
  $frac = ($x - $leftPad) / [math]::Max(1.0, $w - $leftPad - 8.0)
  if ($frac -lt 0) { $frac = 0 }; if ($frac -gt 1) { $frac = 1 }
  $V.V0 = $anchor - ($newSpan * $frac)
  $V.V1 = $V.V0 + $newSpan
  $D.Dirty = $true
}

$overlay.Add_MouseWheel({
  param($s, $e)
  Zoom-At ($e.GetPosition($overlay).X) ($(if ($e.Delta -gt 0) { 0.8 } else { 1.25 }))
  $e.Handled = $true
})

$overlay.Add_MouseLeftButtonDown({
  param($s, $e)
  Leave-Live
  $V.Drag = $true
  $V.DragX = $e.GetPosition($overlay).X
  $V.DragV0 = $V.V0; $V.DragV1 = $V.V1
  $tip.IsOpen = $false
  $overlay.CaptureMouse() | Out-Null
})
$overlay.Add_MouseMove({
  param($s, $e)
  if (-not $V.Drag) {
    if ($V.Hits.Count) {
      $p = $e.GetPosition($overlay)
      $hit = $null
      foreach ($m in $V.Hits) {
        $dx = $p.X - $m.X; $dy = $p.Y - $m.Y
        if (($dx * $dx + $dy * $dy) -le ($m.R * $m.R)) { $hit = $m; break }
      }
      if ($hit) {
        $i = [int]$hit.Idx
        $when = [datetime]::FromOADate($D.SpikeT[$i]).ToString("HH:mm:ss.fff")
        $tip.Content = ("{0}`nRTT {1:n1} ms{2}" -f $when, $D.SpikeRtt[$i], $(if ($D.SpikeLarge[$i]) { "`nLARGE" } else { "" }))
        $tip.IsOpen = $true
      } else { $tip.IsOpen = $false }
    }
    return
  }
  $w = [math]::Max(40.0, $overlay.ActualWidth)
  $dx = $e.GetPosition($overlay).X - $V.DragX
  $span = $V.DragV1 - $V.DragV0
  $dt = -($dx / [math]::Max(1.0, $w - $leftPad - 8.0)) * $span
  $V.V0 = $V.DragV0 + $dt
  $V.V1 = $V.DragV1 + $dt
  $D.Dirty = $true
})
$overlay.Add_MouseLeftButtonUp({
  param($s, $e)
  if ($V.Drag) {
    $V.Drag = $false
    $overlay.ReleaseMouseCapture()
    $D.Dirty = $true
  }
})

$liveBtn.Add_Click({ Enter-Live })
$window.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq "L") { Enter-Live }
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$timer.Add_Tick({
  if ($ui.Busy) { return }
  $ui.Busy = $true
  try {
    $ui.Tick++
    try { Sync-Spikes } catch { $statsText.Text = "sync: $($_.Exception.Message)" }
    if ($V.Live) { Set-LiveWindow }
    Update-Hud (($ui.Tick % 5) -eq 0)
    if ($D.Dirty) {
      try { Draw-Charts } catch { $D.Dirty = $false; $statsText.Text = "draw: $($_.Exception.Message)" }
    }
  } finally { $ui.Busy = $false }
})

$window.Add_Closed({ $timer.Stop() })
$window.Add_Loaded({
  [void]$window.Dispatcher.BeginInvoke([System.Action]{
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Enter-Live
    try { Sync-Spikes } catch { $statsText.Text = "sync: $($_.Exception.Message)" }
    $window.Title = "synced $($D.SpikeT.Count)"
    try { Draw-Charts }
    catch { $statsText.Text = "draw: $($_.Exception.Message)"; $window.Title = "draw-fail" }
    $window.Title = ("Spike timeline — {0}ms" -f $sw.ElapsedMilliseconds)
    Update-Hud $false
    $timer.Start()
  }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
})

Update-LiveButton
Set-LiveWindow
$titleText.Text = "Spike timeline"
$statsText.Text = $RunDir
$window.WindowStartupLocation = "CenterScreen"
[void]$window.ShowDialog()
