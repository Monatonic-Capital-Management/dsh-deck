# check-local-card.ps1 - see the local card a user with no dsh would see.
#
# check-ui.js proves the rendering RULES against the shipped code; this renders
# the real page in a real browser and asserts on the DOM. It exists because the
# defect being fixed was visual: a card that looked merely stopped while its
# 启动 button could never work, with the reason only in a log.
#
# Why the flag is forced rather than the state produced: a local instance's dsh
# version is a property of the machine, read the same way for every local
# instance, so no config can fake "no dsh here" on a machine that has one. The
# page is therefore asked to re-render with the field the launcher sets on such a
# machine (DshInstalled false + the Hint it produces). Everything below that -
# renderer, CSS, action wiring - is the shipped code.
#
# Usage:  pwsh -File tools\check-local-card.ps1
[CmdletBinding()]
param(
  [switch]$KeepTemp,
  [int]$CdpPort = 9333
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { Write-Host '  SKIP  Windows-only'; exit 0 }

$repoRoot = Split-Path -Parent $PSScriptRoot
$browser = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { Write-Host '  SKIP  no Chrome or Edge found'; exit 0 }

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { Write-Host '  SKIP  node not found'; exit 0 }

$scratch = Join-Path $env:TEMP ("dshdeck-card-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$clone   = Join-Path $scratch 'clone'
$profile = Join-Path $scratch 'chrome'
$config  = Join-Path $scratch 'hosts.json'
$backend = $null
$chrome  = $null

try {
  Write-Host "`n=== setup: a sandbox panel in $scratch ==="
  New-Item -ItemType Directory -Force -Path $clone, $profile | Out-Null
  foreach ($item in @('app', 'remote')) {
    Copy-Item -Path (Join-Path $repoRoot $item) -Destination $clone -Recurse -Force
  }
  Copy-Item -Path (Join-Path $repoRoot 'dsh.ps1') -Destination $clone -Force

  # A local instance on a port nothing serves, in a scratch workdir, so the card
  # starts in the "down" state this check is about.
  $wd = Join-Path $scratch 'workdir'
  New-Item -ItemType Directory -Force -Path $wd | Out-Null
  @"
{
  "version": 1,
  "instances": [
    { "name": "local", "kind": "local", "port": 39317, "workdir": "$($wd -replace '\\','\\')" }
  ]
}
"@ | Set-Content -Path $config -Encoding UTF8

  $env:DSH_LAUNCHER_CONFIG = $config
  $backend = Start-Process -FilePath $nodeExe -ArgumentList @((Join-Path $clone 'app\server.js')) `
               -WorkingDirectory $clone -WindowStyle Hidden -PassThru
  $rtFile = Join-Path $clone 'state\app.json'
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline -and -not (Test-Path $rtFile)) { Start-Sleep -Milliseconds 250 }
  if (-not (Test-Path $rtFile)) { throw 'the sandbox panel backend never became ready' }
  $rt = Get-Content $rtFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Host "  backend: pid=$($rt.pid) port=$($rt.port)"

  Write-Host "  browser: $browser"
  $chrome = Start-Process -FilePath $browser -ArgumentList @(
    '--headless=new',
    "--remote-debugging-port=$CdpPort",
    "--user-data-dir=$profile",
    '--no-first-run',
    '--no-default-browser-check',
    "--app=$($rt.url)"
  ) -PassThru

  $deadline = (Get-Date).AddSeconds(30)
  $ready = $false
  while ((Get-Date) -lt $deadline -and -not $ready) {
    try {
      $null = Invoke-WebRequest -Uri "http://127.0.0.1:$CdpPort/json/version" -UseBasicParsing -TimeoutSec 3
      $ready = $true
    } catch { Start-Sleep -Milliseconds 400 }
  }
  if (-not $ready) { throw "Chrome did not open a debugging port on $CdpPort" }

  Write-Host "`n=== the local card with dsh absent, as rendered in the browser ==="
  $env:DSH_CDP_PORT = "$CdpPort"
  & $nodeExe (Join-Path $PSScriptRoot 'check-local-card.js')
  $code = $LASTEXITCODE
  exit $code
} finally {
  Remove-Item Env:\DSH_LAUNCHER_CONFIG -ErrorAction SilentlyContinue
  Remove-Item Env:\DSH_CDP_PORT -ErrorAction SilentlyContinue
  if ($chrome) { try { $null = & taskkill.exe /PID $chrome.Id /T /F 2>&1 } catch { } }
  if ($backend) { try { $null = & taskkill.exe /PID $backend.Id /T /F 2>&1 } catch { } }
  if ($KeepTemp) {
    Write-Host "  kept: $scratch"
  } else {
    Start-Sleep -Milliseconds 700
    for ($i = 0; $i -lt 5; $i++) {
      try { Remove-Item $scratch -Recurse -Force -ErrorAction Stop; break }
      catch { Start-Sleep -Milliseconds 600 }
    }
  }
}
