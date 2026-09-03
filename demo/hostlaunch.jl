# demo/hostlaunch.jl — locate and launch a WebMCP-capable Chromium for native acceptance.
# Shared by demo/run_demo.jl and test/acceptance_native.jl.
# ------------------------------------------------------------------ browser discovery

const CANDIDATES = [
    joinpath(get(ENV, "LOCALAPPDATA", ""), "Google", "Chrome SxS", "Application", "chrome.exe"),   # Canary
    joinpath(get(ENV, "LOCALAPPDATA", ""), "Google", "Chrome Dev", "Application", "chrome.exe"),
    joinpath(get(ENV, "LOCALAPPDATA", ""), "Google", "Chrome Beta", "Application", "chrome.exe"),
    joinpath(get(ENV, "LOCALAPPDATA", ""), "Google", "Chrome", "Application", "chrome.exe"),
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    joinpath(get(ENV, "LOCALAPPDATA", ""), "Microsoft", "Edge SxS", "Application", "msedge.exe"),
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "/usr/bin/google-chrome", "/usr/bin/chromium", "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
]
function find_browser()
    b = get(ENV, "WEBMCP_BROWSER", "")
    isempty(b) || return b
    for c in CANDIDATES
        isfile(c) && return c
    end
    ""
end

const DEFAULT_FLAGS = "--enable-features=WebMCPTesting,WebMCP --enable-blink-features=WebMCPTesting,WebMCP"

"Launch the browser detached on `url`; returns the Process (or nothing)."
function launch_browser(exe::String, url::String)
    flags = split(get(ENV, "WEBMCP_FLAGS", DEFAULT_FLAGS))
    profile = joinpath(tempdir(), "webmcp-acceptance-profile")
    args = String[exe, flags..., "--user-data-dir=$profile", "--no-first-run", "--no-default-browser-check", "--disable-gpu"]
    get(ENV, "WEBMCP_HEADLESS", "") == "1" && push!(args, "--headless=new")
    push!(args, "--new-window", url)
    run(Cmd(args); wait=false)
end

