# shellcheck shell=bash
# beads-runner/lib/coordinator-stub.sh — in-process NO-OP Coordinator stub
# (T2.1, claude-tools-1p0).
#
# WHAT THIS IS
#   The runner is the CALLER of the six jobs (INTERFACE.md v1 §3). T2 proves
#   the runner's loop shape and call surface BEFORE any real Coordinator (T4)
#   exists. This file is the callee: an in-process NO-OP Coordinator whose
#   function signatures conform — byte-for-byte — to INTERFACE.md v1 §2 (the
#   four capabilities), §4 (store schemas) and §6 (lease). No behavior beyond
#   what is needed to return a contract-shaped answer; no persistence model, no
#   arbitration, no consistency machinery. T4 (claude-tools, the real
#   Coordinator) replaces this file wholesale — the runner's job call sites do
#   not change when it does (that is the point of proving the surface here).
#
# BINDS — INTERFACE.md v1 (FROZEN). Every signature below is DERIVED from a
# frozen section and cites it; a reviewer diffs the signature against the cited
# section (EXIT criterion 2). No signature is invented locally — an interface
# gap would be a §11 BLOCKING escalation (reopen claude-tools-65z), never a
# local stub-contract invention.
#   §2.1 — small strongly-consistent store (Dossier / RunnerState /
#          Notification / Lease / work-snapshot — §4 records)
#   §2.2 — durable one-shot timer  fire(dossier_id) at T
#   §2.3 — authed endpoint, ONE authenticate(request) → principal chokepoint
#   §2.4 — deliver-desired-state-on-reconnect
#   §4.2 — RunnerState{desired,actual,last_heartbeat_at,…}
#   §4.4 — Lease{owner,generation,ttl_seconds,…} monotonic fencing token
#   §6.1 — lease acquire/renew/release; AD2.1 acquire BEFORE in_progress
#   §6.3 — ask-capacity coarse verdict ∈ {ok, over}
#
# ANTI-DRIFT: NO extra coupling beyond the signatures. The stub MUST NOT
# acquire dependencies on T2.2 (classification), T2.3 (watchdog), T2.4
# (teardown) or T2.5 (worker prompt). It is a no-op surface, nothing more.
#
# Safe to `source` under `set -uo pipefail`: only function/constant defs; no
# top-level fallible work.

# ── §0.5 frozen constants (single normative definition is INTERFACE.md; these
#    are env-overridable lookups whose literal default EQUALS the §0.5 table
#    value — never a competing normative value, §0.5) ──────────────────────────
co__LEASE_TTL()     { echo "${LEASE_TTL:-900}"; }       # §0.5 LEASE_TTL (900 s)
co__PRINCIPAL_V1()  { echo "${PRINCIPAL_V1:-brian}"; }  # §0.5 PRINCIPAL_V1

# ── §2.3 / §9.1 — the ONE authenticate chokepoint ────────────────────────────
# co_authenticate <bearer_token> → echoes the resolved principal, returns 0 if
# a token is present (validity is a constant-true in v1, §9.1), 1 otherwise.
# v1 resolves the CONSTANT principal AFTER validating presence; callers stamp
# §4 records with the RESOLVED value, never a literal at the use site (C7).
co_authenticate() {
  local token="${1:-}"
  [[ -n "$token" ]] || return 1
  co__PRINCIPAL_V1
  return 0
}

# ── §2.1 / §4 — small strongly-consistent store (NO-OP) ──────────────────────
# The store holds the §4 records (Dossier{body,items[]} / RunnerState /
# Notification / Lease / work-snapshot). The stub accepts a contract-shaped
# record and acknowledges it; it does NOT model strong consistency, schema
# versioning enforcement, or persistence — that is T4 (§4 store owner).
# co_store_put <kind> <json>   — kind ∈ dossier|runner_state|notification|lease|work_snapshot
# co_store_get <kind> <key>    — echoes a contract-shaped record or empty (no-op)
co_store_put() {
  local kind="${1:-}" json="${2:-}"
  [[ -n "$kind" && -n "$json" ]] || return 1
  return 0
}
co_store_get() {
  local kind="${1:-}" key="${2:-}"
  [[ -n "$kind" && -n "$key" ]] || return 1
  return 0
}

# ── §2.2 — durable one-shot timer  fire(dossier_id) at T (NO-OP) ─────────────
# co_timer_fire_at <dossier_id> <fire_at_epoch>. The S-6 backstop
# (missed-fire ⇒ fire-on-next-poll) and the §7.4 per-Item idempotency latch
# are T5's; the stub only conforms to the SET signature.
co_timer_fire_at() {
  local dossier_id="${1:-}" fire_at="${2:-}"
  [[ -n "$dossier_id" && -n "$fire_at" ]] || return 1
  return 0
}

# ── §2.4 / §4.2 — deliver-desired-state-on-reconnect ─────────────────────────
# co_deliver_desired_state <project_ref> → echoes RunnerState.desired
# (§4.2 enum: running|paused|spare-cycles|stopped). This is reconciliation
# (desired-state mutation), NOT a durable command queue (§2.4). The stub is a
# no-op authority: a fresh runner with no prior desired-state reconciles to
# `running` (the §4.2 default for a live project).
co_deliver_desired_state() {
  local project_ref="${1:-}"
  [[ -n "$project_ref" ]] || return 1
  echo "running"
  return 0
}

# ── §6.1 / §4.4 — lease acquire / renew / release (NO-OP) ─────────────────────
# AD2.1: the lease is acquired BEFORE `bd update --status=in_progress`; the
# runner consults it on EVERY pickup. §4.4: a monotonic `generation` is the
# fencing token — a renew/release with a stale generation is rejected (this is
# what closes the BC-04 two-runners-one-orphan race; the binding is T4's, the
# CALL surface is T2.1's). The stub grants unconditionally (no global
# arbitration here — that is T4) and hands back a fencing generation so the
# runner can carry it through renew/release exactly as it will with the real
# Coordinator.
#
# co_lease_acquire <task_ref> <owner>            → 0 + echoes generation | 1 deny
# co_lease_renew   <task_ref> <owner> <gen>      → 0 ok | 1 rejected (stale gen)
# co_lease_release <task_ref> <owner> <gen>      → 0 ok | 1 rejected (stale gen)
co_lease_acquire() {
  local task_ref="${1:-}" owner="${2:-}"
  [[ -n "$task_ref" && -n "$owner" ]] || return 1
  echo "1"            # §4.4 generation (monotonic fencing token)
  return 0
}
co_lease_renew() {
  local task_ref="${1:-}" owner="${2:-}" generation="${3:-}"
  [[ -n "$task_ref" && -n "$owner" && -n "$generation" ]] || return 1
  return 0
}
co_lease_release() {
  local task_ref="${1:-}" owner="${2:-}" generation="${3:-}"
  [[ -n "$task_ref" && -n "$owner" && -n "$generation" ]] || return 1
  return 0
}

# ── §6.3 — coarse capacity verdict ∈ {ok, over} ──────────────────────────────
# The Coordinator AGGREGATES what Local Agents report (§1.1) — it never reads a
# Keychain/usage API. The runner asks capacity via the Local Agent (machine-
# local measurement, §6.3); this Coordinator-side aggregate verdict exists so
# the surface is complete. Coarse: cost_class ∈ {standard, low_priority},
# verdict ∈ {ok, over}. The stub aggregates to `ok` (no fleet pressure).
# co_aggregate_capacity <cost_class> → echoes ok|over
co_aggregate_capacity() {
  local cost_class="${1:-standard}"
  echo "ok"
  return 0
}
