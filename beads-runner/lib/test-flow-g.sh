#!/bin/bash
# beads-runner/lib/test-flow-g.sh — the Flow-G CHAIN regression gate
# (claude-tools-uxg4, GAP G4).
#
# WHY THIS EXISTS (the "preserve" task): the C-shell migration (claude-tools-uxvsh)
# rebuilt the nav into 5 global + 4 workspace facets, and NO facet is
# Failure/Forensic. The progressive-disclosure failure view built in
# claude-tools-xre (Glance → Summary → Forensic, redacted-remote) therefore lives
# in the Board glance (deep-link) + the Inbox SPA target — a CROSS-FILE chain that
# could vanish in the migration with NO failing test. test-board.sh and
# test-inbox.sh each pin their OWN component; nothing pinned the SEAM between them
# (the deep-link target the Board emits must equal the route the Inbox parses, and
# the v2 workspace Board FACET must carry that glance forward). This test pins the
# whole chain so any future refactor that severs it goes RED.
#
# It is the §4 Flow-G + principle-7 ("surface silent failures loudest") gate. It
# is its OWN focused test (anti-drift: touches no sibling test); the minor overlap
# with test-inbox.sh's forensic round-trip is deliberate — the redacted-remote
# forensic store IS the terminus of this chain, and "verify the redacted-remote
# forensic path still resolves" is the literal G4 deliverable, run live here.
#
# Drives the REAL producer (coordinator.sh co__work_snapshot) + the REAL forensic
# store (forensic-put/fetch/dismiss) so the seam is asserted against the FROZEN
# contract, never a hand-faked shape. View-model files are exercised in Node;
# the browser GLUE (which has no headless DOM) is pinned STRUCTURALLY — the same
# discipline test-inbox.sh uses for app.js.
#
# THE CHAIN (each PART is one link; a break in any link goes RED):
#   A  GLANCE model — board-view.js emits the §4.5 failure glance + the
#      /inbox#/f/<ref> deep-link + the loud/silent split (principle 7).
#   B  GLANCE wiring — the v2 workspace Board FACET (workspace/app.js) AND the
#      global Board (board/app.js) carry that glance + deep-link into the DOM,
#      reusing the ONE model (no forked failure logic).
#   C  TARGET resolves — shell.js route shape + _redirects + the Inbox SPA
#      #/f/<ref> route AGREE with the href the Board emits (the cross-file seam).
#   D  SUMMARY + FORENSIC — deriveFailureView renders tiers 1–2, and the
#      redacted-remote forensic path (proxy + store round-trip) still resolves.
#
# Self-contained: its own CO_STORE under mktemp; shares no state with siblings.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/coordinator.sh"
BOARD_VIEW="$HERE/../web/board/board-view.js"
INBOX_VIEW="$HERE/../web/inbox/inbox-view.js"
SHELL_JS="$HERE/../web/shared/shell.js"
WS_APP="$HERE/../web/workspace/app.js"
B_APP="$HERE/../web/board/app.js"
INBOX_APP="$HERE/../web/inbox/app.js"
P_FOR="$HERE/../web/functions/api/inbox/forensic.js"
REDIR="$HERE/../web/_redirects"
for f in "$LIB" "$BOARD_VIEW" "$INBOX_VIEW" "$SHELL_JS" "$WS_APP" "$B_APP" "$INBOX_APP" "$P_FOR" "$REDIR"; do
  [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Flow-G chain test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
ckok(){ if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; } # passes iff the cmd SUCCEEDS
ckno(){ if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; } # passes iff the cmd FAILS
eq()    { [[ "$1" == "$2" ]]; }
nz()    { [[ -n "$1" && "$1" != "null" ]]; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
jqr()   { jq -r "$2" <<<"$1" 2>/dev/null; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 STALE_AFTER USAGE_THRESHOLD 2>/dev/null || true
# shellcheck source=/dev/null
source "$LIB"
GOOD="bearer-runner-secret-xyz"

# Pipe a §4.5 projection through the PURE Board renderer.
render() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const BV=require(process.argv[1]); let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(BV.deriveBoardView(snap)));
  });' "$BOARD_VIEW"; }
# Call an inbox-view.js / shell.js export with JSON args; print its JSON return.
ivcall() { node -e '
  const V=require(process.argv[1]); const fn=process.argv[2];
  const a=process.argv.slice(3).map(s=>{try{return JSON.parse(s);}catch(e){return s;}});
  process.stdout.write(JSON.stringify(V[fn].apply(null,a)));' "$@"; }
iv() { ivcall "$INBOX_VIEW" "$@"; }
sh() { ivcall "$SHELL_JS" "$@"; }

# A real §4.5 projection with two failing cards — one SILENT (TASK_NOT_CLOSED,
# "looked green but isn't"), one LOUD (WATCHDOG_KILL) — plus a healthy card.
BEADS="$(jq -cn '[
  {bead_ref:"claude-tools-91",title:"silent rotter",stage:"impl",priority:2,age:"1h",
   failure:{class:"TASK_NOT_CLOSED",retry_state:"-",runner_notes:["exited 0 but left the bead open"]}},
  {bead_ref:"claude-tools-77",title:"loud kill",stage:"tests",priority:1,age:"2h",
   failure:{class:"WATCHDOG_KILL",retry_state:"2/3",runner_notes:["watchdog kill @attempt2"]}},
  {bead_ref:"claude-tools-12",title:"healthy idea",stage:"idea",priority:3,age:"5m"}
]')"
SNAP="$(co_request "$GOOD" work-snapshot "" "$BEADS" 2>/dev/null)"
# A SECOND snapshot with a §10 forensic STREAM injected into the silent card
# AFTER the producer has run. The producer's normalize_failure allowlist already
# strips stream/blob fields, so injecting at the bead level would prove nothing
# (the renderer would never see them). Injecting POST-producer (the test-board.sh
# idiom) puts the RENDERER + the view-model under test for the §10 boundary: a
# dossier the producer somehow let through MUST still be dropped at render.
CANARY="FORENSIC-LEAK-CANARY-g4"
SNAP_CANARY="$(jq -c --arg c "$CANARY" \
  '.lifecycle_columns.impl[0].failure.forensic_blob=$c
 | .lifecycle_columns.impl[0].failure.stream_json=$c' <<<"$SNAP")"
V="$(render "$SNAP")"
FCARD='[.lifecycle[].cards[]|select(.bead_ref=="claude-tools-91")][0]'
LCARD='[.lifecycle[].cards[]|select(.bead_ref=="claude-tools-77")][0]'

echo "── PART A: GLANCE — board-view.js emits the §4.5 failure glance + deep-link ──"
ck "renderer accepts the real §4.5 projection (ok:true)"          eq "$(jqr "$V" .ok)" "true"
ck "a failing card carries the Flow-G class badge (tier-1)"        has "TASK_NOT_CLOSED" "$(jqr "$V" "$FCARD.failure.badge")"
# THE deep-link target — the single most regression-prone seam. board-view.js
# MUST emit /inbox#/f/<bead_ref>; nothing pinned this before G4.
ck "failing card deep-links to the Inbox failure view (/inbox#/f/<ref>)" \
   eq "$(jqr "$V" "$FCARD.failure.failure_href")" "/inbox#/f/claude-tools-91"
ck "the silent class is flagged silent (principle 7)"             eq "$(jqr "$V" "$FCARD.failure.silent")" "true"
ck "the silent badge says 'silent' (loudest at a glance)"         has "silent" "$(jqr "$V" "$FCARD.failure.badge")"
ck "a LOUD class is NOT flagged silent (honest split)"            eq "$(jqr "$V" "$LCARD.failure.silent")" "false"
ck "the loud card ALSO deep-links to its failure view"            eq "$(jqr "$V" "$LCARD.failure.failure_href")" "/inbox#/f/claude-tools-77"
# The health strip splits loud vs silent and gives silent the LOUDER chip kind.
ck "health strip counts ≥1 silent failure"                        eq "$(jqr "$V" '.health.silent_failures>=1')" "true"
ck "health strip counts ≥1 loud failure"                          eq "$(jqr "$V" '.health.loud_failures>=1')" "true"
ck "the silent strip chip is kind:'bad' (louder than loud's warn)" \
   eq "$(jqr "$V" '[.health.tags[]|select(.kind=="bad" and (.text|test("silent")))]|length>=1')" "true"
# §10 boundary inside the glance: a forensic STREAM injected into the card AFTER
# the producer ran MUST be dropped by the renderer (it maps only §4.5 allowlisted
# failure fields — class/retry/silent/notes — never the tier-3 stream).
VF="$(render "$SNAP_CANARY")"
ck "a §10 forensic STREAM in a card is DROPPED by the renderer (boundary holds)" \
   hasnt "$CANARY" "$VF"
ck "the Flow-G class STILL surfaces after the stream is dropped (not all-or-nothing)" \
   has "TASK_NOT_CLOSED" "$(jqr "$VF" "$FCARD.failure.badge")"

echo "── PART B: GLANCE WIRING — the v2 app-shell glue carries glance + deep-link ──"
# The v2 WORKSPACE BOARD FACET (the surface the migration created). It must reuse
# the ONE model and carry the glance + deep-link into the DOM — not silently drop
# them. Structural, like test-inbox.sh's app.js checks (no headless DOM).
ck "workspace facet REUSES BoardView.deriveBoardView (no forked failure model)" \
   has "BoardView.deriveBoardView" "$(cat "$WS_APP")"
ck "workspace facet renders the failure deep-link (card.failure.failure_href)" \
   has "card.failure.failure_href" "$(cat "$WS_APP")"
ck "workspace facet marks a failing card (failbead class — glance visible)" \
   has "failbead" "$(cat "$WS_APP")"
# Grep the CODE token (card.failure.silent), not the bare word 'silent', which
# also appears in prose comments and would false-green if the code line is cut.
ck "workspace facet marks silent failures LOUDER (reads card.failure.silent)" \
   has "card.failure.silent" "$(cat "$WS_APP")"
# The global Board glue must keep the SAME deep-link + glance affordances.
ck "global board renders the failure deep-link (card.failure.failure_href)" \
   has "card.failure.failure_href" "$(cat "$B_APP")"
ck "global board marks a failing card (failbead class)" \
   has "failbead" "$(cat "$B_APP")"
ck "global board marks silent failures LOUDER (reads card.failure.silent)" \
   has "card.failure.silent" "$(cat "$B_APP")"

echo "── PART C: TARGET RESOLVES — the deep-link chain is consistent end-to-end ──"
# shell.js route shape: the /ws/<ref>/board facet the glance lives in resolves.
WP="$(sh parseWorkspacePath "/ws/projA/board")"
ck "shell parses /ws/<ref>/board → ref"                           eq "$(jqr "$WP" .ref)" "projA"
ck "shell parses /ws/<ref>/board → facet"                         eq "$(jqr "$WP" .facet)" "board"
ck "shell falls back to the board facet for an unknown facet"     eq "$(jqr "$(sh parseWorkspacePath "/ws/projA/bogus")" .facet)" "board"
# The premise the task names: NO workspace facet is Failure/Forensic — so the
# glance MUST deep-link OUT of the Board into the Inbox. Pin the facet set so a
# future "add a Failure facet" change is a conscious edit, not an accident.
NAV="$(sh deriveNav '{"workspace":{"ref":"projA","facet":"board"}}')"
ck "the 4 workspace facets are exactly board,blueprint,activity,gates" \
   eq "$(jqr "$NAV" '[.workspace.tabs[].key]|join(",")')" "board,blueprint,activity,gates"
ck "NO facet is Failure/Forensic (glance must deep-link out of Board)" \
   eq "$(jqr "$NAV" '[.workspace.tabs[]|select(.key=="failure" or .key=="forensic")]|length')" "0"
# _redirects resolves the two routes the chain crosses: /inbox and /ws/*.
ck "_redirects maps the /inbox global route"                      has "/inbox " "$(cat "$REDIR")"
ck "_redirects maps the /ws/* workspace-facet catch-all"          has "/ws/*" "$(cat "$REDIR")"
# The Inbox SPA is the deep-link TARGET. The cross-file seam is "the href the
# Board emits == the route the Inbox parses". PART A pinned the Board half
# behaviorally (it emits exactly /inbox#/f/claude-tools-91). Here we EXECUTE the
# Inbox half: run the inbox route regex on that exact href and prove it extracts
# the bead_ref — so the seam is verified end-to-end, not by two independent greps.
SEAM_HREF="/inbox#/f/claude-tools-91"  # the exact value PART A proved board-view emits
SEAM_REF="$(node -e 'var hash=process.argv[1].split("#")[1]||""; var m=hash.match(/^\/f\/(.+)$/); process.stdout.write(m?m[1]:"");' "$SEAM_HREF")"
ck "the #/f/ route regex EXTRACTS the bead_ref from the board-emitted href (seam executes)" \
   eq "$SEAM_REF" "claude-tools-91"
ck "Inbox SPA uses that exact route regex literal (so the seam can't drift)" \
   has '/^\/f\/(.+)$/' "$(cat "$INBOX_APP")"
ck "Inbox SPA routes #/f/ to loadFailure (the failure-view handler)" \
   has "loadFailure(m[1])" "$(cat "$INBOX_APP")"
ck "Inbox SPA fetches the redacted forensic log from the proxy"   has "/api/inbox/forensic" "$(cat "$INBOX_APP")"

echo "── PART D: SUMMARY + FORENSIC — tiers 2–3 + the redacted-remote path resolve ──"
FV="$(iv deriveFailureView "$SNAP" '"claude-tools-91"')"
ck "deriveFailureView resolves for a real failing bead (ok:true)" eq "$(jqr "$FV" .ok)" "true"
ck "GLANCE: human-worded class plain (tier-1)"                    nz "$(jqr "$FV" .glance.class_plain)"
ck "SUMMARY: the Runner: note timeline is surfaced (tier-2, §4.5)" \
   has "left the bead open" "$(jqr "$FV" '.summary.runner_notes|join(" ")')"
ck "SUMMARY: a silent failure is flagged louder (principle 7)"    eq "$(jqr "$FV" .summary.silent)" "true"
ck "SUMMARY: silent failures carry the louder note"               nz "$(jqr "$FV" .summary.silent_note)"
ck "FORENSIC: tier-3 is an ON-DEMAND affordance, never auto-fetched (§10.3)" \
   eq "$(jqr "$FV" '.forensic.available and (.forensic.fetched|not)')" "true"
# Boundary: a stream injected POST-producer (SNAP_CANARY) must be dropped by the
# view-model too — $FV above came from the clean SNAP and would pass trivially.
FVC="$(iv deriveFailureView "$SNAP_CANARY" '"claude-tools-91"')"
ck "FORENSIC: no raw stream inline in the failure view (the §10 boundary holds)" \
   hasnt "$CANARY" "$FVC"
# The redacted-remote forensic STORE round-trip — the literal G4 deliverable
# ("verify the redacted-remote forensic path still resolves"). The PUT is
# exit-checked (not fire-and-forget) so a fail-closed store surfaces as RED here
# rather than masquerading as a successful DISMISS below.
RED='{"redacted":true,"tool_use":["Read(x.ts)"],"errors":["WATCHDOG_KILL"],"last_turn":"…"}'
ckok "redacted forensic blob PUT into the store succeeds (§10.3)" \
   co_request "$GOOD" forensic-put fb-g4 dRT "$RED"
ck "redacted-remote FETCH resolves the on-demand blob (§10.3)"    has "redacted" "$(co_request "$GOOD" forensic-fetch fb-g4 2>/dev/null)"
co_request "$GOOD" forensic-dismiss fb-g4 >/dev/null 2>&1
ckno "DISMISS hard-deletes the blob — gone, irrecoverable, no tombstone (§10.3)" \
   co_request "$GOOD" forensic-fetch fb-g4
# The forensic PROXY keeps the §9.1 chokepoint that makes the path authed-only.
ck "forensic proxy pins forensic-fetch + forensic-dismiss (2 ops)" \
   eq "$(grep -c "= 'forensic-" "$P_FOR")" "2"
ck "forensic proxy exports BOTH GET+POST only (no put/sweep client op)" \
   eq "$(grep -c 'export async function onRequest' "$P_FOR")" "2"
ck "forensic proxy exposes NO client-side forensic-put"           hasnt "'forensic-put'" "$(cat "$P_FOR")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-flow-g (claude-tools-uxg4, GAP G4):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
