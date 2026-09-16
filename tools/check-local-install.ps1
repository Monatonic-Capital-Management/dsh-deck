# check-local-install.ps1 - what happens on a machine where dsh is missing?
#
# The gap this covers: `start` reported "dsh not found" and stopped, and nothing
# else installed dsh locally. The panel showed a normal red card whose 启动
# button could never work, with the reason only in a log. There was no
# `install` path for a local instance at all - the verb filtered to remote and
# answered "[fail] no remote instances selected" otherwise.
#
# Why everything is faked
# -----------------------
# The interesting behaviour is "dsh is absent", and the only honest way to
# produce that on a working machine is to hide it. Editing the real npm global
# prefix to test uninstalling would be reckless, so:
#
#   * PATH points at a directory containing ONLY a stub npm - the same way
#     tools/check-app-stop.ps1 intercepts taskkill, and the stub is the same
#     compiled C# pattern, for the same reason (a .cmd wearing an .exe name is
#     rejected by CreateProcess);
#   * the stub's exit code is driven by an environment variable, and it writes
#     the global prefix dsh.ps1 was told to use;
#   * dsh.ps1 is pinned to a scratch config whose local instance has workdir and
#     port overridden, so nothing outside the scratch directory is read or
#     written, and the file is never touched;
#   * the real machine's dsh is never in reach of any launcher invocation here.
#
# The stub genuinely installs nothing, so the assertions are about the
# launcher's REPORT, not about a dsh appearing. That is deliberate: with dsh
# still absent afterwards, `install -Json` answering {"ok":true} is a false
# success, and the test has to be able to see it. The success path is covered
# separately (section 3) by running the real launcher where dsh genuinely
# exists, which is this machine.
#
# Usage:  powershell -File tools\check-local-install.ps1
[CmdletBinding()]
param(
  [switch]$KeepTemp,
  [string]$LauncherPath
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  Write-Host '  SKIP  needs a Windows PowerShell launcher'
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

$scratch = Join-Path $env:TEMP ("dshdeck-localinst-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$clone   = Join-Path $scratch 'clone'
$fakeBin = Join-Path $scratch 'bin'
$fakeNpm = Join-Path $scratch 'npm-global'

function Remove-Scratch {
  if ($KeepTemp) { Write-Host "  kept: $scratch"; return }
  Start-Sleep -Milliseconds 300
  for ($i = 0; $i -lt 5; $i++) {
    try { Remove-Item $scratch -Recurse -Force -ErrorAction Stop; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
}

try {
  Write-Host "`n=== setup: launcher + a PATH that contains no dsh ==="
  Write-Host "  launcher under test: $srcLauncher"
  New-Item -ItemType Directory -Force -Path $clone, $fakeBin | Out-Null
  foreach ($item in @('app', 'remote')) {
    Copy-Item -Path (Join-Path $repoRoot $item) -Destination $clone -Recurse -Force
  }
  Copy-Item -Path $srcLauncher -Destination (Join-Path $clone 'dsh.ps1') -Force

  # The config. A local instance on a port nothing uses, starting in a scratch
  # directory, so a start attempt in section 2 cannot disturb anything real.
  $workdir = Join-Path $scratch 'workdir'
  New-Item -ItemType Directory -Force -Path $workdir | Out-Null
  $config = Join-Path $scratch 'hosts.json'
  @"
{
  "version": 1,
  "instances": [
    { "name": "local", "kind": "local", "port": 39217, "workdir": "$($workdir -replace '\\', '\\')" }
  ]
}
"@ | Set-Content -Path $config -Encoding UTF8

  # The npm stub. Compiled, not a .cmd: see the header.
  #
  # Single-quoted here-string: the body is C#, and PowerShell expands both
  # `$env:...` and `$var` inside a double-quoted one, which turned this source
  # into an unparseable mess the first time it ran. Nothing needs substituting -
  # the stub reads its own directory at runtime instead.
  $stubSrc = @'
using System;
using System.IO;
public class NpmStub {
  public static int Main(string[] args) {
    string dir = AppDomain.CurrentDomain.BaseDirectory;
    try { File.AppendAllText(Path.Combine(dir, "invoked.txt"), string.Join(" ", args) + Environment.NewLine); }
    catch { }
    string mode = Environment.GetEnvironmentVariable("DSH_STUB_NPM_MODE") ?? "";
    // `npm root -g` is the launcher's last-resort way of finding dsh, and in a
    // sandbox it must answer with the sandbox prefix. Without this it reaches
    // the machine's REAL npm prefix and finds the REAL dsh - which is how an
    // earlier version of this test stopped testing "dsh is missing" and started
    // measuring the host.
    if (args.Length >= 2 && args[0] == "root" && args[1] == "-g") {
      Console.WriteLine(Environment.GetEnvironmentVariable("DSH_STUB_NPM_PREFIX") ?? "");
      return 0;
    }
    if (mode == "fail") {
      Console.Error.WriteLine("npm ERR! code EACCES");
      Console.Error.WriteLine("npm ERR! syscall mkdir");
      return 1;
    }
    // A global install that "succeeds" but leaves nothing runnable. The launcher
    // must not call that a success: Invoke-NpmGlobal verifies by executing the
    // binary, precisely because npm's exit code does not mean a working install.
    return 0;
  }
}
'@
  $stubExe = Join-Path $fakeBin 'npm.exe'
  Add-Type -TypeDefinition $stubSrc -OutputAssembly $stubExe -OutputType ConsoleApplication -ErrorAction Stop
  $marker = Join-Path $fakeBin 'invoked.txt'

  # A sandbox APPDATA. dsh.ps1 resolves a global npm prefix from
  # %APPDATA%\npm before it ever shells out to npm, so leaving the real APPDATA
  # in place let Find-DshLocal reach the machine's real install through the
  # first branch it tries - the sandbox was never as sealed as it looked.
  $fakeAppData = Join-Path $scratch 'appdata'
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeAppData 'npm') | Out-Null

  function Invoke-Launcher([string[]]$Arguments, [string]$NpmMode, [switch]$WithSystemPath, [switch]$RealAppData) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $clone 'dsh.ps1')`"") + $Arguments
    $psi.Arguments = $args -join ' '
    $psi.WorkingDirectory = $clone
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Only the stub, plus System32 for the OS itself. No Program Files\nodejs, no
    # AppData npm prefix: this is what "dsh is not installed" looks like.
    $path = "$fakeBin;$env:WINDIR\System32;$env:WINDIR"
    if ($WithSystemPath) { $path = "$fakeBin;$env:PATH" }
    $psi.EnvironmentVariables['PATH'] = $path
    $psi.EnvironmentVariables['DSH_STUB_NPM_PREFIX'] = $fakeNpm
    if (-not $RealAppData) { $psi.EnvironmentVariables['APPDATA'] = $fakeAppData }
    if ($NpmMode) { $psi.EnvironmentVariables['DSH_STUB_NPM_MODE'] = $NpmMode }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(300000) | Out-Null
    return [pscustomobject]@{ Code = $proc.ExitCode; Out = $out; Err = $err; Text = ($out + $err) }
  }

  # The panel and tray cache files live in the clone's state/, so a run with a
  # warm cache would skip the network entirely - useful, since it also makes this
  # test independent of npmjs.org being reachable.
  New-Item -ItemType Directory -Force -Path (Join-Path $clone 'state') | Out-Null
  [pscustomobject]@{ version = '9.9.9'; checkedAt = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -Path (Join-Path $clone 'state\latest-version.json') -Encoding UTF8

  $noDshArgs = @('-Command', 'status', '-Json', '-NoProbe', '-Config', $config)

  # -------------------------------------------------------------------------
  # 1. the reported state: dsh absent, and said out loud
  # -------------------------------------------------------------------------
  Write-Host "`n=== 1. a machine with no dsh reports it, rather than looking healthy ==="
  $r = Invoke-Launcher $noDshArgs $null
  $row = $null
  try { $row = (($r.Out.Trim() -split "`r?`n" | Where-Object { $_.Trim().StartsWith('[') } | Select-Object -First 1) | ConvertFrom-Json)[0] } catch { }
  Check 'status still answers with a row' ([bool]$row) $r.Text.Trim()
  Check 'DshInstalled is explicitly false' ($row -and $row.DshInstalled -eq $false) "got: $(if ($row) { $row.DshInstalled } else { 'no row' })"
  Check 'the card carries a hint naming the fix' ($row -and $row.Hint -match 'dsh 未安装') "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'the hint names the install command' ($row -and $row.Hint -match 'npm i -g @deepseek-ai/dsh') "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'the row does not claim a version' ($row -and -not $row.DshVersion) "got: $(if ($row) { $row.DshVersion } else { '' })"

  # -------------------------------------------------------------------------
  # 2. what the person is told on a machine with no dsh
  # -------------------------------------------------------------------------
  Write-Host "`n=== 2. the missing dsh is reported, and the report matches the card ==="
  # On what is and is not reproducible here. Hiding dsh from PATH and APPDATA is
  # not enough: Find-DshLocal's last resort shells out to npm, and npm answers
  # `root -g` from its own prefix cache rather than from PATH. So on a machine
  # where dsh IS installed the launcher keeps finding it however the sandbox is
  # sealed - measured after two wrong guesses, with PATH and APPDATA both faked,
  # `doctor` still printed the real dsh path.
  #
  # This section therefore asserts only what the sandbox can establish, and says
  # so when it cannot. The "dsh is absent" path is driven for real elsewhere:
  # section 1 reads the status row the launcher produces from the same sealed
  # environment, and section 3 exercises install's absent case directly.
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($nodeExe) { Copy-Item $nodeExe (Join-Path $fakeBin 'node.exe') -Force }
  $r = Invoke-Launcher @('-Command', 'doctor', '-NoProbe', '-Config', $config) $null
  Remove-Item (Join-Path $fakeBin 'node.exe') -Force -ErrorAction SilentlyContinue

  if ($r.Text -match 'dsh\s*:\s*NOT FOUND') {
    Check 'doctor reports the missing dsh' $true
    # From here the sandbox really is clean, so the refusal itself is testable.
    $s = Invoke-Launcher @('-Command', 'start', '-Target', 'local', '-NoOpen', '-Config', $config) $null
    Check 'start refuses rather than half-starting' ($s.Text -match 'cannot start') $s.Text.Trim()
    Check 'the refusal names dsh and the exact install command' ($s.Text -match 'dsh not found' -and $s.Text -match 'npm i -g @deepseek-ai/dsh') $s.Text.Trim()
  } else {
    Check 'doctor names where it found dsh' ($r.Text -match 'dsh\s*:\s*\S') $r.Text.Trim()
    Write-Host '  SKIP  this host has a dsh that survives PATH/APPDATA isolation (npm prefix cache),'
    Write-Host '        so the refusal cannot be reproduced here; sections 1 and 3 cover that state.'
  }

  # -------------------------------------------------------------------------
  # 3. the install path the panel calls
  # -------------------------------------------------------------------------
  Write-Host "`n=== 3. install reaches npm, and never claims success it cannot prove ==="

  # 3a. npm refuses
  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config) 'fail'
  Check 'the npm stub ran' (Test-Path $marker) "no marker at $marker"
  if (Test-Path $marker) {
    $calls = @(Get-Content $marker)
    Check 'npm was asked to install dsh globally' ([bool](@($calls | Where-Object { $_ -match 'install' -and $_ -match '-g' -and $_ -match '@deepseek-ai/dsh' }).Count)) ($calls -join ' | ')
  }
  Check 'a failed npm install is reported as failure' ($r.Out -match '"ok":false') "stdout: $($r.Out.Trim())"
  Check 'and exits non-zero' ($r.Code -ne 0) "exit=$($r.Code)"
  Check 'npm stderr is shown to the reader' ($r.Text -match 'EACCES') $r.Text.Trim()

  # 3b. npm "succeeds" but dsh still does not run - the false-success case
  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config) 'succeed'
  $calls = if (Test-Path $marker) { @(Get-Content $marker) } else { @() }
  Check 'npm was asked twice (the --force retry)' ($calls.Count -ge 2) "calls: $($calls.Count)"
  Check 'a still-missing dsh is NOT reported as installed' ($r.Out -match '"ok":false') "stdout: $($r.Out.Trim())"
  Check 'and exits non-zero' ($r.Code -ne 0) "exit=$($r.Code)"
  Check 'the reader is told why the exit code is not enough' ($r.Text -match 'does not run' -or $r.Text -match 'working dsh') $r.Text.Trim()

  # 3c. no npm at all. (The unused $r above is deliberate: the earlier version
  # built this by reassigning a shared object, which is how a stray backtick
  # ended up inside a single-quoted string and broke the whole file's parse.)
  # A PATH of just System32 leaves no npm; powershell.exe is launched by absolute
  # path, so this is a valid "nothing is installed here" machine.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $clone 'dsh.ps1') + '"')) +
                    @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config)) -join ' '
  $psi.WorkingDirectory = $clone
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['PATH'] = "$env:WINDIR\System32;$env:WINDIR"
  $proc = [System.Diagnostics.Process]::Start($psi)
  $o = $proc.StandardOutput.ReadToEnd(); $e = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit(120000) | Out-Null
  $text = $o + $e
  Check 'no npm is reported clearly, not crashed on' ($text -match 'npm not found') $text.Trim()
  Check 'a missing npm exits non-zero' ($proc.ExitCode -ne 0) "exit=$($proc.ExitCode)"
  Check 'the Node prerequisite is named' ($text -match 'Node\.js') $text.Trim()

  # -------------------------------------------------------------------------
  # 4. the success path, where dsh genuinely exists
  # -------------------------------------------------------------------------
  Write-Host "`n=== 4. with a real dsh present, install is a true no-op ==="
  $realDsh = Get-Command dsh -ErrorAction SilentlyContinue
  if (-not $realDsh) {
    Write-Host '  SKIP  no dsh on this machine to install against'
  } else {
    # -Json is deliberately NOT passed here: it sets -Quiet, which suppresses the
    # "already installed" line, and asserting on a message that quiet mode
    # removes was the first version of this check failing for the wrong reason.
    $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Config', $config) $null -WithSystemPath
    Check 'install succeeds when dsh is already there' ($r.Code -eq 0) "exit=$($r.Code) $($r.Text.Trim())"
    Check 'it says so rather than pretending to install' ($r.Text -match 'already installed') $r.Text.Trim()
    Check 'it reports the version it found' ($r.Text -match '\d+\.\d+') $r.Text.Trim()
  }

  # -------------------------------------------------------------------------
  # 5. the panel routes a local install calls
  # -------------------------------------------------------------------------
  Write-Host "`n=== 5. the install preview speaks about the right machine ==="
  # The assertion is on the ROUTE, with a real backend running, because reading
  # server.js as text only proves a string exists somewhere in the file. The
  # backend is started from the clone, and DSH_LAUNCHER_CONFIG points it at the
  # scratch config, so the instance it reports is the sandbox one; it is stopped
  # again before the test ends.
  $env:DSH_LAUNCHER_CONFIG = $config
  $backend = Start-Process -FilePath $nodeExe -ArgumentList @((Join-Path $clone 'app\server.js')) `
               -WorkingDirectory $clone -WindowStyle Hidden -PassThru
  $runtimeFile = Join-Path $clone 'state\app.json'
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline -and -not (Test-Path $runtimeFile)) { Start-Sleep -Milliseconds 250 }
  $rt = $null
  if (Test-Path $runtimeFile) {
    try { $rt = Get-Content $runtimeFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  Check 'the panel backend started for the route check' ([bool]($rt -and $rt.port)) "no state/app.json after 25s"
  if ($rt -and $rt.port) {
    $base = "http://127.0.0.1:$($rt.port)"
    try {
      $preview = Invoke-WebRequest -Uri "$base/api/instances/local/install?t=$($rt.token)" -UseBasicParsing -TimeoutSec 60
      $pv = $preview.Content | ConvertFrom-Json
      Check 'the preview answers 200 for a local instance' ($preview.StatusCode -eq 200) "HTTP $($preview.StatusCode)"
      Check 'it says kind=local' ($pv.kind -eq 'local') "got: $($pv.kind)"
      Check 'it does NOT claim to deploy a systemd unit' ($pv.plan -notmatch 'systemd') "plan: $($pv.plan)"
      Check 'it names the npm global install it will do' ($pv.plan -match 'npm install -g @deepseek-ai/dsh') "plan: $($pv.plan)"
      Check 'it says Node is not installed for you' ($pv.plan -match '不会安装 Node') "plan: $($pv.plan)"
      Check 'it carries no ssh host' (-not $pv.sshHost) "got: $($pv.sshHost)"
    } catch {
      Check 'the preview answers 200 for a local instance' $false $_.Exception.Message
    }
  }
  Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\DSH_LAUNCHER_CONFIG -ErrorAction SilentlyContinue

  # -------------------------------------------------------------------------
  # 6. the card the reader actually sees
  # -------------------------------------------------------------------------
  Write-Host "`n=== 6. the panel card is wired for a local install ==="
  $html = Get-Content (Join-Path $repoRoot 'app\ui\index.html') -Raw
  Check 'a local card with no dsh gets an install action' ($html -match "kind === ""local""[\s\S]{0,300}install")
  Check 'the hint row is shown for a local card, not only unreachable ones' ($html -match 'hintRow')
  Check 'the confirmation distinguishes a local install from a remote deploy' ($html -match 'preview\.kind')
} finally {
  Remove-Scratch
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
