# UX v2 — Architecture Spine (the anti-drift contract)

Status: draft · Owner: Brian · Author: software-architect agent · Date: 2026-05-29
Scope: **the shared contracts** every UX-v2 flow must conform to. This is the
*how-it-fits-together* layer that sits between `UX-DESIGN-V2.md` (the what) and
the per-flow design/impl beads (the build). It is deliberately small: it fixes
only the seams where independent agents would otherwise drift, and explicitly
leaves everything else free.

> **How to use this doc.**
> - Every **design bead** in the v2 epic is handed this file as required reading.
>   A design that violates a contract here is wrong, not creative.
> - Every **implementation bead** checks its output against the relevant
>   contract section before `bd close`.
> - Where this doc says "**[free]**", move fast and don't ask — it's cheap to
>   change later.
> - Where it says "**[spine]**", that's a get-it-right-once seam; changing it
>   later means re-touching multiple flows. Design carefully; amend explicitly.

---

## 1. Why contracts-first (the division strategy)

The expansion is 8 Brian asks (B1–B8) + 4 spine decisions (C1–C4) + a pile of
carried leaks. That's far too much for one agent and too entangled to hand out
blind. The failure mode we are explicitly engineering against is **drift**: two
agents each build half of a seam and the halves don't meet. This repo has a
documented history of exactly that — the "wired but not actually live" family
(`4xe`, `2dk`, `bgw`, `56h`, `qxz`): five bugs, all the same shape, all a
contract that one side honored and the other didn't.

The antidote is: **fix the seams centrally first, then the pieces are
independent.** Four seams carry essentially all the cross-agent coupling:

| Contract | The seam it fixes | Who would drift without it |
|---|---|---|
| **A — Backend op & data conventions** | How any new capability reaches the engine | Each backend agent invents op-names, record-vs-transient choices, forgets the adapter/proxy layer (2dk) or the live-verify (bgw) |
| **B — Read-model projection v2** | The single JSON the UI reads | Backend omits a field the UI needs (56h); UI invents a shape the backend never emits |
| **C — Frontend app-shell** | Navigation + shared plumbing across 9 views | 9 copy-pasted pages that look and behave differently, no coherent hub |
| **D — Vocabulary & enums** | The words and closed sets both tiers use | "gate" re-overloads (the existing collision); activity-enum differs between the log-parser and the renderer |

Once A–D are frozen, each flow (Blueprint, Gates, Activity, Cross-WS, Queue
Health, Inbox-leaks, Notifications) is a **vertical slice** that touches its own
ops, its own projection fields, and its own view — and conforms to A–D at the
edges. That's what makes them safe to hand to separate agents.

**Two delegation rounds.** (1) A *design* bead per slice produces a focused
design that conforms to A–D. (2) After it lands, *impl* beads (sized to one
agent) build it. Impl beads are `--blocked-by` their design bead; design beads
are ready now because this spine is done.

---

## 2. Contract A — Backend op & data-model conventions  [spine]

The engine is a singleton Coordinator Durable Object + D1, fronted by a Worker
that is the **one** auth chokepoint (`cf/src/index.js:35-109`). Ops are
dispatched in per-module guards inside `cf/src/coordinator.js:228-356`, then a
substrate `switch` (`coordinator.js:358-389`). This shape is frozen; new work
*adds modules and guards*, it does not restructure the substrate.

### A.1 Adding an op — the end-to-end checklist (the 2dk + bgw fix)

A new op is **not done** until every layer below lists it. This is the single
most common drift in this repo. The checklist, in order:

1. **Module.** New concern → new `cf/src/<concern>.js` exporting
   `export const <CONCERN>_OPS = new Set([...])` and
   `export async function handle<Concern>Op(co, op, args, principal)`.
   Mirror the existing modules (`capacity.js`, `machine-state.js` are the
   smallest templates).
2. **Guard.** Add `import` + an `if (<CONCERN>_OPS.has(op)) return await
   handle<Concern>Op(this, op, args, principal)` guard in `coordinator.js`
   `fetch()`, *before* the substrate switch. Keep the substrate switch
   byte-stable (its differential tests must not regress).
3. **Pages function.** Add a proxy under `web/functions/api/<area>/<name>.js`.
   Read proxy → `onRequestGet`, hard-codes the read op. Write proxy →
   `onRequestPost`, hard-codes the op + record type, strips any client-sent
   `principal`, attaches `Bearer` server-side, passes the engine response
   **verbatim**. (Templates: `web/functions/api/board/index.js`,
   `.../board/set-desired.js`.)
4. **Local adapter.** If the op must work in the pages-dev local harness, add
   its REST mapping to `cf/pages-dev/adapter.js` (`argsForGet`/`argsForPost`).
   *(This is the layer 2dk forgot.)*
5. **Migration.** If you added a table, ship `cf/migrations/NNNN_<name>.sql`
   even though the DO lazily DDLs — the migration is the deploy-path source of
   truth.
6. **Live-verify before close.** Deploy and probe the live host. Web-track:
   `wrangler pages deploy` + `verify-pages-deploy.sh mismatches=0`. Engine-track:
   a real authed call against `coordinator-cf.bbthechange.workers.dev` returning
   the new shape. **`bd close` on a passing local test is the bgw failure —
   forbidden.**

### A.2 §4 record vs. transient namespace — the decision rule  [spine]

The engine has two storage classes. Pick correctly; it's hard to move later.

- **§4 record** (the `records` table, via `_writeRecord` → `validateRecord` →
  principal-stamp; registered in `cf/src/schema.js`). Use when the thing is
  **owned, addressable by `(type,id)`, versioned, and may legitimately appear in
  the read-model projection or a notification body.** Adding one = bump
  `SCHEMA_VERSIONS` + migration. Examples today: `dossier`, `runner_state`,
  `notification`, `lease`, `workspace_inventory`.
- **Transient sibling namespace** (its own table, lazy-DDL'd in its module,
  *bypasses* `_writeRecord`/registry; structurally absent from the §4.5
  projection and §4.3 notification bodies). Use for **telemetry, append-only
  logs, dedup/control rows, ephemeral aggregations.** Examples today:
  `capacity_reports`, `machine_state_reports`, `forensic_*`, `stuck_*`,
  `work_plane_ops`.

**v2 application of the rule (binding for design beads):**

| New thing | Class | Why |
|---|---|---|
| **Blueprint** (map JSON + narrative + customization layer) | **§4 record** `blueprint`, id = `project_ref` | Owned, addressable, versioned, *and* it appears in the projection + FYI bodies |
| **Gate metadata** (why / unblock / owner per `gate:<id>`) | **transient** `gate_metadata` table | It annotates a beads-label, has no independent §4 lifecycle, read by join |
| **Cross-WS relay log** | **transient** `relay_log` (append-only, `forensic_audit` precedent) | Append-only audit, no `(type,id)` owner |
| **Per-agent activity state** | **transient** `agent_activity` (latest-wins per agent, `machine_state_reports` precedent) | Ephemeral telemetry, aggregation-only read |

### A.3 The projection-field rule (the 56h fix)  [spine]

The board/inbox read-model is **produced at read time** by
`workSnapshot()` in `cf/src/reconcile.js` — it joins `runner_state` + the work
plane + `machine_state_reports` + capacity, and is **never stored.** Every new
UI-visible field is added **there**, by deriving/joining inside `workSnapshot()`,
and is specified in Contract B before either side builds it. **Symptom to avoid
(56h):** a field exists in a record but the projection drops it, so the UI can
never show it. Rule: *if a view needs it, it is named in Contract B and emitted
by `workSnapshot()` — full stop.*

### A.4 Naming  [free-ish]

Op names: `kebab-case`, `<concern>-<verb>` (`blueprint-put`, `gate-meta-set`,
`relay-log-append`, `agent-activity-report`). Record types + tables:
`snake_case`. These are conventions, cheap to rename within a flow before it
ships — but match the existing set so review is mechanical.

---

## 3. Contract B — Read-model projection v2 (the backend↔frontend seam)  [spine]

This is the **joint contract**: the exact JSON the UI consumes. Backend agents
emit exactly these fields from `workSnapshot()` (and a new `blueprint-get` /
`relay-log-tail`); UI agents read exactly these and nothing else. Field names are
normative. Shapes may be *extended* (new optional keys) freely; existing keys
may not change meaning without an explicit amend.

### B.1 `work-snapshot` (extended). One call powers Workspaces hub + Board + Activity + Gates + Queue-Health.

```jsonc
{
  "schema_version": 2,              // bump from 1; UI gates on integer-≤-bound (4xe pattern)
  "read_only": true,
  "machines": [ /* unchanged: runner_id, pct_5h, pct_7d, today_spare_line, fresh, age_seconds */ ],
  "projects": [
    {
      "project_ref": "rhythmGame",
      "desired": "running", "actual": "running", "liveness": "live",   // carried
      "generation": 123,
      "runner_health": {            // NEW (B4 §5.4) — runner-vs-agent distinction
        "process": "alive|dead", "heartbeat": "fresh|stale",
        "last_pickup_at": "…", "state": "working|idle|starved|wedged"
      },
      "activity": {                 // NEW (Flow I) — derived, honesty-tagged
        "writer": {                 // exactly one, or null
          "bead_ref": "rhythmGame-93o", "title": "…", "stage": "impl",
          "state": "writing-code", "state_confidence": "derived",   // never "asserted"
          "liveness_dot": "green|amber|red", "seconds_in_state": 132,
          "touching": ["Gameplay","Input"]   // domain ids, for Blueprint overlay
        },
        "auxiliary": [              // 0..N read-only agents
          { "kind": "blueprint-update|enricher|xws-responder|tests-readonly|docs",
            "label": "…", "state": "updating-blueprint|enriching|read-only-answer",
            "state_confidence": "derived", "liveness_dot": "green" }
        ]
      },
      "holds": [                    // NEW (Flow J) — unified over 3 mechanisms
        { "type": "gate", "id": "gate:audio-redesign", "task_count": 3,
          "owner": "you|agent:<id>", "set_at": "…",
          "why": "…", "unblocks_when": "…", "editable": true },
        { "type": "dependency", "task_ref": "rhythmGame-77p",
          "blocked_on": "rhythmGame-77a", "unblocks_when": "77a closes",
          "editable": false },
        { "type": "scheduled", "task_ref": "rhythmGame-5kq",
          "deferred_until": "2026-07-01", "owning_gate": "gate:audio-redesign|null",
          "editable": false }
      ],
      "queue_health": {             // NEW (§9) — Board strip
        "ready": 4, "held": { "gate": 3, "dependency": 1, "scheduled": 2 },
        "hidden_under_deferred_parent": 5,
        "net_velocity_7d": 2,       // created − closed/day; positive = runaway alarm
        "epics_with_zero_ready_children": ["rhythmGame-aaa"]
      },
      "blueprint_meta": {           // NEW (Flow H) — card thumbnail + freshness
        "updated_at": "…", "thumb_ref": "…", "active_domains": ["Gameplay"]
      }
    }
  ],
  "cards": [ /* Board cards, carried; each gains: "waiting_on": {hold-ref or null} (§7.5) */ ],
  "intake": [                       // NEW (L3 claude-tools-uxvl3; inbox-lifecycle §9.5 #4)
    // The phone-intake state lane — a top-level array PEER to machines[]/
    // waiting_on_you[] (NOT nested per-project; the Workspaces hub slices it by
    // project_ref). ADDITIVE at the CURRENT schema_version 1 (the machines[]
    // precedent — a new top-level key old v1 views harmlessly ignore; NO version
    // bump). One entry per stored intake-request, carrying the frozen state
    // thread so the 19-silent-retry leak can never be invisible again:
    { "intake_id": "intake-…", "project_ref": "rhythmGame", "preset": "autonomous-until-stuck",
      "state": "received|enriching|created|failing|gave-up",   // the FROZEN thread
      "attempts": 0,                // dispatch_attempts — the (n) in failing(n)
      "idea_excerpt": "…",          // short slice of the submitter's OWN idea_text
      "bd_ref": "rhythmGame-93o|null",   // the bead a `created` intake became
      "outcome": "created|augmented|refused|null",
      "last_error": "…|null",       // the failure reason on failing/gave-up
      "submitted_at": "…", "last_attempt_at": "…|null",
      "processed_at": "…|null", "gave_up_at": "…|null" }
  ]
}
```

> **Amendment (L3 claude-tools-uxvl3, 2026-06-01):** `intake[]` added to the
> work-snapshot top-level shape. It is produced CF-side (`workSnapshot()` →
> `readIntake`/`deriveIntakeState` in `cf/src/reconcile.js`) with NO bash-oracle
> twin — exactly the `machines[]` posture (the differential asserts targeted
> fields, not a deep-equal, so a CF-only top-level key is in-contract). The state
> thread is written by the per-machine daemon (`daemon/intake-dispatch-poll.sh`):
> it counts each enricher dispatch (`failing(n)`), caps retries at
> `INTAKE_MAX_ATTEMPTS` (`gave-up`), and writes an in-flight `enriching` marker.
> Surface: the Workspaces hub (`web/workspaces/`). schema_version stays 1.

### B.2 `blueprint-get(project_ref)` → the `blueprint` §4 record body

```jsonc
{
  "schema_version": 1,
  "project_ref": "rhythmGame",
  "derived": { "nodes": [...], "edges": [...], "apis": [...] },  // Diagrammer schema (HANDOFF §3)
  "customization": {                 // the sticky human layer (B1 "customize"), never clobbered
    "renames": { "<node-id>": "Billing" },
    "regroups": { "<node-id>": "<domain-id>" },
    "pins": ["<node-id>"], "hidden": ["<node-id>"],
    "splits": [...], "merges": [...]
  },
  "narrative": { "tldr": "…", "sections": [{ "heading": "…", "prose": "…" }] },
  "updated_at": "…", "updated_by": "agent:blueprint-update|you",
  "conflicts": [ { "kind": "rename-orphan", "custom": "Billing", "note": "no longer maps to code" } ]
}
```
The **map node/edge/api schema is the Diagrammer's** (`~/Downloads/HANDOFF.md`
§3) — port that schema verbatim so the renderer IP transfers. Customization is a
*layer over* `derived`, applied at render time; the updater rewrites `derived`
and **never** touches `customization` except to append `conflicts` (principle 9).

### B.3 `relay-log-tail(project_ref?)` → cross-WS exchanges (Flow K)

```jsonc
{ "exchanges": [
  { "id": "…", "from_ws": "FE", "to_ws": "BE", "at": "…",
    "question": "…", "answer": "…", "outcome": "resolved|escalated",
    "dossier_ref": "…|null" } ] }   // escalated → links the Flow B dossier
```

### B.4 Tolerance rule (carried from 4xe / the inbox renderer)  [spine]

Every renderer degrades per-field with a labeled fallback and **never refuses an
accepted record**; the single refusal point is an integer schema-gate on
`unknown-higher` versions (`inbox-view.js` `schemaGate`). New view-models reuse
this: missing/malformed field → honest placeholder + a `degraded[]` note, not a
blank or a throw. Conformance is enforced at **write** (the engine's
`_writeRecord` body gate), tolerance lives at **render** — never re-add a render
refusal.

---

## 4. Contract C — Frontend app-shell  [spine]

Today there are three standalone pages (`web/{board,inbox,intake}/`), each a
vanilla-JS IIFE (`app.js`) + a pure UMD view-model (`*-view.js`, Node-testable) +
its own CSS, with `getJSON/postJSON/mk/clear` and CSS tokens **copy-pasted** into
each. Scaling that pattern to 9 views = 9 drifting copies and no coherent
navigation. So the **one** structural decision for the whole UI track:

### C.1 Extract a shell; views plug into it.

- **`web/shared/`** — new home for the things all views share:
  - `net.js` — the single `getJSON`/`postJSON` with the verbatim-error-envelope
    handling (`{ok:false,error}` → throw message; non-JSON → throw). No tokens
    client-side (the proxy holds the bearer; carried).
  - `dom.js` — `mk`/`clear`/`el` helpers.
  - `shell.js` — renders the persistent **nav** and mounts the active view.
  - `tokens.css` — the CSS custom properties + reset (today duplicated 3×).
- **View-model pattern is kept** (it's good): each view ships a pure
  `deriveXView(snapshot, now, opts)` UMD module with Node tests, plus a thin
  `app.js` that fetches, calls the derive fn, and renders. New views follow the
  `board-view.js` template exactly.

### C.2 Navigation = the Workspace-hub model (C1 + §2, the "no scavenger hunt" rule)  [spine]

```
GLOBAL nav (always present):  Inbox · Workspaces · Capacity · Cross-WS
WORKSPACE context (entered by tapping a workspace card): Board · Blueprint · Activity · Gates
```
- 5 global routes, 4 workspace facets. Switching facets **never leaves the
  workspace context** (the project_ref stays in the URL).
- **Routing [free within the contract]:** path-based for global
  (`/inbox`,`/workspaces`,`/capacity`,`/cross-ws`) + workspace
  (`/ws/<ref>/board|blueprint|activity|gates`); the inbox keeps its existing
  hash sub-routes (`#/d/<id>`). The *exact* router impl is the UI agent's call;
  the *route shape* above is the contract so deep-links (Board→Blueprint area,
  dossier→Blueprint focus-slice, holds→Gates) resolve.
- **The Inbox stays the product** (carried): the only push surface; everything
  else is pull. Lifting the surface cap does **not** demote it.

### C.3 What's deliberately [free] in the UI

Visual styling within the token system; per-view layout and density; icon
choices; animation; the router library/implementation; whether facets are tabs
vs. a segmented control. Move fast on all of it — none of it couples to another
agent once C.1/C.2 hold.

---

## 5. Contract D — Vocabulary & enums  [spine]

One normative glossary both tiers import (literally, where code: a
`shared/enums.js` on the UI side and the matching constants on the engine side;
where prose: these words). Drift here is the "gate" collision all over again.

### D.1 The noun split (fixes the real collision; UX-DESIGN-V2 §7.1)

| Word | Means | Backed by |
|---|---|---|
| **Blueprint** | the persistent living design+map of a workspace | `blueprint` §4 record |
| **Dossier** | an *ephemeral* Inbox decision card | `dossier` §4 record (unchanged) |
| **Hold** | umbrella: any reason a ready-looking task isn't worked | presentation only |
| → **Dependency hold** | blocked on another task | beads-native `blocked` (read-only) |
| → **Scheduled hold** | deferred to a date | beads-native defer (read-only) |
| → **Gate** | a *named* hold w/ why + unblock, GUI-add/removable, runner-respected | our `gate:<id>` label + `gate_metadata` |
| **Checkpoint** | a lifecycle decision point (old "GATE (you)") — produces a decision, not a hold | `preset:*` + `gate-policy.sh` |

**Gate ≠ Checkpoint.** Keep the internal code names (`gate-defer.sh`,
`gate-policy.sh`) but the UI only ever says Hold / Gate / Checkpoint.

### D.2 Closed enums (shared verbatim by producer and consumer)

- **Activity state** (derived from the log stream; `state_confidence` always
  `"derived"`): `writing-code | running-tests | exploring | thinking |
  waiting-on-you | rate-limited | maybe-stuck`. Mapping basis: Edit/Write/
  MultiEdit→writing-code; test-runner Bash→running-tests; Read/Grep/Glob→
  exploring; no events 90–180s→thinking; in an ask-brian call→waiting-on-you;
  `rate_limit_event`→rate-limited; no events >180s→maybe-stuck.
  **Liveness dot** (separate, blunt): green <90s, amber 90–180s, red >180s.
  **The 90/180 thresholds are measured (60s false-fires ~56×); do not tighten
  without re-measuring.** [spine — the number; the regex set is [free] to grow]
- **Done sub-state** (display only, §3): `done·code` (committed + local green) vs
  `done·verified` (production/contract probe passed). Not a new lifecycle stage.
- **Notification tier** (carried): `blocking | timed-fyi | digest`.
- **Hold type** (B.1 `holds[].type`): `gate | dependency | scheduled`.
- **Gate object** (the metadata `gate:<id>` lacks today): `{ id, why,
  unblock_condition, owner, scope: task|cohort }`.
- **Runner-respect:** a `gate:<id>` label suppresses pickup via the same
  mechanism as `RUNNER_NO_CLAIM_LABELS` (v1 `run-beads-tasks.sh:648-676`) /
  `gate-policy.sh` verdict (v2 `runner.sh:1144-1165`). [spine: the suppression
  must hold on whichever runner is in production — see §8 decision.]

### D.3 Cross-cutting principles (carried + v2; binding)

The 12 principles in UX-DESIGN-V2 §11 are the acceptance lens. The four that
catch the most bugs: **Nothing is held invisibly** (every hold has why+unblock),
**The map is always honest** (customizations sticky, conflicts FYI'd not
reverted), **Derived status is labeled as derived**, **Done means verified**.

---

## 6. Work breakdown — tracks, independence, dependency graph

After A–D, the slices are vertical and independent. Sizing target: each **impl**
bead is one agent / one sitting; each **design** bead is one focused doc.

```
EPIC: ux-v2 — the UX overhaul
│
├─ S (spine)   THIS DOC. Done. Unblocks every design bead below.            [architect]
│
├─ Track H — Blueprint            (biggest; most independent)
│   ├─ H-design  map data-model + customization layer + updater trigger     ⟶ blocked-by S
│   ├─ H1 impl   blueprint §4 record + blueprint-get/-put ops (Contract A/B)
│   ├─ H2 impl   map renderer: port Diagrammer schema+layout+edge-IP (HANDOFF §3,5,6,7)
│   ├─ H3 impl   narrative render + skim structure + Blueprint facet route (Contract C)
│   ├─ H4 impl   customization: rename/regroup/pin/hide in-place; sticky; conflict-FYI
│   └─ H5 impl   blueprint-update auxiliary agent (read-only hat) + change→timed-fyi (Flow F unify)
│
├─ Track J — Gates / unified Hold
│   ├─ J-design  gate_metadata shape + 3-mechanism unification + runner-respect path  ⟶ blocked-by S
│   ├─ J1 impl   gate_metadata table + gate-meta ops (why/unblock/owner) (Contract A.2)
│   ├─ J2 impl   holds[] projection unifier in workSnapshot (Contract B.1)
│   ├─ J3 impl   Gates facet UI (add/edit/lift gate; deps+scheduled read-only) (Contract C)
│   ├─ J4 impl   runner respects gate:<id> on pickup (the production runner — see §8)
│   └─ J5 impl   Board "waiting_on" inline from holds[] (§7.5)
│
├─ Track I — Activity / parallel runners / monitoring
│   ├─ I-design  log→activity-state parser + writer/aux lanes + stuck actions  ⟶ blocked-by S
│   ├─ I1 impl   activity-state log parser → agent_activity transient (Contract A.2, D.2 enum)
│   ├─ I2 impl   activity + runner_health in workSnapshot (Contract B.1)
│   ├─ I3 impl   Activity facet UI: writer lane + aux pool + liveness dots (Contract C, D.2)
│   ├─ I4 impl   stuck actions tappable: nudge / escalate / kill+retry / kill+gate
│   └─ I5 impl   parallel auxiliary dispatch (daemon spawns read-only aux alongside serial writer)
│
├─ Track K — Cross-workspace sync
│   ├─ K-design  ask-workspace MCP + read-only responder + batching + escalation  ⟶ blocked-by S
│   ├─ K1 impl   ask-workspace MCP server (fork mcp-askbrian; read-only responder)
│   ├─ K2 impl   relay_log transient + relay-log-append/-tail (Contract A.2/B.3)
│   ├─ K3 impl   always-FYI batching into timed-fyi/digest (load-bearing; §8.2)
│   ├─ K4 impl   conflict/missing-design → blocking Flow B dossier (the 20%)
│   └─ K5 impl   Cross-WS global view: coupling map (Blueprint slice) + relay log (Contract C)
│
├─ Track Q — Queue Health (small)
│   └─ Q1 impl   queue_health projection + Board strip (Contract B.1; net-velocity alarm) ⟶ blocked-by S
│
├─ Track L — Inbox/Intake leak-fixes (carried Flow A/B; mostly independent of H–K)
│   ├─ L1 impl   verb taxonomy: apply / dismiss-as-stale / defer / escalate — fix empty-payload fallthrough (P1)
│   ├─ L2 impl   auto-close dossier on bead resolution (expire) — the cleanliness win
│   ├─ L3 impl   intake state thread (received→enriching→created/failing/gave-up) phone-visible
│   ├─ L4 impl   overview-request preset → Blueprint refresh / FYI, no bd task   (soft dep on H)
│   └─ L5 impl   readability gate for dossier-builder + fallback (<30s, no jargon)
│
└─ Track N — Notifications
    └─ N1 impl   trigger catalog (§10.2) wired to real events + batching spine (§10.3)  ⟶ touches K3
```

**Independence map (what can run truly in parallel):**

- **Fully independent after S:** H, J, I, K, Q, L are separate verticals. Their
  *only* shared surface is Contract B (one file/section each owns its keys) and
  Contract C (the shell, built once — see ordering).
- **Build the shell first.** `C-shell` (extract `web/shared/` + nav + routing) is
  a prerequisite for every facet UI (H3/H4, J3, I3, K5, Q1's strip). It is small
  and mechanical; do it right after S, before the per-facet UI impl beads. All
  facet-UI beads are `--blocked-by C-shell`.
- **Soft couplings (named so they don't surprise):** L4 (overview→Blueprint)
  needs H1; K5 (coupling map) reuses H2's renderer; N1 batching shares K3's
  batching. These are *reuse*, not *blocking* — sequence them but they don't
  merge.
- **The one genuinely shared mutable seam:** `workSnapshot()` in `reconcile.js`.
  H, J, I, Q all add keys to `projects[]`. To avoid merge collisions, **each
  track owns a named sub-object** (`activity`, `holds`, `queue_health`,
  `blueprint_meta`) — never a shared flat field. That's why B.1 is structured as
  nested objects, not loose keys.

---

## 7. What's easy to get wrong (the must-protect list)

These are where a fast, plausible build is *subtly* wrong. Design beads must
address each explicitly; review beads check them.

1. **Closing on local-green, not live (bgw/2dk).** Every production-touching
   bead live-verifies before close (A.1 step 6). Non-negotiable.
2. **Projection drops a field (56h).** Anything the UI shows is named in B and
   emitted by `workSnapshot()`. UI never reads a key B doesn't promise.
3. **The Blueprint updater clobbering a human customization (B1 "customize" +
   principle 9).** Auto-regen rewrites `derived` only; `customization` is sticky;
   a stale custom name becomes a `conflicts[]` FYI, never a silent revert.
4. **Naming/grouping quality (B1, Brian's flagged hard part).** Good defaults
   (product domains, capabilities-not-Lambda-names, vendors-as-boxes) **and**
   cheap in-place override. A correct-but-ugly auto-map fails the ask.
5. **"Always FYI" becoming 45 pings (C4).** Batching is **load-bearing**, not a
   nice-to-have. K3 ships with H/K, not "later."
6. **Re-overloading "gate" (C3/D.1).** Hold/Gate/Checkpoint stay distinct in all
   user-facing copy.
7. **Asserting derived status as truth (principle 10).** Activity says "looks
   like running tests," carries `state_confidence:"derived"`. Never a confident
   semantic claim regex can't back.
8. **Tightening the 90/180 liveness windows (D.2).** Measured; 60s false-fires
   ~56×. Don't.
9. **The "Dismiss as stale" verb bug (L1, P1).** Each Inbox button → a distinct
   engine verb; no empty-payload fallthrough silently re-applying the
   recommendation.
10. **Auto-close on bead resolution (L2).** A dossier whose bead closed outside
    the tap-path must expire, never sit asking a dead question.
11. **An auxiliary agent that writes code (B3).** The aux pool is read-only by
    construction (the conflict-avoidance is the whole point). Enforce via the
    read-only hat permission set; an aux that needs to write becomes a bead.
12. **Fix-B predicate over-trigger (HANDOFF loose thread).** If I4/I5 touch
    stuck-restart, tighten the `STUCK_NEEDS_HUMAN` match to a recent window, not
    "anywhere in notes."

---

## 8. What's safe to move fast on [free]

- Visual design, layout, density, icons, animation — anything inside Contract C's
  token system and route shape.
- The Blueprint **layout engine internals** — the HANDOFF says explicitly *don't
  productionize the prototype*; swap to elk/dagre/React-Flow later. Port the
  *schema + edge-resolution IP*; the geometry is replaceable.
- Notification **thresholds/cadence** — net-velocity alarm trigger, digest
  cadence (these are §14 open questions; tune from data).
- The **activity regex set** — start with the D.2 mapping; add patterns freely
  (the *enum* is fixed, the detectors that feed it are not).
- Op/table **names within a flow** before it ships.
- Which views are tabs vs. segmented controls; the router library.

Moving fast here is safe **because** A–D pin the seams these touch.

---

## 9. Open decisions (need a call before the dependent impl beads)

1. **v1 vs v2 runner — where do J4 (gate-respect), I1/I5 (activity + parallel
   aux) land?**  Production today is `run-beads-tasks.sh` (v1);
   `runner.sh` (v2) is the rewrite target, **not deployed** (HANDOFF). Building
   gate-respect + parallel-aux on v2 means also finishing+deploying v2;
   building on v1 means touching the script the runner is executing (the ir7
   self-modification hazard). **Architect's recommendation:** land J4 + I1 on
   **v1** (smallest, ships now, gate-respect is a few lines next to
   `RUNNER_NO_CLAIM_LABELS`), keep I5 (parallel aux dispatch) in the **daemon**
   (it already dispatches read-only hats out-of-loop — no runner rewrite needed),
   and treat the v2 cutover as a separate, later epic. This needs Brian's
   yes/no because it sets where three impl beads land.
2. **Gate placement authority** (§14.1) — any agent, or only specific hats?
   Assumed: any agent, every placement visible + FYI'd if it holds significant
   work.
3. **Blueprint customization-conflict default** (§14.2) — keep+FYI (assumed) vs
   auto-drop.
4. **Net-velocity alarm threshold** (§14.3) — assumed any sustained positive
   trend over a few days; tune later ([free]).
5. **Cross-WS digest cadence** (§14.4) — assumed daily + immediate
   conflict-escalation ([free]).

Items 4–5 are [free] (tunable). Items 1–3 are real forks; 1 is the only one that
blocks an impl bead and should get a one-tap answer.

---

## 10. Traceability (every Brian ask → its track)

| Ask | Track | Contract it leans on |
|---|---|---|
| B1 Blueprint (living design+map, current, customizable) | H | B.2, D.1, principle 9 |
| B2 Cross-WS sync, read-only, via MCP | K | A.2, B.3 |
| B3 Parallel runners (serial writer + parallel aux) | I5 | D.2, §7.11 |
| B4 Monitoring in-progress, visible + actionable | I | B.1 activity/runner_health |
| B5 Notifications for new required action | N | D.2 tiers |
| B6 Workspace view (states, gates, diagram) | C.2 hub + Board/Gates/Blueprint | B.1, C.2 |
| B7 Per-task status from logs | I1 | D.2 enum |
| B8 Gates: visible, add/remove, why+unblock, runner-respects | J | D.1, A.2, B.1 holds |
| C1 richer multi-view app | C | C.2 |
| C2 "Blueprint" name | D.1 | — |
| C3 unified Hold over 3 mechanisms | J | D.1, B.1 holds |
| C4 cross-WS always-FYI (batched) | K3 | §7.5 |
| Leaks (verb bug, auto-close, intake state, overview, readability) | L | B.4 |
| Queue health (thirsty) | Q | B.1 queue_health |

---

*Amend like the frozen design docs: explicit section, rationale, date. The
`[spine]` seams especially — changing one is a cross-flow event.*
