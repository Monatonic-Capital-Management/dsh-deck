// CI's dependency gate, reproduced locally so it can be run before pushing.
// The backend promises to need nothing but Node builtins, which is what makes
// "clone and run" true. app/server.js grows new requires whenever a route is
// added, so this is worth running by hand as well as in CI.
const fs = require('fs');
const path = require('path');

const target = path.join(__dirname, '..', 'app', 'server.js');
const src = fs.readFileSync(target, 'utf8');
const builtins = new Set(require('module').builtinModules);
const reqs = [...src.matchAll(/require\((['"])([^'"]+)\1\)/g)].map((m) => m[2]);
const external = reqs.filter((r) => !builtins.has(r) && !r.startsWith('.'));

console.log('requires: ' + ([...new Set(reqs)].join(', ') || '(none)'));
if (external.length) {
  console.error('external dependencies found: ' + external.join(', '));
  process.exit(1);
}
console.log('ok: no external dependencies');
