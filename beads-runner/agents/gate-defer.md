# Gate-defer ownership coupling (R3, claude-tools-vb7)

> Realizes Brian's vb7 fork decision (opt-a, ask-brian dossier 2026-05-22):
> couple a defer-date to its owning gate via the bd label `gate:<gate-id>`
> so lifting the gate mechanically reverses every defer it set.
> Helper: `beads-runner/gate-defer.sh`.

## Why this exists

A cohort/release gate (e.g. `impl-gate-2026-04-22`) is the kind of hold a
human places on a batch of beads — "do not work this until the milestone
lifts". The mechanism used to enforce it in bd is `bd update <id> --defer
<date>` on each member of the cohort. Bd has **no native field** that says
"this defer was set on behalf of gate X" — so when the gate lifted on
2026-05-03, the `Deferred: 2026-07-01` stamps it had applied to every V1
epic were **never cleared**. The cohort stayed invisible to `bd ready` for
two weeks; epics only progressed because audit sweeps pointed agents at
them directly.

That stale-defer-outliving-its-gate is the **origin** of the R2 cascade-
starvation (claude-tools-fyx). Fix R3 and R2 stops recurring every gate
cycle.

## The convention

A defer applied **on behalf of a gate** carries the gate's id as a bd label
on the same bead:

    Deferred: 2026-07-01
    Labels:   gate:impl-gate-2026-04-22  …

The label is the **source of truth** for "which gate owns this defer".
Anything that stamps a defer for a gate MUST also stamp the label — and
the canonical way to do both at once is `gate-defer.sh apply`.

### Gate-id shape

Lowercase letters, digits, hyphens; must start with a letter or digit. The
existing free-text gate names (e.g. `impl-gate-2026-04-22`) already match.
The helper rejects anything else with exit 2.

## Naming — NOT to be confused with the pickup gate

This is the **cohort/release gate** seam. It is independent of the
**pickup-time gate-policy** (`gate-policy.sh`, `agents/gate-policy.md`)
which is keyed on `preset:*` labels and decides "may the runner auto-claim
this one bead". Both call themselves "gate"; they are different concerns:

| concern | seam | label | answers |
| --- | --- | --- | --- |
| cohort hold / release | this doc | `gate:<gate-id>` | "is this bead held by gate X?" |
| pickup eligibility | `gate-policy.sh` | `preset:<value>` | "may the runner pick this up?" |

## Usage

    # Apply: stamp Deferred + the gate label in one step.
    gate-defer.sh apply impl-gate-2026-04-22 claude-tools-abc 2026-07-01

    # Apply WITH a why (an agent placing a Gate): also records the Gate's
    # metadata in the engine via gate-meta-set, in the same call.
    gate-defer.sh apply audio-redesign claude-tools-abc 2026-07-01 \
        --why "blocked on the audio-redesign decision" \
        --unblock "design J ratified" \
        --owner "agent:impl" --scope cohort

    # Lift: dry-run first (the default) — shows what would clear.
    gate-defer.sh lift  impl-gate-2026-04-22

    # Lift for real — clears Deferred AND removes the gate label on each.
    gate-defer.sh lift  impl-gate-2026-04-22 --commit

    # Audit: print every bead currently held by the gate.
    gate-defer.sh list  impl-gate-2026-04-22

### Apply metadata — the why/unblock/owner write seam (claude-tools-escz)

The bare `apply <gate> <bead> <date>` only places the `gate:<id>` label + defer
— the cohort source of truth. An **agent that holds work** must place a Gate
*with a why* (DESIGN J §6 / `design/gates.md`; the thirsty invisible-defer fix,
D.3 "nothing is held invisibly"). The optional flags do that in the **same**
call, so the label and its metadata can never drift:

- `--why <text>` — **required** whenever any metadata flag is given. A Gate
  always carries a why; the engine rejects a why-less write.
- `--unblock <text>` — the condition that would lift the Gate (free text or a
  ref). Surfaces as `unblocks_when` on the Gates facet / Board.
- `--owner <who>` — an **input, not the principal** (§2.3). An agent passes
  `agent:<hat-id>` (e.g. `agent:impl`); the GUI passes `you`.
- `--scope task|cohort` — the closed D.2 enum; defaults to `task` when omitted.

The metadata is written via the J1 `gate-meta-set` op over the `co_request`
transport, so it lands in the **live** hosted `gate_metadata` table (the same
row the Gates facet / `holds[]` projection read back). If that write fails after
the label is placed (engine unreachable / rejected), `apply` exits **5** — the
label (source of truth) stands and the hold renders B.4-degraded (`why:null`)
until re-run with the engine reachable. The label↔defer coupling itself never
depends on the engine being up.

### Lift semantics

- **Default is dry-run.** The flag is `--commit`, not `--dry-run` — the
  safe path is the default path. This is the guard Brian flagged in the
  ask-brian dossier ("gate-lift un-defers en masse").
- **Lift is unconditional.** Option-A foreclosed restoring a bead's prior
  (pre-gate) defer; lift clears to empty. If a bead needs a *new* defer
  after the gate lifts, set it explicitly with `bd update --defer`.
- **Partial failure is not a strand.** If `bd update` fails on one bead in
  the cohort, the script keeps going, surfaces the failure on stderr, and
  exits 3 with `failed=<n>` in the summary. The whole cohort is not held
  hostage to one bad row.
- **Lift removes ONLY the gate label.** Other labels (priority, lifecycle,
  workspace) are untouched. The asserted invariant is in case 4 of the
  test harness.

## Tests

`beads-runner/test-gate-defer.sh` drives the helper against a stateful
fake `bd` (same pattern as `test-bd-stage.sh`). 8 assertions cover:
apply does both stamps; invalid gate-id rejected; dry-run is the default;
`--commit` clears defer + gate label while leaving foreign labels alone;
empty cohort lifts cleanly; `list` is exact; a single update failure
yields exit 3 without stranding the rest; bare invocation prints usage.
