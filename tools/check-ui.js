// Offline regression tests: shipped ESM policy/controller + a small fake DOM.
// No browser, SSH, real API, user configuration, runtime state or dependencies.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { pathToFileURL } = require('node:url');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const source = file => fs.readFileSync(path.join(root, file), 'utf8');
const html = source('app/ui/index.html');
const css = source('app/ui/panel.css');
const panelSource = source('app/ui/panel.mjs');
const NOW = 1_800_000_000_000;
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const base = (over = {}) => ({ name: 'host', displayName: '开发主机', kind: 'remote', state: 'down',
  sshHost: 'host', enabled: true, dshInstalled: true, dshVersion: '0.1.5-rc.1',
  port: 3099, remotePort: 3080, probedAt: NOW, attemptedAt: NOW, ...over });
const plan = (name, action, over = {}) => ({ name, action, kind: 'remote', currentVersion: '0.1.5-rc.1',
  targetVersion: '0.1.6', nodeVersion: '24.0.0', changesSoftware: false, restartsService: false,
  requiresConfirmation: false, summary: '计划由后端提供', steps: ['检查依赖', '执行选定动作'], warnings: [], ...over });

// Only a DOM contract fake, not a browser/layout engine. Model node identity,
// focus loss on replacement, event bubbling and native dialog close events.
const decode = text => text.replace(/&(amp|lt|gt|quot|#39);/g, (_, key) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[key]);
class FakeNode {
  constructor(tag, owner) {
    this.tagName = tag.toUpperCase(); this.ownerDocument = owner; this.parentNode = null;
    this.childNodes = []; this.attrs = {}; this.dataset = {}; this.listeners = new Map();
    this.hidden = false; this.disabled = false; this.open = false; this.value = ''; this.type = '';
    this.checked = false; this.returnValue = ''; this.nodeType = tag === '#text' ? 3 : 1;
    this._text = ''; this.title = ''; this.selectionStart = 0; this.selectionEnd = 0;
  }
  get children() { return this.childNodes.filter(node => node.nodeType === 1); }
  get id() { return this.attrs.id || ''; }
  get className() { return this.attrs.class || ''; }
  set className(value) { this.attrs.class = value; }
  get isConnected() { return this === this.ownerDocument || Boolean(this.parentNode?.isConnected); }
  setAttribute(key, value) {
    this.attrs[key] = String(value);
    if (key.startsWith('data-')) this.dataset[key.slice(5).replace(/-([a-z])/g, (_, char) => char.toUpperCase())] = String(value);
    if (['hidden', 'disabled', 'open', 'checked'].includes(key)) this[key] = true;
    if (['value', 'type', 'title'].includes(key)) this[key] = String(value);
  }
  getAttribute(key) {
    if (key.startsWith('data-')) return this.dataset[key.slice(5).replace(/-([a-z])/g, (_, char) => char.toUpperCase())] ?? null;
    return this.attrs[key] ?? null;
  }
  matches(selector) {
    if (selector === '*') return true;
    const id = selector.match(/^#([\w-]+)$/); if (id) return this.id === id[1];
    const cls = selector.match(/^\.([\w-]+)$/); if (cls) return this.className.split(/\s+/).includes(cls[1]);
    const tag = selector.match(/^[a-z][\w-]*/i);
    if (tag && this.tagName !== tag[0].toUpperCase()) return false;
    const attrs = [...selector.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)];
    return Boolean(tag || attrs.length) && attrs.every(([, key, value]) => value === undefined ? this.getAttribute(key) !== null : this.getAttribute(key) === value);
  }
  querySelectorAll(selector) {
    const selectors = selector.split(',').map(value => value.trim()), result = [];
    const visit = node => { for (const child of node.children) { if (selectors.some(sel => child.matches(sel))) result.push(child); visit(child); } };
    visit(this); return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  closest(selector) { for (let node = this; node; node = node.parentNode) if (node.matches(selector)) return node; return null; }
  contains(node) { for (let it = node; it; it = it.parentNode) if (it === this) return true; return false; }
  append(...nodes) {
    for (let node of nodes) {
      if (typeof node === 'string') { const item = new FakeNode('#text', this.ownerDocument); item._text = node; node = item; }
      node.remove(); node.parentNode = this; this.childNodes.push(node);
    }
  }
  prepend(node) { node.remove(); node.parentNode = this; this.childNodes.unshift(node); }
  remove() {
    if (!this.parentNode) return;
    if (this.contains(this.ownerDocument.activeElement)) this.ownerDocument.activeElement = this.ownerDocument.querySelector('body');
    this.parentNode.childNodes = this.parentNode.childNodes.filter(node => node !== this); this.parentNode = null;
  }
  get textContent() { return this._text + this.childNodes.map(node => node.textContent).join(''); }
  set textContent(value) { for (const node of [...this.childNodes]) node.remove(); this._text = String(value); }
  set innerHTML(value) { this.textContent = ''; this._html = value; parseHTML(value, this); }
  get innerHTML() { return this._html || ''; }
  addEventListener(type, listener, options = {}) {
    const list = this.listeners.get(type) || []; list.push({ listener, once: options.once }); this.listeners.set(type, list);
  }
  dispatchEvent(event) {
    event.target ||= this; event.currentTarget = this;
    event.preventDefault ||= () => { event.defaultPrevented = true; };
    for (const item of [...(this.listeners.get(event.type) || [])]) {
      item.listener(event);
      if (item.once) this.listeners.set(event.type, this.listeners.get(event.type).filter(value => value !== item));
    }
    if (event.bubbles && this.parentNode) this.parentNode.dispatchEvent(event);
    return !event.defaultPrevented;
  }
  focus() { if (!this.disabled && !this.hidden) this.ownerDocument.activeElement = this; }
  click() { if (!this.disabled) this.dispatchEvent({ type: 'click', bubbles: true }); }
  showModal() { this.open = true; (this.querySelector('[autofocus]') || this.querySelector('button'))?.focus(); }
  close(value = '') { if (!this.open) return; this.returnValue = value; this.open = false; this.dispatchEvent({ type: 'close' }); }
  scrollIntoView() { this.wasScrolled = true; }
}
function parseHTML(input, parent) {
  const stack = [parent];
  for (const token of input.match(/<!--[\s\S]*?-->|<![^>]*>|<\/?[^>]+>|[^<]+/g) || []) {
    if (/^<!/.test(token)) continue;
    if (/^<\//.test(token)) { if (stack.length > 1) stack.pop(); continue; }
    if (token.startsWith('<')) {
      const name = token.match(/^<([\w-]+)/)[1];
      const node = new FakeNode(name, parent.ownerDocument);
      const attributes = token.slice(name.length + 1).replace(/\/?\s*>$/, '');
      for (const [, key, double, single, bare] of attributes.matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) node.setAttribute(key, decode(double ?? single ?? bare ?? ''));
      stack.at(-1).append(node);
      if (!['input', 'meta', 'link', 'br', 'hr', 'img'].includes(name) && !token.endsWith('/>')) stack.push(node);
    } else stack.at(-1).append(decode(token));
  }
}
class FakeDocument extends FakeNode {
  constructor() { super('#document', null); this.ownerDocument = this; this.nodeType = 9; parseHTML(html, this); this.activeElement = this.querySelector('body'); }
  createElement(tag) { return new FakeNode(tag, this); }
}

function commandClauses(sourceText, variable = 'Command') {
  const result = [];
  const pattern = new RegExp(`switch\\s*\\(\\s*\\$(?:script:)?${variable}\\s*\\)\\s*\\{`, 'gi');
  for (const match of sourceText.matchAll(pattern)) {
    let depth = 1, i = match.index + match[0].length;
    while (i < sourceText.length && depth) {
      const char = sourceText[i];
      if (char === '#') { const end = sourceText.indexOf('\n', i); i = end < 0 ? sourceText.length : end + 1; continue; }
      if (char === '@' && /['"]/.test(sourceText[i + 1]) && /^@['"]\r?\n/.test(sourceText.slice(i))) {
        const end = sourceText.indexOf(`\n${sourceText[i + 1]}@`, i + 2);
        assert.notEqual(end, -1, 'Unclosed PowerShell here-string in surface scanner'); i = end + 3; continue;
      }
      if (char === "'" || char === '"') {
        const start = i++; let value = '';
        while (i < sourceText.length) {
          if (sourceText[i] === '`') { i += 2; continue; }
          if (sourceText[i] === char) { if (sourceText[i + 1] === char) { i += 2; continue; } i++; break; }
          value += sourceText[i++];
        }
        if (depth === 1 && /^[a-z][a-z-]*$/.test(value) && /^\s*\{/.test(sourceText.slice(i))) result.push(value);
        assert.ok(i > start); continue;
      }
      if (char === '{') depth++;
      if (char === '}') depth--;
      i++;
    }
    assert.equal(depth, 0, 'Unclosed PowerShell command dispatcher');
  }
  return [...new Set(result)].sort();
}

async function main() {
  const m = await import(pathToFileURL(path.join(root, 'app/ui/model.mjs')).href);
  const p = await import(pathToFileURL(path.join(root, 'app/ui/panel.mjs')).href);
  function apiFixture(rows = [base()], handler = () => undefined) {
    const api = { rows, calls: [], clean: m.redactText, establishSession: async () => {},
      async request(url, options = {}) {
        api.calls.push({ url, ...options });
        const result = await handler(url, options);
        if (result !== undefined) return result;
        if (url === '/api/instances' && options.method !== 'POST') return structuredClone(api.rows);
        if (url === '/api/tray') return { running: false };
        if (url.startsWith('/api/balance')) return { ok: false };
        if (url === '/api/ssh-hosts') return { hosts: [], exists: false, configPath: 'fixture-ssh-config' };
        throw new Error(`Unexpected fake API request: ${url}`);
      } };
    return api;
  }
  async function controllerFixture(rows, handler, options = {}) {
    const api = apiFixture(rows, handler);
    const controller = p.createController({ api, now: () => NOW, confirm: async () => true, ...options });
    await controller.refresh(); return { api, controller };
  }
  async function panelFixture(rows, handler, options = {}) {
    const api = apiFixture(rows, handler), document = new FakeDocument(), opened = [], copied = [];
    const window = { open: (...args) => { opened.push(args); return null; },
      navigator: { clipboard: { writeText: async value => copied.push(value) } },
      setInterval: () => { throw new Error('Polling must remain disabled in offline tests'); }, clearInterval: () => {} };
    const app = p.createPanel({ document, window, api, poll: false, now: () => NOW, confirm: async () => true, ...options });
    await app.start(); return { app, api, document, opened, copied, $: selector => document.querySelector(selector) };
  }
  // Former 36 checks: command builders, gates, local setup/recovery, workdir,
  // filtering/focus, syntax and all three launcher surface promises. The old
  // "down is an error" expectations deliberately change to the new contract.
  for (const [code, host, expected] of [
    ['timeout', '192.0.2.10', /^ping/], ['dns', 'no-such-host.invalid', /^ssh -G no-such-host\.invalid/],
    ['auth', 'fixture-host', /^ssh -v/], ['hostkey', 'fixture-host', /^ssh-keygen -F/],
    ['refused', 'fixture-host', /systemctl status ssh/],
  ]) test(`failure command: ${code}`, () => {
    const command = m.FAIL_STEP[code].cmd(host);
    assert.match(command, expected); assert.ok(command.includes(host)); assert.doesNotMatch(command, /\{host\}|\$\{/);
  });
  test('every classified SSH failure has a next step; unknown stays bare', () => {
    for (const code of ['dns', 'refused', 'auth', 'hostkey', 'timeout']) assert.ok(m.FAIL_STEP[code]);
    assert.equal(m.failureStep(base({ failCode: 'unknown' })), null);
  });
  test('failure command cannot turn an unsafe host into shell options or syntax', () => {
    for (const sshHost of ['-oProxyCommand=bad', 'host;anything', 'host\nnext']) assert.equal(m.failureStep(base({ sshHost, failCode: 'dns' })), null);
  });
  for (const [label, over, wanted] of [
    ['remote missing', { dshInstalled: false }, true], ['remote installed', {}, false],
    ['remote unreachable', { dshInstalled: false, state: 'unreachable' }, false],
  ]) test(`deploy action: ${label}`, () => assert.equal(m.availableActions(base(over)).includes('install'), wanted));
  test('local setup is an installation action, never labelled remote deployment', async () => {
    const fixture = await panelFixture([base({ kind: 'local', dshInstalled: false, dshVersion: '' })]);
    const card = fixture.$('.card');
    assert.match(card.querySelector('[data-role="install"]').textContent, /安装准备/);
    assert.doesNotMatch(card.querySelector('[data-role="install"]').textContent, /远程/);
  });
  for (const installed of [false, true]) test(`local install/start are mutually exclusive: installed=${installed}`, () => {
    const actions = m.availableActions(base({ kind: 'local', dshInstalled: installed }));
    assert.equal(actions.includes('start'), installed); assert.equal(actions.includes('install'), !installed);
  });
  test('missing local dependency has a visible hint even without backend hint text', async () => {
    const { $ } = await panelFixture([base({ kind: 'local', dshInstalled: false, hint: '' })]);
    assert.equal($('[data-role="hint-row"]').hidden, false); assert.match($('[data-role="hint"]').textContent, /Node.*dsh/);
  });
  test('manual recovery uses the launcher install path, not npm without a runtime', () => {
    assert.equal(m.installCommand('local'), ".\\dsh.ps1 -Command install -Target 'local'");
    assert.equal(m.installCommand("bad'command"), '');
  });
  for (const [kind, workdir, wanted] of [['local', 'C:\\Projects\\Sample', true], ['local', '', false], ['remote', 'C:\\Projects\\Sample', false]]) {
    test(`workdir visibility: ${kind}, present=${Boolean(workdir)}`, () => assert.equal(Boolean(m.workdirDisplay(base({ kind, workdir }))), wanted));
  }
  test('workdir keeps the full path and a useful two-component abbreviation', () => {
    assert.deepEqual(m.workdirDisplay(base({ kind: 'local', workdir: 'C:\\Users\\Fixture\\Documents' })), { full: 'C:\\Users\\Fixture\\Documents', short: '…\\Fixture\\Documents' });
  });
  test('updates need an installed version and use target/pin before latest', () => {
    assert.equal(m.updateNotice(base({ dshVersion: '', updateAvailable: true })), '');
    const notice = m.updateNotice(base({ updateAvailable: true, pinnedVersion: '0.1.6', latestVersion: '99.0.0' }));
    assert.match(notice, /0\.1\.6/); assert.doesNotMatch(notice, /99\.0\.0/);
  });
  const filterBase = base({ name: 'Trade_Main', displayName: '交易主机', sshHost: 'Trade_Main', description: 'trade box', state: 'up' });
  for (const [label, over, query, errors, wanted] of [
    ['empty', {}, '', false, true], ['name', {}, 'trade', false, true], ['case insensitive', {}, 'TRADE', false, true],
    ['host', { name: 'x', sshHost: 'DuckServer' }, 'duck', false, true], ['description', {}, 'box', false, true],
    ['no match', {}, 'zzz', false, false], ['commas', {}, 'trade,main', false, true], ['spaces', {}, 'trade main', false, true],
    ['missing needle', {}, 'trade,zzz', false, false], ['healthy hidden', {}, '', true, false],
    ['normal down is not an error', { state: 'down' }, '', true, false],
    ['down with query is not an error', { state: 'down' }, 'trade', true, false], ['whitespace', {}, '   ', false, true],
    ['Chinese display name', {}, '交易', false, true], ['disabled is not an error', { state: 'disabled' }, '', true, false],
    ['unreachable is an error', { state: 'unreachable' }, '', true, true],
    ['active but unhealthy is an error', { state: 'unhealthy' }, '', true, true],
    ['failed probe of stopped instance', { state: 'down', statusError: 'probe failed' }, '', true, true],
    ['intentional remote-only', { state: 'remote-only', stopRemoteService: false }, '', true, false],
  ]) test(`filter: ${label}`, () => assert.equal(m.instanceMatches({ ...filterBase, ...over }, query, errors), wanted));
  test('filter and editing form are outside the replaceable list', () => {
    const document = new FakeDocument();
    assert.ok(!document.querySelector('#list').contains(document.querySelector('#flt-q')));
    assert.ok(!document.querySelector('#list').contains(document.querySelector('#config-form')));
  });
  test('single-instance UI hides unnecessary filters and batch actions', async () => {
    const { $ } = await panelFixture([base()]);
    assert.equal($('#filter').hidden, true); assert.equal($('#btn-start-all').hidden, true);
  });
  test('stop targets include remote-only, tunnel-only and active disabled registrations', () => {
    const instances = ['up', 'up-external', 'remote-only', 'tunnel-only', 'unhealthy', 'down', 'disabled'].map((state, index) => base({ name: String(index), state, enabled: false }));
    assert.deepEqual(m.selectTargets(instances, 'stop').map(it => it.state), ['up', 'up-external', 'remote-only', 'tunnel-only', 'unhealthy']);
    for (const it of instances.slice(0, 5)) assert.ok(m.availableActions(it).includes('stop'));
    assert.ok(m.availableActions(base({ state: 'unhealthy' })).includes('restart'));
  });
  test('batch start skips disabled and missing-local dependencies, never installs implicitly', () => {
    const rows = [base({ name: 'missing', kind: 'local', dshInstalled: false }), base({ name: 'disabled', enabled: false }), base({ name: 'ready', kind: 'local' })];
    assert.deepEqual(m.selectTargets(rows, 'start').map(it => it.name), ['ready']);
  });
  test('freshness uses last successful probe rather than request/attempt time', () => {
    const result = m.probeFreshness(base({ probedAt: NOW - 100_000, attemptedAt: NOW, statusError: 'failed' }), NOW);
    assert.equal(result.kind, 'failed'); assert.equal(result.stale, true); assert.equal(result.probedAt, NOW - 100_000);
    assert.equal(m.probeFreshness(base({ probedAt: null }), NOW).kind, 'never');
    assert.equal(m.probeFreshness(base({ probedAt: NOW - 100_000 }), NOW).kind, 'stale');
    assert.equal(m.probeFreshness(base(), NOW).kind, 'fresh');
  });
  test('invalid and future timestamps do not claim a fresh successful probe', () => {
    assert.equal(m.probeFreshness(base({ probedAt: 'invalid' }), NOW).kind, 'never');
    assert.equal(m.probeFreshness(base({ probedAt: NOW + 60_000 }), NOW).stale, true);
  });
  test('older snapshots cannot regress operation state; config can still update', () => {
    const rows = m.mergeSnapshot([base({ state: 'up' })], [base({ state: 'down', probedAt: NOW - 1, displayName: '新名称' })]);
    assert.equal(rows[0].state, 'up'); assert.equal(rows[0].displayName, '新名称');
  });
  for (const suffix of ['?t=fixture-value', '?x=1&token=fixture-value&y=2', '?TOKEN=fixture-value', '#t=fixture-value', '#fixture-value', '?access_token=fixture-value#route']) {
    test(`safeURL strips ${suffix.split('=')[0]}`, () => assert.equal(m.safeURL(`http://127.0.0.1:3080/path${suffix}`), 'http://127.0.0.1:3080/path'));
  }
  test('safeURL rejects non-web schemes and removes userinfo', () => {
    for (const url of ['javascript:alert(1)', 'file:///fixture', 'not a URL']) assert.equal(m.safeURL(url), '');
    assert.equal(m.safeURL('http://fixture-user:fixture-password@localhost:3080/'), 'http://localhost:3080/');
  });
  test('opening is restricted to loopback HTTP without userinfo', () => {
    assert.ok(m.loopbackURL('http://127.0.0.1:3080/?t=fixture'));
    for (const url of ['https://localhost/', 'http://example.invalid/', 'file:///fixture', 'http://u:p@localhost/']) assert.equal(m.loopbackURL(url), '');
  });
  test('diagnostics redact URL credentials, headers, assignments and known memory values', () => {
    const result = m.redactText('http://localhost:3080/?token=fixture-url#fixture-hash\nAuthorization: Bearer fixture-header\nCookie: fixture-cookie\napi_key=fixture-key\npassword="fixture-password"\nfixture-memory', ['fixture-memory']);
    for (const value of ['fixture-url', 'fixture-hash', 'fixture-header', 'fixture-cookie', 'fixture-key', 'fixture-password', 'fixture-memory']) assert.ok(!result.includes(value));
  });
  test('strict business result rejects HTTP-success-like and nested failure replies', () => {
    for (const reply of [{ ok: false, code: 0 }, { code: 0 }, { ok: 'true' }, { ok: true, results: [{ name: 'host', ok: false }] }]) assert.equal(m.operationResult(reply, 'host', 'stop').ok, false);
    assert.equal(m.operationResult({ ok: true, instance: { state: 'remote-only' } }, 'host', 'stop').ok, true);
  });
  test('operation results never retain raw or raw instance URLs', () => {
    const result = m.operationResult({ ok: false, raw: 'fixture-private-output', instance: { url: 'http://localhost/?t=fixture' }, message: 'failed http://localhost/?t=fixture' }, 'host', 'stop');
    assert.ok(!Object.hasOwn(result, 'raw')); assert.ok(!Object.hasOwn(result, 'instance')); assert.ok(!JSON.stringify(result).includes('fixture'));
  });
  test('batch summary reports partial failure rather than successful request count', () => {
    assert.deepEqual(m.summarizeResults([{ ok: true }, { ok: false }]), { total: 2, success: 1, failed: 1, status: 'partial', text: '1 / 2 个成功，1 个失败' });
  });
  test('task history is bounded and does not evict active work', () => {
    let history = [{ id: 0, status: 'running' }];
    for (let id = 1; id < 100; id++) history = m.appendTask(history, { id, status: 'success' });
    assert.equal(history.length, m.HISTORY_LIMIT); assert.equal(history[0].id, 0);
    assert.throws(() => m.appendTask(Array.from({ length: m.HISTORY_LIMIT }, () => ({ status: 'running' })), {}));
  });
  test('plans validate target/action/booleans and retain concrete steps and warnings', () => {
    const result = m.normalizePlan(plan('host', 'install', { changesSoftware: true, steps: ['下载 Node'], warnings: ['不会启动服务'] }), 'host', 'install');
    assert.deepEqual(result.steps, ['下载 Node']); assert.deepEqual(result.warnings, ['不会启动服务']);
    for (const invalid of [{}, plan('other', 'install'), plan('host', 'start'), plan('host', 'install', { changesSoftware: undefined })]) assert.throws(() => m.normalizePlan(invalid, 'host', 'install'));
  });
  test('stop/restart confirmations disclose exact remote scope and interruption', () => {
    const data = m.confirmationFor('stop', [base({ stopRemoteService: false })]);
    assert.match(data.lines.join(' '), /仅断开.*保留远端.*连接将中断/);
    assert.match(m.confirmationFor('restart', [base()]).lines.join(' '), /停止远端.*停止后重新启动/);
  });
  test('install confirmation does not promise Node will never be installed', () => {
    const data = m.confirmationFor('install', [base({ kind: 'local' })]);
    assert.match(data.lines.join(' '), /Node.*计划/); assert.doesNotMatch(data.lines.join(' '), /不会安装 Node/);
  });
  for (const [kind, info] of [
    ['missing', { exists: false, hosts: [] }], ['empty', { exists: true, hosts: [] }],
    ['configured', { exists: true, hosts: [{ name: 'h', configured: true }] }],
    ['available', { exists: true, hosts: [{ name: 'h', configured: false }] }],
  ]) test(`SSH discovery empty state: ${kind}`, () => assert.equal(m.sshHostState(info).kind, kind));
  test('Chinese display names and machine names stay separate, port errors are local', () => {
    const result = m.validateAdd({ sshHost: 'dev', name: 'dev-id', displayName: '中文名称', port: '3090' });
    assert.deepEqual(result.body, { sshHost: 'dev', name: 'dev-id', displayName: '中文名称', port: 3090 });
    for (const port of ['0', '65536', '3.5', '3080oops']) assert.ok(m.validateAdd({ sshHost: 'dev', port }).errors.port);
    assert.ok(m.validateAdd({ sshHost: 'dev', name: '中文' }).errors.name);
    assert.ok(m.validateAdd({ sshHost: 'dev', name: 'HOST' }, [base()]).errors.name);
  });
  test('configuration patch is whitelisted and pinned version is not installed version', () => {
    assert.equal(m.configValues(base({ dshVersion: '1.2.3', pinnedVersion: '' })).dshVersion, '');
    const values = { ...m.configValues(base()), displayName: '新名称', dshVersion: '0.1.6', name: 'illegal', url: 'illegal', workdir: '/remote', enabled: false, autoInstall: false, stopRemoteService: false };
    const remote = m.validateConfig(values, base());
    assert.equal(remote.ok, true); assert.deepEqual(Object.keys(remote.body).sort(), ['autoInstall', 'description', 'displayName', 'dshVersion', 'enabled', 'stopRemoteService'].sort());
    assert.equal(remote.body.autoInstall, false); assert.equal(remote.body.stopRemoteService, false);
    const local = m.validateConfig(values, base({ kind: 'local' }));
    assert.ok(Object.hasOwn(local.body, 'workdir')); assert.ok(!Object.hasOwn(local.body, 'autoInstall'));
    assert.ok(m.validateConfig({ ...values, dshVersion: 'latest' }, base()).errors.dshVersion);
  });

  test('authentication scrubs the address before session POST, then uses headers', async () => {
    const events = [], calls = [];
    const api = p.createApiClient({ location: { href: 'http://127.0.0.1:9000/?t=fixture-query#t=fixture-fragment' },
      history: { replaceState: (_, __, url) => events.push(['clean', url]) },
      fetchImpl: async (url, options) => { events.push(['fetch', url]); calls.push({ url, ...options }); return { ok: true, json: async () => ({ ok: true }) }; } });
    assert.deepEqual(events, [['clean', '/']]);
    await api.establishSession(); await api.request('/api/instances');
    assert.equal(calls[0].url, '/api/session'); assert.equal(calls[0].method, 'POST');
    assert.ok(calls.every(call => call.headers.Authorization === 'Bearer fixture-fragment' && call.credentials === 'same-origin' && !call.url.includes('fixture')));
    assert.ok(!Object.hasOwn(api, 'token'));
  });
  test('legacy query bootstrap and no-fragment cookie refresh are supported', async () => {
    assert.equal(m.entryAuth('http://localhost/?t=fixture-query').token, 'fixture-query');
    const calls = [];
    const api = p.createApiClient({ location: { href: 'http://localhost/' }, history: { replaceState() {} },
      fetchImpl: async (url, options) => { calls.push({ url, ...options }); return { ok: true, json: async () => [] }; } });
    await api.establishSession(); await api.request('/api/instances');
    assert.equal(calls.length, 1); assert.equal(calls[0].headers.Authorization, undefined); assert.equal(calls[0].credentials, 'same-origin');
  });
  test('unauthenticated requests give Start.exe recovery without displaying backend auth text', async () => {
    const api = p.createApiClient({ location: { href: 'http://localhost/' }, history: { replaceState() {} },
      fetchImpl: async () => ({ ok: false, status: 401, json: async () => ({ error: 'fixture-private-auth' }) }) });
    await assert.rejects(api.request('/api/instances'), error => error.auth && /Start\.exe/.test(error.message) && !error.message.includes('fixture-private'));
  });
  test('API cannot leak auth through cross-origin or query-token requests', async () => {
    let calls = 0;
    const api = p.createApiClient({ location: { href: 'http://localhost/#t=fixture' }, history: { replaceState() {} }, fetchImpl: async () => { calls++; } });
    for (const url of ['https://example.invalid/api/instances', '/api/instances?t=fixture', '/api/instances?TOKEN=fixture']) await assert.rejects(api.request(url));
    assert.equal(calls, 0);
  });
  test('HTTP 200 ok:false remains a business failure at the API boundary', async () => {
    const api = p.createApiClient({ location: { href: 'http://localhost/' }, history: { replaceState() {} }, fetchImpl: async () => ({ ok: true, json: async () => ({ ok: false, code: 0, message: 'not stopped' }) }) });
    const reply = await api.request('/api/instances/host/stop', { method: 'POST' });
    assert.equal(m.operationResult(reply, 'host', 'stop').ok, false);
  });
  test('failed stop remains visible as failed; remote-only success respects r.ok', async () => {
    for (const ok of [false, true]) {
      const { controller } = await controllerFixture([base({ state: 'remote-only', stopRemoteService: false })], url => url.endsWith('/stop') ? { ok, code: ok ? 0 : 1, message: ok ? 'tunnel stopped' : 'stop refused' } : undefined);
      const task = await controller.run('stop', ['host']);
      assert.equal(task.status, ok ? 'success' : 'failed'); assert.equal(task.results[0].ok, ok);
      assert.equal(controller.state.tasks.at(-1), task); assert.equal(controller.state.busy.size, 0);
    }
  });
  test('batch partial failure locks every target throughout and blocks duplicate/config operations', async () => {
    const gate = deferred(), rows = [base({ name: 'a', state: 'remote-only' }), base({ name: 'b', state: 'tunnel-only' })];
    const { controller, api } = await controllerFixture(rows, url => url.endsWith('/a/stop') ? gate.promise : url.endsWith('/b/stop') ? { ok: false, message: 'fixture failure' } : undefined);
    const pending = controller.run('stop', ['a', 'b']); await tick();
    assert.deepEqual([...controller.state.busy].sort(), ['a', 'b']);
    assert.equal(await controller.run('stop', ['b']), null);
    assert.equal(await controller.run('config', ['b'], { body: m.configValues(rows[1]) }), null);
    gate.resolve({ ok: true, message: 'stopped' });
    const task = await pending;
    assert.equal(task.status, 'partial'); assert.match(task.phase, /1 \/ 2.*1 个失败/);
    assert.equal(api.calls.filter(call => call.method === 'POST').length, 2); assert.equal(controller.state.busy.size, 0);
  });
  test('first remote start reads a plan and cannot deploy before approval', async () => {
    const consent = deferred(), events = [];
    const { controller } = await controllerFixture([base({ dshInstalled: false })], (url, options) => {
      if (url.includes('/plan?action=start')) { events.push('plan'); return plan('host', 'start', { changesSoftware: true, requiresConfirmation: true, steps: ['安装 Node 和 dsh', '部署服务'] }); }
      if (options.method === 'POST') { events.push('post'); return { ok: true }; }
    }, { confirm: data => { events.push('confirm'); assert.match(data.plans[0].steps.join(' '), /Node/); return consent.promise; } });
    const pending = controller.run('start', ['host']); await tick();
    assert.deepEqual(events, ['plan', 'confirm']); consent.resolve(false);
    const task = await pending; assert.equal(task.status, 'cancelled'); assert.ok(!events.includes('post'));
  });
  test('safe remote start still reads plan but does not require a redundant dialog', async () => {
    let confirmations = 0;
    const { controller, api } = await controllerFixture([base()], (url, options) => url.includes('/plan?') ? plan('host', 'start') : options.method === 'POST' ? { ok: true } : undefined,
      { confirm: async () => { confirmations++; return true; } });
    await controller.run('start', ['host']);
    assert.equal(confirmations, 0); assert.ok(api.calls.some(call => call.url.includes('/plan?action=start')));
  });
  test('plan failure is fail-closed and never sends a mutation', async () => {
    const { controller, api } = await controllerFixture([base()], url => url.includes('/plan?') ? {} : undefined);
    const task = await controller.run('start', ['host']);
    assert.equal(task.status, 'failed'); assert.ok(!api.calls.some(call => call.method === 'POST'));
  });
  test('batch upgrade preview uses GET only and reserves actual target names', async () => {
    const gate = deferred();
    const { controller, api } = await controllerFixture([base({ name: 'a' }), base({ name: 'b' })], url => url === '/api/upgrade?name=a' ? gate.promise : url === '/api/upgrade?name=b' ? { ok: true, plans: [plan('b', 'upgrade')] } : undefined);
    const pending = controller.run('upgrade', ['a', 'b'], { preview: true }); await tick();
    assert.deepEqual([...controller.state.busy].sort(), ['a', 'b']);
    gate.resolve({ ok: true, plans: [plan('a', 'upgrade')] });
    const task = await pending; assert.equal(task.status, 'preview'); assert.equal(task.plans.length, 2);
    assert.ok(!api.calls.some(call => call.method === 'POST' || call.url.includes('dry=')));
  });
  test('late poll cannot overwrite a completed mutation', async () => {
    const old = deferred(); let reads = 0;
    const { controller } = await controllerFixture([base({ kind: 'local' })], (url, options) => {
      if (url === '/api/instances') { reads++; if (reads === 2) return old.promise; if (reads > 2) return [base({ kind: 'local', state: 'up', probedAt: NOW + 1 })]; }
      if (options.method === 'POST') return { ok: true, instance: base({ kind: 'local', state: 'up', probedAt: NOW + 1 }) };
    });
    const pending = controller.refresh(); await tick(); await controller.run('start', ['host']);
    old.resolve([base({ kind: 'local', state: 'down', probedAt: NOW - 1000 })]); await pending;
    assert.equal(controller.state.instances[0].state, 'up');
  });
  test('poll failure preserves cards and last success instead of stamping now', async () => {
    let fail = false;
    const { controller } = await controllerFixture([base({ probedAt: NOW - 100_000 })], url => { if (url === '/api/instances' && fail) throw new Error('offline fixture'); });
    fail = true; await controller.refresh();
    assert.equal(controller.state.instances.length, 1); assert.equal(controller.state.instances[0].probedAt, NOW - 100_000); assert.match(controller.state.loadError, /offline/);
  });
  test('configuration succeeds only by r.ok, sends a whitelist, and refreshes afterward', async () => {
    const { controller, api } = await controllerFixture([base()], (url, options) => options.method === 'POST' ? { ok: true, message: 'saved' } : undefined);
    const task = await controller.run('config', ['host'], { body: { ...m.configValues(base()), displayName: '中文', enabled: false, unexpected: true } });
    assert.equal(task.status, 'success'); const request = api.calls.find(call => call.method === 'POST');
    assert.equal(request.url, '/api/instances/host/config'); assert.equal(request.body.displayName, '中文'); assert.equal(request.body.enabled, false);
    assert.ok(!Object.hasOwn(request.body, 'unexpected')); assert.equal(api.calls.at(-1).url, '/api/instances');
    assert.ok(!api.calls.some(call => /\/(stop|restart)$/.test(call.url)));
  });
  test('remove failure never auto-stops or uninstalls; its scope is confirmed', async () => {
    let confirmation;
    const { controller, api } = await controllerFixture([base({ state: 'up' })], url => url.endsWith('/remove') ? { ok: false, errorCode: 'managed-process', message: 'still managed' } : undefined,
      { confirm: async data => { confirmation = data; return true; } });
    const task = await controller.run('remove', ['host']); assert.equal(task.status, 'failed');
    assert.match(confirmation.lines.join(' '), /不停止进程、不卸载软件、不删除用户数据/);
    assert.equal(api.calls.filter(call => call.method === 'POST').length, 1); assert.equal(controller.state.instances.length, 1);
  });
  test('fresh URL opens with noopener; null is not reported as blocked; tokens stay out of the DOM/history', async () => {
    const freshURL = 'http://127.0.0.1:3080/?t=fixture-fresh-url';
    const { app, opened, document } = await panelFixture([base({ state: 'up', url: 'http://127.0.0.1:3080/?token=fixture-old-url' })], url => url.endsWith('/url') ? { ok: true, url: freshURL } : undefined);
    const task = await app.controller.openInstance('host');
    assert.equal(opened[0][0], freshURL); assert.match(opened[0][2], /noopener/); assert.equal(task.status, 'success');
    assert.doesNotMatch(task.phase, /拦截/); assert.match(task.results[0].message, /已请求/);
    assert.ok(!JSON.stringify(app.controller.state.tasks).includes('fixture-fresh-url'));
    assert.ok(!document.textContent.includes('fixture-old-url'));
    for (const node of document.querySelectorAll('*')) assert.ok(!JSON.stringify([node.attrs, node.dataset, node.title]).includes('fixture-old-url'));
  });
  test('fresh URL failure never falls back to the cached link', async () => {
    const { app, opened } = await panelFixture([base({ state: 'up', url: 'http://localhost:3080/?t=fixture-old' })], url => { if (url.endsWith('/url')) throw new Error('probe unavailable'); });
    const task = await app.controller.openInstance('host'); assert.equal(task.status, 'failed'); assert.equal(opened.length, 0); assert.match(task.phase, /没有回退/);
  });
  test('explicit system browser fallback re-fetches the address before reveal', async () => {
    const freshURL = 'http://localhost:3080/?token=fixture-new';
    const { controller, api } = await controllerFixture([base()], url => url.endsWith('/url') ? { ok: true, url: freshURL } : url === '/api/reveal' ? { ok: true } : undefined);
    const task = await controller.openInstance('host', true); assert.equal(task.status, 'success');
    const calls = api.calls.slice(-2); assert.equal(calls[0].url, '/api/instances/host/url'); assert.equal(calls[1].body.path, freshURL);
  });
  test('copy uses only the visible safe address', async () => {
    const { $, copied } = await panelFixture([base({ state: 'up', url: 'http://localhost:3080/?token=fixture-copy#fixture-hash' })]);
    $('[data-action="copy-url"]').click(); await tick(); assert.deepEqual(copied, ['http://localhost:3080/']);
  });
  test('upgrade preview opens the persistent results and is visible inside an open detail dialog', async () => {
    const { app, $ } = await panelFixture([base()], url => url.startsWith('/api/upgrade?') ? { ok: true, plans: [plan('host', 'upgrade', { changesSoftware: true, steps: ['安装目标 0.1.6'], warnings: ['现有连接会中断'] })] } : undefined);
    app.openDetail('host'); $('#task-panel').open = false;
    const task = await app.controller.run('upgrade', ['host'], { preview: true });
    assert.equal(task.status, 'preview'); assert.equal($('#task-panel').open, true); assert.equal($('#detail-task').hidden, false);
    assert.equal($('#detail-task').wasScrolled, true);
    assert.match($('#detail-task-body').textContent, /安装目标 0\.1\.6/); assert.match($('#detail-task-body').textContent, /现有连接会中断/);
    assert.equal($('#detail-dialog').open, true);
  });
  test('polling preserves search/caret, detail edits, checkbox values and focused card node identity', async () => {
    const { app, api, $, document } = await panelFixture([base(), base({ name: 'other' })]);
    const search = $('#flt-q'); search.value = 'host'; search.selectionStart = 2; search.selectionEnd = 2; search.focus();
    api.rows[0].probedAt = NOW + 1; await app.controller.refresh(); assert.equal(document.activeElement, search); assert.equal(search.selectionStart, 2);
    const cardButton = $('[data-role="name"]'); cardButton.focus(); api.rows[0].probedAt++;
    await app.controller.refresh(); assert.equal(document.activeElement, cardButton); assert.equal($('[data-role="name"]'), cardButton);
    app.openDetail('host'); const field = $('#cfg-display-name'); field.value = '未保存的中文'; field.selectionStart = 3; field.focus(); $('#cfg-auto-install').checked = false;
    api.rows[0].displayName = '后端旧名称'; await app.controller.refresh();
    assert.equal(document.activeElement, field); assert.equal(field.value, '未保存的中文'); assert.equal(field.selectionStart, 3); assert.equal($('#cfg-auto-install').checked, false);
  });
  test('batch DOM busy covers queued targets and configuration controls', async () => {
    const gate = deferred();
    const { app, $, document } = await panelFixture([base({ name: 'a', state: 'up' }), base({ name: 'b', state: 'tunnel-only' })], url => url.endsWith('/a/stop') ? gate.promise : url.endsWith('/b/stop') ? { ok: false } : undefined);
    app.openDetail('b'); const pending = app.controller.run('stop', ['a', 'b']); await tick();
    assert.equal($('#btn-save-config').disabled, true); assert.equal($('#btn-remove').disabled, true); assert.equal($('#cfg-description').disabled, true);
    for (const card of document.querySelectorAll('.card')) assert.equal(card.querySelector('[data-action="stop"]').disabled, true);
    gate.resolve({ ok: true }); await pending; assert.equal($('#btn-save-config').disabled, false);
  });
  test('field errors are local and invalid configuration never sends a POST', async () => {
    const { app, $, api, document } = await panelFixture([base()]);
    app.openDetail('host'); $('#cfg-version').value = 'latest'; await app.saveConfig();
    assert.equal($('#cfg-version').getAttribute('aria-invalid'), 'true'); assert.match($('#cfg-version-error').textContent, /明确版本/);
    assert.equal(document.activeElement, $('#cfg-version')); assert.ok(!api.calls.some(call => call.method === 'POST'));
  });
  test('a failed config save leaves the typed draft and visible reason intact', async () => {
    const { app, $ } = await panelFixture([base()], url => url.endsWith('/config') ? { ok: false, message: 'fixture save failure' } : undefined);
    app.openDetail('host'); $('#cfg-display-name').value = '未保存草稿'; await app.saveConfig();
    assert.equal($('#cfg-display-name').value, '未保存草稿'); assert.match($('#config-feedback').textContent, /fixture save failure/);
    assert.equal($('#detail-task').hidden, false);
  });
  test('native confirmation defaults to cancel and restores its opener on Escape/close', async () => {
    const { app, $, document } = await panelFixture([base()], undefined, { confirm: undefined });
    const opener = $('#btn-tasks'); opener.focus();
    const pending = app.requestConfirmation({ title: '确认测试', lines: ['仅内存测试'], plans: [] }); await tick();
    assert.equal($('#confirm-dialog').open, true); assert.equal(document.activeElement, $('#confirm-cancel'));
    $('#confirm-dialog').close(''); assert.equal(await pending, false); assert.equal(document.activeElement, opener);
  });
  test('Escape cannot silently discard a dirty detail draft', async () => {
    const { app, $ } = await panelFixture([base()], undefined, { confirm: async () => false });
    app.openDetail('host'); $('#cfg-display-name').value = '草稿';
    const event = { type: 'cancel' }; $('#detail-dialog').dispatchEvent(event); await tick();
    assert.equal(event.defaultPrevented, true); assert.equal($('#detail-dialog').open, true); assert.equal($('#cfg-display-name').value, '草稿');
  });
  test('diagnostics are reports, not a false all-checks-passed result', async () => {
    const { controller } = await controllerFixture([base()], url => url === '/api/doctor' ? { text: 'failed\nAuthorization: Bearer fixture-report\nhttp://localhost/?t=fixture-log' } : undefined);
    const task = await controller.report('doctor'); assert.equal(task.status, 'report'); assert.match(task.phase, /不代表所有检查通过/);
    assert.ok(!task.text.includes('fixture-report')); assert.ok(!task.text.includes('fixture-log'));
  });
  test('blocked plans preserve the backend recovery reason instead of a shape error', () => {
    assert.throws(() => m.normalizePlan(plan('host', 'start', { ok: false, blocked: true, summary: 'autoInstall 已关闭，请显式安装', errorCode: 'auto-install-disabled' }), 'host', 'start'), error => error.errorCode === 'auto-install-disabled' && /显式安装/.test(error.message));
  });
  test('a later failed probe is visible even when its cached successful state is older', () => {
    const [it] = m.mergeSnapshot([base({ state: 'up' })], [base({ state: 'down', probedAt: NOW - 100, attemptedAt: NOW + 100, statusError: 'latest failure' })]);
    assert.equal(it.state, 'up'); assert.equal(it.probedAt, NOW); assert.equal(it.statusError, 'latest failure');
  });
  test('config retry inside the detail dialog does not discard the failed draft', async () => {
    const { app, $ } = await panelFixture([base()], url => url.endsWith('/config') ? { ok: false, message: 'save rejected' } : undefined);
    app.openDetail('host'); $('#cfg-display-name').value = '失败后保留的草稿'; await app.saveConfig();
    $('#detail-task-body').querySelector('[data-action="retry-task"]').click(); await tick();
    assert.equal($('#cfg-display-name').value, '失败后保留的草稿'); assert.match($('#config-feedback').textContent, /草稿已保留/);
  });
  test('nested dialog close falls back inside the still-open dialog, not the inert page', () => {
    const document = new FakeDocument(), dialogs = p.createDialogManager(document);
    const detail = document.querySelector('#detail-dialog'), confirm = document.querySelector('#confirm-dialog');
    dialogs.open(detail); const action = document.querySelector('#btn-save-config'); action.focus(); dialogs.open(confirm); action.disabled = true;
    dialogs.close(confirm);
    assert.ok(detail.contains(document.activeElement)); assert.equal(document.activeElement.disabled, false);
  });
  test('loading logs opens their disclosure and redacts text before display', async () => {
    const { app, $ } = await panelFixture([base()], url => url.includes('/logs?') ? { text: 'http://localhost/?token=fixture-log-secret' } : undefined);
    app.openDetail('host'); $('#btn-logs').click(); await tick();
    assert.equal($('#detail-log').closest('details').open, true); assert.ok(!$('#detail-log').textContent.includes('fixture-log-secret'));
  });
  test('rendered task escapes markup and exposes explicit retry/plan actions', () => {
    const task = { id: 1, action: 'stop', title: '<img src=x>', targetLabels: ['a'], targetNames: ['a'], startedAt: NOW,
      status: 'failed', phase: 'failed', locks: ['a'], plans: [], results: [{ name: 'a', ok: false, message: '<script>bad</script>', errorCode: 'failure', code: 1 }] };
    const rendered = p.taskHTML(task); assert.doesNotMatch(rendered, /<img|<script>/); assert.match(rendered, /retry-task/);
  });
  test('all dialogs/inputs have labels and live regions exist', () => {
    const document = new FakeDocument();
    for (const dialog of document.querySelectorAll('dialog')) assert.ok(document.querySelector(`#${dialog.getAttribute('aria-labelledby')}`));
    for (const input of document.querySelectorAll('input,textarea')) assert.ok(document.querySelector(`label[for="${input.id}"]`), `Missing label for ${input.id}`);
    assert.ok(document.querySelector('[aria-live="polite"]')); assert.equal(document.querySelector('#task-panel').open, true);
  });
  test('CSP-compatible external modules/styles, no inline handlers, injected token, storage or eval', () => {
    assert.match(html, /src="\/assets\/panel\.mjs"/); assert.match(html, /href="\/assets\/panel\.css"/);
    assert.doesNotMatch(html, /<style\b|\sstyle=|\son\w+=|<script>|__TOKEN__/i);
    assert.doesNotMatch(panelSource, /localStorage|sessionStorage|indexedDB|eval\(|new Function|\.style\./);
    assert.match(panelSource, /from '\.\/model\.mjs'/); assert.doesNotMatch(panelSource, /from ['"](?:https?:|[^.])/);
    assert.match(html, /<h1>dsh-deck<\/h1>/);
  });
  test('CSS has balanced delimiters and responsive 320px/zoom-safe structure', () => {
    const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '').replace(/"[^"\n]*"|'[^'\n]*'/g, '');
    const stack = [], pair = { ')': '(', ']': '[', '}': '{' };
    for (const char of stripped) { if ('([{'.includes(char)) stack.push(char); else if (')]}'.includes(char)) assert.equal(stack.pop(), pair[char]); }
    assert.equal(stack.length, 0); assert.match(css, /minmax\(min\(100%, 320px\), 1fr\)/);
    assert.match(css, /flex-wrap: wrap/); assert.match(css, /:focus-visible/);
    assert.doesNotMatch(css, /body\s*\{[^}]*overflow:\s*hidden/);
  });
  test('secondary text has at least 4.5:1 contrast on all main surfaces', () => {
    const color = name => css.match(new RegExp(`--${name}: (#[a-f0-9]{6})`))[1];
    const luminance = hex => [1, 3, 5].map(offset => parseInt(hex.slice(offset, offset + 2), 16) / 255)
      .map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4)
      .reduce((sum, value, index) => sum + value * [.2126, .7152, .0722][index], 0);
    for (const surface of ['bg', 'surface', 'surface-raised']) assert.ok((luminance(color('muted')) + .05) / (luminance(color(surface)) + .05) >= 4.5);
  });
  test('shipped ESM modules and test entry point parse with node --check', () => {
    for (const file of ['app/ui/model.mjs', 'app/ui/panel.mjs', 'tools/check-ui.js']) execFileSync(process.execPath, ['--check', path.join(root, file)], { stdio: 'pipe' });
  });

  // Preserve all three old PowerShell static promises after module splitting.
  // Only source code is read; no PowerShell or real launcher is executed.
  const entry = source('dsh.ps1');
  const moduleDir = path.join(root, 'launcher');
  const modules = fs.existsSync(moduleDir) ? fs.readdirSync(moduleDir).filter(name => name.endsWith('.ps1')).sort().map(name => source(`launcher/${name}`)) : [];
  const combined = [entry, ...modules].join('\n');
  const paramBlock = entry.match(/^param\(([\s\S]*?)^\)/m);
  test('PowerShell ValidateSet and command dispatcher remain bidirectional across modules', () => {
    assert.ok(paramBlock, 'Cannot find entry-point param()');
    const raw = paramBlock[1].match(/\[ValidateSet\(([^)]*)\)\]/);
    assert.ok(raw, 'Cannot find command ValidateSet');
    const verbs = raw[1].replace(/['"\s]/g, '').split(',').filter(Boolean).sort();
    const clauses = commandClauses(combined);
    // New entry point dispatches mutations before its read-only switch. Check
    // that BOTH branches are reachable and that every mutation has a handler.
    const mutationBranch = entry.match(/if\s*\(\$Command -in @\(([^)]+)\)\)\s*\{\s*\$result = Invoke-Mutation \$Command \$Target/);
    if (mutationBranch) {
      const mutations = mutationBranch[1].replace(/['"\s]/g, '').split(',').filter(Boolean).sort();
      const start = combined.indexOf('function Invoke-Mutation(');
      const end = combined.indexOf('\nfunction Invoke-Start', start);
      assert.ok(start >= 0 && end > start, 'Cannot locate Invoke-Mutation implementation');
      const implementation = combined.slice(start, end);
      const handlers = commandClauses(implementation, 'Action');
      assert.ok(/if\s*\(\$Action -eq 'add'\)\s*\{\s*\$added = Invoke-Add/.test(implementation), 'add must reach Invoke-Add');
      handlers.push('add'); assert.deepEqual(handlers.sort(), mutations);
      clauses.push(...mutations);
    }
    assert.ok(verbs.length > 0 && clauses.length > 0, 'Cannot find the command dispatcher');
    assert.deepEqual([...new Set(clauses)].sort(), verbs);
  });
  test('every declared launcher parameter is still read beyond its declaration', () => {
    assert.ok(paramBlock, 'Cannot find entry-point param()');
    const decls = [...paramBlock[1].matchAll(/\[[^\]]+\]\s*\$(\w+)/g)].map(match => match[1]);
    const body = entry.slice(paramBlock.index + paramBlock[0].length) + '\n' + modules.join('\n');
    // Probe alone is an explicitly accepted inert compatibility switch.
    const unread = decls.filter(name => name !== 'Probe' && !new RegExp(`\\$${name}\\b`, 'i').test(body));
    assert.ok(decls.length > 0); assert.deepEqual(unread, []);
  });
  test('NoProbe still reaches Get-AllStatus after PowerShell module splitting', () => {
    // Boolean assertion avoids dumping the full launcher source on failure.
    assert.ok(/Get-AllStatus\s+-NoProbeHttp:\$NoProbe\b/.test(combined), 'NoProbe is not forwarded to Get-AllStatus');
  });
}
main().catch(error => { console.error('UI test initialization failed:', error.message); process.exitCode = 1; });
