# Context: The Cloudflare engine (hosted backend)

> One-liner: the hosted brain — a **singleton Coordinator Durable Object + D1**,
> fronted by a Worker that is the *one* auth chokepoint. Stores dossiers, runner
> state, notifications, leases; produces the read-model the phone web app renders.

**Read this doc when** your task touches: anything under `beads-runner/cf/`,
the `work-snapshot` projection, adding/changing an engine op, a `§4` record type
or a transient table, D1 migrations, or the live Worker at
`coordinator-cf.bbthechange.workers.dev`.

**Owns / scope (the files this doc covers):**
- `beads-runner/cf/src/*.js` — the Worker + Coordinator DO + every op module.
- `beads-runner/cf/migrations/*.sql` — the deploy-path schema source of truth.
- `beads-runner/cf/test/*.spec.js` — vitest-pool-workers behavioral conformance.
- `beads-runner/cf/wrangler.*.toml`, `cf/README.md`, `cf/DIFFERENTIAL-EQUIVALENCE.md`.

**Not here (go to the right doc):**
- The bash side of the same contract (`lib/coordinator.sh` etc.) → `lib-shared.md`.
  The CF engine is a **differential realization** of that bash oracle — same
  INTERFACE.md behavior, not a re-spec. Changing engine behavior usually means
  changing *both* and keeping them equal.
- The Pages **proxy functions** (`web/functions/api/**`) and frontend → the
  `web-*.md` docs. The engine never renders; it emits data.
- The frozen contracts themselves (A/B/C/D, INTERFACE.md clauses) → `contracts-and-design.md`.
- Notification/push delivery as an end-to-end pipeline → `notifications.md`
  (the engine's `notification.js`/`push.js` are *part* of that flow).

---

## Mental model

Three structural facts explain almost everything:

1. **One front door = one auth chokepoint.** `cf/src/index.js` runs
   `authenticate(request)` exactly once at the top of `fetch()`. A missing/invalid
   bearer is rejected **401 before the DO is ever contacted**, so a rejected
   request performs zero writes — structurally, not by convention. The resolved
   `principal` (frozen constant `"brian"`, PRINCIPAL_V1) is threaded down; the DO
   trusts it and never re-derives it. There is **no UI-vs-agent split** anywhere.

2. **One singleton DO = single-writer by construction.** `index.js` always talks
   to `idFromName("coordinator")` — one global, single-threaded instance. That
   serialization *is* the critical section, so there is no lock anywhere in the
   engine (it replaces the bash `co__with_lock`). Read-decide-write sequences
   (lease grant, heartbeat merge, desired-state RMW) are race-free for free.

3. **A frozen substrate + sibling op-modules.** `coordinator.js` is the substrate
   (store + the four §2 capabilities + the §4 write path `_writeRecord`). It is
   **byte-stable** — new work *adds* a module and a dispatch guard, never edits the
   substrate switch. Each concern is its own file exporting `<CONCERN>_OPS` (a Set
   of op names) + `handle<Concern>Op(co, op, args, principal)`, dispatched by an
   `if (<CONCERN>_OPS.has(op))` guard in `coordinator.js fetch()` *before* the
   substrate switch (`coordinator.js:247-385`).

Two storage classes (pick correctly — it's hard to move later):
- **§4 record** → the `records` table via `_writeRecord` → `validateRecord` →
  principal-stamp; the type must be registered in `schema.js SCHEMA_VERSIONS`.
  Use when the thing is owned, addressable by `(type,id)`, versioned, and may
  appear in the projection or a notification body.
- **Transient sibling namespace** → the module's own lazy-DDL'd table, bypassing
  `_writeRecord`; structurally absent from the projection. Use for telemetry,
  append-only logs, dedup/control rows, ephemeral aggregations.

## Key files

| File | Role |
|---|---|
| `src/index.js` | The Worker. The ONE `authenticate→principal` chokepoint (§9.1/§2.3); 401-before-DO; routes POST `{op,args}` to the singleton DO. |
| `src/coordinator.js` | The Coordinator DO substrate: lazy D1 DDL, `_writeRecord` (the one gated §4 write path), op-dispatch guards, the four §2 capabilities. **Keep byte-stable.** |
| `src/schema.js` | `SCHEMA_VERSIONS` §4 record registry, `validateRecord` (§0.3 version gate), `safeKey` input hygiene, `PRINCIPAL_V1`. Adding a §4 type starts here. |
| `src/reconcile.js` | **`workSnapshot()`** — the read-only `§4.5` projection producer (Contract B). Joins `runner_state` + work-truth + `machine_state_reports` + `agent_activity` + capacity. The board/inbox read-model. S-1 liveness derived at read time, never stored. I2 (claude-tools-uxvi2) added per-project `runner_health` (runner_state-derived, a TRUE bash twin) + `activity` (writer\|null + auxiliary[], read from I1's `agent_activity`, projected DOWN to B.1's 8-key writer / 5-key aux; stale-report dot honestly downgraded via `worseDot`). Both ADDITIVE at schema_version 1 — the v2 sub-object conformance gate stays PENDING until a coordinated bump to 2 lands ALL of {activity,holds,queue_health,blueprint_meta,runner_health}. runner_health: stale heartbeat + not-stopped/crashed ⇒ `wedged`; cooldown/capacity-deny/skip/starved all heartbeat `idle` within STALE_AFTER ⇒ `idle` (never stuck — findings §180–182). J2 (claude-tools-uxvj2) added per-project `holds[]` (`buildHolds` — the 3-mechanism unifier: gate=`gate:<id>` label grouped + task_count + the J1 `gate_metadata` LEFT-join, editable; dependency=`blocked_on`, scheduled=`deferred_until`+`owning_gate`, both read-only — `editable:false` encodes the C3 honesty rule). dependency/scheduled are a TRUE bash twin; the gate METADATA join is CF-only (bash has no `gate_metadata` store → degrades to null+`degraded[]`, the queue_health shape-parity posture). HELD beads (blocked/deferred/gated) ride a NEW additive §4.6 `held_beads` channel (`la_publish_workspace_inventory` → tolerant `normalizeHeldBeads` ingest → `readHeldBeads`) because the active in_progress/top_n lists exclude held work (the 56h trap). holds built ONCE from `beads ∪ held_beads`, attached to each project (per-project shape; global rollup is UI-side). H3 (claude-tools-uxvh3) added per-project `blueprint_meta` (DESIGN H §8.1 — `{updated_at,thumb_ref,active_domains}`): `updated_at` joins the per-project `blueprint` §4 record's freshness (O(1) `SELECT … type='blueprint' AND id=pr`, tolerant→null); `thumb_ref` = the `project_ref` (the §8.5 "render at thumb size" pointer, null when no map); `active_domains` = `deriveActiveDomains(activity)` (the §8.2 in-flight union of `activity.writer.touching`). The map BODY is NOT inlined (fetched on demand via `blueprint-get`). ADDITIVE at v1 like activity/holds; bash twin emits the honest-empty default for shape parity. |
| `src/dossier.js` | §4.1 Dossier body/items + per-item latch (the human-fork payload). |
| `src/notification.js` / `src/push.js` | §4.3 Notification creation/dispatch + phone DELIVERY transport (web-push). See `notifications.md`. |
| `src/stuck.js` | §7.x STUCK_NEEDS_HUMAN cross-tier routing + blocked-for-human control plane. |
| `src/timer.js` | §2.2 `fire(dossier_id)` timer wiring + the S-6 fire-on-next-poll backstop + timed-fyi auto-proceed; ready-to-pair `pair-arm`/`pair-surface` + the `pair-create` PRODUCER op (build a `kind:"pair"` session card + arm it in one round-trip — N10-10). |
| `src/lease.js` | §6.1 exclusive TTL'd lease + monotonic `generation` fencing. |
| `src/capacity.js` / `src/machine-state.js` | Coarse capacity verdict / per-machine telemetry. Both **transient** (smallest module templates to copy). |
| `src/forensic.js` | §10.3 transient encrypted forensic store. Deliberately NOT a §4 record. |
| `src/relay.js` | K2 (DESIGN K §3) cross-WS `relay_log` **transient** append-only log + `relay-log-append`/`-tail` (the B.3 `{exchanges[]}` projection). Typed columns (not forensic_audit's opaque `line`) so the tail can filter by `project_ref`. Proxies live at `web/functions/api/cross-ws/{relay,relay-append}.js`. |
| `src/activity.js` | I1 (DESIGN I §1.4) `agent_activity` **transient** telemetry: `agent-activity-report` ingest (latest-wins per `agent_key`, §0.3+D.2-closed-enum gate, §9.1 principal stamp) + `get-agent-activity` read. `machine-state.js` precedent; NOT a §4 record, NO web proxy / NOT adapter-mapped (runner/daemon-emitted). Migration `0010_agent_activity.sql`. `ACTIVITY_STATES` is the engine enum mirror `conformance-contract-v2.sh` PART D pins ≡ `enums.js`. NB: `agent_key` (`writer:<id>`/`aux:<kind>:<id>`) has a `:`, so it uses a colon-widened key predicate, not `safeKey`. |
| `src/gate-meta.js` | J1 (claude-tools-uxvj1, DESIGN J §2) `gate_metadata` **transient** annotation of a `gate:<id>` bd label: `gate-meta-set` (upsert — `why` REQUIRED, id `^[a-z0-9][a-z0-9-]*$` gate-defer.sh shape, `scope` closed D.2 enum {task,cohort} default `task`, `owner` an INPUT not the principal §2.3, `set_at` preserved across edits; runs INSIDE `co._serialize`) + `gate-meta-get` (one ⇒ `{gate:…\|null}`, all ⇒ `{gates:[…]}`; pure read, NO serialize). `machine-state.js` precedent; NOT a §4 record (absent from SCHEMA_VERSIONS). Proxy `web/functions/api/ws/gate-meta.js` (GUI seam forces `owner:"you"`; an agent calls the op DIRECT with `owner:"agent:<hat>"` — realized by `gate-defer.sh apply --why/--unblock/--owner/--scope`, the claude-tools-escz placement seam, which calls `gate-meta-set` over the `co_request` transport right after stamping the `gate:<id>` label). **Bash-oracle gap:** `lib/coordinator.sh` does NOT mirror these ops (returns `unknown op` rc 2) — a J1 miss; the LIVE engine has them, offline tests use a fake `co_request`. Adapter-mapped, migration `0008_gate_metadata.sql` (numbered below 0009/0010 — pre-allocated; lazy-DDL'd + idempotent so order-independent). J2 LEFT-joins it into `projects[].holds[]`. |
| `src/blueprint.js` | H1 (claude-tools-uxvh1, DESIGN H / blueprint.md §2) the per-workspace **Blueprint** — the ONE §4 record this epic adds (registered in `schema.js` `SCHEMA_VERSIONS`=1, reuses the shared `records` table, NO new table; `id=project_ref`). `blueprint-get` (pure read ⇒ the B.2 body verbatim, or **`null`** for the honest empty state — never a throw) + `blueprint-put` (one envelope `{project_ref,section,body,updated_by}`). THE SEAM: `blueprint-put` is **sectioned read-merge-write** — `section ∈ {derived,customization,narrative}` REPLACE one layer, `conflicts-append` PUSHES — all INSIDE `co._serialize`, so a racing `derived` (updater hat) + `customization` (GUI) write each merge over the other; **neither clobbers** (§2.3, principle 9, must-protect #3). Composes its write through the ONE gated `_writeRecord` (lease.js precedent), so `validateRecord`/§0.3/§9.1 apply; `updated_by` is a human-facing INPUT, distinct from the stamped `principal` (gate-meta §2.3 precedent). Migration `0012_blueprint.sql` (records-reuse). Proxies `web/functions/api/ws/blueprint.js` (read) + `ws/blueprint-put.js` (write; GUI seam forces `updated_by:"you"`, refuses a GUI `derived` write). Adapter-mapped. **Bash-oracle twin IS present** (`lib/coordinator.sh` `co__blueprint_put`/`co__blueprint_get` + `lib/test-coordinator-blueprint.sh`) — the differential oracle stays complete. vitest `cf/test/blueprint.spec.js`. H2 (render) / H3 (`blueprint_meta` projection + facet) / H4 (customization UI) / H5 (updater hat) build on this body. |
| `src/agent-action.js` | I4 (claude-tools-uxvi4, design/agent-action.md §2) the control-plane `agent_actions` **transient** command queue: `agent-action` (enqueue — closed host-effecting intent enum {nudge,kill-retry,kill-gate,gate-apply,gate-lift} + per-intent required fields, `owner` an INPUT §2.4, `crypto.randomUUID()` action_id, runs INSIDE `co._serialize`) + `agent-action-pending` (daemon read, optionally one `workspace`; pure read) + `agent-action-ack` (daemon write — terminal done\|failed). NOT a §4 record. Adapter-maps ONLY `agent-action` (the web write path; `-pending`/`-ack` are daemon-native via `POST / {op,args}`). Bash-oracle twin IS present (`lib/coordinator.sh` `co__agent_action_*` — closed the gate-meta gap). Migration `0011_agent_actions.sql`. The daemon EXECUTOR is `daemon/agent-action-poll.sh` (drops the runner control marker for the process intents; runs `gate-defer.sh` for the gate intents). Escalate is NOT here — it's a `dossier-generate` write (`web/functions/api/control/escalate.js`). |
| `migrations/NNNN_*.sql` | Deploy-path schema source of truth (the DO lazy-DDLs locally, but ship the migration). |

## Contracts & invariants (don't break these)

- **Contract A** (backend conventions) and **Contract B** (the `work-snapshot`
  shape) are law — see `contracts-and-design.md` / `UX-V2-ARCHITECTURE.md`.
- **The projection-field rule (the 56h scar):** every UI-visible field is derived
  inside `workSnapshot()` and named in Contract B *before* either side builds it.
  A field that exists in a record but is dropped by the projection can never reach
  the UI. If a view needs it, it is in Contract B and emitted by `workSnapshot()`.
- **`work-snapshot` is read-only by construction** — it invokes no write primitive.
  Never add a write path to a reader.
- **Tolerance lives at render, conformance at write.** The engine refuses
  non-conformant records at `_writeRecord`; renderers degrade tolerantly. Never
  move a refusal into the renderer (the 4xe scar — see `bd memories`).
- **The substrate switch and the four §2 capabilities are frozen.** A new op is a
  module + guard, never a fifth capability or a substrate edit. CAPABILITIES stays
  exactly four.
- **Differential equivalence:** `cf/src/*` must match the `lib/coordinator.sh`
  oracle behavior; `run-differential.sh` asserts it. Change one → change both.

## Common changes (recipes)

**Adding an op — the end-to-end checklist (the 2dk + bgw fix). Not done until every layer lists it:**
1. **Module** — new `cf/src/<concern>.js` with `<CONCERN>_OPS` + `handle<Concern>Op`
   (copy `capacity.js`/`machine-state.js`).
2. **Guard** — `import` + `if (<CONCERN>_OPS.has(op)) return await handle...` in
   `coordinator.js fetch()`, before the substrate switch. Keep the switch byte-stable.
3. **Pages function** — proxy under `web/functions/api/<area>/<name>.js` (read =
   `onRequestGet` hard-coding the read op; write = `onRequestPost` hard-coding op +
   type, stripping client `principal`, attaching `Bearer` server-side, passing the
   engine response verbatim).
4. **Local adapter** — if it must work in the pages-dev harness, map it in
   `cf/pages-dev/adapter.js` (`argsForGet`/`argsForPost`). *(The layer 2dk forgot.)*
5. **Migration** — if you added a table, ship `cf/migrations/NNNN_<name>.sql`.
6. **Live-verify before close** — a real authed call against the live Worker
   returning the new shape. `bd close` on a passing local test only is the **bgw
   failure — forbidden.**

**Adding a §4 record type:** add to `SCHEMA_VERSIONS` in `schema.js` + ship a
migration; it then flows through `_writeRecord`/`validateRecord` automatically.
Bumping a version is a deliberate `§0/§11` freeze-escalation, not a casual edit.

**Run it locally (no Cloudflare account):**
```bash
cd beads-runner/cf
npm install            # first run only
npm test               # vitest-pool-workers behavioral conformance (workerd+miniflare)
./run-differential.sh  # full CF.1 EXIT proof: behavioral + the §0.C source assertion
npx wrangler dev       # stand up Worker + DO + local D1 by hand
```

**Deploy (the real hosted Worker):** `docs/runbooks/deploy-cloudflare-worker.md`.
The bearer token lives in macOS Keychain (`claude-beads-runner.coordinator-token`),
never committed.

## Gotchas / scars

- **"Wired but not live" (4xe/2dk/bgw/56h/qxz family).** The recurring failure:
  code lands + local tests pass, but the live deploy/adapter/projection is missing,
  so the phone never sees it. Always live-verify (step 6 above).
- **The local pages-dev adapter is the forgotten layer.** A new op that works in
  vitest but 404s on the phone is almost always a missing `adapter.js` mapping (2dk).
- **`schema_version` is integer-typed at the gate.** A JSON string `"1"`, a float,
  or a bool is rejected (the bash oracle type-checks inside jq; the JS mirror must
  match). An unknown *higher* version is refused, never best-effort-parsed (§0.3).
- **Capacity/machine-state absence degrades to a value, not an error** — an absent
  aggregation surfaces as `"unknown"` / `machines: []`, matching the bash oracle.
- **cf vitest runs with a 30s `testTimeout`, not vitest's 5s default** (set in
  `cf/vitest.config.js`, claude-tools-mqh4). These specs drive the real engine
  through workerd+miniflare; the cold/loaded pool import can take tens of seconds
  and the heavy specs need ~6.9s in-test, so 5s intermittently false-RED'd
  CF.2/CF.6/CF.7 with "Test timed out in 5000ms" (environmental, not assertion).
  Don't drop it back to the default.
- **`projects[].queue_health` (§9 / B.1, Q1 claude-tools-uxvq1) is runner-sourced,
  read-back per project.** The runner computes the block (`la_publish_workspace_inventory`)
  and ships it ADDITIVELY in its §4.6 `workspace_inventory`; `workspaceInventoryPut`
  accepts it TOLERANTLY (`normalizeQueueHealth` coerces — a malformed optional
  sub-block never 422s the write, the ztb6 scar), and `workSnapshot` reads it back
  per project, defaulting to a zeroed block when absent (uniform shape). The bash
  oracle emits the zeroed default for shape parity (the `current_task_title:null`
  precedent) — so it is CF-only in spirit but in-contract for the differential.

## Go deeper

- `cf/README.md` — the CF.1 substrate intent + the INTERFACE→bash→CF mapping table.
- `cf/DIFFERENTIAL-EQUIVALENCE.md` — how CF stays equal to the bash oracle.
- `beads-runner/INTERFACE.md` — the frozen `§`-clause contract the engine binds.
- `beads-runner/UX-V2-ARCHITECTURE.md` Contracts A/B — adding-an-op + work-snapshot.
- `beads-runner/MACHINE-STATE.md` — the `machines[]` D2 telemetry contract.
- `docs/runbooks/{deploy-cloudflare-worker,inspect-engine-records}.md` — operations.

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a new op pattern, a moved/renamed module, a new invariant, a
fresh scar, a changed projection field. **Keep it concise — this doc earns its
keep only if agents read all of it.** Delete lines that have gone stale; don't let
it grow into another copy of INTERFACE.md. Last substantive update: 2026-05-31.
