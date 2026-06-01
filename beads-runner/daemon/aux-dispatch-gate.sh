# shellcheck shell=bash
# beads-runner/daemon/aux-dispatch-gate.sh — I5-cap aux-pool capacity gate
# (claude-tools-pof7; epic claude-tools-mhcp; gap-audit wzejgmopj).
#
# WHAT THIS IS
#   The budget guard for the parallel auxiliary pool (I5 / claude-tools-uxvi5).
#   I5 spawns read-only aux agents (blueprint-update, enricher, …) DETACHED,
#   in parallel with the serial writer, using the M6 `nohup … & ; disown`
#   pattern (design/activity.md §5). Those spawns must NOT blow the machine-wide
#   5h/7d usage budget. Before each aux dispatch the daemon consults the SAME
#   capacity signal it already produces (usage-poll.sh → capacity.json) and
#   SUPPRESSES the spawn when the aux cost-class is over budget.
#
# CHEAPER COST-CLASS THAN THE WRITER (design/activity.md §5: "gate aux spawns on
# a cheaper cost-class than the writer lane")
#   The writer lane gates on `standard` (run-beads-tasks.sh daemon_ask_capacity).
#   Aux dispatch gates on `low_priority` — the cheaper class. usage-poll.sh drops
#   `low_priority` from allowed_cost_classes (the spare-cycles soft ramp) BEFORE
#   it drops `standard` (the hard 5h/7d ceiling), so the aux pool is the FIRST
#   thing suppressed as budget tightens and the LAST to resume — exactly the
#   "cheaper" semantics the gap audit asked for. Proof in test-i5cap PART C:
#   on a fresh allowed=["standard"] cache, the writer (standard) is allowed but
#   the aux (low_priority) is suppressed.
#
# FAIL-OPEN ON AN UNAVAILABLE SIGNAL (BC-34 §6.2 posture)
#   Missing / unparseable / stale (> 2 × USAGE_CACHE_SECONDS) capacity.json ⇒
#   ALLOW the dispatch, the same fail-OPEN posture every other capacity consumer
#   takes (la_capacity_check, daemon_ask_capacity). The daemon is the PRODUCER of
#   capacity.json: if it is alive enough to dispatch aux, its usage-poll keeps the
#   cache fresh, so an unavailable signal is transient + self-healing, and the aux
#   gate is never stricter-on-uncertainty than the writer it shadows. "Suppress
#   when over budget" (bead) = suppress on a FRESH over-budget signal, never on an
#   absent one.
#
# CONTRACT A (UX-V2-ARCHITECTURE.md §A.2): this gate is a PURE READ of a transient
#   signal. It writes NO §4 record and NO transient table — it only consults the
#   capacity cache the daemon already publishes. It adds no op and no schema.
#
# NOT a runner v1/v2 fork (bead): a daemon-side helper, analogous to
#   m6-dispatch.sh. Sourced by daemon.sh; consumed by I5 (uxvi5) before each aux
#   spawn. It is a strict no-op until a caller invokes it.

# ─── paths + tunables ──────────────────────────────────────────────────────
# Resolve the cache dir the same way the producer (usage-poll.sh) and the live
# daemon do: prefer daemon.sh's resolved DAEMON_CACHE_DIR, then the
# BEADS_DAEMON_CACHE_DIR override the producer keys off, then the default. This
# keeps producer and consumer pointed at the same capacity.json in every mode
# (live daemon, sourced-in-isolation test).
AUX_GATE_CACHE_DIR="${DAEMON_CACHE_DIR:-${BEADS_DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}}"
AUX_GATE_CACHE_FILE="$AUX_GATE_CACHE_DIR/capacity.json"

# Same staleness contract as la__capacity_via_daemon (local-agent.sh): accept up
# to 2× the daemon's own USAGE_CACHE_SECONDS of drift, then treat the cache as
# dead and fail-OPEN.
AUX_GATE_TTL_SECONDS="${USAGE_CACHE_SECONDS:-300}"

# The aux pool's cost-class — deliberately the cheaper-than-writer class. Override
# only for a deliberate experiment; the design pins this to `low_priority`.
AUX_GATE_COST_CLASS="${AUX_GATE_COST_CLASS:-low_priority}"

# AUX_GATE_REASON — set by daemon_aux_capacity_ok on EVERY call (the WHY, for the
# daemon log line). One of the §6.3 vocabulary daemon_ask_capacity /
# la__capacity_deny_reason already use, plus the two fail-OPEN tokens:
#   ok | 5h_hard_ceiling | 7d_hard_ceiling | spare_cycles_today_exhausted |
#   cost_class_not_allowed | fail_open_unavailable | fail_open_stale
AUX_GATE_REASON=ok

# ─── helpers ─────────────────────────────────────────────────────────────────

# _aux_gate_log <msg> — forward to the daemon log() if available; else stderr so
# the function works when sourced in isolation (tests).
_aux_gate_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s [aux-gate] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >&2
  fi
}

# _aux_gate_fresh_json — echo the capacity.json body iff it exists, parses, and
# is younger than 2 × AUX_GATE_TTL_SECONDS. Returns:
#   0 + body   — usable, fresh, parseable
#   1          — missing or unparseable
#   2          — stale (older than the drift window)
# Mirrors la__capacity_via_daemon's staleness contract bit-for-bit so the daemon
# and the workspace age the cache identically.
_aux_gate_fresh_json() {
  local f="$AUX_GATE_CACHE_FILE" mtime now age limit json
  [[ -f "$f" ]] || return 1
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  now=$(date +%s 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  limit=$(( AUX_GATE_TTL_SECONDS * 2 ))
  [[ "$age" -lt "$limit" ]] || return 2
  json=$(cat "$f" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$json"
  return 0
}

# ─── public API ──────────────────────────────────────────────────────────────

# daemon_aux_capacity_ok [cost_class]
#   The aux-dispatch budget predicate. cost_class defaults to AUX_GATE_COST_CLASS
#   (low_priority — the cheaper-than-writer class).
#     0  → DISPATCH the aux (cost_class is allowed, OR the signal is unavailable
#          ⇒ fail-OPEN)
#     1  → SUPPRESS the aux (a FRESH signal says cost_class is over budget)
#   Sets AUX_GATE_REASON in all cases. The daemon's allowed_cost_classes IS the
#   verdict — this only reads membership; the §6.3 reason is derived purely for
#   the log line, from the same numbers the daemon decided on (identical decision
#   tree to la__capacity_deny_reason / daemon_ask_capacity — one vocabulary, zfxe).
daemon_aux_capacity_ok() {
  local cost_class="${1:-$AUX_GATE_COST_CLASS}" json rc allowed
  AUX_GATE_REASON=ok

  json=$(_aux_gate_fresh_json); rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 2 ]]; then AUX_GATE_REASON=fail_open_stale; else AUX_GATE_REASON=fail_open_unavailable; fi
    return 0
  fi

  allowed=$(printf '%s' "$json" | jq -r '.allowed_cost_classes[]?' 2>/dev/null)
  if printf '%s\n' "$allowed" | grep -qx "$cost_class"; then
    AUX_GATE_REASON=ok
    return 0
  fi

  # Denied. Derive the specific §6.3 reason for the log line.
  local threshold="${USAGE_THRESHOLD:-70}" pct_5h pct_7d ramp five_i seven_i ramp_i
  pct_5h=$(printf '%s' "$json" | jq -r '.pct_5h // 0' 2>/dev/null) || pct_5h=0
  pct_7d=$(printf '%s' "$json" | jq -r '.pct_7d // 0' 2>/dev/null) || pct_7d=0
  ramp=$(printf '%s'  "$json" | jq -r '.spare_ramp_today // 100' 2>/dev/null) || ramp=100
  five_i=${pct_5h%.*};  five_i=${five_i:-0}
  seven_i=${pct_7d%.*}; seven_i=${seven_i:-0}
  ramp_i=${ramp%.*};    ramp_i=${ramp_i:-100}
  if   [[ "$five_i"  -ge "$threshold" ]]; then AUX_GATE_REASON=5h_hard_ceiling
  elif [[ "$seven_i" -ge "$threshold" ]]; then AUX_GATE_REASON=7d_hard_ceiling
  elif [[ "$cost_class" == "low_priority" ]] && [[ "$seven_i" -ge "$ramp_i" ]]; then
    AUX_GATE_REASON=spare_cycles_today_exhausted
  else
    AUX_GATE_REASON=cost_class_not_allowed
  fi
  return 1
}

# daemon_aux_dispatch_guard <kind> <command> [args…]
#   The ergonomic wrapper a SYNCHRONOUS aux dispatch (intake/flow-f-style) can
#   adopt verbatim: run the gate for the aux cost-class; on OK, exec the dispatch
#   command; on SUPPRESS, log the reason and return WITHOUT spawning (suppression
#   is the intended budget-protect outcome, not an error — the next daemon cadence
#   re-evaluates). A DETACHED caller (the I5 `nohup … & ; disown` block) branches
#   on daemon_aux_capacity_ok directly instead. ALWAYS returns 0 — a gate decision
#   must never abort the daemon's main loop (the every-poll-returns-0 invariant).
daemon_aux_dispatch_guard() {
  local kind="${1:-aux}"
  shift || true
  if [[ $# -eq 0 ]]; then
    _aux_gate_log "aux-gate: $kind dispatch guard called with no command — nothing to run"
    return 0
  fi
  if daemon_aux_capacity_ok "$AUX_GATE_COST_CLASS"; then
    "$@"
    return 0
  fi
  _aux_gate_log "aux-gate: SUPPRESSED $kind dispatch — $AUX_GATE_COST_CLASS over budget (reason=$AUX_GATE_REASON)"
  return 0
}
