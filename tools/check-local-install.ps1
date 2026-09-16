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
  # And a sandbox home, because $HomeDir comes from USERPROFILE and a real
  # `~/.npmrc` with a prefix= line is consulted before anything else.
  $fakeHome = Join-Path $scratch 'home'
  New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
  # Sandbox LOCALAPPDATA too: it is where a self-installed Node runtime goes.
  $fakeLocalAppData = Join-Path $scratch 'localappdata'
  New-Item -ItemType Directory -Force -Path $fakeLocalAppData | Out-Null
  # Nothing may be downloaded during a normal run. DSH_NODE_MIRROR points the
  # managed-Node installer at the sandbox itself, so if any section ever reaches
  # it, it fails fast on a missing file instead of spending 34 MB of the
  # machine's bandwidth - and, more importantly, instead of succeeding.
  $emptyMirror = Join-Path $scratch 'mirror'
  New-Item -ItemType Directory -Force -Path $emptyMirror | Out-Null

  # A sandbox node. Only present when a section asks for it (`node -v` is how the
  # "installed but cannot run" hint reports the version in use), and silent for
  # dsh's own `--version` unless the mode says otherwise. That silence IS the
  # defect being reproduced: dsh's shebang is `#!/usr/bin/env node`, so an older
  # Node runs it and it exits 0 printing nothing.
  #
  # It has to be a real executable named node.exe: the launcher runs `node <bin>`,
  # so `& node` resolves through PATH and PATHEXT, and a .cmd earlier on PATH does
  # NOT win - the same measurement that forced a compiled shim in
  # tools/check-app-stop.ps1.
  $nodeStubSrc = @'
using System;
public class NodeStub {
  public static int Main(string[] args) {
    string mode = Environment.GetEnvironmentVariable("DSH_STUB_NODE_MODE");
    if (args.Length > 0 && (args[0] == "-v" || args[0] == "--version")) {
      Console.WriteLine(mode == "ok" ? "v22.22.0" : "v18.20.4");
      return 0;
    }
    if (mode != "ok") { return 0; }
    Console.WriteLine("0.1.0-rc.6");
    return 0;
  }
}
'@
  $nodeExeStub = Join-Path $fakeBin 'node.exe'
  Add-Type -TypeDefinition $nodeStubSrc -OutputAssembly $nodeExeStub -OutputType ConsoleApplication -ErrorAction Stop

  function Invoke-Launcher([string[]]$Arguments, [string]$NpmMode, [switch]$WithSystemPath, [string]$NodeMode, [switch]$NoNodePath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $clone 'dsh.ps1')`"") + $Arguments
    $psi.Arguments = $args -join ' '
    $psi.WorkingDirectory = $clone
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # The stubs plus System32 for the OS itself, and nothing else. The npm stub
    # matters more than it looks: dsh.ps1 asks `npm root -g` as its last resort
    # for finding dsh, so with a real npm on PATH the sandbox found the machine's
    # REAL global prefix and the REAL dsh, and every "dsh is missing" assertion
    # was quietly measuring this host instead.
    $path = "$fakeBin;$env:WINDIR\System32;$env:WINDIR"
    if ($WithSystemPath) { $path = "$fakeBin;$env:PATH" }
    # -NoNodePath drops the node stub as well, for the sections about a machine
    # with no Node at all.
    if ($NoNodePath) { $path = "$env:WINDIR\System32;$env:WINDIR" }
    $psi.EnvironmentVariables['PATH'] = $path
    $psi.EnvironmentVariables['DSH_STUB_NPM_PREFIX'] = $fakeNpm
    $psi.EnvironmentVariables['APPDATA'] = $fakeAppData
    # USERPROFILE too, and this was the last leak: dsh.ps1 resolves $HomeDir from
    # it at startup and Find-DshLocal reads `$HOME\.npmrc` for a prefix= line
    # BEFORE it looks at APPDATA or asks npm. With the real profile, this machine's
    # real npm-global prefix was found there and the real dsh came back - which is
    # why the "absent" assertions kept failing while the sandbox looked sealed.
    $psi.EnvironmentVariables['USERPROFILE'] = $fakeHome
    # LOCALAPPDATA, because this tool now installs a Node runtime under
    # %LOCALAPPDATA%\dsh-deck\node when nothing usable is found. Without this the
    # section that runs with no node on PATH downloaded a REAL 34 MB Node into
    # the machine running the suite - the tests were installing software on the
    # host. Faking it puts the managed runtime inside the scratch directory, and
    # the guard below fails loudly if that ever stops being true.
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $fakeLocalAppData
    # An empty mirror directory: any attempt to install a Node fails on a missing
    # file rather than reaching nodejs.org.
    $psi.EnvironmentVariables['DSH_NODE_MIRROR'] = $emptyMirror
    if ($NpmMode) { $psi.EnvironmentVariables['DSH_STUB_NPM_MODE'] = $NpmMode }
    if ($NodeMode) { $psi.EnvironmentVariables['DSH_STUB_NODE_MODE'] = $NodeMode }
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
  # 0. the suite must not install anything on the machine running it
  # -------------------------------------------------------------------------
  # This exists because it already happened. Once Install-LocalDsh could fetch a
  # Node runtime, the section that runs with an empty PATH downloaded a real
  # 34 MB Node into %LOCALAPPDATA%\dsh-deck\node on this machine - a test suite
  # modifying the host is worse than a failing test, and it was silent. Faking
  # LOCALAPPDATA plus an empty DSH_NODE_MIRROR prevents it; this assertion proves
  # the faking works instead of trusting it.
  Write-Host "`n=== 0. the sandbox holds: no stray managed-Node directory ==="
  $realManaged = Join-Path $env:LOCALAPPDATA 'dsh-deck\node'
  $managedBefore = @(if (Test-Path $realManaged) { Get-ChildItem $realManaged -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } })
  if ($managedBefore.Count) {
    Write-Host "  note  $realManaged already exists with: $($managedBefore -join ', ')"
  }
  Check 'the managed-Node root is inside the sandbox' `
    ((Join-Path $fakeLocalAppData 'dsh-deck\node') -like "$scratch*") "got: $(Join-Path $fakeLocalAppData 'dsh-deck\node')"

  # -------------------------------------------------------------------------
  # 1. a dsh that cannot run is never presented as usable
  # -------------------------------------------------------------------------
  Write-Host "`n=== 1. an unusable dsh is reported, not covered up ==="
  # The assertion is on the CONTRACT, not on one mechanism. On a machine with no
  # dsh anywhere the notice is "not installed, here is the command"; on one whose
  # dsh is present but silent - an old Node, docs/lessons.md #5 - it is
  # "installed but cannot run, upgrade Node". Both are right, and which appears
  # depends on the host running this suite, so demanding exactly one of them was
  # asserting the wrong thing (and did fail here, for the honest reason).
  #
  # What must hold either way: the card reports the instance unusable, explains
  # itself, names a next step, and never shows a version it could not read. The
  # present-but-silent branch is driven deterministically in section 4b.
  $r = Invoke-Launcher $noDshArgs $null -NodeMode 'ok'
  $row = $null
  try { $row = (($r.Out.Trim() -split "`r?`n" | Where-Object { $_.Trim().StartsWith('[') } | Select-Object -First 1) | ConvertFrom-Json)[0] } catch { }
  Check 'status still answers with a row' ([bool]$row) $r.Text.Trim()
  Check 'the card does not present the instance as usable' ($row -and $row.DshInstalled -eq $false) "got: $(if ($row) { $row.DshInstalled } else { 'no row' })"
  Check 'it carries an explanation' ($row -and $row.Hint) "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'the explanation is one of the two actionable ones' `
    ($row -and ($row.Hint -match 'dsh 未安装' -or $row.Hint -match '已安装但无法运行')) "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'it names a next step (the npm command, or the Node requirement)' `
    ($row -and ($row.Hint -match 'npm i -g @deepseek-ai/dsh' -or $row.Hint -match '22\.19')) "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'the row does not claim a version it could not read' ($row -and -not $row.DshVersion) "got: $(if ($row) { $row.DshVersion } else { '' })"

  # -------------------------------------------------------------------------
  # 2. what the person is told on a machine with no dsh
  # -------------------------------------------------------------------------
  Write-Host "`n=== 2. the missing dsh is reported, and the report matches the card ==="
  # This section used to explain at length why "dsh is absent" could not be
  # reproduced here. That turned out to be wrong, and the reason is worth
  # keeping: the sandbox was leaking. Hiding PATH and APPDATA was not enough,
  # because Find-DshLocal's last resort shells out to npm and a REAL npm answers
  # `root -g` from its own prefix cache, so the launcher kept finding this
  # machine's real dsh. With the npm stub answering that question inside the
  # sandbox, the absent state is now genuinely reproducible - and section 1
  # asserts on it. What remains here is the launcher's own report of the result.
  $r = Invoke-Launcher @('-Command', 'doctor', '-NoProbe', '-Config', $config) $null
  if ($r.Text -match 'dsh\s*:\s*NOT FOUND') {
    Check 'doctor reports the missing dsh' $true
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
  $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config) 'fail' -NodeMode 'ok'
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
  $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config) 'succeed' -NodeMode 'ok'
  $calls = if (Test-Path $marker) { @(Get-Content $marker) } else { @() }
  Check 'npm was asked twice (the --force retry)' ($calls.Count -ge 2) "calls: $($calls.Count)"
  Check 'a still-missing dsh is NOT reported as installed' ($r.Out -match '"ok":false') "stdout: $($r.Out.Trim())"
  Check 'and exits non-zero' ($r.Code -ne 0) "exit=$($r.Code)"
  Check 'the reader is told why the exit code is not enough' ($r.Text -match 'does not run' -or $r.Text -match 'working dsh') $r.Text.Trim()

  # 3c. no node and no npm anywhere, and the Node download cannot succeed either.
  # That last part is what this section now means: since Install-LocalDsh can
  # fetch a Node, "no npm" is only reachable when the download itself is
  # impossible. The empty DSH_NODE_MIRROR makes that deterministic - no bytes
  # leave the machine, and the failure is a missing file rather than a timeout.
  #
  # Build it through the same helper as everything else, with -NoNodePath. This
  # used to hand-roll a ProcessStartInfo, and that copy forgot the fake
  # LOCALAPPDATA and the mirror - so it reached the real %LOCALAPPDATA% and
  # downloaded a real 34 MB Node onto the machine running the suite.
  #
  # The marker is cleared first: it accumulates across sections, and asserting
  # "npm was never reached" against a file still listing earlier sections' calls
  # fails while nothing in THIS section ran npm at all.
  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config) $null -NoNodePath
  Check 'an unusable Node download is reported, not crashed on' ($r.Text -match 'could not fetch the checksum list|could not provide a Node runtime') $r.Text.Trim()
  Check 'the refusal is non-zero' ($r.Code -ne 0) "exit=$($r.Code)"
  Check 'it refuses to install an unverified binary' ($r.Text -match 'cannot be verified') $r.Text.Trim()
  Check 'a manual fallback is named' ($r.Text -match 'nodejs\.org') $r.Text.Trim()
  Check 'npm is never reached in this state' (-not (Test-Path $marker)) "npm ran: $(@(Get-Content $marker -ErrorAction SilentlyContinue) -join ' | ')"

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
    #
    # -WithSystemPath brings the real PATH back, and with it the machine's real
    # dsh; the fake home and APPDATA still point Find-DshLocal at the sandbox
    # first, so the run below is a genuine "already installed" only because the
    # system PATH is what supplies it.
    $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Config', $config) $null -WithSystemPath -NodeMode 'ok'
    Check 'install succeeds when dsh is already there' ($r.Code -eq 0) "exit=$($r.Code) $($r.Text.Trim())"
    Check 'it says so rather than pretending to install' ($r.Text -match 'already installed') $r.Text.Trim()
    Check 'it reports the version it found' ($r.Text -match '\d+\.\d+') $r.Text.Trim()
  }

  # -------------------------------------------------------------------------
  # 4b. present but silent - installed, and unable to run
  # -------------------------------------------------------------------------
  Write-Host "`n=== 4b. a dsh that is installed but cannot run is not called 'missing' ==="
  # The real case: dsh's shebang is `#!/usr/bin/env node`, so an older Node runs
  # it and it exits 0 printing nothing (docs/lessons.md #5, #6). "Absent" and
  # "cannot run" need different advice - telling this user to run `npm i -g`
  # sends them through a reinstall that succeeds and changes nothing - and the
  # install path must not spend two --force npm runs discovering that.
  #
  # The shared stubs do the work: the npm stub answers `root -g` with the sandbox
  # prefix (so Find-DshLocal finds the sandbox dsh, not this machine's), and the
  # node stub is silent for dsh's `--version` unless DSH_STUB_NODE_MODE=ok.
  # A dsh that is present at the prefix Find-DshLocal checks first.
  $presentDsh = Join-Path $fakeAppData 'npm\node_modules\@deepseek-ai\dsh\lib'
  New-Item -ItemType Directory -Force -Path $presentDsh | Out-Null
  Set-Content -Path (Join-Path $presentDsh 'bin.js') -Value '// present, not runnable' -Encoding ASCII

  # Control: with a node that CAN run dsh, the sandbox dsh reports a version.
  # Without this, "DshInstalled is false" below could pass merely because the
  # sandbox never finds that dsh at all.
  $r = Invoke-Launcher $noDshArgs $null -NodeMode 'ok'
  $row = $null
  try { $row = (($r.Out.Trim() -split "`r?`n" | Where-Object { $_.Trim().StartsWith('[') } | Select-Object -First 1) | ConvertFrom-Json)[0] } catch { }
  Check 'control: the sandbox dsh is found and runnable' ($row -and $row.DshInstalled -eq $true) "got: $(if ($row) { $row.DshInstalled } else { 'no row' })"
  Check 'control: its version is reported' ($row -and $row.DshVersion -match '0\.1\.0-rc\.6') "got: $(if ($row) { $row.DshVersion } else { '' })"

  # Now the same dsh under an older Node: present, silent, unusable.
  $r = Invoke-Launcher $noDshArgs $null -NodeMode 'old'
  $row = $null
  try { $row = (($r.Out.Trim() -split "`r?`n" | Where-Object { $_.Trim().StartsWith('[') } | Select-Object -First 1) | ConvertFrom-Json)[0] } catch { }
  Check 'a silent dsh is not reported as installed' ($row -and $row.DshInstalled -eq $false) "got: $(if ($row) { $row.DshInstalled } else { 'no row' })"
  Check 'the hint says installed-but-cannot-run, not missing' ($row -and $row.Hint -match '已安装但无法运行') "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'the hint names the Node requirement' ($row -and $row.Hint -match '22\.19') "got: $(if ($row) { $row.Hint } else { '' })"
  Check 'the hint reports the Node actually in use' ($row -and $row.Hint -match '18\.20\.4') "got: $(if ($row) { $row.Hint } else { '' })"
  # The important one: the advice must not be the command that cannot help.
  Check 'the hint does NOT tell them to reinstall dsh' ($row -and $row.Hint -notmatch 'npm i -g') "got: $(if ($row) { $row.Hint } else { '' })"

  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $r = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Config', $config) $null -NodeMode 'old'
  $calls = if (Test-Path $marker) { @(Get-Content $marker) } else { @() }
  $text = $r.Text

  # What `install` should do here is now a different question than it was before
  # this tool could fetch a Node.
  #
  # The old advice - "installed but cannot run, upgrade Node" - was right when
  # upgrading Node was the only fix. It is no longer the only fix: this tool
  # provides a Node itself, and that IS the fix, so `install` now does it. The
  # hint keeps saying "upgrade Node" because it describes what is wrong on the
  # machine, and that stays true; what changed is that clicking install no longer
  # stops at the diagnosis.
  #
  # The assertions follow the new contract: it must not try npm (reinstalling dsh
  # cannot help), and it must either download a Node or say exactly why it cannot.
  Check 'it does not try to reinstall dsh through npm' `
    ($text -notmatch 'already installed') $text.Trim()
  $attemptedNode = $text -match 'no usable Node found' -or $text -match 'downloading Node'
  Check 'it sets about providing a Node' $attemptedNode $text.Trim()
  Check 'and says why it stopped, when it has to' `
    ($attemptedNode -and ($text -match 'cannot be verified' -or $text -match 'could not provide a Node runtime' -or $text -match 'installed')) $text.Trim()
  Check 'and npm is never invoked' ($calls.Count -eq 0) "npm calls: $($calls.Count) -> $($calls -join ' | ')"

  # The human-readable path must carry the verdict too. It used to discard it
  # ("it already printed the detail") and exit 0, so a caller could not tell a
  # failed install from a successful one - while the -Json branch, above, got
  # that right. Both are asserted because they are separate code paths.
  $rj = Invoke-Launcher @('-Command', 'install', '-Target', 'local', '-Json', '-Config', $config) $null -NodeMode 'old'
  Check '-Json answers ok:false' ($rj.Out -match '"ok":false') "stdout: $($rj.Out.Trim())"
  Check '-Json exits non-zero' ($rj.Code -ne 0) "exit=$($rj.Code)"
  Check 'the plain output exits non-zero as well' ($r.Code -ne 0) "exit=$($r.Code)"

  # Put the sandbox back the way section 5 expects it.
  Remove-Item (Join-Path $fakeAppData 'npm\node_modules') -Recurse -Force -ErrorAction SilentlyContinue

  # -------------------------------------------------------------------------
  # 5. the panel routes a local install calls
  # -------------------------------------------------------------------------
  Write-Host "`n=== 5. the install preview speaks about the right machine ==="
  # The assertion is on the ROUTE, with a real backend running, because reading
  # server.js as text only proves a string exists somewhere in the file. The
  # backend is started from the clone, and DSH_LAUNCHER_CONFIG points it at the
  # scratch config, so the instance it reports is the sandbox one; it is stopped
  # again before the test ends.
  # The real node, resolved here: section 2 used to copy it into the sandbox and
  # no longer does, so $nodeExe was empty and Start-Process rejected it.
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $nodeExe) { Write-Host '  SKIP  node not found, cannot start a backend'; }
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

  # -------------------------------------------------------------------------
  # 7. and nothing was installed on this machine
  # -------------------------------------------------------------------------
  Write-Host "`n=== 7. the host is unchanged ==="
  $managedAfter = @(if (Test-Path $realManaged) { Get-ChildItem $realManaged -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } })
  Check 'no managed Node appeared in the real LOCALAPPDATA' `
    ($managedAfter.Count -eq $managedBefore.Count) "before=[$($managedBefore -join ',')] after=[$($managedAfter -join ',')]"
  Check 'the sandbox managed-Node root was left empty too (nothing was downloaded)' `
    (-not (Test-Path (Join-Path $fakeLocalAppData 'dsh-deck\node'))) `
    "found: $(Join-Path $fakeLocalAppData 'dsh-deck\node')"
} finally {
  Remove-Scratch
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
