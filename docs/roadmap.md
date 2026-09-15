# Roadmap

A product view of what this tool is, what shipped in v0.1, and what should come
next. Kept deliberately opinionated: each item names the user pain it removes,
because "add a feature" is not a roadmap.

## The one-sentence product

> dsh is a great agent, but getting to it is friction: start a server, keep a
> terminal open, build an SSH tunnel, re-derive an auth URL, and do it again on
> every machine. This tool makes *reaching* dsh one click, everywhere.

The value is not in launching a process. It is in **removing the tax between
intent and a working session**, and in making a fleet of dsh instances feel like
one product.

## Who this is for

Two users, and they want different things:

1. **The single-machine user.** Wants a double-click and a working UI. Cares
   about nothing else. Must never see a config file.
2. **The multi-machine user** (this project's origin: a workstation plus several
   Linux boxes). Wants one panel listing every dsh they can reach, honest status,
   and no per-machine ritual. Tolerates config; resents repetition.

Every decision below is judged by whether it helps (2) without taxing (1).

## Shipped in v0.1

| # | Capability | Pain removed |
| --- | --- | --- |
| 1 | Desktop app with one card per instance | No terminal, no remembering ports |
| 2 | Owned SSH tunnel per remote instance | No hand-built `ssh -L`, no stale tunnels |
| 3 | Token URL extraction + port rewrite | No copy-pasting auth URLs, no 401s |
| 4 | Local-first config, zero setup | Clone and run; servers added on purpose |
| 5 | One-click remote provisioning | "Point it at a host" instead of a setup checklist |
| 6 | Connectivity diagnosis | "Needs VPN" told apart from "auth rejected" |
| 7 | Version drift detection | Silent behaviour differences become visible |
| 8 | systemd user service + linger | Survives logout; no tmux babysitting |
| 9 | Orphan detection and repair | A squatting process can no longer shadow the service |

Items 6, 7 and 9 were not in the original brief. Each came from a real failure
encountered while building — which is itself the strongest signal that they
belong on the list.

## Shipped since v0.1 — contract repairs

Not features. These are cases where the tool said one thing and did another, and
the cost was a user trusting an answer that was wrong. Recorded here because the
distinction matters: a launcher's whole value is that its report is believable.

| Defect | What the user saw | Fix |
| --- | --- | --- |
| `-NoProbe` declared, documented, and inert | A "fast path" that took exactly as long as the slow one | Forwarded to the probe (`status` now honours it) |
| `-SshConfigPath` read through the wrong scope | `doctor -SshConfigPath <path>` silently read the default file | Threaded through as an explicit argument |
| `install -Json` answered `{"ok":true}` unconditionally | A failed deploy reported as success, exit 0 | `Invoke-Install` returns its verdict; failure exits 1 |
| `add -Json` returned the unchanged list on failure | "Added" and "not added" looked identical to a script | Non-zero exit distinguishes them |
| `status` ignored `-Target` | Asking about one host probed all six | `-Target` narrows the probe |
| A quoted `'a,b'` target matched nothing | An empty table with no explanation | Comma lists are split and trimmed |
| `[warn]`/`[info]` polluted `-Json` stdout | Any strict JSON consumer failed to parse | Diagnostics go to stderr in that mode |
| `-Follow` advertised, unimplemented | `logs -Follow` printed and exited | It streams until Ctrl-C |

The last four were found by reading the command surface against the docs rather
than by running it; the first four by running it. Both halves are now covered by
`tools/check-ui.js`, which fails the build when a `ValidateSet` verb has no
dispatch clause or a `param()` variable is never read.

## Next — the features I would build, in order

### P0 — Route to the right instance, into the right workspace

**Pain:** you open dsh, work, close the window, and the next day you have lost
your place and cannot remember which host that useful session was on.

**Corrected after checking.** The original entry here said the launcher should
show each instance's recent sessions with one-click resume, "because dsh already
persists sessions under `DSH_HOME/sessions`". The persistence claim is true —
`sessions/<workdir>/<session-id>/session.jsonl.zstd`, plus the newer
`session.v3.jsonl.zstd` alongside it — but the conclusion was wrong. dsh's own
web UI already ships 搜索会话, 新建会话, 添加工作区 and 选择工作区, and a
workspace *is* a working directory. Building a second session browser would
duplicate the better-informed one.

**What is actually missing** is everything around that UI, which is exactly what
a launcher owns:

- *Which* instance. Five instances each with their own session list is the real
  navigation problem, and only the launcher can see all five.
- *Which* working directory. Every local session under a stale workdir starts in
  the wrong place, and the encoded directory names (`--C-Users-you-Documents--`)
  make it hard to tell which of them you actually use.
- *Reopening the last one* you used on a given instance.

**Not blocked on the private format.** These need only instance bookkeeping and,
for the last one, whatever dsh documents for pointing a launch at a session —
reading `session.jsonl.zstd` directly is deliberately out of scope, since the
format is internal and would couple the launcher to it.

**Why first:** it turns the launcher from a connection manager into the place you
actually start work. Highest ratio of value to effort on this list.

### P0 — Fleet-wide upgrade and version pinning

**Pain:** we already hit this. Local was `0.1.1-rc.2` while servers ran
`0.1.5-rc.1`, and dsh changed its auth model between those versions. The
difference was invisible until something broke in a confusing way.

**Status: shipped in v0.2.** `check` compares every instance against npm's
`latest`, `upgrade` applies it (with `-DryRun`), and an instance may pin a
version. Drift and update availability surface on the instance cards.

**Deliberately still manual.** Applying an upgrade restarts dsh and ends any
session in flight, so an automatic upgrade on launch would be a hostile default:
you would open the panel and lose work. The pipeline is automatic; the trigger is
a decision.

**Remaining work:** a scheduled check that notifies without upgrading, and a
`--next` channel opt-in for people who want release candidates ahead of
`latest`.


### P1 — Tray icon and state-change notifications

**Pain:** a tunnel silently dies and you discover it when you next click the
window; a long remote start finishes with nobody watching.

**What:** tray icon with per-instance state, a menu to start/stop, and toasts on
state transitions ("prod went down", "gpu is ready"). The icon must reflect the
worst state across instances so it is useful while minimised.

**Status: shipped.** `tray` / `tray-start` / `tray-stop` draw a notification-area
icon reflecting the worst state across instances, offer 打开面板 / 全部启动 /
全部停止, and raise a toast when an instance changes state.

### P1 — Port and workdir intelligence

**Pain:** port collisions on both ends. Local `3080` was already taken by another
dsh and by Termius; several servers all default to `3080` remotely.

**What:** never reuse a busy port (partly done), remember the tunnel→remote
pairing, explain *who* holds a busy port, and let an instance declare a workdir so
remote dsh starts in the right project.

### P1 — Session sharing and read-only guest links

**Pain:** showing a colleague what the agent did means screenshots.

**What:** export a session as a self-contained HTML transcript, plus an optional
read-only share for a live session.

**Care needed:** the session log contains the working directory, command output
and possibly secrets. This ships only with explicit redaction and a clear warning,
or not at all.

### P2 — Batch and health operations

**Pain:** "is anything wrong right now?" across N hosts requires checking N cards.

**What:** `--all` verbs (already partly there), a health summary, restart-on-failure
for tunnels, and an optional check that surfaces host disk space (a full disk is a
common cause of remote dsh dying).

### P2 — Teams and onboarding polish

**Pain:** a new teammate needs the same setup and there is no guided path.

**What:** `dsh-deck init` producing a working config from `~/.ssh/config`, a
first-run wizard in the app, and a doctor that prints copy-pasteable fixes.

### P3 — Non-Windows desktop parity

**Pain:** the app is Windows-only today. The backend is already cross-platform;
only the launcher is PowerShell.

**What:** port `dsh.ps1`'s logic to a Node CLI so macOS and Linux get the same
experience. A real chunk of work, and only worth it once there is demand — which
is why it is deliberately last.

## Explicitly not doing

Saying no is part of the roadmap.

- **Exposing dsh beyond loopback.** `dsh web` refuses `--host 0.0.0.0` for stated
  RCE reasons and admits only `127.0.0.1`. This tool will never offer to "just
  open the firewall" or reverse-proxy dsh to the internet. Tunnels only.
- **Bundling or forking dsh.** This is a launcher. If dsh needs a change, that
  belongs upstream.
- **A hosted control plane.** Everything stays local: the backend binds
  `127.0.0.1`, holds no telemetry, and phones nowhere. That is a feature.
- **Storing credentials.** No secrets in config. Keys stay in `~/.ssh`, tokens
  stay in dsh's own store. Config holds references, never values.
- **Multi-user server tenancy.** One user account per instance, no sudo.

## How to judge a proposed feature

1. Does it help the multi-machine user **without** making the single-machine
   user configure anything?
2. Does it remove a repeated manual step, or only display more information?
3. Can it fail in a way that is *explained* rather than silent? Silent failure is
   the failure mode this project exists to kill — see `docs/lessons.md`.
4. Does it weaken the loopback-only, no-secrets, no-telemetry posture? If yes,
   it needs a very good reason.
