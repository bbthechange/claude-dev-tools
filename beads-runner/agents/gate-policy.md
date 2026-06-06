# Gate policy — the constant table (L2, claude-tools-1tu)

> L2 — DESIGN.md §5 C1 S-3, integrating into the L1 stage seam
> (`bd-stage.sh` / `agents/lifecycle.md`). The v1 gate policy is the
> **minimum honest realization of autonomous-until-stuck**: transitions
> auto-advance by default; GATE (Brian) fires only on the three named
> occasions below. The runner reads this table on pickup.

## The contract

Keyed by **(stage, transition)** → one of:

- `auto-advance` — the runner picks the bead up and runs it autonomously.
- `gate-human` — the runner does NOT pick the bead up; it surfaces it as
  a human-facing item (an Inbox "ready to pair" row for collaborative
  preset; a Flow F overview dossier for the design-checkpoint FYI)
  and continues to the next ready bead.

Per the L1 spine the closed stage enum is
`idea | ux | design | impl | docs | tests | done`. The transition keying
is the **stage the bead is currently AT** when it appears in `bd ready`
(i.e. the stage the worker will advance OUT OF). `done` is terminal and
never a pickup stage; an unstaged (legacy) bead defaults to
`auto-advance` so the runner does not strand legacy work.

## The table (v1)

| current stage | autonomous-until-stuck (default) | collaborative-stage preset |
| --- | --- | --- |
| `idea`   | auto-advance | gate-human (ready to pair) |
| `ux`     | auto-advance | gate-human (ready to pair) |
| `design` | auto-advance | gate-human (ready to pair) |
| `impl`   | auto-advance | gate-human (ready to pair) |
| `docs`   | auto-advance | gate-human (ready to pair) |
| `tests`  | auto-advance | gate-human (ready to pair) |
| _unstaged_ | auto-advance | gate-human (ready to pair) |

This is the **MINIMUM HONEST REALIZATION** Brian asked for in DESIGN.md
§5 C1 S-3: an `always-manual` policy would gate every stage boundary and
starve the runner — directly conflicting with §0.A "the runner keeps
running." Autonomous-until-stuck is the workhorse; the table reflects
that with `auto-advance` as the default everywhere.

## The 3 GATE points (where Brian actually gets paged)

The table looks one-dimensional because **the v1 GATE surface is mostly
not at pickup** — it lives in three places, only one of which the
runner pickup gate enforces:

1. **The bead's preset is `collaborative-stage`.** (Pickup gate — owned
   here.) The human asked to be *in* a stage with the agent, not just
   approve its output. The runner sees `preset:collaborative-stage` on
   the bead and routes it to the Inbox as **"ready to pair on \<title\>"**
   instead of running it. The bead is set `status=blocked` + `human`
   label so the Coordinator's snapshot projection picks it up; the
   runner appends a `READY_TO_PAIR` note for context and moves to the
   next candidate.

2. **The worker raised `STUCK_NEEDS_HUMAN`.** (Worker signal, not pickup
   gate.) The worker emits the structured ask via the `ask-brian` MCP
   tool, or the §7.2(b) `permission_denials[]` / EnterPlanMode backstop
   fires — the runner's `_drive_blocked_for_human` then writes
   `status=blocked` + `human` label and hands the dossier to the
   Coordinator. The gate-policy table does NOT separately encode this:
   it is the runtime path, not a stage-transition decision.

3. **The proactive design-checkpoint FYI (Flow F overview dossier).**
   (Stage-change observer, not pickup gate.) When a bead transitions
   *out of* `design` (worker calls `bd-stage set <id> impl`), the
   stage-change observer (P1, claude-tools-3pq) fires a Flow F overview
   dossier as a `timed-fyi` item. This is a **soft FYI, not a hard
   pickup gate** — the bead at `stage:impl` still picks up autonomously
   (see the table row above). The FYI gives Brian a parallel
   understanding-check; if he objects he can set the bead to
   collaborative or block it manually.

So the L2 pickup gate's only enforced gate is **(1) the collaborative
preset**. (2) and (3) are listed in the table doc to make the v1 GATE
surface fully named and bounded — every other transition auto-advances
unconditionally. That is the minimum honest realization.

## How the runner consults the table

`beads-runner/gate-policy.sh decide <bead-id>` is the one chokepoint. It
reads the bead's `stage:*` and `preset:*` labels (via `bd label list`)
and prints exactly one of:

- `auto-advance`
- `gate-human:collaborative-stage`

The runner calls it after `bd ready` selects a candidate and before the
lease acquire — so a gate-human bead never burns a lease or an
in-progress write. See `runner.sh` `st_reconcile`.

## Label conventions L2 introduces / consumes

- `stage:<value>` — owned by L1 / `bd-stage.sh`. L2 reads it.
- `preset:autonomous-until-stuck` — the default preset; absence of any
  `preset:*` label is treated as this default (the enricher S3 may
  elide it for the common case to keep the bead label set quiet).
- `preset:collaborative-stage` — the explicit collaborative preset. The
  enricher (claude-tools-bnq) sets this on intake when the human taps
  the collaborative entry-intent preset (see UX-DESIGN §0.A Flow A).
  L2 reads it and routes the bead to the Inbox via the existing
  `status=blocked` + `human` label channel.

Adding a preset = adding a row here and ONE `value:gate` data row to
`PRESET_ENUM` in the lookup script — **no code branch** (claude-tools-uxgpre
generalized `_decide_from_stage_preset` to derive the verdict from the
preset's `gate_aggressiveness`, so the enum is the only thing to touch). The
default-on-absence rule means a new preset that means "still autonomous"
needs no script change for beads that carry no `preset:*` label.

## Why this is `auto-advance | gate-human` and not richer

L2 v1 deliberately has **only two outcomes**. A richer surface
(`fyi-soft`, `dossier-required`, `pair-required`) was considered and
deferred:

- `fyi-soft` is what the Flow F overview dossier (GATE point 3) wants;
  but it is a **stage-change observer's job, not a pickup gate's** —
  P1 (claude-tools-3pq) owns the observer, and from the pickup gate's
  perspective the bead still auto-advances.
- `dossier-required` is what `STUCK_NEEDS_HUMAN` (GATE point 2) wants;
  but it is **emitted at runtime by the worker**, not decided at
  pickup. The `_drive_blocked_for_human` path handles it.

So the only outcome the pickup gate ever produces beyond `auto-advance`
is `gate-human:collaborative-stage`. The two-valued surface is the
right shape for L2's scope.

## Adding a transition rule

The closed stage enum is the L1 contract. To add a row:

1. Make sure the stage exists in `STAGE_ENUM` in `bd-stage.sh`.
2. Add the row to the table above (this doc is the source of truth).
3. Add the `value:gate_aggressiveness` data row to `gate-policy.sh`
   `PRESET_ENUM` (the verdict is derived generically — no `case` branch to
   add since claude-tools-uxgpre).
4. Add the case to the L3 board rendering (claude-tools-2bf).
5. Run `beads-runner/test-gate-policy.sh` AND
   `beads-runner/test-intake-presets.sh` (the latter asserts the
   `PRESET_ENUM` gate token agrees with the catalog and that
   `gate-policy.sh decide` resolves the new preset end-to-end).
