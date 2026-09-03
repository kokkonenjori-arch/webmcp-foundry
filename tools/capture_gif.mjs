// tools/capture_gif.mjs — capture the real demo from a NATIVE WebMCP Edge instance over the
// Chrome DevTools Protocol (Node ≥ 22, no packages). Produces media/frames/*.png + media/frames.json.
//
//   node tools/capture_gif.mjs            # uses local servers (http://127.0.0.1:8090 / 8091)
//
// Sequence (all against the live, working system — nothing is mocked):
//   1. launch Edge with the WebMCP features, open the Foundry console and the Ledgerly page
//   2. ensure the deterministic state "transfer_funds LIVE" via the console's Judge flow (R..5)
//   3. record two element regions ~10 fps: the console's transfer_funds detail (Foundry state)
//      and the Ledgerly "Agent interface" panel (the page's native document.modelContext registry)
//   4. after a hold, trigger the source change + rescan (the same API calls Judge-flow step 6 uses)
//      and keep recording until the tool has left the native registry, plus a hold
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const FOUNDRY = process.env.FOUNDRY || 'http://127.0.0.1:8090';
const APP = process.env.APP || 'http://127.0.0.1:8091';
const EDGE = process.env.WEBMCP_BROWSER || 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const PORT = 9333;
const OUT = 'media/frames';
mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const OWNER = 'tok-human-jori', AGENT = 'tok-agent-planner';
async function api(method, path, body, tok = AGENT) {
  const r = await fetch(FOUNDRY + path, { method, headers: { 'Content-Type': 'application/json', 'X-Foundry-Token': tok }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
}

// ------------------------------------------------------------------ minimal CDP client
class CDP {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.events = []; ws.onmessage = e => this.onmsg(JSON.parse(e.data)); }
  static async connect(url) { const ws = new WebSocket(url); await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; }); return new CDP(ws); }
  onmsg(m) { if (m.id && this.pending.has(m.id)) { const { res, rej } = this.pending.get(m.id); this.pending.delete(m.id); m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result); } }
  send(method, params = {}, sessionId) { const id = ++this.id; return new Promise((res, rej) => { this.pending.set(id, { res, rej }); this.ws.send(JSON.stringify({ id, method, params, sessionId })); }); }
}
async function tab(cdp, url, width, height) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const s = (m, p) => cdp.send(m, p, sessionId);
  await s('Page.enable'); await s('Runtime.enable');
  await s('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: false });   // 2x pixels: crisp after scaling
  await s('Page.navigate', { url });
  await sleep(2500);
  const evalJs = async expr => (await s('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result.value;
  const shot = async (sel) => {
    const r = await evalJs(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return null; const b = e.getBoundingClientRect(); return { x: b.x, y: b.y + window.scrollY, width: b.width, height: b.height }; })()`);
    if (!r) return null;
    const { data } = await s('Page.captureScreenshot', { format: 'png', clip: { ...r, scale: 1 }, captureBeyondViewport: true });
    return Buffer.from(data, 'base64');
  };
  return { s, evalJs, shot };
}

// ------------------------------------------------------------------ main
const profile = join(tmpdir(), 'webmcp-gif-' + Date.now());
const edge = spawn(EDGE, ['--enable-features=WebMCPTesting,WebMCP', '--enable-blink-features=WebMCPTesting,WebMCP', `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--window-size=1400,1000', 'about:blank'], { stdio: 'ignore' });
let wsUrl = '';
for (let i = 0; i < 60 && !wsUrl; i++) { try { wsUrl = (await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json()).webSocketDebuggerUrl; } catch { await sleep(500); } }
if (!wsUrl) { console.error('Edge did not expose the debugging port'); process.exit(1); }
const cdp = await CDP.connect(wsUrl);

// console tab (Capabilities view, transfer_funds selected, enlarged type, chrome hidden)
const con = await tab(cdp, FOUNDRY + '/', 860, 900);
await con.evalJs(`new Promise(r => { const st = document.createElement('style'); st.textContent = \`
  .actions, details, h3, #detail table, .hist, #detail > div[style*="margin-top"] { display:none !important }
  #detail { padding:16px 18px 18px !important }
  #detail h2 { font-size:36px !important; margin-bottom:8px !important; display:flex; align-items:center; gap:14px }
  #detail h2 .badge { font-size:24px !important; padding:9px 14px !important; border-radius:6px !important }
  #detail > div[style] { font-size:15px !important; margin-bottom:12px !important }
  .grid { grid-template-columns: 1fr !important; gap:12px !important }
  .grid .card:not(:nth-child(1)):not(:nth-child(4)) { display:none !important }
  .card { padding:12px 14px !important }
  .card .k { font-size:14px !important; margin-bottom:4px } .card .v { font-size:21px !important; line-height:1.4 !important; word-break:normal !important; overflow-wrap:anywhere !important }
\`; document.head.appendChild(st); r(1); })`);
// app tab (Ledgerly page; the Agent interface panel is the native registry evidence)
const app = await tab(cdp, APP + '/', 520, 1600);
await app.evalJs(`new Promise(r => { const st = document.createElement('style'); st.textContent = \`
  main { padding:0 !important; display:block !important }
  #webmcp { padding:18px 20px !important; margin:0 !important }
  #webmcp h2 { font-size:24px !important; margin-bottom:12px !important }
  #webmcp-status { font-size:21px !important; line-height:1.4 }
  #webmcp-tools { font-size:17px !important; color:#1c1c1a !important; margin-top:12px !important; line-height:1.45 }
  #webmcp-acceptance { display:none }
\`; document.head.appendChild(st); r(1); })`);

// ------------------------------------------------------------------ deterministic state: transfer_funds LIVE
const stateOf = async id => (await api('GET', '/api/capabilities')).capabilities.find(c => c.id === id).state;
const host = async () => (await api('GET', '/api/webmcp/host-status?app=ledgerly'));
const registered = async name => { const h = await host(); return !!(h.seq && h.payload.host === 'native' && (h.payload.report.browser_tools || []).includes(name)); };
if (['STALE', 'VERIFIED', 'FAILED'].includes(await stateOf('ledgerly.transfer_funds'))) {
  // re-qualify without a full reset: fresh evidence, then the owner promotes (Judge-flow step 7)
  console.log('re-qualifying transfer_funds …');
  await api('POST', '/api/capabilities/ledgerly.transfer_funds/verify', {});
  await api('POST', '/api/capabilities/ledgerly.transfer_funds/promote', {}, OWNER);
}
if (await stateOf('ledgerly.transfer_funds') !== 'LIVE') {
  console.log('preparing state via Judge flow R..5 …');
  await con.evalJs(`document.querySelector('.tab[data-view="flow"]').click(); 'ok'`);
  for (const i of [0, 1, 2, 3, 4, 5]) { console.log('  step', i); await con.evalJs(`F.step(${i}).then(() => 'done')`); }
}
for (let i = 0; i < 40 && !(await registered('ledgerly_transfer_funds')); i++) await sleep(1000);
if (!(await registered('ledgerly_transfer_funds'))) { console.error('native registry never contained ledgerly_transfer_funds'); process.exit(2); }
console.log('state ready: transfer_funds LIVE and natively registered');

// which handler version is bound right now? the "code change" must switch to the OTHER one
const view = await api('GET', '/api/capabilities/ledgerly.transfer_funds');
const bound = view.fingerprint.source;
const d2 = (await api('POST', '/api/demo/source', { name: 'transfer_funds', version: 'v2' })).detail.digest;
const d1 = (await api('POST', '/api/demo/source', { name: 'transfer_funds', version: 'v1' })).detail.digest;
const boundVersion = bound === d2 ? 'v2' : 'v1';
const targetVersion = boundVersion === 'v2' ? 'v1' : 'v2';
await api('POST', '/api/demo/source', { name: 'transfer_funds', version: boundVersion });   // restore, no rescan → no state change
console.log(`bound source is ${boundVersion}; the code change will switch to ${targetVersion}`);

// switch console to Capabilities view with transfer_funds selected
await con.evalJs(`document.querySelector('.tab[data-view="caps"]').click(); 'ok'`);
await sleep(800);
const select = () => con.evalJs(`(() => { const e = document.querySelector('.cap[data-id="ledgerly.transfer_funds"]'); if (e) e.click(); return 'ok'; })()`);
await select(); await sleep(1200);

// ------------------------------------------------------------------ record
const frames = [];
const t0 = Date.now();
let triggered = false, removedAt = 0, n = 0;
async function capture() {
  const [l, r] = await Promise.all([con.shot('#detail'), app.shot('#webmcp')]);
  if (!l || !r) return;
  const lf = `${OUT}/L${String(n).padStart(3, '0')}.png`, rf = `${OUT}/R${String(n).padStart(3, '0')}.png`;
  writeFileSync(lf, l); writeFileSync(rf, r);
  frames.push({ t: (Date.now() - t0) / 1000, left: lf, right: rf, triggered });
  n++;
}
let lastSelect = 0;
while (true) {
  const t = (Date.now() - t0) / 1000;
  if (t - lastSelect > 0.7) { select(); lastSelect = t; }   // the detail view re-renders on selection
  await capture();
  if (!triggered && t > 2.0) {
    triggered = true;
    console.log('trigger: source change (transfer_funds v2) + rescan');
    api('POST', '/api/demo/source', { name: 'transfer_funds', version: targetVersion }).then(() => api('POST', '/api/rescan', {}));
    frames[frames.length - 1].event = 'source-change';
  }
  if (triggered && !removedAt && !(await registered('ledgerly_transfer_funds')) && (await stateOf('ledgerly.transfer_funds')) === 'STALE') {
    removedAt = t; console.log('native registry lost the tool at', t.toFixed(1), 's');
  }
  if (removedAt && t - removedAt > 5.0) break;
  if (t > 40) { console.error('timeout waiting for withdrawal'); break; }
  await sleep(60);
}
writeFileSync('media/frames.json', JSON.stringify({ frames, removedAt, fps_est: frames.length / frames[frames.length - 1].t }, null, 1));
console.log(`captured ${frames.length} frames over ${frames[frames.length - 1].t.toFixed(1)} s`);
edge.kill();
process.exit(0);
