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

# Explorer caches a shortcut's icon against its icon PATH, so a re-install that
# reuses the same .ico filename keeps drawing the old bitmap on the desktop and
# in the Start Menu. SHCNE_ASSOCCHANGED is the shell's own "icons changed" ping
# and makes it re-read them (a swap to a different colourway depends on this).
$notify = @'
using System;
using System.Runtime.InteropServices;
public static class DshIconRefresh {
  [DllImport("shell32.dll")]
  public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
  public static void Now() { SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
}
'@
try { Add-Type -TypeDefinition $notify -ErrorAction Stop } catch { }

# powershell.exe is present on every supported Windows version, unlike pwsh.
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
# The panel's own mark (a dolphin). Falls back to the node binary and then to
# PowerShell, so the installer still works from a checkout without the asset.
$icon = Join-Path $root 'app\icon\dsh-deck.ico'
if (-not (Test-Path $icon)) { $icon = 'C:\Program Files\nodejs\node.exe' }
if (-not (Test-Path $icon)) { $icon = $ps }

# $exeTarget, not $target: this script previously used $target as the loop
# variable below, and setting TargetPath = $target then wrote the SHORTCUT's own
# path into the link's target. The shell declines to save a self-referential
# shortcut, so the installer failed with a bare COMException while the fallback
# path looked fine. Names on both sides now say which is which.
$exeTarget = Join-Path $root 'Start.exe'
if (Test-Path $exeTarget) {
  $targetPath = $exeTarget
  $arguments  = ''
  $icon       = $exeTarget
} else {
  $targetPath = $ps
  $arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Command app"
}

foreach ($lnkFile in @($lnkPath, $lnkStart)) {
  $dir = Split-Path -Parent $lnkFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $lnk = $wsh.CreateShortcut($lnkFile)
  $lnk.TargetPath       = $targetPath
  $lnk.Arguments        = $arguments
  $lnk.WorkingDirectory = $root
  $lnk.IconLocation     = "$icon,0"
  $lnk.Description      = 'dsh-deck - choose and use local or remote dsh instances'
  $lnk.Save()
  if (-not $Quiet) { Write-Host "  created $lnkFile" }
}

try { [DshIconRefresh]::Now() } catch { }

if (-not $Quiet) {
  Write-Host ''
  Write-Host '  Double-click the shortcut to open the panel.'
  Write-Host "  Remove it later with: powershell -File tools\install-shortcut.ps1 -Remove"
}
exit 0
