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
      { cwd: LAUNCHER_DIR, windowsHide: true }
    );
    let out = '';
    let err = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { child.kill(); } catch (_) {}
      resolve({ ok: false, code: -1, out, err: err + '\n[timeout]' });
    }, timeoutMs);
    child.stdout.on('data', (d) => { out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { err += d.toString('utf8'); });
    child.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ ok: false, code: -1, out, err: String(e.message) });
    });
    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ ok: code === 0, code, out, err });
    });
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

async function loadInstances() {
  return psJson(show('list'), 30000);
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
  'GET /api/instances': async (ctx) => {
    const probe = ctx.url.searchParams.get('probe') !== '0';
    const rows = await psJson(show('status', null, probe ? ['-Probe'] : ['-NoProbe']), 300000);
    const cfg = await loadInstances();
    const byName = new Map(cfg.map((c) => [c.name, c]));
    return rows.map((r) => {
      const c = byName.get(r.Name) || {};
      return {
        name: r.Name,
        kind: r.Kind,
        state: r.State,
        port: r.Port,
        detail: r.Detail,
        url: r.Url,
        http: r.Http,
        sshHost: c.sshHost || '',
        description: c.description || '',
        enabled: c.enabled !== false,
        remotePort: c.remotePort || null,
        localPort: c.localPort || null,
      };
    });
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
    await assertKnownInstance(ctx.params.name);
    const r = await psMutate(show('start', ctx.params.name, ['-NoOpen']), 300000, ctx.params.name);
    return {
      ok: Boolean(r.state && (r.state.State === 'up' || r.state.State === 'up-external')),
      state: r.state, raw: r.raw, err: r.err, code: r.code,
    };
  },

  'POST /api/instances/:name/stop': async (ctx) => {
    await assertKnownInstance(ctx.params.name);
    const r = await psMutate(show('stop', ctx.params.name), 180000, ctx.params.name);
    return {
      ok: Boolean(r.state && r.state.State === 'down'),
      state: r.state, raw: r.raw, err: r.err, code: r.code,
    };
  },

  'POST /api/instances/:name/restart': async (ctx) => {
    await assertKnownInstance(ctx.params.name);
    const r = await psMutate(show('restart', ctx.params.name), 420000, ctx.params.name);
    return {
      ok: Boolean(r.state && (r.state.State === 'up' || r.state.State === 'up-external')),
      state: r.state, raw: r.raw, err: r.err, code: r.code,
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
    const insts = await loadInstances();
    return { ok: r.ok, raw: (r.out || '').trim(), instances: insts };
  },

  'POST /api/instances/:name/install': async (ctx) => {
    await assertKnownInstance(ctx.params.name);
    const r = await psRun(show('install', ctx.params.name), 300000);
    return { ok: r.ok, raw: (r.out || '').trim() };
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

  'GET /api/doctor': async () => {
    const r = await psRun(show('doctor'), 300000);
    return { text: (r.out || '').replace(/\r/g, '') };
  },

  'POST /api/reveal': async (ctx) => {    if (ctx.body && ctx.body.path && !/^https?:\/\//.test(String(ctx.body.path))) {
      const e = new Error('only http(s) urls can be opened');
      e.statusCode = 400;
      throw e;
    }
    const { spawn: sp } = require('child_process');
    sp('rundll32.exe', ['url.dll,FileProtocolHandler', String(ctx.body.path)],
      { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    return { ok: true };
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
