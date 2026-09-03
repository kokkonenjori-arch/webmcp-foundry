// ui.js — Foundry console. Exposes lifecycle, evidence, effects, authority and
// promotion state; every button is a proposal to the API, whose gates decide.
(function () {
  const $ = s => document.querySelector(s);
  const list = $('#list'), detail = $('#detail');
  let selected = null, caps = [], showLedger = false;

  const token = () => $('#who').value;
  async function api(method, path, body) {
    const opts = { method, headers: { 'X-Foundry-Token': token() } };
    if (body) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    const r = await fetch(path, opts);
    return r.json();
  }
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const badge = st => `<span class="badge st-${st}">${st}</span>`;
  // what the BROWSER's native document.modelContext.getTools() last reported for this capability
  const browserBadge = c => !c.browser || c.browser.presence === 'unknown' ? '' :
    ` · browser: <b class="${c.browser.consistent ? 'v-PASS' : 'v-FAIL'}">${c.browser.presence}</b>${c.browser.host === 'native' ? '' : ' (' + c.browser.host + ')'}`;
  const vb = v => `<b class="v-${v}">${v}</b>`;

  async function refreshList() {
    const r = await api('GET', '/api/capabilities');
    caps = r.capabilities || [];
    list.innerHTML = caps.map(c => `
      <div class="cap ${c.id === selected ? 'sel' : ''}" data-id="${c.id}">
        <div class="t"><span class="name">${esc(c.title)}</span>${badge(c.state)}</div>
        <div class="meta">${c.action.method} ${esc(c.action.path)} · agent fields ${c.agent_fields}/${c.surface_fields}
          ${c.effects.length ? ' · ' + c.effects.join(', ') : ''}${c.evidence_verdict ? ' · evidence ' + vb(c.evidence_verdict) : ''}${browserBadge(c)}</div>
      </div>`).join('') || '<p style="color:var(--mut)">No candidates yet. Press Discover.</p>';
    list.querySelectorAll('.cap').forEach(el => el.onclick = () => { selected = el.dataset.id; showLedger = false; render(); });
  }

  function decisionHtml(d) {
    if (d.ok) return `<div class="ok">accepted${d.detail && d.detail.state ? ' → ' + d.detail.state : ''}</div>`;
    const r = d.refusal || { code: 'ERROR', reasons: [JSON.stringify(d)] };
    return `<div class="refusal"><b>REFUSED · ${esc(r.code)}</b><ul>${(r.reasons || []).map(x => `<li>${esc(x)}</li>`).join('')}</ul></div>`;
  }

  let lastDecision = '';
  async function act(path, body) {
    const d = await api('POST', path, body);
    lastDecision = decisionHtml(d);
    await refreshList(); await render();
  }

  async function render() {
    await refreshList();
    if (showLedger) return renderLedger();
    if (!selected) return;
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
        if (e.kind === 'PROMOTION_REFUSED' || e.kind === 'CONTRACT_REFUSED' || e.kind === 'POLICY_BLOCKED' || e.kind === 'INVOCATION_REFUSED') det = `<span class="v-FAIL">${esc(p.refusal.code)}</span>: ${esc(p.refusal.reasons.join('; '))}`;
        else if (e.kind === 'EVIDENCE_RECORDED') det = `verdict ${vb(p.evidence.verdict)} mutation ${p.evidence.mutation_score} · ${esc(p.evidence.id)}`;
        else if (e.kind === 'PROMOTED') det = `by ${esc(p.by)} on ${esc(p.evidence_id)} (rule ${esc(JSON.stringify(p.rule))})`;
        else if (e.kind === 'STALE') det = `${esc(p.reason)} (was ${esc(p.was || '')})`;
        else if (e.kind === 'INVOKED') det = `by ${esc(p.by)} as ${esc(p.session_user)} input ${esc(JSON.stringify(p.input))} → ${p.status}`;
        else if (e.kind === 'CONTRACT_ACCEPTED') det = `v${p.contract.version} ${esc(p.contract_hash.slice(7, 19))} agent fields ${p.minimization.agent_fields_before}→${p.minimization.agent_fields_after}`;
        else if (e.kind === 'DISCOVERED') det = `surface ${esc(p.candidate.surface_hash.slice(7, 19))}`;
        else if (e.kind === 'WITHDRAWN') det = esc(p.reason);
        return `<tr class="ledger-row"><td>${e.seq}</td><td>${esc(e.at)}</td><td>${e.kind}</td><td>${esc(e.actor)}</td><td>${esc(p.capability_id || (p.candidate && p.candidate.id) || (p.evidence && p.evidence.capability_id) || '')}</td><td>${det}</td></tr>`;
      }).join('') + '</table>';
  }

  window.F = {
    contract: (id, mode) => act(`/api/capabilities/${id}/contract`, { mode }),
    op: (id, op) => act(`/api/capabilities/${id}/${op}`, op === 'withdraw' ? { reason: 'withdrawn from console' } : {}),
  };
  $('#discover').onclick = async () => { const d = await api('POST', '/api/discover'); lastDecision = decisionHtml(d); render(); };
  $('#rescan').onclick = async () => { const d = await api('POST', '/api/rescan'); lastDecision = d.ok ? `<div class="ok">rescan: stale ${esc(JSON.stringify(d.detail.stale))}</div>` : decisionHtml(d); render(); };
  $('#ledger-btn').onclick = () => { showLedger = true; render(); };

  // ---- The Foundry exposes its OWN capabilities through WebMCP as well -------
  // (registered by web/webmcp-bridge.js with data-app="foundry"; the bridge's status
  // line is mirrored into the header so the host class is always visible)
  setInterval(() => { const st = document.getElementById('webmcp-status'); if (st) $('#webmcp-self').innerHTML = st.innerHTML; }, 1000);
  window.FOUNDRY_SESSION = '';

  render();
  setInterval(refreshList, 3000);
})();
