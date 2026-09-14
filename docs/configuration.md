# Configuration

Everything is configured through one JSON file. There are no hidden settings and
nothing is written outside this directory except the app's own state.

## Which file is used

The first one that exists wins:

| Order | Path | Use it for |
| --- | --- | --- |
| 1 | `-Config <path>` | one-off runs, tests |
| 2 | `$DSH_LAUNCHER_CONFIG` | switching between several setups |
| 3 | `<repo>/hosts.json` | your private per-machine config (git-ignored) |
| 4 | `<repo>/.dshproj.json` | a shared team config you commit |
| 5 | `~/.dsh-launcher/hosts.json` | a global config outside any repo |

If none exists, a **local-only** config is written to (5) and the tool runs
immediately. Nothing needs to be configured to get started — that is deliberate,
because a launcher that demands setup before it does anything does not get used.

Related environment variables:

| Variable | Effect |
| --- | --- |
| `DSH_LAUNCHER_CONFIG` | config file to use, same as `-Config` |
| `DSH_SSH_CONFIG` | ssh config to read hosts from (default `~/.ssh/config`) |
| `DSH_HOME` | dsh's own home directory |

## Minimal config

```json
{
  "version": 1,
  "instances": [
    { "name": "local", "kind": "local", "port": 3080 }
  ]
}
```

That is the whole thing for local use. `dsh` is found on `PATH` automatically.

## Adding a server

```json
{
  "version": 1,
  "instances": [
    { "name": "local", "kind": "local", "port": 3080 },
    {
      "name": "prod",
      "kind": "remote",
      "sshHost": "prod",
      "remotePort": 3080,
      "localPort": 3099
    }
  ]
}
```

`sshHost` is an alias from `~/.ssh/config`, so keys, ports, users and jump hosts
all come from there and are not duplicated here.

Or let the tool write it:

```powershell
.\dsh.ps1 -Command add -SshHost prod
```

### Instance fields

| Field | Applies to | Meaning |
| --- | --- | --- |
| `name` | both | identifier used on the command line and in the panel |
| `kind` | both | `local` or `remote` |
| `enabled` | both | set `false` to park an instance without deleting it |
| `description` | both | shown in the panel and in `list` |
| `port` | local | port `dsh web` listens on |
| `workdir` | local | working directory dsh starts in |
| `sshHost` | remote | ssh alias, or `user@host` |
| `remotePort` | remote | port `dsh web` uses on the server (default 3080) |
| `localPort` | remote | local end of the tunnel; a free one is chosen if busy |
| `profile` | remote | pull connection fields from a named profile |
| `sshUser`, `identityFile`, `jumpHost` | remote | overrides passed to ssh |
| `stopRemoteService` | remote | `false` leaves the server running on `stop` |

## Shared team config

A repo can commit connection details that everyone shares, while each person
keeps their own username and key. Put the shared half in `.dshproj.json`:

```json
{
  "version": 1,
  "profiles": [
    { "name": "prod", "sshHost": "prod", "remotePort": 3080 },
    { "name": "gpu", "sshHost": "gpu", "sshUser": "ml", "jumpHost": "bastion" }
  ],
  "userProfiles": {
    "alice": { "prod": { "sshUser": "alice", "identityFile": "~/.ssh/id_ed25519" } },
    "bob":   { "prod": { "sshUser": "bob",   "identityFile": "~/.ssh/work_rsa" } }
  },
  "instances": [
    { "name": "local", "kind": "local", "port": 3080 },
    { "name": "prod", "profile": "prod", "localPort": 3099 },
    { "name": "gpu",  "profile": "gpu",  "localPort": 3100, "enabled": false }
  ]
}
```

The key is looked up by OS username (`$env:USERNAME` on Windows, `$USER` on Unix).
Precedence is **instance field → userProfiles → profile**, so a value set
directly on the instance always wins.

`.dshproj.example.json` in this repo is a complete, commented example.

## Auto-provisioning

`install` (and `start`, which calls it when needed) prepares a remote host with
no manual steps:

1. Explains *why* a host is unreachable, distinguishing "needs a VPN" from
   "auth rejected" from "host down" — these need different actions.
2. Installs **Node** into `~/.local/node` if the host has none **or if its
   version is older than dsh requires**. The system node is left untouched.
3. Installs **dsh** into that host's existing npm prefix, falling back to
   `~/.local` if the configured prefix needs root.
4. Deploys the systemd **user service** and enables **linger** so it survives
   logout.
5. Starts it and waits for the port to actually listen.

Two details are worth knowing because they cost real debugging time:

- **dsh needs Node ≥ 22.19.0.** A transitive dependency declares that engine. On
  an older node npm installs the package successfully and the binary then exits
  `0` with **no output at all** — a silent failure that both a presence check and
  an exit-code check miss. The tool therefore verifies dsh *runs*, not merely
  that it is installed.
- **dsh's shebang is `#!/usr/bin/env node`**, so `PATH` decides which node it
  gets. Both the probe and the systemd unit put `~/.local/node/bin` first.

Nothing here needs `sudo`. `loginctl enable-linger` may want privileges; on hosts
where it fails the service still works for the current session.

## Manual remote setup

If you would rather not let the tool install anything, do it yourself:

```bash
npm install -g @deepseek-ai/dsh    # needs node >= 22.19.0
```

Then deploy only the service files:

```powershell
.\dsh.ps1 -Command install -Target prod
```

To skip provisioning entirely, set `"autoInstall": false` on the instance and the
tool will refuse rather than install.
