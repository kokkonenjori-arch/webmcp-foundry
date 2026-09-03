# test/runtests.jl — conformance suite. Standard library only; in-house checker so
# the product and its instrument share no dependency. Two pillars (Claudia):
#   Pillar 1  invariant certificates (positive behaviour)
#   Pillar 2  seeded ablations / fault injection (every refusal path fires)
# A gate that cannot fail is not a gate: `--selftest` proves the checker can fail.

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "WebMCPFoundry.jl"))
Base.include(WebMCPFoundry, joinpath(ROOT, "demo", "app", "LedgerlyApp.jl"))
using .WebMCPFoundry
const W = WebMCPFoundry
using .W.JSON, .W.Model, .W.Http
import .W.Ledger, .W.Discovery, .W.Minimize, .W.Validate, .W.Gates, .W.Verify, .W.FoundryCore

passed = 0; failed = String[]
function check(name, cond)
    global passed
    if cond; passed += 1; else push!(failed, name); println("  ✘ ", name); end
end
function throws(name, f)
    ok = try f(); false catch; true end
    check(name, ok)
end

if "--selftest" in ARGS
    check("selftest: this must fail", false)
    println(isempty(failed) ? "SELFTEST BROKEN: checker cannot fail" : "selftest ok: checker can fail")
    exit(isempty(failed) ? 1 : 0)
end

# ------------------------------------------------------------------ JSON
println("json")
d = parse_json("{\"b\":[1,2.5,\"x\\u00e9\",null,true],\"a\":{\"z\":-3}}")
check("json roundtrip", parse_json(canonical(d)) == d)
check("canonical sorted keys", canonical(d) == "{\"a\":{\"z\":-3},\"b\":[1,2.5,\"xé\",null,true]}")
check("canonical integral float", canonical(Dict("k" => 3.0)) == "{\"k\":3}")
check("canonical independent of insertion order", canonical(Dict("a" => 1, "b" => 2)) == canonical(Dict("b" => 2, "a" => 1)))
throws("json trailing garbage refused", () -> parse_json("{} x"))
throws("json bad escape refused", () -> parse_json("\"\\q\""))

# ------------------------------------------------------------------ verdict lattice
println("verdicts")
check("empty manifest is INVALID, never PASS", verdict_join(Verdict[]) == INVALID)
check("join precedence FAIL > UNGRADABLE", verdict_join([PASS, UNGRADABLE, FAIL]) == FAIL)
check("join precedence UNGRADABLE > UNKNOWN", verdict_join([UNKNOWN, UNGRADABLE]) == UNGRADABLE)
check("join UNKNOWN > BLOCKED > PASS", verdict_join([PASS, BLOCKED, UNKNOWN]) == UNKNOWN)
check("unknown verdict token -> INVALID", verdict_from_string("PASSED") == INVALID)
check("only PASS establishes", all(v -> v == PASS || verdict_join([PASS, v]) != PASS, instances(Verdict)))

# ------------------------------------------------------------------ discovery
println("discovery")
html = read(joinpath(ROOT, "demo", "app", "page.html"), String)
cands = Discovery.discover_forms(html, "ledgerly", Dict("transfer_funds" => "actions/transfer_funds.jl"))
check("six forms discovered", length(cands) == 6)
tr = cands[findfirst(c -> c.id == "ledgerly.transfer_funds", cands)]
check("hidden controls captured", any(f -> f.name == "from_account" && f.origin == "hidden", tr.fields))
check("select enum captured", any(f -> f.name == "to_account" && f.constraints["enum"] == ["A3", "A2"], tr.fields))
check("number bounds captured", any(f -> f.name == "amount_cents" && f.constraints["minimum"] == 1 && f.constraints["maximum"] == 25000, tr.fields))
check("everything agent-bound at discovery (over-broad by construction)", all(f -> f.binding == AGENT_BOUND, tr.fields))
check("hints recorded as untrusted claims", tr.hints["effect"] == "FINANCIAL")
check("source ref tied", tr.action.source_ref == "actions/transfer_funds.jl")
check("surface hash deterministic", Discovery.discover_forms(html, "ledgerly", Dict())[4].surface_hash == Discovery.discover_forms(html, "ledgerly", Dict())[4].surface_hash)

# ------------------------------------------------------------------ minimization + contract gate
println("minimize / gates")
policy = parse_json(read(joinpath(ROOT, "policy", "authority.json"), String))
rules = policy["contract_rules"]
k, notes = Minimize.minimize(tr, rules; proposed_by="AGENT:planner")
fb(n) = k.inputs[findfirst(f -> f.name == n, k.inputs)].binding
check("hidden from_account -> SESSION_BOUND", fb("from_account") == SESSION_BOUND)
check("visible to_account stays AGENT_BOUND enum", fb("to_account") == AGENT_BOUND)
check("memo keeps maxLength", k.inputs[findfirst(f -> f.name == "memo", k.inputs)].constraints["maxLength"] == 120)
check("FINANCIAL adds nonnegative_balance", "nonnegative_balance" in k.invariants)
check("hint invariants merged", "conservation" in k.invariants)
check("scope field is the session-bound from_account", k.scope_field == "from_account")
check("minimized contract passes gate", Gates.contract_gate(k, tr, policy).ok)
naive = Minimize.naive_contract(tr)
dec = Gates.contract_gate(naive, tr, policy)
check("naive contract refused OVER_BROAD/UNCONSTRAINED", !dec.ok && dec.refusal.code in ("OVER_BROAD", "UNCONSTRAINED"))
check("refusal names the hidden control", any(r -> occursin("from_account", r), dec.refusal.reasons))
del = cands[findfirst(c -> c.id == "ledgerly.delete_account", cands)]
kd, _ = Minimize.minimize(del, rules)
dd = Gates.contract_gate(kd, del, policy)
check("required human-only control -> NOT_AGENT_EXPOSABLE", !dd.ok && dd.refusal.code == "NOT_AGENT_EXPOSABLE")
check("DESTRUCTIVE forbidden by policy", !isempty(Gates.policy_block(kd, policy)))
check("contract hash deterministic", contract_hash(k) == contract_hash(Minimize.minimize(tr, rules; proposed_by="AGENT:planner")[1]))

# ------------------------------------------------------------------ validation
println("validate")
sess = Dict{String,Any}("user_id" => "jori", "default_account" => "A1")
ok, bound, errs = Validate.bind_input(k, Dict{String,Any}("to_account" => "A3", "amount_cents" => 10, "memo" => "hi"), sess)
check("binds nominal", ok && bound["from_account"] == "A1" && bound["amount_cents"] == "10")
ok, _, errs = Validate.bind_input(k, Dict{String,Any}("to_account" => "A3", "amount_cents" => 10, "from_account" => "A2"), sess)
check("agent cannot supply session-bound field", !ok && any(e -> occursin("not agent-controlled", e), errs))
ok, _, _ = Validate.bind_input(k, Dict{String,Any}("to_account" => "A3", "amount_cents" => 0), sess)
check("below minimum refused", !ok)
ok, _, _ = Validate.bind_input(k, Dict{String,Any}("to_account" => "A9", "amount_cents" => 5), sess)
check("enum violation refused", !ok)
ok, _, _ = Validate.bind_input(k, Dict{String,Any}("to_account" => "A3", "amount_cents" => 5, "admin" => "1"), sess)
check("unknown field refused", !ok)
ok, _, _ = Validate.bind_input(k, Dict{String,Any}("to_account" => "A3", "amount_cents" => 5, "memo" => "<script>x"), sess)
check("injection marker refused", !ok)
schema = Validate.input_schema(k)
check("inputSchema exposes only agent-bound fields", sort(collect(keys(schema["properties"]))) == ["amount_cents", "memo", "to_account"])
check("inputSchema closed", schema["additionalProperties"] == false)

# ------------------------------------------------------------------ ledger
println("ledger")
lp = joinpath(ROOT, "data", "test-ledger.jsonl"); isfile(lp) && rm(lp)
s = Ledger.Store(lp; clock=() -> "2026-01-01T00:00:00.000Z")
Ledger.commit!(s, "DISCOVERED", "SYSTEM:test", Dict{String,Any}("candidate" => to_dict(tr)))
check("candidate created", s.capabilities[tr.id].state == CANDIDATE)
fp = Fingerprint("sha256:src", tr.surface_hash, "sha256:pol", "sha256:tests", contract_hash(k))
Ledger.commit!(s, "CONTRACT_ACCEPTED", "AGENT:planner", Dict{String,Any}("capability_id" => tr.id, "contract" => to_dict(k), "contract_hash" => contract_hash(k), "fingerprint" => to_dict(fp)))
check("contracted", s.capabilities[tr.id].state == CONTRACTED)
throws("promotion without evidence is an invalid transition", () -> Ledger.commit!(s, "PROMOTED", "HUMAN:jori", Dict{String,Any}("capability_id" => tr.id, "by" => "HUMAN:jori", "evidence_id" => "nope")))
allchecks = [CheckResult(String(n), PASS, "ok", Probe[]) for n in policy["evidence"]["required_checks"]]
ev = Evidence("ev-1", tr.id, contract_hash(k), fp, allchecks, Dict{String,Any}[], PASS, 1.0, "SYSTEM:verifier", "sha256:x")
throws("evidence from a non-verifier principal refused", () -> Ledger.commit!(s, "EVIDENCE_RECORDED", "AGENT:planner", Dict{String,Any}("evidence" => merge(to_dict(ev), Dict("produced_by" => "AGENT:planner")))))
badfp = Fingerprint("sha256:OTHER", tr.surface_hash, "sha256:pol", "sha256:tests", contract_hash(k))
throws("evidence for a different fingerprint refused", () -> Ledger.commit!(s, "EVIDENCE_RECORDED", "SYSTEM:verifier", Dict{String,Any}("evidence" => to_dict(Evidence("ev-2", tr.id, contract_hash(k), badfp, ev.checks, ev.mutants, PASS, 1.0, "SYSTEM:verifier", "sha256:y")))))
Ledger.commit!(s, "EVIDENCE_RECORDED", "SYSTEM:verifier", Dict{String,Any}("evidence" => to_dict(ev)))
check("verified", s.capabilities[tr.id].state == VERIFIED)
Ledger.commit!(s, "PROMOTED", "HUMAN:jori", Dict{String,Any}("capability_id" => tr.id, "by" => "HUMAN:jori", "evidence_id" => "ev-1"))
check("live", s.capabilities[tr.id].state == LIVE)
Ledger.commit!(s, "STALE", "SYSTEM:foundry", Dict{String,Any}("capability_id" => tr.id, "reason" => "source changed", "new_fingerprint" => to_dict(badfp)))
check("stale detaches evidence and promotion", s.capabilities[tr.id].state == STALE && isempty(s.capabilities[tr.id].evidence_id) && isempty(s.capabilities[tr.id].promoted_by))
ok, msg = Ledger.verify_chain(s.events); check("chain verifies", ok)
r = Ledger.replay(lp)
check("replay reproduces digest", Ledger.digest(r) == Ledger.digest(s))
check("replay reproduces state", r.capabilities[tr.id].state == STALE)
# tamper
lines = readlines(lp); lines[2] = replace(lines[2], "\"actor\":\"AGENT:planner\"" => "\"actor\":\"HUMAN:jori\"")
check("tamper actually altered the line", occursin("HUMAN:jori", lines[2]))
open(lp, "w") do io; for l in lines; println(io, l); end; end
throws("tampered ledger refused on replay", () -> Ledger.replay(lp))
rm(lp)

# ------------------------------------------------------------------ promotion gate (authority)
println("promotion gate")
capx = Capability(tr.id, tr, VERIFIED, k, contract_hash(k), fp, "ev-1", "", 0, "", String[])
agent = Principal(AGENT, "planner", String[]); owner = Principal(HUMAN, "jori", ["owner"]); member = Principal(HUMAN, "sam", ["member"]); sys = Principal(SYSTEM, "foundry", String[])
g(who, e=ev, f=fp) = Gates.promotion_gate(capx, who, e, f, policy)
check("agent refused AUTHORITY_INSUFFICIENT on FINANCIAL", !g(agent).ok && g(agent).refusal.code == "AUTHORITY_INSUFFICIENT")
check("agent refusal includes self-ratification reason", any(r -> occursin("agent plane", r), g(agent).refusal.reasons))
check("member refused ROLE_MISSING", !g(member).ok && g(member).refusal.code == "ROLE_MISSING")
check("system never promotes", !g(sys).ok)
check("owner allowed", g(owner).ok)
selfk = Contract(k.capability_id, k.version, k.description, k.inputs, k.effects, k.scope, k.scope_field, k.invariants, k.nominal_input, "HUMAN:jori")
capself = Capability(tr.id, tr, VERIFIED, selfk, contract_hash(selfk), fp, "ev-1", "", 0, "", String[])
evself = Evidence("ev-1", tr.id, contract_hash(selfk), fp, ev.checks, ev.mutants, PASS, 1.0, "SYSTEM:verifier", "sha256:x")
ds = Gates.promotion_gate(capself, owner, evself, fp, policy)
check("owner cannot ratify own proposal (SELF_RATIFICATION)", !ds.ok && ds.refusal.code == "SELF_RATIFICATION")
check("no evidence -> NO_EVIDENCE", g(owner, nothing).refusal.code == "NO_EVIDENCE")
evfail = Evidence("ev-1", tr.id, contract_hash(k), fp, ev.checks, ev.mutants, FAIL, 1.0, "SYSTEM:verifier", "sha256:x")
check("FAIL evidence -> EVIDENCE_NOT_PASS", g(owner, evfail).refusal.code == "EVIDENCE_NOT_PASS")
evung = Evidence("ev-1", tr.id, contract_hash(k), fp, ev.checks, ev.mutants, UNGRADABLE, 1.0, "SYSTEM:verifier", "sha256:x")
check("UNGRADABLE evidence -> EVIDENCE_NOT_PASS", g(owner, evung).refusal.code == "EVIDENCE_NOT_PASS")
check("moved fingerprint -> EVIDENCE_STALE", g(owner, ev, badfp).refusal.code == "EVIDENCE_STALE")
evlow = Evidence("ev-1", tr.id, contract_hash(k), fp, ev.checks, ev.mutants, PASS, 0.5, "SYSTEM:verifier", "sha256:x")
check("low mutation score -> MUTATION_SCORE", g(owner, evlow).refusal.code == "MUTATION_SCORE")
st_, reasons_ = Gates.staleness(fp, badfp)
check("staleness names the moved component", st_ && any(r -> startswith(r, "source changed"), reasons_))

# ------------------------------------------------------------------ observe (effect derivation)
println("observe")
b = Dict{String,Any}("resources" => Dict("account" => Dict("A1" => Dict("owner" => "jori", "balance_cents" => 100, "notes" => Any[]), "A2" => Dict("owner" => "sam", "balance_cents" => 50, "notes" => Any[]))), "external" => Dict("outbox_count" => 0, "observability" => "partial"))
a = deepcopy(b); a["resources"]["account"]["A2"]["balance_cents"] = 40
check("debit of another's account = WRITE_OTHER+FINANCIAL", Verify.observe(b, a, "jori")[1] == ["FINANCIAL", "WRITE_OTHER"])
a = deepcopy(b); a["resources"]["account"]["A2"]["balance_cents"] = 60
check("credit to another's account = FINANCIAL only", Verify.observe(b, a, "jori")[1] == ["FINANCIAL"])
a = deepcopy(b); push!(a["resources"]["account"]["A1"]["notes"], "n")
check("own note = WRITE_OWN", Verify.observe(b, a, "jori")[1] == ["WRITE_OWN"])
a = deepcopy(b); delete!(a["resources"]["account"], "A1")
check("removal = DESTRUCTIVE", Verify.observe(b, a, "jori")[1] == ["DESTRUCTIVE"])
a = deepcopy(b); a["external"]["outbox_count"] = 1
check("outbox = EXTERNAL_SEND, partial", Verify.observe(b, a, "jori")[1] == ["EXTERNAL_SEND"] && Verify.observe(b, a, "jori")[3])
check("no change = READ", Verify.observe(b, deepcopy(b), "jori")[1] == ["READ"])

# ------------------------------------------------------------------ integration (over TCP)
println("integration")
lp2 = joinpath(ROOT, "data", "test-integration.jsonl")
f, srv, appsrv = W.boot(; foundry_port=8290, app_port=8291, ledger_path=lp2, fresh=true, app_module=W.LedgerlyApp)
sleep(0.2)
ag = FoundryCore.principal_from_token(f, "tok-agent-planner"); ow = FoundryCore.principal_from_token(f, "tok-human-jori")
check("discover over TCP", FoundryCore.discover!(f, ag).ok && length(f.store.order) == 6)
S = "ledgerly.search_transactions"
check("naive refused", !FoundryCore.propose_contract!(f, ag, S; mode="naive").ok)
check("minimized accepted", FoundryCore.propose_contract!(f, ag, S; mode="minimize").ok)
vd = FoundryCore.verify!(f, ag, S)
check("search verifies PASS", vd.ok && vd.detail["evidence"]["verdict"] == "PASS")
check("evidence deterministic (same id on re-run)", FoundryCore.verify!(f, ag, S).detail["evidence"]["id"] == vd.detail["evidence"]["id"])
check("agent may promote READ", FoundryCore.promote!(f, ag, S).ok)
check("manifest exposes LIVE only", [t["name"] for t in FoundryCore.manifest(f, "ledgerly")["tools"]] == ["ledgerly_search_transactions"])
inv = FoundryCore.invoke!(f, FoundryCore.principal_from_token(f, "tok-agent-browser"), "ledgerly_search_transactions", Dict{String,Any}("q" => "coffee", "limit" => 5), "sess-jori")
check("gateway invocation works", inv.ok && inv.detail["result"]["count"] == 1)
inv2 = FoundryCore.invoke!(f, FoundryCore.principal_from_token(f, "tok-agent-browser"), "ledgerly_search_transactions", Dict{String,Any}("q" => "x", "include_all_accounts" => "1"), "sess-jori")
check("hidden knob refused at gateway", !inv2.ok && inv2.refusal.code == "INPUT_REFUSED")
# host reports: native compliance is graded from the ledger; polyfill is never evidence
br = FoundryCore.principal_from_token(f, "tok-agent-browser")
hr(host, tools; execs=nothing) = begin
    d = Dict{String,Any}("app" => "ledgerly", "host" => host, "browser_tools" => tools, "user_agent" => "test", "api" => Dict("getTools" => true))
    execs === nothing || (d["executions"] = execs)
    FoundryCore.host_report!(f, br, d)
end
check("host report refuses unknown host class", !hr("magic", String[]).ok)
check("no report -> acceptance BLOCKED", FoundryCore.host_acceptance(f, "ledgerly")["verdict"] == "BLOCKED")
hr("polyfill", ["ledgerly_search_transactions"]; execs=[Dict("tool" => "ledgerly_search_transactions", "ok" => true, "status" => 200)])
accp = FoundryCore.host_acceptance(f, "ledgerly")
check("polyfill report -> still BLOCKED (not evidence)", accp["verdict"] == "BLOCKED" && occursin("polyfill", accp["reasons"][1]))
check("invariant BLOCKED without native report", FoundryCore.host_invariant(f, "ledgerly")["verdict"] == "BLOCKED")
hr("native", String[])
check("native drift -> invariant FAIL", FoundryCore.host_invariant(f, "ledgerly")["verdict"] == "FAIL")
hr("native", ["ledgerly_search_transactions"])
check("native match without executions -> acceptance UNKNOWN", FoundryCore.host_acceptance(f, "ledgerly")["verdict"] == "UNKNOWN")
d1 = hr("native", ["ledgerly_search_transactions"])
check("identical steady-state report deduplicated", get(d1.detail, "deduplicated", false) == true)
hr("native", ["ledgerly_search_transactions"]; execs=[Dict("tool" => "ledgerly_search_transactions", "ok" => false, "reason" => "boom")])
check("failed native execution -> FAIL", FoundryCore.host_acceptance(f, "ledgerly")["verdict"] == "FAIL")
hr("native", ["ledgerly_search_transactions"]; execs=[Dict("tool" => "ledgerly_search_transactions", "ok" => true, "status" => 200)])
acc = FoundryCore.host_acceptance(f, "ledgerly")
check("native match + ok execution -> PASS", acc["verdict"] == "PASS")
inv = FoundryCore.host_invariant(f, "ledgerly")
check("invariant PASS: LIVE present, others absent", inv["verdict"] == "PASS" && all(r -> r["consistent"], inv["rows"]))
check("withdraw needs a human", !FoundryCore.withdraw!(f, ag, S, "x").ok && FoundryCore.withdraw!(f, ow, S, "test").ok)
check("after withdrawal the last native report is now inconsistent (tool still present in browser)", FoundryCore.host_invariant(f, "ledgerly")["verdict"] == "FAIL")
check("withdrawn leaves manifest", isempty(FoundryCore.manifest(f, "ledgerly")["tools"]))
okc, _ = Ledger.verify_chain(f.store.events)
check("integration chain ok + replay", okc && Ledger.digest(Ledger.replay(lp2)) == Ledger.digest(f.store))
Http.stop!(srv); W.LedgerlyApp.stop!(); rm(lp2; force=true)

println("\n$(passed) passed, $(length(failed)) failed")
exit(isempty(failed) ? 0 : 1)
