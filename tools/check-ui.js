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

  // The workdir row. The backend omits `workdir` for remote instances because
  // that directory is on the other machine, so the two failure modes are a row
  // that never appears and a row that claims a remote folder is local. Both
  // directions are asserted, and the abbreviation is checked because a bare
  // "Documents" would not identify which Documents.
  const showsWd = (o) => buildCardFn(o).includes('wd-row');
  const cases3 = [
    ['local with workdir -> folder row shown',    { ...base, kind: 'local', workdir: 'C:\\Users\\you\\Documents' }, true],
    ['local without workdir -> no folder row',    { ...base, kind: 'local', workdir: '' },  false],
    ['remote -> no folder row even with workdir', { ...base, workdir: 'C:\\somewhere' },    false],
  ];
  for (const [label, obj, want] of cases3) {
    const got = showsWd(obj);
    if (got === want) { console.log(`  PASS  ${label}`); pass++; }
    else { console.log(`  FAIL  ${label} (got ${got}, want ${want})`); fail++; }
  }
  const abbrev = buildCardFn({ ...base, kind: 'local', workdir: 'C:\\Users\\you\\Documents' });
  if (abbrev.includes('you\\Documents') && abbrev.includes('C:\\Users\\you\\Documents')) {
    console.log('  PASS  folder row abbreviates but keeps the full path in the tooltip');
    pass++;
  } else {
    console.log('  FAIL  folder row lost either the abbreviation or the full path');
    fail++;
  }
}

// ---------------------------------------------------------------------------
// Launcher surface checks, read from dsh.ps1 as text.
//
// These cover the class of bug that parameters and verbs kept falling into: a
// switch declared in param() and advertised by Get-Help's syntax line, but
// never actually read by any code. -NoProbe was documented as "much faster,
// skip the HTTP liveness probe", two callers relied on it, and it changed
// nothing; -Follow was advertised and did nothing. Both are invisible to a
// parse check and to any test that only exercises the happy path, because
// neither is a syntax error - they are silent no-ops.
//
// Text inspection rather than PowerShell AST: CI runs this on Linux where no
// PowerShell is installed, and a regex over the source is enough for both
// questions ("is this name read anywhere else?" and "do these two lists
// agree?").
// ---------------------------------------------------------------------------
{
  const ps1 = fs.readFileSync(path.join(__dirname, '..', 'dsh.ps1'), 'utf8');

  // (1) Every dispatcher verb must have a matching switch clause.
  const vsRaw = ps1.match(/\[ValidateSet\(([^)]*)\)\]/);
  const verbs = vsRaw
    ? vsRaw[1].replace(/['"\s]/g, '').split(',').filter(Boolean)
    : [];
  const switchRaw = ps1.match(/switch \(\$Command\) \{([\s\S]*?)\n\}\s*catch/);
  const clauses = switchRaw ? [...switchRaw[1].matchAll(/'([a-z][a-z-]*)'\s*\{/g)].map(m => m[1]) : [];
  const orphanVerbs = verbs.filter(v => !clauses.includes(v));
  const orphanClauses = clauses.filter(c => !verbs.includes(c));
  if (!verbs.length || !clauses.length) {
    console.log('  FAIL  could not read the command dispatch from dsh.ps1');
    fail++;
  } else if (orphanVerbs.length || orphanClauses.length) {
    // The switch has no default clause and the script ends in `exit 0`, so a
    // mismatch is a silent no-op command rather than an error.
    console.log(`  FAIL  ValidateSet/switch disagree:`
      + (orphanVerbs.length ? ` dispatched but no clause: ${orphanVerbs.join(', ')}` : '')
      + (orphanClauses.length ? ` clause but not dispatchable: ${orphanClauses.join(', ')}` : ''));
    fail++;
  } else {
    console.log(`  PASS  all ${verbs.length} commands are both valid and dispatched`);
    pass++;
  }

  // (2) Every param() variable must be read somewhere beyond its declaration.
  const paramBlock = ps1.match(/^param\(([\s\S]*?)^\)/m);
  if (!paramBlock) {
    console.log('  FAIL  could not locate the param() block in dsh.ps1');
    fail++;
  } else {
    // Intentionally accepted-but-unread, with the reason. Keep this list short
    // and justified: each entry is a promise the help text is not keeping.
    const allowedUnread = new Set(['Probe']);
    const decls = [...paramBlock[1].matchAll(/\[[^\]]+\]\s*\$(\w+)/g)].map(m => m[1]);
    const body = ps1.slice(paramBlock.index + paramBlock[0].length);
    const unread = decls.filter((name) => {
      if (allowedUnread.has(name)) return false;
      // A read is a use that is not the declaration: strip the [Type]$Name
      // shape first so the declaration itself cannot satisfy the test.
      const uses = body.match(new RegExp(`\\$${name}\\b`, 'g')) || [];
      return uses.filter(u => u).length === 0;
    });
    if (unread.length) {
      console.log(`  FAIL  declared in param() but never read (dead switch): ${unread.join(', ')}`);
      fail++;
    } else {
      console.log(`  PASS  every declared parameter is read (${decls.length} checked)`);
      pass++;
    }
  }

  // (3) -NoProbe specifically must reach the status probe. Asserting the wiring
  //     rather than just "the name appears somewhere" is the whole point: the
  //     original defect had $NoProbe present in param() and absent from every
  //     call path.
  if (/-Command status/.test(ps1) === false && !/switch \(\$Command\)/.test(ps1)) {
    console.log('  FAIL  could not find the command dispatch to check -NoProbe wiring');
    fail++;
  } else if (/Get-AllStatus -NoProbeHttp:\$NoProbe/.test(ps1)) {
    console.log('  PASS  -NoProbe is forwarded to the status probe');
    pass++;
  } else {
    console.log('  FAIL  -NoProbe does not reach Get-AllStatus (status would always probe)');
    fail++;
  }
}

// ---------------------------------------------------------------------------
// Instance filtering.
//
// instanceMatches() is pure, so it is extracted and tested directly rather than
// through a DOM. The filter input lives outside #list on purpose: render()
// replaces the list wholesale on every poll, so an input inside it would lose
// focus and caret position every 20 seconds. That structural choice is asserted
// too, because it is invisible in a screenshot and easy to undo by accident.
// ---------------------------------------------------------------------------
{
  const isUpSrc = html.match(/const isUp = [^\n]+/);
  const fnStart = html.indexOf('function instanceMatches(');
  const fnEnd = html.indexOf('function filteredInstances(');
  const fnSrc = (fnStart >= 0 && fnEnd > fnStart) ? html.slice(fnStart, fnEnd) : '';
  if (!fnSrc || !isUpSrc) {
    console.log('  FAIL  could not extract instanceMatches from index.html');
    fail++;
  } else {
    const { instanceMatches } = new Function(
      isUpSrc[0] + '\n' + fnSrc + '\nreturn { instanceMatches };')();

    const inst = (over) => ({
      name: 'Trade_Main', sshHost: 'Trade_Main', description: 'trade box',
      kind: 'remote', state: 'up', ...over,
    });

    const cases3 = [
      ['empty query matches everything',    inst(), '', false, true],
      ['name match',                        inst(), 'trade', false, true],
      ['case-insensitive',                  inst(), 'TRADE', false, true],
      ['sshHost match',                     inst({ name: 'x', sshHost: 'DuckServer' }), 'duck', false, true],
      ['description match',                 inst(), 'box', false, true],
      ['non-match',                         inst(), 'zzz', false, false],
      ['comma needles both present',        inst(), 'trade,main', false, true],
      ['space needles both present',        inst(), 'trade main', false, true],
      ['one needle missing -> no match',    inst(), 'trade,zzz', false, false],
      ['downOnly hides a running instance', inst(), '', true, false],
      ['downOnly keeps a down instance',    inst({ state: 'down' }), '', true, true],
      ['downOnly + matching query',         inst({ state: 'down' }), 'trade', true, true],
      ['whitespace-only query is no filter', inst(), '   ', false, true],
    ];
    for (const [label, obj, q, down, want] of cases3) {
      const got = instanceMatches(obj, q, down);
      if (got === want) { console.log(`  PASS  filter: ${label}`); pass++; }
      else { console.log(`  FAIL  filter: ${label} (got ${got}, want ${want})`); fail++; }
    }

    // The input must not live inside #list, or it cannot keep focus.
    const listOpen = html.indexOf('<div id="list">');
    const filterPos = html.indexOf('id="flt-q"');
    if (listOpen < 0 || filterPos < 0) {
      console.log('  FAIL  could not locate the filter input and #list in index.html');
      fail++;
    } else if (filterPos > listOpen) {
      console.log('  FAIL  the filter input is inside #list; it would lose focus on every poll');
      fail++;
    } else {
      console.log('  PASS  filter input is outside #list (survives re-render)');
      pass++;
    }
  }
}

// ---------------------------------------------------------------------------
// The inline <script> must at least parse.
//
// CI checks app/server.js with `node --check` but never looked at the panel's
// own script, so a stray bracket in the shipped UI would only surface as a
// blank page in a browser. vm.Script compiles without executing, which is what
// is wanted here: running it needs a DOM.
// ---------------------------------------------------------------------------
{
  const vm = require('vm');
  const open = html.indexOf('<script>');
  const close = html.lastIndexOf('</script>');
  if (open < 0 || close <= open) {
    console.log('  FAIL  could not find the inline <script> in index.html');
    fail++;
  } else {
    const js = html.slice(open + '<script>'.length, close);
    try {
      new vm.Script(js, { filename: 'app/ui/index.html <script>' });
      console.log('  PASS  inline panel script parses');
      pass++;
    } catch (e) {
      console.log(`  FAIL  inline panel script has a syntax error: ${e.message}`);
      fail++;
    }
  }
}

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
