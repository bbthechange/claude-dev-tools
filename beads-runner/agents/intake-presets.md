# Intake preset catalog (I4 · claude-tools-vvh)

> UX-DESIGN.md §0.C — *Entry-intent preset catalog. Start with the two named
> in Flow A; grow the list from real usage. Each new preset must reduce to
> **(entry stage, gate aggressiveness)** so the spine stays legible.*

## What this is

The **canonical list** of entry-intent presets — the radio cards on the
phone Intake (Flow A), and the `preset` field the enricher hat (S3,
`agents/enricher.system.md`) consumes when it turns a phone-tap into a
structured `bd create`. The catalog is intentionally **closed** in v1; new
presets ship as a deliberate code change so the spine — *(entry stage,
gate aggressiveness)* — stays legible at a glance.

Single source of truth: **`agents/intake-presets.json`** (this directory).
Everything else is a downstream mirror or a documented consumer.

The **general "tap a named preset" affordance** — the catalog-driven picker
and the extensibility of the whole catalog *beyond* the seed two — is owned
by **claude-tools-uxgpre** (it generalized the L2 verdict derivation so
adding a preset is a pure-data, harness-enforced one-PR change; see the
playbook below). A *specific* preset that breaks the reductive contract is
its own bead — e.g. `overview-request` (claude-tools-uxvl4 / L4), which
produces **no bd task** and routes to a Blueprint/FYI. It **has shipped**: it
lives as a SPECIAL catalog row (the catalog still owns the row so the UI
renders it + the write proxy allow-lists it) but its *behavior* is
daemon-side. See "Special presets (no bd task)" below.

## The reductive contract

Every preset reduces to exactly two axes — no more — so the runner's L1
(stage) + L2 (gate) seams keep working without a third dimension:

| axis | values | owned by |
|---|---|---|
| **`entry_stage`** | one of `idea \| ux \| design \| impl \| docs \| tests` | L1 stage spine (`bd-stage.sh`, `agents/lifecycle.md`) |
| **`gate_aggressiveness`** | `auto-advance` \| `gate-human` | L2 gate policy (`gate-policy.sh`, `agents/gate-policy.md`) |

If a proposed preset cannot reduce to that pair (e.g., "sometimes
auto-advance, sometimes gate, depends on the bead's title"), it does
**not** belong in this catalog — surface the request as a normal bead and
have a design conversation first. The whole point of the spine is that an
agent or a human reading a bead's labels in 2026 can tell what will happen
to it.

## v1 catalog

| `value` | UI label | `entry_stage` | `gate_aggressiveness` | one-line meaning |
|---|---|---|---|---|
| `autonomous-until-stuck` (default) | Send it down the pipeline | `impl` | `auto-advance` | Runner picks it up at impl; surfaces only on a worker fork. |
| `collaborative-stage` | Go over the UI with me | `ux` | `gate-human` | Lands at ux as a "ready to pair" Inbox item; runner does not pick up. |

The structured form lives in `intake-presets.json`. The table above is a
human-readable view of the same data; if the two ever drift, **the JSON
wins** — that is the file every consumer reads.

## Who consumes the catalog (the wiring map)

```
                 agents/intake-presets.json   ← single source of truth
                          │
            ┌─────────────┼───────────────────────────────┐
            ▼             ▼                               ▼
   web/functions/api/     agents/enricher.system.md   gate-policy.sh
   intake/_presets-        (prompt-resolution           (L2 preset enum,
   catalog.js              table, §"Entry stage          PRESET_ENUM —
   (Pages-side MIRROR;     label" bullet)               `value:gate` rows
   imported by both        The enricher reads the       must agree with the
   intake/index.js [write] JSON at run-time and          catalog value+gate)
   and intake/presets.js   uses it to pick (stage,
   [read proxy].           gate). Adding a row here
   The browser fetches     means adding a bullet
   /api/intake/presets     in the resolution table.
   and renders radio
   cards from it.)
```

The browser does **not** know about the catalog at compile time — the
preset radios are rendered from the live `/api/intake/presets` response,
which a Pages function serves off the same JS mirror that `/api/intake`
validates against. That collapses the "two-step UI + proxy" sync hazard
from the I1 README into a single mirror file inside the Pages tree.

## Adding a preset — the one-PR playbook

The acceptance criterion for I4 (`claude-tools-vvh`): **adding a new
preset is a documented one-PR change.** That PR touches exactly these
files. Anything else is a hint that the spine is being violated.

1. **Append a row to `agents/intake-presets.json`** with all five fields:
   `value`, `label`, `sublabel`, `entry_stage` (must be in L1
   `STAGE_ENUM`), `gate_aggressiveness` (one of `auto-advance` /
   `gate-human`), `description`.

2. **Mirror it in
   `web/functions/api/intake/_presets-catalog.js`** — the Pages-side
   mirror that both the read proxy (`intake/presets.js`) and the write
   proxy (`intake/index.js`) import. Same five fields, same `value`, no drift.
   This is the only file that has to be updated by hand alongside the
   JSON — Pages Functions cannot read across the repo tree at request
   time, so the mirror is the pragmatic shape.

3. **Add one bullet to the enricher hat's "Entry stage label"
   resolution table** in `agents/enricher.system.md`. The bullet must
   say exactly: <code>`&lt;value&gt;` → `bd label add &lt;id&gt;
   stage:&lt;entry_stage&gt;` + `bd label add &lt;id&gt;
   preset:&lt;value&gt;` (gate: &lt;gate_aggressiveness&gt;)</code>. This
   keeps the enricher's resolution one-line-per-preset; if it needs more,
   that is the signal that the preset is not reducible (see "the
   reductive contract" above).

4. **If `gate_aggressiveness` is anything other than `auto-advance` or
   `gate-human`** — stop. Those are the only two L2 verdicts (see
   `agents/gate-policy.md`). Adding a third verdict is an L2 change, not
   an I4 catalog change, and needs its own bead.

5. **If `entry_stage` is a stage not in `STAGE_ENUM`** — stop. Adding a
   stage is an L1 spine change (see `bd-stage.sh`), not an I4 catalog
   change.

6. **Append a `<value>:<gate_aggressiveness>` row to `PRESET_ENUM` in
   `gate-policy.sh`** (e.g. `my-preset:gate-human`). Since
   claude-tools-uxgpre, `gate-policy.sh` derives the verdict GENERICALLY
   from this gate token — `auto-advance` → `auto-advance`, `gate-human` →
   `gate-human:<value>` — so there is **no `case` branch to add**. The enum
   row is the only edit. (An unknown preset still fails-CLOSED with
   `gate-human:unknown-preset`; the gate token must match the catalog row's
   `gate_aggressiveness` exactly.)

7. **Run `bash beads-runner/test-intake-presets.sh`.** The harness
   enforces every step above: JSON schema + value enums, **no duplicate
   values**, mirror PRESETS[] order/values, **schema_version JSON↔mirror**,
   `PRESET_ENUM` carries each catalog `value:gate` (token must match), the
   enricher names each value, AND — the end-to-end proof —
   **`gate-policy.sh decide` resolves a correct, non-empty verdict for
   every catalog preset** (so "added the data, forgot the wiring" is caught
   here, not silently degraded at runtime). If you skipped a step, this
   fails with a `DRIFT:` line pointing to the file that needs updating.

That's it. One JSON row + one mirror row + one bullet + one `value:gate`
enum row, all in one PR — and the harness fails the PR if any of those is
missed.

## Special presets (no bd task) — the `routing` escape hatch

Most presets reduce to `(entry_stage, gate)`. A **special** preset deliberately
does NOT: it produces no bd task and routes daemon-side. `schema_version 2`
(claude-tools-uxvl4) added one optional field to support this:

- **`routing`** (string, OPTIONAL). Present ⇒ the row is special and is EXEMPT
  from the reductive-contract harness checks (stage enum, gate enum,
  `PRESET_ENUM`, `gate-policy decide`, enricher-mention). A special row MUST then
  carry `entry_stage:null` + `gate_aggressiveness:null` + a *known* `routing`
  value. The only value today is **`overview-fyi`** — the `overview-request`
  preset (L4): the daemon's `intake-dispatch-poll.sh` branches on the preset
  VALUE and routes it to a dossier-builder → `proactive_checkpoint` `timed-fyi`
  (a Blueprint refresh / FYI), instead of the enricher. No `bd create` runs.

The **record only carries the preset `value`**, never `routing` — so the daemon
branches on the value (`overview-request`), and the catalog `routing` field is
the *signal* that drives the harness exemptions + the daemon-branch lockstep.

**Adding a special preset is a different one-PR shape than the normal playbook:**

1. Append a row to `agents/intake-presets.json` with `entry_stage:null`,
   `gate_aggressiveness:null`, `routing:"<known>"`, plus value/label/sublabel/
   description. Mirror it in `_presets-catalog.js` (lockstep, byte-identical
   description).
2. Do NOT add a `PRESET_ENUM` row or an enricher resolution bullet — a special
   preset never reaches L2 or the enricher.
3. Add a daemon branch in `daemon/intake-dispatch-poll.sh` that recognizes the
   value and routes it (the `daemon_intake_dispatch_overview` pattern). If the
   `routing` value is new, extend `KNOWN_ROUTING` in `test-intake-presets.sh`.
4. `bash test-intake-presets.sh` — check 10 fails the PR if the special value is
   not branched on in the daemon (else an unhandled special preset would fall
   through to the enricher and choke on the null `entry_stage`).

## What deliberately stays out

- **Per-stage gate verdicts.** A preset is *one* gate verdict applied
  uniformly across the L1 stages it touches — that is the "spine stays
  legible" rule. A preset that wants "auto-advance at impl, gate at
  tests" is the wrong shape; it is two beads, or a stage-change
  observer (P1 / Flow F), not a preset.
- **Workspace-specific presets.** The catalog is per-deployment, not
  per-workspace. If a workspace needs different defaults, that is a
  workspace-level convention (a `CLAUDE.md` rule the enricher reads)
  rather than a catalog row.
- **Priority / type / parent-epic defaults.** A preset only carries the
  entry stage and gate aggressiveness. Priority / type / dep choices
  remain the enricher's judgement (per `enricher.system.md`).

## Acceptance for I4 (this issue)

- `agents/intake-presets.json` is the single canonical file (this
  document).
- The Intake UI reads the radio set from `/api/intake-presets` at
  page-load; no preset is hard-coded in `index.html`.
- The Intake write proxy (`intake.js`) validates against the same JS
  mirror that the read proxy serves.
- The enricher's resolution table reads as a one-line bullet per row in
  the catalog.
- Adding a new preset is the playbook above — verified by inspection
  that each step is local to one file.

## Acceptance for uxgpre (generalize the picker — first-class + extensible)

- `gate-policy.sh` derives the verdict GENERICALLY from the preset's
  `gate_aggressiveness` (the `value:gate` `PRESET_ENUM`); adding a preset
  needs **no per-preset `case` branch**, and an empty verdict can never be
  emitted.
- `test-intake-presets.sh` enforces, beyond I4's checks: no duplicate
  values, `schema_version` JSON↔mirror agreement, `PRESET_ENUM`
  value+gate agreement with the catalog, and — driven against a fake `bd`
  — that `gate-policy.sh decide` returns the correct, non-empty verdict for
  **every** catalog preset (the cross-tier "data shipped but not wired"
  guard).
- Adding a preset beyond the seed two is therefore a verified pure-data
  one-PR change; the harness fails the PR if any tier is missed.
