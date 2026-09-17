#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(file) : entry.name.endsWith('.md') ? [file] : [];
  });
}
const files = ['README.md', 'CONTRIBUTING.md'].map(file => path.join(root, file)).concat(walk(path.join(root, 'docs')));
let failures = 0;
let links = 0;
let examples = 0;
function fail(file, message) {
  failures++;
  console.error('FAIL ' + path.relative(root, file).replace(/\\/g, '/') + ': ' + message);
}
for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  for (const match of text.matchAll(/\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g)) {
    const target = match[1];
    if (/^(?:[a-z][a-z\d+.-]*:|#)/i.test(target)) continue;
    const destination = path.resolve(path.dirname(file), decodeURIComponent(target.split(/[?#]/)[0]));
    links++;
    if (!destination.startsWith(root + path.sep) || !fs.existsSync(destination)) {
      // Never echo link values: a mistaken authentication URL is not safe output.
      fail(file, 'unresolved internal link near line ' + (text.slice(0, match.index).split('\n').length));
    }
  }
  let fence = null;
  let body = [];
  const archived = file.includes(path.sep + 'archive' + path.sep);
  for (const line of text.split(/\r?\n/)) {
    const match = /^\s*(`{3,}|~{3,})([^`~]*)$/.exec(line);
    if (!fence && match) { fence = { marker: match[1][0], length: match[1].length, language: match[2].trim() }; body = []; }
    else if (fence && match && match[1][0] === fence.marker && match[1].length >= fence.length && !match[2].trim()) {
      if (!archived && fence.language === 'json') {
        examples++;
        try { JSON.parse(body.join('\n')); } catch (_) { fail(file, 'invalid JSON example'); }
      }
      fence = null;
    } else if (fence) body.push(line);
  }
  if (fence) fail(file, 'unclosed code fence');
}
const launcher = fs.readFileSync(path.join(root, 'dsh.ps1'), 'utf8');
const commands = /\[ValidateSet\(([^)]+)\)\]/.exec(launcher);
const operations = fs.readFileSync(path.join(root, 'docs', 'operations.md'), 'utf8');
if (!commands) fail(path.join(root, 'dsh.ps1'), 'command declaration not found');
else for (const command of commands[1].replace(/['"\s]/g, '').split(',')) {
  if (!operations.includes('`' + command + '`') && !operations.includes('-Command ' + command)) {
    fail(path.join(root, 'docs', 'operations.md'), 'undocumented command: ' + command);
  }
}
console.log(files.length + ' documents, ' + links + ' internal links, ' + examples + ' JSON examples; failures=' + failures);
process.exitCode = failures ? 1 : 0;
