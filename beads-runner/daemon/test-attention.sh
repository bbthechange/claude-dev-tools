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
REPO_LIB="$(cd "$HERE/.." && pwd)/lib"

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
    # tv88 digest-push env. PUSHDIS defaults to 1 (canary-disabled) so PARTs A–F
    # exercise the iz36 WARN behavior byte-unchanged; PART G flips it on.
    export DAEMON_ATTENTION_PUSH_DISABLED="${PUSHDIS:-1}"
    export DAEMON_ATTENTION_PUSH_CHANNEL="${PUSHCH:-machine-attention}"
    export DAEMON_ATTENTION_ENGINE_OVERRIDE="${ENGOV:-}"
    export CO_STORE="${COSTORE:-$STATE/attention-co-store}"
    export DAEMON_REPO_DIR="$(cd "$HERE/.." && pwd)"
    export DAEMON_REPO_LIB_DIR="$DAEMON_REPO_DIR/lib"
    unset COORDINATOR_URL COORDINATOR_TOKEN 2>/dev/null || true
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

# ── PART G — tv88 DIGEST PHONE PUSH ──────────────────────────────────────────
echo ""
echo "── PART G — edge ⇒ digest dossier+notification (canary on); dedup; N→1; canary off ──"

# Helpers to read the local CO_STORE the real engine-write lands in.
dossier_count() { ls "$1"/records/dossier.attention-*.json 2>/dev/null | wc -l | tr -d ' '; }
notif_count()   { ls "$1"/records/notification.notif.attention-*.json 2>/dev/null | wc -l | tr -d ' '; }

# G1 — a single alert with the canary ON drives the REAL dg_generate (the §5.1
# write gate) against a local store: a conformant digest overview + a digest
# notification on the shared channel must land, and the .pushed sentinel written.
STATE="$WORK/g1"; COSTORE="$WORK/g1-store"; PUSHDIS=0; DIS=0; RELOG=3600; ENGOV=""
SNAP_G="$(snap_with "thirsty:stale-runner:18000")"
outg1="$(run_poll "$SNAP_G")"
case "$outg1" in *"WARN MACHINE ATTENTION"*) ok "G1 still WARNs (observability half intact)";; *) bad "G1 lost the WARN ($outg1)";; esac
case "$outg1" in *"PUSH digest dossier+notification emitted"*"tier=digest"*"channel=machine-attention"*) ok "G1 logs the digest PUSH";; *) bad "G1 no digest PUSH log ($outg1)";; esac
DREC="$COSTORE/records/dossier.attention-thirsty__stale-runner.json"
NREC="$COSTORE/records/notification.notif.attention-thirsty__stale-runner.json"
if [[ -f "$DREC" ]]; then
  okdoss="$(jq -r 'select(.kind=="overview" and .tier=="digest" and .trigger=="proactive_checkpoint" and (.bead_ref|length>0) and (.items|length==0) and (.body.dossier_schema_version|type=="number") and ((.body.tldr|length)>0) and ((.body.sections|length)>0) and (.body.diagrams==[])) | "ok"' "$DREC" 2>/dev/null)"
  [[ "$okdoss" == "ok" ]] && ok "G1 conformant digest overview dossier passed the §5.1 write gate" || bad "G1 dossier not conformant ($(jq -c '{kind,tier,trigger,sv:.body.dossier_schema_version}' "$DREC" 2>/dev/null))"
else
  bad "G1 no dossier record written"
fi
if [[ -f "$NREC" ]]; then
  oknotif="$(jq -r 'select(.tier=="digest" and .channel=="machine-attention" and .dispatched==true) | "ok"' "$NREC" 2>/dev/null)"
  [[ "$oknotif" == "ok" ]] && ok "G1 digest notification routed to the machine-attention channel (dispatched)" || bad "G1 notification wrong ($(jq -c '{tier,channel,dispatched}' "$NREC" 2>/dev/null))"
else
  bad "G1 no notification record written"
fi
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json.pushed" ]] && ok "G1 .pushed sentinel written (one-push dedup armed)" || bad "G1 no .pushed sentinel"

# G2 — a SECOND distinct alert shares the channel ⇒ the rollup folds N→1 push
# (must-protect #5). Same STATE/store so both notifications coexist.
SNAP_G2="$(snap_with "thirsty:stale-runner:18000" "otherws:stale-runner:9000")"
outg2="$(run_poll "$SNAP_G2")"
[[ "$(notif_count "$COSTORE")" == "2" ]] && ok "G2 second distinct alert emits a second digest notification" || bad "G2 expected 2 notifications, got $(notif_count "$COSTORE")"
rollup="$(cat "$COSTORE"/records/notification.notif.attention-*.json 2>/dev/null | (. "$REPO_LIB/notification.sh" 2>/dev/null; no__group_digests))"
ndigest="$(printf '%s' "$rollup" | jq -r '.digests | length' 2>/dev/null)"
ncount="$(printf '%s' "$rollup" | jq -r '.digests[0].count' 2>/dev/null)"
[[ "$ndigest" == "1" && "$ncount" == "2" ]] && ok "G2 must-protect #5: 2 alerts fold to ONE channel group (count=2 → 1 daily push)" || bad "G2 rollup did not fold N→1 (groups=$ndigest count=$ncount)"

# G3 — re-poll the same alert ⇒ NO new push (the .pushed sentinel dedups).
before="$(notif_count "$COSTORE")"
outg3="$(run_poll "$SNAP_G2")"
case "$outg3" in *"PUSH digest dossier+notification emitted"*) bad "G3 RE-PUSHED an already-pushed alert (dedup broken)";; *) ok "G3 re-poll ⇒ no new PUSH (per-(project,kind) marker dedups)";; esac
[[ "$(notif_count "$COSTORE")" == "$before" ]] && ok "G3 notification count unchanged on re-poll" || bad "G3 notification count grew ($before → $(notif_count "$COSTORE"))"

# G4 — the CANARY default (disabled) WARNs but writes NO dossier (prod-safe dormant).
STATE="$WORK/g4"; COSTORE="$WORK/g4-store"; PUSHDIS=1; ENGOV=""
outg4="$(run_poll "$(snap_with "thirsty:stale-runner:18000")")"
case "$outg4" in *"WARN MACHINE ATTENTION"*) ok "G4 canary-disabled still WARNs (iz36 half unchanged)";; *) bad "G4 lost the WARN ($outg4)";; esac
case "$outg4" in *"PUSH digest"*) bad "G4 canary-disabled still PUSHED (not dormant!)";; *) ok "G4 canary-disabled ⇒ NO push log";; esac
[[ "$(dossier_count "$COSTORE")" == "0" ]] && ok "G4 canary-disabled wrote NO dossier (prod-safe until device-verify)" || bad "G4 wrote a dossier while disabled"

# G5 — the retry lane: an edge emit FAILURE leaves .pushed absent (retry-eligible);
# a later succeeding poll lands the push. Use a failing then a passing override.
STATE="$WORK/g5"; COSTORE="$WORK/g5-store"; PUSHDIS=0
FAILOV="$WORK/fail-ov.sh"; printf '#!/bin/bash\nexit 1\n' > "$FAILOV"; chmod +x "$FAILOV"
PASSOV="$WORK/pass-ov.sh"; printf '#!/bin/bash\ncat "$1" >> "%s/captured.jsonl"\necho "attention-thirsty__stale-runner"\n' "$WORK" > "$PASSOV"; chmod +x "$PASSOV"
ENGOV="$FAILOV"
outg5a="$(run_poll "$(snap_with "thirsty:stale-runner:18000")")"
case "$outg5a" in *"PUSH WARN — digest emit failed"*) ok "G5 edge emit failure logs a PUSH WARN";; *) bad "G5 no failure WARN ($outg5a)";; esac
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json" ]] && ok "G5 marker present after failed edge" || bad "G5 marker missing"
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json.pushed" ]] && bad "G5 .pushed written despite failure (retry would never fire)" || ok "G5 .pushed ABSENT after failure ⇒ retry-eligible"
ENGOV="$PASSOV"
outg5b="$(run_poll "$(snap_with "thirsty:stale-runner:18000")")"
case "$outg5b" in *"PUSH digest dossier+notification emitted"*) ok "G5 next poll RETRIES the push (ongoing branch)";; *) bad "G5 retry did not fire ($outg5b)";; esac
[[ -f "$STATE/attention-fired/thirsty__stale-runner.json.pushed" ]] && ok "G5 .pushed written after successful retry (no further retries)" || bad "G5 .pushed not written after retry"
PUSHDIS=1; ENGOV=""; COSTORE=""

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " test-attention (iz36 + tv88):  PASS=$PASS  FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
