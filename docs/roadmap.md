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

## Next — the features I would build, in order

### P0 — Session continuity ("reconnect where I left off")

**Pain:** you open dsh, work, close the window, and the next day you have lost
your place and cannot remember which host that useful session was on.

**What:** the panel shows each instance's recent sessions and workdir, with a
one-click resume. dsh already persists sessions under `DSH_HOME/sessions`, so the
data exists; it is simply invisible from the launcher.

**Why first:** it turns the launcher from a connection manager into the place you
actually start work. Highest ratio of value to effort on this list.

### P0 — Fleet-wide upgrade and version pinning

**Pain:** we already hit this. Local was `0.1.1-rc.2` while servers ran
`0.1.5-rc.1`, and dsh changed its auth model between those versions. The
difference was invisible until something broke in a confusing way.

**What:** `dsh-deck upgrade --all` with a target version, a preview of what would
change, and a per-host result. Plus `"dshVersion": "0.1.5-rc.1"` in config to pin,
and a warning when a host drifts from the pin.

**Why:** version drift across a fleet is the single most likely source of
"works on my machine" confusion for this exact tool. Drift *detection* shipped in
v0.1; acting on it is the natural completion.

### P1 — Tray icon and state-change notifications

**Pain:** a tunnel silently dies and you discover it when you next click the
window; a long remote start finishes with nobody watching.

**What:** tray icon with per-instance state, a menu to start/stop, and toasts on
state transitions ("prod went down", "gpu is ready"). The icon must reflect the
worst state across instances so it is useful while minimised.

**Tray already exists as a stub** in this repo; notifications are the missing half.

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
