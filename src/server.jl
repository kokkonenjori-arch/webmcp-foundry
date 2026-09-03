# server.jl — the Foundry's HTTP boundary: JSON API + console UI + WebMCP gateway.

module Server

import ..JSON: json, canonical, parse_json
import ..Http
import ..Http: Request, Response, json_response, text_response, static_response, header
import ..Model: to_dict, Decision, Principal, AGENT, HUMAN, SYSTEM
import ..Ledger
import ..FoundryCore
import ..FoundryCore: Foundry, principal_from_token, discover!, propose_contract!, verify!, promote!, withdraw!,
                      rescan!, manifest, invoke!, capability_view, status, anonymous, host_report!, host_acceptance, latest_host_report, host_invariant

export start!, WEB_DIR

const WEB_DIR = normpath(joinpath(@__DIR__, "..", "web"))

const CORS = ["Access-Control-Allow-Origin" => "*",
              "Access-Control-Allow-Headers" => "Content-Type, X-Foundry-Token, X-Foundry-Session, X-Foundry-Host",
              "Access-Control-Allow-Methods" => "GET, POST, OPTIONS"]

function with_cors(r::Response)
    append!(r.headers, CORS)
    r
end

reply(d::Decision) = json_response(d.ok ? 200 : (d.refusal !== nothing && d.refusal.code in ("UNKNOWN_CAPABILITY",) ? 404 : 409), json(to_dict(d)))
reply(status::Int, x) = json_response(status, json(x))

function body_json(req::Request)
    isempty(req.body) && return Dict{String,Any}()
    v = parse_json(String(copy(req.body)))
    v isa Dict ? Dict{String,Any}(v) : Dict{String,Any}()
end

function principal(f::Foundry, req::Request)
    tok = header(req, "x-foundry-token")
    isempty(tok) && return anonymous
    p = principal_from_token(f, tok)
    p === nothing ? anonymous : p
end

function route(f::Foundry, req::Request)
    p = req.path
    req.method == "OPTIONS" && return Response(204, Pair{String,String}[], UInt8[])
    if p == "/" || p == "/index.html"
        return static_response(joinpath(WEB_DIR, "index.html"))
    elseif p in ("/ui.js", "/webmcp-bridge.js", "/webmcp-polyfill.js")
        return static_response(joinpath(WEB_DIR, p[2:end]))
    elseif p == "/api/status"
        return reply(200, status(f))
    elseif p == "/api/policy"
        return reply(200, f.policy)
    elseif p == "/api/capabilities"
        return reply(200, Dict("capabilities" => [FoundryCore.capability_summary(f, f.store.capabilities[id]) for id in f.store.order]))
    elseif startswith(p, "/api/capabilities/")
        rest = split(p[length("/api/capabilities/")+1:end], '/')
        id = String(rest[1])
        haskey(f.store.capabilities, id) || return reply(404, Dict("error" => "unknown capability $id"))
        if length(rest) == 1 && req.method == "GET"
            return reply(200, capability_view(f, id))
        elseif length(rest) == 2 && req.method == "POST"
            who = principal(f, req)
            b = body_json(req)
            op = rest[2]
            op == "contract" && return reply(propose_contract!(f, who, id; mode=string(get(b, "mode", "minimize")), contract=get(b, "contract", nothing)))
            op == "verify" && return reply(verify!(f, who, id))
            op == "promote" && return reply(promote!(f, who, id))
            op == "withdraw" && return reply(withdraw!(f, who, id, string(get(b, "reason", "withdrawn"))))
            op == "source" && return text_response(200, "")
        end
        return reply(404, Dict("error" => "no such operation"))
    elseif p == "/api/source"
        ref = get(req.query, "ref", "")
        name = replace(basename(ref), ".jl" => "")
        st, _, body = Http.request("GET", f.app_host, f.app_port, "/__oracle/source/$name")
        return text_response(st, body)
    elseif p == "/api/evidence"
        return reply(200, Dict("evidence" => [to_dict(e) for e in values(f.store.evidence)]))
    elseif startswith(p, "/api/evidence/")
        id = p[length("/api/evidence/")+1:end]
        haskey(f.store.evidence, id) || return reply(404, Dict("error" => "unknown evidence"))
        return reply(200, to_dict(f.store.evidence[id]))
    elseif p == "/api/ledger"
        return reply(200, Dict("events" => [Ledger.event_dict(e) for e in f.store.events]))
    elseif p == "/api/ledger/verify"
        ok, msg = Ledger.verify_chain(f.store.events)
        rd = ""
        if !isempty(f.store.path)
            rd = try Ledger.digest(Ledger.replay(f.store.path)) catch e; "replay failed: " * sprint(showerror, e) end
        end
        live = Ledger.digest(f.store)
        return reply(200, Dict("chain_ok" => ok, "chain" => msg, "live_digest" => live, "replay_digest" => rd, "replay_matches" => rd == live))
    elseif p == "/api/discover" && req.method == "POST"
        return reply(discover!(f, principal(f, req)))
    elseif p == "/api/rescan" && req.method == "POST"
        return reply(rescan!(f, principal(f, req)))
    elseif p == "/api/webmcp/manifest"
        return reply(200, manifest(f, get(req.query, "app", f.app_id)))
    elseif startswith(p, "/api/webmcp/call/") && req.method == "POST"
        name = Http.urldecode(p[length("/api/webmcp/call/")+1:end])
        who = principal(f, req)
        b = body_json(req)
        input = Dict{String,Any}(get(b, "input", Dict{String,Any}()))
        sess = header(req, "x-foundry-session")
        return reply(invoke!(f, who, name, input, sess; host=header(req, "x-foundry-host")))
    elseif p == "/api/webmcp/host-report" && req.method == "POST"
        return reply(host_report!(f, principal(f, req), body_json(req)))
    elseif p == "/api/webmcp/acceptance"
        return reply(200, host_acceptance(f, get(req.query, "app", f.app_id)))
    elseif p == "/api/webmcp/invariant"
        return reply(200, host_invariant(f, get(req.query, "app", f.app_id)))
    elseif p == "/api/webmcp/host-status"
        app = get(req.query, "app", f.app_id)
        ev = latest_host_report(f, app)
        return reply(200, ev === nothing ? Dict("report" => nothing) : Dict("seq" => ev.seq, "at" => ev.at, "payload" => ev.payload))
    end
    text_response(404, "not found")
end

function start!(f::Foundry, port::Int)
    Http.serve!(port) do req
        with_cors(route(f, req))
    end
end

end # module Server
