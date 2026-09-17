# 架构与实现边界

[返回首页](../../README.md) · [当前架构](../architecture.md) · [实施计划](../implementation-plan.md)

> 历史架构，归档于 2026-09-16。原文反映当时的实现与上游观察，不作为当前行为或安全保证。
>
> 基线后端还负责缓存、结果映射和独立 SSH 发现，不能声称 API 与 CLI 自动一致；运行文件会保存认证信息，不能声称不落盘；远端安装仍会启动服务，进程归属识别和旧探测覆盖也在修复范围内。上游认证行为必须限定版本，不能从旧报告推及所有新版。
>
> **DOC-MODULES｜本轮实施目标。** 配置、运行时、生命周期职责拆分及可注入后端替身待实现验收；最终组件表由主代理同步更新。

## The shape of the problem

`dsh web` is a local web server that serves the harness UI. Two properties of it
dictate this project's entire design:

1. **It binds loopback only.** `--host` accepts just `127.0.0.1` and `0.0.0.0`,
   and the CLI refuses `0.0.0.0` outright, with the message that it "would expose
   remote code execution to the network". So reaching a remote dsh over a network
   is not a configuration problem to solve — a tunnel is the supported path.
2. **Recent versions print a one-time authenticated URL.** `/` answers `401` until
   that token is redeemed, and redemption returns a signed cookie bound to the
   authority the request arrived on.

Everything below follows from those two facts.

```
┌─ browser ─┐
│  dsh UI   │  own window, chromeless (Chrome/Edge --app)
└─────┬─────┘
      │ http://127.0.0.1:3099/?token=...      ← token rewritten to the tunnel port
┌─────▼──────────────────────────────┐
│ ssh -N -L 3099:127.0.0.1:3080      │  owned by the launcher, one per instance
└─────┬──────────────────────────────┘
      │ (encrypted, authenticated by ssh)
┌─────▼──────────────────────────────┐
│ server: 127.0.0.1:3080             │
│ systemd --user  dsh-web.service    │  survives logout (linger)
│   └─ dsh-web-service.sh            │  publishes the token URL to a file
│        └─ dsh web --port 3080      │
└────────────────────────────────────┘
```

## Components

| File | Runs where | Responsibility |
| --- | --- | --- |
| `dsh.ps1` | your machine | **all** dsh logic: start/stop, tunnels, status, provisioning, diagnosis |
| `app/server.js` | your machine | panel backend; a thin HTTP wrapper over `dsh.ps1` |
| `app/ui/index.html` | browser | the interface; one self-contained file, no build step |
| `remote/dsh-web-service.sh` | server | systemd entry point; publishes the startup URL |

### Why the launcher holds all the logic

`app/server.js` deliberately contains **no** dsh knowledge. Every action shells
out to `dsh.ps1 -Json` and relays the result. That means the panel and the CLI can
never disagree about what "start" does, and there is exactly one place to fix a
bug. The cheaper-looking alternative — reimplement status checks in JavaScript —
would have produced two implementations drifting apart within weeks.

### Why the UI talks to a local HTTP server

The interface could have been a PowerShell WinForms window, avoiding Node
entirely. It is a local web app instead for three reasons:

- **zero install**: no compiler, no package manager, no runtime beyond Node which
  dsh already requires;
- a **real window** with a taskbar entry, via the browser's `--app` mode;
- the whole UI is one HTML file that can be iterated on without a build step.

The cost is a local server process, which is why it is fenced as described below.

## Security model

The backend can start servers and open SSH tunnels, so it is treated as
privileged even though it only listens on loopback.

| Control | Why |
| --- | --- |
| Binds `127.0.0.1`, OS-assigned port | Not reachable from the network |
| Per-launch random token on every request | A local process cannot drive the API by guessing a port |
| Origin **and** Host must match | A web page you visit cannot reach the API through your browser |
| Instance names validated against config | Nothing user-supplied is concatenated into a command line |
| Body size caps, method routing | Ordinary hardening |
| dsh never bound beyond loopback | The upstream CLI's own safety position |

There is no credential storage. Config references keys (`identityFile`); it never
contains key material. `ssh` handles authentication using the user's existing
setup.

## Provisioning flow

`install` (and `start`, when needed) runs this sequence:

```
1  ssh reachable?            ── no ─►  classify the failure and explain it
2  facts: os, arch, systemd,
   node, npm prefix, disk    (one round trip)
3  node present AND >= 22.19.0?  ── no ─►  install Node into ~/.local/node
4  dsh present AND runnable?     ── no ─►  npm install -g into the host's prefix
5  deploy service + unit, enable linger
6  start, then wait for the port to actually listen
7  open a tunnel, fetch the token URL, rewrite the port, hand it over
```

Steps 3 and 4 are separate on purpose. "Node is installed" and "dsh runs" are
different conditions, and conflating them produced a silent failure that took a
while to find — see [lessons.md](2026-09-16-lessons.md) #5 and #6.

Nothing requires `sudo`. `loginctl enable-linger` may want privileges and is
optional; without it the service works for the current session.

## The token, precisely

```
dsh web: http://127.0.0.1:3080/?token=<TOKEN>
```

- The URL is printed once, after the plugin tree settles, so it doubles as a
  readiness signal.
- `GET /` without it → `401`. With it → `303` + `Set-Cookie`.
- The cookie payload names the authority it was issued for:

  ```json
  {"version":1,"authority":"127.0.0.1:3099","issuedAt":...,"expiresAt":...}
  ```

  30-day expiry, `HttpOnly`, `SameSite=Strict`.
- Because the authority is the **local tunnel port**, rewriting `3080` → `3099`
  before opening the browser is not a hack; it is what makes the cookie valid.

Older builds (≤ 0.1.1) print no token and serve `/` as `200`. Both shapes are
handled by reading the URL out of the log with
`dsh web:\s+(http://[^\s()]+)`.

## Remote service lifecycle

`remote/dsh-web-service.sh` is a wrapper rather than `ExecStart=dsh web` for
reasons that are all about visibility:

- **systemd has no terminal**, so the startup URL would be lost. The wrapper runs
  a small publisher that greps the log and writes the URL to
  `~/.dsh/remote-web.url` for the launcher to read over ssh.
- **The log is rotated each start** so a stale token can never be mistaken for the
  current one.
- **The exit status is captured and reported.** A bare service that dies
  instantly otherwise shows up as `status=0/SUCCESS`, which is how a broken dsh
  once looked perfectly healthy.
- **PATH is prepared explicitly.** `dsh`'s shebang is `#!/usr/bin/env node`, so
  the wrapper puts `~/.local/node/bin` first — otherwise a too-old system node
  makes dsh exit 0 with no output.

## Status states

| State | Meaning |
| --- | --- |
| `up` | local server serving, or remote unit active + listening + tunnel up |
| `up-external` | the port was already served by a dsh the launcher did not start; it adopts it so `stop` still works |
| `remote-only` | server healthy, tunnel down |
| `tunnel-only` | tunnel up, server not running |
| `down` | nothing running |
| `port-busy` | port held by an unrelated process |
| `unreachable` | ssh failed, with a classified reason |
| `disabled` | `enabled: false` in config |

## Known limitations

- **Windows only, today.** The backend and remote script are portable; the
  launcher is PowerShell and uses `Get-NetTCPConnection`, `taskkill` and
  `Get-CimInstance`. Porting it to a Node CLI is on the roadmap.
- **Remote hosts must be Linux with systemd** for provisioning. Other unixes
  would need a different service manager.
- **SSH connection multiplexing is unavailable on Windows OpenSSH**
  (`ControlMaster` fails with "getsockname failed: Not a socket"), so each probe
  is a fresh connection. Probes are therefore batched into single round trips.
