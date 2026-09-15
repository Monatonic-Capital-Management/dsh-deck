// Drive the panel's filter through CDP and assert what the DOM actually does.
//
// The pure-function tests in check-ui.js prove the matching rules; this proves
// the wiring - that typing filters the grid, that the chip narrows to instances
// that are not running, that Escape clears, and that the caret survives a
// re-render (which is why the input lives outside #list).
//
// Not part of CI: it needs a running panel and a Chrome/Edge on the machine, so
// it is a local integration check. To run it:
//
//   1. .\dsh.ps1 -Command app -NoOpen          # get the backend up
//   2. read state\app.json for port + token
//   3. chrome --headless=new --remote-debugging-port=9222 \
//        --user-data-dir=%TEMP%\cdp-prof "http://127.0.0.1:<port>/?t=<token>"
//   4. node tools\check-filter-cdp.js
//
// Node's global WebSocket (Node 22+) avoids any dependency, which matters: this
// repo promises a dependency-free toolchain.
const http = require('http');

const PORT = 9222;

function getJson(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: PORT, path }, (res) => {
      let b = '';
      res.on('data', (d) => { b += d; });
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } });
    }).on('error', reject);
  });
}

async function main() {
  const targets = await getJson('/json/list');
  const page = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (!page) { throw new Error('no page target with a debugger URL'); }

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
    }
  };
  const send = (method, params) => new Promise((resolve, reject) => {
    const n = ++id;
    pending.set(n, { resolve, reject });
    ws.send(JSON.stringify({ id: n, method, params }));
  });

  // Evaluate in the page and return the value directly.
  const evalJs = async (expr) => {
    const r = await send('Runtime.evaluate', {
      expression: expr, returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.exception?.description || 'page threw');
    }
    return r.result.value;
  };

  // The panel loads its data asynchronously; wait for cards to exist.
  for (let i = 0; i < 40; i++) {
    const n = await evalJs('document.querySelectorAll("#list .card").length');
    if (n > 0) break;
    await new Promise((r) => setTimeout(r, 500));
  }

  const results = [];
  const check = (label, got, want) => {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    results.push({ label, ok, got, want });
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${ok ? '' : ` (got ${JSON.stringify(got)}, want ${JSON.stringify(want)})`}`);
  };

  const cardCount = () => evalJs('document.querySelectorAll("#list .card").length');
  const names = () => evalJs('[...document.querySelectorAll("#list .card h3, #list .card .name")].map(e=>e.textContent.trim())');

  const total = await cardCount();
  check('all instances render with no filter', total > 1, true);

  // --- typing filters the grid -------------------------------------------------
  await evalJs(`(() => { const q = document.querySelector("#flt-q");
    q.focus(); q.value = "trade"; q.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  const filtered = await cardCount();
  check('typing "trade" narrows the grid', filtered > 0 && filtered < total, true);

  check('hits label reports the subset',
    await evalJs('document.querySelector("#flt-hits").textContent'),
    `显示 ${filtered} / ${total}`);

  // --- the caret must survive a re-render --------------------------------------
  await evalJs(`(() => { const q = document.querySelector("#flt-q");
    q.focus(); q.setSelectionRange(2, 2); })()`);
  await evalJs('render()');
  check('input keeps focus across render()',
    await evalJs('document.activeElement === document.querySelector("#flt-q")'), true);
  check('caret position is preserved',
    await evalJs('document.querySelector("#flt-q").selectionStart'), 2);

  // --- a query that matches nothing --------------------------------------------
  await evalJs(`(() => { const q = document.querySelector("#flt-q");
    q.value = "zzz-no-such-instance"; q.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  check('no match renders the filter empty state',
    await evalJs('Boolean(document.querySelector("#list .list-empty"))'), true);
  check('empty state does not claim nothing is configured',
    await evalJs('document.querySelector("#list .list-empty").textContent.includes("没有匹配")'), true);

  // --- Escape clears ------------------------------------------------------------
  await evalJs(`(() => { const q = document.querySelector("#flt-q");
    q.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); })()`);
  check('Escape restores every card', await cardCount(), total);
  check('Escape empties the input',
    await evalJs('document.querySelector("#flt-q").value'), '');

  // --- the "only problems" chip -------------------------------------------------
  const upCount = await evalJs('INSTANCES.filter(i => isUp(i.state)).length');
  await evalJs('document.querySelector("#flt-down").click()');
  check('chip is reported as pressed',
    await evalJs('document.querySelector("#flt-down").getAttribute("aria-pressed")'), 'true');
  check('chip hides the running instances', await cardCount(), total - upCount);
  await evalJs('document.querySelector("#flt-down").click()');
  check('chip toggles back off', await cardCount(), total);

  // --- the count reflects the farm, not the view --------------------------------
  await evalJs(`(() => { const q = document.querySelector("#flt-q");
    q.value = "trade"; q.dispatchEvent(new Event("input", { bubbles: true })); })()`);
  const countText = await evalJs('document.querySelector("#count").textContent');
  check('header count still reports the whole farm', countText.includes(String(total)), true);

  ws.close();
  const failed = results.filter((r) => !r.ok).length;
  console.log(`\n  ${results.length - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => { console.error('error: ' + e.message); process.exit(2); });
