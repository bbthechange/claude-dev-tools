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

# ── L2 (claude-tools-1tu) gate-policy chokepoint ─────────────────────────────
# The runner consults gate-policy.sh on every candidate pickup (st_reconcile).
# A `gate-human:*` verdict means: do NOT auto-pick this bead up — surface it
# to Brian (set status=blocked + add `human` label, append a structured note)
# and move on. See agents/gate-policy.md for the table + the 3 GATE points.
# Env-overridable so the test harness can point at a fake on PATH.
GATE_POLICY_SH="${GATE_POLICY_SH:-$RUNNER_DIR/gate-policy.sh}"

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
# claude-tools-idg — Task subagents are IN-API constructs inside the claude
# process, not OS-level children: a parent waiting on a slow subagent shows
# zero stream growth AND can be CPU-idle (the API request is sitting on the
# Anthropic side). Tree-progress alone can't tell "stuck" from "patiently
# waiting on a 30-minute subagent." The stream itself carries the signal —
# task_notification (start) and task_updated (terminal) events with task_id —
# so the watchdog tracks in-flight subagents and STRETCHES (not pauses) the
# threshold while ≥1 is in-flight. Stretching keeps the kill backstop for
# genuine deadlocks (the D5 hung-bg-Bash case: in-flight but truly stuck)
# while protecting legitimate long subagents (R1's 30-min SIGSTOP probes).
IDLE_TIMEOUT_INFLIGHT_MULT="${IDLE_TIMEOUT_INFLIGHT_MULT:-6}"  # multiplier while ≥1 Task subagent is in-flight

# ── Minimal runtime config (skeleton). The full BC-37 config seam — sourced
#    allowlist, --yolo, runner_setup/runner_cleanup hooks — is NOT T2.1's owned
#    surface; the skeleton keeps a minimal default + an optional project source
#    so it is runnable end-to-end. Richer policy lands with T2 integration. ────
DEFAULT_MODEL="${DEFAULT_MODEL:-opus[1m]}"
PERMISSION_FLAGS=(--permission-mode acceptEdits)
EXTRA_CLAUDE_FLAGS=(--no-chrome)
# ── §7.6 GUARDRAIL (AD3.5; T2.5, claude-tools-kqn) ────────────────────────────
# Workers run with the interactive human-in-the-loop tools removed from the
# advertised set, and KEEP `--output-format stream-json` (line 940; `text`
# hides `result.permission_denials[]` and the `"Entered plan mode."`
# tool_result — the §7.2(b) backstop NEEDS the structured stream). The
# guardrail is DEFENSE-IN-DEPTH, NOT a substitute: a bare prohibition is
# empirically insufficient (research Q5) and EnterPlanMode is a version-pinned
# silent-no-op (O-1 / claude-tools-0vt, GREEN on claude 2.1.142). Both the
# §7.2(a) instructed primary path (the worker prompt) AND the §7.2(b) runner
# backstop remain required — neither replaces this, this replaces neither.
GUARDRAIL_FLAGS=(--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode)
PROJECT_REF="${PROJECT_REF:-$(basename "$(pwd)")}"     # §4.2 project_ref (controllable unit); Coordinator owns desired-state
STOP_FILE="${STOP_FILE:-.stop-beads}"

# ── T2.2 (claude-tools-8nn) — §7.1/§7.5/§8.1 classification constants ──────────
# Per-class retry asymmetry (BC-13) + the consecutive-failure circuit breaker
# (BC-14) are env-overridable (the conformance harness sets MAX_RETRIES=2 /
# MAX_CONSECUTIVE_FAILURES=3); the literal defaults match v1.
MAX_RETRIES="${MAX_RETRIES:-2}"                         # same-task retry budget before analysis-child (BC-13)
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}" # distinct-task generic-failure breaker (BC-14 / §8.1 exit 2)
# §8.1 (FROZEN): WORKER_STUCK_EXIT(7) is the *worker* (`claude -p`) sentinel —
# an internal STUCK detection INPUT, chosen NOT to collide with the BC-21 runner
# codes {0..4}. This child CONSUMES it into the §7.1 STUCK slot; it does NOT
# add a runner exit code (§7.5) and T2.5 owns its PRODUCTION (the worker prompt).
WORKER_STUCK_EXIT="${WORKER_STUCK_EXIT:-7}"
# claude-tools-ntn — bounded exponential INTER-RETRY backoff. The v1 SCAR
# (2026-05-16 incident): same-task SERVER_ERROR/UNKNOWN_FAILURE retries fire
# back-to-back with ZERO delay, so a brief platform API outage exhausts the
# whole MAX_RETRIES budget in seconds and spuriously marks healthy tasks
# exceeded_max_retries. The delay is base*2^(n-1) (n = FAIL_COUNT) hard-capped
# at MAX; env-overridable (the ntn conformance rig drives it small/fast). This
# only SPACES same-task attempts — §7.5/§8.1 are unchanged (SERVER_ERROR /
# UNKNOWN_FAILURE still consume the budget and still advance the distinct-task
# breaker; RATE_LIMIT stays §7.5-invisible to this gate and is untouched).
RETRY_BACKOFF_BASE="${RETRY_BACKOFF_BASE:-5}"          # 1st inter-retry delay (s); doubles per attempt
RETRY_BACKOFF_MAX="${RETRY_BACKOFF_MAX:-60}"           # hard cap on the exponential inter-retry delay (s)
# Post-mortem artifacts + incident ledger. The BC-29 per-iteration basename
# scheme (`<TASK_ID>-<ITER_TS>`) and the LOG_DIR lifecycle are T2.4/T2.3's owned
# surface (st_run_task already creates this dir + its BC-27 self-gitignore);
# here LOG_DIR is only the anchor for the §8.2 incident ledger + selective
# stream preservation this child's classification drives.
LOG_DIR="${LOG_DIR:-.beads/runner-logs}"
INCIDENTS_LOG="$LOG_DIR/incidents.log"

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
CLAUDE_EXIT=0            # T2.2: the worker's exit code (NOT trusted as a verdict — BC-09 — but the §7.1 STUCK slot keys on WORKER_STUCK_EXIT and the marker scan is exit-code-guarded as in v1)
WATCHDOG_PID=""          # T2.3 BC-22 watchdog subshell (one per task; in-band-reaped)
STREAM_FILE=""           # T2.3: worker stream-json capture (watchdog output-progress signal)
SIGNAL_FILE=""           # T2.3 BC-40 IPC seam: watchdog appends WATCHDOG_KILL=1; T2.2 classify consumes
PROC_SNAPSHOT=""         # T2.3 BC-22 snapshot-before-signal artifact (T2.2 keeps it ONLY for WATCHDOG_KILL)
STOP_REQUESTED=""        # set when stop/desired∈{stopped} OBSERVED (§2.5); honored AFTER current task
COMPLETED=0
PROCESSED=0
EXIT_CODE=0              # BC-21 process exit code (§8.1)
TERMINAL_CLASS="CLEAN"   # §8.2 terminal-reason class for job 6
# ── T2.2 classification/retry/breaker state (the ONLY such state — v1 scattered
#    these across LAST_FAILED_ID / FAIL_COUNT / CONSECUTIVE_FAILURES globals).
CLASSIFICATION=""        # §7.1 first-match class for the just-finished task
PRESERVED_LOG=""         # selective stream-preservation path (or "-")
LAST_FAILED_ID=""        # BC-13: the task the per-task retry counter is tracking
FAIL_COUNT=0             # BC-13: same-task consecutive failures (→ analysis at MAX_RETRIES)
CONSECUTIVE_FAILURES=0   # BC-14: DISTINCT-task generic failures (→ §8.1 breaker exit 2)
INCIDENTS=()             # human-readable incident lines for the end-of-run summary

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

# ── BC-38 / §7.2(a) — the worker prompt (T2.5, claude-tools-kqn) ──────────────
# Re-implements v1's prompt INTENT idiomatically (scaffolding not transcribed):
#   • states the run is NON-INTERACTIVE and explicitly forbids EnterPlanMode /
#     ExitPlanMode / AskUserQuestion ("no human to approve/answer") — "just
#     execute directly"; this is the instructed prohibition the §7.6
#     `--disallowedTools` guardrail backs (defense-in-depth, not either/or);
#   • the §7.2(a) PRIMARY worker-driven STUCK path: on a fork it must NOT
#     resolve, the worker MUST, IN ORDER — `bd update <id> --status=blocked`
#     → write the structured ask (TL;DR · ask · options · recommendation+why ·
#     reversible) into the bead (`--append-notes`/`--design`) → `bd human <id>`
#     → exit WORKER_STUCK_EXIT — never an interactive tool. That structured ask
#     is the raw material the §5 dossier builder consumes;
#   • a mandatory honest debrief via `bd update <id> --append-notes=` BEFORE
#     `bd close <id>`; follow the task description exactly.
# BC-38: id/title/description are substituted by LITERAL string replacement
# (the BEADS_* tokens), so a title/desc that itself contains a token-like
# substring is data, never re-expanded, and no BEADS_* token survives into the
# emitted prompt. The `beads issue <ID>:` line is also the worker's bead-id
# anchor (the fake/real worker keys off it) — keep it first.
build_worker_prompt() {
  local id="$1" title="$2" desc="$3" prompt
  read -r -d '' prompt <<'PROMPT_DELIM' || true
You are working on beads issue BEADS_ID: "BEADS_TITLE"

Task description:
BEADS_DESC

IMPORTANT: You are running non-interactively. Do NOT use EnterPlanMode or ExitPlanMode -- there is no human to approve plans. Do NOT use AskUserQuestion -- there is no human to answer. Just execute the work directly.

Follow the instructions in the task description above exactly. The description contains the full workflow for this task type.

If you reach a genuine fork you must NOT resolve yourself -- an irreversible or judgement-call decision the task description does not settle, where guessing could be wrong and costly -- do NOT pick for the human, do NOT use an interactive tool, and do NOT stop silently. Instead, in THIS exact order:
  1. bd update BEADS_ID --status=blocked
  2. Write the structured ask into the bead:
       bd update BEADS_ID --append-notes="<the ask>"   (or --design="...")
     It MUST clearly contain, labelled: TL;DR; the ask (the single decision needed); the options; your recommendation and why; and how reversible each option is.
  3. bd label add BEADS_ID human
  4. Exit with status code BEADS_STUCK_EXIT and do NOT close the issue.
This is the only correct way to surface a human decision.

Before closing the issue, add a brief debrief note summarizing how it went:
  bd update BEADS_ID --append-notes="<your debrief>"
Include: what you did, any difficulties or unexpected behavior, how long things took if notable, anything you were not sure about, and any follow-up suggestions. Be honest -- this is for the human reviewing your work later.

If your work moves this bead to the next lifecycle stage (idea | ux | design | impl | docs | tests | done -- see beads-runner/agents/lifecycle.md), record the transition with the one sanctioned op so the spine stays clean:
  bd-stage set BEADS_ID <next-stage>
This is the only correct way to change stage -- it removes any prior stage:* label before adding the new one, so the "exactly one stage per bead" invariant cannot drift. Do NOT bd label add stage:* directly.

When you have completed all steps, close the issue: bd close BEADS_ID
PROMPT_DELIM
  # Literal replacement, id/title/stuck-exit BEFORE desc so free-form desc text
  # can never shadow a still-unsubstituted earlier token (v1 order + the
  # WORKER_STUCK_EXIT sentinel, kept in sync with the §8.1 constant).
  prompt="${prompt//BEADS_ID/$id}"
  prompt="${prompt//BEADS_TITLE/$title}"
  prompt="${prompt//BEADS_STUCK_EXIT/$WORKER_STUCK_EXIT}"
  prompt="${prompt//BEADS_DESC/$desc}"
  # v1 PROMPT_EXTRA parity: project-specific instructions appended if configured.
  if [[ -n "${PROMPT_EXTRA:-}" ]]; then
    prompt="$prompt

$PROMPT_EXTRA"
  fi
  printf '%s\n' "$prompt"
}

# ── §7.3 / S-2 (AD3.3; T2.5) — a fired backstop MUST itself drive the bead ────
# Runs for the STUCK class regardless of WHICH §7.2 trigger fired, because it
# is IDEMPOTENT: on the §7.2(a) primary path the instructed worker already did
# status=blocked + the structured ask + `bd human`, so this is a harmless
# re-assert; on a fired §7.2(b) backstop the worker SLIPPED and the bead is
# NOT driven, so this is the load-bearing fork-must-not-rot drive (UX
# principle 7). §7.3/S-2: the runner does NOT own blocked-for-human truth — it
# writes the bead as an IMMEDIATE-honesty work-plane PROJECTION and hands the
# §2 store the `worker_stuck` Dossier KEYED ON task_ref. "One fork ⇒ one
# Dossier" is the Coordinator's §7.4 dossier-level latch (real in T5 /
# claude-tools-40c; the §2 stub here is a no-op) — this child makes only the
# KEYED CALL and never reimplements that dedup in the runner.
_drive_blocked_for_human() {
  local tref="$1" rec
  # Work-plane projection — best-effort + idempotent (bd is fail-open here).
  safe_capture BD_UNAVAILABLE "" -- bd update "$tref" --status=blocked >/dev/null
  # `bd human <id>` no-ops in this bd build (human = command group; the
  # human-needed signal is the `human` LABEL — `bd human list` / the wwl §7.2
  # PRIMARY detector read the label). Set it directly (I5-rehearsal divergence).
  safe_capture BD_UNAVAILABLE "" -- bd label add "$tref" human >/dev/null
  # Belt-and-suspenders observable: also fire the legacy `bd human <id>` form.
  # In real bd this prints the help screen (suppressed) and rc 0 — harmless. In
  # the conformance harness (and in any older watcher keying on the literal
  # `bd human <id>` invocation) this is the observable that proves §7.3 fired
  # on the BACKSTOP path, where the worker did NOT itself raise the signal (the
  # PRIMARY path's compliant worker raises it; the backstop slipped past the
  # guardrail and never did, so the runner-side drive is load-bearing here).
  bd human "$tref" >/dev/null 2>&1 || true
  # Control-plane: a contract-shaped (§4.1) worker_stuck Dossier record keyed
  # on task_ref (§0.4 dossier-level double-trigger dedup key). The Coordinator
  # owns the create-once dedup + the control→work reconcile (S-2) — stubbed
  # no-op here; the keyed call is what this child owns.
  rec="$(jq -cn --arg tr "$tref" --arg p "$PRINCIPAL" \
    '{schema_version:1,trigger:"worker_stuck",bead_ref:$tr,task_ref:$tr,principal:$p}' \
    2>/dev/null)" || rec=""
  if [[ -n "$rec" ]]; then
    co_store_put dossier "$rec" >/dev/null 2>&1 \
      || degrade DOSSIER_STORE "co_store_put dossier failed for $tref — §7.3 bead drive already done (fork will not rot); the Coordinator reconcile (S-2) is the truth"
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ T2.2 (claude-tools-8nn) — §7.1 classification precedence + per-class       ║
# ║ retry asymmetry (§7.5/BC-13) + the §8.1/BC-14 consecutive-failure breaker. ║
# ║ This is THE highest-risk-when-silent runner logic: a misordered chain     ║
# ║ retries a deterministic overflow forever, or trips the breaker on         ║
# ║ legitimate human-decision tasks and stops the fleet. The v1 logic         ║
# ║ (run-beads-tasks.sh classify_failure + the loop-top retry gate + the      ║
# ║ per-class dispatch + the breaker) is reimplemented here idiomatically and ║
# ║ behavior-faithfully, with the §7.1 STUCK_NEEDS_HUMAN slot INSERTED and    ║
# ║ the §7.5 breaker/retry exemption added. The precedence order and the      ║
# ║ BC-21 §8.1 exit-code table are FROZEN — a needed change is a §11 BLOCKING  ║
# ║ escalation (reopen claude-tools-65z, re-freeze), NEVER a local reorder.   ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ── Stream-json → typed signal markers (BC-39/40 re-implemented) ──────────────
# v1 ran a `tail -f STREAM_FILE | while read` PARSER subshell concurrently with
# the worker (the BC-39/40 leak: the `tail -f` reparents to PID 1 when the
# parser dies, and the tempfile-as-IPC needs a `sleep 1` flush). The rewrite has
# NO `tail -f` at all: the worker's stdout+stderr are already merged into ONE
# file (st_run_task `> … 2>&1`) and the capture-then-classify happens-before is
# STRUCTURAL — st_run_task `wait`s the worker, reaps+joins the watchdog, THEN
# st_post_task calls this. So the parse is a single deterministic post-hoc pass
# over the COMPLETE merged stream, not a racing tail. It only ACCUMULATES typed
# markers into SIGNAL_FILE (the watchdog already appended WATCHDOG_KILL=1 there
# if it fired — BC-22/BC-40 IPC seam); classify_failure (below) is the sole
# place precedence is applied (BC-10: the order IS the logic).
# BC-42: the WHOLE-file being unreadable is one typed `degrade:` line, never a
# crash; a single non-JSON line yields an empty `.type` and is skipped — that
# is correct (model output legitimately interleaves prose), not a blanket
# `2>/dev/null` swallow of a real signal.
parse_stream_signals() {
  local stream="$1" sig="$2" line typ err est sr ie res aes
  [[ -n "$stream" && -f "$stream" ]] || return 0
  if [[ ! -r "$stream" ]]; then
    degrade STREAM_UNREADABLE "$stream unreadable — classification proceeds on exit-code + watchdog markers only"
    return 0
  fi
  : >> "$sig" 2>/dev/null || true
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    typ="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)" || typ=""
    case "$typ" in
      system)
        [[ "$(printf '%s' "$line" | jq -r '.subtype // empty' 2>/dev/null)" == "api_retry" ]] || continue
        err="$(printf '%s' "$line" | jq -r '.error // empty'        2>/dev/null)"
        est="$(printf '%s' "$line" | jq -r '.error_status // empty' 2>/dev/null)"
        case "$err" in
          rate_limit)            echo "RATE_LIMIT=${est:-429}"   >> "$sig" ;;
          authentication_failed) echo "AUTH_FAILURE=${est:-401}" >> "$sig" ;;
          billing_error)         echo "BILLING_ERROR=1"          >> "$sig" ;;
          server_error)          echo "SERVER_ERROR=${est:-500}" >> "$sig" ;;
          max_output_tokens)     echo "MAX_OUTPUT_TOKENS=1"      >> "$sig" ;;
        esac
        ;;
      result)
        ie="$(printf '%s' "$line"  | jq -r '.is_error // false' 2>/dev/null)"
        sr="$(printf '%s' "$line"  | jq -r '.stop_reason // empty' 2>/dev/null)"
        res="$(printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null)"
        echo "RESULT_IS_ERROR=$ie" >> "$sig"
        [[ -n "$sr" ]] && echo "RESULT_STOP_REASON=$sr" >> "$sig"
        # CONTEXT_OVERFLOW ("Prompt is too long") arrives as an ERRORED result
        # with stop_reason=stop_sequence — it does NOT match the max_tokens /
        # length stop reasons, so without this it falls through to
        # UNKNOWN_FAILURE and is pointlessly retried (each retry re-overflows
        # at the same point). is_error-GUARDED (BC-11): a benign summary that
        # merely quotes the phrase is NOT an overflow.
        if [[ "$ie" == "true" ]] && \
           printf '%s' "$res" | grep -qiE 'prompt is too long|context_length_exceeded' 2>/dev/null; then
          echo "CONTEXT_OVERFLOW=1" >> "$sig"
        fi
        # claude-tools-ntn: when the SDK's OWN retries are EXHAUSTED the
        # terminal failure arrives as an ERRORED result carrying
        # api_error_status 5xx (and/or result text "API Error: 5xx ..."),
        # with NO preceding system/api_retry event — so the §7.1 SERVER_ERROR
        # slot's only other producer (the api_retry branch above) never fires
        # and a pure platform 500 wrongly falls through to UNKNOWN_FAILURE
        # (then gets retried back-to-back, burning the budget — the
        # 2026-05-16 outage). This is the MISSING second SERVER_ERROR trigger.
        # It populates the EXISTING frozen §7.1 slot — classify_failure is
        # unchanged: no slot is added, removed, or reordered (§7.2 already
        # anticipates two independent triggers), so this is NOT a §11/§0
        # escalation. is_error-GUARDED with the same discipline as the
        # CONTEXT_OVERFLOW rule above (BC-11): a benign result that merely
        # quotes "API Error: 5xx", or a tool that returns an api_error_status,
        # is NOT a worker server failure and MUST NOT be manufactured into
        # SERVER_ERROR (protects BC-25 / BC-11).
        aes="$(printf '%s' "$line" | jq -r '.api_error_status // empty' 2>/dev/null)"
        if [[ "$ie" == "true" ]] && \
           { { [[ "$aes" =~ ^[0-9]+$ ]] && [[ "$aes" -ge 500 && "$aes" -le 599 ]]; } || \
             printf '%s' "$res" | grep -qE 'API Error: 5[0-9][0-9]' 2>/dev/null; }; then
          echo "SERVER_ERROR=${aes:-5xx}" >> "$sig"
        fi
        # §7.2(b) BACKSTOP A (AD3.3, zero model trust): the worker slipped
        # past the §7.6 guardrail and the FINAL result carries a
        # permission_denial for AskUserQuestion/ExitPlanMode while FALSELY
        # succeeding (exit-0/is_error:false, bead not closed). Emitting the
        # STUCK marker lets classify_failure (§7.1) slot STUCK ABOVE the
        # exit-0 TASK_NOT_CLOSED path — a real human-ask MUST NOT be masked as
        # "agent forgot to close". Predicate is byte-aligned with the T5
        # recognizer (sr_scan_backstop): precise, no false-positive on a
        # benign result. NOT the classifier — only the typed input it reads.
        if printf '%s' "$line" | jq -e '(.permission_denials != null) and
              (any(.permission_denials[]?;
                   (.tool=="AskUserQuestion") or (.tool=="ExitPlanMode")
                or (.tool_name=="AskUserQuestion") or (.tool_name=="ExitPlanMode")))' \
             >/dev/null 2>&1; then
          echo "STUCK_NEEDS_HUMAN=permission_denials" >> "$sig"
        fi
        ;;
      tool_result)
        # §7.2(b) BACKSTOP B (AD3.3): the EnterPlanMode silent-no-op residual
        # gap (O-1 / claude-tools-0vt) — claude exits 0/success with NO
        # permission_denials, but a "Entered plan mode." tool_result is in the
        # stream. `--disallowedTools` is the GUARDRAIL; THIS scan is the
        # BACKSTOP (defense-in-depth — the guardrail alone is version-pinned
        # and undocumented). Match is intentionally precise (the exact
        # residual string), no false-positive on benign tool_result errors.
        if printf '%s' "$line" | jq -e \
              '((.content // "") | tostring | test("Entered plan mode\\."))' \
             >/dev/null 2>&1; then
          echo "STUCK_NEEDS_HUMAN=entered_plan_mode" >> "$sig"
        fi
        ;;
    esac
  done < "$stream"
  return 0
}

# ── §7.1 FROZEN classification precedence (BC-10's order, STUCK inserted) ──────
# classify_failure <signal_file> <task_id> <exit_code>  → prints ONE class.
#
#   exit 0 : truth is `bd` status, NOT the OS code (BC-09).
#            closed                       → SUCCESS
#            bd-show OK but status empty  → SUCCESS, fail-OPEN + explicit
#                                           stderr note (BC-09: an unverifiable
#                                           status is noise, a phantom failure
#                                           is the SCAR)
#            bd-show command FAILED       → DEGRADED (BC-42: an infra blip is
#                                           NOT a verdict — caller must NOT
#                                           mutate work state on a hiccup)
#            open + STUCK marker          → STUCK_NEEDS_HUMAN  (§7.1 slots STUCK
#                                           ABOVE the exit-0 TASK_NOT_CLOSED
#                                           path — a real human-ask MUST NOT be
#                                           masked as "agent forgot to close")
#            open, no marker              → TASK_NOT_CLOSED
#   exit≠0 : first match in the FROZEN order over the ACCUMULATED markers —
#            AUTH_FAILURE → BILLING_ERROR → STUCK_NEEDS_HUMAN → CONTEXT_OVERFLOW
#            → MAX_OUTPUT_TOKENS → SERVER_ERROR → WATCHDOG_KILL → RATE_LIMIT →
#            UNKNOWN_FAILURE. The two fleet-fatal classes win even when a
#            transient co-occurs (BC-10); STUCK slots immediately below them
#            and above every per-task content class (AD3.2). The STUCK input is
#            EITHER the worker sentinel exit WORKER_STUCK_EXIT (§7.2 primary,
#            this child's literal slot) OR a `STUCK_NEEDS_HUMAN=` marker (the
#            §7.2 backstop, PRODUCED by T2.5 — consumed here).
classify_failure() {
  local sig="$1" id="$2" ec="$3" raw status
  local stuck=0
  [[ -f "$sig" ]] && grep -q '^STUCK_NEEDS_HUMAN=' "$sig" 2>/dev/null && stuck=1
  [[ "$ec" == "$WORKER_STUCK_EXIT" ]] && stuck=1

  if [[ "$ec" -eq 0 ]]; then
    raw="$(safe_capture BD_UNAVAILABLE "__DEGRADED__" -- bd show "$id" --json)"
    if [[ "$raw" == "__DEGRADED__" ]]; then echo "DEGRADED"; return; fi
    if ! status="$(printf '%s' "$raw" | jq -r '.[0].status // empty' 2>/dev/null)"; then
      # bd-show returned but its JSON is unparseable: that is an infra/parse
      # blip, NOT a verdict (BC-42) — typed DEGRADED, never a silent fold.
      degrade BD_PARSE "bd show $id JSON unparseable — typed DEGRADED, not a verdict"
      echo "DEGRADED"; return
    fi
    if [[ "$status" == "closed" ]]; then echo "SUCCESS"; return; fi
    if [[ -z "$status" ]]; then
      # bd-show SUCCEEDED but yielded no status (empty array): BC-09 fail-OPEN
      # to SUCCESS with the explicit stderr note (distinct from a bd-show
      # COMMAND failure above, which is DEGRADED — the BC-42 boundary).
      echo "  (Could not verify task status — assuming success)" >&2
      echo "SUCCESS"; return
    fi
    # exit-0, bead still open: STUCK (backstop) slots ABOVE TASK_NOT_CLOSED.
    [[ $stuck -eq 1 ]] && { echo "STUCK_NEEDS_HUMAN"; return; }
    echo "TASK_NOT_CLOSED"; return
  fi

  # Non-zero exit — ordered first-match over accumulated markers (BC-10).
  if [[ -f "$sig" ]]; then
    grep -q '^AUTH_FAILURE='   "$sig" 2>/dev/null && { echo "AUTH_FAILURE";   return; }
    grep -q '^BILLING_ERROR='  "$sig" 2>/dev/null && { echo "BILLING_ERROR";  return; }
  fi
  [[ $stuck -eq 1 ]] && { echo "STUCK_NEEDS_HUMAN"; return; }
  if [[ -f "$sig" ]]; then
    # CONTEXT_OVERFLOW is the most decisive terminal (the session physically
    # cannot continue; retrying the same task on the same model re-overflows
    # deterministically) — checked BEFORE max_output_tokens (same family).
    grep -q '^CONTEXT_OVERFLOW='            "$sig" 2>/dev/null && { echo "CONTEXT_OVERFLOW";  return; }
    grep -q '^MAX_OUTPUT_TOKENS='           "$sig" 2>/dev/null && { echo "MAX_OUTPUT_TOKENS"; return; }
    grep -q '^RESULT_STOP_REASON=max_tokens' "$sig" 2>/dev/null && { echo "MAX_OUTPUT_TOKENS"; return; }
    grep -q '^RESULT_STOP_REASON=length'     "$sig" 2>/dev/null && { echo "MAX_OUTPUT_TOKENS"; return; }
    grep -q '^SERVER_ERROR='                "$sig" 2>/dev/null && { echo "SERVER_ERROR";      return; }
    grep -q '^WATCHDOG_KILL='               "$sig" 2>/dev/null && { echo "WATCHDOG_KILL";     return; }
    grep -q '^RATE_LIMIT='                  "$sig" 2>/dev/null && { echo "RATE_LIMIT";        return; }
  fi
  echo "UNKNOWN_FAILURE"
}

# ── claude-tools-ntn — bounded exponential inter-retry backoff ───────────────
# $1 = 1-based attempt index (the per-task FAIL_COUNT). Emits ONE greppable
# line then sleeps base*2^(n-1) capped at MAX. Greppable by design: the ntn
# conformance rig asserts a strictly-growing delay sequence WITHOUT a
# wall-clock observer. Pure delay — it mutates no classification, no retry
# budget, no breaker counter (§7.5/§8.1 invariants untouched); it only spaces
# consecutive same-task attempts so a brief outage cannot burn the whole
# budget back-to-back.
_retry_backoff() {
  local n="${1:-1}" base="$RETRY_BACKOFF_BASE" max="$RETRY_BACKOFF_MAX" d
  [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] || n=1
  d=$(( base << (n - 1) ))                       # base * 2^(n-1)
  { [[ "$d" -gt "$max" ]] || [[ "$d" -lt 0 ]]; } && d="$max"   # cap + huge-n overflow guard
  echo "  runner: retry backoff ${d}s before attempt $((n + 1)) (transient failure — claude-tools-ntn)"
  sleep "$d"
}

# ── Analysis child (BC-13/BC-17): a fresh agent investigates a failure that
#    must NOT be blindly retried; it BLOCKS the failed task so the runner does
#    not re-pick it until the analysis closes. The BC-17 self-guard (an
#    analysis task never spawns a grandchild) prevents infinite chains. ────────
create_analysis_task() {
  local task_id="$1" task_title="$2" reason="$3"
  local labels
  labels="$(safe_capture BD_UNAVAILABLE "[]" -- bd label list "$task_id" --json)"
  if printf '%s' "$labels" | jq -e '.[] | select(. == "analysis")' >/dev/null 2>&1; then
    echo "  (Skipping analysis task creation — this is already an analysis task)"
    return 0
  fi
  local analysis_desc
  analysis_desc="Task $task_id (\"$task_title\") failed with reason: $reason.

Investigate what went wrong and determine next steps:
- Check the state of any code changes the previous agent made (git log, git diff)
- Determine if the task needs to be split into smaller sub-tasks
- Determine if a design task should be created first to plan the approach
- Determine if the agent just needs a fresh context window to retry
- Create any necessary follow-up beads tasks with appropriate dependencies

Before closing, ensure $task_id is blocked by any new tasks you create:
  bd dep add $task_id <new-task-id>"
  local create_output analysis_id
  create_output="$(safe_capture BD_UNAVAILABLE "" -- bd create \
    --title "Analyze failure: $task_title" -d "$analysis_desc" -p 1 \
    --labels "model:opus,analysis")"
  if [[ -z "$create_output" ]]; then
    echo "  WARNING: Failed to create analysis task"; return 1
  fi
  analysis_id="$(printf '%s' "$create_output" | sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1)"
  if [[ -z "$analysis_id" ]]; then
    echo "  WARNING: Could not parse analysis task ID from: $create_output"; return 1
  fi
  safe_capture BD_UNAVAILABLE "" -- bd dep add "$task_id" "$analysis_id" >/dev/null
  echo "  Created analysis task: $analysis_id (blocks $task_id)"
  safe_capture BD_UNAVAILABLE "" -- bd update "$task_id" \
    --append-notes="Failed ($reason). Analysis task: $analysis_id" >/dev/null
}

# ── §8.2 visibility — incident ledger + uniform greppable bead note + selective
#    post-mortem stream preservation. record_incident is called for EVERY
#    non-success class (incl. exceeded_max_retries) so a silently-retried
#    failure that later succeeds is never invisible. ────────────────────────────
record_incident() {
  local task_id="$1" classification="$2" log_path="${3:--}" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$ts" "$task_id" "$classification" "$log_path" \
    >> "$INCIDENTS_LOG" 2>/dev/null || true
  INCIDENTS+=("$ts  $task_id  $classification  $log_path")
}
append_runner_note() {
  local task_id="$1" classification="$2" log_path="${3:--}" ts msg
  ts="$(date -u +%H:%M:%SZ)"
  msg="Runner: $classification at $ts"
  if [[ "$log_path" != "-" ]]; then msg="$msg — log: $log_path"
  else msg="$msg — no stream preserved"; fi
  safe_capture BD_UNAVAILABLE "" -- bd update "$task_id" --append-notes="$msg" >/dev/null
}
preserve_stream() {
  local src="$1" dest_base="$2" dest="$LOG_DIR/${2}.jsonl"
  [[ -n "$src" && -f "$src" ]] || { echo ""; return; }
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if cp "$src" "$dest" 2>/dev/null; then echo "$dest"; else echo ""; fi
}
print_incidents_summary() {
  [[ ${#INCIDENTS[@]} -eq 0 ]] && return 0
  echo ""
  echo "Incidents this run (${#INCIDENTS[@]}):"
  local line
  for line in "${INCIDENTS[@]}"; do echo "  $line"; done
  echo "Full log: $INCIDENTS_LOG"
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

# _inflight_tasks <stream_file> — count Task subagents currently in-flight by
# replaying task_notification (start) and task_updated (state change) events
# from the stream. claude-tools-idg: a Task subagent is an IN-API construct,
# not an OS child — neither stream growth nor tree CPU reliably reflects it
# while the parent waits on the model. The stream itself carries task_id +
# status events; we reduce them to a live set. The regex picks up both
# top-level "status":"..." (task_notification) and nested "patch":{"status":
# "..."} (task_updated) — the substring `"status":"<val>"` matches either.
# Robust to multi-task scenarios; an unmatched terminal silently no-ops.
_inflight_tasks() {
  local stream="$1"
  [[ -n "$stream" && -r "$stream" ]] || { echo 0; return 0; }
  grep -E '"(task_notification|task_updated)"' "$stream" 2>/dev/null | awk '
    {
      tid=""; st=""
      if (match($0, /"task_id":"[^"]+"/)) tid = substr($0, RSTART+11, RLENGTH-12)
      if (match($0, /"status":"[^"]+"/)) st  = substr($0, RSTART+10, RLENGTH-11)
      if (tid == "") next
      if (st == "in_progress") inflight[tid] = 1
      else if (st == "completed" || st == "stopped" || st == "killed" \
            || st == "failed"    || st == "cancelled") delete inflight[tid]
    }
    END { n=0; for (t in inflight) n++; print n }'
}

# _watchdog_loop <claude_pid> <stream_file> <signal_file> <proc_snapshot>
# Polls every WATCHDOG_POLL while the worker is alive. Liveness = progress
# since the last poll, where progress is (stream-file GREW) OR (tree CPU
# ADVANCED). idle = seconds since the last observed progress (init at spawn,
# BC-22). Soft-warn at WATCHDOG_SOFT_WARN; KILL at IDLE_TIMEOUT with
# snapshot-BEFORE-signal then staged SIGINT→(≤10×1s)→SIGKILL.
# claude-tools-idg: when ≥1 Task subagent is in-flight (counted from the
# stream's task_notification/task_updated events) the effective kill
# threshold STRETCHES to IDLE_TIMEOUT × IDLE_TIMEOUT_INFLIGHT_MULT — the kill
# is preserved (a genuinely deadlocked bg-Bash that registers as in-flight
# still dies eventually), only deferred for legitimately-slow subagents.
_watchdog_loop() {
  local pid="$1" stream="$2" sig="$3" snap="$4"
  local now last_progress prev_bytes prev_cpu bytes cpu idle warned=0
  local inflight effective_timeout
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
    # Effective threshold: stretch (don't pause) while ≥1 subagent is in-flight.
    inflight="$(_inflight_tasks "$stream")"; inflight="${inflight:-0}"
    if [[ "$inflight" -gt 0 ]]; then
      effective_timeout=$(( IDLE_TIMEOUT * IDLE_TIMEOUT_INFLIGHT_MULT ))
    else
      effective_timeout="$IDLE_TIMEOUT"
    fi
    if [[ "$idle" -ge "$effective_timeout" ]]; then
      echo "  Killing after ${idle}s idle — no CPU or output progress in the agent+child-process tree (likely stuck; in-flight subagents=$inflight, threshold=${effective_timeout}s)"
      # BC-22/BC-40: emit the marker for the classifier (T2.2 owns precedence).
      echo "WATCHDOG_KILL=1" >> "$sig"
      # Snapshot the WHOLE stuck tree BEFORE any signal — lsof on a dying
      # process returns nothing useful, so order is load-bearing (BC-22 SCAR).
      {
        echo "=== ps (tree, idle ${idle}s, IDLE_TIMEOUT=${IDLE_TIMEOUT}, inflight_subagents=${inflight}, effective_threshold=${effective_timeout}s, signal=child-tree-progress) ==="
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

# ── L2 (claude-tools-1tu) — gate-human surface ───────────────────────────────
# When the gate-policy verdict on a candidate is `gate-human:<reason>`, we do
# NOT acquire a lease or set in_progress. We mirror the existing _drive_blocked_
# for_human shape used by §7.3 STUCK_NEEDS_HUMAN so the Coordinator's snapshot
# projection / Inbox surface reuses the same `status=blocked + human label`
# channel — one routing seam, two producers. For the collaborative-stage
# preset (the only v1 enforced gate; see agents/gate-policy.md) the note
# reads "READY_TO_PAIR" so the Inbox can render the canonical
# "ready to pair on <title>" row (UX mocks). The bead does NOT re-appear in
# `bd ready` (status=blocked filters it out), so the runner moves cleanly to
# the next candidate without burning a retry-counter slot.
_surface_gate_human() {
  local bead="$1" title="$2" verdict="$3"
  local reason="${verdict#gate-human:}" ts note
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$reason" in
    collaborative-stage)
      note="READY_TO_PAIR
Reason: preset:collaborative-stage — Brian asked to be IN this stage with the agent
Title: $title
Surfaced at: $ts (runner gate-policy / L2 claude-tools-1tu)" ;;
    bd-unavailable)
      note="GATE_HUMAN
Reason: bd label list failed during gate-policy consultation — fail-CLOSED
Title: $title
Surfaced at: $ts (runner gate-policy / L2 claude-tools-1tu)" ;;
    unknown-preset)
      note="GATE_HUMAN
Reason: preset label is not in the v1 closed enum — fail-CLOSED so an enricher typo cannot quietly skip Brian
Title: $title
Surfaced at: $ts (runner gate-policy / L2 claude-tools-1tu)" ;;
    *)
      note="GATE_HUMAN
Reason: $reason
Title: $title
Surfaced at: $ts (runner gate-policy / L2 claude-tools-1tu)" ;;
  esac
  # Work-plane projection — best-effort + idempotent (mirrors §7.3 shape).
  safe_capture BD_UNAVAILABLE "" -- bd update "$bead" --status=blocked >/dev/null
  safe_capture BD_UNAVAILABLE "" -- bd label add "$bead" human >/dev/null
  safe_capture BD_UNAVAILABLE "" -- bd update "$bead" --append-notes="$note" >/dev/null
  echo "runner: gate-policy verdict=$verdict for $bead — surfaced to human (status=blocked + label:human), continuing"
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

  # ── L2 (claude-tools-1tu) gate-policy consultation ─────────────────────────
  # BEFORE the lease acquire (so a gate-human bead never burns a lease or an
  # in-progress write). The script prints `auto-advance` for the common case
  # and `gate-human:<reason>` when Brian must see it first. A bd subprocess
  # failure inside the script yields `gate-human:bd-unavailable` (fail-CLOSED
  # on the gate — opposite of capacity's fail-OPEN posture; agents/gate-policy.md).
  # If the script itself is missing we fail-OPEN to auto-advance (an old
  # checkout / unwritable RUNNER_DIR should NOT silently block every pickup);
  # one visible degrade line is emitted so the regression is loud.
  local gate_verdict
  if [[ -x "$GATE_POLICY_SH" ]]; then
    gate_verdict="$("$GATE_POLICY_SH" decide "$CANDIDATE_ID" 2>/dev/null)" \
      || gate_verdict="${gate_verdict:-gate-human:bd-unavailable}"
  else
    degrade GATE_POLICY_MISSING "$GATE_POLICY_SH not executable — auto-advancing all pickups (L2 gate disabled)"
    gate_verdict="auto-advance"
  fi
  case "$gate_verdict" in
    auto-advance)
      : ;;
    gate-human:*)
      _surface_gate_human "$CANDIDATE_ID" "$CANDIDATE_TITLE" "$gate_verdict"
      sleep "${LEASE_DENY_BACKOFF:-3}"
      transition RECONCILE; return ;;
    *)
      # Unknown verdict shape is a contract drift — fail-CLOSED for safety
      # and emit a typed degrade so the next iteration's logs name it.
      degrade GATE_POLICY_VERDICT "unrecognized verdict='$gate_verdict' from $GATE_POLICY_SH — treating as gate-human (fail-CLOSED)"
      _surface_gate_human "$CANDIDATE_ID" "$CANDIDATE_TITLE" "gate-human:unrecognized-verdict"
      sleep "${LEASE_DENY_BACKOFF:-3}"
      transition RECONCILE; return ;;
  esac

  transition CLAIM
}

st_claim() {
  # ── BC-13 per-task retry gate (the v1 loop-top retry counter, reimplemented
  #    as a state-machine entry guard). The candidate was just chosen by the
  #    ONE reconcile point; if it is the SAME task the per-task counter is
  #    tracking, this is a retry — bump it, and at MAX_RETRIES stop retrying:
  #    reset to `open` (BC-15), record the incident + greppable note, and hand
  #    it to a blocking analysis child instead of burning the budget forever.
  #    Placed BEFORE the lease acquire (as in v1) so a skipped task never leaks
  #    an unreleased lease. RATE_LIMIT/CONTEXT_OVERFLOW/MAX_OUTPUT_TOKENS/STUCK
  #    deliberately do NOT set LAST_FAILED_ID, so they are invisible HERE — that
  #    asymmetry IS §7.5/BC-13 (a rate-limit must not consume the retry budget;
  #    an overflow/stuck must not be retried at all).
  if [[ "$CANDIDATE_ID" == "$LAST_FAILED_ID" ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ $FAIL_COUNT -ge $MAX_RETRIES ]]; then
      echo "  Skipping after $MAX_RETRIES failures"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CANDIDATE_ID" --status=open >/dev/null
      append_runner_note "$CANDIDATE_ID" "exceeded_max_retries" "-"
      record_incident    "$CANDIDATE_ID" "exceeded_max_retries" "-"
      create_analysis_task "$CANDIDATE_ID" "$CANDIDATE_TITLE" "exceeded_max_retries"
      LAST_FAILED_ID=""; FAIL_COUNT=0
      transition RECONCILE; return
    fi
    # claude-tools-ntn: we WILL retry this same task (budget not exhausted) —
    # space it from the prior attempt with a growing, bounded delay so a brief
    # platform outage (SERVER_ERROR / UNKNOWN_FAILURE — the classes that set
    # LAST_FAILED_ID and so reach this gate) cannot burn the whole MAX_RETRIES
    # budget in seconds. Placed HERE — the ONE per-task retry gate, BEFORE the
    # lease acquire below — so the sleep holds NO lease and NO in_progress
    # bead: a signal landing during it still resets clean (BC-35) and no lease
    # outlives idle time. FAIL_COUNT / LAST_FAILED_ID / the breaker are
    # unchanged — this only delays.
    _retry_backoff "$FAIL_COUNT"
  else
    LAST_FAILED_ID=""; FAIL_COUNT=0
  fi

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
  IDLE_ANNOUNCED=""   # claude-tools-giu: leaving idle — next drain re-announces
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
  # §7.6: --output-format stream-json is KEPT (the §7.2(b) backstop reads
  # result.permission_denials[] / the "Entered plan mode." tool_result — `text`
  # hides both); GUARDRAIL_FLAGS removes the interactive tools from the
  # advertised set (defense-in-depth behind the §7.2(a) instructed prompt).
  claude -p "$prompt" \
    --output-format stream-json \
    --verbose \
    --model "$DEFAULT_MODEL" \
    "${GUARDRAIL_FLAGS[@]+"${GUARDRAIL_FLAGS[@]}"}" \
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
  # BC-09: the exit code is NOT trusted as a verdict (truth is `bd` status).
  # But §7.1 still NEEDS it: the STUCK slot keys on the WORKER_STUCK_EXIT
  # sentinel and the marker scan is exit-0-guarded exactly as v1's was, so the
  # worker's code is CAPTURED here and consumed by classify_failure — never
  # used as a standalone success/fail signal.
  if wait "$CLAUDE_PID" 2>/dev/null; then CLAUDE_EXIT=0; else CLAUDE_EXIT=$?; fi
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

# A §8.1 FATAL terminal (AUTH=3, BILLING=4, breaker=2): reset the bead to open
# (BC-15 — never strand it in_progress), pair the §6.1 lease release, clear the
# in-flight marker (so the EXIT-trap net is a no-op — no double handling), set
# the FROZEN BC-21 code + §8.2 class, and route to the ONE terminal funnel.
_terminal_fatal() {
  local cls="$1" code="$2"
  safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
  job_release_lease "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null
  CURRENT_TASK_ID=""; LEASE_GENERATION=""
  TERMINAL_CLASS="$cls"; EXIT_CODE="$code"
  transition TERMINAL
}

st_post_task() {
  PROCESSED=$((PROCESSED + 1))

  # BC-39/40 happens-before is structural: the worker is `wait`ed and the
  # watchdog reaped (st_run_task) BEFORE this runs, so the merged stream is
  # COMPLETE and the WATCHDOG_KILL marker (if any) is already in SIGNAL_FILE.
  # Accumulate the typed markers, then apply the FROZEN §7.1 precedence ONCE.
  parse_stream_signals "$STREAM_FILE" "$SIGNAL_FILE"
  CLASSIFICATION="$(classify_failure "$SIGNAL_FILE" "$CURRENT_TASK_ID" "$CLAUDE_EXIT")"

  # Selective post-mortem stream preservation: keep the merged stream for the
  # serious classes (so we can reconstruct what the agent was doing when it
  # failed); routine/transient classes get an incident row + bead note only, no
  # disk spam. (BC-28's nuanced retention-by-class is T1b's ASSERTION surface;
  # this is the v1-faithful producer the classification drives.)
  PRESERVED_LOG=""
  local _b
  case "$CLASSIFICATION" in
    WATCHDOG_KILL|UNKNOWN_FAILURE|SERVER_ERROR|MAX_OUTPUT_TOKENS|CONTEXT_OVERFLOW)
      _b="$(basename "$STREAM_FILE" 2>/dev/null)"; _b="${_b%.stream.jsonl}"
      PRESERVED_LOG="$(preserve_stream "$STREAM_FILE" "$_b-$CLASSIFICATION")"
      [[ -n "$PRESERVED_LOG" ]] && echo "  Stream preserved: $PRESERVED_LOG"
      [[ "$CLASSIFICATION" == "WATCHDOG_KILL" && -n "${PROC_SNAPSHOT:-}" && -f "$PROC_SNAPSHOT" ]] && \
        echo "  Process snapshot: $PROC_SNAPSHOT"
      ;;
  esac

  # ── §7.1 first-match dispatch. The ORDER above (classify_failure) decided
  #    the class; HERE each class gets its §7.5/BC-13/BC-14-correct handling.
  #    Breaker invariant (BC-14): ONLY the generic branch, ONLY for a DISTINCT
  #    failing task, advances CONSECUTIVE_FAILURES; ONLY SUCCESS resets it.
  case "$CLASSIFICATION" in
    SUCCESS)
      echo "  Done: $CANDIDATE_TITLE"
      COMPLETED=$((COMPLETED + 1))
      CONSECUTIVE_FAILURES=0          # BC-14: breaker resets ONLY on success
      LAST_FAILED_ID=""; FAIL_COUNT=0
      ;;

    AUTH_FAILURE)                     # §8.1 row 3 — fleet-fatal, terminal
      echo "  FATAL: Authentication failed — stopping runner (BC-21 exit 3)."
      append_runner_note "$CURRENT_TASK_ID" "AUTH_FAILURE" "-"
      record_incident    "$CURRENT_TASK_ID" "AUTH_FAILURE" "-"
      _terminal_fatal AUTH_FAILURE 3; return
      ;;

    BILLING_ERROR)                    # §8.1 row 4 — fleet-fatal, terminal
      echo "  FATAL: Billing error — stopping runner (BC-21 exit 4)."
      append_runner_note "$CURRENT_TASK_ID" "BILLING_ERROR" "-"
      record_incident    "$CURRENT_TASK_ID" "BILLING_ERROR" "-"
      _terminal_fatal BILLING_ERROR 4; return
      ;;

    STUCK_NEEDS_HUMAN)
      # §7.3 (AD3.3): drive the bead to blocked-for-human + route the fork
      # into ONE Dossier keyed on task_ref. This is UNCONDITIONAL and
      # IDEMPOTENT by design: on the §7.2(a) primary path the instructed
      # worker already did status=blocked + the structured ask + `bd human`
      # (a harmless re-assert); on a fired §7.2(b) backstop the worker SLIPPED
      # and the bead is NOT driven — here the runner-side drive is the
      # load-bearing fork-must-not-rot guarantee (the v1 SCAR was exit 7 →
      # UNKNOWN → generic reopen, clobbering the human flag). §7.4 "one fork ⇒
      # one Dossier" is the Coordinator's dossier-level latch (stub no-op
      # here) — _drive_blocked_for_human makes only the task_ref-keyed call.
      # §7.5 (AD3.2): STUCK is retry-EXEMPT and breaker-EXEMPT and adds NO
      # runner exit code — it MUST NOT reset the bead to `open`, MUST NOT
      # advance the breaker (else N legitimate human-asks stop the fleet —
      # turning the normal path into an outage), MUST NOT retry. It records
      # the incident + greppable note and moves on, like a blocking analysis
      # child. CONSECUTIVE_FAILURES / LAST_FAILED_ID deliberately untouched.
      _drive_blocked_for_human "$CURRENT_TASK_ID"
      echo "  STUCK_NEEDS_HUMAN: $CANDIDATE_TITLE — bead driven to blocked-for-human (§7.3); runner continues (§7.5, no retry, no breaker, no exit code)"
      append_runner_note "$CURRENT_TASK_ID" "STUCK_NEEDS_HUMAN" "-"
      record_incident    "$CURRENT_TASK_ID" "STUCK_NEEDS_HUMAN" "-"
      ;;

    RATE_LIMIT)
      # BC-13: INVISIBLE to the per-task retry counter (LAST_FAILED_ID NOT
      # set) and BC-14 breaker-exempt — a rate-limit is routine, not an error
      # to escalate; it must not burn the retry budget or trip the fleet.
      echo "  Rate limited — will retry (invisible to the per-task retry counter)."
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
      append_runner_note "$CURRENT_TASK_ID" "RATE_LIMIT" "-"
      record_incident    "$CURRENT_TASK_ID" "RATE_LIMIT" "-"
      ;;

    CONTEXT_OVERFLOW)
      # BC-11/BC-13: deterministic — retrying as-is re-overflows at the same
      # point, so SKIP retry and go straight to a blocking analysis child.
      # Breaker-exempt (BC-14): an overflow STORM across distinct tasks must
      # NOT trip the fleet breaker.
      echo "  FAILED: $CANDIDATE_TITLE — context window overflowed (Prompt is too long)"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
      append_runner_note "$CURRENT_TASK_ID" "CONTEXT_OVERFLOW" "${PRESERVED_LOG:--}"
      record_incident    "$CURRENT_TASK_ID" "CONTEXT_OVERFLOW" "${PRESERVED_LOG:--}"
      create_analysis_task "$CURRENT_TASK_ID" "$CANDIDATE_TITLE" \
        "context_overflow — ran out of context mid-session. The previous agent likely completed early phases before overflowing: inspect git log / git diff for committed or staged work and re-scope this task to ONLY the remaining steps (do not redo completed work). If the task is inherently too large for one window, split it into smaller dependent tasks."
      LAST_FAILED_ID=""; FAIL_COUNT=0
      ;;

    MAX_OUTPUT_TOKENS)                # BC-13: skip retry → analysis; breaker-exempt
      echo "  FAILED: $CANDIDATE_TITLE — ran out of output/context window"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
      append_runner_note "$CURRENT_TASK_ID" "MAX_OUTPUT_TOKENS" "${PRESERVED_LOG:--}"
      record_incident    "$CURRENT_TASK_ID" "MAX_OUTPUT_TOKENS" "${PRESERVED_LOG:--}"
      create_analysis_task "$CURRENT_TASK_ID" "$CANDIDATE_TITLE" "max_output_tokens"
      LAST_FAILED_ID=""; FAIL_COUNT=0
      ;;

    TASK_NOT_CLOSED)
      # BC-13: retry ONCE (the agent often just forgot `bd close`); the SECOND
      # consecutive occurrence escalates to a blocking analysis child. Breaker-
      # exempt (this is a content/agent issue, not a systemic one).
      echo "  PARTIAL: $CANDIDATE_TITLE — exited 0 but task still open"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
      append_runner_note "$CURRENT_TASK_ID" "TASK_NOT_CLOSED" "-"
      record_incident    "$CURRENT_TASK_ID" "TASK_NOT_CLOSED" "-"
      if [[ "$CURRENT_TASK_ID" == "$LAST_FAILED_ID" ]]; then
        create_analysis_task "$CURRENT_TASK_ID" "$CANDIDATE_TITLE" "task_not_closed"
        LAST_FAILED_ID=""; FAIL_COUNT=0
      else
        LAST_FAILED_ID="$CURRENT_TASK_ID"
      fi
      ;;

    DEGRADED)
      # BC-42: a degraded `bd` read is NOT a verdict — do NOT mutate work
      # state on an infra blip; §6.1 lease expiry recovers a still-open bead.
      # Not an incident (a hiccup is not a failure to escalate).
      echo "  outcome undetermined ($CURRENT_TASK_ID — bd degraded): not mutating work state (BC-42; §6.1 expiry recovers it)"
      ;;

    SERVER_ERROR|WATCHDOG_KILL|UNKNOWN_FAILURE|*)
      # The generic branch: the ONLY one that advances the BC-14 breaker, and
      # ONLY for a DISTINCT failing task (a same-task repeat is the BC-13
      # per-task retry path's concern, gated above in st_claim).
      echo "  FAILED: $CANDIDATE_TITLE ($CLASSIFICATION, exit $CLAUDE_EXIT)"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
      append_runner_note "$CURRENT_TASK_ID" "$CLASSIFICATION" "${PRESERVED_LOG:--}"
      record_incident    "$CURRENT_TASK_ID" "$CLASSIFICATION" "${PRESERVED_LOG:--}"
      if [[ "$CURRENT_TASK_ID" != "$LAST_FAILED_ID" ]]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      fi
      LAST_FAILED_ID="$CURRENT_TASK_ID"
      ;;
  esac

  # Drop the proc snapshot unless WATCHDOG_KILL won classification (only the
  # watchdog writes it, and only that class keeps it — the BC-28 edge where a
  # more-decisive class wins even though the watchdog fired ⇒ snapshot deleted).
  if [[ "$CLASSIFICATION" != "WATCHDOG_KILL" && -n "${PROC_SNAPSHOT:-}" && -f "$PROC_SNAPSHOT" ]]; then
    rm -f "$PROC_SNAPSHOT" 2>/dev/null || true
  fi

  # §8.1 row 2 — consecutive-failure circuit breaker. Advanced ONLY by the
  # generic branch above (BC-14); RATE_LIMIT/CONTEXT_OVERFLOW/MAX_OUTPUT_TOKENS/
  # TASK_NOT_CLOSED/STUCK never touch CONSECUTIVE_FAILURES, so a storm of those
  # (the normal path) NEVER stops the fleet — only genuine systemic failure on
  # distinct tasks does. FROZEN exit 2.
  if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
    echo ""
    echo "  $MAX_CONSECUTIVE_FAILURES consecutive failures — likely systemic error."
    echo "  Stopping to avoid closing healthy tasks as skipped (BC-21 exit 2)."
    _terminal_fatal CIRCUIT_BREAKER 2; return
  fi

  # Job 1 pairing — release the lease (§6.1; fenced by §4.4 generation). For
  # every non-fatal class the bead is already at its correct status (open for
  # the retried/failed classes; blocked-for-human for STUCK; closed for
  # SUCCESS) — release pairs the acquire so the lease never outlives the work.
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

# §1.2 / UX §0.A (claude-tools-giu): empty queue is NOT project death. The
# runner stays alive, reports idle, polls for new ready work every
# RECLAIM_POLL_INTERVAL seconds, and resumes on the next `bd ready` hit
# WITHOUT requiring an external respawn (the T3 daemon is still authoritative
# for desired-state; an idle-poll just avoids burning the claude+lib startup
# cost on every drain cycle). Reconcile-on-each-tick is delegated to
# st_reconcile (which already honors STOP_FILE, desired=stopped, and
# desired=paused) — st_drained just paces the cadence and the heartbeat. The
# IDLE_ANNOUNCED guard keeps logs to one line per idle spell; st_claim clears
# it when a task is finally picked up.
#
# RUNNER_EXIT_ON_DRAIN=1 opts INTO the legacy BC-05/BC-21 SCAR (drain ⇒ exit 0
# verbatim). The conformance harness sets this so the historical exit-code
# table is still exercised end-to-end (the contract is preserved for tests +
# any external coordinator that still treats exit 0 as "queue drained"). The
# production default — unset — is the UX §0.A idle-loop.
st_drained() {
  if [[ -n "${RUNNER_EXIT_ON_DRAIN:-}" ]]; then
    echo ""
    echo "runner: no ready tasks — draining (RUNNER_EXIT_ON_DRAIN=1; BC-05/BC-21 legacy contract)"
    TERMINAL_CLASS="CLEAN"; EXIT_CODE=0
    transition TERMINAL
    return
  fi
  if [[ -z "${IDLE_ANNOUNCED:-}" ]]; then
    echo ""
    echo "runner: no ready tasks — idling (poll every ${RECLAIM_POLL_INTERVAL}s for new work; UX §0.A)"
    IDLE_ANNOUNCED=1
  fi
  job_heartbeat idle "" "" >/dev/null      # §4.2: honestly idle, not gone
  sleep "$RECLAIM_POLL_INTERVAL"
  transition RECONCILE
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
  # §8.2 visibility: surface every incident this run (watchdog kills and other
  # silently-retried failures that later succeeded) on the ONE terminal funnel —
  # so a fatal 2/3/4 OR a clean 0 drain both leave the same auditable summary.
  print_incidents_summary
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
