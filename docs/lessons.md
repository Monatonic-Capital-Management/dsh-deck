# Lessons

Every item here is a bug that actually happened while building this, cost real
debugging time, and is now guarded against in code or CI. They are written down
because most of them are **silent** failures: the program reports success and
nothing works.

## 1. A missing UTF-8 BOM breaks PowerShell 5.1 (not just the text)

`dsh.ps1` contains Chinese UI strings. Windows PowerShell 5.1 decodes a BOM-less
file using the current ANSI code page, so every Chinese character becomes
mojibake — and because some of those bytes land inside quotes, the file stops
parsing entirely:

```
Unexpected token '鏈嶅姟绔繍琛屼腑' in expression or statement.
```

The trap: the file is perfectly valid UTF-8, and editors that write UTF-8 without
a BOM silently introduce this. It happened twice during development, once via a
patch tool.

**Guarded by:** `tools/fix-bom.ps1` and a CI job that fails if any `.ps1` lacks a
BOM.

## 2. `ValueFromRemainingArguments` swallows trailing switches

With `[Parameter(ValueFromRemainingArguments = $true)] [string[]]$Target`, the
command

```
dsh.ps1 start prod -Json -NoOpen
```

binds `-Json` and `-NoOpen` **into `$Target`** as extra instance names. The
command runs, the switches are silently ignored, and the caller gets human text
where it expected JSON. No error, just missing behaviour.

**Rule:** no `ValueFromRemainingArguments`; always call with named parameters.

## 3. Locating JSON by "first bracket" finds the log prefix instead

The app backend parses the launcher's stdout. For mutating commands the launcher
prints progress lines *before* the JSON:

```
  [ok]   prod: tunnel up ...
[{"Name":"prod","State":"up"}]
```

Searching for the first `[` lands on the `[` of `[ok]`, so `JSON.parse` throws and
the caller concludes the operation failed — while it actually succeeded.

**Fix:** try every bracket position left to right, keep the first one that parses.
Log prefixes never parse.

## 4. The result of an action is not `rows[0]`

After starting instance `prod`, the launcher returns the status of **every**
instance. Reading the state from `rows[0]` reports whichever instance happens to
be first in the config — usually `local` — so stopping a remote instance looked
like a failure even though it worked.

**Fix:** look the result up by name.

## 5. dsh requires Node ≥ 22.19.0, and npm will not stop you

A transitive dependency (`@earendil-works/pi-ai`) declares `node >= 22.19.0`. On a
host with Node 20, `npm install -g @deepseek-ai/dsh` reports success, `added 522
packages`, exit code 0 — and then the binary produces **no output at all**:

```
$ dsh --version
$ echo $?
0
```

A presence check passes. An exit-code check passes. Nothing works.

**Fix:** verify the binary *runs* and prints a version, and install a suitable
Node into `~/.local/node` when the host's is too old.

## 6. `#!/usr/bin/env node` makes PATH the deciding factor

Related to the above and easy to miss: because dsh's shebang resolves `node` from
`PATH`, installing a good Node is not enough. The probe *and* the systemd unit
must both put `~/.local/node/bin` first, or dsh keeps finding the old system node
and keeps failing silently.

This is why "installed node 22" and "dsh runs" were two separate bugs.

## 7. Redirecting a child's stdout keeps it tied to your process

The app backend was started with `UseShellExecute = false` and redirected
stdout/stderr. It inherited the parent's pipe handles, so when the launcher
exited the pipes closed and the backend died on its next write. The symptom was
the worst kind: the launcher printed "app running on port NNNNN", the window
opened, and the browser showed `ERR_CONNECTION_REFUSED`.

**Fix:** `UseShellExecute = true` (no inherited handles) and the backend writes
its own log file.

## 8. PowerShell `Write-Host` mis-encodes under redirection

`[Console]::OutputEncoding` must be set explicitly. Otherwise PS 5.1 writes UTF-8
source text to a redirected stream as ANSI, and the app receives mojibake like
`app backend 杩愯涓`. The terminal looks fine; only the redirected path is broken.

## 9. Double-quoted here-strings interpolate your bash

```powershell
$script = @"
echo "OS=$(uname -s)"
"@
```

PowerShell evaluates `$(uname -s)` **locally**, on Windows, producing an empty
string — so the remote shell receives `echo "OS="` and a mangled follow-on line.
The failure surfaces as a confusing bash error, not as a PowerShell error.

**Rule:** every bash script is a single-quoted here-string (`@'...'@`), with
placeholders substituted afterwards.

## 10. `Get-HomeDir` before its definition

PowerShell executes a script top to bottom, so a script-scope function is not
callable until its definition has run. Calling one from the paths block threw
`Get-HomeDir is not recognized` even though the function existed further down.

## 11. StrictMode rejects reading an unset variable, including `$switch`

Under `Set-StrictMode -Version Latest`:

- `if ($Stop)` throws when `-Stop` was not passed.
- `$script:Cache` throws before first assignment.
- `$obj.missingProperty` throws for config keys that older files legitimately lack.

**Rule:** read optional parameters through `$PSBoundParameters`, pre-declare
caches, and access config keys via `PSObject.Properties[...]`.

## 12. Two listeners on one port

`Get-NetTCPConnection -LocalPort 3080 | Select -First 1` picked Termius bound to
`127.0.0.1:124`, and reported the port as "held by Termius" while dsh was happily
serving on `127.0.0.1`. Always filter by local address, not by "first result".

## 13. An orphaned process from a previous run blocks the next one

A service restart left the old dsh alive, still holding 3080. The new instance
could not bind, so it lingered as a stopped process while `systemctl` reported
`active` — two contradictory views of the same unit.

**Fix:** compare the pid that actually holds the port (`ss -ltnpH`) against the
unit's `MainPID`, and clear the orphan before restarting.

## 14. A process search that matches itself

The tray is found by scanning for its own command line:

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*-Command tray-loop*' }
```

Every process whose command line merely *contains* that text matches. That
includes any script that runs `dsh.ps1 -Command tray-loop`, and — the part that
cost real time — the very script doing the searching, because the pattern appears
in its own source. So the tool counted **itself** as a running tray, and a stop
would kill one tray and immediately "find" another.

Worse, the false positive was invisible: `$live.Count` was never zero, so every
code path looked correct while behaving nonsensically.

**Two fixes, both worth keeping:**
1. Anchor the match to the real invocation shape
   (`dsh\.ps1"?\s+-Command\s+tray-loop`) and exclude the current process.
2. Prefer a **pid file owned by the long-lived process itself**, which cannot be
   fooled this way. A parent-written pid file is not equivalent: it survives a
   crashed child and then reports a process that does not exist.

## 15. A default that performs an action

The tray endpoint read its action from the request and defaulted to `"start"`
when absent. An older cached page therefore POSTed with no action and silently
started a tray on every poll, which looked exactly like "stop is resurrecting the
tray". Two separate bugs — the stale page and the default — produced one
convincing illusion.

**Rule:** a mutating endpoint must reject a missing action; never default to the
one that changes state.

## 16. npm's exit code 0 does not mean the install works

Upgrading local dsh from `0.1.1-rc.2` to `0.1.5-rc.1` reported success, and
`npm ls -g` agreed: `@deepseek-ai/dsh@0.1.5-rc.1`. Then:

```
Error: Cannot find module './snippet'
  requireStack: [.../@deepseek-ai/dsh/node_modules/js-yaml/lib/loader.js]
```

`js-yaml` was missing `package.json` and six of its ten `lib/` files. On Windows a
running dsh holds native `.node`/`.dll` files open (`sharp`, `koffi`), so npm
cannot replace them and leaves a **half-extracted tree** while still recording the
new version. A retry with `--force` re-extracted it correctly.

The lesson is the same one as #5, in a different costume: **verify the thing
works, not that the installer said so.** For local dsh the check is "does
`dsh --version` print" — which the first version of `Upgrade-LocalDsh` did not
do, even though `Upgrade-RemoteDsh` already did. Inconsistency between a pair of
functions is a bug waiting to happen.

## 17. PowerShell 5.1 turns native stderr into a fatal error

With `$ErrorActionPreference = 'Stop'`, any stderr output from a native command
becomes a terminating error. npm prints deprecation notices on stderr as a matter
of course:

```
npm warn deprecated node-domexception@1.0.0: ...
```

So a completely successful `npm install -g` aborted the upgrade mid-function, and
the failure looked like an npm problem rather than a PowerShell one.

**Fix:** set `$ErrorActionPreference = 'Continue'` for the duration of the native
call and restore it afterwards. There is no per-invocation flag for this; the
preference is inherited by the child. The same trait is why `taskkill` needed
wrapping (see #14) — it writes "process not found" to stderr.

## The pattern

The majority of these produce a **success report followed by nothing working**.
That is why this project verifies the end state — does the port listen, does the
binary print a version, does the token redeem — instead of trusting that a step
"returned 0".
