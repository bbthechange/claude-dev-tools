#!/bin/bash
# beads-runner/cf/pages-dev/serve.sh — CF.10 (claude-tools-7g0.10).
#
# MANUAL local serve (no Cloudflare account). Stands up the FROZEN engine
# behind the CF.10 re-frame adapter + `wrangler pages dev` for the FROZEN
# Board and Inbox, seeds a demo partly-answered Dossier + a forensic blob,
# prints the URLs, and stays in the foreground until Ctrl-C.
#
# Open the Board to see the WAITING-ON-YOU lane; the Inbox to open the
# dossier, answer ONE item (the sibling stays open — AD7), and exercise the
# §10.3 forensic affordance. COORDINATOR_TOKEN is a SERVER-SIDE pages binding
# only — the browser never holds it (§9.2). The headless EXIT proof is the
# sibling verify.sh; this is the human/demo entrypoint.
#
# Stops at LOCALLY-served. NO production deploy (the a53 gate, EXCLUDED).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(cd "$HERE/.." && pwd)"
WEB_DIR="$(cd "$CF_DIR/../web" && pwd)"
WRANGLER="$CF_DIR/node_modules/.bin/wrangler"
GOOD="${CF10_TOKEN:-bearer-runner-secret-xyz}"
ADAPTER_PORT="${CF10_ADAPTER_PORT:-8787}"
BOARD_PORT="${CF10_BOARD_PORT:-8788}"
INBOX_PORT="${CF10_INBOX_PORT:-8789}"
A="http://127.0.0.1:$ADAPTER_PORT"
B="http://127.0.0.1:$BOARD_PORT"
I="http://127.0.0.1:$INBOX_PORT"

[[ -x "$WRANGLER" ]] || { echo "FATAL: wrangler not found at $WRANGLER (run npm install in cf/)"; exit 2; }

STATE="$(mktemp -d)"
PIDS=()
cleanup() {
  echo ""; echo "── shutting down local serve ──"
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" >/dev/null 2>&1 || true; done
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && pkill -P "$p" >/dev/null 2>&1 || true; done
  rm -rf "$STATE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_http() {  # wait_http <url> <want_code> [curl args...] — stable twice
  local url="$1" want="$2"; shift 2
  local i code hits=0
  for i in $(seq 1 150); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url" 2>/dev/null || echo 000)"
    if [[ "$code" == "$want" ]]; then
      hits=$((hits + 1)); [[ "$hits" -ge 2 ]] && return 0
    else hits=0; fi
    sleep 1
  done
  return 1
}

echo "── booting FROZEN engine + CF.10 re-frame adapter on $A ──"
( cd "$CF_DIR" || exit 2
  exec "$WRANGLER" dev --config wrangler.pages-dev.toml \
    --port "$ADAPTER_PORT" --ip 127.0.0.1 --persist-to "$STATE/adapter-state" ) &
PIDS+=("$!")

wait_http "$A/" 200 -H "authorization: Bearer $GOOD" || { echo "FATAL: adapter did not come up"; exit 2; }

# Boot the Pages servers SEQUENTIALLY (each ready before the next): two
# `wrangler pages dev` started concurrently race wrangler's global dev
# registry and one never binds. `pages dev` detects ./functions relative to
# CWD — run from the web-app dir with directory arg `.` (a cwd holding a
# Worker wrangler.toml is mis-read as the Pages config; web/board|inbox none).
echo "── booting wrangler pages dev — Board on $B ──"
( cd "$WEB_DIR/board" || exit 2
  exec "$WRANGLER" pages dev . --port "$BOARD_PORT" --ip 127.0.0.1 \
    --compatibility-date 2026-05-01 -b "COORDINATOR_URL=$A" -b "COORDINATOR_TOKEN=$GOOD" ) &
PIDS+=("$!")
wait_http "$B/" 200 || { echo "FATAL: Board Pages did not come up"; exit 2; }

echo "── booting wrangler pages dev — Inbox on $I ──"
( cd "$WEB_DIR/inbox" || exit 2
  exec "$WRANGLER" pages dev . --port "$INBOX_PORT" --ip 127.0.0.1 \
    --compatibility-date 2026-05-01 -b "COORDINATOR_URL=$A" -b "COORDINATOR_TOKEN=$GOOD" ) &
PIDS+=("$!")
wait_http "$I/" 200 || { echo "FATAL: Inbox Pages did not come up"; exit 2; }

echo "── seeding a demo partly-answered Dossier + forensic blob ──"
node "$HERE/seed.mjs" "$A" "$GOOD" dRT || { echo "FATAL: seed failed"; exit 2; }

cat <<EOF

  ✓ local serve up (NO Cloudflare account; production deploy = the a53 gate, EXCLUDED)

      Board   $B           (the §4.5 WAITING-ON-YOU lane)
      Inbox   $I/#/d/dRT   (open the dossier; answer ONE item — sibling stays open, AD7)
      engine  $A           (COORDINATOR_URL; token is a SERVER-SIDE binding only)

  Ctrl-C to stop.
EOF

wait
