# Context: The Intake page (UX Flow A — file new work from the phone)

> One-liner: the phone surface where Brian files a new idea in ~5 seconds —
> one text box + workspace picker + entry-intent preset. The proxy writes ONE
> `intake-request` record; the daemon polls for it and dispatches the enricher
> to turn it into a real bead. The UI itself enriches nothing.

**Read this doc when** your task touches: anything under
`beads-runner/web/intake/`, the intake Pages functions under
`beads-runner/web/functions/api/intake/`, the `/intake` route behavior, the
preset radio-card flow, or the workspace-picker dropdown.

**Owns / scope (the files this doc covers):**
- `beads-runner/web/intake/{index.html, intake.css, app.js}` — the phone form.
- `beads-runner/web/functions/api/intake/index.js` — the I2 **write** proxy
  (`POST /api/intake` → engine `put` of one `intake-request`).
- `beads-runner/web/functions/api/intake/workspaces.js` — the **workspace-list**
  read proxy (`GET /api/intake/workspaces`, projected off `work-snapshot`).
- `beads-runner/web/functions/api/intake/presets.js` — the **preset-catalog**
  read proxy (`GET /api/intake/presets`, no engine round-trip).
- `beads-runner/web/functions/api/intake/_presets-catalog.js` — the Pages-side
  mirror of the canonical preset JSON (imported by both proxies above).

**Not here (go to the right doc):**
- The **enricher hat** that processes the submission into a bead → `worker-agents.md`.
- The **daemon poll** (`intake-dispatch-poll.sh`, `intake-pending` op, dispatch
  via `specialist.sh`) → `daemon.md`.
- The **`intake-request` §4 record type** + the `put`/`work-snapshot` engine ops
  → `engine-cloudflare.md`.
- The **preset catalog as a cross-tier contract** (the canonical JSON, the
  one-PR add-a-preset playbook, the enricher + `gate-policy.sh` consumers) →
  `worker-agents.md`; the canonical file is `agents/intake-presets.json`.
- The **app shell, deploy + verify discipline, `shared/*` helpers** →
  `web-shell.md`. READ THAT FOR ANY WEB TASK.
- The sibling read-only Board page → `web-board.md`; the Inbox → `web-inbox.md`.

---

## Mental model

Intake is **submit, not process**. The phone does the smallest possible thing:
capture `{idea_text, project_ref, preset}` and hand it to the engine as one
`intake-request` record. Everything that turns that into a real bead happens
downstream and asynchronously:

```
phone form (app.js)
  ├─ GET  /api/intake/presets    → radio cards   (catalog, no engine call)
  ├─ GET  /api/intake/workspaces → picker        (projected off work-snapshot)
  └─ POST /api/intake            → ONE put of intake-request {processed:false}
                                         │
        (different tier — daemon.md) ────┘
        daemon intake-dispatch-poll.sh polls `intake-pending` ~30s →
        spawns enricher (specialist.sh) → enricher does `bd create` →
        re-PUTs the record processed:true → Board reflects the new bead.
```

Three load-bearing facts:

1. **Submission is split from dispatch by design.** The write proxy never runs
   the enricher and never touches Dolt — it just enqueues. That keeps the proxy
   tiny and lets a submission survive even if no runner is up for that workspace
   (the daemon fires a short-lived enricher in the workspace cwd regardless).
2. **The browser holds no secret and picks no op** (§9.2 / §9.1). Both proxies
   are server-side and **hard-code their op**: the write proxy hard-codes `put`
   + record type `intake-request`; the workspace proxy hard-codes `work-snapshot`.
   The client cannot name a type, select an op, or set a `principal`.
3. **The preset catalog is one mirror, two importers.** The UI renders radios
   from `/api/intake/presets`, and the write proxy validates against the same
   `_presets-catalog.js` module — so the radio set and the write allowlist
   **cannot drift**. The canonical source is `agents/intake-presets.json`; this
   mirror is hand-kept in lockstep (the one-PR playbook in `worker-agents.md`).

## Key files

| File | Role |
|---|---|
| `intake/index.html` | Phone-first form: one `<textarea>`, one `<select id=workspace>`, a `<fieldset id=presets>` radios are injected into, big amber Submit, a confirm pane. Links `/shared/{tokens,net,dom,shell}` then `/intake/{intake.css,app.js}`; `Shell.mount({active:null})`. |
| `intake/intake.css` | Phone rules: `--tap:44px` target floor, 16px+ inputs (dodge iOS auto-zoom), no hover-only states, layout that survives the on-screen keyboard. Reuses the shared tokens — same product, not a third look. |
| `intake/app.js` | Browser glue ONLY. `loadPresets()` + `loadWorkspaces()` on `DOMContentLoaded`; `refreshSubmit()` gates Submit on all three fields + both loads done; `onSubmit()` POSTs and shows the confirm pane. Uses `window.Net.{getJSON,postJSON}` + `window.Dom.{el,clear}` (shell helpers). |
| `functions/api/intake/index.js` | **I2 write proxy.** `onRequestPost` only. Validates `idea_text` (≤8192 bytes), `project_ref` (`/^[A-Za-z0-9._-]+$/`), `preset` (allowlist) → mints a `safeKey`-clean `intake-<ts>-<rand>` id → engine `put`. 503 if bindings unset; passes engine rejects through verbatim. |
| `functions/api/intake/workspaces.js` | **Workspace-list read proxy.** `onRequestGet` only; op hard-coded `work-snapshot`; projects `projects[].project_ref` down to a sorted, de-duped string list. `no-store`. |
| `functions/api/intake/presets.js` | **Preset-catalog read proxy.** `onRequestGet` only; serves `PRESETS` from the mirror — no engine call. `no-store` so a catalog-change deploy isn't masked by a CDN cache. |
| `functions/api/intake/_presets-catalog.js` | The frozen (`Object.freeze`) Pages-side mirror of `agents/intake-presets.json`. Exports `PRESETS`, `SCHEMA_VERSION`, `ALLOWED_PRESET_VALUES`. Underscore prefix ⇒ non-routable; import-only. |

## Contracts & invariants (don't break these)

- **The write is exactly one `intake-request` record, type + op hard-coded.**
  Never let the client choose the op or type. No set-desired / respond /
  item-apply / forensic verb is reachable from this surface; nothing here
  writes Dolt. (`index.js:34-35` freezes `put` + `intake-request`.)
- **Principal is server-side only.** The record is sent with `principal`
  intentionally absent; the §9.1 chokepoint stamps it. The proxy also strips
  any client-sent principal defensively. Never add a principal field to the
  client payload.
- **No second engine op for the workspace list.** `work-snapshot` already
  enumerates every stored `runner_state.project_ref`; the proxy projects it
  down. Adding a `list-projects` op would widen the §9.1 op surface — don't.
- **Preset list = one mirror, two importers.** A preset that exists in the UI
  but not the write allowlist (or vice-versa) is a bug class this design
  forbids. Adding a preset is the documented one-PR change; never hard-code a
  radio in `index.html`.
- **Tolerance at render, conformance at write.** The UI never fabricates a
  workspace list or a preset on failure — it shows an honest disabled state and
  leaves Submit off (principle 4). The engine remains the authoritative gate;
  the proxy's checks are a cheap first gate that pass honest engine errors
  through verbatim.
- **Unset `COORDINATOR_URL`/`COORDINATOR_TOKEN` ⇒ honest 503**, never a faked
  enqueue or a fabricated workspace list.

## Common changes (recipes)

**Add an Intake form field (e.g. a priority hint):** add the input to
`index.html`; read + trim it in `app.js onSubmit()`; add it to the POST body;
validate + size-check it in `index.js onRequestPost`; add it to the `record`
object written via `put`. The daemon's context JSON (`daemon.md`) and the
enricher prompt (`worker-agents.md`) must learn the field too — a field the
record carries but the enricher ignores is dead weight. Live-verify (below).

**Add a preset:** this is a cross-tier catalog change, **not** an Intake-only
edit. Append a row to `agents/intake-presets.json`, mirror it in
`_presets-catalog.js`, add the enricher resolution bullet, add one
`value:gate_aggressiveness` row to `PRESET_ENUM` in `gate-policy.sh`
(**no code branch** — `gate-policy.sh` derives the verdict generically from
the gate token since claude-tools-uxgpre), then run
`bash beads-runner/test-intake-presets.sh` (it fails with a `DRIFT:` line if any
step is skipped). The harness now also asserts: no duplicate values,
`schema_version` JSON↔mirror agreement, the `PRESET_ENUM` gate token matches
the catalog, and `gate-policy.sh decide` resolves a correct non-empty verdict
for every catalog preset (the "data shipped but not wired" guard). Full
playbook in `worker-agents.md` / `agents/intake-presets.md`. No `index.html`
edit — radios re-render from the catalog on next deploy.

**Picker ownership (claude-tools-uxgpre):** the general "tap a named preset"
affordance + extensibility is owned here. The picker UI was already
catalog-driven from I4 (no UI bytes changed by uxgpre — `label`+`sublabel` is
the deliberate phone altitude; `description` rides the API for wire/debug
only). What uxgpre closed was the *extensibility* gap: the L2 verdict was
per-preset code, and three lockstep axes were unchecked.

**Special presets (claude-tools-uxvl4 / L4 — `overview-request`):** a preset
that breaks the `(entry_stage, gate)` reductive contract — makes **no bd task**
and routes daemon-side — IS a catalog row (the catalog owns the row so the UI
renders it + the write proxy allow-lists it), just a *special* one. It carries
`entry_stage:null` + `gate_aggressiveness:null` + a `routing` discriminator
(`schema_version` 2 added that optional field). The UI renders it like any other
radio (no UI bytes changed — still `label`/`sublabel`-driven). The write proxy
still allow-lists it by value via `ALLOWED_PRESET_VALUES` (no `index.js` change).
The *behavior* lives in `daemon/intake-dispatch-poll.sh` (routes to a
dossier-builder → `proactive_checkpoint` `timed-fyi`); `test-intake-presets.sh`
exempts special rows from the spine checks and adds a check that every
`routing`-set value is branched on in the daemon. See `agents/intake-presets.md`
"Special presets (no bd task)" for the special add-a-preset shape.

**The gate before `bd close` (the bgw lesson — web work is not done at commit):**
```bash
bash beads-runner/run-tests.sh --changed              # offline regression (testing.md)
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh              # must print mismatches=0
```
Then a real end-to-end live check: load `/intake` on the phone (or curl the
proxies), submit, and confirm the bead appears on the Board within seconds. A
green local test + committed code is **not** acceptance — `mismatches=0` against
the live host plus the bead landing is. See `web-shell.md` for the deploy detail.

## Intake state is now phone-visible (L3 claude-tools-uxvl3)

The "I submitted but nothing happened" black hole is closed. The daemon
(`daemon/intake-dispatch-poll.sh`) writes a **state thread** onto each
intake-request as it processes it — `dispatch_state` ∈ `received → enriching →
created` / `failing` / `gave_up`, plus the L4 special `overview` terminal (the
`overview-request` preset drained a Blueprint/FYI, NO bd task —
`deriveIntakeState` returns it BEFORE the `processed` gate so it reads distinctly
from `created`, claude-tools-t1uc), plus `dispatch_attempts` (the `(n)` in
`failing(n)`), `last_error`, `last_attempt_at`, `gave_up_at`. It caps retries at
`INTAKE_MAX_ATTEMPTS` (default 3) — the fix for the 19-silent-retry/~$19 night —
and a `gave_up:true` record is terminal (the dispatch loop SKIPS it; it stays
`processed:false`, so `intake-pending` still returns it — excluding gave-up from
`intake-pending` to cut queue bloat is a deferred follow-up). `workSnapshot()`
projects all this into a top-level **`intake[]`** lane (`cf/src/reconcile.js`
`readIntake`/`deriveIntakeState`; Contract B.1 amend), and the **Workspaces hub**
(`web/workspaces/`, see `web-facets.md`) renders the per-workspace thread + a
global failing/gave-up leak counter. NOT surfaced on the Inbox — a gave-up intake
should escalate via the L4 overview-dossier path, not be faked as a dossier.

## Gotchas / scars

- **"Wired but not shipped."** The whole `intake-request` → enricher chain is
  three tiers (web / engine / daemon). A submission can succeed and still never
  become a bead if the daemon poll isn't running or the `project_ref` has no
  registry entry. When debugging "I submitted but nothing happened," check the
  daemon's `intake-dispatch-poll` (`daemon.md`) before suspecting this page — and
  now also the phone: the Workspaces hub shows the intake's state thread (L3).
- **Workspace list is intentionally `no-store`.** A cached list can offer a
  deleted/renamed `project_ref` that then 422s at submit. Don't add caching.
- **Intake is deliberately NOT offline-cached (decided: claude-tools-bnbb).**
  The shared offline-read worker (`web/shared/sw.js`) hard-bypasses `/intake` +
  `/api/intake`; Intake stays network-only. §2.4's "every surface reachable
  off-network" scopes to the §2.1 **read-model** view map (Board / Blueprint /
  Activity / Gates / Workspaces / Capacity / Cross-WS + the live Inbox) — Intake
  is the Flow-A **write** channel, not a read surface. It has no offline write
  path (a booted shell would only invite a Submit that can't complete), and
  caching its workspace list would violate the `no-store` "don't add caching"
  invariant above (the SW Cache API ignores `no-store`, so a stale list could
  offer a deleted/renamed `project_ref` that 422s). The YES path is reversible
  — the two code edits are: drop the two `isBypassed()` clauses in
  `web/shared/sw.js` and add `/shared/sw-register.js` to `intake/index.html`
  (sw.js caches generically via stale-while-revalidate, so there is no
  per-page precache list to touch); then extend the test's `PULL_PAGES`
  coverage list in `jsdom/test/sw-offline.test.js` to include `intake`. Do
  this only if Brian ever wants the shell to boot offline — the default is
  correctly NO. Don't "fix" the bypass by re-adding Intake to the offline path.
- **Empty / unreachable degrades honestly, not silently.** `loadWorkspaces()`
  with zero workspaces disables the picker with a "start a runner first" hint;
  a one-workspace deployment pre-selects it (single-tap confirm). `loadPresets()`
  with an empty catalog leaves Submit disabled rather than inventing a default.
- **`project_ref` regex is a *first* gate, not the authority.** A well-formed but
  unknown ref passes the proxy and only surfaces as "no such workspace" when the
  daemon can't match it to the registry — there is no live workspace list to
  consult inside the write proxy without a second round-trip.
- **The mirror can silently drift from the canonical JSON.** Pages functions
  can't read `agents/` at request time, so `_presets-catalog.js` is hand-kept.
  `test-intake-presets.sh` is the only thing that catches a missed mirror row —
  run it.

## Go deeper

- `beads-runner/web/intake/README.md` — the per-file rationale + the §-clause
  binding table (§9.1/§9.2/§4/§4.5/§0.3) this page realizes.
- `beads-runner/agents/intake-presets.md` — the catalog's reductive contract
  (every preset = entry_stage × gate_aggressiveness) + the add-a-preset playbook.
- `beads-runner/UX-DESIGN-V2.md` (Flow A) — the product intent: "one text box,
  one tap, ~5 seconds."
- `beads-runner/daemon/intake-dispatch-poll.sh` (and `test-i3-intake-dispatch.sh`)
  — the downstream poll + enricher dispatch this page feeds.
- `beads-runner/test-intake-presets.sh` — the catalog-drift harness.

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need
and didn't find here: a new form field + its downstream consumers, a moved
proxy, a changed projection, a new preset-related invariant, a fresh scar. Keep
it concise — this doc earns its keep only if agents read all of it. Delete lines
that have gone stale; don't let it grow into a re-spec of the README or
UX-DESIGN. Last substantive update: 2026-06-06 (uxvl4 — the special
`overview-request` preset: a no-bd-task catalog row, `routing:"overview-fyi"`,
schema_version 2; routes daemon-side to a dossier-builder FYI).
