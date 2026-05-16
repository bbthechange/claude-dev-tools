#!/bin/bash
# beads-runner/runner.sh — the runner as an EXPLICIT STATE MACHINE
# (T2.1 skeleton, claude-tools-1p0; epic claude-tools-glk).
#
# WHY THIS FILE EXISTS
#   v1 `run-beads-tasks.sh` is a straight-line `while true` loop with state
#   scattered across flag variables (LAST_FAILED_ID, FAIL_COUNT,
#   CONSECUTIVE_FAILURES, SIGNAL_FILE, …) checked ad hoc. T2 reimplements the
#   runner as an explicit state machine with ONE reconcile point between tasks
#   (DESIGN §1/§7). This file is the SKELETON: the enumerated states +
#   transitions, the six-job call surface (INTERFACE.md v1 §3) wired against
#   in-process NO-OP stubs, BC-01 (fresh process/context per task) and the
#   BC-42 typed-error POSTURE every sibling inherits. It is deliberately
#   incomplete: classification/retry/breaker (T2.2), idle watchdog (T2.3),
#   process-tree teardown/interrupt cleanup/artifact basenames (T2.4) and the
#   real worker prompt + AD3.5 guardrail + STUCK primary/backstop (T2.5) are
#   each a marked SEAM here, owned by a sibling, and MUST NOT be implemented in
#   this file (non-overlapping ownership — epic ANTI-DRIFT).
#
# OWNS — INTERFACE.md v1 (FROZEN):
#   §1.2  exit-0-on-drain ≠ stop-the-project (the runner PROCESS preserves the
#         BC-05/BC-21 exit contract verbatim; relaunch is T3's, not here)
#   §2.5  connection/cadence: between-tasks new-work poll + during-task
#         desired-state poll every CONTROL_POLL_INTERVAL; a stop request is
#         OBSERVED ≤ CONTROL_POLL_INTERVAL; "stop after current task" — no
#         mid-task kill
#   §3    the runner as the CALLER of the six jobs (claim-lease, ask-capacity,
#         heartbeat-actual-state(+liveness), reconcile-desired-state,
#         publish-work-snapshot, report-terminal-reason) — wired as calls;
#         the callee bodies are the lib/*-stub.sh no-ops
#   BC-01 fresh `claude -p` process + fresh context per task; no
#         --continue/--resume; a retried task starts from an empty window
#   BC-42 fail-open POSTURE re-implemented as EXPLICIT TYPED error handling —
#         a bd/network/IO hiccup degrades gracefully, never crashes the loop,
#         and is NEVER blanket `|| true` / `2>/dev/null` swallowing
#
# ANTI-DRIFT: binds to INTERFACE.md v1 §1.2/§2.5/§3 + the §2–§6 stub
# signatures. An interface gap is a §11 BLOCKING escalation (reopen
# claude-tools-65z, bump+re-freeze), NEVER a local divergence.

# ── BC-42 POSTURE, declared up front ─────────────────────────────────────────
# v1 ran `set -euo pipefail` and then defeated `-e` with pervasive `|| true` /
# `2>/dev/null` on nearly every bd/IO call (BC-42 SCAFFOLDING). That is blanket
# suppression: a real failure is indistinguishable from "no result". The
# rewrite posture is EXPLICIT TYPED handling: NO `set -e`; every fallible
# external call goes through `safe_capture`, which classifies the failure into
# a typed degradation KIND, emits one visible `degrade:` line, and yields a
# caller-chosen fallback the caller then branches on EXPLICITLY. The loop never
# crashes on transient infra failure AND a degradation is never silently
# swallowed. Every sibling (T2.2–T2.5) inherits this posture.
set -uo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ── §0.5 frozen constants (env-overridable; literal default == §0.5 table) ────
CONTROL_POLL_INTERVAL="${CONTROL_POLL_INTERVAL:-60}"   # §0.5 (60 s) desired-state poll DURING a task; stop honored ≤ this
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"         # §0.5 (60 s) actual-state+liveness heartbeat; lease renew
RECLAIM_POLL_INTERVAL="${RECLAIM_POLL_INTERVAL:-60}"   # §0.5 (60 s) re-poll cadence after a clean drain (relaunch itself is T3)
RUNNER_TICK="${RUNNER_TICK:-1}"                        # during-task poll granularity (s); test-tunable

# ── BC-22 watchdog constants (T2.3, claude-tools-9e7) ────────────────────────
# IDLE_TIMEOUT is the ONLY env-overridable knob (BC-22). The 15s poll cadence
# and the 180s soft-warn tier are SCAR-tuned and HARDCODED (BC-22 classification:
# "the 180s-vs-IDLE_TIMEOUT two-tier and the 15s poll cadence are tuned values").
# Default is back to the v1 600s: the 2026-05-16 incident's `.beads/runner.sh`
# IDLE_TIMEOUT=1200 stopgap is now REDUNDANT (not removed here — not T2.3's
# surface) because the liveness SIGNAL is corrected below from "parent-stream
# silence" to "agent+child-process-tree progress" (the real fix the stopgap
# comment itself points at). Declared BEFORE the .beads/runner.sh source so a
# project stopgap can still override; harmless if it does.
IDLE_TIMEOUT="${IDLE_TIMEOUT:-600}"                    # §0.5 / BC-22 — idle-progress kill threshold (env-overridable)
WATCHDOG_POLL=15                                       # BC-22 SCAR — HARDCODED poll cadence (not env-tunable)
WATCHDOG_SOFT_WARN=180                                 # BC-22 SCAR — HARDCODED soft-warn tier (not env-tunable)

# ── Minimal runtime config (skeleton). The full BC-37 config seam — sourced
#    allowlist, --yolo, runner_setup/runner_cleanup hooks — is NOT T2.1's owned
#    surface; the skeleton keeps a minimal default + an optional project source
#    so it is runnable end-to-end. Richer policy lands with T2 integration. ────
DEFAULT_MODEL="${DEFAULT_MODEL:-opus[1m]}"
PERMISSION_FLAGS=(--permission-mode acceptEdits)
EXTRA_CLAUDE_FLAGS=(--no-chrome)
PROJECT_REF="${PROJECT_REF:-$(basename "$(pwd)")}"     # §4.2 project_ref (controllable unit); Coordinator owns desired-state
STOP_FILE="${STOP_FILE:-.stop-beads}"

# BC-35/BC-36 (T2.4, claude-tools-7hx): the project cleanup hook the teardown
# invokes. Defined as a no-op BEFORE the project config source so a
# `.beads/runner.sh` `runner_cleanup` override wins (the broader BC-37 config
# seam — allowlist / --yolo / runner_setup — is NOT this child's surface; only
# the runner_cleanup hook the BC-36 symmetry decision invokes is). v1 ran this
# on INT/TERM + the three fatal exits but NOT on normal completion — the
# asymmetry this child consciously resolves below (symmetric EXIT-trap funnel).
runner_cleanup() { :; }

if [[ -f .beads/runner.sh ]]; then
  # shellcheck source=/dev/null
  source .beads/runner.sh 2>/dev/null || echo "degrade: CONFIG_UNREADABLE — .beads/runner.sh failed to source; using defaults" >&2
fi

# ── The callee surface: in-process NO-OP stubs (T2.1). Integration/T-final
#    swaps these for the real Local Agent (T3, lib/local-agent.sh) +
#    Coordinator (T4) — the runner's job call sites below DO NOT change. ───────
# shellcheck source=/dev/null
source "$RUNNER_DIR/lib/coordinator-stub.sh"
# shellcheck source=/dev/null
source "$RUNNER_DIR/lib/local-agent-stub.sh"

# ── BC-42 typed degradation primitive ────────────────────────────────────────
# degrade <KIND> <human-msg>            — one visible typed line; never silent.
# safe_capture <KIND> <fallback> -- cmd…
#     run cmd; on success echo its stdout; on failure emit `degrade:<KIND>` and
#     echo <fallback>. ALWAYS returns 0 (the loop must not abort) — the CALLER
#     inspects the value and branches EXPLICITLY (that explicit branch, not the
#     suppression, is the posture).
degrade() { echo "degrade: $1 — $2" >&2; }
safe_capture() {
  local kind="$1" fallback="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local out rc
  out="$("$@" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    degrade "$kind" "\`$1\` exited $rc — degrading to fallback"
    printf '%s' "$fallback"
    return 0
  fi
  printf '%s' "$out"
  return 0
}

RUNNER_ID="$(la_runner_id)"
# §2.3/§9.1 — the ONE authenticate chokepoint. This is NOT one of the six
# §3 jobs (it is the request-endpoint chokepoint, resolved once at startup,
# not per-loop), so it deliberately has no `job_*` wrapper — calling it
# directly here is the call-surface-correct shape, not an inconsistency.
PRINCIPAL="$(co_authenticate "${COORDINATOR_TOKEN:-stub-bearer-token}")" \
  || { PRINCIPAL="$(co__PRINCIPAL_V1)"; degrade AUTH_DEGRADED "co_authenticate rejected token; using §9.1 constant principal"; }

# ── Mutable machine state (the ONLY state; no scattered flags) ────────────────
STATE=""                 # current state (enumerated below)
CANDIDATE_ID=""          # task chosen this cycle
CANDIDATE_TITLE=""
CANDIDATE_DESC=""
CURRENT_TASK_ID=""       # task whose lease+in_progress we hold (in flight)
LEASE_GENERATION=""      # §4.4 fencing token for the held lease
CLAUDE_PID=""            # in-flight worker process (BC-01: one fresh proc/task)
WATCHDOG_PID=""          # T2.3 BC-22 watchdog subshell (one per task; in-band-reaped)
STREAM_FILE=""           # T2.3: worker stream-json capture (watchdog output-progress signal)
SIGNAL_FILE=""           # T2.3 BC-40 IPC seam: watchdog appends WATCHDOG_KILL=1; T2.2 classify consumes
PROC_SNAPSHOT=""         # T2.3 BC-22 snapshot-before-signal artifact (retention policy = T2.2/BC-28 seam)
STOP_REQUESTED=""        # set when stop/desired∈{stopped} OBSERVED (§2.5); honored AFTER current task
COMPLETED=0
PROCESSED=0
EXIT_CODE=0              # BC-21 process exit code (§8.1)
TERMINAL_CLASS="CLEAN"   # §8.2 terminal-reason class for job 6

# ── The six jobs — the runner is the CALLER (INTERFACE.md v1 §3) ─────────────
# Thin wrappers so every call site is one line and the stub↔real swap is total.
job_claim_lease()         { co_lease_acquire "$1" "$RUNNER_ID"; }                 # §3 j1 / §6.1 — BEFORE in_progress (AD2.1)
job_renew_lease()         { co_lease_renew "$1" "$RUNNER_ID" "${2:-}"; }          # §3 j3 — renew held lease (§4.4 fenced)
job_release_lease()       { co_lease_release "$1" "$RUNNER_ID" "${2:-}"; }        # §3 j1 pairing / §6.1
job_ask_capacity()        { la_capacity_check "${1:-standard}"; }                 # §3 j2 / §6.3 — fail-OPEN (§6.2)
job_heartbeat()           { la_heartbeat "$PROJECT_REF" "$1" "${2:-}" "${3:-}"; } # §3 j3 / §4.2 (+ renews lease)
job_reconcile_desired()   { co_deliver_desired_state "$PROJECT_REF"; }           # §3 j4 / §2.4 — desired-state
job_publish_snapshot()    { la_publish_work_snapshot "$PROJECT_REF"; }           # §3 j5 / §4.5 — read-only projection
job_report_terminal()     { la_report_terminal_reason "$1" "${2:-}" "${3:-}" "$PROJECT_REF"; } # §3 j6 / §8.2

# ── SEAM (T2.5 owns): the worker prompt + AD3.5 guardrail + STUCK primary/
#    backstop. The skeleton emits the MINIMAL contract-shaped prompt so the
#    end-to-end loop is demonstrable (the fake/real worker keys the bead id off
#    the `beads issue <ID>:` line). BC-38's full prompt (non-interactive
#    prohibition, debrief-then-close) and §7.6 `--disallowedTools` are T2.5 —
#    NOT here. ──────────────────────────────────────────────────────────────
build_worker_prompt() {
  local id="$1" title="$2" desc="$3"
  printf 'You are working on beads issue %s: "%s"\n\n%s\n\nWhen the work is complete, close the issue: bd close %s\n' \
    "$id" "$title" "$desc" "$id"
}

# ── SEAM (T2.2 owns): failure classification precedence / per-class retry /
#    circuit breaker / analysis-child (§7.1/§7.5/§8.1, BC-09/10/11/13/14/15).
#    The skeleton needs only a COARSE outcome to keep the loop well-formed:
#    SUCCESS iff the bead is closed (BC-09's "exit 0 ≠ success; truth is bd
#    status" is the part the skeleton honors — it does NOT trust the exit
#    code). A genuinely-still-open bead ⇒ NOT_CLOSED (handled by the §6.1
#    lease-release pairing below — NOT by retry/breaker, those are T2.2). A
#    DEGRADED bd read is a TYPED third outcome (BC-42): an infra blip is NOT a
#    verdict and MUST NOT be folded into NOT_CLOSED (doing so would mutate
#    work state on a hiccup — exactly the blanket-suppression anti-pattern
#    this file's posture forbids). No class taxonomy/retry/breaker here. ──────
classify_outcome() {
  local id="$1" raw status
  raw="$(safe_capture BD_UNAVAILABLE "__DEGRADED__" -- bd show "$id" --json)"
  if [[ "$raw" == "__DEGRADED__" ]]; then echo "DEGRADED"; return; fi
  # No blanket `2>/dev/null` swallow: a jq parse failure is itself a typed
  # DEGRADED signal, not a silent fold into NOT_CLOSED.
  if ! status="$(printf '%s' "$raw" | jq -r '.[0].status // empty')"; then
    degrade BD_PARSE "bd show $id JSON unparseable — typed DEGRADED, not a verdict"
    echo "DEGRADED"; return
  fi
  if [[ "$status" == "closed" ]]; then echo "SUCCESS"; else echo "NOT_CLOSED"; fi
}

# ── T2.4 (claude-tools-7hx): FULL process-tree teardown on EVERY exit path +
#    BC-35 interrupt reset-to-open + BC-36 cleanup-asymmetry RESOLUTION +
#    BC-39/BC-40 reaping guarantee. (BC-29 timestamped basenames live at the
#    artifact-creation site in st_run_task.) INTERFACE.md v1 §8.1 exit table is
#    FROZEN — preserved verbatim on every path (a change is a §11 BLOCKING
#    escalation: reopen claude-tools-65z, never a local divergence).
#
# THE CONSCIOUS BC-36 DECISION (the hazard the contract demands we RESOLVE, not
# silently inherit): v1 had NO `EXIT` trap — runner_cleanup + in-flight
# handling ran on INT/TERM and the three fatal exits but NOT on normal/graceful
# completion, and not at all on an unguarded `set -e` abort, which stranded
# CURRENT_TASK_ID `in_progress`. RESOLUTION: cleanup is made SYMMETRIC by
# routing EVERY exit path — normal completion, fatal, signal, parent-death —
# through ONE idempotent funnel via `trap … EXIT` (+ HUP for parent death; +
# INT/TERM for the signal path). The funnel: (a) reaps the worker + watchdog
# process SUBTREES (not just the tracked pid — their `claude` subagents /
# `sleep`/`ps` grandchildren too) with a BOUNDED staged escalation, then sweeps
# any still-attached stray descendant; (b) if a task is genuinely in flight,
# resets it to `open` (BC-35) so NO exit path strands it; (c) runs
# runner_cleanup; (d) removes the usage cache + the current signal file. The
# `set -e`-abort sub-hazard is additionally eliminated at the ROOT by this
# file's BC-42 posture (NO `set -e`); the EXIT trap covers every remaining
# non-SIGKILL path. RESIDUALS — consciously characterized, NOT silently
# inherited (the BC-36 mandate), each recovered by §6.1 lease expiry / orphan
# recovery (the backstop v1's PID-1 reaper *cron* was a stopgap for):
#  R1 SIGKILL of the runner ITSELF runs no trap (irreducible — no process can
#     clean up after its own SIGKILL).
#  R2 The reset-to-open issues an UNbounded `bd update` AFTER signals are
#     masked; if `bd`/Dolt is itself wedged (the BD_UNAVAILABLE scenario) the
#     strand window is wider than just R1 — the operator's recourse is SIGKILL
#     (→ R1). A bounded `bd` is intentionally NOT added: `timeout` is
#     non-portable here and lease-expiry already recovers the bead.
#  R3 `_sweep_self`'s broad `$$`-subtree TERM/KILL is PID-based: between the
#     `ps` snapshot and the signal a recycled PID could be hit. Inherent to any
#     PID teardown; the window is sub-millisecond and bounded to the dying
#     runner's own former descendants.
# The new runner
# closes the v1 leak AT THE SOURCE: it has NO `tail -f`/parser subshell at all
# (BC-39/BC-40 re-implemented — see st_run_task) and BOTH async children
# (worker, watchdog) are tracked and reaped here on every path, so nothing
# reparents in the normal/signal/abort cases.
#
# BC-39/BC-40 (re-implemented, SCAFFOLDING not transcribed): worker stdout+
# stderr are already merged into ONE file (st_run_task `> … 2>&1`, no `tail -f`
# subshell, no tempfile-as-IPC `tail`/`pkill -P`/`sleep 1`-to-flush); the
# capture-then-classify happens-before is already structural (st_run_task
# `wait` the worker → reap+join the watchdog → THEN POST_TASK classifies). The
# half the contract assigns HERE: the GUARANTEED reaping of that subtree on
# every exit path, plus a worker teardown that sends SIGINT FIRST so the SDK
# flushes in-flight HTTP-retry stderr into the merged stream file (BC-39
# intent) before the bounded escalation to SIGKILL.

# _tree_pids is defined further below (the T2.3 ps/ppid fixpoint helper); these
# are CALLED only at teardown / in-band-reap time, by which point it exists
# (bash resolves function calls late) — no forward-reference hazard.

# _kill_tree <root> <signal> — signal every pid in <root>'s subtree (incl.
# root, incl. grandchildren) BEFORE any of them can reparent. Skips $$ ALWAYS
# (BC-21: never signal the runner itself ⇒ its frozen exit code is preserved).
# A dead pid is a harmless no-op. Sets _KT_N = number actually signaled.
_KT_N=0
_kill_tree() {
  local root="$1" sig="$2" p
  _KT_N=0
  [[ -n "$root" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$$" ]] || continue
    if kill "-$sig" "$p" 2>/dev/null; then _KT_N=$((_KT_N+1)); fi
  done < <(_tree_pids "$root" 2>/dev/null)
  return 0
}

# _reap_tree <root> <first_sig> <grace_secs> — staged, BOUNDED teardown of a
# child SUBTREE: first_sig the whole tree → ≤grace×1s poll → SIGKILL the
# survivors → reap the direct-child zombie. Bounded by construction — this is
# the fix for the skeleton's marked hazard (an UNbounded `wait` on a
# SIGTERM-ignoring worker would block teardown until a second signal).
_reap_tree() {
  local root="$1" first="${2:-TERM}" grace="${3:-2}" i
  [[ -n "$root" ]] || return 0
  if kill -0 "$root" 2>/dev/null; then
    _kill_tree "$root" "$first"
    for ((i=0; i<grace; i++)); do
      kill -0 "$root" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$root" 2>/dev/null; then _kill_tree "$root" KILL; fi
  fi
  wait "$root" 2>/dev/null || true     # reap our direct-child zombie
}

# _sweep_self — TERM, then (only if something was signaled) KILL, every
# still-ATTACHED descendant of THIS runner: the defensive catch-all for a stray
# subshell the tracked-pid reaps missed. Skips $$ (exit code preserved).
# Reparented-to-init orphans (ppid=1) have LEFT $$'s subtree and are the
# LAUNCHER's process-group sweep (the harness `_reap_runner_pg` does exactly
# `kill -KILL -- -RUNNER_PID` AFTER observing the exit code; the T3 launch
# contract SHOULD start the runner in its own group/session). A self-issued
# negative-PGID kill is deliberately NOT used: it would SIGKILL the runner
# mid-EXIT-trap and turn the frozen BC-21 code into 137 — the contract's
# "process-group kill" option is the launcher's, not the dying process's.
_sweep_self() {
  _kill_tree "$$" TERM
  [[ "${_KT_N:-0}" -gt 0 ]] || return 0
  sleep 1
  _kill_tree "$$" KILL
}

# THE single idempotent teardown funnel — invoked via `trap … EXIT`, so it runs
# on literally every exit path (normal st_terminal `exit`, the signal path's
# `exit 1`, any unexpected abort). Does NOT call `exit` (bash would override
# the in-flight exit code — BC-21 §8.1 is preserved by NOT touching it here).
_TEARDOWN_DONE=0
runner_teardown() {
  # Disarm signals FIRST — before the idempotency latch (T2.4 hardening). If
  # this ran after the latch, a signal landing in the window between entering
  # the trap and the disarm could run _on_signal → `exit 1` → re-enter this
  # trap → the latch returns early → teardown SKIPPED (worker/watchdog not
  # reaped, task not reset) AND a clean 0 corrupted to 1. Masking first closes
  # that race: once any exit funnel starts, signals are inert immediately.
  trap '' INT TERM HUP
  [[ "$_TEARDOWN_DONE" -eq 1 ]] && return 0
  _TEARDOWN_DONE=1

  # (a) Reap the worker subtree FIRST with SIGINT — BC-39 intent: a graceful
  #     interrupt lets the SDK flush in-flight HTTP-retry stderr into the
  #     merged stream file before it dies — then bounded-escalate; then the
  #     watchdog subtree; then the attached-stray catch-all.
  if [[ -n "$CLAUDE_PID" ]];   then _reap_tree "$CLAUDE_PID" INT 3;   CLAUDE_PID=""; fi
  if [[ -n "$WATCHDOG_PID" ]]; then _reap_tree "$WATCHDOG_PID" TERM 2; WATCHDOG_PID=""; fi
  _sweep_self

  # (b) BC-35 / BC-36 in-flight safety net — fires on EVERY path (signal,
  #     fatal, parent-death, unexpected abort), NOT just INT/TERM. CURRENT_TASK_ID
  #     is set at task start and cleared on clean finish, so this resets ONLY a
  #     genuinely in-flight task ⇒ NO exit path strands it `in_progress`.
  if [[ -n "$CURRENT_TASK_ID" ]]; then
    echo "Interrupted — resetting $CURRENT_TASK_ID to open"
    safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
    job_release_lease "$CURRENT_TASK_ID" "${LEASE_GENERATION:-}" >/dev/null 2>&1   # §6.1 pairing
    CURRENT_TASK_ID=""
  fi

  # (c) project cleanup hook — now SYMMETRIC (THE BC-36 resolution: v1 ran this
  #     on INT/TERM+fatal but NOT on normal completion; here it runs on ALL).
  runner_cleanup 2>/dev/null || true

  # (d) lifecycle file removal — BC-35 literal: usage cache + the current
  #     signal file. STREAM_FILE / PROC_SNAPSHOT are deliberately LEFT:
  #     selective retention-vs-delete by FINAL classification is T2.2/BC-28's
  #     seam — this child owns the BC-29 BASENAME scheme, NOT the retention
  #     policy, and must not destroy that seam's input.
  rm -f "${USAGE_CACHE_FILE:-}" "${SIGNAL_FILE:-}" 2>/dev/null || true

  echo "runner: Results: $COMPLETED completed / $PROCESSED processed"
  # NO `exit` — preserve the code set by st_terminal / _on_signal (BC-21).
}
trap runner_teardown EXIT

# Signal path (INT/TERM + HUP for parent-death hangup) → BC-21 exit 1 (§8.1
# row 1). Writes the §8.2 last-durable terminal-reason (job 6, INTERRUPTED/1)
# BEFORE the process exits, then `exit 1`. The `exit` triggers the EXIT trap
# above, which performs the SINGLE symmetric teardown (subtree reap +
# reset-to-open + runner_cleanup + file cleanup + Results) — so the signal path
# and the normal path share ONE teardown (the BC-36 symmetry, by construction).
_on_signal() {
  trap '' INT TERM HUP
  echo ""
  echo "runner: SIGINT/SIGTERM/SIGHUP — stopping (BC-21 exit 1)"
  # Defense-in-depth for the FROZEN BC-21 table (st_terminal already disarms
  # signals before deciding 0/2/3/4, so this is normally unreachable after a
  # terminal decision): only claim row-1 (signal=1) if NO terminal code has
  # been decided yet (EXIT_CODE==0 ⇒ a genuine in-flight interrupt). If a
  # fatal 2/3/4 is already set, preserve it — never downgrade to 1.
  if [[ "${EXIT_CODE:-0}" -eq 0 ]]; then
    EXIT_CODE=1; TERMINAL_CLASS="INTERRUPTED"
    job_report_terminal INTERRUPTED 1 "${CURRENT_TASK_ID:-}" >/dev/null 2>&1
  fi
  exit "$EXIT_CODE"
}
trap _on_signal INT TERM HUP

# ── SEAM (T2.3 owns, claude-tools-9e7): BC-22 idle watchdog, RE-IMPLEMENTED ───
# WHAT CHANGED vs v1 (the behavior CORRECTION, not an interface change):
#   v1 keyed "stuck" PURELY on PARENT stream-json line cadence (an ACTIVITY_FILE
#   stamped by the stream parser). Real incident 2026-05-16: a healthy agent
#   that backgrounded a long op and waited went parent-stream-silent on a
#   CPU-idle machine and was SIGKILLed at the 600s default (forcing the
#   .beads/runner.sh IDLE_TIMEOUT=1200 stopgap). The liveness SIGNAL is now
#   "agent + child-process-tree progress": a working child / Task subagent /
#   spawned `claude -p` / bash op making CPU **or** output progress is NOT
#   stuck. Everything else BC-22 (snapshot-BEFORE-signal, staged
#   SIGINT→poll→SIGKILL, the 180s soft tier, the 15s SCAR poll, the
#   WATCHDOG_KILL marker) is PRESERVED.
#
# EMPIRICAL BASIS (probe run IN this bead, claude 2.1.142, darwin 25.5.0,
# conformance/probes/t23-subagent-stream-warmth-probe.sh): while a real
# CPU-bound child op ran for 60s the PARENT stream-json file did not grow at
# all (frozen 60s) yet the process-tree cumulative CPU climbed monotonically
# 0→53s across that exact silence. ⇒ a subagent/long-op does NOT keep the
# parent stream warm; child-process-tree liveness is **LOAD-BEARING** (not
# optional) for the subagent-heavy task design — not a robustness nicety.
#
# OWNERSHIP: T2.3 defines the watchdog subtree's SHAPE + liveness POLICY and
# only EMITS `WATCHDOG_KILL=1` into the SIGNAL_FILE. It does NOT classify
# (precedence / §7.1 slot / exit-code map = T2.2) and does NOT guarantee the
# subtree is reaped on every exit path (full PG/EXIT/SIGHUP teardown = T2.4) —
# both are marked seams below. The stream-json PARSER (BC-39/40) is T2.2's; the
# watchdog needs only stream-file GROWTH (a byte count), never a parse.

# _tree_pids <root> — every pid in the subtree incl. root (portable
# macOS+Linux: one `ps -A` snapshot, ppid fixpoint; n is tiny).
_tree_pids() {
  local root="$1" table
  table="$(ps -A -o pid=,ppid= 2>/dev/null)" || return 1
  awk -v root="$root" '
    { ppid[$1]=$2; all[++n]=$1 }
    END{
      inset[root]=1; changed=1
      while(changed){ changed=0
        for(i=1;i<=n;i++){ c=all[i]
          if(!inset[c] && inset[ppid[c]]){ inset[c]=1; changed=1 } } }
      for(i=1;i<=n;i++) if(inset[all[i]]) print all[i]
    }' <<<"$table"
}
# _cputime_to_secs "[[DD-]HH:]MM:SS[.f]" — ps -o time= → integer secs
# (10# defeats octal on zero-padded fields).
_cputime_to_secs() {
  local t="$1" d=0 rest h=0 m=0 s=0
  [[ "$t" == *-* ]] && { d="${t%%-*}"; rest="${t#*-}"; } || rest="$t"
  rest="${rest%%.*}"
  local IFS=:; set -- $rest
  case $# in 3) h="$1"; m="$2"; s="$3";; 2) m="$1"; s="$2";; 1) s="$1";; esac
  echo $(( 10#${d:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}
# _tree_cpu_secs <root> — Σ cumulative CPU secs across the live subtree. A
# child still alive and accruing CPU IS progress even if the parent stream is
# silent (the load-bearing signal). Dead children leave the ps table, so this
# tracks ONGOING work — exactly the liveness we want.
_tree_cpu_secs() {
  local root="$1" pids csv total=0 line
  pids="$(_tree_pids "$root")" || return 1
  [[ -z "$pids" ]] && { echo 0; return 0; }
  csv="$(echo "$pids" | tr '\n' ',')"; csv="${csv%,}"
  while IFS= read -r line; do
    line="$(echo "$line" | tr -d ' ')"; [[ -z "$line" ]] && continue
    total=$(( total + $(_cputime_to_secs "$line") ))
  done < <(ps -o time= -p "$csv" 2>/dev/null)
  echo "$total"
}

# _watchdog_loop <claude_pid> <stream_file> <signal_file> <proc_snapshot>
# Polls every WATCHDOG_POLL while the worker is alive. Liveness = progress
# since the last poll, where progress is (stream-file GREW) OR (tree CPU
# ADVANCED). idle = seconds since the last observed progress (init at spawn,
# BC-22). Soft-warn at WATCHDOG_SOFT_WARN; KILL at IDLE_TIMEOUT with
# snapshot-BEFORE-signal then staged SIGINT→(≤10×1s)→SIGKILL.
_watchdog_loop() {
  local pid="$1" stream="$2" sig="$3" snap="$4"
  local now last_progress prev_bytes prev_cpu bytes cpu idle warned=0
  now="$(date +%s)"; last_progress="$now"
  prev_bytes="$(wc -c < "$stream" 2>/dev/null | tr -d ' ')"; prev_bytes="${prev_bytes:-0}"
  prev_cpu="$(_tree_cpu_secs "$pid" 2>/dev/null)"; prev_cpu="${prev_cpu:-0}"
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$WATCHDOG_POLL"
    kill -0 "$pid" 2>/dev/null || break
    now="$(date +%s)"
    bytes="$(wc -c < "$stream" 2>/dev/null | tr -d ' ')"; bytes="${bytes:-0}"
    cpu="$(_tree_cpu_secs "$pid" 2>/dev/null)"; cpu="${cpu:-0}"
    # CPU or output progress anywhere in the agent+child tree ⇒ NOT stuck.
    if [[ "$bytes" -gt "$prev_bytes" || "$cpu" -gt "$prev_cpu" ]]; then
      last_progress="$now"; warned=0
    fi
    prev_bytes="$bytes"; prev_cpu="$cpu"
    idle=$(( now - last_progress ))
    if [[ "$idle" -ge "$IDLE_TIMEOUT" ]]; then
      echo "  Killing after ${idle}s idle — no CPU or output progress in the agent+child-process tree (likely stuck)"
      # BC-22/BC-40: emit the marker for the classifier (T2.2 owns precedence).
      echo "WATCHDOG_KILL=1" >> "$sig"
      # Snapshot the WHOLE stuck tree BEFORE any signal — lsof on a dying
      # process returns nothing useful, so order is load-bearing (BC-22 SCAR).
      {
        echo "=== ps (tree, idle ${idle}s, IDLE_TIMEOUT=${IDLE_TIMEOUT}, signal=child-tree-progress) ==="
        ps -o pid,ppid,stat,etime,pcpu,pmem,time,command -p \
           "$(_tree_pids "$pid" | tr '\n' ',' | sed 's/,$//')" 2>&1 || true
        echo ""
        echo "=== lsof (TCP/IPv/PIPE, root pid $pid) ==="
        lsof -p "$pid" 2>/dev/null | grep -E 'TCP|IPv|PIPE' || echo "(no matching fds)"
      } > "$snap" 2>&1 || true
      # Staged kill (BC-22 SCAR): SIGINT first so the SDK flushes in-flight
      # HTTP-retry state to stderr (merged into the stream file), poll up to
      # 10×1s, then SIGKILL. Signals the root worker pid (full process-tree
      # TEARDOWN is T2.4's owned surface — marked seam, NOT done here).
      echo "  watchdog: staged kill — interrupt first, up to 10s grace, then hard-kill"
      echo "  watchdog: SIGINT sent"
      kill -INT "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "  watchdog: SIGKILL sent (grace elapsed)"
        kill -KILL "$pid" 2>/dev/null || true
      fi
      break
    elif [[ "$idle" -ge "$WATCHDOG_SOFT_WARN" && "$warned" -eq 0 ]]; then
      echo "  No activity for ${idle}s — possibly stuck (soft warning; still waiting)"
      warned=1
    fi
  done
}

# ── Explicit state machine ───────────────────────────────────────────────────
# States (enumerated; transitions are the ONLY control flow — no scattered
# flag checks):
#
#   STARTING   one-time init; heartbeat actual=starting
#   RECONCILE  THE single between-tasks reconcile point: job 4 (desired-state)
#              + new-work poll (§2.5 between-tasks). The ONLY place desired is
#              read between tasks and the ONLY place the next task is chosen.
#   CLAIM      job 1 (claim-lease) BEFORE `bd update --status=in_progress`
#              (AD2.1); job 2 (ask-capacity, fail-OPEN §6.2)
#   RUN_TASK   one fresh `claude -p` (BC-01); during-task §2.5 cadence:
#              job 4 every CONTROL_POLL_INTERVAL (observe stop — no mid-task
#              kill), job 3 every HEARTBEAT_INTERVAL
#   POST_TASK  job 1 pairing (release lease ⇒ §6.1 bead→open if not closed),
#              coarse outcome, job 5 (publish-work-snapshot) → back to RECONCILE
#   DRAINED    empty `bd ready` (§1.2): exit-0-on-drain ≠ stop the project
#   STOPPING   stop observed/consumed (§2.5): graceful, BC-21 exit 0
#   TERMINAL   job 6 (report-terminal-reason) last durable write, then exit
#              the BC-21 code (§8.1)
transition() { echo "state: ${STATE:-∅} -> $1"; STATE="$1"; }

st_starting() {
  echo "runner: principal=$PRINCIPAL runner_id=$RUNNER_ID project=$PROJECT_REF"
  rm -f "$STOP_FILE" 2>/dev/null || true       # clean slate (stop is consumed, not sticky)
  job_heartbeat starting "" "" >/dev/null
  transition RECONCILE
}

# THE single reconcile point between tasks.
st_reconcile() {
  CANDIDATE_ID=""; CANDIDATE_TITLE=""; CANDIDATE_DESC=""

  # Graceful stop file is a between-tasks signal (§2.5 completion semantic).
  if [[ -f "$STOP_FILE" ]]; then
    echo "runner: stop file ($STOP_FILE) observed"
    rm -f "$STOP_FILE" 2>/dev/null || true
    transition STOPPING; return
  fi

  # Job 4 — reconcile desired-state (§2.4/§3). The Coordinator owns `desired`.
  local desired
  desired="$(safe_capture COORD_UNREACHABLE running -- job_reconcile_desired)"
  case "$desired" in
    stopped)
      echo "runner: desired=stopped"
      transition STOPPING; return ;;
    paused)
      # Honest: desired≠actual is legal. Report idle, wait, re-reconcile.
      job_heartbeat idle "" "" >/dev/null
      echo "runner: desired=paused — holding (re-reconcile in ${RECLAIM_POLL_INTERVAL}s)"
      sleep "$RECLAIM_POLL_INTERVAL"
      transition RECONCILE; return ;;
    running|spare-cycles) : ;;     # spare-cycles cost-class mapping is T2.2's
    *)
      degrade COORD_UNREACHABLE "unrecognized desired='$desired' — fail-OPEN to running (§6.2 capacity-side posture)"
      ;;
  esac

  # New-work poll (§2.5 between-tasks). BC-42: a DEGRADED bd is NOT a drain —
  # only a genuine empty queue drains (§1.2). Typed, explicit, not `|| []`.
  local ready_json
  ready_json="$(safe_capture BD_UNAVAILABLE "__DEGRADED__" -- bd ready --json)"
  if [[ "$ready_json" == "__DEGRADED__" ]]; then
    echo "runner: bd ready degraded — NOT treating as drain; retry in ${RECLAIM_POLL_INTERVAL}s"
    sleep "$RECLAIM_POLL_INTERVAL"
    transition RECONCILE; return
  fi

  CANDIDATE_ID="$(printf '%s' "$ready_json"   | jq -r '.[0].id // empty'    2>/dev/null)"
  if [[ -z "$CANDIDATE_ID" ]]; then
    transition DRAINED; return                 # §1.2 genuine empty queue
  fi
  CANDIDATE_TITLE="$(printf '%s' "$ready_json" | jq -r '.[0].title // ""'       2>/dev/null)"
  CANDIDATE_DESC="$(printf '%s' "$ready_json"  | jq -r '.[0].description // ""' 2>/dev/null)"
  transition CLAIM
}

st_claim() {
  # Job 1 — claim-lease BEFORE `bd update --status=in_progress` (AD2.1/§6.1).
  # No lease ⇒ do NOT run it (§6.2 degraded-CLOSED is the stub's `1`).
  local gen rc
  gen="$(job_claim_lease "$CANDIDATE_ID" 2>/dev/null)"; rc=$?   # capture rc explicitly (robust at the real-T4 swap)
  if [[ $rc -ne 0 || -z "$gen" ]]; then
    echo "runner: lease unavailable for $CANDIDATE_ID — not claiming (no lease ⇒ no run)"
    sleep "${LEASE_DENY_BACKOFF:-3}"
    transition RECONCILE; return
  fi
  LEASE_GENERATION="$gen"

  # Job 2 — ask-capacity (§6.3). Failure posture is fail-OPEN (§6.2): the stub
  # returns ok; a real `over` would hold here. Explicit, not silent.
  if ! job_ask_capacity standard; then
    echo "runner: capacity verdict=over — releasing lease, holding"
    job_release_lease "$CANDIDATE_ID" "$LEASE_GENERATION" >/dev/null
    LEASE_GENERATION=""
    sleep "$RECLAIM_POLL_INTERVAL"
    transition RECONCILE; return
  fi

  # Lease held ⇒ now (and only now) drive the bead to in_progress (AD2.1).
  # T2.4: CURRENT_TASK_ID is set BEFORE the in_progress write (v1/skeleton set
  # it AFTER) — it is the BC-35/BC-36 teardown safety-net marker, so a signal
  # or abort landing DURING the write still resets the bead to open ⇒ NO exit
  # path strands it `in_progress`. (AD2.1 is lease-before-in_progress, already
  # satisfied above; CURRENT_TASK_ID is a teardown marker, not a state
  # transition — this reorder is in this child's BC-35/BC-36 surface, not the
  # T2.1 state machine's.)
  CURRENT_TASK_ID="$CANDIDATE_ID"
  safe_capture BD_UNAVAILABLE "" -- bd update "$CANDIDATE_ID" --status=in_progress >/dev/null
  transition RUN_TASK
}

st_run_task() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $CANDIDATE_TITLE ($CURRENT_TASK_ID)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # BC-01: a brand-new `claude -p` process + fresh context per task. NO
  # --continue / --resume EVER — a retried task (it reappears via `bd ready`)
  # is spawned the same way, from an empty window, by construction. The prompt
  # is rebuilt from scratch each task (no cross-task carryover).
  local prompt
  prompt="$(build_worker_prompt "$CURRENT_TASK_ID" "$CANDIDATE_TITLE" "$CANDIDATE_DESC")"

  # T2.3 watchdog artifacts. The stream file is BC-39's intent (stdout+stderr
  # merged so SDK HTTP-retry state is captured) re-implemented idiomatically;
  # the watchdog reads only its GROWTH (a byte count) as the output-progress
  # signal — it never parses it (the parser/classifier is T2.2). PROC_SNAPSHOT
  # lands under LOG_DIR; BC-27's self-gitignore is re-asserted defensively
  # where we write post-mortem artifacts (raw model output must never reach
  # git) — the full LOG_DIR lifecycle/retention policy is T2.2/BC-28's seam.
  local iter_ts log_dir base
  iter_ts="$(date -u +%Y%m%dT%H%M%SZ)"
  log_dir=".beads/runner-logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  [[ -f "$log_dir/.gitignore" ]] || printf '*\n!.gitignore\n' > "$log_dir/.gitignore" 2>/dev/null || true
  # BC-29 (T2.4, claude-tools-7hx): per-iteration timestamped basenames
  # `<TASK_ID>-<ITER_TS>` for ALL three artifacts so repeated attempts of the
  # SAME task never overwrite each other's preserved stream / signal /
  # proc-snapshot. v1's skeleton used `mktemp` for STREAM/SIGNAL: unique, but
  # neither `<TASK_ID>-<ITER_TS>` NOR inside the BC-27 self-gitignored log_dir
  # — the timestamped basename is THIS child's owned surface. mktemp survives
  # ONLY as the degraded fallback when log_dir is unwritable (BC-42 posture:
  # one visible typed degrade, never crash the loop). Selective
  # retention-vs-delete by final classification stays T2.2/BC-28's seam — this
  # child owns the NAMING, not the retention.
  base="$log_dir/$CURRENT_TASK_ID-$iter_ts"
  if [[ -d "$log_dir" && -w "$log_dir" ]]; then
    STREAM_FILE="$base.stream.jsonl"
    SIGNAL_FILE="$base.signal"
    PROC_SNAPSHOT="$base.proc.txt"
  else
    # Degraded: ALL THREE get a unique mktemp fallback (symmetric — a
    # timestamped path inside an unwritable dir would silently fail to write
    # AND, for the proc-snapshot, defeat BC-29's no-collide intent on the
    # degraded path too). BC-42 posture: one visible typed degrade, continue.
    degrade LOGDIR_UNWRITABLE "$log_dir unwritable — artifacts to mktemp (BC-29 basename degraded; loop continues)"
    STREAM_FILE="$(mktemp 2>/dev/null)"   || STREAM_FILE="$base.stream.jsonl"
    SIGNAL_FILE="$(mktemp 2>/dev/null)"   || SIGNAL_FILE="$base.signal"
    PROC_SNAPSHOT="$(mktemp 2>/dev/null)" || PROC_SNAPSHOT="$base.proc.txt"
  fi
  # Truncate to a known-empty start; a failure here is the doubly-degraded edge
  # (log_dir AND mktemp both unusable) — typed, visible, never a silent crash.
  : > "$STREAM_FILE" 2>/dev/null && : > "$SIGNAL_FILE" 2>/dev/null \
    || degrade ARTIFACT_UNWRITABLE "could not init stream/signal files — watchdog output-progress signal degraded; loop continues"

  # BC-39: stdout+stderr → the one stream file (stderr carries SDK HTTP-retry
  # state; the watchdog's SIGINT-before-SIGKILL exists so it flushes here).
  claude -p "$prompt" \
    --output-format stream-json \
    --verbose \
    --model "$DEFAULT_MODEL" \
    "${EXTRA_CLAUDE_FLAGS[@]+"${EXTRA_CLAUDE_FLAGS[@]}"}" \
    "${PERMISSION_FLAGS[@]+"${PERMISSION_FLAGS[@]}"}" \
    > "$STREAM_FILE" 2>&1 &
  CLAUDE_PID=$!

  # BC-22 watchdog (T2.3): a sibling background subshell keying liveness on
  # agent+child-process-tree progress (CPU or stream output) — NOT parent-
  # stream silence (the corrected v1 SCAR). It is the ONLY thing that may end a
  # task early, and ONLY for genuine no-progress-anywhere-in-the-tree stall;
  # this is orthogonal to the §2.5 stop semantic below (a stop REQUEST is never
  # a mid-task kill — honored after the task).
  # T2.4: the watchdog runs in a subshell that EXPLICITLY drops the runner's
  # traps — a subshell exiting must NEVER fire runner_teardown, and a signal
  # must hit the runner main (its _on_signal), not this child. (Bash already
  # resets subshell traps; making it explicit is defensive and documents
  # intent. T2.3's _watchdog_loop body is byte-unchanged — this is T2.4's
  # trap-isolation, not a watchdog-policy edit.)
  ( trap - EXIT HUP INT TERM
    _watchdog_loop "$CLAUDE_PID" "$STREAM_FILE" "$SIGNAL_FILE" "$PROC_SNAPSHOT" ) &
  WATCHDOG_PID=$!

  # §2.5 DURING-task cadence. We poll on a fine RUNNER_TICK and act on the
  # CONTROL_POLL_INTERVAL / HEARTBEAT_INTERVAL boundaries. A stop REQUEST is
  # OBSERVED here (≤ CONTROL_POLL_INTERVAL so the Board can render `stopping…`
  # immediately) but only ACTED ON after the task completes (§2.5 "stop after
  # current task" — no mid-task kill for a stop). The watchdog above is the
  # separate BC-22 liveness concern. Heartbeat (job 3) renews the held lease.
  local since_ctl=0 since_hb=0
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep "$RUNNER_TICK"
    since_ctl=$((since_ctl + RUNNER_TICK))
    since_hb=$((since_hb + RUNNER_TICK))
    if [[ $since_ctl -ge $CONTROL_POLL_INTERVAL ]]; then
      since_ctl=0
      local d
      d="$(safe_capture COORD_UNREACHABLE running -- job_reconcile_desired)"
      if [[ "$d" == "stopped" ]] || [[ -f "$STOP_FILE" ]]; then
        STOP_REQUESTED=1
        job_heartbeat stopping "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null
        echo "runner: stop OBSERVED during task (≤${CONTROL_POLL_INTERVAL}s) — honoring AFTER current task (§2.5, no mid-task kill)"
      fi
    fi
    if [[ $since_hb -ge $HEARTBEAT_INTERVAL ]]; then
      since_hb=0
      job_heartbeat running "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null  # renews held lease (§3 j3)
    fi
  done
  wait "$CLAUDE_PID" 2>/dev/null || true       # BC-01: exit code is NOT trusted (BC-09); see classify_outcome
  CLAUDE_PID=""

  # In-band reap of the watchdog SUBTREE (its SHAPE/policy is T2.3's; the
  # reaping GUARANTEE is T2.4's, claude-tools-7hx). The loop self-exits within
  # ≤WATCHDOG_POLL once CLAUDE_PID dies; reaping the whole subtree here makes
  # it prompt + deterministic on the normal path AND collects the subshell's
  # own `sleep`/`ps`/`lsof` grandchildren (a pid-only `kill` left that `sleep`
  # to reparent — the exact v1-class leak). The EVERY-exit-path guarantee
  # (interrupt, parent-death, abort — BC-35/BC-36 symmetry) is the EXIT/HUP
  # trap funnel above (runner_teardown), which re-reaps this subtree too.
  if [[ -n "$WATCHDOG_PID" ]]; then
    _reap_tree "$WATCHDOG_PID" TERM 2     # subshell + its sleep/ps/lsof kids
    WATCHDOG_PID=""
  fi
  # SIGNAL_FILE + STREAM_FILE + PROC_SNAPSHOT are intentionally LEFT in place:
  # T2.2 (classify/precedence/§7.1) consumes WATCHDOG_KILL=1 from SIGNAL_FILE
  # and T2.2/BC-28 owns selective stream/proc-snapshot retention-vs-delete by
  # final classification. Pre-deleting here would destroy that seam's input.
  transition POST_TASK
}

st_post_task() {
  PROCESSED=$((PROCESSED + 1))

  # Coarse outcome (SEAM — full §7.1 taxonomy/retry/breaker is T2.2).
  local outcome
  outcome="$(classify_outcome "$CURRENT_TASK_ID")"
  case "$outcome" in
    SUCCESS)
      COMPLETED=$((COMPLETED + 1))
      echo "  done: $CANDIDATE_TITLE" ;;
    DEGRADED)
      # BC-42: a degraded bd read is NOT a verdict — do NOT mutate the bead's
      # work state on an infra blip. Release the lease (§6.1); a still-open
      # bead is recovered via lease EXPIRY (§6.1 orphan recovery), never via a
      # blip-driven status write. Typed, explicit, visible — not swallowed.
      echo "  outcome undetermined ($CURRENT_TASK_ID — bd degraded): not mutating work state (BC-42; §6.1 expiry recovers it)" ;;
    *)  # NOT_CLOSED
      # §6.1 lease-release pairing: "lease release or expiry maps the bead
      # back to --status=open". A bead the worker left in_progress is returned
      # to the ready pool by THIS pairing — not by failure classification
      # (per-class retry/breaker/analysis-child is entirely T2.2).
      echo "  not closed: $CANDIDATE_TITLE — §6.1 lease-release returns it to open"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null ;;
  esac

  # Job 1 pairing — release the lease (§6.1; fenced by §4.4 generation).
  job_release_lease "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null
  # Job 5 — publish the §4.5 read-only projection (Dolt stays work-truth).
  job_publish_snapshot >/dev/null

  CURRENT_TASK_ID=""; LEASE_GENERATION=""
  echo ""

  # The stop OBSERVED mid-task (§2.5) is honored HERE — after the task — never
  # by killing it. This is the single place that decision is acted on.
  if [[ -n "$STOP_REQUESTED" ]]; then
    transition STOPPING; return
  fi
  transition RECONCILE                          # back to the ONE reconcile point
}

# §1.2: a drained `bd ready` exits 0. exit-0-on-drain ≠ stop the project — UX
# §0.A "keep the project eligible / relaunch on new work" is satisfied at the
# Local Agent tier (T3), NOT by changing this exit contract. This clause fixes
# only the contract here.
st_drained() {
  echo ""
  echo "runner: no ready tasks — draining (§1.2: exit-0-on-drain ≠ stop project)"
  TERMINAL_CLASS="CLEAN"; EXIT_CODE=0
  transition TERMINAL
}

st_stopping() {
  echo "runner: graceful stop consumed (BC-21 exit 0)"
  job_heartbeat stopping "" "" >/dev/null
  TERMINAL_CLASS="CLEAN"; EXIT_CODE=0
  transition TERMINAL
}

# Job 6 — report-terminal-reason: the LAST DURABLE control-plane write BEFORE
# the process exits (§8.2/S-7), then the verbatim BC-21 process exit (§8.1).
st_terminal() {
  job_heartbeat stopped "" "" >/dev/null
  job_report_terminal "$TERMINAL_CLASS" "$EXIT_CODE" "" >/dev/null
  echo "runner: $COMPLETED completed / $PROCESSED processed — terminal=$TERMINAL_CLASS exit=$EXIT_CODE"
  # T2.4 / BC-21 §8.1 (FROZEN): the terminal code is now DECIDED. Disarm the
  # signal trap BEFORE `exit` so a signal racing the exit→EXIT-trap handoff
  # cannot run _on_signal and downgrade a decided 0/2/3/4 to 1 (a coordinator
  # distinguishing AUTH=3 / BILLING=4 / breaker=2 from clean=0 depends on this;
  # the fatal 2/3/4 producers are T2.2's, but this funnel must already be safe
  # for them — the table is honored on EVERY exit path, this child's OWNS #1).
  trap '' INT TERM HUP
  exit "$EXIT_CODE"
}

# ── Dispatch (the entire control flow is this table — nothing scattered) ──────
STATE="STARTING"
while true; do
  case "$STATE" in
    STARTING)  st_starting  ;;
    RECONCILE) st_reconcile ;;
    CLAIM)     st_claim     ;;
    RUN_TASK)  st_run_task  ;;
    POST_TASK) st_post_task ;;
    DRAINED)   st_drained   ;;
    STOPPING)  st_stopping  ;;
    TERMINAL)  st_terminal  ;;   # exits the process
    *)
      degrade STATE_INVARIANT "unknown state '$STATE' — failing safe to TERMINAL"
      TERMINAL_CLASS="CLEAN"; EXIT_CODE=0; STATE="TERMINAL" ;;
  esac
done
