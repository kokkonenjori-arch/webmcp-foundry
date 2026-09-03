# ledger.jl — append-only, hash-chained event ledger + replayable store.
#
# Doctrine (Globulous/SMF): nothing mutates capability state except a validated
# event passing through `commit!`. State is a pure fold over events (`apply!`),
# so `replay(path)` reconstructs the store and its digest must match. Refusals
# are first-class events, not discarded.

module Ledger

using Dates
import ..JSON: canonical, json, parse_json
import ..Model
import ..Model: Capability, Candidate, Contract, Evidence, Fingerprint, CapState, Verdict, sha,
                CANDIDATE, CONTRACTED, VERIFIED, FAILED, UNGRADED, POLICY_BLOCKED, LIVE, STALE, WITHDRAWN,
                PASS, FAIL, UNGRADABLE, UNKNOWN, BLOCKED, INVALID, to_dict, from_dict, fingerprint_hash

export Event, Store, commit!, replay, verify_chain, digest, event_dict, all_events, LedgerError

struct LedgerError <: Exception
    msg::String
end
Base.showerror(io::IO, e::LedgerError) = print(io, "LedgerError: ", e.msg)

struct Event
    seq::Int
    prev::String
    at::String
    kind::String
    actor::String
    payload::Dict{String,Any}
    hash::String
end

event_dict(e::Event) = Dict{String,Any}("seq" => e.seq, "prev" => e.prev, "at" => e.at, "kind" => e.kind,
    "actor" => e.actor, "payload" => e.payload, "hash" => e.hash)

function event_hash(seq, prev, at, kind, actor, payload)
    sha(prev * "\n" * canonical(Dict{String,Any}("seq" => seq, "at" => at, "kind" => kind,
                                                  "actor" => actor, "payload" => payload)))
end

mutable struct Store
    path::String                       # "" for in-memory
    events::Vector{Event}
    capabilities::Dict{String,Capability}
    order::Vector{String}              # deterministic capability order (insertion)
    evidence::Dict{String,Evidence}
    clock::Function                    # () -> String; injectable for deterministic tests
end
Store(path::String=""; clock=() -> Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS.sssZ")) =
    Store(path, Event[], Dict{String,Capability}(), String[], Dict{String,Evidence}(), clock)

const GENESIS = "sha256:" * repeat("0", 64)

all_events(s::Store) = s.events

# ------------------------------------------------------------------ commit

const KINDS = Set(["DISCOVERED", "CONTRACT_ACCEPTED", "CONTRACT_REFUSED", "POLICY_BLOCKED",
    "EVIDENCE_RECORDED", "PROMOTED", "PROMOTION_REFUSED", "WITHDRAWN", "STALE",
    "INVOKED", "INVOCATION_REFUSED", "RESCAN", "HOST_REPORT"])

"""
    commit!(store, kind, actor, payload) -> Event

Validates the event against the current state (apply! on a copy would be ideal;
here apply! itself throws before mutating), appends it to the chain, applies it,
and persists it. Throws LedgerError on invalid transitions.
"""
function commit!(s::Store, kind::String, actor::String, payload::Dict{String,Any})
    kind in KINDS || throw(LedgerError("unknown event kind $kind"))
    seq = length(s.events) + 1
    prev = isempty(s.events) ? GENESIS : s.events[end].hash
    at = s.clock()
    # canonical round-trip so that in-memory and replayed payloads are identical
    payload = parse_json(canonical(payload))
    ev = Event(seq, prev, at, kind, actor, payload, event_hash(seq, prev, at, kind, actor, payload))
    check!(s, ev)              # throws before any mutation
    apply!(s, ev)
    push!(s.events, ev)
    if !isempty(s.path)
        open(s.path, "a") do io
            write(io, canonical(event_dict(ev)), "\n")
        end
    end
    ev
end

cap(s::Store, id) = get(s.capabilities, id) do
    throw(LedgerError("unknown capability $id"))
end

# Pre-conditions: every rule here is a state-machine invariant, not policy.
function check!(s::Store, ev::Event)
    p = ev.payload
    k = ev.kind
    if k == "DISCOVERED"
        haskey(p, "candidate") || throw(LedgerError("DISCOVERED needs candidate"))
    elseif k == "CONTRACT_ACCEPTED"
        c = cap(s, p["capability_id"])
        c.state in (CANDIDATE, CONTRACTED, FAILED, UNGRADED, STALE, WITHDRAWN, POLICY_BLOCKED, VERIFIED) ||
            throw(LedgerError("contract cannot be replaced while $(c.state); withdraw first"))
        haskey(p, "fingerprint") || throw(LedgerError("CONTRACT_ACCEPTED needs fingerprint"))
    elseif k == "POLICY_BLOCKED"
        cap(s, p["capability_id"])
    elseif k == "EVIDENCE_RECORDED"
        e = from_dict(Evidence, p["evidence"])
        c = cap(s, e.capability_id)
        c.contract === nothing && throw(LedgerError("no contract to evidence"))
        c.fingerprint === nothing && throw(LedgerError("no fingerprint bound"))
        e.produced_by == "SYSTEM:verifier" || throw(LedgerError("evidence must be produced by SYSTEM:verifier, got $(e.produced_by)"))
        e.contract_hash == c.contract_hash ||
            throw(LedgerError("evidence contract hash $(e.contract_hash) != bound contract $(c.contract_hash)"))
        fingerprint_hash(e.fingerprint) == fingerprint_hash(c.fingerprint) ||
            throw(LedgerError("evidence fingerprint does not match the capability's current dependency fingerprint"))
        c.state in (CONTRACTED, VERIFIED, FAILED, UNGRADED, STALE) ||
            throw(LedgerError("cannot record evidence while $(c.state)"))
    elseif k == "PROMOTED"
        c = cap(s, p["capability_id"])
        c.state == VERIFIED || throw(LedgerError("only VERIFIED capabilities can be promoted (state=$(c.state))"))
        haskey(s.evidence, p["evidence_id"]) || throw(LedgerError("unknown evidence"))
        e = s.evidence[p["evidence_id"]]
        e.verdict == PASS || throw(LedgerError("evidence verdict is $(e.verdict), not PASS"))
        e.id == c.evidence_id || throw(LedgerError("evidence is not the one bound to this capability"))
        fingerprint_hash(e.fingerprint) == fingerprint_hash(c.fingerprint) ||
            throw(LedgerError("evidence fingerprint stale"))
    elseif k == "WITHDRAWN"
        c = cap(s, p["capability_id"])
        c.state in (LIVE, VERIFIED, CONTRACTED, STALE, FAILED, UNGRADED) || throw(LedgerError("cannot withdraw from $(c.state)"))
    elseif k == "STALE"
        c = cap(s, p["capability_id"])
        c.fingerprint === nothing && throw(LedgerError("no fingerprint to stale"))
        haskey(p, "new_fingerprint") || throw(LedgerError("STALE needs new_fingerprint"))
    elseif k == "INVOKED"
        c = cap(s, p["capability_id"])
        c.state == LIVE || throw(LedgerError("capability is not LIVE"))
    end
    nothing
end

short(s::AbstractString, a::Int=1, b::Int=12) = s[a:min(end, b)]

function note!(c::Capability, ev::Event, msg::String)
    push!(c.history, "#$(ev.seq) $(ev.at) [$(ev.actor)] $msg")
end

function apply!(s::Store, ev::Event)
    p = ev.payload
    k = ev.kind
    if k == "DISCOVERED"
        cand = from_dict(Candidate, p["candidate"])
        if haskey(s.capabilities, cand.id)
            c = s.capabilities[cand.id]
            c.candidate = cand
            note!(c, ev, "re-discovered (surface $(short(cand.surface_hash, 8, 19)))")
        else
            c = Capability(cand.id, cand, CANDIDATE, nothing, "", nothing, "", "", 0, "", String[])
            s.capabilities[cand.id] = c
            push!(s.order, cand.id)
            note!(c, ev, "discovered from $(cand.action.method) $(cand.action.path)")
        end
    elseif k == "CONTRACT_ACCEPTED"
        c = s.capabilities[p["capability_id"]]
        c.contract = from_dict(Contract, p["contract"])
        c.contract_hash = p["contract_hash"]
        c.fingerprint = from_dict(Fingerprint, p["fingerprint"])
        c.evidence_id = ""
        c.promoted_by = ""; c.promotion_seq = 0; c.stale_reason = ""
        c.state = CONTRACTED
        note!(c, ev, "contract v$(c.contract.version) accepted ($(short(c.contract_hash, 8, 19))); proposed by $(c.contract.proposed_by)")
    elseif k == "CONTRACT_REFUSED"
        c = s.capabilities[p["capability_id"]]
        note!(c, ev, "contract proposal REFUSED: $(p["refusal"]["code"])")
    elseif k == "POLICY_BLOCKED"
        c = s.capabilities[p["capability_id"]]
        c.state = POLICY_BLOCKED
        c.stale_reason = p["refusal"]["code"]
        note!(c, ev, "POLICY_BLOCKED: $(join(p["refusal"]["reasons"], "; "))")
    elseif k == "EVIDENCE_RECORDED"
        e = from_dict(Evidence, p["evidence"])
        s.evidence[e.id] = e
        c = s.capabilities[e.capability_id]
        c.evidence_id = e.id
        if e.verdict == PASS
            c.state = VERIFIED
        elseif e.verdict == FAIL
            c.state = FAILED
        else
            c.state = UNGRADED
        end
        c.stale_reason = ""
        note!(c, ev, "evidence $(short(e.id)) verdict=$(e.verdict) mutation_score=$(e.mutation_score) -> $(c.state)")
    elseif k == "PROMOTED"
        c = s.capabilities[p["capability_id"]]
        c.state = LIVE
        c.promoted_by = p["by"]
        c.promotion_seq = ev.seq
        note!(c, ev, "PROMOTED to LIVE by $(p["by"]) on evidence $(short(p["evidence_id"]))")
    elseif k == "PROMOTION_REFUSED"
        c = s.capabilities[p["capability_id"]]
        note!(c, ev, "promotion by $(p["by"]) REFUSED: $(p["refusal"]["code"]) — $(join(p["refusal"]["reasons"], "; "))")
    elseif k == "WITHDRAWN"
        c = s.capabilities[p["capability_id"]]
        c.state = WITHDRAWN
        c.promoted_by = ""; c.promotion_seq = 0
        note!(c, ev, "WITHDRAWN by $(p["by"]): $(p["reason"])")
    elseif k == "STALE"
        c = s.capabilities[p["capability_id"]]
        was = c.state
        c.state = STALE
        c.stale_reason = p["reason"]
        c.fingerprint = from_dict(Fingerprint, p["new_fingerprint"])
        c.evidence_id = ""           # evidence detached: it spoke for the old fingerprint
        c.promoted_by = ""; c.promotion_seq = 0
        note!(c, ev, "STALE (was $was): $(p["reason"]); exposure withdrawn, fresh evidence required")
    elseif k == "INVOKED"
        c = s.capabilities[p["capability_id"]]
        note!(c, ev, "invoked by $(p["by"]) -> status $(p["status"])")
    elseif k == "INVOCATION_REFUSED"
        if haskey(s.capabilities, get(p, "capability_id", ""))
            note!(s.capabilities[p["capability_id"]], ev, "invocation by $(p["by"]) REFUSED: $(p["refusal"]["code"])")
        end
    elseif k == "RESCAN"
        # informational; per-capability consequences are separate STALE events
    elseif k == "HOST_REPORT"
        # a browser host's account of what it has registered / executed; graded by host_acceptance, never state-changing
    end
    nothing
end

# ------------------------------------------------------------------ replay / integrity

function verify_chain(events::Vector{Event})
    prev = GENESIS
    for (i, e) in enumerate(events)
        e.seq == i || return (false, "seq gap at $i")
        e.prev == prev || return (false, "prev mismatch at #$i")
        h = event_hash(e.seq, e.prev, e.at, e.kind, e.actor, e.payload)
        h == e.hash || return (false, "hash mismatch at #$i")
        prev = e.hash
    end
    (true, "ok ($(length(events)) events)")
end

function load_events(path::String)
    evs = Event[]
    isfile(path) || return evs
    for line in eachline(path)
        isempty(strip(line)) && continue
        d = parse_json(line)
        push!(evs, Event(Int(d["seq"]), d["prev"], d["at"], d["kind"], d["actor"], Dict{String,Any}(d["payload"]), d["hash"]))
    end
    evs
end

"replay(path) -> Store   Rebuilds state purely from the persisted chain (fails closed on a broken chain)."
function replay(path::String; clock=nothing)
    evs = load_events(path)
    ok, msg = verify_chain(evs)
    ok || throw(LedgerError("ledger chain invalid: $msg"))
    s = clock === nothing ? Store(path) : Store(path; clock=clock)
    for e in evs
        apply!(s, e)
        push!(s.events, e)
    end
    s
end

"digest(store) — sha over the full authoritative state in fixed order (equality certificate)."
function digest(s::Store)
    caps = [to_dict(s.capabilities[id]) for id in s.order]
    for c in caps
        delete!(c, "history")   # history is derived presentation, not authoritative state
    end
    evid = [to_dict(s.evidence[k]) for k in sort!(collect(keys(s.evidence)))]
    sha(canonical(Dict{String,Any}("capabilities" => caps, "evidence" => evid, "n" => length(s.events),
                                   "head" => isempty(s.events) ? GENESIS : s.events[end].hash)))
end

end # module Ledger
