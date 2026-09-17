[CmdletBinding()]
param([string]$ExePath, [string]$Version = '1.0.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'payload.ps1')
if (-not $ExePath) { $ExePath = Join-Path $root 'Start.exe' }
$result = Test-Package $root $ExePath $Version
foreach ($name in $result.mismatches) { Write-Host "FAIL $name" }
Write-Host ("Package resources checked={0}; matches={1}" -f $result.checked, $result.ok)
if (-not $result.ok) { exit 1 }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dsh-package-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $fixture | Out-Null
  $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($ExePath))
  $program = $assembly.GetType('DshDeck.Program', $true)
  $flags = [Reflection.BindingFlags]'Static,NonPublic'
  $extract = $program.GetMethod('ExtractEmbeddedTo', $flags)
  $complete = $program.GetMethod('HasCompletePayload', $flags)
  # Join-Path can attach a PSObject wrapper; reflection requires a plain string.
  $cache = [IO.Path]::Combine([string]$fixture, 'cache')
  $null = $extract.Invoke($null, @($cache))
  if (-not $complete.Invoke($null, @($cache))) { throw 'extracted payload is incomplete' }
  Write-Host 'PASS standalone extraction includes every runtime resource'
  $target = Join-Path $cache 'dsh.ps1'
  $before = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  $bytes = [IO.File]::ReadAllBytes($target); $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
  [IO.File]::WriteAllBytes($target, $bytes)
  $null = $extract.Invoke($null, @($cache))
  if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $before) { throw 'same-length cache corruption was not repaired' }
  Write-Host 'PASS same-length payload corruption is detected and repaired'
  $remote = Join-Path $cache 'remote\dsh-web-service.sh'
  Remove-Item -LiteralPath $remote
  if ($complete.Invoke($null, @($cache))) { throw 'incomplete checkout incorrectly accepted' }
  $null = $extract.Invoke($null, @($cache))
  if (-not (Test-Path -LiteralPath $remote)) { throw 'missing remote resource was not restored' }
  Write-Host 'PASS missing remote script is refused as a checkout and restored on extraction'
} catch {
  $errorType = $_.Exception.GetType().Name
  $errorId = $_.FullyQualifiedErrorId
  Write-Host ("FAIL isolated payload extraction check: type={0}; id={1}; line={2}" -f $errorType, $errorId, $_.InvocationInfo.ScriptLineNumber)
  exit 1
} finally {
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
exit 0
