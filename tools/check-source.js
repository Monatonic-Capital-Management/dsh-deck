#!/usr/bin/env node
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');

test('pre-commit is read-only and never stages unstaged work', () => {
  const hook = fs.readFileSync(path.join(root, '.githooks/pre-commit'), 'utf8');
  assert.ok(hook.includes('-Check -Quiet'));
  assert.doesNotMatch(hook, /\bgit\s+add\b/);
});
test('BOM check refuses without rewriting; explicit repair excludes user directories', { skip: process.platform !== 'win32' }, t => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-source-check-'));
  t.after(() => fs.rmSync(fixture, { recursive: true, force: true }));
  for (const name of ['tools', 'state', 'home/AppData/Local', 'home/AppData/Roaming', 'temp']) fs.mkdirSync(path.join(fixture, name), { recursive: true });
  const tool = path.join(fixture, 'tools/fix-bom.ps1');
  fs.copyFileSync(path.join(root, 'tools/fix-bom.ps1'), tool);
  const source = path.join(fixture, 'dsh.ps1');
  const privateFile = path.join(fixture, 'state/user.ps1');
  fs.writeFileSync(source, '# synthetic source\nfunction Test-Fixture { return 1 }\n');
  fs.writeFileSync(privateFile, '[[synthetic unparseable user file');
  const before = fs.readFileSync(source);
  const privateBefore = fs.readFileSync(privateFile);
  const env = {};
  for (const name of ['SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT', 'OS']) if (process.env[name]) env[name] = process.env[name];
  env.USERPROFILE = path.join(fixture, 'home'); env.TEMP = env.TMP = path.join(fixture, 'temp');
  env.APPDATA = path.join(fixture, 'home/AppData/Roaming');
  env.LOCALAPPDATA = path.join(fixture, 'home/AppData/Local');
  // A clean child environment must not depend on the runner's inherited policy.
  // Force the restrictive case; the command-line policy is process-local only.
  env.PSExecutionPolicyPreference = 'Restricted';
  const executable = path.join(env.WINDIR || env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe');
  // CI has many globally installed modules. This gate needs only PS builtins,
  // not a cold scan/import of the runner's Azure/SQL and user module inventory.
  env.PSModulePath = path.join(path.dirname(executable), 'Modules');
  const expectExit = (args, expected) => {
    const started = Date.now();
    const result = spawnSync(executable, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', tool, ...args], { cwd: fixture, env, encoding: 'utf8', windowsHide: true, timeout: 30_000 });
    const known = ['ENOENT', 'EACCES', 'EPERM', 'ETIMEDOUT', 'UNKNOWN'];
    const errorCode = result.error ? (known.includes(result.error.code) ? result.error.code : 'unclassified') : 'none';
    assert.equal(result.status, expected, JSON.stringify({ phase: args.length ? 'check' : 'repair', errorCode, elapsedMs: Date.now() - started, executableFound: fs.existsSync(executable) }));
  };
  expectExit(['-Check'], 1);
  assert.deepEqual(fs.readFileSync(source), before);
  assert.deepEqual(fs.readFileSync(privateFile), privateBefore);
  expectExit([], 0);
  assert.deepEqual(fs.readFileSync(source), Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), before]));
  assert.deepEqual(fs.readFileSync(privateFile), privateBefore);
  expectExit(['-Check'], 0);
});
