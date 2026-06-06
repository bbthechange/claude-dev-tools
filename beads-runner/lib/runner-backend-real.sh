# shellcheck shell=bash
# beads-runner/lib/runner-backend-real.sh — the REAL six-job backend adapter
# (T-final wiring, claude-tools-v2c2; epic claude-tools-v2cut).
#
# WHAT THIS IS
#   runner.sh is the CALLER of the six §3 jobs (INTERFACE.md v1 §3). Until now it
#   sourced the two in-process NO-OP stubs (lib/coordinator-stub.sh +
#   lib/local-agent-stub.sh) so the loop SHAPE could be proven GREEN before any
#   real backend existed (T2.1). This file is the OTHER selectable backend: it
#   sources the REAL Local Agent (T3, lib/local-agent.sh) + Coordinator (T5,
#   lib/coordinator.sh, transparently HTTP-overridden by lib/co-http-transport.sh
#   when COORDINATOR_URL is set — the daemon/hosted path) and provides the exact
#   call surface the runner's `job_*` wrappers invoke, so the runner's job CALL
#   SITES never change (the stub↔real "total swap" the runner header promises).
#   Selected by `RUNNER_BACKEND=real`; the default is `stub` (see runner.sh).
#
# WHY AN ADAPTER (and not a bare `source lib/local-agent.sh; source lib/coordinator.sh`)
#   The stub headers CLAIM the real libs are a "byte-for-byte drop-in," but they
#   are not: the real libs realise the §3 jobs under DIFFERENT public names / arg
#   orders (verified, claude-tools-v2c2):
#     • la_heartbeat(project,actual,task,gen)  → real la_report_heartbeat(actual,task)
#       (reads PROJECT_REF from env; does NOT renew the lease — §3 j3 says
#       heartbeat renews held leases, so the adapter ALSO issues the lease-renew)
#     • la_publish_work_snapshot(project)      → real la_publish_workspace_inventory()
#     • co_deliver_desired_state(project)      → real co_request <tok> poll <project>
#       then extract `.desired` (fail-OPEN to "running" per §6.2 / §2.4)
#     • co_store_put(kind,json)                → real co_request <tok> put <kind> <id> <json>
#       (the id is derived from the record; the runner passes only kind+json)
#     • co_lease_renew / co_lease_release      → real co_request <tok> lease-renew/-release
#       (no PUBLIC co_lease_renew/-release exists; only the co_request verbs)
#     • co_lease_acquire(task,owner)           → real co_request <tok> lease-acquire,
#       NORMALISED: the real grant echoes the whole §4.4 Lease record, but the
#       runner threads the GENERATION into renew/release — so echo `.generation`
#       only (the stub contract the runner is written against).
#   These are bash IMPLEMENTATION-NAME differences between two conformant
#   realisations of the SAME frozen §3 jobs — an integration adapter, NOT an
#   INTERFACE.md change. The §11 escalation path is for a frozen cross-tier
#   CONTRACT gap; §3 (the six jobs) is intact and both sides honour it.
#
# BINDS — INTERFACE.md v1 (FROZEN): §3 (the six jobs), §2.4 (deliver-desired-
#   state), §4.2 (RunnerState), §4.4 (Lease + monotonic generation fencing),
#   §6.1 (lease acquire/renew/release), §6.2 (unreachable posture: capacity
#   fails OPEN, fresh-lease fails CLOSED), §8.2 (terminal-reason re-home), §9.1
#   (the one authenticate→principal chokepoint).
#
# Safe to `source` under `set -uo pipefail`: only function/constant defs + the
# three library sources (themselves def-only at top level) + one bearer-token
# resolution; no top-level fallible work that can abort the loop.

RB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ── source the real backend libraries ────────────────────────────────────────
# Order matters:
#   1. coordinator.sh   — defines the in-process co_request dispatcher + co_*.
#   2. local-agent.sh   — defines la_* incl. la_coordinator_token (used by #3).
#   3. co-http-transport.sh — OVERRIDES co_request to POST to COORDINATOR_URL
#      when that env is set (else a no-op; the in-process co_request stands).
#      Sourced last so the override wins; resolves its bearer via #2.
# shellcheck source=/dev/null
source "$RB_DIR/coordinator.sh"
# shellcheck source=/dev/null
source "$RB_DIR/local-agent.sh"
# shellcheck source=/dev/null
source "$RB_DIR/co-http-transport.sh"

# ── §9.1/§9.2 bearer token resolution (resolved once) ────────────────────────
# COORDINATOR_TOKEN (explicit/test binding) → la_coordinator_token (the §9.2
# per-workspace Keychain token, fail-OPEN to empty) → a non-empty local constant
# so the IN-PROCESS co_authenticate (which accepts any non-empty bearer, §9.1)
# proceeds. With a hosted COORDINATOR_URL and no real token the Worker 401s
# LOUDLY — that is the correct fail-safe, not silently-fabricated access.
RB_BEARER="${COORDINATOR_TOKEN:-}"
[[ -n "$RB_BEARER" ]] || RB_BEARER="$(la_coordinator_token 2>/dev/null || true)"
[[ -n "$RB_BEARER" ]] || RB_BEARER="local-agent-bearer"

# ════════════════════════════════════════════════════════════════════════════
# Pass-through surface — names + arg orders ALREADY match the runner's calls, so
# the real lib functions are used verbatim (NO wrapper): co_authenticate (§9.1,
# called directly @ runner.sh authenticate chokepoint), co__PRINCIPAL_V1 (§9.1
# fallback principal), la_runner_id (§1.1 identity), la_capacity_check (§3 j2 /
# §6.3 fail-OPEN), la_report_terminal_reason (§3 j6 / §8.2). They come from the
# sourced libs above and are intentionally NOT redefined here.
# ════════════════════════════════════════════════════════════════════════════

# ── §3 j1 / §6.1 — claim-lease ───────────────────────────────────────────────
# Runner call: co_lease_acquire <task_ref> <owner>   (stub surface — no bearer).
# Real grant echoes the full §4.4 Lease record; the runner uses the output as
# the GENERATION it threads into renew/release. Normalise: echo `.generation`
# only, preserve rc (0 grant / nonzero deny — incl. Coordinator-unreachable,
# which co_request surfaces as a nonzero transport/auth rc → the runner does not
# claim, the §6.2 fresh-lease-fails-CLOSED posture).
co_lease_acquire() {
  local task="${1:-}" owner="${2:-}" rec rc gen
  rec="$(co_request "$RB_BEARER" lease-acquire "$task" "$owner")"; rc=$?
  [[ $rc -ne 0 ]] && return "$rc"
  gen="$(printf '%s' "$rec" | jq -r '.generation // empty' 2>/dev/null)" || gen=""
  # A grant with no extractable generation is unusable as a lease (the runner
  # would thread an empty gen into renew/release) — treat it as a deny so the
  # caller's `-z "$gen"` / rc guard does not claim. Self-enforcing, not caller-
  # dependent.
  [[ -n "$gen" ]] || return 1
  printf '%s' "$gen"
  return 0
}

# ── §3 j3 / §6.1 — renew held lease (§4.4 fenced by generation) ──────────────
# Runner call: co_lease_renew <task_ref> <owner> <generation>. Output (the
# renewed Lease record) is discarded by the runner; only rc matters.
co_lease_renew() {
  co_request "$RB_BEARER" lease-renew "${1:-}" "${2:-}" "${3:-}" >/dev/null
}

# ── §3 j1 pairing / §6.1 — release lease ─────────────────────────────────────
# Runner call: co_lease_release <task_ref> <owner> <generation>.
co_lease_release() {
  co_request "$RB_BEARER" lease-release "${1:-}" "${2:-}" "${3:-}" >/dev/null
}

# ── §3 j4 / §2.4 — reconcile-desired-state (LOCAL-FIRST, claude-tools-y6j9) ───
# Runner call: co_deliver_desired_state <project_ref> → echo the §4.2 `desired`
# enum (running|paused|spare-cycles|stopped).
#
# THE FIX (break-through-pause, dky8/y6j9): the runner is AUTHORITATIVE for
# desired. Read the LOCAL `.co-store/runner_state.desired` FIRST — a present
# paused/stopped MUST survive a Coordinator-unreachable window. The old body did
# a live `co_request poll` every reconcile and fail-OPENed to "running" on ANY
# failure (and `|| echo running` returned rc 0, so the runner's
# `safe_capture COORD_UNREACHABLE running` degrade NEVER fired) — one failed poll
# discarded a 17h paused history and broke through to CLAIM. Now the cloud only
# QUEUES Brian's change-requests (the agent_actions `set-desired` intent); the
# daemon consumes them and applies the value to this same local record. The
# runner NEVER re-derives desired from a live network read when a local value
# exists, so an unreachable (or 5xx) engine can no longer flip a local pause to
# running.
#
# co__store_get reads the local store file DIRECTLY — the HTTP transport
# (co-http-transport.sh) overrides `co_request`, NOT the store primitives — so
# this read is offline and authoritative (CO_STORE is exported by runner.sh at
# startup to the per-workspace .beads/runner-logs/.co-store path).
#
# Network is consulted ONLY on cold-start (no local record yet) as a best-effort
# seed; if the engine is unreachable or returns no usable desired, fall to the
# EXPLICIT bootstrap default "running" (a runner was LAUNCHED ⇒ its implicit
# desired is running; there is no local pause to break through in the absent
# case). The runner does NOT persist here — the daemon is the single writer of
# local desired (change-request consume + cold-start seed).
co_deliver_desired_state() {
  local proj="${1:-}" rec out d
  rec="$(co__store_get runner_state "$proj" 2>/dev/null)" || rec=""
  if [[ -n "$rec" ]]; then
    d="$(printf '%s' "$rec" | jq -r 'if type=="object" then (.desired // "") else "" end' 2>/dev/null)" || d=""
    case "$d" in
      running|paused|spare-cycles|stopped) echo "$d"; return 0 ;;
    esac
  fi
  # Cold-start: no usable local desired. Best-effort network seed, else bootstrap.
  out="$(co_request "$RB_BEARER" poll "$proj" 2>/dev/null)" || out=""
  if [[ -n "$out" ]]; then
    d="$(printf '%s' "$out" | jq -r 'if type=="object" then (.desired // "") else "" end' 2>/dev/null)" || d=""
    case "$d" in
      running|paused|spare-cycles|stopped) echo "$d"; return 0 ;;
    esac
  fi
  echo "running"
  return 0
}

# ── §2.1/§4 store put (used by the §7.3 dossier drive) ───────────────────────
# Runner call: co_store_put <kind> <json>. The real store is keyed by (kind,id);
# the runner passes only kind+json, so derive the id from the record (Dossier.id,
# else bead_ref/task_ref). The runner ignores rc (degrades on failure), so a
# missing id degrades cleanly rather than aborting.
co_store_put() {
  local kind="${1:-}" json="${2:-}" id
  id="$(printf '%s' "$json" | jq -r '.id // .bead_ref // .task_ref // empty' 2>/dev/null)" || id=""
  # No derivable key ⇒ return nonzero so the caller degrades, rather than
  # silently clobbering a shared "unknown" record (the runner's call site is
  # `co_store_put dossier "$rec" || degrade DOSSIER_STORE …`).
  [[ -n "$id" ]] || return 1
  co_request "$RB_BEARER" put "$kind" "$id" "$json" >/dev/null
}

# ── §3 j3 / §4.2 — heartbeat-actual-state(+liveness) (+ renews held lease) ───
# Runner call: la_heartbeat <project_ref> <actual> <task_ref|""> <lease_gen|"">.
# The real LA reports actual-state UP via la_report_heartbeat(actual,[task]),
# reading PROJECT_REF from env. §3 j3 ALSO renews held leases — the real
# heartbeat report does not, so the adapter issues the lease-renew here (the
# runner has no separate per-tick job_renew_lease call site; renewal rides the
# heartbeat). Renew is best-effort (a stale/expired-gen renew is a no-op the
# next acquire heals); it must never abort the loop.
# claude-tools-h9dl: surface the renew's rc in the LA_LEASE_RENEW_RC sidecar (0 ⇒
# GRANTED, nonzero ⇒ denied/unreachable, "" ⇒ no renew attempted) so the runner's
# §6.2 lease-cache refresh re-stamps the local envelope ONLY on a renew the engine
# actually GRANTED — a reachable-but-DENIED renew (a mid-outage takeover bumped the
# generation, then connectivity returned) must NOT extend the local hold for a
# lease we just lost. The loop still never sees this rc (la_heartbeat returns 0).
la_heartbeat() {
  local proj="${1:-}" actual="${2:-}" task="${3:-}" gen="${4:-}"
  PROJECT_REF="$proj" la_report_heartbeat "$actual" "$task"
  if [[ -n "$task" && -n "$gen" ]]; then
    co_request "$RB_BEARER" lease-renew "$task" "${RUNNER_ID:-$(la_runner_id)}" "$gen" >/dev/null 2>&1
    LA_LEASE_RENEW_RC=$?
  else
    LA_LEASE_RENEW_RC=""   # no renew attempted this beat (no held lease / no gen)
  fi
  return 0
}

# ── §3 j5 / §4.5 — publish-work-snapshot (read-only projection) ──────────────
# Runner call: la_publish_work_snapshot <project_ref>. The real LA producer is
# la_publish_workspace_inventory (no args; reads PROJECT_REF + bd). Best-effort
# (guards on bd/jq; returns 0 regardless — never blocks task pickup).
la_publish_work_snapshot() {
  PROJECT_REF="${1:-${PROJECT_REF:-}}" la_publish_workspace_inventory
  return 0   # best-effort §3 j5: never propagate a producer hiccup to the loop
}
