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
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 2>/dev/null || true

# ── work-plane `bd` fake on PATH — STATEFUL status + human log ───────────────
# Tracks per-id status under $BDST/<id> so a blocked→open clobber (the
# simulated Dolt lag) and the reconcile's re-assert/lift are OBSERVABLE; logs
# every `bd human <id>` to $BD_HUMAN (one id per line). Fail-open like real bd.
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export BDST="$WORK/bdst"; mkdir -p "$BDST"
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
    jq -cn --arg id "$id" --arg s "$s" '[{id:$id,status:$s}]' ;;
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
