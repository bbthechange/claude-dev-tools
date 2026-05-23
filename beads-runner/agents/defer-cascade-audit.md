# Defer-cascade audit (R2, claude-tools-fyx)

> Surfaces the silent parent→child defer cascade described in the fyx bug
> report: open child + zero blockers + no defer of its own gets filtered
> out of `bd ready` solely because some ancestor carries a future
> `defer_until`. `bd show <child>` does not say so.
> Helper: `beads-runner/defer-cascade-audit.sh`.

## Why this exists

bd v1 inherits a parent epic's `defer_until` to every descendant when
deciding what to surface in `bd ready`. The descendant itself shows
`status: open`, no blocked-by, no own `defer_until` — but it still won't
appear as claimable. The only way to tell *from the child* used to be:
walk up to the parent epic and grep its body for `Deferred:`.

That silent cascade is exactly how the runner's queue went empty (or
all-P3) while real demo-critical work existed. mhky's six children
(hzah/ii6b/292r/7kmj/4e0x/jcvn) and three freshly-decomposed tasks
(1mjg/glos/ccdv) were all invisible until someone cleared a stale defer
on the parent.

We can't modify `bd show` itself (bd is an external Go binary), so this
helper is an out-of-band lens: it walks the parent chain and reports the
cascade. Pair it with `gate-defer.sh lift` (R3, [[claude-tools-vb7]]) when
the silent defer turns out to be a stale release-gate stamp; pair it with
plain `bd update <epic> --defer ""` when it's an ad-hoc/auto-defer that
should never have cascaded.

## What this is NOT

This is a **diagnostic**, not a mutator. It never calls `bd update`. The
desired-behavior (2) from the fyx bug — "reconsider whether a parent
defer should cascade to children at all" — is a question for the bd
project itself; the audit makes the cascade *visible* so a human can
make the case for or against it with evidence in hand.

## Usage

    # Catch-all sweep — answers "what's hiding from bd ready right now?"
    defer-cascade-audit.sh audit

    # Targeted lookup — answers "why isn't this specific bead surfacing?"
    defer-cascade-audit.sh explain claude-tools-abc

    # Machine-readable — pipe into anything else
    defer-cascade-audit.sh list

### Output shape

    claude-tools-abc  SUPPRESSED by claude-tools-xyz deferred until 2099-01-01  [Title prefix]
    defer-cascade-audit: epics_with_future_defer=N suppressed_open_children=M

The trailing summary always goes to stderr so `list` and pipelines stay
clean.

### Exit codes

| code | meaning                                                                |
| ---- | ---------------------------------------------------------------------- |
| 0    | no cascade detected (or `list` always — list signals via output)       |
| 1    | at least one suppressed open child found (or explain: bead suppressed) |
| 2    | usage error                                                            |
| 3    | bd subprocess failure on a pre-flight call                             |

A non-zero exit from `audit` is the signal a caller should act on: "bd
ready may look healthy but it isn't — N open children are hidden."

## Semantics

- **"Future" defer means `defer_until > now (UTC)`.** A past
  `defer_until` is stale and bd ready already surfaces the bead — that's
  not a cascade, just an old timestamp.
- **A child with its own future `defer_until` is NOT reported.** The bug
  is the *silent* cascade. A child that has chosen to defer itself is
  intentional, not invisible.
- **One level per scan.** `audit` and `explain` use `bd show --children
  --json` / `bd show --json` respectively — the same one-hop shape the
  runner's `next_task` uses (`run-beads-tasks.sh:628`). If bd ever cascades
  multi-level, the helper is the right place to extend.
- **Open children only.** Closed children are irrelevant to bd ready.

## When to run

- **Whenever `bd ready` looks suspiciously empty** (or all-P3 while you
  expected P1/P2 work). The audit answers "is the queue actually empty
  or is the cascade hiding it?"
- **After lifting a release gate** (`gate-defer.sh lift … --commit`),
  re-run `audit` — if the count drops to 0, the lift recovered every
  suppressed child.
- **After any `bd update <epic> --defer …`** — confirm you didn't
  silently take a subtree out of circulation.

## Tests

`beads-runner/test-defer-cascade-audit.sh` drives the helper against a
stateful fake `bd` (same pattern as `test-gate-defer.sh` /
`test-bd-stage.sh`). 10 assertions cover: clean state; cascade detected;
self-deferred child excluded; closed child excluded; past-defer parent
excluded; `explain` SUPPRESSED + NO_SUPPRESSION cases; `list` shape;
bare invocation + missing-arg invocation both exit 2.

## Cross-references

- [[claude-tools-vb7]] (R3, `gate-defer.sh`) — the *upstream* fix: couples
  a defer to its owning gate so lifts mechanically reverse them. Together
  R3+R2 form the same loop: prevent stale defers at the source (R3),
  surface them when they happen anyway (R2).
- [[claude-tools-av7]] (R1) — runner no longer auto-claims epics, so it
  no longer self-stamps defers on them. R1 removes one source of the
  cascade; R2 surfaces all sources.
- bd memory `cf-selfdecomp-parent-child-dep-deadlock` — a *different*
  subtree-stranded failure mode (dep-edge variant). Don't conflate them:
  fyx is silent-defer-cascade, the cf memory is dep-cycle-deadlock.
