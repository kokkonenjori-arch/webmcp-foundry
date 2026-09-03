#!/usr/bin/env bash
# bin/healthcheck.sh — reachability + health of the public deployment (and local servers).
#
#   bash bin/healthcheck.sh                 # uses data/public-*-url.txt (written by the supervisor)
#   bash bin/healthcheck.sh <foundry-url> <app-url>
# Exit 0 only if both public endpoints answer /health with 200, the app's config points at the
# public Foundry origin, and the Foundry manifest is served with CORS.
cd "$(dirname "$0")/.."
F="${1:-$(cat data/public-foundry-url.txt 2>/dev/null)}"
A="${2:-$(cat data/public-app-url.txt 2>/dev/null)}"
fail=0
probe() {  # label url
  local code; code=$(curl -s -m 15 -o /tmp/hc.body -w '%{http_code}' "$2" 2>/dev/null)
  if [ "$code" = "200" ]; then printf '  %-34s %s  %s\n' "$1" "200" "$(head -c 110 /tmp/hc.body | tr -d '\n')"; else printf '  %-34s %s  FAIL\n' "$1" "${code:-000}"; fail=1; fi
}
echo "public deployment health  $(date -u +%FT%TZ)"
[ -n "$F" ] && [ -n "$A" ] || { echo "  no public URLs recorded (is bin/serve_public.sh running?)"; exit 2; }
echo "  Foundry : $F"; echo "  Ledgerly: $A"
probe "foundry /health" "$F/health"
probe "foundry manifest" "$F/api/webmcp/manifest?app=ledgerly"
probe "foundry acceptance verdict" "$F/api/webmcp/acceptance?app=ledgerly"
probe "app /health" "$A/health"
probe "app /api/config" "$A/api/config"
cfg=$(curl -s -m 15 "$A/api/config" 2>/dev/null | grep -o '"foundry_url":"[^"]*"' | cut -d'"' -f4)
if [ "$cfg" = "$F" ]; then echo "  app config → public Foundry origin  OK"; else echo "  app config → $cfg  MISMATCH (expected $F)"; fail=1; fi
cors=$(curl -s -m 15 -I "$F/api/webmcp/manifest?app=ledgerly" 2>/dev/null | grep -i 'access-control-allow-origin' | tr -d '\r')
if [ -n "$cors" ]; then echo "  manifest CORS  $cors"; else echo "  manifest CORS  MISSING"; fail=1; fi
echo "  local foundry /health: $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/health)   local app /health: $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8091/health)"
[ $fail = 0 ] && echo "RESULT: HEALTHY" || echo "RESULT: UNHEALTHY"
exit $fail
