# Build a single-file native NetStutter.exe (identical STUN probe to Serve-SpikeTimeline.py).
param(
  [string]$Configuration = "Release",
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$dotnet = Join-Path $env:LOCALAPPDATA "dotnet\dotnet.exe"
if (-not (Test-Path $dotnet)) { $dotnet = "dotnet" }

$proj = Join-Path $here "native\NetStutter\NetStutter.csproj"
if (-not $OutDir) { $OutDir = Join-Path $here "dist" }

Get-Process NetStutter -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host "Building NetStutter (self-contained win-x64)..." -ForegroundColor Cyan
& $dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -o $OutDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

$exe = Join-Path $OutDir "NetStutter.exe"
if (-not (Test-Path $exe)) { throw "Build failed - NetStutter.exe not found in $OutDir" }
Write-Host "OK: $exe" -ForegroundColor Green
Write-Host "Double-click to start probing immediately (no browser)."
Write-Host "Optional: copy to shell:Startup to run at login."
