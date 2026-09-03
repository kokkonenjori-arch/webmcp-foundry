# test/acceptance_native.jl — native WebMCP acceptance.
#
# Launches a WebMCP-capable Chromium (Chrome 149+ / Edge with the WebMCP testing
# feature) on the Ledgerly page with ?acceptance=1, then waits for the page's bridge
# to report through Foundry's host-report endpoint. The verdict is Foundry's
# `host_acceptance`, computed from the ledger:
#
#   PASS     native document.modelContext, getTools() ⇔ LIVE manifest exact, executeTool() ok
#   FAIL     drift or failed execution on a native host
#   UNKNOWN  native host could not enumerate
#   BLOCKED  no native report — a polyfill or absent host is NOT evidence (named as such)
#
# Exit code 0 only on PASS. Environment:
#   WEBMCP_BROWSER   path to chrome.exe / msedge.exe (auto-detected if unset)
#   WEBMCP_FLAGS     extra command-line flags (default enables the WebMCP testing features)
#   WEBMCP_HEADLESS  "1" to add --headless=new
#   WEBMCP_TIMEOUT   seconds to wait for a report (default 45)
#   WEBMCP_PAGE      page origin to open (default http://127.0.0.1:8091/); use the public URL to test the judges' path
#
#   julia test/acceptance_native.jl            # boots Foundry+Ledgerly in-process, promotes search_transactions, runs
#   julia test/acceptance_native.jl --attach   # against an already-running pair (state as-is)

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "WebMCPFoundry.jl"))
Base.include(WebMCPFoundry, joinpath(ROOT, "demo", "app", "LedgerlyApp.jl"))
using .WebMCPFoundry
const W = WebMCPFoundry
import .W.JSON: json, parse_json
import .W.Http: request

const FPORT = 8090; const APORT = 8091
attach = "--attach" in ARGS

function api(method, path; body=nothing, token="")
    hdrs = Pair{String,String}[]
    isempty(token) || push!(hdrs, "X-Foundry-Token" => token)
    body === nothing || push!(hdrs, "Content-Type" => "application/json")
    st, _, b = request(method, "127.0.0.1", FPORT, path; body=body === nothing ? "" : json(body), headers=hdrs)
    (st, isempty(b) ? Dict{String,Any}() : parse_json(b))
end

include(joinpath(ROOT, "demo", "hostlaunch.jl"))

# ------------------------------------------------------------------ run

if !attach
    global f, srv, appsrv = W.boot(; foundry_port=FPORT, app_port=APORT, ledger_path=joinpath(ROOT, "data", "acceptance-ledger.jsonl"),
                                   fresh=true, app_module=W.LedgerlyApp)
    sleep(0.3)
    # minimal LIVE surface: the READ capability (agent may promote it), so the host has something to register and execute
    api("POST", "/api/discover"; token="tok-agent-planner")
    api("POST", "/api/capabilities/ledgerly.search_transactions/contract"; token="tok-agent-planner", body=Dict("mode" => "minimize"))
    api("POST", "/api/capabilities/ledgerly.search_transactions/verify"; token="tok-agent-planner")
    api("POST", "/api/capabilities/ledgerly.search_transactions/promote"; token="tok-agent-planner")
end

# only host reports recorded AFTER this point count: evidence must postdate the question
since = api("GET", "/api/status")[2]["ledger"]["events"]
exe = find_browser()
url = get(ENV, "WEBMCP_PAGE", "http://127.0.0.1:$APORT/") * "?acceptance=1"   # WEBMCP_PAGE: e.g. the public tunnel URL of the app
println("native WebMCP acceptance")
println("  page    : $url")
println("  browser : $(isempty(exe) ? "NONE FOUND (set WEBMCP_BROWSER)" : exe)")
proc = nothing
if !isempty(exe)
    proc = launch_browser(exe, url)
    println("  flags   : $(get(ENV, "WEBMCP_FLAGS", DEFAULT_FLAGS))")
end

timeout = parse(Int, get(ENV, "WEBMCP_TIMEOUT", "45"))
deadline = time() + timeout
verdict = Dict{String,Any}("verdict" => "BLOCKED", "reasons" => ["no report before timeout"])
seen_seq = 0
while time() < deadline
    st, v = api("GET", "/api/webmcp/acceptance?app=ledgerly&since=$since")
    global verdict = v
    # final only when the acceptance run (executions) has been graded; transient FAILs may precede it
    v["verdict"] == "PASS" && break
    v["verdict"] == "FAIL" && get(v, "execution_report_seq", 0) > 0 && break
    # a non-native report arrived: keep waiting a little in case a native one follows, but note it
    st2, hs = api("GET", "/api/webmcp/host-status?app=ledgerly")
    if haskey(hs, "seq") && hs["seq"] != seen_seq
        global seen_seq = hs["seq"]
        println("  report #$(hs["seq"]): host=$(hs["payload"]["host"]) matches=$(hs["payload"]["matches_at_receipt"])")
    end
    sleep(1)
end

println("\nVERDICT: $(verdict["verdict"])")
for r in verdict["reasons"]; println("  - $r"); end
if verdict["verdict"] in ("PASS", "FAIL", "UNKNOWN")
    println("  host      : $(verdict["host"]) · report #$(verdict["report_seq"])")
    println("  user agent: $(get(verdict, "user_agent", ""))")
    println("  api       : $(json(get(verdict, "api", nothing)))")
    println("  browser   : $(json(get(verdict, "browser_tools", nothing)))  expected: $(json(get(verdict, "expected_tools", nothing)))")
    println("  executions: $(json(get(verdict, "executions", nothing)))")
end
st, inv = api("GET", "/api/webmcp/invariant?app=ledgerly&since=$since")
println("
LIFECYCLE ⇔ getTools() INVARIANT: $(inv["verdict"])")
for r in get(inv, "rows", []); println("  $(rpad(r["tool"], 32)) $(rpad(r["state"], 10)) expected=$(r["expected"]) browser=$(r["browser"]) $(r["consistent"] ? "✔" : "✘")"); end
proc === nothing || (try kill(proc) catch end)
if !attach
    W.Http.stop!(srv); W.LedgerlyApp.stop!()
end
exit(verdict["verdict"] == "PASS" ? 0 : 1)
