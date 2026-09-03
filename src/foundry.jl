# foundry.jl — the Foundry: operations over the store, all gated.
#
# Authority model:
#   AGENT   proposes (contracts), requests verification, invokes LIVE tools.
#   SYSTEM  discovers, minimizes, verifies, detects staleness. It never promotes.
#   HUMAN   promotes / withdraws (subject to policy roles + separation).
# Every operation returns a Decision and leaves a ledger trace (accept or refuse).

module FoundryCore

using Dates
import ..JSON: json, canonical, parse_json
import ..Http
import ..Model
import ..Model: Principal, Actor, HUMAN, AGENT, SYSTEM, Candidate, Contract, Capability, Evidence, Fingerprint,
                Decision, Refusal, CapState, CANDIDATE, CONTRACTED, VERIFIED, FAILED, UNGRADED, POLICY_BLOCKED,
                LIVE, STALE, WITHDRAWN, PASS, to_dict, from_dict, contract_hash, fingerprint_hash, sha,
                AGENT_BOUND, effect_rank
import ..Ledger
import ..Ledger: Store, commit!
import ..Discovery: discover_forms
import ..Minimize: minimize, naive_contract, minimization_diff
import ..Validate: bind_input, input_schema
import ..Verify
import ..Verify: Target, verify_capability, TESTS_HASH
import ..Gates: contract_gate, policy_block, promotion_gate, required_authority, staleness

export Foundry, principal_from_token, discover!, propose_contract!, verify!, promote!, withdraw!, rescan!,
       manifest, invoke!, capability_view, status, policy_hash, current_fingerprint, anonymous,
       host_report!, host_acceptance, latest_host_report, host_invariant

mutable struct Foundry
    root::String
    store::Store
    policy::Dict{String,Any}
    policy_bytes::Vector{UInt8}
    principals::Dict{String,Any}
    app_id::String
    app_host::String
    app_port::Int
    app_page::String
    verify_session::String
    lock::ReentrantLock
    last_scan::Dict{String,Any}
end

function Foundry(root::String; store::Store, app_id="ledgerly", app_host="127.0.0.1", app_port=8091,
                 app_page="/", verify_session="sess-jori")
    pbytes = read(joinpath(root, "policy", "authority.json"))
    policy = Dict{String,Any}(parse_json(String(copy(pbytes))))
    principals = Dict{String,Any}(parse_json(read(joinpath(root, "policy", "principals.json"), String)))
    Foundry(root, store, policy, pbytes, principals, app_id, app_host, app_port, app_page, verify_session,
            ReentrantLock(), Dict{String,Any}())
end

policy_hash(f::Foundry) = sha(f.policy_bytes)
pid(p::Principal) = "$(p.kind):$(p.id)"
const anonymous = Principal(AGENT, "anonymous", String[])

function principal_from_token(f::Foundry, tok::AbstractString)
    d = get(f.principals["tokens"], String(tok), nothing)
    d === nothing && return nothing
    kind = d["kind"] == "HUMAN" ? HUMAN : (d["kind"] == "AGENT" ? AGENT : SYSTEM)
    Principal(kind, d["id"], String[string(r) for r in d["roles"]])
end

# ------------------------------------------------------------------ app access

function app_get(f::Foundry, path; headers=Pair{String,String}[])
    Http.request("GET", f.app_host, f.app_port, path; headers=headers)
end

function app_sources(f::Foundry)
    st, _, body = app_get(f, "/__oracle/sources")
    st == 200 || return Dict{String,Any}()
    Dict{String,Any}(parse_json(body))
end

"Current dependency fingerprint for a capability (given the contract hash to bind)."
function current_fingerprint(f::Foundry, cap::Capability, chash::String; sources=app_sources(f), surface=cap.candidate.surface_hash)
    src = get(sources, cap.candidate.action.source_ref, "sha256:unavailable")
    Fingerprint(src, surface, policy_hash(f), TESTS_HASH, chash)
end

# ------------------------------------------------------------------ discovery

"SYSTEM scans the app's human page and records candidates. Returns the candidates."
function discover!(f::Foundry, who::Principal)
    lock(f.lock) do
        st, _, html = app_get(f, f.app_page)
        st == 200 || return Decision(Refusal("APP_UNREACHABLE", ["GET $(f.app_page) -> $st"]))
        srcmap = Dict{String,String}()
        for (ref, _) in app_sources(f)
            name = replace(basename(ref), ".jl" => "")
            srcmap[name] = ref
        end
        cands = discover_forms(html, f.app_id, srcmap)
        new = String[]
        for c in cands
            existing = get(f.store.capabilities, c.id, nothing)
            if existing === nothing || existing.candidate.surface_hash != c.surface_hash
                commit!(f.store, "DISCOVERED", pid(who), Dict{String,Any}("candidate" => to_dict(c), "requested_by" => pid(who)))
                push!(new, c.id)
            end
        end
        f.last_scan = Dict{String,Any}("at" => f.store.clock(), "candidates" => [c.id for c in cands])
        Decision(true, nothing, Dict{String,Any}("candidates" => [to_dict(c) for c in cands], "new_or_changed" => new))
    end
end

# ------------------------------------------------------------------ contracts

"""
    propose_contract!(f, who, cap_id; mode="minimize"|"naive"|"explicit", contract=nothing)

A proposal. The contract gate and policy decide; the ledger records either way.
"""
function propose_contract!(f::Foundry, who::Principal, cap_id::String; mode::String="minimize", contract=nothing)
    lock(f.lock) do
        haskey(f.store.capabilities, cap_id) || return Decision(Refusal("UNKNOWN_CAPABILITY", [cap_id]))
        cap = f.store.capabilities[cap_id]
        cap.state == LIVE && return Decision(Refusal("LIVE", ["withdraw the LIVE capability before replacing its contract"]))
        version = cap.contract === nothing ? 1 : cap.contract.version + 1
        notes = String[]
        k = if mode == "naive"
            naive_contract(cap.candidate; proposed_by=pid(who))
        elseif mode == "minimize"
            k0, notes = minimize(cap.candidate, f.policy["contract_rules"]; proposed_by=pid(who), version=version)
            k0
        else
            contract === nothing && return Decision(Refusal("SCHEMA_INVALID", ["explicit mode needs a contract"]))
            d = Dict{String,Any}(contract); d["capability_id"] = cap_id; d["proposed_by"] = pid(who); d["version"] = version
            try from_dict(Contract, d) catch e
                return Decision(Refusal("SCHEMA_INVALID", [sprint(showerror, e)]))
            end
        end
        k = Contract(k.capability_id, version, k.description, k.inputs, k.effects, k.scope, k.scope_field, k.invariants, k.nominal_input, pid(who))
        dec = contract_gate(k, cap.candidate, f.policy)
        if !dec.ok
            commit!(f.store, "CONTRACT_REFUSED", pid(who), Dict{String,Any}("capability_id" => cap_id, "contract" => to_dict(k), "refusal" => to_dict(dec.refusal)))
            return Decision(false, dec.refusal, Dict{String,Any}("contract" => to_dict(k), "minimization_notes" => notes))
        end
        blocked = policy_block(k, f.policy)
        if !isempty(blocked)
            r = Refusal("EFFECT_FORBIDDEN", blocked)
            commit!(f.store, "POLICY_BLOCKED", pid(who), Dict{String,Any}("capability_id" => cap_id, "contract" => to_dict(k), "refusal" => to_dict(r)))
            return Decision(false, r, Dict{String,Any}("contract" => to_dict(k), "state" => "POLICY_BLOCKED"))
        end
        ch = contract_hash(k)
        fp = current_fingerprint(f, cap, ch)
        commit!(f.store, "CONTRACT_ACCEPTED", pid(who), Dict{String,Any}("capability_id" => cap_id, "contract" => to_dict(k),
            "contract_hash" => ch, "fingerprint" => to_dict(fp), "minimization" => minimization_diff(cap.candidate, k), "notes" => notes))
        Decision(true, nothing, Dict{String,Any}("contract" => to_dict(k), "contract_hash" => ch, "fingerprint" => to_dict(fp),
                 "minimization" => minimization_diff(cap.candidate, k), "minimization_notes" => notes))
    end
end

# ------------------------------------------------------------------ verification

function verify!(f::Foundry, who::Principal, cap_id::String)
    lock(f.lock) do
        haskey(f.store.capabilities, cap_id) || return Decision(Refusal("UNKNOWN_CAPABILITY", [cap_id]))
        cap = f.store.capabilities[cap_id]
        cap.contract === nothing && return Decision(Refusal("NOT_VERIFIED", ["no accepted contract to verify"]))
        cap.state in (CONTRACTED, VERIFIED, FAILED, UNGRADED, STALE) ||
            return Decision(Refusal("NOT_VERIFIED", ["cannot verify while $(cap.state)"]))
        # evidence binds to the CURRENT fingerprint; if dependencies moved, mark stale first
        fp_now = current_fingerprint(f, cap, cap.contract_hash)
        stale, reasons = staleness(cap.fingerprint, fp_now)
        if stale
            commit!(f.store, "STALE", "SYSTEM:foundry", Dict{String,Any}("capability_id" => cap_id, "reason" => join(reasons, "; "),
                "old_fingerprint" => to_dict(cap.fingerprint), "new_fingerprint" => to_dict(fp_now)))
        end
        t = Target(f.app_host, f.app_port, f.verify_session)
        ev = verify_capability(t, cap.contract, cap.candidate, fp_now, k -> policy_block(k, f.policy))
        commit!(f.store, "EVIDENCE_RECORDED", "SYSTEM:verifier", Dict{String,Any}("evidence" => to_dict(ev), "requested_by" => pid(who)))
        Decision(true, nothing, Dict{String,Any}("evidence" => to_dict(ev), "state" => string(f.store.capabilities[cap_id].state)))
    end
end

# ------------------------------------------------------------------ promotion / withdrawal

function promote!(f::Foundry, who::Principal, cap_id::String)
    lock(f.lock) do
        haskey(f.store.capabilities, cap_id) || return Decision(Refusal("UNKNOWN_CAPABILITY", [cap_id]))
        cap = f.store.capabilities[cap_id]
        ev = isempty(cap.evidence_id) ? nothing : get(f.store.evidence, cap.evidence_id, nothing)
        fp_now = cap.contract === nothing ? nothing : current_fingerprint(f, cap, cap.contract_hash)
        dec = fp_now === nothing ? Decision(Refusal("NOT_VERIFIED", ["no contract"])) : promotion_gate(cap, who, ev, fp_now, f.policy)
        if !dec.ok
            commit!(f.store, "PROMOTION_REFUSED", pid(who), Dict{String,Any}("capability_id" => cap_id, "by" => pid(who), "refusal" => to_dict(dec.refusal)))
            return dec
        end
        commit!(f.store, "PROMOTED", pid(who), Dict{String,Any}("capability_id" => cap_id, "by" => pid(who), "evidence_id" => ev.id,
            "fingerprint_hash" => fingerprint_hash(fp_now), "rule" => dec.detail["rule"]))
        Decision(true, nothing, Dict{String,Any}("state" => "LIVE", "rule" => dec.detail["rule"]))
    end
end

function withdraw!(f::Foundry, who::Principal, cap_id::String, reason::String)
    lock(f.lock) do
        haskey(f.store.capabilities, cap_id) || return Decision(Refusal("UNKNOWN_CAPABILITY", [cap_id]))
        who.kind == HUMAN || return Decision(Refusal("AUTHORITY_INSUFFICIENT", ["only a HUMAN principal may withdraw; $(pid(who)) is $(who.kind)"]))
        try
            commit!(f.store, "WITHDRAWN", pid(who), Dict{String,Any}("capability_id" => cap_id, "by" => pid(who), "reason" => reason))
        catch e
            e isa Ledger.LedgerError && return Decision(Refusal("INVALID_TRANSITION", [e.msg]))
            rethrow()
        end
        Decision(true)
    end
end

# ------------------------------------------------------------------ staleness

"SYSTEM re-reads dependencies (app source digests, page surface, policy, verifier) and marks STALE where they moved."
function rescan!(f::Foundry, who::Principal)
    lock(f.lock) do
        st, _, html = app_get(f, f.app_page)
        st == 200 || return Decision(Refusal("APP_UNREACHABLE", ["GET $(f.app_page) -> $st"]))
        sources = app_sources(f)
        srcmap = Dict{String,String}(replace(basename(r), ".jl" => "") => r for (r, _) in sources)
        cands = Dict(c.id => c for c in discover_forms(html, f.app_id, srcmap))
        marked = Dict{String,Any}()
        commit!(f.store, "RESCAN", "SYSTEM:foundry", Dict{String,Any}("requested_by" => pid(who), "sources" => sources))
        for id in f.store.order
            cap = f.store.capabilities[id]
            surface = haskey(cands, id) ? cands[id].surface_hash : "sha256:surface-missing"
            if haskey(cands, id) && cands[id].surface_hash != cap.candidate.surface_hash
                commit!(f.store, "DISCOVERED", "SYSTEM:foundry", Dict{String,Any}("candidate" => to_dict(cands[id]), "requested_by" => pid(who)))
            end
            cap.fingerprint === nothing && continue
            fp_now = current_fingerprint(f, cap, cap.contract_hash; sources=sources, surface=surface)
            stale, reasons = staleness(cap.fingerprint, fp_now)
            stale || continue
            cap.state in (WITHDRAWN, POLICY_BLOCKED, CANDIDATE) && continue
            commit!(f.store, "STALE", "SYSTEM:foundry", Dict{String,Any}("capability_id" => id, "reason" => join(reasons, "; "),
                "old_fingerprint" => to_dict(cap.fingerprint), "new_fingerprint" => to_dict(fp_now), "was" => string(cap.state)))
            marked[id] = reasons
        end
        Decision(true, nothing, Dict{String,Any}("stale" => marked, "sources" => sources))
    end
end

# ------------------------------------------------------------------ WebMCP exposure

tool_name(f::Foundry, cap::Capability) = replace(cap.id, "." => "_")

"Manifest of tools for a page. Only LIVE capabilities are exposed; exposure is a pure function of verified state."
function manifest(f::Foundry, app::String)
    tools = Dict{String,Any}[]
    if app == f.app_id
        for id in f.store.order
            cap = f.store.capabilities[id]
            cap.state == LIVE || continue
            k = cap.contract
            push!(tools, Dict{String,Any}("name" => tool_name(f, cap), "description" => k.description *
                " Effects: $(join(string.(k.effects), ", ")). Scope: $(k.scope). Promoted by $(cap.promoted_by).",
                "inputSchema" => input_schema(k), "hash" => cap.contract_hash * "@" * string(cap.promotion_seq),
                "capability_id" => id, "effects" => string.(k.effects), "promoted_by" => cap.promoted_by,
                "evidence_id" => cap.evidence_id, "acceptance_input" => k.nominal_input))
        end
    elseif app == "foundry"
        append!(tools, foundry_tools())
    end
    Dict{String,Any}("app" => app, "tools" => tools, "head" => isempty(f.store.events) ? "" : f.store.events[end].hash)
end

"Foundry's own capabilities. They are engineered artifacts too: READ tools are open; the promote tool exists so that refusal is observable."
function foundry_tools()
    obj(props, req) = Dict{String,Any}("type" => "object", "properties" => props, "required" => req, "additionalProperties" => false)
    [
        Dict{String,Any}("name" => "foundry_list_capabilities", "description" => "List capabilities with lifecycle state, effects and authority. Effects: READ.",
            "inputSchema" => obj(Dict{String,Any}(), String[]), "hash" => "foundry@1"),
        Dict{String,Any}("name" => "foundry_get_capability", "description" => "Inspect one capability: contract, fingerprint, evidence summary. Effects: READ.",
            "inputSchema" => obj(Dict{String,Any}("capability_id" => Dict("type" => "string", "maxLength" => 80)), ["capability_id"]), "hash" => "foundry@1"),
        Dict{String,Any}("name" => "foundry_propose_minimized_contract", "description" => "Propose the system-minimized contract for a candidate (a proposal; the contract gate decides). Effects: WRITE_OWN (ledger).",
            "inputSchema" => obj(Dict{String,Any}("capability_id" => Dict("type" => "string", "maxLength" => 80)), ["capability_id"]), "hash" => "foundry@1"),
        Dict{String,Any}("name" => "foundry_request_verification", "description" => "Ask the verifier to produce evidence for a contracted capability. Effects: WRITE_OWN (ledger).",
            "inputSchema" => obj(Dict{String,Any}("capability_id" => Dict("type" => "string", "maxLength" => 80)), ["capability_id"]), "hash" => "foundry@1"),
        Dict{String,Any}("name" => "foundry_promote", "description" => "Request promotion. The promotion gate applies authority policy to the CALLER: agents cannot ratify consequential capabilities.",
            "inputSchema" => obj(Dict{String,Any}("capability_id" => Dict("type" => "string", "maxLength" => 80)), ["capability_id"]), "hash" => "foundry@1"),
    ]
end

"Gateway: agent input -> validated, bound app request; every call recorded. `session_token` is the human session the agent acts within."
function invoke!(f::Foundry, who::Principal, name::String, input::Dict{String,Any}, session_token::String; host::String="")
    if startswith(name, "foundry_")
        return invoke_foundry(f, who, name, input)
    end
    lock(f.lock) do
        idx = findfirst(id -> tool_name(f, f.store.capabilities[id]) == name, f.store.order)
        if idx === nothing || f.store.capabilities[f.store.order[idx]].state != LIVE
            r = Refusal("NOT_LIVE", ["no LIVE capability named $name; exposure follows verified state"])
            commit!(f.store, "INVOCATION_REFUSED", pid(who), Dict{String,Any}("capability_id" => idx === nothing ? "" : f.store.order[idx], "tool" => name, "by" => pid(who), "refusal" => to_dict(r)))
            return Decision(r)
        end
        cap = f.store.capabilities[f.store.order[idx]]
        st, _, body = app_get(f, "/api/me"; headers=["X-Session" => session_token])
        st == 200 || return Decision(Refusal("NO_SESSION", ["app did not accept the human session ($st)"]))
        session = Dict{String,Any}(parse_json(body))
        ok, bound, errs = bind_input(cap.contract, input, session)
        if !ok
            r = Refusal("INPUT_REFUSED", errs)
            commit!(f.store, "INVOCATION_REFUSED", pid(who), Dict{String,Any}("capability_id" => cap.id, "tool" => name, "by" => pid(who), "input" => input, "refusal" => to_dict(r)))
            return Decision(r)
        end
        a = cap.candidate.action
        hdrs = ["X-Session" => session_token]
        if a.method == "GET"
            qs = join(["$(Http.urlencode(k))=$(Http.urlencode(v))" for (k, v) in sort!(collect(bound))], "&")
            st2, _, out = Http.request("GET", f.app_host, f.app_port, a.path * (isempty(qs) ? "" : "?" * qs); headers=hdrs)
        else
            push!(hdrs, "Content-Type" => "application/json")
            st2, _, out = Http.request("POST", f.app_host, f.app_port, a.path; body=json(bound), headers=hdrs)
        end
        result = try parse_json(out) catch; out end
        commit!(f.store, "INVOKED", pid(who), Dict{String,Any}("capability_id" => cap.id, "tool" => name, "by" => pid(who),
            "session_user" => session["user_id"], "input" => input, "bound" => bound, "status" => st2, "result_hash" => sha(out),
            "host" => host))
        Decision(200 <= st2 < 300, nothing, Dict{String,Any}("status" => st2, "result" => result, "bound_input" => bound, "capability_id" => cap.id))
    end
end

function invoke_foundry(f::Foundry, who::Principal, name::String, input::Dict{String,Any})
    cid = string(get(input, "capability_id", ""))
    if name == "foundry_list_capabilities"
        return Decision(true, nothing, Dict{String,Any}("capabilities" => [capability_summary(f, f.store.capabilities[id]) for id in f.store.order]))
    elseif name == "foundry_get_capability"
        haskey(f.store.capabilities, cid) || return Decision(Refusal("UNKNOWN_CAPABILITY", [cid]))
        return Decision(true, nothing, capability_view(f, cid))
    elseif name == "foundry_propose_minimized_contract"
        return propose_contract!(f, who, cid; mode="minimize")
    elseif name == "foundry_request_verification"
        return verify!(f, who, cid)
    elseif name == "foundry_promote"
        return promote!(f, who, cid)
    end
    Decision(Refusal("NOT_LIVE", ["unknown foundry tool $name"]))
end

# ------------------------------------------------------------------ host reports (native WebMCP compliance)

const HOST_CLASSES = ("native", "polyfill", "none")

"""
    host_report!(f, who, report) -> Decision

A browser page's bridge reports which host class it runs on, what the host's own
getTools() returns, and (for an acceptance run) the results of executeTool() through
the host. Foundry re-derives the expected LIVE set at receipt and compares; the
browser's own `matches` claim is recorded but not trusted.
"""
function host_report!(f::Foundry, who::Principal, report::Dict{String,Any})
    host = string(get(report, "host", ""))
    host in HOST_CLASSES || return Decision(Refusal("SCHEMA_INVALID", ["host must be one of $(HOST_CLASSES), got $(repr(host))"]))
    app = string(get(report, "app", ""))
    isempty(app) && return Decision(Refusal("SCHEMA_INVALID", ["app required"]))
    expected = sort!([string(t["name"]) for t in manifest(f, app)["tools"]])
    browser = get(report, "browser_tools", nothing)
    matches = browser === nothing ? nothing : sort!(String[string(x) for x in browser]) == expected
    payload = Dict{String,Any}("app" => app, "host" => host, "native" => host == "native", "report" => report,
        "expected_tools" => expected, "matches_at_receipt" => matches, "by" => pid(who))
    # dedupe: an identical steady-state report (same host, same sets, no executions) adds nothing to the ledger
    prev = latest_host_report(f, app)
    if prev !== nothing && !haskey(report, "executions")
        pp = prev.payload
        if pp["host"] == host && pp["expected_tools"] == expected && get(pp["report"], "browser_tools", nothing) == browser && !haskey(pp["report"], "executions")
            return Decision(true, nothing, Dict{String,Any}("seq" => prev.seq, "matches_at_receipt" => matches, "expected_tools" => expected, "deduplicated" => true))
        end
    end
    ev = commit!(f.store, "HOST_REPORT", pid(who), payload)
    Decision(true, nothing, Dict{String,Any}("seq" => ev.seq, "matches_at_receipt" => matches, "expected_tools" => expected))
end

function latest_host_report(f::Foundry, app::String; native_only::Bool=false, with_executions::Bool=false)
    for e in Iterators.reverse(f.store.events)
        e.kind == "HOST_REPORT" || continue
        e.payload["app"] == app || continue
        native_only && e.payload["host"] != "native" && continue
        with_executions && !haskey(e.payload["report"], "executions") && continue
        return e
    end
    nothing
end

"""
    host_acceptance(f, app) -> Dict(verdict, reasons, ...)

Native WebMCP compliance verdict for `app`, from the ledger only:
  PASS      latest NATIVE report: getTools() exactly matched the LIVE manifest at receipt and
            every acceptance execution through the host's executeTool() succeeded
  FAIL      native report shows drift or a failed execution
  UNKNOWN   native host could not enumerate, or no executions were attempted
  BLOCKED   no native report at all — a polyfill or absent host is NOT evidence (named as such)
"""
function host_acceptance(f::Foundry, app::String)
    any_ev = latest_host_report(f, app)
    ev = latest_host_report(f, app; native_only=true)
    if ev === nothing
        why = any_ev === nothing ? "no host report received for $app" :
              "latest host report is host=$(any_ev.payload["host"]) (ledger #$(any_ev.seq)); polyfill/absent hosts are not evidence of native WebMCP compliance"
        return Dict{String,Any}("verdict" => "BLOCKED", "reasons" => [why], "report_seq" => any_ev === nothing ? 0 : any_ev.seq,
                                "host" => any_ev === nothing ? "" : any_ev.payload["host"])
    end
    p = ev.payload; r = p["report"]
    reasons = String[]
    verdict = "PASS"
    if p["matches_at_receipt"] === nothing
        verdict = "UNKNOWN"; push!(reasons, "host did not enumerate tools (getTools unavailable)")
    elseif !p["matches_at_receipt"]
        verdict = "FAIL"; push!(reasons, "browser registered set $(r["browser_tools"]) != LIVE manifest $(p["expected_tools"]) at receipt")
    end
    # executions come from the latest native report that carried an acceptance run
    xev = latest_host_report(f, app; native_only=true, with_executions=true)
    execs = xev === nothing ? nothing : get(xev.payload["report"], "executions", nothing)
    if execs === nothing || isempty(execs)
        verdict == "PASS" && (verdict = "UNKNOWN")
        push!(reasons, "no acceptance executions through the host's executeTool() in any native report")
    else
        xev.payload["matches_at_receipt"] === true || (verdict = "FAIL"; push!(reasons, "the acceptance run's report did not match the LIVE manifest at receipt"))
        for x in execs
            get(x, "ok", false) || (verdict = "FAIL"; push!(reasons, "executeTool($(x["tool"])) failed: $(get(x, "reason", get(x, "result", "")))"))
        end
    end
    verdict == "PASS" && push!(reasons, "native document.modelContext; getTools() ⇔ LIVE manifest exact; $(length(execs)) execution(s) via executeTool() ok")
    Dict{String,Any}("verdict" => verdict, "reasons" => reasons, "report_seq" => ev.seq, "execution_report_seq" => xev === nothing ? 0 : xev.seq, "host" => "native",
        "user_agent" => get(r, "user_agent", ""), "expected_tools" => p["expected_tools"], "browser_tools" => get(r, "browser_tools", nothing),
        "executions" => execs, "api" => get(r, "api", nothing))
end

"""
    host_invariant(f, app) -> Dict

The lifecycle ⇔ browser invariant, evaluated against the latest NATIVE host report:
  LIVE  ⇔ present in document.modelContext.getTools()
  every other state ⇒ absent
Returns one row per capability with `consistent`, plus an overall verdict
(PASS / FAIL / BLOCKED when there is no native report).
"""
function host_invariant(f::Foundry, app::String)
    ev = latest_host_report(f, app; native_only=true)
    rows = Dict{String,Any}[]
    ev === nothing && return Dict{String,Any}("verdict" => "BLOCKED", "reason" => "no native host report", "rows" => rows, "report_seq" => 0)
    browser = get(ev.payload["report"], "browser_tools", nothing)
    browser === nothing && return Dict{String,Any}("verdict" => "UNKNOWN", "reason" => "native host did not enumerate", "rows" => rows, "report_seq" => ev.seq)
    present = Set(String[string(x) for x in browser])
    ok = true
    for id in f.store.order
        cap = f.store.capabilities[id]
        app == f.app_id || continue
        name = tool_name(f, cap)
        isp = name in present
        expected = cap.state == LIVE
        consistent = isp == expected
        ok &= consistent
        push!(rows, Dict{String,Any}("capability_id" => id, "tool" => name, "state" => string(cap.state),
            "expected" => expected ? "present" : "absent", "browser" => isp ? "present" : "absent", "consistent" => consistent))
    end
    Dict{String,Any}("verdict" => ok ? "PASS" : "FAIL", "rows" => rows, "report_seq" => ev.seq, "at" => ev.at,
        "user_agent" => get(ev.payload["report"], "user_agent", ""))
end

"Per-capability browser presence from the latest host report of any class (for the UI; host class is shown)."
function browser_presence(f::Foundry, cap::Capability)
    ev = latest_host_report(f, cap.candidate.action.app)
    ev === nothing && return Dict{String,Any}("presence" => "unknown", "host" => "", "consistent" => nothing, "report_seq" => 0)
    browser = get(ev.payload["report"], "browser_tools", nothing)
    browser === nothing && return Dict{String,Any}("presence" => "unknown", "host" => ev.payload["host"], "consistent" => nothing, "report_seq" => ev.seq)
    isp = tool_name(f, cap) in Set(String[string(x) for x in browser])
    Dict{String,Any}("presence" => isp ? "present" : "absent", "host" => ev.payload["host"],
                     "consistent" => isp == (cap.state == LIVE), "report_seq" => ev.seq)
end


# ------------------------------------------------------------------ views

function capability_summary(f::Foundry, cap::Capability)
    k = cap.contract
    ev = isempty(cap.evidence_id) ? nothing : get(f.store.evidence, cap.evidence_id, nothing)
    Dict{String,Any}("id" => cap.id, "title" => cap.candidate.title, "state" => string(cap.state),
        "action" => to_dict(cap.candidate.action), "tool" => tool_name(f, cap),
        "effects" => k === nothing ? Any[] : string.(k.effects), "scope" => k === nothing ? "" : k.scope,
        "agent_fields" => k === nothing ? count(x -> true, cap.candidate.fields) : count(x -> x.binding == AGENT_BOUND, k.inputs),
        "surface_fields" => length(cap.candidate.fields),
        "authority" => k === nothing ? nothing : required_authority(k, f.policy),
        "evidence_verdict" => ev === nothing ? nothing : string(ev.verdict),
        "evidence_id" => cap.evidence_id, "promoted_by" => cap.promoted_by, "stale_reason" => cap.stale_reason,
        "contract_version" => k === nothing ? 0 : k.version, "hints" => cap.candidate.hints,
        "browser" => browser_presence(f, cap))
end

function capability_view(f::Foundry, id::String)
    cap = f.store.capabilities[id]
    d = to_dict(cap)
    d["summary"] = capability_summary(f, cap)
    d["evidence"] = isempty(cap.evidence_id) ? nothing : to_dict(f.store.evidence[cap.evidence_id])
    d["minimization"] = cap.contract === nothing ? nothing : minimization_diff(cap.candidate, cap.contract)
    d["input_schema"] = cap.contract === nothing ? nothing : input_schema(cap.contract)
    d["current_fingerprint"] = cap.contract === nothing ? nothing : to_dict(current_fingerprint(f, cap, cap.contract_hash))
    d["all_evidence"] = [Dict("id" => e.id, "verdict" => string(e.verdict), "contract_hash" => e.contract_hash, "fingerprint_hash" => fingerprint_hash(e.fingerprint), "mutation_score" => e.mutation_score)
                         for e in values(f.store.evidence) if e.capability_id == id]
    sort!(d["all_evidence"]; by=x -> x["id"])
    d
end

function status(f::Foundry)
    ok, msg = Ledger.verify_chain(f.store.events)
    Dict{String,Any}("app" => Dict("id" => f.app_id, "host" => f.app_host, "port" => f.app_port),
        "ledger" => Dict("events" => length(f.store.events), "chain" => msg, "chain_ok" => ok,
                         "head" => isempty(f.store.events) ? "" : f.store.events[end].hash, "digest" => Ledger.digest(f.store),
                         "path" => f.store.path),
        "policy_hash" => policy_hash(f), "tests_hash" => TESTS_HASH,
        "capabilities" => Dict(string(s) => count(id -> f.store.capabilities[id].state == s, f.store.order) for s in instances(CapState)),
        "last_scan" => f.last_scan)
end

end # module FoundryCore
