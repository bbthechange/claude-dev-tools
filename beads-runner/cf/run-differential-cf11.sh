#!/bin/bash
# CF.11 (claude-tools-7g0.11) — DIFFERENTIAL CONFORMANCE RIG.
#
# Seam (e): the integration/verification child. It implements NO new engine
# surface — it PROVES the engine. It points the conformance behaviour at the
# REAL, locally-running CF engine (wrangler dev / pages dev, NO Cloudflare
# account) and asserts the system-under-test is behaviour-equivalent to its
# DIFFERENTIAL ORACLE: lib/coordinator.sh & siblings + the full lib/test-*.sh
# suite + conformance/run-conformance.sh + conformance/assertions/bc-*.sh.
#
# The CF engine is the SYSTEM UNDER TEST; the bash impl + its tests are the
# ORACLE. Per the conformance ANTI-DRIFT this rig adapts the DRIVER to target
# the CF engine — it NEVER edits an INTERFACE clause or a conformance
# assertion to make a gate pass. Any interface gap surfaced here is a BLOCKING
# §11 escalation (reopen claude-tools-65z), never a local divergence.
#
# Six parts, exit 0 iff ALL pass:
#
#   1  SIBLING-SPEC PRESENCE AUDIT — every CF.2..CF.9 sibling must have added
#      its own cf/test/<slice>.spec.js (the per-surface differential against
#      its lib/test-*.sh oracle). A MISSING one is a sibling gap this rig
#      FLAGS and fails on — it is NOT CF.11's to implement.
#
#   2  ENGINE BEHAVIOURAL CONFORMANCE (wrangler dev path) — delegates to the
#      CF.1 rig run-differential.sh: `npm test` runs EVERY cf/test/*.spec.js
#      under @cloudflare/vitest-pool-workers (the REAL Worker + singleton
#      Coordinator DO + D1 on the SAME workerd+miniflare runtime `wrangler
#      dev` uses) — each spec mirrors its lib/test-*.sh oracle clause-for-
#      clause — PLUS the §0.C source-discipline grep + the §6.3/§6.2
#      capacity-never-measures grep.
#
#   3  THE 4 FORWARD GATES — flipped GREEN against the REAL CF engine:
#        • AD2.1  (§6.1)  — realized in cf/test/lease.spec.js (CF.2): a lease
#                           acquire is observable + release pairs it, asserted
#                           via SELF.fetch on the real engine.
#        • AD2.2  (§6.2)  — realized in cf/test/lease.spec.js (CF.2):
#                           Coordinator-unreachable + no held lease ⇒ a NEW
#                           lease is DENIED and the task is NEVER driven.
#        • STUCK-e2e (§7.2/§7.3) — realized in cf/test/stuck.spec.js (CF.8):
#                           the cross-tier OUTCOME bc-stuck-cross-tier.sh
#                           asserts (bead ENDS blocked-for-human, `bd human`
#                           honored, for the worker path AND both backstops).
#        • BC-38  (§7.6)  — a RUNNER / Local-Agent-tier guardrail, NOT a
#                           Coordinator surface. The rig asserts it STAYS
#                           GREEN under the §1.1 engine swap WITHOUT the
#                           engine implementing it: (a) the engine src ports
#                           NO §7.6 worker-prompt guardrail (porting = drift)
#                           and (b) the bash bc-38 gate is GREEN on the
#                           unchanged bash runner.
#
#   4  PAGES SERVE CONFORMANCE (wrangler pages dev path) — delegates to the
#      CF.10 rig pages-dev/verify.sh: boots the FROZEN engine + the FROZEN
#      Board/Inbox Pages proxies via `wrangler pages dev` and drives them
#      end-to-end, behaviour-identical to lib/test-board.sh / lib/test-inbox.sh
#      against the bash oracle. Skippable with CF11_SKIP_PAGES=1 for fast
#      iteration; RUN BY DEFAULT (EXIT criterion 1 binds the pages-dev path).
#
#   5  BASH CONFORMANCE BASELINE UNAFFECTED — runs conformance/run-conformance
#      .sh for the three gate ids against the UNCHANGED bash run-beads-tasks.sh
#      and asserts zero FAIL + BC-38 per-BC rollup still GREEN. Proves EXIT
#      criterion 4: pointing the driver at the CF engine left the bash
#      conformance baseline itself unaffected.
#
#   6  DIFFERENTIAL EQUIVALENCE REPORT — refreshes cf/DIFFERENTIAL-EQUIVALENCE
#      .md's machine verdict block: every ported surface (CF.1..CF.10) is
#      behaviour-identical to its bash oracle + lib/test-*.sh on the bound
#      §-clauses, zero unexplained divergence.
#
# EXCLUDED (the a53 DEPLOY GATE): real `wrangler deploy`, production Pages
# deploy, the §0.B off-network/asleep proof. This rig STOPS AT LOCALLY-GREEN.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$HERE"
RUNNER_DIR="$(cd "$CF_DIR/.." && pwd)"
CONF_DIR="$RUNNER_DIR/conformance"
cd "$CF_DIR" || exit 2

RC=0
# One trap, vars pre-declared (rm -f "" is harmless) — a mid-script exit never
# leaves a temp behind and the trap is never redefined out from under itself.
GATE_LOG=""; B38_LOG=""; BASE_LOG=""
trap 'rm -f "$GATE_LOG" "$B38_LOG" "$BASE_LOG"' EXIT
mktmp() { mktemp 2>/dev/null || { echo "FATAL: mktemp failed"; exit 2; }; }
sec() { echo ""; echo "═══════════════════════════════════════════════════════════════════════"; echo " $1"; echo "═══════════════════════════════════════════════════════════════════════"; }
ok()  { printf '  \xE2\x9C\x93 %s\n' "$1"; }
bad() { printf '  \xE2\x9C\x97 %s\n' "$1"; RC=1; }

echo "╔═════════════════════════════════════════════════════════════════════╗"
echo "║  CF.11 DIFFERENTIAL CONFORMANCE RIG  (claude-tools-7g0.11)           ║"
echo "║  system under test: the REAL CF engine (workerd+miniflare, NO acct) ║"
echo "║  oracle: lib/*.sh + lib/test-*.sh + conformance/ (FROZEN)            ║"
echo "╚═════════════════════════════════════════════════════════════════════╝"

# ── PART 1 — sibling-spec presence audit ─────────────────────────────────────
sec "PART 1/6 — sibling-spec presence audit (a missing spec = a sibling gap)"
# child → spec → its lib/test-*.sh oracle. CF.1 is the substrate; CF.2..CF.9
# each OWN a differential spec; CF.10 has no vitest spec (it is the Pages
# serve, proven in PART 4 by pages-dev/verify.sh).
audit_one() { # <child> <spec> <oracle>
  if [[ -f "test/$2" ]]; then ok "$1  test/$2  ⟷ oracle $3"
  else bad "$1  test/$2 MISSING — sibling gap; CF.11 flags, does NOT implement it"; fi
}
audit_one "CF.1 " "coordinator.spec.js"  "lib/test-coordinator.sh"
audit_one "CF.2 " "lease.spec.js"        "lib/test-coordinator-lease.sh + bc-ad2-lease-posture.sh"
audit_one "CF.3 " "reconcile.spec.js"    "lib/test-coordinator-reconcile.sh + test-board.sh(producer)"
audit_one "CF.4 " "capacity.spec.js"     "lib/test-coordinator-capacity.sh + bc-34-usage-fail-open.sh"
audit_one "CF.5 " "forensic.spec.js"     "lib/test-coordinator-forensic.sh"
audit_one "CF.6 " "dossier.spec.js"      "lib/test-dossier.sh + test-dossier-gen.sh + test-consequence.sh"
audit_one "CF.7 " "timer.spec.js"        "lib/test-timed-fyi.sh"
audit_one "CF.8 " "stuck.spec.js"        "lib/test-stuck-routing.sh + bc-stuck-cross-tier.sh"
audit_one "CF.9 " "notification.spec.js" "lib/test-notification.sh"

# ── PART 2 — engine behavioural conformance (wrangler dev path) ──────────────
sec "PART 2/6 — engine behavioural conformance — delegate to CF.1 run-differential.sh"
echo "  (npm test = every cf/test spec on the REAL Worker+DO+D1; + §0.C + capacity-never-measures)"
if bash "$CF_DIR/run-differential.sh"; then
  ok "run-differential.sh GREEN — every ported surface behaviour-identical to its bash oracle"
else
  bad "run-differential.sh RED — a ported surface diverged from its bash oracle (see above)"
fi

# ── PART 3 — the 4 forward gates GREEN against the REAL engine ───────────────
sec "PART 3/6 — the 4 forward gates flip GREEN against the REAL CF engine"
GATE_LOG="$(mktmp)"
# Re-run ONLY the two engine-exercised gate specs with verbose console so the
# bc-ad2 / bc-stuck OUTCOME clauses are observable (each runs via SELF.fetch:
# Worker → §9.1 chokepoint → singleton Coordinator DO → D1). The vitest EXIT
# CODE is the authoritative per-spec pass/fail signal (each spec ends
# `expect(FAIL).toBe(0)`); we capture it instead of swallowing it with `||`.
npx vitest run test/lease.spec.js test/stuck.spec.js --reporter=verbose > "$GATE_LOG" 2>&1
VRC=$?

# SPECS_OK — FAIL-CLOSED authoritative gate-spec pass signal, three
# independent corroborating sources, ANY one negative ⇒ not-ok:
#   • vitest exit code 0 (the `expect(FAIL).toBe(0)` in BOTH specs); a failed
#     `it()` exits non-zero — this alone makes a regressed gate spec RED.
#   • vitest printed NO "Test Files … failed" line.
#   • stuck.spec.js's OWN terminal banner self-reports `FAIL=0` (it prints
#     `══ CF.8 differential …: PASS=n FAIL=n ══` BEFORE its final expect, so a
#     non-zero FAIL is visible there too — defense in depth for CF.8).
# (lease.spec.js prints no self-banner ⇒ its authority is the vitest rc.)
SPECS_OK=1
[[ $VRC -eq 0 ]]                                                  || SPECS_OK=0
grep -qE 'Test Files .* failed' "$GATE_LOG"                       && SPECS_OK=0
grep -qE '══ CF\.8 differential .*: PASS=[0-9]+ FAIL=0 ══' "$GATE_LOG" || SPECS_OK=0
[[ $SPECS_OK -eq 1 ]] \
  && echo "  (gate specs PASSED on the real engine — vitest rc=$VRC, CF.8 self-banner FAIL=0)" \
  || echo "  (gate specs did NOT cleanly pass — vitest rc=$VRC; gates are RED, fail-closed)"

# gate_green <label> <required-✓-clause-regex>
# FAIL-CLOSED: a gate is GREEN iff ALL of — (1) every gate spec passed
# (SPECS_OK, which already catches a `✗` on ANY clause of the same file via
# the vitest rc), AND (2) the named OUTCOME clause is PRESENT and ticked `✓`
# (absent clause ⇒ cannot prove ⇒ RED), AND (3) it never appears as `✗`.
gate_green() {
  local label="$1" need="$2"
  if [[ $SPECS_OK -ne 1 ]]; then bad "$label — its gate spec did NOT pass on the real engine"; return; fi
  if grep -qE "✗ ($need)" "$GATE_LOG"; then bad "$label — the OUTCOME clause FAILED on the real engine"; return; fi
  if ! grep -qE "✓ ($need)" "$GATE_LOG"; then bad "$label — OUTCOME clause ABSENT (cannot prove GREEN — fail-closed)"; return; fi
  ok "$label — GREEN against the REAL CF engine"
}
gate_green "AD2.1  (§6.1, cf/test/lease.spec.js — bc-ad2-lease-posture)" \
  "AD2\.1: (a lease acquire is observable|lease release pairs it)"
gate_green "AD2.2  (§6.2, cf/test/lease.spec.js — bc-ad2-lease-posture)" \
  "AD2\.2: (unreachable \+ no held lease|the unclaimed task was NEVER driven)"
gate_green "STUCK-e2e (§7.2/§7.3, cf/test/stuck.spec.js — bc-stuck-cross-tier)" \
  "bc-stuck §7\.[23]"

# BC-38 §7.6 — RUNNER-side guardrail. (a) the engine must NOT port it; the
# §7.6 guardrail constructs are: a `--disallowedTools` arg the runner passes
# to claude, the "running non-interactively" worker-prompt text, the
# "Do NOT use EnterPlanMode/AskUserQuestion" prohibition, the
# "bd update <id> --append-notes=" debrief-then-close prompt. Comments are
# stripped first so the lease.js/stuck.js ANTI-DRIFT PROSE that NAMES BC-38
# (to declare it out of scope) does not itself trip the gate. The match is
# case-insensitive (`-i`, same as the §0.C grep) to harden against a port
# that merely re-cases the prompt. Fail-closed: a stripper error / empty
# output is treated as a DRIFT VIOLATION, never a silent pass.
echo ""
echo "  BC-38 (§7.6) — RUNNER guardrail: assert NOT ported into the engine (porting = drift)"
b38viol=0
for f in src/*.js; do
  s="$(node test/strip-comments.mjs "$f" 2>/dev/null)" || { bad "BC-38 — strip-comments failed on $f (fail-closed drift)"; b38viol=1; break; }
  [[ -n "$s" ]] || { bad "BC-38 — $f empty after strip (fail-closed drift)"; b38viol=1; break; }
  if printf '%s' "$s" | grep -Eiq -- '--disallowedTools|running non-interactively|Do NOT use (EnterPlanMode|AskUserQuestion)|--append-notes='; then
    bad "BC-38 — $f PORTS the §7.6 worker-prompt guardrail into the engine (drift / §1.1 boundary violation)"
    b38viol=1
  fi
done
[[ $b38viol -eq 0 ]] && ok "BC-38 — the §7.6 worker-prompt guardrail is NOT in the engine (no drift; stays a runner surface)"

# (b) BC-38 stays GREEN on the UNCHANGED bash runner under the engine swap.
echo ""
echo "  BC-38 (§7.6) — assert STILL GREEN on the unchanged bash runner (engine swap must not regress it)"
B38_LOG="$(mktmp)"
bash "$CONF_DIR/run-conformance.sh" bc-38-worker-prompt > "$B38_LOG" 2>&1 || true
if grep -qE '^ Summary: .* FAIL=0' "$B38_LOG" && grep -qE 'BC-38 +GREEN' "$B38_LOG"; then
  ok "BC-38 — per-BC rollup GREEN, FAIL=0 on the unchanged bash runner (gate not regressed)"
else
  bad "BC-38 — bash bc-38 gate is NOT GREEN under the engine swap"
  grep -E 'Summary:|BC-38 ' "$B38_LOG" | sed 's/^/      /'
fi

# ── PART 4 — Pages serve conformance (wrangler pages dev path) ───────────────
sec "PART 4/6 — Pages serve conformance — delegate to CF.10 pages-dev/verify.sh"
if [[ "${CF11_SKIP_PAGES:-0}" == "1" ]]; then
  bad "SKIPPED (CF11_SKIP_PAGES=1) — EXIT criterion 1 binds the pages-dev path; NOT locally-green"
else
  echo "  (boots the FROZEN engine + FROZEN Board/Inbox proxies via wrangler pages dev; e2e)"
  if bash "$CF_DIR/pages-dev/verify.sh"; then
    ok "pages-dev/verify.sh GREEN — the Pages proxies round-trip behaviour-identical to test-board/test-inbox"
  else
    bad "pages-dev/verify.sh RED — the wrangler pages dev path diverged (see above)"
  fi
fi

# ── PART 5 — bash conformance baseline unaffected ───────────────────────────
sec "PART 5/6 — bash conformance baseline UNAFFECTED (EXIT criterion 4)"
BASE_LOG="$(mktmp)"
bash "$CONF_DIR/run-conformance.sh" bc-38-worker-prompt bc-ad2-lease-posture bc-stuck-cross-tier > "$BASE_LOG" 2>&1 || true
if grep -qE '^ Summary: .* FAIL=0' "$BASE_LOG"; then
  ok "bash conformance: zero FAIL — the bash oracle baseline is itself unaffected by the engine swap"
else
  bad "bash conformance regressed (FAIL>0) — the engine swap perturbed the bash baseline"
fi
grep -qE 'BC-38 +GREEN' "$BASE_LOG" \
  && ok "BC-38 per-BC rollup GREEN on the frozen bash baseline (runner-side gate intact)" \
  || bad "BC-38 per-BC rollup not GREEN on the frozen bash baseline"
grep -E ' Summary:| Per-BC| BC-38 | AD2.1 | AD2.2 | STUCK-e2e ' "$BASE_LOG" | sed 's/^/      /'

# ── PART 6 — differential equivalence report ────────────────────────────────
sec "PART 6/6 — differential equivalence report"
REPORT="$CF_DIR/DIFFERENTIAL-EQUIVALENCE.md"
VERDICT="GREEN"; [[ $RC -eq 0 ]] || VERDICT="RED"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -f "$REPORT" ]]; then
  # Refresh ONLY the machine-verdict block between the sentinels (the prose
  # mapping above it is the human-authored differential argument).
  tmp="$(mktmp)"
  # Fail-closed: awk exits 3 if it never saw the :END sentinel (a malformed
  # report would otherwise be silently TRUNCATED from :BEGIN onward). The
  # rewrite is committed ONLY if awk succeeded AND both sentinels survive in
  # the output — otherwise the human-authored report is left untouched.
  if awk -v v="$VERDICT" -v s="$STAMP" '
       /<!-- CF11-VERDICT:BEGIN -->/{print; print "_Last rig run: **" s "** — overall **" v "**._"; skip=1; seen_b=1; next}
       /<!-- CF11-VERDICT:END -->/{skip=0; seen_e=1}
       !skip{print}
       END{ if (!(seen_b && seen_e)) exit 3 }
     ' "$REPORT" > "$tmp" \
     && grep -q 'CF11-VERDICT:BEGIN' "$tmp" && grep -q 'CF11-VERDICT:END' "$tmp"; then
    mv "$tmp" "$REPORT"
    ok "refreshed $REPORT verdict block → $VERDICT @ $STAMP"
  else
    rm -f "$tmp"
    bad "DIFFERENTIAL-EQUIVALENCE.md verdict sentinels malformed — report left UNTOUCHED (fail-closed)"
  fi
else
  bad "DIFFERENTIAL-EQUIVALENCE.md missing (the report artifact must exist)"
fi

# ── verdict ─────────────────────────────────────────────────────────────────
sec "CF.11 VERDICT"
if [[ $RC -eq 0 ]]; then
  echo "  ══ CF.11 DIFFERENTIAL GREEN ══"
  echo "  All 9 sibling specs present; the engine is behaviour-identical to the"
  echo "  bash oracle + lib/test-*.sh on every bound §-clause; the 4 forward"
  echo "  gates (AD2.1, AD2.2, STUCK-e2e, BC-38) are GREEN against the REAL CF"
  echo "  engine; the wrangler pages dev path round-trips identically; the bash"
  echo "  conformance baseline is itself unaffected. Stops at LOCALLY-GREEN"
  echo "  (real deploy + the §0.B off-network proof = the a53 gate, EXCLUDED)."
else
  echo "  ══ CF.11 DIFFERENTIAL RED — see ✗ above ══"
  echo "  Per ANTI-DRIFT: a real divergence is a BLOCKING §11 escalation"
  echo "  (reopen claude-tools-65z) — NEVER edit INTERFACE or an assertion."
fi
exit $RC
