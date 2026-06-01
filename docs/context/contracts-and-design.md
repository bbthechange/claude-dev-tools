# Context: The frozen contracts & design canon (the law)

> One-liner: a **map of the law** — the four anti-drift contracts (A/B/C/D), the
> frozen `§`-clause interface, and the design docs (the WHAT). This doc is mostly
> POINTERS: it tells you WHICH big doc to open and what it binds, so you file a
> conforming bead and review for drift. It does NOT re-spec them.

**Read this doc when** your task is: filing a bead under either epic, reviewing a
swarm's output for conformance, deciding whether a behavior is "creative" or
"wrong," or you just need to know which authoritative doc owns a rule. A bead that
violates Contract A/B/C/D or an INTERFACE.md `§`-clause is **wrong, not creative.**

**Owns / scope (the docs this doc indexes — all under `beads-runner/`):**
`UX-V2-ARCHITECTURE.md` (Contracts A/B/C/D) · `INTERFACE.md` (frozen cross-tier `§`)
· `DESIGN.md` (architecture decisions AD1–AD8) · `UX-DESIGN.md` + `UX-DESIGN-V2.md`
(the WHAT: Flows A–L) · `MACHINE-STATE.md` (D2 telemetry) ·
`BEHAVIORAL-CONTRACT.md` (the runner SCAR gate) · `design/*.md` (per-track design
deliverables H/I/J/K/N + the agent-action substrate + the v2 gap).

**Not here (go to the right doc):** the **code** that binds these contracts. Every
other context doc is "the binding for one contract." Engine ⇒ `engine-cloudflare.md`;
bash oracle ⇒ `lib-shared.md`; runner ⇒ `runner.md`; daemon ⇒ `daemon.md`; web ⇒
`web-shell.md` + `web-board.md` + the facet docs; notifications pipeline ⇒
`notifications.md`; how to run the gates ⇒ `testing.md`. The system map / naming
traps / "how to pick a doc" ⇒ `overview.md`.

---

## Mental model

These docs are **frozen contracts**, not suggestions. The whole apparatus exists to
fight one failure mode: **drift** — N fresh-context agents each build half a seam
and the halves don't meet (the documented "wired-but-not-actually-live" scar family
`4xe 2dk bgw 56h qxz`). Three rules carry the defense (`docs/HANDOFF-UX-V2.md §3`):

1. **The contracts are law.** A/B/C/D (in `UX-V2-ARCHITECTURE.md`) and the
   `§`-clauses (in `INTERFACE.md`) define correct. Conform at the edges; don't
   reinvent inside a flow.
2. **Beads dependencies ARE the drift guard.** A **DESIGN bead blocks its impl
   beads** (impl can't be claimed until the design is done — "the whole point of
   beads"). C-shell blocks every facet UI. Use *targeted* `blocked-by` edges, never
   a blanket HOLD bead (Brian rejected that — it leaves you coming back to nothing).
   Verify with `bd dep tree <epic>` / `bd dep cycles`.
3. **Don't silently edit a frozen doc.** A real insufficiency is a `§11`
   escalation: stop, reopen the freeze bead, amend the section + bump the version,
   re-freeze (Brian sign-off or a pre-authorized settled call), *then* resume citing
   the new version. A local divergence is a contract violation, not a shortcut.

**The two epics** (`docs/HANDOFF-UX-V2.md §2`):
- **`claude-tools-mhcp`** (label `ux-v2`) — the UX v2 overhaul: Blueprint, Gates,
  Activity, Cross-WS, Queue-Health, Inbox-leaks, Notifications. Built on A/B/C/D.
- **`claude-tools-v2cut`** (label `v2-cutover`) — finish + cut over `runner.sh` (v2),
  retire `run-beads-tasks.sh` (v1). Gated by `BEHAVIORAL-CONTRACT.md` (SCAR gate).
  (`claude-tools-rznj` is the parallel testing-strategy epic — see `testing.md`.)

## Key files (which doc owns which law)

| Doc | What it is / when to read it |
|---|---|
| `UX-V2-ARCHITECTURE.md` | **The spine — Contracts A/B/C/D.** Read before filing ANY mhcp bead. §2 A, §3 B, §4 C, §5 D; §6 track breakdown; §7 the must-protect list; §9 open decisions; §10 traceability. |
| `INTERFACE.md` | **The frozen cross-tier `§`-clause contract** (v2, FROZEN, freeze bead `claude-tools-65z`). The four §2 capabilities, §4 store schemas, §5 Dossier (Mermaid), §7 STUCK, §9 auth, §11 binding-map + change protocol. The engine + bash oracle bind this verbatim. |
| `DESIGN.md` | **Architecture decisions AD1–AD8** (the design counterpart to UX-DESIGN). AD7 = the Dossier model; §3.1 = dossier-builder dispatched by ask-brian MCP; §3.2 = Local Agent is a per-machine *daemon*, not a sourced lib; AD8 = resume-dispatch + parallel-work boundary. |
| `UX-DESIGN.md` (v1) | **The WHAT, v1: Flows A–G** + §0 requirement provenance (Brian-asked vs agent-added) + §2.1 the 7-hat specialist model. Frozen-with-amend-ledger; the contract for the parts that don't change. |
| `UX-DESIGN-V2.md` | **The WHAT, v2 overhaul: Flows H–L** + §2 surfaces + §11 the 12 cross-cutting principles (the acceptance lens). Supersedes v1 only inside the four §0.D spine decisions. The authoritative source for v2 Brian-vs-agent provenance. |
| `MACHINE-STATE.md` | **D2 per-machine telemetry contract** (v1, FROZEN). The wire format + storage + the `machines[]` snapshot strip. Binds to INTERFACE §4.5 (never edits it). See `notifications.md`/`daemon.md` for producers. |
| `BEHAVIORAL-CONTRACT.md` | **The v1 runner SCAR gate** (READ-ONLY characterization of `run-beads-tasks.sh`). Every **SCAR** must survive the v2 rewrite; every **SCAFFOLDING** must NOT be ported faithfully. The acceptance bar for `v2cut`. |
| `design/blueprint.md` (H) | Flow H design — Blueprint `§4` record + customization layer + updater. Behind `uxvh1..5`. |
| `design/activity.md` (I) | Flow I design — activity enum, runner-vs-agent split, parallel aux. Behind `uxvi1..5`. Never tightens 90/180. |
| `design/gates.md` (J) | Flow J design — `gate_metadata` (transient) + 3-mechanism Hold unification + runner-respect. Behind `uxvj1..5`. |
| `design/cross-ws.md` (K) | Flow K design — `relay-log-tail`, FE↔BE sync, batching (K3). Behind `uxvk1..5`. |
| `design/notifications.md` (N) | Notification delivery + tiers + trigger catalog + ready-to-pair. Behind N1/N2/N3 (`uxvn1`,`uxg1`,`uxg6`). See `notifications.md`. |
| `design/agent-action.md` | The **shared** host-side executor op that J3 (lift/add gate) and I4 (stuck actions) both call — froze the seam neither H/J doc pinned. |
| `design/v2-gap.md` | `runner.sh` (v2) vs v1 gap analysis — sizes the `v2cut` port-forward. The v2 rewrite is finished + conformance-GREEN, not a skeleton. |

## Contracts & invariants (the crisp restatement — open the doc for detail)

- **Contract A — backend op & data conventions** (`UX-V2-ARCHITECTURE.md §2`).
  - *A.1 add-an-op checklist:* module → coordinator guard → Pages function →
    **local adapter** → migration → **live-verify before close**. The adapter (2dk)
    and live-verify (bgw) steps are the ones agents forget.
  - *A.2 storage class:* **§4 record** (owned, addressable, versioned, may appear in
    the projection/notification body) vs **transient namespace** (telemetry, logs,
    dedup, ephemeral aggregation). Hard to move later — pick right.
  - *A.3 projection-field rule (56h):* every UI-visible field is derived inside
    `workSnapshot()` and **named in Contract B** before either side builds it.
- **Contract B — the read-model projection** (`UX-V2-ARCHITECTURE.md §3`). ONE JSON
  (`work-snapshot`) is the backend↔frontend seam. **Each track owns a named
  sub-object** so four agents editing `reconcile.js workSnapshot()` don't collide:
  `activity` (Flow I), `holds` (Flow J), `queue_health` (Q), `blueprint_meta`
  (Flow H). New UI field ⇒ named in B ⇒ emitted by `workSnapshot()`; UI never reads
  a key B doesn't promise. Also: `blueprint-get` (B.2), `relay-log-tail` (B.3).
- **Contract C — frontend app-shell** (`UX-V2-ARCHITECTURE.md §4`). `web/shared/`
  (net/dom/tokens/shell); the **Workspace-hub nav** = 5 global routes
  (Inbox · Workspaces · Capacity · Cross-WS) + 4 workspace facets
  (Board · Blueprint · Activity · Gates); switching a facet never leaves the
  workspace context. Pure `deriveXView` UMD + Node-test pattern. The Inbox stays
  the product (the only push surface). Built once (C-shell, done); facets plug in.
- **Contract D — vocabulary & closed enums** (`UX-V2-ARCHITECTURE.md §5`).
  - *The noun split:* **Blueprint** (living design+map, `§4` record) ≠ **Dossier**
    (ephemeral Inbox card). **Hold** umbrella = Dependency / Scheduled / **Gate**
    (a *named* hold, GUI-add/removable, runner-respected, `gate:<id>`) ≠
    **Checkpoint** (a lifecycle decision point — old "GATE (you)").
  - *Closed enums (shared verbatim):* activity-state `writing-code | running-tests |
    exploring | thinking | waiting-on-you | rate-limited | maybe-stuck` with
    `state_confidence:"derived"` always; liveness dot green <90s / amber 90–180s /
    red >180s (**the 90/180 thresholds are measured — do NOT tighten**); notification
    tier `blocking | timed-fyi | digest`; hold type `gate | dependency | scheduled`;
    done sub-state `done·code | done·verified`.
- **INTERFACE.md is immutable once `claude-tools-65z` closed.** The four §2
  capabilities are exactly four; the §4 record set + Dossier schema version are
  gated. Insufficiency ⇒ §11 escalation (above), not a local divergence.

## Common changes (recipes)

**Filing a bead under `mhcp`:** identify the flow (H/I/J/K/N/L/Q) and its design doc
under `design/`; cite the Contract A/B/C/D clauses it leans on (the design doc's
blockquote already names them); wire `--blocked-by` to its DESIGN bead if the design
isn't done. A web-touching bead is **not done until deployed + verified** (the bgw
lesson — `wrangler pages deploy` + `verify-pages-deploy.sh mismatches=0`).

**Reviewing the swarm for drift** (`docs/HANDOFF-UX-V2.md §3.3`, the high-value
recurring task) — run two audits: (1) **design-quality** — does each design doc
conform to A/B/C/D, is it substantive, does its self-proposed impl split match the
filed beads, do sibling designs agree where they touch? (2) **coverage** —
section-by-section through `UX-DESIGN-V2.md`, map every capability → a bead or a GAP
(lean toward flagging; a false "covered" is a wasted weekend).

**Amending a frozen doc** — explicit section + rationale + date; reopen the freeze
bead; bump the version (and any `*_schema_version`); re-freeze. The `[spine]` seams
in A–D especially: changing one is a cross-flow event. The §11 precedent to copy is
INTERFACE.md v1→v2 (the Mermaid amend) and the amend ledgers at the top of each doc.

**Gate (no code in this doc):** there is nothing to run here. The conformance gate
for the code that *binds* these contracts is `beads-runner/run-tests.sh` (the
`contract` tier is the A–D + machine-state guardian) — see `testing.md`.

## Gotchas / scars

- **"Creative" is usually "wrong."** When an impl looks clever but diverges from a
  contract, the contract wins. The exception path is §11, not improvisation.
- **The amend ledgers are load-bearing history.** DESIGN/UX-DESIGN have multiple
  same-day AD7/Flow-B re-amends (the dossier author flip-flopped worker-in-session →
  dossier-builder-via-ask-brian-MCP). Read the *latest* row; the producer identity
  is "a fresh dossier-builder agent dispatched by the ask-brian MCP server."
- **MACHINE-STATE.md is NOT an INTERFACE amendment** — it defines the channel
  INTERFACE §4.5 already named. A conflict ⇒ reopen `65z` + amend INTERFACE, never
  edit MACHINE-STATE silently (its §C says so).
- **The must-protect list (`UX-V2-ARCHITECTURE.md §7`) is the review checklist** —
  12 spots where a fast, plausible build is subtly wrong (close-on-local-green,
  projection drops a field, updater clobbers a human customization, "always-FYI"
  becoming 45 pings, re-overloading "gate," asserting derived status as truth, …).
- **Vocabulary in prose:** use the component names *workspace runner / per-machine
  daemon / hosted engine / dossier-builder agent / ask-brian MCP tool / Inbox /
  Board*. Avoid the section-symbol in human-facing prose; reserve `INTERFACE.md §4.5`
  / `UX-V2-ARCHITECTURE.md §3`-style only as a precise reference, never as filler.

## Go deeper

- The docs themselves (all `beads-runner/`): `UX-V2-ARCHITECTURE.md`, `INTERFACE.md`,
  `DESIGN.md`, `UX-DESIGN.md`, `UX-DESIGN-V2.md`, `MACHINE-STATE.md`,
  `BEHAVIORAL-CONTRACT.md`, `design/*.md`.
- `docs/HANDOFF-UX-V2.md §3` — the anti-drift method (contracts-as-law, beads-as-
  guard, swarm review). `§2` = the two epics; `§9` = the UX-v2 key-files index.
- `docs/HANDOFF.md` — the older rescue-epic map; lists the design docs as frozen and
  the original "wired-but-not-live" scar (`§63`).
- `docs/context/overview.md` — the system map + how to pick the right context doc.

## Keeping this doc current

When you finish a task here, append anything a future agent needs and didn't find:
a new contract clause, a new frozen doc, a fresh `§11` amend (and its version bump),
a renamed/added design-track doc, a new must-protect entry. This doc is an **index** —
when a doc moves or a contract changes, fix the one-line pointer; do NOT copy the
big doc's body in here. Delete stale lines. **Keep it concise — it earns its keep
only if agents read all of it.** Last substantive update: 2026-05-31.
