# build-exe.ps1 - compile Start.exe from tools\exe\DshDeck.cs.
#
# Why a compiler that ships with Windows: this repo has no build step, no SDK
# and no package manager, and adding any of those to produce one small wrapper
# would be a bad trade. csc.exe from the .NET Framework (present on every
# supported Windows) is enough, and it means the committed binary can be
# rebuilt from the source committed beside it rather than merely trusted.
#
# Usage:
#   powershell -File tools\build-exe.ps1
#   powershell -File tools\build-exe.ps1 -Force     # rebuild even if up to date
#   powershell -File tools\build-exe.ps1 -Verify    # inspect the result
[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$Verify,
  [string]$Version = '1.0.0.0'
)

$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'exe\DshDeck.cs'
$outExe = Join-Path $root 'Start.exe'
$icon   = Join-Path $root 'app\icon\dsh-deck.ico'

. (Join-Path $PSScriptRoot 'payload.ps1')
$payloadFiles = @(Get-PayloadFiles $root)
$resources = Get-PackageResources $root

function Get-Csc {
  # Framework64 first: the 64-bit compiler produces a 64-bit exe. AnyCPU would
  # be equivalent here, but matching the platform avoids a surprise on a machine
  # carrying only the 32-bit framework.
  foreach ($p in @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
  )) { if (Test-Path $p) { return $p } }
  return $null
}

$csc = Get-Csc
if (-not $csc) {
  Write-Host '  csc.exe not found. It ships with the .NET Framework 4.x, part of'
  Write-Host '  every supported Windows. Without it, build Start.exe elsewhere and'
  Write-Host '  commit the result.'
  exit 1
}

$inputs = @($source, $icon) + @($payloadFiles | ForEach-Object { Join-Path $root $_ })
foreach ($f in $inputs) {
  if (-not (Test-Path $f)) { Write-Host "  missing input: $f"; exit 1 }
}

# Content equality, not timestamps: a fresh checkout can make stale binaries
# look newer than their sources. Build metadata also covers this compiler script.
if (-not $Force) {
  $current = Test-Package $root $outExe $Version
  if ($current.ok) {
    Write-Host "  Start.exe matches all $($current.checked) resources (content verified)"
    exit 0
  }
  Write-Host "  rebuild required: $($current.mismatches.Count) resource/version mismatch(es)"
}

Write-Host "  compiler: $csc"

# ---------------------------------------------------------------------------
# Resource naming.
#
# csc's `-resource:<file>,<name>` embeds <name> VERBATIM as the manifest
# resource name - measured, not assumed: it is NOT prefixed with the root
# namespace. (That prefixing belongs to .resx compilation, a different code
# path. An earlier version of this script carried a `/namespace:DshDeck` flag
# for it and csc rejected the flag outright as CS2007.) So DshDeck.cs looking
# for resources beginning "payload/" matches exactly what is embedded here.
#
# This is worth stating because the failure is invisible while the exe sits in
# its checkout - it would only break once the exe is separated from the repo,
# which is precisely the case the embedded payload exists for. -Verify reads the
# real names out of the built binary instead of trusting this comment.
# ---------------------------------------------------------------------------
$cscArgs = @(
  '/nologo',
  '/target:exe',
  '/platform:x64',
  '/optimize+',
  "/out:`"$outExe`"",
  "/win32icon:`"$icon`""
)
foreach ($resourceName in $resources.Keys) {
  $cscArgs += "/resource:`"$($resources[$resourceName])`",$resourceName"
}

# Assembly version names the extraction directory. Resource hashes, not the
# version stamp alone, detect changed or damaged cached payload files.
$asmInfo = Join-Path $env:TEMP ("dshdeck-asm-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".cs")
@"
using System.Reflection;
[assembly: AssemblyVersion("$Version")]
[assembly: AssemblyFileVersion("$Version")]
[assembly: AssemblyTitle("dsh-deck")]
[assembly: AssemblyProduct("dsh-deck")]
[assembly: AssemblyDescription("Double-click entry point for the dsh-deck panel")]
"@ | Set-Content -Path $asmInfo -Encoding UTF8

Write-Host "  compiling Start.exe (version $Version, $(@($payloadFiles).Count) embedded file(s))..."
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  # Both sources: the launcher itself, plus the generated version attributes.
  # An earlier version passed only the latter, and csc answered - correctly -
  # with CS5001 "does not contain a static 'Main' method".
  $output = & $csc @cscArgs $source $asmInfo 2>&1 | Out-String
  $code = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $prev
  Remove-Item $asmInfo -Force -ErrorAction SilentlyContinue
}

if ($code -ne 0 -or -not (Test-Path $outExe)) {
  Write-Host '  COMPILE FAILED:'
  ($output.Trim() -split "`r?`n" | Select-Object -First 20) | ForEach-Object { Write-Host "    $_" }
  exit 1
}
if ($output.Trim()) { ($output.Trim() -split "`r?`n") | ForEach-Object { Write-Host "    $_" } }

Write-Host "  built: Start.exe ($([math]::Round((Get-Item $outExe).Length / 1KB, 1)) KB)"

if ($Verify) {
  Write-Host ''
  Write-Host '  verifying the binary...'
  $ok = $true

  $verification = Test-Package $root $outExe $Version
  $ok = $verification.ok
  foreach ($mismatch in $verification.mismatches) { Write-Host "    FAIL  $mismatch" }
  Write-Host "    resources checked: $($verification.checked); content matches: $ok"

  # The icon a shortcut reads as IconLocation '<exe>,0'. Extracted rather than
  # assumed, because "the flag was passed" is not "the resource is there".
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($outExe)
    if ($ic -and $ic.Width -gt 0) { Write-Host ("    ok    embedded icon {0}x{1}" -f $ic.Width, $ic.Height) }
    else { Write-Host '    FAIL  the binary carries no icon'; $ok = $false }
    if ($ic) { $ic.Dispose() }
  } catch {
    Write-Host '    FAIL  could not extract the embedded icon'
    $ok = $false
  }

  if (-not $ok) { Write-Host '  VERIFICATION FAILED'; exit 1 }
  Write-Host '  verification passed'
}
exit 0
