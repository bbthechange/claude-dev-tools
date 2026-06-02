#!/usr/bin/env bash
# beads-runner/lib/activity-report.sh
# Activity-state stream→report wiring (I1 · claude-tools-uxvi1).
#
# This is the RUNNER-SIDE companion to lib/activity-classifier.sh (the PURE
# enum/dot classifier). It is the "extract the facts the classifier needs out of
# a live claude `--output-format stream-json` capture, then publish the derived
# state out-of-band" layer the design calls for (design/activity.md §1.1/§1.4):
#
#   STREAM_FILE  ──facts──▶  activity-classifier  ──state──▶  agent-activity-report
#   (the worker's              (pure, D.2)                     (transient table,
#    merged stdout+stderr)                                      latest-wins per agent_key)
#
# It is FACTORED INTO A SOURCEABLE LIB precisely so I5 (parallel aux dispatch)
# can reuse the SAME extraction+publish on the daemon's read-only aux streams —
# "one enum/threshold definition feeds the whole table" (design/activity.md §5.4).
#
# v2 NOTE (the seam): the v2 runner.sh has NO concurrent `tail -f` stream parser
# (it closed the BC-39/40 leak). So this lib does NOT tail; it is POLLED on the
# runner's existing during-task control cadence (the heartbeat-beat sibling
# ticker, §1.4 "fold into the existing watchdog cadence, or a sibling ticker"),
# reading the WHOLE capture each tick. The hot loop never blocks on the network:
# the POST is best-effort, guarded, and BACKGROUNDED.
#
# Sourced with no side effects (safe under `set -euo pipefail`). Sources the
# sibling classifier so activity_classify_state / activity_liveness_dot /
# activity_state_confidence are available to callers that source only this file.

# Locate + source the pure classifier sibling (idempotent; double-source is safe).
_ACTIVITY_REPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if ! declare -F activity_classify_state >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_ACTIVITY_REPORT_DIR/activity-classifier.sh" 2>/dev/null || true
fi

# The ask-brian MCP tool name AS IT APPEARS in a stream-json tool_use `.name`
# (agents/specialist.sh NO_XWS_RECURSION). The §1.2 row-1 override keys on this.
ACTIVITY_ASKBRIAN_TOOL="${ACTIVITY_ASKBRIAN_TOOL:-mcp__askbrian__ask-brian}"

# How fresh a still-in-the-same-state liveness report must be kept (seconds). A
# transition publishes immediately; otherwise re-publish at least this often so
# the liveness dot stays honest during a long single-state stretch. [free] per
# ARCH §8 (any value ≤ the 90s soft window keeps liveness fresh).
ACTIVITY_REPORT_FRESHNESS_S="${ACTIVITY_REPORT_FRESHNESS_S:-45}"

# How many trailing lines of the capture to scan for facts. The LAST tool /
# in-flight 429 / ask-brian block all live at the tail; bounding the scan keeps
# the per-tick jq cheap on a large capture. [free].
ACTIVITY_TAIL_LINES="${ACTIVITY_TAIL_LINES:-800}"

# activity_stream_mtime <file> → epoch seconds of last write (0 if absent).
# Portable across macOS (stat -f %m) and Linux (stat -c %Y).
activity_stream_mtime() {
  local f="$1" m=""
  [[ -e "$f" ]] || { printf '0'; return; }
  m="$(stat -f %m "$f" 2>/dev/null)" || m=""
  [[ -n "$m" ]] || m="$(stat -c %Y "$f" 2>/dev/null)" || m=""
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

# activity_iso8601 <epoch> → ISO-8601 UTC string (RFC-3339, latest-wins sortable).
activity_iso8601() {
  local e="$1"
  case "$e" in ''|*[!0-9]*) e=0 ;; esac
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '1970-01-01T00:00:00Z'
}

# activity_facts_from_stream <stream_file>
# Extract the CONTENT facts the classifier needs (clock-independent, so it is
# deterministic + unit-testable). Prints ONE tab-separated line:
#     <last_tool_name>\t<last_bash_cmd>\t<askbrian_inflight 0|1>\t<rate_limited 0|1>
# Tolerates non-JSON lines (claude merges stderr into the capture via `2>&1`),
# an empty file, and partial/truncated trailing lines (jq `fromjson?` drops them).
#
# Derivation over the tail (events in stream order):
#   • last_tool       = the LAST tool_use `.name` — read from assistant message
#                       content blocks (`.message.content[]|select(.type=="tool_use")`,
#                       the design's canonical path) OR a top-level tool_use
#                       (`.type=="tool_use"`, the older shape) — last wins.
#   • last_bash_cmd   = that tool_use's `.input.command` (empty unless Bash-like).
#   • askbrian_inflight = the last tool_use is the ask-brian MCP call AND no
#                       tool_result has appeared after it (§1.2 row 1 — "no result
#                       yet"; a blocked human-decision must suppress maybe-stuck).
#   • rate_limited    = a REAL 429 is in flight (§1.3): the most recent event is a
#                       `system api_retry error=rate_limit` (or a `rate_limit_event`
#                       status rejected|exceeded) with NO progress event after it.
#                       Benign subscription-window `allowed`/`allowed_warning`
#                       events are NOT rate-limited (the t5k correction).
activity_facts_from_stream() {
  local f="$1"
  if [[ ! -r "$f" ]]; then printf '\t\t0\t0\n'; return; fi
  tail -n "$ACTIVITY_TAIL_LINES" "$f" 2>/dev/null \
    | jq -R 'fromjson?' 2>/dev/null \
    | jq -rs '
        def hasTU:
          (.type=="tool_use")
          or (((.message.content // []) | type=="array")
              and ((.message.content // []) | any(.type=="tool_use")));
        def isResult:
          (.type=="result")
          or (((.message.content // []) | type=="array")
              and ((.message.content // []) | any(.type=="tool_result")));
        def isProg:
          (.type=="assistant") or (.type=="user") or (.type=="result") or (.type=="tool_use");
        def isRL:
          (.type=="system" and .subtype=="api_retry" and .error=="rate_limit")
          or (.type=="rate_limit_event"
              and (((.rate_limit_info.status) // "") | test("rejected|exceeded")));
        . as $e
        | ([ $e | to_entries[] | select(.value | hasTU)   | .key ] | (last // -1)) as $ltu
        | ([ $e | to_entries[] | select(.value | isResult)| .key ] | (last // -1)) as $ltr
        | ([ $e | to_entries[] | select(.value | isProg)  | .key ] | (last // -1)) as $lprog
        | ([ $e | to_entries[] | select(.value | isRL)    | .key ] | (last // -1)) as $lrl
        | (if $ltu >= 0
             then ($e[$ltu]
                   | ([ .message.content[]? | select(.type=="tool_use") ]
                      + (if .type=="tool_use" then [{name:((.name)//(.tool)), input:(.input)}] else [] end)
                      | last))
             else null end) as $tu
        | [ (($tu.name) // ""),
            (($tu.input.command) // ""),
            (if (($tu.name) // "")==$tool and $ltr < $ltu then 1 else 0 end),
            (if $lrl >= 0 and $lrl > $lprog then 1 else 0 end) ]
        | @tsv
      ' --arg tool "$ACTIVITY_ASKBRIAN_TOOL" 2>/dev/null \
    || printf '\t\t0\t0'
  # jq @tsv already emits the trailing newline; the `|| printf` fallback covers a
  # jq failure (no jq, OOM) with the all-empty/zero facts row.
}

# activity_state_from_stream <stream_file> [delta_override]
# The end-to-end stream→state: combine the content facts with the silence delta
# (now − stream mtime, or an explicit override for deterministic tests) and run
# the PURE classifier. Prints ONE tab-separated line:
#     <state>\t<liveness_dot>\t<delta>\t<tool>\t<cmd>\t<askbrian>\t<rl>
# `now` is overridable via $ACTIVITY_NOW (tests pin the clock). A delta_override
# (2nd arg) bypasses the mtime read entirely — the test harness feeds exact Δ so
# the silence-gate boundaries are pinned without touching file timestamps.
activity_state_from_stream() {
  local f="$1" delta="${2:-}"
  local now mtime facts tool cmd ab rl state dot
  if [[ -z "$delta" ]]; then
    now="${ACTIVITY_NOW:-$(date +%s)}"
    mtime="$(activity_stream_mtime "$f")"
    delta=$(( now - mtime ))
    (( delta < 0 )) && delta=0
  fi
  facts="$(activity_facts_from_stream "$f")"
  # NB: tab is an IFS-WHITESPACE char, so `IFS=$'\t' read` COLLAPSES the empty
  # cmd field and misaligns every field after it. Translate the real (jq @tsv)
  # tab delimiters to US (0x1f, non-whitespace) so empty fields are preserved.
  # @tsv backslash-escapes any tab/newline INSIDE a field, so only delimiters
  # are real tabs — the translate cannot corrupt a command's own whitespace.
  IFS=$'\x1f' read -r tool cmd ab rl <<<"${facts//$'\t'/$'\x1f'}"
  : "${tool:=}"; : "${cmd:=}"; : "${ab:=0}"; : "${rl:=0}"
  state="$(activity_classify_state "$delta" "$tool" "$ab" "$rl" "$cmd")"
  dot="$(activity_liveness_dot "$delta")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$dot" "$delta" "$tool" "$cmd" "$ab" "$rl"
}

# activity__post <json> — best-effort, guarded POST of one agent-activity-report.
# No-op (rc 0) unless the live-engine transport is actually wired: it needs the
# co_request override (RUNNER_BACKEND=real + co-http-transport.sh) AND a
# COORDINATOR_URL. Offline/stub runs and the conformance gate therefore never
# touch the network. NEVER fails the caller (telemetry must not break the loop).
activity__post() {
  local json="$1" tok=""
  [[ -n "$json" ]] || return 0
  command -v co_request >/dev/null 2>&1 || return 0
  [[ -n "${COORDINATOR_URL:-}" ]] || return 0
  if command -v co_http__token >/dev/null 2>&1; then
    tok="$(co_http__token 2>/dev/null || true)"
  fi
  co_request "$tok" "agent-activity-report" "$json" >/dev/null 2>&1 || true
}

# activity_report_tick <stream_file> <state_file> <agent_key> <workspace> \
#                      <lane> <kind> <bead_ref> <title> <stage>
# One throttled reporter tick. ALWAYS rc 0 (best-effort). Cheap work (classify +
# write the local state file) runs every tick; the NETWORK POST is throttled to
# state TRANSITIONS plus an ≤ACTIVITY_REPORT_FRESHNESS_S heartbeat, and is
# BACKGROUNDED so the control loop never blocks on it. The state file is the
# §1.4 ACTIVITY_STATE_FILE: one line `<state>|<state_first_ts>|<last_report_ts>`.
activity_report_tick() {
  local stream="$1" sfile="$2" agent_key="$3" workspace="$4" lane="$5" \
        kind="$6" bead="$7" title="$8" stage="$9"
  command -v activity_classify_state >/dev/null 2>&1 || return 0

  local now mtime parsed state dot delta tool cmd ab rl
  now="${ACTIVITY_NOW:-$(date +%s)}"
  mtime="$(activity_stream_mtime "$stream")"
  parsed="$(activity_state_from_stream "$stream")" || return 0
  # Same empty-field-collapse guard as above (tool/cmd may be empty).
  IFS=$'\x1f' read -r state dot delta tool cmd ab rl <<<"${parsed//$'\t'/$'\x1f'}"
  [[ -n "$state" ]] || return 0

  # Prior state-file: <prev_state>|<state_first_ts>|<last_report_ts>
  local prev_state="" first_ts="$now" last_report=0
  if [[ -r "$sfile" ]]; then
    IFS='|' read -r prev_state first_ts last_report < "$sfile" 2>/dev/null || true
    case "$first_ts"   in ''|*[!0-9]*) first_ts="$now" ;; esac
    case "$last_report" in ''|*[!0-9]*) last_report=0 ;; esac
  fi

  local transition=0
  if [[ "$state" != "$prev_state" ]]; then transition=1; first_ts="$now"; fi
  local seconds_in_state=$(( now - first_ts )); (( seconds_in_state < 0 )) && seconds_in_state=0

  # Decide whether to POST this tick: a transition, the first report, or the
  # freshness window elapsed since the last POST.
  local do_emit=0
  if (( transition == 1 )) || (( last_report == 0 )) \
     || (( now - last_report >= ACTIVITY_REPORT_FRESHNESS_S )); then
    do_emit=1
  fi

  if (( do_emit == 1 )); then
    local obs_iso last_iso conf json
    obs_iso="$(activity_iso8601 "$now")"
    last_iso="$(activity_iso8601 "$mtime")"
    conf="$(activity_state_confidence)"
    json="$(jq -cn \
      --arg report agent_activity --argjson sv 1 \
      --arg agent_key "$agent_key" --arg ws "$workspace" --arg lane "$lane" \
      --arg kind "$kind" --arg bead "$bead" --arg title "$title" --arg stage "$stage" \
      --arg state "$state" --arg conf "$conf" --arg dot "$dot" \
      --arg obs "$obs_iso" --arg last "$last_iso" --argjson sis "$seconds_in_state" \
      --arg tool "$tool" \
      '{report:$report, schema_version:$sv, agent_key:$agent_key, workspace:$ws,
        lane:$lane, kind:$kind, bead_ref:$bead, title:$title, stage:$stage,
        state:$state, state_confidence:$conf, liveness_dot:$dot,
        observed_at:$obs, last_event_ts:$last, seconds_in_state:$sis,
        current_tool:$tool}' 2>/dev/null)"
    if [[ -n "$json" ]]; then
      activity__post "$json" &   # BACKGROUNDED — telemetry never blocks the loop
      last_report="$now"
    fi
  fi

  # Persist the state file every tick (the local liveness record, cheap).
  printf '%s|%s|%s\n' "$state" "$first_ts" "$last_report" > "$sfile" 2>/dev/null || true
  return 0
}
