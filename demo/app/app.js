// app.js — the human UI of Ledgerly. Plain fetch-based forms; nothing agent-related.
(function () {
  const SESSION = 'sess-jori';   // demo: a signed-in owner
  window.LEDGERLY_SESSION = SESSION;

  async function api(method, path, body) {
    const opts = { method, headers: { 'X-Session': SESSION } };
    if (body) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    const r = await fetch(path, opts);
    return { status: r.status, json: await r.json().catch(() => ({})) };
  }

  async function refresh() {
    const me = await api('GET', '/api/me');
    document.getElementById('me').textContent = me.json.user_id || '(none)';
    const st = await api('GET', '/api/state');
    const rows = document.getElementById('acct-rows');
    rows.innerHTML = '';
    const accts = (st.json.resources && st.json.resources.account) || {};
    Object.keys(accts).sort().forEach(id => {
      const a = accts[id];
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${a.id} · ${a.name}</td><td>${a.owner}</td><td>${(a.balance_cents / 100).toFixed(2)}</td><td>${a.notes.map(n => n.text).join(' | ')}</td>`;
      rows.appendChild(tr);
    });
  }
  window.ledgerlyRefresh = refresh;

  document.querySelectorAll('form[data-action]').forEach(form => {
    form.addEventListener('submit', async ev => {
      ev.preventDefault();
      const data = {};
      new FormData(form).forEach((v, k) => { data[k] = v; });
      form.querySelectorAll('input[type=checkbox]').forEach(cb => { if (!cb.checked) data[cb.name] = '0'; });
      const method = form.method.toUpperCase();
      let res;
      if (method === 'GET') {
        const qs = new URLSearchParams(data).toString();
        res = await api('GET', form.action.replace(location.origin, '') + '?' + qs);
      } else {
        res = await api('POST', form.action.replace(location.origin, ''), data);
      }
      form.querySelector('.out').textContent = res.status + ' ' + JSON.stringify(res.json);
      refresh();
    });
  });
  refresh();
})();
