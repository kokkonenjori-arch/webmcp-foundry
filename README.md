# WebMCP Foundry

A dependency-free, pure-Julia environment for **engineering WebMCP capabilities** from
human-facing web applications.

> Agents propose. Evidence qualifies. Authority promotes.

An agent capability is treated as an engineered artifact — derived, versioned, minimized,
effect-aware, tested, evidence-backed and authority-governed — rather than as a function
exposed to agents. Unsafe, ambiguous, stale, over-broad, insufficiently tested or
insufficiently authorized capabilities are **refused with typed reasons**, never silently
published. Exposure through **native WebMCP** (`document.modelContext`) is a pure function of
verified state, and the browser's own registry is checked against that state.

```
human web action → candidate → contract → minimized agent inputs → effects + authority
      → adversarial verification → evidence → authorized promotion → live WebMCP tool
      → stale invalidation → re-verification
```

License: MIT. Standard library only (Sockets, SHA, Dates); nothing to install beyond Julia ≥ 1.10.

## Live

**Stable entry page: https://kokkonenjori-arch.github.io/webmcp-foundry/** — always links to the
currently live Foundry console and Ledgerly app (the supervisor republishes it when an origin
changes). The console's **Judge flow** tab runs the demonstration below step by step; see
[docs/DEMO-SCRIPT.md](docs/DEMO-SCRIPT.md) for the three-minute path.

## Try it locally

```bash
julia bin/foundry.jl --fresh        # Foundry console http://127.0.0.1:8090 · Ledgerly app http://127.0.0.1:8091
```

Open the **Ledgerly** page in a WebMCP-enabled browser (Chrome 149+ with
`chrome://flags/#enable-webmcp-testing`, or Chromium/Edge launched with
`--enable-features=WebMCPTesting,WebMCP --enable-blink-features=WebMCPTesting,WebMCP`, or the
ChatGPT in-app browser). The page's "Agent interface" panel names the host class it detected
(**native document.modelContext** / polyfill / unavailable) and lists the tools registered from
Foundry's manifest. In the console, press **Discover**, propose contracts, **Verify**, and
**Promote** as different principals; every refusal is shown with its typed reason, and each
capability card shows what the browser's `getTools()` last reported for it.

Without a WebMCP-enabled browser, `?polyfill=1` loads a clearly labeled local-development
polyfill. Foundry records its reports as `host=polyfill` and its acceptance gate refuses to
count them.

## Prove it

```bash
julia demo/run_demo.jl               # the ten-step demonstration, driven over HTTP, browser launched for steps 8–10
julia test/acceptance_native.jl      # native WebMCP acceptance: PASS only from a native document.modelContext
julia test/runtests.jl               # conformance suite (94 checks); --selftest proves the checker can fail
```

Both the demo and the acceptance test auto-detect Chrome/Edge (override with `WEBMCP_BROWSER`)
and launch it with the WebMCP features enabled. The verdict is computed by Foundry **from the
ledger**, from reports the page's bridge posts about the host it runs on:

| Verdict | Meaning |
|---------|---------|
| PASS | native `document.modelContext`; `getTools()` exactly equals the LIVE manifest; every `executeTool()` in the acceptance run succeeded |
| FAIL | drift between the browser's registry and Foundry's LIVE set, or a failed native execution |
| UNKNOWN | native host could not enumerate / no executions |
| BLOCKED | no native report — a polyfill or absent host is named and **not counted** |

### Tested browsers

| Browser | Version | Host | Result (against the public deployment) |
|---|---|---|---|
| **Google Chrome** | 152.0.7977.76 (stable, WebMCP testing features enabled) | native `document.modelContext` | acceptance PASS; invariant PASS; full demo: LIVE → STALE withdraws the tool natively, re-qualification re-registers it |
| **Microsoft Edge** | 152.0.4191.53 (WebMCP testing features enabled) | native `document.modelContext` | acceptance PASS; invariant PASS; full demo holds |

Both runs verified, from the ledger: native `document.modelContext` present; `registerTool()`,
`getTools()`, `executeTool()` and `toolchange` present; `getTools()` exactly equal to the LIVE
manifest; two native `executeTool()` executions succeeded; LIVE ⇔ present invariant; LIVE → STALE
caused native withdrawal; re-qualification caused re-registration. Enable the feature in Chrome
via `chrome://flags/#enable-webmcp-testing` or launch with
`--enable-features=WebMCPTesting,WebMCP --enable-blink-features=WebMCPTesting,WebMCP`.

This is **native WebMCP integration PASS**, not a claim of WebMCP specification conformance for
the browsers: one host compatibility quirk was observed and recorded in the evidence rather than
hidden. The specification's WebIDL makes the object form of `executeTool()` input normative;
both Chromium 152 builds (Chrome and Edge) rejected the object form and required serialized
JSON. The bridge tries the normative form first, falls back, and records `input_encoding` and
the host's error in the ledger.

| | `executeTool()` input |
|---|---|
| Expected by the current specification | object |
| Observed in Chromium 152 (Chrome, Edge) | object rejected, serialized JSON accepted |
| Foundry | recorded the disagreement as evidence |

## What the demonstration shows

| # | Claim | Mechanism |
|---|-------|-----------|
| 1 | discover / model candidate actions | `Discovery` scans the human page's `<form data-action>` controls; everything is agent-bound and unconstrained at discovery — over-broad by construction |
| 2 | narrow an over-broad input surface | the naive contract is **refused** (`OVER_BROAD`/`UNCONSTRAINED`); the minimized one binds hidden/identity controls to the session, fixes hidden knobs, ceilings free text: 4 agent fields → 2 |
| 3 | detect an incorrect capability | `apply_adjustment` v1 lacks an ownership check; the adversarial scope probe debits another user's account and reports a **counterexample** — verdict `FAIL` |
| 4 | block promotion using evidence | even the owner is refused: `EVIDENCE_NOT_PASS` |
| 5 | reevaluate a repaired candidate | the source digest moves → `STALE`, old evidence detached; fresh verification against v2 → `PASS` |
| 6 | prevent agent self-ratification | `transfer_funds` (FINANCIAL): agent promotion refused `AUTHORITY_INSUFFICIENT` + self-ratification, also through Foundry's own WebMCP tool `foundry_promote`; a human without the `owner` role: `ROLE_MISSING` |
| 7 | permit human promotion | owner ≠ proposer promotes → `LIVE` |
| 8 | expose via **native** WebMCP | the page bridge calls `await document.modelContext.registerTool(tool, { signal })`; the browser's `getTools()` is reported back and must equal the LIVE manifest exactly |
| 9 | use it | `document.modelContext.executeTool()` → bridge → Foundry gateway (input re-validated, session fields bound, ledgered with `host=native`) → app; forged bound fields and out-of-contract values are refused |
| 10 | dependency change → STALE → withdrawn → fresh evidence | source edit → rescan marks `STALE` → the bridge aborts that tool's `AbortController` → the browser's `getTools()` no longer contains it (observed natively) → re-promotion needs new evidence → re-qualified → re-registered |

**Lifecycle ⇔ browser invariant** (`/api/webmcp/invariant`): `LIVE ⇔ present in getTools()`;
`VERIFIED`, `CANDIDATE`, `BLOCKED`, `STALE`, `WITHDRAWN` ⇒ absent. Evaluated against the
latest native report, so the yellow STALE badge in the console corresponds to the capability
actually disappearing from the browser agent's tool set.

Also exercised: `delete_account` (DESTRUCTIVE, human-only confirm) is `NOT_AGENT_EXPOSABLE`;
`share_report` (EXTERNAL_SEND) verifies `UNGRADABLE` because delivery leaves the observable
boundary, and UNGRADABLE is not PASS; `add_note` (WRITE_OWN) cannot be promoted by an agent.
Finally the hash chain is verified and `data/ledger.jsonl` is replayed to the same digest.

## Deployment and health

Two modes, both documented in [deploy/README.md](deploy/README.md):

* **VPS with fixed hostnames** (`deploy/docker-compose.yml` + Caddy automatic HTTPS): the
  recommended permanent home.
* **Supervised tunnels from a workstation** (`bin/serve_public.sh`): keeps the Julia process and
  two HTTPS tunnels alive, restarts whatever dies, keeps the app pointed at the current public
  Foundry origin, and republishes the stable entry page. `bin/install_autostart.ps1` registers it
  at logon.

`bash bin/healthcheck.sh` probes both public origins (`/health`, manifest with CORS, app→Foundry
config consistency). Each server also answers `/health` for load balancers. On boot the Foundry
replays its ledger and refuses to start on a broken chain.

## Layout

```
src/WebMCPFoundry.jl   module assembly
src/json.jl            canonical JSON codec (sorted keys; the only form that is hashed)
src/http.jl            HTTP/1.1 server + loopback client over Sockets
src/model.jl           typed vocabulary: actors, effects, verdict lattice, bindings, lifecycle, evidence
src/ledger.jl          append-only hash-chained event ledger; state = fold(apply!, events); replay + digest
src/discovery.jl       human page → candidates (HTML form scanner; no JavaScript understanding)
src/minimize.jl        candidate → system-proposed minimized contract (R1–R5, recorded as a diff)
src/validate.jl        the gateway: agent input → bound app request (unknown/bound fields refused)
src/verify.jl          external-oracle checks, observed-effect derivation, must-kill mutants → Evidence
src/gates.jl           contract gate, policy block, promotion gate (authority + separation), staleness
src/foundry.jl         gated operations; WebMCP manifest + gateway; host reports, acceptance, invariant
src/server.jl          JSON API, console UI, CORS
web/webmcp-bridge.js   Foundry's client artifact: document.modelContext registration with AbortControllers,
                       getTools() reconciliation, toolchange listener, host reports, acceptance run
web/webmcp-polyfill.js LOCAL-DEVELOPMENT fallback (?polyfill=1); never counted as native evidence
web/                   console: lifecycle, evidence, effects, authority, promotion, browser presence, ledger
policy/                effect class → required promoter (min actor, roles, separation); contract rules; demo principals
demo/app/              Ledgerly: forms, hot-reloadable action sources (v1/v2), oracle protocol
demo/run_demo.jl       the ten-step demonstration (HTTP client + native browser)
test/                  conformance suite, native acceptance
docs/DOCTRINE.md       the rules, their sources, and what they refuse
```

## Non-goals

Understanding arbitrary JavaScript, universal web-app safety, automatic correctness, generic
MCP-server generation, workflow orchestration, opaque risk scoring. Discovery reads what a
human can do on the page; verification proves only what the oracle can observe; everything
else is reported as UNKNOWN or UNGRADABLE.
