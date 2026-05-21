#!/usr/bin/env bash
# verify-pages-deploy.sh — confirm a Cloudflare Pages deployment matches the
# committed source. Catches the "closed bd task without deploying" failure
# mode (claude-tools-bgw).
#
# Usage:
#   beads-runner/web/verify-pages-deploy.sh board
#   beads-runner/web/verify-pages-deploy.sh inbox
#
# Exit 0 if every static asset under the project root matches the deployed
# byte count; non-zero (and prints the mismatched files) otherwise.

set -euo pipefail

proj="${1:-}"
case "$proj" in
  board) host="claude-wrangler-board.pages.dev"; root="beads-runner/web/board" ;;
  inbox) host="claude-wrangler-inbox.pages.dev"; root="beads-runner/web/inbox" ;;
  *) echo "usage: $0 {board|inbox}" >&2; exit 2 ;;
esac

if [ ! -d "$root" ]; then
  echo "verify-pages-deploy: $root not found (run from repo root)" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mismatches=0
checked=0

# Walk the static assets at the project root (one level — Pages doesn't
# recurse into functions/ for static serving). Skip READMEs and the
# functions/ directory.
while IFS= read -r -d '' f; do
  rel="${f#"$root/"}"
  case "$rel" in
    README*|functions/*|functions) continue ;;
  esac
  committed_bytes="$(wc -c < "$f" | tr -d ' ')"
  if ! curl -fsSL "https://$host/$rel" -o "$tmp/got" 2>/dev/null; then
    echo "MISS    $rel  (committed=$committed_bytes, deployed=<fetch-failed>)"
    mismatches=$((mismatches + 1))
    checked=$((checked + 1))
    continue
  fi
  deployed_bytes="$(wc -c < "$tmp/got" | tr -d ' ')"
  if [ "$committed_bytes" = "$deployed_bytes" ]; then
    echo "ok      $rel  ($committed_bytes bytes)"
  else
    echo "DRIFT   $rel  (committed=$committed_bytes, deployed=$deployed_bytes)"
    mismatches=$((mismatches + 1))
  fi
  checked=$((checked + 1))
done < <(find "$root" -maxdepth 1 -type f -print0)

echo "----"
echo "checked=$checked  mismatches=$mismatches  host=$host"
if [ "$mismatches" -gt 0 ]; then
  echo "FAIL: deploy is behind committed source. Run:"
  echo "  (cd $root && npx wrangler pages deploy . --project-name claude-wrangler-$proj)"
  exit 1
fi
exit 0
