#!/usr/bin/env bash
# bin/serve_public.sh — supervised public deployment (self-healing).
#
# Keeps three things alive and consistent, forever:
#   1. the Foundry+Ledgerly Julia process (bin/foundry.jl, resuming data/ledger.jsonl)
#   2. two HTTPS tunnels (keyless localhost.run) — restarted when their public URL stops answering /health
#   3. the STABLE public entry page on GitHub Pages (live.json) — republished whenever a tunnel URL changes
#
# Judges use the stable entry URL; it always points at the currently live origins.
# On a VPS with a fixed hostname use deploy/ instead (Caddy + systemd/docker) — this script is
# the "run it from a workstation" mode and needs the machine awake and online.
#
#   bash bin/serve_public.sh              # foreground supervisor (Ctrl-C stops everything it started)
#   LHR_USER=<registered user> ...        # stable localhost.run hostnames if you registered a key
#   PAGES_REPO=owner/name                 # GitHub Pages repo for the entry page (default: the origin remote)
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FPORT="${FPORT:-8090}"; APORT="${APORT:-8091}"
LHR_USER="${LHR_USER:-nokey}"
PAGES_REPO="${PAGES_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')}"
INTERVAL="${INTERVAL:-20}"
mkdir -p data
log() { echo "$(date -u +%FT%TZ) $*" | tee -a data/serve_public.log; }
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=20 -o ServerAliveCountMax=2 -o ExitOnForwardFailure=yes -T)

# ------------------------------------------------------------------ server
server_ok() { curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FPORT/health" 2>/dev/null | grep -q '^200$'; }
start_server() {
  log "starting julia server"
  nohup julia bin/foundry.jl --port "$FPORT" --app-port "$APORT" > data/server.log 2>&1 &
  echo $! > data/server.pid
  for i in $(seq 1 90); do server_ok && { log "server up"; return 0; }; sleep 1; done
  log "server did not come up; see data/server.log"; return 1
}

# ------------------------------------------------------------------ tunnels
declare -A TPID TURL
open_tunnel() {   # $1 name  $2 local port
  local name=$1
  local port=$2
  local logf="data/tunnel-$name.log"
  : > "$logf"
  ssh "${SSH_OPTS[@]}" -R "80:localhost:$port" "$LHR_USER@localhost.run" > "$logf" 2>&1 &
  TPID[$name]=$!
  local url=""
  for i in $(seq 1 40); do
    url=$(grep -o 'https://[a-z0-9.-]*\.lhr\.life' "$logf" | head -1 || true)
    [ -n "$url" ] && break; sleep 1
  done
  if [ -z "$url" ]; then log "tunnel $name: no url (see $logf)"; kill "${TPID[$name]}" 2>/dev/null; TPID[$name]=0; TURL[$name]=""; return 1; fi
  TURL[$name]=$url
  echo "$url" > "data/public-$name-url.txt"
  log "tunnel $name: $url"
  return 0
}
tunnel_ok() {     # $1 name : process alive AND public /health answers 200
  local name=$1
  local pid=${TPID[$name]:-0}
  local url=${TURL[$name]:-}
  [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$url" ] || return 1
  curl -s -m 12 -o /dev/null -w '%{http_code}' "$url/health" 2>/dev/null | grep -q '^200$'
}
ensure_tunnel() { # $1 name $2 port ; returns 0 if url changed
  local name=$1
  local port=$2
  local old=${TURL[$name]:-}
  tunnel_ok "$name" && return 1
  [ "${TPID[$name]:-0}" -gt 0 ] && kill "${TPID[$name]}" 2>/dev/null
  log "tunnel $name unhealthy; reopening"
  open_tunnel "$name" "$port" || return 1
  [ "${TURL[$name]}" != "$old" ]
}

# ------------------------------------------------------------------ consistency + publication
push_app_config() {   # the app page must fetch the manifest from the CURRENT public Foundry origin
  curl -s -m 5 -X POST -H 'Content-Type: application/json' -d "{\"foundry_url\":\"${TURL[foundry]}\"}" "http://127.0.0.1:$APORT/__oracle/config" > /dev/null
}
publish_pages() {     # update live.json on the gh-pages branch (stable entry page reads it)
  [ -n "$PAGES_REPO" ] || return 0
  command -v gh > /dev/null || { log "gh not available; entry page not updated"; return 0; }
  local now; now=$(date -u +%FT%TZ)
  local json="{\"foundry\":\"${TURL[foundry]}\",\"app\":\"${TURL[app]}\",\"updated\":\"$now\",\"mode\":\"supervised-tunnel\"}"
  local sha; sha=$(gh api "repos/$PAGES_REPO/contents/live.json?ref=gh-pages" -q .sha 2>/dev/null || true)
  local content; content=$(printf '%s' "$json" | base64 | tr -d '\n')
  if [ -n "$sha" ]; then
    gh api -X PUT "repos/$PAGES_REPO/contents/live.json" -f message="live: $now" -f content="$content" -f branch=gh-pages -f sha="$sha" > /dev/null 2>&1
  else
    gh api -X PUT "repos/$PAGES_REPO/contents/live.json" -f message="live: $now" -f content="$content" -f branch=gh-pages > /dev/null 2>&1
  fi && log "entry page updated: $json" || log "entry page update FAILED"
}

cleanup() { log "stopping"; for n in foundry app; do [ "${TPID[$n]:-0}" -gt 0 ] && kill "${TPID[$n]}" 2>/dev/null; done; [ -f data/server.pid ] && kill "$(cat data/server.pid)" 2>/dev/null; exit 0; }
trap cleanup INT TERM

# ------------------------------------------------------------------ main loop
TPID[foundry]=0; TPID[app]=0; TURL[foundry]=""; TURL[app]=""
server_ok || start_server
while true; do
  if ! server_ok; then
    log "server unhealthy; restarting"; [ -f data/server.pid ] && kill "$(cat data/server.pid)" 2>/dev/null; sleep 2
    start_server && [ -n "${TURL[foundry]}" ] && push_app_config   # the app's public Foundry origin is in-memory: re-push after a restart
  fi
  changed=0
  ensure_tunnel foundry "$FPORT" && changed=1
  ensure_tunnel app "$APORT" && changed=1
  if [ "$changed" = 1 ] && [ -n "${TURL[foundry]}" ] && [ -n "${TURL[app]}" ]; then
    push_app_config
    publish_pages
    log "LIVE  console=${TURL[foundry]}  app=${TURL[app]}"
  fi
  sleep "$INTERVAL"
done
