# bin/foundry.jl — start the Foundry (port 8090) and the Ledgerly demo app (port 8091).
#
#   julia bin/foundry.jl            # resume from data/ledger.jsonl (replayed + chain-verified)
#   julia bin/foundry.jl --fresh    # start from an empty ledger
#
# Standard library only. No Project activation needed.

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "WebMCPFoundry.jl"))
Base.include(WebMCPFoundry, joinpath(ROOT, "demo", "app", "LedgerlyApp.jl"))

using .WebMCPFoundry

fresh = "--fresh" in ARGS
fport = 8090; aport = 8091; furl = ""
for (i, a) in enumerate(ARGS)
    a == "--port" && (global fport = parse(Int, ARGS[i+1]))
    a == "--app-port" && (global aport = parse(Int, ARGS[i+1]))
    a == "--foundry-url" && (global furl = ARGS[i+1])     # public origin the app page should use (tunnel/deploy)
end

# under the supervisor the public Foundry origin is recorded on disk; adopt it so a restart is consistent without a push
pubfile = joinpath(ROOT, "data", "public-foundry-url.txt")
isempty(furl) && isfile(pubfile) && (global furl = strip(read(pubfile, String)))
f, srv, app = WebMCPFoundry.boot(; foundry_port=fport, app_port=aport, fresh=fresh, app_module=WebMCPFoundry.LedgerlyApp,
                                 foundry_url=isempty(furl) ? nothing : furl)
isempty(furl) || println("app page will use Foundry at : $furl")
println("WebMCP Foundry console : http://127.0.0.1:$fport/")
println("Ledgerly demo app      : http://127.0.0.1:$aport/")
println("ledger                 : $(f.store.path)  ($(length(f.store.events)) events replayed)")
flush(stdout)
wait(srv.task)
