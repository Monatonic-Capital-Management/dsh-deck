# check-app-stop.ps1 - does `app -Stop` tell the truth about stopping the panel?
#
# Why this file exists
# --------------------
# `app -Stop` reported "app backend was not running" while the backend was in
# fact still alive and still listening, in 6 of 8 observed runs. The cause was
# `taskkill /T` printing
#
#   ERROR: The process with PID n (child process of PID m) could not be terminated.
#
# on stderr AFTER it had already killed the parent. With $ErrorActionPreference
# = 'Stop' at the top of dsh.ps1, that stderr line is a terminating error (the
# same rule Invoke-B64 and Get-NetstatListeners already document), so the
# `$stopped = $true` under it never ran, the surrounding catch swallowed the
# exception, the runtime file was deleted anyway, and the next launch started a
# SECOND backend instead of adopting the live one.
#
# How it is reproduced deterministically
# --------------------------------------
# Waiting for the real race to happen is not a test: it was intermittent, it
# needed the panel to have spawned its own balance/tray poll children first, and
# a suite that fails 6 times in 8 is as likely to pass against broken code as
# against fixed code.
#
# So `taskkill.exe` is intercepted: a shim compiled from C# to a real console
# executable (named taskkill.exe, because that is the name dsh.ps1 invokes)
# forwards to the real one and then injects exactly the stderr line above. That
# reproduces the failure with the kill itself SUCCEEDING - the interesting case,
# and the one the old code got wrong. A second mode makes the kill genuinely
# fail ("Access is denied", nothing killed), which is the other half of the
# contract: a survivor must be reported as a failure, must not lose its runtime
# file, and must not be forgotten.
#
# Nothing here touches the user's own instances: the launcher is run from a
# throwaway copy, so its state/, logs/ and config all live inside that copy.
#
# Usage:  powershell -File tools\check-app-stop.ps1   (Windows only)
[CmdletBinding()]
param(
  # Keep the throwaway copy around for inspection after a failure.
  [switch]$KeepTemp,

  # Launcher to test. Defaults to this checkout's dsh.ps1; pointed elsewhere it
  # answers "does this suite actually fail against the broken code?", which is
  # the only way to know the test is worth running. See the note in README.
  [string]$LauncherPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-launcher-contracts.ps1') -HelpersOnly

if ($env:OS -ne 'Windows_NT') {
  Write-Host '  SKIP  app -Stop is Windows-only (taskkill); nothing to check here'
  exit 0
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcLauncher = if ($LauncherPath) { (Resolve-Path $LauncherPath).Path } else { Join-Path $repoRoot 'dsh.ps1' }
if (-not (Test-Path $srcLauncher)) { Write-Host "  FAIL  no launcher at $srcLauncher"; exit 1 }
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else     { $script:fail++; Write-Host ("  FAIL  {0}" -f $Name) }
}

$realTaskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
if (-not (Test-Path $realTaskkill)) {
  Write-Host "  FAIL  cannot find $realTaskkill"
  exit 1
}

# ---------------------------------------------------------------------------
# Scratch area: a copy to run the launcher from, and a stub to intercept with.
# ---------------------------------------------------------------------------
$scratch = Join-Path $env:TEMP ("dshdeck-stopcheck-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$clone   = Join-Path $scratch 'clone'
$stubDir = Join-Path $scratch 'stub'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null

function Remove-Scratch {
  # Kill anything the test started before deleting its directory, or a surviving
  # backend keeps running from a deleted path - the exact orphan this suite is
  # about, and not something to leave on the machine running it.
  foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -like "*$scratch*" })) {
    try { $null = & $realTaskkill /PID $p.ProcessId /T /F 2>&1 } catch { }
  }
  if ($KeepTemp) { Write-Host "  kept: $scratch"; return }
  Start-Sleep -Milliseconds 500
  for ($i = 0; $i -lt 5; $i++) {
    try { Remove-Item $scratch -Recurse -Force -ErrorAction Stop; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
}

try {
  # Copied rather than git cloned: this runs from a checkout that may hold
  # uncommitted work, and the point is to test the files in front of you.
  Write-Host "`n=== setup: throwaway launcher in $scratch ==="
  Write-Host "  launcher under test: $srcLauncher"
  $null = New-Item -ItemType Directory -Force -Path $clone
  foreach ($item in @('dsh.cmd')) {
    Copy-Item -Path (Join-Path $repoRoot $item) -Destination $clone -Recurse -Force
  }
  Copy-Item -Path $srcLauncher -Destination (Join-Path $clone 'dsh.ps1') -Force
  Copy-LauncherTestModules $srcLauncher $clone
  New-Item -ItemType Directory -Path (Join-Path $clone 'app') -Force | Out-Null
  $fakeServer = @'
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = path.resolve(__dirname, '..');
const scratch = path.dirname(root);
if (process.env.DSH_TEST_APP_MODE === 'exit') process.exit(7);
const server = http.createServer((req, res) => { res.writeHead(200); res.end('isolated fixture'); });
server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const token = crypto.randomBytes(24).toString('hex');
  fs.mkdirSync(path.join(root, 'state'), {recursive:true});
  fs.writeFileSync(path.join(root, 'state', 'app.json'), JSON.stringify({pid:process.pid,port,token,url:`http://127.0.0.1:${port}/#t=${token}`,startedAt:new Date().toISOString(),configPath:process.env.DSH_LAUNCHER_CONFIG||'',sshConfigPath:process.env.DSH_SSH_CONFIG||''}));
  fs.writeFileSync(path.join(scratch, 'context-check.json'), JSON.stringify({config:process.env.DSH_LAUNCHER_CONFIG===path.join(scratch,'hosts.json'),ssh:process.env.DSH_SSH_CONFIG===path.join(scratch,'ssh-config'),noAccountKey:!process.env.DEEPSEEK_API_KEY}));
});
'@
  [IO.File]::WriteAllText((Join-Path $clone 'app\server.js'), $fakeServer, (New-Object Text.UTF8Encoding($false)))
  $nodeCommand = Get-Command node -ErrorAction Stop
  $testNodeDir = Join-Path $scratch 'node'
  New-Item -ItemType Directory -Path $testNodeDir -Force | Out-Null
  Copy-Item -LiteralPath $nodeCommand.Source -Destination (Join-Path $testNodeDir 'node.exe')
  $envSetup = New-Object Diagnostics.ProcessStartInfo
  Set-LauncherTestEnvironment $envSetup $scratch $clone
  [IO.File]::WriteAllText((Join-Path $scratch 'hosts.json'), '{"version":1,"instances":[]}', (New-Object Text.UTF8Encoding($true)))

  $realPathFile = Join-Path $stubDir 'real-taskkill.txt'
  Set-Content -Path $realPathFile -Value $realTaskkill -Encoding ASCII
  $marker = Join-Path $stubDir 'invoked.txt'
  # The interceptor has to be a REAL executable named taskkill.exe.
  #
  # A .cmd earlier on PATH does NOT win: dsh.ps1 invokes the literal name
  # "taskkill.exe", and PowerShell resolves an exact file-name match before it
  # ever considers PATHEXT, so `& taskkill.exe` kept reaching
  # C:\Windows\System32\taskkill.exe and the stub was never called. Measured,
  # not assumed: with the stub directory first on PATH, Get-Command still
  # reported the System32 binary, and a batch file wearing an .exe name is
  # rejected by CreateProcess as "not a valid application for this OS platform".
  #
  # So the shim is compiled from C# into a console application. It writes the
  # marker, acts according to DSH_STUB_TASKKILL_MODE, and otherwise forwards to
  # the real taskkill and relays its exit code, stdout and stderr - which makes
  # the error line below arrive at the launcher exactly as the real one does.
  $stubExe = Join-Path $stubDir 'taskkill.exe'
  $shimSrc = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public class TaskKillShim {
  public static int Main(string[] args) {
    string dir = AppDomain.CurrentDomain.BaseDirectory;
    string mode = (Environment.GetEnvironmentVariable("DSH_STUB_TASKKILL_MODE") ?? "").Trim().ToLowerInvariant();
    try { File.AppendAllText(Path.Combine(dir, "invoked.txt"), string.Join(" ", args) + Environment.NewLine); }
    catch { }

    if (mode == "denied") {
      // Nothing is killed, and the message is the one taskkill uses when it is
      // refused: this is the "backend really did survive" half of the contract.
      Console.Error.WriteLine("ERROR: The process with PID 12345 could not be terminated.");
      Console.Error.WriteLine("ERROR: Access is denied.");
      return 1;
    }

    string allowed = File.ReadAllText(Path.Combine(dir, "allowed-pid.txt")).Trim();
    int index = Array.FindIndex(args, delegate(string a) { return a.Equals("/PID", StringComparison.OrdinalIgnoreCase); });
    if (index < 0 || index + 1 >= args.Length || args[index + 1] != allowed || allowed == "0") return 5;
    string real = File.ReadAllText(Path.Combine(dir, "real-taskkill.txt")).Trim();
    int code = 0;
    try {
      ProcessStartInfo psi = new ProcessStartInfo(real);
      StringBuilder argline = new StringBuilder();
      foreach (string a in args) {
        if (argline.Length > 0) argline.Append(' ');
        argline.Append('"').Append(a).Append('"');
      }
      psi.Arguments = argline.ToString();
      psi.UseShellExecute = false;
      psi.RedirectStandardOutput = true;
      psi.RedirectStandardError = true;
      using (Process p = Process.Start(psi)) {
        string o = p.StandardOutput.ReadToEnd();
        string e = p.StandardError.ReadToEnd();
        p.WaitForExit();
        code = p.ExitCode;
        if (o.Length > 0) Console.Out.Write(o);
        if (e.Length > 0) Console.Error.Write(e);
      }
    } catch (Exception ex) {
      Console.Error.WriteLine("shim could not run " + real + ": " + ex.Message);
      return 1;
    }

    if (mode == "noisy") {
      // The exact line the real taskkill printed in production, AFTER it had
      // already terminated the parent. This is the whole defect in one line.
      Console.Error.WriteLine("ERROR: The process with PID 99999 (child process of PID 11111) could not be terminated.");
    }
    return code;
  }
}
"@
  try {
    Add-Type -TypeDefinition $shimSrc -OutputAssembly $stubExe -OutputType ConsoleApplication -ErrorAction Stop
  } catch {
    Write-Host "  FAIL  could not compile the taskkill shim: $($_.Exception.Message)"
    throw
  }

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------
  function Read-Runtime {
    $f = Join-Path $clone 'state\app.json'
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
  }
  function Test-Alive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    return [bool](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue)
  }

  # Run the launcher in a separate process with the stub on PATH, so the test
  # reads the real exit code and the real stdout/stderr instead of capture
  # artefacts of its own shell.
  function Invoke-Launcher([string[]]$Arguments, [string]$StubMode, [string]$AppMode) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $clone 'dsh.ps1')`"") + $Arguments) -join ' '
    $psi.WorkingDirectory = $clone
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    Set-LauncherTestEnvironment $psi $scratch $clone
    $psi.EnvironmentVariables['PATH'] = "$stubDir;$testNodeDir;$env:WINDIR\System32;$env:WINDIR\System32\WindowsPowerShell\v1.0"
    $psi.Arguments += ' -NoOpen'
    $runtime = Read-Runtime
    $allowedPid = if ($runtime) { [int]$runtime.pid } else { 0 }
    [IO.File]::WriteAllText((Join-Path $stubDir 'allowed-pid.txt'), [string]$allowedPid)
    if ($StubMode) { $psi.EnvironmentVariables['DSH_STUB_TASKKILL_MODE'] = $StubMode }
    if ($AppMode) { $psi.EnvironmentVariables['DSH_TEST_APP_MODE'] = $AppMode }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(120000) | Out-Null
    return [pscustomobject]@{ Code = $proc.ExitCode; Out = $out; Err = $err; Text = ($out + $err) }
  }

  # -------------------------------------------------------------------------
  # 0. a clean start, and proof the stub is the taskkill the launcher calls
  # -------------------------------------------------------------------------
  Write-Host "`n=== 0. the interception is in place ==="
  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $r = Invoke-Launcher @('-Command', 'app', '-Json') $null
  Check 'app starts on a clean checkout' ($r.Code -eq 0)
  if ($r.Code -ne 0) {
    $failure = Read-LauncherTestJson $r.Out
    if ($failure) { Write-Host ('  startup failure: ' + $failure.message) }
    throw 'isolated app setup failed; dependent stop checks not run'
  }
  $rt = Read-Runtime
  Check 'a runtime file records the backend pid' ([bool]($rt -and $rt.pid))
  $backendPid = 0
  if ($rt -and $rt.pid) { $backendPid = [int]$rt.pid }
  Check 'the recorded pid is actually running' (Test-Alive $backendPid) "pid=$backendPid"
  $context = Get-Content -LiteralPath (Join-Path $scratch 'context-check.json') -Raw | ConvertFrom-Json
  Check 'config and SSH context reach backend environment' ($context.config -and $context.ssh)
  Check 'account keys were not inherited by the fixture backend' $context.noAccountKey
  Check 'NoOpen did not create a browser profile' (-not (Test-Path -LiteralPath (Join-Path $clone 'browser-profile')))
  $alternate = Join-Path $scratch 'alternate.json'
  [IO.File]::WriteAllText($alternate, '{"version":1,"instances":[]}', (New-Object Text.UTF8Encoding($true)))
  $different = Invoke-Launcher @('-Command','app','-Json','-Config',$alternate) $null
  Check 'different config context is not silently reused' ($different.Code -ne 0 -and (Test-Alive $backendPid))

  # -------------------------------------------------------------------------
  # 1. the original defect: taskkill kills the backend AND complains on stderr
  # -------------------------------------------------------------------------
  Write-Host "`n=== 1. taskkill succeeds but writes the 'could not be terminated' line ==="
  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $r = Invoke-Launcher @('-Command', 'app', '-Stop') 'noisy'
  Check 'the stub intercepted taskkill' (Test-Path $marker) "no marker at $marker"
  Check 'stop succeeds when the backend really did die' ($r.Code -eq 0) "exit=$($r.Code)"
  Check 'the pid is gone afterwards' (-not (Test-Alive $backendPid)) "pid $backendPid still alive"
  Check 'the stop is reported as a stop' ($r.Text -match 'app backend stopped') $r.Text.Trim()
  # The old code printed "app backend was not running" here, because it judged
  # itself by taskkill's stderr instead of by the process table.
  Check 'it does not claim the backend was never running' ($r.Text -notmatch 'was not running') $r.Text.Trim()
  Check 'the runtime file is cleaned up once the process is gone' (-not (Test-Path (Join-Path $clone 'state\app.json')))

  # -------------------------------------------------------------------------
  # 2. a backend that survives must be reported as a failure, and remembered
  # -------------------------------------------------------------------------
  Write-Host "`n=== 2. taskkill fails and the backend survives ==="
  $r = Invoke-Launcher @('-Command', 'app') $null
  $rt = Read-Runtime
  $survivorPid = 0
  if ($rt -and $rt.pid) { $survivorPid = [int]$rt.pid }
  Check 'a fresh backend is up to survive with' (Test-Alive $survivorPid) "pid=$survivorPid"

  $r = Invoke-Launcher @('-Command', 'app', '-Stop') 'denied'
  Check 'a failed stop exits non-zero' ($r.Code -ne 0) "exit=$($r.Code)"
  Check 'the surviving pid is still alive' (Test-Alive $survivorPid) "pid $survivorPid died unexpectedly"
  Check 'the failure is stated, not swallowed' ($r.Text -match 'did not stop') $r.Text.Trim()
  Check 'the report names the surviving pid' ($r.Text -match "$survivorPid") $r.Text.Trim()
  Check 'the report hands over a manual command' ($r.Text -match "taskkill /PID $survivorPid") $r.Text.Trim()
  Check 'it does not claim the backend was never running' ($r.Text -notmatch 'was not running') $r.Text.Trim()

  # The runtime file is the only record that makes the survivor adoptable, so a
  # failed stop must leave it in place - deleting it is what turned one orphan
  # into a second backend on a second port.
  $rt = Read-Runtime
  Check 'the runtime file survives a failed stop' ([bool]$rt) 'app.json was deleted'
  Check 'and still points at the survivor' ([bool]($rt -and [int]$rt.pid -eq $survivorPid)) "app.json pid=$(if($rt){$rt.pid}else{'none'})"

  # -------------------------------------------------------------------------
  # 3. recovery: with the runtime file intact, the next launch adopts it
  # -------------------------------------------------------------------------
  Write-Host "`n=== 3. the survivor is not lost: the next launch adopts it ==="
  $r = Invoke-Launcher @('-Command', 'app') $null
  $rt = Read-Runtime
  Check 'the second launch adopts the same backend' ([bool]($rt -and [int]$rt.pid -eq $survivorPid)) "now pid=$(if($rt){$rt.pid}else{'none'})"
  $all = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -and $_.CommandLine -like "*$clone*" })
  Check 'no second backend was stacked' ($all.Count -eq 1) "$($all.Count) backends: $(($all | ForEach-Object ProcessId) -join ',')"

  # -------------------------------------------------------------------------
  # 4. a clean stop still works, and a second stop is a no-op that says so
  # -------------------------------------------------------------------------
  Write-Host "`n=== 4. ordinary stop, then stopping nothing ==="
  $r = Invoke-Launcher @('-Command', 'app', '-Stop') $null
  Check 'a clean stop exits zero' ($r.Code -eq 0) "exit=$($r.Code)"
  Check 'the pid is gone' (-not (Test-Alive $survivorPid)) "pid $survivorPid still alive"
  $r = Invoke-Launcher @('-Command', 'app', '-Stop') $null
  Check 'stopping an app that is not running exits zero' ($r.Code -eq 0) "exit=$($r.Code)"
  Check 'and says it was not running' ($r.Text -match 'was not running') $r.Text.Trim()
  $r = Invoke-Launcher @('-Command','app','-Json') $null 'exit'
  Check 'backend exiting before ready makes app fail nonzero' ($r.Code -ne 0 -and (Read-LauncherTestJson $r.Out).ok -eq $false)
} finally {
  Remove-Scratch
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
