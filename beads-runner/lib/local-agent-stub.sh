# shellcheck shell=bash
# beads-runner/lib/local-agent-stub.sh — in-process NO-OP Local Agent stub
# (T2.1, claude-tools-1p0).
#
# WHAT THIS IS
#   The machine-local half of the runner's six-job call surface (INTERFACE.md
#   v1 §3). The runner CALLS these; the bodies are no-ops here so T2 can prove
#   the loop shape before the real per-computer Local Agent (T3,
#   claude-tools-3al, lib/local-agent.sh) exists. Where the real T3 lib already
#   binds the same frozen section, this stub uses the SAME function name and
#   the SAME argument order — that is signature CONFORMANCE (the real lib is
#   itself contract-conformant), not extra coupling: the real lib is a
#   byte-for-byte drop-in replacement for the overlapping surface, and the
#   runner's call sites never change.
#
# BINDS — INTERFACE.md v1 (FROZEN). Each signature cites the section it is
# derived from (EXIT criterion 2: reviewer diffs signature ↔ section). No
# locally-invented signature; an interface gap is a §11 BLOCKING escalation.
#   §1.1  — UP-only: capacity report + terminal-reason report flow up
#   §3 j2 — ask-capacity (coarse verdict; failure posture §6.2 fail-OPEN)
#   §3 j3 — heartbeat-actual-state(+liveness): RunnerState.actual +
#           last_heartbeat_at every HEARTBEAT_INTERVAL (§4.2); renews leases
#   §3 j5 — publish-work-snapshot: the read-only §4.5 projection
#   §3 j6 — report-terminal-reason: a last durable control-plane write of the
#           BC-21 class (or STUCK_NEEDS_HUMAN) BEFORE the process exits (§8.2)
#   §6.2  — unreachable posture: capacity fails OPEN; lease degraded-CLOSED
#           with a bounded local fallback (LA enforces the cached lease)
#   §6.3  — coarse capacity verdict ∈ {ok, over}
#
# ANTI-DRIFT: NO-OP only. MUST NOT implement the real BC-34 keychain/usage path
# (T3), classification (T2.2), watchdog/liveness evaluation (T2.3), teardown
# (T2.4) or the worker prompt (T2.5). It only conforms to the call signatures.

# ── §0.5 frozen constants (env-overridable; default == §0.5 table value) ──────
la__LEASE_TTL()      { echo "${LEASE_TTL:-900}"; }       # §0.5 LEASE_TTL (900 s)
la__PRINCIPAL_V1()   { echo "${PRINCIPAL_V1:-brian}"; }  # §0.5 PRINCIPAL_V1

# ── identity (signatures identical to the real T3 lib) ───────────────────────
# la_runner_id — stable per-runner id (one Local Agent per computer; RUNNER_ID
# overrides; hostname default). Stamped on every UP report (§1.1).
la_runner_id() {
  if [[ -n "${RUNNER_ID:-}" ]]; then printf '%s' "$RUNNER_ID"; return 0; fi
  local h; h=$(hostname 2>/dev/null) || h=""
  printf '%s' "${h:-localhost}"
}
# la_principal — the §9.1-resolved principal (constant PRINCIPAL_V1 in v1).
la_principal() { la__PRINCIPAL_V1; }

# ── §3 job 2 / §6.3 — ask-capacity, fail-OPEN posture (§6.2) ──────────────────
# la_capacity_check <cost_class>   (cost_class ∈ standard | low_priority)
#   return 0 → verdict ok   (proceed)
#   return 1 → verdict over (hard 5h/7d ceiling, or low_priority spare ramp)
# Signature identical to the real T3 lib. §6.2: EVERY credential/API error
# fails OPEN (return 0) — a one-task overshoot is noise, a silent halt is the
# SCAR. The stub has no measurement path, so it always returns the fail-OPEN
# verdict `ok` — exactly the posture the real lib degrades to on error.
la_capacity_check() {
  local cost_class="${1:-standard}"
  return 0
}

# ── §3 job 3 / §4.2 — heartbeat-actual-state(+liveness) ──────────────────────
# Every HEARTBEAT_INTERVAL the runner writes RunnerState.actual +
# last_heartbeat_at (§4.2 — last_heartbeat_at is the S-1 liveness datum) and
# the call renews any held lease (§3 job 3 / §6.1, fenced by §4.4 generation).
# la_heartbeat <project_ref> <actual> <task_ref|""> <lease_generation|"">
#   actual ∈ starting|running|idle|stopping|stopped|crashed (§4.2)
#   → 0. NO-OP: the real Coordinator/LA path (T3/T4) persists the §4.2 record.
la_heartbeat() {
  local project_ref="${1:-}" actual="${2:-}" task_ref="${3:-}" lease_gen="${4:-}"
  [[ -n "$project_ref" && -n "$actual" ]] || return 1
  return 0
}

# ── §3 job 5 / §4.5 — publish-work-snapshot (read-only projection) ───────────
# Publish the §4.5 read-only projection (Dolt remains work-truth; this is a
# projection, not a second source — no write path from any reader).
# la_publish_work_snapshot <project_ref> → 0. NO-OP.
la_publish_work_snapshot() {
  local project_ref="${1:-}"
  [[ -n "$project_ref" ]] || return 1
  return 0
}

# ── §3 job 6 / §8.2 — report-terminal-reason (re-home S-7) ────────────────────
# Signature identical to the real T3 lib. THE re-home: a heartbeat-absence
# channel cannot tell AUTH=3 from clean=0, so this is a LAST DURABLE control-
# plane write performed BEFORE the runner process exits, carrying the BC-21
# class OR STUCK_NEEDS_HUMAN. Never aborts (it must not mask the real exit
# reason). NO-OP here; T3 writes the durable §8.2 record.
# la_report_terminal_reason <terminal_class> <bc21_exit|""> <task_ref|""> <project_ref|"">
#   classes: CLEAN(0) INTERRUPTED(1) CIRCUIT_BREAKER(2) AUTH_FAILURE(3)
#            BILLING_ERROR(4) | STUCK_NEEDS_HUMAN (no exit code — §7.5/§8.1)
la_report_terminal_reason() {
  local cls="${1:-UNKNOWN}" exit_code="${2:-}" task_ref="${3:-}" project_ref="${4:-}"
  return 0
}

# ── §1.1 — UP capacity report ────────────────────────────────────────────────
# Signature identical to the real T3 lib. The Coordinator never reads a
# Keychain/usage API; it aggregates what Local Agents report (§1.1 item 1).
# la_report_capacity <cost_class> <verdict>  (verdict ∈ ok|over) → 0. NO-OP.
la_report_capacity() {
  local cost_class="${1:-}" verdict="${2:-}"
  [[ -n "$cost_class" && -n "$verdict" ]] || return 1
  return 0
}

# ── §6.2 / AD2.2 — bounded LOCAL lease fallback (signatures == real T3 lib) ───
# The LA does NOT grant leases (no arbitration — T4). It only decides whether
# THIS runner may proceed when the Coordinator is unreachable: continue ONLY a
# task whose lease it ALREADY holds AND is still valid; a missing/expired local
# lease ⇒ refuse (no NEW unsynchronised claim — keeps a blip from stranding
# in-flight work without reintroducing BC-04). The stub holds nothing, so the
# `reachable` path returns 0 (Coordinator arbitrates) and the `unreachable`
# path with no cached lease returns 1 (degraded-CLOSED) — the real posture.
# la_lease_note_held    <task_ref> [acquired_at_epoch]   → record/refresh hold
# la_lease_release_local <task_ref>                      → forget local hold
# la_lease_fallback_allows <task_ref> <reachable|unreachable> → 0 may | 1 must-not
la_lease_note_held() {
  local task_ref="${1:-}" at="${2:-}"
  [[ -n "$task_ref" ]] || return 0
  return 0
}
la_lease_release_local() {
  local task_ref="${1:-}"
  [[ -n "$task_ref" ]] || return 0
  return 0
}
la_lease_fallback_allows() {
  local task_ref="${1:-}" reach="${2:-reachable}"
  [[ -n "$task_ref" ]] || return 1
  if [[ "$reach" != "unreachable" ]]; then
    return 0     # reachable ⇒ Coordinator arbitrates; LA does not block
  fi
  return 1        # unreachable + no cached lease ⇒ degraded-CLOSED (§6.2)
}
