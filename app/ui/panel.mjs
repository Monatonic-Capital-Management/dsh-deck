import {
  ACTION_TEXT, STATE_TEXT, displayName, isUp, needsLocalInstall,
  instanceMatches, selectTargets, availableActions, shortDetail, workdirDisplay, updateNotice,
  probeFreshness, mergeSnapshot, safeURL, loopbackURL, entryAuth, redactText, publicInstance,
  operationResult, summarizeResults, appendTask, normalizePlan, confirmationFor, requiresApproval,
  sshHostState, validateAdd, validateConfig, configValues, failureStep, installCommand,
  escapeHTML as esc,
} from './model.mjs';

export const AUTH_GUIDANCE = '管理会话未认证或已过期。请关闭此页面，重新打开 Start.exe，再从新窗口进入 dsh-deck。';

export function createApiClient({ fetchImpl, location, history }) {
  const { token, cleanPath, origin } = entryAuth(location.href);
  // Synchronous, before session exchange, rendering, polling or any await.
  history.replaceState(null, '', cleanPath);
  const clean = value => redactText(value, [token]);
  async function request(path, { method = 'GET', body } = {}) {
    const url = new URL(path, origin);
    if (!path.startsWith('/api/') || url.origin !== origin || url.hash ||
        [...url.searchParams.keys()].some(key => /^(t|token|access_token)$/i.test(key))) {
      throw new Error('拒绝不安全的 API 地址。');
    }
    let response;
    try {
      response = await fetchImpl(path, {
        method, credentials: 'same-origin', cache: 'no-store', redirect: 'error',
        headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch {
      const unconfirmed = method === 'POST' && path !== '/api/session';
      const error = new Error(unconfirmed
        ? '无法取得操作结果；后端任务可能仍在执行。请先重新读取状态、确认结果，再决定是否重试。'
        : '无法连接 dsh-deck 后端。请检查面板进程，或重新打开 Start.exe。');
      error.errorCode = unconfirmed ? 'result-unconfirmed' : 'backend-unreachable';
      throw error;
    }
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      const auth = response.status === 401 || response.status === 403;
      const error = new Error(auth ? AUTH_GUIDANCE : clean(data?.message || data?.error || `HTTP ${response.status}`));
      error.auth = auth;
      error.errorCode = clean(data?.errorCode || `http-${response.status}`);
      throw error;
    }
    if (data === null) throw new Error('后端未返回有效 JSON；请重新读取状态，不要重复提交变更。');
    return data;
  }
  return { request, clean,
    async establishSession() {
      if (!token) return; // A hard refresh authenticates with the same-origin HttpOnly cookie.
      const result = await request('/api/session', { method: 'POST' });
      if (result.ok === false) {
        const error = new Error(AUTH_GUIDANCE); error.auth = true; throw error;
      }
    },
  };
}

const route = (name, action) => `/api/instances/${encodeURIComponent(name)}/${action}`;
const clockText = value => value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '尚无记录';

// The controller has no DOM or timers. Tests inject in-memory API replies and
// promises; the real view supplies confirmation and window-opening callbacks.
export function createController({ api, confirm = async () => false, openWindow = () => {},
  onChange = () => {}, onTask = () => {}, onNotice = () => {}, now = Date.now }) {
  const clean = api.clean || redactText;
  const state = { instances: [], tasks: [], busy: new Set(), loading: false, loadError: '',
    authenticated: false, authError: false, lastReadAt: null, trayOn: null, balance: null };
  let sequence = 0, epoch = 0, nextTask = 0;
  const emit = () => onChange(state);
  const notice = message => onNotice(clean(message));
  const row = name => state.instances.find(it => it.name === name);
  const errorResult = (error, name) => ({ name, ok: false, code: null,
    errorCode: clean(error.errorCode || 'request-failed'), message: clean(error.message || '请求失败。') });

  function authFailure(error) {
    if (error.auth) { state.authError = true; state.authenticated = false; state.loadError = AUTH_GUIDANCE; }
  }
  function patchInstance(value) {
    if (!value?.name) return;
    const it = publicInstance(value, clean);
    const index = state.instances.findIndex(item => item.name === it.name);
    if (index >= 0) state.instances[index] = { ...state.instances[index], ...it };
    epoch++;
  }
  async function refresh({ allowBusy = [], manual = false } = {}) {
    const ticket = ++sequence;
    const version = epoch;
    state.loading = true; emit();
    try {
      const data = await api.request('/api/instances');
      if (!Array.isArray(data) || data.some(it => !it || typeof it.name !== 'string')) throw new Error('实例列表格式不正确。');
      if (ticket !== sequence || version !== epoch) return { ok: false, superseded: true };
      const protectedNames = new Set([...state.busy].filter(name => !allowBusy.includes(name)));
      state.instances = mergeSnapshot(state.instances, data.map(it => publicInstance(it, clean)), protectedNames);
      state.loadError = ''; state.authError = false; state.authenticated = true; state.lastReadAt = now();
      if (manual) {
        const failed = state.instances.filter(it => it.statusError).length;
        const stale = state.instances.filter(it => probeFreshness(it, now()).stale).length;
        notice(`已重新读取状态快照；这不等于刚完成探测。${failed ? ` ${failed} 个实例最近探测失败。` : ''}${stale ? ` ${stale} 个实例状态过期或尚未成功探测。` : ''}`);
      }
      return { ok: true };
    } catch (error) {
      if (ticket === sequence && version === epoch) {
        state.loadError = clean(error.message); authFailure(error);
        if (manual) notice(state.loadError);
      }
      return { ok: false, message: clean(error.message) };
    } finally {
      if (ticket === sequence) state.loading = false;
      emit();
    }
  }
  function begin(action, instances, { locks = instances.map(it => it.name), preview = false } = {}) {
    if (!state.authenticated || state.authError) { notice(state.authError ? AUTH_GUIDANCE : '请先连接后端并读取实例列表。'); return null; }
    if (locks.some(name => state.busy.has(name))) { notice('目标已有进行中的任务；请等待结果，勿重复操作。'); return null; }
    const task = { id: ++nextTask, action, targetNames: instances.map(it => it.name),
      targetLabels: instances.map(it => `${displayName(it)}（${it.name}）`), preview,
      title: `${preview ? '预览 · ' : ''}${ACTION_TEXT[action] || action}`,
      status: 'running', phase: '准备请求', startedAt: now(), endedAt: null, plans: [], results: [], text: '', note: '', locks };
    try { state.tasks = appendTask(state.tasks, task); }
    catch (error) { notice(error.message); return null; }
    for (const name of locks) state.busy.add(name);
    epoch++; emit(); onTask(task);
    return task;
  }
  function phase(task, text) { task.phase = text; emit(); }
  function finish(task) {
    task.endedAt = now();
    for (const name of task.locks) state.busy.delete(name);
    emit();
  }
  async function readPlan(it, action) {
    let data;
    if (action === 'upgrade') {
      const reply = await api.request(`/api/upgrade?name=${encodeURIComponent(it.name)}`);
      if (reply.ok !== true || !Array.isArray(reply.plans)) {
        const blocked = Array.isArray(reply.plans) ? reply.plans.find(plan => plan.name === it.name) : null;
        const error = new Error(clean(reply.message || reply.error || blocked?.summary || '无法取得升级计划；未发送变更。'));
        error.errorCode = clean(reply.errorCode || blocked?.errorCode || 'plan-failed');
        throw error;
      }
      if (reply.plans.some(plan => plan.name !== it.name)) throw new Error('升级计划包含未选择的实例；未发送变更。');
      data = reply.plans.find(plan => plan.name === it.name);
    } else data = await api.request(`${route(it.name, 'plan')}?action=${action}`);
    const plan = normalizePlan(data, it.name, action, clean);
    if (plan.kind !== it.kind) throw new Error('计划的实例类型发生变化；请重新读取状态后重试。');
    return plan;
  }
  async function run(action, names, options = {}) {
    const instances = [...new Set(names)].map(row);
    if (!instances.length || instances.some(it => !it)) { notice('没有可操作的目标；请重新读取状态。'); return null; }
    const task = begin(action, instances, options);
    if (!task) return null;
    let sent = false;
    let currentName = instances[0].name;
    try {
      if (action === 'config') {
        const validated = validateConfig(options.body || {}, instances[0]);
        if (!validated.ok) throw new Error(Object.values(validated.errors).join(' '));
        options = { ...options, body: validated.body };
      }
      for (const it of instances) {
        currentName = it.name;
        if (action === 'start' && needsLocalInstall(it)) throw new Error('本机缺少可用 dsh。请先查看并执行「安装准备」计划，再启动。');
        const planAction = action === 'restart' ? 'start' : action;
        if (['install', 'upgrade'].includes(action) || (['start', 'restart'].includes(action) && it.kind === 'remote')) {
          phase(task, `正在读取 ${displayName(it)} 的${ACTION_TEXT[planAction]}计划；尚未发送变更`);
          task.plans.push(await readPlan(it, planAction)); emit();
        }
      }
      if (options.preview) {
        task.status = 'preview'; task.phase = '预览完成，尚未执行任何变更';
        return task;
      }
      if (requiresApproval(action, task.plans)) {
        task.status = 'confirming'; phase(task, '等待确认影响范围；尚未发送变更');
        if (!await confirm(confirmationFor(action, instances, task.plans))) {
          task.status = 'cancelled'; task.phase = '已取消确认，未发送任何变更'; return task;
        }
      }
      task.status = 'running';
      for (const [index, it] of instances.entries()) {
        currentName = it.name;
        phase(task, `第 ${index + 1} / ${instances.length} 个：已发送${ACTION_TEXT[action]}请求，等待后端结果（后端未提供内部进度）`);
        sent = true;
        try {
          const path = action === 'upgrade' ? `/api/upgrade?name=${encodeURIComponent(it.name)}` : route(it.name, action);
          const reply = await api.request(path, { method: 'POST', ...(options.body ? { body: options.body } : {}) });
          const result = operationResult(reply, it.name, action, clean);
          task.results.push(result); patchInstance(reply.instance); epoch++;
          if (action === 'remove' && result.ok) state.instances = state.instances.filter(item => item.name !== it.name);
        } catch (error) { authFailure(error); task.results.push(errorResult(error, it.name)); epoch++; }
        emit();
      }
      const summary = summarizeResults(task.results);
      task.status = summary.status; task.phase = summary.text;
      if (action === 'config' && summary.failed === 0) task.note = '配置已保存。停用不停止进程；工作目录与版本配置是否需要后续重启，以计划及当前运行状态为准。';
    } catch (error) {
      authFailure(error); task.results.push(errorResult(error, currentName));
      task.status = 'failed'; task.phase = sent ? '操作未完成，请查看逐项结果' : '准备或计划读取失败，未发送变更';
    } finally {
      if (sent && !state.authError) {
        const result = await refresh({ allowBusy: task.targetNames });
        if (!result.ok && !result.superseded) task.note += `${task.note ? '\n' : ''}变更结果已保留，但状态快照读取失败；请手动重新读取状态。`;
      }
      finish(task);
    }
    return task;
  }
  async function addInstance(values) {
    const validated = validateAdd(values, state.instances);
    if (!validated.ok) return { validation: validated.errors };
    const label = { name: validated.body.name || validated.body.sshHost, displayName: validated.body.displayName };
    const task = begin('add', [label], { locks: ['@add'] });
    if (!task) return null;
    try {
      phase(task, '正在保存远端登记；不会安装软件或启动服务');
      const reply = await api.request('/api/instances', { method: 'POST', body: validated.body });
      task.results.push(operationResult(reply, label.name, 'add', clean)); epoch++;
      task.status = summarizeResults(task.results).status;
      task.phase = task.results[0].ok ? '登记已保存；请查看实例状态和启动计划' : '添加登记失败';
      const result = await refresh();
      if (!result.ok) task.note = '状态列表读取失败；请重新读取状态，避免重复添加。';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, label.name)); task.status = 'failed'; task.phase = '添加登记失败'; }
    finally { finish(task); }
    return task;
  }
  async function openInstance(name, system = false) {
    const it = row(name);
    if (!it) return null;
    const task = begin(system ? 'open-system' : 'open', [it]);
    if (!task) return null;
    try {
      phase(task, '正在取得最新实例地址；不会使用旧缓存链接回退');
      const fresh = await api.request(route(name, 'url'));
      const url = loopbackURL(fresh.url || fresh.instance?.url);
      if (fresh.ok === false || !url) throw new Error(clean(fresh.message || '未取得可用的 loopback HTTP 地址。未打开旧链接，请检查状态后重试。'));
      patchInstance(fresh.instance);
      if (system) {
        phase(task, '已取得新地址，正在请求系统浏览器打开');
        const reply = await api.request('/api/reveal', { method: 'POST', body: { path: url } });
        task.results.push(operationResult(reply, name, 'open-system', clean));
      } else {
        // noopener can legitimately return null. It is not proof of blocking.
        openWindow(url);
        task.results.push({ name, ok: true, code: null, errorCode: '', message: '已请求在独立窗口打开 dsh；若未出现窗口，请使用下方「系统浏览器打开」。不根据窗口句柄判断是否被拦截。' });
      }
      task.status = summarizeResults(task.results).status; task.phase = '打开请求已处理';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, name)); task.status = 'failed'; task.phase = '未能完成打开请求；没有回退到旧链接'; }
    finally { finish(task); }
    return task;
  }
  async function revealDirectory(name) {
    const it = row(name);
    if (!it || it.kind !== 'local' || !it.workdir) return null;
    const task = begin('reveal', [it]);
    if (!task) return null;
    try {
      phase(task, '正在请求资源管理器打开本机工作目录');
      const reply = await api.request('/api/reveal', { method: 'POST', body: { path: it.workdir } });
      task.results.push(operationResult(reply, name, 'reveal', clean));
      task.status = summarizeResults(task.results).status; task.phase = '目录打开请求已处理';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, name)); task.status = 'failed'; task.phase = '打开目录失败'; }
    finally { finish(task); }
    return task;
  }
  async function report(action) {
    const task = begin(action, [], { locks: [`@${action}`] });
    if (!task) return null;
    try {
      phase(task, action === 'doctor' ? '正在等待环境自检报告；没有内部进度可显示' : '正在查询目标版本；不安装或升级');
      const reply = await api.request(`/api/${action}`);
      if (reply.ok === false) throw new Error(clean(reply.message || reply.error || '报告请求失败。'));
      if (action === 'doctor') task.text = clean(reply.text || '后端没有返回诊断文本。');
      else {
        const rows = Array.isArray(reply.instances) ? reply.instances : Array.isArray(reply.rows) ? reply.rows : reply.instances ? [reply.instances] : [];
        task.text = rows.length ? rows.map(it => clean(`${it.Name || it.name}：已安装 ${it.Current || it.currentVersion || '未检测到'}；目标 ${it.Target || it.TargetVersion || it.targetVersion || it.Latest || '以计划为准'}；${it.UpdateAvailable || it.updateAvailable ? '可查看升级计划' : '未报告更新'}`)).join('\n') : '没有可用版本记录；请查看单实例计划。';
      }
      task.status = 'report'; task.phase = '报告已返回；具体问题请查看内容，不代表所有检查通过';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, '')); task.status = 'failed'; task.phase = '无法取得报告'; }
    finally { finish(task); }
    return task;
  }
  async function refreshTray() {
    try { const reply = await api.request('/api/tray'); state.trayOn = typeof reply.running === 'boolean' ? reply.running : null; }
    catch (error) { state.trayOn = null; authFailure(error); }
    emit();
  }
  async function toggleTray() {
    if (state.trayOn === null) {
      await refreshTray();
      notice(state.trayOn === null ? '托盘状态仍未知；未请求切换监控，请稍后重试。' : '已重新查询托盘状态；再次点击可切换监控。');
      return;
    }
    const task = begin('tray', [], { locks: ['@tray'] });
    if (!task) return null;
    try {
      phase(task, '正在请求切换托盘监控');
      const reply = await api.request(`/api/tray?action=${state.trayOn ? 'stop' : 'start'}`, { method: 'POST' });
      task.results.push(operationResult(reply, '', 'tray', clean));
      if (typeof reply.running === 'boolean') state.trayOn = reply.running;
      task.status = summarizeResults(task.results).status; task.phase = '托盘请求已返回';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, '')); task.status = 'failed'; task.phase = '托盘请求失败'; }
    finally { finish(task); }
    return task;
  }
  async function loadBalance(force = false) {
    try {
      const reply = await api.request(`/api/balance${force ? '?refresh=1' : ''}`);
      state.balance = reply.ok === true && Array.isArray(reply.balances) && reply.balances.length
        ? { checkedAt: reply.checkedAt, balances: reply.balances.map(item => ({ currency: clean(item.currency), total: clean(String(item.total)) })) } : null;
      if (force) notice(state.balance ? '余额记录已返回；查询时间见余额按钮说明。' : '余额查询未成功；不影响实例管理。');
    } catch (error) { authFailure(error); state.balance = null; if (force) notice('余额查询失败；不影响实例管理。'); }
    emit();
  }
  return { state, refresh, run, addInstance, openInstance, revealDirectory, report, refreshTray, toggleTray, loadBalance,
    notice, authFailure, emit,
    targets: action => selectTargets(state.instances, action),
  };
}

export function planHTML(plan) {
  return `<section class="plan"><h4>${esc(plan.name)} · ${esc(ACTION_TEXT[plan.action])}</h4>
    <p>${esc(plan.summary)}</p><p class="muted">当前 dsh：${esc(plan.currentVersion)} · 目标：${esc(plan.targetVersion)} · 当前 Node：${esc(plan.nodeVersion)}</p>
    <p>软件变更：${plan.changesSoftware ? '是' : '否'} · 重启服务：${plan.restartsService ? '是' : '否'}</p>
    <ol>${plan.steps.map(step => `<li>${esc(step)}</li>`).join('')}</ol>
    ${plan.warnings.length ? `<div class="warnings"><strong>注意事项</strong><ul>${plan.warnings.map(step => `<li>${esc(step)}</li>`).join('')}</ul></div>` : ''}</section>`;
}

export function taskHTML(task, busy = new Set()) {
  const running = ['running', 'confirming'].includes(task.status);
  const blocked = running || task.locks.some(name => busy.has(name));
  const failures = task.results.some(result => !result.ok);
  const actionButton = (action, label) => `<button type="button" data-action="${action}" data-task="${task.id}"${blocked ? ' disabled' : ''}>${label}</button>`;
  return `<h3 tabindex="-1">${esc(task.title)}${task.targetLabels.length ? ` · ${esc(task.targetLabels.join('、'))}` : ''}</h3>
    <p class="phase">${esc(task.phase)}</p><time datetime="${new Date(task.startedAt).toISOString()}">开始：${esc(clockText(task.startedAt))}${task.endedAt ? ` · 结束：${esc(clockText(task.endedAt))}` : ''}</time>
    ${task.plans.map(planHTML).join('')}
    ${task.results.length ? `<ul>${task.results.map(result => `<li class="${result.ok ? 'result-ok' : 'result-bad'}"><strong>${esc(result.name || '请求')}：${result.ok ? '成功' : '失败'}</strong> · ${esc(result.message)}${result.errorCode ? ` [${esc(result.errorCode)}]` : ''}${result.code !== null && !result.ok ? `（退出码 ${esc(result.code)}）` : ''}</li>`).join('')}</ul>` : ''}
    ${task.note ? `<p>${esc(task.note)}</p>` : ''}${task.text ? `<pre tabindex="0" aria-label="已脱敏的任务报告">${esc(task.text)}</pre>` : ''}
    <div class="actions">${failures && !running ? actionButton('retry-task', ['config', 'add'].includes(task.action) ? '检查输入后重试' : '重试失败目标') : ''}
    ${task.status === 'preview' ? actionButton('execute-task', `重新核对计划并${ACTION_TEXT[task.action]}`) : ''}
    ${task.action === 'open' && !running ? actionButton('system-open-task', '系统浏览器打开') : ''}</div>`;
}

export function createDialogManager(document) {
  const openers = new Map();
  for (const dialog of document.querySelectorAll('dialog')) {
    dialog.addEventListener('close', () => {
      const opener = openers.get(dialog);
      openers.delete(dialog);
      const activeDialog = [...document.querySelectorAll('dialog')].reverse().find(item => item.open);
      const openerDialog = opener?.closest?.('dialog');
      if (opener?.isConnected && !opener.disabled && !opener.hidden &&
          (!openerDialog || openerDialog.open) && (!activeDialog || activeDialog.contains(opener))) {
        opener.focus({ preventScroll: true });
      } else {
        const fallback = activeDialog
          ? [...activeDialog.querySelectorAll('button')].find(button => !button.disabled && !button.hidden)
          : document.querySelector('#btn-tasks');
        fallback?.focus({ preventScroll: true });
      }
    });
  }
  return {
    open(dialog) {
      if (dialog.open) return;
      openers.set(dialog, document.activeElement);
      dialog.showModal();
    },
    close(dialog, value = '') { if (dialog.open) dialog.close(value); },
  };
}

// Stable card elements are updated in place. Polling never replaces a form,
// search box or focused action button, even when a timestamp changes.
export function createPanel({ document, window, api, poll = true, confirm: confirmOverride, now = Date.now }) {
  const $ = selector => document.querySelector(selector);
  const dialogs = createDialogManager(document);
  const cards = new Map(), taskNodes = new Map();
  let query = '', exceptionsOnly = false, detailName = '', detailInitial = '', detailSession = 0;
  let timer = null, disposed = false, logSequence = 0, addSession = 0, confirmQueue = Promise.resolve();
  const clean = api.clean || redactText;
  const text = (element, value) => { const next = String(value ?? ''); if (element.textContent !== next) element.textContent = next; };
  const announce = message => text($('#notice'), clean(message));
  const configFields = { displayName: 'cfg-display-name', description: 'cfg-description', workdir: 'cfg-workdir',
    dshVersion: 'cfg-version', enabled: 'cfg-enabled', autoInstall: 'cfg-auto-install', stopRemoteService: 'cfg-stop-remote' };
  const addFields = { sshHost: 'in-host', name: 'in-name', displayName: 'in-display-name', port: 'in-port' };
  function readFields(fields) {
    return Object.fromEntries(Object.entries(fields).map(([key, id]) => {
      const el = $(`#${id}`); return [key, el.type === 'checkbox' ? el.checked : el.value];
    }));
  }
  function showErrors(fields, errors) {
    for (const [key, id] of Object.entries(fields)) {
      const input = $(`#${id}`), error = $(`#${id}-error`);
      input.setAttribute('aria-invalid', errors[key] ? 'true' : 'false');
      if (error) text(error, errors[key] || '');
    }
    const first = Object.keys(errors).find(key => fields[key]);
    if (first) $(`#${fields[first]}`).focus();
  }
  function dirtyDetail() { return detailName && JSON.stringify(readFields(configFields)) !== detailInitial; }
  function requestConfirmation(data) {
    const next = confirmQueue.then(() => new Promise(resolve => {
      const dialog = $('#confirm-dialog');
      text($('#confirm-title'), data.title);
      $('#confirm-lines').innerHTML = data.lines.map(line => `<p>${esc(clean(line))}</p>`).join('');
      $('#confirm-plans').innerHTML = data.plans.map(planHTML).join('');
      dialog.returnValue = '';
      dialog.addEventListener('close', () => resolve(dialog.returnValue === 'proceed'), { once: true });
      dialogs.open(dialog);
      $('#confirm-cancel').focus();
    }));
    confirmQueue = next.catch(() => false);
    return next;
  }
  const controller = createController({ api, now, confirm: confirmOverride || requestConfirmation,
    openWindow: url => window.open(url, '_blank', 'noopener,noreferrer'),
    onChange: () => render(), onNotice: announce,
    onTask: task => {
      $('#task-panel').open = true;
      if ($('#more-dialog').open) dialogs.close($('#more-dialog'));
      if (detailName && $('#detail-dialog').open && task.targetNames.includes(detailName)) {
        renderDetailTask();
        $('#detail-task').scrollIntoView?.({ block: 'nearest' });
      } else $('#task-panel').scrollIntoView?.({ block: 'nearest' });
    },
  });
  const state = controller.state;

  function createCard(it) {
    const card = document.createElement('article');
    card.className = 'card'; card.dataset.name = it.name;
    card.innerHTML = `<div class="card-head"><h3><button type="button" class="quiet" data-action="detail" data-role="name"></button></h3><span class="state-label" data-role="state"></span></div>
      <p class="card-sub mono" data-role="id"></p><p class="card-sub" data-role="sub"></p><p class="card-context" data-role="description"></p><p class="card-context" data-role="detail"></p>
      <div class="hint-row" data-role="hint-row"><p data-role="hint"></p><button type="button" data-action="copy-step" data-role="step"></button><button type="button" data-action="copy-install" data-role="manual">复制安装命令（项目目录 PowerShell）</button></div>
      <div class="url-row" data-role="url-row"><span class="mono" data-role="url"></span><button type="button" data-action="copy-url">复制无认证地址</button></div>
      <div class="wd-row" data-role="wd-row"><span class="mono" data-role="workdir"></span><button type="button" data-action="reveal">打开目录</button></div>
      <div class="update-row" data-role="update-row"><p data-role="update"></p><button type="button" data-action="preview-upgrade">查看升级计划</button></div>
      <div class="freshness" data-role="freshness"><p data-role="probed"></p><p data-role="attempted"></p><p data-role="probe-error"></p></div>
      <p class="busy-label" data-role="busy">任务进行中；结果保留在任务面板。</p>
      <div class="actions"><button type="button" class="primary" data-action="start">启动</button><button type="button" class="primary" data-action="open">打开 dsh</button><button type="button" class="primary" data-action="install" data-role="install"></button><button type="button" data-action="restart">重启</button><button type="button" class="danger" data-action="stop">停止</button><button type="button" data-action="detail">详情与配置</button></div>`;
    for (const button of card.querySelectorAll('[data-action]')) button.dataset.name = it.name;
    return card;
  }
  function paintCard(card, it) {
    const role = name => card.querySelector(`[data-role="${name}"]`);
    const busy = state.busy.has(it.name), actions = availableActions(it), freshness = probeFreshness(it, now());
    const knownState = Object.hasOwn(STATE_TEXT, it.state) ? it.state : 'down';
    card.className = `card state-${knownState}`;
    card.setAttribute('aria-busy', String(busy));
    text(role('name'), displayName(it)); text(role('id'), `机器标识：${it.name}`);
    text(role('state'), STATE_TEXT[it.state] || '状态未知'); text(role('sub'), shortDetail(it));
    text(role('description'), it.description || ''); role('description').hidden = !it.description;
    text(role('detail'), it.detail || ''); role('detail').hidden = !it.detail;
    const missing = needsLocalInstall(it);
    const hint = it.hint || (missing ? '本机尚无可用 dsh。先查看安装准备计划；后端会说明如何准备 Node 与 dsh。安装后再启动。' : '');
    const step = failureStep(it);
    text(role('hint'), hint); role('hint-row').hidden = !hint;
    role('step').hidden = !step; text(role('step'), step ? `复制命令：${step.label}` : '');
    role('manual').hidden = !missing || !installCommand(it.name);
    const address = safeURL(it.url); role('url-row').hidden = !address; text(role('url'), address);
    const workdir = workdirDisplay(it); role('wd-row').hidden = !workdir;
    text(role('workdir'), workdir?.short || ''); role('workdir').title = workdir?.full || '';
    const update = updateNotice(it); role('update-row').hidden = !update; text(role('update'), update);
    role('freshness').dataset.freshness = freshness.kind;
    text(role('probed'), `最近成功探测：${clockText(freshness.probedAt)}${freshness.stale ? ' · 已过期或未确认，不能当作当前状态' : ''}`);
    text(role('attempted'), freshness.attemptedAt ? `最近尝试：${clockText(freshness.attemptedAt)}` : '');
    text(role('probe-error'), freshness.failed ? `最近探测失败：${it.statusError}；保留上次状态。` : '');
    role('busy').hidden = !busy;
    text(role('install'), it.kind === 'local' ? '安装准备（先看计划）' : '部署远程服务（先看计划）');
    for (const button of card.querySelectorAll('[data-action]')) {
      const action = button.dataset.action;
      if (['start', 'open', 'install', 'restart', 'stop', 'detail'].includes(action)) button.hidden = !actions.includes(action);
      button.disabled = (busy && !['detail', 'copy-url', 'copy-step', 'copy-install'].includes(action)) || !state.authenticated;
    }
    const focused = document.activeElement;
    if (focused && card.contains(focused) && focused.hidden) role('name').focus({ preventScroll: true });
  }
  function renderTasks() {
    text($('#task-count'), `${state.tasks.length} 条`);
    $('#tasks-empty').hidden = state.tasks.length > 0;
    for (const [id, node] of taskNodes) if (!state.tasks.some(task => task.id === id)) { node.remove(); taskNodes.delete(id); }
    for (const task of [...state.tasks].reverse()) {
      let node = taskNodes.get(task.id);
      if (!node) {
        node = document.createElement('article'); node.className = 'task'; node.dataset.task = String(task.id);
        taskNodes.set(task.id, node); $('#task-list').prepend(node);
      }
      const html = taskHTML(task, state.busy);
      if (node._taskHTML !== html) {
        const focused = node.contains(document.activeElement) ? document.activeElement.dataset.action : null;
        node.innerHTML = html; node._taskHTML = html;
        if (focused) (node.querySelector(`[data-action="${focused}"]`) || node.querySelector('h3'))?.focus({ preventScroll: true });
      }
      node.dataset.status = task.status;
    }
    renderDetailTask();
  }
  function renderDetailTask() {
    if (!detailName || !$('#detail-dialog').open) return;
    const task = [...state.tasks].reverse().find(item => item.targetNames.includes(detailName));
    $('#detail-task').hidden = !task;
    if (task) {
      const html = taskHTML(task, state.busy);
      const target = $('#detail-task-body');
      if (target._taskHTML !== html) {
        const focused = target.contains(document.activeElement) ? document.activeElement.dataset.action : null;
        target.innerHTML = html; target._taskHTML = html;
        if (focused) (target.querySelector(`[data-action="${focused}"]`) || target.querySelector('h3'))?.focus({ preventScroll: true });
      }
    }
  }
  function render() {
    const total = state.instances.length;
    const up = state.instances.filter(it => isUp(it.state)).length;
    text($('#count'), `${up} / ${total} 个运行中`);
    const filtering = total > 1;
    $('#filter').hidden = !filtering;
    if (!filtering) { query = ''; exceptionsOnly = false; $('#flt-q').value = ''; }
    $('#flt-errors').setAttribute('aria-pressed', String(exceptionsOnly));
    let hits = 0;
    for (const [name, card] of cards) if (!state.instances.some(it => it.name === name)) { card.remove(); cards.delete(name); }
    for (const it of state.instances) {
      let card = cards.get(it.name);
      if (!card) { card = createCard(it); cards.set(it.name, card); $('#cards').append(card); }
      paintCard(card, it);
      card.hidden = filtering && !instanceMatches(it, query, exceptionsOnly);
      if (!card.hidden) hits++;
    }
    text($('#flt-hits'), `显示 ${hits} / ${total}`);
    $('#empty-config').hidden = !state.authenticated || total > 0 || state.loading || Boolean(state.loadError);
    $('#empty-filter').hidden = !total || hits > 0;
    $('#loading').hidden = !state.loading || total > 0;
    $('#backend-error').hidden = !state.loadError; text($('#backend-error-text'), state.loadError);
    text($('#sb-text'), state.loadError || (state.loading ? '正在读取状态快照；不代表刚完成探测…' : `${up} / ${total} 个运行中；探测时间与失败情况见卡片`));
    text($('#sb-updated'), state.lastReadAt ? `最近读取快照：${clockText(state.lastReadAt)}` : '尚未读取状态快照');
    const noAuth = !state.authenticated || state.authError;
    $('#btn-refresh').disabled = state.loading;
    for (const [id, action] of [['btn-start-all', 'start'], ['btn-stop-all', 'stop'], ['btn-upgrade-all', 'upgrade']]) {
      const targets = controller.targets(action);
      $(`#${id}`).disabled = noAuth || !targets.length || targets.some(it => state.busy.has(it.name));
    }
    $('#btn-start-all').hidden = total < 2;
    $('#btn-stop-all').hidden = total < 2;
    $('#btn-upgrade-all').hidden = total < 2;
    $('#btn-add').disabled = noAuth || state.busy.has('@add');
    $('#btn-add-ok').disabled = noAuth || state.busy.has('@add');
    for (const id of Object.values(addFields)) $(`#${id}`).disabled = state.busy.has('@add');
    for (const action of ['doctor', 'versions']) $(`#btn-${action}`).disabled = noAuth || state.busy.has(`@${action}`);
    $('#btn-tray').disabled = noAuth || state.busy.has('@tray');
    $('#btn-tray').setAttribute('aria-pressed', String(state.trayOn === true));
    text($('#btn-tray'), state.trayOn === null ? '查询托盘状态' : state.trayOn ? '托盘监控：开' : '托盘监控：关');
    $('#btn-balance').hidden = !state.balance;
    if (state.balance) {
      const amount = state.balance.balances.find(item => Number(item.total) > 0) || state.balance.balances[0];
      text($('#btn-balance'), `DeepSeek 余额 ${amount.currency} ${amount.total}`);
      $('#btn-balance').title = `账户余额（不是 dsh-deck 收费）。查询于 ${clockText(state.balance.checkedAt)}；点击重新查询。`;
    }
    if (detailName && $('#detail-dialog').open) {
      const it = state.instances.find(item => item.name === detailName);
      const busy = state.busy.has(detailName);
      text($('#detail-status'), it ? `${STATE_TEXT[it.state] || '状态未知'} · ${shortDetail(it)} · 最近成功探测：${clockText(probeFreshness(it, now()).probedAt)}` : '登记已移除；此处未保存的输入不会生效。');
      for (const id of Object.values(configFields)) $(`#${id}`).disabled = busy || !it || noAuth;
      $('#btn-save-config').disabled = busy || !it || noAuth;
      $('#btn-remove').disabled = busy || !it || noAuth;
      for (const button of $('#detail-actions').querySelectorAll('[data-action]')) {
        button.disabled = busy || !it || noAuth;
        if (it && ['start', 'stop', 'restart', 'open', 'install'].includes(button.dataset.action)) button.hidden = !availableActions(it).includes(button.dataset.action);
      }
    }
    renderTasks();
  }
  function showTasks() {
    $('#task-panel').open = true;
    if ($('#detail-dialog').open) {
      renderDetailTask(); $('#detail-task').scrollIntoView?.({ block: 'nearest' });
      if (!$('#detail-task').hidden) $('#detail-task-heading').focus();
    } else { $('#task-panel').scrollIntoView?.({ block: 'nearest' }); $('#tasks-summary').focus(); }
  }
  function openDetail(name) {
    const it = state.instances.find(item => item.name === name);
    if (!it) return;
    detailName = name; detailSession++; logSequence++;
    text($('#detail-title'), `${displayName(it)} · 详情与配置`);
    text($('#detail-identity'), `机器标识：${it.name}（不可修改） · ${it.kind === 'local' ? '本机' : `SSH：${it.sshHost || ''}`}`);
    const values = configValues(it);
    for (const [key, id] of Object.entries(configFields)) {
      const input = $(`#${id}`);
      if (input.type === 'checkbox') input.checked = values[key]; else input.value = values[key];
    }
    detailInitial = JSON.stringify(readFields(configFields));
    $('#local-config').hidden = it.kind !== 'local'; $('#remote-config').hidden = it.kind === 'local';
    text($('#config-feedback'), ''); text($('#config-dirty'), ''); showErrors(configFields, {});
    text($('#detail-log'), '日志可能含主机与路径信息。点击「载入日志」后只显示脱敏文本；请勿直接上传原始运行文件。');
    for (const button of $('#detail-actions').querySelectorAll('[data-action]')) button.dataset.name = name;
    $('#btn-remove').dataset.name = name;
    dialogs.open($('#detail-dialog')); render(); $('#cfg-display-name').focus();
  }
  async function requestCloseDetail() {
    if (dirtyDetail()) {
      const approved = await (confirmOverride || requestConfirmation)({ title: '放弃尚未保存的编辑？', lines: ['输入只保留在当前面板内存中。关闭详情不会保存这些修改。'], plans: [] });
      if (!approved) return;
    }
    dialogs.close($('#detail-dialog'));
  }
  async function saveConfig() {
    const name = detailName, session = detailSession;
    const it = state.instances.find(item => item.name === name);
    if (!it || state.busy.has(name)) return;
    const values = readFields(configFields), validated = validateConfig(values, it);
    showErrors(configFields, validated.errors);
    if (!validated.ok) return;
    text($('#config-feedback'), '正在保存；不会自动停止或重启实例。');
    const task = await controller.run('config', [name], { body: values });
    if (!task || name !== detailName || session !== detailSession || !$('#detail-dialog').open) return;
    const result = task.results[0];
    if (result?.ok) {
      // Keep the actual submitted draft in place. A late cache reply must not
      // erase it, and an installed dshVersion must never become a version pin.
      detailInitial = JSON.stringify(readFields(configFields));
      text($('#config-dirty'), ''); text($('#config-feedback'), `配置已保存。${task.note || '当前进程不会自动采用需要重启的配置。'}`);
    } else text($('#config-feedback'), `保存失败：${result?.message || task.phase}`);
  }
  async function removeInstance(name) {
    const task = await controller.run('remove', [name]);
    if (task?.results[0]?.ok && name === detailName) { dialogs.close($('#detail-dialog')); showTasks(); }
  }
  async function loadLog(name) {
    const ticket = ++logSequence, session = detailSession;
    $('#detail-log').closest('details').open = true;
    text($('#detail-log'), '正在载入并脱敏日志…'); $('#btn-logs').disabled = true;
    try {
      const reply = await api.request(`${route(name, 'logs')}?lines=200`);
      if (ticket === logSequence && name === detailName && session === detailSession) text($('#detail-log'), clean(reply.text || '没有日志输出。'));
    } catch (error) {
      controller.authFailure(error);
      if (ticket === logSequence && name === detailName && session === detailSession) text($('#detail-log'), `载入失败：${clean(error.message)}。可以再次点击「载入日志」重试。`);
    } finally { if (ticket === logSequence) $('#btn-logs').disabled = state.busy.has(name); }
  }
  async function openAdd({ preserve = false } = {}) {
    if (!state.authenticated || state.authError || state.busy.has('@add')) {
      announce(state.authError ? AUTH_GUIDANCE : '请等待连接或当前添加任务完成，再打开添加表单。');
      return;
    }
    const ticket = ++addSession;
    if (!preserve) {
      for (const id of Object.values(addFields)) $(`#${id}`).value = '';
      $('#in-port').value = '3080';
      showErrors(addFields, {}); text($('#add-feedback'), '');
    }
    text($('#host-hint'), '正在读取已配置的 SSH 别名；不会发起 SSH 连接…');
    dialogs.open($('#add-dialog')); $('#in-host').focus();
    try {
      const reply = await api.request('/api/ssh-hosts');
      if (ticket !== addSession || !$('#add-dialog').open) return;
      const info = sshHostState(reply);
      text($('#host-hint'), `${info.message}${reply.configPath ? ` 配置来源：${clean(reply.configPath)}` : ''}`);
      $('#ssh-hosts').innerHTML = info.free.map(host => `<option value="${esc(clean(host.name))}"></option>`).join('');
    } catch (error) {
      controller.authFailure(error);
      if (ticket === addSession && $('#add-dialog').open) text($('#host-hint'), `SSH 别名读取失败：${clean(error.message)}。仍可输入已知地址；添加登记不会配置 SSH。`);
    }
  }
  async function submitAdd() {
    if (state.busy.has('@add')) return;
    const validated = validateAdd(readFields(addFields), state.instances);
    showErrors(addFields, validated.errors);
    if (!validated.ok) return;
    text($('#add-feedback'), '正在保存登记…');
    const task = await controller.addInstance(validated.body);
    if (task?.results?.[0]?.ok) { dialogs.close($('#add-dialog')); showTasks(); }
    else if (task) text($('#add-feedback'), `添加失败：${task.results?.[0]?.message || task.phase}`);
  }
  async function copy(value, message) {
    if (!value) { announce('没有可复制的内容。'); return; }
    try { await window.navigator.clipboard.writeText(value); announce(message); }
    catch { announce('复制失败。可直接选择卡片上的无认证地址或工作目录文本；未复制任何认证参数。'); }
  }
  async function retryTask(task, execute = false) {
    if (!task) return;
    const names = execute ? task.targetNames : task.results.filter(result => !result.ok && result.name).map(result => result.name);
    if (task.action === 'config') {
      if (detailName === task.targetNames[0] && $('#detail-dialog').open) {
        text($('#config-feedback'), '上次保存未成功。草稿已保留；请核对输入后再次点击「保存配置」。');
        $('#cfg-display-name').focus();
        return;
      }
      return openDetail(task.targetNames[0]);
    }
    if (task.action === 'add') return openAdd({ preserve: true });
    if (['open', 'open-system'].includes(task.action)) return controller.openInstance(task.targetNames[0], task.action === 'open-system');
    if (task.action === 'reveal') return controller.revealDirectory(task.targetNames[0]);
    if (['doctor', 'versions'].includes(task.action)) return controller.report(task.action);
    if (task.action === 'tray') return controller.refreshTray(); // Re-query before deciding a new toggle.
    return controller.run(task.action, names.length ? names : task.targetNames, { preview: execute ? false : task.preview });
  }
  async function handleAction(button) {
    const action = button.dataset.action, name = button.dataset.name;
    const it = state.instances.find(item => item.name === name);
    const task = state.tasks.find(item => item.id === Number(button.dataset.task));
    if (['start', 'stop', 'restart', 'install'].includes(action)) return controller.run(action, [name]);
    if (action === 'preview-upgrade') return controller.run('upgrade', [name], { preview: true });
    if (action === 'preview-install') return controller.run('install', [name], { preview: true });
    if (action === 'detail') return openDetail(name);
    if (action === 'open') return controller.openInstance(name);
    if (action === 'open-system') return controller.openInstance(name, true);
    if (action === 'reveal') return controller.revealDirectory(name);
    if (action === 'remove') return removeInstance(name);
    if (action === 'logs') return loadLog(name);
    if (action === 'copy-url') return copy(safeURL(it?.url), '已复制无认证地址；未包含任何查询参数或片段。此地址不保证能在另一浏览器中直接登录。');
    if (action === 'copy-step') return copy(it ? failureStep(it)?.command : '', '已复制诊断命令。执行前请核对目标，诊断输出不应直接分享。');
    if (action === 'copy-install') return copy(installCommand(name), '已复制安装命令。在 dsh-deck 项目目录的 PowerShell 中运行；安装准备可能补齐运行时。');
    if (action === 'retry-task') return retryTask(task);
    if (action === 'execute-task') return retryTask(task, true);
    if (action === 'system-open-task') return controller.openInstance(task.targetNames[0], true);
    if (action === 'close-detail') return requestCloseDetail();
    if (action === 'close-dialog') return dialogs.close(button.closest('dialog'));
    if (action === 'confirm-cancel') return dialogs.close($('#confirm-dialog'), 'cancel');
    if (action === 'confirm-proceed') return dialogs.close($('#confirm-dialog'), 'proceed');
    if (action === 'tasks') return showTasks();
    if (action === 'add') return openAdd();
    if (action === 'more') return dialogs.open($('#more-dialog'));
    if (action === 'refresh') return controller.refresh({ manual: true });
    if (action === 'clear-filter') { query = ''; exceptionsOnly = false; $('#flt-q').value = ''; render(); $('#flt-q').focus(); return; }
    if (action === 'exceptions') { exceptionsOnly = !exceptionsOnly; render(); return; }
    if (action === 'start-all' || action === 'stop-all' || action === 'upgrade-all') {
      const kind = action.split('-')[0], targets = controller.targets(kind);
      if (!targets.length) { announce('没有符合条件的目标。缺依赖的本机实例需先完成安装准备。'); return; }
      if (kind === 'start' && state.instances.some(needsLocalInstall)) announce('批量启动不包含缺少 dsh 的本机实例。请先在其卡片查看安装准备计划。');
      dialogs.close($('#more-dialog')); return controller.run(kind, targets.map(item => item.name), { preview: kind === 'upgrade' });
    }
    if (['doctor', 'versions'].includes(action)) { dialogs.close($('#more-dialog')); return controller.report(action); }
    if (action === 'tray') return controller.toggleTray();
    if (action === 'balance') return controller.loadBalance(true);
  }
  document.addEventListener('click', event => {
    const button = event.target.closest?.('[data-action]');
    if (!button || button.disabled) return;
    Promise.resolve(handleAction(button)).catch(error => { controller.authFailure(error); announce(error.message); render(); });
  });
  $('#add-form').addEventListener('submit', event => { event.preventDefault(); submitAdd().catch(error => announce(error.message)); });
  $('#config-form').addEventListener('submit', event => { event.preventDefault(); saveConfig().catch(error => announce(error.message)); });
  $('#config-form').addEventListener('input', () => text($('#config-dirty'), dirtyDetail() ? '有尚未保存的修改；后台刷新不会覆盖输入。' : ''));
  $('#flt-q').addEventListener('input', event => { query = event.target.value; render(); });
  $('#flt-q').addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); query = ''; exceptionsOnly = false; event.target.value = ''; render(); }
  });
  $('#detail-dialog').addEventListener('cancel', event => { if (dirtyDetail()) { event.preventDefault(); requestCloseDetail(); } });
  $('#detail-dialog').addEventListener('close', () => { detailName = ''; detailSession++; logSequence++; });
  $('#add-dialog').addEventListener('close', () => { addSession++; });
  document.addEventListener('visibilitychange', () => {
    if (poll && !disposed && !document.hidden && !state.loading && !state.authError) controller.refresh();
  });
  async function start() {
    render();
    try { await api.establishSession(); }
    catch (error) { state.loadError = clean(error.message); controller.authFailure(error); announce(state.loadError); render(); return; }
    await controller.refresh();
    if (state.authenticated) await Promise.all([controller.refreshTray(), controller.loadBalance()]);
    if (poll && !disposed) timer = window.setInterval(() => {
      if (!document.hidden && !state.loading && !state.authError) controller.refresh();
    }, 20_000);
  }
  return { controller, start, render, openDetail, openAdd, saveConfig, showTasks, requestConfirmation,
    dispose() { disposed = true; if (timer !== null) window.clearInterval(timer); },
  };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined' && document.querySelector('#app')) {
  const api = createApiClient({ fetchImpl: window.fetch.bind(window), location: window.location, history: window.history });
  const panel = createPanel({ document, window, api });
  panel.start().catch(() => { document.querySelector('#notice').textContent = '面板初始化失败，请重新打开 Start.exe。'; });
}
