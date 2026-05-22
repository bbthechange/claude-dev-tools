#!/usr/bin/env bash
# mcp-askbrian/helpers/engine-bridge.sh — sub-process bridge from the Node MCP
# server to the existing beads-runner libs (dossier-gen.sh, notification.sh,
# stuck-routing.sh, co-http-transport.sh). The Node side handles the MCP
# protocol + the dossier-builder subprocess + the poll loop; this script
# handles every interaction with the hosted engine so the schema validation,
# §0.3 anti-drift, idempotent one-per-Dossier emit, and the §4.1/§5 envelope
# stay in the existing single source of truth.
#
# Sub-commands (each reads/writes JSON over stdout; diagnostics to stderr;
# nonzero rc on failure):
#
#   id_for <task_ref>
#       Echo the deterministic dossier id (sr_dossier_id_for).
#
#   write_polished <gi_json>
#       Persist a §4.1 envelope assembled from the builder's {body, items[]}
#       and emit + dispatch the §4.3 Notification. <gi_json> is the
#       dossier-gen.sh generation-input shape (id, kind, trigger, bead_ref,
#       tier, timer_fire_at, source, items). Echoes the dossier id on
#       success; nonzero on validation/transport failure.
#
#   write_fallback <dossier_id> <bead_ref> <worker_ask_json>
#       The B3 fallback: hand the raw worker_ask straight to
#       dg_from_worker_ask (the jq-deterministic author already binds the
#       frozen §5 gate). Then emit + dispatch the Notification.
#
#   poll_once <dossier_id>
#       Read the dossier back from the hosted engine and check whether EVERY
#       item has moved out of `open` (i.e. answered/applied/expired/etc).
#       Multi-item dossiers (N>1 items) hold the worker until ALL items are
#       resolved — partial returns leak answers (claude-tools-88e: an N=3
#       dossier with all 3 answered returned only item 1, the worker re-asked
#       items 2-3, Brian's Inbox got a duplicate dossier). If every item is
#       resolved, prints ONE JSON object on stdout (and rc 0); otherwise
#       prints nothing (and rc 0). rc 1 is reserved for transport/auth
#       failure (caller keeps polling). Schema:
#         { items: [ { item_id, state, ask, chosen, chosen_label,
#                      chosen_blast_radius, free_text, response }, ... ] }
#
# Auth: COORDINATOR_URL + COORDINATOR_TOKEN must be set in the env (the
# user-scope MCP add command's -e flags). With no COORDINATOR_URL the
# in-process bash store is used (the same fallback as the runner's standalone
# / oracle / conformance runs); that lets the focused test below run without
# a hosted engine.

set -uo pipefail

ME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RUNNER_LIB_DIR="${MCP_ASKBRIAN_LIB_DIR:-$ME_DIR/../../beads-runner/lib}"

# Source the libs in the same order run-beads-tasks.sh does so the in-process
# co_request is wired BEFORE co-http-transport.sh overrides it (when
# COORDINATOR_URL is set).
# shellcheck source=/dev/null
. "$RUNNER_LIB_DIR/stuck-routing.sh"     # pulls dossier-gen → dossier → coordinator
# shellcheck source=/dev/null
. "$RUNNER_LIB_DIR/notification.sh"
# shellcheck source=/dev/null
. "$RUNNER_LIB_DIR/co-http-transport.sh"

bearer() { printf '%s' "${COORDINATOR_TOKEN:-bearer-runner-mcp-askbrian}"; }

cmd_id_for() {
  local tref="${1:-}"
  [[ -n "$tref" ]] || { echo "engine-bridge: id_for needs <task_ref>" >&2; return 2; }
  sr_dossier_id_for "$tref"
}

# Emit + dispatch the §4.3 Notification for a dossier that is already
# persisted. Tolerates the idempotent "already emitted" path.
emit_and_dispatch() {
  local did="${1:-}" b nid
  [[ -n "$did" ]] || { echo "engine-bridge: emit_and_dispatch needs <dossier_id>" >&2; return 2; }
  b="$(bearer)"
  nid="$(no_emit "$b" "$did" 2>&1)" || {
    # no_emit's rc 0 already-emitted path echoes the nid too; only nonzero
    # rcs reach here. Surface the diagnostic but don't fail the call — the
    # dossier is durable cloud-side and the daemon-resume backstop catches
    # the rest.
    echo "engine-bridge: no_emit warn for '$did': $nid" >&2
    return 0
  }
  # Best-effort dispatch flip (one-shot, never reset). Failures don't fail
  # the call — the row exists; a later sweep can flip the latch.
  no_dispatch "$b" "$nid" "mcp-askbrian" >/dev/null 2>&1 || true
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
  # Multi-item dossiers (claude-tools-88e): block until EVERY item has moved
  # out of `open`. Returning as soon as the first item resolves caused the
  # worker to receive only one answer and re-ask the rest (see sr_poll_hosted_
  # resolution at lib/stuck-routing.sh ~547 — that path is per-fork via a bfh
  # record, so the partial-return there was correct; here we have no bfh
  # record and one tool call covers all items in the dossier, so we must wait
  # for the whole dossier).
  all_resolved=$(printf '%s' "$rec" | jq -r '
    ( .items // [] ) as $items
    | if ($items | length) == 0 then "false"
      else (if ($items | all(.state != "open")) then "true" else "false" end)
      end
  ' 2>/dev/null) || all_resolved="false"
  [[ "$all_resolved" == "true" ]] || return 0   # still pending — caller keeps polling
  # Build the per-item human-readable answer records. Same nz/`//` idiom as
  # sr_poll_hosted_resolution; one entry per item in the dossier so the
  # worker sees all of Brian's answers in one tool_result.
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

main() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    id_for)         cmd_id_for "$@" ;;
    write_polished) cmd_write_polished "$@" ;;
    write_fallback) cmd_write_fallback "$@" ;;
    poll_once)      cmd_poll_once "$@" ;;
    *)
      echo "engine-bridge: unknown subcommand '$sub' (id_for|write_polished|write_fallback|poll_once)" >&2
      return 2
      ;;
  esac
}

main "$@"
