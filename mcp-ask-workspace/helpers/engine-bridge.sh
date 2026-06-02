#!/usr/bin/env bash
# mcp-ask-workspace/helpers/engine-bridge.sh — sub-process bridge from the Node
# `ask-workspace` MCP server (K1, claude-tools-uxvk1; DESIGN K §1) to the
# beads-runner libs (coordinator/co-http-transport for the relay ops; the
# dossier-gen / notification / stuck-routing chain for the §5 ESCALATION leg
# the fork inherits from ask-brian VERBATIM).
#
# This is a faithful FORK of mcp-askbrian/helpers/engine-bridge.sh. It keeps the
# four inherited escalation sub-commands (`id_for` / `write_polished` /
# `write_fallback` / `poll_once`) so the 20% that escalates can reuse the
# ask-brian dossier-publish-and-block path with no new dossier machinery, and
# ADDS the two cross-WS relay sub-commands DESIGN K §1.4 calls for:
#
#   relay_log_append <exchange_json>
#       INSERT one row into the K2 `relay_log` transient (CF op
#       `relay-log-append`). Called ONCE per exchange after the verdict
#       resolves: outcome:"resolved" for an answer, outcome:"escalated" (with
#       the just-created Flow B dossier id) for the 20%. Append-only (A.2) — the
#       final outcome is known at append time (the dossier is created BEFORE the
#       responder returns), so one INSERT captures it. Echoes nothing on
#       success; nonzero rc on a transport/validation failure (the CALLER treats
#       a relay-append miss as a tolerated warn — the answer already landed in A
#       and the dossier is durable cloud-side; the relay log is an audit trail,
#       never a gate).
#
#   relay_log_tail [project_ref] [n]
#       The B.3 `{exchanges:[...]}` projection (CF op `relay-log-tail`). A
#       pure read; the `/cross-ws` view (K5) is the primary consumer. Echoes
#       the JSON projection on stdout.
#
#   emit_fyi <from_ws> <ref>   (claude-tools-mhcp.1; DESIGN K §4.2 item 1)
#       Emit ONE digest-eligible `timed-fyi` notification for an ANSWERED
#       cross-WS exchange so K3's read-side rollup (no_digest) batches it. The
#       answer path has NO dossier (only the 20% escalate creates one), so this
#       is the DOSSIER-LESS sibling of the escalation leg's emit_and_dispatch:
#       it builds the K3-owned channel (xws:<from_ws>) and calls the
#       notification.sh producer `no_emit_fyi`, which COMPOSES the generic
#       `put notification` front door (NO new CF op). Echoes nothing on success;
#       a miss is a tolerated caller warn (the relay row is the audit trail).
#
# Inherited escalation sub-commands (UNCHANGED from the ask-brian bridge):
#
#   id_for <task_ref>           — deterministic dossier id (sr_dossier_id_for).
#   write_polished <gi_json>    — persist a §4.1 envelope + emit/dispatch.
#   write_fallback <dossier_id> <bead_ref> <worker_ask_json>
#                               — the jq-deterministic author (dg_from_worker_ask)
#                                 + emit/dispatch. The escalate leg uses THIS:
#                                 the responder already handed us a structured
#                                 conflict, so no second dossier-builder runs.
#   poll_once <dossier_id>      — block-until-every-item-resolved poll (the same
#                                 claude-tools-88e multi-item discipline).
#
# Auth: COORDINATOR_URL + COORDINATOR_TOKEN must be set in the env (the
# user-scope MCP add command's -e flags). With no COORDINATOR_URL the in-process
# bash store is used — note that the K2 `relay_log` transient is a CF-only op
# (cf/src/relay.js) with NO in-process twin, so `relay_log_append`/`-tail`
# require a live COORDINATOR_URL; offline they return rc 2 (unknown op), which
# the caller tolerates for the append leg.

set -uo pipefail

ME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RUNNER_LIB_DIR="${MCP_ASK_WORKSPACE_LIB_DIR:-$ME_DIR/../../beads-runner/lib}"

# Source the libs in the same order run-beads-tasks.sh does so the in-process
# co_request is wired BEFORE co-http-transport.sh overrides it (when
# COORDINATOR_URL is set).
# shellcheck source=/dev/null
. "$RUNNER_LIB_DIR/stuck-routing.sh"     # pulls dossier-gen → dossier → coordinator
# shellcheck source=/dev/null
. "$RUNNER_LIB_DIR/notification.sh"
# shellcheck source=/dev/null
. "$RUNNER_LIB_DIR/co-http-transport.sh"

bearer() { printf '%s' "${COORDINATOR_TOKEN:-bearer-runner-mcp-ask-workspace}"; }

cmd_id_for() {
  local tref="${1:-}"
  [[ -n "$tref" ]] || { echo "engine-bridge: id_for needs <task_ref>" >&2; return 2; }
  sr_dossier_id_for "$tref"
}

# Emit + dispatch the §4.3 Notification for a dossier that is already
# persisted. Tolerates the idempotent "already emitted" path. (Inherited; used
# by the escalation leg only.)
emit_and_dispatch() {
  local did="${1:-}" b nid
  [[ -n "$did" ]] || { echo "engine-bridge: emit_and_dispatch needs <dossier_id>" >&2; return 2; }
  b="$(bearer)"
  nid="$(no_emit "$b" "$did" 2>&1)" || {
    echo "engine-bridge: no_emit warn for '$did': $nid" >&2
    return 0
  }
  no_dispatch "$b" "$nid" "mcp-ask-workspace" >/dev/null 2>&1 || true
}

cmd_write_polished() {
  local gi="${1:-}" did b
  [[ -n "$gi" ]] || { echo "engine-bridge: write_polished needs <gi_json>" >&2; return 2; }
  b="$(bearer)"
  did="$(dg_generate "$b" "$gi")" || return $?
  [[ -n "$did" ]] || { echo "engine-bridge: write_polished — dg_generate returned no id" >&2; return 3; }
  emit_and_dispatch "$did"
  printf '%s' "$did"
}

cmd_write_fallback() {
  local did="${1:-}" bref="${2:-}" ask="${3:-}" out b
  [[ -n "$did" && -n "$bref" && -n "$ask" ]] || {
    echo "engine-bridge: write_fallback needs <dossier_id> <bead_ref> <worker_ask_json>" >&2; return 2; }
  b="$(bearer)"
  out="$(dg_from_worker_ask "$b" "$did" "$bref" "$ask")" || return $?
  [[ -n "$out" ]] || { echo "engine-bridge: write_fallback — dg_from_worker_ask returned no id" >&2; return 3; }
  emit_and_dispatch "$did"
  printf '%s' "$did"
}

cmd_poll_once() {
  local did="${1:-}" b rec all_resolved
  [[ -n "$did" ]] || { echo "engine-bridge: poll_once needs <dossier_id>" >&2; return 2; }
  b="$(bearer)"
  rec="$(do_dossier_get "$b" "$did" 2>/dev/null)" || return 1
  [[ -n "$rec" ]] || return 1
  printf '%s' "$rec" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
  # Multi-item dossiers (claude-tools-88e): block until EVERY item has moved out
  # of `open`. One tool call covers all items in the dossier.
  all_resolved=$(printf '%s' "$rec" | jq -r '
    ( .items // [] ) as $items
    | if ($items | length) == 0 then "false"
      else (if ($items | all(.state != "open")) then "true" else "false" end)
      end
  ' 2>/dev/null) || all_resolved="false"
  [[ "$all_resolved" == "true" ]] || return 0   # still pending — caller keeps polling
  printf '%s' "$rec" | jq -c '
    def nz: select((. // "") != "");
    { items:
      [ ( .items // [] )[]
        | ( .response // {} ) as $r
        | ( ($r.selected_option_id | nz) // "" ) as $sel
        | ( ($r.decision | nz) // "" ) as $dec
        | ( ( .options // [] ) | map(select(.option_id==$sel)) | .[0] // {} ) as $opt
        | ( ($sel | nz) // ($dec | nz) // "" ) as $chosen
        | { item_id:(.id // ""),
            state:(.state // ""),
            ask:( (.framing.ask | nz) // (.context_anchor.where | nz) // "" ),
            chosen:$chosen,
            chosen_label:( ($opt.label | nz) // ($chosen | nz) // "(answered — see the dossier)" ),
            chosen_blast_radius:( $opt.blast_radius // "" ),
            free_text:( ($r.free_text | nz) // ($r.note | nz) // ($r.edited_value | nz) // ($r.text | nz) // "" ),
            response:$r } ]
    }'
}

# ── K2 relay_log ops (DESIGN K §1.4 — the two sub-commands the fork ADDS) ─────
# relay_log_append <exchange_json> — INSERT one append-only row. CF-only op (no
# in-process twin); requires a live COORDINATOR_URL. The CF op returns
# text("",200) on the INSERT and text("",422) on a reject; co_request maps those
# to rc 0 / rc 1 respectively. A bad arg ⇒ rc 2. Echoes nothing on success.
cmd_relay_log_append() {
  local ex="${1:-}" b
  [[ -n "$ex" ]] || { echo "engine-bridge: relay_log_append needs <exchange_json>" >&2; return 2; }
  b="$(bearer)"
  co_request "$b" relay-log-append "$ex" >/dev/null || return $?
}

# emit_fyi <from_ws> <ref> — emit ONE digest-eligible timed-fyi notification for
# an ANSWERED cross-WS exchange (claude-tools-mhcp.1; DESIGN K §4.2 item 1), so
# K3's read-side rollup (no_digest) batches it into ONE daily digest entry. The
# answer path has NO dossier (only the 20% escalate creates one — §3.3), so this
# is the DOSSIER-LESS sibling of the escalation leg's emit_and_dispatch: it
# builds the cross-WS channel via the K3-owned `no__xws_channel` convention
# (xws:<from_ws>, matching the relay row's project_ref=from_ws so the digest
# expands via relay-log-tail[from_ws]) and calls no_emit_fyi. CF-backed through
# the generic `put notification` front door no_emit_fyi composes — NO new CF op.
# Echoes nothing on success; nonzero rc on a transport/validation failure — the
# CALLER treats a miss as a tolerated warn (the answer already landed in A and
# the relay row is the durable audit trail; the FYI is a notification, never a
# gate).
cmd_emit_fyi() {
  local from_ws="${1:-}" ref="${2:-}" b channel
  [[ -n "$from_ws" && -n "$ref" ]] || { echo "engine-bridge: emit_fyi needs <from_ws> <ref>" >&2; return 2; }
  b="$(bearer)"
  channel="$(no__xws_channel "$from_ws")"
  no_emit_fyi "$b" "$channel" "$ref" >/dev/null || return $?
}

# relay_log_tail [project_ref] [n] — the B.3 {exchanges:[...]} projection. Pure
# read. Omitting project_ref returns the cross-WS log across all workspaces.
# Only forward args that are actually present so the global call sends [] (not
# ["",""]) — `n` is positional-2, so a limit without a project_ref forwards an
# empty placeholder to keep `n` in slot 2 (relay-log-tail reads "" as "all").
cmd_relay_log_tail() {
  local pr="${1:-}" n="${2:-}" b
  b="$(bearer)"
  if [[ -n "$pr" && -n "$n" ]]; then
    co_request "$b" relay-log-tail "$pr" "$n"
  elif [[ -n "$pr" ]]; then
    co_request "$b" relay-log-tail "$pr"
  elif [[ -n "$n" ]]; then
    co_request "$b" relay-log-tail "" "$n"
  else
    co_request "$b" relay-log-tail
  fi
}

main() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    id_for)            cmd_id_for "$@" ;;
    write_polished)    cmd_write_polished "$@" ;;
    write_fallback)    cmd_write_fallback "$@" ;;
    poll_once)         cmd_poll_once "$@" ;;
    relay_log_append)  cmd_relay_log_append "$@" ;;
    relay_log_tail)    cmd_relay_log_tail "$@" ;;
    emit_fyi)          cmd_emit_fyi "$@" ;;
    *)
      echo "engine-bridge: unknown subcommand '$sub' (id_for|write_polished|write_fallback|poll_once|relay_log_append|relay_log_tail|emit_fyi)" >&2
      return 2
      ;;
  esac
}

main "$@"
