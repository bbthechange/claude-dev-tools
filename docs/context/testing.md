# Context: How to test + the quality gates

> One-liner: `beads-runner/run-tests.sh` is the **one offline regression gate** —
> every offline deterministic tier, one tally, one exit code. A green run is the
> §5 acceptance-bar "full offline suite is green" step. **T8 live-verify stays
> manual at close** — green here is the regression gate, not acceptance.

**Read this doc when** your task touches: running the suite before a `bd close`,
adding/finding a test tier, the conformance (runner-BC) harness, the contract A–D
guardian, the live-verify (T8) step, the close-time enforcement hooks, or you hit
a confusing test fail and need to know whether it's yours.

**Owns / scope (the files this doc covers):**
- `beads-runner/run-tests.sh` — the gate (tier discovery by glob, per-tier tally).
- `beads-runner/TESTING-STRATEGY.md` — the tier strategy, §5 acceptance bar, anti-flaky rules.
- `beads-runner/conformance/` — the runner behavioral-contract (BC) harness.
- `beads-runner/cf/test/conformance-*.sh` — the contract A–D + machine-state guardian (T7).
- `beads-runner/verify-pages-deploy.sh`, `cf/pages-dev/verify.sh` — the networked T8 live-verify.
- `beads-runner/hooks/` — the close-time enforcement hooks.
- `beads-runner/lib/{test-assert,sweep-fixtures}.sh` — the shared test vocabulary + fixture self-heal.

**Not here (go to the right doc):**
- The CODE each tier exercises → `engine-cloudflare.md` (cf/), `lib-shared.md` (lib/),
  `runner.md` (the runner scripts), `daemon.md` (daemon/), the `web-*.md` docs (web/).
  This doc owns how to RUN the tests, not what they assert about that code.
- The runner's behavioral-contract DOCUMENT itself (`BEHAVIORAL-CONTRACT.md`, the BC-NN
  scars) → `runner.md` / `contracts-and-design.md`. This doc owns how to run its harness.
- The frozen contracts A/B/C/D + the §-clause INTERFACE → `contracts-and-design.md`.
- The deploy-then-verify discipline as a *web* workflow → `web-shell.md` (it owns the
  deploy command; this doc owns T8's place in the gate ladder).

---

## Mental model

**Two gates, one boundary.** TESTING-STRATEGY.md §2 splits every test into tiers
T1–T8. **T1–T7 are offline and deterministic** — they are the *regression* gate,
green on every change. **T8 alone touches the network** — it is the *acceptance*
gate, run by hand at close. `run-tests.sh` runs exactly T1–T7 and deliberately
EXCLUDES T8. Keep that boundary clean: a unit test that reaches a URL is a defect (§8).

**One command, one exit code.** `run-tests.sh` supersedes the old lib-only
`tmp/run-all-tests.sh`. It runs every offline tier, prints `TIER <name> pass=N
fail=M` per tier and a final `TOTAL pass=N fail=M`, and exits 0 iff every selected
unit passed (non-zero names the failing tier). That single green is the §5 bar's
step 3 — the *only* defence against a change breaking a sibling through the shared
`workSnapshot()` projection seam (which H/J/I/Q all mutate).

**Tiers auto-enroll by glob, never a hardcoded list.** A new `test-*.sh` under any
enrolled dir, a new `cf/test/conformance-*.sh`, a new `cf/test/*.spec.js`, or a new
`jsdom/test/*.test.js` joins the gate the moment it lands. You write the test; you
do not register it.

**Differential conformance is the spine.** The engine has two realizations — the
bash oracle (`lib/coordinator.sh` + `lib/test-*.sh`) and the JS twin (`cf/src/*` +
`cf/test/*.spec.js` on real workerd+miniflare). Each spec asserts the JS engine is
behaviour-identical to the bash oracle. New engine behaviour ships BOTH halves, and
both run inside the gate (tiers `lib` and `cf`). `lib/test-<x>.sh` tests `lib/<x>.sh`.

## Key files

| File | Role |
|---|---|
| `run-tests.sh` | THE offline gate. Globs tiers, runs each, tallies, single exit. Singleton mkdir-lock (exit 75 = busy). Neutralizes the coordinator token + shims `security` so live probes SKIP; forces `DG_AUTHOR_AUTOWIRE=0` so no tier spawns claude-in-claude (bmfj). Sweeps stale fixtures up front. |
| `TESTING-STRATEGY.md` | The canon: §2 tier table, §3 R-anchors (named regression scars), §5 acceptance bar, §7.x infra, §8 anti-flaky rules. The acceptance lens every test checks against. |
| `conformance/run-conformance.sh` | The runner BC harness driver (tier `conformance`). Runs `run-beads-tasks.sh` under stubbed `bd`/`claude`/`security`/`curl`, asserts each BC scar black-box. Exit 0 = HARNESS GREEN. |
| `conformance/assertions/bc-*.sh` | The ~69 BC scar rigs (`RESULT\|PASS\|bc-NN\|…` protocol), each citing a frozen INTERFACE §-clause. Add a rig here for a runner scar; it auto-enrolls. |
| `conformance/lib/harness.sh` | The shared BC harness: `H_init_test`, process-group containment + `_reap_runner_pg` (so a leaked `tail -f` can't self-saturate), the result protocol. |
| `conformance/lib/fake-bin/{bd,claude,curl,security,…}` | The frozen fakes the runner runs against (file-backed `bd` store, scripted `claude` plan via `$HARNESS_CLAUDE_PLAN`). |
| `cf/test/conformance-*.sh` | Tier `contract` (T7): the cross-cutting A–D guardian + `conformance-machine-state.sh` (D2). Fails when an op-wiring/projection/enum/tolerance seam drifts. |
| `jsdom/test/*.test.js` | Tier `jsdom` (T4): shell router / nav / deep-link resolution under jsdom (no real browser — deterministic by design; §8 forbids Playwright). |
| `verify-pages-deploy.sh` | **T8.** Deployed Pages bytes == committed bytes for every route. Pass prints `mismatches=0`. The R1/bgw close gate for any web task. |
| `cf/pages-dev/verify.sh` | **T8 (local serve).** Stands up the frozen engine + Board/Inbox proxies on workerd+miniflare and drives them end-to-end. Stops at locally-green; NO prod deploy. |
| `hooks/close-checklist.sh` | The close-time Stop+PreToolUse gate (see Gotchas). |
| `lib/test-assert.sh` | OPTIONAL shared assertion vocabulary (`ok/bad/ck/has/hasnt/eq/nz` + `summary`). New tests source it; **vocabulary only — never a shared store/fixture**. |
| `lib/sweep-fixtures.sh` | `sweep_fixtures` — deletes orphaned LIVE-bd test fixtures. Run by the gate up front and at the leaky test's own startup. |

## Contracts & invariants (don't break these)

- **`run-tests.sh` green is the regression gate; T8 is the separate acceptance
  gate.** Never fold a network probe into the offline gate, and never `bd close`
  production-touching work on offline-green alone (the bgw/2dk line: local green +
  committed is NOT acceptance).
- **No network below T8.** A T1–T7 test that hits a URL is a defect (§8). The one
  legitimate live test (`lib/test-co-http-transport.sh` PART A/C/D) is token-gated
  and SKIPs without a prod token — that SKIP is not a failure.
- **Tier discovery is by glob — do not hardcode a list** into the gate. Adding a
  test means adding a `test-*.sh` / `conformance-*.sh` / `*.spec.js` / `*.test.js`.
- **A fix in the R-anchor family lands with its assertion in the same commit**
  (§3 / §5 step 2). A regression fix without a test pinning it is not done.
- **The BC harness asserts FROZEN expected behavior** (sourced from
  `BEHAVIORAL-CONTRACT.md` + INTERFACE §-clauses). A red rig means the harness is
  wrong (fix it to match the contract) or the script regressed — **never** edit a
  rig to make it pass. Changing an expected behavior is a §11 escalation, not a test edit.
- **Per-test isolation stays:** own `mktemp -d` store, own fake `bd` on PATH,
  `trap rm` cleanup. The shared helper (`test-assert.sh`) is vocabulary only.
- **Deterministic clocks:** never assert on wall-clock; pass an explicit `now` into
  liveness/view-models. Pin contract numbers (90/180s liveness, the D.2 enum); test
  tunable numbers as "computed and surfaced," not a magic threshold.

## Common changes (recipes)

**Run the gate before every `bd close` on beads-runner work** (CLAUDE.md "Build & Test"):
```bash
bash beads-runner/run-tests.sh            # full gate (all offline tiers) — the authoritative run
bash beads-runner/run-tests.sh --changed  # only tiers touched by the git diff (fast pre-close)
bash beads-runner/run-tests.sh --tier lib,cf   # one or more tiers (repeatable / comma-list)
bash beads-runner/run-tests.sh --list     # the tier names + canonical run order
```
Tiers: `lib daemon hooks agents top conformance contract cf jsdom`. `--changed` is a
fast PRE-FILTER (it reports files it mapped to no tier); the no-arg full run is the
authoritative gate. Exit 0 = green; 1 = a tier failed; 2 = bad usage; 75 = another
gate already holds the singleton lock (busy — retry).

**Add a test:** drop a `test-*.sh` in `lib/ daemon/ hooks/ agents/` or top-level
`beads-runner/`; a `cf/test/*.spec.js` (the JS twin) or `conformance-*.sh` (a
contract rig); a `conformance/assertions/bc-*.sh` (a runner scar); or a
`jsdom/test/*.test.js`. It auto-enrolls — re-run `--tier <that-tier>` to confirm.

**T8 live-verify at close (the acceptance gate — required, manual):**
```bash
# web task: deploy the unified Pages project, then verify the bytes landed
(cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
bash beads-runner/verify-pages-deploy.sh          # all routes — must print mismatches=0
# engine task: a real authed probe against coordinator-cf.bbthechange.workers.dev
```
The deploy command + the full web close ladder live in `web-shell.md`. `mismatches=0`
against the live host — not local-green + committed — is acceptance.

## Gotchas / scars

- **`test-i3-stuck-dossier.sh` PART C can FAIL (not SKIP) on standalone runs** when
  the prod token is in the macOS Keychain but not exported as `COORDINATOR_TOKEN`.
  Signature: `CLIVE nr=1 bead=null` + `pass=49 fail=1`. It is a **pre-existing
  keychain-only-token harness artifact, not your regression** (bd memory
  `test-i3-partc-token-artifact`; owned by claude-tools-38y). Inside `run-tests.sh`
  this can't bite — the gate shims `security` to deny that one keychain item so the
  probe SKIPs cleanly — but a hand-run `bash lib/test-i3-stuck-dossier.sh` on Brian's
  machine will show it. Reproduce with `COORDINATOR_TOKEN` exported to confirm green.
- **Fixtures leak to LIVE bd on SIGKILL.** `test-bd-ready-ordering.sh` (top tier)
  seeds real beads into the live `bd` workspace to pin the real `bd ready` ordering;
  its cleanup trap does NOT fire on `kill -9` (the runner watchdog's weapon), so a
  killed run leaves orphans in `bd ready` (observed: 8 `ordering-fixture` beads). The
  gate runs `sweep_fixtures` up front on every form, and the test self-heals at its
  own startup, so a leak is bounded by "next gate run."
- **Singleton lock (exit 75).** All gate forms share one mkdir-based lock keyed by
  checkout, so concurrent gates can't pile up and contend for the Dolt server / bd
  lock (a 2026-05-30 4-way pile-up turned a few-min gate into ~16 min). 75 = busy,
  never confused with 1 (failed) or 2 (bad usage). A dead holder's lock is reclaimed.
- **The gate runs strictly offline by design.** It `unset`s `COORDINATOR_*` and shims
  `security`, so even on a machine that HAS a prod token the gate never reaches the
  network. On CI (no token, no `security`) the same code is a no-op. Don't "fix" a
  SKIP'd live section by feeding it a token inside the gate.
- **The gate must NEVER spawn `claude` (no claude-in-claude).** Both runners
  `export DG_AUTHOR_AUTOWIRE=1` at startup, and the gate runs inside a `claude -p`
  worker that inherits it. dossier-gen.sh's `dg__author` has an autowire chokepoint:
  `DG_AUTHOR_AUTOWIRE=1` + real `claude` on PATH + the executable
  `lib/dg-author-bridge.sh` ⇒ it wires the real bridge as `DG_AUTHOR_CMD` and fires a
  300s-timeout opus call **once per `dg_generate`** — which an orphaned run looped on,
  wedging the gate ~1h and holding the single global lock for the whole swarm
  (claude-tools-bmfj). The gate now `export DG_AUTHOR_AUTOWIRE=0` at the TOP (next to
  the `DG_AUDIT_LOG` isolation, before the lock/SELFTEST), forcing the deterministic
  jq author for every tier. EVERY chokepoint-reaching lib test also `unset`s the seam
  at startup so a standalone hand-run inside a worker session can't wedge either:
  `test-dossier-gen.sh`, `test-stuck-routing.sh`, `test-i3-stuck-dossier.sh` (the last
  two route via `sr_route_stuck`→`dg_from_worker_ask`→`dg_generate`→`dg__author`).
  `test-gate-offline-author.sh` (top tier) pins both halves — the gate's forced 0 AND
  the per-test unset across all three. The §9 autowire subtests stay green because they
  stub `CLAUDE_BIN`/`DG_AUTHOR_BRIDGE_PATH` inline. If you ever see
  `pgrep -fl dossier-builder.system.md` during the gate, this guard regressed.
- **BC-35 INT/HUP and the inherited-`SIG_IGN` harness scar (claude-tools-54ei, FIXED).**
  Symptom (was): `conformance` RED on BC-35 INT (v1+v2) and HUP (v2) — TERM PASSed, the
  runner only died to SIGKILL after the 20s grace (`harness.sh: line 18x … Killed: 9`).
  Root cause was NOT the runner: POSIX says **a signal that is `SIG_IGN` on entry to a
  shell cannot be trapped or reset from within bash**, so the runner's `trap cleanup INT`
  / `trap _on_signal … HUP` was a SILENT no-op. A worker-driven gate runs inside a
  *detached* runner (launch-detached.sh: `nohup … &` ⇒ HUP ignored; an async list ⇒
  INT/QUIT ignored), and that disposition is inherited all the way down to the
  runner-under-test — so bc-35 passed from a clean shell but failed inside the gate. The
  bug was masked for weeks (the claude-in-claude wedge kept the gate from running) and
  surfaced when bmfj un-wedged it. **Fix:** `conformance/lib/harness.sh:_spawn_runner`
  resets INT/HUP/QUIT to `SIG_DFL` via an external exec helper (perl→python3→plain-exec)
  before exec'ing the runner — modeling a real foreground/interactive Ctrl-C, the scenario
  BC-35 describes. `set -m` does NOT rescue an *inherited* ignore (only bash's own
  async-list setting). Regression-locked by top-tier `test-conformance-signal-disposition.sh`
  (reproduces the SIG_IGN gate context and asserts the reset holds — invisible to bc-35
  from a clean shell). No runner/contract change; the production runner's detached
  HUP/INT-ignore is intentional (it must outlive its launcher) and unaffected.
- **`conformance` and `cf`/`jsdom` count as ONE unit each.** They fan out internally;
  on failure the gate prints their full output. Bash `test-*.sh` files are one unit
  apiece (pass == exit 0).

## Go deeper

- `beads-runner/TESTING-STRATEGY.md` — the authoritative tier strategy (§2 table), the
  R-anchor scar list (§3), the §5 acceptance bar, §7.1 (this gate), §7.2 (the audit +
  shared vocab), §7.3 (the A–D guardian), §7.4 (jsdom), §8 (anti-flaky rules).
- `beads-runner/conformance/README.md` — the BC harness: how black-box driving works,
  the four result statuses (PASS/FAIL/GATE-PENDING/GATE-MET), the ANTI-DRIFT rule.
- `beads-runner/conformance/COVERAGE-AUDIT.md` — which v1 runner behaviours map to a
  `bc-*` rig and which are cutover blind spots (the v2c3 mandate).
- `CLAUDE.md` "Build & Test" — the one-line gate contract + the web-task close ladder.
- `run-tests.sh` header (lines 1–46) — the per-tier mapping, tally semantics, and exit codes.

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a new tier, a moved harness file, a new known-artifact fail, a
changed exit code, a new anti-flaky rule. **Keep it concise — this doc earns its
keep only if agents read all of it.** Delete lines that have gone stale; don't let
it grow into a second copy of TESTING-STRATEGY.md. Last substantive update: 2026-06-01.
