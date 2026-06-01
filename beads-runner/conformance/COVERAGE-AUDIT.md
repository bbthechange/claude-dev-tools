# BC-harness coverage audit — v2 cutover (claude-tools-v2c3)

> **Mandate** (TESTING-STRATEGY §7.2(a), the explicit core of `claude-tools-v2c3`):
> enumerate every v1 runner behaviour (`BEHAVIORAL-CONTRACT.md` BC-01…BC-65), map
> each to a `conformance/assertions/bc-*` assertion **and** to its presence in the
> v2 runner (`runner.sh`), list the unmapped ones, and file the gaps. The cutover
> bar (Brian, 2026-05-30): **v2 must provably MATCH OR EXCEED v1** — a green
> harness is necessary-but-not-sufficient, because v1 accreted battle-fixes the
> rewrite never received and the harness may not have covered.

**Method.** A 10-agent coverage workflow read `BEHAVIORAL-CONTRACT.md`,
`INTERFACE.md`, both runners (`run-beads-tasks.sh` v1, `runner.sh` v2), and the
`conformance/assertions/` glob, partitioning BC-01…BC-65 into clusters; one
synthesis pass de-duplicated and reconciled the verdicts (preferring file+line
evidence). 70 behaviour rows assessed.

**Headline.** v2's failure-classification / retry / exit-code / teardown /
watchdog spine is faithfully ported and **v2-tree-asserted** (19 BCs fully
covered). But the rewrite is **missing a whole task-selection / workability /
orphan-recovery layer** that v1 accreted, and a band of present-but-untested and
observability behaviours. These are the cutover blind spots this bead exists to
surface.

---

## What `claude-tools-v2c3` itself landed (implemented + GREEN here)

These were either named v2c3 deliverables or the worst co-located blocker; each
ships with a GREEN `-tree` conformance assertion:

| Behaviour | runner.sh change | Assertion |
|---|---|---|
| **BC-08b** `RUNNER_NO_CLAIM_LABELS` human-* hard gate (worst cutover-blocker — auto-claimed a phone-gated fixture 4× in one night, claude-tools-240/0kr/tkf) | `_candidate_label_gated` + the st_reconcile candidate **walk** (skip-not-fail, advance past — no starvation); `RUNNER_NO_CLAIM_LABELS` default restored | `bc-08b-no-claim-label-gate-tree.sh` (6) |
| **uxvj4** runner refuses any `gate:<id>` Gate label (gates.md §5; ALWAYS-ON, `^gate:` anchor, no `gateway` over-match) | same `_candidate_label_gated` (one hoisted `bd label list`, both gates) | `bc-uxvj4-gate-refusal-tree.sh` (4) |
| **BC-58** per-task permission-mode auto (qcoe v2c1 port had no assertion) | none (asserts existing runner.sh:186-198) | `bc-58-permission-mode-tree.sh` (3) |
| **uxvi1** activity-state classifier (D.2 7-state enum + 90/180 liveness, derived) | new `lib/activity-classifier.sh` (pure classifier; runner wiring is uxvi1's remaining surface) | `bc-uxvi1-activity-parser.sh` (34, table-driven) |

The `dzc` epic-exclusion port already had `bc-dzc-epic-exclusion-tree.sh` (v2c1);
that closes the "a NEW regression assertion for every v2c1-ported fix" deliverable
(dzc ✓, qcoe ✓ added here).

---

## Cutover blockers — FILED as beads blocking `claude-tools-v2c4`

The cutover (`v2c4`) is gated on these; v2c3 surfaces + files them rather than
porting them (a gate audits and blocks; the ports are v2c1-class work, kept as
separate beads to avoid the "two beads build the same v2 state two ways" hazard
the v2c1 SCOPE-NARROW note warns of). Each filed bead must add its own `-tree`
assertion when it lands.

| BC | What v2 lacks | v2 site to change |
|---|---|---|
| **BC-02/03/04** | Orphan recovery: no startup `in_progress` snapshot, no one-per-loop orphan drain with resume-time status re-check. A SIGKILLed prior run strands a bead `in_progress` until lease expiry. | `st_starting` (snapshot) + a reconcile-time orphan pass. *Note:* verify whether v2's lease-expiry + Coordinator reconcile already covers crash-orphan release — the mechanism may legitimately differ from v1's snapshot. |
| **BC-06/07/08/51** | The workability-validation layer: no `bd blocked` TOCTOU re-check (06), no `bd show --children` self-exclusion (07), no parent/container auto-close-or-skip (08), no `select_workable_task` walk past an unworkable head (51). v2 picks `.[0]` and claims it. *(The v2c3 label-gate walk is a partial 51 for the label-skip class only.)* | `st_reconcile` candidate selection — a `validate_task` gate folding 06/07/08/51. |
| **BC-08d** | Cross-workspace scope check (`RUNNER_SIBLING_PREFIXES` / `RUNNER_TRACKING_ONLY_LABELS`) — only doc-comment mentions in runner.sh; `bc-xws-scope-check.sh` is v1-only. | `st_reconcile` (alongside the label gate) + a `-tree` mirror. |
| **BC-56** | `post_close_audit` — a SUCCESS that didn't ship is **not** surfaced as a discipline-bypass regression bead. (`bc-2fkp-close-discipline-tree.sh` tests the close-hook wiring (BC-65), not the audit.) | `st_post_task` SUCCESS branch + a `-tree` assertion. |

## Observability / side-effect ports — LANDED (claude-tools-v2cut.4)

All six were ported into `runner.sh` with `-tree` assertions (none are
exit/classification blockers):

| BC | runner.sh change | Assertion |
|---|---|---|
| **BC-25** `scan_tool_errors` (side-effect tool-error scan; the only absent **should-have**) | `scan_tool_errors` defined in the §8.2 observability block; called UNCONDITIONALLY after the st_post_task dispatch case (never mutates class/exit) | `bc-25-scan-tool-errors-tree.sh` (2) |
| **BC-26** `notify_user` desktop notifications + selective silence | `notify_user` defined (bell + osascript); noisy classes (AUTH/BILLING/MAXTOK/OVERFLOW/generic/max-retries/subagent/discipline/breaker) notify, routine (SUCCESS/RATE_LIMIT/first-not-closed/stuck) stay silent | `bc-26-notify-policy-tree.sh` (4) |
| **BC-30** `LOG_RETENTION_DAYS` rotation-once | prune in `st_starting` (reached exactly once), excludes `.gitignore`+`incidents.log` | `bc-30-rotation-once-tree.sh` (1) |
| **BC-31** preflight non-aborting agent-count | `preflight.log` + one-line count in `st_starting`; 0 does NOT abort | `bc-31-preflight-nonaborting-tree.sh` (2) |
| **BC-32** per-task `model:` label selection | `_resolve_task_model` (per-task) re-resolves TASK_MODEL + TASK_PERMISSION_FLAGS at the top of st_run_task; spawn uses `--model "$TASK_MODEL"` (was DEFAULT_MODEL); BC-58 coupling preserved | `bc-32-model-selection-tree.sh` (5) |
| **BC-61** `rate_limit_event` subscription-window parse | `rate_limit_event` case in `parse_stream_signals` (allowed/allowed_warning/rejected\|exceeded); no classifier marker | `bc-61-rate-limit-event-tree.sh` (3) |

The fake `claude` gained `rate_limit_event_{allowed,warning,quota}` behaviors and
the fake `osascript` now records notifications to `notify_log` (harness observer).

## Coverage-hardening — present-in-v2 but only v1-tested — FILED

These behaviours **are** in runner.sh but only the v1-default-RUNNER assertion
drives them; add `-tree` mirrors so v2 is *provably* covered:
**BC-23** greppable notes, **BC-24** incidents log, **BC-27** logdir security,
**BC-28** selective preservation, **BC-34** usage fail-open, **BC-48** lease
posture (`bc-ad2`), plus focused `-tree` cases for **BC-12** (dual-path
MAX_OUTPUT_TOKENS collapse), **BC-17** (analysis-chain guard, named), **BC-45**
(v2's *deliberate* unconditional-HB + watchdog-soft-warn honesty — assert the NEW
intent, not v1 silence-on-stuck), **BC-49/50** (capacity gate + desired-state
resolver), **BC-60** (epoch-floor + liveness mechanism), and the no-assertion
load-bearing present behaviours **BC-37/42/43/44/47/63/64/BC-NEW-SPAWN**.

## Decisions (NOT ports)

- **BC-39/40/41** stream-merge / signal-file IPC / `RESULT_IS_ERROR` dead-data —
  scaffolding; v2 reimplements via `parse_stream_signals`. BC-41 dead-data must
  **not** be preserved.
- **BC-18** `bd create` sed-scrape — unasserted scaffolding in both; do not test.
- **BC-33** chunked graceful-stop during a usage sleep — **CONFIRMED moot**
  (claude-tools-v2cut.4): v2 has NO long usage sleep. The capacity gate (st_claim
  `job_ask_capacity`) releases the lease and sleeps a short `RECLAIM_POLL_INTERVAL`
  (60 s) then re-reconciles; `STOP_FILE` is polled at the top of every
  `st_reconcile` and observed mid-task by the watchdog (→ STOP_REQUESTED, honored
  after the task). So a stop is honored ≤ `RECLAIM_POLL_INTERVAL` STRUCTURALLY —
  v1's 60 s-chunked-sleep + `break 3` scaffolding is correctly NOT ported.
- **BC-19** CONTEXT_OVERFLOW salvage-reason drift — **RESOLVED: RESTORE**
  (claude-tools-v2cut.4). The truncated final "relabel model:opus" sentence is
  restored in v2's st_post_task CONTEXT_OVERFLOW arm. It was dropped in the
  pre-BC-32 skeleton because per-task `model:` labels did nothing then; BC-32
  (same bead) makes the relabel meaningful again (a model:opus task now actually
  runs on the 1M-context Opus variant). `bc-19-overflow-salvage-tree.sh` (1).
- **BC-45** heartbeat is intentionally unconditional in v2 (lease-ride; v2c1
  documented) — a departure, not a regression; assert the new intent.
- **BC-55** async-human `ASKBRIAN_BLOCK` / I4 seam — explicitly out of cutover
  scope.

---

## Fully covered (v2 present + v2-tree assertion) — 19

BC-01, BC-05, BC-09, BC-10, BC-11, BC-13, BC-14, BC-15, BC-21, BC-22,
BC-22-addendum, BC-29, BC-35, BC-36, BC-52, BC-59, BC-62, BC-63, plus the new
BC-08b/uxvj4/BC-58/uxvi1 landed by this bead.
