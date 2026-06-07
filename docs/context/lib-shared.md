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
| `coordinator.sh` | The bash Coordinator: §2.1 store (`co__store_put`/`_get` under `co__with_lock`), §2.2 timer, §2.3/§9.1 `co_authenticate`→`co_request` chokepoint, §4 record round-trip, plus capacity/forensic/reconcile/`co__work_snapshot` + the J1 `gate-meta-set`/`-get` ops (transient `gate_metadata/` namespace, NOT a §4 record — twin of `cf/src/gate-meta.js`; clauses in `test-coordinator-gate-meta.sh`). **The frozen oracle.** Functions are `co_*`/`co__*`. |
| `co-http-transport.sh` | When `COORDINATOR_URL` set: overrides `co_request` with authed HTTPS to the live Worker; maps HTTP status→bash rc op-aware (401/404/409→1, 422→2/3, 5xx→4), normalizes the JSON envelope back to bare stdout. The D0–D6 reconnection spec. |
| `runner-backend-real.sh` | `RUNNER_BACKEND=real` adapter: bridges the runner's six-job names (`la_heartbeat`, `co_lease_acquire`, …) to the real libs' actual public names/arg-orders. An integration adapter, NOT an INTERFACE change. |
| `dossier.sh` | §4.1/§4.1.1 Dossier+Item substrate: the per-Item state machine (open→answered→applied / open→expired) + the two single-writer idempotency-latch STRUCTURES (`consequence_applied`, the task_ref dedup record). Structures only — apply LOGIC is `consequence.sh`. |
| `dossier-gen.sh` | §5 SOLE producer of `body`⊃`items[]` via ONE structured `dg_generate`. Deterministic jq author by default; `DG_AUTHOR_CMD` swaps in a real model/agent. All four body tiers MANDATORY (AD7); diagrams MUST be Mermaid. |
| `dg-author-bridge.sh` | The `DG_AUTHOR_CMD` shim wiring the Flow-B backstop to the real dossier-builder agent (hardened `claude -p` flags). stdin=generation_input JSON → stdout=`{body,items}`; rc≠0 ⇒ `dossier-gen.sh` falls back to the jq path. |
| `stuck-routing.sh` | §7.4 dossier-level double-trigger dedup (worker self-signal + runner backstop → ONE dossier via deterministic id from `task_ref`) + §7.3 backstop-drives-the-bead (status=blocked + `bd human`) + S-2 control→work reconcile. |
| `consequence.sh` | §5.3 idempotent per-Item ConsequenceBlock applier: applies creates/unblocks/labels/status_changes to the work plane via `bd`, latching `consequence_applied` false→true EXACTLY once inside the per-dossier critical section. |
| `notification.sh` | §4.3 Notification record (terse by construction: `no__validate` rejects any key outside the closed set; content lives in the dossier body, never here). One-per-Dossier; creation ≠ dispatch. **Exception:** `no_emit_fyi` (claude-tools-mhcp.1) is the DOSSIER-LESS producer the cross-WS answer path uses — it stamps an explicit `timed-fyi` tier + `xws:<ref>` channel with `dossier_ref`=a relay exchange id (no backing dossier; `no_emit` requires one), composing the generic `put notification` front door. K3's `no_digest` groups these by channel. See `notifications.md` + `mcp-askbrian.md`. |
| `timed-fyi.sh` | §2.2 `fire(dossier_id)@T` timer for the timed-fyi auto-proceed window + the S-6 missed-fire ⇒ fire-on-next-poll backstop (`tf_fire` shared by alarm + poll-fallback); ready-to-pair `pair_arm`/`pair_surface` + the `pair_create` PRODUCER (kind:"pair" session card + arm; CLI face = top-level `pair-create.sh`). See `notifications.md`. |
| `local-agent.sh` | The per-computer Local Agent: §1.1 UP-only reports, §6.3 coarse capacity {ok,over} + USAGE_THRESHOLD ceiling, §6.2 unreachable posture (capacity fails OPEN, lease degraded-CLOSED), §8.2 terminal-reason re-home. |
| `*-stub.sh` | `local-agent-stub.sh` / `coordinator-stub.sh`: NO-OP six-job surface (signature-conformant) so the runner loop shape is provable before the real backend. |
| `activity-classifier.sh` | PURE log→activity-enum + liveness-dot classifier (Contract D.2 closed enum, 90/180s windows). No LLM, no I/O. |
| `activity-report.sh` | I1 runner-side companion (sources `activity-classifier.sh`): extracts facts (last tool from assistant **content** blocks, ask-brian-in-flight, real-429 vs benign subscription) from a `stream-json` capture → classifies → **throttled, backgrounded** `agent-activity-report` POST. The shared seam I5 reuses on daemon aux streams. NB: tab is IFS-whitespace, so its `read` sites translate tab→`\x1f` to keep empty fields. |
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
  scratch path. Any NEW test that drives `dg__author` must set `DG_AUDIT_LOG`.
  The gate (`run-tests.sh:61`) exports it, but that is NOT sufficient on its own:
  claude-tools-j30y re-measured the clean log and found 69u8 left two leaks —
  (a) `test-dossier-gen.sh` did `unset DG_AUTHOR_CMD DG_AUDIT_LOG` mid-script,
  re-exposing the REAL log for the `b3lint`/readability section below it (a
  recurring leak even *through the gate*), and (b) the manual, non-gate
  `mcp-ask-workspace/test-{mcp-protocol,escalate-conformance}.sh` had no
  isolation at all (the `XWS_SMOKE_ESCALATE=1` leg spawns the real bridge →
  `thirsty-fe-77e` fixture rows). Both fixed in j30y. RULES: never `unset
  DG_AUDIT_LOG` mid-script, and non-gate tests must isolate it themselves.
  PRODUCTION SIGNAL (j30y, clean window post-69u8): genuine `agent_unavailable`
  is ~0 — every residual row is a fixture; the agent path (opus-4-7) is healthy
  and the only non-fixture "failures" are honest `{refuse:true}` of thin input.
- **A new CF data-returning op MUST be added to `co_http__op_is_data`** (the
  DATA-200 allowlist in `co-http-transport.sh`) or its 200 JSON body is SUPPRESSED
  to empty stdout over the HTTP transport (it falls to the ACK-200 arm: rc 0 but
  nothing to read). Recurring footgun — bit `intake-pending` (I3),
  `agent-action-pending` (I4), and `relay-log-tail`/`notif-digest` (K2/K3,
  claude-tools-u1pt). Offline tests pass (they use the in-process oracle, not this
  transport); only live-verify / a local-engine clause catches it. Write-side ops
  (e.g. `relay-log-append`) correctly stay ACK.
- **The local `.co-store` store is now LIVE in PROD for desired-state (claude-tools-dky8/y6j9
  P1 SHIPPED).** When `COORDINATOR_URL` is set, `co-http-transport.sh:168` redefines `co_request`
  wholesale — but it overrides ONLY `co_request`, NOT the store primitives, so `co__store_get`/
  `co__store_put` read/write the local file directly even in PROD. `co_store_dir()` defaults to
  `$TMPDIR` but the runner (`runner.sh` startup `export CO_STORE`, y6j9 — was the :730 subshell
  ONLY) and daemon both pin `CO_STORE` to `<ws>/.beads/runner-logs/.co-store`. **The runner is
  now LOCAL-AUTHORITATIVE for `desired`:** `runner-backend-real.sh co_deliver_desired_state` reads
  `co__store_get runner_state` FIRST (network is a cold-start seed only — the break-through-pause
  fix), and Brian's Stop/Run taps ride the `agent_actions` TRANSIENT queue's NEW `set-desired`
  intent (`co__agent_action_enqueue` enum at coordinator.sh:773 + the per-intent `args.state`
  branch; the CF twin is `cf/src/agent-action.js` `AGENT_ACTION_INTENTS` + `intentRequirementError`
  — keep them differential-equivalent). The daemon's `agent-action-poll.sh` is the SINGLE consumer
  → `co__set_desired` writes the local record (apply-local-before-ack). Do NOT register a new §4
  record for change-requests; do NOT re-add a network-authoritative desired read.
- **§4 WRITE-THROUGH cache of 2xx hosted responses is now LIVE in PROD (claude-tools-cx7t, P4
  SHIPPED).** The §4 record round-trip of the local store — inert under the HTTP override until now
  — is RE-ACTIVATED: in `co-http-transport.sh` the 2xx DATA arms call `co_http__cache_record`
  (best-effort `co__store_put`) AFTER emitting the verbatim body, so a hosted read seeds the local
  fallback P1/P2 consult on a miss. STRICTLY best-effort & non-blocking — it suppresses all output
  and always returns 0, so a cache miss/reject NEVER changes the rc/stdout the caller sees (the
  in-process contract). It re-stamps with the record's OWN server `.principal` so co__store_put's
  §9.1 stamp is idempotent (the cached copy stays byte-equal to the D1 row — §8bm). **Only genuine
  single-§4-record bodies are cached:** `get` (keyed type=args[0],id=args[1]) and `lease-acquire`/
  `lease-renew` (the unwrapped `.lease`, keyed `lease`,task_ref). **DELIBERATELY NOT cached** (would
  break a shipped invariant, NOT an omission): `get runner_state` AND `poll` — the transport must
  never seed local desired (the break-through-pause invariant above; the daemon is the SOLE writer);
  and `work-snapshot`/`reconcile` — read-only DERIVED projections (S-1 liveness is never stored).
  co__store_put is already the differential-equivalent §4 write chokepoint, so the cache inherits D1
  equivalence (no CF twin — the transport IS the bash↔engine bridge). Tests: `test-co-http-transport.sh`
  PART F (always-run, stubbed curl) + the PART B BCACHE assertion (live byte-identical engine).
- **The local-agent LEASE-CACHE stores a §4.4 ENVELOPE, NOT the `.co-store` (claude-tools-h9dl,
  P2 SHIPPED).** Distinct mechanism from the `.co-store` desired-state store above: the bounded-
  local-fallback cache (`local-agent.sh` `la__lease_cache_dir` = `$LOG_DIR/lease-cache/<task>`, a
  T3 artifact) now holds a JSON envelope `{generation, owner, acquired_epoch, ttl_seconds,
  expires_epoch}` MIRRORING the §4.4 Lease record's load-bearing subset — it was a bare acquired_at
  epoch. It does NOT touch coordinator.sh, the `.co-store`, or D1, so there is NO CF mirror and NO
  differential-equivalence obligation (local-agent.sh is the per-machine LA, not the oracle). Why:
  (1) `la_lease_recover_generation` lets the runner re-seed `LEASE_GENERATION` from cache on a
  restart/blip so the unreachable-fallback path no longer sends an EMPTY fence token (ylu2 follow-up
  #1 — an empty gen makes the next heartbeat's renew a no-op, so the lease silently lapses once the
  Coordinator recovers); (2) `la_lease_fallback_allows` now validates against the STORED expiry, and
  the runner refreshes `note_held` on each renew tick GATED on a GRANTED renew (`LA_LEASE_RENEW_RC
  == 0`, a sidecar `la_heartbeat` sets from the renew's rc), so a task longer than `LEASE_TTL` no
  longer under-reports validity — but neither a prolonged OUTAGE nor a reachable-but-DENIED renew (a
  mid-outage takeover bumped the generation, then connectivity returned) advances the local expiry,
  preserving the bounded property. Gating on mere reachability would let a denied renew extend a
  stale hold a SIGKILL+restart could wrongly resume on. Still cannot DETECT a takeover offline — the
  reachable path must re-validate. Clauses: `lib/test-local-agent.sh` (§4.4 envelope) +
  `conformance/assertions/bc-ad2-lease-posture-tree.sh` (`ad22tree-h9dl-…`). Legacy bare-epoch cache
  files (pre-P2 / external writers) are still honoured.
- **Loop-hygiene libs guard recurring footguns:** the runner never branches, so
  `git-pin-main.sh` re-pins HEAD to trunk each iteration; a daemon-stripped PATH
  resolves `claude` to Node v25 which crashes it (`node25-prime.sh`); SIGKILL'd
  workers leak LIVE-bd fixtures (`sweep-fixtures.sh` self-heals at gate start).
- **`sr_poll_hosted_resolution` now has THREE poll-owned sibling namespaces, and a
  DISMISSED fork must STOP re-reading the hosted dossier (claude-tools-1xx1,
  `stuck-routing.sh`).** A `worker_stuck` fork the human DISMISSED-as-stale (every
  Item `expired`, no `answered|applied`) is correctly PARKED by uxvl1 — but the
  poll kept doing one hosted `do_dossier_get` on its all-expired dossier EVERY
  poll (~30s) forever (unbounded low-rate read, per-dismissal). Fix: a third
  poll-owned sibling namespace `sr__dismissed_dir` (beside `sr__bfh_dir` /
  `sr__answer_dir`) — the poll writes a one-shot sentinel when the dossier is
  fully TERMINAL and skips the hosted read next time. TWO invariants a future edit
  must NOT break: (1) the skip path NEVER calls `sr__resolve_bfh` (a resolve lifts
  the block + re-dispatches with an EMPTY answer = the uxvl1 false-resume bug it
  exists to prevent — the fork stays `resolved:false` until the human acts on the
  bead directly); (2) "fully terminal" REQUIRES `>0 Items` AND none `open|answered`
  — an item-LESS dossier rolls up `open` (NOT terminal, §4.1.1) and MUST keep
  polling (else a parked item-less fork stalls forever). The sentinel is cleared
  on a FRESH `sr__raise_bfh` (re-fork) and swept at both reconcile hard-delete
  sites. Runner/daemon-side only — NO CF twin (no poll op in `cf/src/stuck.js`),
  like `sr__answer_dir`. Lock: the claude-tools-1xx1 section of `test-stuck-routing.sh`
  (a `do_dossier_get` spy proving the 2nd poll does zero hosted reads).

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
INTERFACE.md or the lib headers it points at. Last substantive update: 2026-06-07 (a DISMISSED
worker_stuck fork now STOPS re-reading its all-expired hosted dossier every poll — third poll-owned
sibling namespace `sr__dismissed_dir`; the skip NEVER calls `sr__resolve_bfh` and "terminal" requires
`>0 Items` so an item-less dossier keeps polling — claude-tools-1xx1; see the new scar above). Prior:
2026-06-06 (§4 write-through
cache of 2xx hosted responses RE-ACTIVATED in PROD — `get`/`lease-*` cached, `runner_state`/`poll`/
`work-snapshot` carved out; best-effort, differential-equivalent — claude-tools-cx7t). Prior: local-agent
lease-cache now stores a §4.4 ENVELOPE — generation+ttl+expires — so a restart/blip recovers the
fencing token without the network; distinct from the `.co-store` store, no CF mirror —
claude-tools-h9dl. Prior: local-first `.co-store` §4 store re-activated for desired-state — claude-tools-dky8;
reuse the `agent_actions` queue for change-requests, don't add a §4 record. Prior: 2026-06-03 (co_http__op_is_data DATA-200 allowlist scar + relay-log-tail/notif-digest passthrough — claude-tools-u1pt).
