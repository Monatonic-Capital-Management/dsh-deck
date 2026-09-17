// Deterministic tests for the panel's status cache.
//
// These extract getStatus / applyStatusRows straight out of app/server.js and
// run them against a stubbed probe, so the three guarantees the cache exists for
// are verified by counting probes rather than by timing a live ssh handshake:
//
//   1. a read inside the TTL does not probe
//   2. concurrent cold reads collapse into ONE probe (single-flight)
//   3. a failed probe keeps the last good rows and records the error
//   4. a mutation's own result is folded in, so the next read is already correct
//
// Doing this through HTTP was not possible without a mutation: the only routes
// that force a cold read are POST /install and upgrade, and firing those at
// production hosts to test a cache would be absurd. Extracting the function also
// removes the timing noise that made the live latency check flaky the first time
// it was written.
const { createStatusCache } = require('../app/lib/status-cache');

function build() {
  const state = { probes: 0, delayMs: 0, fail: false, rowsPerProbe: 1, now: 1000 };
  const calls = { trace: [] };
  const cache = createStatusCache({
    clock: () => state.now,
    trace: message => calls.trace.push(message),
    probe: async () => {
      const n = ++state.probes;
      await new Promise(resolve => setTimeout(resolve, state.delayMs));
      if (state.fail) throw new Error('probe blew up');
      return Array.from({ length: state.rowsPerProbe }, (_, i) => ({ Name: 'inst' + i, State: 'up', Probe: n }));
    },
  });
  const api = {
    getStatus: cache.get, applyStatusRows: cache.apply, invalidate: cache.invalidate,
    metadata: cache.metadata, remove: cache.remove,
    STATUS_TTL_MS: cache.ttlMs, STATUS_POLL_MS: cache.pollMs,
    peek: () => { const s = cache.snapshot(); return { ...s, at: s.probedAt, error: s.statusError }; },
  };
  return { api, state, calls };
}

let pass = 0, fail = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`  PASS  ${label}${detail ? '  ' + detail : ''}`); pass++; }
  else { console.log(`  FAIL  ${label}  ${detail === undefined ? '' : detail}`); fail++; }
}

(async () => {
  console.log('\n=== TTL is longer than the poll interval ===');
  {
    const { api } = build();
    console.log(`  TTL=${api.STATUS_TTL_MS} ms, poll=${api.STATUS_POLL_MS} ms`);
    // If the TTL were shorter, the cache would be stale by construction: reads
    // arriving between polls would each pay for their own probe. That was the
    // original defect (15 s TTL under a 30 s poll).
    check('TTL exceeds the poll interval', api.STATUS_TTL_MS > api.STATUS_POLL_MS,
      `${api.STATUS_TTL_MS} vs ${api.STATUS_POLL_MS}`);
  }

  console.log('\n=== 1. a warm cache does not probe ===');
  {
    const { api, state } = build();
    await api.getStatus(false);            // cold: one probe
    const afterCold = state.probes;
    for (let i = 0; i < 5; i++) await api.getStatus(false);
    check('cold read probes exactly once', afterCold === 1, `got ${afterCold}`);
    check('five warm reads add no probes', state.probes === 1, `got ${state.probes}`);
  }

  console.log('\n=== 2. single-flight: concurrent cold reads share one probe ===');
  {
    const { api, state } = build();
    state.delayMs = 60; // keep the first probe in flight while the others arrive
    const results = await Promise.all([
      api.getStatus(false), api.getStatus(false), api.getStatus(false), api.getStatus(false),
    ]);
    console.log(`  4 concurrent cold reads -> ${state.probes} probe(s)`);
    check('four concurrent reads collapse into one probe', state.probes === 1, `got ${state.probes}`);
    check('every caller still received rows', results.every((r) => r.length === 1));
    // The in-flight promise must be released, or the cache would never refresh
    // again after the first call.
    await api.getStatus(true);
    check('in-flight slot is released after settling', state.probes === 2, `got ${state.probes}`);
  }

  console.log('\n=== 2b. force bypasses a fresh cache but still dedupes ===');
  {
    const { api, state } = build();
    await api.getStatus(false);
    check('setup probed once', state.probes === 1);
    await api.getStatus(true);
    check('force re-probes a warm cache', state.probes === 2, `got ${state.probes}`);
    state.delayMs = 60;
    await Promise.all([api.getStatus(true), api.getStatus(true), api.getStatus(true)]);
    check('concurrent forced reads still collapse', state.probes === 3, `got ${state.probes}`);
  }

  console.log('\n=== 3. a failed probe keeps the last good rows ===');
  {
    const { api, state } = build();
    const good = await api.getStatus(false);
    state.fail = true;
    const after = await api.getStatus(true);
    check('failed refresh still returns the previous rows',
      after.length === good.length && after[0].Name === good[0].Name);
    check('the error is recorded for the panel to surface',
      api.peek().error === 'probe blew up', JSON.stringify(api.peek().error));
    check('the failure was traced', state.probes === 2);
  }

  console.log('\n=== 3b. a failed probe with nothing cached must throw ===');
  {
    const { api, state } = build();
    state.fail = true;
    let threw = false;
    try { await api.getStatus(false); } catch (_) { threw = true; }
    // Returning [] here would render as "no instances configured", which is a
    // much worse lie than an error.
    check('cold failure throws instead of reporting an empty farm', threw);
  }

  console.log('\n=== 4. a mutation is folded into the cache ===');
  {
    const { api, state } = build();
    state.rowsPerProbe = 3;
    await api.getStatus(false);
    const probesBefore = state.probes;
    api.applyStatusRows([{ Name: 'inst1', State: 'down', Detail: 'stopped by the test' }]);
    const rows = await api.getStatus(false);
    check('folding a mutation does not trigger a probe', state.probes === probesBefore, `got ${state.probes}`);
    const inst1 = rows.find((r) => r.Name === 'inst1');
    check('the mutated row is the one served next', inst1 && inst1.State === 'down',
      JSON.stringify(inst1));
    check('the other rows are preserved', rows.length === 3, `got ${rows.length}`);
    check('mutation preserves the complete-probe metadata', api.peek().at === state.now && api.peek().error === '');
  }

  console.log('\n=== 4b. a mutation must not make a partial cache look complete ===');
  {
    // Reachable in practice: the panel is interactive while the first full probe
    // is still running (it takes seconds, one ssh handshake per remote host), so
    // a click on start/stop can fold a single row into an empty cache. Treating
    // that as a fresh view of the farm showed one instance instead of five.
    const { api, state } = build();
    api.applyStatusRows([{ Name: 'solo', State: 'up' }]);
    check('folding into an empty cache does not mark it complete',
      api.peek().complete === false, JSON.stringify(api.peek().complete));
    const rows = await api.getStatus(false);
    check('the next read still probes', state.probes === 1, `got ${state.probes}`);
    check('and the probe result wins', rows.length === 1 && rows[0].Name === 'inst0',
      JSON.stringify(rows.map((r) => r.Name)));
  }

  console.log('\n=== 4b2. the race that motivated the flag ===');
  {
    // Interleave the way the server actually does at startup: the full probe is
    // in flight when the mutation arrives.
    const { api, state } = build();
    state.delayMs = 80;
    state.rowsPerProbe = 4;
    const firstRead = api.getStatus(true);         // initial full probe, slow
    await new Promise((r) => setTimeout(r, 20));   // mutation lands mid-probe
    api.applyStatusRows([{ Name: 'inst1', State: 'down' }]);
    await firstRead;
    const rows = await api.getStatus(false);
    check('after the race the cache holds every instance, not just the mutated one',
      rows.length === 4, `got ${rows.length}: ${JSON.stringify(rows.map((r) => r.Name))}`);
    check('and the mutation is reflected in it',
      rows.find((r) => r.Name === 'inst1').State === 'down' &&
      state.probes === 1, `probes=${state.probes}`);
    check('cache is complete once a real probe has landed', api.peek().complete === true);
  }

  console.log('\n=== 4c. an empty mutation payload is ignored ===');
  {
    const { api, state } = build();
    await api.getStatus(false);
    const before = api.peek();
    api.applyStatusRows([]);
    api.applyStatusRows(null);
    api.applyStatusRows([{ noName: true }]);
    const after = api.peek();
    // Compare the values, not the array identity: applyStatusRows always builds
    // a new array, so `rows === before.rows` could never hold. The first version
    // of this check asserted identity and failed against correct code.
    check('empty or malformed payloads leave the cache untouched',
      state.probes === 1 && after.at === before.at && after.complete === true &&
      after.rows.length === before.rows.length,
      `probes=${state.probes} at=${after.at === before.at}`);
  }

  console.log('\n=== 5. failures never claim a new successful observation ===');
  {
    const { api, state } = build();
    await api.getStatus(false);
    const successAt = api.peek().at;
    state.now += 50000;
    state.fail = true;
    await api.getStatus(true);
    check('last successful timestamp is preserved', api.peek().at === successAt);
    check('last attempt advances separately', api.peek().attemptedAt === state.now);
    await api.getStatus(false);
    check('failed refreshes do not cause a request storm', state.probes === 2);
  }
  console.log('\n=== 6. partial observations and configuration invalidation ===');
  {
    const { api, state } = build();
    state.rowsPerProbe = 2;
    await api.getStatus(false);
    const otherAt = api.metadata('inst0').probedAt;
    state.now += 100;
    api.applyStatusRows([{ Name: 'inst1', State: 'down' }]);
    check('one mutation does not freshen another instance', api.metadata('inst0').probedAt === otherAt);
    check('the acted-on row has its own observation time', api.metadata('inst1').probedAt === state.now);
    state.delayMs = 20;
    const pending = api.getStatus(true);
    await new Promise(resolve => setTimeout(resolve, 5));
    api.invalidate();
    await pending;
    check('an invalidated in-flight probe is replaced', state.probes === 3);
    check('replacement completes the cache', api.peek().complete);
    state.now += api.STATUS_TTL_MS + 1;
    await api.getStatus(false);
    check('expiry triggers a fresh probe', state.probes === 4);
  }
  // HTTP preview coverage belongs to check-server.js and never discovers a live panel.

  console.log(`\n  ${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('error: ' + e.message); process.exit(2); });
