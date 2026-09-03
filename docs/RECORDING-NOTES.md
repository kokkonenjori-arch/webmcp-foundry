# Recording notes (for whoever cuts the video)

Release baseline: commit `16262bd`+ on `main`; runtime frozen during recording.

## Targets (record the cloud, not localhost)

* Foundry console: https://foundry.136.111.215.133.nip.io
* Ledgerly app (the page that registers WebMCP tools): https://ledgerly.136.111.215.133.nip.io
* Stable entry page: https://kokkonenjori-arch.github.io/webmcp-foundry/
* Repository: https://github.com/kokkonenjori-arch/webmcp-foundry
* Existing submission GIF (do not overwrite): `webmcp-foundry-demo.gif`

Workstation fallback URLs are listed in the entry page's `live.json` under `fallback`; they rotate.

## Browser

Google Chrome 152 (tested) or Edge 152 (tested), launched with
`--enable-features=WebMCPTesting,WebMCP --enable-blink-features=WebMCPTesting,WebMCP`
(or `chrome://flags/#enable-webmcp-testing`). Ledgerly's "Agent interface (WebMCP)" panel must read
**native document.modelContext**; if it reads polyfill or unavailable, nothing shown is native evidence.
Use a fresh `--user-data-dir` per take so the page's one-shot state does not leak between takes.

## Deterministic states between takes

`bin/stage.sh` drives the public API only (tokens are the demo principals in `policy/principals.json`):

| command | resulting state | scene |
|---|---|---|
| `bash bin/stage.sh reset` | fresh ledger (previous archived), app re-seeded, handlers at v1, six CANDIDATEs | cold open, Discover |
| `bash bin/stage.sh search-live` | search_transactions LIVE (agent-promoted READ) | 4 → 2 minimization |
| `bash bin/stage.sh transfer-live` | + apply_adjustment repaired (VERIFIED), transfer_funds LIVE (owner-promoted) | authority, budget, STALE scene |
| `bash bin/stage.sh stale-transfer` | transfer_funds STALE, browser drops it | zombie-tool climax |
| `bash bin/stage.sh four-live` | search, add_note, apply_adjustment, transfer all LIVE | blast radius |
| `bash bin/stage.sh blast` | prints the prediction, applies the shared change, rescans: 2 STALE, 2 survive | blast radius |
| `bash bin/stage.sh requalify transfer_funds apply_adjustment` | fresh evidence + owner promotion | recovery |
| `bash bin/stage.sh status` | states, last browser report, manifest | anytime |

Or press the console's **Judge flow** buttons R…9 in order; they perform the same operations and show
the moment cards. Step timings on the cloud: verification steps take 20–40 s each (jump-cut them).

## Exact on-screen facts (verified in the current build)

* Minimization: `search_transactions` 4 controls → 2 agent-controlled (`account_id` SESSION_BOUND, `include_all_accounts` FIXED_BOUND).
* Counterexample: `apply_adjustment` v1 — probe `account_id=A2, amount_cents=-500` returns 201 and produces `FINANCIAL, WRITE_OTHER` on `account/A2`; evidence FAIL; owner promotion refused `EVIDENCE_NOT_PASS`.
* Authority: agent promotion of `transfer_funds` → `AUTHORITY_INSUFFICIENT` (reasons include self-ratification); member → `ROLE_MISSING`; owner → LIVE; Chrome's `getTools()` then contains `ledgerly_transfer_funds`.
* Budget (contract field `budget`): 10 calls/hour and 25000 `amount_cents`/hour per human session; the 11th call in an hour is refused `BUDGET_EXCEEDED`, guidance `retryable: true`, `retry_after_seconds: 3600`, `next_steps`. A native `executeTool()` that reaches Foundry and receives `BUDGET_EXCEEDED` is a completed native round trip plus an intentional policy refusal — do not narrate it as a successful execution.
* Blast radius: `/api/impact?change=source:actions/_money.jl` → "this change withdraws 2 of 4 live tools", survivors `ledgerly_search_transactions`, `ledgerly_add_note`; after the change: `apply_adjustment` and `transfer_funds` STALE, browser holds exactly the two survivors.
* Stale: `transfer_funds` LIVE → source change → rescan → STALE → the bridge aborts the tool's `AbortController` → `getTools()` no longer contains it; re-verification + owner promotion re-registers it.
* Foundry's own WebMCP tools on the console page: `foundry_list_capabilities`, `foundry_get_capability`, `foundry_propose_minimized_contract`, `foundry_request_verification`, `foundry_promote`, `foundry_explain_refusal`, `foundry_impact`.
* Host quirk to state honestly if mentioned: Chromium 152 (Chrome and Edge) rejects the spec's object form of `executeTool()` input and accepts serialized JSON; the bridge records which encoding the host accepted. This is native WebMCP integration, not a specification-conformance claim.
* Deployment: Google Cloud e2-micro, Caddy automatic HTTPS, systemd, ledger persisted on disk, reboot-tested.

## Do not

* do not record the polyfill (`?polyfill=1`) as native evidence;
* do not present generated clips as Foundry behaviour;
* do not run two takes concurrently against the same deployment (the ledger and budgets are shared);
* do not commit media or keys; `data/`, `media/frames/` are ignored.
