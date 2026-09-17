// CI's dependency gate, reproduced locally so it can be run before pushing.
// The backend promises to need nothing but Node builtins, which is what makes
// "clone and run" true. app/server.js grows new requires whenever a route is
// added, so this is worth running by hand as well as in CI.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'app');
function sources(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(dir, entry.name);
    return entry.isDirectory() ? sources(file) : /\.(?:js|mjs)$/.test(entry.name) ? [file] : [];
  });
}
const files = sources(root);
const src = files.map(file => fs.readFileSync(file, 'utf8')).join('\n');
const builtins = new Set(require('module').builtinModules.map(name => name.replace(/^node:/, '')));
const reqs = [...src.matchAll(/require\((['"])([^'"]+)\1\)/g)].map(m => m[2])
  .concat([...src.matchAll(/\bfrom\s+(['"])([^'"]+)\1/g)].map(m => m[2]));
const external = reqs.filter(r => !builtins.has(r.replace(/^node:/, '')) && !r.startsWith('.'));

console.log('requires: ' + ([...new Set(reqs)].join(', ') || '(none)'));
if (external.length) {
  console.error('external dependencies found: ' + external.join(', '));
  process.exit(1);
}
console.log('ok: no external dependencies in ' + files.length + ' runtime modules');
