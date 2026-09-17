'use strict';
const { parseJson } = require('./process-runner');
const { redact } = require('./security');

function problem(statusCode, errorCode, message) {
  return Object.assign(new Error(message), { statusCode, errorCode });
}

function createOperationGate() {
  const active = new Set();
  async function run(names, action) {
    const keys = [...new Set(names.length ? names : ['*'])];
    if (active.has('*') || (keys.includes('*') && active.size) || keys.some(name => active.has(name))) {
      throw problem(409, 'BUSY', '已有相关操作正在执行，请等待结果后重试。');
    }
    for (const key of keys) active.add(key);
    try { return await action(); } finally { for (const key of keys) active.delete(key); }
  }
  return { run, isBusy: name => active.has('*') || active.has(name) };
}

function createConfigCache(load, { ttlMs = 5000, clock = Date.now } = {}) {
  let cached = null;
  let at = 0;
  let pending = null;
  let generation = 0;
  function invalidate() { cached = null; pending = null; generation++; }
  function get(force = false) {
    if (!force && cached && clock() - at < ttlMs) return Promise.resolve(cached);
    if (pending) return pending;
    const started = generation;
    let promise;
    promise = Promise.resolve().then(load).then(rows => {
      if (!Array.isArray(rows)) throw problem(502, 'INVALID_CONFIG_RESULT', '启动器未返回有效实例列表。');
      if (generation === started) { cached = rows; at = clock(); }
      return rows;
    }).finally(() => { if (pending === promise) pending = null; });
    pending = promise;
    return promise;
  }
  return { get, invalidate };
}

function mutationResult(run, name, expected) {
  const body = parseJson(run.out);
  const results = body && Array.isArray(body.results) ? body.results : [];
  const rows = body && Array.isArray(body.rows) ? body.rows : [];
  const result = results.find(row => row && row.name === name);
  const state = rows.find(row => row && row.Name === name) || null;
  const valid = body && typeof body.ok === 'boolean' && Array.isArray(body.results);
  const reported = name ? result && result.ok === true : body && body.ok === true && results.length > 0 && results.every(row => row.ok === true);
  const ok = Boolean(valid && run.ok && run.code === 0 && body.ok === true && reported && (!expected || expected(state, result)));
  const errorCode = ok ? '' : (run.errorCode || (result && result.errorCode) || (body && body.errorCode) || (valid ? 'OPERATION_FAILED' : 'INVALID_RESULT'));
  const message = redact(run.message || (result && result.message) || (body && body.message) ||
    (ok ? '操作已完成。' : valid ? '操作未达到目标状态，请查看结果并重新检查。' : '启动器返回了无效操作结果，不能确认成功。'));
  return {
    ok, code: run.code, errorCode, message, state, rows,
    results: results.map(row => ({ ...row, message: redact(row.message), errorCode: redact(row.errorCode) })),
    raw: redact(run.err || run.out), err: redact(run.err),
  };
}

module.exports = { problem, createOperationGate, createConfigCache, mutationResult };
