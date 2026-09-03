# verify.jl — adversarial, mutation-oriented verification against an EXTERNAL oracle.
#
# The verifier never calls the app in-process. It drives the app over TCP with the
# human's session, snapshots authoritative state through the Foundry Oracle
# Protocol before/after every probe, and derives OBSERVED effects from the diff.
# The contract's declared effects are an upper bound; TraceWithin(bound, observed)
# must hold (Dumas). Anything the oracle cannot observe is UNGRADABLE, not PASS.
#
# Mutation discipline (LADGK / Loft "a gate that cannot fail is not a gate"):
# before evidence counts, the suite must demonstrate it can FAIL by killing
# must-kill mutants of the contract whose correct verdict is known. Informative
# mutants report whether each constraint is load-bearing or app-redundant.

module Verify

import ..JSON: json, canonical, parse_json
import ..Http
import ..Model
import ..Model: Contract, Candidate, FieldSpec, Evidence, CheckResult, Probe, Fingerprint, Verdict,
                PASS, FAIL, UNKNOWN, UNGRADABLE, BLOCKED, INVALID, verdict_join,
                AGENT_BOUND, SESSION_BOUND, FIXED_BOUND, HUMAN_ONLY,
                EffectKind, READ, WRITE_OWN, WRITE_OTHER, FINANCIAL, EXTERNAL_SEND, DESTRUCTIVE,
                effect_from_string, sha, to_dict, contract_hash
import ..Validate: bind_input

export Target, verify_capability, observe, snapshot, TESTS_HASH

const TESTS_HASH = sha(read(@__FILE__))

struct Target
    host::String
    port::Int
    session_token::String     # the human session the verifier acts within
end

# ------------------------------------------------------------------ oracle protocol

function oracle_get(t::Target, path)
    st, _, body = Http.request("GET", t.host, t.port, path)
    (st, body)
end
function snapshot(t::Target)
    st, body = oracle_get(t, "/__oracle/snapshot")
    st == 200 || return nothing
    parse_json(body)
end
function reset!(t::Target)
    st, _, _ = Http.request("POST", t.host, t.port, "/__oracle/reset")
    st == 200
end
function session_info(t::Target)
    st, _, body = Http.request("GET", t.host, t.port, "/api/me"; headers=["X-Session" => t.session_token])
    st == 200 || return nothing
    Dict{String,Any}(parse_json(body))
end

"Call the app action with already-bound input. `auth=false` omits the session (adversarial)."
function call_app(t::Target, k::Contract, action, bound::Dict{String,String}; auth::Bool=true)
    hdrs = Pair{String,String}[]
    auth && push!(hdrs, "X-Session" => t.session_token)
    if action.method == "GET"
        qs = join(["$(Http.urlencode(k))=$(Http.urlencode(v))" for (k, v) in sort!(collect(bound))], "&")
        st, _, body = Http.request("GET", t.host, t.port, action.path * (isempty(qs) ? "" : "?" * qs); headers=hdrs)
    else
        push!(hdrs, "Content-Type" => "application/json")
        st, _, body = Http.request("POST", t.host, t.port, action.path; body=json(bound), headers=hdrs)
    end
    (st, body)
end

# ------------------------------------------------------------------ observed effects

"""
    observe(before, after, user) -> (effects::Vector{String}, touched::Vector{String}, partial::Bool)

Derives the observed effect trace from two oracle snapshots.
"""
function observe(before, after, user::String)
    effects = Set{String}()
    touched = String[]
    partial = false
    ra = before["resources"]; rb = after["resources"]
    for kind in union(keys(ra), keys(rb))
        ia = get(ra, kind, Dict{String,Any}()); ib = get(rb, kind, Dict{String,Any}())
        for id in sort!(collect(union(keys(ia), keys(ib))))
            if !haskey(ib, id)
                push!(effects, "DESTRUCTIVE"); push!(touched, "$kind/$id")
            elseif !haskey(ia, id)
                push!(effects, get(ib[id], "owner", "") == user ? "WRITE_OWN" : "WRITE_OTHER"); push!(touched, "$kind/$id")
            elseif canonical(ia[id]) != canonical(ib[id])
                push!(touched, "$kind/$id")
                owner = get(ia[id], "owner", "")
                a = ia[id]; b = ib[id]
                balchange = haskey(a, "balance_cents") && a["balance_cents"] != b["balance_cents"]
                if balchange
                    push!(effects, "FINANCIAL")
                    delta = b["balance_cents"] - a["balance_cents"]
                    owner == user ? push!(effects, "WRITE_OWN") : (delta < 0 && push!(effects, "WRITE_OTHER"))
                end
                # any non-balance field change
                a2 = copy(a); b2 = copy(b); delete!(a2, "balance_cents"); delete!(b2, "balance_cents")
                if canonical(a2) != canonical(b2)
                    push!(effects, owner == user ? "WRITE_OWN" : "WRITE_OTHER")
                end
            end
        end
    end
    ea = get(before, "external", Dict{String,Any}()); eb = get(after, "external", Dict{String,Any}())
    for key in keys(eb)
        key == "observability" && continue
        if get(ea, key, nothing) != eb[key]
            push!(effects, "EXTERNAL_SEND"); push!(touched, "external/$key")
            get(eb, "observability", "full") == "partial" && (partial = true)
        end
    end
    isempty(effects) && push!(effects, "READ")
    (sort!(collect(effects)), touched, partial)
end

effect_rank(s::String) = Int(effect_from_string(s))
# Coverage: READ is always within bound; a declared FINANCIAL/DESTRUCTIVE bound
# covers the WRITE_OWN it necessarily entails on the actor's own resources.
# WRITE_OTHER is never implied by anything — it must be declared (and policy forbids it).
function covers(declared::Vector{EffectKind}, o::String)
    o == "READ" && return true
    any(d -> string(d) == o, declared) && return true
    o == "WRITE_OWN" && any(d -> d == FINANCIAL || d == DESTRUCTIVE, declared) && return true
    false
end
within(observed::Vector{String}, declared::Vector{EffectKind}) = all(o -> covers(declared, o), observed)

balances(snap) = Dict(id => a["balance_cents"] for (id, a) in get(snap["resources"], "account", Dict()))
owned(snap, user) = Set(id for (id, a) in get(snap["resources"], "account", Dict()) if get(a, "owner", "") == user)

# ------------------------------------------------------------------ probe runner

mutable struct Ctx
    t::Target
    k::Contract
    cand::Candidate
    session::Dict{String,Any}
    user::String
    probes::Vector{Probe}         # every probe, for the no_effect_on_rejection invariant
end

"Run one bound input against the app; reset first; return the Probe (and the before/after snapshots)."
function probe!(ctx::Ctx, label::String, bound::Dict{String,String}; auth::Bool=true, note::String="")
    reset!(ctx.t)
    before = snapshot(ctx.t)
    st, body = call_app(ctx.t, ctx.k, ctx.cand.action, bound; auth=auth)
    after = snapshot(ctx.t)
    eff, touched, partial = observe(before, after, ctx.user)
    p = Probe(label, Dict{String,Any}(bound), st, eff, touched, note * (partial ? " [external effect only partially observable]" : ""))
    push!(ctx.probes, p)
    (p, before, after, partial)
end

function bind_or_error(ctx::Ctx, input::Dict{String,Any})
    ok, bound, errs = bind_input(ctx.k, input, ctx.session)
    (ok, bound, errs)
end

agent_fields(k::Contract) = [f for f in k.inputs if f.binding == AGENT_BOUND]

# ------------------------------------------------------------------ checks

function check_unauthenticated(ctx::Ctx)
    ok, bound, errs = bind_or_error(ctx, ctx.k.nominal_input)
    ok || return CheckResult("unauthenticated_refused", INVALID, "nominal input does not bind: " * join(errs, "; "), Probe[])
    p, _, _, _ = probe!(ctx, "no-session", bound; auth=false, note="nominal input without any session")
    if p.status in (401, 403) && p.observed_effects == ["READ"]
        CheckResult("unauthenticated_refused", PASS, "app refused ($(p.status)) and state unchanged", [p])
    else
        CheckResult("unauthenticated_refused", FAIL, "unauthenticated call got $(p.status) with effects $(p.observed_effects)", [p])
    end
end

function check_nominal(ctx::Ctx)
    ok, bound, errs = bind_or_error(ctx, ctx.k.nominal_input)
    ok || return CheckResult("nominal_within_bound", FAIL, "nominal input refused by validator: " * join(errs, "; "), Probe[])
    p, before, after, partial = probe!(ctx, "nominal", bound; note="contract nominal input, human session")
    200 <= p.status < 300 || return CheckResult("nominal_within_bound", FAIL, "nominal input rejected by app with $(p.status)", [p])
    any(e -> e == EXTERNAL_SEND, ctx.k.effects) &&
        return CheckResult("nominal_within_bound", UNGRADABLE, "declared EXTERNAL_SEND: delivery leaves the system boundary and no oracle can observe it; observed $(p.observed_effects)", [p])
    partial && return CheckResult("nominal_within_bound", UNGRADABLE, "observed an external hand-off the oracle can only partially observe", [p])
    within(p.observed_effects, ctx.k.effects) ||
        return CheckResult("nominal_within_bound", FAIL, "observed effects $(p.observed_effects) exceed declared bound $(string.(ctx.k.effects)); touched $(p.touched)", [p])
    if ctx.k.scope == "own_account"
        own = owned(before, ctx.user)
        for t in p.touched
            startswith(t, "account/") || continue
            id = t[9:end]
            id in own && continue
            # a credit to another's account is FINANCIAL, allowed only if declared
            any(e -> e == FINANCIAL, ctx.k.effects) && after["resources"]["account"][id]["balance_cents"] > before["resources"]["account"][id]["balance_cents"] && continue
            return CheckResult("nominal_within_bound", FAIL, "touched $t outside own_account scope", [p])
        end
    end
    CheckResult("nominal_within_bound", PASS, "observed $(p.observed_effects) ⊆ declared $(string.(ctx.k.effects)); touched $(p.touched)", [p])
end

function boundary_values(f::FieldSpec)
    vals = Any[]
    c = f.constraints
    if f.type == "integer"
        haskey(c, "minimum") && push!(vals, c["minimum"] - 1)
        haskey(c, "maximum") && push!(vals, c["maximum"] + 1)
        push!(vals, "12abc")
    elseif f.type == "enum"
        push!(vals, "__not_an_option__")
    elseif f.type == "boolean"
        push!(vals, "maybe")
    else
        haskey(c, "maxLength") && push!(vals, repeat("x", c["maxLength"] + 1))
        push!(vals, "<script>alert(1)</script>")
        get(c, "format", "") == "email" && push!(vals, "not-an-email")
    end
    vals
end

function check_constraints(ctx::Ctx)
    probes = Probe[]
    fails = String[]
    notes = String[]
    n = 0
    for f in agent_fields(ctx.k)
        for v in boundary_values(f)
            n += 1
            inp = copy(ctx.k.nominal_input); inp[f.name] = v
            ok, bound, errs = bind_or_error(ctx, inp)
            if ok
                push!(fails, "$(f.name)=$(repr(v)) passed validation")
                continue
            end
            # informative: does the app itself reject the out-of-contract value?
            _, nominal_bound, _ = bind_or_error(ctx, ctx.k.nominal_input)
            forged = copy(nominal_bound); forged[f.name] = string(v)
            p, _, _, _ = probe!(ctx, "boundary:$(f.name)=$(repr(v))", forged; note="validator refused; sent directly to app to measure app-side defense")
            push!(probes, p)
            if 200 <= p.status < 300
                push!(notes, "$(f.name)=$(repr(v)): validator refused; APP ACCEPTED (constraint is load-bearing)")
            else
                push!(notes, "$(f.name)=$(repr(v)): validator refused; app also refused ($(p.status))")
            end
        end
    end
    n == 0 && return CheckResult("constraint_boundary", UNKNOWN, "no agent-bound constrained fields to probe", probes)
    isempty(fails) || return CheckResult("constraint_boundary", FAIL, join(fails, "; "), probes)
    CheckResult("constraint_boundary", PASS, "$n out-of-contract values refused by the gateway. " * join(notes, " | "), probes)
end

function check_scope(ctx::Ctx, before_snap)
    k = ctx.k
    sf = isempty(k.scope_field) ? nothing : findfirst(f -> f.name == k.scope_field, k.inputs)
    if sf === nothing
        all(e -> e == READ, k.effects) && return CheckResult("scope_adversarial", PASS, "no scope field and READ-only bound: nothing an agent can direct at another's resource (nominal check confirms no writes)", Probe[])
        return CheckResult("scope_adversarial", UNKNOWN, "non-READ contract declares no scope field; cross-resource behaviour not probed", Probe[])
    end
    f = k.inputs[sf]
    own = owned(before_snap, ctx.user)
    others = sort!([id for id in keys(get(before_snap["resources"], "account", Dict())) if !(id in own)])
    isempty(others) && return CheckResult("scope_adversarial", UNKNOWN, "oracle shows no foreign resources to probe against", Probe[])
    probes = Probe[]
    amount_field = findfirst(x -> x.type == "integer" && get(x.constraints, "minimum", 0) < 0, k.inputs)
    if f.binding == AGENT_BOUND
        for id in others
            inp = copy(k.nominal_input); inp[f.name] = id
            amount_field === nothing || (inp[k.inputs[amount_field].name] = -500)
            ok, bound, errs = bind_or_error(ctx, inp)
            if !ok
                push!(probes, Probe("cross-scope:$id", inp, 0, String[], String[], "gateway refused: " * join(errs, "; ")))
                continue
            end
            p, _, _, _ = probe!(ctx, "cross-scope:$id", bound; note="agent directs the scope field at a resource the session does not own")
            push!(probes, p)
            if "WRITE_OTHER" in p.observed_effects || "DESTRUCTIVE" in p.observed_effects
                return CheckResult("scope_adversarial", FAIL, "COUNTEREXAMPLE: input $(json(bound)) returned $(p.status) and produced $(p.observed_effects) on $(p.touched) — the app mutated a resource outside own_account scope", probes)
            end
        end
        return CheckResult("scope_adversarial", PASS, "$(length(others)) foreign resources probed through the agent-controlled scope field; no cross-scope mutation", probes)
    else
        # bound field: agent must not be able to override it
        fails = String[]
        for id in others
            inp = copy(k.nominal_input); inp[f.name] = id
            ok, bound, errs = bind_or_error(ctx, inp)
            ok && push!(fails, "agent-supplied $(f.name)=$id accepted by validator")
            push!(probes, Probe("override-bound:$id", inp, 0, String[], String[], ok ? "ACCEPTED" : "gateway refused: " * join(errs, "; ")))
        end
        # informative: forge the bound value straight at the app
        _, nb, _ = bind_or_error(ctx, k.nominal_input)
        forged = copy(nb); forged[f.name] = first(others)
        amount_field === nothing || (forged[k.inputs[amount_field].name] = "-500")
        p, _, _, _ = probe!(ctx, "forge-bound:$(first(others))", forged; note="bound field forged directly at the app (bypassing gateway) to measure app-side defense")
        push!(probes, p)
        appnote = ("WRITE_OTHER" in p.observed_effects) ? "APP HAS NO OWN DEFENSE (gateway binding is load-bearing)" : "app also refused ($(p.status))"
        isempty(fails) || return CheckResult("scope_adversarial", FAIL, join(fails, "; "), probes)
        return CheckResult("scope_adversarial", PASS, "session-bound $(f.name) cannot be overridden by the agent; $appnote", probes)
    end
end

function check_unknown_fields(ctx::Ctx)
    k = ctx.k
    probes = Probe[]
    fails = String[]
    extras = Any[("admin", "1"), ("__proto__", "x"), ("include_all_accounts", "1")]
    for f in ctx.cand.fields
        any(x -> x.name == f.name && x.binding == AGENT_BOUND, k.inputs) && continue
        push!(extras, (f.name, "1"))
    end
    for (name, v) in unique(extras)
        inp = copy(k.nominal_input); inp[name] = v
        ok, _, errs = bind_or_error(ctx, inp)
        ok && push!(fails, "extra field $name accepted")
        push!(probes, Probe("extra:$name", inp, 0, String[], String[], ok ? "ACCEPTED" : "gateway refused: " * join(errs, "; ")))
    end
    isempty(fails) || return CheckResult("unknown_fields_rejected", FAIL, join(fails, "; "), probes)
    CheckResult("unknown_fields_rejected", PASS, "$(length(probes)) non-contract fields refused by the gateway", probes)
end

function check_invariants(ctx::Ctx)
    k = ctx.k
    results = CheckResult[]
    for inv in k.invariants
        if inv == "hidden_not_agent"
            bad = [f.name for f in k.inputs if f.origin == "hidden" && f.binding == AGENT_BOUND]
            push!(results, CheckResult("invariant:hidden_not_agent", isempty(bad) ? PASS : FAIL,
                isempty(bad) ? "no hidden control is agent-controlled" : "hidden controls agent-controlled: $bad", Probe[]))
        elseif inv == "no_effect_on_rejection"
            bad = [p for p in ctx.probes if p.status >= 400 && p.observed_effects != ["READ"]]
            push!(results, CheckResult("invariant:no_effect_on_rejection", isempty(bad) ? PASS : FAIL,
                isempty(bad) ? "every rejected probe ($(count(p -> p.status >= 400, ctx.probes))) left state unchanged" :
                               "rejected probes mutated state: " * join([p.label for p in bad], ", "), bad))
        elseif inv == "conservation"
            ok, bound, errs = bind_or_error(ctx, k.nominal_input)
            if !ok
                push!(results, CheckResult("invariant:conservation", INVALID, "nominal does not bind", Probe[])); continue
            end
            p, before, after, _ = probe!(ctx, "conservation", bound; note="sum of balances before == after")
            sb = sum(values(balances(before))); sa = sum(values(balances(after)))
            push!(results, CheckResult("invariant:conservation", sb == sa ? PASS : FAIL, "total balance $sb -> $sa", [p]))
        elseif inv == "nonnegative_balance"
            af = findfirst(f -> f.type == "integer" && f.binding == AGENT_BOUND, k.inputs)
            if af === nothing
                push!(results, CheckResult("invariant:nonnegative_balance", UNGRADABLE, "no agent-bound amount field to overdraw with", Probe[])); continue
            end
            fld = k.inputs[af]
            _, nb, _ = bind_or_error(ctx, k.nominal_input)
            before = snapshot(ctx.t)
            src = get(nb, k.scope_field, get(ctx.session, "default_account", ""))
            bal = get(balances(before), src, 0)
            over = get(fld.constraints, "minimum", 0) < 0 ? -(bal + 1) : bal + 1   # debit direction
            forged = copy(nb); forged[fld.name] = string(over)
            p, b0, a0, _ = probe!(ctx, "overdraw:$over", forged; note="amount exceeding the source balance $bal of $src (sent directly; may exceed contract max)")
            neg = any(v -> v < 0, values(balances(a0)))
            if neg
                push!(results, CheckResult("invariant:nonnegative_balance", FAIL, "a balance went negative after $(p.label)", [p]))
            elseif 200 <= p.status < 300 && p.observed_effects != ["READ"]
                push!(results, CheckResult("invariant:nonnegative_balance", FAIL, "overdraw accepted", [p]))
            else
                push!(results, CheckResult("invariant:nonnegative_balance", PASS, "overdraw refused ($(p.status)); no balance negative", [p]))
            end
        else
            push!(results, CheckResult("invariant:$inv", UNGRADABLE, "no evaluator registered for invariant '$inv' (required and unmeasurable)", Probe[]))
        end
    end
    isempty(results) && push!(results, CheckResult("invariants", UNKNOWN, "contract declares no invariants", Probe[]))
    results
end

# ------------------------------------------------------------------ suite

"Run the whole check suite for a contract. Returns Vector{CheckResult} (never throws on app behaviour)."
function run_suite(t::Target, k::Contract, cand::Candidate)
    snap = snapshot(t)
    snap === nothing && return [CheckResult("oracle_available", BLOCKED, "oracle snapshot unavailable at $(t.host):$(t.port); nothing can be graded", Probe[])]
    reset!(t) || return [CheckResult("oracle_available", BLOCKED, "oracle reset failed", Probe[])]
    sess = session_info(t)
    sess === nothing && return [CheckResult("oracle_available", BLOCKED, "verification session $(t.session_token) not accepted by app", Probe[])]
    ctx = Ctx(t, k, cand, sess, string(sess["user_id"]), Probe[])
    out = CheckResult[CheckResult("oracle_available", PASS, "snapshot+reset+session ok (user=$(ctx.user))", Probe[])]
    push!(out, check_unauthenticated(ctx))
    push!(out, check_nominal(ctx))
    push!(out, check_constraints(ctx))
    push!(out, check_scope(ctx, snapshot(t)))
    push!(out, check_unknown_fields(ctx))
    append!(out, check_invariants(ctx))
    reset!(t)
    out
end

suite_verdict(checks) = verdict_join(c.verdict for c in checks)

# ------------------------------------------------------------------ mutants

function mutate(k::Contract, kind::String)
    if kind == "effects_underdeclared"
        return Contract(k.capability_id, k.version, k.description, k.inputs, [READ], k.scope, k.scope_field, k.invariants, k.nominal_input, k.proposed_by)
    elseif kind == "scope_widened"
        return Contract(k.capability_id, k.version, k.description, k.inputs, unique(vcat(k.effects, [WRITE_OTHER])), "any", k.scope_field, k.invariants, k.nominal_input, k.proposed_by)
    elseif kind == "nominal_out_of_contract"
        nom = copy(k.nominal_input)
        for f in agent_fields(k)
            if f.type == "integer" && haskey(f.constraints, "maximum")
                nom[f.name] = f.constraints["maximum"] + 1; break
            elseif f.type == "string" && haskey(f.constraints, "maxLength")
                nom[f.name] = repeat("x", f.constraints["maxLength"] + 1); break
            elseif f.type == "enum"
                nom[f.name] = "__not_an_option__"; break
            end
        end
        return Contract(k.capability_id, k.version, k.description, k.inputs, k.effects, k.scope, k.scope_field, k.invariants, nom, k.proposed_by)
    elseif startswith(kind, "constraint_dropped:")
        fname = kind[length("constraint_dropped:")+1:end]
        inputs = [f.name == fname ? FieldSpec(f.name, f.type, f.binding, f.required, Dict{String,Any}(kk => vv for (kk, vv) in f.constraints if !(kk in ("minimum", "maximum", "maxLength"))), f.origin) : f for f in k.inputs]
        return Contract(k.capability_id, k.version, k.description, inputs, k.effects, k.scope, k.scope_field, k.invariants, k.nominal_input, k.proposed_by)
    end
    error("unknown mutant $kind")
end

function applicable_mutants(k::Contract)
    must = String[]
    all(e -> e == READ, k.effects) || push!(must, "effects_underdeclared")
    push!(must, "scope_widened")
    any(f -> (f.type == "integer" && haskey(f.constraints, "maximum")) || (f.type == "string" && haskey(f.constraints, "maxLength")) || f.type == "enum", agent_fields(k)) &&
        push!(must, "nominal_out_of_contract")
    info = ["constraint_dropped:$(f.name)" for f in agent_fields(k) if any(c -> haskey(f.constraints, c), ("minimum", "maximum", "maxLength"))]
    (must, info)
end

# ------------------------------------------------------------------ evidence assembly

"""
    verify_capability(target, contract, candidate, fingerprint, policy_block) -> Evidence

`policy_block(contract) -> Vector{String}` returns policy reasons that would block
the contract (used to kill the scope_widened mutant: policy is part of the gate).
"""
function verify_capability(t::Target, k::Contract, cand::Candidate, fp::Fingerprint, policy_block::Function)
    checks = run_suite(t, k, cand)
    base = suite_verdict(checks)
    mutants = Dict{String,Any}[]
    killed = 0; total = 0
    if base != BLOCKED
        must, info = applicable_mutants(k)
        for m in must
            total += 1
            mk = mutate(k, m)
            reasons = policy_block(mk)
            v = isempty(reasons) ? suite_verdict(run_suite(t, mk, cand)) : BLOCKED
            dead = v != PASS
            dead && (killed += 1)
            push!(mutants, Dict{String,Any}("id" => m, "kind" => "must-kill", "expected" => "not PASS", "outcome" => string(v),
                "killed" => dead, "note" => isempty(reasons) ? "" : "policy: " * join(reasons, "; ")))
        end
        for m in info
            mk = mutate(k, m)
            # informative: is the dropped constraint load-bearing? probe the app with the out-of-contract value
            fname = m[length("constraint_dropped:")+1:end]
            f = k.inputs[findfirst(x -> x.name == fname, k.inputs)]
            sess = session_info(t)
            ctx = Ctx(t, k, cand, sess, string(sess["user_id"]), Probe[])
            _, nb, _ = bind_or_error(ctx, k.nominal_input)
            lb = false
            for v in boundary_values(f)
                forged = copy(nb); forged[fname] = string(v)
                p, _, _, _ = probe!(ctx, "drop:$fname=$(repr(v))", forged)
                (200 <= p.status < 300 || p.observed_effects != ["READ"]) && (lb = true)
            end
            push!(mutants, Dict{String,Any}("id" => m, "kind" => "informative", "expected" => "n/a",
                "outcome" => lb ? "load_bearing" : "app_redundant", "killed" => nothing,
                "note" => lb ? "app accepts out-of-contract values for $fname; the contract constraint is the only defense" : "app independently refuses out-of-contract values for $fname"))
        end
        reset!(t)
    end
    score = total == 0 ? 1.0 : killed / total
    verdict = base
    if base == PASS && score < 1.0
        verdict = INVALID       # the suite could not demonstrate it can fail -> its PASS is not credible
    end
    body = Dict{String,Any}("capability_id" => k.capability_id, "contract_hash" => contract_hash(k),
        "fingerprint" => to_dict(fp), "checks" => [to_dict(c) for c in checks], "mutants" => mutants,
        "verdict" => string(verdict), "mutation_score" => score, "produced_by" => "SYSTEM:verifier")
    h = sha(canonical(body))
    Evidence("ev-" * h[8:23], k.capability_id, contract_hash(k), fp, checks, mutants, verdict, score, "SYSTEM:verifier", h)
end

end # module Verify
