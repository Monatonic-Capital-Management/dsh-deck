# check-remote-node.ps1 - does provisioning a host verify the Node it installs?
#
# The gap this closes: the remote path downloaded node-<ver>-linux-<arch>.tar.xz
# with curl and extracted it, without checking what it got. A tampered mirror or
# an intercepted connection would be installed silently - and the whole point of
# automating a host's provisioning is that nobody is watching the download.
#
# How this can be tested on one machine
# -------------------------------------
# The bash that runs on the host is extracted from dsh.ps1 and run locally:
#
#   * Git Bash (which ships sha256sum, awk, curl and tar) provides the host;
#   * tools/fake-nodejs-server.js serves a synthetic nodejs.org/dist, so the URL
#     is redirected at a local port and nothing comes off the network;
#   * Every HOME reference in the extracted script is replaced by the dedicated
#     DSH_DECK_TEST_HOME input. The real HOME and shell profile are not changed.
#
# That is what makes the interesting cases reachable at all: a matching tarball
# must install, a tampered one must be refused, and one the checksum list does not
# mention must be refused too. Against the real nodejs.org none of those can be
# produced without breaking it.
#
# Usage:  powershell -File tools\check-remote-node.ps1
[CmdletBinding()]
param(
  [switch]$KeepTemp,
  [string]$LauncherPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-launcher-contracts.ps1') -HelpersOnly

if ($env:OS -ne 'Windows_NT') {
  Write-Host '  SKIP  needs the Windows launcher plus a Git Bash to act as the host'
  exit 0
}

$repoRoot    = Split-Path -Parent $PSScriptRoot
$srcLauncher = if ($LauncherPath) { (Resolve-Path $LauncherPath).Path } else { Join-Path $repoRoot 'dsh.ps1' }
if (-not (Test-Path $srcLauncher)) { Write-Host "  FAIL  no launcher at $srcLauncher"; exit 1 }

$bash = @(
  "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
  "$env:ProgramFiles\Git\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
  "$env:ProgramFiles\Git\usr\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) {
  Write-Host '  SKIP  no Git Bash found to act as the remote host'
  exit 0
}

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { Write-Host '  SKIP  node not found (needed for the fake server)'; exit 0 }

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else     { $script:fail++; Write-Host ("  FAIL  {0}" -f $Name) }
}

# The version the launcher requests, so the fixture is named what it expects.
$src = Get-LauncherTestSource $srcLauncher
$m = [regex]::Match($src, '\$nodeVersion\s*=\s*''(v[\d.]+)''')
if (-not $m.Success) { Write-Host '  FAIL  could not read $nodeVersion from the launcher'; exit 1 }
$nodeVer = $m.Groups[1].Value
$tarballName = "node-$nodeVer-linux-x64.tar.xz"

$scratch  = Join-Path $env:TEMP ("dshdeck-remote-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$www      = Join-Path $scratch 'www'
$server   = $null
$nodeProc = $null

function Stop-Fixtures {
  if ($server) { try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch { } }
}
function Remove-Scratch {
  Stop-Fixtures
  if ($KeepTemp) { Write-Host "  kept: $scratch"; return }
  Start-Sleep -Milliseconds 400
  for ($i = 0; $i -lt 5; $i++) {
    try { Remove-Item $scratch -Recurse -Force -ErrorAction Stop; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
}

# Pull the bash body the launcher sends to a host, and rewrite only the URL root
# so it points at the local fixture server instead of nodejs.org. Everything else
# - the checksum logic, the awk lookup, the extraction - runs verbatim.
function Get-RemoteInstallScript([int]$Port) {
  $body = [regex]::Match($src, "(?s)\`$installNode = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
  if (-not $body) { throw 'could not extract the remote Node install script from the launcher' }
  $body = $body.Replace('__TARBALL__', "node-$nodeVer-linux-x64").Replace('__NODEVER__', $nodeVer)
  $body = $body -replace 'https://nodejs\.org/dist/', "http://127.0.0.1:$Port/"
  $body = $body.Replace('$HOME', '${DSH_DECK_TEST_HOME}')
  if ($body -match '\$HOME\b|\$\{HOME\}') { throw 'unisolated home reference in remote fixture' }
  return ($body -replace "`r`n", "`n")
}

# Windows paths handed to Git Bash's tar fail with "Cannot connect to C: resolve
# failed", because tar reads `C:/x` as a remote host called C. Everything bash
# touches goes through here. Defined at script scope so both the fixture and the
# host runner can use it.
function ConvertTo-BashPath([string]$p) {
  $u = $p -replace '\\', '/'
  if ($u -match '^([A-Za-z]):') { return '/' + $Matches[1].ToLower() + $u.Substring(2) }
  return $u
}

function Invoke-Host([string]$Script, [hashtable]$ExtraEnvironment = @{}) {
  # Dedicated test input; HOME is never assigned or inherited as a fixture path.
  $sh = Join-Path $scratch ("job-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.sh')
  $homeDir = Join-Path $scratch ("home-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
  # A real profile file, so the PATH-appending branch runs and can be inspected.
  Set-Content -Path (Join-Path $homeDir '.bashrc') -Value '# sandbox profile' -Encoding ASCII
  [IO.File]::WriteAllText($sh, $Script, (New-Object Text.UTF8Encoding($false)))
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $bash
  $psi.Arguments = Join-LauncherTestArguments @('--noprofile','--norc', (ConvertTo-BashPath $sh))
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  Set-LauncherTestEnvironment $psi $scratch $scratch
  $gitUsr = Join-Path (Split-Path -Parent (Split-Path -Parent $bash)) 'usr\bin'
  $psi.EnvironmentVariables['PATH'] = $gitUsr + ';' + $psi.EnvironmentVariables['PATH']
  $psi.EnvironmentVariables['DSH_DECK_TEST_HOME'] = ConvertTo-BashPath $homeDir
  foreach ($entry in $ExtraEnvironment.GetEnumerator()) { $psi.EnvironmentVariables[$entry.Key] = [string]$entry.Value }
  $process = [Diagnostics.Process]::Start($psi)
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(45000)) { $process.Kill(); throw 'fake remote installation timed out' }
  $result = [pscustomobject]@{ Code = $process.ExitCode; Text = ($stdout.Result + $stderr.Result); Home = $homeDir }
  $process.Dispose()
  return $result
}

try {
  Write-Host "`n=== setup: a fake nodejs.org for $nodeVer ==="
  Write-Host "  launcher under test: $srcLauncher"
  Write-Host "  host: $bash"
  New-Item -ItemType Directory -Force -Path $www | Out-Null

  # A real .tar.xz is not needed: the payload only has to survive a round trip
  # through tar and be named like the official archive. tar.xz is produced by Git
  # Bash's own tar, so extraction exercises the real code path.
  #
  # Paths are converted to the /c/... form wherever bash touches them - see
  # ConvertTo-BashPath above for why.
  $stage = Join-Path $scratch "stage/node-$nodeVer-linux-x64/bin"
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Set-Content -Path (Join-Path $stage 'node') -Encoding ASCII -Value "#!/bin/sh`necho $nodeVer"
  Set-Content -Path (Join-Path $stage 'npm') -Encoding ASCII -Value "#!/bin/sh`necho 10.9.8"
  $goodTar = Join-Path $www $tarballName
  $stageDirUnix = ConvertTo-BashPath (Join-Path $scratch 'stage')
  $goodTarUnix  = ConvertTo-BashPath $goodTar
  $build = Invoke-Host "cd '$stageDirUnix' && tar -cJf '$goodTarUnix' 'node-$nodeVer-linux-x64' && echo BUILT"
  if ($build.Code -ne 0 -or $build.Text -notmatch 'BUILT') { throw 'could not build the isolated fixture tarball' }
  "  fixture tarball: $([math]::Round((Get-Item $goodTar).Length / 1KB, 1)) KB"

  # The checksum list, computed from that tarball the same way nodejs.org does.
  $goodHash = (Get-FileHash -LiteralPath $goodTar -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -Path (Join-Path $www 'SHASUMS256.txt') -Encoding ASCII -Value "$goodHash  $tarballName"

  # -NoNewWindow, not -WindowStyle Hidden: PowerShell rejects the two together,
  # and the server's output has to be readable to find the port it chose.
  $serverPsi = New-Object Diagnostics.ProcessStartInfo
  $serverPsi.FileName = $nodeExe
  $serverPsi.Arguments = Join-LauncherTestArguments @((Join-Path $PSScriptRoot 'fake-nodejs-server.js'), $www)
  $serverPsi.UseShellExecute = $false; $serverPsi.CreateNoWindow = $true
  $serverPsi.RedirectStandardOutput = $true; $serverPsi.RedirectStandardError = $true
  Set-LauncherTestEnvironment $serverPsi $scratch $scratch
  $nodeProc = [Diagnostics.Process]::Start($serverPsi)
  $readyTask = $nodeProc.StandardOutput.ReadLineAsync()
  $serverErrors = $nodeProc.StandardError.ReadToEndAsync()
  $port = 0
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and $port -eq 0) {
    Start-Sleep -Milliseconds 200
    if ($readyTask.IsCompleted) {
      $line = $readyTask.Result
      if ($line -and $line -match '^LISTENING (\d+)') { $port = [int]$Matches[1] }
    }
  }
  if ($port -eq 0) { throw 'the fake nodejs.org server did not start' }
  # It replaces the fixture files while serving, so it has to run from a node
  # process that outlives them; Stop-Fixtures owns its lifetime.
  $server = $nodeProc
  Write-Host '  fake nodejs.org ready (loopback fixture)'

  $script = Get-RemoteInstallScript $port

  # -------------------------------------------------------------------------
  # 1. a matching tarball installs, and says it verified
  # -------------------------------------------------------------------------
  Write-Host "`n=== 1. a verified tarball is installed ==="
  $r = Invoke-Host $script
  Check 'the host reported the checksum was verified' ($r.Text -match 'checksum verified') $r.Text.Trim()
  Check 'node was placed where the service expects it' `
    (Test-Path (Join-Path $r.Home '.local/node/bin/node')) "expected $($r.Home)\.local\node\bin\node"
  Check 'npm travelled with it' (Test-Path (Join-Path $r.Home '.local/node/bin/npm'))
  Check 'it reported a node version' ($r.Text -match [regex]::Escape($nodeVer)) $r.Text.Trim()
  Check 'the run succeeded' ($r.Code -eq 0) "exit=$($r.Code)"
  $rc = Get-Content (Join-Path $r.Home '.bashrc') -Raw
  Check 'the shell profile got the PATH line' ($rc -match '\.local/node/bin') $rc.Trim()
  Check 'the download directory was cleaned up' (@(Get-ChildItem -LiteralPath $r.Home -Directory -Filter '.dsh-node-download.*').Count -eq 0)

  # -------------------------------------------------------------------------
  # 2. a tampered tarball is refused before extraction
  # -------------------------------------------------------------------------
  Write-Host "`n=== 2. a tampered tarball is refused ==="
  $original = [IO.File]::ReadAllBytes($goodTar)
  # Flip a byte in the compressed body: same name, same length, different content.
  $tampered = [byte[]]::new($original.Length)
  [Array]::Copy($original, $tampered, $original.Length)
  $tampered[$original.Length - 1] = $tampered[$original.Length - 1] -bxor 0xFF
  [IO.File]::WriteAllBytes($goodTar, $tampered)
  $r = Invoke-Host $script
  Check 'the mismatch is reported as a checksum failure' ($r.Text -match 'CHECKSUM_FAIL') $r.Text.Trim()
  Check 'nothing was extracted' (-not (Test-Path (Join-Path $r.Home '.local/node'))) "found $($r.Home)\.local\node"
  Check 'the run failed' ($r.Code -ne 0) "exit=$($r.Code)"
  [IO.File]::WriteAllBytes($goodTar, $original)

  # -------------------------------------------------------------------------
  # 3. a tarball the checksum list does not mention is refused
  # -------------------------------------------------------------------------
  Write-Host "`n=== 3. an unlisted tarball is refused ==="
  Set-Content -Path (Join-Path $www 'SHASUMS256.txt') -Encoding ASCII -Value (('0' * 64) + "  node-other.tar.xz")
  $r = Invoke-Host $script
  Check 'the missing listing is reported' ($r.Text -match 'CHECKSUM_FAIL') $r.Text.Trim()
  Check 'it says the file is not listed' ($r.Text -match 'is not listed in SHASUMS256') $r.Text.Trim()
  Check 'nothing was extracted' (-not (Test-Path (Join-Path $r.Home '.local/node')))
  Set-Content -Path (Join-Path $www 'SHASUMS256.txt') -Encoding ASCII -Value "$goodHash  $tarballName"

  # -------------------------------------------------------------------------
  # 4. no checksum list at all is refused
  # -------------------------------------------------------------------------
  Write-Host "`n=== 4. an unfetchable checksum list is refused ==="
  Rename-Item (Join-Path $www 'SHASUMS256.txt') 'SHASUMS256.txt.off'
  $r = Invoke-Host $script
  Check 'the run failed' ($r.Code -ne 0) "exit=$($r.Code)"
  Check 'nothing was extracted' (-not (Test-Path (Join-Path $r.Home '.local/node')))
  Check 'the failure is not silent' ($r.Text.Trim().Length -gt 0) 'no output at all'
  Rename-Item (Join-Path $www 'SHASUMS256.txt.off') 'SHASUMS256.txt'

  Write-Host "`n=== 5. cgroup child ownership is proved without real processes ==="
  $snapshot = [regex]::Match($src, '(?s)function Get-RemoteSnapshotScript\b.*?\$body = @''\r?\n(.*?)\r?\n''@').Groups[1].Value
  if (-not $snapshot) { throw 'remote snapshot script is missing' }
  $snapshot = $snapshot.Replace('__PORT__','41080').Replace('$HOME','${DSH_DECK_TEST_HOME}').Replace('/proc/', '${DSH_DECK_TEST_HOME}/proc/')
  $snapshotFixture = @'
mkdir -p "${DSH_DECK_TEST_HOME}/proc/222"
printf '0::%s\n' "$DSH_TEST_CGROUP" > "${DSH_DECK_TEST_HOME}/proc/222/cgroup"
systemctl() { printf 'MainPID=111\nActiveState=active\nControlGroup=/user.slice/dsh-web.service\n'; }
ss() { printf 'LISTEN 0 511 127.0.0.1:41080 0.0.0.0:* users:(("node",pid=222,fd=19))\n'; }
curl() { printf 200; }
'@
  $r = Invoke-Host ($snapshotFixture + "`n" + $snapshot) @{ DSH_TEST_CGROUP = '/user.slice/dsh-web.service/worker' }
  Check 'listener child PID differs from MainPID and is still owned' ($r.Code -eq 0 -and $r.Text -match 'SNAP_MAIN=111' -and $r.Text -match 'SNAP_LISTEN=222' -and $r.Text -match 'SNAP_OWNED=yes' -and $r.Text -match 'SNAP_HTTP=200')
  $r = Invoke-Host ($snapshotFixture + "`n" + $snapshot) @{ DSH_TEST_CGROUP = '/user.slice/dsh-web.service-unrelated' }
  Check 'a cgroup name prefix cannot prove ownership or trigger HTTP' ($r.Code -eq 0 -and $r.Text -match 'SNAP_OWNED=no' -and $r.Text -match 'SNAP_HTTP=0')

  Write-Host "`n=== 6. service wrapper publishes privately and redacts diagnostics ==="
  $service = Get-Content -LiteralPath (Join-Path $repoRoot 'remote\dsh-web-service.sh') -Raw -Encoding UTF8
  $service = $service.Replace('$HOME','${DSH_DECK_TEST_HOME}')
  if ($service -match '\$HOME\b|\$\{HOME\}') { throw 'unisolated home reference in service fixture' }
  $wrapperFixture = @'
mkdir -p "${DSH_DECK_TEST_HOME}/bin"
export DSH_HOME="${DSH_DECK_TEST_HOME}/data"
export DSH_PORT=41080
export DSH_WORKDIR="${DSH_DECK_TEST_HOME}"
export DSH_RUNTIME_DIR="${DSH_DECK_TEST_HOME}/run"
export DSH_BIN="${DSH_DECK_TEST_HOME}/bin/dsh"
cat > "$DSH_BIN" <<'FIXTURE_DSH'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo '1.2.3-rc.1+fixture'; exit 0; fi
printf 'dsh web: http://127.0.0.1:41080/#t=%s\n' "$DSH_TEST_CREDENTIAL"
printf 'Bearer %s\n' "$DSH_TEST_CREDENTIAL"
printf '{"token":"%s"}\n' "$DSH_TEST_CREDENTIAL"
FIXTURE_DSH
chmod +x "$DSH_BIN"
'@
  $credential = [guid]::NewGuid().ToString('N')
  $r = Invoke-Host ($wrapperFixture + "`n" + $service) @{ DSH_TEST_CREDENTIAL = $credential }
  $privateUrlFile = Join-Path $r.Home 'data\remote-web.url'
  $logFile = Join-Path $r.Home 'data\remote-web.log'
  $readyFile = Join-Path $r.Home 'run\ready'
  Check 'wrapper publishes a private URL and readiness marker' ($r.Code -eq 0 -and (Test-Path -LiteralPath $privateUrlFile) -and (Test-Path -LiteralPath $readyFile))
  $privateUrl = if (Test-Path -LiteralPath $privateUrlFile) { Get-Content -LiteralPath $privateUrlFile -Raw } else { '' }
  $diagnostics = if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Raw } else { '' }
  Check 'raw synthetic credential only exists in private URL, never diagnostics' ($privateUrl.Contains($credential) -and -not $diagnostics.Contains($credential) -and $diagnostics.Contains('[redacted]') -and -not $r.Text.Contains($credential))
  $versionFile = Join-Path $r.Home 'data\remote-web.version'
  Check 'running-version marker preserves prerelease plus build metadata' ((Test-Path -LiteralPath $versionFile) -and (Get-Content -LiteralPath $versionFile -Raw).Trim() -eq '1.2.3-rc.1+fixture')
} finally {
  if ($nodeProc) { try { Stop-Process -Id $nodeProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
  Remove-Scratch
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
