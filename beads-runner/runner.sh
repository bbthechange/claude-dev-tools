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

# ── Minimal runtime config (skeleton). The full BC-37 config seam — sourced
#    allowlist, --yolo, runner_setup/runner_cleanup hooks — is NOT T2.1's owned
#    surface; the skeleton keeps a minimal default + an optional project source
#    so it is runnable end-to-end. Richer policy lands with T2 integration. ────
DEFAULT_MODEL="${DEFAULT_MODEL:-opus[1m]}"
PERMISSION_FLAGS=(--permission-mode acceptEdits)
EXTRA_CLAUDE_FLAGS=(--no-chrome)
PROJECT_REF="${PROJECT_REF:-$(basename "$(pwd)")}"     # §4.2 project_ref (controllable unit); Coordinator owns desired-state
STOP_FILE="${STOP_FILE:-.stop-beads}"
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

# ── SEAM (T2.4 owns): full process-group/tree teardown on EVERY exit path,
#    BC-35 interrupt reset-to-open, BC-29 timestamped artifact basenames,
#    BC-36 cleanup symmetry. The skeleton does the MINIMAL safe thing — reap
#    the one worker process it tracks — and nothing more; the leaked-subshell /
#    PG-kill / EXIT+SIGHUP coverage is explicitly T2.4. ───────────────────────
_reap_worker() {
  [[ -n "$CLAUDE_PID" ]] || return 0
  kill -0 "$CLAUDE_PID" 2>/dev/null && kill "$CLAUDE_PID" 2>/dev/null
  # KNOWN MARKED GAP (T2.4 seam): a worker that ignores SIGTERM makes this
  # `wait` block until a second signal. The bounded SIGINT→SIGKILL staged
  # escalation + full process-group/tree teardown is T2.4's owned surface —
  # deliberately NOT implemented here (non-overlapping ownership).
  wait "$CLAUDE_PID" 2>/dev/null || true
  CLAUDE_PID=""
}

# Interrupt → BC-21 exit 1 (§8.1 row 1). The runner still owns its six-job
# CALLS on this path: pair the lease release (§6.1) and write the §8.2
# last-durable terminal-reason (job 6) BEFORE exit. The fuller BC-35
# reset-the-in-flight-bead-to-open + lifecycle cleanup is T2.4's SEAM.
_on_interrupt() {
  trap - INT TERM
  echo ""
  echo "runner: SIGINT/SIGTERM — stopping (BC-21 exit 1)"
  _reap_worker
  [[ -n "$CURRENT_TASK_ID" ]] && job_release_lease "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null 2>&1
  job_report_terminal INTERRUPTED 1 "${CURRENT_TASK_ID:-}" >/dev/null 2>&1
  echo "runner: $COMPLETED completed / $PROCESSED processed"
  exit 1
}
trap _on_interrupt INT TERM

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
  safe_capture BD_UNAVAILABLE "" -- bd update "$CANDIDATE_ID" --status=in_progress >/dev/null
  CURRENT_TASK_ID="$CANDIDATE_ID"
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

  claude -p "$prompt" \
    --output-format stream-json \
    --verbose \
    --model "$DEFAULT_MODEL" \
    "${EXTRA_CLAUDE_FLAGS[@]+"${EXTRA_CLAUDE_FLAGS[@]}"}" \
    "${PERMISSION_FLAGS[@]+"${PERMISSION_FLAGS[@]}"}" \
    >/dev/null 2>&1 &
  CLAUDE_PID=$!

  # §2.5 DURING-task cadence. We poll on a fine RUNNER_TICK and act on the
  # CONTROL_POLL_INTERVAL / HEARTBEAT_INTERVAL boundaries. We DO NOT evaluate
  # "stuck" (idle watchdog is T2.3) and we DO NOT kill mid-task: a stop is
  # OBSERVED here (≤ CONTROL_POLL_INTERVAL so the Board can render `stopping…`
  # immediately) but only ACTED ON after the task completes (§2.5 "stop after
  # current task"). Heartbeat (job 3) renews the held lease (§4.4 fenced).
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
