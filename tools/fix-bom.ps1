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

# Adding the BOM is only half the job: a file can be correctly encoded and still
# be broken. This runs under Windows PowerShell 5.1 - the interpreter that
# actually executes dsh.ps1 - so its parser is the authority. CI cannot cover
# this: it parses under pwsh 7 on Linux, which reads BOM-less UTF-8 as UTF-8 and
# therefore accepts files that 5.1 rejects outright.
$broken = @()
foreach ($f in $files) {
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    $broken += $f
    Write-Host "  PARSE ERROR: $($f.FullName.Replace($root, '.'))" -ForegroundColor Red
    $errors | Select-Object -First 3 | ForEach-Object {
      Write-Host ("    line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red
    }
  }
}

if (-not $Quiet) {
  Write-Host ("  {0} file(s) checked, {1} re-encoded, {2} unparseable" -f $files.Count, $fixed, $broken.Count)
}
if ($broken.Count -gt 0) { exit 1 }
exit 0
