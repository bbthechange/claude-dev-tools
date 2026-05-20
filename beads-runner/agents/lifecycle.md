# Lifecycle stages — the spine, the enum, the gate policy

> L1 (claude-tools-u6s) — one-page note. Realizes DESIGN.md §5 C1's seam:
> "`stage` is a first-class enumerated field on every bead; every stage
> change goes through one *advance stage* operation; the gate map is an
> explicit policy function keyed by `(stage, transition)`."

## The spine

Every bead carries a **lifecycle stage**. The set is closed:

```
idea → ux → design → impl → docs → tests → done
(intake)  (auto)   (auto)   (auto)   (auto)   (auto, with manual e2e gate)
```

The spine is a *spine*, not a strict pipeline — a bead may enter at any
stage (set by the enricher per the entry-intent preset) and may skip
stages that do not apply (a docs-only bead enters at `docs`, never
`impl`). What is **not** allowed is a freeform stage string or a bead
carrying two stages at once. The closed enum and the "exactly one" rule
are the contract every downstream surface binds to.

## The realization (label convention)

Stages are realized as bd labels of the form `stage:<value>`. The single
chokepoint is `beads-runner/bd-stage.sh`:

```
bd-stage.sh set  <bead-id> <stage>   # remove any prior stage:*, add stage:<new>
bd-stage.sh get  <bead-id>           # print bare stage value (empty if unstaged)
bd-stage.sh list <stage>             # list beads at <stage>
```

`set` is the **one operation** every stage change goes through. It
removes any *prior* `stage:*` label before adding the new one — the
"exactly one" invariant cannot drift even from a caller that forgets to
clear the old label, and a legacy bead with two stage labels is *healed*
by the next `set` rather than masked.

A bead with **no** `stage:*` label is legacy / unstaged — that is the
only honest reading of the acceptance criterion ("every bead has
exactly one stage label or none"). Downstream renderings (L3 board
columns) put unstaged beads in a separate lane; they are not hidden.

## Who sets stage, and when

| Trigger | Setter | What it sets |
| --- | --- | --- |
| **Idea intake** (Flow A) | The **enricher** hat (S3, `claude-tools-bnq`) — the agent that turns a phone-captured idea into a structured `bd create` | The new bead's *entry stage*, derived from the tapped preset: `autonomous-until-stuck` ⇒ `stage:idea`; `collaborative-stage` ⇒ `stage:ux` |
| **Worker advancing** | The worker (the `claude -p` task body) | The next stage when its bead's work is genuinely complete and the next stage's body should pick up — the worker calls `bd-stage set <id> <next>` as a near-last step before `bd close` |
| **Specialist hat handoff** | The hat (ux / design / impl / docs / tests) at the end of its bead | Same as above — the hat is just a worker with a kind-selected system prompt; the transition discipline is identical |
| **Manual correction** | A human (you, on the Board) | Any value, same script |

The enricher is the only setter that uses a *creation-time* preset
mapping; everywhere else, the worker decides based on the work it
actually did.

## The gate policy — minimum honest realization (DESIGN.md C1 S-3)

The gate policy is the **constant table** that decides whether a stage
transition auto-advances or surfaces to Brian. L1 only nails the
**spine + the enum + the script**; the table itself is L2
(`claude-tools-1tu`). The contract L2 must satisfy:

- **Default = auto-advance.** The "autonomous-until-stuck" preset is the
  workhorse; transitions advance without a touchpoint. (S-3 fix in
  DESIGN.md §5 C1: "an `always-manual` v1 policy would gate every stage
  boundary, starving the runner — directly conflicting with §0.A
  `runner keeps running`.")
- **GATE (you) fires only on three named occasions:**
  1. The bead's preset is **collaborative-stage** (the human asked to
     be *in* a stage, not just approve its output) — surfaces as a
     "ready to pair on X" Inbox item.
  2. The worker raised `STUCK_NEEDS_HUMAN` — surfaces as a dossier
     (Flow B).
  3. A proactive **design-checkpoint FYI** (Flow F overview dossier) —
     surfaces as a timed-fyi tier item, *not* a hard gate.
- **Manual e2e is itself a human-task.** The `tests → done` boundary,
  for the e2e-manual portion, routes to the Inbox the same way any
  other decision does. It is not modeled as a special case.

L1 deliberately does **not** ship the table; the seam is the script.
L2 lands the table behind that seam without changing how anyone calls
`bd-stage set`.

## What L1 deliberately does NOT do

- **Does not run on bd pickup.** The runner does not yet read the stage
  on `bd ready` — that is L2's job (gate policy integrated into pickup).
- **Does not render columns.** The Board still groups by ad-hoc labels;
  L3 (`claude-tools-2bf`) swaps in the canonical 7-column rendering.
- **Does not fire the Flow F overview-dossier observer.** That is P1
  (`claude-tools-3pq`) — a stage-change observer triggers Flow F
  proactive dossiers. P1 binds to the same `stage:` label convention.

These deferrals are intentional and traceable: every L1-blocked
downstream issue lists `claude-tools-u6s` as its dependency. The seam
in L1 — the closed enum + the script — is what each one binds to.

## Adding a stage

Don't, casually. The closed enum is constant by design (DESIGN.md
§5 C1: "v1 MUST NOT allow ad-hoc free-text stage labels"). If a real
need surfaces, the change is:

1. Add the value to `STAGE_ENUM` in `bd-stage.sh`.
2. Add the row to the L2 gate-policy table.
3. Add the column to the L3 board rendering.
4. Update this doc's spine diagram.

A new freeform label that *looks like* `stage:foo` but is not in the
enum will be rejected by `bd-stage set` (exit 2). That is the contract
working.
