# shellcheck shell=bash
# beads-runner/daemon/usage-poll.sh — M2 Anthropic-usage poll
# (claude-tools-8mz; epic claude-tools-kie).
#
# ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1 (D2).
# Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json +
# daemon/test-machine-state-producer.sh.
# A D2 gap ⇒ reopen D2, bump+re-freeze — NEVER diverge, NEVER edit
# MACHINE-STATE.md silently. (The _machine_state_emit helper below is the D2
# §1.1 producer; field names + types + closed-enum discipline mirror the
# contract verbatim. The render is tolerant; the WRITE is strict.)
#
# WHAT THIS IS (DESIGN §3.2 job 1 / UX 0.A "one central runner per computer")
#   The daemon-side periodic poll of the Anthropic usage API. Before M2,
#   every workspace's la_capacity_check (lib/local-agent.sh:169) did this
#   independently: N workspaces ⇒ N keychain reads ⇒ N API polls per loop
#   top, racing on the same machine-wide budget. M2 centralizes it: ONE
#   keychain read + ONE API call per machine per USAGE_CACHE_SECONDS, and
#   each workspace consults the daemon's cached verdict instead.
#
# THE "API" (UX 0.A — GET /capacity)
#   Cache file at $DAEMON_CACHE_DIR/capacity.json, atomically written:
#     {
#       "schema_version":      1,
#       "pct_5h":              <float>,                  // raw 5h utilisation
#       "pct_7d":              <float>,                  // raw 7d utilisation
#       "spare_ramp_today":    <int 0..100>,             // §6.3 soft ramp
#       "allowed_cost_classes":["standard"|"low_priority", ...],
#       "observed_at":         "<ISO8601Z>",
#       "expires_at":          "<ISO8601Z>"              // observed_at + TTL
#     }
#   Why file, not nc-served UDS: same blast radius (local user FS only),
#   simpler+atomic (rename, no listener loop), zero port surface, easier to
#   test. The workspace side (la__capacity_via_daemon, this file's pair in
#   lib/local-agent.sh) wraps the read so the back end can swap to a UDS or
#   localhost HTTP server later without touching the workspace contract.
#
# WHAT THIS IS *NOT*
#   • NOT the workspace-side gate. The workspace's la_capacity_check
#     consults this cache (M2 wiring lives in local-agent.sh). The daemon
#     produces the cache; the workspace consumes it.
#   • NOT the §6.2 fail-OPEN backstop. The workspace ALWAYS retains its
#     direct-keychain+API path as a fallback when the daemon is down /
#     cache is stale / daemon never produced a record. BC-34 preserved.
#   • NOT a credentials replacement. Same Keychain item ("Claude Code-
#     credentials"), same Anthropic OAuth bearer, same usage endpoint. The
#     only change is who reads them: the daemon, once per cycle, instead
#     of every workspace runner every loop top.
#
# UPSTREAM CAPACITY REPORT (§1.1 item 1)
#   Per the M2 spec ("la_report_capacity becomes the daemon's job too;
#   per-workspace runners stop reporting"), the daemon emits the §1.1
#   capacity record once per poll cycle into its OWN outbox at
#   $DAEMON_CACHE_DIR/coordinator-outbox.jsonl. The workspace runner's
#   la_capacity_check no longer calls la_report_capacity (one machine,
#   one report — not N workspace reports racing the same budget).

# ─── paths + tunables ────────────────────────────────────────────────────
# DAEMON_CACHE_DIR is set by daemon.sh; default here so this file is
# sourceable in isolation (tests).
USAGE_POLL_CACHE_DIR="${BEADS_DAEMON_CACHE_DIR:-$HOME/.cache/claude-tools}"
USAGE_POLL_CACHE_FILE="$USAGE_POLL_CACHE_DIR/capacity.json"
USAGE_POLL_OUTBOX="$USAGE_POLL_CACHE_DIR/coordinator-outbox.jsonl"

# Cache TTL — same default as INTERFACE.md §0.5 USAGE_CACHE_SECONDS=300.
# An ALSO-named env var override (USAGE_CACHE_SECONDS) ties the daemon's
# poll cadence to the same constant the runner used to honour for its
# in-process cache — a single normative source.
USAGE_POLL_TTL_SECONDS="${USAGE_CACHE_SECONDS:-300}"

# §0.5 USAGE_THRESHOLD (0 disables — same semantics as the runner's path).
USAGE_POLL_THRESHOLD="${USAGE_THRESHOLD:-70}"

# §0.5 SPARE_RAMP_PER_DAY soft ramp for low_priority (lib/local-agent.sh
# la__spare_ramp_pct logic, mirrored here so the daemon computes
# allowed_cost_classes itself rather than punting to each workspace).
USAGE_POLL_SPARE_RAMP_PER_DAY="${SPARE_RAMP_PER_DAY:-14.2}"

# Test/canary hook: 1 ⇒ produce a synthetic cache record without touching
# the Keychain or the Anthropic API. Useful for the M2 acceptance test
# and for local dev when offline. The synthetic record has pct_5h=0,
# pct_7d=0, allowed=[standard,low_priority] so workspaces don't gate on
# a stub.
USAGE_POLL_DISABLED="${USAGE_POLL_DISABLED:-0}"

# ─── helpers ─────────────────────────────────────────────────────────────

# _usage_poll_log <msg>  — forward to daemon log() if available; otherwise
# stderr-print so the function works when sourced in isolation.
_usage_poll_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s [usage-poll] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >&2
  fi
}

# _usage_poll_resets_at_to_day <resets_at_iso8601> — convert the Anthropic
# usage API's seven_day.resets_at timestamp into a "day N of the rolling 7d
# window" index in 1..7. The window ends at resets_at and is 7d wide, so
# day N = ceil((now - (resets_at - 7d)) / 86400) = 8 - ceil((resets_at - now) / 86400).
# Empty input or parse failure ⇒ empty stdout (caller falls back to day=1).
#
# pkp2: the real API returns timestamps like "2026-05-25T07:00:00.585476+00:00"
# (fractional microseconds + explicit +00:00 offset), NOT the strict-Z form.
# macOS BSD `date -j -u -f "%Y-%m-%dT%H:%M:%SZ"` rejects that outright, and
# BSD `date` has no `-d` flag for the GNU fallback, so on macOS every call
# was silently falling to day=1. We normalize the input first:
#   1. strip fractional seconds when followed by a TZ marker (`+`, `-`, or `Z`)
#   2. convert a `+00:00` / `+0000` UTC offset to `Z`
# Non-UTC offsets are intentionally NOT normalized (the API returns UTC) — a
# future non-UTC value falls to day=1, the conservative soft line.
_usage_poll_resets_at_to_day() {
  local resets="$1"
  [[ -n "$resets" ]] || return 0
  local norm resets_epoch now remaining day
  norm=$(printf '%s' "$resets" | sed -E 's/\.[0-9]+([+-Z])/\1/; s/\+00:?00$/Z/')
  # macOS first, then GNU date — matches the pattern used by _usage_poll_write_cache.
  resets_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$norm" +%s 2>/dev/null \
                 || date -u -d "$resets" +%s 2>/dev/null \
                 || echo "")
  [[ -n "$resets_epoch" ]] || return 0
  now=$(date +%s 2>/dev/null || echo 0)
  remaining=$(( resets_epoch - now ))
  if (( remaining <= 0 )); then
    printf '7'
    return 0
  fi
  # ceil(remaining / 86400) without bc.
  day=$(( 8 - ( (remaining + 86399) / 86400 ) ))
  (( day < 1 )) && day=1
  (( day > 7 )) && day=7
  printf '%s' "$day"
}

# _usage_poll_spare_ramp_pct [resets_at] — mirror of la__spare_ramp_pct (lib/
# local-agent.sh): day N of the rolling 7d window allows ≤ N×SPARE_RAMP_PER_DAY%
# utilisation for low_priority. The day index is anchored on the Anthropic
# usage API's seven_day.resets_at (the END of the rolling window), NOT on
# the calendar — so the ramp moves monotonically through the user's actual
# window instead of cycling at UTC midnight (x7ve). SPARE_DAY_INDEX env
# override pins the day for deterministic tests. Missing resets_at ⇒ day=1
# (conservative: the soft line is tightest when the window position is
# unknown; the hard 5h/7d ceiling is the real guard, AD2.3).
_usage_poll_spare_ramp_pct() {
  local resets="${1:-}" day ramp
  if [[ -n "${SPARE_DAY_INDEX:-}" ]]; then
    day="$SPARE_DAY_INDEX"
  else
    day=$(_usage_poll_resets_at_to_day "$resets")
    [[ -n "$day" ]] || day=1
  fi
  ramp=$(awk -v d="$day" -v r="$USAGE_POLL_SPARE_RAMP_PER_DAY" \
           'BEGIN{ v=d*r; if(v>100) v=100; printf "%d", v }' 2>/dev/null) || ramp=100
  printf '%s' "${ramp:-100}"
}

# _usage_poll_spare_ramp_day [resets_at] — the day-into-window index (1..7)
# the current ramp was computed against. Same SPARE_DAY_INDEX override and
# same resets_at-anchored derivation the pct function uses, so a log line
# of the form `day=N × R%` matches the ramp emitted alongside it.
_usage_poll_spare_ramp_day() {
  local resets="${1:-}" day
  if [[ -n "${SPARE_DAY_INDEX:-}" ]]; then
    printf '%s' "$SPARE_DAY_INDEX"
    return 0
  fi
  day=$(_usage_poll_resets_at_to_day "$resets")
  [[ -n "$day" ]] || day=1
  printf '%s' "$day"
}

# _usage_poll_read_token — read Anthropic OAuth token via macOS Keychain.
# Same BC-34 contract as la__anthropic_token (lib/local-agent.sh) but
# inlined here so the daemon does not need to source local-agent.sh just
# for this. Returns:
#   0 + token  — usable
#   10         — keychain unreadable (fail-OPEN; produce permissive cache)
#   11         — creds present, no token (fail-OPEN; permissive cache)
_usage_poll_read_token() {
  local creds token
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 10
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [[ -n "$token" ]] || return 11
  printf '%s' "$token"
}

# _usage_poll_call_api <token> — call the Anthropic usage endpoint. Echoes
# the raw JSON; returns nonzero on transport/API failure (fail-OPEN at the
# caller).
_usage_poll_call_api() {
  local token="$1"
  curl -s -f -X GET "https://api.anthropic.com/api/oauth/usage" \
       -H "Accept: application/json" \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $token" \
       -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null
}

# _usage_poll_compute_allowed <pct_5h_int> <pct_7d_int> <spare_ramp>
#   Apply §6.3 verdict logic to decide which cost classes are allowed.
#   Echoes a JSON array body, e.g. `"standard","low_priority"` (no brackets).
#   Rules:
#     pct_5h ≥ THRESHOLD or pct_7d ≥ THRESHOLD ⇒ []
#     pct_7d ≥ spare_ramp                       ⇒ ["standard"]
#     else                                       ⇒ ["standard","low_priority"]
#   THRESHOLD=0 disables (everyone allowed).
_usage_poll_compute_allowed() {
  local five="$1" seven="$2" ramp="$3" t="$USAGE_POLL_THRESHOLD"
  if [[ "$t" -eq 0 ]]; then
    printf '"standard","low_priority"'
    return 0
  fi
  if [[ "${five:-0}" -ge "$t" ]] || [[ "${seven:-0}" -ge "$t" ]]; then
    printf ''
    return 0
  fi
  if [[ "${seven:-0}" -ge "${ramp:-100}" ]]; then
    printf '"standard"'
    return 0
  fi
  printf '"standard","low_priority"'
}

# _usage_poll_write_cache <pct_5h> <pct_7d> <ramp> <allowed_body>
#   Atomic write: tmp + rename. The rename is the publish point — readers
#   never see a torn JSON.
_usage_poll_write_cache() {
  local five="$1" seven="$2" ramp="$3" allowed="$4"
  local now expires
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  expires=$(date -u -v+"${USAGE_POLL_TTL_SECONDS}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -d "+${USAGE_POLL_TTL_SECONDS} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || echo "")
  mkdir -p "$USAGE_POLL_CACHE_DIR" 2>/dev/null || true
  local tmp="$USAGE_POLL_CACHE_FILE.tmp.$$"
  printf '{"schema_version":1,"pct_5h":%s,"pct_7d":%s,"spare_ramp_today":%s,"allowed_cost_classes":[%s],"observed_at":"%s","expires_at":"%s"}\n' \
    "${five:-0}" "${seven:-0}" "${ramp:-0}" "$allowed" "$now" "$expires" \
    > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$USAGE_POLL_CACHE_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# _machine_state_emit <pct_5h> <pct_7d> <ramp> <threshold> <keychain_ok> <usage_api_ok>
#   The §1.1 MACHINE-STATE.md v1 (D2) upward telemetry report. Parallel to
#   _usage_poll_emit_capacity_report but a SEPARATE channel (§0.C Path B):
#   the §6.3 gate keeps emitting the {ok|over} verdict; THIS channel carries
#   the human-facing per-machine 5h/7d numbers the Board renders. Same outbox
#   (USAGE_POLL_OUTBOX), same cadence (once per cycle).
#
#   Fields mirror MACHINE-STATE.md §1.1/§1.2 verbatim — adding/removing a
#   field here = a D2 amend (the small ceremony in §C), NOT a local tweak.
#   Booleans use --argjson so they land as JSON true/false (not strings); the
#   numeric fields use --argjson so floats stay floats and ints stay ints (the
#   engine §1.4 rejects wrong-type fields). gate_disabled is the §1.2 mirror
#   of threshold_in_effect===0; we send both so the Board may render off
#   either (§4.D).
_machine_state_emit() {
  local pct5="$1" pct7="$2" ramp="$3" thr="$4" kc_ok="$5" api_ok="$6"
  local ts rid gate_disabled
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  rid="${RUNNER_ID:-$(hostname 2>/dev/null || echo localhost)}"
  if [[ "${thr:-0}" -eq 0 ]]; then gate_disabled=true; else gate_disabled=false; fi
  mkdir -p "$USAGE_POLL_CACHE_DIR" 2>/dev/null || true
  jq -cn \
     --argjson sv 1 \
     --arg pr  "${PRINCIPAL_V1:-brian}" \
     --arg rid "$rid" \
     --arg at  "$ts" \
     --argjson pct5 "${pct5:-0}" \
     --argjson pct7 "${pct7:-0}" \
     --argjson ramp "${ramp:-0}" \
     --argjson thr  "${thr:-0}" \
     --argjson gd   "$gate_disabled" \
     --argjson kc   "${kc_ok:-false}" \
     --argjson api  "${api_ok:-false}" \
     '{report:"machine_state",schema_version:$sv,principal:$pr,runner_id:$rid,
       observed_at:$at,pct_5h:$pct5,pct_7d:$pct7,spare_ramp_today:$ramp,
       threshold_in_effect:$thr,gate_disabled:$gd,keychain_ok:$kc,
       usage_api_ok:$api}' \
     >> "$USAGE_POLL_OUTBOX" 2>/dev/null || true
}

# _usage_poll_emit_capacity_report <verdict> <cost_class>
#   The §1.1 UP capacity report — the daemon's now-owned producer. Same
#   JSON shape la_report_capacity (lib/local-agent.sh:213) emits, written
#   to the daemon's outbox (not a workspace's). principal=PRINCIPAL_V1 per
#   §9.1; runner_id=hostname (the daemon IS the machine-local authority).
_usage_poll_emit_capacity_report() {
  local verdict="$1" cost_class="$2" ts rid
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  rid="${RUNNER_ID:-$(hostname 2>/dev/null || echo localhost)}"
  mkdir -p "$USAGE_POLL_CACHE_DIR" 2>/dev/null || true
  jq -cn \
     --argjson sv 1 \
     --arg pr  "${PRINCIPAL_V1:-brian}" \
     --arg rid "$rid" \
     --arg cc  "$cost_class" \
     --arg vd  "$verdict" \
     --arg at  "$ts" \
     '{report:"capacity",schema_version:$sv,principal:$pr,runner_id:$rid,
       cost_class:$cc,verdict:$vd,observed_at:$at}' \
     >> "$USAGE_POLL_OUTBOX" 2>/dev/null || true
}

# ─── public API ──────────────────────────────────────────────────────────

# daemon_usage_poll_once
#   Run one usage poll cycle: read token, hit API, compute verdict,
#   atomically publish the cache, emit the §1.1 capacity reports. Always
#   returns 0 — a poll failure must not abort the daemon (it's just data
#   the next cadence retries; workspaces fall open in the meantime).
daemon_usage_poll_once() {
  # Test/dev mode — produce a permissive synthetic cache, skip Keychain & API.
  if [[ "$USAGE_POLL_DISABLED" == "1" ]]; then
    _usage_poll_log "M2 usage-poll: DAEMON_USAGE_POLL_DISABLED=1 ⇒ writing synthetic permissive cache"
    _usage_poll_write_cache 0 0 100 '"standard","low_priority"' || true
    return 0
  fi

  # §6.3: THRESHOLD=0 disables — no Keychain, no API, but we still publish
  # a permissive cache so workspaces' la__capacity_via_daemon doesn't fall
  # back to the direct path on every check (which would re-read Keychain).
  if [[ "$USAGE_POLL_THRESHOLD" -eq 0 ]]; then
    _usage_poll_write_cache 0 0 100 '"standard","low_priority"' || true
    # D2 (MACHINE-STATE.md §1.1): emit a machine_state record with
    # threshold_in_effect=0 so the Board can render the §4.D gate-disabled
    # chip without a redeploy.
    _machine_state_emit 0 0 100 0 true true
    return 0
  fi

  local token usage five seven resets five_i seven_i ramp allowed
  if ! token=$(_usage_poll_read_token); then
    # BC-34 fail-OPEN: cache a permissive record so the workspace doesn't
    # gate. The next cycle retries the Keychain (a locked Keychain unlocks
    # eventually). We do NOT clear the existing cache here — if a previous
    # cycle succeeded and the cache is still fresh, leaving it alone is
    # MORE accurate than overwriting with an open verdict. Only overwrite
    # if the cache is missing or expired.
    if [[ ! -f "$USAGE_POLL_CACHE_FILE" ]] || _usage_poll_cache_expired; then
      _usage_poll_log "M2 usage-poll: Keychain unreadable / no token ⇒ writing permissive fail-OPEN cache (BC-34)"
      _usage_poll_write_cache 0 0 100 '"standard","low_priority"' || true
    fi
    # D2 §1.1 fail-OPEN emit: keychain_ok=false, usage_api_ok=false (no API
    # call made), pct_5h/pct_7d=0. The Board surfaces the "keychain
    # unreadable" breadcrumb (§4.C) — the strip is never hidden. The ramp
    # mirrors the permissive cache literal (100) — without a usage-API
    # response there is no resets_at to anchor the soft line, and the gate
    # is already fail-OPEN here.
    _machine_state_emit 0 0 100 "$USAGE_POLL_THRESHOLD" false false
    return 0
  fi

  if ! usage=$(_usage_poll_call_api "$token"); then
    if [[ ! -f "$USAGE_POLL_CACHE_FILE" ]] || _usage_poll_cache_expired; then
      _usage_poll_log "M2 usage-poll: Anthropic usage API failed ⇒ writing permissive fail-OPEN cache (BC-34)"
      _usage_poll_write_cache 0 0 100 '"standard","low_priority"' || true
    fi
    # D2 §1.1 fail-OPEN emit: keychain_ok=true, usage_api_ok=false; pct=0.
    # Ramp=100 mirrors the permissive cache for the same reason as above.
    _machine_state_emit 0 0 100 "$USAGE_POLL_THRESHOLD" true false
    return 0
  fi

  five=$(printf '%s'  "$usage" | jq -r '.five_hour.utilization  // 0' 2>/dev/null) || five=0
  seven=$(printf '%s' "$usage" | jq -r '.seven_day.utilization // 0' 2>/dev/null) || seven=0
  # x7ve: anchor the day-N ramp on the API-reported window end. Accept either
  # snake_case or camelCase; an absent field returns empty ⇒ conservative day=1.
  resets=$(printf '%s' "$usage" | jq -r '.seven_day.resets_at // .seven_day.resetsAt // ""' 2>/dev/null) || resets=""
  five_i=${five%.*};   five_i=${five_i:-0}
  seven_i=${seven%.*}; seven_i=${seven_i:-0}
  ramp="$(_usage_poll_spare_ramp_pct "$resets")"
  allowed="$(_usage_poll_compute_allowed "$five_i" "$seven_i" "$ramp")"

  if ! _usage_poll_write_cache "$five" "$seven" "$ramp" "$allowed"; then
    _usage_poll_log "M2 usage-poll: WARN failed to write cache at $USAGE_POLL_CACHE_FILE"
    return 0
  fi

  # §1.1 UP capacity report — one per cost class, matching what the runner
  # used to emit (lib/local-agent.sh:205) but produced exactly once per
  # machine per cycle here.
  local std_v lp_v
  if printf '%s' "$allowed" | grep -q '"standard"'; then std_v=ok; else std_v=over; fi
  if printf '%s' "$allowed" | grep -q '"low_priority"'; then lp_v=ok; else lp_v=over; fi
  _usage_poll_emit_capacity_report "$std_v" standard
  _usage_poll_emit_capacity_report "$lp_v"  low_priority

  # D2 (MACHINE-STATE.md §1.1) — the per-machine telemetry record. SEPARATE
  # channel from the §1.1 capacity report above (§0.C Path B): the gate keeps
  # emitting the verdict; this carries the human-facing 5h/7d numbers the
  # Board renders. Same outbox, same cadence (once per cycle). pct_5h/pct_7d
  # are passed as the raw API values (float OK; engine §1.4 keeps them in
  # [0,200]).
  _machine_state_emit "${five:-0}" "${seven:-0}" "$ramp" "$USAGE_POLL_THRESHOLD" true true

  # C2 (claude-tools-oil): log the daily-ramp FORMULA, not just the result,
  # so the UX 0.A math (day-of-week × SPARE_RAMP_PER_DAY%) is auditable from
  # the daemon's logs. e.g. ramp=42% (day=3 × 14.2%).
  local ramp_day; ramp_day="$(_usage_poll_spare_ramp_day "$resets")"
  _usage_poll_log "M2 usage-poll: 5h=${five}% 7d=${seven}% ramp=${ramp}% (day=${ramp_day} × ${USAGE_POLL_SPARE_RAMP_PER_DAY}%) allowed=[$allowed] (cache TTL=${USAGE_POLL_TTL_SECONDS}s)"
  return 0
}

# _usage_poll_cache_expired — true (return 0) if the cache file is missing
# or older than USAGE_POLL_TTL_SECONDS.
_usage_poll_cache_expired() {
  [[ -f "$USAGE_POLL_CACHE_FILE" ]] || return 0
  local mtime now age
  mtime=$(stat -f %m "$USAGE_POLL_CACHE_FILE" 2>/dev/null || stat -c %Y "$USAGE_POLL_CACHE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  [[ "$age" -ge "$USAGE_POLL_TTL_SECONDS" ]]
}

# daemon_usage_drain
#   Drain hook — invoked from daemon.sh on_exit. Removes the cache so a
#   restarted daemon doesn't serve a stale verdict on the boot gap. We do
#   NOT remove the outbox (that's the durable §1.1 UP queue).
daemon_usage_drain() {
  rm -f "$USAGE_POLL_CACHE_FILE" 2>/dev/null || true
  _usage_poll_log "M2 usage-poll: cache cleared on drain"
  return 0
}

# daemon_outbox_drain_once
#   Ship the daemon's own §1.1 UP queue (USAGE_POLL_OUTBOX) to the deployed
#   Coordinator. The daemon emits capacity + machine_state reports here every
#   USAGE_POLL_INTERVAL; nothing else drained them until this hook existed
#   (claude-tools-1p0u: "wired-but-not-live gap" — outbox grew unbounded, the
#   Worker's /work-snapshot machines[] stayed empty even though the engine's
#   report-machine-state op was deployed).
#
#   Picks the FIRST registered workspace's coordinator binding (COORDINATOR_URL
#   + the Keychain-resolved COORDINATOR_TOKEN). In practice every workspace
#   points at the same hosted engine — the §1.1 reports are keyed by
#   {principal, runner_id}, not project_ref, so the daemon outbox is machine-
#   wide and any one workspace's binding addresses the same coordinator. With
#   no workspaces registered (the M1-only posture), this is a strict no-op —
#   no binding ⇒ no push.
#
#   Always returns 0. A drain failure (auth, transport, etc.) leaves the line
#   in the outbox for the next cycle to retry (la_outbox_drain's rewrite-
#   survivors contract); we must not abort the daemon main loop on it.
daemon_outbox_drain_once() {
  [[ -f "$USAGE_POLL_OUTBOX" ]] || return 0
  # Empty file ⇒ nothing to do (the drainer would handle this too, but avoid
  # the subshell + lib source on the common no-op path).
  [[ -s "$USAGE_POLL_OUTBOX" ]] || return 0

  local ws_count=0
  if declare -p REGISTRY_PROJECT_REFS >/dev/null 2>&1; then
    ws_count="${#REGISTRY_PROJECT_REFS[@]}"
  fi
  if [[ "$ws_count" -eq 0 ]]; then
    _usage_poll_log "M2 outbox-drain: no workspaces registered ⇒ skipping daemon-outbox push (lines retained for later)"
    return 0
  fi

  local curl_url="${REGISTRY_COORDINATOR_URLS[0]:-}"
  local tk_item="${REGISTRY_TOKEN_KEYCHAIN_ITEMS[0]:-}"
  if [[ -z "$curl_url" ]]; then
    _usage_poll_log "M2 outbox-drain: workspace[0] has no coordinator_url ⇒ skipping daemon-outbox push (lines retained)"
    return 0
  fi

  local lib_dir="${DAEMON_REPO_LIB_DIR:-${DAEMON_REPO_DIR:-}/lib}"
  if [[ ! -f "$lib_dir/co-http-transport.sh" ]]; then
    _usage_poll_log "M2 outbox-drain: co-http-transport.sh not found at $lib_dir ⇒ skipping"
    return 0
  fi

  local outbox_path="$USAGE_POLL_OUTBOX"
  (
    set +e
    export COORDINATOR_URL="$curl_url"
    if [[ -n "$tk_item" ]] && command -v security >/dev/null 2>&1; then
      local _tk
      _tk="$(security find-generic-password -s "$tk_item" -w 2>/dev/null || true)"
      [[ -n "$_tk" ]] && export COORDINATOR_TOKEN="$_tk"
    fi
    # shellcheck source=/dev/null
    . "$lib_dir/co-http-transport.sh" 2>/dev/null || exit 0
    command -v la_outbox_drain >/dev/null 2>&1 || exit 0
    # Pass the bearer explicitly (the transport prefers the resolved token, but
    # an empty arg still drives a clean 401 if no token resolved). The 2-arg
    # form points the drainer at the daemon outbox instead of la__outbox.
    la_outbox_drain "${COORDINATOR_TOKEN:-}" "$outbox_path" >/dev/null 2>&1
    exit 0
  )
  return 0
}
