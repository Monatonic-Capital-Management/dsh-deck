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

There is no test suite yet; verification so far has been end to end against real
hosts. If you add tests, the highest-value target is `app/server.js` — pure
functions like `parseJson` and `Compare-Version` are easy to cover and have
already carried bugs.

Manual smoke test before opening a pull request:

```powershell
.\dsh.ps1 -Command status               # all instances report sanely
.\dsh.ps1 -Command app                  # panel opens, cards clickable
.\dsh.ps1 -Command doctor               # no unexpected errors
.\dsh.ps1 -Command start -Target local  # lifecycle still works
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
