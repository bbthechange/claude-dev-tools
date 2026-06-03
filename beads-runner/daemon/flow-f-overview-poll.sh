# shellcheck shell=bash
# beads-runner/daemon/flow-f-overview-poll.sh — P1 Flow F stage-change observer
# + proactive overview-dossier dispatch
# (claude-tools-3pq; epic claude-tools-kie).
#
# WHAT THIS IS (UX-DESIGN.md Flow F §11 amend; DESIGN.md AD7)
#   The daemon-side per-machine stage-change observer that fires Flow F
#   proactive overview dossiers. On a 60s cadence the daemon walks every
#   registered workspace, asks bd for the closed beads carrying the
#   `stage:design` label, and for each one it has not yet observed, spawns a
#   `claude -p` dossier-builder (B-track) and pushes the result to the engine
#   as a `timed-fyi` (24h auto-proceed) overview dossier. Brian gets the
#   "here's how this is going to fit together" brief on his phone without
#   having to go ask.
#
#   The trigger shape is closing-on-stage rather than transitioning-into-
#   stage so a closed bd task with `stage:design` is the natural seed:
#   bd-stage.sh enforces the one-stage invariant; until a worker advances the
#   bead past design the closed+stage:design predicate is exactly "design
#   just landed and is awaiting downstream pickup," which is the moment Brian
#   wants the overview at. The label-based detection is the floor while the
#   L-track stage-as-first-class field lands (claude-tools-u6s); the same
#   observer migrates without code change once stage is a first-class
#   column.
#
# WHAT THIS IS *NOT*
#   • NOT the dossier author. The dossier-builder (B-track, agents/
#     dossier-builder.system.md) authors the §5 body+items; this file is
#     ONLY the dispatch site + the §4.1 envelope/§2.2 timer wiring.
#   • NOT a worker-stuck path. Flow B's stuck-dossier trigger lives in
#     lib/stuck-routing.sh + mcp-askbrian/server.mjs; Flow F is a separate
#     trigger (stage close) on the same dossier substrate.
#   • NOT a workspace-runner spawner. The Flow F dispatch is a short-lived
#     `claude -p` against the workspace cwd (specialist.sh
#     --kind=dossier-builder); the workspace runner's lifecycle is M3's
#     business, independent of whether the runner is up or paused.
#
# DEDUP (one Flow F overview per bead, ever)
#   Per-bead marker files at `$DAEMON_CACHE_DIR/flow-f-overview-fired/<safe_
#   key>.json` record dispatch metadata. A bead with a marker is skipped on
#   every subsequent poll, even on a daemon restart, even if the bead is
#   re-opened and re-closed. (The marker file is the local memory; the
#   deterministic dossier id `overview-<bead_ref>` makes the engine itself
#   reject a second write — see §7.4 dossier-level dedup — so the marker is
#   belt-and-suspenders, not the only line of defense.)
#
#   First-run backlog suppression: a single seed flag file
#   `$DAEMON_CACHE_DIR/flow-f-overview-seeded.flag` records "we have seeded
#   markers for the existing backlog." On a fresh install the first poll
#   creates the flag + a marker for every already-closed stage:design bead
#   *without* dispatching, so we do not dump a year of historical design
#   closes onto Brian's phone in one shot. Subsequent polls dispatch only on
#   NEW closes.
#
# LOGGING
#   Every dispatch attempt is logged with workspace + bead_ref + outcome
#   (dispatched|skipped|refused|failed). The dossier-builder's full claude
#   stream is captured by specialist.sh under
#   <workspace>/.beads/runner-logs/specialist-dossier-builder-*.jsonl
#   (BC-27 self-gitignore); we do NOT duplicate it in the daemon log.
#
# ENGINE TRANSPORT
#   Per-workspace, like every other daemon poll: cd into the workspace,
#   export PROJECT_REF / CO_STORE / COORDINATOR_URL / COORDINATOR_TOKEN
#   from the registry + Keychain, source the runner libs (stuck-routing →
#   dossier-gen → dossier → coordinator, plus notification + co-http-
#   transport + timed-fyi), then write through the §2.3 authed front door.

# Resolve sibling paths at source time (matches intake-dispatch-poll.sh).
DAEMON_REPO_DIR="${DAEMON_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
DAEMON_REPO_LIB_DIR="${DAEMON_REPO_LIB_DIR:-$DAEMON_REPO_DIR/lib}"
DAEMON_REPO_AGENTS_DIR="${DAEMON_REPO_AGENTS_DIR:-$DAEMON_REPO_DIR/agents}"
DAEMON_SPECIALIST_SH="${DAEMON_SPECIALIST_SH:-$DAEMON_REPO_AGENTS_DIR/specialist.sh}"

# DAEMON_CACHE_DIR is set by daemon.sh before sourcing this file; default
# only for direct sourcing under tests.
DAEMON_CACHE_DIR="${DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
DAEMON_FLOW_F_FIRED_DIR="${DAEMON_FLOW_F_FIRED_DIR:-$DAEMON_CACHE_DIR/flow-f-overview-fired}"
DAEMON_FLOW_F_SEED_FLAG="${DAEMON_FLOW_F_SEED_FLAG:-$DAEMON_CACHE_DIR/flow-f-overview-seeded.flag}"

# The stage label this observer watches. Defaults to stage:design (Flow F
# seed per UX-DESIGN §11 amend); env-overridable so a project can extend the
# observer to other closing-stages (impl, tests) without forking the file.
DAEMON_FLOW_F_STAGE_LABEL="${DAEMON_FLOW_F_STAGE_LABEL:-stage:design}"

# Test/canary hook: set DAEMON_FLOW_F_DISABLED=1 to log decisions but skip
# the actual specialist.sh + engine writes. The test exercises this branch
# to verify call-site wiring without spending tokens or hitting an engine.
DAEMON_FLOW_F_DISABLED="${DAEMON_FLOW_F_DISABLED:-0}"

# Optional test override: a script that replaces specialist.sh for the
# dossier-builder invocation. When set, this takes precedence over
# DAEMON_FLOW_F_DISABLED — the override IS the dispatch path.
DAEMON_FLOW_F_BUILDER_OVERRIDE="${DAEMON_FLOW_F_BUILDER_OVERRIDE:-}"

# Optional test override: a script that replaces the engine-write subshell.
# When set, the lib calls "$DAEMON_FLOW_F_ENGINE_OVERRIDE <ws> <gi.json>" and
# expects rc 0 to mean "written". Lets the test verify dispatch wiring
# without sourcing the full coordinator stack.
DAEMON_FLOW_F_ENGINE_OVERRIDE="${DAEMON_FLOW_F_ENGINE_OVERRIDE:-}"

# daemon_flow_f__safe_key <bead_ref> — sanitize for use as a filename
#   component. Mirrors daemon_m6__safe_key's posture (no '/' or '..',
#   conservative allowed-set).
daemon_flow_f__safe_key() {
  local in="${1:-}" out
  out="${in//\//_}"
  out="${out//../_}"
  printf '%s' "$out" | tr -c 'A-Za-z0-9._-' '_'
}

# daemon_flow_f_marker_for <bead_ref> — echo the per-bead marker file path.
daemon_flow_f_marker_for() {
  local bref="${1:-}" key
  [[ -n "$bref" ]] || return 0
  key="$(daemon_flow_f__safe_key "$bref")"
  printf '%s/%s.json' "$DAEMON_FLOW_F_FIRED_DIR" "$key"
}

# daemon_flow_f_already_fired <bead_ref> — true (0) iff a marker exists.
daemon_flow_f_already_fired() {
  local mf
  mf="$(daemon_flow_f_marker_for "$1")"
  [[ -n "$mf" && -f "$mf" ]]
}

# daemon_flow_f_write_marker <bead_ref> <workspace> <outcome> [dossier_id]
#   Record a per-bead marker so subsequent polls skip the bead. ALWAYS
#   returns 0 — a marker-write failure is logged but must not abort the
#   dispatch loop (re-dispatch on next poll is preferable to crashing).
daemon_flow_f_write_marker() {
  local bref="${1:-}" ws="${2:-}" outcome="${3:-}" did="${4:-}" mf tmp
  mf="$(daemon_flow_f_marker_for "$bref")"
  [[ -n "$mf" ]] || return 0
  mkdir -p "$DAEMON_FLOW_F_FIRED_DIR" 2>/dev/null || return 0
  tmp="$mf.$$.tmp"
  if jq -cn \
        --arg b   "$bref" \
        --arg w   "$ws" \
        --arg o   "$outcome" \
        --arg d   "$did" \
        --arg ts  "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
        '{bead_ref:$b, workspace:$w, outcome:$o, dossier_id:$d, observed_at:$ts}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$mf" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  declare -F log >/dev/null 2>&1 && \
    log "Flow F: WARN — could not write marker for bead_ref=$bref (outcome=$outcome)"
  return 0
}

# daemon_flow_f__list_closed_at_stage <workspace>
#   List bd IDs at $workspace that are closed AND carry the watched stage
#   label, one per line. Subshell-isolated so a workspace's local .beads
#   does not leak its env back to the caller.
daemon_flow_f__list_closed_at_stage() {
  local ws="${1:-}"
  [[ -n "$ws" && -d "$ws" ]] || return 0
  (
    cd "$ws" 2>/dev/null || exit 0
    # --all so closed beads aren't hidden; --flat for grep-friendly shape;
    # --no-pager so a non-tty harness doesn't open less.
    bd list --label "$DAEMON_FLOW_F_STAGE_LABEL" \
            --status closed \
            --all --flat --no-pager --json 2>/dev/null \
      | jq -r 'if type=="array" then .[] | .id else empty end' 2>/dev/null
  )
}

# daemon_flow_f_seed_if_needed
#   On a fresh install, mark every currently-closed stage:design bead as
#   ALREADY-FIRED *without* dispatching, then drop the seed flag. Subsequent
#   polls dispatch only on NEW closes. Idempotent: a second call is a no-op.
#   ALWAYS returns 0.
daemon_flow_f_seed_if_needed() {
  [[ -f "$DAEMON_FLOW_F_SEED_FLAG" ]] && return 0
  mkdir -p "$DAEMON_CACHE_DIR" "$DAEMON_FLOW_F_FIRED_DIR" 2>/dev/null || return 0
  local n i ws bref count=0
  n="${#REGISTRY_DIRS[@]}"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    ws="${REGISTRY_DIRS[$i]:-}"
    if [[ -n "$ws" && -d "$ws" ]]; then
      while IFS= read -r bref; do
        [[ -n "$bref" ]] || continue
        daemon_flow_f_already_fired "$bref" && continue
        daemon_flow_f_write_marker "$bref" "$ws" "seeded" ""
        count=$((count + 1))
      done < <(daemon_flow_f__list_closed_at_stage "$ws")
    fi
    i=$((i + 1))
  done
  # Drop the seed flag last so a crashed mid-seed run is retried (the marker
  # writes are idempotent — already-marker'd beads short-circuit above).
  : > "$DAEMON_FLOW_F_SEED_FLAG" 2>/dev/null || true
  declare -F log >/dev/null 2>&1 && \
    log "Flow F: seeded $count existing closed $DAEMON_FLOW_F_STAGE_LABEL bead(s) — backlog suppressed; only NEW closes dispatch"
  return 0
}

# daemon_flow_f__build_builder_input <dossier_id> <bead_ref> <ws>
#   Build the dossier-builder stdin JSON for a Flow F overview dispatch.
#   The builder's input contract (agents/dossier-builder.system.md) is
#   stuck-flavored, so we shape the input as an overview by:
#     - the `question` is the framing ("here's how X fits together")
#     - the load-bearing `context_dump` carries the Flow F trigger context
#       explicitly: it tells the builder THIS IS NOT WORKER-STUCK — produce
#       a deep body + zero or all-fyi-objectable items, NOT a pick-option.
#     - options/recommendation/reversible are omitted (no decision being
#       forced).
daemon_flow_f__build_builder_input() {
  local did="${1:-}" bref="${2:-}" ws="${3:-}"
  local context_dump
  context_dump="FLOW F TRIGGER: the bd task \`$bref\` just closed at \`$DAEMON_FLOW_F_STAGE_LABEL\`. This is a PROACTIVE OVERVIEW dossier (UX-DESIGN.md Flow F / DESIGN.md AD7), NOT a worker-stuck decision dossier. Produce the deep body Brian will read on his phone to understand 'here is how this is going to fit together': what just landed at $DAEMON_FLOW_F_STAGE_LABEL on this bead, how it fits with the rest of the system, where the seams are, what he might want to push back on. ITEMS DISCIPLINE: emit either an empty items[] (pure FYI) or items all of kind \`fyi-objectable\` (each a small claim Brian can push back on inside the 24h window). DO NOT emit a \`pick-option\` item — the human is not being asked to pick. The tier is \`timed-fyi\`: silence auto-proceeds in 24h, an objection cancels follow-on work. Step 1 (gather context) is THE WHOLE JOB — walk the bd graph (\`bd show $bref\`, \`bd show <each dep>\`, the epic if there is one), read the design docs (\`DESIGN.md\`, \`UX-DESIGN.md\`, \`INTERFACE.md\`, \`README.md\`, any \`CLAUDE.md\`), and the recent commits (\`git log --oneline -n 30\`) before writing a single section. If the bead is genuinely too thin to anchor a real overview, refuse cleanly per the prompt's refuse channel."
  jq -cn \
    --arg did "$did" \
    --arg b   "$bref" \
    --arg w   "$ws" \
    --arg q   "How does the work that just closed on $bref fit into the larger picture, and what should you push back on?" \
    --arg cd  "$context_dump" \
    '{dossier_id:$did, bead_ref:$b, workspace_dir:$w, question:$q, context_dump:$cd}'
}

# daemon_flow_f__build_generation_input <dossier_id> <bead_ref> <builder_json>
#   Wrap the dossier-builder's {body, items[]} output into the §4.1 envelope
#   shape (dg_generate's `generation_input`) for a Flow F overview dossier:
#     kind   = "overview"            (C2 open discriminator; first-class
#                                     profile per DESIGN AD7 / §5.2.1)
#     trigger= "stage_gate"          (the §4.1 enum value covering Flow F's
#                                     stage-close trigger — INTERFACE.md line
#                                     242 lists stage_gate as a Flow B/F
#                                     trigger. P2 caught the original
#                                     `stage_${stage}_close` was outside the
#                                     frozen enum and the §4.1 validator
#                                     refused the write; the stage-granular
#                                     info lives on the bead's labels +
#                                     bead_ref, never the trigger field —
#                                     nothing downstream branches on the
#                                     trigger value.)
#     tier   = "timed-fyi"           (Flow F rides §0.B / D5 24h auto-proceed)
#     source = body fields           (so dg__author preserves the polished
#                                     four-tier body the builder authored)
#     items  = builder.items[]       (zero or all-fyi-objectable per AD7)
daemon_flow_f__build_generation_input() {
  local did="${1:-}" bref="${2:-}" out="${3:-}"
  local trigger="stage_gate"
  printf '%s' "$out" | jq -c \
    --arg did "$did" \
    --arg b   "$bref" \
    --arg t   "$trigger" '
      .body  as $body
    | (.items // []) as $items
    | { id: $did,
        kind: "overview",
        trigger: $t,
        bead_ref: $b,
        tier: "timed-fyi",
        timer_fire_at: null,
        source: {
          tldr:        ($body.tldr // ""),
          sections:    ($body.sections // []),
          diagrams:    ($body.diagrams // []),
          full_detail: ($body.full_detail // ""),
          # claude-tools-69u8: this body was ALREADY authored by the dossier-
          # builder agent spawned above (daemon_flow_f_dispatch_one). Stamp the
          # §xdo pre-author hint so dg__author treats its jq pass as shape-
          # coercion (NOT a degraded fallback): it badges authored_by="agent"
          # and SKIPS the misleading DOSSIER_FALLBACK:no_DG_AUTHOR_CMD incident.
          # Without this, every Flow F overview was logged as a degraded no-
          # author fallback even though the builder authored it (the loudest
          # real no_DG_AUTHOR_CMD producer in the audit log).
          authored_by:        "agent",
          authored_by_reason: "flow_f_overview_builder"
        },
        items: $items }
  ' 2>/dev/null
}

# _daemon_flow_f_engine_write <ws> <pref> <curl> <tk_item> <gi_json>
#   Subshell-isolated engine write. Sources the runner libs (matches the
#   engine-bridge.sh discipline + I3's intake-dispatch-poll fetch subshell)
#   and calls dg_generate to persist the dossier, no_emit/no_dispatch for
#   the §4.3 notification, and tf_arm to arm the 24h timed-fyi window. The
#   `DAEMON_FLOW_F_ENGINE_OVERRIDE` test hook short-circuits this so the
#   focused test can verify the dispatch wiring without sourcing the full
#   coordinator stack.
#
#   Returns 0 on success; nonzero on any failure (caller logs but does NOT
#   abort the rest of the dispatch loop).
_daemon_flow_f_engine_write() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4" gi="$5"
  if [[ -n "$DAEMON_FLOW_F_ENGINE_OVERRIDE" && -x "$DAEMON_FLOW_F_ENGINE_OVERRIDE" ]]; then
    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 1
    printf '%s' "$gi" > "$tmp" 2>/dev/null
    "$DAEMON_FLOW_F_ENGINE_OVERRIDE" "$ws" "$tmp"
    local rc=$?
    rm -f "$tmp" 2>/dev/null
    return "$rc"
  fi
  (
    set +e
    cd "$ws" 2>/dev/null || exit 1
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"
    export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # Source order mirrors engine-bridge.sh / run-beads-tasks.sh: stuck-
    # routing pulls dossier-gen → dossier → coordinator; notification owns
    # §4.3 emit/dispatch; co-http-transport overrides co_request when
    # COORDINATOR_URL is set; timed-fyi owns §2.2 tf_arm.
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/stuck-routing.sh"   2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/notification.sh"    2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/timed-fyi.sh"       2>/dev/null || exit 1
    command -v dg_generate >/dev/null 2>&1 || exit 1
    command -v tf_arm      >/dev/null 2>&1 || exit 1
    local bearer did nid
    bearer="${COORDINATOR_TOKEN:-bearer-daemon-flow-f}"
    did="$(dg_generate "$bearer" "$gi" 2>/dev/null)" || exit 2
    [[ -n "$did" ]] || exit 2
    # §4.3 emit + best-effort dispatch (already-emitted is a no-op).
    nid="$(no_emit "$bearer" "$did" 2>/dev/null)" || true
    [[ -n "$nid" ]] && no_dispatch "$bearer" "$nid" "flow-f-overview" >/dev/null 2>&1 || true
    # §2.2 arm — Flow F dossiers ride the default 24h timed-fyi window.
    tf_arm "$bearer" "$did" >/dev/null 2>&1 || exit 3
    printf '%s' "$did"
    exit 0
  )
}

# daemon_flow_f_dispatch_one <ws> <pref> <curl> <tk_item> <bead_ref>
#   Dispatch ONE Flow F overview build for <bead_ref>. ALWAYS returns 0 — a
#   per-bead failure must not abort the loop. Writes a per-bead marker
#   (outcome dispatched|refused|failed) so the bead is not reconsidered on
#   the next poll regardless of outcome (a flapping bead would otherwise
#   re-trigger every 60s).
daemon_flow_f_dispatch_one() {
  local ws="${1:-}" pref="${2:-}" curl="${3:-}" tk_item="${4:-}" bref="${5:-}"
  local did ctx_file builder_out rc parsed body items refuse
  [[ -n "$bref" && -n "$ws" && -d "$ws" ]] || return 0

  did="overview-$(daemon_flow_f__safe_key "$bref")"

  declare -F log >/dev/null 2>&1 && \
    log "Flow F dispatch: workspace=$ws bead_ref=$bref dossier_id=$did (stage=$DAEMON_FLOW_F_STAGE_LABEL close)"

  # Build the builder context JSON.
  ctx_file="$(mktemp 2>/dev/null)" || {
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: FAIL — mktemp failed for bead_ref=$bref (marker NOT written; retried next poll)"
    return 0
  }
  daemon_flow_f__build_builder_input "$did" "$bref" "$ws" > "$ctx_file" 2>/dev/null

  # Resolve which spawner to use. Override > disabled-canary > real.
  local spawner=() _override _disabled stub_out
  _override="$DAEMON_FLOW_F_BUILDER_OVERRIDE"
  _disabled="$DAEMON_FLOW_F_DISABLED"
  if [[ -n "$_override" ]]; then
    if [[ ! -x "$_override" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "Flow F dispatch: refuse — DAEMON_FLOW_F_BUILDER_OVERRIDE='$_override' not executable"
      rm -f "$ctx_file" 2>/dev/null
      return 0
    fi
    spawner=("$_override")
  elif [[ "$_disabled" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: DAEMON_FLOW_F_DISABLED=1 ⇒ would invoke $DAEMON_SPECIALIST_SH --kind=dossier-builder --workspace=$ws (bead_ref=$bref); synthesising a refusal so the marker is written and we don't retry"
    # The canary path treats the dispatch as "refused" so the marker lands
    # and we don't loop. The dispatch wiring (builder input shape) is still
    # exercised in tests via the OVERRIDE path; the disabled-canary is a
    # safe default for CI.
    daemon_flow_f_write_marker "$bref" "$ws" "canary-disabled" ""
    rm -f "$ctx_file" 2>/dev/null
    return 0
  else
    if [[ ! -x "$DAEMON_SPECIALIST_SH" ]]; then
      declare -F log >/dev/null 2>&1 && \
        log "Flow F dispatch: refuse — specialist.sh missing/non-executable at $DAEMON_SPECIALIST_SH (marker NOT written; retried next poll once installed)"
      rm -f "$ctx_file" 2>/dev/null
      return 0
    fi
    spawner=("$DAEMON_SPECIALIST_SH")
  fi

  builder_out="$("${spawner[@]}" \
                  --kind=dossier-builder \
                  --workspace="$ws" \
                  --context-file="$ctx_file" \
                  2>/dev/null)"
  rc=$?
  rm -f "$ctx_file" 2>/dev/null

  if [[ "$rc" -ne 0 ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: FAIL — builder exit=$rc workspace=$ws bead_ref=$bref (marker WRITTEN as failed — do not retry; inspect specialist log)"
    daemon_flow_f_write_marker "$bref" "$ws" "builder-failed" ""
    return 0
  fi

  # Parse the builder's stdout. It is EITHER a refusal `{refuse:true,...}`
  # OR a `{body, items[]}` shape. Anything else is a content failure.
  parsed="$(printf '%s' "$builder_out" | jq -c 'if type=="object" then . else null end' 2>/dev/null)"
  if [[ -z "$parsed" || "$parsed" == "null" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: FAIL — builder stdout not JSON object workspace=$ws bead_ref=$bref (marker WRITTEN as failed)"
    daemon_flow_f_write_marker "$bref" "$ws" "parse-failed" ""
    return 0
  fi
  refuse="$(printf '%s' "$parsed" | jq -r '.refuse // false' 2>/dev/null)"
  if [[ "$refuse" == "true" ]]; then
    local reason
    reason="$(printf '%s' "$parsed" | jq -r '.reason // ""' 2>/dev/null)"
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: REFUSED workspace=$ws bead_ref=$bref reason='${reason:0:120}' (marker WRITTEN as refused; honest refusal is a valid Flow F outcome)"
    daemon_flow_f_write_marker "$bref" "$ws" "builder-refused" ""
    return 0
  fi

  body="$(printf '%s' "$parsed"  | jq -c '.body // null' 2>/dev/null)"
  items="$(printf '%s' "$parsed" | jq -c '.items // null' 2>/dev/null)"
  if [[ "$body" == "null" || -z "$body" || "$items" == "null" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: FAIL — builder output missing body or items[] workspace=$ws bead_ref=$bref (marker WRITTEN as failed)"
    daemon_flow_f_write_marker "$bref" "$ws" "shape-failed" ""
    return 0
  fi

  # Assemble the generation input + write through the engine.
  local gi
  gi="$(daemon_flow_f__build_generation_input "$did" "$bref" "$parsed")"
  if [[ -z "$gi" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: FAIL — could not assemble generation input workspace=$ws bead_ref=$bref"
    daemon_flow_f_write_marker "$bref" "$ws" "assemble-failed" ""
    return 0
  fi

  local written_did
  written_did="$(_daemon_flow_f_engine_write "$ws" "$pref" "$curl" "$tk_item" "$gi" 2>/dev/null)"
  if [[ -z "$written_did" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F dispatch: FAIL — engine write returned no id workspace=$ws bead_ref=$bref (marker NOT written; retried next poll)"
    return 0
  fi
  daemon_flow_f_write_marker "$bref" "$ws" "dispatched" "$written_did"
  declare -F log >/dev/null 2>&1 && \
    log "Flow F dispatch: OK — workspace=$ws bead_ref=$bref dossier_id=$written_did tier=timed-fyi (24h auto-proceed; objection cancels follow-on work, silence proceeds)"
  return 0
}

# daemon_flow_f__poll_workspace <idx>
#   Per-workspace poll: list closed stage:design beads, dispatch the new
#   ones. ALWAYS returns 0. Echoes the count of dispatched beads on stdout
#   for the driver to aggregate into a single log line.
daemon_flow_f__poll_workspace() {
  local i="${1:-0}" ws pref curl tk_item bref count=0
  ws="${REGISTRY_DIRS[$i]:-}"
  pref="${REGISTRY_PROJECT_REFS[$i]:-}"
  curl="${REGISTRY_COORDINATOR_URLS[$i]:-}"
  tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[$i]:-}"
  [[ -n "$ws" && -d "$ws" ]] || { printf '0'; return 0; }
  while IFS= read -r bref; do
    [[ -n "$bref" ]] || continue
    daemon_flow_f_already_fired "$bref" && continue
    daemon_flow_f_dispatch_one "$ws" "$pref" "$curl" "$tk_item" "$bref"
    count=$((count + 1))
  done < <(daemon_flow_f__list_closed_at_stage "$ws")
  printf '%s' "$count"
}

# daemon_flow_f_poll_once
#   Single iteration: seed-on-first-run, then walk every registered
#   workspace. ALWAYS returns 0. Called from daemon.sh's main loop on the
#   FLOW_F_POLL_INTERVAL cadence.
daemon_flow_f_poll_once() {
  daemon_flow_f_seed_if_needed
  local n i total=0 c
  n="${#REGISTRY_DIRS[@]}"
  [[ "$n" -gt 0 ]] || return 0
  i=0
  while [[ "$i" -lt "$n" ]]; do
    c="$(daemon_flow_f__poll_workspace "$i" 2>/dev/null)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    total=$((total + c))
    i=$((i + 1))
  done
  if [[ "$total" -gt 0 ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "Flow F poll (§Flow F / P1): dispatched $total overview-dossier build(s) across $n workspace(s) — 24h timed-fyi tier; silence auto-proceeds, objection cancels follow-on"
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# H5 (claude-tools-uxvh5) — the blueprint-update trigger path
# (DESIGN H, design/blueprint.md §7). This is the NEW path §7.3 says H5 "wires
# into that same poll" — it SHARES the Flow-F stage-completion signal (a
# structural bd close) rather than adding a second watcher, which is exactly
# why the Blueprint-changed ping UNIFIES with the Flow F overview (§6.5/§7.4):
# both are the SAME kind=overview tier=timed-fyi notification.
#
# WHAT H5 OWNS here (§7.2 split): the structure-change TRIGGER PREDICATE
# (stage-coarse), the hat I/O contract, and the change→ONE-timed-fyi SEMANTICS
# (the §7.4 unification). The PARALLEL/detached/capacity-gated SPAWN + per-bead
# dedup scheduling is I5's (claude-tools-uxvi5, deferred) — it wraps the
# SYNCHRONOUS unit `daemon_blueprint_update_dispatch_one` below in the
# m6-dispatch nohup/disown + aux-dispatch-gate machinery. Until I5, the hat is
# runnable synchronously (the design's "runnable synchronously pre-I5"), and
# `daemon_blueprint_update_dispatch_one` is canary-disabled by default
# (DAEMON_BLUEPRINT_UPDATE_DISABLED=1) so nothing fires in prod until I5 turns
# it on. None of these functions are called from daemon.sh's main loop yet —
# defining them is "adds the path"; I5 makes it live + parallel.
# ════════════════════════════════════════════════════════════════════════════

# The structural stage set (§6.2/§7.3): a close carrying any of these labels is
# a CANDIDATE for a Blueprint redraw. Deliberately GENEROUS — the hat's own
# idempotent regen (Step 3.4) is the real gate that suppresses a cosmetic close.
# Space-separated, env-overridable (a project may extend it without forking).
DAEMON_BLUEPRINT_STRUCTURAL_STAGES="${DAEMON_BLUEPRINT_STRUCTURAL_STAGES:-stage:design stage:impl stage:docs}"

# Canary: 1 (default) ⇒ dispatch_one logs "would dispatch" and does NOT spawn a
# real hat (I5 flips this to 0 when it wires the parallel poll). A test/override
# spawner (DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE) takes precedence — the override
# IS the dispatch path (mirrors DAEMON_FLOW_F_BUILDER_OVERRIDE > _DISABLED).
DAEMON_BLUEPRINT_UPDATE_DISABLED="${DAEMON_BLUEPRINT_UPDATE_DISABLED:-1}"

# Test overrides (parallel to the Flow-F override hooks):
#   _HAT_OVERRIDE     — replaces specialist.sh for the --kind=blueprint-update spawn
#   _GET_OVERRIDE     — replaces the current-blueprint fetch; echoes the current
#                       blueprint JSON on stdout (or empty / "null" for none)
#   _BP_WRITE_OVERRIDE— replaces the blueprint-put transport; called as
#                       "<override> <ws> <payload.json>" (payload = the hat's
#                       {derived,narrative,conflicts_append}); rc 0 ⇒ written
# The timed-fyi EMIT reuses _daemon_flow_f_engine_write (the literal §7.4
# unification — same machinery), so DAEMON_FLOW_F_ENGINE_OVERRIDE governs it too.
DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE="${DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE:-}"
DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE="${DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE:-}"
DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE="${DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE:-}"

# daemon_blueprint_update_should_trigger <stage_label>
#   THE structure-change coarse predicate (§7.3). True (0) iff <stage_label> is
#   in the structural set; false (1) otherwise — a trivial close (stage:idea,
#   stage:ux, stage:tests, no stage at all) does NOT trigger a redraw. Accepts
#   either the bare value ("impl") or the full label ("stage:impl"). This is the
#   ONE-label check the bead's testing note says to "drive directly."
daemon_blueprint_update_should_trigger() {
  local stage="${1:-}"
  [[ -n "$stage" ]] || return 1
  # normalise: accept "impl" as "stage:impl"
  case "$stage" in stage:*) : ;; *) stage="stage:$stage" ;; esac
  local s
  for s in $DAEMON_BLUEPRINT_STRUCTURAL_STAGES; do
    [[ "$stage" == "$s" ]] && return 0
  done
  return 1
}

# daemon_blueprint_update__list_structural_closes <workspace>
#   List bd IDs at <workspace> that are CLOSED and carry ANY structural stage
#   label, one per line, de-duplicated (a bead with two stage labels is illegal
#   per the one-stage spine, but we uniq defensively). Subshell-isolated so a
#   workspace's local .beads env never leaks back. Mirrors
#   daemon_flow_f__list_closed_at_stage, unioned over the structural set.
daemon_blueprint_update__list_structural_closes() {
  local ws="${1:-}"
  [[ -n "$ws" && -d "$ws" ]] || return 0
  (
    cd "$ws" 2>/dev/null || exit 0
    local s
    for s in $DAEMON_BLUEPRINT_STRUCTURAL_STAGES; do
      bd list --label "$s" --status closed --all --flat --no-pager --json 2>/dev/null \
        | jq -r 'if type=="array" then .[] | .id else empty end' 2>/dev/null
    done
  ) | awk 'NF && !seen[$0]++'
}

# daemon_blueprint_update__build_hat_input <project_ref> <bead_ref> <trigger_stage> <current_blueprint_json>
#   Build the blueprint-update hat's stdin JSON (the §7.1 input contract). The
#   current Blueprint is passed IN (so the hat diffs in-memory and needs no
#   engine read of its own — keeping the bearer out of agent context). A
#   missing/empty current_blueprint becomes JSON null (the first-creation case).
daemon_blueprint_update__build_hat_input() {
  local pref="${1:-}" bref="${2:-}" stage="${3:-}" cur="${4:-}"
  [[ -n "$cur" ]] || cur="null"
  # Guard: if cur is not valid JSON, fall back to null rather than emit a broken
  # context object (the hat treats null as "first creation").
  printf '%s' "$cur" | jq -e . >/dev/null 2>&1 || cur="null"
  jq -cn \
    --arg pr "$pref" \
    --arg b  "$bref" \
    --arg st "$stage" \
    --argjson cb "$cur" \
    '{project_ref:$pr, bead_ref:$b, trigger_stage:$st, current_blueprint:$cb}'
}

# daemon_blueprint_update__shape_timed_fyi <dossier_id> <bead_ref> <hat_stdout_json>
#   THE §7.4 unification, made concrete: shape the hat's material-change
#   `overview` (+ focus_id + summary) into the SAME §4.1 generation_input the
#   Flow-F overview uses — kind=overview, tier=timed-fyi, trigger=stage_gate —
#   so the Blueprint-changed ping IS the Flow F overview dossier, NOT a second
#   notification mechanism (§6.5). `focus_id` is threaded into the source so the
#   FYI deep-links `?focus=<id>` into the Blueprint (§8.4). items[] is empty (a
#   pure FYI; silence auto-proceeds in 24h). authored_by=agent +
#   authored_by_reason=blueprint_update_overview so dg__author treats it as the
#   already-authored body (the claude-tools-69u8 no-fallback-badge fix), with the
#   reason naming THIS producer in the audit log. Echoes "" if the hat output is
#   not a material change (caller must not emit an FYI then).
daemon_blueprint_update__shape_timed_fyi() {
  local did="${1:-}" bref="${2:-}" out="${3:-}"
  printf '%s' "$out" | jq -c \
    --arg did "$did" \
    --arg b   "$bref" '
      if (type=="object" and (.material_change==true)) then
        (.overview // {}) as $ov
      | { id: $did,
          kind: "overview",
          trigger: "stage_gate",
          bead_ref: $b,
          tier: "timed-fyi",
          timer_fire_at: null,
          source: {
            tldr:        ($ov.tldr // (.summary // "")),
            sections:    ($ov.sections // []),
            diagrams:    ($ov.diagrams // []),
            full_detail: ($ov.full_detail // ""),
            focus_id:    (.focus_id // ""),
            authored_by:        "agent",
            authored_by_reason: "blueprint_update_overview"
          },
          items: [] }
      else empty end
  ' 2>/dev/null
}

# _daemon_blueprint_update_write_blueprint <ws> <pref> <curl> <tk_item> <payload_json>
#   Transport the hat's regenerated Blueprint into the engine via blueprint-put
#   (§2.2 sectioned read-merge-write): one put for `derived`, one for `narrative`,
#   and a `conflicts-append` per entry — all stamped updated_by="agent:blueprint-
#   update" (so the never-clobber owner split holds, §2.3). <payload_json> is the
#   hat's {derived, narrative, conflicts_append}. Subshell-isolated; sources the
#   coordinator + HTTP transport (the same per-workspace env wiring
#   _daemon_flow_f_engine_write uses). The _BP_WRITE_OVERRIDE hook short-circuits
#   this for tests. Returns 0 iff every put landed.
_daemon_blueprint_update_write_blueprint() {
  local ws="$1" pref="$2" curl="$3" tk_item="$4" payload="$5"
  if [[ -n "$DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE" && -x "$DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE" ]]; then
    local tmp; tmp="$(mktemp 2>/dev/null)" || return 1
    printf '%s' "$payload" > "$tmp" 2>/dev/null
    "$DAEMON_BLUEPRINT_UPDATE_BP_WRITE_OVERRIDE" "$ws" "$tmp"
    local rc=$?; rm -f "$tmp" 2>/dev/null; return "$rc"
  fi
  (
    set +e
    cd "$ws" 2>/dev/null || exit 1
    export PROJECT_REF="$pref"
    : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"; export CO_STORE
    if [[ -n "$curl" ]]; then export COORDINATOR_URL="$curl"; fi
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk; _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/coordinator.sh"        2>/dev/null || exit 1
    # shellcheck source=/dev/null
    . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh"  2>/dev/null || true
    command -v co_request >/dev/null 2>&1 || exit 1
    local bearer; bearer="${COORDINATOR_TOKEN:-bearer-daemon-blueprint-update}"
    local derived narrative env
    derived="$(printf '%s' "$payload"   | jq -c '.derived   // empty' 2>/dev/null)"
    narrative="$(printf '%s' "$payload" | jq -c '.narrative // empty' 2>/dev/null)"
    # derived is mandatory for a material write; narrative + conflicts optional.
    [[ -n "$derived" ]] || exit 2
    env="$(jq -cn --arg pr "$pref" --argjson body "$derived" \
            '{project_ref:$pr, section:"derived", body:$body, updated_by:"agent:blueprint-update"}')" || exit 2
    co_request "$bearer" blueprint-put "$env" >/dev/null 2>&1 || exit 3
    if [[ -n "$narrative" ]]; then
      env="$(jq -cn --arg pr "$pref" --argjson body "$narrative" \
              '{project_ref:$pr, section:"narrative", body:$body, updated_by:"agent:blueprint-update"}')" || exit 2
      co_request "$bearer" blueprint-put "$env" >/dev/null 2>&1 || exit 3
    fi
    # conflicts-append: one put per entry (the §2.3 push-don't-replace mode).
    local n j entry
    n="$(printf '%s' "$payload" | jq -r '(.conflicts_append // []) | length' 2>/dev/null)" || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    j=0
    while [[ "$j" -lt "$n" ]]; do
      entry="$(printf '%s' "$payload" | jq -c ".conflicts_append[$j]" 2>/dev/null)"
      if [[ -n "$entry" && "$entry" != "null" ]]; then
        env="$(jq -cn --arg pr "$pref" --argjson body "$entry" \
                '{project_ref:$pr, section:"conflicts-append", body:$body, updated_by:"agent:blueprint-update"}')" || exit 2
        co_request "$bearer" blueprint-put "$env" >/dev/null 2>&1 || exit 3
      fi
      j=$((j + 1))
    done
    exit 0
  )
}

# daemon_blueprint_update_dispatch_one <ws> <pref> <curl> <tk_item> <bead_ref> <trigger_stage>
#   The SYNCHRONOUS H5 orchestration unit (I5 wraps it in the parallel/capacity-
#   gated scheduler). Assumes the caller already passed the §7.3 coarse predicate
#   (daemon_blueprint_update_should_trigger). It:
#     1. fetches the current Blueprint (blueprint-get; override-able),
#     2. spawns the read-only blueprint-update hat with {project_ref, bead_ref,
#        trigger_stage, current_blueprint},
#     3. parses the hat's single stdout JSON,
#     4. material_change=false / refuse ⇒ writes NOTHING, emits NO FYI (the
#        idempotent gate — a cosmetic close no-ops),
#     5. material_change=true ⇒ blueprint-put(derived/narrative/conflicts) THEN
#        emits exactly ONE timed-fyi overview (the §7.4 unification, via the
#        shared _daemon_flow_f_engine_write).
#   Reports a one-word OUTCOME via the GLOBAL `DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME`
#   (no-change|refused|dispatched|disabled|spawn-failed|parse-failed|
#   write-failed|fyi-failed) for the caller / test — NOT stdout, because the
#   daemon `log` helper writes to stdout and would otherwise pollute a captured
#   outcome. ALWAYS returns 0 (a per-bead failure must never abort a loop).
DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME=""
daemon_blueprint_update_dispatch_one() {
  local ws="${1:-}" pref="${2:-}" curl="${3:-}" tk_item="${4:-}" bref="${5:-}" stage="${6:-}"
  DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME=""
  [[ -n "$bref" && -n "$ws" && -d "$ws" ]] || { DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='spawn-failed'; return 0; }

  local did; did="overview-$(daemon_flow_f__safe_key "$bref")"

  declare -F log >/dev/null 2>&1 && \
    log "blueprint-update dispatch: workspace=$ws bead_ref=$bref trigger=$stage dossier_id=$did"

  # ── resolve the spawner: override > canary-disabled > real specialist.sh ────
  local spawner=()
  if [[ -n "$DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE" ]]; then
    [[ -x "$DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE" ]] || { DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='spawn-failed'; return 0; }
    spawner=("$DAEMON_BLUEPRINT_UPDATE_HAT_OVERRIDE")
  elif [[ "$DAEMON_BLUEPRINT_UPDATE_DISABLED" == "1" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "blueprint-update dispatch: DAEMON_BLUEPRINT_UPDATE_DISABLED=1 ⇒ would invoke $DAEMON_SPECIALIST_SH --kind=blueprint-update --workspace=$ws (bead_ref=$bref); I5 turns this live + parallel"
    DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='disabled'; return 0
  else
    [[ -x "$DAEMON_SPECIALIST_SH" ]] || { DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='spawn-failed'; return 0; }
    spawner=("$DAEMON_SPECIALIST_SH")
  fi

  # ── 1. fetch the current Blueprint ─────────────────────────────────────────
  local cur=""
  if [[ -n "$DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE" && -x "$DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE" ]]; then
    cur="$("$DAEMON_BLUEPRINT_UPDATE_GET_OVERRIDE" "$ws" "$pref" 2>/dev/null)"
  else
    cur="$(
      set +e
      cd "$ws" 2>/dev/null || exit 0
      export PROJECT_REF="$pref"
      : "${CO_STORE:=$ws/.beads/runner-logs/.co-store}"; export CO_STORE
      [[ -n "$curl" ]] && export COORDINATOR_URL="$curl"
      if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
        _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
        [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
      fi
      # shellcheck source=/dev/null
      . "$DAEMON_REPO_LIB_DIR/coordinator.sh"       2>/dev/null || exit 0
      # shellcheck source=/dev/null
      . "$DAEMON_REPO_LIB_DIR/co-http-transport.sh" 2>/dev/null || true
      command -v co_request >/dev/null 2>&1 || exit 0
      co_request "${COORDINATOR_TOKEN:-bearer-daemon-blueprint-update}" blueprint-get "$pref" 2>/dev/null
    )"
  fi

  # ── 2. spawn the hat ───────────────────────────────────────────────────────
  local ctx_file hat_out rc
  ctx_file="$(mktemp 2>/dev/null)" || { DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='spawn-failed'; return 0; }
  daemon_blueprint_update__build_hat_input "$pref" "$bref" "$stage" "$cur" > "$ctx_file" 2>/dev/null
  hat_out="$("${spawner[@]}" --kind=blueprint-update --workspace="$ws" --context-file="$ctx_file" 2>/dev/null)"
  rc=$?
  rm -f "$ctx_file" 2>/dev/null
  if [[ "$rc" -ne 0 ]]; then
    declare -F log >/dev/null 2>&1 && log "blueprint-update dispatch: hat exit=$rc bead_ref=$bref (no write, no FYI)"
    DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='spawn-failed'; return 0
  fi

  # ── 3. parse the single stdout JSON ────────────────────────────────────────
  local parsed material refuse
  parsed="$(printf '%s' "$hat_out" | jq -c 'if type=="object" then . else empty end' 2>/dev/null)"
  if [[ -z "$parsed" ]]; then DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='parse-failed'; return 0; fi
  refuse="$(printf '%s' "$parsed" | jq -r '.refuse // false' 2>/dev/null)"
  material="$(printf '%s' "$parsed" | jq -r '.material_change // false' 2>/dev/null)"

  # ── 4. idempotent gate: no material change (or honest refuse) ⇒ no-op ───────
  if [[ "$material" != "true" || "$refuse" == "true" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "blueprint-update dispatch: no material change for bead_ref=$bref (idempotent no-op — no write, no FYI)"
    [[ "$refuse" == "true" ]] && { DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='refused'; return 0; }
    DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='no-change'; return 0
  fi

  # ── 5a. write the regenerated Blueprint (derived/narrative/conflicts) ───────
  if ! _daemon_blueprint_update_write_blueprint "$ws" "$pref" "$curl" "$tk_item" "$parsed"; then
    declare -F log >/dev/null 2>&1 && \
      log "blueprint-update dispatch: blueprint-put FAILED bead_ref=$bref (NO FYI emitted — the map write is the precondition for the ping)"
    DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='write-failed'; return 0
  fi

  # ── 5b. emit exactly ONE timed-fyi overview (the §7.4 unification) ──────────
  local gi written
  gi="$(daemon_blueprint_update__shape_timed_fyi "$did" "$bref" "$parsed")"
  if [[ -z "$gi" ]]; then DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='fyi-failed'; return 0; fi
  written="$(_daemon_flow_f_engine_write "$ws" "$pref" "$curl" "$tk_item" "$gi" 2>/dev/null)"
  if [[ -z "$written" ]]; then
    declare -F log >/dev/null 2>&1 && \
      log "blueprint-update dispatch: timed-fyi emit returned no id bead_ref=$bref (map written; FYI retried by I5 next poll)"
    DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='fyi-failed'; return 0
  fi
  declare -F log >/dev/null 2>&1 && \
    log "blueprint-update dispatch: OK — bead_ref=$bref dossier_id=$written tier=timed-fyi (Blueprint redrawn; ONE overview ping = the Flow F overview, §6.5)"
  DAEMON_BLUEPRINT_UPDATE_LAST_OUTCOME='dispatched'; return 0
}
