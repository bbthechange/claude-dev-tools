#!/usr/bin/env bash
# beads-runner/sweep-stranded-live-sessions.sh — Mechanism C
# (claude-tools-uxc3; inbox-lifecycle §8.3.5 / §8.3.9 bead C-3).
#
# WHAT THIS IS:
#   The third leg of the cross-process-ownership stack (A: PID claim files
#   = uxc1; B: PreToolUse auto-label = n6ek; C: this sweep). Mechanisms A+B
#   keep the runner from ADOPTING a task a live external Claude session owns:
#   an interactive (non-runner) agent that drives a bead to `in_progress`
#   gets `human-live-session` auto-attached, and the runner's
#   RUNNER_NO_CLAIM_LABELS gate refuses it on every loop. Correct WHILE the
#   human/agent is alive — but if that interactive session CRASHES (machine
#   reboot, Claude Code quit, OOM) the label is STRANDED: the bead sits
#   `in_progress + human-live-session` forever, the runner keeps refusing it
#   by label, and nothing ever cleans it up. It rots.
#
#   This sweep is the janitor for that edge case. It finds beads that are
#   `in_progress + human-live-session` with (a) no LIVE local owner and
#   (b) no recent activity, and for each files a TRIAGE bead carrying the
#   audit data a follow-up agent (or Brian) needs to decide what happened.
#
# THE HARD INVARIANT (C-3 acceptance, do not weaken):
#   This script files an AUDIT bead and NOTHING ELSE. It NEVER flips the
#   stranded bead's status and NEVER clears its `human-live-session` label.
#   Deciding "the work was finished, close it" vs "it should resume, clear
#   the label" requires reading git/notes/commits — judgement this blind
#   sweep does not have and must not fake. The sweep's only job is to make
#   the strand VISIBLE; the triage bead it files asks an agent to make the
#   reversible call. (inbox-lifecycle §8.3.5: "does NOT itself flip status
#   or clear labels".)
#
# WHEN IS A BEAD "STRANDED"?  (claim_live==0  AND  stale)
#   • claim_live: a Mechanism-A claim file ($CLAIMS_DIR/<id>.json) on THIS
#     host with a numeric, still-alive pid (`kill -0`). Interactive sessions
#     do not write claim files at all, so the common case is "no claim".
#     A claim with a DEAD pid is a crashed owner — it does NOT protect the
#     bead (its details are captured as audit data instead). A foreign-host
#     claim can't be liveness-checked locally, so it doesn't count as a live
#     owner either (its host is recorded in the audit). Only a provably-alive
#     local pid means "something is actively on this — leave it".
#     We interpret §8.3.5's "no claim file" as "no LIVE claim" deliberately:
#     a stale dead-pid claim is exactly a crash, which is what we're after.
#   • stale: `updated_at` older than STALE_HOURS (default 4h, §8.3.5 "~4h").
#     A bead touched in the last few hours is presumed still-live work and
#     is left alone — that is the §8.3.7 "updated_at 5 min ago ⇒ no triage"
#     case. An empty/unparseable `updated_at` on an in_progress bead is
#     itself anomalous and is treated as stale (surface it).
#
#   Coordinator heartbeat is NOT consulted. §8.3.5 lists it as a third signal,
#   but the live work-snapshot is reached over the §2.3 HTTP front door and
#   tracks RUNNER liveness, not the INTERACTIVE sessions this edge case is
#   about — so it is both offline-unsafe here and largely irrelevant. We take
#   the same posture uxc1 took for the cross-workspace liveness refinement:
#   document it as a follow-up; the offline signals (claim + updated_at) are
#   the robust ones. The triage bead records this so the reader is not misled.
#
# IDEMPOTENCY:
#   A scheduled sweep must not refile the same triage every cycle. Each triage
#   bead carries the label `stranded-live-session-triage` and a machine marker
#   line `STRANDED_TASK=<id>` in its description. Before filing for <id> the
#   sweep scans existing NON-closed triage beads for that exact marker line and
#   skips (reports `already-triaged`) if one is present. A CLOSED triage that
#   left the bead still-stranded does NOT suppress a refile — if it's still
#   rotting it should be re-surfaced.
#
# SUBCOMMANDS:
#   sweep   Find stranded beads and FILE a triage bead for each new one.
#           Exit 0 if none stranded, 1 if any stranded found, 2 usage, 3 bd/jq
#           preflight failure. (Exit 1 is a signal, not an error — a scheduler
#           can branch on it.)
#   scan    Dry-run: detect + report exactly what `sweep` would do, but FILE
#           NOTHING. Same exit-code contract.
#   list    Machine-readable: print only the stranded bead-ids, one per line.
#
# OUTPUT (sweep / scan), one line per stranded bead on stdout:
#   <id>  STRANDED  last_activity=<ts> (<age>) claim=<state>  -> <disposition>
# Trailing summary on stderr:
#   sweep-stranded-live-sessions: candidates=C stranded=N triaged=F already=A skipped=S
#
# SCHEDULING: out of scope for this bead (C-3: "ship script first"). Wire later
#   via /loop, /schedule, or the lib/timed-fyi.sh cadence.
#
# Safe under `set -uo pipefail`: every bd/jq/date call is guarded; the script
# controls its own exit codes. bd + jq are resolved from PATH so a stateful
# fake bd (test-sweep-stranded-live-sessions.sh) exercises it with zero
# live-bd risk.

set -uo pipefail

# ── config (all env-overridable; defaults match the spec) ────────────────────
STALE_HOURS="${STRANDED_STALE_HOURS:-4}"                       # §8.3.5 "~4h"
LOG_DIR="${LOG_DIR:-.beads/runner-logs}"                       # claims live under here (uxc1)
CLAIMS_DIR="${CLAIMS_DIR:-$LOG_DIR/claims}"                    # Mechanism-A claim files
TRIAGE_LABEL="stranded-live-session-triage"                    # dedup + filter marker
LIVE_LABEL="human-live-session"                                # the stranded label we hunt

usage() {
  cat <<'EOF'
sweep-stranded-live-sessions.sh — Mechanism C: triage stranded
`human-live-session` tasks left by a crashed interactive agent
(claude-tools-uxc3; inbox-lifecycle §8.3.5).

Usage:
  sweep-stranded-live-sessions.sh sweep
      Find stranded beads and FILE a triage bead for each new one.
      Files audit data only — never flips status, never clears labels.
      Exit 0 clean, 1 if any stranded found, 2 usage, 3 bd/jq failure.

  sweep-stranded-live-sessions.sh scan
      Dry-run: report what `sweep` would do, file nothing. Same exit codes.

  sweep-stranded-live-sessions.sh list
      Print stranded bead-ids only, one per line (machine-readable).

Env: STRANDED_STALE_HOURS (default 4), CLAIMS_DIR, LOG_DIR.
EOF
}

_preflight() {
  command -v bd >/dev/null 2>&1 || { echo "sweep-stranded-live-sessions: reject — bd not on PATH" >&2; return 3; }
  command -v jq >/dev/null 2>&1 || { echo "sweep-stranded-live-sessions: reject — jq required" >&2; return 3; }
  return 0
}

# UTC now, ISO-8601 Z.
_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# (now - $1 hours) as ISO-8601 Z. GNU date first, then BSD/macOS date.
_cutoff_iso() {
  local hrs="$1"
  date -u -d "$hrs hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${hrs}"H   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# Parse an ISO-8601 Z timestamp to epoch seconds (GNU then BSD). Empty on miss.
_epoch_of() {
  local t="${1:-}"
  [[ -n "$t" && "$t" != "null" ]] || return 0
  date -u -d "$t" +%s 2>/dev/null \
    || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$t" +%s 2>/dev/null \
    || true
}

# Human "<N>h" / "<N>m" age for display only (decision uses the lexical cutoff
# compare, never this). Falls back to the raw timestamp if date can't parse it.
_age_str() {
  local t="${1:-}" now_e then_e diff
  now_e="$(_epoch_of "$(_now_utc)")"; then_e="$(_epoch_of "$t")"
  if [[ -n "$now_e" && -n "$then_e" ]]; then
    diff=$(( now_e - then_e )); (( diff < 0 )) && diff=0
    if (( diff >= 3600 )); then echo "$(( diff / 3600 ))h"; else echo "$(( diff / 60 ))m"; fi
  else
    echo "${t:-unknown}"
  fi
}

# Records use ASCII Unit-Separator (\x1f), not TAB — an empty field (e.g. a
# bead with no labels joined to "") must not collapse into its neighbour the
# way `read` collapses consecutive TAB whitespace. (Same guard as
# defer-cascade-audit.sh.)
US=$'\x1f'

# Emit every `in_progress` bead carrying $LIVE_LABEL as
#   <id><US><updated_at><US><title>
# The label join is done in jq over the REAL .labels array (NOT bd's
# --label flag, a documented no-op for patterns and brittle for exact —
# bd-label-pattern-regex-noop-v104 / sweep-fixtures.sh). type=="string"
# guards startswith/== against a non-string label aborting the stream.
_live_session_candidates() {
  # --limit 0 (unlimited): bd's default caps `list` at 50 rows, which would
  # false-skip a genuine strand beyond the 50th in_progress bead — the exact
  # rot this janitor exists to prevent. Matches _existing_triage_markers.
  bd list --status=in_progress --json --limit 0 2>/dev/null \
    | jq -r --arg lbl "$LIVE_LABEL" --arg us "$US" '
        .[]
        | select(any(.labels[]?; type=="string" and . == $lbl))
        | "\(.id)\($us)\(.updated_at // "")\($us)\((.title // "")[0:80])"
      ' 2>/dev/null
}

# Marker lines (one per id, `STRANDED_TASK=<id>`) of every NON-closed triage
# bead already on the board. Read once before the loop for O(1) dedup. The
# label join is again the safe jq-over-.labels scan; the marker is matched as
# a WHOLE line downstream (grep -xF) so `...uxc3` never matches `...uxc30`.
_existing_triage_markers() {
  bd list --all --json --limit 0 2>/dev/null \
    | jq -r --arg lbl "$TRIAGE_LABEL" '
        .[]
        | select(any(.labels[]?; type=="string" and . == $lbl))
        | select(.status != "closed")
        | (.description // "")
        | split("\n")[]
        | select(startswith("STRANDED_TASK="))
      ' 2>/dev/null
}

# Classify the Mechanism-A claim for <id>. Echoes "<live><US><desc>" where
# <live> is 1 iff a provably-alive LOCAL pid owns it, and <desc> is the audit
# string. Pure read; never touches the claim file.
_claim_state() {
  local id="$1" cf rid pid host ws started this_host
  cf="$CLAIMS_DIR/$id.json"
  if [[ ! -f "$cf" ]]; then
    printf '0%snone (no Mechanism-A claim file — in_progress set by a non-runner: interactive session / manual bd update)' "$US"
    return 0
  fi
  rid="$(jq -r '.runner_id // empty' "$cf" 2>/dev/null || true)"
  pid="$(jq -r '.pid // empty'       "$cf" 2>/dev/null || true)"
  host="$(jq -r '.host // empty'     "$cf" 2>/dev/null || true)"
  ws="$(jq -r '.workspace // empty'  "$cf" 2>/dev/null || true)"
  started="$(jq -r '.started_at // empty' "$cf" 2>/dev/null || true)"
  this_host="$(hostname 2>/dev/null || echo unknown)"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    printf '0%spresent but unusable pid=%q (runner=%q ws=%q started=%q)' "$US" "${pid:-}" "${rid:-?}" "${ws:-?}" "${started:-?}"
    return 0
  fi
  if [[ "$host" != "$this_host" ]]; then
    # The claim does not assert THIS host (foreign host, or a forged/corrupt
    # claim missing the host field): its pid is in another machine's process
    # table (or unknowable), so `kill -0` here is meaningless and it is NOT a
    # provable local live owner. Surface it — only an explicit local-host claim
    # earns the LIVE skip. (Mechanism-A claims always stamp host; uxc1.)
    local why
    if [[ -z "$host" ]]; then why="claim missing host field"; else why="foreign-host claim host=$host"; fi
    printf '0%s%s pid=%s (runner=%q ws=%q) — local liveness unverifiable, not a provable live owner' "$US" "$why" "$pid" "${rid:-?}" "${ws:-?}"
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    printf '1%sLIVE local owner pid=%s (runner=%q ws=%q) — actively held, not stranded' "$US" "$pid" "${rid:-?}" "${ws:-?}"
    return 0
  fi
  printf '0%sstale claim pid=%s is DEAD (runner=%q ws=%q started=%q) — crashed owner' "$US" "$pid" "${rid:-?}" "${ws:-?}" "${started:-?}"
}

# Build the triage-bead description for a stranded <id>. Carries the audit data
# §8.3.5/C-3 require + the standing instruction for the triage agent + the
# STRANDED_TASK=<id> dedup marker line.
_triage_description() {
  local id="$1" title="$2" updated="$3" age="$4" claim_desc="$5" now
  now="$(_now_utc)"
  cat <<EOF
Auto-filed by sweep-stranded-live-sessions.sh (Mechanism C; claude-tools-uxc3;
inbox-lifecycle §8.3.5).

An interactive (non-runner) Claude session drove $id to in_progress, so
Mechanism B auto-attached \`$LIVE_LABEL\` and the runner correctly refuses it
by label (RUNNER_NO_CLAIM_LABELS). That session now appears to have crashed or
quit: no live local owner and no activity for $age. The bead will rot
in_progress forever — the runner will never adopt a \`$LIVE_LABEL\` task — until
someone resolves it. This sweep files audit data ONLY; it has NOT changed $id.

Resolve $id (do the homework FIRST — read its git log, commits, and bd notes):
  • Work was actually finished  ⇒ \`bd close $id\`.
  • Should resume autonomously  ⇒ \`bd label remove $id $LIVE_LABEL\` so the
    runner can adopt it on its next loop.
  • Genuinely still live human work ⇒ leave it as-is.
  • Genuinely cannot decide ⇒ file a follow-up \`human-action\` bead (the
    warranted use). Do NOT add \`human-triage\` to THIS bead.

--- audit (sweep-stranded-live-sessions.sh) ---
Stranded bead:       $id — $title
Last activity:       ${updated:-unknown} ($age ago)
Staleness threshold: ${STALE_HOURS}h (STRANDED_STALE_HOURS)
Claim file:          $claim_desc
Coordinator:         not consulted — the live work-snapshot tracks runner, not
                     interactive-session, liveness; cross-workspace liveness is
                     a documented follow-up (inbox-lifecycle §8.3.3, uxc1).
Detected at:         $now
STRANDED_TASK=$id
EOF
}

# File one triage bead for stranded <id>. Echoes the new triage id (or empty on
# failure). Links the triage back to the stranded bead with a non-blocking
# `discovered-from` dep. NO human-triage label (§11 / feedback_beads_human_triage_label).
_file_triage() {
  local id="$1" desc="$2" out new_id=""
  out="$(bd create \
    --title "stranded human-live-session triage: $id" \
    -d "$desc" \
    --type task \
    -p 2 \
    --labels "runner-reliability,$TRIAGE_LABEL" \
    --deps "discovered-from:$id" 2>&1)" || true
  # `bd create` (text mode) emits "✓ Created issue: <id> — title" — same parse
  # the runner uses (runner.sh:1199). Empty ⇒ caller reports the file failed.
  new_id="$(printf '%s' "$out" | sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1)"
  printf '%s' "$new_id"
}

# Core detection + (optional) filing. Mode: sweep | scan | list.
#   - sweep files a triage for each NEW stranded bead.
#   - scan/list detect only, file nothing.
# Exit: 0 none stranded, 1 at least one stranded, 3 bd/jq preflight failure.
_run() {
  local mode="$1"
  _preflight || return 3

  local cutoff markers candidates
  cutoff="$(_cutoff_iso "$STALE_HOURS")"
  [[ -n "$cutoff" ]] || { echo "sweep-stranded-live-sessions: reject — could not compute staleness cutoff (date)" >&2; return 3; }
  markers="$(_existing_triage_markers)"
  candidates="$(_live_session_candidates)"

  local n_cand=0 n_stranded=0 n_triaged=0 n_already=0 n_skipped=0
  local id updated title claim_live claim_desc age stale disp

  if [[ -n "$candidates" ]]; then
    while IFS="$US" read -r id updated title; do
      [[ -n "$id" ]] || continue
      n_cand=$(( n_cand + 1 ))

      # claim liveness
      IFS="$US" read -r claim_live claim_desc < <(_claim_state "$id")
      if [[ "$claim_live" == "1" ]]; then
        n_skipped=$(( n_skipped + 1 ))
        continue
      fi

      # staleness: lexical compare of well-formed Z timestamps (identical
      # format ⇒ lexical order == chronological). Empty/malformed updated_at
      # on an in_progress bead is anomalous ⇒ treat as stale (surface it).
      if [[ "$updated" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        if [[ "$updated" < "$cutoff" ]]; then stale=1; else stale=0; fi
      else
        stale=1
      fi
      if [[ "$stale" != "1" ]]; then
        n_skipped=$(( n_skipped + 1 ))
        continue
      fi

      # STRANDED.
      n_stranded=$(( n_stranded + 1 ))
      age="$(_age_str "$updated")"

      if [[ "$mode" == "list" ]]; then
        printf '%s\n' "$id"
        continue
      fi

      # dedup against existing non-closed triage beads
      if printf '%s\n' "$markers" | grep -qxF "STRANDED_TASK=$id"; then
        n_already=$(( n_already + 1 ))
        disp="already-triaged (open triage bead exists)"
      elif [[ "$mode" == "scan" ]]; then
        disp="would-file (dry-run)"
      else
        local desc tid
        desc="$(_triage_description "$id" "$title" "$updated" "$age" "$claim_desc")"
        tid="$(_file_triage "$id" "$desc")"
        if [[ -n "$tid" ]]; then
          n_triaged=$(( n_triaged + 1 ))
          disp="triaged -> $tid"
          # Add to the in-run marker set so a (impossible) duplicate id in the
          # same pass can't double-file.
          markers="$markers"$'\n'"STRANDED_TASK=$id"
        else
          disp="FILE FAILED — see bd output (no triage bead created)"
        fi
      fi
      printf '%s  STRANDED  last_activity=%s (%s) claim=[%s]  -> %s\n' \
        "$id" "${updated:-unknown}" "$age" "$claim_desc" "$disp"
    done <<< "$candidates"
  fi

  if [[ "$mode" != "list" ]]; then
    printf 'sweep-stranded-live-sessions: candidates=%d stranded=%d triaged=%d already=%d skipped=%d\n' \
      "$n_cand" "$n_stranded" "$n_triaged" "$n_already" "$n_skipped" >&2
  fi

  [[ "$n_stranded" -eq 0 ]] && return 0
  return 1
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift || true

case "$CMD" in
  sweep)      _run sweep; exit $? ;;
  scan)       _run scan;  exit $? ;;
  list)       _run list;  exit $? ;;
  -h|--help)  usage; exit 0 ;;
  *) echo "sweep-stranded-live-sessions: reject — unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac
