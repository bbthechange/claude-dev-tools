# `bd ready` ordering — empirical contract

> Filed for claude-tools-7my (runner-reliability residual at the close of
> claude-tools-1yt). Pins what `bd ready --json` actually returns, so the
> ah8/R5 priority-band workaround and the broader ir7 shielding posture
> stop relying on an un-verified assumption.

## Why this doc exists

Every claude-tools-ir7 sibling mitigation silently assumed `bd ready`
returns issues priority-ascending with a stable, deterministic tiebreak:

  - The ah8/R5 priority-band workaround for runner queue starvation.
  - The original "P2/P3 + defer + human-triage" shielding of the ir7
    subtree itself.
  - `next_task()` in `run-beads-tasks.sh:609`, which calls
    `bd ready --json` and treats element 0 as "the work to do next".

None of these had ever been empirically verified against the running bd
binary. This doc records what the verification showed.

## What was verified

`beads-runner/test-bd-ready-ordering.sh` (the empirical test) seeds 8
beads in the live workspace under a unique fixture label, at three
priorities (P1, P2, P3) and with creation timestamps staggered by ≥1s.
It then calls `bd ready --label <fixture> --json` five times in a row
and inspects the result.

Findings against `bd version 1.0.2 (main@a3f834b31fe9)` on 2026-05-24:

1. **Primary sort: priority-ascending.** P0 < P1 < P2 < P3 < P4. Lower
   priority number = earlier in the list. The default `--sort priority`
   matches the runner's assumption.

2. **Order is deterministic.** All 5 back-to-back invocations returned
   the exact same sequence. No flap, no reshuffle.

3. **Within-priority tiebreak: created-at descending (newest first).**
   For two beads at the same priority, the one with the more recent
   `created_at` appears first. This is `--sort priority`'s observed
   tiebreak — the bd CLI also exposes `--sort oldest` (created-at
   ascending across all priorities) and `--sort hybrid`, which we do
   not use.

## What this means for the runner

`next_task()` reading element 0 of `bd ready --json` will get the
highest-priority bead in the workspace. If multiple beads share that
priority, it picks the **most recently created** one — which is a
reasonable default (newer work usually carries more context the human
just loaded) but is worth knowing if you're debugging "why did the
runner pick X over Y when both are P3."

The ah8/R5 priority-band workaround is therefore valid: there is no
hidden secondary axis (e.g. dependency count, recent activity, alpha
sort on id) bypassing the priority sort. A P3 bead never precedes a P2
bead under `--sort priority`.

## What is NOT verified here

  - Ordering at P0 and P4. We deliberately avoided P0 (live-runner
    critical/escalate treatment is risky to provoke even briefly) and
    P4 (collides with existing P4 beads, dilutes the label-isolation).
    The mechanism is the same numeric sort key — there is no reason to
    expect P0 or P4 to behave differently — but the test does not prove
    it.
  - Behavior under `--sort hybrid`. The runner uses default
    (`--sort priority`); if a future change adopts hybrid, re-verify.
  - Behavior across federation / multi-workspace queries. Test runs
    against the single live workspace.
  - Behavior when ties are sub-second. The test enforces ≥1.1s between
    creates because bd's `created_at` field has second-level resolution
    in the JSON we observed. Sub-second ties were not observed and the
    tiebreak rule for that case is not pinned.

## If this regresses

If `test-bd-ready-ordering.sh` starts failing assertion 1 (priority not
ascending) or assertion 2 (non-deterministic across calls), the
correction goes **upstream into the bd project**, not into the runner.
Per claude-tools-7my SCOPE (3): "DO NOT add a sort to the runner; that's
a workaround for an upstream bug." File the upstream issue with the
test's observed output as the repro.

If the tiebreak direction silently flips (newest-first → oldest-first),
that is **not** a bug per se — `bd ready` does not document the
tiebreak — but it is worth updating this doc and any downstream
documentation that quotes "newest first" as the observed behavior.

## What the runner does NOT read from `bd ready --json`

> Filed for claude-tools-507 (runner-reliability residual at the close
> of claude-tools-1yt, R6 / handoff P6). The hypothesis was stated
> aloud but never empirically pinned; this section pins it.

The FE session that motivated 1yt observed some `Owner='Brian Butler'`
tasks (ha5j / ppvf / hqgx) surfacing in `bd ready` while other tasks
with **identical** owner (1cjp / 65x8) did not. The hypothesis at the
time was "the runner does not filter on assignee/owner." Verified:

### Code audit (2026-05-23, `run-beads-tasks.sh` @ 53d93e4)

  - `grep -nE 'assignee|owner|\.owner|\.assignee' run-beads-tasks.sh`
    returns **zero matches**. Neither field is named anywhere in the
    runner.
  - `next_task()` (line 586) consumes `bd ready --exclude-type=epic
    --json` and the only fields it reads, via jq, are `.issue_type` /
    `.type` (the client-side epic filter from claude-tools-dzc). It
    picks element 0 and hands the full JSON object to the caller — no
    assignee/owner gate.
  - `validate_task()` (line 626) is the only other place a ready bead
    can be rejected before claim. It checks, in order:
      1. `RUNNER_NO_CLAIM_LABELS` (BC-08b, claude-tools-noj/tkf)
      2. `bd blocked` re-query (BC-07, deps added after queueing)
      3. `issue_type == "epic"` (defense-in-depth behind dzc's
         query-layer exclude; see also BC-07 epic skip)
      4. parent/container with open formal children (BC-08)
    None of these read assignee or owner.
  - The actual claim is `bd update <id> --status=in_progress` (line
    1302). No `--assignee` flag, no owner check.

**Conclusion:** the runner's eligibility surface is exactly the four
filters above plus the lease gate (§6.1 / BC-04). It is owner-blind by
design — the single-author repo posture means "if Brian filed it and
it's open and unblocked, the runner is welcome to work it."

### What actually caused the FE inconsistency

Not the runner. `bd ready` itself filters out beads that are:
  - `status != open`
  - currently deferred (`Deferred: <future-date>` — including inherited
    defers from a gate label, see [`gate-defer.md`](gate-defer.md))
  - blocked by an open dependency

Across the FE-observed bead pairs the most likely explanation is one
of those three (one of the missing pair was deferred or had an open
blocker) — **not** an owner check anywhere in the pipeline. If a
future audit ever finds an `Owner='Brian Butler'` bead that meets all
three of (open, not deferred, not blocked) and still doesn't appear in
`bd ready` while a sibling does, that is an upstream `bd ready` bug,
not a runner filter — file it against bd, the same way [§"If this
regresses"](#if-this-regresses) handles the ordering case.

### Why no new filter

Out of scope for 507 and out of scope by design. The runner's
owner-blind posture is intentional for single-author repos; adding an
assignee gate would re-introduce the exact starvation class that
RUNNER_NO_CLAIM_LABELS already handles cleanly (label the bead, not
the worker). If a future multi-worker setup wants owner-routing, the
right shape is another `RUNNER_*` env var that maps `Owner=<x>` to
"skip-not-fail with reason", not a hardcoded assignee read.

## See also

  - `beads-runner/test-bd-ready-ordering.sh` — the test that produced
    these findings; rerun against any future bd version to re-confirm.
  - `beads-runner/run-beads-tasks.sh:586` (`next_task()` — the consumer;
    audit point for "does the runner filter on owner/assignee").
  - `beads-runner/run-beads-tasks.sh:626` (`validate_task()` no-claim
    label gate — the safety net that lets us seed test beads in the
    live workspace without the runner trying to work them).
  - `beads-runner/BEHAVIORAL-CONTRACT.md` BC-07 / BC-08 / BC-08b — the
    contract-level statements of the four eligibility filters above.
  - [`gate-defer.md`](gate-defer.md) — the inherited-defer mechanism
    that explains most "why isn't this in bd ready" mysteries.
