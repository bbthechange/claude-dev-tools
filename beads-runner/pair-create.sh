#!/bin/bash
# beads-runner/pair-create.sh — N10-10 (claude-tools-l6vx) the kind:"pair"
# dossier PRODUCER, as a CLI.
#
# WHAT THIS IS
#   The "someone schedules a pair session" surface N3 (claude-tools-uxg6) left
#   as a follow-up. N3 realized the reserved `kind:"pair"` discriminator and
#   built the §2.2 arm/surface fire-action + the Inbox upcoming→ready
#   rendering, but nothing PRODUCED a pair dossier. This CLI does: it resolves
#   the engine bearer (env or Keychain), sources the runner libs, and calls the
#   `pair_create` producer (lib/timed-fyi.sh) — which builds the canonical
#   `kind:"pair"` SESSION CARD AND arms the §2.2 timer at `scheduled_at` in one
#   step. From there the EXISTING uxg6/N3 path (timer-due → pair_surface →
#   blocking ready_to_pair push via N2 + §4.5 lane visibility) carries it
#   through unchanged: before the appointment an "upcoming" card; at the
#   appointment a promoted, blocking-pushed "ready to pair on X" session.
#
#   The differential twin is the CF engine op `pair-create` (cf/src/timer.js
#   pairCreate), reachable over the HTTP transport — this CLI is the local
#   oracle/standalone face of the same producer (it runs `pair_create`, which
#   composes the substrate ops the CF op composes server-side).
#
# USAGE
#   pair-create.sh --bead-ref=<id> --scheduled-at=<RFC-3339 …Z> \
#                  [--tldr="pair on X"] [--full-detail="…"] \
#                  [--dossier-id=<safe-id>] [--dry-run]
#
#   --bead-ref      REQUIRED. The bead the session pairs on (the §4.1 bead_ref).
#   --scheduled-at  REQUIRED. The appointment time, RFC-3339 UTC (e.g.
#                   2026-06-02T15:00:00Z). Fail-closed if missing/unparseable.
#   --tldr          OPTIONAL. The Inbox row title ("pair on X"); defaults to
#                   "pair on <bead_ref>".
#   --full-detail   OPTIONAL. The session brief prose.
#   --dossier-id    OPTIONAL. Override the deterministic id (default
#                   `pair-<bead_ref>`). Must be key-safe ([A-Za-z0-9._-]).
#   --dry-run       OPTIONAL. Run the REAL producer against a throwaway,
#                   in-process store (NO engine, NO Keychain, NO side effects)
#                   and print the envelope it would create. Use to preview the
#                   exact shape before scheduling for real.
#
# ENGINE TRANSPORT (non-dry-run)
#   COORDINATOR_URL   the live engine (default the hosted Worker). When set,
#                     co-http-transport.sh routes the producer's writes there.
#   COORDINATOR_TOKEN the bearer; if unset it is resolved from the macOS
#                     Keychain item $CO_TOKEN_KEYCHAIN_ITEM
#                     (default "claude-beads-runner.coordinator-token").
set -euo pipefail

PCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCS_LIB_DIR="${PCS_LIB_DIR:-$PCS_DIR/lib}"
CO_TOKEN_KEYCHAIN_ITEM="${CO_TOKEN_KEYCHAIN_ITEM:-claude-beads-runner.coordinator-token}"
DEFAULT_COORDINATOR_URL="https://coordinator-cf.bbthechange.workers.dev"

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

bead_ref=""; scheduled_at=""; tldr=""; full_detail=""; dossier_id=""; dry_run=0
for arg in "$@"; do
  case "$arg" in
    --bead-ref=*)     bead_ref="${arg#*=}" ;;
    --scheduled-at=*) scheduled_at="${arg#*=}" ;;
    --tldr=*)         tldr="${arg#*=}" ;;
    --full-detail=*)  full_detail="${arg#*=}" ;;
    --dossier-id=*)   dossier_id="${arg#*=}" ;;
    --dry-run)        dry_run=1 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "pair-create: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

[[ -n "$bead_ref" ]]     || { echo "pair-create: --bead-ref is required (try --help)" >&2; exit 2; }
[[ -n "$scheduled_at" ]] || { echo "pair-create: --scheduled-at is required (try --help)" >&2; exit 2; }

# ── source the runner libs (order mirrors flow-f-overview-poll.sh /
#    engine-bridge.sh: stuck-routing pulls dossier-gen → dossier → coordinator;
#    notification owns §4.3; co-http-transport overrides co_request when
#    COORDINATOR_URL is set; timed-fyi owns pair_create/pair_arm). ──
source_libs() {
  # shellcheck source=/dev/null
  . "$PCS_LIB_DIR/stuck-routing.sh"
  # shellcheck source=/dev/null
  . "$PCS_LIB_DIR/notification.sh"
  # shellcheck source=/dev/null
  . "$PCS_LIB_DIR/co-http-transport.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$PCS_LIB_DIR/timed-fyi.sh"
}

if [[ "$dry_run" -eq 1 ]]; then
  # Preview against a throwaway in-process store — NO engine, NO Keychain.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  export CO_STORE="$tmp/store"
  unset COORDINATOR_URL COORDINATOR_TOKEN CO_EXPECTED_TOKEN 2>/dev/null || true
  source_libs
  bearer="dry-run-bearer"
  if ! did="$(pair_create "$bearer" "$bead_ref" "$scheduled_at" "$tldr" "$full_detail" "$dossier_id")"; then
    echo "pair-create: DRY-RUN rejected the inputs (see the reason above)" >&2
    exit 1
  fi
  echo "DRY-RUN — would create + arm this kind:\"pair\" dossier:" >&2
  do_dossier_get "$bearer" "$did" | jq .
  echo "DRY-RUN — armed the §2.2 timer at scheduled_at=$scheduled_at (no engine was contacted)" >&2
  exit 0
fi

# ── real path: resolve the live engine bearer + URL, then produce ────────────
: "${COORDINATOR_URL:=$DEFAULT_COORDINATOR_URL}"
export COORDINATOR_URL
if [[ -z "${COORDINATOR_TOKEN:-}" ]] && command -v security >/dev/null 2>&1; then
  COORDINATOR_TOKEN="$(security find-generic-password -s "$CO_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[[ -n "${COORDINATOR_TOKEN:-}" ]] || {
  echo "pair-create: no COORDINATOR_TOKEN (env unset and Keychain item '$CO_TOKEN_KEYCHAIN_ITEM' not found). Set COORDINATOR_TOKEN or use --dry-run." >&2
  exit 3
}
export COORDINATOR_TOKEN
source_libs

if did="$(pair_create "$COORDINATOR_TOKEN" "$bead_ref" "$scheduled_at" "$tldr" "$full_detail" "$dossier_id")"; then
  echo "$did"
  echo "pair-create: scheduled kind:\"pair\" session '$did' on $bead_ref @ $scheduled_at (upcoming until then; surfaces as a blocking 'ready to pair' push at the appointment)." >&2
  exit 0
fi
echo "pair-create: failed to create the kind:\"pair\" session (see the reason above)" >&2
exit 1
