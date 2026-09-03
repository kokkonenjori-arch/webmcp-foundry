# model.jl — the typed vocabulary of the Foundry.
#
# Doctrine encoded here:
#   * Agents propose. Evidence qualifies. Authority promotes.
#   * Verdicts are a lattice; uncertainty never collapses into PASS.
#   * Effects are an UPPER BOUND declared in the contract; the verifier observes a
#     trace and checks TraceWithin(bound, observed) (Dumas).
#   * Refusal is typed and carries reasons (Loft/LADGK), never prose-only.

module Model

using SHA
import ..JSON: canonical, parse_json

export Actor, HUMAN, AGENT, SYSTEM, Principal,
       EffectKind, READ, WRITE_OWN, WRITE_OTHER, FINANCIAL, DESTRUCTIVE, EXTERNAL_SEND,
       effect_rank, effect_from_string,
       Verdict, PASS, FAIL, UNKNOWN, UNGRADABLE, BLOCKED, INVALID, verdict_join, verdict_from_string,
       Binding, AGENT_BOUND, SESSION_BOUND, FIXED_BOUND, HUMAN_ONLY, binding_from_string,
       CapState, CANDIDATE, CONTRACTED, VERIFIED, FAILED, UNGRADED, POLICY_BLOCKED, LIVE, STALE, WITHDRAWN,
       capstate_from_string,
       FieldSpec, ActionRef, Contract, Candidate, Capability, Evidence, CheckResult, Probe,
       Fingerprint, Refusal, Decision, sha, contract_hash, fingerprint_hash, to_dict, from_dict

sha(s::AbstractString) = "sha256:" * bytes2hex(sha256(s))
sha(b::Vector{UInt8}) = "sha256:" * bytes2hex(sha256(b))

# ------------------------------------------------------------------ actors

@enum Actor HUMAN AGENT SYSTEM

"A principal is an authenticated actor. Roles are strings from policy (e.g. \"owner\")."
struct Principal
    kind::Actor
    id::String
    roles::Vector{String}
end
to_dict(p::Principal) = Dict{String,Any}("kind" => string(p.kind), "id" => p.id, "roles" => p.roles)

# ------------------------------------------------------------------ effects

# Ordered by consequence. A contract declares a SET; policy is keyed by the maximum.
@enum EffectKind READ=0 WRITE_OWN=1 WRITE_OTHER=2 FINANCIAL=3 EXTERNAL_SEND=4 DESTRUCTIVE=5
effect_rank(e::EffectKind) = Int(e)
const EFFECT_NAMES = Dict(string(e) => e for e in instances(EffectKind))
effect_from_string(s::AbstractString) = get(EFFECT_NAMES, String(s), nothing)

# ------------------------------------------------------------------ verdicts

# Precedence (strongest first): INVALID > FAIL > UNGRADABLE > UNKNOWN > BLOCKED > PASS.
# "A gate reports the strongest reason it could not establish." Only PASS establishes.
@enum Verdict PASS=0 BLOCKED=1 UNKNOWN=2 UNGRADABLE=3 FAIL=4 INVALID=5
verdict_join(a::Verdict, b::Verdict) = Int(a) >= Int(b) ? a : b
function verdict_join(vs)
    v = PASS
    n = 0
    for x in vs
        v = verdict_join(v, x); n += 1
    end
    n == 0 && return INVALID          # empty manifest establishes nothing
    v
end
const VERDICT_NAMES = Dict(string(v) => v for v in instances(Verdict))
verdict_from_string(s::AbstractString) = get(VERDICT_NAMES, String(s), INVALID)  # unknown token -> INVALID, never PASS

# ------------------------------------------------------------------ input bindings

# Who controls a field's value when the capability is invoked by an agent.
@enum Binding AGENT_BOUND SESSION_BOUND FIXED_BOUND HUMAN_ONLY
const BINDING_NAMES = Dict(string(b) => b for b in instances(Binding))
binding_from_string(s::AbstractString) = get(BINDING_NAMES, String(s), nothing)

struct FieldSpec
    name::String
    type::String                 # "string" | "integer" | "boolean" | "enum"
    binding::Binding
    required::Bool
    constraints::Dict{String,Any}   # minimum, maximum, maxLength, pattern, enum, fixed, session_key
    origin::String               # discovery note: "visible" | "hidden" | "select" ...
end
to_dict(f::FieldSpec) = Dict{String,Any}("name" => f.name, "type" => f.type, "binding" => string(f.binding),
    "required" => f.required, "constraints" => f.constraints, "origin" => f.origin)
function fieldspec_from_dict(d::Dict{String,Any})
    b = binding_from_string(get(d, "binding", "AGENT_BOUND"))
    b === nothing && error("unknown binding: $(d["binding"])")
    FieldSpec(d["name"], get(d, "type", "string"), b, get(d, "required", true),
              Dict{String,Any}(get(d, "constraints", Dict{String,Any}())), get(d, "origin", "unknown"))
end

# ------------------------------------------------------------------ actions / candidates

struct ActionRef
    app::String        # app id, e.g. "ledgerly"
    method::String
    path::String
    source_ref::String # which source artifact implements it (for dependency tracking)
end
to_dict(a::ActionRef) = Dict{String,Any}("app" => a.app, "method" => a.method, "path" => a.path, "source_ref" => a.source_ref)
actionref_from_dict(d) = ActionRef(d["app"], d["method"], d["path"], d["source_ref"])

"A raw discovered surface: everything the human form exposes, before any narrowing."
struct Candidate
    id::String
    title::String
    action::ActionRef
    fields::Vector{FieldSpec}     # all AGENT_BOUND and unconstrained at discovery (over-broad by construction)
    hints::Dict{String,Any}       # untrusted claims made by the page (data-effect etc.)
    surface_hash::String          # hash of the discovered form (schema dependency)
end
to_dict(c::Candidate) = Dict{String,Any}("id" => c.id, "title" => c.title, "action" => to_dict(c.action),
    "fields" => [to_dict(f) for f in c.fields], "hints" => c.hints, "surface_hash" => c.surface_hash)
candidate_from_dict(d) = Candidate(d["id"], d["title"], actionref_from_dict(d["action"]),
    [fieldspec_from_dict(Dict{String,Any}(f)) for f in d["fields"]], Dict{String,Any}(d["hints"]), d["surface_hash"])

# ------------------------------------------------------------------ contracts

"""
A Contract is the engineered artifact. It is a PROPOSAL until a gate accepts it.
`effects` is the declared upper bound; `scope` names the resource boundary the
capability may touch on the invoking human's behalf.
"""
struct Contract
    capability_id::String
    version::Int
    description::String
    inputs::Vector{FieldSpec}
    effects::Vector{EffectKind}
    scope::String                # "own_account" | "any" | "none"
    scope_field::String          # which input names the resource (or "")
    invariants::Vector{String}   # e.g. "conservation", "nonnegative_balance", "no_effect_on_rejection"
    nominal_input::Dict{String,Any}   # a known-good agent input used by the verifier
    proposed_by::String          # principal id string "AGENT:planner"
    budget::Dict{String,Any}     # invocation budget (max_per_hour, max_amount_per_hour, amount_field); empty = none
end
Contract(id, v, d, i, e, s, sf, inv, n, p) = Contract(id, v, d, i, e, s, sf, inv, n, p, Dict{String,Any}())
function to_dict(c::Contract)
    Dict{String,Any}("capability_id" => c.capability_id, "version" => c.version, "description" => c.description,
        "inputs" => [to_dict(f) for f in c.inputs], "effects" => [string(e) for e in c.effects],
        "scope" => c.scope, "scope_field" => c.scope_field, "invariants" => c.invariants,
        "nominal_input" => c.nominal_input, "proposed_by" => c.proposed_by, "budget" => c.budget)
end
function contract_from_dict(d::Dict{String,Any})
    effs = EffectKind[]
    for e in get(d, "effects", Any[])
        k = effect_from_string(string(e))
        k === nothing && error("unknown effect: $e")
        push!(effs, k)
    end
    Contract(d["capability_id"], Int(get(d, "version", 1)), get(d, "description", ""),
        [fieldspec_from_dict(Dict{String,Any}(f)) for f in get(d, "inputs", Any[])],
        effs, get(d, "scope", "none"), get(d, "scope_field", ""),
        String[string(x) for x in get(d, "invariants", Any[])],
        Dict{String,Any}(get(d, "nominal_input", Dict{String,Any}())), get(d, "proposed_by", "unknown"),
        Dict{String,Any}(get(d, "budget", Dict{String,Any}())))
end
contract_hash(c::Contract) = sha(canonical(to_dict(c)))

# ------------------------------------------------------------------ dependency fingerprint

"""
Everything evidence depends on. If any component changes, evidence bound to the
old fingerprint no longer speaks for the capability (STALE).
"""
struct Fingerprint
    source::String     # hash of the app's action source artifact
    schema::String     # hash of the discovered surface (form)
    policy::String     # hash of the authority policy
    tests::String      # hash of the verifier + vectors
    contract::String   # hash of the accepted contract
end
to_dict(f::Fingerprint) = Dict{String,Any}("source" => f.source, "schema" => f.schema, "policy" => f.policy,
    "tests" => f.tests, "contract" => f.contract)
fingerprint_from_dict(d) = Fingerprint(d["source"], d["schema"], d["policy"], d["tests"], d["contract"])
fingerprint_hash(f::Fingerprint) = sha(canonical(to_dict(f)))

# ------------------------------------------------------------------ evidence

struct Probe
    label::String
    input::Dict{String,Any}
    status::Int
    observed_effects::Vector{String}
    touched::Vector{String}
    note::String
end
to_dict(p::Probe) = Dict{String,Any}("label" => p.label, "input" => p.input, "status" => p.status,
    "observed_effects" => p.observed_effects, "touched" => p.touched, "note" => p.note)
probe_from_dict(d) = Probe(d["label"], Dict{String,Any}(d["input"]), Int(d["status"]),
    String[string(x) for x in d["observed_effects"]], String[string(x) for x in d["touched"]], d["note"])

struct CheckResult
    name::String
    verdict::Verdict
    reason::String
    probes::Vector{Probe}
end
to_dict(c::CheckResult) = Dict{String,Any}("name" => c.name, "verdict" => string(c.verdict), "reason" => c.reason,
    "probes" => [to_dict(p) for p in c.probes])
checkresult_from_dict(d) = CheckResult(d["name"], verdict_from_string(d["verdict"]), d["reason"],
    [probe_from_dict(Dict{String,Any}(p)) for p in get(d, "probes", Any[])])

struct Evidence
    id::String
    capability_id::String
    contract_hash::String
    fingerprint::Fingerprint
    checks::Vector{CheckResult}
    mutants::Vector{Dict{String,Any}}   # {id, kind, expected, outcome, killed}
    verdict::Verdict
    mutation_score::Float64             # over must-kill mutants; 1.0 required
    produced_by::String                 # always "SYSTEM:verifier"
    hash::String
end
function to_dict(e::Evidence)
    Dict{String,Any}("id" => e.id, "capability_id" => e.capability_id, "contract_hash" => e.contract_hash,
        "fingerprint" => to_dict(e.fingerprint), "checks" => [to_dict(c) for c in e.checks],
        "mutants" => e.mutants, "verdict" => string(e.verdict), "mutation_score" => e.mutation_score,
        "produced_by" => e.produced_by, "hash" => e.hash)
end
evidence_from_dict(d) = Evidence(d["id"], d["capability_id"], d["contract_hash"],
    fingerprint_from_dict(d["fingerprint"]), [checkresult_from_dict(Dict{String,Any}(c)) for c in d["checks"]],
    [Dict{String,Any}(m) for m in d["mutants"]], verdict_from_string(d["verdict"]),
    Float64(d["mutation_score"]), d["produced_by"], d["hash"])

# ------------------------------------------------------------------ capability lifecycle

@enum CapState CANDIDATE CONTRACTED VERIFIED FAILED UNGRADED POLICY_BLOCKED LIVE STALE WITHDRAWN
const CAPSTATE_NAMES = Dict(string(s) => s for s in instances(CapState))
capstate_from_string(s) = CAPSTATE_NAMES[String(s)]

mutable struct Capability
    id::String
    candidate::Candidate
    state::CapState
    contract::Union{Contract,Nothing}
    contract_hash::String
    fingerprint::Union{Fingerprint,Nothing}
    evidence_id::String            # evidence that qualifies the current state ("" if none)
    promoted_by::String
    promotion_seq::Int             # ledger seq of the promotion act (0 if none)
    stale_reason::String
    history::Vector{String}        # human-readable transition log (derived, for UI)
end
function to_dict(c::Capability)
    Dict{String,Any}("id" => c.id, "candidate" => to_dict(c.candidate), "state" => string(c.state),
        "contract" => c.contract === nothing ? nothing : to_dict(c.contract), "contract_hash" => c.contract_hash,
        "fingerprint" => c.fingerprint === nothing ? nothing : to_dict(c.fingerprint),
        "evidence_id" => c.evidence_id, "promoted_by" => c.promoted_by, "promotion_seq" => c.promotion_seq,
        "stale_reason" => c.stale_reason, "history" => c.history)
end

# ------------------------------------------------------------------ decisions

"A typed refusal. `code` is from a closed vocabulary; `reasons` are concrete."
struct Refusal
    code::String
    reasons::Vector{String}
end
to_dict(r::Refusal) = Dict{String,Any}("code" => r.code, "reasons" => r.reasons)

struct Decision
    ok::Bool
    refusal::Union{Refusal,Nothing}
    detail::Dict{String,Any}
end
Decision(ok::Bool) = Decision(ok, nothing, Dict{String,Any}())
Decision(r::Refusal) = Decision(false, r, Dict{String,Any}())
to_dict(d::Decision) = Dict{String,Any}("ok" => d.ok, "refusal" => d.refusal === nothing ? nothing : to_dict(d.refusal), "detail" => d.detail)

from_dict(::Type{Contract}, d) = contract_from_dict(Dict{String,Any}(d))
from_dict(::Type{Candidate}, d) = candidate_from_dict(Dict{String,Any}(d))
from_dict(::Type{Evidence}, d) = evidence_from_dict(Dict{String,Any}(d))
from_dict(::Type{Fingerprint}, d) = fingerprint_from_dict(Dict{String,Any}(d))
from_dict(::Type{FieldSpec}, d) = fieldspec_from_dict(Dict{String,Any}(d))

end # module Model
