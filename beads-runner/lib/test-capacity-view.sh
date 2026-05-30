#!/bin/bash
# beads-runner/lib/test-capacity-view.sh — focused unit test for the C-shell
# CAPACITY global view (unit label: capacity-view; UX-DESIGN-V2 §2.1/§2.2).
#
# Mirrors lib/test-board.sh's technique: a node `require` of the PURE view-model
# (web/capacity/capacity-view.js), fed a hand-crafted §4.5 work-snapshot fixture,
# asserting the derived model. Lives OUTSIDE the deployed web/ dir (here in lib/).
#
# Asserts the unit contract:
#   • ok:true on a good snapshot carrying machines[]
#   • machines_empty:true on machines:[]  (the §3.C "no telemetry yet" banner)
#   • band 'red' when pct ≥ threshold; 'green' when pct < half-threshold (§4.B,
#     logically identical to board-view.js deriveMachine — Capacity & Board agree)
#   • ok:false on schema_version:99 (§0.3 — never best-effort-render the future)
#   • modes length matches projects[]
# Plus the honesty edges the unit owns: <allowed> mirror, gate-disabled neutral,
# stale grayed, missing-field degrade, and a stale runner never reading as a
# live mode (S-1 / principle 4).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW="$HERE/../web/capacity/capacity-view.js"
[[ -f "$VIEW" ]] || { echo "FATAL: capacity-view.js not found at $VIEW"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required for the Capacity view test"; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for assertions"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
has()   { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
hasnt() { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()    { [[ "$1" == "$2" ]]; }
nz()    { [[ -n "$1" ]]; }

# Pipe an arbitrary snapshot object through the PURE view-model, emit the view.
derive() { printf '%s' "$1" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const CV=require(process.argv[1]);
    let snap; try{snap=JSON.parse(s);}catch(e){snap=s;}
    process.stdout.write(JSON.stringify(CV.deriveCapacityView(snap, Date.now())));
  });' "$VIEW"; }

# A good §4.5 snapshot: threshold=70 ⇒ half-threshold=35.
#   m1 alpha: pct_5h=10 (<35 ⇒ green), pct_7d=90 (≥70 ⇒ red), fresh, gate on.
#   m2 zeta : pct_5h=82 (≥70 ⇒ red),  pct_7d=20 (<35 ⇒ green), fresh, gate on.
# Two projects ⇒ modes length must be 2; one live+matching, one live+mismatch.
GOOD='{
  "schema_version":1,"principal":"PRINCIPAL_V1","read_only":true,
  "projects":[
    {"project_ref":"projA","runner_state":{"liveness":"live","actual":"running","desired":"running","desired_actual_mismatch":false}},
    {"project_ref":"projB","runner_state":{"liveness":"live","actual":"running","desired":"stopped","desired_actual_mismatch":true}}
  ],
  "waiting_on_you":[],
  "lifecycle_columns":{},
  "machines":[
    {"runner_id":"alpha-host","observed_at":"2026-05-29T06:00:00Z","pct_5h":10,"pct_7d":90,"spare_ramp_today":56,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":42},
    {"runner_id":"zeta-host","observed_at":"2026-05-29T06:00:00Z","pct_5h":82,"pct_7d":20,"spare_ramp_today":56,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":12}
  ]
}'

echo "── EXIT-1: a good snapshot with machines derives ok:true ──"
V="$(derive "$GOOD")"
ck "deriveCapacityView returns ok:true on a good snapshot"        eq "$(jq -r '.ok' <<<"$V")" "true"
ck "schema_version surfaced (1)"                                  eq "$(jq -r '.schema_version' <<<"$V")" "1"
ck "principal surfaced"                                           eq "$(jq -r '.principal' <<<"$V")" "PRINCIPAL_V1"
ck "machines_empty is false when rows present"                    eq "$(jq -r '.machines_empty' <<<"$V")" "false"
ck "two machine rows present"                                     eq "$(jq -r '.machines|length' <<<"$V")" "2"
ck "row 0 runner_id surfaced verbatim"                            eq "$(jq -r '.machines[0].runner_id' <<<"$V")" "alpha-host"
ck "row 0 pct_5h_text formatted '10%'"                            eq "$(jq -r '.machines[0].pct_5h_text' <<<"$V")" "10%"
ck "row 0 pct_7d_text formatted '90%'"                            eq "$(jq -r '.machines[0].pct_7d_text' <<<"$V")" "90%"
ck "row 0 ramp_text formatted '56%'"                              eq "$(jq -r '.machines[0].ramp_text' <<<"$V")" "56%"
ck "row 0 observed age uses age_seconds (42s)"                    eq "$(jq -r '.machines[0].age_text' <<<"$V")" "42s"

echo "── EXIT-2: §4.B bands — red when pct ≥ threshold, green below half ──"
# threshold=70 ⇒ half=35.  alpha: 5h=10<35 green, 7d=90≥70 red.
ck "alpha pct_5h band green (10 < 35 = 0.5×70)"                   eq "$(jq -r '.machines[0].pct_5h_band' <<<"$V")" "green"
ck "alpha pct_7d band red (90 ≥ 70)"                              eq "$(jq -r '.machines[0].pct_7d_band' <<<"$V")" "red"
# zeta: 5h=82≥70 red, 7d=20<35 green.
ck "zeta pct_5h band red (82 ≥ 70)"                               eq "$(jq -r '.machines[1].pct_5h_band' <<<"$V")" "red"
ck "zeta pct_7d band green (20 < 35)"                             eq "$(jq -r '.machines[1].pct_7d_band' <<<"$V")" "green"
ck "ramp band is neutral (§4.B only bands pct_<n>)"               eq "$(jq -r '.machines[0].ramp_band' <<<"$V")" "neutral"
# Amber middle band: pct in [35,70). Craft an amber row to prove the third band.
AMBER_SNAP="$(jq -c '.machines=[{"runner_id":"amber-host","observed_at":"x","pct_5h":50,"pct_7d":50,"spare_ramp_today":99,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":5}]' <<<"$GOOD")"
VA="$(derive "$AMBER_SNAP")"
ck "amber band when 0.5×T ≤ pct < T (50 ∈ [35,70))"               eq "$(jq -r '.machines[0].pct_5h_band' <<<"$VA")" "amber"

echo "── EXIT-3: <allowed> mirrors daemon _usage_poll_compute_allowed ──"
# alpha pct_7d=90 ≥ T=70 ⇒ over ⇒ '(none — over)'.
ck "alpha over the cap ⇒ allowed '(none — over)'"                 eq "$(jq -r '.machines[0].allowed_text' <<<"$V")" "(none — over)"
# A row under T with pct_7d ≥ spare_ramp ⇒ 'standard' only.
SR_SNAP="$(jq -c '.machines=[{"runner_id":"sr","observed_at":"x","pct_5h":30,"pct_7d":50,"spare_ramp_today":40,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":5}]' <<<"$GOOD")"
VSR="$(derive "$SR_SNAP")"
ck "pct_7d ≥ spare_ramp (under T) ⇒ allowed 'standard'"           eq "$(jq -r '.machines[0].allowed_text' <<<"$VSR")" "standard"
# Comfortably under both ⇒ both classes allowed.
LO_SNAP="$(jq -c '.machines=[{"runner_id":"lo","observed_at":"x","pct_5h":5,"pct_7d":5,"spare_ramp_today":90,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":5}]' <<<"$GOOD")"
ck "under ramp & threshold ⇒ allowed 'standard,low_priority'"     eq "$(jq -r '.machines[0].allowed_text' <<<"$(derive "$LO_SNAP")")" "standard,low_priority"

echo "── EXIT-4: machines_empty true on machines:[] (§3.C banner, no phantom ok) ──"
EMPTY_SNAP="$(jq -c '.machines=[]' <<<"$GOOD")"
VE="$(derive "$EMPTY_SNAP")"
ck "empty machines ⇒ ok:true (the read succeeded)"               eq "$(jq -r '.ok' <<<"$VE")" "true"
ck "empty machines ⇒ machines_empty:true (drives the banner)"    eq "$(jq -r '.machines_empty' <<<"$VE")" "true"
ck "empty machines ⇒ machines array length 0"                    eq "$(jq -r '.machines|length' <<<"$VE")" "0"
# Absent machines key (not even an empty array) ⇒ still honest empty, never throw.
NOMACH_SNAP="$(jq -c 'del(.machines)' <<<"$GOOD")"
ck "absent machines key ⇒ machines_empty:true (tolerant)"        eq "$(jq -r '.machines_empty' <<<"$(derive "$NOMACH_SNAP")")" "true"

echo "── EXIT-5: §0.3 — unknown-HIGHER / missing schema_version REFUSED ──"
HI_SNAP="$(jq -c '.schema_version=99' <<<"$GOOD")"
VHI="$(derive "$HI_SNAP")"
ck "schema_version 99 ⇒ ok:false (refuse, never best-effort)"    eq "$(jq -r '.ok' <<<"$VHI")" "false"
ck "refusal cites the unsupported version"                       has "schema_version 99" "$(jq -r '.error' <<<"$VHI")"
ck "refusal cites §0.3"                                           has "§0.3" "$(jq -r '.error' <<<"$VHI")"
ck "refusal tells the user to update the app"                    has "update the app" "$(jq -r '.error' <<<"$VHI")"
NOSV_SNAP="$(jq -c 'del(.schema_version)' <<<"$GOOD")"
ck "missing schema_version ⇒ also ok:false"                      eq "$(jq -r '.ok' <<<"$(derive "$NOSV_SNAP")")" "false"
FLOATSV_SNAP="$(jq -c '.schema_version=1.5' <<<"$GOOD")"
ck "non-integer schema_version ⇒ ok:false"                       eq "$(jq -r '.ok' <<<"$(derive "$FLOATSV_SNAP")")" "false"
ck "the bound version 1 still derives ok:true (regression guard)" eq "$(jq -r '.ok' <<<"$(derive "$GOOD")")" "true"

echo "── EXIT-6: modes[] — one per project, honest actual + mismatch target ──"
ck "modes length matches projects length (2)"                    eq "$(jq -r '.modes|length' <<<"$V")" "2"
ck "mode 0 project_ref surfaced"                                 eq "$(jq -r '.modes[0].project_ref' <<<"$V")" "projA"
ck "mode 0 actual surfaced honestly (running)"                   eq "$(jq -r '.modes[0].actual' <<<"$V")" "running"
ck "mode 0 (no mismatch) label is the bare actual"               eq "$(jq -r '.modes[0].mode_label' <<<"$V")" "running"
ck "mode 0 mismatch:false"                                       eq "$(jq -r '.modes[0].mismatch' <<<"$V")" "false"
ck "mode 0 liveness live"                                        eq "$(jq -r '.modes[0].liveness' <<<"$V")" "live"
# projB: live, actual=running, desired=stopped, mismatch=true ⇒ honest target.
ck "mode 1 mismatch:true"                                        eq "$(jq -r '.modes[1].mismatch' <<<"$V")" "true"
ck "mode 1 label shows actual + '(target: stopped)' (principle 4)" has "running (target: stopped)" "$(jq -r '.modes[1].mode_label' <<<"$V")"
ck "mode 1 label is NOT collapsed to the desired"                hasnt "^stopped\$" "$(jq -r '.modes[1].mode_label' <<<"$V")"
# Empty projects ⇒ modes length 0, still ok.
NOPROJ_SNAP="$(jq -c '.projects=[]' <<<"$GOOD")"
ck "empty projects ⇒ modes length 0"                             eq "$(jq -r '.modes|length' <<<"$(derive "$NOPROJ_SNAP")")" "0"

echo "── EXIT-7: stale runner never reads as a live mode (S-1) ──"
STALE_SNAP="$(jq -c '.projects=[{"project_ref":"projStale","runner_state":{"liveness":"stale","actual":"running","desired":"running","desired_actual_mismatch":false}}]' <<<"$GOOD")"
VS="$(derive "$STALE_SNAP")"
ck "stale runner liveness is 'stale' (from §4.2, not re-derived)" eq "$(jq -r '.modes[0].liveness' <<<"$VS")" "stale"
ck "stale runner live_mode:false (not promoted to a live mode)"   eq "$(jq -r '.modes[0].live_mode' <<<"$VS")" "false"
ck "stale mode_label says 'stale' (last actual only as context)"  has "stale" "$(jq -r '.modes[0].mode_label' <<<"$VS")"
ck "stale mode_label does NOT read as a bare live 'running'"      hasnt "^running\$" "$(jq -r '.modes[0].mode_label' <<<"$VS")"

echo "── EXIT-8: honesty edges — gate-disabled neutral, stale gray, missing degrade ──"
# Gate disabled (threshold=0) ⇒ neutral bands + chip; the row STILL renders.
GD_SNAP="$(jq -c '.machines=[{"runner_id":"gd","observed_at":"x","pct_5h":80,"pct_7d":90,"spare_ramp_today":56,"threshold_in_effect":0,"gate_disabled":true,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":5}]' <<<"$GOOD")"
VGD="$(derive "$GD_SNAP")"
ck "gate-disabled: row STILL present (never voided)"             eq "$(jq -r '.machines|length' <<<"$VGD")" "1"
ck "gate-disabled: pct_5h band neutral (un-banded)"              eq "$(jq -r '.machines[0].pct_5h_band' <<<"$VGD")" "neutral"
ck "gate-disabled: pct_7d band neutral"                          eq "$(jq -r '.machines[0].pct_7d_band' <<<"$VGD")" "neutral"
ck "gate-disabled: gate_disabled flag exposed"                   eq "$(jq -r '.machines[0].gate_disabled' <<<"$VGD")" "true"
ck "gate-disabled: chip present"                                 eq "$(jq -r '.machines[0].gate_disabled_chip' <<<"$VGD")" "gate disabled"
ck "gate-disabled: allowed 'standard,low_priority' (all allowed)" eq "$(jq -r '.machines[0].allowed_text' <<<"$VGD")" "standard,low_priority"
ck "gate-disabled: numbers STILL formatted (degrade per-field)"  eq "$(jq -r '.machines[0].pct_5h_text' <<<"$VGD")" "80%"
# Stale record (fresh:false) ⇒ grayed bands + stale chip.
STALEM_SNAP="$(jq -c '.machines=[{"runner_id":"sm","observed_at":"x","pct_5h":24,"pct_7d":82,"spare_ramp_today":56,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":false,"age_seconds":1800}]' <<<"$GOOD")"
VSM="$(derive "$STALEM_SNAP")"
ck "stale record: pct_5h band 'stale' (grayed, not a color)"     eq "$(jq -r '.machines[0].pct_5h_band' <<<"$VSM")" "stale"
ck "stale record: pct_7d band 'stale'"                           eq "$(jq -r '.machines[0].pct_7d_band' <<<"$VSM")" "stale"
ck "stale record: stale chip names the age"                      has "30m" "$(jq -r '.machines[0].stale_chip' <<<"$VSM")"
ck "stale record: fresh:false propagated"                        eq "$(jq -r '.machines[0].fresh' <<<"$VSM")" "false"
# Missing pct_5h ⇒ '—' + partial chip; row not collapsed.
MISS_SNAP="$(jq -c '.machines=[{"runner_id":"miss","observed_at":"x","pct_7d":50,"spare_ramp_today":60,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":true,"usage_api_ok":true,"fresh":true,"age_seconds":15}]' <<<"$GOOD")"
VMS="$(derive "$MISS_SNAP")"
ck "missing pct_5h: row STILL present (no collapse)"             eq "$(jq -r '.machines[0].runner_id' <<<"$VMS")" "miss"
ck "missing pct_5h ⇒ '—' (per-field degrade)"                    eq "$(jq -r '.machines[0].pct_5h_text' <<<"$VMS")" "—"
ck "missing pct_5h ⇒ band 'missing' (no false color)"            eq "$(jq -r '.machines[0].pct_5h_band' <<<"$VMS")" "missing"
ck "missing pct_5h ⇒ 'partial' chip surfaces"                    eq "$(jq -r '.machines[0].partial_chip' <<<"$VMS")" "partial"
ck "missing pct_5h: pct_7d still rendered honestly"              eq "$(jq -r '.machines[0].pct_7d_text' <<<"$VMS")" "50%"
# keychain/api breadcrumb chips.
KC_SNAP="$(jq -c '.machines=[{"runner_id":"kc","observed_at":"x","pct_5h":24,"pct_7d":40,"spare_ramp_today":80,"threshold_in_effect":70,"gate_disabled":false,"keychain_ok":false,"usage_api_ok":false,"fresh":true,"age_seconds":12}]' <<<"$GOOD")"
VKC="$(derive "$KC_SNAP")"
ck "keychain_ok:false ⇒ 'keychain unreadable' chip"              has "keychain" "$(jq -r '.machines[0].keychain_chip' <<<"$VKC")"
ck "usage_api_ok:false ⇒ 'usage API failed' chip"               has "usage API" "$(jq -r '.machines[0].api_chip' <<<"$VKC")"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-capacity-view (unit: capacity-view):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
