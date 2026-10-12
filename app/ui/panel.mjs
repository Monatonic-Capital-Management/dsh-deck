import {
  ACTION_TEXT, BUSY_TEXT, DONE_TEXT, QUIET_ACTIONS, STATE_TEXT, TASK_STATUS_TEXT,
  displayName, isUp, isDisabled, isExceptional, needsLocalInstall,
  instanceMatches, selectTargets, availableActions, workdirDisplay, updateNotice,
  probeFreshness, relativeTime, mergeSnapshot, safeURL, loopbackURL, entryAuth, redactText, publicInstance,
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
const timeText = value => value ? new Date(value).toLocaleTimeString('zh-CN', { hour12: false }) : '';
const durationText = ms => { const s = Math.max(0, Math.round(ms / 1000)); return s < 60 ? `${s} 秒` : `${Math.floor(s / 60)} 分 ${s % 60} 秒`; };

// The controller has no DOM or timers. Tests inject in-memory API replies and
// promises; the real view supplies confirmation and window-opening callbacks.
export function createController({ api, confirm = async () => false,
  onChange = () => {}, onTask = () => {}, onNotice = () => {}, now = Date.now }) {
  const clean = api.clean || redactText;
  const state = { instances: [], tasks: [], busy: new Set(), loading: false, probing: false, loadError: '',
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
  // manual=true asks the backend for a fresh probe instead of its cached snapshot.
  async function refresh({ allowBusy = [], manual = false } = {}) {
    const ticket = ++sequence;
    const version = epoch;
    state.loading = true; state.probing = manual; emit();
    try {
      const data = await api.request(manual ? '/api/instances?refresh=1' : '/api/instances');
      if (!Array.isArray(data) || data.some(it => !it || typeof it.name !== 'string')) throw new Error('实例列表格式不正确。');
      if (ticket !== sequence || version !== epoch) return { ok: false, superseded: true };
      const protectedNames = new Set([...state.busy].filter(name => !allowBusy.includes(name)));
      state.instances = mergeSnapshot(state.instances, data.map(it => publicInstance(it, clean)), protectedNames);
      state.loadError = ''; state.authError = false; state.authenticated = true; state.lastReadAt = now();
      if (manual) {
        const failed = state.instances.filter(it => it.statusError).length;
        const up = state.instances.filter(it => isUp(it.state)).length;
        notice(`探测完成：${up} / ${state.instances.length} 个运行中。${failed ? `${failed} 个探测失败，已保留上次状态。` : ''}`);
      }
      return { ok: true };
    } catch (error) {
      if (ticket === sequence && version === epoch) {
        state.loadError = clean(error.message); authFailure(error);
        if (manual) notice(state.loadError);
      }
      return { ok: false, message: clean(error.message) };
    } finally {
      if (ticket === sequence) { state.loading = false; state.probing = false; }
      emit();
    }
  }
  function clearTasks() {
    state.tasks = state.tasks.filter(task => ['running', 'confirming'].includes(task.status) || task.endedAt === null);
    emit();
  }
  function begin(action, instances, { locks = instances.map(it => it.name), preview = false } = {}) {
    if (!state.authenticated || state.authError) { notice(state.authError ? AUTH_GUIDANCE : '请先连接后端并读取实例列表。'); return null; }
    if (locks.some(name => state.busy.has(name))) { notice('该实例有操作正在进行，请等待结果后再试。'); return null; }
    const task = { id: ++nextTask, action, targetNames: instances.map(it => it.name),
      targetLabels: instances.map(it => `${displayName(it)}（${it.name}）`), targetDisplays: instances.map(displayName), preview,
      title: `${preview ? '预览' : ''}${ACTION_TEXT[action] || action}`,
      status: 'running', phase: '准备中', startedAt: now(), endedAt: null, plans: [], results: [], text: '', note: '', locks };
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
    if (!instances.length || instances.some(it => !it)) { notice('没有可操作的目标，请重新探测。'); return null; }
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
        if (action === 'start' && needsLocalInstall(it)) throw new Error('本机尚未安装 dsh，请先安装。');
        const planAction = action === 'restart' ? 'start' : action;
        if (['install', 'upgrade'].includes(action) || (['start', 'restart'].includes(action) && it.kind === 'remote')) {
          phase(task, `正在读取${instances.length > 1 ? ` ${displayName(it)} 的` : ''}${ACTION_TEXT[planAction]}计划`);
          task.plans.push(await readPlan(it, planAction)); emit();
        }
      }
      if (options.preview) {
        task.status = 'preview'; task.phase = '预览完成，未做任何更改';
        return task;
      }
      let pending = instances, plans = task.plans;
      if (action === 'upgrade') {
        const changes = plan => plan.changesSoftware || plan.requiresConfirmation;
        pending = instances.filter((it, index) => changes(task.plans[index]));
        plans = task.plans.filter(changes);
        for (const it of instances) if (!pending.includes(it)) task.results.push({ name: it.name, ok: true, code: null, errorCode: '', message: '已是目标版本，无需升级。' });
        if (!pending.length) { task.status = 'success'; task.phase = '已是目标版本，无需升级'; return task; }
      }
      if (requiresApproval(action, plans)) {
        task.status = 'confirming'; phase(task, '等待确认');
        if (!await confirm(confirmationFor(action, pending, plans))) {
          task.status = 'cancelled'; task.phase = '已取消，未做任何更改'; task.results = []; return task;
        }
      }
      task.status = 'running';
      for (const [index, it] of pending.entries()) {
        currentName = it.name;
        phase(task, `${BUSY_TEXT[action] || ACTION_TEXT[action]}${pending.length > 1 ? `（${index + 1} / ${pending.length}）：${displayName(it)}` : ''}`);
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
      task.status = summary.status;
      task.phase = task.results.length > 1 ? summary.text : summary.failed ? '未完成' : '已完成';
      if (action === 'config' && summary.failed === 0) task.note = '停用不会停止进程；工作目录在重启后生效，固定版本在升级后生效。';
    } catch (error) {
      authFailure(error); task.results.push(errorResult(error, currentName));
      task.status = 'failed'; task.phase = sent ? '未全部完成，请查看逐项结果' : '准备或读取计划失败，未做任何更改';
    } finally {
      if (sent && !state.authError) {
        const result = await refresh({ allowBusy: task.targetNames });
        if (!result.ok && !result.superseded) task.note += `${task.note ? '\n' : ''}操作结果已保留，但状态读取失败，请手动重新探测。`;
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
      phase(task, '正在保存登记');
      const reply = await api.request('/api/instances', { method: 'POST', body: validated.body });
      task.results.push(operationResult(reply, label.name, 'add', clean)); epoch++;
      task.status = summarizeResults(task.results).status;
      task.phase = task.results[0].ok ? '登记已保存，未安装或启动任何服务' : '添加登记失败';
      const result = await refresh();
      if (!result.ok) task.note = '状态读取失败，请重新探测，避免重复添加。';
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
      phase(task, '正在获取地址');
      const fresh = await api.request(route(name, 'url'));
      const url = loopbackURL(fresh.url || fresh.instance?.url);
      if (fresh.ok === false || !url) throw new Error(clean(fresh.message || '未取得可用的 loopback HTTP 地址。未打开旧链接，请检查状态后重试。'));
      patchInstance(fresh.instance);
      if (system) {
        phase(task, '正在打开系统浏览器');
        const reply = await api.request('/api/reveal', { method: 'POST', body: { path: url } });
        task.results.push(operationResult(reply, name, 'open-system', clean));
      } else {
        phase(task, '正在打开窗口');
        const reply = await api.request('/api/open-window', { method: 'POST', body: { url } });
        const result = operationResult(reply, name, 'open', clean);
        if (result.ok) result.message = reply.appWindow === false ? '未找到 Chrome 或 Edge，已用系统默认浏览器打开。' : '已在无边框窗口中打开 dsh。';
        if (result.ok && reply.appWindow === false) task.note = result.message;
        task.results.push(result);
      }
      task.status = summarizeResults(task.results).status; task.phase = task.status === 'success' ? '已打开' : '未能打开';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, name)); task.status = 'failed'; task.phase = '未能打开，没有回退到旧链接'; }
    finally { finish(task); }
    return task;
  }
  async function revealDirectory(name) {
    const it = row(name);
    if (!it || it.kind !== 'local' || !it.workdir) return null;
    const task = begin('reveal', [it]);
    if (!task) return null;
    try {
      phase(task, '正在打开工作目录');
      const reply = await api.request('/api/reveal', { method: 'POST', body: { path: it.workdir } });
      task.results.push(operationResult(reply, name, 'reveal', clean));
      task.status = summarizeResults(task.results).status; task.phase = task.status === 'success' ? '已打开' : '未能打开';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, name)); task.status = 'failed'; task.phase = '打开目录失败'; }
    finally { finish(task); }
    return task;
  }
  async function report(action) {
    const task = begin(action, [], { locks: [`@${action}`] });
    if (!task) return null;
    try {
      phase(task, action === 'doctor' ? '正在检查本机运行时并探测已登记主机' : '正在查询各实例版本，不会安装或升级');
      const reply = await api.request(`/api/${action}`);
      if (reply.ok === false) throw new Error(clean(reply.message || reply.error || '报告请求失败。'));
      if (action === 'doctor') task.text = clean(reply.text || '后端没有返回诊断文本。');
      else {
        const rows = Array.isArray(reply.instances) ? reply.instances : Array.isArray(reply.rows) ? reply.rows : reply.instances ? [reply.instances] : [];
        task.text = rows.length ? rows.map(it => clean(`${it.Name || it.name}：已安装 ${it.Current || it.currentVersion || '未检测到'}，目标 ${it.Target || it.TargetVersion || it.targetVersion || it.Latest || '以计划为准'}${it.UpdateAvailable || it.updateAvailable ? '，可升级' : ''}`)).join('\n') : '没有可用的版本记录。';
      }
      task.status = 'report'; task.phase = '报告已生成。请阅读内容确认结果，生成报告不代表所有检查通过';
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
      notice(state.trayOn === null ? '暂时无法读取托盘状态，未做更改。请稍后重试。' : '已读取托盘状态，再次点击即可切换。');
      return;
    }
    const task = begin('tray', [], { locks: ['@tray'] });
    if (!task) return null;
    try {
      phase(task, '正在切换托盘图标');
      const reply = await api.request(`/api/tray?action=${state.trayOn ? 'stop' : 'start'}`, { method: 'POST' });
      task.results.push(operationResult(reply, '', 'tray', clean));
      if (typeof reply.running === 'boolean') state.trayOn = reply.running;
      task.status = summarizeResults(task.results).status; task.phase = task.status === 'success' ? '已完成' : '未完成';
    } catch (error) { authFailure(error); task.results.push(errorResult(error, '')); task.status = 'failed'; task.phase = '托盘请求失败'; }
    finally { finish(task); }
    return task;
  }
  async function loadBalance(force = false) {
    try {
      const reply = await api.request(`/api/balance${force ? '?refresh=1' : ''}`);
      state.balance = reply.ok === true && Array.isArray(reply.balances) && reply.balances.length
        ? { checkedAt: reply.checkedAt, balances: reply.balances.map(item => ({ currency: clean(item.currency), total: clean(String(item.total)) })) } : null;
      if (force) notice(state.balance ? '余额已更新。' : '余额查询未成功，不影响实例管理。');
    } catch (error) { authFailure(error); state.balance = null; if (force) notice('余额查询失败，不影响实例管理。'); }
    emit();
  }
  return { state, refresh, run, addInstance, openInstance, revealDirectory, report, refreshTray, toggleTray, loadBalance,
    clearTasks, notice, authFailure, emit,
    targets: action => selectTargets(state.instances, action),
  };
}

export function planHTML(plan) {
  const facts = [['dsh', `${plan.currentVersion} → ${plan.targetVersion}`], ['Node', plan.nodeVersion],
    ['变更软件', plan.changesSoftware ? '是' : '否'], ['重启服务', plan.restartsService ? '是' : '否']];
  return `<section class="plan"><h4>${esc(plan.name)} · ${esc(ACTION_TEXT[plan.action])}计划</h4>
    <p class="plan-summary">${esc(plan.summary)}</p>
    <dl class="plan-facts">${facts.map(([key, value]) => `<div><dt>${key}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl>
    ${plan.steps.length ? `<ol class="plan-steps">${plan.steps.map(step => `<li>${esc(step)}</li>`).join('')}</ol>` : ''}
    ${plan.warnings.length ? `<ul class="plan-warnings">${plan.warnings.map(step => `<li>${esc(step)}</li>`).join('')}</ul>` : ''}</section>`;
}

export function taskHTML(task, busy = new Set()) {
  const running = ['running', 'confirming'].includes(task.status);
  const blocked = running || task.locks.some(name => busy.has(name));
  const failures = task.results.some(result => !result.ok);
  const button = (action, label) => `<button type="button" class="small" data-action="${action}" data-task="${task.id}"${blocked ? ' disabled' : ''}>${label}</button>`;
  const targets = (task.targetDisplays || task.targetLabels || []).join('、');
  const elapsed = task.endedAt ? `，用时 ${durationText(task.endedAt - task.startedAt)}` : '';
  const results = task.results.length && (failures || task.results.length > 1)
    ? `<ul class="task-results">${task.results.map(result => `<li data-ok="${result.ok}"><strong>${esc(result.name || '请求')}</strong><span>${esc(result.message)}${result.errorCode && !result.ok ? ` <span class="task-code">${esc(result.errorCode)}</span>` : ''}${result.code !== null && !result.ok ? ` <span class="task-code">退出码 ${esc(result.code)}</span>` : ''}</span></li>`).join('')}</ul>` : '';
  const plans = task.plans.length ? `<details class="task-more"${task.status === 'preview' ? ' open' : ''}><summary>${task.plans.length > 1 ? `查看 ${task.plans.length} 份计划` : '查看计划'}</summary>${task.plans.map(planHTML).join('')}</details>` : '';
  const report = task.text ? `<details class="task-more"><summary>查看报告</summary><pre tabindex="0" aria-label="已脱敏的任务报告">${esc(task.text)}</pre></details>` : '';
  const actions = [
    failures && !running ? button('retry-task', ['config', 'add'].includes(task.action) ? '检查输入后重试' : '重试失败项') : '',
    task.status === 'preview' ? button('execute-task', `核对计划后${ACTION_TEXT[task.action]}`) : '',
    task.action === 'open' && failures && !running ? button('system-open-task', '用系统浏览器打开') : '',
  ].join('');
  return `<span class="task-icon" aria-hidden="true"></span><div class="task-main">
    <div class="task-head"><h3 tabindex="-1">${esc(task.title)}${targets ? `<span class="task-target">${esc(targets)}</span>` : ''}</h3><time datetime="${new Date(task.startedAt).toISOString()}">${esc(timeText(task.startedAt))}</time></div>
    <p class="task-phase"><span class="sr-only">${esc(TASK_STATUS_TEXT[task.status] || task.status)}：</span>${esc(task.phase)}${esc(elapsed)}</p>
    ${results}${task.note ? `<p class="task-note">${esc(task.note)}</p>` : ''}${plans}${report}
    ${actions ? `<div class="task-actions">${actions}</div>` : ''}</div>`;
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
          : document.querySelector('#main');
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
    close(dialog, value = '') { if (dialog?.open) dialog.close(value); },
  };
}

const SEARCH_THRESHOLD = 6;
const TABS = ['overview', 'settings', 'logs'];
const quietStates = ['up', 'up-external', 'down', 'unknown', 'not-probed'];

function toneOf(it) {
  if (isDisabled(it)) return 'off';
  if (['unreachable', 'port-busy'].includes(it.state)) return 'bad';
  if (isExceptional(it) || needsLocalInstall(it)) return 'warn';
  if (isUp(it.state)) return 'ok';
  return 'idle';
}

// What the instance page should explain, if anything. Normal states say nothing.
function situation(it) {
  if (needsLocalInstall(it)) return { title: '本机尚未安装 dsh', hint: '安装会准备 Node 与 dsh，执行前会展示计划供你确认。' };
  if (it.statusError) return { title: '最近一次探测失败，显示的是上次结果', hint: it.statusError };
  if (it.state === 'unhealthy') return { title: '服务进程存在，但尚未就绪', hint: '可以重启，或在“日志”中查看原因。' };
  if (it.state === 'unreachable') return { title: '无法连接 SSH 主机', hint: '' };
  if (it.state === 'port-busy') return { title: '端口被其他程序占用', hint: '请先确认占用该端口的进程。' };
  if (it.state === 'remote-only') return it.stopRemoteService === false
    ? { title: '远端服务保持运行，本机隧道已断开', hint: '点击“连接”即可继续使用。', tone: 'info' }
    : { title: '远端服务在运行，但本机隧道未连接', hint: '点击“连接”重新建立隧道。' };
  if (it.state === 'tunnel-only') return { title: '隧道已连接，但远端服务未就绪', hint: '可以重启，或在“日志”中查看原因。' };
  if (isDisabled(it)) return { title: '此登记已停用', hint: '不参与“全部启动”。可在“设置”中重新启用。', tone: 'info' };
  if (!quietStates.includes(it.state) || it.hint) return { title: STATE_TEXT[it.state] || '状态未知', hint: '' };
  return null;
}

const stateText = it => needsLocalInstall(it) ? '未安装 dsh' : STATE_TEXT[it.state] || '状态未知';
const endpointShort = it => it.kind === 'local' ? (it.port ? `127.0.0.1:${it.port}` : '端口未分配') : it.sshHost || it.name;
function connectionText(it) {
  if (it.kind === 'local') return `本机 · 端口 ${it.port || '未分配'}`;
  const local = it.port || it.localPort;
  return `SSH ${it.sshHost || it.name} · 本机 ${local || '未分配'} → 远端 ${it.remotePort || 3080}`;
}
function versionText(it) {
  const installed = it.dshVersion || (it.dshInstalled === false ? '未安装' : '未检测到');
  const pinned = it.pinnedVersion ? `（固定 ${it.pinnedVersion}）` : '';
  const running = it.runningVersion && it.runningVersion !== it.dshVersion ? `，运行中 ${it.runningVersion}` : '';
  return `${installed}${pinned}${running}`;
}
const balanceText = amount => `${amount.currency === 'CNY' ? '¥' : `${amount.currency} `}${amount.total}`;

// Stable list items and form fields are updated in place. Polling never replaces
// a form, search box or focused button, and operations never move the layout:
// progress shows on the instance itself, results as toasts and in the activity sheet.
export function createPanel({ document, window, api, poll = true, confirm: confirmOverride, now = Date.now }) {
  const $ = selector => document.querySelector(selector);
  const dialogs = createDialogManager(document);
  const items = new Map(), taskNodes = new Map(), toasts = [];
  let query = '', selected = '', tab = 'overview', formFor = '', formInitial = '', formSession = 0;
  let logFor = '', logSequence = 0, addSession = 0, seenTask = 0, openMenu = null;
  let timer = null, disposed = false, confirmQueue = Promise.resolve();
  const clean = api.clean || redactText;
  const text = (element, value) => { const next = String(value ?? ''); if (element.textContent !== next) element.textContent = next; };
  const configFields = { displayName: 'cfg-display-name', description: 'cfg-description', workdir: 'cfg-workdir',
    dshVersion: 'cfg-version', enabled: 'cfg-enabled', autoInstall: 'cfg-auto-install', stopRemoteService: 'cfg-stop-remote' };
  const addFields = { sshHost: 'in-host', name: 'in-name', displayName: 'in-display-name', port: 'in-port' };

  function toast(message, { tone = 'info', task = null } = {}) {
    const value = clean(message);
    if (!value) return;
    text($('#notice'), value);
    const node = document.createElement('div');
    node.className = 'toast'; node.dataset.tone = tone;
    node.innerHTML = `<span class="toast-icon" aria-hidden="true"></span><p>${esc(value)}</p>${task ? `<button type="button" class="subtle small" data-action="view-task" data-task="${task.id}">查看</button>` : ''}<button type="button" class="subtle icon small" data-action="dismiss-toast" data-icon="close" aria-label="关闭通知"></button>`;
    $('#toasts').append(node); toasts.push(node);
    while (toasts.length > 3) toasts.shift().remove();
    if (tone !== 'critical' && poll && typeof window.setTimeout === 'function') window.setTimeout(() => dismissToast(node), 6000);
  }
  function dismissToast(node) {
    const index = toasts.indexOf(node);
    if (index < 0) return;
    toasts.splice(index, 1);
    if (node.contains(document.activeElement)) $('#main').focus({ preventScroll: true });
    node.remove();
  }
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
  function requestConfirmation(data) {
    const next = confirmQueue.then(() => new Promise(resolve => {
      const dialog = $('#confirm-dialog'), proceed = $('#confirm-proceed');
      text($('#confirm-title'), data.title);
      $('#confirm-lines').innerHTML = data.lines.map(line => `<p>${esc(clean(line))}</p>`).join('');
      $('#confirm-plans').innerHTML = data.plans.map(planHTML).join('');
      text(proceed, data.verb || '确认');
      proceed.dataset.tone = data.danger ? 'danger' : 'accent';
      dialog.returnValue = '';
      dialog.addEventListener('close', () => resolve(dialog.returnValue === 'proceed'), { once: true });
      dialogs.open(dialog);
      $('#confirm-cancel').focus();
    }));
    confirmQueue = next.catch(() => false);
    return next;
  }
  const ask = data => (confirmOverride || requestConfirmation)(data);
  const controller = createController({ api, now, confirm: ask, onChange: () => render(), onNotice: message => toast(message) });
  const state = controller.state;
  const row = name => state.instances.find(it => it.name === name);
  const activeTask = name => [...state.tasks].reverse().find(task => ['running', 'confirming'].includes(task.status) && task.targetNames.includes(name));
  const busyText = task => task?.status === 'confirming' ? '等待确认…' : `${BUSY_TEXT[task?.action] || '处理中'}…`;
  const listed = task => !(QUIET_ACTIONS.includes(task.action) && task.status === 'success' && !task.note);
  const showView = view => { $('#app').dataset.view = view; };
  const targetText = task => task.targetDisplays?.length === 1 ? `「${task.targetDisplays[0]}」` : task.targetNames.length > 1 ? ` ${task.targetNames.length} 个实例` : '';

  // One toast per finished operation. Navigation (open, reveal) only speaks when something differs from the request.
  function settle(task) {
    if (!task || ['running', 'confirming', 'cancelled', 'preview', 'report'].includes(task.status)) return task;
    if (QUIET_ACTIONS.includes(task.action) && task.status === 'success') { if (task.note) toast(task.note); return task; }
    if (task.action === 'config') return task;
    if (task.status === 'success' || task.status === 'empty') {
      const skipped = task.action === 'upgrade' && task.results.length > 0 && !task.results.some(result => result.code !== null || !/已是目标版本/.test(result.message));
      toast(skipped ? `${targetText(task).trim() || '所选实例'}已是目标版本` : `${DONE_TEXT[task.action] || `${task.title}已完成`}${targetText(task)}`, { tone: 'success' });
      return task;
    }
    const failed = task.results.find(result => !result.ok);
    const head = task.status === 'partial' ? `${task.title}部分完成（${task.phase}）` : `${task.title}${targetText(task)}失败`;
    toast(`${head}${failed?.message ? `：${failed.message}` : ''}`, { tone: 'critical', task });
    return task;
  }

  function probeText(freshness) {
    const last = relativeTime(freshness.probedAt, now());
    if (freshness.failed) return last ? `探测失败，最近成功于${last}` : '探测失败';
    if (freshness.kind === 'never') return '尚未成功探测';
    return `${last}探测${freshness.stale ? '，可能已过期' : ''}`;
  }
  function quickAction(it) {
    const actions = availableActions(it);
    return actions.includes('open') ? 'open' : actions.includes('start') ? 'start' : '';
  }

  function createItem(it) {
    const node = document.createElement('div');
    node.className = 'instance-item'; node.dataset.name = it.name; node.setAttribute('role', 'listitem');
    node.innerHTML = `<button type="button" class="item-main" data-action="select" data-role="name">
        <span class="avatar" aria-hidden="true"><span class="badge"></span></span>
        <span class="item-text"><span class="item-title"><span class="item-name" data-role="title"></span><span class="pill" data-role="update-badge">可升级</span></span>
          <span class="item-sub"><span class="state-text" data-role="state"></span><span class="item-endpoint" data-role="endpoint"></span></span></span>
      </button><button type="button" class="subtle icon item-quick" data-role="quick"></button>`;
    for (const button of node.querySelectorAll('button')) button.dataset.name = it.name;
    return node;
  }
  function paintItem(node, it) {
    const role = name => node.querySelector(`[data-role="${name}"]`);
    const busy = state.busy.has(it.name), current = it.name === selected;
    node.dataset.state = Object.hasOwn(STATE_TEXT, it.state) ? it.state : 'down';
    node.dataset.tone = toneOf(it); node.dataset.kind = it.kind; node.dataset.selected = String(current);
    node.setAttribute('aria-busy', String(busy));
    text(role('title'), displayName(it));
    text(role('state'), busy ? busyText(activeTask(it.name)) : stateText(it));
    text(role('endpoint'), endpointShort(it));
    role('update-badge').hidden = !updateNotice(it) || isDisabled(it);
    const main = role('name');
    main.setAttribute('aria-current', current ? 'true' : 'false');
    main.title = `${displayName(it)}（${it.name}）`;
    const quick = role('quick'), action = quickAction(it);
    quick.hidden = !action || busy;
    quick.disabled = busy || !state.authenticated || state.authError;
    if (action) {
      const label = `${action === 'open' ? '打开' : it.state === 'remote-only' ? '连接' : '启动'} ${displayName(it)}`;
      quick.dataset.action = action; quick.dataset.icon = action === 'open' ? 'open' : 'play';
      quick.setAttribute('aria-label', label); quick.title = label;
    }
  }

  function applyTab() {
    for (const name of TABS) {
      const button = $(`#tab-${name}`), current = name === tab;
      button.setAttribute('aria-selected', String(current)); button.setAttribute('tabindex', current ? '0' : '-1');
      $(`#panel-${name}`).hidden = !current;
    }
  }
  function setTab(next, { focus = false } = {}) {
    if (!TABS.includes(next)) return;
    tab = next; applyTab();
    if (tab === 'logs' && selected && logFor !== selected) loadLog(selected);
    if (focus) $(`#tab-${tab}`).focus();
  }
  function dirtyForm() { return Boolean(formFor && row(formFor)) && JSON.stringify(readFields(configFields)) !== formInitial; }
  function loadForm(it) {
    const values = configValues(it);
    for (const [key, id] of Object.entries(configFields)) {
      const input = $(`#${id}`);
      if (input.type === 'checkbox') input.checked = values[key]; else input.value = values[key];
    }
    formFor = it.name; formSession++; formInitial = JSON.stringify(readFields(configFields));
    $('#local-config').hidden = it.kind !== 'local'; $('#remote-config').hidden = it.kind === 'local';
    text($('#config-feedback'), ''); text($('#config-dirty'), ''); showErrors(configFields, {});
  }
  function resetPage() {
    tab = 'overview'; logFor = ''; logSequence++;
    text($('#detail-log'), '');
  }
  function ensureSelection() {
    if (selected && row(selected)) return;
    const first = state.instances[0];
    selected = first?.name || '';
    resetPage();
    if (first) loadForm(first); else { formFor = ''; formInitial = ''; showView('list'); }
  }
  function applySelection(name, { focus = false } = {}) {
    const it = row(name);
    if (!it) return false;
    if (name !== selected || formFor !== name) { selected = name; resetPage(); loadForm(it); }
    showView('detail'); render();
    if (focus) $('#detail-title').focus({ preventScroll: true });
    return true;
  }
  function selectInstance(name, options = {}) {
    if (name !== selected && dirtyForm()) {
      const owner = row(formFor);
      return ask({ title: '放弃未保存的设置？', lines: [`「${displayName(owner)}」有尚未保存的设置修改，切换实例会丢弃它们。`], plans: [], verb: '放弃修改', danger: true })
        .then(approved => approved ? applySelection(name, options) : false);
    }
    return applySelection(name, options);
  }

  function paintDetail() {
    const it = row(selected), noAuth = !state.authenticated || state.authError;
    $('#detail').hidden = !it;
    $('#empty-config').hidden = Boolean(it) || !state.authenticated || state.loading || Boolean(state.loadError);
    if (!it) return;
    const busy = state.busy.has(it.name), task = activeTask(it.name), actions = availableActions(it);
    const freshness = probeFreshness(it, now()), missing = needsLocalInstall(it), detail = $('#detail');
    detail.dataset.state = Object.hasOwn(STATE_TEXT, it.state) ? it.state : 'down';
    detail.dataset.tone = toneOf(it); detail.dataset.kind = it.kind; detail.setAttribute('aria-busy', String(busy));
    text($('#detail-title'), displayName(it)); $('#detail-title').title = it.name;
    text($('#detail-state'), busy ? busyText(task) : stateText(it));
    text($('#detail-identity'), it.kind === 'local' ? `本机 ${endpointShort(it)}` : `SSH ${it.sshHost || it.name}`);
    text($('#detail-probe'), probeText(freshness)); $('#detail-probe').dataset.freshness = freshness.kind;

    const primary = ['open', 'install', 'restart', 'start'].find(action => actions.includes(action));
    const header = { open: actions.includes('open'), start: actions.includes('start'), install: actions.includes('install'),
      restart: primary === 'restart', stop: actions.includes('stop') };
    const menu = { restart: actions.includes('restart') && primary !== 'restart', upgrade: selectTargets([it], 'upgrade').length > 0,
      'open-system': isUp(it.state), 'copy-url': Boolean(safeURL(it.url)), reveal: it.kind === 'local' && Boolean(it.workdir) };
    for (const button of $('#detail-actions').querySelectorAll('[data-action]')) {
      const action = button.dataset.action;
      if (action === 'menu') continue;
      const inMenu = Boolean(button.getAttribute('role'));
      button.hidden = !(inMenu ? menu[action] : header[action]);
      if (!inMenu) button.dataset.priority = action === primary ? 'primary' : 'secondary';
      button.disabled = noAuth || (busy && action !== 'copy-url');
      if (!inMenu && action === 'start') text(button, it.state === 'remote-only' ? '连接' : '启动');
      if (!inMenu && action === 'install') text(button, it.kind === 'local' ? '安装 dsh…' : '部署 dsh…');
    }
    $('#detail-more').hidden = !Object.values(menu).some(Boolean);
    $('#detail-progress').hidden = !busy;
    text($('#detail-phase'), busy ? task?.phase || '处理中' : '');

    const alert = $('#detail-alert'), info = situation(it);
    alert.hidden = !info;
    if (info) {
      const hint = it.hint || info.hint, step = failureStep(it), role = name => alert.querySelector(`[data-role="${name}"]`);
      alert.dataset.tone = { bad: 'critical', warn: 'warning' }[toneOf(it)] || info.tone || 'info';
      text(role('summary'), info.title);
      text(role('hint'), hint); role('hint').hidden = !hint;
      role('step').hidden = !step; text(role('step'), step ? `复制诊断命令：${step.label}` : '');
      role('manual').hidden = !missing || !installCommand(it.name);
    }
    const update = updateNotice(it);
    $('#detail-update').hidden = !update || isDisabled(it);
    text($('#detail-update-text'), update);
    $('#detail-update').querySelector('[data-action="upgrade"]').disabled = busy || noAuth;

    const address = safeURL(it.url), workdir = workdirDisplay(it);
    $('#detail-url-row').hidden = !address; text($('#detail-url'), address);
    text($('#detail-connection'), connectionText(it));
    $('#detail-wd-row').hidden = !workdir; text($('#detail-workdir'), workdir?.full || '');
    text($('#detail-version'), versionText(it));
    $('#detail-node-row').hidden = !it.nodeVersion; text($('#detail-node'), it.nodeVersion || '');
    text($('#detail-probed'), freshness.probedAt ? `${clockText(freshness.probedAt)}（${relativeTime(freshness.probedAt, now())}）` : '尚无成功记录');
    const attempted = freshness.attemptedAt && freshness.attemptedAt !== freshness.probedAt;
    $('#detail-attempt-row').hidden = !attempted; text($('#detail-attempted'), attempted ? clockText(freshness.attemptedAt) : '');
    $('#detail-backend-row').hidden = !it.detail && !it.statusError; text($('#detail-backend'), [it.statusError, it.detail].filter(Boolean).join('；'));
    $('#detail-desc-row').hidden = !it.description; text($('#detail-description'), it.description || '');
    for (const button of $('#panel-overview').querySelectorAll('[data-action]')) if (button.dataset.action === 'reveal') button.disabled = busy || noAuth;

    for (const id of Object.values(configFields)) $(`#${id}`).disabled = busy || noAuth;
    $('#btn-save-config').disabled = busy || noAuth;
    $('#btn-remove').disabled = busy || noAuth;
    applyTab();
  }
  function paintTask(node, task) {
    const html = taskHTML(task, state.busy);
    node.dataset.status = task.status;
    if (node._taskHTML === html) return;
    const focused = node.contains(document.activeElement) ? document.activeElement.dataset.action : null;
    const open = [...node.querySelectorAll('details')].map(item => item.open);
    node.innerHTML = html; node._taskHTML = html;
    [...node.querySelectorAll('details')].forEach((item, index) => { if (open[index]) item.open = true; });
    if (focused) (node.querySelector(`[data-action="${focused}"]`) || node.querySelector('h3'))?.focus({ preventScroll: true });
  }
  function renderTasks() {
    if ($('#activity-dialog').open) seenTask = Math.max(seenTask, ...state.tasks.map(task => task.id));
    const visible = state.tasks.filter(listed);
    const running = state.tasks.filter(task => ['running', 'confirming'].includes(task.status)).length;
    const unseen = state.tasks.filter(task => task.id > seenTask && ['failed', 'partial'].includes(task.status)).length;
    const indicator = $('#task-indicator');
    indicator.dataset.state = unseen ? 'attention' : running ? 'running' : 'idle';
    text(indicator, running || unseen || '');
    $('#btn-tasks').setAttribute('aria-label', `活动：${running ? `${running} 项进行中` : unseen ? `${unseen} 项失败未查看` : `${visible.length} 条记录`}`);
    text($('#task-count'), visible.length ? `${visible.length} 条` : '');
    $('#tasks-empty').hidden = visible.length > 0;
    $('#btn-clear-tasks').hidden = !state.tasks.some(task => task.endedAt !== null && !['running', 'confirming'].includes(task.status));
    for (const [id, node] of taskNodes) if (!visible.some(task => task.id === id)) { node.remove(); taskNodes.delete(id); }
    for (const task of visible) {
      let node = taskNodes.get(task.id);
      if (!node) {
        node = document.createElement('article'); node.className = 'task'; node.dataset.task = String(task.id);
        taskNodes.set(task.id, node); $('#task-list').prepend(node);
      }
      paintTask(node, task);
    }
    const recent = selected ? [...state.tasks].reverse().find(task => task.targetNames.includes(selected) && listed(task)) : null;
    $('#detail-task').hidden = !recent;
    if (recent) paintTask($('#detail-task-body'), recent);
  }
  function render() {
    ensureSelection();
    const total = state.instances.length, noAuth = !state.authenticated || state.authError;
    text($('#count'), total || '');
    const searchable = total >= SEARCH_THRESHOLD;
    $('#filter').hidden = !searchable;
    if (!searchable && query) { query = ''; $('#flt-q').value = ''; }
    let hits = 0;
    for (const [name, node] of items) if (!row(name)) { node.remove(); items.delete(name); }
    for (const it of state.instances) {
      let node = items.get(it.name);
      if (!node) { node = createItem(it); items.set(it.name, node); $('#cards').append(node); }
      paintItem(node, it);
      node.hidden = searchable && !instanceMatches(it, query);
      if (!node.hidden) hits++;
    }
    $('#empty-filter').hidden = !total || hits > 0;
    $('#loading').hidden = Boolean(state.lastReadAt || state.loadError || total);
    $('#backend-error').hidden = !state.loadError; text($('#backend-error-text'), state.loadError);
    text($('#sb-updated'), state.probing ? '正在探测全部实例…' : state.lastReadAt ? `已更新 ${timeText(state.lastReadAt)}` : '');
    $('#btn-refresh').disabled = state.probing; $('#btn-refresh').dataset.busy = String(state.probing);
    for (const [id, action] of [['btn-start-all', 'start'], ['btn-stop-all', 'stop'], ['btn-upgrade-all', 'upgrade']]) {
      const targets = controller.targets(action);
      $(`#${id}`).hidden = total < 2;
      $(`#${id}`).disabled = noAuth || !targets.length || targets.some(it => state.busy.has(it.name));
    }
    $('#batch-group').hidden = total < 2;
    $('#btn-add').disabled = noAuth || state.busy.has('@add');
    $('#btn-add-ok').disabled = noAuth || state.busy.has('@add');
    for (const id of Object.values(addFields)) $(`#${id}`).disabled = state.busy.has('@add');
    for (const action of ['doctor', 'versions']) $(`#btn-${action}`).disabled = noAuth || state.busy.has(`@${action}`);
    $('#btn-tray').disabled = noAuth || state.busy.has('@tray');
    $('#btn-tray').setAttribute('aria-checked', String(state.trayOn === true));
    text($('#btn-tray'), state.trayOn === null ? '托盘图标（读取状态）' : '在通知区显示图标');
    $('#btn-balance').hidden = !state.balance;
    if (state.balance) {
      const amount = state.balance.balances.find(item => Number(item.total) > 0) || state.balance.balances[0];
      text($('#balance-amount'), balanceText(amount));
      $('#btn-balance').title = `DeepSeek 账户余额，查询于 ${clockText(state.balance.checkedAt)}。点击重新查询。`;
    }
    paintDetail();
    renderTasks();
  }

  function showTasks(taskId) {
    closeMenu();
    seenTask = Math.max(seenTask, ...state.tasks.map(task => task.id));
    dialogs.open($('#activity-dialog'));
    render();
    const node = taskId ? taskNodes.get(taskId) : null;
    if (node) {
      for (const item of node.querySelectorAll('details')) item.open = true;
      node.scrollIntoView?.({ block: 'nearest' }); node.querySelector('h3')?.focus();
    } else $('#tasks-heading').focus();
  }
  async function runReport(action) {
    const dialog = $('#report-dialog');
    text($('#report-title'), ACTION_TEXT[action]);
    text($('#report-status'), action === 'doctor' ? '正在检查本机运行时并探测已登记主机…' : '正在查询各实例的版本…');
    text($('#report-text'), ''); $('#report-text').hidden = true; dialog.dataset.state = 'loading';
    dialogs.open(dialog);
    const task = await controller.report(action);
    if (!task) { dialogs.close(dialog); return null; }
    if (task.status === 'report') {
      text($('#report-status'), task.phase); text($('#report-text'), task.text); $('#report-text').hidden = false; dialog.dataset.state = 'done';
    } else {
      text($('#report-status'), `无法生成报告：${task.results[0]?.message || task.phase}`); dialog.dataset.state = 'failed';
    }
    if (!dialog.open) toast(`${ACTION_TEXT[action]}${task.status === 'report' ? '报告已生成' : '失败'}`, { tone: task.status === 'report' ? 'info' : 'critical', task });
    return task;
  }
  async function saveConfig() {
    const name = formFor, session = formSession;
    const it = row(name);
    if (!it || state.busy.has(name)) return;
    const values = readFields(configFields), validated = validateConfig(values, it);
    if (!validated.ok && tab !== 'settings') setTab('settings');
    showErrors(configFields, validated.errors);
    if (!validated.ok) return;
    text($('#config-feedback'), '正在保存…');
    const task = await controller.run('config', [name], { body: values });
    if (!task || name !== formFor || session !== formSession) return;
    const result = task.results[0];
    if (result?.ok) {
      // Keep the submitted draft in place. A late cache reply must not erase it,
      // and an installed dshVersion must never become a version pin.
      formInitial = JSON.stringify(readFields(configFields));
      text($('#config-dirty'), ''); text($('#config-feedback'), `已保存。${task.note || ''}`);
    } else text($('#config-feedback'), `保存失败：${result?.message || task.phase}`);
  }
  async function removeInstance(name) {
    const task = await controller.run('remove', [name]);
    if (task?.results[0]?.ok && formFor === name) { formFor = ''; formInitial = ''; }
    settle(task);
    render();
  }
  async function loadLog(name) {
    if (!name) return;
    const ticket = ++logSequence;
    logFor = name;
    if (tab !== 'logs') { tab = 'logs'; applyTab(); }
    text($('#detail-log'), '正在载入日志…'); $('#btn-logs').disabled = true;
    try {
      const reply = await api.request(`${route(name, 'logs')}?lines=200`);
      if (ticket === logSequence && name === selected) text($('#detail-log'), clean(reply.text || '没有日志输出。'));
    } catch (error) {
      controller.authFailure(error);
      if (ticket === logSequence && name === selected) { logFor = ''; text($('#detail-log'), `载入失败：${clean(error.message)}`); }
    } finally { if (ticket === logSequence) $('#btn-logs').disabled = false; }
  }
  async function openAdd({ preserve = false } = {}) {
    if (!state.authenticated || state.authError || state.busy.has('@add')) {
      toast(state.authError ? AUTH_GUIDANCE : '请等待连接或当前添加完成后再试。');
      return;
    }
    const ticket = ++addSession;
    if (!preserve) {
      for (const id of Object.values(addFields)) $(`#${id}`).value = '';
      $('#in-port').value = '3080';
      showErrors(addFields, {}); text($('#add-feedback'), '');
    }
    text($('#host-hint'), '正在读取 SSH 配置中的别名…');
    dialogs.open($('#add-dialog')); $('#in-host').focus();
    try {
      const reply = await api.request('/api/ssh-hosts');
      if (ticket !== addSession || !$('#add-dialog').open) return;
      const info = sshHostState(reply);
      text($('#host-hint'), `${info.message}${reply.configPath ? ` 来源：${clean(reply.configPath)}` : ''}`);
      $('#ssh-hosts').innerHTML = info.free.map(host => `<option value="${esc(clean(host.name))}"></option>`).join('');
    } catch (error) {
      controller.authFailure(error);
      if (ticket === addSession && $('#add-dialog').open) text($('#host-hint'), `SSH 别名读取失败：${clean(error.message)}。仍可直接填写地址。`);
    }
  }
  async function submitAdd() {
    if (state.busy.has('@add')) return;
    const validated = validateAdd(readFields(addFields), state.instances);
    showErrors(addFields, validated.errors);
    if (!validated.ok) return;
    text($('#add-feedback'), '正在保存…');
    const before = new Set(state.instances.map(it => it.name));
    const task = await controller.addInstance(validated.body);
    if (task?.results?.[0]?.ok) {
      dialogs.close($('#add-dialog')); settle(task);
      const added = state.instances.find(it => !before.has(it.name));
      if (added) await selectInstance(added.name);
    } else if (task) text($('#add-feedback'), `添加失败：${task.results?.[0]?.message || task.phase}`);
  }
  async function copy(value, message) {
    if (!value) { toast('没有可复制的内容。'); return; }
    try { await window.navigator.clipboard.writeText(value); toast(message, { tone: 'success' }); }
    catch { toast('复制失败，请手动选中文本复制。', { tone: 'critical' }); }
  }
  async function retryTask(task, execute = false) {
    if (!task) return;
    const names = execute ? task.targetNames : task.results.filter(result => !result.ok && result.name).map(result => result.name);
    if (task.action === 'config') {
      const target = task.targetNames[0];
      if (formFor !== target && !await selectInstance(target)) return;
      setTab('settings');
      text($('#config-feedback'), '上次保存未成功，草稿已保留。请核对后再次保存。');
      $('#cfg-display-name').focus();
      return;
    }
    if (task.action === 'add') return openAdd({ preserve: true });
    if (['open', 'open-system'].includes(task.action)) return settle(await controller.openInstance(task.targetNames[0], task.action === 'open-system'));
    if (task.action === 'reveal') return settle(await controller.revealDirectory(task.targetNames[0]));
    if (['doctor', 'versions'].includes(task.action)) return runReport(task.action);
    if (task.action === 'tray') return controller.refreshTray(); // Re-query before deciding a new toggle.
    return settle(await controller.run(task.action, names.length ? names : task.targetNames, { preview: execute ? false : task.preview }));
  }

  function menuItems(menu) {
    const shown = el => { for (let node = el; node && node !== menu; node = node.parentNode) if (node.hidden) return false; return true; };
    return [...menu.querySelectorAll('[role="menuitem"], [role="menuitemcheckbox"]')].filter(item => !item.disabled && shown(item));
  }
  function closeMenu({ restore = false } = {}) {
    if (!openMenu) return;
    const { menu, button } = openMenu;
    openMenu = null; menu.hidden = true; button.setAttribute('aria-expanded', 'false');
    if (restore) button.focus({ preventScroll: true });
  }
  function toggleMenu(button) {
    const menu = $(`#${button.dataset.menu}`), wasOpen = openMenu?.menu === menu;
    closeMenu();
    if (wasOpen || !menu) return;
    menu.hidden = false; button.setAttribute('aria-expanded', 'true'); openMenu = { menu, button };
    menuItems(menu)[0]?.focus({ preventScroll: true });
  }

  async function handleAction(button) {
    const action = button.dataset.action;
    const name = button.dataset.name || (button.closest?.('#detail') ? selected : '');
    const it = row(name);
    const task = state.tasks.find(item => item.id === Number(button.dataset.task));
    if (action === 'select') return selectInstance(name);
    if (['start', 'stop', 'restart', 'install', 'upgrade'].includes(action)) return settle(await controller.run(action, [name]));
    if (action === 'open') return settle(await controller.openInstance(name));
    if (action === 'open-system') return settle(await controller.openInstance(name, true));
    if (action === 'reveal') return settle(await controller.revealDirectory(name));
    if (action === 'remove') return removeInstance(name);
    if (action === 'logs') return loadLog(name);
    if (action === 'tab') return setTab(button.dataset.tab);
    if (action === 'back') { showView('list'); items.get(selected)?.querySelector('[data-role="name"]')?.focus(); return; }
    if (action === 'menu') return toggleMenu(button);
    if (action === 'copy-url') return copy(safeURL(it?.url), '已复制地址（不含认证参数）。在其他浏览器中打开可能需要重新登录。');
    if (action === 'copy-step') return copy(it ? failureStep(it)?.command : '', '已复制诊断命令。执行前请核对目标主机，输出不要直接分享。');
    if (action === 'copy-install') return copy(installCommand(name), '已复制安装命令，请在 dsh-deck 目录的 PowerShell 中运行。');
    if (action === 'copy-log') return copy($('#detail-log').textContent, '已复制日志。日志可能包含主机名和路径，请勿直接外传。');
    if (action === 'copy-report') return copy($('#report-text').textContent, '已复制报告。');
    if (action === 'retry-task') return retryTask(task);
    if (action === 'execute-task') return retryTask(task, true);
    if (action === 'system-open-task') return settle(await controller.openInstance(task.targetNames[0], true));
    if (action === 'view-task') { dismissToast(button.closest('.toast')); return showTasks(task?.id); }
    if (action === 'dismiss-toast') return dismissToast(button.closest('.toast'));
    if (action === 'close-dialog') return dialogs.close(button.closest('dialog'));
    if (action === 'confirm-cancel') return dialogs.close($('#confirm-dialog'), 'cancel');
    if (action === 'confirm-proceed') return dialogs.close($('#confirm-dialog'), 'proceed');
    if (action === 'tasks') return showTasks();
    if (action === 'add') return openAdd();
    if (action === 'refresh') return controller.refresh({ manual: true });
    if (action === 'clear-filter') { query = ''; $('#flt-q').value = ''; render(); $('#flt-q').focus(); return; }
    if (action === 'clear-tasks') { controller.clearTasks(); $('#tasks-heading').focus(); return; }
    if (['start-all', 'stop-all', 'upgrade-all'].includes(action)) {
      const kind = action.split('-')[0], targets = controller.targets(kind);
      if (!targets.length) { toast('没有符合条件的实例。'); return; }
      if (kind === 'start' && state.instances.some(needsLocalInstall)) toast('已跳过尚未安装 dsh 的本机实例。');
      return settle(await controller.run(kind, targets.map(item => item.name)));
    }
    if (['doctor', 'versions'].includes(action)) return runReport(action);
    if (action === 'tray') return settle(await controller.toggleTray());
    if (action === 'balance') return controller.loadBalance(true);
  }
  const fail = error => { controller.authFailure(error); toast(error.message, { tone: 'critical' }); render(); };
  document.addEventListener('click', event => {
    if (event.target?.id === 'activity-dialog') { dialogs.close(event.target); return; } // Light dismiss on the backdrop.
    const button = event.target.closest?.('[data-action]');
    const inMenu = Boolean(openMenu && button && openMenu.menu.contains(button));
    if (openMenu && button !== openMenu.button && !inMenu) closeMenu();
    if (!button || button.disabled) return;
    if (inMenu) closeMenu({ restore: true });
    Promise.resolve(handleAction(button)).catch(fail);
  });
  document.addEventListener('dblclick', event => {
    const main = event.target.closest?.('[data-role="name"]');
    const quick = main && items.get(main.dataset.name)?.querySelector('[data-role="quick"]');
    if (quick && !quick.hidden && !quick.disabled) Promise.resolve(handleAction(quick)).catch(fail);
  });
  document.addEventListener('keydown', event => {
    const target = event.target;
    if (openMenu) {
      if (event.key === 'Escape') { event.preventDefault(); closeMenu({ restore: true }); return; }
      if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) && openMenu.menu.contains(target)) {
        event.preventDefault();
        const list = menuItems(openMenu.menu), index = list.indexOf(target);
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? list.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + list.length) % list.length;
        list[next]?.focus(); return;
      }
      if (event.key === 'Tab') closeMenu();
    }
    if (target?.getAttribute?.('role') === 'tab' && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      const index = TABS.indexOf(target.dataset.tab);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? TABS.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + TABS.length) % TABS.length;
      setTab(TABS[next], { focus: true }); return;
    }
    if (target?.dataset?.role === 'name' && ['ArrowDown', 'ArrowUp'].includes(event.key)) {
      event.preventDefault();
      const visible = state.instances.filter(it => !items.get(it.name)?.hidden);
      const next = visible[visible.findIndex(it => it.name === target.dataset.name) + (event.key === 'ArrowDown' ? 1 : -1)];
      if (next) items.get(next.name).querySelector('[data-role="name"]').focus();
    }
  });
  $('#add-form').addEventListener('submit', event => { event.preventDefault(); submitAdd().catch(fail); });
  $('#config-form').addEventListener('submit', event => { event.preventDefault(); saveConfig().catch(fail); });
  $('#config-form').addEventListener('input', () => text($('#config-dirty'), dirtyForm() ? '有未保存的更改' : ''));
  $('#flt-q').addEventListener('input', event => { query = event.target.value; render(); });
  $('#flt-q').addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); query = ''; event.target.value = ''; render(); }
  });
  $('#add-dialog').addEventListener('close', () => { addSession++; });
  document.addEventListener('visibilitychange', () => {
    if (poll && !disposed && !document.hidden && !state.loading && !state.authError) controller.refresh();
  });
  async function start() {
    render();
    try { await api.establishSession(); }
    catch (error) { state.loadError = clean(error.message); controller.authFailure(error); render(); return; }
    await controller.refresh();
    if (state.authenticated) await Promise.all([controller.refreshTray(), controller.loadBalance()]);
    if (poll && !disposed) timer = window.setInterval(() => {
      if (!document.hidden && !state.loading && !state.authError) controller.refresh();
    }, 20_000);
  }
  return { controller, start, render, selectInstance, setTab, openAdd, saveConfig, showTasks, runReport, requestConfirmation,
    dispose() { disposed = true; if (timer !== null) window.clearInterval(timer); },
  };
}

if (typeof window !== 'undefined' && typeof document !== 'undefined' && document.querySelector('#app')) {
  const api = createApiClient({ fetchImpl: window.fetch.bind(window), location: window.location, history: window.history });
  const panel = createPanel({ document, window, api });
  panel.start().catch(() => {
    document.querySelector('#backend-error-text').textContent = '面板初始化失败，请重新打开 Start.exe。';
    document.querySelector('#backend-error').hidden = false;
  });
}
