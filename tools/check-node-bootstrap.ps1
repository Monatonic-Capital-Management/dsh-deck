# check-node-bootstrap.ps1 - can this tool provide its own Node runtime?
#
# The panel backend is a Node program and dsh needs Node >= 22.19.0, so on a
# machine with no Node nothing could run and nothing could fix itself: the
# install button had no npm to install dsh with. `Ensure-ManagedNode` closes that
# by downloading a Node into %LOCALAPPDATA%\dsh-deck\node\<version>\.
#
# Why a synthetic mirror rather than nodejs.org
# ---------------------------------------------
# Three reasons, in order of importance:
#
#   1. Downloading and executing software during a test run is unacceptable - and
#      it already happened once here. A section of check-local-install.ps1 that
#      ran with an empty PATH reached the real %LOCALAPPDATA% and put a real
#      34 MB Node on the machine. Tests must not install things on the host.
#   2. The interesting cases are the failure ones: a checksum mismatch, a mirror
#      serving nothing, a zip missing from the list. None of those can be
#      produced against the real nodejs.org without breaking it.
#   3. 34 MB per run, offline-intolerant, and it would still not cover the
#      branches above.
#
# So a fake distribution is assembled from stubs: a node.exe that reports a
# version, an npm.cmd recording that it was called, and a SHASUMS256.txt computed
# from the zip that was actually built. The real code path then runs unchanged -
# the same download, verification, extraction, and verification-by-running.
#
# Entry point: `dsh.ps1 -Command node-path -Ensure`, the user-facing way to reach
# this logic, which reports JSON so the assertions are on data, not on log text.
#
# Usage:  powershell -File tools\check-node-bootstrap.ps1
[CmdletBinding()]
param(
  [switch]$KeepTemp,
  [string]$LauncherPath
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  Write-Host '  SKIP  the managed Node is Windows-only (zip + %LOCALAPPDATA%)'
  exit 0
}

$repoRoot    = Split-Path -Parent $PSScriptRoot
$srcLauncher = if ($LauncherPath) { (Resolve-Path $LauncherPath).Path } else { Join-Path $repoRoot 'dsh.ps1' }
if (-not (Test-Path $srcLauncher)) { Write-Host "  FAIL  no launcher at $srcLauncher"; exit 1 }

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else     { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

$scratch = Join-Path $env:TEMP ("dshdeck-nodeboot-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$clone   = Join-Path $scratch 'clone'
$mirror  = Join-Path $scratch 'mirror'
$nodeV   = 'v22.23.2'
$stem    = "node-$nodeV-win-x64"
$stagingBefore = @(Get-ChildItem $env:TEMP -Directory -Filter 'dsh-node-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

function Remove-Scratch {
  if ($KeepTemp) { Write-Host "  kept: $scratch"; return }
  Start-Sleep -Milliseconds 400
  for ($i = 0; $i -lt 5; $i++) {
    try { Remove-Item $scratch -Recurse -Force -ErrorAction Stop; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
}

# A node.exe that answers -v, and can be made broken or old on demand. Compiled,
# because `& node` resolves an exact file name before PATHEXT: a .cmd would never
# be chosen - the measurement behind every shim in this repo.
$nodeStubSrc = @'
using System;
public class BootNodeStub {
  public static int Main(string[] args) {
    string m = Environment.GetEnvironmentVariable("DSH_STUB_NODE_MODE");
    if (m == "broken") { return 3; }
    if (args.Length > 0 && (args[0] == "-v" || args[0] == "--version")) {
      Console.WriteLine(m == "old" ? "v18.20.4" : "v22.23.2");
      return 0;
    }
    return 0;
  }
}
'@

$npmStubSrc = @'
using System;
using System.IO;
public class BootNpmStub {
  public static int Main(string[] args) {
    File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "npm-invoked.txt"), string.Join(" ", args) + Environment.NewLine);
    return 0;
  }
}
'@

# The fake distribution is laid out exactly like the official one, so the
# extraction path is the real one (the code looks for <stem>\node.exe).
function New-FakeDistribution([string]$OutDir) {
  $build = Join-Path $scratch ("build-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
  $inner = Join-Path $build $stem
  New-Item -ItemType Directory -Force -Path $inner | Out-Null
  Add-Type -TypeDefinition $nodeStubSrc -OutputAssembly (Join-Path $inner 'node.exe') -OutputType ConsoleApplication -ErrorAction Stop
  Add-Type -TypeDefinition $npmStubSrc  -OutputAssembly (Join-Path $inner 'npm.exe')  -OutputType ConsoleApplication -ErrorAction Stop
  Set-Content -Path (Join-Path $inner 'npm.cmd') -Encoding ASCII -Value @'
@echo off
"%~dp0npm.exe" %*
exit /b %ERRORLEVEL%
'@
  Set-Content -Path (Join-Path $inner 'LICENSE') -Encoding ASCII -Value 'fake node for tests'
  $zip = Join-Path $OutDir "$stem.zip"
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
  if (Test-Path $zip) { Remove-Item $zip -Force }
  [IO.Compression.ZipFile]::CreateFromDirectory($build, $zip)
  Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
  return $zip
}

function Write-Sums([string]$MirrorDir, [string]$ZipPath, [switch]$Omit, [switch]$Corrupt) {
  if ($Omit) {
    Set-Content -Path (Join-Path $MirrorDir 'SHASUMS256.txt') -Encoding ASCII -Value (('0' * 64) + "  node-other.zip")
    return
  }
  $hash = if ($Corrupt) { 'a' * 64 } else { (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLower() }
  Set-Content -Path (Join-Path $MirrorDir 'SHASUMS256.txt') -Encoding ASCII -Value "$hash  $([IO.Path]::GetFileName($ZipPath))"
}

try {
  Write-Host "`n=== setup: a fake nodejs.org distribution in $scratch ==="
  Write-Host "  launcher under test: $srcLauncher"
  New-Item -ItemType Directory -Force -Path $clone, $mirror | Out-Null
  Copy-Item $srcLauncher (Join-Path $clone 'dsh.ps1') -Force
  $goodZip = New-FakeDistribution $mirror
  Write-Sums $mirror $goodZip
  Get-ChildItem $mirror | ForEach-Object { "  mirror: $($_.Name)  $($_.Length) bytes" }

  function New-Sandbox { return (Join-Path $scratch ("la-" + [guid]::NewGuid().ToString('N').Substring(0, 6))) }

  function Invoke-Launcher([string]$LocalAppData, [string]$Mirror, [string[]]$ExtraArgs, [string]$StubMode) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $clone 'dsh.ps1')`"",
                        '-Command', 'node-path', '-Json') + $ExtraArgs) -join ' '
    $psi.WorkingDirectory = $clone
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # System32 only: no node and no npm from this machine. Adding the real PATH
    # would let the host satisfy the very thing under test, which is how an
    # earlier version of this suite ended up measuring the host.
    $psi.EnvironmentVariables['PATH'] = "$env:WINDIR\System32;$env:WINDIR"
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $LocalAppData
    $psi.EnvironmentVariables['APPDATA'] = (Join-Path $LocalAppData 'Roaming')
    $psi.EnvironmentVariables['USERPROFILE'] = (Join-Path $LocalAppData 'home')
    if ($Mirror) { $psi.EnvironmentVariables['DSH_NODE_MIRROR'] = $Mirror }
    if ($StubMode) { $psi.EnvironmentVariables['DSH_STUB_NODE_MODE'] = $StubMode }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(300000) | Out-Null
    $json = $null
    try {
      $line = $out.Trim() -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -First 1
      if ($line) { $json = $line | ConvertFrom-Json }
    } catch { }
    return [pscustomobject]@{ Code = $proc.ExitCode; Out = $out; Err = $err; Text = ($out + $err); Json = $json }
  }

  # -------------------------------------------------------------------------
  # 0. a plain report never downloads
  # -------------------------------------------------------------------------
  Write-Host "`n=== 0. reporting is not installing ==="
  $la0 = New-Sandbox
  $r = Invoke-Launcher $la0 $mirror @()
  Check 'node-path answers without -Ensure' ([bool]$r.Json) $r.Text.Trim()
  Check 'it reports ok=false when nothing usable exists' ($r.Json -and $r.Json.ok -eq $false) "ok=$(if ($r.Json) { $r.Json.ok } else { '?' })"
  Check 'and it installed nothing' (-not (Test-Path (Join-Path $la0 "dsh-deck\node\$nodeV\node.exe")))
  Check 'it does not even reach for the mirror' ($r.Text -notmatch 'downloading Node') $r.Text.Trim()

  # -------------------------------------------------------------------------
  # 1. -Ensure: download, verify, extract, run
  # -------------------------------------------------------------------------
  Write-Host "`n=== 1. -Ensure installs a verified runtime ==="
  $la1 = New-Sandbox
  $r = Invoke-Launcher $la1 $mirror @('-Ensure')
  $node = Join-Path $la1 "dsh-deck\node\$nodeV\node.exe"
  $npm  = Join-Path $la1 "dsh-deck\node\$nodeV\npm.cmd"
  Check 'it reports success' ($r.Json -and $r.Json.ok -eq $true) $r.Text.Trim()
  Check 'the checksum was verified before extracting' ($r.Text -match 'checksum verified') $r.Text.Trim()
  Check 'node.exe landed in the managed root' (Test-Path $node) "expected $node"
  Check 'npm came with it (npm ships inside the Node zip)' (Test-Path $npm) "expected $npm"
  Check 'the report says the runtime is managed' ($r.Json -and $r.Json.managed -eq $true) "managed=$(if ($r.Json) { $r.Json.managed } else { '?' })"
  Check 'the report names the managed path' ($r.Json -and $r.Json.node -eq $node) "got: $(if ($r.Json) { $r.Json.node } else { '?' })"
  Check 'it reports the installed version' ($r.Json -and $r.Json.version -match 'v22\.23\.2') "got: $(if ($r.Json) { $r.Json.version } else { '?' })"
  $stagingAfter = @(Get-ChildItem $env:TEMP -Directory -Filter 'dsh-node-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  Check 'no staging directory was left behind' ($stagingAfter.Count -eq $stagingBefore.Count) "before=$($stagingBefore -join ',') after=$($stagingAfter -join ',')"

  # -------------------------------------------------------------------------
  # 2. a tampered download is refused
  # -------------------------------------------------------------------------
  Write-Host "`n=== 2. a checksum mismatch is refused ==="
  $badMirror = Join-Path $scratch 'mirror-bad'
  New-Item -ItemType Directory -Force -Path $badMirror | Out-Null
  Copy-Item $goodZip (Join-Path $badMirror "$stem.zip") -Force
  Write-Sums $badMirror $goodZip -Corrupt
  $la2 = New-Sandbox
  $r = Invoke-Launcher $la2 $badMirror @('-Ensure')
  Check 'the mismatch is named' ($r.Text -match 'checksum mismatch') $r.Text.Trim()
  Check 'it says the download is not what was published' ($r.Text -match 'not what nodejs\.org published') $r.Text.Trim()
  Check 'nothing was installed' (-not (Test-Path (Join-Path $la2 "dsh-deck\node\$nodeV\node.exe")))
  Check 'the run failed' ($r.Code -ne 0) "exit=$($r.Code)"

  # -------------------------------------------------------------------------
  # 3. a zip absent from the list is refused
  # -------------------------------------------------------------------------
  Write-Host "`n=== 3. an unlisted zip is refused ==="
  $omitMirror = Join-Path $scratch 'mirror-omit'
  New-Item -ItemType Directory -Force -Path $omitMirror | Out-Null
  Copy-Item $goodZip (Join-Path $omitMirror "$stem.zip") -Force
  Write-Sums $omitMirror $goodZip -Omit
  $la3 = New-Sandbox
  $r = Invoke-Launcher $la3 $omitMirror @('-Ensure')
  Check 'it refuses a zip the checksum list does not cover' ($r.Text -match 'not listed in the checksum file') $r.Text.Trim()
  Check 'nothing was installed' (-not (Test-Path (Join-Path $la3 "dsh-deck\node\$nodeV\node.exe")))

  # -------------------------------------------------------------------------
  # 4. no checksum list at all: refuse rather than download blind
  # -------------------------------------------------------------------------
  Write-Host "`n=== 4. an unreachable checksum list stops everything ==="
  $emptyMirror = Join-Path $scratch 'mirror-empty'
  New-Item -ItemType Directory -Force -Path $emptyMirror | Out-Null
  $la4 = New-Sandbox
  $r = Invoke-Launcher $la4 $emptyMirror @('-Ensure')
  Check 'it reports the checksum list could not be fetched' ($r.Text -match 'could not fetch the checksum list') $r.Text.Trim()
  Check 'it states it will not run an unverified binary' ($r.Text -match 'cannot be verified') $r.Text.Trim()
  Check 'nothing was installed' (-not (Test-Path (Join-Path $la4 "dsh-deck\node\$nodeV\node.exe")))
  # The download-URL fallback lives in Install-LocalDsh rather than in node-path,
  # and the human-readable lines are not printed in -Json mode. So assert on the
  # DATA: the report must still say where a runtime belongs and what it must be,
  # even when the download failed. Getting this wrong was this check's first
  # version, and the fix was to make the verb report through a failed attempt
  # instead of exiting early.
  Check 'it still reports where a runtime would live' `
    ($r.Json -and $r.Json.root -and $r.Json.root -match 'dsh-deck') "root=$(if ($r.Json) { $r.Json.root } else { '?' })"
  Check 'it still reports the minimum version' ($r.Json -and $r.Json.minimum -eq '22.19.0') "min=$(if ($r.Json) { $r.Json.minimum } else { '?' })"
  Check 'it marks the ensure attempt as failed' ($r.Json -and $r.Json.ensureFailed -eq $true) "ensureFailed=$(if ($r.Json) { $r.Json.ensureFailed } else { '?' })"
  Check 'and it exits non-zero' ($r.Code -ne 0) "exit=$($r.Code)"

  # -------------------------------------------------------------------------
  # 5. an existing runtime is reused rather than re-downloaded
  # -------------------------------------------------------------------------
  Write-Host "`n=== 5. an existing managed Node is reused ==="
  $la5 = New-Sandbox
  $null = Invoke-Launcher $la5 $mirror @('-Ensure')
  Check 'the first run installed it' (Test-Path (Join-Path $la5 "dsh-deck\node\$nodeV\node.exe"))
  # The mirror is now unreadable, so any attempt to download would fail loudly.
  # A pass therefore proves the cache was used rather than that it happened to work.
  $r = Invoke-Launcher $la5 (Join-Path $scratch 'gone') @('-Ensure')
  Check 'the second run did not download again' ($r.Text -notmatch 'downloading Node') $r.Text.Trim()
  Check 'and still reports the runtime' ($r.Json -and $r.Json.ok -eq $true) $r.Text.Trim()

  # -------------------------------------------------------------------------
  # 6. a runtime that cannot run is not accepted on sight
  # -------------------------------------------------------------------------
  Write-Host "`n=== 6. a broken runtime does not pass as a good one ==="
  $la6 = New-Sandbox
  $broken = Join-Path $la6 "dsh-deck\node\$nodeV"
  New-Item -ItemType Directory -Force -Path $broken | Out-Null
  $env:DSH_STUB_NODE_MODE = 'broken'
  Add-Type -TypeDefinition $nodeStubSrc -OutputAssembly (Join-Path $broken 'node.exe') -OutputType ConsoleApplication -ErrorAction Stop
  Remove-Item Env:\DSH_STUB_NODE_MODE -ErrorAction SilentlyContinue
  # -Force, not -Ensure: -Ensure only acts when the chosen Node is NOT usable, so
  # a broken node.exe that exits non-zero still LOOKS usable and -Ensure returns it
  # unchanged. That is defensible for the verb - it reports where node is, and
  # `node -v` is the arbiter - but it means the replacement path needs -Force to be
  # exercised. Worth knowing rather than papering over: a runtime that reports a
  # version and then fails on real work is not something a version check can catch.
  $r = Invoke-Launcher $la6 $mirror @('-Ensure', '-Force')
  Check 'it replaces the broken runtime' ($r.Text -match 'downloading Node') $r.Text.Trim()
  Check 'it ends up with a working node' ($r.Json -and $r.Json.ok -eq $true) $r.Text.Trim()
  $v = (& (Join-Path $broken 'node.exe') -v 2>&1 | Out-String).Trim()
  Check 'and that node reports a usable version' ($v -match 'v22\.') "got: $v"
  # And -Ensure on its own does not silently accept a runtime that cannot run dsh
  # work: with no usable version reported at all, the download is what happens.
  $la7 = New-Sandbox
  $absent = Join-Path $la7 "dsh-deck\node\$nodeV"
  New-Item -ItemType Directory -Force -Path $absent | Out-Null
  $r = Invoke-Launcher $la7 $mirror @('-Ensure')
  Check 'an empty managed directory is not mistaken for an install' ($r.Text -match 'downloading Node') $r.Text.Trim()
} finally {
  Remove-Item Env:\DSH_STUB_NODE_MODE -ErrorAction SilentlyContinue
  Remove-Scratch
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
