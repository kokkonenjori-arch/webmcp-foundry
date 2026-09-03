# The three-minute demonstration

Two browser tabs, both in a WebMCP-enabled browser (Chrome 149+ with
`chrome://flags/#enable-webmcp-testing`, or Chromium/Edge launched with
`--enable-features=WebMCPTesting,WebMCP --enable-blink-features=WebMCPTesting,WebMCP`):

* **Tab A — Ledgerly** (the human app). Its "Agent interface" panel shows the host class and the
  tools currently registered on `document.modelContext`.
* **Tab B — Foundry console → Judge flow.** Every step is one button; the acting principal is
  chosen for you; the outcome is shown as a large "moment" card; the **Browser registry** card
  mirrors Tab A's native `getTools()` live.

Press **Reset** first. Every transition below is deterministic from that state (fresh ledger,
app state re-seeded, both handlers at v1).

| t | Step (button) | What the audience sees |
|---|---------------|------------------------|
| 0:00 | Tab A: Ledgerly | An ordinary app: accounts, forms. Agent interface: native host, 0 tools. |
| 0:15 | **1 Discover** | Six candidates modelled from the page's forms. |
| 0:30 | **2 Minimize** | Naive contract REFUSED (hidden `account_id`, `include_all_accounts` agent-controlled). Minimized: **4 → 2** agent inputs; the other two become session-bound / fixed. Verified, promoted by the agent (READ is agent-promotable). Tab A gains `ledgerly_search_transactions`. |
| 0:55 | **3 Counterexample** | `apply_adjustment` (v1, no ownership check): **COUNTEREXAMPLE FOUND** — the probe debited another user's account. Evidence FAIL. Owner's promotion attempt: **BLOCKED**. |
| 1:15 | **4 Repair** | Source switched to v2 → rescan → STALE (old evidence detached) → re-verify → PASS. |
| 1:35 | **5 Authority** | `transfer_funds` (FINANCIAL) verified PASS. Agent requests promotion: **AUTHORITY_INSUFFICIENT** (and self-ratification). Member: ROLE_MISSING. Owner promotes: **LIVE**. Browser registry gains `ledgerly_transfer_funds` — natively. |
| 2:15 | **6 Source change** | `transfer_funds.jl` edited → rescan → **LIVE → STALE**. The bridge aborts the tool's controller; the Browser registry shows the tool **removed** from `document.modelContext.getTools()`. Invariant PASS. |
| 2:45 | **7 Re-qualify** | Fresh evidence PASS, owner re-promotes, the tool reappears. |
| 3:00 | close | *Agents propose. Evidence qualifies. Authority promotes.* |

Determinism notes

* Reset archives the previous ledger (never deletes) and starts a new chain; the demo's evidence
  ids are content hashes and repeat across runs.
* Steps are enabled in order; each waits for the browser report it needs (the bridge syncs every
  1.5 s) before it is marked done, so the registry card is never ahead of or behind the ledger.
* If the browser is not WebMCP-enabled the registry card says so and steps 5–7 mark the native
  observation as BLOCKED rather than pretending.
