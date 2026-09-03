# minimize.jl — narrow an over-broad agent input surface.
#
# The SYSTEM proposes a minimized contract deterministically from a candidate;
# agents may propose their own. Either way the CONTRACT GATE (gates.jl) decides.
# Minimization rules (all recorded in the diff so the narrowing is inspectable):
#   R1 hidden controls are never agent-controlled: identity-like -> SESSION_BOUND,
#      otherwise FIXED_BOUND at the page's default value.
#   R2 principal-identity visible fields (author, user, owner ...) are
#      SESSION_BOUND — an agent acts *as* the human, it does not choose who.
#      Visible RESOURCE selectors (a <select> of accounts) stay agent-choosable
#      within their enum: which of the human's resources to act on is a legitimate
#      agent decision, and whether the app enforces ownership is exactly what the
#      adversarial scope check must prove — minimization must not hide that.
#   R3 select controls keep their enum; number controls keep min/max; free text
#      gets a maxLength ceiling (policy.max_string_length) if the page gave none.
#   R4 human-only controls (data-human-only) become HUMAN_ONLY and make the
#      capability non-exposable unless the field is optional.
#   R5 the scope field (data-scope hint) is recorded; scope is never widened here.

module Minimize

import ..Model: Candidate, Contract, FieldSpec, Binding, AGENT_BOUND, SESSION_BOUND, FIXED_BOUND, HUMAN_ONLY,
                EffectKind, effect_from_string, READ, WRITE_OWN

export minimize, identity_like, naive_contract, minimization_diff

identity_like(name::AbstractString, pattern::AbstractString) = occursin(Regex(pattern), name)

const SESSION_KEYS = Dict("account_id" => "default_account", "from_account" => "default_account",
                          "author" => "user_id", "user" => "user_id", "owner" => "user_id", "session" => "user_id")

function minimize_field(f::FieldSpec, rules::Dict{String,Any})
    cons = copy(f.constraints)
    pat = rules["identity_field_pattern"]
    if f.origin == "human-only"
        return FieldSpec(f.name, f.type, HUMAN_ONLY, f.required, cons, f.origin), "R4 human-only control -> HUMAN_ONLY"
    end
    if f.origin == "hidden"
        if haskey(SESSION_KEYS, f.name) || identity_like(f.name, pat)
            cons["session_key"] = get(SESSION_KEYS, f.name, "user_id")
            delete!(cons, "default")
            return FieldSpec(f.name, f.type, SESSION_BOUND, true, cons, f.origin), "R1 hidden identity/resource control -> SESSION_BOUND($(cons["session_key"]))"
        else
            cons["fixed"] = get(cons, "default", "")
            delete!(cons, "default")
            return FieldSpec(f.name, f.type, FIXED_BOUND, true, cons, f.origin), "R1 hidden control -> FIXED_BOUND($(repr(cons["fixed"])))"
        end
    end
    if identity_like(f.name, pat)
        cons["session_key"] = get(SESSION_KEYS, f.name, "user_id")
        delete!(cons, "enum")
        return FieldSpec(f.name, f.type, SESSION_BOUND, true, cons, f.origin), "R2 identity-like visible control -> SESSION_BOUND($(cons["session_key"]))"
    end
    note = "kept AGENT_BOUND"
    if f.type == "string" && !haskey(cons, "maxLength") && !haskey(cons, "enum")
        cons["maxLength"] = rules["max_string_length"]
        note = "R3 free text ceiling maxLength=$(cons["maxLength"])"
    end
    FieldSpec(f.name, f.type, AGENT_BOUND, f.required, cons, f.origin), note
end

"System-proposed minimized contract for a candidate. Deterministic."
function minimize(c::Candidate, rules::Dict{String,Any}; proposed_by::String="SYSTEM:minimizer", version::Int=1)
    fields = FieldSpec[]
    notes = String[]
    for f in c.fields
        nf, note = minimize_field(f, rules)
        push!(fields, nf); push!(notes, "$(f.name): $note")
    end
    eff = effect_from_string(get(c.hints, "effect", ""))
    effects = eff === nothing ? (c.action.method == "GET" ? [READ] : [WRITE_OWN]) : [eff]
    scope = get(c.hints, "scope", eff == READ ? "own_account" : "own_account")
    scope_field = ""
    rpat = get(rules, "scope_field_pattern", "(^|_)(account_id|from_account)(\$|_)")   # the ACTED-ON resource, not a destination
    for f in fields   # prefer an agent-choosable resource selector; else the session-bound one
        f.binding == AGENT_BOUND && identity_like(f.name, rpat) && (scope_field = f.name; break)
    end
    if isempty(scope_field)
        for f in fields
            f.binding == SESSION_BOUND && identity_like(f.name, rpat) && (scope_field = f.name; break)
        end
    end
    nominal = Dict{String,Any}()
    for f in fields
        f.binding == AGENT_BOUND || continue
        if f.type == "integer"
            lo = get(f.constraints, "minimum", 1); hi = get(f.constraints, "maximum", 100)
            nominal[f.name] = clamp(lo > 0 ? lo : (hi >= 1 ? 1 : lo), lo, hi)
        elseif f.type == "enum"
            nominal[f.name] = first(f.constraints["enum"])
        elseif f.type == "boolean"
            nominal[f.name] = false
        elseif get(f.constraints, "format", "") == "email"
            nominal[f.name] = "verifier@example.com"
        else
            nominal[f.name] = "foundry nominal"
        end
    end
    invariants = default_invariants(effects)
    for inv in split(get(c.hints, "invariants", ""), ','; keepempty=false)
        push!(invariants, String(strip(inv)))
    end
    contract = Contract(c.id, version, "Minimized contract for $(c.title) ($(c.action.method) $(c.action.path))",
        fields, effects, scope, scope_field, unique(invariants), nominal, proposed_by)
    contract, notes
end

function default_invariants(effects::Vector{EffectKind})
    inv = ["no_effect_on_rejection", "hidden_not_agent"]
    any(e -> string(e) == "FINANCIAL", effects) && push!(inv, "nonnegative_balance")
    inv
end

"A deliberately naive proposal: every discovered control agent-bound, as-is. (What an unengineered agent surface looks like.)"
function naive_contract(c::Candidate; proposed_by::String="AGENT:planner")
    eff = effect_from_string(get(c.hints, "effect", ""))
    effects = eff === nothing ? [READ] : [eff]
    nominal = Dict{String,Any}()
    for f in c.fields
        nominal[f.name] = get(f.constraints, "default", f.type == "integer" ? 1 : "x")
    end
    Contract(c.id, 1, "Naive contract: every form control agent-controlled", c.fields, effects,
             get(c.hints, "scope", "any"), "", String[], nominal, proposed_by)
end

"Structured diff between a candidate surface and a contract (for UI + evidence)."
function minimization_diff(c::Candidate, k::Contract)
    before = Dict(f.name => f for f in c.fields)
    rows = Dict{String,Any}[]
    for f in k.inputs
        b = get(before, f.name, nothing)
        push!(rows, Dict{String,Any}("field" => f.name, "origin" => f.origin,
            "before" => b === nothing ? "absent" : "AGENT_BOUND " * (isempty(b.constraints) ? "(unconstrained)" : string(b.constraints)),
            "after" => string(f.binding) * " " * string(f.constraints)))
    end
    Dict{String,Any}("agent_fields_before" => count(f -> f.binding == AGENT_BOUND, c.fields),
                     "agent_fields_after" => count(f -> f.binding == AGENT_BOUND, k.inputs), "rows" => rows)
end

end # module Minimize
