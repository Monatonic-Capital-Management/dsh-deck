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

const LAUNCHER_DIR = path.resolve(__dirname, '..');
const PS1 = path.join(LAUNCHER_DIR, 'dsh.ps1');
const RUNTIME_FILE = path.join(LAUNCHER_DIR, 'state', 'app.json');

const TOKEN = crypto.randomBytes(24).toString('base64url');
const HOST = '127.0.0.1';

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

try { fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true }); } catch (_) {}

/**
 * Append one line, trimming the file when it grows past LOG_MAX_BYTES.
 *
 * The UI polls every 20s and each poll logs a couple of launcher invocations,
 * so an always-open window would otherwise grow this file without bound. The
 * trim only runs on the threshold crossing, which keeps the common path cheap.
 */
function trace(line) {
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

function psRun(args, timeoutMs = 300000) {
  trace(`psRun ${JSON.stringify(args)}`);
  return new Promise((resolve) => {
    const child = spawn(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PS1].concat(args),
      // No stdin: nothing the launcher runs reads it, and an extra inherited
      // pipe is one more handle a detached child can keep open.
      { cwd: LAUNCHER_DIR, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }
    );
    let out = '';
    let err = '';
    let settled = false;
    let timer = null;
    const finish = (code) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ ok: code === 0, code, out, err });
    };
    timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill(); } catch (_) {}
      resolve({ ok: false, code: -1, out, err: err + '\n[timeout]' });
    }, timeoutMs);
    child.stdout.on('data', (d) => { out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { err += d.toString('utf8'); });
    child.on('error', (e) => {
      if (settled) return;
      err = String(e.message);
      finish(-1);
    });
    // A command that starts dsh leaves the detached dsh process holding a
    // duplicate of this child's stdout pipe, so 'close' never fires while that
    // instance runs: start/restart looked like they hung for the whole life of
    // the instance even though the launcher had finished and printed its JSON.
    // The reply is written before the child exits, so its exit plus a moment for
    // the pipes to drain is the end of the command; 'close' still wins if it
    // arrives first.
    child.on('exit', (code) => { setTimeout(() => finish(code), 400); });
    child.on('close', (code) => finish(code));
  });
}

/**
 * dsh.ps1 -Json prints one JSON document, but for mutating commands it also
 * prints progress lines first -- and those lines start with "[ok]" / "[info]".
 * Locating the JSON by "first bracket" therefore lands on the "[" of a log
 * prefix and JSON.parse fails. Instead, try every bracket position left to
 * right and keep the first one that parses; log prefixes never parse.
 */
function parseJson(raw) {
  if (!raw) return null;
  const text = raw.replace(/^\uFEFF/, '');
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch !== '[' && ch !== '{') continue;
    // Cheap pre-filter so we do not JSON.parse on every bracket in a long log.
    const rest = text.slice(i);
    if (ch === '[' && !/^\[\s*[{["\]\d-]/.test(rest)) continue;
    if (ch === '{' && !/^\{\s*"/.test(rest)) continue;
    try {
      return JSON.parse(rest);
    } catch (_) {
      // keep scanning
    }
  }
  return null;
}

async function psJson(args, timeoutMs) {
  const r = await psRun(args.concat(['-Json']), timeoutMs);
  const data = parseJson(r.out);
  if (data === null) {
    const detail = (r.err || r.out || '').trim().split('\n').slice(-4).join(' ').trim();
    throw new Error(detail || 'launcher produced no JSON');
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
async function psMutate(args, timeoutMs, name) {
  const r = await psRun(args.concat(['-Json']), timeoutMs);
  const parsed = parseJson(r.out);
  const rows = Array.isArray(parsed) ? parsed : null;
  const state = rows ? (rows.find((x) => x && x.Name === name) || null) : null;
  return {
    code: r.code,
    err: (r.err || '').trim(),
    raw: (r.out || '').trim(),
    rows,
    state,
  };
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
let configCache = null;

async function loadInstances() {
  if (configCache) return configCache;
  configCache = asArray(await psJson(show('list'), 30000));
  return configCache;
}

function invalidateConfig() {
  configCache = null;
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
const STATUS_TTL_MS = 45000;
const STATUS_POLL_MS = 30000;

let statusCache = { rows: null, at: 0, error: '', complete: false };
let statusInFlight = null;

function getStatus(force) {
  const age = Date.now() - statusCache.at;
  // `complete` matters as much as the age. A mutation can arrive before the
  // first full probe has finished (the panel is interactive during those first
  // seconds) and folds its own single row into the cache; without this flag that
  // row would look like a fresh, authoritative view of the whole farm, and the
  // panel would show one instance instead of five until the next poll. Only a
  // real probe may declare the cache complete.
  if (!force && statusCache.rows && statusCache.complete && age < STATUS_TTL_MS) {
    return Promise.resolve(statusCache.rows);
  }
  if (statusInFlight) return statusInFlight;
  statusInFlight = (async () => {
    try {
      const rows = asArray(await psJson(show('status', null, ['-Probe']), 300000));
      statusCache = { rows, at: Date.now(), error: '', complete: true };
      trace(`status refreshed (${rows.length} instance(s))`);
      return rows;
    } catch (e) {
      // Keep the last good rows: a transient probe failure should not blank the
      // panel. The empty case is the one time we have nothing to fall back on.
      statusCache = {
        rows: statusCache.rows,
        at: Date.now(),
        error: String(e && e.message ? e.message : e),
        complete: statusCache.complete,
      };
      trace(`status refresh failed: ${statusCache.error}`);
      if (statusCache.rows) return statusCache.rows;
      throw e;
    } finally {
      statusInFlight = null;
    }
  })();
  return statusInFlight;
}

let statusTimer = null;

function startStatusPolling() {
  if (statusTimer) return;
  // Unref'd so a pending timer can never hold the process open.
  statusTimer = setInterval(() => {
    getStatus(true).catch(() => { /* already traced */ });
  }, STATUS_POLL_MS);
  if (statusTimer.unref) statusTimer.unref();
}

/**
 * Fold a mutation's own result into the cache.
 *
 * The mutation command already returns the acted-on instance's new row, so
 * reusing it avoids the full re-probe the route used to trigger, and the panel's
 * very next read is already correct.
 */
function applyStatusRows(rows) {
  const incoming = asArray(rows);
  if (!incoming.length) return;
  const byName = new Map((statusCache.rows || []).map((r) => [r.Name, r]));
  for (const r of incoming) {
    if (r && r.Name) byName.set(r.Name, r);
  }
  // Preserve `complete`: folding in a mutation does not make a partial cache
  // whole, so a cache that has only ever seen mutations keeps asking to be
  // filled by a real probe (see getStatus).
  statusCache = {
    rows: [...byName.values()],
    at: Date.now(),
    error: '',
    complete: statusCache.complete,
  };
}

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
    kind: r.Kind,
    state: r.State,
    port: r.Port,
    detail: r.Detail,
    url: r.Url,
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
    // Why a host is unreachable, classified by the launcher from the ssh error.
    // The panel shows the hint and a matching next step; without it a card said
    // only "unreachable", which tells the reader nothing they can act on.
    failCode: r.FailCode || '',
    hint: r.Hint || '',
    // Where a local instance starts sessions. Absent for remote rows, which is
    // deliberate: the directory is on the other machine, so offering to open it
    // here would be a lie. The panel gates the reveal action on this.
    workdir: r.Workdir || '',
  };
}

// ---------------------------------------------------------------- http glue

function send(res, status, body, headers) {
  const payload = typeof body === 'string' || Buffer.isBuffer(body)
    ? body
    : JSON.stringify(body === undefined ? {} : body);
  res.writeHead(status, Object.assign(
    { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    headers || {}
  ));
  res.end(payload);
}

function authorized(req, url) {
  // Same-origin fence first: a foreign page cannot read the token, but it could
  // still attempt a blind request, and Origin/Host mismatch is the cheapest way
  // to reject that class outright.
  const host = req.headers.host || '';
  if (host !== `${HOST}:${PORT}`) return false;
  const origin = req.headers.origin;
  if (origin && origin !== `http://${HOST}:${PORT}`) return false;
  return url.searchParams.get('t') === TOKEN;
}

async function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 1e6) { reject(new Error('body too large')); req.destroy(); return; }
      data += chunk;
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch (_) { resolve({}); }
    });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------- routes

const routes = {
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
      instance: row ? mapInstance(row, cfg) : null,
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
    if (!wantNoProbe) {
      const rows = await getStatus(false);
      const cfg = await loadInstances();
      const byName = new Map(cfg.map((c) => [c.name, c]));
      // `probedAt` / `statusError` let the panel tell "live" apart from "last
      // known good, because the background probe is failing". Presenting a stale
      // row as current would be the one thing this cache must not do.
      return rows.map((r) => Object.assign(mapInstance(r, byName.get(r.Name)), {
        probedAt: statusCache.at,
        statusError: statusCache.error || '',
      }));
    }
    const rows = asArray(await psJson(show('status', null, ['-NoProbe']), 300000));
    const cfg = await loadInstances();
    const byName = new Map(cfg.map((c) => [c.name, c]));
    return rows.map((r) => mapInstance(r, byName.get(r.Name)));
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
    return { name: ctx.params.name, text: text || '(no output)' };
  },

  'POST /api/instances/:name/start': async (ctx) => {
    const cfg = await assertKnownInstance(ctx.params.name);
    const r = await psMutate(show('start', ctx.params.name, ['-NoOpen']), 300000, ctx.params.name);
    applyStatusRows(r.state);
    return {
      ok: Boolean(r.state && (r.state.State === 'up' || r.state.State === 'up-external')),
      state: r.state, raw: r.raw, err: r.err, code: r.code,
      instance: r.state ? mapInstance(r.state, cfg.find((c) => c.name === ctx.params.name)) : null,
    };
  },

  'POST /api/instances/:name/stop': async (ctx) => {
    const cfg = await assertKnownInstance(ctx.params.name);
    const r = await psMutate(show('stop', ctx.params.name), 180000, ctx.params.name);
    applyStatusRows(r.state);
    return {
      ok: Boolean(r.state && r.state.State === 'down'),
      state: r.state, raw: r.raw, err: r.err, code: r.code,
      instance: r.state ? mapInstance(r.state, cfg.find((c) => c.name === ctx.params.name)) : null,
    };
  },

  'POST /api/instances/:name/restart': async (ctx) => {
    const cfg = await assertKnownInstance(ctx.params.name);
    const r = await psMutate(show('restart', ctx.params.name), 420000, ctx.params.name);
    applyStatusRows(r.state);
    return {
      ok: Boolean(r.state && (r.state.State === 'up' || r.state.State === 'up-external')),
      state: r.state, raw: r.raw, err: r.err, code: r.code,
      instance: r.state ? mapInstance(r.state, cfg.find((c) => c.name === ctx.params.name)) : null,
    };
  },

  'POST /api/instances': async (ctx) => {
    const b = ctx.body || {};
    if (!b.sshHost || typeof b.sshHost !== 'string' || !/^[A-Za-z0-9._@:-]+$/.test(b.sshHost)) {
      const e = new Error('sshHost is required and may only contain letters, digits, . _ @ : -');
      e.statusCode = 400;
      throw e;
    }
    const args = show('add', null, ['-SshHost', b.sshHost]);
    if (b.name) {
      if (!/^[A-Za-z0-9._-]+$/.test(b.name)) {
        const e = new Error('name may only contain letters, digits, . _ -');
        e.statusCode = 400;
        throw e;
      }
      args.push('-Name', b.name);
    }
    if (b.port) args.push('-Port', String(parseInt(b.port, 10) || 3080));
    const r = await psRun(args, 60000);
    // The list changed: drop the cache so the next read sees the new instance.
    invalidateConfig();
    const insts = await loadInstances();
    return { ok: r.ok, raw: (r.out || '').trim(), instances: insts };
  },

  'GET /api/instances/:name/install': async (ctx) => {
    // A preview built so the confirmation can state what would actually change
    // instead of a generic warning. For a remote host that comes from the probe
    // the URL route already performs, because whether dsh is missing, present
    // but broken, or already fine differs per host.
    await assertKnownInstance(ctx.params.name);
    const cfg = (await loadInstances()).find((c) => c.name === ctx.params.name) || {};
    const isLocal = (cfg.kind || 'remote') === 'local';

    if (isLocal) {
      // A local install is a different proposition and used to have no preview
      // at all: the route described a remote deployment unconditionally, so a
      // local card would have been told "服务器上还没有 dsh" about a machine the
      // reader is sitting at. Nothing here touches the network or ssh.
      return {
        name: ctx.params.name,
        kind: 'local',
        sshHost: '',
        dshInstalled: false,
        dshVersion: '',
        nodeVersion: '',
        linger: '',
        reachable: true,
        plan: '将在这台机器上执行：npm install -g @deepseek-ai/dsh，装进 npm 的全局目录。' +
              '不会安装 Node，也不会修改 hosts.json。',
      };
    }

    const rows = asArray(await psJson(show('status', null, ['-Probe']), 300000));
    const row = rows.find((r) => r.Name === ctx.params.name) || {};
    const version = row.DshVersion || '';
    const installed = Boolean(row.DshInstalled);
    return {
      name: ctx.params.name,
      sshHost: cfg.sshHost || row.SshHost || ctx.params.name,
      kind: cfg.kind || 'remote',
      dshInstalled: installed,
      dshVersion: version,
      nodeVersion: row.NodeV || '',
      linger: row.Linger || '',
      reachable: row.SshReady !== false,
      plan: row.DshInstalled
        ? `服务器上已有 dsh ${version || ''}；将更新服务定义并重新部署 systemd 单元`
        : '服务器上还没有 dsh；将安装 Node 和 dsh，并部署 systemd 用户服务',
    };
  },

  'POST /api/instances/:name/install': async (ctx) => {
    // Destructive-ish either way, so the panel always confirms first and the
    // confirm text names the target: a remote machine, or the one the reader is
    // sitting at. Locally it installs a global npm package and nothing else -
    // Node is never installed for you, and no config file is touched.
    await assertKnownInstance(ctx.params.name);
    const cfg = (await loadInstances()).find((c) => c.name === ctx.params.name) || {};
    const isLocal = (cfg.kind || 'remote') === 'local';
    // The local path only runs npm, but a cold registry plus the --force retry
    // can take minutes; the remote path provisions a whole host.
    const r = await psRun(show('install', ctx.params.name), isLocal ? 600000 : 300000);
    // Installation can change the reported version and service state.
    getStatus(true).catch(() => { /* traced inside */ });
    return { ok: r.ok, kind: isLocal ? 'local' : 'remote', raw: (r.out || '').trim() };
  },

  'GET /api/ssh-hosts': async () => {
    const cfgFile = path.join(process.env.USERPROFILE || '', '.ssh', 'config');
    const configured = new Set((await loadInstances()).map((i) => i.sshHost));
    if (!fs.existsSync(cfgFile)) return { hosts: [], configPath: cfgFile };
    const hosts = [];
    for (const line of fs.readFileSync(cfgFile, 'utf8').split(/\r?\n/)) {
      const m = /^\s*Host\s+(.+)$/i.exec(line);
      if (!m) continue;
      for (const alias of m[1].trim().split(/\s+/)) {
        if (!alias || /[*?]/.test(alias)) continue;
        if (hosts.includes(alias)) continue;
        hosts.push(alias);
      }
    }
    return {
      configPath: cfgFile,
      hosts: hosts.map((h) => ({ name: h, configured: configured.has(h) })),
    };
  },

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
      ok: stop ? !running : running,
      running,
      pid: (status && status.pid) || 0,
      action,
      raw: (r.out || '').trim(),
    };
  },

  'GET /api/versions': async () => {
    // Read-only. Answers "is anything out of date?" without touching anything.
    return { instances: await psJson(show('check'), 180000) };
  },

  'POST /api/upgrade': async (ctx) => {
    // Upgrading restarts dsh on the target, which ends any session in flight, so
    // this is only ever reached by an explicit click -- never by a poll, and
    // never by starting an instance.
    const name = ctx.url.searchParams.get('name') || '';
    const dryRun = ctx.url.searchParams.get('dry') === '1';
    const args = show('upgrade', name || null, dryRun ? ['-DryRun'] : []);
    const r = await psRun(args, 900000);
    // A slow npm install can outlive the child's stdout, so re-read status to
    // report what actually happened rather than trusting the command's own word.
    let after = null;
    try { after = await psJson(show('check'), 180000); } catch (_) { }
    return {
      ok: r.code === 0,
      dryRun,
      name: name || '(all)',
      versions: after && after.instances ? after.instances : after,
      raw: (r.out || '').trim(),
    };
  },

  'GET /api/balance': async (ctx) => {
    // Read-only. Cached for 5 minutes inside the launcher, so a 20s panel poll
    // does not hammer a billing endpoint. ?refresh=1 forces a fresh query.
    const refresh = ctx.url.searchParams.get('refresh') === '1';
    return psJson(show('balance', null, refresh ? ['-Refresh'] : []), 60000);
  },

  'GET /api/doctor': async () => {
    const r = await psRun(show('doctor'), 300000);
    return { text: (r.out || '').replace(/\r/g, '') };
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
      // Only an http(s) URL may be opened as a URL, and only those two schemes.
      const { spawn: sp } = require('child_process');
      sp('rundll32.exe', ['url.dll,FileProtocolHandler', raw],
        { detached: true, stdio: 'ignore', windowsHide: true }).unref();
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
    const { spawn: sp } = require('child_process');
    sp('explorer.exe', [resolved],
      { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    return { ok: true, opened: 'directory' };
  },
};

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

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${HOST}:${PORT}`);
  } catch (_) {
    return send(res, 400, { error: 'bad request' });
  }
  const pathname = url.pathname;

  // The UI shell itself is served with the token injected so the page can call
  // the API; every other route requires the token.
  if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
    if (!authorized(req, url)) return send(res, 403, { error: 'forbidden' }, { 'Content-Type': 'text/plain' });
    const html = fs.readFileSync(path.join(__dirname, 'ui', 'index.html'), 'utf8')
      .replace(/__TOKEN__/g, TOKEN);
    return send(res, 200, html, { 'Content-Type': 'text/html; charset=utf-8' });
  }

  if (!pathname.startsWith('/api/')) return send(res, 404, { error: 'not found' });
  if (!authorized(req, url)) return send(res, 403, { error: 'forbidden' });

  const m = matchRoute(req.method, pathname);
  if (!m) return send(res, 404, { error: 'no such endpoint' });

  try {
    const body = req.method === 'POST' ? await readBody(req) : null;
    const result = await m.handler({ url, params: m.params, body });
    send(res, 200, result);
  } catch (err) {
    send(res, err.statusCode || 500, {
      error: String(err && err.message ? err.message : err),
    });
  }
});

server.listen(0, HOST, () => {
  PORT = server.address().port;
  const publicUrl = `http://${HOST}:${PORT}/?t=${TOKEN}`;
  try {
    fs.mkdirSync(path.dirname(RUNTIME_FILE), { recursive: true });
    fs.writeFileSync(RUNTIME_FILE, JSON.stringify({
      pid: process.pid, port: PORT, token: TOKEN, url: publicUrl,
      startedAt: new Date().toISOString(),
    }, null, 2), 'utf8');
  } catch (e) {
    trace(`warning: could not write ${RUNTIME_FILE}: ${e.message}`);
  }
  trace(`ready on port ${PORT}`);
  // Best effort: harmless when stdout is a pipe, and wrapped so a detached
  // process with no stdout cannot die here.
  try { process.stdout.write(`DSH_APP_READY ${JSON.stringify({ port: PORT, token: TOKEN, url: publicUrl })}\n`); } catch (_) {}

  // Warm the config cache now, while nobody is waiting. Populating it lazily
  // would make whichever request arrived first pay ~1s, and the panel's very
  // first paint is exactly that request.
  loadInstances()
    .then((n) => trace(`config cache warmed (${n.length} instance(s))`))
    .catch((e) => trace(`config cache warm-up failed (will retry on demand): ${e.message}`));

  // Probe once now, then keep refreshing in the background. Callers read the
  // cache and never wait on ssh, so the first panel paint is served from it too.
  getStatus(true)
    .then((rows) => trace(`initial status probe done (${rows.length} instance(s))`))
    .catch((e) => trace(`initial status probe failed: ${e.message}`));
  startStatusPolling();
});

server.on('error', (e) => {
  trace(`app server error: ${e.message}`);
  try { process.stderr.write(`app server error: ${e.message}\n`); } catch (_) {}
  process.exit(1);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    try { fs.unlinkSync(RUNTIME_FILE); } catch (_) {}
    process.exit(0);
  });
}
