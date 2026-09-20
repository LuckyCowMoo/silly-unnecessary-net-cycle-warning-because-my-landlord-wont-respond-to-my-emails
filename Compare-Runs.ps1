# Summarize detector runs in logs\
$ErrorActionPreference = "Continue"
$dir = Join-Path $PSScriptRoot "logs"
$summaries = Get-ChildItem $dir -Filter "summary-*.txt" | Sort-Object LastWriteTime
Write-Host ""
Write-Host "=== Stutter A/B comparison ===" -ForegroundColor Cyan
$rows = foreach ($f in $summaries) {
  $t = Get-Content $f.FullName -Raw
  $label = if ($t -match 'Label:\s+(\S+)') { $Matches[1] } else { $f.BaseName }
  $loss = if ($t -match 'Lifetime loss %:\s+(.+)') { $Matches[1].Trim() } else { "?" }
  $bursts = if ($t -match 'Stutter bursts:\s+(\d+)') { $Matches[1] } else { "?" }
  $spikes = if ($t -match 'Relative spikes:\s+(\d+)') { $Matches[1] } else { "?" }
  $nic = if ($t -match 'NIC counter hits:\s+(\d+)') { $Matches[1] } else { "?" }
  $elapsed = if ($t -match 'ElapsedSec:\s+([\d\.]+)') { $Matches[1] } else { "?" }
  [pscustomobject]@{
    Label = $label
    Sec = $elapsed
    Bursts = $bursts
    Spikes = $spikes
    NicHits = $nic
    LifetimeLoss = $loss
    File = $f.Name
  }
}
$rows | Format-Table -AutoSize
Write-Host "Current adapter/service snapshot:" -ForegroundColor Yellow
Get-NetAdapter -Name Ethernet, "Radmin VPN", Hamachi -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
Get-NetAdapterBinding -Name Ethernet -ComponentID INSECURE_NPCAP -ErrorAction SilentlyContinue | Format-Table Name, Enabled -AutoSize
Get-Service nordvpn-service, RvControlSvc, rsVPNSvc -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
Get-NetAdapter -Name Ethernet | Select-Object Name, DriverVersion, DriverDate, DriverDescription | Format-List
