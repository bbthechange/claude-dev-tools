#!/bin/bash
# beads-runner/daemon/one-shot-outbox-drain.sh — claude-tools-1p0u
#
# A standalone helper that sources the daemon's libs and runs ONE pass of
# daemon_outbox_drain_once against the live $DAEMON_CACHE_DIR/coordinator-
# outbox.jsonl. Useful for:
#   - validating the 1p0u fix end-to-end against the deployed Worker without
#     restarting the running daemon.
#   - manually draining a backlog accumulated before the fix was deployed.
#
# Exits 0 on success (drained whatever could be drained); the rewrite-survivors
# contract in la_outbox_drain means any line that fails to push is retained for
# the next pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DAEMON_REPO_DIR="$(cd "$HERE/.." && pwd)"
export DAEMON_REPO_LIB_DIR="$DAEMON_REPO_DIR/lib"

# Stub `log` so usage-poll's _usage_poll_log surfaces here.
log() { printf '%s [one-shot-drain] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*"; }

# shellcheck source=/dev/null
. "$HERE/workspace-registry.sh"
# shellcheck source=/dev/null
. "$HERE/usage-poll.sh"

WORKSPACES_JSON="${BEADS_DAEMON_CONFIG_DIR:-$HOME/.config/claude-tools}/workspaces.json"
if ! registry_load "$WORKSPACES_JSON"; then
  echo "one-shot-drain: FATAL: could not load workspace registry from $WORKSPACES_JSON" >&2
  exit 1
fi

before=0
[[ -f "$USAGE_POLL_OUTBOX" ]] && before="$(wc -l < "$USAGE_POLL_OUTBOX" | tr -d ' ')"
log "outbox before drain: $before line(s) at $USAGE_POLL_OUTBOX"
log "registered workspaces: $(registry_count)"

daemon_outbox_drain_once

after=0
[[ -f "$USAGE_POLL_OUTBOX" ]] && after="$(wc -l < "$USAGE_POLL_OUTBOX" | tr -d ' ')"
log "outbox after  drain: $after line(s) (drained: $((before - after)))"
