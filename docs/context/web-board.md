# Context: The Board page (UX Flow E)

> One-liner: the one-screen situational-awareness view — *"is anything waiting
> on me, and is the machine healthy?"* It RENDERS the read-only work-snapshot
> projection and never re-derives liveness; a stale runner is structurally
> incapable of reading as `running` (S-1, principle 4 "honest state").

**Read this doc when** your task touches: anything under
`beads-runner/web/board/`, the Board's read proxy or its one write seam under
`web/functions/api/board/`, the honest desired≠actual surface, the
status/health strip, lifecycle columns, the per-machine capacity strip, or the
per-workspace Run/Pause/Spare-only/Stop toggles. The Board is the `/board`
route of the unified `claude-wrangler` Pages project.

**Owns / scope (the files this doc covers):**
- `web/board/board-view.js` — **the pure, headless-testable core.** `(§4.5
  projection) → view model`. No DOM, no network, no timers. Every honest-state
  / S-1 / failure-badge / capacity decision lives HERE.
- `web/board/app.js` — browser glue only: the read GET, the one write POST, and
  DOM painting. No state decisions.
- `web/board/index.html`, `web/board/board.css` — the responsive shell.
- `web/functions/api/board/index.js` — the read proxy (`GET /api/board`).
- `web/functions/api/board/set-desired.js` — the one write seam (`POST
  /api/board/set-desired`).

**Not here (go to the right doc):**
- The shared app shell (`web/shared/`), the Pages proxy LAYER conventions, and
  the deploy-then-verify gate → `docs/context/web-shell.md` (**read it for any
  web task**). The Board links its assets absolute (`/board/*`, `/shared/*`).
- The dossier / WAITING-ON-YOU detail rendering → `docs/context/web-inbox.md`.
  The Board's waiting lane is **only a POINTER** (`/inbox#<dossier_ref>` and
  `/inbox#/f/<bead_ref>`); it never renders a dossier body/items or the §10
  forensic stream.
- The projection PRODUCER (`workSnapshot()` / `co__work_snapshot`) →
  `docs/context/engine-cloudflare.md`. A field the Board needs but the
  projection does not emit is a §11 escalation, never a UI fabrication.
- The frozen contracts (A/B/C/D, INTERFACE.md §-clauses) →
  `docs/context/contracts-and-design.md`.

---

## Mental model

Three facts explain almost everything:

1. **One read, one write, both credential-less from the browser.** The whole
   client makes exactly two network calls: a same-origin `GET /api/board`
   (read) and a same-origin `POST /api/board/set-desired` (write, F1/F2). The
   browser holds NO secret — both Pages functions attach the server-only bearer
   and hard-code the upstream op (`work-snapshot` / `set-desired`). The Board
   never picks the principal or the op (§9.1 chokepoint, §9.2 secret).

2. **The renderer never derives liveness — it RENDERS it (S-1).** Liveness
   (`live`/`stale`) is computed by the Coordinator at read time and consumed
   verbatim. A `stale` runner gets its own `state_class:'stale'`, label "stale
   (last seen Nh ago)", and its last-reported `actual` is shown only as muted
   context — never promoted to a live pill. So a stale runner *cannot* read as
   `actual: running`. The 30s auto-refresh exists precisely so a runner going
   silent surfaces honestly. Formatting a timestamp into "Nh ago" is
   presentation of a contract field, NOT derived state — that is the only kind
   of derivation allowed here.

3. **All decisions live in `board-view.js`; `app.js` only paints.** The pure
   core takes the parsed projection JSON and returns a deterministic view model
   of strings (health headline, tags, runner rows, lifecycle cards, machine
   strips). `app.js` writes those strings into elements and wires click
   handlers. **New honest-state logic goes in board-view.js so the Node test
   can cover it** — never bury a decision in the DOM glue.

## Key files

| File | Role |
|---|---|
| `web/board/board-view.js` | The pure core. `deriveBoardView(snapshot, nowMs?, opts?)` is the entry; helpers `deriveRunner`, `deriveMachine`, `deriveQueueHealth`, `formatAgo`/`formatAgeSeconds`/`formatPct`. Holds `STAGE_ORDER`, `DESIRED_CONTROLS`, `NET_VELOCITY_ALARM_THRESHOLD`, `SUPPORTED_SNAPSHOT_SCHEMA`, the `SILENT_CLASSES` back-compat set, the §0.3 reject. |
| `web/board/app.js` | Browser glue. `refresh()` (the GET + render + auto-poll), `postSetDesired()` (the one POST), `render*` painters, the ephemeral `pendingDesired` overlay + `clearHonoredPending`. **claude-tools-758l:** `renderRunners` now delegates the runner state row + the F2 control row to the shared `RunnerCard.renderStateRow`/`renderControls` (`web/shared/runner-card.js`); the runner-card CSS moved to `web/shared/tokens.css` (bare control selectors). board.css keeps only the `.runners` grid + `.rqh`. `postSetDesired` stays local. |
| `web/board/index.html` | The shell DOM: status strip, WAITING-ON-YOU lane, lifecycle spine, machine strip, runners grid. Mounts `Shell.mount({active:null})`. Asset links are absolute (`/board/*`, `/shared/*`) — also served at `/` via `web/_redirects` (q6z7). |
| `web/board/board.css` | Responsive phone-first → desktop. Band classes (`band-green/amber/red/neutral/stale/missing`), `.silent`/`.failbead`, `.sub.verified`/`.sub.code` (done substate), `.rbtn.active`. |
| `web/functions/api/board/index.js` | Read proxy. `onRequestGet` ONLY (no write handler exists → POST hits 405). Hard-coded op `work-snapshot`. Unset bindings ⇒ honest 503; passes the projection body through verbatim (does not re-render §0.3). |
| `web/functions/api/board/set-desired.js` | The one write seam (F1). `onRequestPost` only, hard-coded op `set-desired`. Validates the 4 states locally (422 on typo) and **normalises UI `spare-only` → wire `spare-cycles`** (F3). |

## Contracts & invariants (don't break these)

- **S-1 / honest state (principle 4):** never paint desired over actual, never
  promote a stale runner's last task to "currently working", never let the
  client-side `pendingDesired` overlay promote actual. The pending tap is only
  a secondary "desired: X (waiting for runner to honor)" banner that clears the
  moment a refresh reports `actual === pending`.
- **Read-only by construction:** the read proxy exports only `onRequestGet`;
  the upstream op is the hard-coded literal `work-snapshot`. There is no handler
  that could mutate. Never add a write verb to the read path — the ONE write is
  the separate `set-desired.js`.
- **No UI-side derived state.** A field the Board needs but §4.5 does not emit
  is a §11 escalation, not a fabrication. (Known dormant slot: per-runner
  `capacity_verdict` was dropped from the projection in claude-tools-zdxd.5 —
  per-machine usage now surfaces ONCE via the top-of-board strip, never
  duplicated per runner.)
- **`STAGE_ORDER` and `DESIRED_CONTROLS` are frozen closed sets** mirroring the
  producer / `set-desired.js`'s `ALLOWED_STATES` in the same order — a UI typo
  and an engine typo cannot drift. The empty-string `''` bucket is the honest
  "unstaged" eighth lane; never fold it into `impl`.
- **§0.3:** an unknown HIGHER snapshot `schema_version` returns an error view —
  refuse, never best-effort-render. `SUPPORTED_SNAPSHOT_SCHEMA = 1`.
- **Tolerance at render, conformance at write (4xe scar).** Machine strips and
  failure badges degrade per-field (missing pct → `—`, stale → grayed + badge,
  gate disabled → neutral) — never refuse the whole strip. The write gate lives
  in the engine, not here.
- **Silent failures surface LOUDEST (UX principle 7).** The `silent` flag is
  consumed verbatim from the projection; `SILENT_CLASSES` in board-view.js is
  only a back-compat fallback for older producers — if you add a silent class,
  add it in BOTH the producer and here. A "⚠ N silent" chip carries `kind:'bad'`
  weight even when loud failures outnumber it.
- **The capacity strip binds FROZEN MACHINE-STATE.md v1 (D2).** `deriveMachine`
  re-derives the `<allowed>` gate using the SAME formula as
  `daemon/usage-poll.sh:_usage_poll_compute_allowed`; color bands key off
  `threshold_in_effect` (never a hardcoded 70). A D2 gap ⇒ reopen and re-freeze
  D2; never edit MACHINE-STATE.md silently.

## Common changes (recipes)

**Surface a new projection field on the Board (the typical task):**
1. Confirm the field is emitted by the §4.5 producer (Contract B). If not, it
   is a §11 escalation — STOP, file it (see `engine-cloudflare.md`).
2. Add the derivation to the right helper in **board-view.js** (`deriveRunner`
   for per-workspace, `deriveMachine` for capacity, the lifecycle-card mapper
   for cards, the `health`/`tags` block for the strip). Output strings only.
3. Add the painter line in **app.js** + a class in **board.css**. No decision
   logic in app.js.
4. Add an assertion in `lib/test-board.sh` (it drives board-view.js via Node
   against the REAL `coordinator.sh co__work_snapshot` output).
5. Run the gate, then **deploy + verify** (the bgw web discipline below).

**Add a desired-state control:** widen `DESIRED_CONTROLS` in board-view.js AND
`ALLOWED_STATES`/`WIRE_STATE` in `set-desired.js` together (same order), plus
the engine's `set-desired` op enum. Mismatched sets silently break Flow D for
one state (the F3 scar).

**Test + ship gate (run before every `bd close`):**
```bash
bash beads-runner/lib/test-board.sh        # EXIT-1..8, drives board-view.js via Node
bash beads-runner/run-tests.sh --changed   # the offline regression gate (testing.md)
# THEN — web tasks are NOT done until deployed + verified (bgw lesson):
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh board   # must print mismatches=0
```
`test-board.sh` is the Board's own focused surface — it is auto-enrolled into
`run-tests.sh` but is NOT a member of the T1 conformance suite.

## Gotchas / scars

- **"Wired but not live" (the F1/F2/F3/G1/L3 family, bgw).** Code lands + local
  tests pass, but the deploy didn't land, so the phone never sees it. `bd close`
  without `mismatches=0` against the live host is the forbidden failure.
- **F3 vocabulary seam:** the UI toggle is `spare-only`; the §4.2 wire enum is
  `spare-cycles`. The normalisation lives ONLY in `set-desired.js` — the daemon
  (M3) and the runner's C2 gate both read `spare-cycles` literally. Send the UI
  name verbatim and Flow D silently no-ops for that one state.
- **The pending overlay is in-memory only.** A reload starts honest with no
  pending banner. `clearHonoredPending` deletes an entry the instant the
  projection's actual catches up — never on a timer.
- **Queue Health (§9, Q1 claude-tools-uxvq1) is per-project, summed for the strip.**
  `projects[].queue_health` (B.1) is sourced from the runner's §4.6
  `workspace_inventory` (computed in `lib/local-agent.sh`, normalized in
  `cf/src/reconcile.js`), so it is WORK-TRUTH, not runner-state — `deriveRunner`
  attaches it ungated by liveness (a paused workspace can still have a runaway
  backlog). `deriveBoardView` sums the projects into the board-level
  `view.queue_health` and emits the §9 chips (net-velocity *runaway* alarm =
  `kind:'bad'`; empty-queue explainer + 0-ready epics = `kind:'warn'`). The
  alarm cutoff is the named, tunable `NET_VELOCITY_ALARM_THRESHOLD` (default
  `> 0`) — never a magic number; queue health is deliberately NOT folded into
  `health.ok` (machine health ≠ backlog trend).
- **Audit coverage (§9 row 4, Q9-4 claude-tools-t5ud) is the ONE queue_health
  field NOT derived from `bd`.** `queue_health.audit_coverage` is OPTIONAL
  `{read,total}|null` — present only when an **agent audit** has reported N items
  (null = no audit ⇒ no chip, never a phantom `0/0`). Audit coverage is a signal an
  audit EMITS, not a standing queue fact, so the runner READS it from a tolerant
  per-workspace marker file (default `.beads/runner-logs/audit-coverage.json` — the
  gitignored ephemeral dir, never committed; env `LA_AUDIT_COVERAGE_FILE`) — NOT
  from a bd query. The WRITER now exists (claude-tools-mhcp.2): `defer-cascade-audit.sh
  audit` emits the marker via `la_publish_audit_coverage` (`lib/local-agent.sh`, the
  SAME lib + path accessor `la_audit_coverage_file` as the reader, so they can't
  drift) — `total` = future-defer epics it had to examine, `read` = those it walked
  ok (`read<total` ⇒ a `bd` call failed ⇒ the audit may under-report ⇒ warn chip);
  it overwrites-or-removes each run so the marker never goes stale. Until a runner
  actually runs that audit in a workspace the field stays null (in-contract).
  `deriveQueueHealth` derives
  `coverage_complete`(`read>=total`)/`coverage_text`; the strip chip is NEUTRAL
  (`kind:'runners'`) when complete ("audit read everything") and WARN when not.
  Aggregate sums read/total across the projects whose audit reported.
- **`g2s` soft "thinking" is presentation-only.** Between 90s–180s heartbeat age
  on a `running` runner the pill softens to `thinking`, but wire `liveness`
  stays binary and control-button gating still keys off `liveness === 'live'`,
  never off `state_class`.
- **Unset proxy bindings ⇒ honest 503, never a fabricated projection.** The
  client surfaces the proxy's `{ok:false,error}` envelope verbatim (covers
  502 Coordinator-unreachable / 503 unconfigured / bearer-rejected).

## Go deeper

- `beads-runner/web/board/README.md` — the authoritative per-§ binding table and
  the deliberately-NOT-here anti-drift list. Read it fully before non-trivial work.
- `beads-runner/UX-DESIGN-V2.md` Flow E (line ~336) — the design intent ("is
  anything waiting on me + is the machine healthy?", extended with Queue Health).
- `beads-runner/lib/test-board.sh` — EXIT-1..8: one-screen answer, L3 per-card
  runner, S-1 offline→stale, write-path-by-structure, §0.3 reject, F2 toggles,
  8ag/4g5o current-task, g2s thinking, MACHINE-STATE §4 strip.
- `beads-runner/MACHINE-STATE.md` — the D2 telemetry contract the capacity strip
  binds; `daemon/usage-poll.sh` — the `<allowed>` gate formula it mirrors.

## Keeping this doc current

When you finish a Board task, append anything a future agent will need and
didn't find here: a new projection field you surfaced, a moved helper, a new
honest-state invariant, a fresh scar, a changed control set. Keep new
honest-state logic in `board-view.js` (not `app.js`) so the Node test covers it.
**Keep it concise — this doc earns its keep only if agents read all of it.**
Delete stale lines; don't let it grow into a copy of the README or INTERFACE.md.
Last substantive update: 2026-06-03 (Q9-4 audit_coverage on the §9 strip,
claude-tools-t5ud reader+surface; claude-tools-mhcp.2 added the writer —
`defer-cascade-audit.sh audit` now emits the marker — the one queue_health field
sourced from a marker file, not bd).
