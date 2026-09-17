'use strict';
const path = require('path');
const { spawn: nativeSpawn } = require('child_process');
const { StringDecoder } = require('string_decoder');

function parseJson(raw) {
  const text = String(raw || '').replace(/^\uFEFF/, '').trim();
  if (!text) return null;
  try { return JSON.parse(text); } catch (_) { return null; }
}

function createProcessRunner({ launcherDir, spawn = nativeSpawn, killTree, trace = () => {}, drainMs = 400, maxBytes = 2 * 1024 * 1024 }) {
  function terminate(child) {
    if (killTree) return Promise.resolve(killTree(child));
    if (!child.pid) return Promise.resolve(false);
    if (process.platform !== 'win32') {
      try { return Promise.resolve(child.kill('SIGKILL')); } catch (_) { return Promise.resolve(false); }
    }
    return new Promise(resolve => {
      const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      killer.once('error', () => resolve(false));
      killer.once('close', code => resolve(code === 0));
    });
  }

  return function run(args, timeoutMs = 300000) {
    const commandIndex = args.indexOf('-Command');
    trace('launcher ' + (commandIndex >= 0 ? args[commandIndex + 1] : 'command'));
    return new Promise(resolve => {
      let child;
      let out = '';
      let err = '';
      let count = 0;
      let settled = false;
      let aborting = false;
      let timer;
      const decoders = { out: new StringDecoder('utf8'), err: new StringDecoder('utf8') };
      function finish(code, errorCode = '', message = '') {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        out += decoders.out.end(); err += decoders.err.end();
        resolve({ ok: code === 0 && !errorCode, code, out, err, errorCode, message });
      }
      async function abort(errorCode) {
        if (settled || aborting) return;
        aborting = true;
        const stopped = await terminate(child).catch(() => false);
        const reason = errorCode === 'TIMEOUT' ? '操作超时' : '命令输出超过安全上限';
        finish(-1, errorCode, reason + (stopped ? '，本机命令进程树已终止。' : '，本机命令进程清理未确认。') + '远端动作可能已生效，请重新检查实例状态。');
      }
      function append(kind, chunk) {
        if (settled || aborting) return;
        const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        count += bytes.length;
        if (count > maxBytes) { void abort('OUTPUT_LIMIT'); return; }
        if (kind === 'out') out += decoders.out.write(bytes); else err += decoders.err.write(bytes);
      }
      try {
        child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(launcherDir, 'dsh.ps1'), ...args],
          { cwd: launcherDir, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      } catch (_) { finish(-1, 'LAUNCH_FAILED', '无法启动 PowerShell。'); return; }
      timer = setTimeout(() => { void abort('TIMEOUT'); }, timeoutMs);
      child.stdout.on('data', chunk => append('out', chunk));
      child.stderr.on('data', chunk => append('err', chunk));
      child.on('error', () => { if (!aborting) finish(-1, 'LAUNCH_FAILED', '无法启动 PowerShell。'); });
      child.on('exit', code => { if (!aborting) setTimeout(() => { if (!aborting) finish(code); }, drainMs); });
      child.on('close', code => { if (!aborting) finish(code); });
    });
  };
}

module.exports = { createProcessRunner, parseJson };
