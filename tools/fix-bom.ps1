# fix-bom.ps1 - ensure .ps1 files in this repo carry a UTF-8 BOM.
#
# Windows PowerShell 5.1 reads a BOM-less file using the current ANSI code page.
# Every Chinese string in dsh.ps1 then decodes to mojibake, and because some of
# those characters land inside strings and quotes the file stops parsing at all
# ("The string is missing the terminator"). Editors and patch tools that write
# UTF-8 without a BOM therefore break the launcher, so this runs as a guard.
#
# Usage: powershell -File tools\fix-bom.ps1
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem $root -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notlike '*\browser-profile\*' })

$fixed = 0
foreach ($f in $files) {
  $bytes = [IO.File]::ReadAllBytes($f.FullName)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    continue
  }
  # Decode as UTF-8 explicitly, then rewrite WITH the BOM.
  $text = [IO.File]::ReadAllText($f.FullName, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($f.FullName, $text, (New-Object Text.UTF8Encoding($true)))
  $fixed++
  if (-not $Quiet) { Write-Host "  added BOM: $($f.FullName.Replace($root, '.'))" }
}

if (-not $Quiet) {
  Write-Host ("  {0} file(s) checked, {1} fixed" -f $files.Count, $fixed)
}
exit 0
