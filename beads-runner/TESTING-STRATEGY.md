# Testing Strategy — beads-runner (UX v2 era)

Status: draft · Owner: Brian · Author: test-strategy agent · Date: 2026-05-30
Scope: **how we test the UX-v2 expansion without regressing, going flaky, or
becoming fragile.** Sits beside `UX-V2-ARCHITECTURE.md` (the contracts) and
`UX-DESIGN-V2.md` (the what). This doc is the *acceptance lens for tests*: every
ux-v2 impl bead checks its test work against the relevant section here before
`bd close`.

> **How to use this doc.**
> - Every **impl bead** in the ux-v2 epic (`claude-tools-mhcp`) and the v2-cutover
>   epic (`claude-tools-v2cut`) is handed this file. The per-track requirements in
>   §6 say exactly what tests that bead must add.
> - The **infrastructure** this strategy needs (§7) is filed as its own beads under
>   the testing epic — do those first; they unblock everything else.
> - Where this says **[invariant]**, a test that fails to pin it is incomplete.
>   Where it says **[free]**, the implementer picks the shape.

---

## 0. TL;DR

We already have a good, coherent testing culture. The strategy is to **extend it,
not replace it** — and to close the four gaps that will otherwise bite a
23-bead parallel build:

1. **No way to run "everything" and know green.** The only aggregator
   (`tmp/run-all-tests.sh`) covers `lib/` only; no CI. → Build one real runner (§7.1).
2. **The v2 anti-drift contracts (A–D) have no guardian test.** The whole point of
   `UX-V2-ARCHITECTURE.md` is to stop drift; nothing *fails* when drift happens. →
   Build the contract-conformance harness (§7.3), modelled on the existing
   `conformance-machine-state.sh`.
3. **The new app-shell router/nav/deep-links are untested.** View-model tests don't
   exercise routing. → Add deterministic jsdom shell/router tests (§7.4). **No
   Playwright** (§8).
4. **Per-track tests aren't specified, so they'll be inconsistent.** → §6 gives each
   open impl bead its exact test contract; those are also appended to the beads.

Everything else (the differential bash-oracle ⇆ vitest pairs, the view-model node
tests, `verify-pages-deploy.sh mismatches=0` before close) is working and stays.

---

## 1. The testing philosophy we already have (and keep)

These are the patterns in the repo today. They are good; new work conforms to them.

- **Differential conformance.** The engine has two realizations — the bash oracle
  (`lib/coordinator.sh` + `lib/test-*.sh`) and the JS engine (`cf/src/*` +
  `cf/test/*.spec.js`, run on real `workerd`+miniflare via
  `@cloudflare/vitest-pool-workers`, no Cloudflare account). Each `*.spec.js` is the
  twin of a `test-*.sh`, asserting the JS engine is **behaviour-identical** to the
  bash oracle. New engine behaviour ships **both halves**.
- **Pure view-model + node test.** Each web view is a pure
  `deriveXView(snapshot, now, opts)` UMD module, tested by a node-driven bash script
  (`lib/test-board.sh`, `test-capacity-view.sh`, `test-inbox.sh`,
  `test-workspaces-view.sh`). The DOM glue (`app.js`) is asserted by *structure*, not
  behaviour. New views follow `board-view.js` exactly.
- **Drive the real producer, never a hand-faked shape.** Renderer tests assert
  against the *actual* `workSnapshot()`/`co__work_snapshot` projection, not a
  hand-written JSON — the seam is tested against the frozen contract (the lesson
  `lib/test-board.sh`'s own header calls out).
- **Behavioral-contract (BC) conformance for the runner.** `conformance/` holds the
  runner regression scars against `run-beads-tasks.sh`, with a *shared* harness
  (`conformance/lib/harness.sh`, the `RESULT|PASS|bc-NN|…` protocol) and frozen
  fakes (`conformance/lib/fake-bin/{bd,claude,curl,…}`). This is the one tier with a
  shared harness — and it's the model for §7.2.
- **Close on what Brian experiences, not a passing weak check.** Web tasks
  live-verify with `verify-pages-deploy.sh mismatches=0` (the bgw/2dk lesson, in
  CLAUDE.md); engine tasks live-probe the real Worker. **Local-green + committed is
  NOT acceptance.**
- **Each test is self-contained.** Own `mktemp -d` store, own fixtures, shares no
  state with siblings (deliberate anti-drift). We keep this — see §8 on the shared
  helper being *vocabulary only*, never shared fixtures.

---

## 2. Test tiers — what each owns

| Tier | Lives in | Runs via | Owns | Network? |
|---|---|---|---|---|
| **T1 Engine unit/integration (bash oracle)** | `lib/test-*.sh` | `bash <file>` | `lib/*.sh` behaviour over a `mktemp` `CO_STORE`; fake `bd` on PATH | none |
| **T2 Engine differential (JS twin)** | `cf/test/*.spec.js` | `cd cf && npm test` | the CF engine ≡ the bash oracle, on real workerd+miniflare | none (local) |
| **T3 Web view-model** | `lib/test-*-view*.sh` + the `*-view.js` | `bash <file>` (drives `node`) | pure `deriveXView` output for a given snapshot | none |
| **T4 Web shell/router (NEW)** | `web/shared/*.test.*` (jsdom) | the runner (§7.4) | route resolution, nav, deep-link targets, tolerance gate | none |
| **T5 Daemon** | `daemon/test-*.sh` | `bash <file>` | out-of-loop dispatch, capacity gating, polls | none |
| **T6 Runner BC conformance** | `conformance/assertions/bc-*.sh` | `conformance/run-conformance.sh` | runner exit-code/classification/retry/watchdog/gate scars | none (fakes) |
| **T7 Contract conformance (NEW)** | `cf/test/conformance-*.sh` | the runner (§7.3) | the cross-cutting A–D seams (op-wiring, projection v2, enums, tolerance) | none |
| **T8 Live-verify** | `verify-pages-deploy.sh`, `cf/pages-dev/verify.sh`, real-Worker probe | `bash <file>` | committed bytes == deployed bytes; live contract shape | **yes** (deploy gate) |

**The split that matters for flakiness:** T1–T7 are **offline and deterministic** —
they are the regression gate that must be green on every change. **T8 alone touches
the network** and is the *acceptance* gate run at close time. Keep that boundary
clean: a unit test that reaches the network is a bug (§8).

---

## 3. Regression anchors — the bugs we must never re-ship

The design docs name a recurring failure family. Each gets a *named, permanent*
assertion so it cannot recur. These are the spine of the suite.

| Anchor | The bug | Test that pins it | Tier |
|---|---|---|---|
| **R1 closed-but-not-shipped** (bgw/2dk) | web task `done` in beads, deployed bytes never updated | `verify-pages-deploy.sh mismatches=0` is a *required close step*, not optional | T8 |
| **R2 projection drops a field** (56h) | a record field the UI needs is absent from `workSnapshot()` | T7 projection-v2 conformance: every Contract-B key present or honestly degraded | T7 |
| **R3 op not wired through all layers** (2dk) | new op missing the adapter/proxy/migration layer | T7 op-wiring conformance: each op present in module+guard+proxy+adapter(+migration) | T7 |
| **R4 enum drift / "gate" collision** | producer and consumer disagree on a closed set | T7 enum conformance: engine constants ≡ `web/shared/enums.js`, single source | T7 |
| **R5 render refusal re-added** (4xe) | a renderer throws/blanks on an accepted record | T7 tolerance conformance: per-field degrade + single integer schema gate | T7/T3 |
| **R6 verb empty-payload fallthrough** (L1 P1) | `dismiss-as-stale` silently re-applies the recommendation | each Inbox verb sends its own distinct payload; dismiss-as-stale consumes nothing | T1/T2/T3 |
| **R7 dossier asks a dead question** (L2) | bead resolved out-of-band, dossier stays in Inbox | resolve bead via side channel → dossier expires from projection | T1/T2 |
| **R8 liveness false-fires** (56× @ 60s) | tightening the 90/180s windows re-introduces ~56 false-fires | windows pinned at 90/180s with a guard comment; changing them fails the test | T1/T2 |
| **R9 silent agent deferral** (B8) | an agent holds work with no visible reason | every Gate requires non-empty `why`+`unblock`; agent-placed == human-placed visibility | T1/T2 |
| **R10 permanent local stuck record** (`1xx1`) | dismissed `worker_stuck` fork leaves a record the poll re-reads forever | dismissing a fork removes/ignores the local record on the next poll | T1/T5 |

**Rule:** when a bug in this family is fixed, the fix lands **with its R-anchor
assertion in the same commit.** A fix without a regression test is not done. (This is
also v2c3's explicit bar for the runner.)

---

## 4. The v2 invariants every relevant track must pin

From `UX-DESIGN-V2.md` + `UX-V2-ARCHITECTURE.md`, the mechanically-assertable
invariants. Each is owned by the track in parens and appears in §6.

- **[invariant] Projection is `schema_version:2`** and each track owns a *named
  sub-object* in `projects[]` (`activity`, `holds`, `queue_health`,
  `blueprint_meta`) — never a loose flat field (H/J/I/Q; Contract B.1).
- **[invariant] UI gates on `schema_version` as an integer ≤ bound**; unknown-higher
  is the *single* refusal point; everything else degrades per-field (all web; B.4).
- **[invariant] Single writer lane** — never two code-writing agents concurrent in a
  workspace (I; §5.1).
- **[invariant] Auxiliary pool is read-only** — no pool agent (incl. the cross-WS
  responder) has Write/Edit/mutating-Bash into the tree (I5, K1; §5.1/§8.1).
- **[invariant] Activity state is the closed D.2 enum**, derived from the exact
  tool→state mapping, always tagged `state_confidence:"derived"` (I1; D.2).
- **[invariant] Liveness windows = 90s / 180s**, presented as a heuristic, not
  tightened without re-measuring (I1; R8).
- **[invariant] Every Gate has `why` + `unblock_condition`**; only Gates are
  GUI-editable; dependency+scheduled holds are read-only (J; §7).
- **[invariant] Runner refuses a `gate:<id>`-labelled task** on pickup (J4, on the
  **v2 runner** — gated behind `v2c3`).
- **[invariant] Customization never clobbered** — updater rewrites `derived` only;
  override survives N regen cycles; orphan → `conflicts[]`/FYI, never silent revert
  (H4; principle 9).
- **[invariant] Structure-change redraw trigger** fires on design/impl/docs close or
  a domain/endpoint/store/dep/cross-edge diff; trivial close does **not** redraw (H5).
- **[invariant] Cross-WS batching is not optional** — N exchanges in a window → 1
  digest entry; mechanical → timed-fyi, conflict/missing-design → blocking dossier
  (K3✓/K4; §8.2/§8.3).
- **[invariant] Notification tier per trigger** matches the §10.2 catalog; payload
  carries *triage only*, never decision content (N1✓; principle 2).
- **[invariant] `done · code` vs `done · verified`** — a `done` card without a passing
  probe never renders `verified` (Board; principle 11/R1).
- **[invariant] Honest state** — UI renders `actual` + `stopping…/starting…`, never
  `desired` optimistically; state derives from the engine response, never a local
  patch (Board/Activity; principle 4).
- **[invariant] Intake state thread** surfaces received→enriching→created /
  failing(n)/gave-up (L3; the 19-silent-retry leak).
- **[invariant] overview-request preset produces NO bd task** (L4).

---

## 5. Acceptance gate — what "tested" means before `bd close`

A track's impl bead is **not closeable** until:

1. **Its tier tests are green** — engine beads: the bash-oracle test *and* its vitest
   twin; web beads: the view-model node test *and* (for shell/routed work) the T4
   shell test; runner beads: the BC conformance assertion.
2. **Its R-/invariant assertions exist** — the §3/§4 items the bead owns are pinned
   by a test that would fail if the behaviour regressed.
3. **The full offline suite is green** — `run-tests.sh` (§7.1) passes, proving the
   change didn't break a sibling (this is the *only* defence against the shared
   `workSnapshot()` seam, which H/J/I/Q all mutate).
4. **T8 live-verify passed** for production-touching work — web: `verify-pages-deploy.sh
   mismatches=0`; engine: a real authed probe against
   `coordinator-cf.bbthechange.workers.dev` returning the new shape. **This is the
   bgw/2dk line — local green is not acceptance.**

> ~~Carryover debt to clear: `uxvk3` (K3) is closed with **live-verify deferred** (not
> CF-deployed).~~ **CLEARED 2026-05-31 (`claude-tools-rznj.6`).** K3's `notif-digest`
> read-side rollup shipped to production in the 2026-05-30/31 `coordinator-cf` redeploys
> (the digest engine `groupDigests`/`noDigest` is byte-stable from K3→HEAD — N1 reuses it
> verbatim), and an authed probe against `coordinator-cf.bbthechange.workers.dev` returns
> the new shape `{digests:[{channel,count,tier,dossier_refs},…]}` with live prod data.
> That probe is now an institutionalized, re-runnable T8 step (PART D of
> `lib/test-co-http-transport.sh`, same token-gating as PART A/C — SKIPs without a token,
> so the offline gate stays network-free). The "closed but not shipped" precedent did not
> take hold.

---

## 6. Per-track test requirements (appended to each impl bead)

Each open impl bead gets a `## Testing` block (also added to the bead itself). The
engine convention is **bash oracle + vitest twin**; web is **view-model node test**;
runner is **BC conformance**.

### Track H — Blueprint
- **H1** `uxvh1` (engine): vitest twin + bash oracle for `blueprint-put`/`-get`;
  `blueprint` is a §4 record (in `schema.js` `SCHEMA_VERSIONS`, +migration present);
  write-gate rejects a malformed body; round-trip preserves `customization` untouched.
  Op-wiring: extend the T7 op-wiring fixture with the two new ops.
- **H2** `uxvh2` (web): `blueprint-view.js` pure derive test (node) — node/edge/api
  schema from the design; edge-resolution to deepest *visible* ancestor; focus/dim
  logic. **No layout-geometry assertions** (the engine internals are [free], swappable).
- **H3** `uxvh3` (web): narrative render test (TL;DR→headings→drill); **T4** route test
  that `/ws/<ref>/blueprint` mounts the facet and `?focus=<id>` deep-link resolves.
- **H4** `uxvh4` (web+engine): **[invariant]** override survives N regen cycles;
  updater rewrites `derived` only and never touches `customization`; orphan override →
  `conflicts[]` entry + FYI, kept by default (never silent revert).
- **H5** `uxvh5` (daemon/agent): **[invariant]** structure-change trigger fires on
  design/impl/docs close or structural diff; trivial close → no redraw; change → one
  `timed-fyi` (not a second mechanism). Drive the trigger predicate directly.

### Track J — Gates / unified Hold
- **J1** `uxvj1` (engine): bash oracle + vitest twin for `gate-meta-set/-get`;
  `gate_metadata` is a **transient** table — assert it is **absent** from `schema.js`
  `SCHEMA_VERSIONS` (the `conformance-machine-state.sh` PART D pattern); `why` required;
  `gate:<id>` format = lowercase/digits/hyphens.
- **J2** `uxvj2` (engine): `holds[]` unifier in `workSnapshot()` emits all three types
  (gate/dependency/scheduled) with `editable` correct (gate=true, others=false);
  cohort lift releases all owned defers. Add `holds` to the T7 projection fixture.
- **J3** `uxvj3` (web): Gates-facet view-model test — gate rows editable, dep/scheduled
  read-only (no edit affordance); **T4** route `/ws/<ref>/gates`.
- **J4** `uxvj4` (**v2 runner**, P1): a **BC conformance assertion** (`bc-*`) that the
  runner does **not** claim a `gate:<id>`-labelled ready task, alongside the
  `RUNNER_NO_CLAIM_LABELS`/`gate-policy.sh` path. Lands on `runner.sh` → the assertion
  is part of the v2c3 green bar. See §6-note.
- **J5** `uxvj5` (web): Board card shows the hold + unblock condition inline from
  `holds[]`; held card never renders without a reason.

### Track I — Activity / parallel / monitoring
- **I1** `uxvi1` (**v2 runner** + engine): table-driven parser test — feed synthetic
  tool-streams, assert each derived state against the **exact D.2 mapping**;
  **[invariant R8]** liveness 90/180 pinned with the "don't tighten / 60s=~56
  false-fires" guard; `state_confidence` always `"derived"`. Lands on v2 → part of v2c3.
- **I2** `uxvi2` (engine): `activity` + `runner_health` sub-objects in `workSnapshot()`;
  starved-but-alive runner reads `idle`, wedged reads `stuck` (the `dzc` shape). Add to
  T7 projection fixture.
- **I3** `uxvi3` (web): Activity-facet view-model — exactly-one writer lane rendered;
  aux pool 0..N; liveness dots green/amber/red; **T4** route `/ws/<ref>/activity`.
- **I4** `uxvi4` (web+runner): the four stuck actions (nudge/escalate/kill+retry/
  kill+gate) each reachable; escalate produces a Flow B dossier; kill+gate places a Gate.
- **I5** `uxvi5` (daemon): **[invariant]** parallel aux dispatch never spawns a second
  *writer*; dispatched aux has the read-only hat (no Write/Edit/mutating-Bash). Assert
  the capability set, not just intent.

### Track K — Cross-workspace sync
- **K1** `uxvk1` (agent/MCP): **[invariant]** responder capability lockdown —
  Read/Grep/Glob/bd-read only; assert a Write/Edit/mutating-Bash attempt is *refused*,
  not merely unused. Fork-parity with `mcp-askbrian` request/response framing.
- **K2** `uxvk2` (engine): `relay_log` transient (absent from `SCHEMA_VERSIONS`);
  `relay-log-append/-tail` bash oracle + vitest twin; tail shape matches B.3.
- **K4** `uxvk4` (agent): **[invariant]** mechanical answer → batched timed-fyi + relay
  entry; conflict/missing-design → **blocking** Flow B dossier (the two-path branch).
- **K5** `uxvk5` (web): coupling-map slice (reuses H2 renderer) + relay-log view-model;
  **T4** route `/cross-ws`.
- *(K3 `uxvk3` done; T8 CF live-verify **CLEARED** 2026-05-31 — `notif-digest` probed live, institutionalized as PART D of `lib/test-co-http-transport.sh`. See §5 note + §7.6.)*

### Track Q — Queue Health
- **Q1** `uxvq1` (engine+web): `queue_health` sub-object — ready/held-by-type/
  hidden-under-deferred-parent counts; epics-with-0-ready-children flagged;
  `net_velocity_7d = created−closed/day`. **Threshold is [free]** (Open Q #3) — test the
  *number is computed and surfaced*, not a specific alarm cutoff (so tuning it later
  doesn't break the test). Board-strip view-model test.

### Track L — Inbox/Intake leaks
- **L3** `uxvl3` (web): intake state thread renders received→enriching→created /
  failing(n)/gave-up; the failure + retry-count + gave-up states must surface.
- **L4** `uxvl4` (engine/intake): **[invariant]** overview-request preset creates **no
  bd task**; routes to Blueprint refresh / FYI.
- **L5** `uxvl5` (agent, bug): readability — a lint that flags an untranslated
  internal ID/jargon token in dossier body; fallback template passes the same lint;
  the residual fallback bug has a failing-then-fixed assertion.

### Standalone
- **1xx1** (bug): **[invariant R10]** dismissing a `worker_stuck` fork removes/ignores
  the local `bfh` record so the ~30s poll does not re-surface it.

> **§6-note — the v2-runner beads.** `uxvj4` and `uxvi1` land on `runner.sh` (v2) and
> are gated behind `v2c3` (conformance green). Their tests are authored as **BC
> conformance assertions** in `conformance/assertions/` so they become part of the
> cutover safety gate, not one-off scripts. This is why §7.2 (a coverage audit of the
> BC harness) blocks them.

---

## 7. Infrastructure to build (each is its own bead under the testing epic)

These are the "large pieces." Filed as beads with exact steps. Do §7.1 and §7.3 first
— they unblock confident parallel work on the 23 impl beads.

### 7.1 `run-tests.sh` — the one offline regression gate  [build first]
A committed `beads-runner/run-tests.sh` that runs **all offline tiers** with a unified
tally and a single exit code, superseding the partial `tmp/run-all-tests.sh` (lib-only).
Must: (a) run every `*.spec.js` via `(cd cf && npm test)`; (b) discover and run **all**
`test-*.sh` under `lib/ daemon/ hooks/ agents/` and top-level `beads-runner/`
(currently ~50 files — do **not** hardcode a list; glob, so new tests auto-enroll);
(c) run `conformance/run-conformance.sh`; (d) run `cf/test/conformance-machine-state.sh`
and the §7.3 contract conformance; (e) print `TIER pass/fail` lines + a final
`TOTAL pass=N fail=M`; exit non-zero on any fail. **Excludes T8** (network). Add a
`--tier <name>` filter and a `--changed` mode (run only tiers touching files in the
diff) so it's fast enough to run pre-close. Document it in CLAUDE.md as the gate.

### 7.2 BC-harness coverage audit + shared-vocabulary extraction
Two things: (a) **Coverage audit** (this is `v2c3`'s explicit mandate — do it there,
referenced here): enumerate v1 runner behaviours, map each to a `bc-*` assertion, list
the unmapped ones, file the gaps. (b) Extract the *assertion vocabulary* the ~50 bash
tests each re-define (`ok/bad/ck/has/hasnt/eq/nz`) into a single optional
`lib/test-assert.sh` that new tests **source** — **vocabulary only, never shared
fixtures or shared store** (the per-test `mktemp` isolation is deliberate and stays).
Do **not** mass-rewrite the 50 existing tests (churn + risk); new v2 tests use it,
existing ones migrate only when otherwise touched.

### 7.3 The v2 contract-conformance harness (A–D guardian)  [build first]
Model on `cf/test/conformance-machine-state.sh`. One (or a small set of) cross-cutting
test(s) that **fail when a Contract-A–D seam drifts**, authored *now* from the frozen
`UX-V2-ARCHITECTURE.md` so they guide impl:
- **Contract A (op-wiring):** a fixture listing each v2 op and the layers it must
  appear in (module `*_OPS` set, `coordinator.js` guard, `web/functions/api/.../*.js`
  proxy, `cf/pages-dev/adapter.js` mapping, migration if it added a table). Grep each
  layer; a missing layer fails. Prevents R3/2dk. Seed it with the existing ops as the
  passing baseline; tracks add their op rows.
- **Contract B (projection v2):** assert `workSnapshot()` emits `schema_version:2` and
  the B.1 shape; each track's named sub-object is present **or honestly degraded**
  (never silently dropped). Prevents R2/56h. This is the guardian of the one shared
  mutable seam (`reconcile.js`).
- **Contract D (enums):** create `web/shared/enums.js` as the **single source of
  truth** for the closed sets (activity-state, hold types, notif tiers, liveness
  90/180) and matching engine constants; the test asserts the two are byte-equivalent
  sets. Prevents R4. *(Note: `enums.js` does not exist yet — this bead creates it; the
  C-shell extraction did `net/dom/shell/tokens` but not enums.)*
- **Contract B.4 (tolerance):** assert each new view-model degrades per-field and has
  exactly one integer schema gate (reuse the `inbox-view.js` `schemaGate` pattern).
  Prevents R5/4xe.

### 7.4 Shell / router / deep-link tests (jsdom)  [moderate]
The C-shell (`uxvsh`) added a router (Contract C.2 route shape), persistent nav, and
deep-links — none tested. Add deterministic **jsdom** tests (a `cf`-style devDep, run by
`run-tests.sh`) that assert: each global route (`/inbox /workspaces /capacity /cross-ws`)
and workspace facet (`/ws/<ref>/{board,blueprint,activity,gates}`) resolves to the right
mounted view; nav renders the 5+4 set; deep-links (Board→Blueprint area, dossier→focus
slice, holds→Gates) compute the right target. jsdom (not a real browser) keeps it
**deterministic and fast**; see §8 for why not Playwright. Each facet bead (H3/I3/J3/K5)
adds its route case here.

### 7.5 (decision) Offline CI on push
There is no CI (`.github/` absent). The T1–T7 tiers are offline+deterministic, so a CI
that runs `run-tests.sh` on push would catch regressions with **no prod secrets**
(T8 stays manual at close). This needs a Brian yes/no (does this repo want GitHub
Actions at all?) — filed as a low-priority bead with that question, not assumed.

### 7.6 Clear the deferred-live-verify debt (K3)  ✅ DONE (`claude-tools-rznj.6`, 2026-05-31)
`uxvk3` was closed with CF deploy/live-verify deferred. The residual T8 step is now both
**filed and executed**: K3's `notif-digest` rollup shipped in the 2026-05-30/31
`coordinator-cf` redeploys (its digest engine is byte-stable K3→HEAD), and an authed probe
returns the new `{digests:[…]}` shape against the live Worker. The probe is institutionalized
as **PART D of `lib/test-co-http-transport.sh`** (token-gated like PART A/C: runs at close
when a prod token resolves, SKIPs by-design otherwise so `run-tests.sh` stays network-free).
The "closed but not shipped" precedent (R1) did not take hold. Note: the live Worker was
deployed from a prior `main`-line state; the 3 in-flight worker commits ahead of that deploy
(N3/G2, `reconcile.js`/`timer.js`) are **other tracks** and ship under their own acceptance —
this debt-clear did not redeploy them (K3 is byte-stable and already live).

---

## 8. Anti-flaky / anti-fragile rules  [invariant]

The user's bar: tests that *prevent* regressions without being flaky, non-deterministic,
or fragile. The rules that deliver that here:

- **No network below T8.** A unit/integration test that hits a URL is a defect. The one
  legitimate live test (`lib/test-co-http-transport.sh` PART A/C, `verify-*`) is T8 and
  is *expected* to be skipped/SKIP without a prod token — that SKIP is not a failure.
- **Deterministic clocks.** Never assert on wall-clock. Pass an explicit `now` into
  `deriveLiveness`/view-models (the existing pattern). Time-window tests advance a
  supplied `now`, not `sleep`.
- **No `Date.now()`/random in assertions.** Liveness/age tests use the injected clock;
  age strings are computed from `(now − observed_at)`, both supplied.
- **Per-test isolation stays.** Own `mktemp -d` store, own fake `bd` on PATH, `trap rm`
  cleanup. The shared helper (§7.2) is **vocabulary only** — never a shared store/fixture
  (shared mutable state is the classic flake source; the repo already avoids it on
  purpose).
- **Assert behaviour/structure, not prose.** Don't grep for a comment or a UI string
  that will legitimately change; assert the *projection shape*, the *capability set*,
  the *route target*. (The existing tests already favour structural assertions over
  defeatable source greps — keep that.)
- **Drive the real producer.** Renderer tests consume the actual projection, so a
  producer change can't leave a renderer test green against a stale hand-faked shape.
- **Pin numbers that are contracts, free numbers that are tunable.** 90/180 liveness and
  the D.2 enum are pinned (changing them must fail a test). Net-velocity alarm cutoff,
  digest cadence, the 14.2% ramp's *display* are [free]/tunable — test that the value is
  *computed and surfaced*, not a magic threshold, so tuning doesn't break tests.
- **No Playwright/headless-browser e2e.** For a single-dev, mobile web app the
  full-browser tier is the flaky/fragile category (timing, selectors, deploy coupling).
  We get the coverage deterministically with: T3 view-model (logic) + T4 jsdom (router/
  nav/deep-links) + `cf/pages-dev/verify.sh` curl-level serve check + T8
  `verify-pages-deploy.sh` (bytes live). If a future flow genuinely needs in-browser
  behaviour, that's a scoped decision, not a default.

---

## 9. What's deliberately out of scope / [free]

- **Coverage-percentage targets.** We gate on *named invariants + R-anchors*, not a
  line-coverage number (line coverage rewards the wrong tests for this codebase).
- **Layout-engine geometry (Blueprint).** The HANDOFF says don't productionize the
  prototype; test the *schema + edge-resolution IP*, not pixel positions.
- **The router library / facet-as-tabs-vs-segmented.** [free] (Contract C.3) — T4 tests
  the *route shape*, not the impl.
- **Tunable thresholds** (§8) — tested as "computed and surfaced," not pinned.

---

*Amend like the other contract docs: explicit section, rationale, date. The R-anchors
(§3) and the §8 anti-flaky rules especially — weakening one is a cross-suite event.*
