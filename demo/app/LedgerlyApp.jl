# LedgerlyApp.jl — the human-facing demonstration application ("Ledgerly").
#
# This is the TARGET of the Foundry, not part of it. It is an ordinary small web
# app: HTML forms for humans, POST handlers, sessions, in-memory state. It knows
# nothing about capabilities or verdicts. Two things make it Foundry-verifiable:
#
#   1. Its action handlers live in separate source files (actions/*.jl) that are
#      hot-reloadable; the app reports their digests at /__oracle/sources. That is
#      the "source dependency" Foundry fingerprints.
#   2. In test mode it exposes the Foundry Oracle Protocol (/__oracle/*): a
#      deterministic state snapshot and reset. Foundry NEVER calls handlers in
#      process; everything crosses TCP.
#
# The page also loads /webmcp-bridge.js, which registers navigator.modelContext
# tools from Foundry's manifest of LIVE capabilities — nothing else.

module LedgerlyApp

using SHA
import ..JSON: json, canonical, parse_json
import ..Http
import ..Http: Request, Response, json_response, text_response, static_response, header, parse_query

export start!, stop!, AppState, reset!, ACTIONS_DIR

const APP_DIR = @__DIR__
const ACTIONS_DIR = joinpath(APP_DIR, "actions")
const ACTION_NAMES = ["search_transactions", "add_note", "apply_adjustment", "transfer_funds",
                      "delete_account", "share_report"]

mutable struct AppState
    accounts::Dict{String,Dict{String,Any}}
    transactions::Vector{Dict{String,Any}}
    audit::Vector{String}
    outbox::Vector{Dict{String,Any}}
    next_id::Int
end

const SESSIONS = Dict("sess-jori" => "jori", "sess-sam" => "sam")

function seed_state()
    AppState(Dict(
        "A1" => Dict{String,Any}("id" => "A1", "name" => "Jori · Operating", "owner" => "jori", "balance_cents" => 50000, "notes" => Any[]),
        "A2" => Dict{String,Any}("id" => "A2", "name" => "Sam · Travel", "owner" => "sam", "balance_cents" => 12000, "notes" => Any[]),
        "A3" => Dict{String,Any}("id" => "A3", "name" => "Jori · Reserve", "owner" => "jori", "balance_cents" => 8000, "notes" => Any[]),
    ), [
        Dict{String,Any}("id" => "T1", "account" => "A1", "amount_cents" => 50000, "memo" => "opening balance", "kind" => "credit"),
        Dict{String,Any}("id" => "T2", "account" => "A2", "amount_cents" => 12000, "memo" => "opening balance", "kind" => "credit"),
        Dict{String,Any}("id" => "T3", "account" => "A3", "amount_cents" => 8000, "memo" => "opening balance", "kind" => "credit"),
        Dict{String,Any}("id" => "T4", "account" => "A1", "amount_cents" => -1250, "memo" => "coffee beans", "kind" => "debit"),
    ], String[], Dict{String,Any}[], 5)
end

const STATE = Ref{AppState}(seed_state())
const ORACLE = Ref{Bool}(false)
const FOUNDRY_URL = Ref{String}("http://127.0.0.1:8090")

reset!() = (STATE[] = seed_state(); nothing)

newid!(st::AppState, prefix) = (id = "$prefix$(st.next_id)"; st.next_id += 1; id)

# ------------------------------------------------------------------ action sources

"Load (or re-load) every handler file. Handlers are `handle_<name>(state, user, input)`."
function load_actions!()
    for n in ACTION_NAMES
        path = joinpath(ACTIONS_DIR, n * ".jl")
        # the demo swaps versioned handlers in and out; a fresh clone starts from v1
        isfile(path) || cp(joinpath(ACTIONS_DIR, n * ".v1.jl"), path)
        Base.include(@__MODULE__, path)
    end
    nothing
end

source_digest(name) = "sha256:" * bytes2hex(sha256(read(joinpath(ACTIONS_DIR, name * ".jl"))))
sources() = Dict{String,Any}("actions/$n.jl" => source_digest(n) for n in ACTION_NAMES)

# ------------------------------------------------------------------ oracle snapshot

"Deterministic snapshot of authoritative state. External hand-offs are reported as counters only."
function snapshot(st::AppState)
    Dict{String,Any}(
        "resources" => Dict{String,Any}("account" => Dict{String,Any}(k => v for (k, v) in st.accounts)),
        "records" => Dict{String,Any}("transaction" => st.transactions, "audit_count" => length(st.audit)),
        "external" => Dict{String,Any}("outbox_count" => length(st.outbox), "observability" => "partial"),
    )
end

# ------------------------------------------------------------------ request handling

function parse_input(req::Request)
    ct = header(req, "content-type")
    body = String(copy(req.body))
    d = Dict{String,String}()
    if startswith(ct, "application/json") && !isempty(body)
        for (k, v) in parse_json(body)
            d[String(k)] = v === nothing ? "" : (v isa Bool ? (v ? "1" : "0") : string(v))
        end
    elseif !isempty(body)
        merge!(d, parse_query(body))
    end
    merge!(d, req.query)   # query params also count (GET forms)
    d
end

function session_user(req::Request)
    tok = header(req, "x-session")
    if isempty(tok)
        ck = header(req, "cookie")
        m = match(r"session=([A-Za-z0-9_-]+)", ck)
        m === nothing || (tok = m.captures[1])
    end
    get(SESSIONS, tok, nothing)
end

function handle(req::Request)
    p = req.path
    if p == "/" || p == "/index.html"
        return static_response(joinpath(APP_DIR, "page.html"))
    elseif p in ("/webmcp-bridge.js", "/webmcp-polyfill.js")
        # Foundry's client-side artifact, vendored by the app (single source of truth in web/)
        return static_response(normpath(joinpath(APP_DIR, "..", "..", "web", p[2:end])))
    elseif p == "/app.js"
        return static_response(joinpath(APP_DIR, "app.js"))
    elseif p == "/api/config"
        return json_response(200, json(Dict("foundry_url" => FOUNDRY_URL[], "app" => "ledgerly")))
    elseif p == "/api/me"
        u = session_user(req)
        u === nothing && return json_response(401, json(Dict("error" => "no session")))
        st = STATE[]
        owned = sort!([k for (k, a) in st.accounts if a["owner"] == u])
        return json_response(200, json(Dict("user_id" => u, "default_account" => isempty(owned) ? "" : owned[1],
                                            "accounts" => owned)))
    elseif p == "/api/state"
        u = session_user(req)
        u === nothing && return json_response(401, json(Dict("error" => "no session")))
        return json_response(200, json(snapshot(STATE[])))
    elseif startswith(p, "/actions/")
        name = p[length("/actions/")+1:end]
        name in ACTION_NAMES || return json_response(404, json(Dict("error" => "unknown action")))
        u = session_user(req)
        u === nothing && return json_response(401, json(Dict("error" => "authentication required")))
        input = parse_input(req)
        fn = Base.invokelatest(getglobal, @__MODULE__, Symbol("handle_" * name))
        status, out = Base.invokelatest(fn, STATE[], u, input)
        return json_response(status, json(out))
    elseif startswith(p, "/__oracle/")
        ORACLE[] || return json_response(404, json(Dict("error" => "oracle disabled")))
        sub = p[length("/__oracle/")+1:end]
        if sub == "snapshot"
            return json_response(200, canonical(snapshot(STATE[])))
        elseif sub == "reset"
            reset!(); return json_response(200, json(Dict("ok" => true)))
        elseif sub == "reload"
            load_actions!(); return json_response(200, json(Dict("ok" => true, "sources" => sources())))
        elseif sub == "sources"
            return json_response(200, canonical(sources()))
        elseif startswith(sub, "source/")
            n = sub[length("source/")+1:end]
            n in ACTION_NAMES || return text_response(404, "no such action")
            return text_response(200, read(joinpath(ACTIONS_DIR, n * ".jl"), String))
        end
    end
    text_response(404, "not found")
end

const SERVER = Ref{Any}(nothing)

function start!(port::Int; oracle::Bool=false, foundry_url::String="http://127.0.0.1:8090")
    ORACLE[] = oracle
    FOUNDRY_URL[] = foundry_url
    load_actions!()
    SERVER[] = Http.serve!(handle, port)
    SERVER[]
end
stop!() = (SERVER[] === nothing || Http.stop!(SERVER[]); SERVER[] = nothing)

end # module LedgerlyApp
