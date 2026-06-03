# Context: The UX-v2 facet routes (Workspace hub + global facets)

> One-liner: the newer, lighter Contract-C routes — the per-workspace **hub**
> (`/ws/<ref>/<facet>`) and the three global facet views (Workspaces, Capacity,
> Cross-WS). Each is the same shape as Board/Inbox: a pure `deriveXView` model +
> a thin `app.js` shell + CSS, plugging into the shared nav. Mostly read-only.

**Read this doc when** your task touches `beads-runner/web/{workspace,workspaces,capacity,cross-ws}/`,
the per-workspace facet nav, a `deriveWorkspacesView`/`deriveCapacityView`
view-model, the workspace-shell catch-all page, or wiring a still-placeholder
facet (Blueprint/Activity/Gates/Cross-WS) to live content.

**Owns / scope (the files this doc covers):**
- `web/workspaces/` — the cross-machine **Workspaces hub** (the global list:
  "which workspaces are healthy / busy / stuck / need me?"). MATURE.
- `web/capacity/` — the **Capacity** view ("how much Claude budget is left, what
  mode is each project in?"). MATURE.
- `web/workspace/` — the per-workspace **hub / facet shell** (`/ws/<ref>/<facet>`).
  The `board`, `activity`, `gates` **and `blueprint`** facets are all real now.
  `blueprint` graduated placeholder→live in **H4 (claude-tools-uxvh4)** — the
  customization map + the §5.3 conflict-FYI; H3 still layers narrative prose +
  `?focus` deep-links on top. (`activity` graduated in I3 (claude-tools-uxvi3);
  `gates` in J3 (claude-tools-uxvj3); the map renderer `blueprint-view.js` landed
  in H2 (claude-tools-uxvh2).)
- `web/cross-ws/` — the cross-workspace sync route. **SCAFFOLD ONLY** — nav shell
  + an honest "ships with track K" placeholder; makes no `/api` call.

**Not here (go to the right doc):**
- The shared shell, nav, `Net`/`Dom` helpers, `_redirects` routing, deploy/verify
  → `web-shell.md`. **Read it first for any web task.**
- The three established pages → `web-board.md`, `web-inbox.md`, `web-intake.md`.
  The hub's `board` facet *reuses* `BoardView` verbatim — its rules live there.
- The engine surfaces these read (the `/api/board` work-snapshot, capacity verdict,
  `machines[]`, `blueprint`/`relay-log-tail`) → `engine-cloudflare.md`.
- The cross-WS RELAY / notification flows that Cross-WS will eventually render →
  `notifications.md`.
- The frozen Contract C / B vocabulary itself → `contracts-and-design.md`.

---

## Mental model

These are the **Contract C facet routes** (UX-V2-ARCHITECTURE §4). The whole UI
is one shell + N views; each view follows the `board-view.js` template exactly:

1. **A pure UMD `deriveXView(snapshot, nowMs)` core** — no DOM, no network, no
   timers, no write path. Input is the §4.5 work-snapshot JSON (the *same*
   `/api/board` read the Board consumes); output is `{ ok, … }`, a deterministic
   view model of strings. Node-testable: `lib/test-workspaces-view.sh` /
   `test-capacity-view.sh` `require()` the module and assert against a fixture.
2. **A thin `app.js` IIFE** — `Net.getJSON('/api/board')` → `deriveXView` →
   paint via `Dom` helpers (`textContent`, never `innerHTML`) → `Shell.mount(...)`
   for the persistent nav → 30s auto-refresh (`REFRESH_MS`). **Zero rendering
   business logic** lives here; it only writes derived strings into elements.
3. **CSS** styling within the shared token system.

**Nav model (Contract C.2):** 5 global routes (`/inbox /workspaces /capacity
/cross-ws`) + 4 workspace facets (`/ws/<ref>/{board,blueprint,activity,gates}`).
Switching a facet never leaves the workspace context (the `ref` stays in the
URL). `_redirects` rewrites every `/ws/*` to the ONE `web/workspace/` page, which
calls `Shell.parseWorkspacePath(location.pathname)` to learn `{ref, facet}`.

**Maturity is uneven — be honest about it:**

| Route | State |
|---|---|
| `workspaces/` | **Mature** — full pure view + Node test + shell. |
| `capacity/` | **Mature** — full pure view + Node test + shell. |
| `workspace/` (`board` facet) | **Real** — reuses `BoardView`, scoped to `ref`. |
| `workspace/` (`activity` facet) | **Real** (I3) — `ActivityView`: writer lane + aux pool + liveness dots + a distinct runner-health pip; pure view-model + `lib/test-activity-view.sh` + jsdom row. |
| `workspace/` (`gates` facet) | **Real** (J3) — `GatesView`: the unified Hold view (gate editable: lift/edit-why/edit-unblock + add-a-gate; dependency/scheduled read-only; scheduled-under-its-gate); pure view-model + `lib/test-gates-view.sh` + jsdom row. Writes route through `/api/ws/gate-meta` (engine-direct) + `/api/control/gate-action` (host gate-apply/gate-lift). |
| `workspace/` (blueprint) | **Real** (H4, claude-tools-uxvh4) — `mountBlueprintFacet`: a drill-in customization map (rename/regroup/pin/hide via tap → `BlueprintCustomize` builders → `POST /api/ws/blueprint-put` section:"customization") + the §5.3 conflict-FYI keep/drop lane (`deriveLiveConflicts`) + a HIDDEN/unhide list. Reads its OWN §4 record via `GET /api/ws/blueprint?project_ref` (NOT /api/board). Reuses `BlueprintView` (H2 renderer) + the G5 overlay fields. The map geometry is a `[free]` tree, not the spatial canvas. **H3 still owns** the narrative prose (TL;DR→headings ABOVE the map), the `?focus=<id>` deep-link contract, the `blueprint_meta` projection, and the overlay *wiring* (passing `activity` into the renderer). |
| `cross-ws/` | **Scaffold** — nav + placeholder; no `/api` call, no view-model. |

## Key files

| File | Role |
|---|---|
| `workspaces/workspaces-view.js` | `deriveWorkspacesView(snapshot, nowMs)` → one card per `projects[]`: honest `state_label`, `current_task`, per-workspace `decisions` (sliced from global `waiting_on_you` by ref-prefix), DERIVED `stage_counts`, per-workspace `intake` thread (L3 — sliced from the top-level `intake[]` by EXACT `project_ref`), `health`. Sorts attention/stale first. Also returns global `decisions_total` + `intake_attention_total`. |
| `workspaces/app.js` | Shell glue: read `/api/board`, paint cards (each an `<a>` into `/ws/<ref>/board`), surface `decisions_total` prominently. Read-only. |
| `capacity/capacity-view.js` | `deriveCapacityView(snapshot, nowMs)` → `machines[]` (detailed per-machine bands + allowed line, **logically identical** to `board-view.js deriveMachine`) + `modes[]` (one honest actual mode per project). |
| `capacity/app.js` | Shell glue: paint the detailed machine cards + mode rows; `machines_empty` → "no telemetry yet" banner (§3.C). |
| `workspace/app.js` | The workspace-shell glue. `parseWorkspacePath` → `{ref, facet}`; `board` facet **reuses `window.BoardView`** scoped to `ctx.ref`; `activity` facet **reuses `window.ActivityView`** (stuck actions are I4); `gates` facet **reuses `window.GatesView`** (J3); `blueprint` facet (H4) **reuses `window.BlueprintView` + `window.BlueprintCustomize`** in `mountBlueprintFacet` — the customization map + conflict-FYI write path. No facet is a `mountPlaceholder` anymore (`FACET_TRACK = {}`). |
| `workspace/blueprint-customize.js` | `window.BlueprintCustomize` (H4, claude-tools-uxvh4) — the PURE, headless WRITE-side of the customization layer (the sibling of H2's read-side `blueprint-view.js`). Six override builders (rename/regroup/pin/hide/split/merge), each PURE (never mutates input → the in-memory never-clobber, §2.3) and emitting a POST-ready customization sub-object; conflict **keep/drop** (§5.3: KEEP records an additive `customization.acked` ack and NEVER reverts the override — the §14.2 default; DROP removes the backing override); `deriveLiveConflicts` — the honest projection over the append-only `conflicts[]` log (dedup by (kind,node_id) + suppress acked/dropped/§4-reattached). Node test: `lib/test-blueprint-customize.sh`. |
| `workspace/gates-view.js` | `deriveGatesView(snapshot, ref, nowMs)` (J3) → the unified Hold list: `gates[]` (editable, each with nested `scheduled_under[]` for gate-owned defers), `dependencies[]` + `scheduled[]` (read-only, native note), `other[]` (out-of-set holds, B.4). Reads ONLY `projects[].holds[]` (the J2 `buildHolds` shape); `editable` copied VERBATIM from the projection (C3 — the view never decides editability). One refusal = unknown-HIGHER schema_version; else degrade + `degraded[]`. Writes: `/api/ws/gate-meta` (engine-direct why/unblock) + `/api/control/gate-action` (host gate-apply/gate-lift). |
| `workspace/blueprint-view.js` | `deriveBlueprintView(record, nowMs, opts)` (H2) → the Blueprint MAP model. **The ONE facet that reads its own §4 record (the `blueprint-get` body, B.2), NOT the work-snapshot** (§8.1 keeps the map out of the projection, fetched on demand). Ports the Diagrammer IP: §3.1 node taxonomy (top-level domains/client/store/vendor, drill-in capabilities, queues-as-edges), §3.2 edge-resolution to the deepest VISIBLE ancestor + bundle + macro/focus density, §3.3 APIs as boundary boxes, §3.4 focus/dim/drill, the §5.2 customization view-transform keyed by the §4 STABLE node id (rename/regroup/pin/hide), `makeNodeId`. Layout geometry is `[free]` (§3.5 — emitted, never asserted). One refusal = unknown-HIGHER schema_version; else degrade + `degraded[]`. **In-flight overlay (G5, §6.4/§8.2):** `opts.active_domains` (the FROZEN flat-union `blueprint_meta.active_domains` shape) and/or `opts.activity` (the B.1 `{writer,auxiliary}` sub-object — the only form carrying agent IDENTITY) light up worked domains — each active node resolves to its deepest VISIBLE ancestor box (the §3.2 edge IP), per-node `active`/`active_self`/`collision`/`collision_self`/`touchers` + an `overlay{active_ids,lit,collisions,touchers_by_node,unmapped}` summary + `counts.active`/`counts.collisions`. **Collision honesty:** ≥2 DISTINCT agents in one box ⇒ collision; one writer touching two domains does NOT (a flat union can't assert collision — identity unknown; an unmapped active id is honestly `unmapped[]`, never lit). Node test: `lib/test-blueprint-view.sh`. The **mount** is H4 (`mountBlueprintFacet`); narrative + the overlay *wiring* (read `blueprint_meta.active_domains`/`activity` from the work-snapshot, pass into the renderer) + `?focus` deep-links remain H3. |
| `workspace/activity-view.js` | `deriveActivityView(snapshot, ref, nowMs)` (I3) → the writer lane (one\|null, the B.1 8-key shape), the auxiliary pool (0..N, the narrower 5-key shape), and a `runner_health` bucket DISTINCT from agent activity. Reads ONLY B.1 keys (must-protect #2); derived states render as "looks like" with always-"derived" confidence; liveness dots consumed verbatim (90/180 never re-derived); B.4 per-field tolerance + `degraded[]`; one refusal = unknown-HIGHER schema_version. |
| `workspace/index.html` | The catch-all page `_redirects` rewrites all `/ws/*` to. **Every asset ref is ABSOLUTE** (the q6z7 lesson) — loads `/board/board-view.js` verbatim, never copied. |
| `cross-ws/index.html` | Scaffold: mounts only `Shell.mount({active:'cross-ws'})`; states it ships with track K (K2 relay log, K5 coupling map). No JS view-model file exists. |
| `lib/test-{workspaces,capacity}-view.sh` | Node-require differential tests for the two mature views (mirror `lib/test-board.sh`). Auto-enrolled in the `lib` tier. |

## Contracts & invariants (don't break these)

- **The view-model is pure; the shell is dumb.** No fetch/DOM/timer/write path in
  `*-view.js`; no band/health/state derivation in `app.js`. A new rule that
  belongs in the model goes in the model (so the Node test can pin it).
- **One read for the whole UI.** Every mature facet reads `/api/board` (the §4.5
  work-snapshot) — they do NOT add new engine reads. A field a facet needs must
  be in Contract B.1 and emitted by `workSnapshot()` first (the projection-field
  rule — see `engine-cloudflare.md`). The hub deliberately *slices* the global
  queues per workspace by ref-prefix; it does not ask the engine to pre-slice.
- **The one hard refusal is an unknown-HIGHER `schema_version`** (or a
  missing/non-integer one): `deriveXView` returns `{ok:false,error}` and the app
  shows "update the app". Every other gap degrades per-field with an honest
  placeholder — never fabricate (the 4xe write-gate / render-tolerance line).
- **Honest desired≠actual + S-1 liveness.** A stale runner is NEVER promoted to a
  live state/mode and its `current_task_ref` is dropped (honestly unknown). On a
  mismatch, show the actual then `(target: desired)` — never collapse one onto the
  other. Both mature views re-implement this locally; they do NOT import
  `board-view.js` (the workspace `board` facet is the only thing that reuses it).
- **`stage_counts` is DERIVED and must be labeled.** `workspaces-view.js` infers
  the per-workspace lifecycle tally by `bead_ref` prefix (`prefixMatch` enforces
  the `-` separator), flags `derived:true`, and the UI MUST render "derived from
  board". It is not an authoritative per-project projection (Q1's `queue_health`
  supersedes it later).
- **Capacity bands stay in lockstep with the Board.** `deriveMachineRow` bands +
  the `<allowed>` line are logically identical to `board-view.js deriveMachine`
  (FROZEN MACHINE-STATE.md v1 / D2) and mirror `daemon/usage-poll.sh:_usage_poll_compute_allowed`.
  Bands are driven by `threshold_in_effect`, never a hardcoded 70. A divergence is
  a D2 drift — reopen D2, never silently edit one side.
- **The workspace facets are READ-oriented.** The `board` facet has NO set-desired
  control (control stays on the global `/board`); it never widens the write path.

## Common changes (recipes)

**Tweak a mature facet's derivation** (a new health rule, a label, a band edge):
1. Edit the pure `*-view.js` (where the logic belongs).
2. Add/extend the fixture assertion in `lib/test-{workspaces,capacity}-view.sh`.
3. `bash beads-runner/run-tests.sh --tier lib` (the Node-require test is here).
4. Wire any new field into `app.js` (string-in, paint-out only).
5. **Deploy + verify** (the bgw gate — see below). Code committed is NOT done.

**Promote a placeholder facet to live content** (Blueprint H3 / Activity I3 /
Gates J3 / Cross-WS K5): the route, nav, and rewrite already exist. The work is
(a) the engine projection field in Contract B.1 + `workSnapshot()` (see
`engine-cloudflare.md`), (b) a new pure `deriveXView` + a `lib/test-*-view.sh`,
(c) the facet's `app.js`/host wiring. For `workspace/`, replace the
`mountPlaceholder(ctx.facet)` branch; for `cross-ws/`, the route currently has NO
view-model file — add one. Read the matching design doc first:
`design/{blueprint,activity,gates,cross-ws}.md`.

**Deploy + verify (MANDATORY before `bd close` — the bgw lesson):** all routes
live in the ONE unified `claude-wrangler` Pages project; one deploy ships them all.
```bash
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh        # mismatches=0 means it landed
```
A web task is done when the deployed bytes match committed bytes, not at commit.

## Gotchas / scars

- **Absolute asset paths under `/ws/<ref>/<facet>` (q6z7).** The workspace-shell
  page is served at arbitrary depth via rewrite; a relative `./x` resolves against
  the request path and 404s. `index.html` links `/shared/*`, `/board/board-view.js`,
  `/workspace/*` absolutely. Same rule for the global facet pages.
- **The hub slices the GLOBAL queues — it never gets a per-project read.**
  `decisions`/`stage_counts`/`health` are all inferences over `waiting_on_you` +
  `lifecycle_columns` by ref-prefix. `prefixMatch` requires the `-` separator so
  `claude-tools-web` does not greedily swallow `claude-tools-web-extra`'s beads.
  **The L3 `intake` slice is the exception:** intake-request records carry
  `project_ref` DIRECTLY (the Flow-A submitter chose the workspace), so the hub
  matches it EXACTLY, not by prefix. A terminal-success (`created`) intake ages
  off the hub after 6h (`INTAKE_CREATED_RECENT_MS`) — the bead is the artifact,
  the hub is not its grave; `failing`/`gave-up` never age out (they're the leak).
- **Don't make Cross-WS pretend.** It deliberately makes no `/api` call and invents
  no exchanges — it states what track K will answer. Keep that honesty until the
  K2/K5 projections actually exist; do not add a phantom data read.
- **"Wired but not live" (the bgw/4xe/2dk family).** Local Node test green + code
  committed is NOT acceptance for a web route — the phone reads the deployed Pages
  site. Always deploy + `verify-pages-deploy.sh` (mismatches=0) before `bd close`.

## Go deeper

- `beads-runner/UX-V2-ARCHITECTURE.md` §4 (Contract C — shell + the 5-global /
  4-facet nav model) and §3 (Contract B.1 work-snapshot the facets read).
- `beads-runner/UX-DESIGN-V2.md` §2 (the surfaces / "no scavenger hunt" rule).
- `beads-runner/design/{blueprint,activity,gates,cross-ws}.md` — the design canon
  for the not-yet-shipped facets (tracks H/I/J/K).
- `web/board/board-view.js` — the template every facet view copies, and the
  oracle the Capacity bands and the workspace `board` facet stay equal to.
- `lib/test-{workspaces,capacity}-view.sh` — how the pure views are pinned.

## Keeping this doc current

When you finish a task here, append what a future agent will need and didn't find:
a facet that graduated from placeholder to live (update the maturity table!), a new
view-model field, a moved/renamed module, a fresh scar. **Keep it concise — this
doc earns its keep only if agents read all of it.** Delete stale lines; don't let
it grow into a re-spec of Contract C. Last substantive update: 2026-06-03
(Blueprint facet H4 graduated placeholder→live — customization map + conflict-FYI,
claude-tools-uxvh4; Gates J3 + Activity I3 before it).
