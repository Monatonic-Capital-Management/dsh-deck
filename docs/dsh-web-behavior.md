# `dsh web` lifecycle & API surface — evidence report

> **Context.** Written while building dsh-deck, to answer questions the CLI help
> does not: is there a stop command, what exactly does the startup URL do, what
> does `--host` accept, and is there a service helper. Kept because those answers
> still hold and because the method is reusable.
>
> **One finding has since been superseded.** This report concludes there is no
> `?token=` URL and no authentication. That is true of the version installed
> here, **`0.1.1-rc.2`** — but **`0.1.5-rc.1` and later do print a one-time token
> URL and answer `401` until it is redeemed**, returning a signed cookie bound to
> the request authority. Verified directly against 0.1.5-rc.1 on two servers; see
> [architecture.md](architecture.md).
>
> That change of auth model between two releases is precisely why dsh-deck
> detects version drift: a local and a remote instance can differ in behaviour in
> a way that stays invisible until a request fails.

Package investigated: `@deepseek-ai/dsh@0.1.1-rc.2`, installed at
`C:\Users\<you>\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\` (`package.json:4`, `:14-16` → `bin.dsh = lib/bin.js`).
All paths below are relative to that root unless stated otherwise. The bundle is **not** minified — `lib/*.js` is
readable, per-module output with `//#region` markers, so line numbers are exact.

> **Headline correction (for this build).** This build has **no `?token=` URL, no
> cookie, and no 401 anywhere.** The startup URL is plain
> `http://127.0.0.1:<port>`, `/` answers **200 without any credential**, and the
> access-control layer is a **Host-header "browser-trust fence" that answers
> 403** (not 401) — documented in-source as *not* an authentication layer. As
> noted above, this does not hold for 0.1.5+.

---

## 1. Stop / status subcommands and the full CLI surface

**No stop, kill, status, ps, or port-query subcommand or flag exists.** Not found — and I checked the whole command
tree, not just `dsh --help`.

**Top-level command tree** — the only file that builds it is `lib/bin.js` (`lib/types/args.js` region):

| Kind | Name | Declared at | Purpose |
|---|---|---|---|
| command | `web [args...]` | `lib/bin.js:91-95` | `boot the web profile (alias of --profile web); the web app's own flags follow` |
| command | `plugin [args...]` | `lib/bin.js:96-105` | forward the remaining args to `pnpm` inside the profile directory |
| root arg | `[args...]` | `lib/bin.js:77` | args handed to the booted profile |
| root opt | `-V, --version` | `lib/bin.js:77` | version |
| root opt | `--profile <name>` | `lib/bin.js:77` | profile under `$DSH_HOME/profiles` to boot |
| root opt | `--patch <path>` | `lib/bin.js:77` (repeatable, `collect` at `:27`) | extra patch-list overlay |
| root opt | `--dump-config` | `lib/bin.js:77` | print composed tree and exit |
| root opt | `--dump-default-config` | `lib/bin.js:77` | print tree without user layer / `--patch` and exit |

Dispatch switch: `lib/bin.js:130-152` — exactly three modes, `profile`, `plugin`, `dump-config`; anything else throws
(`lib/bin.js:151`). Subcommand bodies are `lib/plugin-9h8shc4d.js` (pnpm forwarder) and
`lib/dump-config-D-jtgwY3.js` (config dump). Neither touches a running server.

**Every `web` flag** (both launcher-level and app-level, verified live with `dsh web --help`):

- On the `web` subcommand itself (`lib/bin.js:92`): `--patch <path>`, `--dump-config`, `--dump-default-config`.
  The subcommand rejects the parent's flags (`rejectParentOptions`, `lib/bin.js:87-90`).
- App-level flags — declared in `node_modules/@deepseek-ai/dsh-web-app/lib/startup.js:22`:

```js
new Command().name("dsh --profile web").description("Serve the DeepSeek Harness browser UI.")
  .helpOption("-h, --help", "show this help")
  .option("--host <host>", "bind host")
  .option("--no-open", "do not open the Web UI in the default browser")
  .option("--port <port>", "listen port; pass 0 to let the OS pick a free one")
  .option("--trusted-host <authority...>", "extra authority the /api browser-trust fence accepts (host or host:port; repeatable)")
```

Validation in the same file: `--host 0.0.0.0` is a hard usage error (`startup.js:40`), a non-numeric `--port` is a
usage error (`startup.js:41`); the parsed values become the `webStartup` service (`startup.js:42-47`), and are
consumed by bundle rows via `!!js` config expressions (`dsh-web-app/cordis.patch.yml:121-127`, `:137-144`).

**How a running instance is actually stopped/detected (all OS-level, no dsh support):**

- Signals only — `lib/profile-boot-DG5t9aNs.js:231-236`: `SIGTERM` → exit code `0`, `SIGINT` → exit code `130`,
  both routed through `interrupt()` → `signalShutdown.abort()` + `shutdown.interrupt(code)`.
- Shutdown is bounded and escalating (`profile-boot-DG5t9aNs.js:9-70`): 5 s grace (`PROCESS_SHUTDOWN_TIMEOUT_MS = 5e3`,
  `:11`) to dispose the tree, then forced `process.exit`; a **second** signal exits immediately (`interrupt()` path,
  `:62-68`).
- The webserver's own teardown closes the socket and all upgraded sockets (`dsh-host-webserver/lib/index.js:253-267`).
- **No pid file, port file, or lock file is written anywhere** — searched all `lib/*.js` for pid/lock/port-state
  patterns and found only unrelated Windows ACL `LockFileEx` bindings in `dsh-sandbox-windows-acl`.
- Port discovery is only possible from the process's own stdout (Q6), from `$DSH_WEB_URL` inside the launched
  session (`dsh-web-app/lib/index.js:37-38`, `:186-192`), or from the OS (`Get-NetTCPConnection` / `netstat`).
  On a failed bind the process exits non-zero via `lib/app-boot` fail-loud (listen rejection surfaces as a failed fiber,
  `dsh-host-webserver/lib/index.js:90-95`).
- A third-party helper exists outside the package — [`chenkai2/dsh-daemon`](https://github.com/chenkai2/dsh-daemon)
  (LaunchAgent/systemd/cron + watchdog) — which is itself evidence that dsh ships no such helper (see Q5).

## 2. What the token URL does server-side

**Not found — there is no token mechanism in this build.** Concretely:

- No route, middleware, or code reads a `?token=` query parameter. Grep for `token=`, `query.token`,
  `searchParams.get(` across every installed `@deepseek-ai` package (`dsh/node_modules/@deepseek-ai/**/*.js`,
  196 packages) returns no auth-token match.
- No cookie is ever set or read: grep for `setCookie`, `Set-Cookie`, `cookie`, `httpOnly`, `signedCookie`,
  `cookie-signature`, `createHmac`, `hmac`, `timingSafeEqual`, `maxAge`, `SameSite` finds **zero** matches in any
  server-side file (only an unrelated `cookie`/`cookie-signature` tree inside third-party `node_modules` pulled in by
  protobuf-adjacent deps, and a React error-code `401` in `react-dom`).
- No `401` and no `303` status is produced by the web stack. The only statuses the server emits are 200/403/404/405/415/
  426/400 (`dsh-host-frontend-static/lib/index.js:49,65,69,83`; `dsh-client-connection/lib/index.js:237,250,278,279,284,298,539`).
- The printed URL is built with **no query string at all**:
  `node_modules/@deepseek-ai/dsh-web-app/lib/index.js:101-105` (`localWebUrl` → `` `http://${LOOPBACK_HOST}:${String(port)}` ``,
  `LOOPBACK_HOST = "127.0.0.1"` at `:39`) and printed at `:199`.

**Live confirmation against the running instance on the already-bound port 3080** (my probe, matching the
currently-served GUI whose `$DSH_WEB_URL=http://127.0.0.1:3080`):

| Request | Result |
|---|---|
| `GET /` | `200 OK`, `content-type: text/html; charset=utf-8`, **no `Set-Cookie`** |
| `GET /?token=abc` | `200 OK` (parameter ignored entirely) |
| `POST /` | `405` |
| `POST /api/host.ping` (Host = 127.0.0.1) | `400` `body is not JSON` (reached the RPC bridge) |
| `POST /api/host.ping` with `Host: evil.example:3080` | **`403` `forbidden`** |
| `GET /` with `Host: evil.example:3080` | `200` (static content is deliberately unfenced) |

**What replaces the token/cookie** (answer to "what authority is bound, TTL, single-use"): the `/api` **browser-trust
fence**, `node_modules/@deepseek-ai/dsh-client-connection/lib/index.js:106-198`:

- `isTrustedApiRequest(request, trustedHosts)` (`:184-198`) requires a parseable **`Host`** header that is either a
  loopback authority (`isLoopbackHostname`, `:100-104`: `localhost`, `[::1]`, any `127/8`) or matches a
  `trustedHosts` entry, rejects `sec-fetch-site: cross-site`, and — when an `Origin` is present — requires
  `new URL(origin).host === hostUrl.host`.
- The in-source rationale (`:107-120`) states the fence defends **DNS rebinding and cross-site requests**, that it is
  bound to the Host header because Host is the one header rebinding cannot forge, and explicitly: *"Network
  reachability and authentication stay out of scope … this fence is not an auth layer."*
- There is therefore **no signature, no signing key, no TTL, no expiry, and no single-use semantics** — trust is
  recomputed from headers on every request. Trust is also **port-sensitive** for explicit-port entries (see Q4).
- Privileged RPC methods get a second, stricter check with an **empty** trust list, pinning them to loopback regardless
  of `--trusted-host` (`:504-520` list, enforced at `:538`): `agentPreset.*`, `host.pickDirectory`, `host.openPath`,
  `settings.*`, `credentials.*`, `llm.discoverModels`.

## 3. Exact HTTP behaviour at `/`, the UI routes, and the `/api` fence

There is **no 401 and no redirect at `/`**. Why 200 with no token, and why the cookie is irrelevant:

1. Route matching is a two-table lookup — exact table, then longest-prefix, then a single fallback seat
   (`dsh-host-webserver/lib/index.js:269-279`, `:180-196`). `/` is claimed by nobody, so it falls to the fallback.
2. The fallback owner is mounted by the web bundle: `dsh-web-app/lib/index.js:176` →
   `ctx.plugin(FrontendStatic, { distIndex: … })`.
3. `dsh-host-frontend-static/lib/index.js:81-90` serves the SPA dist; `/` (the dist root) and the configured index path
   render `index.html` through the webserver's index pipeline (structured injection rows then raw taps,
   `dsh-host-webserver/lib/index.js:286-310`) and answer `200 text/html; charset=utf-8` (`:56-70`). Non-GET/HEAD → `405`
   (`:82-85`); missing file → `404` (`:65`); traversal outside dist → `403` (`:48-52`); unknown extension →
   `application/octet-stream` (`:61`).
4. Nothing in that path consults a cookie — a cookie cannot and does not change the outcome, and a request *with* no
   cookie succeeds identically (verified above). Conversely, holding a "cookie" would grant nothing, because the fence
   reads `Host`/`Origin`, not cookies.

**Routes registered for the web UI** (every `webServer.register`/`registerUpgrade`/`registerFallback` call site):

| Kind | Path | Owner | Notes |
|---|---|---|---|
| prefix | `/plugins` | `dsh-client-modules/lib/index.js:295-299` | serves `/plugins/<id>/client.js` and `.map` (`:71`, `:155`, `:459-472`) |
| exact | `/plugins/events` | `dsh-client-hmr/lib/index.js:11`, `:133-144` | SSE reload channel; GET/HEAD only, else 405 |
| prefix | `/api` | `dsh-client-connection/lib/index.js:14`, `:550-562` | the fence + RPC bridge |
| prefix | registered RPC channels | `dsh-client-connection/lib/index.js:241-258` | one per live channel; rejects the reserved `/api` (`:331`) |
| upgrade | `/api/events.mux`, `/api/events.host` | `dsh-client-connection/lib/index.js:16-18`, `:566-584` | WebSocket downlinks; non-upgrade GET → `426 upgrade required` (`:539-545`) |
| fallback | *everything unmatched* | `dsh-host-frontend-static/lib/index.js:81` | single-owner seat (`dsh-host-webserver/lib/index.js:157-163`) |
| (invariant probe) | `/__dsh_invariant_probe__`, `/__dsh_invariant_upgrade_probe__` | `dsh-host-webserver/lib/invariant.js:24-37` | registered then immediately disposed, on every fiber teardown |

**The `/api` fence in detail** — `dsh-client-connection/lib/index.js`:

- Route handler `:550-561`: untrusted → `403` + body `forbidden`; otherwise `bridge(req, res, fetchHandler, maxRequestBodyBytes)`.
- Shared-channel dispatch `:232-240`: interceptor match, then `authority: "loopback"` handlers re-check with an empty
  trust list and answer `403` (`:237`); the API gateway registers its `/api` interceptor with
  `{ authority: "trusted-host" }` (`dsh-api-gateway/lib/index.js:62`).
- RPC wire rules (`rpcFetchHandler`, `:275-301`): non-POST or bad endpoint → `404`; wrong `content-type`
  (must be bare `application/json`) → `415`; unparsable body → `400`; envelope validation failure → JSON
  `server-response` error; method must equal the URL endpoint (`:289-293`); handler throw → `500`.
- `trustedHosts` entries are validated loudly at load (`assertTrustedAuthority`, `:135-152`) — a non-canonical
  authority (path, userinfo, stray whitespace, zero-padded or dangling port, unbracketed IPv6) throws rather than
  silently broadening the grant.
- If no `apiProxy` is mounted the fence still runs and then answers `404 not found` (`:546-548`).
- Default request body cap: 314 572 800 bytes (`:532`, config `maxRequestBodyBytes`, `:480-483`).

## 4. Non-loopback `--host`, and what `--trusted-host` changes

**Any non-loopback host is impossible in this build — for two independent reasons, both verified live:**

1. **The CLI refuses the all-interfaces literal.** `dsh-web-app/lib/startup.js:40`:
   `error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network; use 127.0.0.1 instead`
   → exit code 1 (verified).
2. **The webserver schema admits only two literals.** `dsh-host-webserver/lib/index.js:98-101`:
   `Config = z.object({ host: z.union([z.const("127.0.0.1"), z.const("0.0.0.0")]).required(), port: z.natural().max(65535).required() })`.
   Passing any other address dies at tree load (verified with `--host 192.168.1.10 --port 0`):
   `dsh: plugin tree failed to load: failed to apply loader entry webserver (@deepseek-ai/dsh-host-webserver): invalid config: - $.host expected "127.0.0.1" | "0.0.0.0" but got "192.168.1.10" (at host)`
   → non-zero exit. So even bypassing the CLI check by patching the `webserver` row's config only ever yields those two
   literals, and `0.0.0.0` is exactly the value the CLI rejects.

Net: **no documented or discoverable supported way to serve the web UI off-loopback.** The intended remote-access path
is a tunnel/forward (the code handles SSH explicitly: `launchedThroughSsh()`, `dsh-web-app/lib/index.js:42-49`,
suppressing browser handoff, and the README documents that the SSH client owns the forwarded address).

**What `--trusted-host <authority...>` actually changes:** it is *only* an addition to the `/api` fence's allow-list —
it never changes the bind host or the port.

- Parsed repeatably into `trustedHosts` (`startup.js:46`), passed through `webRuntime` (`cordis.patch.yml:144`, `:171`) into
  `dsh-client-connection`'s `trustedHosts` config (`dsh-client-connection/lib/index.js:480-481`).
- Matching semantics (`isTrustedAuthority`, `:164-177`): an entry **with an explicit port** matches that exact
  `host:port` authority; a **port-less** entry matches that hostname on **any** port.
- The bundle additionally derives **port-less LAN IP literals** automatically when the bind is all-interfaces
  (`resolveLanTrust`, `dsh-web-app/lib/index.js:89-95`; `lanAddresses` used for the `(LAN: …)` half of the URL line and
  for `trustedHosts`), because "an IP-literal Host is safe on any port and an OS-assigned port is unknowable before bind".
- It does **not** unlock the privileged methods listed in Q2 — those stay loopback-pinned with an empty trust list.

**Safety implication of exposing beyond loopback:** the fence is a DNS-rebinding / cross-site defence, *not*
authentication (`dsh-client-connection/lib/index.js:107-120` says so explicitly), and the composition runs the agent with
the user's own filesystem and shell. Anyone who can reach the port **and** present a trusted authority (a LAN IP, or any
host declared `--trusted-host`) passes the fence and reaches the full RPC surface — create sessions, run tools, read the
workspace. With this machine's `permission.defaultPreset: danger-full-access` (from `C:\Users\<you>\.dsh\settings.yaml`),
that is effectively unauthenticated remote code execution plus credential/context exposure, which is precisely the
subject of the CLI's own refusal message above. The loopback-pinned setting/credential/native-dialog methods remain
protected, but they are not the dangerous surface here. Recommended posture: keep the bind at `127.0.0.1` and reach it
through SSH/tunnel; if a trusted authority is declared, also narrow it with an explicit port. (This matches the
community FAQ's framing that the project refuses network exposure because it equals handing RCE, credentials, and
context to an untrusted network: [`Electricitysheep/dsh-handbook` FAQ](https://raw.githubusercontent.com/Electricitysheep/dsh-handbook/refs/heads/main/docs/faq.md).)

## 5. Shipped systemd unit / Dockerfile / "run as a service" helper

**None. Not found.** Evidence:

- `glob **/*.{service,dockerfile,Dockerfile,daemon}` over the whole installed package tree → no files.
- `package.json:17-20` — the published `files` allowlist is literally `["lib/*.js", "config"]`, plus README/LICENSE, so no
  packaging or service assets can ship (confirmed: the only entries on disk are `LICENSE`, `README*.md`,
  `README.i18n.yaml`, `package.json`, `lib/`, `config/`, `node_modules/`).
- Keyword sweep (`systemd|docker|daemon|nssm|pm2|launchd|service unit`) over every `*.md`/`*.yml`/`*.yaml` in the package
  (excluding the frontend dist) returned only unrelated hits: `dsh-subprocess-local/README.md:9,30` about detached
  process groups and daemons that re-parent away, and third-party dependency READMEs (`is-docker`, `node-pty`).
- The web bundle README documents the URL line, SSH behaviour, and known limitations — no service/daemon guidance
  (`node_modules/@deepseek-ai/dsh-web-app/README.md`).
- No `install`/`postinstall` script, no `dsh service` verb: the whole launcher is the 154-line `lib/bin.js`.
- Process lifetime is simply "as long as the mounted tree lives" — `runProfile` leaves lifetime to the plugins
  (`lib/profile-boot-DG5t9aNs.js:214-220`), ended by SIGINT/SIGTERM.
- The only "run as a service" option is third-party: [`chenkai2/dsh-daemon`](https://github.com/chenkai2/dsh-daemon)
  ([npm](https://www.npmjs.com/package/@chenkai114/dsh-daemon)), which registers `dsh web` as a LaunchAgent/systemd/cron
  service with a watchdog. Windows would need an equivalent (Task Scheduler / NSSM / a wrapper), written by the user.

## 6. Exact startup stdout format and the regex to extract the URL

**Literal format string** — `node_modules/@deepseek-ai/dsh-web-app/lib/index.js:199`:

```js
if (config.printUrl) console.log(`dsh web: ${webUrl}${lanCandidate === void 0 ? "" : ` (LAN: http://${lanCandidate}:${String(port)})`}`);
```

with `webUrl` from `localWebUrl()` (`:101-105`) = `` `http://127.0.0.1:${port}` `` (host is the hardcoded
`LOOPBACK_HOST` at `:39`; `port` is the **bound** port, so `--port 0` prints the OS-assigned one —
`get port()` → `listenedPort`, `dsh-host-webserver/lib/index.js:114-117`, set from `server.address().port` at `:249`).

- Trailing newline only; nothing after it. The `(LAN: http://<ip>:<port>)` suffix appears **only** when the bind is
  `0.0.0.0` (`lanAddresses` empty otherwise, `dsh-web-app/lib/index.js:90`), and is **empty for normal loopback runs**.
- The line is printed once, after the Loader tree settles (`announceReady`, `:194-213`), i.e. only once the socket is
  bound — it is a real readiness signal, not an early banner.

**Verified live** (fresh instance, `--port 0`, `--no-open`; stdout captured to a file, stderr empty):

```
dsh web: http://127.0.0.1:63008
```

**Suggested extraction regex** (ignores an optional LAN suffix and any hypothetical trailing token):

```regex
^dsh web:\s+(?<url>https?://[^\s()]+)
```

For the URL-only form when the LAN suffix is present but unwanted, capture up to the whitespace:

```regex
dsh web:\s+(http://[^\s]+)
```

**Everything else printed at startup:**

- With browser handoff enabled (default; suppressed by `--no-open` or an SSH launch):
  `dsh-web-app/lib/index.js:201` → `console.log("dsh web: opening the default browser; pass --no-open to disable")`.
  Verified live (stdout, second line):

  ```
  dsh web: http://127.0.0.1:64197
  dsh web: opening the default browser; pass --no-open to disable
  ```

- **stderr is empty on a healthy start** (verified twice). It is only written on failure:
  - browser handoff failure → `console.error(`web-app: could not open the default browser because ${reason}; visit ${webUrl} manually`)`, `dsh-web-app/lib/index.js:204`;
  - `dsh plugin` diagnostics (`lib/plugin-9h8shc4d.js:57,105,115,123-124`);
  - commander usage errors and boot/tree-load failures (e.g. the `--host` refusal and the schema `ValidationError` in Q4) — these go to stderr and exit non-zero;
  - the `dsh --profile web --help` text goes to **stdout** and exits 0, printing **no** URL line (`cordis.patch.yml:12` notes no server binds for `--help`; verified).

- Clean shutdown prints nothing; `SIGTERM` → exit 0, `SIGINT` → exit 130 (Q1).

---

### Reproduction notes (all read-only; nothing outside temp dirs was modified)

- `dsh --help`, `dsh web --help`, `--host 0.0.0.0`, `--port notanumber`, `--host 192.168.1.10 --port 0` run directly.
- Two short-lived `node lib/bin.js web --port 0 [--no-open]` probes launched via `Start-Process` with stdout/stderr
  redirected to `%TEMP%\dsh-*-probe-*.txt`, read, then killed (ports 63008 and 64197; no orphaned processes left).
- HTTP probes with `curl.exe` against the already-running instance on `127.0.0.1:3080` using `Host:` header overrides.
- Static evidence from `lib/*.js`, `config/`, and `node_modules/@deepseek-ai/dsh-{web-app,web,host-webserver,host-frontend-static,client-connection,client-hmr,client-modules,api-gateway,cmdline}`, plus greps across all 196 bundled `@deepseek-ai` packages.
