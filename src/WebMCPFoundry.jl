# WebMCPFoundry.jl — module assembly. Pure Julia; standard library only.
#
# Layering (Strategy -> Requirements -> Domain -> CIM -> PIM, SMF-style):
#   json/http      : transport primitives (no semantics)
#   model          : the typed vocabulary (effects, verdicts, bindings, lifecycle)
#   ledger         : authoritative state as a replayable hash chain
#   discovery      : human surface -> candidates (over-broad by construction)
#   minimize       : candidate -> minimized contract proposal (system plane)
#   validate       : agent input -> bound app input (the only crossing)
#   budget         : invocation budgets enforced from the ledger
#   verify         : external-oracle checks + mutants -> evidence (system plane)
#   gates          : deterministic decisions (contract / policy / promotion / stale)
#   foundry        : gated operations over the store
#   server         : HTTP boundary (API, console UI, WebMCP gateway)

module WebMCPFoundry

include("json.jl")
include("http.jl")
include("model.jl")
include("ledger.jl")
include("discovery.jl")
include("minimize.jl")
include("validate.jl")
include("budget.jl")
include("verify.jl")
include("gates.jl")
include("foundry.jl")
include("server.jl")

using .JSON, .Http, .Model, .Ledger, .Discovery, .Minimize, .Validate, .Budget, .Verify, .Gates, .FoundryCore, .Server

const ROOT = normpath(joinpath(@__DIR__, ".."))

"""
    boot(; foundry_port=8090, app_port=8091, ledger_path=..., fresh=false)

Starts the demo app (with oracle enabled) and the Foundry in this process, on two
separate TCP listeners. Returns (foundry, foundry_server, app_server).
"""
function boot(; foundry_port::Int=8090, app_port::Int=8091, ledger_path::String=joinpath(ROOT, "data", "ledger.jsonl"),
              fresh::Bool=false, app_module=nothing, foundry_url=nothing)
    fresh && isfile(ledger_path) && rm(ledger_path)
    store = isfile(ledger_path) ? Ledger.replay(ledger_path) : Ledger.Store(ledger_path)
    f = FoundryCore.Foundry(ROOT; store=store, app_port=app_port)
    app_srv = nothing
    if app_module !== nothing
        app_srv = app_module.start!(app_port; oracle=true, foundry_url=foundry_url === nothing ? "http://127.0.0.1:$foundry_port" : String(foundry_url))
    end
    srv = Server.start!(f, foundry_port)
    (f, srv, app_srv)
end

end # module WebMCPFoundry
