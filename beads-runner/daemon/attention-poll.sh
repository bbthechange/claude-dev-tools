#!/bin/bash
# beads-runner/daemon/attention-poll.sh — iz36 (claude-tools-iz36).
#
# THE GAP (incident claude-tools-jzzw, 2026-06-14): runners went process-alive
# but heartbeat-stale for DAYS while desired=running across every workspace, and
# NOTHING alerted Brian. The jzzw fixes closed the two MECHANICAL recurrences
# (daemon self-staleness re-exec; agent_actions TTL/GC) and added a cheap
# queue-backlog WARN. This poll closes the OBSERVABILITY half: it reads the
# engine's NEW top-level `attention` read-model field (the precise, sustained
# "wanted running but wedged" signal derived in workSnapshot()/co__derive_attention)
# and emits an EDGE-TRIGGERED structured WARN to the daemon log — the exact log
# where this incident was diagnosed (`ps … daemon.pid` vs the *-poll.sh mtimes).
#
# WHY a daemon-LOG signal (not a phone push) here: the phone push needs a
# conformance-gated dossier body (Mermaid + dossier_schema_version — the 4xe
# write gate) authored by a dossier-builder PLUS the §2.5 device live-verify that
# can't be done autonomously; shipping it half-verified would violate the
# notification track's first invariant ("done = lands on the phone"). That is a
# tracked follow-up. This poll is the consumer SCAFFOLD it extends: the engine
# derivation + the edge/dedup/resolve bookkeeping land here, offline-green and
# zero-storm, and the follow-up bolts a `dg_generate`+digest emit onto the SAME
# detection.
#
# THE SIGNAL IS ALREADY SUSTAINED at the engine: an `attention` alert fires only
# when the heartbeat has been silent for HOURS (ATTENTION_STALE_SECONDS, default
# 1h ≫ STALE_AFTER 180s) — the heartbeat AGE *is* the duration, so no cross-poll
# debounce is needed. This poll only avoids LOG spam: it logs once on the EDGE
# (first detection per project+kind), re-logs at most hourly while the alert
# persists (an operator heartbeat without a 60s storm), and logs RESOLVED when it
# clears.
#
# ENGINE REACH: the singleton Coordinator (workspace[0] url + Keychain bearer,
# the notif-delivery-poll/1p0u-drain pattern) — ONE `work-snapshot` call reaches
# the one DO that owns every workspace's runner state. Always returns 0; a
# transport/auth failure is logged and retried next cadence, never aborts the loop.

# Resolved at source-time; daemon.sh sets these before sourcing (defaults let this
# file be unit-tested standalone).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"

# DAEMON_CACHE_DIR is set by daemon.sh before sourcing; default for standalone tests.
DAEMON_CACHE_DIR="${DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
# The edge-trigger marker dir (one file per alerting project+kind), parallel to
# flow-f-overview-fired/. A marker means "we have already WARNed about this alert."
DAEMON_ATTENTION_FIRED_DIR="${DAEMON_ATTENTION_FIRED_DIR:-$DAEMON_CACHE_DIR/attention-fired}"

# Re-log an ongoing alert at most this often (an hourly operator heartbeat, not a
# 60s storm). Env-overridable; 0 disables re-logging (edge + resolve only).
DAEMON_ATTENTION_RELOG_SECONDS="${DAEMON_ATTENTION_RELOG_SECONDS:-3600}"

# Test/canary kill switch (parallel to DAEMON_NOTIF_DELIVERY_DISABLED). Off by default.
DAEMON_ATTENTION_DISABLED="${DAEMON_ATTENTION_DISABLED:-0}"

# Override hook: a test injects a canned work-snapshot JSON instead of hitting the
# engine. When set (non-empty), _attention_fetch_snapshot echoes it verbatim.
DAEMON_ATTENTION_SNAPSHOT_OVERRIDE="${DAEMON_ATTENTION_SNAPSHOT_OVERRIDE:-}"

_attention_log() {
  if declare -F log >/dev/null 2>&1; then
    log "[attention] $*"
  else
    printf '%s [attention] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >&2
  fi
}

# A filesystem-safe key for a project+kind pair (the marker filename).
_attention_safe_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# _attention_fetch_snapshot — echo the engine's work-snapshot JSON (all projects,
# no inline beads), or the test override. Empty string on any failure (the caller
# treats an empty/unparseable snapshot as "no alerts" — observe-first, never act
# on uncertainty).
_attention_fetch_snapshot() {
  if [[ -n "$DAEMON_ATTENTION_SNAPSHOT_OVERRIDE" ]]; then
    printf '%s' "$DAEMON_ATTENTION_SNAPSHOT_OVERRIDE"
    return 0
  fi
  local ws_count=0
  if declare -p REGISTRY_PROJECT_REFS >/dev/null 2>&1; then
    ws_count="${#REGISTRY_PROJECT_REFS[@]}"
  fi
  [[ "$ws_count" -eq 0 ]] && return 0
  local curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  local tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  [[ -n "$curl_url" ]] || return 0
  local lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  [[ -f "$lib_dir/co-http-transport.sh" ]] || return 0
  (
    set +e
    export COORDINATOR_URL="$curl_url"
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$lib_dir/co-http-transport.sh" 2>/dev/null || exit 0
    command -v co_request >/dev/null 2>&1 || exit 0
    co_request "${COORDINATOR_TOKEN:-}" work-snapshot "" "" 2>/dev/null
  )
  return 0
}

# daemon_attention_poll_once — the one cadence step. Reads the engine `attention`
# field, edge-logs new alerts, hourly-re-logs ongoing ones, and RESOLVED-logs
# cleared ones. Always returns 0.
daemon_attention_poll_once() {
  [[ "$DAEMON_ATTENTION_DISABLED" = "1" ]] && return 0

  local snap
  snap="$(_attention_fetch_snapshot)" || snap=""
  # No snapshot reachable ⇒ observe-first: do NOT touch markers, do NOT clear —
  # uncertainty must not flap RESOLVED on a transient transport failure.
  [[ -n "$snap" ]] || return 0
  printf '%s' "$snap" | jq -e 'type=="object"' >/dev/null 2>&1 || return 0
  # An OLDER engine without the field ⇒ no `.attention` ⇒ honest no-op (additive).
  printf '%s' "$snap" | jq -e 'has("attention")' >/dev/null 2>&1 || return 0

  mkdir -p "$DAEMON_ATTENTION_FIRED_DIR" 2>/dev/null || return 0

  local now; now=$(date -u +%s 2>/dev/null || echo "")
  # Build the CURRENT alert set as `key\tjson` lines (key = project_ref::kind).
  local alerts_tsv
  alerts_tsv="$(printf '%s' "$snap" | jq -r '
    (.attention.alerts // [])
    | .[] | select(type=="object")
    | ((.project_ref // "?") + "::" + (.kind // "?")) + "\t" + (@json)
  ' 2>/dev/null)" || alerts_tsv=""

  # Track which marker keys are still active this cycle (to detect resolutions).
  local active_keys=""
  if [[ -n "$alerts_tsv" ]]; then
    local line key ajson safe marker detail ref kind age logged_at relog
    while IFS=$'\t' read -r key ajson; do
      [[ -n "$key" ]] || continue
      safe="$(_attention_safe_key "$key")"
      marker="$DAEMON_ATTENTION_FIRED_DIR/$safe.json"
      active_keys="$active_keys $safe"
      ref="$(printf '%s' "$ajson" | jq -r '.project_ref // "?"' 2>/dev/null)"
      kind="$(printf '%s' "$ajson" | jq -r '.kind // "?"' 2>/dev/null)"
      detail="$(printf '%s' "$ajson" | jq -r '.detail // ""' 2>/dev/null)"
      age="$(printf '%s' "$ajson" | jq -r '.heartbeat_age_seconds // "?"' 2>/dev/null)"
      if [[ ! -f "$marker" ]]; then
        # EDGE — first detection of this alert.
        _attention_log "WARN MACHINE ATTENTION workspace=$ref kind=$kind heartbeat_age_seconds=$age — ${detail:-needs attention}"
        printf '%s\n' "$ajson" > "$marker" 2>/dev/null
        [[ -n "$now" ]] && printf '%s\n' "$now" > "$marker.at" 2>/dev/null
      else
        # ONGOING — re-log at most once per DAEMON_ATTENTION_RELOG_SECONDS so an
        # operator sees it is still broken, without a 60s storm.
        relog="$DAEMON_ATTENTION_RELOG_SECONDS"
        if [[ -n "$now" && "$relog" =~ ^[0-9]+$ && "$relog" -gt 0 ]]; then
          logged_at="$(cat "$marker.at" 2>/dev/null || echo 0)"
          [[ "$logged_at" =~ ^[0-9]+$ ]] || logged_at=0
          if [[ "$(( now - logged_at ))" -ge "$relog" ]]; then
            _attention_log "WARN MACHINE ATTENTION (ongoing) workspace=$ref kind=$kind heartbeat_age_seconds=$age — ${detail:-needs attention}"
            printf '%s\n' "$ajson" > "$marker" 2>/dev/null
            printf '%s\n' "$now" > "$marker.at" 2>/dev/null
          fi
        fi
      fi
    done <<< "$alerts_tsv"
  fi

  # RESOLVED — any marker whose key is no longer in the active set has cleared.
  local f base
  for f in "$DAEMON_ATTENTION_FIRED_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"; base="${base%.json}"
    case " $active_keys " in
      *" $base "*) : ;; # still active
      *)
        local rref rkind
        rref="$(jq -r '.project_ref // "?"' "$f" 2>/dev/null || echo "?")"
        rkind="$(jq -r '.kind // "?"' "$f" 2>/dev/null || echo "?")"
        _attention_log "RESOLVED machine attention cleared workspace=$rref kind=$rkind"
        rm -f "$f" "$f.at" 2>/dev/null
        ;;
    esac
  done
  return 0
}
