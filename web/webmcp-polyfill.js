// webmcp-polyfill.js — LOCAL-DEVELOPMENT FALLBACK for browsers without WebMCP.
//
// Installs a document.modelContext with the SAME SURFACE as the WebMCP imperative API
// (registerTool with AbortSignal, getTools, executeTool, toolchange) so the bridge and
// the acceptance harness can be developed without a WebMCP-enabled browser.
//
// It is marked with __polyfill = true. Foundry records reports from it as host="polyfill"
// and its acceptance gate REFUSES to count them as native compliance. Only loaded when
// the page is opened with ?polyfill=1.
(function () {
  if (document.modelContext && !document.modelContext.__polyfill) return;   // never shadow a native implementation
  const tools = new Map();   // name -> { descriptor, registered: RegisteredTool }
  const target = new EventTarget();
  function change() { target.dispatchEvent(new Event('toolchange')); if (typeof mc.ontoolchange === 'function') mc.ontoolchange(new Event('toolchange')); }
  const mc = {
    __polyfill: true,
    ontoolchange: null,
    addEventListener: (...a) => target.addEventListener(...a),
    removeEventListener: (...a) => target.removeEventListener(...a),
    async registerTool(tool, options) {
      if (!tool || typeof tool.name !== 'string' || typeof tool.execute !== 'function') throw new TypeError('ModelContextTool requires name and execute');
      if (tools.has(tool.name)) throw new DOMException('tool already registered: ' + tool.name, 'InvalidStateError');
      const registered = Object.freeze({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema, __origin: location.origin });
      tools.set(tool.name, { descriptor: tool, registered });
      const signal = options && options.signal;
      if (signal) {
        if (signal.aborted) { tools.delete(tool.name); return; }
        signal.addEventListener('abort', () => { if (tools.get(tool.name) && tools.get(tool.name).registered === registered) { tools.delete(tool.name); change(); } }, { once: true });
      }
      change();
    },
    async getTools() { return [...tools.values()].map(t => t.registered); },
    async executeTool(registered, input) {
      const entry = [...tools.values()].find(t => t.registered === registered || t.registered.name === (registered && registered.name));
      if (!entry) throw new DOMException('unknown tool', 'NotFoundError');
      const out = await entry.descriptor.execute(input || {}, {});
      return typeof out === 'string' ? out : JSON.stringify(out);
    },
    unregisterTool(name) { if (tools.delete(name)) change(); },
    provideContext(ctx) { tools.clear(); for (const t of (ctx && ctx.tools) || []) this.registerTool(t); },
  };
  Object.defineProperty(document, 'modelContext', { value: mc, configurable: true });
})();
