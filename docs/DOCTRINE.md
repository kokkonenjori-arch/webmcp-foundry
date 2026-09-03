# WebMCP Foundry — doctrine and architecture

## 1. The claim

*A web application's agent interface can be treated as a derived, versioned, minimized,
effect-aware, tested, evidence-backed, authority-governed software artifact rather than an
ad-hoc collection of agent-callable functions.*

The Foundry makes this claim operational by giving every capability a typed lifecycle in
which **no proposal is a state transition**. Agents (and humans, and the system's own
minimizer) may only *propose*; deterministic gates decide; the ledger records both
acceptance and refusal.

## 2. Planes and authority

| Plane | Who | May do | May never do |
|-------|-----|--------|--------------|
| Proposal | `AGENT:*`, humans, `SYSTEM:minimizer` | propose contracts, request verification, invoke LIVE tools | change lifecycle state |
| Qualification | `SYSTEM:verifier` | produce evidence (checks + mutants) against the external oracle | promote |
| Authority | `HUMAN:*` (roles from policy) | promote, withdraw | promote without PASS evidence bound to the current fingerprint; ratify own proposals where policy demands separation |

Policy (`policy/authority.json`) is keyed by the contract's **maximum-consequence effect**:

| Effect | Min promoter | Roles | Separation |
|--------|--------------|-------|------------|
| READ | AGENT | — | no |
| WRITE_OWN | HUMAN | — | no |
| FINANCIAL | HUMAN | owner | proposer ≠ promoter |
| EXTERNAL_SEND | HUMAN | owner | proposer ≠ promoter |
| WRITE_OTHER | FORBIDDEN | | |
| DESTRUCTIVE | FORBIDDEN | | |

Separation is enforced on principal identity *and* on plane: an agent can never ratify an
agent-plane proposal (`SELF_RATIFICATION`). `SYSTEM` never promotes.

## 3. Lifecycle

```
CANDIDATE ─contract gate─▶ CONTRACTED ─verifier─▶ VERIFIED ─promotion gate─▶ LIVE
    │                           │                   │  FAILED / UNGRADED          │
    └─policy──▶ POLICY_BLOCKED  └──── rescan ──────▶ STALE ◀────── rescan ────────┘
                                                      │ (evidence detached, exposure withdrawn)
                                                      └─verifier─▶ VERIFIED ─▶ promotion again
HUMAN withdraw ─▶ WITHDRAWN (from LIVE/VERIFIED/CONTRACTED/STALE/FAILED/UNGRADED)
```

Only `LIVE` capabilities appear in the WebMCP manifest. Exposure is a pure function of
verified state: the page bridge re-syncs the manifest and registers tools on
`document.modelContext` with a per-tool `AbortController`; leaving the manifest aborts the
controller, which unregisters the tool natively. The invariant **LIVE ⇔ present in
`document.modelContext.getTools()`** (every other state ⇒ absent) is evaluated by Foundry
against the browser's own reports (`/api/webmcp/invariant`).

## 4. Contracts and minimization

A **candidate** is everything the human form exposes: every control, including hidden ones,
agent-bound and unconstrained beyond the markup. A **contract** assigns each control a
binding:

* `AGENT_BOUND` — the agent chooses, within constraints (min/max, maxLength, enum, format);
* `SESSION_BOUND` — bound from the invoking human's session (`user_id`, `default_account`);
* `FIXED_BOUND` — a constant (hidden knobs such as `include_all_accounts=0`);
* `HUMAN_ONLY` — only a human may supply it; if required, the capability is not agent-exposable.

The system's minimizer applies rules R1–R5 (`src/minimize.jl`) and records a diff. The
contract gate refuses: hidden or principal-identity controls left agent-bound
(`OVER_BROAD`), unconstrained agent fields (`UNCONSTRAINED`), required human-only inputs
(`NOT_AGENT_EXPOSABLE`), non-READ contracts without a scope (`SCOPE_UNDECLARED`), FINANCIAL
contracts without `nonnegative_balance` (`INVARIANTS_MISSING`), empty effect bounds
(`SCHEMA_INVALID`). Visible *resource selectors* (a `<select>` of accounts) deliberately
stay agent-choosable: whether the app enforces ownership is exactly what verification must
prove, and minimization must not hide it.

The WebMCP `inputSchema` is derived from the contract and contains **only** agent-bound
fields with `additionalProperties: false`.

## 5. Effects: static bound vs observed trace

The contract declares an **upper bound** of effects. The verifier snapshots the app's
authoritative state through the Foundry Oracle Protocol before and after every probe and
derives the **observed** effects from the diff:

| Observation | Effect |
|-------------|--------|
| no change | READ |
| non-balance change to a resource the actor owns | WRITE_OWN |
| any change to a resource the actor does not own, or a debit of it | WRITE_OTHER |
| any balance change | FINANCIAL (+ WRITE_OWN if own) |
| resource removed | DESTRUCTIVE |
| external hand-off counter moved | EXTERNAL_SEND, *partially observable* |

`TraceWithin(bound, observed)` must hold. A declared FINANCIAL bound covers the WRITE_OWN it
entails; nothing ever implies WRITE_OTHER. Effects the oracle cannot observe (delivery of an
email) make the check **UNGRADABLE**, never PASS.

## 6. Verification and the verdict lattice

Checks (`src/verify.jl`): `oracle_available`, `unauthenticated_refused`,
`nominal_within_bound`, `constraint_boundary`, `scope_adversarial`,
`unknown_fields_rejected`, `invariant:*` (`no_effect_on_rejection`, `hidden_not_agent`,
`conservation`, `nonnegative_balance`; an unknown invariant is UNGRADABLE — required and
unmeasurable).

Verdict precedence, strongest first: **INVALID > FAIL > UNGRADABLE > UNKNOWN >
BLOCKED > PASS**. The empty set of checks is INVALID. An unrecognised verdict token is
INVALID. Only PASS establishes.

**Mutation discipline.** Before evidence counts, the suite must demonstrate it can fail.
Must-kill mutants of the contract with a known correct outcome are run: effects
under-declared (`[READ]`), scope widened to `any` + WRITE_OTHER (policy must BLOCK),
nominal input pushed out of contract (the validator must refuse). If any survives, the
evidence is **INVALID** regardless of the base verdict. Informative mutants drop one
constraint at a time and report whether it is *load-bearing* (the app itself accepts the
out-of-contract value) or *app-redundant*.

Evidence is deterministic: its id is the hash of its content, and re-running the same
verification against the same fingerprint yields the same id.

## 7. Dependency fingerprint and staleness

Evidence binds to `Fingerprint(source, schema, policy, tests, contract)`:

* `source` — digest of the app's handler artifact, reported by the app (`/__oracle/sources`);
* `schema` — hash of the discovered form surface;
* `policy` — hash of `policy/authority.json`;
* `tests` — hash of the verifier source;
* `contract` — hash of the accepted contract.

`rescan` recomputes the fingerprint; any moved component marks the capability `STALE`: its
evidence is detached, its promotion cleared, it leaves the manifest, the gateway refuses
`NOT_LIVE`, and re-promotion requires fresh evidence *and* a fresh authority act. Old
evidence records remain in the ledger, visibly detached.

## 8. Ledger

Append-only JSON Lines, hash-chained (`hash = sha256(prev ‖ canonical(event))`). State is a
pure fold over events; `replay(path)` refuses a broken chain and must reproduce the live
state digest. Refusals (`CONTRACT_REFUSED`, `PROMOTION_REFUSED`, `INVOCATION_REFUSED`,
`POLICY_BLOCKED`) are first-class events. Invocations are recorded with the bound input and
a hash of the app's response.

## 9. The host boundary

The browser and WebMCP are external. The Foundry serves a manifest and a gateway; the target
page's bridge (`web/webmcp-bridge.js`, vendored by the app) registers tools on
`document.modelContext` per the WebMCP imperative API: `await registerTool(tool, { signal })`
with one `AbortController` per tool; leaving the manifest aborts the controller, which
unregisters the tool natively. After every sync the bridge reads the host's own `getTools()`
and reports to Foundry (`/api/webmcp/host-report`) which host class it runs on — `native`,
`polyfill` (a clearly labeled local-development fallback loaded only with `?polyfill=1`), or
`none` — together with the registered set. Foundry re-derives the expected LIVE set at
receipt and records the comparison; `host_acceptance` grades native compliance from the
ledger and **refuses** to count polyfill reports; `host_invariant` checks
`LIVE ⇔ present in getTools()` for every capability. An acceptance run (`?acceptance=1`)
additionally executes each LIVE tool through the host's `executeTool()`.

Every `execute()` crosses back into the gateway, where the agent input is re-validated
against the contract, session fields are bound, and the call is ledgered with the host class.
The Foundry exposes its own capabilities the same way (`foundry_list_capabilities`,
`foundry_get_capability`, `foundry_propose_minimized_contract`,
`foundry_request_verification`, `foundry_promote`), so the refusal of agent
self-ratification is observable *through WebMCP itself*.

The verifier likewise never calls the app in-process: every probe crosses TCP and every
observation comes from the oracle snapshot (external-oracle thinking).