# dsh-deck

A desktop control panel for **every** [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) you run — the one on this machine and the ones on your servers.

> dsh is a great agent, but getting to it is friction: start a server, keep a
> terminal open, build an SSH tunnel, re-derive an auth URL — and do it again on
> every machine. **dsh-deck makes reaching dsh one click, everywhere.**

![The control panel](docs/images/panel.png)

Each card is one instance. Green means running: click **打开** and dsh opens in its
own window while the panel stays put. Red means stopped: click **启动** and dsh-deck
starts the server, brings up the SSH tunnel, redeems the auth token and hands you
a working window. Adding a brand-new server auto-installs everything it needs.

## Highlights

- **Zero-config start.** Clone and run. It opens a local-only panel immediately;
  servers are added deliberately, never required.
- **Tunnels you don't think about.** One owned SSH port-forward per remote
  instance, stable across restarts, cleaned up on stop.
- **One-click provisioning.** Point it at a host and it installs Node and dsh,
  deploys a systemd user service, enables linger, and verifies it works — no
  `sudo`, no manual checklist.
- **Honest status.** "Needs a VPN" is told apart from "auth rejected" and "host
  down", because those need different actions from you.
- **Version drift detection.** Warns when a server's dsh differs from your local
  one — the mismatch that silently changes behaviour between releases.
- **Local by design.** The backend binds `127.0.0.1`, requires a per-launch token,
  sends no telemetry, and never exposes dsh to the network.

## Requirements

| | |
| --- | --- |
| OS | Windows 10/11 (the app is Windows-only today; see [roadmap](docs/roadmap.md)) |
| PowerShell | 5.1 (built in) |
| Node.js | 18+ on the machine running the panel; **22.19+ on any host running dsh** |
| Browser | Chrome or Edge, for the chromeless app window |
| Remote hosts | Linux with systemd (user services) |

No `npm install` step, and the app backend has **zero dependencies**.

## Quick start

```powershell
git clone https://github.com/Monotonic-Capital-Management/dsh-deck.git
cd dsh-deck
.\dsh.ps1 -Command app
```

That opens the panel with a single `local` instance. To add a server:

```powershell
# register a host from your ~/.ssh/config (picks a free tunnel port)
.\dsh.ps1 -Command add -SshHost prod

# install + start it; this provisions Node/dsh/systemd if the host needs them
.\dsh.ps1 -Command start -Target prod
```

Create a desktop shortcut for the panel:

```powershell
.\tools\install-shortcut.ps1
```

## Command line

Everything the panel does is also a command, because that is what you script:

```
dsh.ps1 -Command app                    start the panel (what the shortcut runs)
dsh.ps1 -Command app -Stop              stop the panel backend and close its window
dsh.ps1 -Command status                 health of every instance
dsh.ps1 -Command start                  start everything, then open browsers
dsh.ps1 -Command start -Target prod     start one
dsh.ps1 -Command stop                   stop everything (servers + tunnels)
dsh.ps1 -Command restart -Target prod
dsh.ps1 -Command open                   open whatever is already running
dsh.ps1 -Command logs -Target prod      remote journal / local server log
dsh.ps1 -Command install -Target prod   provision and deploy only
dsh.ps1 -Command add -SshHost prod      register a host from ~/.ssh/config
dsh.ps1 -Command list                   show configured instances
dsh.ps1 -Command doctor                 diagnose this machine and every host
dsh.ps1 -Command menu                   terminal control panel
```

Useful switches: `-NoOpen`, `-AppWindow`, `-Json`, `-NoProbe`, `-LocalPort 3097`,
`-Lines 200`, `-Config <path>`.

> Use **named** parameters. `$Target` does not accept remaining arguments, so
> trailing switches would otherwise be swallowed into the target list.

## How it works

```
browser ──► 127.0.0.1:3099 ──► [ssh -N -L] ──► server:127.0.0.1:3080 ──► dsh web
             (tunnel we own)                    (systemd user service)
```

`dsh web` refuses to bind anything but loopback — it rejects `--host 0.0.0.0` with
an explicit remote-code-execution warning — so a tunnel is not a workaround, it is
the supported path. dsh-deck keeps the server on remote loopback and owns the
forward.

Recent dsh prints a one-time authenticated URL at startup:

```
dsh web: http://127.0.0.1:3080/?token=<TOKEN>
```

`/` answers **401** until that token is redeemed. Redemption returns a signed
cookie **bound to the authority the request arrived on**, so dsh-deck rewrites the
URL onto the local tunnel port before opening it. Verified end to end: redeem →
`303` + cookie, then `GET /` → `200`.

Older dsh builds print no token and serve `/` as `200`; both shapes work.

Full details in [docs/architecture.md](docs/architecture.md).

## Configuration

One JSON file, discovered automatically. With none present, a local-only config
is created and the tool just works.

```json
{
  "version": 1,
  "instances": [
    { "name": "local", "kind": "local", "port": 3080 },
    { "name": "prod", "kind": "remote", "sshHost": "prod",
      "remotePort": 3080, "localPort": 3099 }
  ]
}
```

`sshHost` is an alias from `~/.ssh/config`, so keys, ports, users and jump hosts
come from there rather than being duplicated.

For teams, commit connection details in `.dshproj.json` and keep personal
usernames and key paths in `userProfiles` — see
[`docs/configuration.md`](docs/configuration.md) and
[`.dshproj.example.json`](.dshproj.example.json).

## Auto-provisioning

`install` and `start` prepare a host with no manual steps: detect what is missing,
install Node into `~/.local/node` if absent **or too old**, install dsh into the
host's existing npm prefix, deploy the systemd user service, enable linger, start
it, and wait for the port to actually listen. No `sudo` required.

Two findings that cost real debugging time, both now handled automatically:

- **dsh needs Node ≥ 22.19.0.** On an older Node, npm installs the package
  successfully and the binary then exits `0` with **no output at all**.
- **dsh's shebang is `#!/usr/bin/env node`**, so `PATH` decides which Node it
  gets — both the probe and the service unit must prefer the installed one.

Set `"autoInstall": false` on an instance to forbid the tool from touching that
host's software.

## Security posture

- The app backend binds **`127.0.0.1` only**, on an OS-assigned port.
- Every request requires a **per-launch random token**; the page receives it once
  and keeps it in memory.
- Requests are **same-origin fenced** (Origin and Host must match), so a random
  web page cannot drive the API through your browser.
- **Instance names are validated** against the configured list, so nothing
  user-supplied reaches a command line.
- dsh is **never** exposed beyond loopback. No stored credentials — config holds
  references to keys, never key material.
- No telemetry, no network calls except ssh to hosts you configured.

## Project layout

```
dsh.ps1                  the launcher: all dsh logic lives here
dsh.cmd                  PATH-friendly shim for the CLI
app/
  server.js              panel backend (Node, no dependencies)
  ui/index.html          the interface (one self-contained file)
remote/
  dsh-web-service.sh     systemd wrapper deployed to servers
tools/
  fix-bom.ps1            keeps .ps1 files readable by PowerShell 5.1
  install-shortcut.ps1   creates the desktop shortcut
docs/
  architecture.md        how the pieces fit, and why
  configuration.md       every config field
  lessons.md             the bugs behind the design decisions
  roadmap.md             where this is going, and what it will not do
```

Generated and machine-specific (`state/`, `logs/`, `hosts.json`,
`browser-profile/`) is git-ignored.

## Troubleshooting

```powershell
.\dsh.ps1 -Command doctor
.\dsh.ps1 -Command logs -Target prod -Lines 200
ssh prod journalctl --user -u dsh-web -n 50 --no-pager
ssh prod 'ss -ltnp | grep 3080'          # who actually holds the port
ssh prod 'cat ~/.dsh/remote-web.url'     # the published token URL
```

If a service will not start, run its wrapper by hand to see the real error — the
wrapper records dsh's exit status and diagnostics into `~/.dsh/remote-web.log`:

```bash
ssh prod '~/.local/bin/dsh-web-service.sh'
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: run
`tools/fix-bom.ps1` after editing any `.ps1`, and keep the backend
dependency-free.

## License

[MIT](LICENSE) © Monotonic Capital Management
