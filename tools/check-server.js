#!/usr/bin/env node
'use strict';
// Real loopback HTTP with in-memory launcher/desktop substitutes. No user files,
// PowerShell, SSH, browser, credentials or install commands are accessed.
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { createApp } = require('../app/server');
const { createProcessRunner, parseJson } = require('../app/lib/process-runner');
const { createOperationGate, createConfigCache, mutationResult } = require('../app/lib/operations');
const { redact, publicUrl } = require('../app/lib/security');

const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const cli = (body, code = 0, err = '') => ({ ok: code === 0, code, out: JSON.stringify(body), err });
function envelope(name = 'local', state = 'down', ok = true) {
  return { ok, action: 'fixture', results: [{ name, ok, errorCode: ok ? '' : 'FIXTURE_FAILURE', message: ok ? '完成' : '受控失败' }],
    rows: [{ Name: name, Kind: name === 'local' ? 'local' : 'remote', State: state, Port: 3080, DshInstalled: true }] };
}
async function fixture(t, overrides = {}) {
  const secret = crypto.randomBytes(24).toString('base64url');
  const calls = [];
  let configs = [{ name: 'local', kind: 'local', displayName: '本机', port: 3080 },
    { name: 'remote', kind: 'remote', sshHost: 'example.invalid', localPort: 3099, remotePort: 3080, stopRemoteService: false }];
  const run = async args => {
    const command = args[args.indexOf('-Command') + 1];
    const target = args.includes('-Target') ? args[args.indexOf('-Target') + 1] : null;
    calls.push({ command, target, args });
    if (overrides.run) {
      const value = await overrides.run(command, target, args);
      if (value !== undefined) return value;
    }
    if (command === 'list') return cli(configs);
    if (command === 'status') return cli(configs.map(c => ({ Name: c.name, Kind: c.kind, State: 'down', Port: c.port || c.localPort, DshInstalled: true })));
    if (command === 'plan') {
      const action = args[args.indexOf('-Action') + 1];
      return cli({ ok: true, plans: configs.filter(c => !target || c.name === target).map(c => ({
        name: c.name, kind: c.kind, action, summary: '准备 Node 与 npm install -g @deepseek-ai/dsh，不自动启动服务。',
        targetVersion: '1.2.3', currentVersion: '', nodeVersion: '', changesSoftware: true,
        restartsService: false, requiresConfirmation: true, steps: ['校验运行时', '准备软件'], warnings: [],
      })) });
    }
    if (command === 'ssh-hosts') return cli({ exists: false, hosts: [], configPath: 'fixture/config' });
    if (command === 'edit') {
      const patch = JSON.parse(args[args.indexOf('-Patch') + 1]);
      configs = configs.map(c => c.name === target ? { ...c, ...patch } : c);
      return cli(envelope(target));
    }
    if (command === 'remove') { configs = configs.filter(c => c.name !== target); return cli(envelope(target)); }
    if (command === 'add') {
      const name = args.includes('-Name') ? args[args.indexOf('-Name') + 1] : 'added';
      configs.push({ name, kind: 'remote', sshHost: 'example.invalid' });
      return cli(envelope(name));
    }
    return cli(envelope(target || 'local', command === 'stop' && target === 'remote' ? 'remote-only' : command === 'start' ? 'up' : 'down'));
  };
  const desktop = [];
  const app = createApp({ run, token: secret, persist: false, poll: false, trace: () => {},
    launchDesktop: async (command, args) => desktop.push({ command, args }) });
  const { port } = await app.start();
  t.after(() => app.close());
  function request(endpoint, { method = 'GET', body, raw, auth = true, headers = {} } = {}) {
    return new Promise((resolve, reject) => {
      const req = http.request({ host: '127.0.0.1', port, path: endpoint, method, agent: false,
        headers: { ...(auth ? { Authorization: 'Bearer ' + secret } : {}), 'Content-Type': 'application/json', ...headers } }, response => {
        let text = '';
        response.setEncoding('utf8');
        response.on('data', chunk => { text += chunk; });
        response.on('end', () => {
          let data = null; try { data = JSON.parse(text); } catch (_) {}
          resolve({ status: response.statusCode, headers: response.headers, text, data });
        });
      });
      req.on('error', () => reject(new Error('fixture request failed (request details suppressed)')));
      req.end(raw === undefined ? body === undefined ? undefined : JSON.stringify(body) : raw);
    });
  }
  return { app, request, calls, desktop, secret, port };
}

test('module import has no listening or launcher side effects', () => { assert.equal(typeof createApp, 'function'); });
test('static shell and assets contain no injected credential and carry security headers', async t => {
  const f = await fixture(t);
  for (const endpoint of ['/', '/assets/panel.css', '/assets/panel.mjs', '/assets/model.mjs']) {
    const r = await f.request(endpoint, { auth: false });
    assert.equal(r.status, 200);
    assert.ok(!r.text.includes(f.secret), 'static output must not contain the fixture credential');
    assert.equal(r.headers['referrer-policy'], 'no-referrer');
    assert.ok(!r.headers['content-security-policy'].includes('unsafe-inline'));
  }
  assert.equal(f.calls.length, 0);
  assert.equal((await f.request('/assets/../server.js')).status, 404);
});
test('API authenticates only headers or scoped same-origin session cookies', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/api/instances', { auth: false })).status, 403);
  assert.equal((await f.request('/api/instances?t=' + f.secret, { auth: false })).status, 403);
  const login = await f.request('/api/session', { method: 'POST' });
  assert.equal(login.status, 200);
  const cookie = login.headers['set-cookie'][0];
  assert.ok(cookie.includes('HttpOnly') && cookie.includes('SameSite=Strict'), 'session protection flags');
  const session = cookie.split(';')[0];
  assert.equal((await f.request('/api/instances', { auth: false, headers: { Cookie: session } })).status, 200);
  assert.equal((await f.request('/api/instances', { headers: { Origin: 'https://example.invalid' } })).status, 403);
  assert.equal((await f.request('/api/instances', { headers: { Host: 'example.invalid:' + f.port } })).status, 403);
});
test('malformed paths, invalid JSON and oversized bodies cannot crash the backend', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/api/instances/%E0%A4%A/start', { method: 'POST' })).status, 400);
  assert.equal((await f.request('/api/instances', { method: 'POST', raw: '{' })).status, 400);
  assert.equal((await f.request('/api/instances', { method: 'POST', raw: '[]' })).status, 400);
  assert.equal((await f.request('/api/instances', { method: 'POST', raw: 'x'.repeat(66000) })).status, 413);
  assert.equal((await f.request('/api/instances')).status, 200);
  assert.equal(f.calls.filter(c => ['start', 'add'].includes(c.command)).length, 0);
});
test('failed stops and starts stay failed even with HTTP 200 or process exit zero', async t => {
  const f = await fixture(t, { run: command => ['stop', 'start'].includes(command) ? cli(envelope('local', 'up', false)) : undefined });
  for (const action of ['start', 'stop']) {
    const r = await f.request('/api/instances/local/' + action, { method: 'POST' });
    assert.equal(r.status, 200); assert.equal(r.data.ok, false); assert.equal(r.data.errorCode, 'FIXTURE_FAILURE');
  }
});
test('reported success cannot contradict the observed stop state', async t => {
  const f = await fixture(t, { run: command => command === 'stop' ? cli(envelope('local', 'up', true)) : undefined });
  assert.equal((await f.request('/api/instances/local/stop', { method: 'POST' })).data.ok, false);
});
test('tunnel-only stop scope accepts remote-only as its actual successful state', async t => {
  const f = await fixture(t);
  const r = await f.request('/api/instances/remote/stop', { method: 'POST' });
  assert.equal(r.data.ok, true); assert.equal(r.data.instance.state, 'remote-only');
});
test('upgrade validates targets and propagates child failures', async t => {
  const f = await fixture(t, { run: command => command === 'upgrade' ? cli(envelope('local', 'down', false)) : undefined });
  assert.equal((await f.request('/api/upgrade?name=missing', { method: 'POST' })).status, 400);
  assert.equal(f.calls.filter(c => c.command === 'upgrade').length, 0);
  assert.equal((await f.request('/api/upgrade?name=local', { method: 'POST' })).data.ok, false);
});
test('previews are launcher plans, not an independent hard-coded installation promise', async t => {
  const f = await fixture(t);
  const plan = await f.request('/api/instances/local/plan?action=install');
  assert.equal(plan.data.action, 'install'); assert.equal(plan.data.changesSoftware, true);
  assert.ok(plan.data.summary.includes('Node'));
  const compatibility = await f.request('/api/instances/local/install');
  assert.ok(compatibility.data.plan.includes('npm install'));
  const upgrade = await f.request('/api/upgrade?name=local');
  assert.equal(upgrade.data.plans[0].targetVersion, '1.2.3');
  const dry = await f.request('/api/upgrade?name=local&dry=1', { method: 'POST' });
  assert.equal(dry.data.dryRun, true);
  assert.equal(f.calls.filter(c => ['install', 'upgrade', 'start'].includes(c.command)).length, 0);
});
test('blocked plans preserve actionable details despite launcher exit one', async t => {
  const f = await fixture(t, { run: (command, target) => command === 'plan' ? cli({ ok: false, plans: [{
    ok: false, blocked: true, name: target, action: 'start', kind: 'local', summary: '需要先安装运行时', errorCode: 'runtime-unavailable',
    changesSoftware: false, restartsService: false, requiresConfirmation: false, steps: [], warnings: [],
  }] }, 1) : undefined });
  const r = await f.request('/api/instances/local/plan?action=start');
  assert.equal(r.status, 200); assert.equal(r.data.ok, false); assert.equal(r.data.errorCode, 'runtime-unavailable');
  assert.equal(r.data.summary, '需要先安装运行时');
});
test('fatal launcher errors retain their cause across all plan routes', async t => {
  const f = await fixture(t, { run: command => command === 'plan' ? cli({
    ok: false, plans: [], errorCode: 'invalid-config', error: '配置未通过校验', message: '配置未通过校验',
  }, 1) : undefined });
  for (const [route, options] of [
    ['/api/instances/local/plan?action=start', {}],
    ['/api/upgrade?name=local', {}],
    ['/api/upgrade?name=local&dry=1', { method: 'POST' }],
  ]) {
    const r = await f.request(route, options);
    assert.equal(r.status, 502); assert.equal(r.data.errorCode, 'invalid-config');
    assert.equal(r.data.error, '配置未通过校验');
  }
});
test('per-instance probe errors do not become a freshly successful observation', async t => {
  const f = await fixture(t, { run: command => command === 'status' ? cli([
    { Name: 'local', Kind: 'local', State: 'unreachable', StatusError: '受控探测失败', ProbedAt: '', DshInstalled: false },
  ]) : undefined });
  const r = await f.request('/api/instances');
  assert.equal(r.data[0].probedAt, 0); assert.equal(r.data[0].statusError, '受控探测失败');
});
test('only disconnecting the tunnel can succeed while the remote host is unreachable', async t => {
  const f = await fixture(t, { run: command => command === 'stop' ? cli(envelope('remote', 'unreachable', true)) : undefined });
  assert.equal((await f.request('/api/instances/remote/stop', { method: 'POST' })).data.ok, true);
});
test('invalid ports and config fields are rejected before mutation', async t => {
  const f = await fixture(t);
  for (const port of [0, 65536, 1.2, '3080']) assert.equal((await f.request('/api/instances', { method: 'POST', body: { sshHost: 'example.invalid', port } })).status, 400);
  assert.equal((await f.request('/api/instances/local/config', { method: 'POST', body: { unknown: true } })).status, 400);
  assert.equal((await f.request('/api/instances/local/config', { method: 'POST', body: { enabled: 'false' } })).status, 400);
  assert.equal(f.calls.filter(c => ['add', 'edit'].includes(c.command)).length, 0);
});
test('configuration updates and removal invalidate the configured list', async t => {
  const f = await fixture(t);
  await f.request('/api/instances');
  const edited = await f.request('/api/instances/local/config', { method: 'POST', body: { displayName: '工作机' } });
  assert.equal(edited.data.ok, true);
  assert.equal(edited.data.instances.find(row => row.name === 'local').displayName, '工作机');
  const removed = await f.request('/api/instances/remote/remove', { method: 'POST' });
  assert.equal(removed.data.ok, true); assert.equal(removed.data.instances.length, 1);
  const added = await f.request('/api/instances', { method: 'POST', body: { sshHost: 'example.invalid', name: 'new', displayName: '测试机', port: 3081 } });
  assert.equal(added.data.ok, true); assert.equal(added.data.instances.length, 2);
});
test('offline snapshot does not invoke a status probe and SSH discovery uses the CLI context', async t => {
  const f = await fixture(t);
  const r = await f.request('/api/instances?probe=0');
  assert.equal(r.data[0].state, 'unknown'); assert.equal(r.data[0].probedAt, 0);
  assert.equal(f.calls.filter(c => c.command === 'status').length, 0);
  const hosts = await f.request('/api/ssh-hosts');
  assert.equal(hosts.data.exists, false);
  assert.equal(f.calls.at(-1).command, 'ssh-hosts');
});
test('overlapping instance/global operations are rejected, then released after completion', async t => {
  const started = deferred(); const release = deferred();
  const f = await fixture(t, { run: async command => {
    if (command === 'start') { started.resolve(); await release.promise; return cli(envelope('local', 'up')); }
  } });
  const first = f.request('/api/instances/local/start', { method: 'POST' });
  await started.promise;
  assert.equal((await f.request('/api/instances/local/stop', { method: 'POST' })).status, 409);
  assert.equal((await f.request('/api/instances/remote/install', { method: 'POST' })).status, 409);
  release.resolve(); assert.equal((await first).data.ok, true);
  assert.equal((await f.request('/api/instances/local/stop', { method: 'POST' })).data.ok, true);
});
test('raw diagnostics and logs are redacted before HTTP output', async t => {
  const privateValue = crypto.randomBytes(24).toString('hex');
  const f = await fixture(t, { run: command => ['logs', 'doctor'].includes(command)
    ? { ok: true, code: 0, out: 'http://127.0.0.1:3080/?token=' + privateValue + '\nAuthorization: Bearer ' + privateValue, err: '' } : undefined });
  for (const endpoint of ['/api/instances/local/logs', '/api/doctor']) {
    const r = await f.request(endpoint);
    assert.ok(!r.text.includes(privateValue), 'private diagnostic values must never cross this boundary');
  }
});
test('desktop reveal refuses executable files and non-loopback URLs without launching anything', async t => {
  const f = await fixture(t);
  for (const value of ['https://example.invalid', 'file:///example.exe', __filename]) {
    assert.equal((await f.request('/api/reveal', { method: 'POST', body: { path: value } })).status, 400);
  }
  assert.equal(f.desktop.length, 0);
});
test('strict JSON parser refuses mixed console text and tolerates UTF-8 BOM', () => {
  assert.equal(parseJson('[ok] progress\n{"ok":true}'), null);
  assert.equal(parseJson('\uFEFF{"ok":true}').ok, true);
});
test('operation contract refuses missing results and nonzero exit, even with ok:true', () => {
  assert.equal(mutationResult(cli({ ok: true }), 'local').ok, false);
  assert.equal(mutationResult(cli(envelope(), 1), 'local').ok, false);
});
test('config cache invalidation cannot let an older in-flight load poison the next read', async () => {
  const release = deferred(); let count = 0;
  const cache = createConfigCache(() => ++count === 1 ? release.promise : [{ name: 'new' }]);
  const old = cache.get(); await Promise.resolve();
  cache.invalidate(); const fresh = await cache.get(); release.resolve([{ name: 'old' }]); await old;
  assert.equal(fresh[0].name, 'new'); assert.equal((await cache.get())[0].name, 'new');
});
test('gate releases failed tasks and blocks global work against any active instance', async () => {
  const gate = createOperationGate();
  await assert.rejects(gate.run(['local'], async () => { throw new Error('fixture'); }));
  assert.equal(gate.isBusy('local'), false);
});
test('public URLs discard all credentials, query parameters and fragments', () => {
  const privateValue = crypto.randomBytes(16).toString('hex');
  assert.ok(!publicUrl('http://127.0.0.1:3080/?token=' + privateValue).includes(privateValue));
  assert.ok(!redact('secret=' + privateValue).includes(privateValue));
  assert.equal(publicUrl('javascript:alert(1)'), '');
});
function fakeChild() {
  const child = new EventEmitter(); child.pid = 123456;
  child.stdout = new PassThrough(); child.stderr = new PassThrough(); return child;
}
test('runner reports spawn errors as failures without dumping environment or request detail', async () => {
  const child = fakeChild();
  const run = createProcessRunner({ launcherDir: '.', spawn: () => { queueMicrotask(() => child.emit('error', new Error('fixture'))); return child; } });
  const r = await run(['-Command', 'list'], 1000);
  assert.equal(r.ok, false); assert.equal(r.errorCode, 'LAUNCH_FAILED');
});
test('runner timeout terminates the controlled process tree before reporting an unconfirmed result', async () => {
  const child = fakeChild(); let terminated = false;
  const run = createProcessRunner({ launcherDir: '.', spawn: () => child, killTree: async () => { terminated = true; return true; } });
  const r = await run(['-Command', 'start'], 10);
  assert.equal(terminated, true); assert.equal(r.ok, false); assert.equal(r.errorCode, 'TIMEOUT');
});
test('runner bounds output and reports output-limit failure, not truncated JSON success', async () => {
  const child = fakeChild(); let terminated = false;
  const run = createProcessRunner({ launcherDir: '.', maxBytes: 8, spawn: () => {
    queueMicrotask(() => child.stdout.write('123456789')); return child;
  }, killTree: async () => { terminated = true; return true; } });
  const r = await run(['-Command', 'status'], 1000);
  assert.equal(terminated, true); assert.equal(r.errorCode, 'OUTPUT_LIMIT');
});
