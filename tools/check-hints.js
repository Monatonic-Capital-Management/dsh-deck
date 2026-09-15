// Exercise the panel's failure-hint command builders.
//
// These produce the exact text a user copies to a terminal, so a broken one is
// worse than no button: it costs a round trip and looks authoritative. Extracted
// from index.html rather than reimplemented, so the test cannot drift from what
// actually ships.
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(
  path.join(__dirname, '..', 'app', 'ui', 'index.html'), 'utf8');

// Pull the FAIL_STEP literal straight out of the page.
const m = html.match(/const FAIL_STEP = \{[\s\S]*?\n\};/);
if (!m) { console.error('FAIL_STEP not found in index.html'); process.exit(1); }
const FAIL_STEP = new Function(m[0] + '\nreturn FAIL_STEP;')();

const cases = [
  ['timeout', '172.26.42.63', /ping/],
  ['dns',     'no-such-host.invalid', /^ssh -G no-such-host\.invalid/],
  ['auth',    'prod', /ssh -v prod/],
  ['hostkey', 'prod', /ssh-keygen -R prod/],
  ['refused', 'prod', /systemctl status ssh/],
];

let pass = 0, fail = 0;
for (const [code, host, expect] of cases) {
  const step = FAIL_STEP[code];
  if (!step) { console.log(`  FAIL  ${code}: no entry`); fail++; continue; }
  const cmd = step.cmd(host);
  const problems = [];
  if (!cmd) problems.push('empty command');
  if (/{host}|__|\$\{/.test(cmd)) problems.push('unsubstituted placeholder');
  if (!cmd.includes(host)) problems.push(`does not mention host (${host})`);
  if (!expect.test(cmd)) problems.push(`unexpected shape: ${cmd}`);
  if (problems.length) {
    console.log(`  FAIL  ${code}: ${problems.join('; ')}  -> "${cmd}"`);
    fail++;
  } else {
    console.log(`  PASS  ${code.padEnd(8)} -> ${cmd}`);
    pass++;
  }
}

// Every code the launcher can emit should have a hint or be deliberately bare.
const launcherCodes = ['dns', 'refused', 'auth', 'hostkey', 'timeout', 'unknown'];
const missing = launcherCodes.filter((c) => c !== 'unknown' && !FAIL_STEP[c]);
if (missing.length) { console.log(`  FAIL  no builder for: ${missing.join(', ')}`); fail++; }
else { console.log('  PASS  every classifiable failure has a next step'); pass++; }

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
