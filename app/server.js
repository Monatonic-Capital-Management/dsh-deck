#!/usr/bin/env node
/**
 * server.js - backend for the DeepSeek Harness desktop app.
 *
 * Deliberately dependency-free: only Node builtins. It owns no dsh logic of its
 * own; every action is delegated to dsh.ps1 with -Json so the GUI and the CLI
 * can never disagree about what "start" means.
 *
 * Security posture (this process can start servers and tunnels, so it matters):
 *   - binds 127.0.0.1 only, on an OS-assigned port
 *   - every request needs a per-launch token, handed to the browser as a query
 *     parameter and kept in memory by the page
 *   - strictly same-origin: the Origin/Host must match, which keeps a random
 *     web page from driving this API through the user's browser
 *   - instance names are validated against the configured list before they ever
 *     reach a command line, so nothing user-supplied is concatenated into a shell
 *
 * On the token in the URL: the browser's own title bar is hidden in --app mode,
 * so the one-time token is not visible to the user, and it never leaves
 * 127.0.0.1.
 */

'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { createProcessRunner, parseJson } = require('./lib/process-runner');
const { createStatusCache } = require('./lib/status-cache');
const { redact, publicUrl, createAuthorization, securityHeaders } = require('./lib/security');
const { problem, createConfigCache, createOperationGate, mutationResult } = require('./lib/operations');

// Importing this module never starts a process, reads user state or opens a port.
function createApp(options = {}) {
const LAUNCHER_DIR = options.launcherDir || path.resolve(__dirname, '..');
const RUNTIME_FILE = options.persist === false ? null : path.join(LAUNCHER_DIR, 'state', 'app.json');
const TOKEN = options.token || crypto.randomBytes(24).toString('base64url');
const HOST = '127.0.0.1';
const gate = createOperationGate();

/**
 * Own our log file instead of relying on stdout/stderr.
 *
 * The launcher starts this process fully detached (UseShellExecute = true) so it
 * outlives the console that started it. A detached process has no inherited
 * pipes, and writing to a closed stdout would kill it -- which is exactly how an
 * earlier version died the moment the launcher exited. Writing to a file keeps
 * every diagnostic and removes the hazard.
 */
const LOG_FILE = path.join(LAUNCHER_DIR, 'logs', 'app.log');
const LOG_MAX_BYTES = 1024 * 1024;   // trim above ~1 MB
const LOG_KEEP_LINES = 400;

if (!options.trace) { try { fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true }); } catch (_) {} }

/**
 * Append one line, trimming the file when it grows past LOG_MAX_BYTES.
 *
 * The UI polls every 20s and each poll logs a couple of launcher invocations,
 * so an always-open window would otherwise grow this file without bound. The
 * trim only runs on the threshold crossing, which keeps the common path cheap.
 */
function trace(line) {
  line = redact(line);
  if (options.trace) { options.trace(line); return; }
  try {
    fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${line}\n`);
    const st = fs.statSync(LOG_FILE);
    if (st.size > LOG_MAX_BYTES) {
      const kept = fs.readFileSync(LOG_FILE, 'utf8').split('\n').slice(-LOG_KEEP_LINES);
      fs.writeFileSync(LOG_FILE,
        `[${new Date().toISOString()}] (log trimmed to last ${LOG_KEEP_LINES} lines)\n` + kept.join('\n'),
        'utf8');
    }
  } catch (_) { /* logging is best-effort */ }
}

// ---------------------------------------------------------------- utilities

const psRun = options.run || createProcessRunner({ launcherDir: LAUNCHER_DIR, trace });

async function psJson(args, timeoutMs, allowPlanFailure = false) {
  const result = await psRun(args.concat(['-Json']), timeoutMs);
  const data = parseJson(result.out);
  // Blocked per-instance plans are useful results; a top-level failure is not
  // an empty successful plan and must retain its actual recovery information.
  if (allowPlanFailure && data && Array.isArray(data.plans) && !data.error) return data;
  if (!result.ok || result.code !== 0 || data === null || (data && data.error)) {
    throw problem(502, result.errorCode || (data && data.errorCode) || 'LAUNCHER_FAILED',
      redact(result.message || (data && (data.message || data.error)) || result.err || '启动器未返回有效 JSON。'));
  }
  return data;
}

/**
 * Always call the launcher with NAMED parameters. dsh.ps1's earlier
 * ValueFromRemainingArguments declaration used to swallow trailing switches into
 * the positional target list, so `start X -Json` silently dropped the JSON and
 * `-NoOpen` silently stayed off. Named parameters avoid that class entirely.
 */
/**
 * Run a mutating launcher command and return its parsed JSON plus raw output.
 * These routes deliberately use psRun rather than psJson so that a failed
 * action still yields the raw progress text for the UI to show, but they must
 * still ASK for JSON -- hence the explicit concat here.
 *
 * `state` is looked up BY NAME: the launcher returns the status of every
 * instance, so parsed[0] is whichever instance happens to be configured first
 * (the local one), not the one just acted on. Reporting that as the result made
 * stopping a remote instance look like a failure even though it succeeded.
 */
async function psMutate(args, timeoutMs, name, expected) {
  return mutationResult(await psRun(args.concat(['-Json']), timeoutMs), name, expected);
}

const show = (cmd, name, extra) =>
  ['-Command', cmd].concat(name ? ['-Target', name] : []).concat(extra || []);

/**
 * The launcher's -Json output is an array for list/status, but a single-element
 * array can still arrive as a bare object (and a crashed command arrives as
 * `{ error }`). Coercing here keeps a malformed reply from turning into
 * "cfg.map is not a function" and blanking the whole panel: an error document
 * surfaces as its message, anything else becomes a one-element list.
 */
function asArray(value) {
  if (Array.isArray(value)) return value;
  if (value && typeof value === 'object') {
    if (value.error) throw new Error(String(value.error));
    return [value];
  }
  return [];
}

/**
 * The configured instance list.
 *
 * Cached, because it is static: hosts.json only changes when someone adds or
 * edits an instance, yet every panel poll was re-reading and re-parsing it
 * through a fresh PowerShell process -- measured at roughly a second per poll,
 * about 40% of the refresh. Anything that can change the list invalidates the
 * cache explicitly via invalidateConfig().
 *
 * A throw is deliberately NOT cached: a transient failure would otherwise
 * poison the panel until the backend restarted.
 */
const configStore = createConfigCache(() => psJson(show('list'), 30000));
const loadInstances = () => configStore.get();
function invalidateConfig() {
  configStore.invalidate();
  statusStore.invalidate();
}

// ------------------------------------------------------- status cache

/**
 * Background-refreshed instance status.
 *
 * Why: a refresh cost one PowerShell process plus an ssh handshake per remote
 * host, measured at ~2s with five instances, on a 20-second timer. The backend
 * is already a long-lived process, so it probes on its own schedule and callers
 * read the result. A panel refresh becomes a map lookup.
 *
 * `inFlight` is what makes concurrent callers safe. Without it, several requests
 * arriving during a refresh would each spawn their own probe -- worse than the
 * polling this replaces, not better. Everyone who asks while a probe runs awaits
 * that same probe.
 *
 * A failure is never cached as data: the previous rows are kept so the panel can
 * still render, and the error is surfaced through statusError for the UI to show
 * if it wants to.
 */
// The TTL must be LONGER than the poll interval, or the cache is stale by
// construction: with a 15s TTL under a 30s poll, half of all reads found an
// expired entry and paid ~1.5s for their own probe, which defeats the point.
// At 45s the background poll (30s) always refreshes before expiry, so every read
// is served from cache and only a genuinely dead poller makes a reader wait.
const statusStore = createStatusCache({
  probe: async () => asArray(await psJson(show('status', null, ['-Probe']), 300000)),
  trace,
});
const getStatus = force => statusStore.get(force);
const applyStatusRows = rows => statusStore.apply(rows);

async function assertKnownInstance(name) {
  const insts = await loadInstances();
  if (!insts.some((i) => i.name === name)) {
    const e = new Error(`unknown instance: ${name}`);
    e.statusCode = 400;
    throw e;
  }
  return insts;
}

/**
 * One panel-shaped instance object out of a launcher status row plus its config
 * entry. GET /api/instances and the mutation replies share this, so a card can
 * be updated from the reply a start/stop/restart already carries instead of
 * paying for another full status refresh.
 */
function mapInstance(r, c) {
  const cfg = c || {};
  return {
    name: r.Name,
    displayName: cfg.displayName || r.DisplayName || r.Name,
    kind: r.Kind,
    state: r.State,
    port: r.Port,
    detail: redact(r.Detail),
    url: publicUrl(r.Url),
    http: r.Http,
    sshHost: cfg.sshHost || r.SshHost || '',
    description: cfg.description || '',
    enabled: cfg.enabled !== false,
    remotePort: cfg.remotePort || r.RemotePort || null,
    localPort: cfg.localPort || null,
    // dshInstalled drove a card action in the panel but was never mapped, so the
    // condition read `undefined === false` and the deploy button could not
    // appear. Map it explicitly.
    dshInstalled: r.DshInstalled !== false,
    dshVersion: r.DshVersion || '',
    latestVersion: r.LatestVersion || '',
    updateAvailable: Boolean(r.UpdateAvailable),
    versionDrift: Boolean(r.VersionDrift),
    pinnedVersion: cfg.dshVersion || r.PinnedVersion || r.DshVersionPinned || '',
    nodeVersion: r.NodeVersion || r.NodeV || '',
    runningVersion: r.RunningVersion || '',
    targetVersion: r.TargetVersion || cfg.dshVersion || r.LatestVersion || '',
    autoInstall: cfg.autoInstall !== false,
    stopRemoteService: cfg.stopRemoteService !== false,
    // Why a host is unreachable, classified by the launcher from the ssh error.
    // The panel shows the hint and a matching next step; without it a card said
    // only "unreachable", which tells the reader nothing they can act on.
    failCode: r.FailCode || '',
    hint: redact(r.Hint || ''),
    // Where a local instance starts sessions. Absent for remote rows, which is
    // deliberate: the directory is on the other machine, so offering to open it
    // here would be a lie. The panel gates the reveal action on this.
    workdir: r.Workdir || cfg.workdir || '',
  };
}

// ---------------------------------------------------------------- http glue

function send(res, status, body, headers) {
  const payload = typeof body === 'string' || Buffer.isBuffer(body)
    ? body
    : JSON.stringify(body === undefined ? {} : body);
  res.writeHead(status, Object.assign(
    securityHeaders, { 'Content-Type': 'application/json; charset=utf-8' },
    headers || {}
  ));
  res.end(payload);
}

const authorization = createAuthorization({ token: TOKEN, port: () => PORT });

async function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 65536) { reject(problem(413, 'BODY_TOO_LARGE', '请求内容过大。')); return; }
      data += chunk;
    });
    req.on('end', () => {
      if (size > 65536) return;
      if (!data) return resolve({});
      try {
        const body = JSON.parse(data);
        if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error();
        resolve(body);
      } catch (_) { reject(problem(400, 'INVALID_JSON', '请求必须是有效 JSON 对象。')); }
    });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------- routes

async function planFor(name, action) {
  if (!['start', 'install', 'upgrade'].includes(action)) throw problem(400, 'INVALID_ACTION', '不支持的计划类型。');
  await assertKnownInstance(name);
  const result = await psJson(show('plan', name, ['-Action', action]), 180000, true);
  const plan = result && Array.isArray(result.plans) && result.plans.find(item => item.name === name);
  if (!plan) throw problem(502, 'INVALID_PLAN', '启动器未返回该实例的操作计划。');
  return { ...plan, ok: result.ok !== false && plan.ok !== false };
}

async function operate(action, name, timeoutMs) {
  return gate.run(action === 'install' ? ['*'] : [name], async () => {
    const cfg = (await assertKnownInstance(name)).find(item => item.name === name);
    const up = row => row && ['up', 'up-external'].includes(row.State);
    const stopped = row => row && (['down', 'disabled'].includes(row.State) ||
      (cfg.kind === 'remote' && cfg.stopRemoteService === false && ['remote-only', 'unreachable'].includes(row.State)));
    const expected = action === 'stop' ? stopped : ['start', 'restart'].includes(action) ? up : null;
    const result = await psMutate(show(action, name, ['-NoOpen']), timeoutMs, name, expected);
    applyStatusRows(result.rows);
    if (action === 'install') statusStore.invalidate();
    return { ...result, kind: cfg.kind,
      instance: result.state ? Object.assign(mapInstance(result.state, cfg), statusStore.metadata(name)) : null };
  });
}

const routes = {
  'GET /api/instances/:name/plan': ctx => planFor(ctx.params.name, ctx.url.searchParams.get('action') || 'start'),
  'GET /api/instances/:name/url': async (ctx) => {
    // A freshly probed URL for one instance.
    //
    // The panel's cached card URL can be up to a poll old, and a remote service
    // restart reissues its one-time token, so opening the cached URL yields a 401
    // page in the browser. Rather than guess, re-probe on demand and hand back
    // whatever is current now. The caller compares against what it held, so a
    // stale link is reported rather than silently opening something different
    // from what was on screen.
    await assertKnownInstance(ctx.params.name);
    // '-Target' keeps the probe to this instance only, so opening one card does
    // not pay for an ssh handshake to every other host. A single-instance reply
    // is an object rather than an array, hence the unwrap.
    const raw = await psJson(show('url', ctx.params.name), 300000);
    const row = (Array.isArray(raw) ? raw[0] : raw) || null;
    const cfg = (await loadInstances()).find((c) => c.name === ctx.params.name);
    return {
      ok: Boolean(row && row.Url),
      instance: row ? { ...mapInstance(row, cfg), url: row.Url || '' } : null,
    };
  },

  'GET /api/instances': async (ctx) => {
    // Served from a background-refreshed cache, so a panel refresh costs
    // milliseconds instead of an ssh handshake per remote host.
    //
    // `probe=0` still means "do not touch the network": it returns whatever the
    // cache holds and asks the launcher for the no-probe view only if the cache
    // is empty, which is the case a caller uses it for (first paint, or a
    // deliberately offline look).
    const wantNoProbe = ctx.url.searchParams.get('probe') === '0';
    const force = ctx.url.searchParams.get('refresh') === '1';
    const cfg = await configStore.get(force);
    const byName = new Map(cfg.map(c => [c.name, c]));
    const rows = wantNoProbe ? (statusStore.snapshot().rows || cfg.map(c => ({
      Name: c.name, Kind: c.kind, State: c.enabled === false ? 'disabled' : 'unknown',
      Detail: '尚未探测', Port: c.port || c.localPort || 0,
    }))) : await getStatus(force);
    return rows.filter(r => byName.has(r.Name)).map(r => Object.assign(mapInstance(r, byName.get(r.Name)), {
      ...statusStore.metadata(r.Name), statusError: redact(statusStore.metadata(r.Name).statusError),
    }));
  },

  'GET /api/instances/:name/logs': async (ctx) => {
    await assertKnownInstance(ctx.params.name);
    const lines = Math.min(Math.max(parseInt(ctx.url.searchParams.get('lines') || '120', 10) || 120, 10), 2000);
    const r = await psRun(show('logs', ctx.params.name, ['-Lines', String(lines)]), 120000);
    // The launcher prints a heading plus indented lines; strip the indentation so
    // the panel can render it as plain text.
    const text = (r.out || '')
      .split(/\r?\n/)
      .filter((l) => l.trim() !== '' && !/^\s*(logs |---)/.test(l))
      .map((l) => l.replace(/^\s{2}/, ''))
      .join('\n');
    return { name: ctx.params.name, ok: r.ok, text: redact(text || '(no output)') };
  },

  'POST /api/instances/:name/start': ctx => operate('start', ctx.params.name, 600000),
  'POST /api/instances/:name/stop': ctx => operate('stop', ctx.params.name, 180000),
  'POST /api/instances/:name/restart': ctx => operate('restart', ctx.params.name, 600000),

  'POST /api/instances': ctx => gate.run(['*'], async () => {
    const b = ctx.body;
    if (typeof b.sshHost !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._@:\[\]-]{0,253}$/.test(b.sshHost)) {
      throw problem(400, 'INVALID_HOST', 'SSH 主机必须是有效别名或 user@host，不能包含空格或命令字符。');
    }
    const args = show('add', null, ['-SshHost', b.sshHost]);
    if (b.name) {
      if (typeof b.name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$/.test(b.name)) {
        throw problem(400, 'INVALID_NAME', '实例标识只能使用字母、数字、点、下划线、@ 和连字符，且须以字母或数字开头。');
      }
      args.push('-Name', b.name);
    }
    if (b.displayName !== undefined) {
      if (typeof b.displayName !== 'string' || b.displayName.length > 120) throw problem(400, 'INVALID_DISPLAY_NAME', '显示名称最多 120 个字符。');
      args.push('-DisplayName', b.displayName);
    }
    if (b.port !== undefined) {
      if (!Number.isInteger(b.port) || b.port < 1 || b.port > 65535) throw problem(400, 'INVALID_PORT', '远端端口必须是 1–65535 的整数。');
      args.push('-Port', String(b.port));
    }
    const result = await psMutate(args, 60000, null);
    invalidateConfig();
    return { ...result, instances: await loadInstances() };
  }),

  'POST /api/instances/:name/config': ctx => gate.run(['*'], async () => {
    await assertKnownInstance(ctx.params.name);
    const fields = new Set(['displayName', 'description', 'workdir', 'enabled', 'dshVersion', 'autoInstall', 'stopRemoteService']);
    if (!Object.keys(ctx.body).length || Object.keys(ctx.body).some(key => !fields.has(key))) throw problem(400, 'INVALID_PATCH', '配置修改包含不支持的字段或没有任何修改。');
    for (const [key, value] of Object.entries(ctx.body)) {
      if (['enabled', 'autoInstall', 'stopRemoteService'].includes(key) ? typeof value !== 'boolean' : typeof value !== 'string') {
        throw problem(400, 'INVALID_FIELD', '配置字段类型不正确。');
      }
    }
    const result = await psMutate(show('edit', ctx.params.name, ['-Patch', JSON.stringify(ctx.body)]), 60000, ctx.params.name);
    invalidateConfig();
    return { ...result, instances: await loadInstances() };
  }),

  'POST /api/instances/:name/remove': ctx => gate.run(['*'], async () => {
    await assertKnownInstance(ctx.params.name);
    const result = await psMutate(show('remove', ctx.params.name), 60000, ctx.params.name);
    if (result.ok) statusStore.remove(ctx.params.name);
    invalidateConfig();
    return { ...result, instances: await loadInstances() };
  }),

  'GET /api/instances/:name/install': async ctx => {
    const plan = await planFor(ctx.params.name, 'install');
    return { ...plan, plan: plan.summary };
  },
  'POST /api/instances/:name/install': ctx => operate('install', ctx.params.name, 600000),
  'GET /api/ssh-hosts': () => psJson(show('ssh-hosts'), 30000),

  'GET /api/tray': async () => {
    // The launcher owns tray process management, so ask it rather than tracking
    // state here: the tray can equally be started from the command line.
    const r = await psJson(show('tray'), 30000);
    return { running: Boolean(r && r.running), pid: (r && r.pid) || 0 };
  },

  'POST /api/tray': async (ctx) => {
    // The action is read from the QUERY STRING first and the body second, and it
    // is REQUIRED. It used to default to "start", which meant any caller that
    // omitted it -- an older cached page, a hand-run curl -- silently started a
    // tray instead of doing nothing, and stops appeared to resurrect the tray.
    const action = String(
      ctx.url.searchParams.get('action') ||
      (ctx.body && ctx.body.action) ||
      ''
    ).toLowerCase();
    if (action !== 'start' && action !== 'stop') {
      const e = new Error("action must be 'start' or 'stop'");
      e.statusCode = 400;
      throw e;
    }
    const stop = action === 'stop';

    // Start/stop use the dedicated verbs, then CONFIRM by re-reading status
    // rather than trusting the verb's own output. A detached process can lose its
    // stdout before printing a result (its console may already be gone), so "did
    // it report success" is not a reliable question; "is it running now" is.
    const r = await psRun(show(stop ? 'tray-stop' : 'tray-start'), 60000);
    let status = null;
    try {
      status = await psJson(show('tray'), 30000);
    } catch (_) { /* fall through to the raw output */ }
    const running = Boolean(status && status.running);
    return {
      ok: Boolean(status && r.ok && (stop ? !running : running)),
      running,
      pid: (status && status.pid) || 0,
      action,
      raw: redact(r.out),
    };
  },

  'GET /api/versions': async () => {
    // Read-only. Answers "is anything out of date?" without touching anything.
    return { instances: await psJson(show('check'), 180000) };
  },

  'GET /api/upgrade': async ctx => {
    const name = ctx.url.searchParams.get('name') || '';
    if (name) await assertKnownInstance(name);
    return psJson(show('plan', name || null, ['-Action', 'upgrade']), 180000, true);
  },
  'POST /api/upgrade': ctx => gate.run(['*'], async () => {
    const name = ctx.url.searchParams.get('name') || '';
    if (name) await assertKnownInstance(name);
    const dryRun = ctx.url.searchParams.get('dry') === '1';
    if (dryRun) return { ...await psJson(show('plan', name || null, ['-Action', 'upgrade']), 180000, true), dryRun: true };
    const result = await psMutate(show('upgrade', name || null, ['-NoOpen']), 900000, name || null);
    applyStatusRows(result.rows);
    statusStore.invalidate();
    return { ...result, dryRun: false, name: name || '(all)' };
  }),

  'GET /api/balance': async (ctx) => {
    // Read-only. Cached for 5 minutes inside the launcher, so a 20s panel poll
    // does not hammer a billing endpoint. ?refresh=1 forces a fresh query.
    const refresh = ctx.url.searchParams.get('refresh') === '1';
    return psJson(show('balance', null, refresh ? ['-Refresh'] : []), 60000);
  },

  'GET /api/doctor': async () => {
    const r = await psRun(show('doctor'), 300000);
    return { ok: r.ok, text: redact(r.out).replace(/\r/g, '') };
  },

  'POST /api/reveal': async (ctx) => {
    // Open a folder in Explorer (or a URL in the browser).
    //
    // The previous version was wrong in two ways. Its guard read
    // `if (path && !/^https?:/.test(path)) throw` - which rejects a plain
    // Windows path and *accepts* an http URL - and it was written inline after
    // the opening brace, so every ordinary path fell through unchecked. It then
    // handed whatever it was given to url.dll,FileProtocolHandler, which will
    // happily execute a binary. Nothing here may launch a program: the caller
    // supplies a path, and this end decides what may be done with it.
    const raw = ctx.body && ctx.body.path ? String(ctx.body.path) : '';
    if (!raw) {
      // path.resolve('') is the process cwd, which would quietly open the
      // launcher's own directory for a request that named nothing.
      const e = new Error('path is required');
      e.statusCode = 400;
      throw e;
    }

    if (/^https?:\/\//i.test(raw)) {
      const target = new URL(raw);
      if (target.protocol !== 'http:' || target.hostname !== HOST || target.username || target.password) {
        throw problem(400, 'INVALID_URL', '这里只能打开本机 loopback 上的实例地址。');
      }
      await launchDesktop('rundll32.exe', ['url.dll,FileProtocolHandler', raw]);
      return { ok: true, opened: 'url' };
    }

    const path = require('path');
    const fs = require('fs');
    const resolved = path.resolve(raw);
    let stat = null;
    try { stat = fs.statSync(resolved); } catch (_) { stat = null; }
    if (!stat || !stat.isDirectory()) {
      // Directories only. Explorer can select a file, but there is no need to
      // accept one, and refusing files removes the "executable" case entirely.
      const e = new Error('path must be an existing directory');
      e.statusCode = 400;
      throw e;
    }
    // `explorer.exe <dir>` opens the folder itself and reuses an existing
    // window; url.dll would instead try to *execute* the target.
    await launchDesktop('explorer.exe', [resolved]);
    return { ok: true, opened: 'directory' };
  },
};

async function launchDesktop(command, args) {
  if (options.launchDesktop) return options.launchDesktop(command, args);
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: 'ignore', windowsHide: true });
    child.once('error', () => reject(problem(502, 'OPEN_FAILED', '无法启动桌面应用。')));
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}

// ---------------------------------------------------------------- dispatcher

function matchRoute(method, pathname) {
  const key = `${method} ${pathname}`;
  if (routes[key]) return { handler: routes[key], params: {} };
  for (const routeKey of Object.keys(routes)) {
    const [m, pattern] = routeKey.split(' ');
    if (m !== method) continue;
    const pp = pattern.split('/');
    const ap = pathname.split('/');
    if (pp.length !== ap.length) continue;
    const params = {};
    let ok = true;
    for (let i = 0; i < pp.length; i++) {
      if (pp[i].startsWith(':')) params[pp[i].slice(1)] = decodeURIComponent(ap[i]);
      else if (pp[i] !== ap[i]) { ok = false; break; }
    }
    if (ok) return { handler: routes[routeKey], params };
  }
  return null;
}

let PORT = 0;

const assets = new Map([
  ['/assets/panel.css', ['panel.css', 'text/css; charset=utf-8']],
  ['/assets/panel.mjs', ['panel.mjs', 'text/javascript; charset=utf-8']],
  ['/assets/model.mjs', ['model.mjs', 'text/javascript; charset=utf-8']],
]);
const uiDir = options.uiDir || path.join(__dirname, 'ui');
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    const pathname = url.pathname;
    if (!authorization.sameOrigin(req)) return send(res, 403, { error: '请求来源不允许。', errorCode: 'FORBIDDEN' });
    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
      return send(res, 200, fs.readFileSync(path.join(uiDir, 'index.html')), { 'Content-Type': 'text/html; charset=utf-8' });
    }
    if (req.method === 'GET' && assets.has(pathname)) {
      const [file, type] = assets.get(pathname);
      return send(res, 200, fs.readFileSync(path.join(uiDir, file)), { 'Content-Type': type });
    }
    if (!pathname.startsWith('/api/')) return send(res, 404, { error: '未找到该资源。' });
    if (!authorization.authenticated(req)) return send(res, 403, { error: '面板凭据已失效，请重新打开 Start.exe。', errorCode: 'UNAUTHORIZED' });
    if (req.method === 'POST' && pathname === '/api/session') {
      await readBody(req);
      return send(res, 200, { ok: true }, { 'Set-Cookie': authorization.sessionCookie() });
    }
    // Decode and dispatch inside the error boundary: malformed percent escapes
    // must answer 400, not become an unhandled rejection that kills the panel.
    const route = matchRoute(req.method, pathname);
    if (!route) return send(res, 404, { error: '未找到该接口。' });
    const body = req.method === 'POST' ? await readBody(req) : null;
    send(res, 200, await route.handler({ url, params: route.params, body }));
  } catch (error) {
    send(res, error instanceof URIError ? 400 : error.statusCode || 500, {
      ok: false, errorCode: error.errorCode || (error instanceof URIError ? 'INVALID_PATH' : 'REQUEST_FAILED'),
      error: redact(error instanceof URIError ? '请求路径编码不正确。' : error.message || '请求失败。'),
    });
  }
});
server.requestTimeout = 30000;
server.headersTimeout = 10000;
server.on('error', error => trace('HTTP server error: ' + error.code));
const startedAt = new Date().toISOString();

function start() {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, HOST, () => {
      server.removeListener('error', reject);
      PORT = server.address().port;
      try {
        if (RUNTIME_FILE) {
          fs.mkdirSync(path.dirname(RUNTIME_FILE), { recursive: true, mode: 0o700 });
          const staging = RUNTIME_FILE + '.' + process.pid + '.tmp';
          fs.writeFileSync(staging, JSON.stringify({
            pid: process.pid, port: PORT, token: TOKEN, url: `http://${HOST}:${PORT}/#t=${TOKEN}`, startedAt,
            configPath: process.env.DSH_LAUNCHER_CONFIG || '', sshConfigPath: process.env.DSH_SSH_CONFIG || '',
          }), { encoding: 'utf8', mode: 0o600 });
          fs.renameSync(staging, RUNTIME_FILE);
        }
      } catch (_) {
        server.close();
        reject(new Error('无法安全保存面板运行文件，请检查目录权限。'));
        return;
      }
      trace('ready on port ' + PORT);
      if (options.poll !== false) {
        loadInstances().catch(() => trace('config warm-up failed'));
        getStatus(true).catch(() => trace('initial status probe failed'));
        statusStore.start();
      }
      resolve({ port: PORT });
    });
  });
}
async function close() {
  statusStore.stop();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  if (RUNTIME_FILE) {
    try {
      const current = JSON.parse(fs.readFileSync(RUNTIME_FILE, 'utf8'));
      if (current.pid === process.pid && current.startedAt === startedAt && current.port === PORT) fs.unlinkSync(RUNTIME_FILE);
    } catch (_) {}
  }
}
return { server, start, close, statusStore };
}

module.exports = { createApp };
if (require.main === module) {
  const app = createApp();
  app.start().catch(error => { process.stderr.write(redact(error.message) + '\n'); process.exitCode = 1; });
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { app.close().then(() => process.exit(0)); });
}
