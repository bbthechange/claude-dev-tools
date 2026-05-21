#!/usr/bin/env bash
# beads-runner/lib/dg-author-metric.sh — B3 (claude-tools-95m): daily-rollup
# metric over the dg__author audit log.
#
# Reads $DG_AUDIT_LOG (default ~/.cache/claude-tools/dossier-author-audit.jsonl)
# and prints, per UTC day, the fraction of dossiers authored by the agent vs.
# the deterministic jq fallback. Surfaces whether B2's dossier-builder agent is
# actually being USED or is silently broken.
#
# Usage:
#   dg-author-metric.sh             # last 7 days
#   dg-author-metric.sh --days=30   # last 30 days
#   dg-author-metric.sh --all       # everything in the log
#   dg-author-metric.sh --json      # newline-delimited JSON rows
#
# Output (default, plain text):
#   date         agent  fallback  fb_reasons                       total  agent_pct
#   2026-05-20      14         3  no_DG_AUTHOR_CMD=2;agent_timeout=1   17    82.4%
#
# Reason codes (from dg__audit_fallback):
#   agent_ok              — agent shim succeeded (the goal-state)
#   no_DG_AUTHOR_CMD      — env var not set; jq path is the deterministic baseline
#   agent_unavailable     — shim exited nonzero
#   agent_timeout         — shim exceeded DG_AUTHOR_TIMEOUT_SEC
#   agent_invalid_output  — shim produced non-{body,items[]} output

set -uo pipefail

LOG_PATH="${DG_AUDIT_LOG:-$HOME/.cache/claude-tools/dossier-author-audit.jsonl}"
DAYS=7
FMT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days=*) DAYS="${1#--days=}" ;;
    --days)   shift; DAYS="${1:-7}" ;;
    --all)    DAYS="all" ;;
    --json)   FMT="json" ;;
    --log=*)  LOG_PATH="${1#--log=}" ;;
    --log)    shift; LOG_PATH="${1:?--log needs a path}" ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "dg-author-metric: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$LOG_PATH" ]]; then
  echo "dg-author-metric: no audit log at $LOG_PATH (no dossiers have been authored yet, or DG_AUDIT_LOG is set elsewhere)" >&2
  exit 0
fi

# Build a since-cutoff filter (jq compares ts strings — ISO-8601 sorts
# lexicographically, so a string compare is equivalent to a date compare).
since=""
if [[ "$DAYS" != "all" ]]; then
  if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
    echo "dg-author-metric: --days needs a non-negative integer or 'all'" >&2
    exit 2
  fi
  # macOS `date` doesn't support `-d` arithmetic the GNU way; do it in awk.
  since=$(awk -v d="$DAYS" 'BEGIN {
    n = systime() - d*86400
    print strftime("%Y-%m-%d", n, 1)
  }')
fi

ROWS=$(jq -c --arg since "$since" '
  select(.ts != null and .ts != "")
  | { day: (.ts | .[0:10]), reason: (.reason // "unknown") }
  | select(($since == "") or (.day >= $since))
' "$LOG_PATH" 2>/dev/null | jq -cs '
  group_by(.day) | map({
    day: .[0].day,
    agent_ok:              ([ .[] | select(.reason=="agent_ok") ]              | length),
    no_DG_AUTHOR_CMD:      ([ .[] | select(.reason=="no_DG_AUTHOR_CMD") ]      | length),
    agent_unavailable:     ([ .[] | select(.reason=="agent_unavailable") ]     | length),
    agent_timeout:         ([ .[] | select(.reason=="agent_timeout") ]         | length),
    agent_invalid_output:  ([ .[] | select(.reason=="agent_invalid_output") ]  | length),
    other:                 ([ .[] | select(.reason as $r | ["agent_ok","no_DG_AUTHOR_CMD","agent_unavailable","agent_timeout","agent_invalid_output"] | index($r) | not) ] | length)
  }) | sort_by(.day) | reverse | .[]
') || ROWS=""

if [[ -z "$ROWS" ]]; then
  echo "dg-author-metric: no rows in window (since=${since:-all-time}; log=$LOG_PATH)" >&2
  exit 0
fi

if [[ "$FMT" == "json" ]]; then
  printf '%s\n' "$ROWS" | jq -c '
    .agent     = .agent_ok
    | .fallback = (.no_DG_AUTHOR_CMD + .agent_unavailable + .agent_timeout + .agent_invalid_output + .other)
    | .total    = (.agent + .fallback)
    | .agent_fraction = (if .total>0 then (.agent / .total) else 0 end)'
  exit 0
fi

printf '%s\n' "$ROWS" | jq -r '
  def pad(n): tostring | (. + (" " * (n - length)))[:n];
  def lpad(n): tostring | ((" " * n) + .) | .[-n:];
  . as $r
  | (.agent_ok)                                                                                            as $agent
  | (.no_DG_AUTHOR_CMD + .agent_unavailable + .agent_timeout + .agent_invalid_output + .other)             as $fb
  | ($agent + $fb)                                                                                          as $tot
  | (if $tot>0 then ($agent*1000/$tot | floor)/10 else 0 end)                                              as $pct
  | ( [ (if .no_DG_AUTHOR_CMD     >0 then "no_DG_AUTHOR_CMD="     + (.no_DG_AUTHOR_CMD|tostring)     else empty end),
        (if .agent_unavailable    >0 then "agent_unavailable="    + (.agent_unavailable|tostring)    else empty end),
        (if .agent_timeout        >0 then "agent_timeout="        + (.agent_timeout|tostring)        else empty end),
        (if .agent_invalid_output >0 then "agent_invalid_output=" + (.agent_invalid_output|tostring) else empty end),
        (if .other                >0 then "other="                + (.other|tostring)                else empty end)
      ] | join(";") ) as $reasons
  | (.day | pad(12)) + " " + ($agent|lpad(6)) + " " + ($fb|lpad(9)) + "  " + (($reasons|pad(32))) + " " + ($tot|lpad(6)) + " " + (($pct|tostring) + "%" | lpad(9))
' | (printf '%-12s %6s %9s  %-32s %6s %9s\n' "date" "agent" "fallback" "fb_reasons" "total" "agent_pct"; cat)
