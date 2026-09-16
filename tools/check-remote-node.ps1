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
#   * HOME points at a scratch directory, so the PATH lines the script appends to
#     shell rc files land in the sandbox and never in the real profile.
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
  else     { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

# The version the launcher requests, so the fixture is named what it expects.
$src = Get-Content $srcLauncher -Raw
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

function Invoke-Host([string]$Script) {
  # HOME is the sandbox, so the rc-file edits stay inside it. The script is fed on
  # stdin: it is one file, and bash reads it as the whole program.
  $sh = Join-Path $scratch ("job-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.sh')
  $homeDir = Join-Path $scratch ("home-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
  # A real profile file, so the PATH-appending branch runs and can be inspected.
  Set-Content -Path (Join-Path $homeDir '.bashrc') -Value '# sandbox profile' -Encoding ASCII
  [IO.File]::WriteAllText($sh, $Script, (New-Object Text.UTF8Encoding($false)))
  $out = & $bash -c "HOME='$(ConvertTo-BashPath $homeDir)' bash '$(ConvertTo-BashPath $sh)' 2>&1"
  $code = $LASTEXITCODE
  return [pscustomobject]@{ Code = $code; Text = ($out | Out-String); Home = $homeDir }
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
  $build = & $bash -c "cd '$stageDirUnix' && tar -cJf '$goodTarUnix' 'node-$nodeVer-linux-x64' && echo BUILT" 2>&1 | Out-String
  if ($build -notmatch 'BUILT') { throw "could not build the fixture tarball: $($build.Trim())" }
  "  fixture tarball: $([math]::Round((Get-Item $goodTar).Length / 1KB, 1)) KB"

  # The checksum list, computed from that tarball the same way nodejs.org does.
  $goodHash = (& $bash -c "sha256sum '$goodTarUnix' | awk '{print `$1}'" | Out-String).Trim()
  Set-Content -Path (Join-Path $www 'SHASUMS256.txt') -Encoding ASCII -Value "$goodHash  $tarballName"

  # -NoNewWindow, not -WindowStyle Hidden: PowerShell rejects the two together,
  # and the server's output has to be readable to find the port it chose.
  $nodeProc = Start-Process -FilePath $nodeExe `
    -ArgumentList @((Join-Path $PSScriptRoot 'fake-nodejs-server.js'), $www) `
    -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $scratch 'server.out')
  $port = 0
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and $port -eq 0) {
    Start-Sleep -Milliseconds 200
    if (Test-Path (Join-Path $scratch 'server.out')) {
      $line = Get-Content (Join-Path $scratch 'server.out') -ErrorAction SilentlyContinue |
              Where-Object { $_ -match '^LISTENING (\d+)' } | Select-Object -First 1
      if ($line -and $line -match '^LISTENING (\d+)') { $port = [int]$Matches[1] }
    }
  }
  if ($port -eq 0) { throw 'the fake nodejs.org server did not start' }
  # It replaces the fixture files while serving, so it has to run from a node
  # process that outlives them; Stop-Fixtures owns its lifetime.
  $server = $nodeProc
  Write-Host "  fake nodejs.org on 127.0.0.1:$port"

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
  Check 'the download directory was cleaned up' (-not (Test-Path (Join-Path $r.Home '.dsh-deck-dl')))

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
} finally {
  if ($nodeProc) { try { Stop-Process -Id $nodeProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
  Remove-Scratch
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
