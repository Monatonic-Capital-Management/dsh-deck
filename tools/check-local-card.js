// What does a real local card say when dsh is not installed?
//
// The pure-function checks in check-ui.js prove the rendering rules; this proves
// the shipped page, driven through Chrome DevTools Protocol, actually renders the
// install action and the explanatory row instead of an enabled start button.
//
// Local integration check, not part of CI (it needs a running panel and a
// browser). Usage:
//
//   pwsh -File tools/check-local-card.ps1
//
// which sets up a sandbox panel and then runs this file against it.
const http = require('http');

const PORT = Number(process.env.DSH_CDP_PORT || 9333);

function getJson(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: PORT, path }, (res) => {
      let b = '';
      res.on('data', (d) => { b += d; });
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } });
    }).on('error', reject);
  });
}

let pass = 0, fail = 0;
function check(label, ok, detail) {
  if (ok) { console.log(`  PASS  ${label}`); pass++; }
  else { console.log(`  FAIL  ${label}${detail ? '  ' + detail : ''}`); fail++; }
}

(async () => {
  const targets = await getJson('/json/list');
  const page = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (!page) throw new Error('no page target with a debugger URL');

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

  const evaluate = async (expr) => {
    const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result.value;
  };

  // Wait for the card to exist before asserting on it: the page renders, then
  // loads instances asynchronously.
  let html = '';
  for (let i = 0; i < 40; i++) {
    html = await evaluate('(document.querySelector(".card") || {}).outerHTML || ""');
    if (html) break;
    await new Promise((r) => setTimeout(r, 250));
  }

  check('a card rendered', Boolean(html), String(html).slice(0, 120));
  if (!html) { ws.close(); process.exit(1); }

  // Put the card into the state a machine with no dsh produces. These are the
  // launcher's own fields, set to the values the launcher emits (see the status
  // row's DshInstalled and Hint); everything rendered below is the shipped card.
  const forced = await evaluate(`(function(){
    const it = INSTANCES.find(function (x) { return x.kind === 'local'; });
    if (!it) return 'no local instance in INSTANCES';
    it.dshInstalled = false;
    it.dshVersion = '';
    it.hint = 'dsh 未安装。可点「安装 dsh」自动装好，或手动运行：npm i -g @deepseek-ai/dsh';
    render();
    return 'ok';
  })()`);
  check('the sandbox has a local instance to render', forced === 'ok', String(forced));

  html = await evaluate('document.querySelector(".card").outerHTML');
  const text = await evaluate('document.querySelector(".card").innerText');
  console.log('  --- the card, as the user sees it ---');
  String(text).split('\n').filter(Boolean).forEach((l) => console.log('      ' + l));

  check('the install action is offered', html.includes("act('install'"));
  check('the start action is withdrawn', !html.includes("act('start'"));
  check('the button is labelled 安装 dsh', String(text).includes('安装 dsh'));
  check('the hint row explains why', html.includes('hint-row') && String(text).includes('dsh 未安装'));
  check('the manual command is offered too', String(text).includes('npm i -g @deepseek-ai/dsh'));
  // There is nothing to upgrade without an installed version. This row used to
  // render anyway - "发现新版本 0.1.5-rc.1（当前 ?）" with an 升级 button, on a
  // machine with no dsh - which is how this check earned its keep the first time
  // it ran.
  check('no upgrade is offered for software that is not installed',
    !html.includes('update-row') && !String(text).includes('发现新版本'));

  const state = await evaluate('document.querySelector(".card").className');
  console.log(`      card class: ${state}`);

  ws.close();
  console.log(`\n  ${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('error: ' + e.message); process.exit(2); });
