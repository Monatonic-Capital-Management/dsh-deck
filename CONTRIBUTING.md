# Contributing

Thanks for looking. This is a small tool with a narrow purpose, and the most
useful contributions are usually bug reports with a clear failure description.

## Before you start

```powershell
git clone https://github.com/Monotonic-Capital-Management/dsh-deck.git
cd dsh-deck
.\dsh.ps1 -Command app        # panel with a single local instance
.\dsh.ps1 -Command doctor     # environment check
```

No build step and no dependencies. `app/server.js` is required by CI to use only
Node builtins — please keep it that way, since "clone and run" is a feature.

## The traps that will actually bite you

**1. `.ps1` files must keep their UTF-8 BOM.** Windows PowerShell 5.1 decodes a
BOM-less file as ANSI, which turns the Chinese UI strings into mojibake and often
stops the file parsing entirely:

```
Unexpected token '鏈嶅姟绔繍琛屼腑' in expression or statement.
```

Many editors and patch tools silently strip the BOM when they write a file, so
this is not a one-off mistake you make and learn from — it comes back. After
editing any `.ps1`:

```powershell
.\tools\fix-bom.ps1
```

CI fails the build if any `.ps1` lacks a BOM, so a missed case cannot reach `main`.

**2. Never pass a trailing switch after a positional target.** `$Target` does not
accept remaining arguments precisely because `ValueFromRemainingArguments` swallows
trailing switches into it, silently dropping them:

```powershell
.\dsh.ps1 start prod -Json      # WRONG: -Json lands in $Target
.\dsh.ps1 -Command start -Target prod -Json   # right
```

**3. Bash scripts are always single-quoted here-strings.** Inside `@"..."@`,
PowerShell expands `$(...)` and `$VAR` locally, before anything reaches the remote
host, producing an error that looks like a bash bug. Use `@'...'@` and substitute
placeholders afterwards if you need values injected.

## House style

**Comments explain why, not what.** The code already says what it does. What is
worth writing down is the constraint, the failure that motivated the line, or the
alternative that was rejected. Example from `dsh.ps1`:

```powershell
# UseShellExecute = true is what actually detaches the backend: no inherited
# handles, so it survives this console exiting. Redirecting the child's
# stdout/stderr (the earlier approach) left it holding our pipe handles -- it
# reported ready, then died the moment the launcher exited.
```

**Failures must be explained.** This project exists because a launcher reported
success and nothing worked. When adding a failure path, name the likely cause and
the next action: "needs a VPN" is useful, "unreachable" is not.

**Verify the end state.** Before reporting success, check the thing that matters —
does the port listen, does the binary print a version, does the token redeem —
rather than trusting that a command exited 0. See [docs/lessons.md](docs/lessons.md)
for thirteen occasions where that distinction mattered.

**Bash is always a single-quoted here-string.** In a double-quoted `@"..."@`,
PowerShell expands `$(...)` and `$VAR` locally before the script ever reaches the
remote host.

## Testing

The suites live in `tools/` and CI runs all of them except the two that need a
deployment (`check-panel.ps1`, which asserts on the author's own instance names,
and the live half of `check-status-cache.js`, which skips itself when no backend
is up).

```powershell
node tools\check-ui.js              # panel rendering logic, extracted from index.html
node tools\check-status-cache.js    # the status cache's three guarantees
node tools\check-stop-contract.js   # app -Stop's verdict contract (static, cross-platform)
node tools\check-no-deps.js         # the backend uses only Node builtins
.\tools\fix-bom.ps1                 # BOM + parse gate, under PowerShell 5.1
.\tools\check-app-stop.ps1          # Windows: app -Stop end to end, against a real panel
.\tools\check-local-install.ps1     # Windows: local install / missing-dsh reporting
.\tools\check-node-bootstrap.ps1    # Windows: the Node runtime it downloads for itself
.\tools\check-remote-node.ps1       # Windows+Git Bash: host provisioning verifies its download
.\tools\check-local-card.ps1        # local-only: the local card, in a real browser
```

The last one needs Chrome or Edge and is not in CI; it drives the panel through
CDP and asserts on the DOM. It earned its place on the first run: the card
rendered correctly but also carried "发现新版本 0.1.5-rc.1（当前 ?）" with an 升级
button, on a machine with no dsh to upgrade.

`check-app-stop.ps1` is worth knowing about before you touch `Stop-App`. It
compiles a shim named `taskkill.exe` that forwards to the real one and then
prints the `could not be terminated` line on stderr — the exact thing that made
`app -Stop` report a killed backend as "was not running". Point it at any
launcher to check the test is still meaningful:

```powershell
.\tools\check-app-stop.ps1 -LauncherPath <path to a dsh.ps1>
```

Against the pre-fix launcher it fails 12 of 24 checks, which is the only real
evidence that the suite can see the bug it was written for.

## Start.exe is a generated artifact

`Start.exe` is committed so a fresh clone has a double-clickable entry point
carrying the panel's icon, and so a shortcut can point at a file that is
actually in the repo rather than at absolute paths baked into a `.lnk`. It is
built from `tools\exe\DshDeck.cs`:

```powershell
.\tools\build-exe.ps1 -Verify
```

**Rebuild it whenever `dsh.ps1`, `app\server.js`, `app\ui\index.html` or the
icon changes**, or the committed binary ships a stale panel. The script compares
timestamps and skips the work when nothing moved, so running it before a commit
is cheap. CI cannot check this for you — the exe is a binary — which is exactly
why the build is one command with no SDK, no Visual Studio and no NuGet: csc.exe
from the .NET Framework is enough. `-Verify` inspects the built file for the
embedded resource names and the icon, the parts that fail invisibly.

Two traps in that area, both already paid for:

- **Resource names are embedded verbatim.** csc's `-resource:<file>,<name>` does
  not prefix `<name>` with the root namespace; that belongs to `.resx`
  compilation, a different code path. `DshDeck.cs` searches for `payload/...`,
  which is exactly what the build script passes.
- **`$target` in `install-shortcut.ps1` was the shortcut's own path.** Reusing
  that name for the link's target made the shell refuse to save a
  self-referential shortcut, and the failure surfaced as a bare COMException.
  The variables are now `$lnkFile` and `$targetPath`.

## Sandboxing a launcher test

`check-local-install.ps1` and `check-app-stop.ps1` both hide something the
launcher looks for, and both were wrong at first in the same direction: the
sandbox leaked and the test quietly measured the host instead of the sandbox.

What it takes to actually hide dsh, in the order `Find-DshLocal` looks:

| What it checks | How to close it |
| --- | --- |
| `%USERPROFILE%\.npmrc` for a `prefix=` line | set `USERPROFILE` to a scratch dir |
| `%APPDATA%\npm` | set `APPDATA` to a scratch dir |
| `npm root -g` | stub `npm.exe` earlier on PATH, answering that one subcommand |
| `Get-Command dsh` | keep the real PATH out of the child |

The `$USERPROFILE` row is the easy one to miss and the one that cost the most
time: `dsh.ps1` derives `$HomeDir` from it at startup, and a real `~/.npmrc`
with a custom prefix sends every lookup straight back to the real install.

Two more things that only work one way:

- **A stub must be a real executable.** `& taskkill.exe` and `& node` resolve an
  exact file-name match before PATHEXT, so a `.cmd` on PATH does not win — hence
  the compiled C# shims. Measured, twice.
- **Patch a mutant in a copy, never in place.** Rewriting a `.ps1` from
  PowerShell drops the UTF-8 BOM unless you write the bytes back explicitly, and
  mutation-testing the real file one time left it unparseable for the rest of the
  run; `fix-bom.ps1` caught it, which is exactly why that gate exists.

## A test must never install anything on the host

This one is not a style preference. Once `Install-LocalDsh` could fetch a Node
runtime, the section of `check-local-install.ps1` that runs with an empty PATH
reached the **real** `%LOCALAPPDATA%` and downloaded a real 34 MB Node onto the
machine — silently, during a test run. Two things came out of it:

- the harness now fakes `LOCALAPPDATA` too, and `DSH_NODE_MIRROR` points at an
  empty sandbox directory so any download attempt fails on a missing file rather
  than reaching the network;
- section 0 and section 7 assert the sandbox holds, comparing the real managed-Node
  directory before and after. A test that modifies the host is worse than a test
  that fails, because nothing tells you.

`check-node-bootstrap.ps1` follows the same rule from the other direction: it
serves a *synthetic* nodejs.org from a local directory, so the download, checksum,
extraction and refusal paths are all exercised while nothing leaves the machine.
That is also the only way to test the failures that matter — a tampered zip, an
unlisted zip, an unreachable checksum list.

`check-remote-node.ps1` does the same for the **remote** path: it extracts the
bash the launcher runs on a host and executes it under **Git Bash**, which ships
sha256sum, awk, curl and tar — everything that script touches. `HOME` points at a
scratch directory so the shell-profile edits stay in the sandbox, and
`tools/fake-nodejs-server.js` serves a synthetic `nodejs.org/dist`. That makes a
tampered tarball, an unlisted one, and an unfetchable checksum list all testable.

Two things that bit while writing these, both worth knowing:

- **Windows paths must reach bash as `/c/...`.** Git Bash's tar reads `C:/x` as a
  remote host named `C` and fails with "Cannot connect to C: resolve failed" —
  a harness problem that looks exactly like a product problem.
- **A stub `node.exe` has to answer a script FILE, not just `-v`.** Once the
  launcher decided usability by running a probe, a fixture that only printed
  versions made every install look broken. The failure was correct; the fixture
  was stale.

If you add tests, the highest-value target remains `app/server.js` — pure
functions like `parseJson` and `Compare-Version` are easy to cover and have
already carried bugs.

Manual smoke test before opening a pull request:

```powershell
.\dsh.ps1 -Command status               # all instances report sanely
.\dsh.ps1 -Command app                  # panel opens, cards clickable
.\dsh.ps1 -Command app -Stop            # exits 0 AND the backend is really gone
.\dsh.ps1 -Command install -Target local # no-op when dsh is present, and says so
.\dsh.ps1 -Command doctor               # no unexpected errors
.\dsh.ps1 -Command start -Target local  # lifecycle still works
.\Start.exe                             # the double-click path still works
```

## Reporting a bug

Please include:

- what you ran, and what happened instead of what you expected;
- `.\dsh.ps1 -Command doctor` output (review it for hostnames first);
- for remote problems, `.\dsh.ps1 -Command logs -Target <name> -Lines 100`;
- your Windows and PowerShell version, and the `dsh --version` on both ends.

## Scope

This is a **launcher**. Changes to dsh itself belong upstream. Features that
expose dsh beyond loopback, store credentials, or add a hosted component will be
declined — see the "explicitly not doing" section of
[docs/roadmap.md](docs/roadmap.md).
