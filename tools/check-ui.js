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
  ['timeout', '192.0.2.10', /ping/],
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

// ---------------------------------------------------------------------------
// Card action gating.
//
// The deploy button was dead code for a while: it tested `dshInstalled`, which
// the backend never mapped, so the condition was always `undefined === false`
// and the button could not appear. Checking only "hidden when dsh is present"
// would have passed anyway, so both directions are asserted here.
// ---------------------------------------------------------------------------
// card() depends on a run of neighbouring helpers (shortDetail, urlRow, hintRow,
// copyCmd, updateRow). They are contiguous, so everything from shortDetail up to
// (but not including) upgrade() is taken in one slice. A lazy per-function regex
// stops at the first closing brace and silently omits card() itself -- which is
// exactly how the first attempt at this failed.
const startIdx = html.indexOf('function shortDetail(it)');
const endIdx = html.indexOf('async function upgrade(');
const blockSrc = (startIdx >= 0 && endIdx > startIdx) ? html.slice(startIdx, endIdx) : '';
// esc() lives after the slice and is used inside it.
const escSrc = html.match(/function esc\(s\) \{[\s\S]*?\n\}/);
const isUpSrc = html.match(/const isUp = [^\n]+/);
const stateSrc = html.match(/const STATE_TEXT = \{[\s\S]*?\n\};/);
if (!blockSrc || !escSrc || !isUpSrc || !stateSrc) {
  console.log('  FAIL  could not extract the card render block from index.html');
  fail++;
} else {
  // BUSY and toast are stubbed (a module-level set and a DOM side effect);
  // everything else is the shipped code, so this exercises real rendering.
  const buildCard = new Function(
    'const BUSY = new Set();\nconst toast = () => {};\n' +
    stateSrc[0] + '\n' + isUpSrc[0] + '\n' + escSrc[0] + '\n' + blockSrc +
    '\nreturn { card, hintRow, FAIL_STEP };')();
  const buildCardFn = buildCard.card;

  const base = {
    name: 'host', kind: 'remote', state: 'down', port: 3099, detail: '',
    url: '', http: 0, sshHost: 'host', description: '', enabled: true,
    remotePort: 3080, localPort: 3099, dshInstalled: true,
    dshVersion: '0.1.5-rc.1', latestVersion: '0.1.5-rc.1',
    updateAvailable: false, versionDrift: false, failCode: '', hint: '',
  };
  const offers = (o) => buildCardFn(o).includes('部署远程服务');

  const cases2 = [
    ['remote with dsh missing -> deploy offered', { ...base, dshInstalled: false }, true],
    ['remote with dsh present -> not offered',    { ...base, dshInstalled: true },  false],
    ['remote unreachable -> not offered',         { ...base, dshInstalled: false, state: 'unreachable' }, false],
    ['local instance -> not offered',             { ...base, kind: 'local', dshInstalled: false }, false],
  ];
  for (const [label, obj, want] of cases2) {
    const got = offers(obj);
    if (got === want) { console.log(`  PASS  ${label}`); pass++; }
    else { console.log(`  FAIL  ${label} (got ${got}, want ${want})`); fail++; }
  }
}

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
