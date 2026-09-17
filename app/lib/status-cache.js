'use strict';

function createStatusCache({ probe, clock = Date.now, ttlMs = 45000, pollMs = 30000, trace = () => {} }) {
  let rows = null;
  let complete = false;
  let probedAt = 0;
  let attemptedAt = 0;
  let error = '';
  let inFlight = null;
  let timer = null;
  let revision = 0;
  let generation = 0;
  const revisions = new Map();
  const observed = new Map();
  const superseded = Symbol('superseded probe');
  const asRows = value => (Array.isArray(value) ? value : value ? [value] : []).filter(row => row && typeof row.Name === 'string');

  function get(force = false) {
    const now = clock();
    if (!force && rows && complete && (now - probedAt < ttlMs || (error && now - attemptedAt < pollMs))) {
      return Promise.resolve(rows);
    }
    if (inFlight) return inFlight;
    const startedRevision = revision;
    const startedGeneration = generation;
    let promise;
    promise = Promise.resolve().then(probe).then(value => {
      if (generation !== startedGeneration) return superseded;
      const prior = new Map((rows || []).map(row => [row.Name, row]));
      const next = new Map();
      const at = clock();
      for (const row of asRows(value)) {
        const newer = (revisions.get(row.Name) || 0) > startedRevision;
        next.set(row.Name, newer && prior.has(row.Name) ? prior.get(row.Name) : row);
        if (!newer && !row.StatusError) {
          const supplied = typeof row.ProbedAt === 'number' ? row.ProbedAt : Date.parse(row.ProbedAt || '');
          if (Number.isFinite(supplied) && supplied > 0) observed.set(row.Name, supplied);
          else if (!Object.prototype.hasOwnProperty.call(row, 'ProbedAt')) observed.set(row.Name, at);
        }
      }
      // A mutation can introduce a row after a probe took its configuration snapshot.
      for (const [name, row] of prior) {
        if (!next.has(name) && (revisions.get(name) || 0) > startedRevision) next.set(name, row);
      }
      rows = [...next.values()];
      for (const name of observed.keys()) if (!next.has(name)) { observed.delete(name); revisions.delete(name); }
      complete = true;
      probedAt = at;
      attemptedAt = at;
      error = '';
      trace('status refreshed (' + rows.length + ' instances)');
      return rows;
    }).catch(cause => {
      if (generation !== startedGeneration) return superseded;
      attemptedAt = clock();
      error = String(cause && cause.message || cause);
      trace('status refresh failed');
      if (rows) return rows;
      throw cause;
    }).finally(() => {
      if (inFlight === promise) inFlight = null;
    }).then(value => value === superseded ? get(true) : value);
    inFlight = promise;
    return promise;
  }

  function apply(value) {
    const incoming = asRows(value);
    if (!incoming.length) return;
    const next = new Map((rows || []).map(row => [row.Name, row]));
    const at = clock();
    revision++;
    for (const row of incoming) {
      next.set(row.Name, row);
      revisions.set(row.Name, revision);
      if (!row.StatusError) {
        const supplied = typeof row.ProbedAt === 'number' ? row.ProbedAt : Date.parse(row.ProbedAt || '');
        if (Number.isFinite(supplied) && supplied > 0) observed.set(row.Name, supplied);
        else if (!Object.prototype.hasOwnProperty.call(row, 'ProbedAt')) observed.set(row.Name, at);
      }
    }
    rows = [...next.values()];
    // One operation says nothing about freshness or completeness of the other rows.
  }

  function invalidate() { generation++; complete = false; }
  function remove(name) {
    invalidate();
    if (rows) rows = rows.filter(row => row.Name !== name);
    observed.delete(name);
    revisions.delete(name);
  }
  function start() {
    if (timer) return;
    timer = setInterval(() => { get(true).catch(() => {}); }, pollMs);
    timer.unref();
  }
  function stop() { if (timer) clearInterval(timer); timer = null; }
  function snapshot() { return { rows, complete, probedAt, attemptedAt, statusError: error }; }
  function metadata(name) {
    const row = (rows || []).find(item => item.Name === name);
    return { probedAt: observed.get(name) || 0, attemptedAt,
      statusError: error || (row && row.StatusError) || '' };
  }
  return { get, apply, invalidate, remove, start, stop, snapshot, metadata, ttlMs, pollMs };
}

module.exports = { createStatusCache };
