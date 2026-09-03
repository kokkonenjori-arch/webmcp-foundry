# gates.jl — deterministic gates. Proposals are not state transitions; gates are.
#
#   contract_gate   : is the proposed contract an acceptable engineered artifact?
#   policy_block    : does authority policy forbid exposing this effect class at all?
#   promotion_gate  : may THIS principal promote THIS capability on THIS evidence?
#   staleness       : does the current dependency fingerprint still match?
#
# Every refusal is typed (closed code vocabulary) with concrete reasons.

module Gates

import ..Model
import ..Model: Contract, Candidate, Capability, Evidence, Principal, Refusal, Decision, Fingerprint,
                Actor, HUMAN, AGENT, SYSTEM, EffectKind, effect_rank, effect_from_string,
                AGENT_BOUND, SESSION_BOUND, FIXED_BOUND, HUMAN_ONLY, Verdict, PASS, CapState, VERIFIED, LIVE,
                fingerprint_hash
import ..Minimize: identity_like

export contract_gate, policy_block, promotion_gate, required_authority, staleness, REFUSAL_CODES

const REFUSAL_CODES = ["OVER_BROAD", "UNCONSTRAINED", "NOT_AGENT_EXPOSABLE", "SCOPE_UNDECLARED",
    "INVARIANTS_MISSING", "EFFECT_FORBIDDEN", "NO_EVIDENCE", "EVIDENCE_NOT_PASS", "EVIDENCE_STALE",
    "AUTHORITY_INSUFFICIENT", "SELF_RATIFICATION", "ROLE_MISSING", "NOT_VERIFIED", "MUTATION_SCORE",
    "CHECKS_MISSING", "PROPOSER_NOT_ALLOWED", "SCHEMA_INVALID"]

max_effect(effects::Vector{EffectKind}) = isempty(effects) ? nothing : effects[argmax(effect_rank.(effects))]
sh(s::AbstractString) = s[min(8, end):min(end, 19)]   # short hash for messages

# ------------------------------------------------------------------ contract gate

function contract_gate(k::Contract, cand::Candidate, policy::Dict{String,Any})
    rules = policy["contract_rules"]
    reasons = String[]
    code = ""
    push_reason!(c, r) = (isempty(code) && (code = c); push!(reasons, r))
    known = Set(f.name for f in cand.fields)
    for f in k.inputs
        f.name in known || push_reason!("SCHEMA_INVALID", "input '$(f.name)' is not a control of the discovered surface")
    end
    for f in k.inputs
        if f.origin == "hidden" && f.binding == AGENT_BOUND && !rules["hidden_fields_may_be_agent_bound"]
            push_reason!("OVER_BROAD", "hidden control '$(f.name)' is agent-controlled")
        end
        if f.binding == AGENT_BOUND && identity_like(f.name, rules["identity_field_pattern"])
            push_reason!("OVER_BROAD", "identity control '$(f.name)' is agent-controlled (an agent acts as the human; it does not choose who)")
        end
        if f.binding == AGENT_BOUND && rules["require_constraints"]
            c = f.constraints
            if f.type == "integer" && !(haskey(c, "minimum") && haskey(c, "maximum"))
                push_reason!("UNCONSTRAINED", "integer control '$(f.name)' lacks minimum/maximum")
            elseif f.type == "string" && !(haskey(c, "maxLength") || haskey(c, "enum"))
                push_reason!("UNCONSTRAINED", "string control '$(f.name)' lacks maxLength")
            elseif f.type == "enum" && isempty(get(c, "enum", []))
                push_reason!("UNCONSTRAINED", "enum control '$(f.name)' has no options")
            end
        end
        if f.binding == HUMAN_ONLY && f.required
            push_reason!("NOT_AGENT_EXPOSABLE", "required control '$(f.name)' is human-only; the capability cannot be completed by an agent")
        end
    end
    nagent = count(f -> f.binding == AGENT_BOUND, k.inputs)
    nagent > rules["max_agent_fields"] && push_reason!("OVER_BROAD", "$nagent agent-controlled fields exceed policy maximum $(rules["max_agent_fields"])")
    isempty(k.effects) && push_reason!("SCHEMA_INVALID", "contract declares no effects (empty bound establishes nothing)")
    me = max_effect(k.effects)
    if me !== nothing && effect_rank(me) > 0 && k.scope == "any"
        push_reason!("SCOPE_UNDECLARED", "non-READ contract with scope 'any' — declare a resource scope")
    end
    if me !== nothing && string(me) == "FINANCIAL"
        "nonnegative_balance" in k.invariants || push_reason!("INVARIANTS_MISSING", "FINANCIAL contract must declare invariant 'nonnegative_balance'")
    end
    "no_effect_on_rejection" in k.invariants || push_reason!("INVARIANTS_MISSING", "every contract must declare 'no_effect_on_rejection'")
    isempty(reasons) ? Decision(true) : Decision(Refusal(code, reasons))
end

# ------------------------------------------------------------------ policy block

"Reasons policy forbids exposing this contract as an agent capability at all (empty = allowed)."
function policy_block(k::Contract, policy::Dict{String,Any})
    reasons = String[]
    for e in k.effects
        rule = get(policy["promotion"], string(e), nothing)
        rule === nothing && (push!(reasons, "no policy for effect $(e): fail closed"); continue)
        rule["min_actor"] == "FORBIDDEN" && push!(reasons, "effect $(e) is FORBIDDEN for agent exposure by policy")
    end
    reasons
end

# ------------------------------------------------------------------ authority

"The promotion rule that governs a contract: keyed by its maximum-consequence effect."
function required_authority(k::Contract, policy::Dict{String,Any})
    me = max_effect(k.effects)
    me === nothing && return Dict{String,Any}("min_actor" => "FORBIDDEN", "roles" => [], "separation" => true)
    Dict{String,Any}(policy["promotion"][string(me)])
end

actor_rank(a::Actor) = a == AGENT ? 1 : (a == HUMAN ? 2 : 0)   # SYSTEM never promotes
actor_rank(s::String) = s == "AGENT" ? 1 : (s == "HUMAN" ? 2 : (s == "FORBIDDEN" ? 99 : 0))

function promotion_gate(cap::Capability, who::Principal, evidence::Union{Evidence,Nothing},
                        current_fp::Fingerprint, policy::Dict{String,Any})
    reasons = String[]
    code = ""
    push_reason!(c, r) = (isempty(code) && (code = c); push!(reasons, r))
    k = cap.contract
    k === nothing && return Decision(Refusal("NOT_VERIFIED", ["no accepted contract"]))
    # 1. evidence
    if evidence === nothing
        push_reason!("NO_EVIDENCE", "no evidence bound to the capability")
    else
        evidence.verdict == PASS || push_reason!("EVIDENCE_NOT_PASS", "evidence verdict is $(evidence.verdict); only PASS establishes")
        evidence.contract_hash == cap.contract_hash || push_reason!("EVIDENCE_STALE", "evidence is for contract $(sh(evidence.contract_hash)), bound contract is $(sh(cap.contract_hash))")
        fingerprint_hash(evidence.fingerprint) == fingerprint_hash(current_fp) ||
            push_reason!("EVIDENCE_STALE", "dependency fingerprint changed since evidence was produced")
        evidence.mutation_score >= policy["evidence"]["require_mutation_score"] ||
            push_reason!("MUTATION_SCORE", "mutation score $(evidence.mutation_score) below required $(policy["evidence"]["require_mutation_score"])")
        have = Set(c.name for c in evidence.checks)
        for req in policy["evidence"]["required_checks"]
            req in have || push_reason!("CHECKS_MISSING", "required check '$req' absent from evidence")
        end
    end
    cap.state == VERIFIED || push_reason!("NOT_VERIFIED", "capability state is $(cap.state), not VERIFIED")
    # 2. authority
    rule = required_authority(k, policy)
    who.kind == SYSTEM && push_reason!("AUTHORITY_INSUFFICIENT", "SYSTEM principals never promote (authority is human or delegated)")
    if rule["min_actor"] == "FORBIDDEN"
        push_reason!("EFFECT_FORBIDDEN", "effect class $(max_effect(k.effects)) may never be agent-exposed")
    elseif actor_rank(who.kind) < actor_rank(String(rule["min_actor"]))
        push_reason!("AUTHORITY_INSUFFICIENT", "$(max_effect(k.effects)) capabilities require a $(rule["min_actor"]) promoter; $(who.kind):$(who.id) is $(who.kind)")
    end
    for r in rule["roles"]
        r in who.roles || push_reason!("ROLE_MISSING", "promoter lacks role '$r' required for $(max_effect(k.effects))")
    end
    if rule["separation"]
        proposer = k.proposed_by
        me = "$(who.kind):$(who.id)"
        proposer == me && push_reason!("SELF_RATIFICATION", "proposer $proposer may not promote their own contract (authority separation)")
        # an agent promoting anything an agent proposed is still self-ratification of the agent plane
        who.kind == AGENT && startswith(proposer, "AGENT:") && push_reason!("SELF_RATIFICATION", "agent plane cannot ratify agent-plane proposals")
    end
    isempty(reasons) ? Decision(true, nothing, Dict{String,Any}("rule" => rule)) : Decision(Refusal(code, reasons))
end

# ------------------------------------------------------------------ staleness

"Compare a capability's bound fingerprint with the current one; return (stale?, reasons)."
function staleness(bound::Fingerprint, current::Fingerprint)
    reasons = String[]
    bound.source != current.source && push!(reasons, "source changed ($(sh(bound.source)) -> $(sh(current.source)))")
    bound.schema != current.schema && push!(reasons, "surface schema changed ($(sh(bound.schema)) -> $(sh(current.schema)))")
    bound.policy != current.policy && push!(reasons, "authority policy changed ($(sh(bound.policy)) -> $(sh(current.policy)))")
    bound.tests != current.tests && push!(reasons, "verifier changed ($(sh(bound.tests)) -> $(sh(current.tests)))")
    bound.contract != current.contract && push!(reasons, "contract changed")
    (!isempty(reasons), reasons)
end

end # module Gates
