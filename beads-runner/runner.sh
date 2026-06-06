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
#   BC-42 typed-error POSTURE every sibling inherits. The T2.x mechanism seams
#   are now FILLED IN PLACE (epic claude-tools-glk closed GREEN, PASS=99/FAIL=0):
#   classification/retry/breaker (T2.2, claude-tools-8nn), idle watchdog (T2.3,
#   claude-tools-9e7), process-tree teardown/interrupt cleanup/artifact basenames
#   (T2.4, claude-tools-7hx) and the real worker prompt + AD3.5 guardrail + STUCK
#   primary/backstop (T2.5, claude-tools-kqn) — each is marked in-body with its
#   owning bead + a "RE-IMPLEMENTED" banner (e.g. the T2.3 watchdog banner near
#   st_run_task). The one surface that remains a genuine CALLEE seam is the
#   six-job BACKEND: it is selectable via RUNNER_BACKEND (`stub` | `real`) — see
#   the backend block below (T-final wiring, claude-tools-v2c2). Per-section
#   ANTI-DRIFT ownership (non-overlapping, owned by a sibling) is unchanged.
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

# ── Pickup label gate (BC-08b human-* fixtures + uxvj4 gate:* Gates) ──────────
# claude-tools-v2c3: port-forward of the v1 RUNNER_NO_CLAIM_LABELS hard gate
# (run-beads-tasks.sh:86) that the v2 rewrite was missing — the v2c3 coverage
# audit's worst cutover-blocker. The exact-match list names the human-driven
# fixtures the autonomous runner must NEVER claim (the claude-tools-noj / tkf /
# 240 SCAR: re-claiming a phone-gated fixture burned Brian's per-dossier spend
# 4× in one night). The gate:<id> Gate refusal (uxvj4 / gates.md §5) is
# ALWAYS-ON and independent of this list — see _candidate_label_gated.
RUNNER_NO_CLAIM_LABELS="${RUNNER_NO_CLAIM_LABELS:-human-live-session,human-triage,human-action}"

# ── Cross-workspace scope check (BC-08d, claude-tools-v2cut.1) ────────────────
# Port-forward of v1 run-beads-tasks.sh:87-107 (claude-tools-uxg8, GAP G8) —
# UX-DESIGN-V2 §8.5 / design/cross-ws.md §2.4. A bead that references a
# *cross-repo id* (a bead id belonging to a SIBLING workspace) and is not a
# tracking-only bead is FLAGGED, not silently claimed by the wrong workspace's
# runner (the "why is there a backend task in the frontend tracking" frustration
# — a silent-misclaim hazard amplified by parallel FE/BE runners). The check
# lives at the TAIL of _validate_workable. RUNNER_SIBLING_PREFIXES is the
# comma-separated list of sibling bd id prefixes this workspace knows about
# (e.g. an FE workspace sets 'thirsty-be'); EMPTY by default, so a single-repo
# runner does nothing (no bd calls, behaviour unchanged). List PEER-workspace
# prefixes only — do NOT list a prefix that is a parent-segment of your own
# local prefix (e.g. 'thirsty' when you are 'thirsty-be'), or your own ids match.
RUNNER_SIBLING_PREFIXES="${RUNNER_SIBLING_PREFIXES:-}"
# Labels that EXEMPT a bead from the cross-repo flag — a coordination / tracking
# bead is *meant* to reference sibling-workspace ids (the "isn't a tracking-only
# task" carve-out, §8.5). Sticky + human-controlled like the no-claim labels.
RUNNER_TRACKING_ONLY_LABELS="${RUNNER_TRACKING_ONLY_LABELS:-tracking-only}"

# ── §0.5 frozen constants (env-overridable; literal default == §0.5 table) ────
CONTROL_POLL_INTERVAL="${CONTROL_POLL_INTERVAL:-60}"   # §0.5 (60 s) desired-state poll DURING a task; stop honored ≤ this
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"         # §0.5 (60 s) actual-state+liveness heartbeat; lease renew
RECLAIM_POLL_INTERVAL="${RECLAIM_POLL_INTERVAL:-60}"   # §0.5 (60 s) re-poll cadence after a clean drain (relaunch itself is T3)
RUNNER_TICK="${RUNNER_TICK:-1}"                        # during-task poll granularity (s); test-tunable
# I1 (claude-tools-uxvi1) — how often the during-task loop classifies the worker
# stream + (throttled) reports agent_activity. [free] per ARCH §8 (any cadence
# that keeps liveness ≤ the 90s soft window). The lib throttles the actual POST
# to transitions + an ≤ACTIVITY_REPORT_FRESHNESS_S heartbeat; this is just the
# classify/scan cadence (the jq scan is bounded to the stream tail).
ACTIVITY_REPORT_INTERVAL="${ACTIVITY_REPORT_INTERVAL:-15}"

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
# claude-tools-2fkp (port of td0y): post-terminal SIGKILL grace. Once the SDK
# emits its terminal record (`terminal_reason` or `type":"result"`), claude is
# contract-done; if the process is STILL alive this many seconds later it is
# wedged on an orphan child (the krxv incident: Node won't exit while a
# `run_in_background:true` Bash poller keeps its event loop alive). This is
# ORTHOGONAL to IDLE_TIMEOUT — that's stream/tree silence inside an ACTIVE task;
# this is a known-COMPLETED task that won't release. 60s is comfortably longer
# than any legitimate Node teardown but ~360× faster than the inflight-stretched
# idle ceiling. The watchdog (which already polls every WATCHDOG_POLL while the
# worker is alive) both STAMPS the terminal marker and ENFORCES this grace —
# v2 has no concurrent tail -f parser (v1's stamping seam). Env-overridable.
POST_TERMINAL_GRACE="${POST_TERMINAL_GRACE:-60}"      # secs after SDK terminal record before SIGKILL backstop

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
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"   # BC-30: prune runner-logs older than this, ONCE at startup (st_starting)

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

# ── BC-37 — first-arg --yolo escape hatch (port from v1 run-beads-tasks.sh
#    ~290-296; claude-tools-92l3, the last BC-37 half v2 hadn't ported). Parsed
#    at MODULE scope on purpose: the dispatch loop calls st_* with NO args, so
#    `$1` here is the runner's OWN first positional arg (e.g. a human running
#    `bash runner.sh --yolo`, or `RUNNER_CMD="bash …/runner.sh --yolo"` through
#    launch-detached.sh's "$@" passthrough — the daemon never passes it).
#    Applied AFTER the project `.beads/runner.sh` source so --yolo WINS over a
#    project PERMISSION_FLAGS override (v1 ordering: config @178-183, yolo
#    @290-296). It replaces the curated allowlist wholesale with
#    --dangerously-skip-permissions and relabels the run; YOLO=1 also suppresses
#    the opus→`--permission-mode auto` override below so the bypass flows through
#    unmodified (yolo wins — BC-58/§12). SCAR (deliberate product surface), not
#    scaffolding.
MODE_LABEL="scoped permissions"
YOLO=0
if [[ "${1:-}" == "--yolo" ]]; then
  PERMISSION_FLAGS=(--dangerously-skip-permissions)
  MODE_LABEL="all permissions bypassed"
  YOLO=1
fi

# claude-tools-qcoe / BC-58: per-task permission mode. Opus supports
# `--permission-mode auto` (LLM-classified auto-approval, still honors
# permissions.deny). Sonnet silently downgrades auto→default in headless = block
# on first prompt = watchdog kill, so non-Opus stays on the workspace
# PERMISSION_FLAGS (acceptEdits + allowlist).
# This module-scope resolution is now only the STARTUP DEFAULT (against
# DEFAULT_MODEL). The AUTHORITATIVE per-task resolution is _resolve_task_model
# (BC-32, claude-tools-v2cut.4), called once per task at the top of st_run_task —
# it re-reads the task's `model:` label, upgrades bare opus→opus[1m], and
# re-derives TASK_PERMISSION_FLAGS from THAT model before every spawn. Keeping
# this default keeps the array defined (unset-safe) and mirrors the common
# no-label case.
# FORWARD COMPAT: when Sonnet gains auto support, change `opus*)` to `opus*|sonnet*)`.
# --yolo WINS (claude-tools-92l3): YOLO=1 skips this override entirely so
# --dangerously-skip-permissions (set above) flows through to the worker argv
# instead of being replaced by --permission-mode auto (mirrors v1 ~1611).
TASK_MODEL="$DEFAULT_MODEL"
TASK_PERMISSION_FLAGS=("${PERMISSION_FLAGS[@]}")
if [[ "$YOLO" != 1 ]]; then
  case "$DEFAULT_MODEL" in
    opus*) TASK_PERMISSION_FLAGS=(--permission-mode auto) ;;
  esac
fi

# ── BC-32 — per-task label-driven model selection (claude-tools-v2cut.4) ──────
# v1 read a `model:<X>` label off EACH task (run-beads-tasks.sh ~1597-1602); v2
# had only the single per-runner DEFAULT_MODEL above. This restores the per-task
# split: _resolve_task_model runs once per task at the top of st_run_task and
# (re)sets both TASK_MODEL and TASK_PERMISSION_FLAGS for THAT task.
#   • TASK_MODEL = the task's `model:` label value, else DEFAULT_MODEL.
#   • bare `opus` (the 200K alias) is upgraded to `opus[1m]` (the 1M variant);
#     `sonnet`/`sonnet[1m]` are left EXACTLY as-is — sonnet[1m] needs "extra
#     usage" this org has disabled, so a model:sonnet task deliberately runs on
#     the 200K window (this is WHY the BC-19 overflow salvage text tells the next
#     agent to relabel model:opus before retry).
#   • TASK_PERMISSION_FLAGS is then re-derived from the RESOLVED model (BC-58
#     coupling) — the same opus*⇒auto / else-acceptEdits / yolo-wins rule as the
#     startup default above, but keyed on the per-task TASK_MODEL.
# Faithful-port note (BC-32 "Finding (edge)"): v1 has NO first-`model:`-match
# guard — multiple `model:` labels make TASK_MODEL a newline-joined string passed
# verbatim to `claude --model` (undefined). BEHAVIORAL-CONTRACT characterizes that
# edge AS-IS ("not proposed for fix"), so this port reproduces v1's jq verbatim
# rather than silently fixing it (a unilateral fix would be undocumented drift).
_resolve_task_model() {
  local id="$1"
  TASK_MODEL="$(bd label list "$id" --json 2>/dev/null \
    | jq -r '.[] | select(startswith("model:")) | sub("model:"; "")' 2>/dev/null)"
  TASK_MODEL="${TASK_MODEL:-$DEFAULT_MODEL}"
  [[ "$TASK_MODEL" == "opus" ]] && TASK_MODEL="opus[1m]"
  TASK_PERMISSION_FLAGS=("${PERMISSION_FLAGS[@]}")
  if [[ "$YOLO" != 1 ]]; then
    case "$TASK_MODEL" in
      opus*) TASK_PERMISSION_FLAGS=(--permission-mode auto) ;;
    esac
  fi
}

# ── The callee surface: a SELECTABLE six-job backend (BC §3 callees; T-final
#    wiring, claude-tools-v2c2). The runner is the CALLER of the six §3 jobs; the
#    callee bodies live in a swappable backend chosen by RUNNER_BACKEND:
#      stub  — in-process NO-OP stubs (T2.1; lib/coordinator-stub.sh +
#              lib/local-agent-stub.sh). Zero external deps. This is what the
#              FROZEN conformance harness and any bare `bash runner.sh` get, and
#              what proves the loop SHAPE with no Coordinator/Local-Agent/daemon
#              present. DEFAULT — deliberately fail-safe.
#      real  — the real Local Agent (T3, lib/local-agent.sh) + Coordinator (T5,
#              lib/coordinator.sh, HTTP-overridden by lib/co-http-transport.sh
#              when COORDINATOR_URL is set — the daemon/hosted path), behind a
#              thin name/arg adapter (lib/runner-backend-real.sh) so the runner's
#              job_* call sites below DO NOT change (the stub↔real total swap).
#    Defaulting to `stub` keeps every FROZEN conformance assertion GREEN with
#    ZERO rig edits (ANTI-DRIFT: never edit an assertion to make it pass). The
#    staged cutover (claude-tools-v2c4) is what flips the production launcher to
#    RUNNER_BACKEND=real; the daemon already sets the sibling COORDINATOR_URL env
#    the same way (daemon/*-poll.sh). degrade() is defined below, so the unknown
#    fallback emits a raw `degrade:` line in the same format. ──────────────────
RUNNER_BACKEND="${RUNNER_BACKEND:-stub}"
case "$RUNNER_BACKEND" in
  real)
    # shellcheck source=/dev/null
    source "$RUNNER_DIR/lib/runner-backend-real.sh"
    ;;
  stub)
    # shellcheck source=/dev/null
    source "$RUNNER_DIR/lib/coordinator-stub.sh"
    # shellcheck source=/dev/null
    source "$RUNNER_DIR/lib/local-agent-stub.sh"
    ;;
  *)
    echo "degrade: BACKEND_UNKNOWN — RUNNER_BACKEND='$RUNNER_BACKEND' not in {stub,real}; using stub" >&2
    # shellcheck source=/dev/null
    source "$RUNNER_DIR/lib/coordinator-stub.sh"
    # shellcheck source=/dev/null
    source "$RUNNER_DIR/lib/local-agent-stub.sh"
    ;;
esac

# ── Cutover safety: LOUD notice if we are on the stub backend in a HOSTED
#    context (claude-tools-v2c4). Under RUNNER_BACKEND=stub la_capacity_check is
#    a hardcoded no-op (lib/local-agent-stub.sh) — there is NO 5h/7d usage
#    ceiling. That is correct and silent for a bare standalone `bash runner.sh`
#    (no COORDINATOR_URL — the conformance/standalone path), but a runner WIRED
#    to the hosted engine (COORDINATOR_URL set — the daemon/production path)
#    running stub capacity is an ACCIDENTAL unguarded launch that can burn
#    Anthropic quota. Per the never-silent-degradation principle (claude-tools-18c)
#    we make it HEARD immediately rather than discovered after the burn. The
#    production cutover path (daemon M3 spawn) pins RUNNER_BACKEND=real, so this
#    only fires on a misconfiguration. ──────────────────────────────────────
if [[ "$RUNNER_BACKEND" == "stub" && -n "${COORDINATOR_URL:-}" ]]; then
  echo "════════════════════════════════════════════════════════════════════" >&2
  echo "degrade: BACKEND_STUB_ON_HOSTED — RUNNER_BACKEND=stub but COORDINATOR_URL is set." >&2
  echo "  The stub backend's la_capacity_check is a NO-OP: this runner has NO 5h/7d usage" >&2
  echo "  ceiling and can burn Anthropic quota UNGUARDED. Set RUNNER_BACKEND=real for any" >&2
  echo "  hosted/production launch (claude-tools-v2c4 cutover safety)." >&2
  echo "════════════════════════════════════════════════════════════════════" >&2
fi

# ── §4.2 local-first desired-state store path (claude-tools-y6j9) ─────────────
# The runner is AUTHORITATIVE for `desired`: co_deliver_desired_state reads the
# LOCAL .co-store RunnerState first (the break-through-pause fix). The MAIN loop
# had NO CO_STORE export — only the :730 stuck-routing subshell set it — so an
# unset CO_STORE would point co__store_get at the /tmp scratch store and read the
# WRONG file. Pin it ONCE at startup to the per-workspace path the daemon also
# uses (daemon/desired-state-poll.sh CO_STORE default + the :730 subshell): the
# daemon WRITES this record (change-request consume + cold-start seed), the runner
# READS it. Workspace-relative ($PWD is the workspace root under launch-detached).
: "${CO_STORE:=$PWD/.beads/runner-logs/.co-store}"; export CO_STORE

# ── Node v25 PATH prime (claude-tools-18c; shared lib at lib/node25-prime.sh,
#    pattern proven in specialist.sh = claude-tools-3kd and run-beads-tasks.sh
#    = claude-tools-4tj). The body lives in the shared helper because the same
#    bug bit three siblings; the SCOPED skip env var (RUNNER_SKIP_NVM_PRIME)
#    stays caller-local so each test surface forces a skip under its own name.
#    See node25-prime.sh for the bug-and-fix narrative; the one-liner: a
#    daemon-launched PATH resolves `claude` to system-node v25 which crashes
#    the CLI at startup. Doing the prime ONCE at runner startup (not per-task)
#    is sufficient — the runner's PATH inherits to every spawned `claude -p`.
# shellcheck source=/dev/null
source "$RUNNER_DIR/lib/node25-prime.sh"
node25_prime_path "${RUNNER_SKIP_NVM_PRIME:-0}"

# ── Trunk pin (claude-tools-trunkpin; shared lib at lib/git-pin-main.sh, shared
#    with run-beads-tasks.sh = v1). The runner does per-bead auto-commit on
#    whatever branch HEAD points at and NEVER creates branches; a worker that
#    manually `git checkout -b`s and never returns the tree to main makes EVERY
#    later bead pile onto that feature branch until a human notices. The fix
#    enforces in the loop (same lesson as the gate/close hooks): pin_head_to_main
#    runs at THE single reconcile point (st_reconcile, before CLAIM) and
#    self-heals a wandered-off tree back to main each iteration when it is clean.
#    OPTIONAL & guarded — a missing lib degrades to a no-op stub, never crashes.
pin_head_to_main() { :; }   # default no-op; overridden by the lib if present
if [[ -f "$RUNNER_DIR/lib/git-pin-main.sh" ]]; then
  # shellcheck source=lib/git-pin-main.sh
  source "$RUNNER_DIR/lib/git-pin-main.sh"
fi

# ── I1 (claude-tools-uxvi1) activity-state stream→report wiring ──────────────
# Sourced ONCE at startup (it sources lib/activity-classifier.sh, the pure D.2
# classifier). OPTIONAL & guarded (BC-43): an absent lib degrades to a no-op —
# the during-task loop calls activity_report_tick only when it is defined, so a
# missing lib never crashes the runner. The actual POST is a further-guarded,
# backgrounded best-effort (activity__post no-ops unless the live-engine
# transport is wired), so offline/stub runs never touch the network.
if [[ -f "$RUNNER_DIR/lib/activity-report.sh" ]]; then
  # shellcheck source=lib/activity-report.sh
  source "$RUNNER_DIR/lib/activity-report.sh" 2>/dev/null || true
fi

# ── close-discipline hook settings builder (claude-tools-2fkp) ────────────────
# The `--settings` JSON shape that wires the close-checklist hook into each
# worker is shared with run-beads-tasks.sh (v1) via hooks/build-settings.sh so
# the PreToolUse(Bash)+Stop matcher set can never drift between the two runners.
# OPTIONAL & guarded: an absent builder DEGRADES to "spawn the worker without
# the hook" at the st_run_task call site (the §7.2 prompt-instructed discipline
# + the post-terminal watchdog backstop still apply), never crashes the loop.
if [[ -f "$RUNNER_DIR/hooks/build-settings.sh" ]]; then
  # shellcheck source=hooks/build-settings.sh
  source "$RUNNER_DIR/hooks/build-settings.sh"
fi

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

# ── claude-tools-69u8: wire the dossier-builder bridge ONCE at the dg__author
#    chokepoint for the whole v2 runner process (same opt-in sentinel + kill-
#    switch as v1 run-beads-tasks.sh). _drive_blocked_for_human authors the
#    §7.3 STUCK dossier in a sourced subshell (below); these exports give that
#    subshell's dg__author the real-agent bridge when claude is reachable, the
#    labeled-degraded jq author otherwise. Set DG_AUTHOR_AUTOWIRE=0 to force the
#    pure jq path everywhere.
export DG_AUTHOR_AUTOWIRE="${DG_AUTHOR_AUTOWIRE:-1}"
export DG_AUTHOR_TIMEOUT_SEC="${DG_AUTHOR_TIMEOUT_SEC:-300}"
export DG_AUTHOR_BRIDGE_WORKSPACE="${DG_AUTHOR_BRIDGE_WORKSPACE:-$PWD}"

# ── Mutable machine state (the ONLY state; no scattered flags) ────────────────
STATE=""                 # current state (enumerated below)
CANDIDATE_ID=""          # task chosen this cycle
CANDIDATE_TITLE=""
CANDIDATE_DESC=""
CURRENT_TASK_ID=""       # task whose lease+in_progress we hold (in flight)
LEASE_GENERATION=""      # §4.4 fencing token for the held lease
ORPHANED_IDS=()          # BC-02: beads `in_progress` at STARTUP = crash orphans from a prior run (drained ONE-per-reconcile, BC-04). A bead that becomes in_progress LATER is a live sibling agent's — never adopted (absent from this startup set). claude-tools-v2cut.2.
CLAUDE_PID=""            # in-flight worker process (BC-01: one fresh proc/task)
CLAUDE_EXIT=0            # T2.2: the worker's exit code (NOT trusted as a verdict — BC-09 — but the §7.1 STUCK slot keys on WORKER_STUCK_EXIT and the marker scan is exit-code-guarded as in v1)
WATCHDOG_PID=""          # T2.3 BC-22 watchdog subshell (one per task; in-band-reaped)
STREAM_FILE=""           # T2.3: worker stream-json capture (watchdog output-progress signal)
SIGNAL_FILE=""           # T2.3 BC-40 IPC seam: watchdog appends WATCHDOG_KILL=1; T2.2 classify consumes
PROC_SNAPSHOT=""         # T2.3 BC-22 snapshot-before-signal artifact (T2.2 keeps it ONLY for WATCHDOG_KILL)
POST_TERMINAL_FILE=""    # claude-tools-2fkp: epoch the SDK terminal record was seen; watchdog stamps + enforces the grace
HOOK_SETTINGS_FILE=""    # claude-tools-2fkp: per-task close-discipline --settings JSON (cleaned at task-end + teardown)
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

# ── §1.1/§2.4 outbox DRAIN — BC-45's SHIPPING half (claude-tools-zyxz) ─────────
# job_heartbeat -> la_heartbeat -> la_report_heartbeat only APPENDS the §4.2
# actual-state line to the durable §1.1 UP queue (.beads/runner-logs/coordinator-
# outbox.jsonl); NOTHING reaches the hosted engine until that queue is DRAINED.
# v1 run-beads-tasks.sh drains inline in hb() (288-302) AND in its mid-task HB
# subshell, so the engine's last_heartbeat_at stays live BOTH between tasks AND
# during a long one. v2 emitted heartbeats but had NO drain call anywhere — so
# the instant a workspace ran on v2 the engine froze at the PRIOR runner's
# heartbeat: stale Board liveness, a frozen current_task_ref, and a spurious-
# 'runner stuck' risk while desired=running (the live cutover scar). This is the
# single drain seam; its three call sites mirror v1's drain cadence:
#   1. st_reconcile — once per loop, ships the just-finished task's heartbeats
#   2. the during-task §2.5 heartbeat branch — once per HEARTBEAT_INTERVAL so a
#      task longer than the engine's STALE_AFTER stays live (the ACTUAL bug:
#      st_reconcile is NOT re-entered during a task, so a reconcile-only drain
#      would still freeze a >STALE_AFTER task)
#   3. st_terminal — the last durable write, ships the final `stopped` state
# Guarded-optional (BC-43): la_outbox_drain is defined ONLY when the HTTP
# transport is sourced with a non-empty COORDINATOR_URL; absent ⇒ the queue just
# persists locally (standalone/oracle/conformance byte-unaffected, drained on a
# later hosted reconnect — the §2.4 at-least-once contract). NEVER aborts.
_drain_outbox() {
  declare -F la_outbox_drain >/dev/null 2>&1 || return 0
  [[ -n "${COORDINATOR_URL:-}" ]] || return 0
  la_outbox_drain "${COORDINATOR_TOKEN:-}" >/dev/null 2>&1 || true
}

# ── §6.2 / AD2.2 — bounded LOCAL lease fallback (the machine-local half, la_*) ──
# These are NOT one of the six §3 jobs (the LA does NOT arbitrate leases — T4
# does); they are the runner-side wiring of the §6.2 degraded-CLOSED posture. The
# LA records which leases THIS runner holds locally and decides whether to keep
# going when the Coordinator is unreachable: continue ONLY a task whose still-
# valid lease we ALREADY hold; a missing/expired local lease ⇒ refuse (no NEW
# unsynchronised claim, so a Coordinator blip cannot reintroduce the BC-04 two-
# runners-one-orphan race). Same backend swap as the §3 jobs (stub: no-op holds
# nothing ⇒ unreachable always refuses; real: file-backed $LOG_DIR/lease-cache).
job_lease_note_held()         { la_lease_note_held "$1" "${2:-}" "${3:-}"; }              # record/refresh the local lease ENVELOPE (gen+ttl+expires; bounded-fallback INPUT, claude-tools-h9dl)
job_lease_release_local()     { la_lease_release_local "$1"; }                            # forget the local hold (pairs note_held at every release site)
job_lease_recover_generation(){ la_lease_recover_generation "$1"; }                       # recover the cached §4.4 fence token across a restart/blip (claude-tools-h9dl)
job_lease_fallback_allows()   { la_lease_fallback_allows "$1" "${2:-reachable}"; }        # 0 may | 1 must-not — the degraded-CLOSED verdict (consulted ONLY when unreachable)

# ── Mechanism A (claude-tools-uxc1) — per-task PID claim files ─────────────────
# inbox-lifecycle §8.3.3. The startup orphan snapshot (st_starting, BC-02) used to
# treat EVERY `in_progress` bead as this runner's crash orphan and adopt it. That
# is the dup-work hazard: a task `in_progress` because a LIVE external Claude
# session (or another live runner in this same workspace, or a manual `bd update`)
# set it gets ADOPTED → two workers, commit fights — amplified by the weekend's
# parallel runners. Claim files make adoption PID-VALIDATED: the runner stamps a
# claim when it drives a bead to `in_progress` and removes it on close /
# failure-reset / teardown. A claim left behind with a DEAD owning pid is the
# unforgeable "my previous self crashed here" signal; no claim, a LIVE pid, or a
# FOREIGN runner_id all mean "not my dead orphan — skip". Claims live under LOG_DIR
# (so they inherit its BC-27 self-gitignore + the LOG_RETENTION_DAYS rotation) and
# key on $$ — the RUNNER pid, the process we ask "are you still alive?" — never the
# child `claude -p` pid.
CLAIMS_DIR="${CLAIMS_DIR:-$LOG_DIR/claims}"
_claim_path() { printf '%s/%s.json' "$CLAIMS_DIR" "$1"; }

# write_task_claim <id> — stamp THIS runner ($$) as the in_progress owner of <id>.
# Called right after the `bd update --status=in_progress` write (st_claim). On a
# resumed crash-orphan this OVERWRITES the dead-pid claim with our live pid, which
# is also how the stale claim is retired (the startup walk is deliberately
# read-only — see _adopt_orphan_by_claim). Best-effort (BC-42): a claim we cannot
# write only weakens crash-recovery, it never aborts the loop.
write_task_claim() {
  local id="$1" cf
  [[ -n "$id" ]] || return 0
  mkdir -p "$CLAIMS_DIR" 2>/dev/null || return 0
  # Ensure the BC-27 self-gitignore exists even on the FIRST task — st_claim runs
  # before st_run_task, which is where the LOG_DIR .gitignore is otherwise born.
  [[ -f "$LOG_DIR/.gitignore" ]] || printf '*\n!.gitignore\n' > "$LOG_DIR/.gitignore" 2>/dev/null || true
  cf="$(_claim_path "$id")"
  jq -cn \
     --arg     rid     "$RUNNER_ID" \
     --argjson pid     "$$" \
     --arg     host    "$(hostname 2>/dev/null || echo unknown)" \
     --arg     started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg     ws      "$PROJECT_REF" \
     '{runner_id:$rid, pid:$pid, host:$host, started_at:$started, workspace:$ws}' \
     > "$cf" 2>/dev/null || true
}

# remove_task_claim <id> — drop <id>'s claim. Idempotent (rm -f). Paired with the
# in_progress→{closed,open,blocked} exits exactly like the lease release / the
# current-task pointer: st_post_task (every non-fatal class), _terminal_fatal (the
# §8.1 fatal classes), and runner_teardown's in-flight net (signal/abort/EXIT).
remove_task_claim() {
  [[ -n "${1:-}" ]] || return 0
  rm -f "$(_claim_path "$1")" 2>/dev/null || true
}

# _adopt_orphan_by_claim <id> — Mechanism A adoption gate for ONE startup-snapshot
# in_progress bead. Returns 0 (ADOPT) iff a claim file proves <id> is THIS
# workspace's runner's crash orphan: our runner_id (+ workspace backstop) AND a
# DEAD owning pid. Returns 1 (SKIP) for every other case — no claim (interactive /
# manual in_progress), a LIVE pid (a live sibling runner owns it), or a FOREIGN
# runner_id/workspace (default-CLOSED: never adopt what we cannot prove is our own
# dead orphan; the cross-workspace coordinator-liveness refinement of §8.3.3 is a
# documented follow-up — offline the safe answer is skip either way). READ-ONLY: it
# never deletes a claim. Deleting here would strand orphans 2..K — the snapshot
# validates all eligible at once but the drain resumes one-per-loop (BC-04), so a
# second crash before they are re-claimed would lose every still-unclaimed orphan
# whose claim we had already removed. The stale dead-pid claim is instead retired
# when the orphan is actually re-claimed (write_task_claim overwrites it) or by
# LOG_RETENTION rotation. PID-reuse: `kill -0` can hit a recycled pid; an
# alive-but-recycled pid resolves to SKIP (the safe direction). The
# `started_at`/`ps -o lstart` disambiguation is the §8.3.3 stretch goal — recorded
# in the claim, not yet consulted. Emits one typed reason line per bead.
_adopt_orphan_by_claim() {
  local id="$1" cf rid pid ws
  cf="$(_claim_path "$id")"
  if [[ ! -f "$cf" ]]; then
    echo "  orphan-skip $id — no claim file (in_progress set by a non-runner: live interactive session / manual bd update — not this runner's crash orphan)"
    return 1
  fi
  rid="$(jq -r '.runner_id // empty' "$cf" 2>/dev/null || true)"
  pid="$(jq -r '.pid // empty'       "$cf" 2>/dev/null || true)"
  ws="$( jq -r '.workspace // empty' "$cf" 2>/dev/null || true)"
  if [[ -n "$rid" && "$rid" != "$RUNNER_ID" ]] || [[ -n "$ws" && "$ws" != "$PROJECT_REF" ]]; then
    echo "  orphan-skip $id — claim is a FOREIGN runner/workspace (runner_id='${rid:-?}' workspace='${ws:-?}'); default-closed, not adopting"
    return 1
  fi
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "  orphan-skip $id — claim has no usable pid ('${pid:-}'); default-closed, not adopting"
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "  orphan-skip $id — claim pid $pid is ALIVE (a live sibling runner in this workspace owns it); not adopting"
    return 1
  fi
  echo "  orphan-adopt $id — our crashed claim (pid $pid is dead); eligible for resume"
  return 0
}

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

When a step needs a long-running command -- the offline test gate (e.g. `bash beads-runner/run-tests.sh`), a build, or a deploy-verify -- follow this gate-wait discipline so you neither blind yourself to it nor stampede it:
  - Run it EXACTLY ONCE. For a pre-close gate prefer the fast `--changed` path and use the full gate only when required. NEVER relaunch a long-running command because it looks quiet -- a quiet gate is normal (some tiers run for minutes with sparse output), and silence is NOT evidence that it is wedged.
  - NEVER pipe a long-running command through a non-streaming `tail -N` (e.g. `cmd | tail -40`): `tail -N` without `-f` buffers ALL its input and emits nothing until the pipe closes, so you see zero output until the command exits and wrongly conclude it stalled. Instead watch the live stream: `cmd 2>&1 | tee /tmp/gate-BEADS_ID.log` prints output as it runs AND saves a log; or redirect it to a file (or run it with `run_in_background`) and `tail -f /tmp/gate-BEADS_ID.log` to follow that file.
  - To WAIT for it, use a non-blocking pattern the harness allows: run it with `run_in_background` (then poll for completion), or `until <done-condition>; do sleep N; done`. NEVER chain `sleep N; <cmd>` -- the harness blocks sleep-chaining and it only degrades into worse polling.

If you reach a genuine fork you must NOT resolve yourself -- an irreversible or judgement-call decision the task description does not settle, where guessing could be wrong and costly -- do NOT pick for the human, do NOT use an interactive tool, and do NOT stop silently. Instead, in THIS exact order:
  1. bd update BEADS_ID --status=blocked
  2. Write the structured ask into the bead, HEADED by a first line that contains the exact marker HUMAN DECISION NEEDED -- keep that marker verbatim, it is the canonical signal the runner's human-fork safety net keys on, and without it a status-read race can misfile your correctly-surfaced fork as an unclosed task:
       bd update BEADS_ID --append-notes="HUMAN DECISION NEEDED -- <one-line title of the decision>
       <the structured ask>"   (or --design="...")
     The ask MUST clearly contain, labelled: TL;DR; the ask (the single decision needed); the options; your recommendation and why; and how reversible each option is.
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
  local tref="$1" rec authored=0
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
  # Control-plane: AUTHOR a contract-shaped (§4.1) worker_stuck Dossier — a real
  # §5 body+items, NOT a body-less stub. claude-tools-69u8: the v2 path used to
  # write ONLY {schema_version,trigger,bead_ref,task_ref,principal} via
  # co_store_put and never called dg__author, so a v2 STUCK fork shipped neither
  # an agent body NOR a jq-fallback body. Author it the way v1 does — in a
  # sourced subshell (runner.sh does not source the dossier stack), via
  # dg_from_worker_ask → dg__author (real agent when claude is reachable per
  # DG_AUTHOR_AUTOWIRE set at startup, labeled-degraded jq author otherwise).
  # §7.4 dedup id = stuck-<task_ref> collapses re-triggers to ONE dossier; the
  # bead drive above is the guaranteed §7.3 work-plane projection. Mirrors the
  # daemon Flow F engine-write subshell (daemon/flow-f-overview-poll.sh).
  if [[ -f "$RUNNER_DIR/lib/stuck-routing.sh" ]]; then
    if (
      set +e
      : "${CO_STORE:=$PWD/.beads/runner-logs/.co-store}"; export CO_STORE
      export PRINCIPAL
      [[ -n "${COORDINATOR_URL:-}"   ]] && export COORDINATOR_URL
      [[ -n "${COORDINATOR_TOKEN:-}" ]] && export COORDINATOR_TOKEN
      # shellcheck source=/dev/null
      . "$RUNNER_DIR/lib/stuck-routing.sh" 2>/dev/null || exit 1   # → dossier-gen → dossier → coordinator
      # shellcheck source=/dev/null
      [[ -f "$RUNNER_DIR/lib/notification.sh" ]] && . "$RUNNER_DIR/lib/notification.sh" 2>/dev/null
      # shellcheck source=/dev/null
      [[ -n "${COORDINATOR_URL:-}" && -f "$RUNNER_DIR/lib/co-http-transport.sh" ]] \
        && . "$RUNNER_DIR/lib/co-http-transport.sh" 2>/dev/null
      command -v dg_from_worker_ask >/dev/null 2>&1 || exit 1
      command -v sr_dossier_id_for  >/dev/null 2>&1 || exit 1
      local bearer did ask
      bearer="${COORDINATOR_TOKEN:-bearer-runner-stuck}"
      did="$(sr_dossier_id_for "$tref" 2>/dev/null)" || exit 2
      [[ -n "$did" ]] || exit 2
      ask="$(sr_worker_ask "$tref" 2>/dev/null || true)"
      dg_from_worker_ask "$bearer" "$did" "$tref" "$ask" >/dev/null 2>&1 || exit 3
      # §4.3/C3 — the SINGLE Notification at creation (idempotent; best-effort).
      command -v no_emit >/dev/null 2>&1 && no_emit "$bearer" "$did" >/dev/null 2>&1 || true
      exit 0
    ); then
      authored=1
    fi
  fi
  if [[ "$authored" -ne 1 ]]; then
    # Authoring unavailable (libs unsourceable / generation failed) — fall back
    # to the keyed body-less control-plane record so the §7.4 dedup + S-2
    # reconcile still have the worker_stuck signal. The Coordinator owns the
    # create-once dedup + the control→work reconcile (S-2); the keyed call is
    # the floor this child owns when authoring can't run.
    rec="$(jq -cn --arg tr "$tref" --arg p "$PRINCIPAL" \
      '{schema_version:1,trigger:"worker_stuck",bead_ref:$tr,task_ref:$tr,principal:$p}' \
      2>/dev/null)" || rec=""
    if [[ -n "$rec" ]]; then
      co_store_put dossier "$rec" >/dev/null 2>&1 \
        || degrade DOSSIER_STORE "co_store_put dossier failed for $tref — §7.3 bead drive already done (fork will not rot); the Coordinator reconcile (S-2) is the truth"
    fi
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
  local rl_status rl_type rl_resets rl_util rl_thr rl_ts
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
      rate_limit_event)
        # BC-61 (claude-tools-t5k; v2 port claude-tools-v2cut.4): rate_limit_event
        # entries are Claude-Code SUBSCRIPTION-window quota snapshots (5h / 7d),
        # NOT a 429 throttle — the real 429 is system.api_retry.error=rate_limit
        # above (⇒ RATE_LIMIT). Collapse `allowed` to ONE terse line (anti-spam),
        # surface `allowed_warning` LOUDLY so a 7-day-quota approach is visible,
        # and reserve a RATE_LIMIT_QUOTA marker for rejected/exceeded (never
        # observed today — forward-compat). NO classification marker is emitted
        # for allowed/allowed_warning, so classify_failure is unaffected; the
        # forward-compat RATE_LIMIT_QUOTA marker is likewise not a classifier
        # input (classify_failure reads RATE_LIMIT, not RATE_LIMIT_QUOTA). v1 ran
        # this in the live tail-parser; v2 runs it post-hoc here (same observable
        # log line — the BC-39/40 re-implementation difference, already accepted).
        # rl_ts is v2 house-style UTC `+%H:%M:%SZ` (matches record_incident /
        # append_runner_note; v1 used local-time `+%H:%M:%S` here) and is
        # parse-time, consistent with the post-hoc parse above — intentional, not
        # an accidental copy of the surrounding UTC iter_ts idiom.
        rl_status="$(printf '%s' "$line" | jq -r '.rate_limit_info.status // empty' 2>/dev/null)"
        rl_type="$(printf '%s' "$line"   | jq -r '.rate_limit_info.rateLimitType // empty' 2>/dev/null)"
        rl_resets="$(printf '%s' "$line" | jq -r 'try (.rate_limit_info.resetsAt | todateiso8601) catch ""' 2>/dev/null)"
        rl_ts="$(date -u +%H:%M:%SZ)"
        case "$rl_status" in
          allowed_warning)
            rl_util="$(printf '%s' "$line" | jq -r '.rate_limit_info.utilization // empty' 2>/dev/null)"
            rl_thr="$(printf '%s' "$line"  | jq -r '.rate_limit_info.surpassedThreshold // empty' 2>/dev/null)"
            echo "  [$rl_ts] [rate_limit:WARN] $rl_type utilization=$rl_util (>=$rl_thr) resetsAt=$rl_resets" ;;
          allowed)
            echo "  [$rl_ts] [rate_limit] $rl_type ok resetsAt=$rl_resets" ;;
          rejected|exceeded)
            echo "  [$rl_ts] [rate_limit:QUOTA] $rl_type status=$rl_status resetsAt=$rl_resets"
            echo "RATE_LIMIT_QUOTA=$rl_type" >> "$sig" ;;
          *)
            echo "  [$rl_ts] [rate_limit_event] status=$rl_status $rl_type resetsAt=$rl_resets" ;;
        esac
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
# claude-tools-1vnx — true iff the bead carries the sticky `human` decision label.
# Read via `bd label list` (the same read the RUNNER_NO_CLAIM_LABELS gate uses),
# RETRIED once so a transient hiccup does not drop a genuine fork. A degraded/empty
# read ⇒ false: the caller only UPGRADES blocked→STUCK on a POSITIVE label, never on
# an unread one (mirrors v1 _bead_blocked_for_human, which fires only on a confirmed
# label). The label is the durable fork signal where status/defer are not.
_bead_has_human_label() {
  local id="$1" labels _try
  labels=""
  for _try in 1 2; do
    labels="$(safe_capture BD_UNAVAILABLE "" -- bd label list "$id" --json)"
    [[ -n "$labels" && "$labels" != "[]" ]] && break
  done
  printf '%s' "$labels" | jq -e 'any(.[]?; . == "human")' >/dev/null 2>&1
}

# claude-tools-309l/gqyp — true iff the bead carries the worker's OWN human-fork
# ask note, RECENCY-INDEPENDENT. The `(?<!Runner: )` lookbehind drops the runner's
# own audit/auto-flip residue (the dominant uxvi4 over-trigger vector), so this is
# the honest worker-ask signal, not a self-echo. Paired with _bead_has_human_label
# below, it distinguishes a genuine fork the worker left NOT blocked (slipped the
# status flip — the m3xi vector) from a spurious bare `human` label (the
# test-stuck-primary-relaxed negative posture). Reads via `bd show --long --json`
# (the only form carrying `notes`), retried; a degraded read ⇒ false (fail-CLOSED,
# never pin an unfinished bead on a read glitch).
#
# claude-tools-gqyp — the detector MUST recognise the signal the escalation
# PROTOCOL actually emits. 309l keyed ONLY on the literal token STUCK_NEEDS_HUMAN,
# but the human-fork protocol (build_worker_prompt's "If you reach a genuine fork"
# block) tells the worker to write a structured ask HEADED `HUMAN DECISION NEEDED`
# (TL;DR / the ask / options / recommendation / reversibility) and NEVER that
# token — so Net 2 was DEAD for every canonical fork (proven on casualty
# claude-tools-o0yq: a full ask, 0 occurrences of STUCK_NEEDS_HUMAN). Match BOTH
# the canonical `HUMAN DECISION NEEDED` header (the protocol contract; producer-
# guaranteed in build_worker_prompt) AND the legacy STUCK_NEEDS_HUMAN token (the
# v1 `--append-notes` fallback at run-beads-tasks.sh:2050 + the runner's own
# recency stamp), both under the same `(?<!Runner: )` guard. The runner never
# writes "HUMAN DECISION NEEDED" to a bead note, so adding it cannot self-echo.
_bead_has_stuck_ask_note() {
  local id="$1" row notes _try
  row="__ERR__"
  for _try in 1 2; do
    row="$(safe_capture BD_UNAVAILABLE "__ERR__" -- bd show "$id" --long --json)"
    [[ "$row" != "__ERR__" && -n "$row" ]] && break
  done
  # Degraded/empty read ⇒ fail-CLOSED. Checked on the RAW row BEFORE jq so the
  # sentinel is load-bearing (safe_capture's __ERR__ fallback would otherwise be
  # swallowed by jq's parse error into an empty string — a dead guard).
  [[ "$row" == "__ERR__" || -z "$row" ]] && return 1
  notes="$(printf '%s' "$row" | jq -r '.[0].notes // ""' 2>/dev/null)" || return 1
  printf '%s' "$notes" \
    | jq -Rrs 'test("(?<!Runner: )(STUCK_NEEDS_HUMAN|HUMAN DECISION NEEDED)")' 2>/dev/null \
    | grep -qx true
}

classify_failure() {
  local sig="$1" id="$2" ec="$3" raw status
  local stuck=0
  [[ -f "$sig" ]] && grep -q '^STUCK_NEEDS_HUMAN=' "$sig" 2>/dev/null && stuck=1
  [[ "$ec" == "$WORKER_STUCK_EXIT" ]] && stuck=1

  if [[ "$ec" -eq 0 ]]; then
    # claude-tools-gqyp — harden Net 1's status read: RETRY a degraded read once
    # before typing DEGRADED, mirroring v1's retried reads (_bead_blocked_for_human)
    # and _bead_has_human_label above. A transient bd hiccup on this single read is
    # what left a blocked+human fork to fall through to Net 2; give it a second
    # chance so the canonical blocked+human path (Net 1) catches it on THIS classify
    # rather than relying on the recency-independent backstop. (A persistent failure
    # still types DEGRADED, which does not mutate work state — the BC-42 fail-safe.)
    raw="__DEGRADED__"
    for _try in 1 2; do
      raw="$(safe_capture BD_UNAVAILABLE "__DEGRADED__" -- bd show "$id" --json)"
      [[ "$raw" != "__DEGRADED__" ]] && break
    done
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
    # claude-tools-1vnx — exit-0 deliberate human fork. A COMPLIANT worker that
    # hits a human-decision fork takes the deterministic bd path (status=blocked +
    # a `human` label + a structured ask) and then ENDS ITS TURN: `claude -p`
    # exits 0 with NO WORKER_STUCK_EXIT sentinel and NO STUCK_NEEDS_HUMAN= stream
    # marker, so `stuck` is 0 above. Without this, the bead folds to
    # TASK_NOT_CLOSED, st_post_task resets it --status=open, and the retry spawns
    # an analysis child whose close re-arms the bead (re-pick → re-block →
    # re-misclassify) — the claude-tools-m3xi thrash that burned an Opus analysis
    # task per cycle (v1 had the same hole; fixed there too). The bead the worker
    # DELIBERATELY left blocked + `human` IS a human decision, not an unclosed
    # task: confirm the sticky LABEL and classify STUCK_NEEDS_HUMAN so v2's
    # existing breaker/retry-EXEMPT STUCK dispatch (drive-blocked-for-human, no
    # reset, no analysis — BC-13/14/53) pins it. (A degraded bd-show at line 969
    # already fails SAFE to DEGRADED, which does not mutate work state.)
    if [[ "$status" == "blocked" ]] && _bead_has_human_label "$id"; then
      echo "STUCK_NEEDS_HUMAN"; return
    fi
    # claude-tools-309l — the aged-out NOT-blocked residual 1vnx left open. The
    # worker SLIPPED step 1 (human label + structured ask note, but never
    # status=blocked — the m3xi run-note vector). v1's §7.3 Case-3 RELAXED preempt
    # catches this only while the note is RECENT (uxvi4 window); once it ages out,
    # a genuinely-still-stuck bead falls to TASK_NOT_CLOSED → reset + analysis
    # (thrash). v2 had NO Case-3 analogue at all. Recognise it RECENCY-
    # INDEPENDENTLY on the durable signals: the sticky `human` LABEL (resolution
    # REMOVES it via the answer consequence, so its presence means still-stuck) +
    # the worker's OWN non-audit STUCK_NEEDS_HUMAN note (distinguishes a genuine
    # fork from a spurious bare label — the test-stuck-primary-relaxed negative
    # posture). status here is already non-closed/non-empty/parseable and the
    # blocked+human case returned above, so this is the open|in_progress
    # complement. Reuses the SAME breaker/retry-EXEMPT STUCK dispatch
    # (_drive_blocked_for_human: flips blocked + authors the §7.4/69u8 dossier),
    # so it leaves the ready set AND is Inbox-visible. Does NOT reopen uxvi4: the
    # lookbehind drops the runner's own residue and a resolved bead has no label.
    if _bead_has_human_label "$id" && _bead_has_stuck_ask_note "$id"; then
      echo "STUCK_NEEDS_HUMAN"; return
    fi
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

# ── BC-26 — desktop notification (claude-tools-v2cut.4 port) ──────────────────
# macOS desktop notification + terminal bell. Best-effort, NEVER fails the run;
# a silent no-op when osascript is absent (Linux / CI / the conformance harness).
# Double-quotes are escaped for the AppleScript string literal. SCAFFOLDING
# (platform mechanism); the SCAR is the SELECTIVE-silence call policy at the
# sites below — routine/expected classes (SUCCESS, RATE_LIMIT, first
# TASK_NOT_CLOSED, the deliberate-stuck path) are deliberately NOT notified
# (alert fatigue). No remote/push transport here — that is the la_report_* seam
# (BC-63). Args: $1 = title, $2 = body.
notify_user() {
  local title="$1" body="$2"
  printf '\a' 2>/dev/null || true
  if command -v osascript >/dev/null 2>&1; then
    local safe_title="${title//\"/\\\"}"
    local safe_body="${body//\"/\\\"}"
    osascript -e "display notification \"$safe_body\" with title \"$safe_title\"" 2>/dev/null || true
  fi
}

# ── BC-25 — scan_tool_errors (claude-tools-v2cut.4 port) ──────────────────────
# Side-effect-only scan of the merged stream for tool_result entries with
# is_error:true. Called UNCONDITIONALLY after the classification dispatch (incl.
# SUCCESS / STUCK) in st_post_task: it NEVER changes the classification or the
# exit code — it only appends an incident row + a greppable beads note (+ a
# notify_user for the subagent case). A cheap `grep -qF` pre-filter skips the jq
# pass entirely when no error markers exist. Only THREE pattern-matched
# signatures are surfaced — subagent-not-found, permission, MCP-down — because
# raw is_error COUNTS would be dominated by routine probes (Read-on-missing-file,
# grep-no-match). SCAR (intent): an inline-recovered tool failure still means the
# agent didn't do what we asked — surface it without failing the run.
# SCAFFOLDING (mechanism): the regex strings are CLI-format-coupled and brittle
# by the code's own admission. Args: $1 = stream file, $2 = task_id.
scan_tool_errors() {
  local stream="$1" task_id="$2"
  [[ -n "$stream" && -f "$stream" ]] || return 0
  # Cheap pre-filter: skip the jq pass entirely if no error markers exist.
  grep -qF '"is_error":true' "$stream" 2>/dev/null || return 0
  # .content can be a string OR an array of {type,text} parts — handle both.
  local all_errors
  all_errors="$(jq -r '
    .. | objects? | select(.type? == "tool_result" and .is_error? == true) |
    (.content | if type == "string" then .
                elif type == "array" then (map(select(.type? == "text") | .text) | join(" "))
                else "" end)
  ' "$stream" 2>/dev/null || true)"
  [[ -z "$all_errors" ]] && return 0
  local subagent_hits perm_hits mcp_hits
  subagent_hits="$(echo "$all_errors" | grep -cE "Agent type '[^']+' not found" 2>/dev/null || true)"
  perm_hits="$(echo "$all_errors" | grep -cE "Permission denied|is not allowed" 2>/dev/null || true)"
  mcp_hits="$(echo "$all_errors" | grep -cE "MCP server.*(unavailable|failed|not connected)" 2>/dev/null || true)"
  if [[ "${subagent_hits:-0}" -gt 0 ]]; then
    local subagent_names
    subagent_names="$(echo "$all_errors" | grep -oE "Agent type '[^']+'" | sort -u | sed -E "s/Agent type '([^']+)'/\1/" | paste -sd, - 2>/dev/null || echo "?")"
    local msg="subagent-unavailable: $subagent_names (×$subagent_hits)"
    bd update "$task_id" --append-notes="Runner: tool-error $msg" 2>/dev/null || true
    record_incident "$task_id" "TOOL_ERROR:$msg" "-"
    notify_user "beads-runner: subagent unavailable" "$task_id — $subagent_names"
  fi
  if [[ "${perm_hits:-0}" -gt 0 ]]; then
    bd update "$task_id" --append-notes="Runner: tool-error permission-denied (×$perm_hits)" 2>/dev/null || true
    record_incident "$task_id" "TOOL_ERROR:permission-denied (×$perm_hits)" "-"
  fi
  if [[ "${mcp_hits:-0}" -gt 0 ]]; then
    bd update "$task_id" --append-notes="Runner: tool-error mcp-unavailable (×$mcp_hits)" 2>/dev/null || true
    record_incident "$task_id" "TOOL_ERROR:mcp-unavailable (×$mcp_hits)" "-"
  fi
}

# BC-56 (claude-tools-apen → v2 port claude-tools-v2cut.3): post-close discipline
# audit. Catches the AGENT-BYPASS-VIA-CAP class — a worker that burns the 8-block
# close-checklist Stop-hook cap (claude-tools-td0y / BC-65, ported in 2fkp) and
# closes the bead ANYWAY. Mirrors the close-checklist.sh checks at the runner
# level after the session ends, so a bypass leaves a regression bead + incident,
# not a silent disappear. Only meaningful on a real close (the SUCCESS path), so
# st_post_task calls it from there.
#
# Args: $1 = task_id, $2 = session anchor (forensic backtrack handle — the merged
# stream-capture path STREAM_FILE in v2; v1 passed LOG_BASE).
# Side effects only: records incident, files regression bead, appends note. Never
# reopens the original bead — that decision belongs to the human triaging the
# regression bead (reopening here could let the same broken worker loop on it).
post_close_audit() {
  local task_id="$1" session_anchor="${2:-}"
  local project_dir="$PWD"

  # claude-tools-d3w9 test-isolation seam: the conformance harness fakes the
  # worker (claude/bd stubbed, commit-less throwaway workdir), so this discipline
  # audit can only ever fire spurious close_without_commit / dirty_tree /
  # missing_debrief findings and their side-effects (Runner: note, incident row,
  # regression bead) — none of which the harness's INTERFACE §3/§7/§8 assertions
  # model, and the audit is self-perpetuating under the faked worker (each
  # commit-less close spawns a bead that is itself closed commit-less). The
  # audited behaviour is out of that harness's scope and has its own BC-56 -tree
  # rig, so the harness opts out via this seam (mirrors RUNNER_EXIT_ON_DRAIN).
  # Defaults OFF — production ALWAYS runs the audit; the BC-56 rig opts back IN.
  [[ -n "${RUNNER_SKIP_POST_CLOSE_AUDIT:-}" ]] && return 0

  # Re-verify the bead is actually closed. SUCCESS classification is fail-open on
  # bd-show errors (classify_failure) — don't audit if we can't read the status,
  # since we can't tell whether the close even happened.
  if ! command -v bd >/dev/null 2>&1; then return 0; fi
  local status
  status="$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)"
  [[ "$status" == "closed" ]] || return 0

  local failures=()

  # Check 1: close-without-commit — the primary signal for the bypass case.
  # Mirrors close-checklist.sh check 3 (--since='1 hour ago'). NOTE: uses
  # `--format=%h` + emptiness check rather than `wc -l`, because git's `format:`
  # (and the default `format=`) emit no trailing newline — `wc -l` on a single
  # matching hash returns 0, indistinguishable from no-match. Emptiness is the
  # honest signal. (`|| true` keeps a commit-less repo from tripping pipefail.)
  if command -v git >/dev/null 2>&1 && [[ -d "$project_dir/.git" ]]; then
    local grep_out
    grep_out="$(git -C "$project_dir" log --grep="$task_id" -1 --since='1 hour ago' --format=%h 2>/dev/null || true)"
    if [[ -z "$grep_out" ]]; then
      failures+=("close_without_commit")
    fi
  fi

  # Check 2: dirty tree (excluding .beads/issues.jsonl, debrief, runner-log
  # scratch, .stop-beads). Mirrors close-checklist.sh check 2 — a closed bead
  # with a dirty tree means the worker's diff is about to be smuggled into the
  # next bead's commit. issues.jsonl is excluded because bd close itself writes
  # to it as a side-effect of flipping status; authoritative state is in Dolt
  # (claude-tools-u4ms).
  if command -v git >/dev/null 2>&1 && [[ -d "$project_dir/.git" ]]; then
    local dirty
    dirty="$(git -C "$project_dir" status --porcelain --untracked-files=all 2>/dev/null \
      | grep -vE '^.{3}(\.beads/issues\.jsonl$|\.beads/[^/]*-debrief\.txt$|\.beads/runner-logs/|\.stop-beads$)' \
      || true)"
    if [[ -n "$dirty" ]]; then
      failures+=("dirty_tree")
    fi
  fi

  # Check 3: wrapup marker (only if the workspace has a /wrapup skill).
  if [[ -f "$project_dir/.claude/skills/wrapup/SKILL.md" ]]; then
    local notes
    notes="$(bd show "$task_id" --long --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null)"
    if ! printf '%s' "$notes" | grep -q 'wrapup-reviewed:'; then
      failures+=("wrapup_not_invoked")
    fi
  fi

  # Check 4: debrief presence. Mirrors close-checklist.sh check 5 (>=40 chars).
  local notes2
  notes2="$(bd show "$task_id" --long --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null)"
  if [[ -z "$notes2" || ${#notes2} -lt 40 ]]; then
    failures+=("missing_debrief")
  fi

  if (( ${#failures[@]} == 0 )); then
    return 0
  fi

  local failed_csv
  failed_csv="$(printf '%s,' "${failures[@]}" | sed 's/,$//')"

  # 1. File the regression bead FIRST so the note we append below can carry its
  #    id — otherwise a `bd create` failure would leave the original bead
  #    claiming a regression was filed when it wasn't. P1 because a silently-
  #    closed bead is the exact failure mode this is designed to surface; sitting
  #    in the backlog defeats the purpose. Labeled discipline-bypass so it's
  #    filterable; NOT human-triage-labeled by default (feedback_beads_human_triage_label).
  local desc
  desc="Auto-filed by runner.sh post-close audit (claude-tools-apen; v2 BC-56).

Bead $task_id was closed despite failing the close-discipline checks. This
typically means the close-checklist.sh Stop hook was bypassed — the 8-block
cap was burned by repeated retries, or the runner-session gating failed open.

Failed checks: $failed_csv
Session anchor: ${session_anchor:-unknown}
Runner log dir: $LOG_DIR

Human triage:
- Pull the stream-json and runner log for the session anchor (forensic).
- Inspect git log / git diff — was real work done, just not committed?
- If the close was premature, 'bd reopen $task_id' and finish properly.
- If the hook itself let it slip, investigate beads-runner/hooks/close-checklist.sh.

Cross-ref: claude-tools-apen (this audit), claude-tools-td0y (the hook)."
  local create_output regression_id=""
  create_output="$(bd create \
    --title "discipline-bypass: $task_id closed without $failed_csv" \
    -d "$desc" \
    --type=bug \
    -p 1 \
    --labels "discipline-bypass" 2>&1)" || true
  # `bd create` (text mode) emits "✓ Created issue: <prefix-id> — title".
  # Mirrors create_analysis_task's parse (same source format). Empty on parse
  # failure ⇒ the note below honestly says "regression bead may have failed".
  regression_id="$(printf '%s' "$create_output" | sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1)"

  # 2. Incident log entry — forensic anchor (carries the session/log handle so
  #    the stream-json post-mortem is one ls away). The classification follows
  #    the existing INCIDENTS schema (TAB-separated, "CLASS:detail" tag form).
  local incident_tag="DISCIPLINE_BYPASS:$failed_csv"
  [[ -n "$regression_id" ]] && incident_tag="$incident_tag (regression=$regression_id)"
  record_incident "$task_id" "$incident_tag" "${session_anchor:--}"

  # 3. Append a marker note on the original bead so `bd show` reveals the bypass
  #    at a glance. Cross-reference the regression bead id if we got one back —
  #    otherwise be honest that the file step may have failed.
  local note="Runner: DISCIPLINE_BYPASS $failed_csv (session=${session_anchor:-unknown})"
  if [[ -n "$regression_id" ]]; then
    note="$note — regression bead $regression_id filed (claude-tools-apen)"
  else
    note="$note — regression-bead create FAILED, see incidents.log (claude-tools-apen)"
  fi
  bd update "$task_id" --append-notes="$note" 2>/dev/null || true

  # 4. Best-effort desktop notification. BC-26 `notify_user` now lands in v2 (ported
  #    in claude-tools-v2cut.4); the `command -v` guard is kept as defensive
  #    optional-seam posture (BC-43) — it is a silent no-op if the function is ever
  #    absent, and discipline-bypass IS one of BC-26's "noisy" notify classes.
  if command -v notify_user >/dev/null 2>&1; then
    local notify_body="$task_id closed without $failed_csv"
    [[ -n "$regression_id" ]] && notify_body="$notify_body — $regression_id filed"
    notify_user "beads-runner: discipline bypass" "$notify_body"
  fi
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
# inherited (the BC-36 mandate). Each strands the in-flight bead `in_progress`;
# the recovery is TWO-PLANE and needs BOTH halves: the NEXT runner's startup
# orphan snapshot (st_starting → ORPHANED_IDS, BC-02/03/04, claude-tools-v2cut.2)
# re-presents the bead on the WORK plane (it is invisible to `bd ready`), and the
# §6.1 lease expiry recovers the STRONG plane so that runner's re-claim re-acquires
# the crashed owner's expired lease. Lease-expiry ALONE does NOT recover the bead —
# nothing would re-attempt the task_ref without the snapshot. (Backstop the v1
# PID-1 reaper *cron* was a stopgap for.):
#  R1 SIGKILL of the runner ITSELF runs no trap (irreducible — no process can
#     clean up after its own SIGKILL). The strand is recovered at the next
#     runner's startup orphan snapshot (claude-tools-v2cut.2), not in-process.
#  R2 The reset-to-open issues an UNbounded `bd update` AFTER signals are
#     masked; if `bd`/Dolt is itself wedged (the BD_UNAVAILABLE scenario) the
#     strand window is wider than just R1 — the operator's recourse is SIGKILL
#     (→ R1). A bounded `bd` is intentionally NOT added: `timeout` is
#     non-portable here and the next-startup orphan snapshot recovers the bead
#     (lease-expiry recovers its strong-plane lease so that re-claim succeeds).
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
    job_lease_release_local "$CURRENT_TASK_ID" >/dev/null 2>&1 || true   # §6.2/AD2.2 — graceful interrupt relinquishes the local hold too (a SIGKILL skips this ⇒ cache persists as the orphan-resume signal)
    remove_task_claim "$CURRENT_TASK_ID"   # claude-tools-uxc1: clean exit reset it to open — drop our claim (a SIGKILL leaves it as the crash-orphan signal)
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
  # claude-tools-2fkp: the per-task close-discipline ephemera — the post-terminal
  # stamp, the --settings JSON, and the current-task pointer — are NOT classifier
  # inputs (unlike STREAM_FILE/PROC_SNAPSHOT, deliberately LEFT above), so they
  # are cleaned on EVERY exit path. Clearing current-task here stops a respawning
  # runner from seeing a stale id on its first hook firing.
  rm -f "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}" "$LOG_DIR/current-task" 2>/dev/null || true

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
# I4 (claude-tools-uxvi4): the staged worker teardown used by the agent-action
# control-marker kill (design/agent-action.md §4). Byte-identical posture to the
# BC-22 idle-kill SCAR sequence (SIGINT first so the SDK flushes in-flight
# HTTP-retry state to stderr, up to 10×1s grace, then SIGKILL) but extracted as a
# helper so the FROZEN idle-kill block stays untouched. Signals the root worker
# pid; full process-tree teardown is T2.4's owned surface (the EXIT funnel).
_watchdog_signal_worker() {
  local pid="$1" _
  # Log to STDERR: this runs inside _watchdog_scan_agent_action's $(...) capture,
  # so a stdout echo would pollute the scan's return value. stderr still lands in
  # the runner's log (the watchdog subshell's fds are the runner's).
  echo "  watchdog: staged kill — interrupt first, up to 10s grace, then hard-kill" >&2
  echo "  watchdog: SIGINT sent" >&2
  kill -INT "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || break
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "  watchdog: SIGKILL sent (grace elapsed)" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

# I4 (claude-tools-uxvi4): honor a daemon-dropped agent-action CONTROL MARKER.
# The watchdog OWNS CLAUDE_PID + the kill path + the idle-grace timer, so it is
# the natural place to read the marker each WATCHDOG_POLL tick (design/agent-
# action.md §4: "honored each 15s tick"). The daemon (agent-action-poll.sh) drops
# <ws>/.beads/runner-logs/agent-action/<action_id>.json for the process intents;
# this CONSUMES every marker it reads (the daemon already acked it engine-side)
# and acts only on a marker targeting the CURRENT bead — a stale/late marker for
# a bead the worker already moved past is dropped without effect. Echoes:
#   ""       — nothing applicable this tick
#   "nudge"  — a grace extension (the caller resets last_progress — veto one window)
#   "kill"   — a kill-retry/kill-gate was requested AND already performed here
# (kill wins over nudge; classification rides the existing WATCHDOG_KILL marker so
# the FROZEN §8.1 exit table is untouched: kill-retry re-dispatches the reset-to-
# open bead, kill-gate's daemon-applied gate:* label then makes J4 refuse re-pickup.)
_watchdog_scan_agent_action() {
  local dir="$1" bead="$2" pid="$3" sig="$4" mf intent mbead acted=""
  [[ -n "$dir" && -d "$dir" ]] || { printf ''; return 0; }
  for mf in "$dir"/*.json; do
    [[ -e "$mf" ]] || continue
    intent="$(jq -r '.intent // ""' "$mf" 2>/dev/null)" || intent=""
    mbead="$(jq -r '.bead_ref // ""' "$mf" 2>/dev/null)" || mbead=""
    rm -f "$mf" 2>/dev/null || true   # consume (the daemon already acked it engine-side)
    [[ -n "$mbead" && -n "$bead" && "$mbead" != "$bead" ]] && continue  # stale/late ⇒ moot
    # NB: informational echoes go to STDERR — this function's STDOUT is captured
    # by the caller as the action verb (printf at the end), so a stray stdout
    # log line would corrupt the "nudge"/"kill" return.
    case "$intent" in
      nudge)
        echo "  watchdog: agent-action NUDGE (control marker) — vetoing the pending kill one more window, NO terminate" >&2
        [[ -z "$acted" ]] && acted="nudge"
        ;;
      kill-retry|kill-gate)
        echo "  watchdog: agent-action ${intent} (control marker) — terminating the worker on Brian's command" >&2
        echo "WATCHDOG_KILL=1"          >> "$sig"   # FROZEN §8.1 class (re-dispatch / gate-refuse semantics)
        echo "AGENT_ACTION_KILL=${intent}" >> "$sig"  # observability only (NOT a classifier input)
        _watchdog_signal_worker "$pid"
        acted="kill"
        break
        ;;
    esac
  done
  printf '%s' "$acted"
}

_watchdog_loop() {
  local pid="$1" stream="$2" sig="$3" snap="$4" post_terminal_file="${5:-}"
  local aa_marker_dir="${6:-}" aa_bead="${7:-}"   # I4: agent-action control-marker seam
  local now last_progress prev_bytes prev_cpu bytes cpu idle warned=0
  local inflight effective_timeout pt_at pt_age aa_act
  now="$(date +%s)"; last_progress="$now"
  prev_bytes="$(wc -c < "$stream" 2>/dev/null | tr -d ' ')"; prev_bytes="${prev_bytes:-0}"
  prev_cpu="$(_tree_cpu_secs "$pid" 2>/dev/null)"; prev_cpu="${prev_cpu:-0}"
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$WATCHDOG_POLL"
    kill -0 "$pid" 2>/dev/null || break
    now="$(date +%s)"
    # I4 (claude-tools-uxvi4): honor any daemon-dropped agent-action control
    # marker FIRST — a Brian-initiated kill must win over (and pre-empt) the
    # idle-progress heuristics below, and a nudge must veto a kill that is about
    # to fire this same tick. A kill is performed in-scan; a nudge resets the
    # idle-grace timer (one more soft window — the §4 "veto, don't terminate").
    if [[ -n "$aa_marker_dir" ]]; then
      aa_act="$(_watchdog_scan_agent_action "$aa_marker_dir" "$aa_bead" "$pid" "$sig")"
      if [[ "$aa_act" == "kill" ]]; then
        break                       # worker already signaled by the scan
      elif [[ "$aa_act" == "nudge" ]]; then
        last_progress="$now"; warned=0
        continue                    # skip this tick's idle check — grace extended
      fi
    fi
    # claude-tools-2fkp (port of td0y): post-terminal SIGKILL backstop. The SDK
    # terminal record (`terminal_reason` or `type":"result"`) means claude is
    # contract-done; if it is STILL alive POST_TERMINAL_GRACE seconds later it is
    # wedged on an orphan child (the krxv pattern: a run_in_background Bash poller
    # keeps Node's event loop alive past the terminal record — which ALSO keeps
    # stream/CPU "progress" fresh, so the IDLE_TIMEOUT path below NEVER fires).
    # v2 has no concurrent tail -f parser (v1's stamping seam), so the watchdog
    # BOTH stamps the marker (first poll it is greppable in the stream) AND
    # enforces the grace. Independent of IDLE_TIMEOUT; immune to the inflight mult.
    if [[ -n "$post_terminal_file" ]]; then
      if [[ ! -e "$post_terminal_file" ]] \
         && grep -Eq '"terminal_reason"|"type":"result"' "$stream" 2>/dev/null; then
        echo "$now" > "$post_terminal_file" 2>/dev/null || true
        echo "  watchdog: SDK terminal record detected — SIGKILL claude in ${POST_TERMINAL_GRACE:-60}s if still alive (claude-tools-2fkp)"
      fi
      if [[ -f "$post_terminal_file" ]]; then
        pt_at="$(tr -d '[:space:]' < "$post_terminal_file" 2>/dev/null)"
        if [[ "$pt_at" =~ ^[0-9]+$ ]] && (( pt_at >= 1704067200 )); then
          pt_age=$(( now - pt_at ))
          if (( pt_age >= ${POST_TERMINAL_GRACE:-60} )); then
            echo "  POST-TERMINAL SIGKILL: SDK terminal record was ${pt_age}s ago (grace=${POST_TERMINAL_GRACE:-60}s); claude pid=$pid still alive — likely orphan-child wedge (claude-tools-2fkp)."
            echo "POST_TERMINAL_KILL=1" >> "$sig"
            { echo "=== post-terminal snapshot (age=${pt_age}s, grace=${POST_TERMINAL_GRACE:-60}s) ==="
              ps -o pid,ppid,stat,etime,pcpu,pmem,time,command -p \
                 "$(_tree_pids "$pid" | tr '\n' ',' | sed 's/,$//')" 2>&1 || true
            } >> "$snap" 2>&1 || true
            kill -KILL "$pid" 2>/dev/null || true
            break
          fi
        fi
      fi
    fi
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
  echo "Running: $MODE_LABEL"   # BC-37 — surfaces "all permissions bypassed" under --yolo (claude-tools-92l3)
  rm -f "$STOP_FILE" 2>/dev/null || true       # clean slate (stop is consumed, not sticky)
  # claude-tools-2fkp: clear any stale current-task pointer a previous runner
  # left behind (SIGKILL, crash). It is regenerated per-task at claim; a stale
  # id here would make the close-discipline hook enforce against the WRONG bead
  # on the first tool call of the next task before the new id is written.
  rm -f "$LOG_DIR/current-task" 2>/dev/null || true

  # ── BC-30 — age-based artifact rotation, EXACTLY ONCE at startup ────────────
  # (claude-tools-v2cut.4 port.) Prune artifacts older than LOG_RETENTION_DAYS
  # here in st_starting — which is reached EXACTLY ONCE (STARTING→RECONCILE never
  # returns) — and NEVER per-iteration, so it cannot race the artifacts a running
  # task (this invocation or a concurrent one) is actively producing. .gitignore
  # and incidents.log are name-excluded (incidents.log is the append-only
  # forensic ledger — BC-24's rotation exemption). Runs BEFORE the orphan
  # snapshot below: a >14-day-old claim file is itself stale (its owner is long
  # dead) and a missing claim resolves to "skip" (safe).
  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -type f ! -name '.gitignore' ! -name 'incidents.log' \
      -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  fi

  # ── BC-31 — pre-flight asset snapshot (DIAGNOSTIC-ONLY, non-aborting) ────────
  # (claude-tools-v2cut.4 port.) Project agents/skills resolve relative to cwd; a
  # runner launched from the wrong directory (or an empty .claude/agents) makes
  # agents that worked interactively silently fail inside `claude`. Snapshot the
  # environment once so a missing-asset condition is obvious from line 1. A count
  # of 0 does NOT abort — the non-aborting nature is itself characterized behavior
  # (a rewrite that hard-gates here is a behavior change). preflight.log is
  # OVERWRITTEN each run (vs incidents.log which appends).
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  local preflight_log="$LOG_DIR/preflight.log"
  {
    echo "=== preflight $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "pwd: $(pwd)"
    echo ""
    echo "=== .claude/agents ==="
    if [[ -d .claude/agents ]]; then ls -1 .claude/agents; else echo "(no .claude/agents directory)"; fi
    echo ""
    echo "=== .claude/skills ==="
    if [[ -d .claude/skills ]]; then ls -1 .claude/skills; else echo "(no .claude/skills directory)"; fi
    echo ""
    echo "=== claude version ==="
    claude --version 2>&1 || echo "(claude --version failed)"
    echo ""
    echo "=== bd version ==="
    bd version 2>&1 || echo "(bd version failed)"
  } > "$preflight_log" 2>&1 || true
  local preflight_agents=0 preflight_skills=0
  [[ -d .claude/agents ]] && preflight_agents="$(find .claude/agents -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  [[ -d .claude/skills ]] && preflight_skills="$(find .claude/skills -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
  echo "Pre-flight: ${preflight_agents} project agent(s), ${preflight_skills} project skill(s) — $preflight_log"

  # ── BC-02/BC-03 — startup in_progress snapshot = crash orphans ──────────────
  # claude-tools-v2cut.2 (v2c3 coverage-audit gap). A prior runner that died
  # SIGKILLed runs NO EXIT trap (the irreducible BC-36 R1 residual) — and even a
  # graceful exit against a wedged bd (R2) — strands its in-flight bead
  # `in_progress`. That bead is INVISIBLE to `bd ready` (which returns only
  # `open`), so st_reconcile's new-work poll never re-presents it. The §6.1 lease
  # orphan-recovery (test-coordinator-lease.sh EXIT-3) recovers only the STRONG
  # plane — a NEW owner can re-acquire the crashed owner's EXPIRED lease — but it
  # is reached ONLY when some runner re-attempts that task_ref, and nothing in v2
  # ever does, because the work-plane bead status is never reset. The Coordinator
  # reconcile (job 4) carries desired-state (running/paused/stopped), not a
  # per-bead reopen. So lease-expiry alone does NOT recover the bead — the line-947
  # "lease-expiry already recovers the bead" claim holds only for the lease, not
  # the bead status. THIS snapshot is the missing work-plane half: it re-presents
  # the orphan as a CANDIDATE so st_claim's lease re-acquire can compose with the
  # strong-plane recovery.
  #
  # We snapshot ONCE, at startup. A bead going in_progress LATER is a live
  # sibling's and is never adopted (it is simply not in this set). claude-tools-uxc1
  # (inbox-lifecycle §8.3.3) narrows the snapshot further: an in_progress bead is
  # adopted ONLY if a PID claim file proves it is THIS workspace's runner's crash
  # orphan — our runner_id + a DEAD owning pid (_adopt_orphan_by_claim is the gate).
  # No claim (a live interactive session / manual `bd update` set it), a LIVE pid (a
  # live sibling runner), or a FOREIGN runner_id are all SKIPPED — closing the
  # dup-work hazard where the runner adopted an externally-owned in_progress task.
  # BC-03: the empty case yields an EMPTY array — built element-by-element from a
  # while-read that skips blank lines, so there is NO `bd show ""`. The v1
  # `read -ra` empty-field quirk + its one-empty-element guard is SCAFFOLDING
  # (BEHAVIORAL-CONTRACT BC-03) and is deliberately NOT transcribed — this list
  # construction simply cannot produce a phantom empty element.
  ORPHANED_IDS=()
  local _orphans_raw _oid _seen=0
  _orphans_raw="$(safe_capture BD_UNAVAILABLE "" -- bd list --status=in_progress --json | jq -r '.[].id // empty' 2>/dev/null || true)"
  while IFS= read -r _oid; do
    [[ -z "$_oid" ]] && continue
    _seen=$((_seen + 1))
    # claude-tools-uxc1: PID-validate before adopting — not every in_progress bead
    # is OUR crash orphan (the dup-work hazard §8.3.3 closes).
    if _adopt_orphan_by_claim "$_oid"; then
      ORPHANED_IDS+=("$_oid")
    fi
  done <<< "$_orphans_raw"
  if [[ ${#ORPHANED_IDS[@]} -gt 0 ]]; then
    echo "runner: startup in_progress snapshot — ${#ORPHANED_IDS[@]} PID-validated crash-orphan(s) eligible for resume (of $_seen in_progress bead(s) seen): ${ORPHANED_IDS[*]}"
  elif [[ $_seen -gt 0 ]]; then
    echo "runner: startup in_progress snapshot — $_seen in_progress bead(s) seen, none are this runner's crash orphans (no-claim / live-pid / foreign all skipped, claude-tools-uxc1) — adopting 0"
  fi

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

# ── Pickup label gate (claude-tools-v2c3) ────────────────────────────────────
# Returns 0 (GATED — skip-not-fail) when the candidate carries a label the
# autonomous runner must not claim; 1 (clean) otherwise. ONE `bd label list`
# fetch serves BOTH gates (the gates.md §5.2 hoist):
#   • gate:<id> Gate label — our native hold (uxvj4 / gates.md §5). ALWAYS-ON,
#     independent of RUNNER_NO_CLAIM_LABELS; prefix match because gate ids are
#     dynamic and cannot live in an exact-match list. The ^gate:<id-shape>$
#     anchor guards against gateway/gate-foo false positives (gates.md §5.3).
#   • RUNNER_NO_CLAIM_LABELS — exact-match human-* fixtures (BC-08b, ported
#     from run-beads-tasks.sh:716-744). Skip-not-fail, sticky across bd reloads
#     (the runner cannot lift the label itself).
# Skip-not-fail posture (no incident, no FAILED++, no lease) matches v1: the
# bead stays open-and-ready for the human to claim/lift; st_reconcile advances
# to the next candidate (no starvation). Fail-OPEN on a bd label-list error
# (empty labels ⇒ not gated ⇒ claimed), matching v1's `|| echo ""`.
_candidate_label_gated() {
  local id="$1" labels hit=""
  labels="$(safe_capture BD_UNAVAILABLE "" -- bd label list "$id" --json | jq -r '.[]?' 2>/dev/null || echo "")"

  # Gate (gate:<id>) — always-on, prefix match.
  if printf '%s\n' "$labels" | grep -qE '^gate:[a-z0-9][a-z0-9-]*$' 2>/dev/null; then
    local g; g="$(printf '%s\n' "$labels" | grep -m1 -E '^gate:[a-z0-9][a-z0-9-]*$')"
    echo "  Skipping: gate label '$g' present (runner respects Gates — lift it from the Gates facet)"
    return 0
  fi

  # RUNNER_NO_CLAIM_LABELS — exact-match human-* fixtures.
  if [[ -n "${RUNNER_NO_CLAIM_LABELS:-}" ]]; then
    local gate_label IFS=','
    for gate_label in $RUNNER_NO_CLAIM_LABELS; do
      gate_label="${gate_label## }"; gate_label="${gate_label%% }"
      [[ -z "$gate_label" ]] && continue
      if printf '%s\n' "$labels" | grep -qxF "$gate_label" 2>/dev/null; then hit="$gate_label"; break; fi
    done
    if [[ -n "$hit" ]]; then
      echo "  Skipping: label '$hit' present (RUNNER_NO_CLAIM_LABELS — human-driven fixture, not for autonomous claim)"
      return 0
    fi
  fi
  return 1
}

# ── Workability validation (BC-06/07/08/52-DiD/08d, claude-tools-v2cut.1) ─────
# Port of v1 run-beads-tasks.sh validate_task (745-855), folded into the
# st_reconcile candidate WALK (BC-51): a candidate this rejects is SKIPPED-not-
# failed and the walk advances to the next bead — no FAILED++, no lease, no
# incident (the same cost-free posture as _candidate_label_gated). The label
# gate (_candidate_label_gated, BC-08b/uxvj4) already ran in the walk BEFORE
# this, so this fn covers the REMAINING v1 validate_task classes the v2c3
# coverage audit found absent from runner.sh (the cutover-blocker: without it v2
# would CLAIM a late-blocked / container / cross-repo bead):
#   BC-06  bd blocked TOCTOU re-check — a dep added AFTER the bd ready snapshot.
#   BC-52  epic defense-in-depth — redundant with the query-layer jq filter in
#          the walk (line ~1640), kept for v1 parity + dual bd-shape coverage.
#   BC-07  bd show --children self-inclusion filter + {<id>:[…]} object flatten.
#   BC-08  all-children-closed ⇒ auto-close the parent; some open ⇒ skip it.
#   BC-08d cross-workspace scope check (RUNNER_SIBLING_PREFIXES) — the LAST check
#          (the bead is otherwise claimable by here); no-op when the env is empty.
# Check order matches v1 (blocked → epic → parent → cross-ws). Returns 0
# (workable ⇒ select) / 1 (skip ⇒ walk advances). bd calls ride safe_capture
# (BD_UNAVAILABLE) with v1's fail-postures preserved: a degraded `bd blocked`
# ⇒ "" ⇒ not-blocked (claim, matching v1's `|| true`); a degraded children read
# ⇒ "[]" ⇒ 0 children (fail-CLOSED to zero, never a FALSE parent skip).
# SCOPE NOTE (matches v1): this is applied ONLY to bd-ready candidates, NOT to
# resumed crash-orphans — v1's next_task() orphan pass likewise does not
# re-validate (a resumed orphan re-discovers a post-crash block itself).
_validate_workable() {
  local id="$1"

  # BC-06 — re-check bd blocked (a dependency may have been added AFTER bd ready
  # produced the snapshot we are walking). Skip-not-fail (no retry/breaker cost).
  local blocked_ids
  blocked_ids="$(safe_capture BD_UNAVAILABLE "" -- bd blocked --json | jq -r '.[].id // empty' 2>/dev/null || true)"
  if printf '%s\n' "$blocked_ids" | grep -qxF "$id" 2>/dev/null; then
    echo "  Skipping: has unresolved dependencies (added after task was queued)"
    return 1
  fi

  # BC-52 (defense-in-depth) — an epic that slipped the query-layer filter. Both
  # bd shapes: `bd show` wraps the object in a 1-elem array + names the field
  # `issue_type`; `bd list` is top-level `type`. Accept either.
  local task_type
  task_type="$(safe_capture BD_UNAVAILABLE "" -- bd show "$id" --json \
               | jq -r '(if type == "array" then .[0] else . end) | (.issue_type // .type // "")' 2>/dev/null || echo "")"
  if [[ "$task_type" == "epic" ]]; then
    echo "  Skipping: epic (containers are not workable; see children for actual work)"
    return 1
  fi

  # BC-07 + BC-08 — parent/container check. `bd show --children` INCLUDES self
  # and wraps the children array in a {<parent-id>: [...]} object (a bd quirk).
  # Flatten that to the children array and filter self out; fail-CLOSED to [] on
  # any jq error (treat as 0 children — never a false "skipping parent"). All
  # children closed ⇒ auto-close the parent and skip; some open ⇒ skip it.
  local children child_count
  children="$(safe_capture BD_UNAVAILABLE "[]" -- bd show "$id" --children --json)"
  children="$(printf '%s' "$children" | jq --arg id "$id" '
    ((if type == "object" then [.[] | .[]?] else . end) | map(select(.id? != $id)))
  ' 2>/dev/null || echo "[]")"
  child_count="$(printf '%s' "$children" | jq 'length' 2>/dev/null || echo "0")"
  if [[ "${child_count:-0}" -gt 0 ]]; then
    local open_children
    open_children="$(printf '%s' "$children" | jq '[.[] | select(.status != "closed")] | length' 2>/dev/null || echo "0")"
    if [[ "${open_children:-0}" -eq 0 ]]; then
      echo "  Auto-closing parent task: all $child_count children completed"
      safe_capture BD_UNAVAILABLE "" -- bd close "$id" --reason="All children completed" >/dev/null
    else
      echo "  Skipping parent task: $open_children of $child_count children still open"
    fi
    return 1
  fi

  # BC-08d — cross-workspace scope check (LAST; port of v1 806-853). Opt-in:
  # with RUNNER_SIBLING_PREFIXES empty (single-repo default) this whole block is
  # skipped — no bd calls. A bead whose title/description references a declared
  # SIBLING prefix's id is FLAGGED (loud skip-not-fail) unless it carries a
  # RUNNER_TRACKING_ONLY_LABELS label (cross-ref is its job).
  if [[ -n "${RUNNER_SIBLING_PREFIXES:-}" ]]; then
    # The local prefix is the bead's own id minus its short suffix — the bead
    # lives in THIS workspace's DB, so its own prefix IS the local prefix.
    local local_prefix="${id%-*}"
    local show_json title desc haystack
    show_json="$(safe_capture BD_UNAVAILABLE "[]" -- bd show "$id" --json)"
    title="$(printf '%s' "$show_json" | jq -r '(if type == "array" then .[0] else . end) | (.title // "")' 2>/dev/null || echo "")"
    desc="$(printf '%s' "$show_json"  | jq -r '(if type == "array" then .[0] else . end) | (.description // "")' 2>/dev/null || echo "")"
    haystack="$title"$'\n'"$desc"
    local sib hit=""
    local -a sib_arr=()
    IFS=',' read -ra sib_arr <<< "$RUNNER_SIBLING_PREFIXES"
    for sib in "${sib_arr[@]}"; do
      sib="${sib## }"; sib="${sib%% }"
      [[ -z "$sib" ]] && continue
      [[ "$sib" == "$local_prefix" ]] && continue   # never flag our own prefix
      # Match a <sibling-prefix>-<shortid> token. The left boundary (start-of-line
      # or a non-id char) keeps it from matching inside a longer hyphenated word;
      # the second grep extracts the clean id for the message.
      hit="$(printf '%s' "$haystack" \
            | grep -oE "(^|[^[:alnum:]-])${sib}-[a-z0-9]+" 2>/dev/null \
            | grep -oE "${sib}-[a-z0-9]+" 2>/dev/null | head -1 || true)"
      [[ -n "$hit" ]] && break
    done
    if [[ -n "$hit" ]]; then
      # A tracking-only bead is allowed to reference sibling ids. Fetch labels
      # only now — the common no-hit path paid nothing.
      local task_labels tlabel exempt=""
      local -a tlabel_arr=()
      task_labels="$(safe_capture BD_UNAVAILABLE "" -- bd label list "$id" --json | jq -r '.[]?' 2>/dev/null || echo "")"
      IFS=',' read -ra tlabel_arr <<< "$RUNNER_TRACKING_ONLY_LABELS"
      for tlabel in "${tlabel_arr[@]}"; do
        tlabel="${tlabel## }"; tlabel="${tlabel%% }"
        [[ -z "$tlabel" ]] && continue
        if printf '%s\n' "$task_labels" | grep -qxF "$tlabel" 2>/dev/null; then
          exempt="$tlabel"; break
        fi
      done
      if [[ -n "$exempt" ]]; then
        echo "  Note: references cross-repo id '$hit' but is labelled '$exempt' (tracking-only — cross-ref is intentional, claiming normally)"
      else
        echo "  Skipping: references cross-repo id '$hit' (workspace-scope check — this looks misfiled in '$local_prefix'; move it to its home repo, or add a '${RUNNER_TRACKING_ONLY_LABELS%%,*}' label if the cross-ref is intentional). Not claimed."
        return 1
      fi
    fi
  fi

  return 0
}

# ── BC-04 — resume ONE crash-orphan per reconcile, status re-checked at resume ─
# Drains the startup orphan snapshot (BC-02) one bead per loop. The snapshot may
# be stale by the time a loop reaches it (RECLAIM_POLL_INTERVAL — or, capacity-
# gated, an eternity — may have passed; a sibling or human may have closed or
# advanced the bead), so before resuming ANY orphan we RE-QUERY its CURRENT
# status via `bd show` (the BC-04 TOCTOU re-check):
#   • still `in_progress`        → resume it (set CANDIDATE_*), keep the orphans
#                                  AFTER it for later loops, return 0.
#   • changed (non-empty, ≠ ip)  → DROP it (a sibling/human moved it on), skip.
#   • bd show unparseable/empty  → KEEP it for a later retry (a flaky bd show
#                                  must NEVER lose an orphan), skip.
# Returns 0 with CANDIDATE_* set (→ resume) | 1 with ORPHANED_IDS narrowed to the
# survivors (→ fall through to the bd ready poll). Mirrors v1 next_task()'s
# orphan pass (run-beads-tasks.sh:675-697) — the SCAR (crash recovery) kept, the
# `read -ra`/array-quirk SCAFFOLDING dropped. The residual two-runners-one-orphan
# race (both observe in_progress) is closed by st_claim's §6.1 lease acquire
# (BC-48): only one runner re-acquires the expired lease; the other backs off.
_drain_one_orphan() {
  [[ ${#ORPHANED_IDS[@]} -gt 0 ]] || return 1
  local kept=() pos=0 oid show_json status
  for oid in "${ORPHANED_IDS[@]}"; do
    pos=$((pos + 1))
    # v1 (run-beads-tasks.sh:681) split the re-check into TWO keep-triggers: a
    # NONZERO `bd show` exit (degraded bd) kept immediately via `|| { remaining+=… }`,
    # and a zero-exit-but-unparseable body kept via the status branch. Here both
    # COLLAPSE into one: the EMPTY-string fallback below maps a degraded `bd show`
    # to show_json="" ⇒ status="" ⇒ the final `else` (keep). The empty fallback is
    # load-bearing for that equivalence — a degraded re-check must KEEP (never DROP)
    # the orphan. Do NOT change it to a non-empty sentinel (e.g. "__DEGRADED__")
    # without re-checking that `jq … // empty` still yields empty so the keep holds.
    show_json="$(safe_capture BD_UNAVAILABLE "" -- bd show "$oid" --json)"
    status="$(printf '%s' "$show_json" | jq -r '.[0].status // empty' 2>/dev/null || true)"
    if [[ "$status" == "in_progress" ]]; then
      # Resume THIS orphan; preserve the untouched orphans (after pos) for later
      # loops — `kept` already holds any flaky-show keepers seen before it.
      kept+=("${ORPHANED_IDS[@]:$pos}")
      ORPHANED_IDS=("${kept[@]+"${kept[@]}"}")
      CANDIDATE_ID="$oid"
      CANDIDATE_TITLE="$(printf '%s' "$show_json" | jq -r '.[0].title // ""'       2>/dev/null || true)"
      CANDIDATE_DESC="$(printf '%s' "$show_json"  | jq -r '.[0].description // ""' 2>/dev/null || true)"
      echo "runner: resuming crash-orphan $CANDIDATE_ID (still in_progress at reconcile; ${#ORPHANED_IDS[@]} orphan(s) remain)"
      return 0
    elif [[ -n "$status" ]]; then
      echo "runner: dropping orphan $oid — status is now '$status' (a sibling/human advanced it since startup)"
      :   # DROP — do not carry it forward
    else
      kept+=("$oid")   # bd show unparseable/degraded — keep for a later retry
    fi
  done
  # No resumable orphan this loop — narrow the list to the kept-for-retry set.
  ORPHANED_IDS=("${kept[@]+"${kept[@]}"}")
  return 1
}

# THE single reconcile point between tasks.
st_reconcile() {
  CANDIDATE_ID=""; CANDIDATE_TITLE=""; CANDIDATE_DESC=""

  # §1.1/§2.4 drain (BC-45, claude-tools-zyxz): ship the durable UP queue ONCE
  # per reconcile pass, so the heartbeats the just-finished task (or st_starting)
  # queued actually reach the hosted engine — keeps last_heartbeat_at / Board
  # liveness / current_task_ref fresh BETWEEN tasks. Guarded; never aborts.
  _drain_outbox

  # Graceful stop file is a between-tasks signal (§2.5 completion semantic).
  if [[ -f "$STOP_FILE" ]]; then
    echo "runner: stop file ($STOP_FILE) observed"
    rm -f "$STOP_FILE" 2>/dev/null || true
    transition STOPPING; return
  fi

  # claude-tools-trunkpin: pin HEAD back to main at THE reconcile point, before
  # CLAIM. The runner auto-commits per bead onto whatever branch HEAD points at;
  # once a worker wanders the tree onto a feature branch, every later bead piles
  # there until a human notices. Enforce in the loop, not by worker discipline
  # (the gate/close-hook lesson). Self-heals only when the tree is clean; silent
  # no-op on the common already-on-main path. Best-effort: never aborts reconcile.
  pin_head_to_main "${RUNNER_SKIP_PIN_MAIN:-0}"

  # Job 4 — reconcile desired-state (§2.4/§3). LOCAL-FIRST (claude-tools-y6j9):
  # the RUNNER owns `desired` — job_reconcile_desired reads the local .co-store
  # RunnerState first (the cloud only queues Brian's change-requests, which the
  # daemon applies locally). The safe_capture fallback is FAIL-CLOSED (`paused`,
  # not the old `running`): if the local read itself errors, HOLD rather than
  # break through a pause. This closes the second half of the break-through-pause
  # bug — the old `running` fallback (paired with the adapter's `|| echo running`
  # rc-0, so this degrade never even fired) is exactly what let one failed poll
  # discard a 17h paused history and CLAIM (dky8).
  local desired
  desired="$(safe_capture COORD_UNREACHABLE paused -- job_reconcile_desired)"
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
      # An UNRECOGNIZED desired now FAILS CLOSED (hold), not open: under
      # local-first an unreachable engine can no longer manufacture a value here
      # (the read is local), so a non-enum value is a genuine anomaly — holding
      # is safe, claiming is not. Mirror the paused hold.
      degrade COORD_UNREACHABLE "unrecognized desired='$desired' — fail-CLOSED to hold (re-reconcile in ${RECLAIM_POLL_INTERVAL}s)"
      job_heartbeat idle "" "" >/dev/null
      sleep "$RECLAIM_POLL_INTERVAL"
      transition RECONCILE; return ;;
  esac

  # ── BC-04 crash-orphan drain — BEFORE the bd ready poll ────────────────────
  # An `in_progress` orphan is invisible to `bd ready`, so this drain is the ONLY
  # path that re-presents it. Placed AFTER the desired-state check (a stop/pause
  # correctly preempts resuming stranded work) and BEFORE the new-work poll
  # (orphans-first, matching v1's next_task ordering). A resumed orphan goes
  # STRAIGHT to CLAIM, bypassing the bd-ready epic/label/gate-policy selection:
  # it already passed those gates when first claimed, and re-gating an
  # already-in_progress bead risks stranding it permanently (a gate-skip would
  # drop it from ORPHANED_IDS AND it is absent from bd ready — the exact failure
  # this bead closes). st_claim's lease acquire is where the §6.1 strong-plane
  # orphan-recovery composes (re-acquire the crashed owner's expired lease); the
  # `bd update --status=in_progress` re-write there is idempotent. ACCEPTED
  # v1 carry-over (claude-tools-v2cut.1 decision): like v1's next_task, the orphan
  # path does NOT re-validate deps — if a sibling reopened the orphan's dependency
  # post-crash, the now-effectively-blocked orphan is resumed anyway (the worker
  # re-discovers the block). The BC-06/07/08/51 workability gate that v2cut.1
  # added (_validate_workable) is applied ONLY to bd-ready candidates below, NOT
  # to resumed orphans — matching v1 exactly (v1's validate_task runs only inside
  # select_workable_task over the ready array, never over the orphan resume).
  if _drain_one_orphan; then
    transition CLAIM; return
  fi

  # New-work poll (§2.5 between-tasks). BC-42: a DEGRADED bd is NOT a drain —
  # only a genuine empty queue drains (§1.2). Typed, explicit, not `|| []`.
  #
  # claude-tools-dzc (port-forward, claude-tools-v2c1): exclude EPICs from the
  # ready query. Epics are CONTAINERS, not workable; an epic-topped queue would
  # otherwise starve every workable task beneath it — v1 logged 158 epic-skip
  # spin-cycles in a single detached run (detached-20260524T003251Z.log). The
  # v1 fix is run-beads-tasks.sh:708-709; this is its belt-and-suspenders shape:
  #   • `--exclude-type=epic` — now honored by bd (it was empirically a NO-OP at
  #     dzc's 2026-05-24; current bd filters epics correctly), AND
  #   • the jq selection below independently drops epics. The belt backstops the
  #     flag silently REGRESSING to a no-op (the dzc-2026-05-24 failure mode) and
  #     covers the field-name difference (`bd ready` → `issue_type`, `bd list` →
  #     `type`). It does NOT cover a bd that HARD-REJECTS the flag (nonzero exit):
  #     the safe_capture below degrades that to a retry-spin (NOT a drain) before
  #     the belt runs — acceptable (no false drain, no epic claim), just noisier.
  local ready_json
  ready_json="$(safe_capture BD_UNAVAILABLE "__DEGRADED__" -- bd ready --exclude-type=epic --json)"
  if [[ "$ready_json" == "__DEGRADED__" ]]; then
    echo "runner: bd ready degraded — NOT treating as drain; retry in ${RECLAIM_POLL_INTERVAL}s"
    sleep "$RECLAIM_POLL_INTERVAL"
    transition RECONCILE; return
  fi

  # Select the FIRST workable NON-EPIC candidate at the ONE reconcile point (no
  # scattered downstream skip — keeps the v2 state-machine shape; claude-tools-dzc).
  # This IS v1's select_workable_task (BC-51) as a state-machine walk: epics are
  # dropped by the jq select (containers, not workable); each surviving candidate
  # is then run through BOTH gates in v1's order —
  #   1. the pickup label gate (_candidate_label_gated, claude-tools-v2c3) — any
  #      human-* fixture (BC-08b) or gate:<id> Gate (uxvj4); then
  #   2. the workability validation (_validate_workable, claude-tools-v2cut.1) —
  #      BC-06 late-blocked deps, BC-52 epic DiD, BC-07/08 parent/container,
  #      BC-08d cross-repo scope.
  # A candidate either gate rejects is SKIPPED-not-failed and the walk advances
  # to the next bead (the v1 no-starvation posture — a single unworkable head no
  # longer starves the workable beads below it, the claude-tools-uxqj/dzc class).
  # `job_heartbeat idle` per skip keeps actual-state warm while we scan past a
  # long unworkable run (the v1 select_workable_task `hb idle` / g20 hot-spin
  # guard). If EVERY ready item is an epic / gated / unworkable, CANDIDATE_ID is
  # empty and we DRAIN/idle (§1.2): nothing autonomously-claimable ⇒ honest idle,
  # never a claimed epic/gated/blocked/container/cross-repo bead, never a skip-spin.
  local cand_ids
  cand_ids="$(printf '%s' "$ready_json" | jq -r 'map(select((.issue_type // .type // "") != "epic")) | .[].id // empty' 2>/dev/null)"
  CANDIDATE_ID=""
  local _cid
  while IFS= read -r _cid; do
    [[ -z "$_cid" ]] && continue
    if _candidate_label_gated "$_cid"; then job_heartbeat idle "" "" >/dev/null; continue; fi
    if ! _validate_workable "$_cid"; then    job_heartbeat idle "" "" >/dev/null; continue; fi
    CANDIDATE_ID="$_cid"; break
  done <<< "$cand_ids"
  if [[ -z "$CANDIDATE_ID" ]]; then
    transition DRAINED; return                 # §1.2 empty / all-epic / all-gated / all-unworkable queue
  fi
  local candidate_obj
  candidate_obj="$(printf '%s' "$ready_json" | jq -c --arg id "$CANDIDATE_ID" 'map(select(.id == $id)) | .[0] // empty' 2>/dev/null)"
  CANDIDATE_TITLE="$(printf '%s' "$candidate_obj" | jq -r '.title // ""'       2>/dev/null)"
  CANDIDATE_DESC="$(printf '%s' "$candidate_obj"  | jq -r '.description // ""' 2>/dev/null)"

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
      notify_user "beads-runner: max retries" "$CANDIDATE_ID — analysis task created"   # BC-26
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
    # The Coordinator did not grant. §6.2/AD2.2 bounded LOCAL fallback: act ONLY
    # when the Coordinator is GENUINELY unreachable, signalled by the transport's
    # CO_HTTP_UNREACHABLE sidecar (set ONLY on the curl-failed / no-HTTP-code path
    # — NOT on a reachable 5xx, a contended-lease 409, or a local fault, all of
    # which must fail CLOSED here). Even then, continue ONLY a task whose still-
    # valid lease we ALREADY hold locally (la_lease_fallback_allows enforces that
    # from the §6.2 lease cache; its TTL bound ⊆ the Coordinator's, so a still-
    # valid local hold proves the Coordinator lease is still ours). A reachable
    # deny, OR unreachable with no/expired cached lease, still refuses: no NEW
    # unsynchronised claim ⇒ no BC-04 two-runners-one-orphan regression.
    if [[ "${CO_HTTP_UNREACHABLE:-0}" == "1" ]] && job_lease_fallback_allows "$CANDIDATE_ID" unreachable; then
      echo "runner: Coordinator unreachable — bounded local fallback CONTINUES $CANDIDATE_ID (still-valid local lease held; §6.2/AD2.2)"
      # claude-tools-h9dl (P2 / ylu2 follow-up #1): seed the §4.4 fencing token
      # from the locally-cached lease ENVELOPE instead of sending an EMPTY one.
      # An empty generation means the renew that rides the next heartbeat is
      # SKIPPED (la_heartbeat only renews when gen is non-empty) — so once the
      # Coordinator recovers mid-task the lease silently lapses and a sibling
      # could double-claim. With the cached token the renew is ATTEMPTED: if no
      # takeover happened during the outage it still matches and the lease is
      # renewed; if one did, the renew is correctly denied (we lost the lease —
      # which offline self-verify cannot detect, hence the reachable re-validate).
      LEASE_GENERATION="$(job_lease_recover_generation "$CANDIDATE_ID" 2>/dev/null || true)"
    else
      echo "runner: lease unavailable for $CANDIDATE_ID — not claiming (no lease ⇒ no run)"
      sleep "${LEASE_DENY_BACKOFF:-3}"
      transition RECONCILE; return
    fi
  else
    LEASE_GENERATION="$gen"
    # §6.2/AD2.2: record the locally-held lease the instant the Coordinator grants
    # it, so a LATER Coordinator blip can consult the bounded fallback and continue
    # THIS task (and only this task). Paired by job_lease_release_local at every
    # release site; a SIGKILL (no teardown) deliberately leaves the cache entry as
    # the crash-orphan resume signal. Best-effort (BC-43): never aborts the claim.
    # claude-tools-h9dl: forward the §4.4 generation so the cached envelope carries
    # the fence token (recovered on a restart/blip via job_lease_recover_generation).
    job_lease_note_held "$CANDIDATE_ID" "" "$LEASE_GENERATION" >/dev/null 2>&1 || true
  fi

  # Job 2 — ask-capacity (§6.3). Failure posture is fail-OPEN (§6.2): the stub
  # returns ok; a real `over` would hold here. Explicit, not silent.
  if ! job_ask_capacity standard; then
    # zfxe: name WHICH gate tripped + the numbers it tripped on. job_ask_capacity
    # (la_capacity_check) sets these sidecars alongside its exit code; before this
    # the reason was discarded and the deny line couldn't say which gate held.
    echo "runner: capacity verdict=over reason=${LA_CAPACITY_REASON:-unknown} (5h=${LA_CAPACITY_PCT_5H:-?}% 7d=${LA_CAPACITY_PCT_7D:-?}%) — releasing lease, holding"
    job_release_lease "$CANDIDATE_ID" "$LEASE_GENERATION" >/dev/null; job_lease_release_local "$CANDIDATE_ID" >/dev/null 2>&1 || true   # §6.1 release + §6.2/AD2.2 drop the local hold we just noted (kept on ONE line so the deny-branch §6.2 SCAR window — BC-34/BC-49 grep -A8 — is undisturbed)
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
  # claude-tools-2fkp: surface CURRENT_TASK_ID to the close-discipline hook —
  # export so the `claude -p` worker (and its hook subprocesses) inherit it, and
  # write a file fallback for a hook that lands in a subshell that dropped env
  # (the hook reads env first, file second). Done HERE (claim, before the worker
  # spawns in st_run_task) so the very first tool call is gated against the right
  # bead. Cleared at task-end (st_post_task) + on every teardown path.
  export CURRENT_TASK_ID
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s' "$CURRENT_TASK_ID" > "$LOG_DIR/current-task" 2>/dev/null || true
  # claude-tools-uxc1 (Mechanism A): stamp our PID claim BEFORE the in_progress
  # write. The claim is keyed on the runner pid, not the bead status, so writing it
  # first means a crash in the (claim-write → in_progress-write) window leaves the
  # bead at `open` — normally recoverable via `bd ready` — instead of
  # `in_progress`-with-no-claim, which the claim-validated startup walk would now
  # SKIP (→ strand). A claim for a not-yet-in_progress bead is harmless: the walk
  # only inspects in_progress beads, and a re-claim overwrites it. On a RESUMED
  # orphan this overwrites the prior (dead-pid) claim with our live pid — the
  # read-only startup walk leaves it in place for exactly this re-stamp.
  write_task_claim "$CURRENT_TASK_ID"
  safe_capture BD_UNAVAILABLE "" -- bd update "$CANDIDATE_ID" --status=in_progress >/dev/null
  IDLE_ANNOUNCED=""   # claude-tools-giu: leaving idle — next drain re-announces
  transition RUN_TASK
}

st_run_task() {
  # BC-32 (claude-tools-v2cut.4): resolve THIS task's model + permission flags
  # from its `model:` label (default DEFAULT_MODEL) BEFORE the banner + spawn.
  _resolve_task_model "$CURRENT_TASK_ID"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $CANDIDATE_TITLE ($CURRENT_TASK_ID) [$TASK_MODEL]"
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
  # claude-tools-62xc: derive the per-task log_dir from the env-overridable global
  # $LOG_DIR (default .beads/runner-logs, set at line ~194) — NOT a second hardcoded
  # literal. The claim-time current-task pointer (st_claim ~line 2434) and every
  # teardown `rm` target $LOG_DIR/current-task; if someone exports LOG_DIR=/custom
  # the per-task STREAM/SIGNAL/PROC/POST_TERMINAL/HOOK_SETTINGS artifacts must land
  # there too or teardown's current-task rm and these artifacts disagree. They MATCH
  # by default, so this is a latent non-default-LOG_DIR symmetry fix, not a live bug.
  log_dir="${LOG_DIR:-.beads/runner-logs}"
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

  # claude-tools-2fkp: per-task close-discipline artifacts. POST_TERMINAL_FILE
  # records the epoch the SDK terminal record was first seen — stamped by the
  # watchdog (v2 has NO concurrent stream parser, v1's stamping seam), which
  # then SIGKILLs claude POST_TERMINAL_GRACE seconds later if it is still alive
  # (the orphan-child wedge). Both files share the BC-29 timestamped basename so
  # a killed iteration's leak is cleanable; mktemp is the symmetric fallback
  # when log_dir is unwritable (mirrors STREAM/SIGNAL/PROC above).
  if [[ -d "$log_dir" && -w "$log_dir" ]]; then
    POST_TERMINAL_FILE="$base.post-terminal"
    HOOK_SETTINGS_FILE="$base.hook-settings.json"
  else
    POST_TERMINAL_FILE="$(mktemp 2>/dev/null)" || POST_TERMINAL_FILE="$base.post-terminal"
    HOOK_SETTINGS_FILE="$(mktemp 2>/dev/null)" || HOOK_SETTINGS_FILE="$base.hook-settings.json"
  fi
  rm -f "$POST_TERMINAL_FILE" 2>/dev/null || true   # stale-leak guard; watchdog re-stamps on the terminal record

  # claude-tools-2fkp: wire the close-discipline hook (PreToolUse on Bash so a
  # `bd close|done|--status=closed` is gated, + Stop so the 8-block checklist
  # fires at session end) into THIS worker via runner-injected --settings. The
  # hook script ships with the runner (hooks/close-checklist.sh); the JSON shape
  # is the shared hooks/build-settings.sh (sourced at startup) so v1/v2 never
  # drift. BEADS_RUNNER_SESSION=1 gates the hook so an interactive claude in the
  # same workspace is unaffected even if it loads the same settings. Absent
  # builder / no jq / write-failure ⇒ NO --settings (the worker runs, no hook).
  local hook_script hook_settings_flags=()
  hook_script="$RUNNER_DIR/hooks/close-checklist.sh"
  if [[ -x "$hook_script" ]]; then
    if command -v build_hook_settings >/dev/null 2>&1; then
      build_hook_settings "$hook_script" "$HOOK_SETTINGS_FILE" \
        && hook_settings_flags=(--settings "$HOOK_SETTINGS_FILE")
    fi
  else
    echo "  WARN: close-discipline hook not executable at $hook_script — running WITHOUT hook enforcement (claude-tools-2fkp)." >&2
  fi

  # BC-39: stdout+stderr → the one stream file (stderr carries SDK HTTP-retry
  # state; the watchdog's SIGINT-before-SIGKILL exists so it flushes here).
  # §7.6: --output-format stream-json is KEPT (the §7.2(b) backstop reads
  # result.permission_denials[] / the "Entered plan mode." tool_result — `text`
  # hides both); GUARDRAIL_FLAGS removes the interactive tools from the
  # advertised set (defense-in-depth behind the §7.2(a) instructed prompt).
  # claude-tools-2fkp: BEADS_RUNNER_SESSION + POST_TERMINAL_FILE env + the
  # close-discipline --settings are injected alongside the existing flags.
  BEADS_RUNNER_SESSION=1 \
  POST_TERMINAL_FILE="$POST_TERMINAL_FILE" \
  claude -p "$prompt" \
    --output-format stream-json \
    --verbose \
    --model "$TASK_MODEL" \
    "${GUARDRAIL_FLAGS[@]+"${GUARDRAIL_FLAGS[@]}"}" \
    "${EXTRA_CLAUDE_FLAGS[@]+"${EXTRA_CLAUDE_FLAGS[@]}"}" \
    "${TASK_PERMISSION_FLAGS[@]+"${TASK_PERMISSION_FLAGS[@]}"}" \
    "${hook_settings_flags[@]+"${hook_settings_flags[@]}"}" \
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
  # I4 (claude-tools-uxvi4): the agent-action control-marker dir the daemon drops
  # into for THIS workspace's stuck-actions (nudge / kill-retry / kill-gate). The
  # watchdog reads it each tick and honors a marker targeting CURRENT_TASK_ID.
  #
  # claude-tools-wqx7: PIN this to the FROZEN default path, NOT $log_dir/$LOG_DIR.
  # This dir is a daemon→runner RENDEZVOUS, not a runner post-mortem artifact: the
  # daemon (agent-action-poll.sh daemon_aa_control_marker_dir) drops markers here
  # but cannot know a workspace's exported LOG_DIR override, so it hardcodes
  # .beads/runner-logs/agent-action — exactly as launch-detached.sh pins the
  # detached-runner.pid rendezvous to the fixed path. design/agent-action.md §4
  # FREEZES "the marker directory" at <ws>/.beads/runner-logs/agent-action/. LOG_DIR
  # (BC-27) reparents only the runner's OWN raw artifacts (STREAM/SIGNAL/PROC, the
  # 62xc $log_dir derive above); a cross-process rendezvous must stay at the fixed
  # path so the daemon side can find it. Deriving this from $log_dir (it did so
  # incidentally) would silently break the seam under a non-default LOG_DIR — the
  # daemon drops into the default dir while the watchdog scans the override dir, so
  # stuck-actions never arrive. cwd is the workspace, so the relative literal here
  # resolves to the same dir the daemon writes ($ws/.beads/runner-logs/agent-action).
  local agent_action_dir=".beads/runner-logs/agent-action"
  ( trap - EXIT HUP INT TERM
    _watchdog_loop "$CLAUDE_PID" "$STREAM_FILE" "$SIGNAL_FILE" "$PROC_SNAPSHOT" "$POST_TERMINAL_FILE" \
                   "$agent_action_dir" "$CURRENT_TASK_ID" ) &
  WATCHDOG_PID=$!

  # §2.5 DURING-task cadence. We poll on a fine RUNNER_TICK and act on the
  # CONTROL_POLL_INTERVAL / HEARTBEAT_INTERVAL boundaries. A stop REQUEST is
  # OBSERVED here (≤ CONTROL_POLL_INTERVAL so the Board can render `stopping…`
  # immediately) but only ACTED ON after the task completes (§2.5 "stop after
  # current task" — no mid-task kill for a stop). The watchdog above is the
  # separate BC-22 liveness concern. Heartbeat (job 3) renews the held lease.
  # I1 (claude-tools-uxvi1): the writer-lane activity reporter state. The writer
  # is singular per workspace BY CONSTRUCTION (one serial st_run_task loop), so
  # its latest-wins key is `writer:<runner_id>` (design/activity.md §1.4). The
  # ACTIVITY_STATE_FILE rides the BC-29 timestamped basename so a killed
  # iteration's leak is cleanable; it is under the BC-27 self-gitignored log_dir.
  local act_state_file="$base.activity-state"
  local act_agent_key="writer:${RUNNER_ID}"
  local since_act=0
  rm -f "$act_state_file" 2>/dev/null || true

  local since_ctl=0 since_hb=0
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep "$RUNNER_TICK"
    since_ctl=$((since_ctl + RUNNER_TICK))
    since_hb=$((since_hb + RUNNER_TICK))
    since_act=$((since_act + RUNNER_TICK))
    # I1: out-of-band activity classify + (throttled) agent-activity-report.
    # OPTIONAL & guarded — only when the lib is sourced; the tick itself is
    # best-effort (always rc 0) and BACKGROUNDS its POST so this loop never
    # blocks on the network. This is the §1.4 "separate throttled reporter,
    # not in the hot loop" mirror — v2 has NO tail-f parser, so the during-task
    # control cadence IS the sibling ticker. current_tool/stage are best-effort;
    # the projection (I2) reads only the B.1 subset it promises.
    if [[ $since_act -ge $ACTIVITY_REPORT_INTERVAL ]] \
       && command -v activity_report_tick >/dev/null 2>&1; then
      since_act=0
      activity_report_tick "$STREAM_FILE" "$act_state_file" "$act_agent_key" \
        "$PROJECT_REF" "writer" "impl" "$CURRENT_TASK_ID" "${CANDIDATE_TITLE:-}" "" \
        2>/dev/null || true
    fi
    if [[ $since_ctl -ge $CONTROL_POLL_INTERVAL ]]; then
      since_ctl=0
      local d
      # local-first (claude-tools-y6j9): job_reconcile_desired reads local
      # .co-store first; FAIL-CLOSED fallback `paused` (not the old `running`) —
      # during a task only a `stopped` triggers the §2.5 after-task honor, so a
      # transient local-read error must not be read as `stopped` NOR manufacture
      # a `running` that masks a real local pause for the NEXT reconcile.
      d="$(safe_capture COORD_UNREACHABLE paused -- job_reconcile_desired)"
      if [[ "$d" == "stopped" ]] || [[ -f "$STOP_FILE" ]]; then
        STOP_REQUESTED=1
        job_heartbeat stopping "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null
        echo "runner: stop OBSERVED during task (≤${CONTROL_POLL_INTERVAL}s) — honoring AFTER current task (§2.5, no mid-task kill)"
      fi
    fi
    if [[ $since_hb -ge $HEARTBEAT_INTERVAL ]]; then
      since_hb=0
      # claude-tools-7v5 (port-forward decision, claude-tools-v2c1): this beat is
      # DELIBERATELY UNCONDITIONAL — do NOT stream-gate it the way v1's 7v5 gated
      # `hb running` on ACTIVITY_FILE freshness. In v1 the heartbeat was PURE
      # liveness (hb()→la_report_heartbeat, no lease; the lease was a separate
      # `lease acquire/release` seam), so suppressing it on a stuck worker only
      # let the Board render liveness=stale — harmless. In v2, lease-renewal
      # RIDES this same call (§3 j3; runner-backend-real.sh la_heartbeat issues
      # the lease-renew — the runner has no separate per-tick renew site). Gating
      # it would stop renewing the lease on any CPU-busy-but-stream-quiet worker
      # (e.g. a long compile/install: the watchdog's tree-CPU check keeps it
      # ALIVE, so it is NOT killed), and once such a phase exceeds LEASE_TTL
      # (900s) > IDLE_TIMEOUT (600s) the lease would lapse and a sibling could
      # double-claim the in-flight bead. The honest-stale-on-stuck signal v1 got
      # from 7v5 is instead provided in v2 by the watchdog (WATCHDOG_SOFT_WARN +
      # the WATCHDOG_KILL incident). Re-adding the gate here is a regression, not
      # a fix; decoupling liveness from lease-renewal would be a §3 job-surface
      # change (v2c2/§11), out of this port-forward's scope.
      job_heartbeat running "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null  # renews held lease (§3 j3)
      # claude-tools-h9dl (P2): refresh the local lease ENVELOPE on each renew so
      # the §6.2 bounded-fallback self-verify tracks the ACTIVELY-renewed
      # Coordinator lease. note_held was previously called ONLY on the fresh grant,
      # so on a task longer than LEASE_TTL (900s) the local hold drifted STALE and
      # under-reported validity while the engine lease was fine. Gated on:
      #   • non-empty LEASE_GENERATION — there is a fenced lease to carry forward
      #     (the empty-gen unreachable-continuation case has nothing to refresh);
      #   • LA_LEASE_RENEW_RC == 0 — the renew that just rode the heartbeat was
      #     actually GRANTED by the engine (la_heartbeat sets this sidecar; "" or
      #     nonzero ⇒ no renew / denied / unreachable). STRICTER than mere
      #     reachability: a reachable-but-DENIED renew (a mid-outage takeover bumped
      #     the generation, then connectivity returned) must NOT re-stamp — we lost
      #     the lease, and advancing the local expiry would extend a stale hold a
      #     later SIGKILL+restart would wrongly resume on. An outage (rc nonzero)
      #     likewise does not advance, so the BOUNDED property holds: a bounded
      #     outage still eventually expires the local hold and stops the task. The
      #     ":-1" default (a backend that never set it, e.g. the stub) ⇒ skip.
      #     Best-effort; never aborts the loop.
      # The refresh passes only the generation (no §4.4 record — la_heartbeat
      # discards the renew's returned record), so note_held RE-DERIVES the local
      # expiry as now+ttl. That mirrors the Coordinator's own renew (engine_now+ttl
      # on the same beat) within clock skew — the cached expires_epoch is thus
      # runner-recomputed after the first renew, NOT the engine's echoed value.
      if [[ -n "$LEASE_GENERATION" && "${LA_LEASE_RENEW_RC:-1}" == "0" ]]; then
        job_lease_note_held "$CURRENT_TASK_ID" "" "$LEASE_GENERATION" >/dev/null 2>&1 || true
      fi
      # §1.1/§2.4 drain (BC-45, claude-tools-zyxz): SHIP that running heartbeat
      # NOW. st_reconcile is NOT re-entered during a task, so without an in-loop
      # drain a task longer than the engine's STALE_AFTER (≈180s) freezes the
      # engine heartbeat and risks a spurious 'runner stuck' — the exact live
      # cutover scar (a 30-min bpmap1 task showed the prior runner's heartbeat).
      # Gated by since_hb ⇒ at most once per HEARTBEAT_INTERVAL, matching v1's
      # mid-task HB-subshell cadence (run-beads-tasks.sh:2280-2310 → hb() drain).
      _drain_outbox
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

  # ── wrong-Node crash detector (LOUD, never silent) — claude-tools-18c ─────
  # Backstop behind the startup-time path-prime (node25_prime_path, sourced
  # near the top of this file). The detection regex/scan lives in
  # node25_check_wrong_node_crash (lib/node25-prime.sh, shared with
  # specialist.sh / run-beads-tasks.sh); here we own the runner-scoped
  # surface: a CURRENT_TASK_ID-attributed stderr block, an INCIDENTS entry
  # that surfaces in the end-of-run summary via emit_incidents(), and a
  # sticky line in wrong-node-crash.log. $CLAUDE_EXIT is NOT mutated — the
  # T2.2 classify_failure path below still runs (so any downstream retry /
  # breaker behavior is unchanged), but the silent degradation we're killing
  # (UNKNOWN_FAILURE-and-retry on every spawn) is now impossible: the crash
  # leaves visible fingerprints in three places. Even after the prime, an
  # unforeseen launch environment could reintroduce the wrong-Node case
  # (system claude wrapper, NVM_DIR moved, custom $CLAUDE_BIN) — this detector
  # is the backstop that ensures it is heard instantly instead of weeks later.
  if [[ "$CLAUDE_EXIT" -ne 0 ]] && declare -F node25_check_wrong_node_crash >/dev/null; then
    if _node_seen="$(node25_check_wrong_node_crash "$STREAM_FILE")"; then
      {
        printf '  WRONG-NODE CRASH — claude CLI crashed at startup.\n'
        printf '    detected: %s (the claude CLI is incompatible with Node v25+; see claude-tools-18c / claude-tools-3kd / claude-tools-4tj)\n' "${_node_seen:-<unknown>}"
        printf '    stream:   %s\n' "$STREAM_FILE"
        printf '    fix:      ensure $NVM_DIR/versions/node/<lts>/bin is first in PATH for the launching process.\n'
        printf '              runner.sh already prepends nvm bin when node --version is v25+; the wrong-Node\n'
        printf '              detection firing means even that prepend did not resolve the right binary.\n'
      } >&2
      mkdir -p "$LOG_DIR" 2>/dev/null || true
      {
        printf '%s\t%s\twrong_node_crash\t%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
          "$CURRENT_TASK_ID" "${_node_seen:-unknown}"
      } >> "$LOG_DIR/wrong-node-crash.log" 2>/dev/null || true
      INCIDENTS+=("$(date -u +%Y-%m-%dT%H:%M:%SZ)	$CURRENT_TASK_ID	WRONG_NODE_CRASH:${_node_seen:-unknown}	$STREAM_FILE")
    fi
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
  job_lease_release_local "$CURRENT_TASK_ID" >/dev/null 2>&1 || true   # §6.2/AD2.2 — fatal reset relinquishes the local hold (pairs the §6.1 release)
  remove_task_claim "$CURRENT_TASK_ID"   # claude-tools-uxc1: bead reset to open — drop our claim
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
      # BC-56 (claude-tools-apen): post-close discipline audit. A SUCCESS that
      # closed the bead WITHOUT shipping a commit (Stop-hook bypassed via the
      # 8-block cap) is surfaced as a P1 discipline-bypass regression bead +
      # incident + note here, so the silent-disappear never happens. Opt-out via
      # RUNNER_SKIP_POST_CLOSE_AUDIT (the conformance harness sets it; production
      # never does). STREAM_FILE is the v2 forensic session anchor.
      post_close_audit "$CURRENT_TASK_ID" "${STREAM_FILE:-}"
      ;;

    AUTH_FAILURE)                     # §8.1 row 3 — fleet-fatal, terminal
      echo "  FATAL: Authentication failed — stopping runner (BC-21 exit 3)."
      append_runner_note "$CURRENT_TASK_ID" "AUTH_FAILURE" "-"
      record_incident    "$CURRENT_TASK_ID" "AUTH_FAILURE" "-"
      notify_user "beads-runner: auth failure" "$CURRENT_TASK_ID — runner stopped"   # BC-26
      _terminal_fatal AUTH_FAILURE 3; return
      ;;

    BILLING_ERROR)                    # §8.1 row 4 — fleet-fatal, terminal
      echo "  FATAL: Billing error — stopping runner (BC-21 exit 4)."
      append_runner_note "$CURRENT_TASK_ID" "BILLING_ERROR" "-"
      record_incident    "$CURRENT_TASK_ID" "BILLING_ERROR" "-"
      notify_user "beads-runner: billing error" "$CURRENT_TASK_ID — runner stopped"   # BC-26
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
      notify_user "beads-runner: context overflow" "$CURRENT_TASK_ID — see $LOG_DIR"   # BC-26
      # BC-19 (claude-tools-v2cut.4): the reason string carries class-specific
      # salvage guidance. The final "relabel model:opus" sentence — DROPPED in the
      # pre-BC-32 v2 skeleton because per-task model: labels did nothing then — is
      # RESTORED here: BC-32 (same bead) makes the relabel meaningful (a model:opus
      # task now actually runs on the 1M-context Opus variant, vs sonnet's 200K).
      create_analysis_task "$CURRENT_TASK_ID" "$CANDIDATE_TITLE" \
        "context_overflow — ran out of context mid-session. The previous agent likely completed early phases before overflowing: inspect git log / git diff for committed or staged work and re-scope this task to ONLY the remaining steps (do not redo completed work). If the task is inherently too large for one window, split it into smaller dependent tasks. Overflow-prone tasks are usually labeled model:sonnet (200K window); relabel the re-scoped task model:opus (the runner auto-selects the 1M-context Opus variant) before it is retried."
      LAST_FAILED_ID=""; FAIL_COUNT=0
      ;;

    MAX_OUTPUT_TOKENS)                # BC-13: skip retry → analysis; breaker-exempt
      echo "  FAILED: $CANDIDATE_TITLE — ran out of output/context window"
      safe_capture BD_UNAVAILABLE "" -- bd update "$CURRENT_TASK_ID" --status=open >/dev/null
      append_runner_note "$CURRENT_TASK_ID" "MAX_OUTPUT_TOKENS" "${PRESERVED_LOG:--}"
      record_incident    "$CURRENT_TASK_ID" "MAX_OUTPUT_TOKENS" "${PRESERVED_LOG:--}"
      notify_user "beads-runner: max output tokens" "$CURRENT_TASK_ID — context exhausted"   # BC-26
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
      notify_user "beads-runner: $CLASSIFICATION" "$CURRENT_TASK_ID — see $LOG_DIR"   # BC-26
      if [[ "$CURRENT_TASK_ID" != "$LAST_FAILED_ID" ]]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      fi
      LAST_FAILED_ID="$CURRENT_TASK_ID"
      ;;
  esac

  # BC-25 (claude-tools-v2cut.4): scan the merged stream for high-signal
  # tool-level errors REGARDLESS of classification (incl. SUCCESS/STUCK). Many
  # silent failures (subagent missing, permission denied, MCP down) leave the
  # exit code clean because the agent recovered inline — surface them as a
  # side-effect (incident + note + subagent notify) WITHOUT changing the
  # classification or exit code. Called here, after the dispatch case, mirroring
  # v1's unconditional post-dispatch call site.
  scan_tool_errors "$STREAM_FILE" "$CURRENT_TASK_ID"

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
    notify_user "beads-runner: stopped" "$MAX_CONSECUTIVE_FAILURES consecutive failures"   # BC-26
    _terminal_fatal CIRCUIT_BREAKER 2; return
  fi

  # Job 1 pairing — release the lease (§6.1; fenced by §4.4 generation). For
  # every non-fatal class the bead is already at its correct status (open for
  # the retried/failed classes; blocked-for-human for STUCK; closed for
  # SUCCESS) — release pairs the acquire so the lease never outlives the work.
  job_release_lease "$CURRENT_TASK_ID" "$LEASE_GENERATION" >/dev/null
  job_lease_release_local "$CURRENT_TASK_ID" >/dev/null 2>&1 || true   # §6.2/AD2.2 — task-end relinquishes the local hold (pairs the §6.1 release; a retry re-acquires)
  # Job 5 — publish the §4.5 read-only projection (Dolt stays work-truth).
  job_publish_snapshot >/dev/null

  # claude-tools-2fkp: drop this task's close-discipline ephemera — the
  # post-terminal stamp, the --settings JSON, and the current-task pointer.
  # They are NOT classifier inputs (STREAM_FILE/PROC_SNAPSHOT retention is the
  # T2.2/BC-28 seam above), so they go on the normal task-end path; the teardown
  # EXIT funnel re-clears them on every abnormal exit (circuit-breaker/fatal).
  rm -f "${POST_TERMINAL_FILE:-}" "${HOOK_SETTINGS_FILE:-}" "$LOG_DIR/current-task" 2>/dev/null || true
  POST_TERMINAL_FILE=""; HOOK_SETTINGS_FILE=""
  # claude-tools-uxc1: the bead is now at its correct non-in_progress status
  # (closed for SUCCESS, open for the retried/failed classes, blocked for STUCK) —
  # drop our PID claim so the next startup walk never re-adopts a task we finished.
  # EXCEPTION — DEGRADED: that class deliberately did NOT mutate work state (BC-42:
  # a degraded `bd` read is not a verdict), so the bead is STILL in_progress and
  # must stay recoverable. KEEP its claim so that once THIS runner dies its now-dead
  # pid lets a future startup snapshot re-adopt the bead (the pre-uxc1 "any
  # in_progress is recovered" guarantee; removing the claim would strand it).
  [[ "$CLASSIFICATION" == "DEGRADED" ]] || remove_task_claim "$CURRENT_TASK_ID"

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
  # §1.1/§2.4 drain (BC-45, claude-tools-zyxz; mirrors v1 run-beads-tasks.sh:2693):
  # the LAST durable write — ship the final `stopped` heartbeat so the engine sees
  # a clean stop instead of waiting out STALE_AFTER. (The terminal-reason line has
  # no hosted op and is correctly RETAINED here, not dropped — pre-existing, not
  # this bug.)
  _drain_outbox
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
# claude-tools-69u8: run the loop only when EXECUTED, not when SOURCED, so a
# focused test can exercise an individual helper (e.g. _drive_blocked_for_human)
# without entering the state machine. EXEC-TRANSPARENT: `bash runner.sh` (and the
# conformance harness's `exec bash "$RUNNER"`) keep $0==BASH_SOURCE ⇒ loop runs.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
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
fi
