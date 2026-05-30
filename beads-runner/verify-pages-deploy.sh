#!/usr/bin/env bash
# verify-pages-deploy.sh — confirm the unified `claude-wrangler` Cloudflare Pages
# deployment matches the committed source. Catches the "closed bd task without
# deploying" failure mode (claude-tools-bgw).
#
# Usage:
#   beads-runner/verify-pages-deploy.sh                # verifies ALL routes
#   beads-runner/verify-pages-deploy.sh board          # verifies just /board
#   beads-runner/verify-pages-deploy.sh inbox
#   beads-runner/verify-pages-deploy.sh intake
#   beads-runner/verify-pages-deploy.sh workspaces     # C-shell global hub (B6)
#   beads-runner/verify-pages-deploy.sh capacity       # C-shell global capacity view
#   beads-runner/verify-pages-deploy.sh cross-ws       # C-shell Cross-WS surface
#   beads-runner/verify-pages-deploy.sh workspace      # C-shell /ws/* facet shell
#   beads-runner/verify-pages-deploy.sh shared          # C-shell shared modules (net/dom/shell/tokens)
#
# Exit 0 if every static asset under each route prefix matches the deployed byte
# count; non-zero (and prints the mismatched files) otherwise.
#
# Why one host, three route prefixes: UX-DESIGN.md §2 — Board/Inbox/Intake are
# ROUTES inside one responsive web app, not separate Pages projects. The unified
# project lives at `claude-wrangler.pages.dev` with `/board`, `/inbox`, `/intake`
# (the apps' static assets) and `/api/{board,inbox,intake}/*` (their Pages
# Functions). See claude-tools-b59.

set -euo pipefail

HOST="claude-wrangler.pages.dev"
WEB_ROOT="beads-runner/web"

route_arg="${1:-all}"
# `shared` is an ASSET dir, not a nav route — but every page hard-depends on
# /shared/{net,dom,shell}.js + /shared/tokens.css, so a stale/failed shared
# deploy breaks all routes at runtime while their own bytes still match. It is
# therefore verified as part of `all` (and addressable on its own) — otherwise
# `mismatches=0` would be a false green (the exact closed-but-not-shipped trap).
case "$route_arg" in
  board|inbox|intake|workspaces|capacity|cross-ws|workspace|shared) routes=("$route_arg") ;;
  all) routes=(board inbox intake workspaces capacity cross-ws workspace shared) ;;
  *) echo "usage: $0 [board|inbox|intake|workspaces|capacity|cross-ws|workspace|shared|all]" >&2; exit 2 ;;
esac

if [ ! -d "$WEB_ROOT" ]; then
  echo "verify-pages-deploy: $WEB_ROOT not found (run from repo root)" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

total_mismatches=0
total_checked=0

for proj in "${routes[@]}"; do
  root="$WEB_ROOT/$proj"
  if [ ! -d "$root" ]; then
    echo "verify-pages-deploy: $root not found" >&2
    exit 2
  fi

  echo "==> /$proj  ($root → https://$HOST/$proj/)"

  # Walk the static assets at the route root (one level — Pages doesn't
  # recurse into the functions tree for static serving, and we don't deploy
  # READMEs as content). The unified project's Pages Functions live at
  # $WEB_ROOT/functions and are not served as static files; they don't need
  # byte-for-byte verification.
  while IFS= read -r -d '' f; do
    rel="${f#"$root/"}"
    case "$rel" in
      README*) continue ;;
    esac
    committed_bytes="$(wc -c < "$f" | tr -d ' ')"
    if ! curl -fsSL "https://$HOST/$proj/$rel" -o "$tmp/got" 2>/dev/null; then
      echo "MISS    /$proj/$rel  (committed=$committed_bytes, deployed=<fetch-failed>)"
      total_mismatches=$((total_mismatches + 1))
      total_checked=$((total_checked + 1))
      continue
    fi
    deployed_bytes="$(wc -c < "$tmp/got" | tr -d ' ')"
    if [ "$committed_bytes" = "$deployed_bytes" ]; then
      echo "ok      /$proj/$rel  ($committed_bytes bytes)"
    else
      echo "DRIFT   /$proj/$rel  (committed=$committed_bytes, deployed=$deployed_bytes)"
      total_mismatches=$((total_mismatches + 1))
    fi
    total_checked=$((total_checked + 1))
  done < <(find "$root" -maxdepth 1 -type f -print0)
done

# Apex / check (mlyp). The /_redirects rewrite serves /board/ at the apex with
# status 200. The verifier confirms (a) / returns 200, and (b) its body is
# byte-identical to /board/'s body. Only meaningful when board was in scope.
if printf '%s\n' "${routes[@]}" | grep -qx board; then
  echo "==> /  (apex rewrite → /board/, see beads-runner/web/_redirects)"
  apex_status="$(curl -fsSLo "$tmp/apex" -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo "000")"
  curl -fsSL "https://$HOST/board/" -o "$tmp/board-root" 2>/dev/null || true
  if [ "$apex_status" != "200" ]; then
    echo "MISS    /  (expected 200, got $apex_status)"
    total_mismatches=$((total_mismatches + 1))
  elif [ ! -s "$tmp/board-root" ]; then
    echo "MISS    /  (could not fetch /board/ to compare)"
    total_mismatches=$((total_mismatches + 1))
  elif ! cmp -s "$tmp/apex" "$tmp/board-root"; then
    apex_bytes="$(wc -c < "$tmp/apex" | tr -d ' ')"
    board_bytes="$(wc -c < "$tmp/board-root" | tr -d ' ')"
    echo "DRIFT   /  (apex=$apex_bytes bytes, /board/=$board_bytes bytes — bodies differ)"
    total_mismatches=$((total_mismatches + 1))
  else
    echo "ok      /  ($(wc -c < "$tmp/apex" | tr -d ' ') bytes, body == /board/)"
  fi
  total_checked=$((total_checked + 1))
fi

# Clean-URL rewrite checks (the C-shell route shape, Contract C.2). For each
# global clean route in scope, confirm the bare path 200-rewrites to its served
# directory index (not a 404 / redirect roundtrip) and the body matches — the
# same discipline as the apex check above, extended to the v2 routes. The
# /ws/<ref>/<facet> catch-all is sampled with a synthetic ref; any ref serves
# the one /workspace/ shell, so the body must equal /workspace/'s.
check_rewrite() {
  local clean="$1" served="$2" st
  echo "==> $clean  (clean-route rewrite → $served, see beads-runner/web/_redirects)"
  st="$(curl -fsSLo "$tmp/clean" -w '%{http_code}' "https://$HOST$clean" 2>/dev/null || echo "000")"
  curl -fsSL "https://$HOST$served" -o "$tmp/servd" 2>/dev/null || true
  if [ "$st" != "200" ]; then
    echo "MISS    $clean  (expected 200, got $st)"; total_mismatches=$((total_mismatches + 1))
  elif [ ! -s "$tmp/servd" ]; then
    echo "MISS    $clean  (could not fetch $served to compare)"; total_mismatches=$((total_mismatches + 1))
  elif ! cmp -s "$tmp/clean" "$tmp/servd"; then
    echo "DRIFT   $clean  (body differs from served $served)"; total_mismatches=$((total_mismatches + 1))
  else
    echo "ok      $clean  (200, body == $served)"
  fi
  total_checked=$((total_checked + 1))
}
in_scope() { printf '%s\n' "${routes[@]}" | grep -qx "$1"; }

if in_scope inbox;      then check_rewrite /inbox            /inbox/;      fi
if in_scope workspaces; then check_rewrite /workspaces       /workspaces/; fi
if in_scope capacity;   then check_rewrite /capacity         /capacity/;   fi
if in_scope cross-ws;   then check_rewrite /cross-ws         /cross-ws/;   fi
if in_scope workspace;  then check_rewrite /ws/_verify/board /workspace/;  fi

echo "----"
echo "checked=$total_checked  mismatches=$total_mismatches  host=$HOST"
if [ "$total_mismatches" -gt 0 ]; then
  echo "FAIL: deploy is behind committed source. Run:"
  echo "  (cd $WEB_ROOT && npx wrangler pages deploy . --project-name claude-wrangler)"
  exit 1
fi
exit 0
