# install-shortcut.ps1 - create a desktop and Start Menu shortcut for the panel.
#
# The shortcut launches PowerShell with a hidden window and no console, so the
# only thing the user sees is the chromeless app window. It is a separate script
# rather than something dsh.ps1 does automatically, because writing to someone's
# desktop is not a side effect a launcher should have on its own.
#
# Usage:
#   powershell -File tools\install-shortcut.ps1
#   powershell -File tools\install-shortcut.ps1 -Remove
[CmdletBinding()]
param(
  [switch]$Remove,
  [string]$Name = 'DeepSeek Harness',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$script   = Join-Path $root 'dsh.ps1'
$desktop  = [Environment]::GetFolderPath('Desktop')
$startDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnkPath  = Join-Path $desktop  "$Name.lnk"
$lnkStart = Join-Path $startDir "$Name.lnk"

$wsh = New-Object -ComObject WScript.Shell

if ($Remove) {
  foreach ($p in @($lnkPath, $lnkStart)) {
    if (Test-Path $p) { Remove-Item $p -Force; if (-not $Quiet) { Write-Host "  removed $p" } }
  }
  exit 0
}

if (-not (Test-Path $script)) { throw "cannot find dsh.ps1 at $script" }

# powershell.exe is present on every supported Windows version, unlike pwsh.
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$icon = 'C:\Program Files\nodejs\node.exe'
if (-not (Test-Path $icon)) { $icon = $ps }

$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Command app"

foreach ($target in @($lnkPath, $lnkStart)) {
  $dir = Split-Path -Parent $target
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $lnk = $wsh.CreateShortcut($target)
  $lnk.TargetPath       = $ps
  $lnk.Arguments        = $arguments
  $lnk.WorkingDirectory = $root
  $lnk.IconLocation     = "$icon,0"
  $lnk.Description      = 'dsh-deck - choose and use local or remote dsh instances'
  $lnk.Save()
  if (-not $Quiet) { Write-Host "  created $target" }
}

if (-not $Quiet) {
  Write-Host ''
  Write-Host '  Double-click the shortcut to open the panel.'
  Write-Host "  Remove it later with: powershell -File tools\install-shortcut.ps1 -Remove"
}
exit 0
