# v2 Gap Analysis — `runner.sh` (v2) vs `run-beads-tasks.sh` (v1)

> Spike output for **claude-tools-v2c0**. Sizes the port-forward (**v2c1**) and
> finish-seams (**v2c2**) children of epic **claude-tools-v2cut**
> ("Finish + cut over to the v2 runner, retire v1").
> Date: 2026-05-30. All line numbers / bead IDs below were read directly from the
> tree at this date (HEAD `8bc02ff`-era); re-verify before acting on a stale copy.

## TL;DR

The v2 rewrite is **not an unfinished skeleton**. Its rewrite epic
(`claude-tools-glk`) closed **DONE with conformance GREEN (PASS=99 / FAIL=0)**, and
**all four T2.x seams the file header still calls "unimplemented" are in fact
FILLED** (the header at lines 14–18 is stale; the in-body banner at line 847 even
says "RE-IMPLEMENTED"). The real gap is three things:

1. **Drift** — v2 never received the ~4 post-`962f0ed` v1 close-discipline / audit
   commits (td0y, apen, u4ms). This is a hard, enumerable gap. → **v2c1**
2. **Battle-fix coverage** — v1 accumulated a cohort of P1 reliability bug-fixes
   (h7n, 8mb, yva, dzc, hkwg …). v2 addresses the same *surfaces* structurally via
   different beads (9e7 watchdog, 7hx teardown), but whether each v1 fix's *specific
   failure mode* is covered is **unproven**, and several v1 features are simply
   **absent** in v2 (usage gate, per-model permission-mode, epic-exclusion, stream-
   gated heartbeat, post-terminal kill). → **v2c1** + audited by **v2c3**
3. **Open seams** — the only genuinely-stubbed code left in v2 is the six
   `co_*` / `la_*` distributed-tier jobs (`lib/*-stub.sh`); the T3 daemon/Local-Agent
   exists as a separate built component but the runner still calls **stubs**, not the
   real backends; the runner correctly defers self-relaunch to T3. → **v2c2**

Close-discipline (mechanisms B5/B6 below) is the **clearest genuine regression**:
v1's two-layer enforcement has *no counterpart* in v2.

---

## Ground facts

| Thing | Value |
|---|---|
| **v1** | `beads-runner/run-beads-tasks.sh` — the canonical imperative `while true` loop (~2397 lines) |
| **v2** | `beads-runner/runner.sh` — explicit state machine (~1692 lines), built by epic `glk` |
| `.beads/runner.sh` | **Not** the v2 runner — a per-workspace **config** file `source`d by runner.sh @156. The name collision is real and is `v2c5`'s cleanup. |
| **Fork baseline** | `962f0ed` = "qcoe: per-task permission-mode auto for Opus" (2026-05-26). v2's last sync with v1. |
| **glk** (closed) | The rewrite epic. Children that own the T2.x surfaces: `1p0` (T2.1 skeleton), `8nn` (T2.2), `9e7` (T2.3), `7hx` (T2.4), `kqn` (T2.5), `ntn` (SERVER_ERROR + backoff). **All CLOSED.** |
| **v2cut** (open) | The cutover epic. Children: `v2c0` (this), `v2c1` (port-forward), `v2c2` (finish seams), `v2c3` (conformance/differential GREEN gate), `v2c4` (staged cutover), `v2c5` (retire v1 + naming). |

---

## Part A — v1 commits v2 never received (`git log 962f0ed..HEAD -- run-beads-tasks.sh`)

Exactly **4 commits**, all the close-discipline / audit chain. **None are in v2.**
All landed on `run-beads-tasks.sh` + the new `hooks/close-checklist.sh`.

| sha | bead | What it added | Size |
|---|---|---|---|
| `ba1baa9` | **td0y** | **Enforce commit/wrapup BEFORE `bd close` + post-terminal watchdog.** New `hooks/close-checklist.sh` (PreToolUse(Bash) matches `bd close`/`--status=closed`; Stop catches "done without closing") running 5 checks (orphan bg procs, dirty tree, closed-without-commit, wrapup marker, debrief). Plus a post-terminal watchdog: stream parser stamps `POST_TERMINAL_FILE`, watchdog SIGKILLs `claude` `POST_TERMINAL_GRACE`(60s) later. | new ~200-line hook + runner edits |
| `95571a0` | **td0y** | Review fixes: (1) quoted close forms (`-s closed`, `--status='closed'`) now matched; (2) multi-id `bd close a b c` no longer bypasses checks for b/c; (3) bash-3.2 empty-array guard; (4) cleanup() removes `POST_TERMINAL_FILE`/hook-settings/current-task pointer on INT/TERM. | moderate |
| `41733bb` | **apen** | **Post-close discipline audit** (backstop for a worker that burns the Stop-hook cap then closes anyway): on every SUCCESS re-runs the checks; on failure files a **P1 regression bead** + `DISCIPLINE_BYPASS` incident + cross-ref note. Does **not** auto-reopen. | ~376 lines (incl. `test-post-close-audit.sh`) |
| `8bc02ff` | **u4ms** | Exclude `.beads/issues.jsonl` from the dirty_tree audit (`bd close` writes it as a side-effect; was causing ~50% false `DISCIPLINE_BYPASS:dirty_tree`). Adds the exclusion to both call sites + test cases. | ~84 lines |

**v1 anchors:** `post_close_audit()` @1094, dirty_tree exclusion @1130–1132, close-checklist
`--settings` injection @1664–1684, `POST_TERMINAL_FILE`/grace @106,1656–1662.
**v2 status:** `post_close_audit` = **0 occurrences**; no dirty-tree gate, no hook
injection, no post-terminal kill. The v2 worker prompt merely *asks* for a debrief
before close (`build_worker_prompt` @302) — **no enforcement, no audit.**

---

## Part B — T2.x seam status in v2 `runner.sh` + T3

The header (lines 14–18) is **stale** ("T2.2–T2.5 … MUST NOT be implemented in this
file"). Verified against the bodies: **all four are FILLED.**

| Seam (owner) | v2 status | Evidence (runner.sh) | v1 equivalent |
|---|---|---|---|
| **T2.2** classify / retry / breaker (`8nn`, +`ntn`) | **FILLED** | `classify_failure` @524 (frozen §7.1 precedence); `parse_stream_signals` @399 → typed markers incl. RATE_LIMIT/SERVER_ERROR @416–419,459; `_retry_backoff` @580 (bounded exp `base<<(n-1)` capped — **NEW vs v1**); per-task retry gate in `st_claim` @1183–1204; consecutive-failure breaker in `st_post_task` → `_terminal_fatal CIRCUIT_BREAKER 2` @1589–1593 | `classify_failure` @736 + loop-top counter + breaker exit 2 (no inter-retry backoff) |
| **T2.3** idle watchdog (`9e7`; header wrongly says `r3w`) | **FILLED** | `_watchdog_loop` @952: polls `WATCHDOG_POLL`=15s, liveness = **agent+child-process-tree** CPU/byte progress (not parent-stream silence), soft-warn @1008, at `IDLE_TIMEOUT` snapshots tree then staged `kill -INT`→≤10×1s→`kill -KILL` @998–1005, appends `WATCHDOG_KILL=1` @981; spawned trap-isolated @1324, in-band reaped @1370 | inline watchdog @~1863 keyed on `ACTIVITY_FILE` mtime (the surface h7n patched) |
| **T2.4** process-tree teardown (`7hx`) | **FILLED** | `_kill_tree` @726, `_reap_tree` @742 (staged TERM→grace→KILL), `_sweep_self` @766, `runner_teardown` @778 — single idempotent funnel via `trap runner_teardown EXIT` @822 + `trap _on_signal INT TERM HUP` @845; resets in-flight task to open @801–806. **Negative-PGID kill deliberately left to the T3 launcher** @761–765 | `cleanup()` @378 on `trap … INT TERM` only — **no EXIT trap**; v2 header @673 calls this out as the BC-36 hazard it fixes |
| **T2.5** worker prompt + AD-3.5 + STUCK (`kqn`) | **FILLED** | `build_worker_prompt` @281 (heredoc: non-interactive prohibition + §7.2(a) primary self-stuck: blocked→structured ask→`bd label add human`→`exit BEADS_STUCK_EXIT`); `WORKER_STUCK_EXIT=7` @125; `GUARDRAIL_FLAGS=(--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode)` @111; §7.2(b) backstop markers @475,489; `_drive_blocked_for_human` @340 | `GUARDRAIL_FLAGS` @49 + prompt + STUCK detection present |

**Only genuine open seams in v2:** the six distributed-tier jobs `job_claim_lease /
job_ask_capacity / job_heartbeat / job_reconcile_desired / job_publish_snapshot /
job_report_terminal` @253–260, wired against `lib/coordinator-stub.sh` /
`lib/local-agent-stub.sh` no-ops. Real backends = T3 (`lib/local-agent.sh`) + T5
(Coordinator).

### T3 daemon / relaunch — **exists, but runner↔daemon wiring is the open seam**

- The supervisor tier is **built**: `beads-runner/daemon/` has `daemon.sh` (19KB),
  `launchd-plist.template`, `install.sh`/`uninstall.sh`, `desired-state-poll.sh`,
  `usage-poll.sh`, `work-control-reconcile-poll.sh`, `intake-dispatch-poll.sh`,
  `hosted-resolution-poll.sh`, `m6-dispatch.sh`, `workspace-registry.sh` + tests.
- `runner.sh` **correctly does not self-relaunch** — `st_drained` @1631 idles &
  re-polls every `RECLAIM_POLL_INTERVAL`, or exits 0 with `RUNNER_EXIT_ON_DRAIN=1`;
  comments @22/66/1618 state "relaunch is T3's, not here."
- **Open:** the runner still calls the `*-stub.sh` no-ops, so the runner↔Local-Agent /
  Coordinator path (lease, capacity, heartbeat, reconcile, snapshot, terminal-report)
  is **not yet wired to the real daemon**. That swap is the substantive part of
  **v2c2** (and the deploy path of **v2c4**).

---

## Part C — ir7-era / named v1 reliability cohort: presence in v2

**Terminology trap (load-bearing):** "ir7" is overloaded.
`claude-tools-ir7` is a CLOSED epic about runner *self-modification / queue
starvation governance* (children R1–R6 = `av7 fyx vb7 tkf ah8 1yt`, all reports, no
code). There is **no `ir7` label** to query. The cohort the v2c0 task names by raw
id (`h7n, 8mb/yva, dzc, hkwg, 2y1`) is a **separate set of code-level P1 bugs**, not
children of that epic. v2c1/v2c3's phrase "any ir7 fixes v2 lacks" conflates the two
— pin it to the explicit id cohort below.

| bead | Bug (file fixed) | In v2? |
|---|---|---|
| **h7n** | Watchdog false-positive kill: unguarded `IDLE=$((NOW-LAST))` when `ACTIVITY_FILE` read is empty → "56-year idle" instant kill (**v1** @1528) | **Bug class structurally avoided** — v2's `_watchdog_loop` tracks `last_progress` as an in-loop variable + tree CPU/bytes, not a re-read file that can be empty. *Confirm v2 has no analogous empty-read path.* (v2c3) |
| **8mb** | `cleanup()`/`_final_subshell_reap` leaks TAIL+WATCHDOG grandchildren on the SIGTERM/EXIT path (**v1** @329–354,109–113) | **Surface covered** by 7hx's `trap … EXIT` teardown funnel. *Verify the specific orphan-on-early-exit case.* |
| **yva** | Runner leaks watchdog+tail subshells (~50%) → orphan to PID 1; fixed with `set -m` PG-isolation + EXIT-trap reap (**v1** @~1530–1572) | **Surface covered** by 7hx (different mechanism: idempotent reap funnel, not `set -m`). v2 has **no** `setsid`/`set -m` PG isolation — relies on the reap funnel + T3 launcher's negative-PGID kill. |
| **dzc** | `next_task()` runs `bd ready --json` with **no** `--exclude-type=epic` → starves on an epic-topped queue (**v1** @609; fix is jq epic-filter) | **GAP (probable).** v2 `bd ready --json` @1120 has **no epic exclusion** and no `validate_task`-style epic skip was found. v2 relies on `bd ready` status filtering only. → **port to v2c1.** |
| **hkwg** | `TASK_COST_CLASS` leaks across loop iterations (empty-guard never reset) → P0/P1 mis-gated as low_priority (**v1** @1263) | **N/A by architecture** — v2 has **no** inline cost-class / priority gating at all (grep for `cost_class|priority` = empty); capacity is delegated to the `job_ask_capacity → la_capacity_check` (T3) job. Bug can't recur, but note the **feature moved tiers** (was inline in v1). |
| **2y1** | `runner.sh` STUCK backstop fires its scan but doesn't drive the bead to blocked-for-human (**v2**!) | **Already fixed in v2** (`_drive_blocked_for_human` + `bd human` belt-and-suspenders). The lone v2-side bug of the set — and it sits on the `kqn`-produced §7.3 drive, i.e. a follow-up to a *filled* seam. |

**Net:** of the named cohort, **5 are v1-only** (h7n, 8mb, yva, dzc, hkwg) and 1 is
v2-only/already-fixed (2y1). v2 addresses the watchdog/leak surfaces structurally
(9e7/7hx) but **dzc (epic-exclusion) is a concrete missing port**, and h7n/8mb/yva
coverage is **unproven** (no differential assertion yet).

### Other v1 reliability mechanisms absent / weaker in v2

These are not in the named cohort but surfaced during the audit; each is a v2c1
candidate or a deliberate tier-move to confirm:

- **Usage/quota gate** — v1 `check_usage` @423 (`USAGE_THRESHOLD`/`USAGE_SLEEP`/cache) pauses new tasks over threshold. v2 has only the thin `job_ask_capacity` wrapper → T3 stub. (Confirm the daemon's `usage-poll.sh` covers it before deciding.)
- **Per-task permission-mode auto** — v1 picks `--permission-mode auto` for opus per-task (`qcoe`, @1383). v2 hardcodes `acceptEdits` @99. (This is literally the fork-baseline commit's feature — note the irony.)
- **Stream-gated mid-task heartbeat** — v1 emits heartbeat only if `ACTIVITY_FILE` fresh within 90s (`7v5` @1958). v2 heartbeats at state transitions only (coarser).
- **Post-terminal SIGKILL backstop** — v1 `krxv` orphan-child-wedge SIGKILL @1867. v2 relies on the idle watchdog + EXIT reap only.
- **Stale current-task-pointer clear** — v1 clears the td0y pointer at start/interrupt so a respawn doesn't enforce against a stale bead. v2 has no such pointer (it has no close hook to feed — falls out of B5).

---

## What's left — concrete sizing

### v2c1 — port-forward the v1-only fixes (keep v2's state-machine shape; add a conformance assertion per fix)

**Must port (hard gaps, enumerable):**
1. **Close-discipline enforcement (td0y)** — the largest item. Either (a) port the
   `hooks/close-checklist.sh` Stop/PreToolUse gate + `--settings` injection, or
   (b) reimplement the gate as a state in the v2 machine (preferred per v2c1 "don't
   reintroduce scattered flags"). Includes the multi-id / quoted-form / bash-3.2
   fixes from `95571a0`.
2. **Post-close discipline audit (apen)** — re-check on SUCCESS, file P1 regression
   bead + `DISCIPLINE_BYPASS` incident on bypass. Maps cleanly onto `st_post_task`.
3. **Dirty_tree `.beads/issues.jsonl` exclusion (u4ms)** — comes free with #1/#2.
4. **Post-terminal watchdog/SIGKILL (td0y / krxv)** — decide vs v2's idle watchdog;
   may be redundant, may not (idle≠post-terminal-wedge). Confirm, don't assume.
5. **Epic-exclusion in the ready query (dzc)** — add the `bd ready` epic filter
   (jq, since `--exclude-type=epic` was empirically a bd no-op) to `st_reconcile`/
   candidate selection.

**Confirm-then-port (tier-move or maybe-covered):**
6. Per-task permission-mode auto (qcoe) — restore per-model `auto` if v2's flat
   `acceptEdits` is a regression for opus tasks.
7. Usage gate (check_usage) — only if the daemon's `usage-poll.sh` does **not**
   already cover it via `job_ask_capacity`.
8. Stream-gated mid-task heartbeat (7v5) — if the coarser v2 heartbeat is
   insufficient for the GUI liveness signal.

### v2c2 — finish remaining v2 seams (open T2.x / T3)

The T2.x mechanism seams are **already filled** — v2c2 is **not** "build the state
machine." The real open seams:
1. **Wire the six distributed-tier jobs** — swap `lib/coordinator-stub.sh` /
   `lib/local-agent-stub.sh` for the real `lib/local-agent.sh` (T3) + Coordinator
   (T5) backends so lease/capacity/heartbeat/reconcile/snapshot/terminal-report hit
   the live daemon instead of no-ops.
2. **runner↔T3-daemon integration** — relaunch authority + desired-state delivery
   via `beads-runner/daemon/` (which already exists). The runner side is the gap.
3. Any residual `lib/*-stub.sh` no-ops surfaced by #1.
*(Per v2c2: an INTERFACE.md gap here is a §11 escalation, not a local divergence.)*

### Feeds v2c3 (cutover safety gate)

v2c3's strengthened bar (Brian, 2026-05-30): green harness is **necessary but not
sufficient** (glk already closed at PASS=99). Each v2c1 port needs a **new
differential/regression assertion** proving v2 *matches or exceeds* v1 for that
specific failure mode — especially the **unproven** coverage of h7n / 8mb / yva and
the **absent** close-discipline chain. This gap doc is the input checklist for that
coverage audit.

---

## Reconciliation with existing epic children (extend, don't duplicate)

- **glk children are DONE — do not redo them.** `8nn`/`9e7`/`7hx`/`kqn`/`ntn`
  already filled T2.2–T2.5 in v2. v2c1/v2c2 must *not* re-implement these; they
  port v1-only fixes and wire the distributed tier.
- **This doc sizes v2c1 and v2c2** (above); a one-line pointer note has been
  appended to each so the lists travel with the beads.
- **Corrections found (worth filing/fixing during v2c1/v2c2):**
  - runner.sh **header lines 14–18 are stale** — they claim T2.2–T2.5 are
    unimplemented seams. Update to "RE-IMPLEMENTED, see §…".
  - runner.sh **header names the T2.3 owner as `r3w`** — that id does not exist;
    the real owner is **`9e7`**. Doc-only typo, but in a load-bearing header.

## Open questions for v2c1/v2c3 (don't resolve here — spike)

1. Does v2's `_watchdog_loop` have *any* path that can synthesize a bogus idle like
   h7n did? (Believed no; prove it.)
2. Does the daemon's `usage-poll.sh` + `job_ask_capacity` fully subsume v1's inline
   `check_usage`, or is there a coverage hole during the cutover window?
3. Is flat `acceptEdits` (v2) vs per-model `auto` (v1) a real behavioral regression
   for opus tasks, given the fork baseline was exactly that feature?
