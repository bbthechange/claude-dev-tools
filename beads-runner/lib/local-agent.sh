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

# ── M2 (claude-tools-8mz) — consult the daemon's machine-level cache ─────────
# Before M2, every workspace runner did its OWN Keychain read + Anthropic
# API call (la__anthropic_token + la__usage_json). With the daemon up, that
# work moves to ONE central poll per machine (beads-runner/daemon/usage-
# poll.sh), publishing $DAEMON_CACHE_DIR/capacity.json on a TTL. The
# workspace's la_capacity_check consults this cache first; if it's missing
# or stale, the workspace falls back to its direct path (BC-34 fail-OPEN
# preserved — daemon down ⇒ workspace still safe).
#
# CACHE LOCATION
#   Same env contract as the daemon: BEADS_DAEMON_CACHE_DIR override,
#   defaulting to $HOME/.cache/claude-tools. The cache file is the formal
#   "GET /capacity" surface (UX 0.A) — currently file-backed because the
#   blast radius matches a UDS socket (local user FS only) without the
#   listener/server complexity. If we ever swap to a real UDS or local
#   HTTP server, that change lives entirely inside la__capacity_via_daemon.
la__daemon_cache_dir() { printf '%s' "${BEADS_DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"; }
la__daemon_capacity_file() { printf '%s/capacity.json' "$(la__daemon_cache_dir)"; }

# la__capacity_via_daemon — read the daemon's cached verdict. Echoes the
# raw JSON on success; returns nonzero (caller falls back) if:
#   • the cache file does not exist
#   • the cache file is older than la__USAGE_CACHE_SECONDS * 2 (we accept a
#     1× drift over the daemon's own TTL — the daemon's "refresh imminent"
#     window — but past that we treat the cache as dead and fall open)
#   • the cache file is unparseable JSON
la__capacity_via_daemon() {
  local f mtime now age limit json
  f="$(la__daemon_capacity_file)"
  [[ -f "$f" ]] || return 1
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  now=$(date +%s 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  limit=$(( $(la__USAGE_CACHE_SECONDS) * 2 ))
  [[ "$age" -lt "$limit" ]] || return 1
  json=$(cat "$f" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$json"
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

# la__spare_ramp_pct [resets_at] — the §6.3 soft-ramp ceiling for low_priority
# work: day N of the rolling 7d window allows ≤ N × SPARE_RAMP_PER_DAY of the
# 7d budget. The day index is anchored on the Anthropic usage API's
# seven_day.resets_at (the END of the rolling window) — NOT on the calendar
# (x7ve: pre-fix used (epoch_days % 7)+1, which is day-of-week relative to
# 1970-01-01 and so jumped non-monotonically at UTC midnight, uncorrelated
# with the user's real window). The LA owns only the local *measurement*,
# deliberately coarse (AD2.3: the ramp is a soft line, the hard 5h/7d
# ceiling is the real guard). SPARE_DAY_INDEX overrides the day index
# (1..7) for a deterministic measurement / test. Missing resets_at ⇒
# day=1 (conservative: tightest soft line when window position unknown).
la__spare_ramp_pct() {
  local resets="${1:-}" norm day ramp resets_epoch now remaining
  if [[ -n "${SPARE_DAY_INDEX:-}" ]]; then
    day="$SPARE_DAY_INDEX"
  elif [[ -n "$resets" ]]; then
    # Parse ISO 8601 — macOS first, GNU date second, matching the rest of
    # the project's date-arithmetic pattern. pkp2: the real API returns
    # microseconds + explicit +00:00 offset (e.g. "...07:00:00.585476+00:00"),
    # which BSD `date -j -f "%Y-%m-%dT%H:%M:%SZ"` rejects. Normalize: strip
    # fractional seconds, convert "+00:00"/"+0000" to "Z". GNU date handles
    # the raw form fine, so the Linux branch sees the un-normalized string.
    # Non-UTC offsets fall through to day=1, the conservative soft line.
    norm=$(printf '%s' "$resets" | sed -E 's/\.[0-9]+([+-Z])/\1/; s/\+00:?00$/Z/')
    resets_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$norm" +%s 2>/dev/null \
                   || date -u -d "$resets" +%s 2>/dev/null \
                   || echo "")
    if [[ -n "$resets_epoch" ]]; then
      now=$(date +%s 2>/dev/null || echo 0)
      remaining=$(( resets_epoch - now ))
      if (( remaining <= 0 )); then
        day=7
      else
        day=$(( 8 - ( (remaining + 86399) / 86400 ) ))
        (( day < 1 )) && day=1
        (( day > 7 )) && day=7
      fi
    else
      day=1
    fi
  else
    day=1
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

  # M2 (claude-tools-8mz): consult the daemon's machine-level cache first.
  # When the daemon is up and the cache is fresh, the workspace runner makes
  # ZERO direct Anthropic API calls — the acceptance criterion of M2 (UX
  # 0.A "one central runner per computer that checks Claude capacity").
  # The daemon also emits the §1.1 capacity report once per machine, so the
  # workspace MUST NOT also call la_report_capacity here (would produce N
  # reports per cycle, defeating the centralisation).
  local cached
  if cached=$(la__capacity_via_daemon 2>/dev/null); then
    local pct_5h pct_7d allowed verdict
    pct_5h=$(printf '%s' "$cached" | jq -r '.pct_5h // 0' 2>/dev/null) || pct_5h=0
    pct_7d=$(printf '%s' "$cached" | jq -r '.pct_7d // 0' 2>/dev/null) || pct_7d=0
    allowed=$(printf '%s' "$cached" | jq -r '.allowed_cost_classes[]?' 2>/dev/null)
    if printf '%s\n' "$allowed" | grep -qx "$cost_class"; then
      verdict=ok
      echo "  Usage (via daemon): 5h=${pct_5h}% 7d=${pct_7d}% — $cost_class allowed"
      return 0
    else
      verdict=over
      echo "  Usage (via daemon): 5h=${pct_5h}% 7d=${pct_7d}% — $cost_class over"
      return 1
    fi
  fi

  # ── Fallback path: daemon unreachable / cache missing/stale (BC-34 §6.2
  # fail-OPEN posture preserved). Reads Keychain + hits Anthropic API
  # directly, exactly as the pre-M2 runner did. Per the M2 spec, the
  # workspace runner does NOT emit a §1.1 capacity report on this path
  # either ("per-workspace runners stop reporting capacity") — the daemon
  # owns the upstream report. If the daemon is down for an extended
  # window, capacity reports go silent; the next daemon poll cycle resumes
  # them. Workspaces remain locally gated by the verdict below.
  local token usage five seven resets five_i seven_i verdict="ok"
  token=$(la__anthropic_token) || { return 0; }            # §6.2 fail-OPEN
  usage=$(la__usage_json "$token") || { return 0; }         # §6.2 fail-OPEN

  five=$(printf '%s'  "$usage" | jq -r '.five_hour.utilization  // 0' 2>/dev/null) || five=0
  seven=$(printf '%s' "$usage" | jq -r '.seven_day.utilization // 0' 2>/dev/null) || seven=0
  # x7ve: anchor the day-N ramp on the API-reported window end.
  resets=$(printf '%s' "$usage" | jq -r '.seven_day.resets_at // .seven_day.resetsAt // ""' 2>/dev/null) || resets=""
  five_i=${five%.*};   five_i=${five_i:-0}
  seven_i=${seven%.*}; seven_i=${seven_i:-0}

  # Hard ceiling (BC-34 verbatim): either window's integer-truncated
  # utilisation ≥ threshold ⇒ over. Applies to BOTH cost classes.
  if [[ "${five_i:-0}" -ge "$threshold" ]] || [[ "${seven_i:-0}" -ge "$threshold" ]]; then
    verdict="over"
    echo "  Usage: 5h=${five}% 7d=${seven}% (threshold: ${threshold}%)"
  elif [[ "$cost_class" == "low_priority" ]]; then
    # Spare-cycles soft ramp: low_priority backfills unused capacity only.
    local ramp; ramp="$(la__spare_ramp_pct "$resets")"
    if [[ "${seven_i:-0}" -ge "${ramp:-100}" ]]; then
      verdict="over"
      echo "  Usage: 5h=${five}% 7d=${seven}% (low_priority spare-cycles ramp: ${ramp}%)"
    else
      echo "  Usage: 5h=${five}% 7d=${seven}% (low_priority ≤ ramp ${ramp}%)"
    fi
  else
    echo "  Usage: 5h=${five}% 7d=${seven}%"
  fi

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

# la_publish_workspace_inventory — workspace_inventory record (epic
# claude-tools-vvgy, producer Phase A redo claude-tools-gk17). One UP report
# describing this workspace's bd queue: counts by status, the full
# in_progress set, and the top-N open beads (most recently updated). Wire
# shape is frozen in the epic; field names match it verbatim. The hosted
# join projects these per-workspace records into the Board's machine strip /
# title rendering — never reads bd directly. Drainer maps report=="workspace_
# inventory" to op=workspace-inventory-put (CF handler claude-tools-8dfb).
#
# Stage normalisation: the CF handler (reconcile.js:541-551) requires every
# stage field to be a non-empty string. The first cut (ztb6, reverted) emitted
# `stage:""` for any bead without a `stage:*` label and was 422'd 100% by the
# canary (g6s9). We normalise empty → "unknown" at the producer so every
# entry passes the wire contract; the consumer remains strict.
#
# OPTIONAL/guarded posture (matches la_report_heartbeat): a missing bd or jq
# returns 0 silently — the runner's main job is not workspace inventory
# publishing, and a transient producer failure must NEVER abort task pickup.
# The next pickup tries again. Output goes to la__outbox; the §1.1 drain
# pushes it on the next cycle.
la_publish_workspace_inventory() {
  command -v jq >/dev/null 2>&1 || return 0
  command -v bd >/dev/null 2>&1 || return 0

  local ts open ready in_prog blocked
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  # counts — each query is independently best-effort; an empty/failed count
  # falls to 0 (the wire contract requires integers, not nulls).
  open=$(bd list --status=open --json 2>/dev/null | jq 'length' 2>/dev/null) || open=0
  ready=$(bd ready --json 2>/dev/null | jq 'length' 2>/dev/null) || ready=0
  in_prog=$(bd list --status=in_progress --json 2>/dev/null | jq 'length' 2>/dev/null) || in_prog=0
  blocked=$(bd list --status=blocked --json 2>/dev/null | jq 'length' 2>/dev/null) || blocked=0
  [[ "$open"    =~ ^[0-9]+$ ]] || open=0
  [[ "$ready"   =~ ^[0-9]+$ ]] || ready=0
  [[ "$in_prog" =~ ^[0-9]+$ ]] || in_prog=0
  [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0

  # in_progress_beads — ALL of them (never capped by the top_n bound; the
  # Board needs the full set to render "what is each runner doing right now").
  # Stage: first stage:* label, with "stage:" prefix stripped; empty → "unknown"
  # so the CF wire-contract's non-empty-string requirement is always satisfied.
  local ip_beads
  ip_beads=$(bd list --status=in_progress --json 2>/dev/null \
    | jq -c 'map({bead_ref: .id, title: (.title // ""),
                  stage: ((.labels // [])
                          | map(select(type=="string" and startswith("stage:")))
                          | (first // "")
                          | sub("^stage:"; "")
                          | if . == "" then "unknown" else . end)})' 2>/dev/null) || ip_beads="[]"
  [[ -n "$ip_beads" ]] || ip_beads="[]"

  # top_n_beads — at most 20 open beads, ordered by updated_at desc, mapped
  # to the wire shape {bead_ref, title, status, stage}. The cap is enforced
  # in jq so a bd that ignores --limit is still bounded. Same stage-normalisation
  # as in_progress_beads (empty → "unknown").
  local top_beads
  top_beads=$(bd list --status=open --json 2>/dev/null \
    | jq -c '(sort_by(.updated_at // "") | reverse)[0:20]
             | map({bead_ref: .id, title: (.title // ""),
                    status: (.status // "open"),
                    stage: ((.labels // [])
                            | map(select(type=="string" and startswith("stage:")))
                            | (first // "")
                            | sub("^stage:"; "")
                            | if . == "" then "unknown" else . end)})' 2>/dev/null) || top_beads="[]"
  [[ -n "$top_beads" ]] || top_beads="[]"

  jq -cn \
     --argjson sv 1 \
     --arg pr  "$(la_principal)" \
     --arg rid "$(la_runner_id)" \
     --arg prj "${PROJECT_REF:-$(basename "$(pwd)" 2>/dev/null)}" \
     --arg at  "$ts" \
     --argjson o  "${open:-0}" \
     --argjson rd "${ready:-0}" \
     --argjson ip "${in_prog:-0}" \
     --argjson bl "${blocked:-0}" \
     --argjson ipb "$ip_beads" \
     --argjson tb  "$top_beads" \
     '{report:"workspace_inventory",schema_version:$sv,principal:$pr,
       runner_id:$rid,project_ref:$prj,observed_at:$at,
       counts:{open:$o,ready:$rd,in_progress:$ip,blocked:$bl},
       in_progress_beads:$ipb,top_n_beads:$tb}' \
     >> "$(la__outbox)" 2>/dev/null || true
  return 0
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
