// webmcp-bridge.js — Foundry's client-side artifact: registers WebMCP tools on a page
// FROM FOUNDRY'S MANIFEST OF LIVE CAPABILITIES, and nothing else.
//
// Standard: WebMCP imperative API (webmachinelearning.github.io/webmcp)
//   document.modelContext.registerTool(tool, { signal })  -> Promise<undefined>
//   document.modelContext.getTools()                       -> Promise<sequence<RegisteredTool>>
//   document.modelContext.executeTool(tool, input)         -> Promise<DOMString>
//   'toolchange' event on document.modelContext
//
// Host classes (reported to Foundry, recorded in the ledger, never conflated):
//   native   — document.modelContext provided by the browser (Chrome 149+ with
//              chrome://flags/#enable-webmcp-testing, or an origin-trial host)
//   polyfill — LOCAL-DEVELOPMENT FALLBACK ONLY, loaded from webmcp-polyfill.js when the
//              page is opened with ?polyfill=1. Execution through it is NOT evidence of
//              native WebMCP compliance and Foundry's acceptance gate refuses it.
//   none     — no document.modelContext; the page shows how to enable it.
//
// Dynamic withdrawal: every registration owns an AbortController; when a capability
// leaves the manifest (STALE / BLOCKED / WITHDRAWN) its controller is aborted, which
// unregisters the tool natively. After each sync the bridge reconciles getTools()
// against the manifest and reports whether the browser's registered set EXACTLY
// matches Foundry's LIVE state.
(function () {
  const script = document.currentScript || {};
  const APP = (script.dataset && script.dataset.app) || 'ledgerly';
  const statusEl = document.getElementById('webmcp-status');
  const toolsEl = document.getElementById('webmcp-tools');
  const params = new URLSearchParams(location.search);
  const registrations = new Map();   // name -> { controller, hash, tool }
  let foundryUrl = (script.dataset && script.dataset.foundry) || null;
  let host = 'none';
  let mc = null;
  let lastReport = null;
  let syncing = false;
  let acceptanceFor = '';   // signature of the LIVE set the last acceptance run executed against

  // Acceptance run (?acceptance=1): for every LIVE tool, look it up through the HOST's
  // getTools() and execute it through the HOST's executeTool() with the contract's
  // nominal input. The results are reported to Foundry, which grades them and refuses
  // anything not coming from a native host.
  async function runAcceptance(m, rec, want) {
    const executions = [];
    const el = document.getElementById('webmcp-acceptance');
    for (const [name, entry] of want) {
      let x = { tool: name, ok: false };
      try {
        const tools = await mc.getTools();
        const t = [...tools].find(z => z.name === name);
        if (!t) { x.reason = 'not in getTools()'; }
        else {
          // Spec: executeTool(tool, object). Some hosts accept only a JSON string for the
          // input; try the spec form first and record which encoding the host accepted.
          let out, encoding = 'object';
          try { out = await mc.executeTool(t, entry.acceptance_input || {}); }
          catch (e1) {
            encoding = 'json-string';
            out = await mc.executeTool(t, JSON.stringify(entry.acceptance_input || {}));
            x.object_form_error = e1.message;
          }
          x.input_encoding = encoding;
          const txt = typeof out === 'string' ? out : JSON.stringify(out);
          let parsed = null; try { parsed = JSON.parse(txt); } catch (e) {}
          // the bridge's execute() wraps the gateway reply as MCP content; unwrap it
          const sc = parsed && parsed.structuredContent;
          // the native round trip is complete once the host's executeTool() reached the gateway and a
          // typed answer came back; a policy refusal on the way (budget spent) is a correct outcome, not a failure
          x.native_round_trip = !!sc;
          x.gateway = sc && sc.refused ? sc.code : (sc ? 'ok' : 'no structured response');
          x.ok = !!(sc && (!sc.refused || sc.code === 'BUDGET_EXCEEDED')); x.status = sc ? sc.status : null;
          if (!x.ok) x.reason = sc && sc.refused ? sc.code + ': ' + (sc.reasons || []).join('; ') : txt.slice(0, 200);
        }
      } catch (e) { x.reason = e.message; }
      executions.push(x);
    }
    if (el) el.textContent = 'acceptance (' + host + '): ' + executions.map(x => x.tool + ' → ' + (x.ok ? 'ok ' + x.status : 'FAILED ' + x.reason)).join(' | ');
    lastReport = null;   // force a report carrying the executions
    await report(m, rec, executions);
  }

  function say(msg) { if (statusEl) statusEl.innerHTML = msg; }

  async function detectHost() {
    const native = !!(document.modelContext && typeof document.modelContext.registerTool === 'function' && !document.modelContext.__polyfill);
    if (native) { mc = document.modelContext; host = 'native'; return; }
    if (params.get('polyfill') === '1') {
      await new Promise((res, rej) => { const s = document.createElement('script'); s.src = '/webmcp-polyfill.js'; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
      if (document.modelContext && document.modelContext.__polyfill) { mc = document.modelContext; host = 'polyfill'; return; }
    }
    host = 'none';
  }

  function sessionToken() { return window.LEDGERLY_SESSION || window.FOUNDRY_SESSION || ''; }
  function agentToken() { return (script.dataset && script.dataset.token) || 'tok-agent-browser'; }

  function makeTool(entry) {
    return {
      name: entry.name,
      description: entry.description,
      inputSchema: entry.inputSchema,
      async execute(input) {
        const r = await fetch(foundryUrl + '/api/webmcp/call/' + encodeURIComponent(entry.name), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Foundry-Session': sessionToken(), 'X-Foundry-Token': agentToken(), 'X-Foundry-Host': host },
          body: JSON.stringify({ input: input || {} }),
        });
        const j = await r.json();
        if (window.ledgerlyRefresh) window.ledgerlyRefresh();
        if (j.ok) return { content: [{ type: 'text', text: JSON.stringify(j.detail) }], structuredContent: j.detail, isError: false };
        // Agent-visible refusal (MCP tool error): a typed code, the concrete reasons, and what would
        // change the outcome — so a calling agent can adapt instead of retrying blindly.
        const g = (j.detail && j.detail.guidance) || {};
        const code = j.refusal ? j.refusal.code : 'REFUSED';
        const reasons = j.refusal ? j.refusal.reasons : [];
        const text = `REFUSED ${code}: ${reasons.join('; ')}` +
          (g.next_steps ? `\nnext: ${g.next_steps.join(' | ')}` : '') +
          (g.retryable ? `\nretryable: yes${g.retry_after_seconds ? ' after ' + g.retry_after_seconds + 's' : ''}` : '\nretryable: no') +
          `\nexplain: call foundry_explain_refusal({code: "${code}", capability_id: "${g.capability_id || ''}"})`;
        return { content: [{ type: 'text', text }], isError: true,
                 structuredContent: { refused: true, code, reasons, capability_id: g.capability_id || null, state: g.state || null,
                                      retryable: !!g.retryable, retry_after_seconds: g.retry_after_seconds || null, next_steps: g.next_steps || [], usage: j.detail && j.detail.usage || null } };
      },
    };
  }

  async function registeredNames() {
    if (!mc || typeof mc.getTools !== 'function') return null;   // host cannot enumerate: reconciliation UNKNOWN
    const tools = await mc.getTools();
    return [...tools].map(t => t.name).sort();
  }

  async function reconcile(manifestNames) {
    const browserNames = await registeredNames();
    const want = manifestNames.slice().sort();
    const matches = browserNames === null ? null : JSON.stringify(browserNames) === JSON.stringify(want);
    return { browser: browserNames, manifest: want, matches };
  }

  async function report(manifest, rec, executions) {
    const body = {
      executions: executions || undefined,
      app: APP, host, native: host === 'native', user_agent: navigator.userAgent, secure_context: window.isSecureContext,
      api: { registerTool: !!(mc && mc.registerTool), getTools: !!(mc && mc.getTools), executeTool: !!(mc && mc.executeTool), toolchange: !!(mc && 'ontoolchange' in mc) },
      manifest_head: manifest.head, manifest_tools: rec.manifest, browser_tools: rec.browser, matches: rec.matches,
      page: location.href,
    };
    const key = JSON.stringify([body.host, body.manifest_tools, body.browser_tools, body.matches, !!executions]);
    if (key === lastReport) return;   // only report state changes
    lastReport = key;
    try {
      await fetch(foundryUrl + '/api/webmcp/host-report', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Foundry-Token': agentToken() }, body: JSON.stringify(body) });
    } catch (e) { /* Foundry unreachable: nothing to record */ }
  }

  function render(rec) {
    const names = [...registrations.keys()].sort();
    const label = host === 'native' ? '<b>native document.modelContext</b>'
      : host === 'polyfill' ? '<b style="color:#a33">POLYFILL document.modelContext — local development fallback, not native evidence</b>'
      : '<b style="color:#a33">document.modelContext unavailable</b> — enable chrome://flags/#enable-webmcp-testing (Chrome 149+) or open with ?polyfill=1 for local development';
    const recon = rec ? (rec.matches === null ? ' · getTools() unavailable: reconciliation UNKNOWN' : rec.matches ? ' · getTools() ⇔ Foundry LIVE set: <b>exact match</b>' : ' · <b style="color:#a33">DRIFT</b>: browser ' + JSON.stringify(rec.browser) + ' vs manifest ' + JSON.stringify(rec.manifest)) : '';
    say(`${label} · ${names.length} tool(s) registered from Foundry manifest${recon}`);
    if (toolsEl) toolsEl.textContent = names.length ? names.map(n => '• ' + n + ' — ' + registrations.get(n).tool.description).join('\n') : '(no LIVE capabilities exposed)';
  }

  async function sync() {
    if (syncing) return; syncing = true;
    try {
      if (!foundryUrl) {
        // an app page tells the bridge where Foundry is via /api/config; on the Foundry console itself the origin is Foundry
        try { const r = await fetch('/api/config'); if (!r.ok) throw new Error(r.status); foundryUrl = (await r.json()).foundry_url; }
        catch (e) { foundryUrl = location.origin; }
      }
      const m = await (await fetch(foundryUrl + '/api/webmcp/manifest?app=' + encodeURIComponent(APP))).json();
      const want = new Map((m.tools || []).map(t => [t.name, t]));
      if (!mc) { render(null); await report(m, { browser: null, manifest: [...want.keys()], matches: null }); return; }
      let changed = false;
      // withdraw: abort the controller of anything vanished or changed
      for (const [name, reg] of registrations) {
        if (!want.has(name) || want.get(name).hash !== reg.hash) {
          reg.controller.abort();          // spec: aborting the signal unregisters the tool
          registrations.delete(name); changed = true;
        }
      }
      // register new / changed
      for (const [name, entry] of want) {
        if (!registrations.has(name)) {
          const controller = new AbortController();
          const tool = makeTool(entry);
          await mc.registerTool(tool, { signal: controller.signal });
          registrations.set(name, { controller, hash: entry.hash, tool }); changed = true;
        }
      }
      // a native host's registry is updated asynchronously (registerTool resolves before
      // getTools() reflects it); settle before reconciling so reports describe a stable state
      if (changed) await new Promise(r => setTimeout(r, 400));
      const rec = await reconcile([...want.keys()]);
      render(rec);
      await report(m, rec);
      // acceptance re-runs whenever the LIVE set changes, so every promotion is also exercised natively
      const sig = JSON.stringify([...want.keys()].sort());
      if (params.get('acceptance') === '1' && want.size > 0 && rec.matches !== false && sig !== acceptanceFor) {
        acceptanceFor = sig;
        await runAcceptance(m, rec, want);
      }
    } catch (e) {
      say('bridge: ' + (foundryUrl ? 'Foundry unreachable' : 'no config') + ' (' + e.message + ')');
    } finally { syncing = false; }
  }

  window.__webmcpBridge = {
    get host() { return host; },
    sync,
    registered: () => [...registrations.keys()].sort(),
    // Acceptance harness: exercise the HOST's own registry and executor, not the bridge's bookkeeping.
    async acceptance(toolName, input) {
      if (!mc) return { host, ok: false, reason: 'no document.modelContext' };
      const tools = await mc.getTools();
      const t = [...tools].find(x => x.name === toolName);
      if (!t) return { host, ok: false, reason: 'tool not in getTools()', tools: [...tools].map(x => x.name) };
      const out = await mc.executeTool(t, input || {});
      return { host, ok: true, result: typeof out === 'string' ? out : JSON.stringify(out) };
    },
  };

  (async () => {
    await detectHost();
    if (mc && typeof mc.addEventListener === 'function') {
      mc.addEventListener('toolchange', () => { sync(); });
    }
    await sync();
    setInterval(sync, 1500);
  })();
})();
