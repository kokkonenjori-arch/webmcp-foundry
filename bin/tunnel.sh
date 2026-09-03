#!/usr/bin/env bash
# bin/tunnel.sh — publish the running Foundry (8090) and Ledgerly (8091) on public HTTPS URLs
# with an install-free, keyless localhost.run SSH tunnel, then start the servers with the app
# pointed at the public Foundry origin.
#
#   bash bin/tunnel.sh            # start tunnels + servers; prints the two public URLs
#
# Notes
#   * Keyless tunnels get a fresh *.lhr.life hostname each run and live only while this
#     script runs. For a stable hostname register an SSH key at https://localhost.run/docs/forever-free/
#     and set LHR_USER (default: nokey).
#   * WebMCP requires a secure context; the tunnel terminates TLS, so document.modelContext is
#     available on the public URLs in a WebMCP-enabled browser.
set -euo pipefail
cd "$(dirname "$0")/.."
LHR_USER="${LHR_USER:-nokey}"
FPORT="${FPORT:-8090}"; APORT="${APORT:-8091}"
mkdir -p data
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=20 -o ExitOnForwardFailure=yes -T)

open_tunnel() {  # $1 local port, $2 logfile -> prints public url
  ssh "${SSH_OPTS[@]}" -R "80:localhost:$1" "$LHR_USER@localhost.run" > "$2" 2>&1 &
  echo $! > "$2.pid"
  for i in $(seq 1 30); do
    url=$(grep -o 'https://[a-z0-9.-]*\.lhr\.life' "$2" | head -1 || true)
    [ -n "$url" ] && { echo "$url"; return 0; }
    sleep 1
  done
  echo "tunnel for port $1 did not come up; see $2" >&2; return 1
}

FURL=$(open_tunnel "$FPORT" data/tunnel-foundry.log)
AURL=$(open_tunnel "$APORT" data/tunnel-app.log)
echo "Foundry console : $FURL"
echo "Ledgerly app    : $AURL"
echo "$FURL" > data/public-foundry-url.txt; echo "$AURL" > data/public-app-url.txt

cleanup() { for f in data/tunnel-foundry.log.pid data/tunnel-app.log.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; done; }
trap cleanup EXIT

exec julia bin/foundry.jl --foundry-url "$FURL" "$@"
