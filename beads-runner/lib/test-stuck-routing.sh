#!/bin/bash
# beads-runner/lib/test-stuck-routing.sh — focused unit test for the T5.5
# STUCK_NEEDS_HUMAN DO routing: §7.4 dossier-level double-trigger dedup +
# §7.3 backstop-drives-the-bead + S-2/AD3.1 control→work reconcile
# (claude-tools-j7f; epic claude-tools-glk).
#
# T5.5's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it touches NO
# sibling test (test-coordinator{,-lease,-reconcile,-capacity,-forensic}.sh,
# test-dossier.sh, test-dossier-gen.sh, test-consequence.sh, test-timed-fyi.sh,
# test-notification.sh). It exercises ONLY the §7.3 / §7.4 (dossier-level) /
# S-2 surface on stuck-routing.sh, consuming the T5.2 generator
# (dg_from_worker_ask), the T5.1 substrate (dossier.sh: do_dedup_record /
# do_dedup_get / do_dossier_get) and the T4 §2.1 store as BLACK BOXES, and the
# WORK plane `bd` via a PATH-injected stateful fake — the SAME fake-bin
# pattern the conformance harness / test-consequence.sh / test-timed-fyi.sh use.
#
# Asserts the EXIT CRITERIA T5.5 owns against INTERFACE.md v1:
#   1. Worker-self-signal + backstop on the SAME fork ⇒ EXACTLY ONE Dossier
#      (dossier-level dedup keyed task_ref); two triggers never two dossiers
#      (parent EXIT 3; AD3.4 / preserved AD3.1).
#   2. A fired backstop ITSELF drives the bead to blocked-for-human
#      (status=blocked + bd human), for BOTH triggers; the bead ENDS blocked
#      (never reset to open) and bd human is preserved (parent EXIT 3; §7.3).
#   3. Human approves ⇒ the bead unblocks via the COORDINATOR reconcile EVEN
#      under simulated Dolt lag (control→work; the Board never lies; S-2).
#   4. The §7.2 worker structured ask is routed into the T5.2 generator as a
#      `worker_stuck` decision dossier (one pick-option item).
#   5. Binds §7.3/§7.4 DOSSIER-level (key=task_ref, §0.4 layer 1), DISTINCT
#      from the T5.3 per-Item Item-id latch: sr_* NEVER flips
#      consequence_applied; a different task_ref ⇒ an independent Dossier; a
#      same task_ref re-bound to a DIFFERENT id is REJECTED by the structure;
#      blocked-for-human is NOT a §4 record type (no co__schema_version).
#
# Self-contained: its own CO_STORE + fake-bin under mktemp; shares NO state
# with the conformance harness or sibling tests.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stuck-routing.sh"
[[ -f "$LIB" ]] || { echo "FATAL: stuck-routing.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # expect SUCCESS
ckn() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # expect FAILURE
eq()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1 (got '$2' want '$3')"; fi; }
ne()  { if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1 (both '$2')"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
# claude-tools-69u8: isolate the dossier-author audit log so a STANDALONE run
# doesn't pollute the real $HOME/.cache production telemetry (the gate sets it
# itself; honor that). See run-tests.sh / conformance/lib/harness.sh.
export DG_AUDIT_LOG="${DG_AUDIT_LOG:-$WORK/.dossier-author-audit.jsonl}"
# claude-tools-bmfj: this harness drives sr_route_stuck → dg_from_worker_ask →
# dg_generate → dg__author, which has an AUTOWIRE chokepoint. A STANDALONE
# `bash lib/test-stuck-routing.sh` inside a worker session inherits
# DG_AUTHOR_AUTOWIRE=1 with real `claude` on PATH + the executable
# lib/dg-author-bridge.sh present, so the chokepoint would wire the real bridge
# and fire claude-in-claude (the run-tests.sh wedge, from a sibling file). This
# test EXPECTS the deterministic jq fallback (it asserts no_DG_AUTHOR_CMD), so
# drop the whole authoring seam at startup. (The gate also forces
# DG_AUTHOR_AUTOWIRE=0; this is the belt-and-suspenders for a hand-run.)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 \
      DG_AUTHOR_CMD DG_AUTHOR_AUTOWIRE CLAUDE_BIN DG_AUTHOR_BRIDGE_PATH 2>/dev/null || true

# ── work-plane `bd` fake on PATH — STATEFUL status + human log ───────────────
# Tracks per-id status under $BDST/<id> so a blocked→open clobber (the
# simulated Dolt lag) and the reconcile's re-assert/lift are OBSERVABLE; logs
# every `bd human <id>` to $BD_HUMAN (one id per line). Fail-open like real bd.
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export BDST="$WORK/bdst"; mkdir -p "$BDST"
export BDNOTES="$WORK/bdnotes"; mkdir -p "$BDNOTES"   # claude-tools-d752: --append-notes sink
export BD_HUMAN="$WORK/bd-human.log"; : > "$BD_HUMAN"
export BD_LOG="$WORK/bd.log"; : > "$BD_LOG"
cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BD_LOG:-/dev/null}"
cmd="${1:-}"; shift || true
case "$cmd" in
  update)
    id="${1:-}"; shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status=*) printf '%s' "${1#--status=}" > "${BDST}/$id"; shift;;
        --status)   printf '%s' "${2:-}"        > "${BDST}/$id"; shift 2;;
        # claude-tools-d752: persist --append-notes so the fold's idempotency
        # read (bd show --long --json | .notes) round-trips through the fake.
        --append-notes=*) printf '%s\n' "${1#--append-notes=}" >> "${BDNOTES}/$id"; shift;;
        --append-notes)   printf '%s\n' "${2:-}"               >> "${BDNOTES}/$id"; shift 2;;
        *) shift;;
      esac
    done ;;
  # The human-needed signal in this bd build is the `human` LABEL set via
  # `bd label add <id> human` (NOT `bd human <id>`, which no-ops — the I5
  # rehearsal divergence). Track BOTH forms into $BD_HUMAN so the assertions
  # observe "the bead was marked human-needed" regardless of mechanism.
  human)  printf '%s\n' "${1:-}" >> "${BD_HUMAN:-/dev/null}" ;;
  label)
    sub="${1:-}"; shift || true
    if [[ "$sub" == "add" ]]; then
      lid="${1:-}"; shift || true
      for a in "$@"; do [[ "$a" == "human" ]] && printf '%s\n' "$lid" >> "${BD_HUMAN:-/dev/null}"; done
    fi ;;
  show)
    id="${1:-}"; s="open"; [[ -f "${BDST}/$id" ]] && s="$(cat "${BDST}/$id")"
    nt=""; [[ -f "${BDNOTES}/$id" ]] && nt="$(cat "${BDNOTES}/$id")"   # d752: notes for --long --json
    jq -cn --arg id "$id" --arg s "$s" --arg nt "$nt" '[{id:$id,status:$s,notes:$nt}]' ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"

# shellcheck source=/dev/null
source "$LIB"                 # → dossier-gen.sh → dossier.sh → coordinator.sh

GOOD="bearer-runner-secret-xyz"
BDSTATUS() { [[ -f "$BDST/$1" ]] && cat "$BDST/$1" || echo "open"; }
HUMAN_HITS() { grep -c -x -- "$1" "$BD_HUMAN" 2>/dev/null | tr -d ' \n' || echo 0; }
DOSSIER_CNT() { ls -1 "$CO_STORE/records"/dossier.*.json 2>/dev/null | grep -c . | tr -d ' \n' || echo 0; }
GET() { co_request "$GOOD" get dossier "$1" 2>/dev/null; }
# In-process projections (a `bash -c` subshell can NOT see sourced functions —
# every dossier/bfh probe MUST evaluate in THIS shell).
DJQ()  { GET "$1" | jq -r "$2" 2>/dev/null; }            # DJQ <id> <filter>
BFHJQ(){ sr_bfh_get "$1" 2>/dev/null | jq -r "$2" 2>/dev/null; }  # BFHJQ <tref> <filter>

# A contract-valid §7.2 worker structured ask (≥1 pick-option with a
# machine-applyable §5.3 block + recommendation{value,why}) so T5.2 authors a
# real worker_stuck dossier — the §7.2→§5 raw-material consumption.
ASK_JSON='{"tldr":"Worker hit a fork it must not resolve.",
 "ask":"Adopt approach A or B?",
 "options":[
   {"option_id":"a","label":"Approach A","blast_radius":"low",
    "consequence_block":{"cb_schema_version":2,"creates":[],"unblocks":[],"labels":[],"status_changes":[]}},
   {"option_id":"b","label":"Approach B","blast_radius":"medium",
    "consequence_block":{"cb_schema_version":2,"creates":[],"unblocks":[],"labels":[],"status_changes":[]}}],
 "recommendation":{"value":"a","why":"A is reversible and lower blast radius."},
 "reversible":"Nothing applied until a human picks (§5.3 = T5.3)."}'

echo "── §7.4 / §7.3 / S-2 — STUCK DO routing (T5.5) ──────────────────────────"

# ── EXIT 1 + EXIT 4 — one fork ⇒ ONE Dossier (worker-self-signal THEN backstop)
T=stuck-fork-1
DID1="$(sr_route_stuck "$GOOD" "$T" worker_stuck "$ASK_JSON" 2>/dev/null)"
ck   "worker-self-signal routes (echoes a dossier id)" test -n "$DID1"
eq   "deterministic dossier id keyed task_ref (§0.4)" "$DID1" "$(sr_dossier_id_for "$T")"
eq   "Dossier generated for the first trigger (T5.2)" "$(DJQ "$DID1" '.trigger')" "worker_stuck"
eq   "§7.2 ask → exactly ONE Item"            "$(DJQ "$DID1" '.items|length')" "1"
eq   "the Item is a pick-option (worker_stuck profile §5.2.1)" \
       "$(DJQ "$DID1" '.items[0].kind')" "pick-option"
N_AFTER_1="$(DOSSIER_CNT)"

# SECOND, INDEPENDENT trigger on the SAME fork — the runner backstop.
DID2="$(sr_route_stuck "$GOOD" "$T" backstop:permission_denials "$ASK_JSON" 2>/dev/null)"
eq   "backstop on the SAME fork ⇒ the SAME dossier id (§7.4 dossier dedup)" "$DID2" "$DID1"
eq   "two triggers never make two dossiers (count unchanged)" "$(DOSSIER_CNT)" "$N_AFTER_1"
eq   "T5.1 dedup record binds task_ref → the one dossier" "$(do_dedup_get "$T" 2>/dev/null)" "$DID1"

# ── EXIT 2 / §7.3 — a fired backstop ITSELF drives the bead (no worker help) ──
B=stuck-backstop-only
DIDB="$(sr_route_stuck "$GOOD" "$B" backstop:entered_plan_mode "$ASK_JSON" 2>/dev/null)"
ck   "backstop-only trigger routes" test -n "$DIDB"
eq   "§7.3 backstop drove the bead to blocked"        "$(BDSTATUS "$B")" "blocked"
ck   "§7.3 backstop raised bd human (fork ≠ rot)"     test "$(HUMAN_HITS "$B")" -ge 1
eq   "worker-self-signal fork ALSO ends blocked"      "$(BDSTATUS "$T")" "blocked"
ck   "worker-self-signal fork bd human preserved"     test "$(HUMAN_HITS "$T")" -ge 1
eq   "control-plane blocked-for-human record exists, unresolved (S-2 truth)" \
       "$(BFHJQ "$B" '.resolved')" "false"

# ── EXIT 3 / S-2 — human approves ⇒ unblock via reconcile UNDER Dolt lag ──────
H=stuck-human-loop
DIDH="$(sr_route_stuck "$GOOD" "$H" worker_stuck "$ASK_JSON" 2>/dev/null)"
eq   "raised: bead blocked-for-human"                 "$(BDSTATUS "$H")" "blocked"
# Simulate Dolt lag / a stale propagation that CLOBBERS the work-plane status
# back to open while the control plane still says blocked-for-human.
printf 'open' > "$BDST/$H"
n1="$(sr_reconcile_blocked_for_human "$GOOD" "$H" 2>/dev/null)"
eq   "reconcile acted on the unresolved record"       "$n1" "1"
eq   "Board never lies: reconcile RE-ASSERTS blocked under Dolt lag (S-2)" \
       "$(BDSTATUS "$H")" "blocked"
# Human decides on the control plane (the source of truth).
ck   "human resolves on the control plane"            sr_human_resolve "$GOOD" "$H" "$DIDH" "${DIDH}-d1" '{"decision":"a"}'
eq   "decision recorded (bfh now resolved)"           "$(BFHJQ "$H" '.resolved')" "true"
# Re-clobber the work plane (Dolt lag again) BEFORE the lift reconcile — the
# lift must be driven by the control-plane record, never by bead status.
printf 'blocked' > "$BDST/$H"
n2="$(sr_reconcile_blocked_for_human "$GOOD" "$H" 2>/dev/null)"
eq   "reconcile acted on the resolved record"         "$n2" "1"
eq   "human approved ⇒ bead UNBLOCKED via reconcile under Dolt lag (S-2)" \
       "$(BDSTATUS "$H")" "open"
ckn  "resolved record hard-deleted (fork closed)"     sr_bfh_get "$H"
sr_reconcile_blocked_for_human "$GOOD" "$H" >/dev/null 2>&1 || true
eq   "reconcile is idempotent (re-run ⇒ no-op, stays open)" "$(BDSTATUS "$H")" "open"

# ── claude-tools-2z14 — §7.9 work→control AUTO-CLOSE: a CLOSED bead must NEVER
#    be resurrected by the reconcile (the zombie / false-human-fork vector) ────
# A worker raised a fork (bfh resolved:false). The human then CLOSED the bead
# OUT OF BAND (closed the bead directly, never answered the dossier) — so the
# bfh record is STILL resolved:false. The PRE-FIX reconcile re-asserted
# status=blocked on that closed bead every ~30s (uxg1: zombied +18/+29s after
# two manual closes — a verified-done bead surfacing as "Brian must decide").
# The fix: a closed bead auto-closes the stale record instead of resurrecting it.
echo ""
echo "── claude-tools-2z14 — closed bead auto-closes the fork (no zombie) ──────────"
Z=stuck-closed-zombie
DIDZ="$(sr_route_stuck "$GOOD" "$Z" worker_stuck "$ASK_JSON" 2>/dev/null)"
eq   "zombie fixture: bead raised blocked-for-human"   "$(BDSTATUS "$Z")" "blocked"
eq   "zombie fixture: bfh raised, unresolved"          "$(BFHJQ "$Z" '.resolved')" "false"
# The human CLOSES the bead directly (terminal resolution; the dossier is never
# answered, so the bfh record stays resolved:false — the exact uxg1 shape).
printf 'closed' > "$BDST/$Z"
: > "$BD_LOG"   # capture only the reconcile's bd calls
nZ="$(sr_reconcile_blocked_for_human "$GOOD" "$Z" 2>/dev/null)"
eq   "reconcile acted on the closed bead's record"     "$nZ" "1"
eq   "CLOSED bead is NOT resurrected to blocked (stays closed — zombie killed)" \
       "$(BDSTATUS "$Z")" "closed"
ckn  "reconcile issued NO 'bd update --status=blocked' on the closed bead" \
       grep -q -- "update $Z --status=blocked" "$BD_LOG"
ckn  "stale bfh record hard-deleted (the fork is closed, work→control §7.9)" \
       sr_bfh_get "$Z"
# Re-run is a clean no-op — the record is gone, nothing to re-assert.
nZ2="$(sr_reconcile_blocked_for_human "$GOOD" "$Z" 2>/dev/null)"
eq   "reconcile idempotent after auto-close (re-run acts on 0 records)" "$nZ2" "0"
eq   "closed bead STAYS closed on re-run (no zombie resurrection)"      "$(BDSTATUS "$Z")" "closed"
# Defense-in-depth: the single work-plane drive chokepoint also refuses a closed
# bead — so no other current/future caller can resurrect it either.
sr_drive_bead_blocked "$Z" >/dev/null 2>&1 || true
eq   "sr_drive_bead_blocked refuses to drive a CLOSED bead to blocked" \
       "$(BDSTATUS "$Z")" "closed"
# PRESERVE the S-2 anti-Dolt-lag contract: a NON-closed (clobbered/lagged) bead
# is STILL re-asserted + its record KEPT — only `closed` short-circuits.
P=stuck-lagged-keep
DIDP="$(sr_route_stuck "$GOOD" "$P" worker_stuck "$ASK_JSON" 2>/dev/null)"
printf 'open' > "$BDST/$P"        # Dolt lag clobbered it back to open (not closed)
sr_reconcile_blocked_for_human "$GOOD" "$P" >/dev/null 2>&1 || true
eq   "non-closed lag STILL re-asserts blocked (S-2 anti-lag preserved)" \
       "$(BDSTATUS "$P")" "blocked"
ck   "non-closed bfh record KEPT (only a closed bead auto-closes — fork must not rot)" \
       sr_bfh_get "$P"

# ── claude-tools-d752 — CLOSE-HYGIENE: fold the stale work-plane "ask" ────────
# DEFENSE-IN-DEPTH companion to the §7.9 auto-close above. When the reconcile
# auto-closes a CLOSED forked bead's stale record, it ALSO folds the bead's
# work-plane ask (an idempotent marker note) so a LEGITIMATE later reopen + a
# fresh worker re-reading the body can't re-derive the SAME fork. (NOT the 2z14
# vector — that was a pure control-plane re-assert with no worker; this guards
# the OTHER, hypothetical reopen→re-read path the 2z14 description weighed.)
echo ""
echo "── claude-tools-d752 — closed bead's stale ask is FOLDED on auto-close ───────"
FOLD_HITS() {  # FOLD_HITS <tref> → count of fold-marker lines in the bead notes
  local f="$BDNOTES/$1" c
  [[ -f "$f" ]] || { echo 0; return 0; }
  c=$(grep -c -F -- "$SR_FOLD_MARKER" "$f" 2>/dev/null); [[ -n "$c" ]] || c=0
  echo "$c"
}
D=stuck-fold-on-close
DIDD="$(sr_route_stuck "$GOOD" "$D" worker_stuck "$ASK_JSON" 2>/dev/null)"
eq   "fold fixture: bead raised blocked-for-human"        "$(BDSTATUS "$D")" "blocked"
eq   "NOT folded while still LIVE (blocked, not closed)"  "$(FOLD_HITS "$D")" "0"
# The human CLOSES the bead out of band (the uxg1 shape) — then a reconcile.
printf 'closed' > "$BDST/$D"
sr_reconcile_blocked_for_human "$GOOD" "$D" >/dev/null 2>&1 || true
eq   "CLOSED bead's stale ask is FOLDED exactly once on auto-close" "$(FOLD_HITS "$D")" "1"
ckn  "the stale bfh record is STILL hard-deleted (2z14 unchanged)"  sr_bfh_get "$D"
eq   "fold never resurrects the bead (stays closed)"               "$(BDSTATUS "$D")" "closed"
# CRITICAL: the fold note must carry NO classify trigger token — else a reopened
# bead's §7.2/309l/gqyp net would read the fold ITSELF as a fresh ask (the very
# false fork this defends against).
ck   "fold note carries the greppable FORK marker"                grep -qF -- "$SR_FOLD_MARKER" "$BDNOTES/$D"
ckn  "fold note contains NO STUCK_NEEDS_HUMAN trigger token"      grep -qF -- "STUCK_NEEDS_HUMAN" "$BDNOTES/$D"
ckn  "fold note contains NO 'HUMAN DECISION NEEDED' trigger token" grep -qF -- "HUMAN DECISION NEEDED" "$BDNOTES/$D"
# Idempotent: a second fold pass (e.g. a re-trigger before the delete landed)
# never double-appends — the marker stays exactly once.
sr__fold_ask_on_close "$D" >/dev/null 2>&1 || true
eq   "re-fold is idempotent (marker count stays 1)"               "$(FOLD_HITS "$D")" "1"
# Negative: a NON-closed (lagged/clobbered) bead is NEVER folded — fold rides
# ONLY the §7.9 closed-bead branch, so a live fork's body is left intact ($P is
# the 2z14 anti-lag fixture above: re-asserted blocked, record kept, NOT closed).
eq   "non-closed lagged bead is NOT folded (fold rides closed-branch only)" "$(FOLD_HITS "$P")" "0"

# ── EXIT 5 — §7.4 DOSSIER-level (task_ref) DISTINCT from T5.3 per-Item latch ──
ne   "a DIFFERENT task_ref ⇒ an INDEPENDENT dossier id" \
       "$(sr_dossier_id_for other-fork)" "$DID1"
# sr_* is the dossier-level (task_ref) layer ONLY — it NEVER flips the per-Item
# consequence_applied latch (§7.4 per-Item key = Item id; T5.3's, orthogonal).
eq   "per-Item consequence_applied latch UNTOUCHED by sr_* (T5.3 boundary)" \
       "$(DJQ "$DIDH" '[.items[]?|select(.consequence_applied==true)]|length')" "0"
eq   "item moved open→answered by the substrate, NOT applied (T5.1 surface)" \
       "$(DJQ "$DIDH" '[.items[]?|select(.state=="answered")]|length')" "1"
# The §7.4 STRUCTURE rejects binding the SAME task_ref to a DIFFERENT dossier
# ("two triggers never make two dossiers" — the property sr_route_stuck's
# deterministic id stands on; proven directly against the T5.1 primitive).
ckn  "same task_ref → DIFFERENT id REJECTED by the dedup structure (§7.4)" \
       do_dedup_record "$GOOD" "$T" "some-other-dossier-id"
eq   "binding still points at the original Dossier (no overwrite)" \
       "$(do_dedup_get "$T" 2>/dev/null)" "$DID1"
# blocked-for-human is a T5-owned SIBLING namespace, NOT a §4 record type
# (absent from the T4 co__schema_version registry — §0/§11 if ever added).
eq   "blocked-for-human is NOT a §4 record type (no co__schema_version)" \
       "$(co__schema_version blocked-for-human 2>/dev/null)" ""

# ── stuck-restart (claude-tools-0wu) — wipe + re-run from scratch ────────────
# Distinct from sr_human_resolve: records NO decision; expires every still-open
# dossier item (open→expired); flips bfh so the next reconcile lifts the bead.
R=stuck-restart-bead
DIDR="$(sr_route_stuck "$GOOD" "$R" worker_stuck "$ASK_JSON" 2>/dev/null)"
ck   "stuck-restart fixture: bfh raised + Dossier authored" test -n "$DIDR"
eq   "before restart: Item is open (the worker_stuck pick-option)" \
       "$(DJQ "$DIDR" '[.items[]?|select(.state=="open")]|length')" "1"
ck   "sr_stuck_restart returns ok"                       sr_stuck_restart "$GOOD" "$R"
eq   "still-open Item moved to expired (Option A — no answered/applied)" \
       "$(DJQ "$DIDR" '[.items[]?|select(.state=="expired")]|length')" "1"
eq   "NO Item moved to answered (no decision recorded — distinct from stuck-resolve)" \
       "$(DJQ "$DIDR" '[.items[]?|select(.state=="answered")]|length')" "0"
eq   "bfh now resolved (next reconcile will lift the bead)" \
       "$(BFHJQ "$R" '.resolved')" "true"
# A second restart is idempotent — the already-expired Item is untouched
# (the state machine forbids expired→expired), and the already-resolved bfh
# flip is a no-op. The op returns ok.
ck   "sr_stuck_restart is idempotent (re-run ⇒ ok)"     sr_stuck_restart "$GOOD" "$R"
eq   "expired Item count unchanged after idempotent re-run" \
       "$(DJQ "$DIDR" '[.items[]?|select(.state=="expired")]|length')" "1"
# Next reconcile lifts the bead + hard-deletes the bfh (the canonical S-2 leg).
n3="$(sr_reconcile_blocked_for_human "$GOOD" "$R" 2>/dev/null)"
eq   "reconcile acted on the restart-flipped record"    "$n3" "1"
eq   "stuck-restart + reconcile ⇒ bead UNBLOCKED for re-pick" \
       "$(BDSTATUS "$R")" "open"
ckn  "stuck-restart + reconcile ⇒ bfh record hard-deleted" sr_bfh_get "$R"

# stuck-restart on an unsafe / missing task_ref ⇒ rejected; absent bfh ⇒ ok.
ckn  "stuck-restart rejects unsafe task_ref"            sr_stuck_restart "$GOOD" "../escape"
ck   "stuck-restart on a never-stuck task_ref ⇒ ok no-op" \
                                                          sr_stuck_restart "$GOOD" "never-stuck-fork"

# ── claude-tools-uxvl1 (inbox-lifecycle §5) — DISMISS-AS-STALE must NOT
#    auto-re-dispatch. DISTINCT from stuck-restart: the human taps "Dismiss as
#    stale" on the Inbox → /api/inbox/expire → item-set-state expired. That
#    expires the Item but does NOT touch the S-2 bfh record (it stays
#    resolved:false). The dossier then rolls up `resolved` (all Items terminal),
#    but there is NO answered/applied human DECISION to resume WITH. sr_poll
#    MUST keep the fork PARKED — never fall back to the expired Item and flip
#    S-2 / re-dispatch the worker with an empty "Raw response (§5.2): {}" (the
#    §5 live P1). bfh staying resolved:false is the gate that prevents the
#    reconcile from lifting the bead, so the worker is never re-dispatched.
echo ""
echo "── claude-tools-uxvl1 — dismiss-as-stale parks the fork (no false resume) ──"
DSM=stuck-dismiss-bead
DIDM="$(sr_route_stuck "$GOOD" "$DSM" worker_stuck "$ASK_JSON" 2>/dev/null)"
ck   "dismiss fixture: bfh raised + Dossier authored"   test -n "$DIDM"
eq   "before dismiss: fork parked (bfh resolved:false)" "$(BFHJQ "$DSM" '.resolved')" "false"
IIDM="$(DJQ "$DIDM" '.items[0].id')"
# the human taps "Dismiss as stale" — the §4.1 open→expired terminal, NO bfh flip
do_item_set_state "$GOOD" "$DIDM" "$IIDM" expired >/dev/null
eq   "every Item expired (the dismiss)" \
       "$(DJQ "$DIDM" '[.items[]?|select(.state=="expired")]|length')" "1"
eq   "dossier rolls up resolved (all Items terminal)" \
       "$(do_dossier_rollup "$(GET "$DIDM")" 2>/dev/null)" "resolved"
nDM="$(sr_poll_hosted_resolution "$GOOD" "$DSM" 2>/dev/null)"
eq   "poll reports ZERO newly-resolved forks (a dismiss ≠ a decision)" "${nDM:-x}" "0"
eq   "fork STAYS parked (bfh resolved:false — no false resume / no re-dispatch)" \
       "$(BFHJQ "$DSM" '.resolved')" "false"
ckn  "NO resume-answer captured (a dismiss carries no decision to resume WITH)" \
       sr_resume_answer "$DSM"

# ── claude-tools-1xx1 — a DISMISSED fork must STOP the per-poll hosted re-read.
#    After the uxvl1 fix the dismissed fork stays PARKED (good), but the poll was
#    still doing one hosted do_dossier_get on its all-expired Dossier EVERY poll
#    (~30s) forever (an unbounded low-rate hosted read, accumulating per
#    dismissal). The fix: the first poll above writes a one-shot DISMISSED
#    sentinel; the NEXT poll SKIPS the hosted read — WITHOUT flipping S-2 (a
#    resolve would re-open the uxvl1 false-resume bug).
echo ""
echo "── claude-tools-1xx1 — dismissed fork stops the per-poll hosted re-read ─────"
ck   "first poll wrote a one-shot DISMISSED sentinel" \
       test -f "$(sr__dismissed_dir)/$DSM.json"
# Spy on do_dossier_get to PROVE the 2nd poll does ZERO hosted reads for the
# dismissed fork: rename the real fn, wrap it with a byte-counter, restore after.
DDG_SPY="$WORK/ddg-spy"; : > "$DDG_SPY"
eval "_orig_ddg_spy() $(declare -f do_dossier_get | tail -n +2)"
do_dossier_get() { printf 'x' >> "$DDG_SPY"; _orig_ddg_spy "$@"; }
nDM2="$(sr_poll_hosted_resolution "$GOOD" "$DSM" 2>/dev/null)"
unset -f do_dossier_get
eval "do_dossier_get() $(declare -f _orig_ddg_spy | tail -n +2)"
unset -f _orig_ddg_spy
eq   "2nd poll did ZERO hosted do_dossier_get reads (sentinel skip)" \
       "$(wc -c < "$DDG_SPY" | tr -d ' ')" "0"
eq   "2nd poll still reports ZERO newly-resolved forks" "${nDM2:-x}" "0"
eq   "fork STILL parked after the skip (bfh resolved:false — no false resume)" \
       "$(BFHJQ "$DSM" '.resolved')" "false"
ckn  "STILL no resume-answer captured (the skip carries no decision)" \
       sr_resume_answer "$DSM"
# A NOT-YET-ANSWERED fork (an Item still open) must NOT be sentinel'd — the poll
# must keep observing it. A fresh fork with an open Item: no sentinel after poll.
PND=stuck-pending-bead
DIDP="$(sr_route_stuck "$GOOD" "$PND" worker_stuck "$ASK_JSON" 2>/dev/null)"
eq   "pending fixture: the Item is still open" \
       "$(DJQ "$DIDP" '[.items[]?|select(.state=="open")]|length')" "1"
sr_poll_hosted_resolution "$GOOD" "$PND" >/dev/null 2>&1
ckn  "a NOT-YET-ANSWERED fork is NOT sentinel'd (poll keeps observing it)" \
       test -f "$(sr__dismissed_dir)/$PND.json"
# An item-LESS Dossier rolls up `open` (NOT terminal — §4.1.1; items[] MAY be
# empty), so a parked fork whose Dossier has ZERO Items must KEEP polling and
# must NEVER be mistaken for a dismiss. Stub do_dossier_get to hand back an
# extant-but-item-less Dossier for this fork and assert no sentinel is written.
ZI=stuck-zeroitem-bead
ZIDID="$(sr_dossier_id_for "$ZI")"
sr__raise_bfh "$GOOD" "$ZI" "$ZIDID" worker_stuck >/dev/null 2>&1
eval "_orig_ddg_zi() $(declare -f do_dossier_get | tail -n +2)"
do_dossier_get() { if [[ "${2:-}" == "$ZIDID" ]]; then printf '%s' '{"items":[]}'; return 0; fi; _orig_ddg_zi "$@"; }
sr_poll_hosted_resolution "$GOOD" "$ZI" >/dev/null 2>&1
unset -f do_dossier_get
eval "do_dossier_get() $(declare -f _orig_ddg_zi | tail -n +2)"
unset -f _orig_ddg_zi
ckn  "an item-LESS Dossier is NOT mistaken for a dismiss (no sentinel ⇒ keep polling)" \
       test -f "$(sr__dismissed_dir)/$ZI.json"
eq   "item-less fork stays parked (bfh resolved:false)" "$(BFHJQ "$ZI" '.resolved')" "false"
# Closing the dismissed bead out of band sweeps BOTH the bfh record AND the
# sentinel (no orphan accumulation — the §7.9 / claude-tools-2z14 close branch).
printf '%s' "closed" > "$BDST/$DSM"
nDMc="$(sr_reconcile_blocked_for_human "$GOOD" "$DSM" 2>/dev/null)"
eq   "reconcile auto-closed the dismissed fork's record"  "$nDMc" "1"
ckn  "closed bead ⇒ bfh record swept"                     sr_bfh_get "$DSM"
ckn  "closed bead ⇒ DISMISSED sentinel swept too (no orphan)" \
       test -f "$(sr__dismissed_dir)/$DSM.json"
# A FRESH fork on a task_ref that was previously dismissed must start CLEAN: the
# stale sentinel is cleared at raise time so the poll observes the new answer.
RF=stuck-refork-bead
RFDID="$(sr_dossier_id_for "$RF")"
mkdir -p "$(sr__dismissed_dir)" 2>/dev/null
printf '%s' '{"task_ref":"stuck-refork-bead","dossier_id":"x","dismissed_at":"t"}' > "$(sr__dismissed_dir)/$RF.json"
sr_route_stuck "$GOOD" "$RF" worker_stuck "$ASK_JSON" >/dev/null 2>&1
ckn  "a FRESH fork clears the stale DISMISSED sentinel at raise (re-fork starts clean)" \
       test -f "$(sr__dismissed_dir)/$RF.json"

# ── claude-tools-uxvl5 (inbox-lifecycle §4.4) — READABILITY GATE on the
#    deterministic fallback template + the residual no_DG_AUTHOR_CMD jargon bug.
#    When the dossier-builder agent is unreachable, sr_worker_ask's raw material
#    IS the dossier Brian reads cold on his phone (the jq fallback lifts its
#    tldr/ask/options straight into the §5 body). The OLD text shipped contract
#    jargon — "slipped past the §7.6 guardrail", "blocked-for-human", "(§5.3 =
#    T5.3)" — exactly the claude-tools-7xl defect. This is the failing-THEN-
#    fixed assertion: dg__readability_lint FLAGS the old text and PASSES both
#    the current sr_worker_ask AND the full dossier it generates.
echo ""
echo "── claude-tools-uxvl5 — readability gate on the fallback template ──────────"
# (a) FAILING half — the pre-fix sr_worker_ask jargon, captured verbatim, MUST trip the lint.
OLD_FALLBACK='{"tldr":"A backstop fired on claude-tools-7xl: the worker reached an interactive fork it must not resolve and slipped past the §7.6 guardrail.","ask":"How should the runner proceed on claude-tools-7xl (a human-decision fork)?","options":[{"option_id":"resume","label":"resume","blast_radius":"Re-queues the task as-is once a human resolves the fork."},{"option_id":"abandon","label":"abandon","blast_radius":"Leaves the bead blocked-for-human pending a human re-scope."}],"recommendation":{"value":"resume","why":"resume once decided (§7.5 retry-exempt)."},"reversible":"Fully reversible — no consequence is applied until a human picks an option (§5.3 = T5.3)."}'
ckn  "readability lint FLAGS the OLD fallback jargon (§ / contract-IDs / state tokens)" \
       dg__readability_lint "$OLD_FALLBACK"
# (b) FIXED half — the current sr_worker_ask raw material passes the same lint.
ck   "readability lint PASSES the current sr_worker_ask raw material" \
       dg__readability_lint "$(sr_worker_ask "$T")"
# (c) and the FULL worker_stuck dossier it generates (tldr + sections + diagram
#     caption + full_detail + every item field) passes too — the deterministic
#     fallback (DG_AUTHOR_CMD unset in this harness) is what authored it here.
RD_DID="$(sr_dossier_id_for readability-fork)"
dg_from_worker_ask "$GOOD" "$RD_DID" readability-fork "$(sr_worker_ask readability-fork)" >/dev/null 2>&1
ck   "readability lint PASSES the full generated worker_stuck dossier" \
       dg__readability_lint "$(GET "$RD_DID")"

echo ""
echo "── stuck-routing: $PASS passed, $FAIL failed ────────────────────────────"
[[ $FAIL -eq 0 ]] && { echo "ALL GREEN"; exit 0; } || { echo "RED"; exit 1; }
