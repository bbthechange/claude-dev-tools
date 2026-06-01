# Context: The bash library layer (shared by runner + tests)

> One-liner: the sourceable `lib/` bash that the runner loads at startup. Its
> centerpiece, `lib/coordinator.sh`, is BOTH a real local backend AND the
> **differential oracle** that `beads-runner/cf/src/*` mirrors clause-for-clause.

**Read this doc when** your task touches anything under `beads-runner/lib/`: the
bash coordinator/local-agent backends, dossier authoring, notification/timer
helpers, STUCK routing, the consequence applier, the HTTP transport to the live
engine, or a `test-<x>.sh` for one of these libs.

**Owns / scope (the files this doc covers):**
- `lib/coordinator.sh` — the bash Coordinator (store + 4 §2 capabilities + §9.1
  chokepoint) **and the frozen oracle the CF engine is asserted equal to**.
- `lib/co-http-transport.sh`, `lib/runner-backend-real.sh` — talking to the LIVE
  CF engine over HTTPS (transport override + the runner's six-job adapter).
- `lib/dossier.sh`, `lib/dossier-gen.sh`, `lib/dg-author-bridge.sh` — Dossier
  substrate + §5 body/items generation + the real dossier-builder shim.
- `lib/stuck-routing.sh`, `lib/consequence.sh` — STUCK_NEEDS_HUMAN routing/dedup
  + the idempotent per-Item ConsequenceBlock applier.
- `lib/notification.sh`, `lib/timed-fyi.sh` — §4.3 record + §2.2 timer (delivery
  pipeline is its own doc, below).
- `lib/local-agent.sh`, `lib/local-agent-stub.sh`, `lib/coordinator-stub.sh` —
  per-machine measurement/supervision + the NO-OP loop-shape stubs.
- `lib/activity-classifier.sh`, `lib/git-pin-main.sh`, `lib/node25-prime.sh`,
  `lib/sweep-fixtures.sh`, `lib/test-assert.sh` — small shared helpers.

**Not here (go to the right doc):**
- The CF realization of the SAME contract (`cf/src/*.js`, the Worker/DO/D1) →
  `engine-cloudflare.md`. These libs are the oracle; the engine is the twin.
- The runner loop that *sources* these libs → `runner.md`. The daemon that
  supervises runners → `daemon.md`.
- How to RUN the lib test suites / the regression gate → `testing.md`.
- The notification/push DELIVERY pipeline end-to-end → `notifications.md`
  (`notification.sh`/`timed-fyi.sh` are *part* of that flow).
- The worker/dossier-builder persona prompts dispatched behind `DG_AUTHOR_CMD` →
  `worker-agents.md`. The frozen INTERFACE.md/A–D contracts → `contracts-and-design.md`.

---

## Mental model

Three facts explain this layer:

1. **`coordinator.sh` is the differential ORACLE.** It is a fully working local
   backend (used by tests and as a fallback), and it is the FROZEN reference the
   CF engine mirrors. `cf/src/*.js` must exhibit the identical INTERFACE.md
   behavior; `cf/run-differential.sh` asserts it spec-by-spec, with the bash
   `lib/test-*.sh` as the oracle clauses. **Change a behavior here ⇒ mirror it
   in `cf/src` and keep them equal.** (`cf/DIFFERENTIAL-EQUIVALENCE.md`.)

2. **These libs are written against the FROZEN INTERFACE.md, not each other.**
   Each file's header binds the exact §-clauses it owns and the sibling surfaces
   it MUST NOT touch (e.g. `coordinator.sh` is substrate-only — no arbitration,
   no reconcile-semantics, no dossier production; those are siblings). The boundary
   IS the anti-drift contract — respect the header's OWNS / MUST-NOT split.

3. **Two backends, selected by env; the transport is an invisible override.**
   The runner's six §3 jobs are satisfied by either the stubs (`*-stub.sh`,
   `RUNNER_BACKEND=stub`, default — proves loop shape) or the real libs via
   `runner-backend-real.sh` (`RUNNER_BACKEND=real`). When `COORDINATOR_URL` is
   set, `co-http-transport.sh` transparently REPLACES the in-process `co_request`
   with authed HTTPS to the deployed Worker — same bash rc + bare-stdout contract,
   no call-site change. Absent `COORDINATOR_URL`, everything runs fully in-process
   (which is what keeps the oracle and conformance runs deterministic & offline).

## Key files

| File | Role |
|---|---|
| `coordinator.sh` | The bash Coordinator: §2.1 store (`co__store_put`/`_get` under `co__with_lock`), §2.2 timer, §2.3/§9.1 `co_authenticate`→`co_request` chokepoint, §4 record round-trip, plus capacity/forensic/reconcile/`co__work_snapshot`. **The frozen oracle.** Functions are `co_*`/`co__*`. |
| `co-http-transport.sh` | When `COORDINATOR_URL` set: overrides `co_request` with authed HTTPS to the live Worker; maps HTTP status→bash rc op-aware (401/404/409→1, 422→2/3, 5xx→4), normalizes the JSON envelope back to bare stdout. The D0–D6 reconnection spec. |
| `runner-backend-real.sh` | `RUNNER_BACKEND=real` adapter: bridges the runner's six-job names (`la_heartbeat`, `co_lease_acquire`, …) to the real libs' actual public names/arg-orders. An integration adapter, NOT an INTERFACE change. |
| `dossier.sh` | §4.1/§4.1.1 Dossier+Item substrate: the per-Item state machine (open→answered→applied / open→expired) + the two single-writer idempotency-latch STRUCTURES (`consequence_applied`, the task_ref dedup record). Structures only — apply LOGIC is `consequence.sh`. |
| `dossier-gen.sh` | §5 SOLE producer of `body`⊃`items[]` via ONE structured `dg_generate`. Deterministic jq author by default; `DG_AUTHOR_CMD` swaps in a real model/agent. All four body tiers MANDATORY (AD7); diagrams MUST be Mermaid. |
| `dg-author-bridge.sh` | The `DG_AUTHOR_CMD` shim wiring the Flow-B backstop to the real dossier-builder agent (hardened `claude -p` flags). stdin=generation_input JSON → stdout=`{body,items}`; rc≠0 ⇒ `dossier-gen.sh` falls back to the jq path. |
| `stuck-routing.sh` | §7.4 dossier-level double-trigger dedup (worker self-signal + runner backstop → ONE dossier via deterministic id from `task_ref`) + §7.3 backstop-drives-the-bead (status=blocked + `bd human`) + S-2 control→work reconcile. |
| `consequence.sh` | §5.3 idempotent per-Item ConsequenceBlock applier: applies creates/unblocks/labels/status_changes to the work plane via `bd`, latching `consequence_applied` false→true EXACTLY once inside the per-dossier critical section. |
| `notification.sh` | §4.3 Notification record (terse by construction: `no__validate` rejects any key outside the closed set; content lives in the dossier body, never here). One-per-Dossier; creation ≠ dispatch. See `notifications.md`. |
| `timed-fyi.sh` | §2.2 `fire(dossier_id)@T` timer for the timed-fyi auto-proceed window + the S-6 missed-fire ⇒ fire-on-next-poll backstop (`tf_fire` shared by alarm + poll-fallback); ready-to-pair `pair_arm`/`pair_surface` + the `pair_create` PRODUCER (kind:"pair" session card + arm; CLI face = top-level `pair-create.sh`). See `notifications.md`. |
| `local-agent.sh` | The per-computer Local Agent: §1.1 UP-only reports, §6.3 coarse capacity {ok,over} + USAGE_THRESHOLD ceiling, §6.2 unreachable posture (capacity fails OPEN, lease degraded-CLOSED), §8.2 terminal-reason re-home. |
| `*-stub.sh` | `local-agent-stub.sh` / `coordinator-stub.sh`: NO-OP six-job surface (signature-conformant) so the runner loop shape is provable before the real backend. |
| `activity-classifier.sh` | PURE log→activity-enum + liveness-dot classifier (Contract D.2 closed enum, 90/180s windows). No LLM, no I/O. |
| `git-pin-main.sh` / `node25-prime.sh` / `sweep-fixtures.sh` | Loop hygiene: pin HEAD back to trunk each iteration; prime Node-version PATH (avoid the v25-crashes-claude bug); self-heal orphaned LIVE-bd test fixtures. |
| `test-assert.sh` | Optional shared assert vocabulary (`ok`/`bad`/`ck`/`has`/`hasnt`/`eq`/`nz` + `summary`) so a new `test-*.sh` sources it instead of copy-pasting. |

## Contracts & invariants (don't break these)

- **Differential equivalence is the headline invariant.** A behavior change in
  `coordinator.sh` (or any oracle-bound lib) must be mirrored in `cf/src/*.js`
  and proven equal by `cf/run-differential.sh`. Drift between the two = a bug.
- **Each header's OWNS / MUST-NOT split is law.** `coordinator.sh` is substrate
  only (no arbitration, reconcile-semantics, or dossier production — those are
  siblings). Don't move a sibling's logic into the substrate to "save a file."
- **Tolerance at render, conformance at WRITE.** Dossiers are validated where
  they're written (`co__dossier_write_body_ok`, `no__validate`); renderers stay
  tolerant. Never add a write-time refusal to a renderer (the 4xe scar — see
  `bd memories`).
- **`co__work_snapshot` is read-only** — it derives every UI field at read time
  (S-1 liveness is never stored) and invokes no write primitive. The CF mirror
  (`reconcile.js workSnapshot`) is the projection's twin.
- **§0.3 reject-unknown-higher schema_version, never best-parse.** A wrong
  `schema_version`/`cb_schema_version`/`dossier_schema_version` is REJECTED. The
  jq type-check here is what the JS gate must match.
- **The §5 dossier schema is never shrunk to decision-singular (AD7).** All four
  body tiers + item granularity are §0.A. `DG_AUTHOR_CMD` swaps the *mechanism*,
  never the schema.
- **Convention: `lib/test-<x>.sh` tests `lib/<x>.sh`.** Add a behavior ⇒ extend
  that file's oracle clauses (and mirror in the matching `cf/test/<slice>.spec.js`).

## Common changes (recipes)

**Change a coordinator behavior (the oracle).** Edit `coordinator.sh`; extend
`lib/test-coordinator*.sh` to pin the new clause; then mirror the change in the
corresponding `cf/src/*.js` + `cf/test/*.spec.js` and run the differential:
```bash
bash beads-runner/lib/test-coordinator.sh        # the oracle clauses
(cd beads-runner/cf && ./run-differential.sh)    # asserts CF == oracle
```

**Add/extend a dossier/notification/stuck behavior.** Edit the owning lib, extend
its `test-<x>.sh`, mirror in the matching `cf/src` module (`dossier.js`,
`notification.js`, `stuck.js`, `timer.js`), then the differential as above.

**Swap the dossier author for a real agent.** Set `DG_AUTHOR_CMD` to a command
that reads generation_input JSON on stdin and emits `{body,items}` (see
`dg-author-bridge.sh`). Leave it unset for the deterministic jq path.

**Wire the real author for a whole process (claude-tools-69u8).** Don't export
`DG_AUTHOR_CMD` per-call-site — the bridge is now defaulted at the ONE
`dg__author` chokepoint. A runner/daemon opts the whole process in with
`export DG_AUTHOR_AUTOWIRE=1` at startup (both runners do; kill-switch: `=0`);
`dg__author` then auto-resolves the colocated `dg-author-bridge.sh` **iff**
claude is reachable AND `.source` isn't already pre-authored (the §xdo Flow F /
MCP case must not double-spawn a builder). Opt-in is OFF by default so the
offline unit tests keep the pure jq path. Override the bridge with
`DG_AUTHOR_BRIDGE_PATH` (prod swap + hermetic test seam). The v2 `runner.sh`
`_drive_blocked_for_human` authors its STUCK dossier through this seam in a
sourced subshell (it used to ship a body-less `co_store_put` stub).

**Always run the offline gate before `bd close`:**
```bash
bash beads-runner/run-tests.sh --changed   # fast pre-close; tiers touched by the diff
bash beads-runner/run-tests.sh             # full offline regression gate (T1–T7)
```
These libs run **fully in-process** (no `COORDINATOR_URL`) — that is what keeps
the oracle/conformance runs deterministic and offline. The live-Worker probe
(T8) is the separate manual acceptance step (`testing.md`).

## Gotchas / scars

- **`COORDINATOR_URL` flips the whole transport.** With it set, `co_request`
  is the HTTPS override and the placeholder bearer the libs carry will **401**
  unless a real per-workspace token is resolved (Keychain `la_coordinator_token`
  / `COORDINATOR_TOKEN`). A surprise 401 in a real run is almost always this.
- **The "stub vs real" name gap is real, not cosmetic.** The real libs realize
  the six §3 jobs under different public names/arg-orders — that's exactly why
  `runner-backend-real.sh` exists. Don't `source` the real libs raw expecting a
  byte drop-in; go through the adapter.
- **test-i3 PART C `nr=1 bead=null` is a known keychain-token harness artifact**,
  not a regression (`bd memories`).
- **The dg__author AUDIT LOG must be isolated in tests (claude-tools-69u8).** Its
  default is `$HOME/.cache/claude-tools/dossier-author-audit.jsonl` — keyed on
  `$HOME`, NOT `XDG_CACHE_HOME` — so tests that exercise `dg__author` (the lib
  tests, the conformance harness running run-beads-tasks.sh) silently polluted
  the REAL production telemetry until ~95% of the lifetime fire counts were test
  fixtures (`analysis-T1`, `swap`, `stuck-stuck-*`). `run-tests.sh` + the
  conformance `harness.sh` + `test-dossier-gen.sh` now pin `DG_AUDIT_LOG` to a
  scratch path. Any NEW test that drives `dg__author` must set `DG_AUDIT_LOG`
  (run-tests.sh covers it when run via the gate).
- **Loop-hygiene libs guard recurring footguns:** the runner never branches, so
  `git-pin-main.sh` re-pins HEAD to trunk each iteration; a daemon-stripped PATH
  resolves `claude` to Node v25 which crashes it (`node25-prime.sh`); SIGKILL'd
  workers leak LIVE-bd fixtures (`sweep-fixtures.sh` self-heals at gate start).

## Go deeper

- `beads-runner/INTERFACE.md` — the frozen §-clause contract every lib here binds.
- `beads-runner/cf/DIFFERENTIAL-EQUIVALENCE.md` — how the CF engine is held equal
  to this bash oracle (per-surface table + the 4 forward gates).
- `beads-runner/cf/README.md` — the INTERFACE→bash→CF mapping table (Appendix-A
  non-normative primitive map).
- Each lib's own header — the authoritative OWNS / MUST-NOT / bound-§ statement.
- `lib/test-<x>.sh` — the executable oracle clauses for `lib/<x>.sh`.

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a renamed/moved lib, a new env override, a fresh oracle clause,
a new MUST-NOT boundary, a scar. **Keep it concise — this doc earns its keep only
if agents read all of it.** Delete stale lines; never let it grow into a copy of
INTERFACE.md or the lib headers it points at. Last substantive update: 2026-05-31.
