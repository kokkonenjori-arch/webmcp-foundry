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
    # a fresh profile per launch guarantees a NEW browser process (an existing instance would just
    # open a tab, and its older pages would keep reporting with their own one-shot state)
    profile = joinpath(tempdir(), "webmcp-acceptance-" * string(round(Int, time() * 1000)))
    args = String[exe, flags..., "--user-data-dir=$profile", "--no-first-run", "--no-default-browser-check", "--disable-gpu"]
    get(ENV, "WEBMCP_HEADLESS", "") == "1" && push!(args, "--headless=new")
    push!(args, "--new-window", url)
    proc = run(Cmd(args); wait=false)
    LAST_PROFILE[] = profile
    proc
end

const LAST_PROFILE = Ref{String}("")

"Kill every browser process using the profile we launched (Chrome re-spawns itself, so killing the launcher is not enough)."
function kill_browser!(profile::String=LAST_PROFILE[])
    isempty(profile) && return
    if Sys.iswindows()
        tag = replace(basename(profile), "'" => "")
        cmd = "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*$tag*' -and (\$_.Name -eq 'chrome.exe' -or \$_.Name -eq 'msedge.exe') } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }"
        try run(`powershell -NoProfile -Command $cmd`; wait=true) catch end
    end
    nothing
end

