# shellcheck shell=bash
# beads-runner/lib/local-agent.sh — the per-computer Local Agent (T3, claude-tools-3al).
#
# WHAT THIS IS (DESIGN §2 "Local Agent" row; epic claude-tools-glk):
#   The machine-local measurement & supervision authority. One per computer.
#   Capacity and credentials are machine-local; this tier owns them. It NEVER
#   originates desired-state and contains NO Coordinator-side logic — it only
#   reports UP (§1.1).
#
# BINDS — INTERFACE.md v1 (FROZEN), the sections this file owns per §11:
#   §1.1  — UP-only directionality (capacity report + terminal-reason report)
#   §6.2  — unreachable posture: capacity fails OPEN; lease degraded-CLOSED
#           with a bounded local fallback (the LA enforces the cached lease)
#   §6.3  — coarse capacity verdict {ok,over}; USAGE_THRESHOLD hard ceiling,
#           USAGE_CACHE_SECONDS TTL cache, SPARE_RAMP_PER_DAY soft ramp
#   §8.2  — terminal-reason re-home: a durable control-plane record written
#           BEFORE the runner process exits, carrying the BC-21 class (or
#           STUCK_NEEDS_HUMAN), so a heartbeat-absence channel can tell
#           AUTH=3 from clean=0
#   §9.2  — per-runner Coordinator bearer token in the SAME machine
#           secure-store family as the BC-34 credential path (macOS Keychain),
#           distinct service; the LA owns reading it
#   §10.2 — redaction happens at the runner tier (this tier); raw stream-json
#           never leaves the machine (helper exposed; producer is T2)
#
# ANTI-DRIFT (this task's contract): this file touches ONLY the Local Agent
# surface + the upward report contract. It does NOT implement lease
# ARBITRATION (granting/serialising leases globally) — that is T4. The LA only
# *enforces* an already-held, still-valid local lease when the Coordinator is
# unreachable (§6.2 / AD2.2 bounded fallback).
#
# Safe to `source` under `set -euo pipefail`: only function definitions and
# constant lookups below; every fallible call is guarded. Frozen numeric
# constants are read from the environment with the INTERFACE.md §0.5 default
# so a caller (or the Coordinator, later) can inject them without edits here —
# the literal default equals the §0.5 table value, never a competing one.

# ── §0.5 frozen constants (single normative definition is INTERFACE.md;
#    these are env-overridable lookups defaulting to the frozen value) ─────────
la__USAGE_THRESHOLD()     { echo "${USAGE_THRESHOLD:-70}"; }      # §0.5 USAGE_THRESHOLD (0 disables)
la__USAGE_CACHE_SECONDS() { echo "${USAGE_CACHE_SECONDS:-300}"; } # §0.5 USAGE_CACHE_SECONDS
la__SPARE_RAMP_PER_DAY()  { echo "${SPARE_RAMP_PER_DAY:-14.2}"; } # §0.5 SPARE_RAMP_PER_DAY
la__LEASE_TTL()           { echo "${LEASE_TTL:-900}"; }           # §0.5 LEASE_TTL
la__PRINCIPAL_V1()        { echo "${PRINCIPAL_V1:-brian}"; }      # §0.5 PRINCIPAL_V1

# ── identity & locations ─────────────────────────────────────────────────────

# la_runner_id — stable per-runner id. One Local Agent per computer, so the
# hostname is the machine-local default; RUNNER_ID overrides (e.g. multiple
# logical runners on one host). Used as the Keychain `account` (§9.2) and
# stamped on every UP report (§1.1).
la_runner_id() {
  if [[ -n "${RUNNER_ID:-}" ]]; then printf '%s' "$RUNNER_ID"; return 0; fi
  local h; h=$(hostname 2>/dev/null) || h=""
  printf '%s' "${h:-localhost}"
}

# la_principal — the resolved principal (§9.1). v1 = the constant PRINCIPAL_V1
# AFTER the auth chokepoint resolves it; callers stamp records with THIS, never
# a hardcoded literal at the use site (C7: later = mint real tokens, no schema
# change).
la_principal() { la__PRINCIPAL_V1; }

# la_log_dir — the machine-local control-plane drop. Defaults to the runner's
# self-gitignoring LOG_DIR (§10.1: raw post-mortem never enters a committable
# path; the terminal-reason record is a control record, not forensic content,
# but lives under the same machine-local, never-committed dir).
la_log_dir() { printf '%s' "${LOG_DIR:-.beads/runner-logs}"; }

la__ensure_logdir() {
  local d; d="$(la_log_dir)"
  mkdir -p "$d" 2>/dev/null || true
  # Preserve the BC-27 self-gitignore boundary if we are the first to create it.
  [[ -f "$d/.gitignore" ]] || printf '*\n!.gitignore\n' > "$d/.gitignore" 2>/dev/null || true
  printf '%s' "$d"
}

# The §1.1 UP queue. With no Coordinator yet (T4), "report UP" is realised as a
# machine-local append-only outbox the Coordinator drains on reconnect (§2.4).
# This is a realisation seam, NOT Coordinator-side logic (anti-drift) and NOT a
# normative provider primitive (§0.2 — Appendix A territory).
la__outbox() { printf '%s/coordinator-outbox.jsonl' "$(la__ensure_logdir)"; }

# ── §9.2 token storage — Coordinator bearer token in the Keychain ────────────
# Distinct generic-password service from Anthropic's "Claude Code-credentials"
# entry; account = runner_id. The LA owns reading it (same tier as the BC-34
# Keychain path). Fail-OPEN and silent: a missing/locked Keychain MUST NOT
# abort the runner — it degrades to "no token" (the §6.2 posture, applied to
# the auth read too). No token is ever sourced from env/source/beads.
LA_COORDINATOR_TOKEN_SERVICE="claude-beads-runner.coordinator-token"

la_coordinator_token() {
  local tok
  tok=$(security find-generic-password \
          -s "$LA_COORDINATOR_TOKEN_SERVICE" \
          -a "$(la_runner_id)" -w 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$tok"
}

# ── BC-34 credential path + §6.3 coarse capacity verdict ─────────────────────
# la__anthropic_token — read the Anthropic OAuth token from the macOS Keychain
# (the BC-34 credential path). Returns:
#   0 + token        creds present and parseable
#   10               keychain unreadable      → caller fails OPEN
#   11               creds present, no token  → caller fails OPEN
# Stderr notes are the BC-34 contract strings (preserved VERBATIM so the
# regression assertion stays GREEN; the rig substring-matches these).
la__anthropic_token() {
  local creds token
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || {
    echo "  (Could not read credentials for usage check — skipping)" >&2
    return 10
  }
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  if [[ -z "$token" ]]; then
    echo "  (No OAuth token found — skipping usage check)" >&2
    return 11
  fi
  printf '%s' "$token"
}

# la__usage_json <token> — call the Anthropic usage API. Echoes the JSON on
# success; returns nonzero (caller fails OPEN with the contract note) on any
# transport/API error.
la__usage_json() {
  local token="$1" json
  json=$(curl -s -f -X GET "https://api.anthropic.com/api/oauth/usage" \
           -H "Accept: application/json" \
           -H "Content-Type: application/json" \
           -H "Authorization: Bearer $token" \
           -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || {
    echo "  (Usage API call failed — skipping check)" >&2
    return 1
  }
  printf '%s' "$json"
}

# la__spare_ramp_pct — the §6.3 soft-ramp ceiling for low_priority work: day N
# of the 7d window allows ≤ N × SPARE_RAMP_PER_DAY of the 7d budget. The window
# anchor is Coordinator-aggregated globally (T4); the LA owns only the local
# *measurement*, deliberately coarse (AD2.3: the ramp is a soft line, the hard
# 5h/7d ceiling is the real guard). SPARE_DAY_INDEX overrides the day index
# (1..7) for a deterministic measurement / test; default = rolling day-of-cycle.
la__spare_ramp_pct() {
  local day ramp now
  if [[ -n "${SPARE_DAY_INDEX:-}" ]]; then
    day="$SPARE_DAY_INDEX"
  else
    now=$(date +%s 2>/dev/null || echo 0)
    day=$(( (now / 86400) % 7 + 1 ))      # 1..7, rolling
  fi
  # ramp = day * SPARE_RAMP_PER_DAY, capped at 100, integer-truncated (the
  # verdict is coarse — §6.3 compares integer-truncated utilisation).
  ramp=$(awk -v d="$day" -v r="$(la__SPARE_RAMP_PER_DAY)" \
           'BEGIN{ v=d*r; if(v>100) v=100; printf "%d", v }' 2>/dev/null) || ramp=100
  printf '%s' "${ramp:-100}"
}

# la_capacity_check <cost_class>  (cost_class ∈ standard | low_priority)
#   Returns 0  → verdict ok    (proceed)
#   Returns 1  → verdict over  (hard ceiling or, for low_priority, the ramp)
#
# §6.2 posture: EVERY credential / API / keychain error fails OPEN (return 0)
# with the contract note — a one-task overshoot is noise, a silent halt is the
# SCAR. §6.3: USAGE_THRESHOLD=0 disables the gate entirely (the keychain/API
# path is never touched). `standard` is gated ONLY by the hard 5h-or-7d
# ceiling; `low_priority` is ADDITIONALLY gated by the spare-cycles ramp and
# never starves the weekly cap. The verdict is reported UP (§1.1).
la_capacity_check() {
  local cost_class="${1:-standard}" threshold
  threshold="$(la__USAGE_THRESHOLD)"

  # §6.3: 0 disables — no keychain, no API, no banner, nothing.
  if [[ "$threshold" -eq 0 ]]; then
    return 0
  fi

  local token usage five seven five_i seven_i verdict="ok"
  token=$(la__anthropic_token) || { return 0; }            # §6.2 fail-OPEN
  usage=$(la__usage_json "$token") || { return 0; }         # §6.2 fail-OPEN

  five=$(printf '%s'  "$usage" | jq -r '.five_hour.utilization  // 0' 2>/dev/null) || five=0
  seven=$(printf '%s' "$usage" | jq -r '.seven_day.utilization // 0' 2>/dev/null) || seven=0
  five_i=${five%.*};   five_i=${five_i:-0}
  seven_i=${seven%.*}; seven_i=${seven_i:-0}

  # Hard ceiling (BC-34 verbatim): either window's integer-truncated
  # utilisation ≥ threshold ⇒ over. Applies to BOTH cost classes.
  if [[ "${five_i:-0}" -ge "$threshold" ]] || [[ "${seven_i:-0}" -ge "$threshold" ]]; then
    verdict="over"
    echo "  Usage: 5h=${five}% 7d=${seven}% (threshold: ${threshold}%)"
  elif [[ "$cost_class" == "low_priority" ]]; then
    # Spare-cycles soft ramp: low_priority backfills unused capacity only.
    local ramp; ramp="$(la__spare_ramp_pct)"
    if [[ "${seven_i:-0}" -ge "${ramp:-100}" ]]; then
      verdict="over"
      echo "  Usage: 5h=${five}% 7d=${seven}% (low_priority spare-cycles ramp: ${ramp}%)"
    else
      echo "  Usage: 5h=${five}% 7d=${seven}% (low_priority ≤ ramp ${ramp}%)"
    fi
  else
    echo "  Usage: 5h=${five}% 7d=${seven}%"
  fi

  la_report_capacity "$cost_class" "$verdict" || true
  [[ "$verdict" == "over" ]] && return 1
  return 0
}

# la_report_capacity <cost_class> <verdict>  — §1.1 UP capacity report. The
# Coordinator never reads a Keychain/usage API; it aggregates what Local Agents
# report (§1.1 item 1). Coarse cost-class verdict only.
la_report_capacity() {
  local cost_class="$1" verdict="$2" ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -cn \
     --argjson sv 1 \
     --arg pr  "$(la_principal)" \
     --arg rid "$(la_runner_id)" \
     --arg cc  "$cost_class" \
     --arg vd  "$verdict" \
     --arg at  "$ts" \
     '{report:"capacity",schema_version:$sv,principal:$pr,runner_id:$rid,
       cost_class:$cc,verdict:$vd,observed_at:$at}' \
     >> "$(la__outbox)" 2>/dev/null || true
}

# la_report_heartbeat <actual> [current_task_ref]  — §1.1 item-3 / §4.2 UP
# actual-state+liveness heartbeat (the I2 per-workspace registration line;
# epic claude-tools-8bm). The Coordinator never reads runner liveness from
# anywhere — it ingests what the Local Agent reports UP, keyed by the §4.2
# controllable unit `project_ref` (PROJECT_REF, distinct per workspace: this
# is what makes "coordinate across workspaces" = N runners, one hosted
# authority). The drainer (la_outbox_drain) maps report=="heartbeat" to the
# hosted `heartbeat` op (reconcile.js co__heartbeat, differentially proven ≡
# the bash oracle by CF.11); `observed_at` IS last_heartbeat_at, THE S-1
# liveness datum read back as `live` iff now − it ≤ STALE_AFTER. Same
# OPTIONAL/guarded posture as la_report_capacity — every call site in the
# runner is `command -v la_report_heartbeat`-gated; with no hosted
# COORDINATOR_URL the line only ever appends to the durable local outbox
# (byte-unaffected standalone/oracle/conformance runs), exactly as the §1.1
# queue did before I1. `actual` MUST be in the §4.2 enum
# {starting,running,idle,stopping,stopped,crashed}; the hosted co__heartbeat
# rejects anything else (we never best-effort-coerce — pass it verbatim).
la_report_heartbeat() {
  local actual="$1" cur="${2:-}" ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -cn \
     --argjson sv 1 \
     --arg pr  "$(la_principal)" \
     --arg rid "$(la_runner_id)" \
     --arg prj "${PROJECT_REF:-$(basename "$(pwd)" 2>/dev/null)}" \
     --arg act "$actual" \
     --arg cur "$cur" \
     --arg at  "$ts" \
     '{report:"heartbeat",schema_version:$sv,principal:$pr,runner_id:$rid,
       project_ref:$prj,actual:$act,observed_at:$at}
      + (if $cur=="" then {} else {current_task_ref:$cur} end)' \
     >> "$(la__outbox)" 2>/dev/null || true
}

# ── §8.2 terminal-reason re-home ─────────────────────────────────────────────
# la_report_terminal_reason <terminal_class> <bc21_exit> <task_ref> <project_ref>
#
# THE re-home (S-7): a heartbeat-absence channel structurally cannot tell
# AUTH=3 from clean=0. So this is a LAST DURABLE control-plane write performed
# BEFORE the runner process exits, observed by the Local Agent from the actual
# intended process exit code. The record carries the BC-21 class OR
# STUCK_NEEDS_HUMAN (§1.1 item 2 / §8.2). Written two places:
#   1. $LOG_DIR/terminal-reason         — the single authoritative latest
#      record (the literal close-criterion the BC-21 §8.2 gate checks).
#   2. $LOG_DIR/coordinator-outbox.jsonl — appended to the §1.1 UP queue the
#      Coordinator drains on reconnect (§2.4). No Coordinator-side logic here.
#
# Never aborts (it is the "last durable write"; a failure here must not mask
# the real exit reason). Recognised classes: the BC-21 table classes
# {CLEAN(0), INTERRUPTED(1), CIRCUIT_BREAKER(2), AUTH_FAILURE(3),
# BILLING_ERROR(4)} plus STUCK_NEEDS_HUMAN (no exit code — §7.5/§8.1; accepted
# so T2 can route it through the same upward seam).
la_report_terminal_reason() {
  local cls="${1:-UNKNOWN}" exit_code="${2:-}" task_ref="${3:-}" project_ref="${4:-}" ts rec
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  rec=$(jq -cn \
     --argjson sv 1 \
     --arg pr  "$(la_principal)" \
     --arg rid "$(la_runner_id)" \
     --arg prj "$project_ref" \
     --arg tr  "$task_ref" \
     --arg cl  "$cls" \
     --arg ec  "$exit_code" \
     --arg at  "$ts" \
     '{report:"terminal-reason",tr_schema_version:$sv,principal:$pr,
       runner_id:$rid,project_ref:$prj,task_ref:$tr,terminal_class:$cl,
       bc21_exit:(if $ec=="" then null else ($ec|tonumber? // $ec) end),
       observed_at:$at}' 2>/dev/null) || rec=""
  [[ -z "$rec" ]] && \
    rec="{\"report\":\"terminal-reason\",\"tr_schema_version\":1,\"terminal_class\":\"$cls\",\"bc21_exit\":\"$exit_code\"}"
  local d; d="$(la__ensure_logdir)"
  printf '%s\n' "$rec" >  "$d/terminal-reason"        2>/dev/null || true
  printf '%s\n' "$rec" >> "$d/coordinator-outbox.jsonl" 2>/dev/null || true
  return 0
}

# ── §6.2 / AD2.2 bounded LOCAL lease fallback ────────────────────────────────
# Highest-blast-radius invariant; frozen in the contract, NOT left to
# implementation. The Local Agent enforces this from the locally-cached lease.
# It does NOT grant leases (no arbitration — that is T4); it only decides
# whether *this* runner may keep going when the Coordinator is unreachable.
#
# Local lease cache: one file per held lease under $LOG_DIR/lease-cache/<task>,
# whose mtime (or recorded acquired-at) bounds validity by LEASE_TTL. T4's
# arbitration writes/refreshes these on grant/renew; T3 only reads & TTL-checks.
la__lease_cache_dir() { printf '%s/lease-cache' "$(la__ensure_logdir)"; }

# la_lease_note_held <task_ref> [acquired_at_epoch]
#   Record/refresh a locally-held lease (called by T4's grant/renew path, and
#   by the T3 test). acquired_at defaults to now.
la_lease_note_held() {
  local task="$1" at="${2:-}"
  [[ -n "$task" ]] || return 0
  local dir; dir="$(la__lease_cache_dir)"; mkdir -p "$dir" 2>/dev/null || true
  [[ -z "$at" ]] && at=$(date +%s 2>/dev/null || echo 0)
  printf '%s' "$at" > "$dir/$task" 2>/dev/null || true
}

# la_lease_release_local <task_ref> — drop the local cache entry (lease
# release/expiry maps the bead back to open at the work plane — that side is
# T2/T4; here we only forget the local hold).
la_lease_release_local() {
  local task="$1"; [[ -n "$task" ]] || return 0
  rm -f "$(la__lease_cache_dir)/$task" 2>/dev/null || true
}

# la_lease_fallback_allows <task_ref> <coordinator_reachable: reachable|unreachable>
#   Returns 0 → this runner MAY proceed with <task_ref>
#   Returns 1 → it MUST NOT (no fresh lease ⇒ no new claim)
#
# Rules (§6.2 / AD2.2):
#   reachable   ⇒ 0   the Coordinator arbitrates (T4); the LA does not block
#                     the reachable path — it only owns the unreachable
#                     fallback.
#   unreachable ⇒ continue ONLY a task whose lease we ALREADY hold AND is
#                 STILL VALID (now − acquired_at < LEASE_TTL). A missing OR
#                 expired local lease ⇒ refuse: no NEW unsynchronised claim
#                 (this is exactly what keeps a brief outage from stranding
#                 in-flight work without reintroducing BC-04).
la_lease_fallback_allows() {
  local task="$1" reach="${2:-reachable}"
  [[ -n "$task" ]] || return 1
  if [[ "$reach" != "unreachable" ]]; then
    return 0
  fi
  local f; f="$(la__lease_cache_dir)/$task"
  [[ -f "$f" ]] || return 1                  # no held lease ⇒ no new claim
  local acquired now ttl age
  acquired=$(cat "$f" 2>/dev/null || echo "")
  [[ "$acquired" =~ ^[0-9]+$ ]] || return 1  # unparseable ⇒ refuse (safe)
  now=$(date +%s 2>/dev/null || echo 0)
  ttl="$(la__LEASE_TTL)"
  age=$(( now - acquired ))
  [[ "$age" -lt "$ttl" ]] || return 1        # expired locally ⇒ refuse
  return 0                                    # held + still valid ⇒ continue
}

# ── §10.2 redaction boundary (helper; the producer is T2) ────────────────────
# Redaction happens AT the runner (this tier) BEFORE transit; raw stream-json
# never leaves the machine. T3 owns the boundary fact; T2 produces the blob.
# Exposed so T2 binds to one place: file PATHS kept, file CONTENTS replaced by
# a {byte_length, sha256_prefix(12)} placeholder so size is visible, content
# is not (§10.2).
la_redaction_placeholder() {
  local body="$1" len sha
  len=$(printf '%s' "$body" | wc -c | tr -d ' ' 2>/dev/null || echo 0)
  sha=$(printf '%s' "$body" | shasum -a 256 2>/dev/null | cut -c1-12) || sha=""
  jq -cn --argjson bl "${len:-0}" --arg sp "${sha:-}" \
     '{redacted:true,byte_length:$bl,sha256_prefix:$sp}' 2>/dev/null \
     || printf '{"redacted":true,"byte_length":%s}' "${len:-0}"
}
