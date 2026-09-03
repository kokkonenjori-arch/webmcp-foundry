# demo/run_demo.jl — the ten-step demonstration, driven ENTIRELY over HTTP.
#
#   julia demo/run_demo.jl            # boots Foundry (8090) + Ledgerly (8091) in-process, then drives them over TCP
#   julia demo/run_demo.jl --attach   # drives an already-running pair (e.g. started by bin/foundry.jl)
#   julia demo/run_demo.jl --keep     # leave the servers running afterwards (for the browser)
#
# Every step asserts the doctrine outcome; the process exits non-zero if any step
# does not hold. A transcript is written to data/demo-transcript.md.

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "WebMCPFoundry.jl"))
Base.include(WebMCPFoundry, joinpath(ROOT, "demo", "app", "LedgerlyApp.jl"))
using .WebMCPFoundry
const W = WebMCPFoundry
import .WebMCPFoundry.JSON: json, parse_json
import .WebMCPFoundry.Http: request

const FPORT = parse(Int, get(ENV, "FPORT", "8090")); const APORT = parse(Int, get(ENV, "APORT", "8091"))   # override to drive a remote pair through an ssh port-forward
const ACTIONS = joinpath(ROOT, "demo", "app", "actions")
attach = "--attach" in ARGS
keep = "--keep" in ARGS

# ------------------------------------------------------------------ transcript

const T = IOBuffer()
failures = String[]
function say(s...)
    line = join(string.(s))
    println(line); write(T, line, "\n")
end
function must(cond::Bool, what::String)
    say(cond ? "   ✔ " : "   ✘ ", what)
    cond || push!(failures, what)
    cond
end
step(n, title) = say("\n## Step $n — $title")

# ------------------------------------------------------------------ http helpers (the driver is an external client)

function api(method, path; body=nothing, token="", session="")
    hdrs = Pair{String,String}[]
    isempty(token) || push!(hdrs, "X-Foundry-Token" => token)
    isempty(session) || push!(hdrs, "X-Foundry-Session" => session)
    body === nothing || push!(hdrs, "Content-Type" => "application/json")
    st, _, b = request(method, "127.0.0.1", FPORT, path; body=body === nothing ? "" : json(body), headers=hdrs)
    (st, isempty(b) ? Dict{String,Any}() : (try parse_json(b) catch; Dict{String,Any}("raw" => b) end))
end
app(method, path; body=nothing) = request(method, "127.0.0.1", APORT, path; body=body === nothing ? "" : json(body),
                                          headers=body === nothing ? Pair{String,String}[] : ["Content-Type" => "application/json"])

const AGENT = "tok-agent-planner"; const OWNER = "tok-human-jori"; const MEMBER = "tok-human-sam"
refusal(r) = r["refusal"] === nothing ? "" : r["refusal"]["code"]
reasons(r) = r["refusal"] === nothing ? String[] : String[string(x) for x in r["refusal"]["reasons"]]
manifest_names() = String[t["name"] for t in api("GET", "/api/webmcp/manifest?app=ledgerly")[2]["tools"]]
cap(id) = api("GET", "/api/capabilities/$id")[2]

copy_source(name, version) = cp(joinpath(ACTIONS, "$name.$version.jl"), joinpath(ACTIONS, "$name.jl"); force=true)

# ---- native WebMCP host (a real browser; polyfill reports are never accepted as evidence)
include(joinpath(ROOT, "demo", "hostlaunch.jl"))
host_status() = api("GET", "/api/webmcp/host-status?app=ledgerly")[2]
"Wait for a NATIVE host report satisfying pred(payload); returns the payload or nothing."
function wait_native(pred; timeout=45)
    deadline = time() + timeout
    while time() < deadline
        hs = host_status()
        if haskey(hs, "seq") && hs["payload"]["host"] == "native" && pred(hs["payload"])
            return hs["payload"]
        end
        sleep(1)
    end
    nothing
end
browser_has(p, name) = get(p["report"], "browser_tools", nothing) !== nothing && name in String[string(x) for x in p["report"]["browser_tools"]]
# a "developer commit": switch a handler between its versioned sources ON THE APP (works for a remote pair too)
function set_source(name, version)
    st, _, body = app("POST", "/__oracle/source-version"; body=Dict("name" => name, "version" => version))
    st == 200 || error("source switch failed: $st $body")
end

# ------------------------------------------------------------------ boot

attach || (copy_source("apply_adjustment", "v1"); copy_source("transfer_funds", "v1"); copy_source("_money", "v1"))   # local boot: known starting point (attach mode resets server-side)
if !attach
    global f, srv, appsrv = W.boot(; foundry_port=FPORT, app_port=APORT, ledger_path=joinpath(ROOT, "data", "ledger.jsonl"),
                                   fresh=true, app_module=W.LedgerlyApp)
    sleep(0.3)
end
if attach
    # deterministic start against a running deployment: archive the ledger, restore v1 handlers, re-seed
    st, r = api("POST", "/api/demo/reset"; token=OWNER)
    r["ok"] || error("demo reset refused: $(r)")
end
app("POST", "/__oracle/reload")

say("# WebMCP Foundry — demonstration transcript")
say("Foundry http://127.0.0.1:$FPORT · Ledgerly http://127.0.0.1:$APORT · driver acts over HTTP only")

# ------------------------------------------------------------------ 1. discover
step(1, "discover / model candidate actions from the human page")
st, r = api("POST", "/api/discover"; token=AGENT)
ids = String[c["id"] for c in r["detail"]["candidates"]]
must(length(ids) == 6, "6 candidates modelled from <form data-action> controls: $(join(ids, ", "))")
for c in r["detail"]["candidates"]
    say("   · $(c["id"]): $(c["action"]["method"]) $(c["action"]["path"]) — $(length(c["fields"])) controls, hints $(json(c["hints"]))")
end

# ------------------------------------------------------------------ 2. narrow over-broad surface
step(2, "narrow an over-broad agent input surface (search_transactions)")
S = "ledgerly.search_transactions"
st, r = api("POST", "/api/capabilities/$S/contract"; token=AGENT, body=Dict("mode" => "naive"))
must(!r["ok"] && refusal(r) in ("OVER_BROAD", "UNCONSTRAINED"), "naive contract (every control agent-controlled) REFUSED: $(refusal(r))")
for x in reasons(r); say("      - $x"); end
st, r = api("POST", "/api/capabilities/$S/contract"; token=AGENT, body=Dict("mode" => "minimize"))
m = r["detail"]["minimization"]
must(r["ok"] && m["agent_fields_before"] == 4 && m["agent_fields_after"] == 2, "minimized contract accepted: agent-controlled fields $(m["agent_fields_before"]) → $(m["agent_fields_after"])")
for row in m["rows"]; say("      $(row["field"]) ($(row["origin"])): $(row["before"]) ⇒ $(row["after"])"); end
st, r = api("POST", "/api/capabilities/$S/verify"; token=AGENT)
ev = r["detail"]["evidence"]
must(ev["verdict"] == "PASS", "verification PASS, mutation score $(ev["mutation_score"]) ($(length(ev["checks"])) checks, $(length(ev["mutants"])) mutants)")
lb = [mm["id"] for mm in ev["mutants"] if get(mm, "outcome", "") == "load_bearing"]
say("      load-bearing constraints (app accepts out-of-contract values itself): $(join(lb, ", "))")
st, r = api("POST", "/api/capabilities/$S/promote"; token=AGENT)
must(r["ok"], "READ capability promoted by the AGENT (policy allows agents to promote READ-only, low blast radius)")
must("ledgerly_search_transactions" in manifest_names(), "manifest now exposes ledgerly_search_transactions")

# ------------------------------------------------------------------ 3. detect unsafe capability
step(3, "detect an intentionally incorrect capability (apply_adjustment v1: no ownership check)")
A = "ledgerly.apply_adjustment"
st, r = api("POST", "/api/capabilities/$A/contract"; token=AGENT, body=Dict("mode" => "minimize"))
must(r["ok"], "minimized contract accepted (account_id stays an agent-choosable enum; scope own_account)")
st, r = api("POST", "/api/capabilities/$A/verify"; token=AGENT)
ev = r["detail"]["evidence"]
sc = first(c for c in ev["checks"] if c["name"] == "scope_adversarial")
must(ev["verdict"] == "FAIL" && sc["verdict"] == "FAIL", "evidence verdict FAIL; scope_adversarial FAIL with counterexample")
say("      " * sc["reason"])

# ------------------------------------------------------------------ 4. block promotion using evidence
step(4, "block promotion using evidence")
st, r = api("POST", "/api/capabilities/$A/promote"; token=OWNER)
must(!r["ok"] && refusal(r) == "EVIDENCE_NOT_PASS", "even the OWNER cannot promote: $(refusal(r)) — $(join(reasons(r), "; "))")
must(!("ledgerly_apply_adjustment" in manifest_names()), "not exposed via WebMCP")

# ------------------------------------------------------------------ 5. reevaluate a repaired candidate
step(5, "reevaluate a repaired candidate (apply_adjustment v2 adds the ownership check)")
set_source("apply_adjustment", "v2")
st, r = api("POST", "/api/rescan"; token=AGENT)
must(haskey(r["detail"]["stale"], A), "rescan detects the source change: $(get(r["detail"]["stale"], A, ""))")
must(cap(A)["state"] == "STALE" && isempty(cap(A)["evidence_id"]), "capability STALE; old FAIL evidence detached (it spoke for the old fingerprint)")
st, r = api("POST", "/api/capabilities/$A/verify"; token=AGENT)
ev = r["detail"]["evidence"]
sc = first(c for c in ev["checks"] if c["name"] == "scope_adversarial")
must(ev["verdict"] == "PASS" && sc["verdict"] == "PASS", "fresh evidence against v2: PASS (scope_adversarial: $(sc["reason"][1:min(end, 90)])…)")
must(length(cap(A)["all_evidence"]) == 2, "both evidence records retained in the ledger; only the current one is bound")

# ------------------------------------------------------------------ 6. prevent agent self-ratification
step(6, "prevent agent self-ratification of a consequential capability (transfer_funds, FINANCIAL)")
Tr = "ledgerly.transfer_funds"
st, r = api("POST", "/api/capabilities/$Tr/contract"; token=AGENT, body=Dict("mode" => "minimize"))
must(r["ok"], "minimized contract accepted: from_account SESSION_BOUND, to_account enum, amount 1..25000, memo ≤120")
st, r = api("POST", "/api/capabilities/$Tr/verify"; token=AGENT)
ev = r["detail"]["evidence"]
must(ev["verdict"] == "PASS", "evidence PASS (conservation + nonnegative_balance invariants hold; mutation score $(ev["mutation_score"]))")
st, r = api("POST", "/api/capabilities/$Tr/promote"; token=AGENT)
must(!r["ok"] && refusal(r) == "AUTHORITY_INSUFFICIENT" && any(x -> occursin("SELF", x) || occursin("agent plane", x), reasons(r)),
     "AGENT promotion REFUSED: $(refusal(r)) — $(join(reasons(r), "; "))")
st, r = api("POST", "/api/webmcp/call/foundry_promote"; token=AGENT, body=Dict("input" => Dict("capability_id" => Tr)))
must(!r["ok"] && refusal(r) == "AUTHORITY_INSUFFICIENT", "same refusal through Foundry's own WebMCP tool foundry_promote")
st, r = api("POST", "/api/capabilities/$Tr/promote"; token=MEMBER)
must(!r["ok"] && refusal(r) == "ROLE_MISSING", "HUMAN without the owner role REFUSED: $(refusal(r))")

# ------------------------------------------------------------------ 7. human promotion
step(7, "permit appropriate human promotion")
st, r = api("POST", "/api/capabilities/$Tr/promote"; token=OWNER)
must(r["ok"] && cap(Tr)["state"] == "LIVE", "HUMAN owner (≠ proposer) promotes transfer_funds → LIVE")

# ------------------------------------------------------------------ 8. expose through WebMCP
step(8, "expose the promoted capability through NATIVE WebMCP (document.modelContext)")
st, man = api("GET", "/api/webmcp/manifest?app=ledgerly")
tool = first(t for t in man["tools"] if t["name"] == "ledgerly_transfer_funds")
props = sort!(collect(keys(tool["inputSchema"]["properties"])))
must(props == ["amount_cents", "memo", "to_account"], "manifest tool inputSchema exposes only agent-bound fields: $(props) (from_account is bound from the human session)")
say("      description: " * tool["description"])
exe = find_browser()
must(!isempty(exe), "WebMCP-capable browser found: $(exe)")
since8 = api("GET", "/api/status")[2]["ledger"]["events"]        # host reports must postdate the browser launch
page = get(ENV, "WEBMCP_PAGE", "http://127.0.0.1:$APORT/")   # the public app URL exercises the judges' path
browser_proc = isempty(exe) ? nothing : launch_browser(exe, page * "?acceptance=1")
say("      page opened in browser: $page")
p8 = wait_native(p -> p["matches_at_receipt"] === true && browser_has(p, "ledgerly_transfer_funds"))
must(p8 !== nothing, "NATIVE host report: document.modelContext.getTools() == LIVE manifest, includes ledgerly_transfer_funds" *
     (p8 === nothing ? " — no native report (BLOCKED: a polyfill would not count)" : " (ledger #$(host_status()["seq"]))"))
p8 === nothing || say("      host: $(p8["report"]["user_agent"])\n      api : $(json(p8["report"]["api"]))")

# ------------------------------------------------------------------ 9. use it
step(9, "successfully use it through the browser's native executeTool() and through the gateway")
st, acc = api("GET", "/api/webmcp/acceptance?app=ledgerly&since=$since8")
t0 = time()
while !(acc["verdict"] == "PASS" || (acc["verdict"] == "FAIL" && get(acc, "execution_report_seq", 0) > 0)) && time() - t0 < 45
    sleep(1); global acc = api("GET", "/api/webmcp/acceptance?app=ledgerly&since=$since8")[2]
end
must(acc["verdict"] == "PASS", "native acceptance verdict: $(acc["verdict"]) — $(join(acc["reasons"], "; "))")
xs = get(acc, "executions", nothing)
xt = xs === nothing ? nothing : findfirst(x -> x["tool"] == "ledgerly_transfer_funds", xs)
must(xt !== nothing && xs[xt]["ok"] && xs[xt]["status"] == 201,
     "document.modelContext.executeTool(ledgerly_transfer_funds) → gateway → app: status " * (xt === nothing ? "none" : string(xs[xt]["status"])) *
     (xt === nothing ? "" : " (input encoding accepted by host: $(get(xs[xt], "input_encoding", "?")))"))
st, l9 = api("GET", "/api/ledger")
inv9 = [e for e in l9["events"] if e["kind"] == "INVOKED" && get(e["payload"], "host", "") == "native"]
must(!isempty(inv9), "ledger records $(length(inv9)) invocation(s) tagged host=native")
before = parse_json(app("GET", "/__oracle/snapshot")[3])
st, r = api("POST", "/api/webmcp/call/ledgerly_transfer_funds"; token="tok-agent-browser", session="sess-jori",
            body=Dict("input" => Dict("to_account" => "A3", "amount_cents" => 1500, "memo" => "via gateway")))
after = parse_json(app("GET", "/__oracle/snapshot")[3])
b1 = before["resources"]["account"]["A1"]["balance_cents"]; a1 = after["resources"]["account"]["A1"]["balance_cents"]
must(r["ok"] && r["detail"]["status"] == 201 && b1 - a1 == 1500, "gateway transfer executed: A1 $b1 → $a1 (bound input $(json(r["detail"]["bound_input"])))")
st, r = api("POST", "/api/webmcp/call/ledgerly_transfer_funds"; token="tok-agent-browser", session="sess-jori",
            body=Dict("input" => Dict("from_account" => "A2", "to_account" => "A1", "amount_cents" => 100, "memo" => "steal")))
must(!r["ok"] && refusal(r) == "INPUT_REFUSED", "attempt to control the session-bound from_account REFUSED: $(join(reasons(r), "; "))")
st, r = api("POST", "/api/webmcp/call/ledgerly_transfer_funds"; token="tok-agent-browser", session="sess-jori",
            body=Dict("input" => Dict("to_account" => "A3", "amount_cents" => 999999, "memo" => "too much")))
must(!r["ok"] && refusal(r) == "INPUT_REFUSED", "out-of-contract amount REFUSED at the gateway: $(join(reasons(r), "; "))")
must(haskey(r["detail"], "guidance") && r["detail"]["guidance"]["retryable"] == true && !isempty(r["detail"]["guidance"]["next_steps"]),
     "refusal carries agent guidance: retryable=$(r["detail"]["guidance"]["retryable"]) · $(r["detail"]["guidance"]["next_steps"][1])")
# over-broad in TIME: the contract's budget is enforced by the gateway from the ledger
kb = cap(Tr)["contract"]["budget"]
must(kb["max_per_hour"] > 0 && kb["max_amount_per_hour"] > 0 && kb["amount_field"] == "amount_cents", "contract declares a budget: $(kb["max_per_hour"]) calls/h, $(kb["max_amount_per_hour"]) $(kb["amount_field"])/h per session")
nref = 0; last = nothing
for i in 1:kb["max_per_hour"] + 1
    st, rr = api("POST", "/api/webmcp/call/ledgerly_transfer_funds"; token="tok-agent-browser", session="sess-jori",
                 body=Dict("input" => Dict("to_account" => "A3", "amount_cents" => 10, "memo" => "budget probe $i")))
    global last = rr
    rr["ok"] || (global nref = i; break)
end
must(last !== nothing && !last["ok"] && refusal(last) == "BUDGET_EXCEEDED", "gateway refused call #$nref with BUDGET_EXCEEDED: $(last === nothing ? "" : join(reasons(last), "; "))")
must(last !== nothing && get(get(last["detail"], "guidance", Dict()), "retry_after_seconds", 0) == 3600, "agent guidance: retry after 3600 s")
st, r = api("POST", "/api/webmcp/call/foundry_explain_refusal"; token="tok-agent-browser", body=Dict("input" => Dict("code" => "BUDGET_EXCEEDED", "capability_id" => Tr)))
must(r["ok"] && r["detail"]["found"] && r["detail"]["guidance"]["code"] == "BUDGET_EXCEEDED", "foundry_explain_refusal finds the ledgered refusal (#$(r["detail"]["ledger_seq"])) and explains it")

# ------------------------------------------------------------------ 10. stale invalidation
step(10, "detect a dependency change, mark STALE, withdraw, require fresh evidence")
set_source("transfer_funds", "v2")
st, r = api("POST", "/api/rescan"; token=AGENT)
must(haskey(r["detail"]["stale"], Tr), "rescan: $(get(r["detail"]["stale"], Tr, ""))")
must(cap(Tr)["state"] == "STALE", "transfer_funds is STALE (was LIVE)")
must(!("ledgerly_transfer_funds" in manifest_names()), "withdrawn from the WebMCP manifest")
p10 = wait_native(p -> p["matches_at_receipt"] === true && !browser_has(p, "ledgerly_transfer_funds") && browser_has(p, "ledgerly_search_transactions"))
must(p10 !== nothing, "NATIVE host: bridge aborted the tool's AbortController → document.modelContext.getTools() no longer contains ledgerly_transfer_funds" *
     (p10 === nothing ? " — not observed" : " (ledger #$(host_status()["seq"]))"))
st, inv = api("GET", "/api/webmcp/invariant?app=ledgerly")
row = findfirst(r -> r["tool"] == "ledgerly_transfer_funds", inv["rows"])
must(inv["verdict"] == "PASS" && row !== nothing && inv["rows"][row]["state"] == "STALE" && inv["rows"][row]["browser"] == "absent",
     "lifecycle ⇔ getTools() invariant PASS: " * join(["$(r["tool"])=$(r["state"])/$(r["browser"])" for r in inv["rows"]], ", "))
st, r = api("POST", "/api/webmcp/call/ledgerly_transfer_funds"; token="tok-agent-browser", session="sess-jori",
            body=Dict("input" => Dict("to_account" => "A3", "amount_cents" => 100, "memo" => "after stale")))
must(!r["ok"] && refusal(r) == "NOT_LIVE", "gateway refuses invocation: $(refusal(r))")
st, r = api("POST", "/api/capabilities/$Tr/promote"; token=OWNER)
must(!r["ok"] && refusal(r) in ("NO_EVIDENCE", "NOT_VERIFIED"), "owner cannot re-promote without fresh evidence: $(refusal(r))")
st, r = api("POST", "/api/capabilities/$Tr/verify"; token=AGENT)
must(r["detail"]["evidence"]["verdict"] == "PASS", "fresh evidence against v2: PASS")
st, r = api("POST", "/api/capabilities/$Tr/promote"; token=OWNER)
must(r["ok"] && "ledgerly_transfer_funds" in manifest_names(), "re-qualified and re-promoted by the owner → LIVE again")
p10b = wait_native(p -> p["matches_at_receipt"] === true && browser_has(p, "ledgerly_transfer_funds"))
must(p10b !== nothing, "NATIVE host: tool re-registered; getTools() contains ledgerly_transfer_funds again")

# ------------------------------------------------------------------ 11. blast radius across capabilities
step(11, "blast radius — a shared helper changes; exactly its dependents are withdrawn")
N = "ledgerly.add_note"; A = "ledgerly.apply_adjustment"
for (id, needs_contract) in ((N, true), (A, false))
    c = cap(id)
    c["contract"] === nothing && api("POST", "/api/capabilities/$id/contract"; token=AGENT, body=Dict("mode" => "minimize"))
    c["state"] in ("VERIFIED", "LIVE") || api("POST", "/api/capabilities/$id/verify"; token=AGENT)
    c["state"] == "LIVE" || api("POST", "/api/capabilities/$id/promote"; token=OWNER)
end
live_now = sort(manifest_names())
must(length(live_now) == 4, "four tools LIVE: $(join(live_now, ", "))")
p11 = wait_native(p -> p["matches_at_receipt"] === true && length(p["report"]["browser_tools"]) == 4)
must(p11 !== nothing, "NATIVE host: getTools() holds all four")
st, g = api("GET", "/api/deps")
money = findfirst(n -> n["id"] == "source:actions/_money.jl", g["nodes"])
must(money !== nothing && sort(String[string(x) for x in g["nodes"][money]["dependents"]]) == [A, Tr], "dependency graph: actions/_money.jl is shared by exactly apply_adjustment and transfer_funds")
st, pre = api("GET", "/api/impact?change=source:actions/_money.jl")
must(pre["withdrawn"] == 2 && pre["live"] == 4 && sort(String[string(x) for x in pre["survivors"]]) == ["ledgerly_add_note", "ledgerly_search_transactions"],
     "impact BEFORE applying: $(pre["summary"]); survivors $(join(pre["survivors"], ", "))")
st, pol = api("GET", "/api/impact?change=policy")
must(pol["withdrawn"] == 4, "for comparison, a policy change: $(pol["summary"])")
set_source("_money", "v2")
st, pend = api("GET", "/api/impact?change=pending")
must(sort(String[string(x) for x in pend["affected"]]) == [A, Tr], "pending impact (fingerprints moved, nothing applied yet): $(pend["summary"])")
st, r = api("POST", "/api/rescan"; token=AGENT)
must(sort(collect(keys(r["detail"]["stale"]))) == [A, Tr], "rescan staled exactly the dependents: $(join(sort(collect(keys(r["detail"]["stale"]))), ", "))")
must(sort(manifest_names()) == ["ledgerly_add_note", "ledgerly_search_transactions"], "manifest keeps the two survivors")
p11b = wait_native(p -> p["matches_at_receipt"] === true && sort(String[string(x) for x in p["report"]["browser_tools"]]) == ["ledgerly_add_note", "ledgerly_search_transactions"])
must(p11b !== nothing, "NATIVE host: two tools vanished from getTools(), two survived (ledger #$(host_status()["seq"]))")
st, inv = api("GET", "/api/webmcp/invariant?app=ledgerly")
must(inv["verdict"] == "PASS", "lifecycle ⇔ getTools() invariant PASS across all six")
for id in (A, Tr)
    st, r = api("POST", "/api/capabilities/$id/verify"; token=AGENT)
    st, r = api("POST", "/api/capabilities/$id/promote"; token=OWNER)
end
p11c = wait_native(p -> p["matches_at_receipt"] === true && length(p["report"]["browser_tools"]) == 4)
must(p11c !== nothing, "re-qualified both against the new helper; NATIVE host holds four tools again")

# ------------------------------------------------------------------ extras: forbidden & ungradable
step("+", "refusals for the other effect classes")
st, r = api("POST", "/api/capabilities/ledgerly.delete_account/contract"; token=AGENT, body=Dict("mode" => "minimize"))
must(!r["ok"] && refusal(r) in ("NOT_AGENT_EXPOSABLE", "EFFECT_FORBIDDEN"), "delete_account: $(refusal(r)) — $(join(reasons(r), "; "))")
st, r = api("POST", "/api/capabilities/ledgerly.share_report/contract"; token=AGENT, body=Dict("mode" => "minimize"))
must(r["ok"], "share_report: contract accepted (EXTERNAL_SEND)")
st, r = api("POST", "/api/capabilities/ledgerly.share_report/verify"; token=AGENT)
must(r["detail"]["evidence"]["verdict"] == "UNGRADABLE", "share_report: evidence UNGRADABLE (delivery is unobservable) — uncertainty is not PASS")
st, r = api("POST", "/api/capabilities/ledgerly.share_report/promote"; token=OWNER)
must(!r["ok"], "share_report: promotion refused ($(refusal(r)))")
st, r = api("POST", "/api/capabilities/ledgerly.add_note/withdraw"; token=OWNER, body=Dict("reason" => "extras check"))
st, r = api("POST", "/api/capabilities/ledgerly.add_note/contract"; token=AGENT, body=Dict("mode" => "minimize"))
st, r = api("POST", "/api/capabilities/ledgerly.add_note/verify"; token=AGENT)
must(r["detail"]["evidence"]["verdict"] == "PASS", "add_note (WRITE_OWN): evidence PASS")
st, r = api("POST", "/api/capabilities/ledgerly.add_note/promote"; token=AGENT)
must(!r["ok"] && refusal(r) == "AUTHORITY_INSUFFICIENT", "add_note: agent promotion refused (WRITE_OWN needs a HUMAN)")
st, r = api("POST", "/api/capabilities/ledgerly.add_note/promote"; token=OWNER)

# ------------------------------------------------------------------ ledger integrity
step("=", "deterministic evidence and promotion history")
st, v = api("GET", "/api/ledger/verify")
must(v["chain_ok"] && v["replay_matches"], "hash chain intact; replaying data/ledger.jsonl reproduces the live state digest $(v["live_digest"][1:30])…")
st, l = api("GET", "/api/ledger")
kinds = Dict{String,Int}()
for e in l["events"]; kinds[e["kind"]] = get(kinds, e["kind"], 0) + 1; end
say("      $(length(l["events"])) events: " * join(["$k×$v" for (k, v) in sort!(collect(kinds))], ", "))

# ------------------------------------------------------------------ wrap up
say("\n## Result")
if isempty(failures)
    say("ALL STEPS HOLD. A web application's agent interface was treated as a derived, versioned, minimized, effect-aware, tested, evidence-backed, authority-governed artifact.")
else
    say("FAILED STEPS:"); for x in failures; say("   ✘ $x"); end
end
open(joinpath(ROOT, "data", "demo-transcript.md"), "w") do io; write(io, String(take!(T))); end
browser_proc === nothing || (try kill(browser_proc) catch end); kill_browser!()
# the app is left as the demo left it (both handlers at v2, consistent with the ledger's bound fingerprints)
if !attach && !keep
    W.Http.stop!(srv); W.LedgerlyApp.stop!()
end
if keep && !attach
    println("\nservers kept running — Foundry http://127.0.0.1:$FPORT  Ledgerly http://127.0.0.1:$APORT")
    wait(srv.task)
end
exit(isempty(failures) ? 0 : 1)
