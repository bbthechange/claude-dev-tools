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

## See also

  - `beads-runner/test-bd-ready-ordering.sh` — the test that produced
    these findings; rerun against any future bd version to re-confirm.
  - `beads-runner/run-beads-tasks.sh:609` (`next_task()` — the consumer).
  - `beads-runner/run-beads-tasks.sh:626` (`validate_task()` no-claim
    label gate — the safety net that lets us seed test beads in the
    live workspace without the runner trying to work them).
