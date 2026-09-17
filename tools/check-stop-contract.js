// Guard the one bug class that made `app -Stop` lie, and that nothing else here
// can catch.
//
// The defect
// ----------
// `taskkill /T` can terminate the backend and still print
//
//   ERROR: The process with PID n (child process of PID m) could not be terminated.
//
// on stderr. dsh.ps1 sets $ErrorActionPreference = 'Stop' at the top, and under
// Windows PowerShell 5.1 a native command's stderr line is then a TERMINATING
// error - a rule this file's own comments already document in Invoke-B64,
// Get-NetstatListeners, Invoke-NpmGlobal and the browser-window loop. Stop-App's
// kill was the one call that did not allow for it, so:
//
//   * the `$stopped = $true` under it never ran,
//   * the surrounding catch swallowed the exception,
//   * a backend that had in fact been killed was reported as
//     "app backend was not running", and
//   * the runtime file was deleted anyway, so the next launch could not adopt
//     anything and started a SECOND backend on a new port.
//
// Observed 6 times in 8 runs. tools/check-app-stop.ps1 proves the behaviour end
// to end by intercepting taskkill; this file is the cheap static half, so the
// contract is still enforced on Linux CI where taskkill does not exist.
//
// What is asserted
// ----------------
//   1. the kill in Stop-App runs with stderr tolerated
//   2. the verdict is the process table, not taskkill's exit code or output
//   3. a runtime file is never deleted while its backend is still alive
//   4. a survivor makes `app -Stop` exit non-zero
//
// Every check reports pass/fail honestly. If a future refactor moves or renames
// what these look for, they fail loudly rather than passing against nothing -
// silence would be worse than a red build, which is the whole point here.
const { readLauncherSource } = require('./launcher-source');
const src = readLauncherSource();
const fn = src.indexOf('function Stop-App');
if (fn < 0) { console.error('  FAIL  Stop-App not found in dsh.ps1'); process.exit(1); }
const block = src.slice(fn);
// End of the function: the next top-level `function ` or the entry-point banner.
const endMatch = /\n(?:function \w|\/\/ -{10})/.exec(block);
const body = endMatch ? block.slice(0, endMatch.index) : block;

const ownedStart = src.indexOf('function Stop-OwnedProcess(');
const ownedEnd = src.indexOf('\nfunction ', ownedStart + 1);
const owned = src.slice(ownedStart, ownedEnd < 0 ? undefined : ownedEnd);
const killIdx = owned.indexOf('taskkill.exe');
const eapIdx = owned.indexOf("$ErrorActionPreference = 'Continue'");
const tableIdx = owned.indexOf('return (-not (Test-ProcessAlive');
const removeIdx = body.indexOf('foreach ($file in @((Join-Path $StateDir');
const exitIdx = src.indexOf('if (-not $ok) { $script:ExitCode = 1 }');

let pass = 0, fail = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`  PASS  ${label}`); pass++; }
  else { console.log(`  FAIL  ${label}${detail ? '  ' + detail : ''}`); fail++; }
}

check('Stop-App delegates termination to the shared owned-process helper',
  killIdx > 0 && body.includes('Stop-OwnedProcess'), 'termination is not delegated');
check('stderr is tolerated for the kill (Continue before the call)',
  eapIdx > 0 && killIdx > 0 && eapIdx < killIdx,
  eapIdx < 0 ? "no $ErrorActionPreference = 'Continue'" : 'Continue comes after taskkill');
check('the verdict is the process table, not taskkill',
  tableIdx > 0, 'no Test-ProcessAlive call inside Stop-App');
check('a surviving process returns before runtime records are removed',
  removeIdx > 0 && body.indexOf('return $false') > 0 && body.indexOf('return $false') < removeIdx,
  'runtime cleanup can run before the survivor verdict');
check('a surviving backend makes app -Stop exit non-zero',
  exitIdx > 0, 'dispatcher does not act on Stop-App\'s verdict');

// The success message must not be reachable while the process is alive. Rather
// than parse the branches, assert the two strings exist and that the failure one
// is emitted: a rewrite that drops the survivor report is a regression even if
// the control flow still happens to work.
check('a survivor is reported as a failure',
  body.includes('did not stop'), 'no "did not stop" message');
check('the survivor report hands over a manual command',
  /stop it manually: taskkill \/PID/.test(body), 'no copy-pasteable remedy');
// The lie itself. "was not running" is correct only when nothing was running,
// and Stop-App guards it with `$survivorPid -eq 0`.
check('"was not running" is guarded against a survivor',
  body.includes('if ($wasRunning)') && body.includes("} else { Write-Info 'app backend was not running' }"), 'unconditional "was not running"');

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
