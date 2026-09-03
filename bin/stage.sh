#!/usr/bin/env bash
# bin/stage.sh — stage manager for recording: put the deployed demo into a known state between takes.
# Uses only the existing public API (no runtime changes). Default target: the GCP primary.
#
#   bash bin/stage.sh status                 # states of all capabilities + what the browser last reported
#   bash bin/stage.sh reset                  # deterministic start: fresh ledger (old one archived), app re-seeded, handlers at v1
#   bash bin/stage.sh search-live            # reset + search_transactions LIVE           (Judge flow after step 2)
#   bash bin/stage.sh transfer-live          # + apply_adjustment repaired/VERIFIED + transfer_funds LIVE  (after step 7; for the STALE scene)
#   bash bin/stage.sh four-live              # + add_note and apply_adjustment LIVE       (after step 5 + blast-radius prerequisites)
#   bash bin/stage.sh stale-transfer         # from transfer-live: switch transfer_funds source → rescan → STALE (browser drops it)
#   bash bin/stage.sh blast                  # from four-live: switch shared _money.jl → rescan → 2 STALE, 2 survive
#   bash bin/stage.sh requalify <cap> ...    # verify + owner-promote the named capabilities (e.g. transfer_funds apply_adjustment)
#   bash bin/stage.sh impact [node]          # blast-radius prediction (default: source:actions/_money.jl)
#
#   FOUNDRY=https://... APP=https://...      # override targets (workstation fallback, local, ...)
set -euo pipefail
FOUNDRY="${FOUNDRY:-https://foundry.136.111.215.133.nip.io}"
APP="${APP:-https://ledgerly.136.111.215.133.nip.io}"
AGENT=tok-agent-planner; OWNER=tok-human-jori
post() { curl -s -m 180 -X POST -H "X-Foundry-Token: $2" -H 'Content-Type: application/json' -d "${3:-{\}}" "$FOUNDRY$1"; }
get()  { curl -s -m 60 "$FOUNDRY$1"; }
j()    { local code=$1; shift; python -c "import json,sys; d=json.load(sys.stdin); $code" "$@"; }
cap()  { echo "ledgerly.$1"; }
contract() { post "/api/capabilities/$(cap "$1")/contract" $AGENT '{"mode":"minimize"}' | j 'print("  contract", sys.argv[1], "ok" if d["ok"] else d["refusal"]["code"])' "$1"; }
verify()   { post "/api/capabilities/$(cap "$1")/verify"   $AGENT | j 'print("  verify  ", sys.argv[1], d["detail"]["evidence"]["verdict"] if d["ok"] else d["refusal"]["code"])' "$1"; }
promote()  { post "/api/capabilities/$(cap "$1")/promote"  "${2:-$OWNER}" | j 'print("  promote ", sys.argv[1], "LIVE" if d["ok"] else d["refusal"]["code"])' "$1"; }
source_v() { post "/api/demo/source" $AGENT "{\"name\":\"$1\",\"version\":\"$2\"}" | j 'print("  source  ", sys.argv[1], sys.argv[2], "ok" if d["ok"] else d)' "$1" "$2"; }
rescan()   { post "/api/rescan" $AGENT | j 'print("  rescan  stale:", sorted(d["detail"]["stale"].keys()))'; }
status() {
  get /api/capabilities | j 'print("  " + "  ".join(c["id"].split(".")[1] + "=" + c["state"] for c in d["capabilities"]))'
  get "/api/webmcp/host-status?app=ledgerly" | j 'print("  browser:", ("#%s %s %s" % (d["seq"], d["payload"]["host"], d["payload"]["report"].get("browser_tools"))) if d.get("seq") else "no host report yet")'
  get "/api/webmcp/manifest?app=ledgerly" | j 'print("  manifest:", [t["name"] for t in d["tools"]])'
}
reset() { post /api/demo/reset $OWNER | j 'print("  reset ok; archived", d["detail"]["archived_ledger"] or "(none)")'; post /api/discover $AGENT > /dev/null; echo "  discovered"; }
case "${1:-status}" in
  status) status ;;
  reset) reset; status ;;
  search-live) reset; contract search_transactions; verify search_transactions; promote search_transactions $AGENT; status ;;
  transfer-live) reset; contract search_transactions; verify search_transactions; promote search_transactions $AGENT
       contract apply_adjustment; source_v apply_adjustment v2; rescan; verify apply_adjustment
       contract transfer_funds; verify transfer_funds; promote transfer_funds; status ;;
  four-live) "$0" transfer-live > /dev/null; contract add_note; verify add_note; promote add_note; promote apply_adjustment; status ;;
  stale-transfer) source_v transfer_funds v2; rescan; status ;;
  blast) get "/api/impact?change=source:actions/_money.jl" | j 'print("  predicted:", d["summary"], "| survivors", d["survivors"])'; source_v _money v2; rescan; status ;;
  requalify) shift; for c in "$@"; do verify "$c"; promote "$c"; done; status ;;
  impact) get "/api/impact?change=${2:-source:actions/_money.jl}" | j 'print("  ", d["summary"]); [print("   ", r["tool"], r["state"], "affected" if r["affected"] else "-", "WITHDRAWN" if r["withdrawn"] else "") for r in d["rows"]]' ;;
  *) echo "unknown command $1"; exit 2 ;;
esac
