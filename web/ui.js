// ui.js — Foundry console.
//   Judge flow    : the deterministic ten-step demonstration, one button per step, with a
//                   "moment" card and a live mirror of the browser's native tool registry.
//   Capabilities  : lifecycle, evidence, effects, authority, promotion, browser presence.
//   Ledger        : the hash chain, refusals included.
// Every button is a proposal to the API, whose gates decide.
(function () {
  const $ = s => document.querySelector(s);
  const list = $('#list'), detail = $('#detail'), flow = $('#flow');
  let selected = null, caps = [], view = 'flow';

  const token = () => $('#who').value;
  async function api(method, path, body, tok) {
    const opts = { method, headers: { 'X-Foundry-Token': tok || token() } };
    if (body) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    const r = await fetch(path, opts);
    return r.json();
  }
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const badge = st => `<span class="badge st-${st}">${st}</span>`;
  const vb = v => `<b class="v-${v}">${v}</b>`;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const AGENT = 'tok-agent-planner', OWNER = 'tok-human-jori', MEMBER = 'tok-human-sam';

  // ------------------------------------------------------------ header: public URLs + tabs
  async function publicUrls() {
    try { const p = await api('GET', '/api/public'); const el = $('#pub');
      el.innerHTML = (p.foundry || p.app) ? `public: console ${esc(p.foundry || '—')} · app ${esc(p.app || '—')} · <a href="${esc(p.app || 'http://127.0.0.1:8091/')}" target="_blank" style="color:var(--blue)">open Ledgerly (agent page) ↗</a>`
        : `local only · <a href="http://127.0.0.1:8091/" target="_blank" style="color:var(--blue)">open Ledgerly (agent page) ↗</a>`; } catch (e) {}
  }
  document.querySelectorAll('.tab').forEach(t => t.onclick = () => { view = t.dataset.view; document.querySelectorAll('.tab').forEach(x => x.classList.toggle('on', x === t)); render(); });
  function layout() {
    const m = document.querySelector('main');
    m.classList.toggle('flow', view === 'flow');
    flow.style.display = view === 'flow' ? 'grid' : 'none';
    list.style.display = view === 'caps' ? 'block' : 'none';
    detail.style.display = view === 'flow' ? 'none' : 'block';
    if (view === 'ledger') { list.style.display = 'none'; m.classList.add('flow'); }
  }

  // ------------------------------------------------------------ capabilities list
  const browserBadge = c => !c.browser || c.browser.presence === 'unknown' ? '' :
    ` · browser: <b class="${c.browser.consistent ? 'v-PASS' : 'v-FAIL'}">${c.browser.presence}</b>${c.browser.host === 'native' ? '' : ' (' + c.browser.host + ')'}`;
  async function refreshList() {
    const r = await api('GET', '/api/capabilities');
    caps = r.capabilities || [];
    list.innerHTML = caps.map(c => `
      <div class="cap ${c.id === selected ? 'sel' : ''}" data-id="${c.id}">
        <div class="t"><span class="name">${esc(c.title)}</span>${badge(c.state)}</div>
        <div class="meta">${c.action.method} ${esc(c.action.path)} · agent fields ${c.agent_fields}/${c.surface_fields}
          ${c.effects.length ? ' · ' + c.effects.join(', ') : ''}${c.evidence_verdict ? ' · evidence ' + vb(c.evidence_verdict) : ''}${browserBadge(c)}</div>
      </div>`).join('') || '<p style="color:var(--mut)">No candidates yet. Press Discover.</p>';
    list.querySelectorAll('.cap').forEach(el => el.onclick = () => { selected = el.dataset.id; render(); });
  }

  function decisionHtml(d) {
    if (d.ok) return `<div class="ok">accepted${d.detail && d.detail.state ? ' → ' + d.detail.state : ''}</div>`;
    const r = d.refusal || { code: 'ERROR', reasons: [JSON.stringify(d)] };
    return `<div class="refusal"><b>REFUSED · ${esc(r.code)}</b><ul>${(r.reasons || []).map(x => `<li>${esc(x)}</li>`).join('')}</ul></div>`;
  }
  let lastDecision = '';
  async function act(path, body) { const d = await api('POST', path, body); lastDecision = decisionHtml(d); await render(); }

  // ------------------------------------------------------------ capability detail
  async function renderDetail() {
    if (!selected) { detail.innerHTML = '<p style="color:var(--mut)">Select a capability, or press <b>Discover</b> to scan the app.</p>'; return; }
    const c = await api('GET', '/api/capabilities/' + selected);
    const s = c.summary, k = c.contract, ev = c.evidence;
    const auth = s.authority ? `${s.authority.min_actor}${s.authority.roles.length ? ' + role ' + s.authority.roles.join('/') : ''}${s.authority.separation ? ' · proposer ≠ promoter' : ''}` : '—';
    let h = `<h2>${esc(s.title)} ${badge(s.state)}</h2>
      <div style="color:var(--mut)">${s.action.method} ${esc(s.action.path)} · source <code>${esc(s.action.source_ref)}</code> · tool <code>${esc(s.tool)}</code></div>
      <div class="actions">
        <button onclick="F.contract('${c.id}','naive')">Propose naive contract</button>
        <button onclick="F.contract('${c.id}','minimize')">Propose minimized contract</button>
        <button onclick="F.op('${c.id}','verify')">Verify</button>
        <button class="primary" onclick="F.op('${c.id}','promote')">Promote</button>
        <button class="danger" onclick="F.op('${c.id}','withdraw')">Withdraw</button>
      </div>
      ${lastDecision}
      <div class="grid">
        <div class="card"><div class="k">Lifecycle</div><div class="v">${s.state}${c.stale_reason ? ' — ' + esc(c.stale_reason) : ''}</div></div>
        <div class="card"><div class="k">Declared effects (upper bound)</div><div class="v">${s.effects.join(', ') || '— (no contract)'}${k ? ' · scope ' + esc(k.scope) : ''}</div></div>
        <div class="card"><div class="k">Authority to promote</div><div class="v">${esc(auth)}</div></div>
        <div class="card"><div class="k">Browser (document.modelContext.getTools)</div><div class="v">${s.browser && s.browser.presence !== 'unknown' ? `${s.browser.presence} on ${s.browser.host} host · ${s.browser.consistent ? '<b class="v-PASS">consistent with lifecycle</b>' : '<b class="v-FAIL">INCONSISTENT</b>'} · report #${s.browser.report_seq}` : 'no host report yet'}</div></div>
        <div class="card"><div class="k">Promotion</div><div class="v">${s.promoted_by ? 'LIVE, promoted by ' + esc(s.promoted_by) + ' at ledger #' + c.promotion_seq : 'not promoted'}</div></div>
        <div class="card"><div class="k">Evidence</div><div class="v">${ev ? vb(ev.verdict) + ' · mutation ' + ev.mutation_score + ' · ' + esc(ev.id) : 'none'}</div></div>
        <div class="card"><div class="k">Page hints (untrusted)</div><div class="v">${esc(JSON.stringify(s.hints))}</div></div>
      </div>`;
    h += `<h3>Discovered surface (over-broad by construction)</h3><table><tr><th>control</th><th>type</th><th>origin</th><th>constraints</th></tr>` +
      c.candidate.fields.map(f => `<tr><td>${esc(f.name)}</td><td>${f.type}</td><td>${f.origin}</td><td><code>${esc(JSON.stringify(f.constraints))}</code></td></tr>`).join('') + '</table>';
    if (k) {
      h += `<h3>Contract v${k.version} <span style="color:var(--mut)">proposed by ${esc(k.proposed_by)} · ${esc(c.contract_hash.slice(0, 19))}</span></h3>
        <table><tr><th>input</th><th>binding</th><th>type</th><th>constraints</th></tr>` +
        k.inputs.map(f => `<tr><td>${esc(f.name)}</td><td><b>${f.binding}</b></td><td>${f.type}</td><td><code>${esc(JSON.stringify(f.constraints))}</code></td></tr>`).join('') + '</table>' +
        `<div style="margin-top:6px;color:var(--mut)">invariants: ${k.invariants.join(', ') || 'none'} · nominal input <code>${esc(JSON.stringify(k.nominal_input))}</code></div>` +
        `<details><summary>WebMCP inputSchema (agent-facing surface only)</summary><pre>${esc(JSON.stringify(c.input_schema, null, 1))}</pre></details>` +
        `<details><summary>Minimization diff: ${c.minimization.agent_fields_before} agent-controlled fields → ${c.minimization.agent_fields_after}</summary><table><tr><th>field</th><th>before</th><th>after</th></tr>` +
        c.minimization.rows.map(r => `<tr><td>${esc(r.field)} <span style="color:var(--mut)">(${r.origin})</span></td><td>${esc(r.before)}</td><td>${esc(r.after)}</td></tr>`).join('') + '</table></details>';
      h += `<h3>Dependency fingerprint</h3><table><tr><th>component</th><th>bound at contract</th><th>current</th></tr>` +
        ['source', 'schema', 'policy', 'tests', 'contract'].map(kk => {
          const a = c.fingerprint ? c.fingerprint[kk] : '', b = c.current_fingerprint ? c.current_fingerprint[kk] : '';
          return `<tr><td>${kk}</td><td><code>${esc(a.slice(7, 23))}</code></td><td><code class="${a === b ? '' : 'v-FAIL'}">${esc(b.slice(7, 23))}${a === b ? '' : ' ← moved'}</code></td></tr>`;
        }).join('') + '</table>';
    }
    if (ev) {
      h += `<h3>Evidence ${esc(ev.id)} · verdict ${vb(ev.verdict)} · produced by ${esc(ev.produced_by)}</h3>
        <table><tr><th>check</th><th>verdict</th><th>reason</th></tr>` +
        ev.checks.map(ch => `<tr><td>${esc(ch.name)}</td><td>${vb(ch.verdict)}</td><td>${esc(ch.reason)}${ch.probes.length ? `<details><summary>${ch.probes.length} probe(s)</summary><pre>${esc(ch.probes.map(p => `${p.label}: ${JSON.stringify(p.input)} → ${p.status} effects=${p.observed_effects.join(',')} touched=${p.touched.join(',')} ${p.note}`).join('\n'))}</pre></details>` : ''}</td></tr>`).join('') + '</table>';
      h += `<h3>Mutants (the suite must be able to fail)</h3><table><tr><th>mutant</th><th>kind</th><th>expected</th><th>outcome</th><th>note</th></tr>` +
        ev.mutants.map(m => `<tr><td>${esc(m.id)}</td><td>${m.kind}</td><td>${m.expected}</td><td>${m.kind === 'must-kill' ? (m.killed ? '<b class="v-PASS">killed</b> (' + m.outcome + ')' : '<b class="v-FAIL">SURVIVED</b>') : '<b>' + m.outcome + '</b>'}</td><td>${esc(m.note || '')}</td></tr>`).join('') + '</table>';
    }
    if (c.all_evidence && c.all_evidence.length > 1) {
      h += `<h3>All evidence for this capability</h3><table><tr><th>id</th><th>verdict</th><th>contract</th><th>fingerprint</th><th>bound?</th></tr>` +
        c.all_evidence.map(e => `<tr><td><code>${esc(e.id)}</code></td><td>${vb(e.verdict)}</td><td><code>${esc(e.contract_hash.slice(7, 19))}</code></td><td><code>${esc(e.fingerprint_hash.slice(7, 19))}</code></td><td>${e.id === c.evidence_id ? 'current' : 'detached'}</td></tr>`).join('') + '</table>';
    }
    h += `<h3>History</h3><div class="hist">${c.history.map(esc).join('<br>')}</div>`;
    h += `<details style="margin-top:12px"><summary>App source for ${esc(s.action.source_ref)}</summary><pre id="src">loading…</pre></details>`;
    detail.innerHTML = h;
    fetch('/api/source?ref=' + encodeURIComponent(s.action.source_ref)).then(r => r.text()).then(t => { const el = $('#src'); if (el) el.textContent = t; });
  }

  // ------------------------------------------------------------ ledger
  async function renderLedger() {
    const [l, v, st] = await Promise.all([api('GET', '/api/ledger'), api('GET', '/api/ledger/verify'), api('GET', '/api/status')]);
    detail.innerHTML = `<h2>Ledger</h2>
      <div class="grid">
        <div class="card"><div class="k">chain</div><div class="v">${v.chain_ok ? '<b class="v-PASS">intact</b>' : '<b class="v-FAIL">BROKEN</b>'} · ${esc(v.chain)}</div></div>
        <div class="card"><div class="k">replay from disk</div><div class="v">${v.replay_matches ? '<b class="v-PASS">digest matches live state</b>' : '<b class="v-FAIL">MISMATCH</b>'}<br>${esc(v.live_digest.slice(0, 30))}…</div></div>
        <div class="card"><div class="k">policy / verifier hashes</div><div class="v">${esc(st.policy_hash.slice(7, 23))} / ${esc(st.tests_hash.slice(7, 23))}</div></div>
      </div>
      <table><tr><th>#</th><th>at</th><th>kind</th><th>actor</th><th>subject</th><th>detail</th></tr>` +
      l.events.slice().reverse().map(e => {
        const p = e.payload; let det = '';
        if (['PROMOTION_REFUSED', 'CONTRACT_REFUSED', 'POLICY_BLOCKED', 'INVOCATION_REFUSED'].includes(e.kind)) det = `<span class="v-FAIL">${esc(p.refusal.code)}</span>: ${esc(p.refusal.reasons.join('; '))}`;
        else if (e.kind === 'EVIDENCE_RECORDED') det = `verdict ${vb(p.evidence.verdict)} mutation ${p.evidence.mutation_score} · ${esc(p.evidence.id)}`;
        else if (e.kind === 'PROMOTED') det = `by ${esc(p.by)} on ${esc(p.evidence_id)} (rule ${esc(JSON.stringify(p.rule))})`;
        else if (e.kind === 'STALE') det = `${esc(p.reason)} (was ${esc(p.was || '')})`;
        else if (e.kind === 'INVOKED') det = `by ${esc(p.by)} as ${esc(p.session_user)} via ${esc(p.host || '?')} host · input ${esc(JSON.stringify(p.input))} → ${p.status}`;
        else if (e.kind === 'CONTRACT_ACCEPTED') det = `v${p.contract.version} ${esc(p.contract_hash.slice(7, 19))} agent fields ${p.minimization.agent_fields_before}→${p.minimization.agent_fields_after}`;
        else if (e.kind === 'DISCOVERED') det = `surface ${esc(p.candidate.surface_hash.slice(7, 19))}`;
        else if (e.kind === 'WITHDRAWN') det = esc(p.reason);
        else if (e.kind === 'HOST_REPORT') det = `host <b class="host-${p.host}">${p.host}</b> · browser tools ${esc(JSON.stringify(p.report.browser_tools))} · matches ${p.matches_at_receipt}${p.report.executions ? ' · executions ' + p.report.executions.length : ''}`;
        return `<tr class="ledger-row"><td>${e.seq}</td><td>${esc(e.at)}</td><td>${e.kind}</td><td>${esc(e.actor)}</td><td>${esc(p.capability_id || (p.candidate && p.candidate.id) || (p.evidence && p.evidence.capability_id) || p.app || '')}</td><td>${det}</td></tr>`;
      }).join('') + '</table>';
  }

  // ------------------------------------------------------------ judge flow
  const S = { search: 'ledgerly.search_transactions', adj: 'ledgerly.apply_adjustment', tr: 'ledgerly.transfer_funds' };
  const steps = [
    { n: 'R', title: 'Reset to the deterministic starting point', run: stepReset },
    { n: '1', title: 'Discover — model candidate actions from the human page', run: stepDiscover },
    { n: '2', title: 'Minimize — refuse the naive contract, 4 → 2 agent inputs, verify, agent promotes READ', run: stepMinimize },
    { n: '3', title: 'Counterexample — the buggy adjustment debits another user; promotion BLOCKED', run: stepCounterexample },
    { n: '4', title: 'Repair — source change → STALE → fresh evidence PASS', run: stepRepair },
    { n: '5', title: 'Authority — agent refused, member refused, owner promotes; native tool appears', run: stepAuthority },
    { n: '6', title: 'Source change — LIVE → STALE; native tool disappears', run: stepStale },
    { n: '7', title: 'Re-qualify — fresh evidence, owner re-promotes; tool returns', run: stepRequalify },
  ];
  let stepDone = -1, running = false;
  let momentHtml = `<h2>Judge flow</h2><div class="lines">Open Ledgerly in a WebMCP-enabled browser tab (link in the header), then press Reset and run the steps in order.\nEach step waits for the browser's own getTools() report where it matters, so the registry card below is never ahead of the ledger.</div>`;

  function moment(title, big, cls, lines) { momentHtml = `<h2>${esc(title)}</h2><div class="big ${cls}">${esc(big)}</div><div class="lines">${esc(lines.join('\n'))}</div>`; renderFlow(); }
  function progress(title, lines) { momentHtml = `<h2>${esc(title)}</h2><div class="big warn">…</div><div class="lines">${esc(lines.join('\n'))}</div>`; renderFlow(); }
  const refusal = d => d.refusal ? d.refusal.code : '';
  const reasons = d => d.refusal ? d.refusal.reasons : [];

  async function hostStatus() { return api('GET', '/api/webmcp/host-status?app=ledgerly'); }
  async function waitBrowser(pred, timeout = 30) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeout * 1000) {
      const hs = await hostStatus();
      if (hs.seq && pred(hs.payload)) return hs.payload;
      await sleep(800);
    }
    return null;
  }
  const has = (p, name) => p.host === 'native' && (p.report.browser_tools || []).includes(name);

  async function stepReset() {
    progress('Reset', ['archiving the ledger, restoring v1 handlers, re-seeding the app…']);
    const d = await api('POST', '/api/demo/reset', {}, OWNER);
    if (!d.ok) throw new Error(refusal(d));
    moment('Reset', 'READY', 'ok', ['ledger archived: ' + (d.detail.archived_ledger || '(none)'), 'fresh hash chain · app handlers at v1 · app state re-seeded']);
  }
  async function stepDiscover() {
    progress('Discover', ['scanning the human page…']);
    const d = await api('POST', '/api/discover', {}, AGENT);
    const cs = d.detail.candidates;
    moment('Discover', cs.length + ' CANDIDATES', 'ok', cs.map(c => `${c.id.replace('ledgerly.', '')}  ${c.action.method} ${c.action.path}  ${c.fields.length} controls (${c.fields.filter(f => f.origin === 'hidden').length} hidden)`));
  }
  async function stepMinimize() {
    progress('Minimize', ['proposing the naive contract…']);
    const naive = await api('POST', `/api/capabilities/${S.search}/contract`, { mode: 'naive' }, AGENT);
    const min = await api('POST', `/api/capabilities/${S.search}/contract`, { mode: 'minimize' }, AGENT);
    const m = min.detail.minimization;
    progress('Minimize', ['naive REFUSED: ' + refusal(naive), `minimized accepted: ${m.agent_fields_before} → ${m.agent_fields_after} agent inputs`, 'verifying against the external oracle…']);
    const v = await api('POST', `/api/capabilities/${S.search}/verify`, {}, AGENT);
    const p = await api('POST', `/api/capabilities/${S.search}/promote`, {}, AGENT);
    const b = await waitBrowser(x => has(x, 'ledgerly_search_transactions'), 20);
    moment('Minimize', `${m.agent_fields_before} → ${m.agent_fields_after}`, 'ok', [
      'naive contract REFUSED · ' + refusal(naive) + ': ' + reasons(naive).slice(0, 2).join('; '),
      ...m.rows.map(r => `${r.field} (${r.origin}): ${r.after.split(' ')[0]}`),
      `evidence ${v.detail.evidence.verdict} · mutation score ${v.detail.evidence.mutation_score}`,
      p.ok ? 'agent promoted READ capability → LIVE (policy allows agents to promote READ)' : 'promotion refused ' + refusal(p),
      b ? '✔ browser getTools() now contains ledgerly_search_transactions (native)' : '… browser report not seen (open Ledgerly in a WebMCP-enabled tab)']);
  }
  async function stepCounterexample() {
    progress('Counterexample', ['contracting apply_adjustment (v1)…', 'probing the scope adversarially…']);
    await api('POST', `/api/capabilities/${S.adj}/contract`, { mode: 'minimize' }, AGENT);
    const v = await api('POST', `/api/capabilities/${S.adj}/verify`, {}, AGENT);
    const sc = v.detail.evidence.checks.find(c => c.name === 'scope_adversarial');
    const p = await api('POST', `/api/capabilities/${S.adj}/promote`, {}, OWNER);
    moment('Counterexample', sc.verdict === 'FAIL' ? 'COUNTEREXAMPLE FOUND' : 'no counterexample', sc.verdict === 'FAIL' ? 'fail' : 'warn', [
      'effect scope: ' + sc.verdict, sc.reason, '', 'evidence verdict: ' + v.detail.evidence.verdict,
      'owner promotion: ' + (p.ok ? 'ALLOWED (unexpected)' : 'BLOCKED · ' + refusal(p))]);
  }
  async function stepRepair() {
    progress('Repair', ['switching apply_adjustment to v2 (ownership check)…', 'rescanning dependencies…']);
    await api('POST', '/api/demo/source', { name: 'apply_adjustment', version: 'v2' }, AGENT);
    const rs = await api('POST', '/api/rescan', {}, AGENT);
    const c1 = await api('GET', `/api/capabilities/${S.adj}`);
    progress('Repair', ['rescan: ' + JSON.stringify(rs.detail.stale), 'state: ' + c1.state + ' (old evidence detached)', 're-verifying…']);
    const v = await api('POST', `/api/capabilities/${S.adj}/verify`, {}, AGENT);
    moment('Repair', v.detail.evidence.verdict, v.detail.evidence.verdict === 'PASS' ? 'ok' : 'fail', [
      'source changed → capability STALE → old FAIL evidence detached (kept in the ledger)',
      'fresh evidence against v2: ' + v.detail.evidence.verdict,
      v.detail.evidence.checks.find(c => c.name === 'scope_adversarial').reason]);
  }
  async function stepAuthority() {
    progress('Authority', ['contracting + verifying transfer_funds (FINANCIAL)…']);
    await api('POST', `/api/capabilities/${S.tr}/contract`, { mode: 'minimize' }, AGENT);
    const v = await api('POST', `/api/capabilities/${S.tr}/verify`, {}, AGENT);
    const pa = await api('POST', `/api/capabilities/${S.tr}/promote`, {}, AGENT);
    const pm = await api('POST', `/api/capabilities/${S.tr}/promote`, {}, MEMBER);
    progress('Authority', ['evidence ' + v.detail.evidence.verdict, 'AGENT promotion: ' + refusal(pa), 'MEMBER promotion: ' + refusal(pm), 'owner promoting…']);
    const po = await api('POST', `/api/capabilities/${S.tr}/promote`, {}, OWNER);
    const b = await waitBrowser(x => has(x, 'ledgerly_transfer_funds'), 30);
    moment('Authority', pa.ok ? 'AGENT PROMOTED (unexpected)' : refusal(pa), pa.ok ? 'fail' : 'ok', [
      'evidence: ' + v.detail.evidence.verdict + ' (conservation, nonnegative balance, mutation score ' + v.detail.evidence.mutation_score + ')',
      'AGENT requests promotion → ' + refusal(pa) + ': ' + reasons(pa).join('; '),
      'HUMAN member → ' + refusal(pm),
      'HUMAN owner (≠ proposer) → ' + (po.ok ? 'LIVE' : refusal(po)),
      b ? `✔ NATIVE: document.modelContext.getTools() now contains ledgerly_transfer_funds (${b.report.user_agent.split(') ').pop()})` : '… native registration not observed (is Ledgerly open in a WebMCP-enabled tab?)']);
  }
  async function stepStale() {
    progress('Source change', ['editing transfer_funds.jl (v2)…', 'rescanning…']);
    await api('POST', '/api/demo/source', { name: 'transfer_funds', version: 'v2' }, AGENT);
    const rs = await api('POST', '/api/rescan', {}, AGENT);
    const c = await api('GET', `/api/capabilities/${S.tr}`);
    progress('Source change', ['rescan: ' + JSON.stringify(rs.detail.stale), 'transfer_funds: ' + c.state, 'waiting for the browser to drop the tool…']);
    const b = await waitBrowser(x => x.host === 'native' && x.matches_at_receipt === true && !(x.report.browser_tools || []).includes('ledgerly_transfer_funds'), 30);
    const inv = await api('GET', '/api/webmcp/invariant?app=ledgerly');
    moment('Source change', 'LIVE → ' + c.state, 'warn', [
      'rescan: ' + (rs.detail.stale[S.tr] || []).join('; '),
      'exposure withdrawn from the manifest · evidence detached · gateway refuses NOT_LIVE',
      b ? '✔ NATIVE: AbortController aborted → getTools() no longer contains ledgerly_transfer_funds' : '… browser withdrawal not observed',
      'lifecycle ⇔ getTools() invariant: ' + inv.verdict + ' — ' + (inv.rows || []).map(r => `${r.tool.replace('ledgerly_', '')}=${r.state}/${r.browser}`).join(', ')]);
  }
  async function stepRequalify() {
    progress('Re-qualify', ['verifying against v2…']);
    const v = await api('POST', `/api/capabilities/${S.tr}/verify`, {}, AGENT);
    const po = await api('POST', `/api/capabilities/${S.tr}/promote`, {}, OWNER);
    const b = await waitBrowser(x => has(x, 'ledgerly_transfer_funds'), 30);
    const lv = await api('GET', '/api/ledger/verify');
    moment('Re-qualify', po.ok ? 'LIVE' : refusal(po), po.ok ? 'ok' : 'fail', [
      'fresh evidence: ' + v.detail.evidence.verdict, 'owner re-promotes → ' + (po.ok ? 'LIVE' : refusal(po)),
      b ? '✔ NATIVE: tool re-registered; getTools() contains ledgerly_transfer_funds again' : '… not observed',
      `ledger: chain ${lv.chain_ok ? 'intact' : 'BROKEN'} · replay ${lv.replay_matches ? 'reproduces the live digest' : 'MISMATCH'}`,
      '', 'Agents propose. Evidence qualifies. Authority promotes.']);
  }

  async function runStep(i) {
    if (running) return;
    running = true; steps[i].active = true; renderFlow();
    try { await steps[i].run(); stepDone = i; steps[i].ok = true; }
    catch (e) { moment(steps[i].title, 'ERROR', 'fail', [String(e.message || e)]); }
    finally { steps[i].active = false; running = false; renderFlow(); refreshList(); }
  }

  async function registryHtml() {
    const [hs, inv] = await Promise.all([hostStatus(), api('GET', '/api/webmcp/invariant?app=ledgerly')]);
    if (!hs.seq) return `<div class="card" id="registry"><div class="k">Browser registry (document.modelContext.getTools)</div><div class="v">no host report yet — open Ledgerly in a WebMCP-enabled tab</div></div>`;
    const p = hs.payload, r = p.report;
    const tools = (r.browser_tools || []);
    const rows = (inv.rows || []).map(x => `<span class="${x.browser}">${x.browser === 'present' ? '●' : '○'} ${esc(x.tool.replace('ledgerly_', ''))}</span> <span class="badge st-${x.state}">${x.state}</span>${x.consistent ? '' : ' <b class="v-FAIL">INCONSISTENT</b>'}`).join('<br>');
    return `<div class="card" id="registry"><div class="k">Browser registry — host: <b class="host-${p.host}">${p.host}</b>${p.host !== 'native' ? ' (not evidence)' : ''} · report #${hs.seq}</div>
      <div class="tools">${tools.length ? tools.map(esc).join(' · ') : '(no tools registered)'}</div>
      <div style="margin-top:8px">${rows}</div>
      <div class="v" style="margin-top:8px">lifecycle ⇔ getTools(): ${vb(inv.verdict)} · ${esc((r.user_agent || '').split(') ').pop())}</div></div>`;
  }

  async function renderFlow() {
    const reg = await registryHtml();
    flow.innerHTML = `<div>${steps.map((s, i) => `<div class="step ${s.active ? 'active' : ''}"><span class="n">${s.n}</span><span class="title">${esc(s.title)}</span>
        <span class="done">${s.ok ? '✔' : ''}</span><button class="${i === stepDone + 1 ? 'primary' : ''}" ${running || i > stepDone + 1 ? 'disabled' : ''} onclick="F.step(${i})">Run</button></div>`).join('')}
      <div style="color:var(--mut);font-size:12px;margin-top:8px">Steps unlock in order. "R" can be pressed at any time to restart.</div></div>
      <div><div id="moment">${momentHtml}</div>${reg}</div>`;
  }

  // ------------------------------------------------------------ render
  async function render() {
    layout();
    await refreshList();
    if (view === 'flow') return renderFlow();
    if (view === 'ledger') return renderLedger();
    return renderDetail();
  }
  window.F = {
    contract: (id, mode) => act(`/api/capabilities/${id}/contract`, { mode }),
    op: (id, op) => act(`/api/capabilities/${id}/${op}`, op === 'withdraw' ? { reason: 'withdrawn from console' } : {}),
    step: i => runStep(i),
  };
  $('#discover').onclick = async () => { const d = await api('POST', '/api/discover'); lastDecision = decisionHtml(d); render(); };
  $('#rescan').onclick = async () => { const d = await api('POST', '/api/rescan'); lastDecision = d.ok ? `<div class="ok">rescan: stale ${esc(JSON.stringify(d.detail.stale))}</div>` : decisionHtml(d); render(); };
  setInterval(() => { const st = document.getElementById('webmcp-status'); if (st) $('#webmcp-self').innerHTML = st.innerHTML; }, 1000);
  window.FOUNDRY_SESSION = '';
  publicUrls(); setInterval(publicUrls, 15000);
  render();
  setInterval(() => { refreshList(); if (view === 'flow' && !running) renderFlow(); }, 3000);
})();
