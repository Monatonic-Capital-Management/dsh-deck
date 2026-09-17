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
  for (const name of ['tools', 'state', 'home', 'temp']) fs.mkdirSync(path.join(fixture, name));
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
  const executable = path.join(env.WINDIR || env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe');
  const run = args => spawnSync(executable, ['-NoProfile', '-NonInteractive', '-File', tool, ...args], { cwd: fixture, env, encoding: 'utf8', timeout: 30_000 });
  assert.equal(run(['-Check']).status, 1);
  assert.deepEqual(fs.readFileSync(source), before);
  assert.deepEqual(fs.readFileSync(privateFile), privateBefore);
  assert.equal(run([]).status, 0);
  assert.deepEqual(fs.readFileSync(source), Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), before]));
  assert.deepEqual(fs.readFileSync(privateFile), privateBefore);
  assert.equal(run(['-Check']).status, 0);
});
