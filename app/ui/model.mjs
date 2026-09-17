// Pure UI policy. No DOM, network, storage or launcher side effects.
export const HISTORY_LIMIT = 30;
export const STALE_AFTER_MS = 90_000;
export const STATE_TEXT = Object.freeze({
  up: '运行中', 'up-external': '运行中（外部进程）', 'remote-only': '仅远端服务',
  'tunnel-only': '仅隧道', down: '已停止', disabled: '已停用',
  unreachable: '无法连接', 'port-busy': '端口被占用', unhealthy: '服务未就绪',
  unknown: '尚未探测', 'not-probed': '尚未探测',
});
export const ACTION_TEXT = Object.freeze({
  start: '启动', stop: '停止', restart: '重启', install: '安装准备', upgrade: '升级',
  config: '保存配置', remove: '移除登记', add: '添加实例', open: '打开实例',
  'open-system': '用系统浏览器打开', reveal: '打开工作目录', doctor: '环境自检',
  versions: '检查版本', tray: '切换托盘监控',
});
export const isUp = state => state === 'up' || state === 'up-external';
export const isActive = state => isUp(state) || ['remote-only', 'tunnel-only', 'unhealthy'].includes(state);
export const displayName = it => it.displayName || it.name || '未命名实例';
export const needsLocalInstall = it => it.kind === 'local' && it.dshInstalled === false;

export function isExceptional(it) {
  if (it.enabled === false || it.state === 'disabled') return false;
  if (it.statusError) return true;
  if (it.state === 'remote-only' && it.stopRemoteService === false) return false;
  return ['unreachable', 'port-busy', 'remote-only', 'tunnel-only', 'unhealthy'].includes(it.state);
}

export function instanceMatches(it, query, exceptionsOnly = false) {
  if (exceptionsOnly && !isExceptional(it)) return false;
  const needles = String(query || '').trim().toLowerCase().split(/[\s,]+/).filter(Boolean);
  const haystack = [it.name, it.displayName, it.sshHost, it.description, it.kind]
    .filter(Boolean).join(' ').toLowerCase();
  return needles.every(needle => haystack.includes(needle));
}

export function selectTargets(instances, action) {
  return instances.filter(it => {
    // A disabled registration can still own a running process or tunnel.
    if (action === 'stop') return isActive(it.state);
    if (it.enabled === false || it.state === 'disabled') return false;
    if (action === 'start') return !isUp(it.state) && !needsLocalInstall(it);
    if (action === 'restart') return isActive(it.state);
    if (action === 'upgrade') return it.dshInstalled !== false && Boolean(it.dshVersion);
    return false;
  });
}

export function availableActions(it) {
  const actions = ['detail'];
  if (isActive(it.state)) actions.push('stop');
  if (it.enabled === false || it.state === 'disabled') return actions;
  if (isUp(it.state)) actions.push('open', 'restart');
  else if (needsLocalInstall(it)) actions.push('install');
  else actions.push(it.state === 'unhealthy' ? 'restart' : 'start');
  if (it.kind === 'remote' && it.state !== 'unreachable' && it.dshInstalled === false) actions.push('install');
  return actions;
}

export function shortDetail(it) {
  if (it.kind === 'local') return `本机 · 端口 ${it.port || '未分配'}`;
  return `${it.sshHost || '远端'} · ${it.port || it.localPort || '未分配'} → ${it.remotePort || 3080}`;
}

export function workdirDisplay(it) {
  if (it.kind !== 'local' || !it.workdir) return null;
  const parts = String(it.workdir).split(/[\\/]+/).filter(Boolean);
  return { full: String(it.workdir), short: (parts.length > 2 ? '…\\' : '') + parts.slice(-2).join('\\') };
}

export function updateNotice(it) {
  if (!it.dshVersion || !it.updateAvailable) return '';
  const target = it.targetVersion || it.pinnedVersion || it.latestVersion || '以计划为准';
  return `已安装 ${it.dshVersion} → 目标 ${target}${it.pinnedVersion ? '（固定版本）' : ''}`;
}

function timestamp(value) {
  if (value === null || value === undefined || value === '') return null;
  const result = typeof value === 'number' ? value : Date.parse(value);
  return Number.isFinite(result) && result > 0 ? result : null;
}

export function probeFreshness(it, now, maxAge = STALE_AFTER_MS) {
  const probedAt = timestamp(it.probedAt);
  const attemptedAt = timestamp(it.attemptedAt);
  const age = probedAt === null ? null : Math.max(0, now - probedAt);
  const failed = Boolean(it.statusError);
  const stale = probedAt === null || now - probedAt > maxAge || probedAt > now + 30_000;
  return { probedAt, attemptedAt, age, failed, stale,
    kind: failed ? 'failed' : probedAt === null ? 'never' : stale ? 'stale' : 'fresh' };
}

export function mergeSnapshot(previous, incoming, protectedNames = new Set()) {
  const old = new Map(previous.map(it => [it.name, it]));
  return incoming.map(it => {
    const before = old.get(it.name);
    if (!before) return it;
    if (protectedNames.has(it.name)) return before;
    const oldTime = timestamp(before.probedAt);
    const nextTime = timestamp(it.probedAt);
    if (oldTime && (!nextTime || nextTime < oldTime)) {
      // Configuration may be new even when a cached observation is older.
      const merged = { ...it };
      for (const key of ['state', 'port', 'detail', 'url', 'http', 'dshInstalled', 'dshVersion',
        'hint', 'failCode', 'probedAt', 'attemptedAt', 'statusError']) merged[key] = before[key];
      // A later failed attempt may accompany an older cached success. Keep the
      // newer state, but do not hide that latest failure from the reader.
      if (timestamp(it.attemptedAt) > (timestamp(before.attemptedAt) || 0)) {
        merged.attemptedAt = it.attemptedAt; merged.statusError = it.statusError;
      }
      return merged;
    }
    return it;
  }).concat(previous.filter(it => protectedNames.has(it.name) && !incoming.some(row => row.name === it.name)));
}

// Display/copy intentionally discard ALL query parameters and fragments. We do
// not guess which future upstream parameter might become an authentication key.
export function safeURL(value) {
  try {
    const url = new URL(String(value || ''));
    if (!['http:', 'https:'].includes(url.protocol)) return '';
    url.username = ''; url.password = ''; url.search = ''; url.hash = '';
    return url.href;
  } catch { return ''; }
}

export function loopbackURL(value) {
  try {
    const url = new URL(String(value || ''));
    const loopback = url.hostname === 'localhost' || url.hostname === '[::1]' || /^127\./.test(url.hostname);
    return url.protocol === 'http:' && loopback && !url.username && !url.password ? url.href : '';
  } catch { return ''; }
}

export function entryAuth(href) {
  const url = new URL(href);
  const fragment = new URLSearchParams(url.hash.slice(1));
  const token = fragment.get('t') || url.searchParams.get('t') || '';
  // No panel feature needs a query string or a fragment after bootstrap.
  return { token, cleanPath: url.pathname, origin: url.origin };
}

export function redactText(value, secrets = []) {
  let text = typeof value === 'string' ? value : value == null ? '' : String(value);
  for (const secret of secrets.filter(Boolean)) {
    text = text.split(secret).join('[已隐藏]').split(encodeURIComponent(secret)).join('[已隐藏]');
  }
  text = text.replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)/g, '[私钥已隐藏]');
  text = text.replace(/\b(?:authorization|proxy-authorization|set-cookie|cookie)\s*:[^\r\n]*/gi, '[认证信息已隐藏]');
  text = text.replace(/\bBearer\s+[^\s,;"'<>]+/gi, 'Bearer [已隐藏]');
  text = text.replace(/https?:\/\/[^\s<>"'`]+/gi, url => safeURL(url) || '[地址已隐藏]');
  text = text.replace(/([?&#](?:t|token|access_token|api_key|auth|password)=)[^&#\s<>"']*/gi, '$1[已隐藏]');
  text = text.replace(/((?:["']?)(?:t|[\w-]*token|[\w-]*api[_-]?key|password|passwd|[\w-]*secret)(?:["']?)\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}]+)/gi, '$1[已隐藏]');
  return text.length > 12_000 ? text.slice(0, 12_000) + '\n（显示内容已截断）' : text;
}

export function publicInstance(it, clean = redactText) {
  const result = {};
  const fields = ['name', 'kind', 'state', 'port', 'detail', 'http', 'sshHost', 'description', 'enabled',
    'remotePort', 'localPort', 'dshInstalled', 'dshVersion', 'latestVersion', 'updateAvailable',
    'versionDrift', 'failCode', 'hint', 'workdir', 'displayName', 'probedAt', 'attemptedAt',
    'statusError', 'pinnedVersion', 'targetVersion', 'autoInstall', 'stopRemoteService', 'nodeVersion', 'runningVersion'];
  for (const key of fields) if (key in it) result[key] = typeof it[key] === 'string' ? clean(it[key]) : it[key];
  result.url = safeURL(it.url);
  return result;
}

export function operationResult(reply, name, action, clean = redactText) {
  const children = Array.isArray(reply?.results) ? reply.results : [];
  const own = children.find(row => row.name === name);
  const ok = reply?.ok === true && children.every(row => row.ok === true);
  const fallback = ok ? `${ACTION_TEXT[action] || '操作'}已完成。` : '操作未成功，后端未提供原因。请重新读取状态后重试。';
  return {
    name, ok, code: Number.isFinite(reply?.code) ? reply.code : null,
    errorCode: clean(reply?.errorCode || own?.errorCode || (ok ? '' : 'operation-failed')),
    message: clean(reply?.message || own?.message || reply?.error || fallback),
  };
}

export function summarizeResults(results) {
  const total = results.length;
  const success = results.filter(result => result.ok === true).length;
  const failed = total - success;
  return { total, success, failed, status: !total ? 'empty' : !failed ? 'success' : !success ? 'failed' : 'partial',
    text: `${success} / ${total} 个成功${failed ? `，${failed} 个失败` : ''}` };
}

export function appendTask(history, task, limit = HISTORY_LIMIT) {
  const next = [...history];
  while (next.length >= limit) {
    const index = next.findIndex(item => !['running', 'confirming'].includes(item.status) && item.endedAt !== null);
    if (index < 0) throw new Error('进行中的任务过多，请等待其中一项完成。');
    next.splice(index, 1);
  }
  return [...next, task];
}

const stepText = value => typeof value === 'string' ? value : value &&
  (value.text || value.summary || value.description || value.title || value.label || value.command) || '';

export function normalizePlan(plan, name, action, clean = redactText) {
  if (plan && (plan.ok === false || plan.blocked === true)) {
    const error = new Error(clean(plan.summary || plan.message || '计划被后端拒绝；未发送变更。'));
    error.errorCode = clean(plan.errorCode || 'plan-blocked');
    throw error;
  }
  if (!plan || plan.name !== name || plan.action !== action ||
      !['local', 'remote'].includes(plan.kind) ||
      ['changesSoftware', 'restartsService', 'requiresConfirmation'].some(key => typeof plan[key] !== 'boolean') ||
      !Array.isArray(plan.steps) || !Array.isArray(plan.warnings) || typeof plan.summary !== 'string') {
    throw new Error('后端计划不完整或目标不匹配；未发送变更。请更新 dsh-deck 后重试。');
  }
  return { name, action, kind: plan.kind, currentVersion: clean(plan.currentVersion || '未检测到'),
    targetVersion: clean(plan.targetVersion || '由后端计划确定'), nodeVersion: clean(plan.nodeVersion || '未检测到'),
    changesSoftware: plan.changesSoftware, restartsService: plan.restartsService,
    requiresConfirmation: plan.requiresConfirmation, summary: clean(plan.summary),
    steps: plan.steps.map(step => clean(stepText(step))).filter(Boolean),
    warnings: plan.warnings.map(step => clean(stepText(step))).filter(Boolean) };
}

export function stopScope(it) {
  if (it.kind === 'local') return '停止本机受管 dsh 服务；不会接管其他进程';
  return it.stopRemoteService === false
    ? '仅断开本机 SSH 隧道；保留远端 dsh 服务'
    : '断开本机 SSH 隧道，并停止远端 dsh 服务';
}

export function confirmationFor(action, instances, plans = []) {
  const lines = instances.map(it => `${displayName(it)}（标识：${it.name}）：${
    ['stop', 'restart'].includes(action) ? stopScope(it) : it.kind === 'local' ? '本机' : `远端 ${it.sshHost || it.name}`}`);
  if (['stop', 'restart'].includes(action)) lines.push('连接将中断，正在进行的会话可能中断。请先保存工作。');
  if (action === 'restart') lines.push('停止后重新启动；远端启动是否变更软件见下方计划。');
  if (action === 'remove') lines.push('只移除登记，不停止进程、不卸载软件、不删除用户数据。存在受管进程时后端会拒绝；不会自动替你停止。未保存的编辑不会生效。');
  if (action === 'install') lines.push('准备可用运行时、dsh 和所需服务定义，不自动启动服务。Node 的安装或复用范围以下方计划为准。');
  if (action === 'upgrade') lines.push('目标版本遵守固定版本配置；服务重启会中断连接或会话。不保证原子回滚。');
  return { title: `确认${ACTION_TEXT[action] || action}${instances.length > 1 ? ` ${instances.length} 个实例` : ''}？`,
    lines, plans };
}

export function requiresApproval(action, plans) {
  return ['stop', 'restart', 'install', 'upgrade', 'remove'].includes(action) ||
    plans.some(plan => plan.requiresConfirmation || plan.changesSoftware || plan.restartsService);
}

export function sshHostState(info) {
  const hosts = Array.isArray(info?.hosts) ? info.hosts : [];
  if (info?.exists === false) return { kind: 'missing', free: [], message: '未找到 SSH 配置文件。可先配置 SSH 别名，或直接填写 user@host；添加登记不会配置密钥或测试连通性。' };
  if (!hosts.length) return { kind: 'empty', free: [], message: 'SSH 配置中没有可用的具体 Host 别名（通配符不列出）。可填写已有的 SSH 地址；添加登记不会配置密钥。' };
  const free = hosts.filter(host => !host.configured);
  return { kind: free.length ? 'available' : 'configured', free,
    message: free.length ? `有 ${free.length} 个尚未添加的 SSH 别名，可输入或从建议中选择。` : '发现的 SSH 别名已全部添加。仍可填写其他已有的 SSH 地址。' };
}

export function validateAdd(values, instances = []) {
  const errors = {};
  const sshHost = String(values.sshHost || '').trim();
  const name = String(values.name || '').trim();
  const body = { sshHost };
  if (!/^[A-Za-z0-9._@:-]+$/.test(sshHost) || sshHost.startsWith('-')) errors.sshHost = '请填写 SSH 别名或 user@host，只能包含英文、数字及 . _ @ : -。';
  if (name && (!/^[A-Za-z0-9._-]+$/.test(name) || /^\.+$/.test(name) || name.startsWith('-'))) errors.name = '机器标识只能包含英文、数字及 . _ -，不能以 - 开头。中文请填入显示名称。';
  if (name && instances.some(it => it.name.toLowerCase() === name.toLowerCase())) errors.name = '此机器标识已经存在，请使用另一个标识。';
  if (name) body.name = name;
  if (String(values.displayName || '').trim()) body.displayName = String(values.displayName).trim();
  const port = String(values.port ?? '').trim();
  if (port) {
    if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535) errors.port = '端口必须是 1–65535 之间的整数。';
    else body.port = Number(port);
  }
  return { body, errors, ok: Object.keys(errors).length === 0 };
}

export function configValues(it) {
  return { displayName: it.displayName || '', description: it.description || '', workdir: it.workdir || '',
    enabled: it.enabled !== false, dshVersion: it.pinnedVersion || '',
    autoInstall: it.autoInstall !== false, stopRemoteService: it.stopRemoteService !== false };
}

export function validateConfig(values, it) {
  const errors = {};
  const body = { displayName: String(values.displayName || '').trim(), description: String(values.description || '').trim(),
    enabled: values.enabled === true, dshVersion: String(values.dshVersion || '').trim() };
  if (body.dshVersion && !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(body.dshVersion)) {
    errors.dshVersion = '请填写明确版本（如 0.1.5-rc.1），不要填写 latest 或版本范围；留空取消固定。';
  }
  if (it.kind === 'local') {
    body.workdir = String(values.workdir || '').trim();
    if (/[\0\r\n]/.test(body.workdir)) errors.workdir = '工作目录必须是单行路径。是否存在由后端校验。';
  } else {
    body.autoInstall = values.autoInstall === true;
    body.stopRemoteService = values.stopRemoteService === true;
  }
  return { body, errors, ok: Object.keys(errors).length === 0 };
}

export const FAIL_STEP = Object.freeze({
  timeout: { label: '检查连通性', cmd: host => `ping -n 2 ${host}` },
  dns: { label: '查看解析结果', cmd: host => `ssh -G ${host} | findstr hostname` },
  auth: { label: '详细认证诊断', cmd: host => `ssh -v ${host}` },
  // Inspect first; do not suggest deleting a trusted fingerprint without review.
  hostkey: { label: '查看已存指纹', cmd: host => `ssh-keygen -F ${host}` },
  refused: { label: '查看 sshd', cmd: host => `ssh ${host} "systemctl status ssh"` },
});

export function failureStep(it) {
  const host = it.sshHost || it.name || '';
  const step = FAIL_STEP[it.failCode];
  if (!step || !/^[A-Za-z0-9._@:-]+$/.test(host) || host.startsWith('-')) return null;
  return { label: step.label, command: step.cmd(host) };
}

export function installCommand(name) {
  return /^[A-Za-z0-9._-]+$/.test(name) && !name.startsWith('-') && !/^\.+$/.test(name)
    ? `.\\dsh.ps1 -Command install -Target '${name}'` : '';
}

export function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
}
