#!/bin/bash
# beads-runner/daemon/test-attention.sh — iz36 (claude-tools-iz36)
# machine-attention observability poll conformance (offline — no engine, no net).
#
# WHAT THIS PROVES:
#   PART 0 — file parses, defines the API, carries the iz36 banner.
#   PART A — an `attention` alert in the (injected) work-snapshot ⇒ an
#            edge-triggered WARN line + a marker; a SECOND poll on the SAME
#            snapshot ⇒ NO new WARN (dedup, no 60s storm).
#   PART B — the alert clearing ⇒ a RESOLVED line + the marker removed.
#   PART C — DAEMON_ATTENTION_DISABLED=1 is a hard kill switch (no log, no marker).
#   PART D — an OLDER engine snapshot WITHOUT the `attention` key ⇒ honest no-op.
#   PART E — an empty/unreachable snapshot ⇒ no-op, markers UNTOUCHED (observe-
#            first: a transient transport failure must NOT flap RESOLVED).
#   PART F — the hourly re-log: a backdated marker.at ⇒ ONE "(ongoing)" re-log;
#            DAEMON_ATTENTION_RELOG_SECONDS=0 ⇒ no re-log.
#
# The engine derivation itself (deriveAttention / co__derive_attention) is pinned
# by cf/test/reconcile.spec.js + lib/test-board.sh; this proves the daemon CLOCK
# reads the field and emits the right log signal with the right edge/dedup/resolve.
#
# Run: bash beads-runner/daemon/test-attention.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/attention-poll.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " iz36 machine-attention observability poll — claude-tools-iz36"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A work-snapshot JSON with N attention alerts. $@ = "ref:kind:age" triples.
snap_with() {
  local arr='[]' spec ref kind age
  for spec in "$@"; do
    ref="${spec%%:*}"; rest="${spec#*:}"; kind="${rest%%:*}"; age="${rest#*:}"
    arr="$(printf '%s' "$arr" | jq -c --arg r "$ref" --arg k "$kind" --argjson a "$age" \
      '. + [{project_ref:$r, kind:$k, desired:"running", actual:"idle",
             heartbeat_age_seconds:$a,
             detail:("desired running but the runner heartbeat is stale (process alive — wedged)")}]')"
  done
  jq -cn --argjson alerts "$arr" \
    '{schema_version:1, principal:"brian", read_only:true, projects:[],
      lifecycle_columns:{}, waiting_on_you:[], machines:[],
      attention:{needs_attention:($alerts|length>0), alerts:$alerts}}'
}

# Run one poll with an injected snapshot, capturing the log lines.
# $1 = snapshot JSON ("" ⇒ unreachable/empty). Echoes the captured log.
LOGCAP="$WORK/log.txt"
run_poll() {
  local snap="$1"
  : > "$LOGCAP"
  ( set +e
    export DAEMON_CACHE_DIR="$STATE"
    export DAEMON_ATTENTION_FIRED_DIR="$STATE/attention-fired"
    export DAEMON_ATTENTION_SNAPSHOT_OVERRIDE="$snap"
    export DAEMON_ATTENTION_DISABLED="${DIS:-0}"
    export DAEMON_ATTENTION_RELOG_SECONDS="${RELOG:-3600}"
    # capture log() to a file (attention-poll prefixes "[attention] ")
    log() { printf '%s\n' "$*" >> "$LOGCAP"; }
    # shellcheck source=/dev/null
    . "$LIB"
    daemon_attention_poll_once
  )
  cat "$LOGCAP"
}

# ── PART 0 ──────────────────────────────────────────────────────────────────
echo ""
echo "── PART 0 — file parses + defines the API ──"
[[ -f "$LIB" ]] && ok "attention-poll.sh present" || bad "lib missing"
bash -n "$LIB" 2>/dev/null && ok "lib parses (bash -n clean)" || bad "lib syntax error"
( . "$LIB" 2>/dev/null; declare -F daemon_attention_poll_once >/dev/null 2>&1 ) \
  && ok "defines daemon_attention_poll_once" || bad "missing daemon_attention_poll_once"
grep -q "claude-tools-iz36" "$LIB" && ok "carries the iz36 provenance banner" || bad "iz36 banner missing"

# ── PART A — edge WARN + dedup ───────────────────────────────────────────────
echo ""
echo "── PART A — alert ⇒ edge WARN + marker; re-poll ⇒ no new WARN (dedup) ──"
STATE="$WORK/a"; DIS=0; RELOG=3600
SNAP_A="$(snap_with "thirsty:stale-runner:18000")"
out1="$(run_poll "$SNAP_A")"
case "$out1" in *"WARN MACHINE ATTENTION"*"thirsty"*) ok "first poll WARNs the wedged workspace";; *) bad "first poll did not WARN ($out1)";; esac
case "$out1" in *"heartbeat_age_seconds=18000"*) ok "WARN carries the heartbeat age";; *) bad "WARN missing heartbeat age";; esac
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json" ]] && ok "marker written for the alert" || bad "no marker written"
out2="$(run_poll "$SNAP_A")"
case "$out2" in *"WARN MACHINE ATTENTION"*) bad "second poll RE-WARNED (dedup broken: $out2)";; *) ok "second poll on same alert ⇒ NO new WARN (dedup)";; esac

# ── PART B — resolve ─────────────────────────────────────────────────────────
echo ""
echo "── PART B — alert clears ⇒ RESOLVED + marker removed ──"
SNAP_CLEAR="$(snap_with)"   # no alerts
out3="$(run_poll "$SNAP_CLEAR")"
case "$out3" in *"RESOLVED"*"thirsty"*) ok "cleared alert ⇒ RESOLVED line";; *) bad "no RESOLVED on clear ($out3)";; esac
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json" ]] && bad "marker not removed on resolve" || ok "marker removed on resolve"

# ── PART C — kill switch ─────────────────────────────────────────────────────
echo ""
echo "── PART C — DAEMON_ATTENTION_DISABLED=1 ⇒ hard no-op ──"
STATE="$WORK/c"; DIS=1; RELOG=3600
out4="$(run_poll "$(snap_with "x:stale-runner:18000")")"
[[ -z "$out4" ]] && ok "disabled ⇒ no log output" || bad "disabled still logged ($out4)"
[[ -d "$STATE/attention-fired" ]] && bad "disabled still created marker dir" || ok "disabled ⇒ no marker dir"
DIS=0

# ── PART D — older engine, no attention key ──────────────────────────────────
echo ""
echo "── PART D — snapshot WITHOUT an attention key ⇒ honest no-op (additive) ──"
STATE="$WORK/d"
NOATT='{"schema_version":1,"principal":"brian","read_only":true,"projects":[],"lifecycle_columns":{},"waiting_on_you":[],"machines":[]}'
out5="$(run_poll "$NOATT")"
[[ -z "$out5" ]] && ok "no attention key ⇒ no log" || bad "older-engine snapshot logged ($out5)"

# ── PART E — empty/unreachable ⇒ observe-first ───────────────────────────────
echo ""
echo "── PART E — empty snapshot ⇒ no-op, markers UNTOUCHED (observe-first) ──"
STATE="$WORK/e"; mkdir -p "$STATE/attention-fired"
# seed a pre-existing marker; an unreachable engine must NOT flap it to RESOLVED.
printf '{"project_ref":"thirsty","kind":"stale-runner"}\n' > "$STATE/attention-fired/thirsty__stale-runner.json"
out6="$(run_poll "")"
case "$out6" in *"RESOLVED"*) bad "empty snapshot flapped RESOLVED (observe-first broken)";; *) ok "empty snapshot ⇒ no RESOLVED flap";; esac
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json" ]] && ok "pre-existing marker survives an unreachable poll" || bad "marker wrongly removed on unreachable"

# ── PART F — hourly re-log ───────────────────────────────────────────────────
echo ""
echo "── PART F — ongoing alert re-logs at most hourly (and 0 disables it) ──"
STATE="$WORK/f"; RELOG=3600
SNAP_F="$(snap_with "thirsty:stale-runner:20000")"
run_poll "$SNAP_F" >/dev/null   # edge WARN + marker.at = now
# backdate the marker.at past the re-log window
echo "1" > "$STATE/attention-fired/thirsty__stale-runner.json.at"
out7="$(run_poll "$SNAP_F")"
case "$out7" in *"(ongoing)"*) ok "backdated marker ⇒ ONE (ongoing) re-log";; *) bad "no re-log after the window ($out7)";; esac
# with RELOG=0, re-logging is disabled even with a backdated marker
echo "1" > "$STATE/attention-fired/thirsty__stale-runner.json.at"
RELOG=0
out8="$(run_poll "$SNAP_F")"
case "$out8" in *"(ongoing)"*) bad "RELOG=0 still re-logged ($out8)";; *) ok "RELOG=0 ⇒ no re-log (edge+resolve only)";; esac

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " test-attention (iz36):  PASS=$PASS  FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
