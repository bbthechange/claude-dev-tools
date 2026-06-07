# Context: The per-workspace runner (the task loop)

> One-liner: the per-project `while`-loop that pulls a `bd` task, spawns ONE
> fresh `claude -p` worker for it, then repeats. **"The runner" is the
> per-workspace loop — NEVER the per-machine daemon.** It does NOT branch; it
> sources the `lib/` layer and spawns the worker personas.

**Read this doc when** your task touches: the task-selection / orphan-recovery /
failure-classification / watchdog / spawn loop in `run-beads-tasks.sh` (v1) or
`runner.sh` (v2); the behavioral contract (`BEHAVIORAL-CONTRACT.md`, the BC-NN
clauses); how a runner is detached + supervised; or anything gated on the v2
cutover.

**Owns / scope (the files this doc covers):**
- `beads-runner/run-beads-tasks.sh` — **v1, LIVE in production** (~2626 lines,
  imperative `while true` loop). This is what runs today.
- `beads-runner/runner.sh` — **v2, the state-machine rewrite. PILOTING LIVE on
  rhythmGame** (~2556 lines; explicit `st_*` states) as of the staged cutover
  (claude-tools-v2c4); v1 is still the default on the other 4 workspaces. Cut
  over by the `v2cut` epic.
- `beads-runner/launch-detached.sh` — double-fork/`nohup` detach so a runner
  reparents to PID 1 and outlives its launcher (used by the daemon + manual launch).
- `beads-runner/BEHAVIORAL-CONTRACT.md` — the runner's frozen behavioral contract
  (BC-01…BC-65). The doc that says what must NOT change in a rewrite.
- `beads-runner/design/v2-gap.md` — the v1↔v2 gap analysis driving the cutover.

**Not here (go to the right doc):**
- The `lib/*.sh` the runner **sources** (`coordinator.sh`, `local-agent.sh`,
  `stuck.sh`, dossier/notification/`git-pin-main.sh`) → `lib-shared.md`. The
  runner CALLS these as guarded-optional seams; the libs themselves live there.
- The worker **persona prompts** + dispatch policy the runner spawns →
  `worker-agents.md`. The runner builds a prompt + runs `claude -p`; the persona
  content is the agents doc.
- The **daemon** that respawns/SIGTERMs runners + owns the workspace registry →
  `daemon.md`.
- How to **run** the conformance / regression suite (the harness, `run-tests.sh`,
  tiers) → `testing.md`. The contract is NAMED here; the harness lives there.
- The hosted engine the runner's `co_*`/`la_*` seams talk to → `engine-cloudflare.md`.

---

## Mental model

A runner is a single-workspace `while` loop. Each iteration: pin HEAD to main →
check usage/capacity → reconcile desired-state + answered dossiers → select the
first **workable** `bd ready` bead → claim it (lease + `in_progress`) → spawn
**one brand-new `claude -p` worker** for exactly that bead → classify the result
→ repeat. The whole reason it exists: **fresh process + fresh context per task**
(BC-01) to defeat autocompact drift — there is never a `--continue`/`--resume`,
and a retried task starts from an empty window.

**The runner does NOT create branches.** It (and the worker) auto-commit per bead
onto **whatever branch HEAD currently points at**. If a worker does `git checkout
-b` and never returns the tree to `main`, every subsequent bead piles onto that
feature branch until a human notices — the **trunkpin scar**. The fix lives in the
loop, not in worker discipline: `pin_head_to_main` runs at the loop top (sourced
from `lib/git-pin-main.sh`; a no-op when absent or the tree is dirty).

**v1 vs v2 is a split inside the per-workspace runner only** (the daemon has no
such fork). v1 (`run-beads-tasks.sh`) is the production default (4 of 5
workspaces). v2 (`runner.sh`) is a rewrite-complete, conformance-green state
machine now **PILOTING LIVE on rhythmGame** via the staged cutover
(claude-tools-v2c4): a per-workspace, machine-local, **gitignored** marker
`<ws>/.beads/runner-logs/use-runner-v2` flips the daemon's M3 spawn to v2 with
`RUNNER_BACKEND=real` (mandatory — the stub backend's capacity gate is a no-op);
instant rollback = remove the marker, next respawn is v1. The `v2cut` epic
policy: build new **runner-touching** features on the clean v2 machine *while it
is offline* (gated behind `v2c3`), then this controlled staged cutover — do NOT
patch live v1. See HANDOFF-UX-V2 §2.

## Key files

| File | Role |
|---|---|
| `run-beads-tasks.sh` | **v1, LIVE.** `while true` loop @1438; per-task `claude -p` spawn @1916–1927; `select_workable_task`/`validate_task`/`next_task` selection; `classify_failure`; `post_close_audit` @1266; watchdog/cleanup. The production source of truth. |
| `runner.sh` | **v2, OFFLINE.** Same behavior as an explicit state machine: `st_starting → st_reconcile → st_claim → st_run_task → st_post_task` (+ `st_drained/stopping/terminal`). `transition()` @1445; `claude -p` spawn @2123. The cutover target. |
| `launch-detached.sh` | The long-lived START: `( nohup CMD >LOG 2>&1 </dev/null & )` reparents the runner to PID 1, severs tty/SIGHUP. Per-workspace pidfile `.beads/runner-logs/detached-runner.pid` refuses a duplicate runner. Exit 3 = a live runner already owns the workspace. |
| `BEHAVIORAL-CONTRACT.md` | BC-01…BC-65. Each clause = assertion + repro + source line + **SCAR vs SCAFFOLDING** class (a SCAR must survive a rewrite; SCAFFOLDING is a bash artifact that must NOT be transcribed faithfully). §21 is the "do not port" inventory. |
| `design/v2-gap.md` | What v1 has that v2 lacks: 4 un-ported close-discipline commits (td0y/apen/u4ms), an unproven battle-fix cohort, and the 6 stubbed `co_*`/`la_*` distributed-tier seams. Sizes `v2c1`/`v2c2`. |
| `hooks/close-checklist.sh` | Runner-injected `--settings` hook (PreToolUse(Bash) on `bd close`, Stop) enforcing commit/wrapup BEFORE close. v1 only; the clearest v2 regression. See `hooks` test tier in `testing.md`. |

## Contracts & invariants (don't break these)

- **BC-01 — fresh process + fresh context per task.** Every bead = a new
  `claude -p` invocation, no `--continue`/`--resume`. The lone exception is the I4
  resume splice (BC-55): one human answer prepended, not a prior conversation.
- **The runner never branches; per-bead commits land on HEAD's branch.** Keep
  `pin_head_to_main` at the loop top. Switching the runner to another branch is an
  operational dance (stop → desired=stopped → checkout in a worktree → respawn),
  never a worker free-for-all. (trunkpin scar.)
- **Exit 0 ≠ success — truth is `bd` status** (BC-09). The runner classifies the
  result from `bd show`, not the process exit code.
- **Exact, distinct process exit codes** (BC-21): 0 drain/graceful-stop, 1
  INT/TERM, 2 circuit-breaker, 3 AUTH_FAILURE, 4 BILLING_ERROR. A supervisor
  switches on these — do not renumber. (`WORKER_STUCK_EXIT=7` is the *worker's*
  sentinel, never a *runner* exit code.)
- **Optional lib seams degrade to a working standalone runner** (BC-43): an absent
  `co_*`/`la_*`/`sr_*`/dossier/pin lib ⇒ a visible typed degrade + continue, NEVER
  an abort. New seams MUST follow this guarded-optional posture.
- **Lease binds to beads-status** (BC-48): acquire the global exclusive lease
  BEFORE the `in_progress` write; release ⇒ bead back to `open`. This is what stops
  two runners fighting over one orphan.
- **AD2.2 bounded-local-fallback is wired** (claude-tools-ylu2, v2 only): on a
  FAILED acquire, `st_claim` continues a task ONLY if the Coordinator is GENUINELY
  unreachable (the `CO_HTTP_UNREACHABLE` transport sidecar) AND
  `la_lease_fallback_allows` confirms a still-valid locally-held lease
  (`job_lease_note_held` on grant; `job_lease_release_local` at every release
  site; a SIGKILL keeps the cache as the orphan-resume signal). A reachable deny
  fails CLOSED — no new unsynchronised claim, no BC-04 regression. **The cache now
  stores a §4.4 ENVELOPE, not a bare epoch (claude-tools-h9dl, P2):** the fallback
  path re-seeds `LEASE_GENERATION` from `job_lease_recover_generation` so a
  restart/blip no longer sends an EMPTY fence token (ylu2 follow-up #1 — an empty
  gen makes the next heartbeat's renew a no-op, lapsing the lease once the
  Coordinator recovers). `la_lease_fallback_allows` validates vs the STORED expiry,
  and the renew tick refreshes `note_held` ONLY on a GRANTED renew (`LA_LEASE_RENEW_RC
  == 0`, a sidecar `la_heartbeat` sets) so neither an outage NOR a reachable-but-DENIED
  renew (mid-outage takeover) can extend the local hold past the engine lease. Offline
  self-verify still cannot DETECT a takeover — the reachable path must re-validate.
  Lib detail: `lib-shared.md`.
- **`LOG_DIR` is a self-gitignoring SECURITY boundary** (BC-27): raw model
  output / stream files must never reach git. The dirty-tree close audit excludes
  `.beads/issues.jsonl` (bd writes it as a side-effect — BC-56/u4ms). All per-task
  artifacts in `st_run_task` (STREAM/SIGNAL/PROC, POST_TERMINAL/HOOK_SETTINGS)
  derive their dir from `"${LOG_DIR:-.beads/runner-logs}"`, NOT a second hardcoded
  literal, so they stay symmetric with the `$LOG_DIR/current-task` pointer + teardown
  `rm` under a non-default `LOG_DIR` (claude-tools-62xc). **The exception is a
  daemon↔runner RENDEZVOUS dir/file, which must NOT follow `LOG_DIR`:** the
  agent-action control-marker dir (`st_run_task`'s `agent_action_dir`) is PINNED to
  the frozen `.beads/runner-logs/agent-action`, and the `detached-runner.pid`
  liveness file is pinned by `launch-detached.sh`. The daemon supervises many
  workspaces and cannot know a per-workspace `LOG_DIR` override, so cross-process
  IPC stays at the workspace-stable default (design/agent-action.md §4 freezes the
  marker dir; claude-tools-wqx7) — `LOG_DIR` reparents only the runner's OWN raw
  artifacts. A `$log_dir` derive on a rendezvous path silently breaks the seam under
  a non-default `LOG_DIR` (daemon drops in the default dir, watchdog scans the
  override dir).
- **SCAR vs SCAFFOLDING when porting to v2.** Before "faithfully porting" any v1
  mechanism, read its BC class: a SCAFFOLDING entry (e.g. the `read -ra` empty-array
  quirk BC-03, the `--exclude-type=epic` belt-and-suspenders BC-52) is a bash
  artifact to re-derive, not transcribe.

## Common changes (recipes)

**Add a runner-touching feature (the v2cut rule):** if the feature changes the
loop/selection/spawn/classification, build it on **v2 (`runner.sh`)** behind the
`v2c3` gate — NOT on live v1. (The two ux-v2 runner beads `uxvj4` and `uxvi1` are
gated this way.) If it is a hot production fix, it lands on v1 **and** must be
back-filled into v2 or it becomes another `v2-gap.md` drift entry.

**Add/port a behavior:** (1) write or update the **BC-NN** clause in
`BEHAVIORAL-CONTRACT.md` (assertion + repro + source line + class); (2) implement;
(3) add a conformance assertion under `beads-runner/conformance/` so the
regression-locks the fix; (4) run the gate. The local test gate before any close:
```bash
bash beads-runner/run-tests.sh --changed   # only tiers your diff touched (fast)
bash beads-runner/run-tests.sh             # full offline regression gate
```
The runner tiers are `conformance` (the BC harness) and `contract`; lib changes
hit `lib`. See `testing.md` for the tier map. A green offline run is the
regression gate — it is NOT a substitute for the live-verify step on web/engine work.

**Start / restart a runner manually:**
```bash
beads-runner/launch-detached.sh <workspace-dir>   # detaches, prints the pid
```
Normally you don't: the daemon respawns a runner whenever `desired=running` and no
runner is alive. You control the **branch** it comes back on, not the start.
Runbooks: `runner-status-check.md`, `cleanup-orphan-runners.md`, `reset-stuck-bead.md`.

**Flip a workspace to v2 (or roll back to v1) — the staged cutover
(claude-tools-v2c4):**
```bash
touch <ws>/.beads/runner-logs/use-runner-v2          # arm v2 (gitignored, machine-local)
kill -TERM "$(cat <ws>/.beads/runner-logs/detached-runner.pid)"   # trigger respawn
# daemon M3 (≤60s) respawns as v2 with RUNNER_BACKEND=real; the spawn log line reads
#   "launching v2 (runner.sh, RUNNER_BACKEND=real) [use-runner-v2 marker]"
rm <ws>/.beads/runner-logs/use-runner-v2             # instant rollback: next respawn is v1
```
The marker is per-workspace + machine-local (never committed), so each machine
opts in independently. A missing `runner.sh` fails safe to v1 (BC-43). Watch the
new runner's `detached-*.log` for the `state: STARTING -> …` v2 banner and the
absence of any `BACKEND_STUB_ON_HOSTED` notice (which would mean the safety pin
was lost).

## Gotchas / scars

- **Editing the running script is SAFE.** Bash slurps the whole script at start, so
  an in-place edit to `run-beads-tasks.sh` does not affect the live process — it
  takes effect on the **next respawn**. (This is also the ir7 self-modification
  discipline: a runner editing its own running script is fine; just know the change
  is deferred.)
- **The `bd ready` poll is TTL-cached, and the two runners cache DIFFERENTLY
  (claude-tools-4a2e).** A short window (`READY_CACHE_SECONDS`) memoizes the ready
  ARRAY so a spinning runner (lease-deny 3s / gate-human / skip backoffs) stops
  re-taking the dolt lock every pass. **v1 MUST use a FILE cache, not a global:**
  `next_task()` is always called as `TASK_JSON=$(next_task)` — a command-sub
  SUBSHELL — so any global it writes is discarded with the subshell (this is also
  why v1's in-`next_task` `ORPHANED_IDS` narrowing is effectively per-call). The
  file lives at `$LOG_DIR/.ready-cache.json` (`<epoch>\n<json>`). **That file
  SURVIVES the process, so v1 ALSO busts it ONCE at startup (claude-tools-iu53,
  right after the `BEADS_RUNNER_TEST_MODE` source-guard, before the main loop)** —
  a fresh process must not trust a prior process's last poll. Without that startup
  bust a respawn (or any 2nd invocation in the same workspace) within
  `READY_CACHE_SECONDS` serves a STALE cross-process ready set and hides work filed
  in the gap; it surfaced as BC-24 cross-run-append RED — a 2nd `run_runner` read
  the 1st's final empty `[]` poll and never picked up the newly-seeded bead.
  **v2 uses an in-memory global** (`READY_CACHE_JSON/TIME`) because
  `st_reconcile`/`st_claim` are dispatched DIRECTLY (no subshell), so globals
  persist — and it is cold at process start by construction, so v2 needs NO startup
  bust; that asymmetry is why `bc-24-incidents-log-tree.sh` (v2) stayed GREEN while
  the v1 rig went RED. BOTH bust the cache at
  commit-to-run (`ready_cache_bust` where `CURRENT_TASK_ID` is set) so a bead this
  runner just closed is never re-presented stale → re-claimed → reopened (bd ready
  itself never returns a closed bead; only a warm cache could). **The BC-06 `bd
  blocked` re-check (validate_task / `_validate_workable`) is LEFT UNCACHED** — it
  is a freshness guard for a dep added after the snapshot; caching it would claim a
  late-blocked bead. Locks: `lib/test-ready-cache.sh` (v1 behavioral + both
  structural) + `conformance/assertions/bc-06-blocked-recheck-tree.sh` (v2 e2e).
- **Queue starvation by a no-claim bead at `ready[0]`** (uxqj, fixed): a single
  `human-action`/`human-triage` TASK at the top of `bd ready` once starved every
  workable bead below it for ~25 min. Epics are query-filtered (BC-52) but tasks
  are not — `select_workable_task` (BC-51) now skips past an unworkable head
  instead of starving. **Keep human-action beads `bd update --defer`'d out of the
  ready set**, not just labeled.
- **Workers wander off `main`** — the trunkpin scar above. To switch branches
  safely: `.stop-beads` (graceful) → wait for runner down → `desired=stopped`
  (freeze respawn) → checkout/merge in worktree-discipline → `rm .stop-beads` →
  `desired=running`.
- **Do git surgery in an isolated worktree while a worker is live** — `git
  worktree add /tmp/ct-x <branch>`; never `checkout` the live tree under a running
  worker (you'll smuggle its diff into the next bead's commit).
- **`pgrep` counts look inflated** (your own subshells + the runner-accumulation
  loose thread). Use the per-workspace pidfile, not raw `pgrep`, for "is MY
  workspace's runner alive."
- **v2's file header lies.** `runner.sh` lines 14–18 still call the T2.x seams
  "unimplemented" — they are FILLED (the in-body banner @847 says "RE-IMPLEMENTED").
  Trust `v2-gap.md`, not the stale header.
- **v2's observability + per-task model selection now match v1** (claude-tools-v2cut.4):
  `scan_tool_errors` (BC-25), `notify_user` + selective silence (BC-26), startup
  `LOG_RETENTION_DAYS` rotation in `st_starting` (BC-30), the preflight snapshot
  (BC-31), per-task `model:` label selection via `_resolve_task_model` (BC-32 — the
  spawn now uses `--model "$TASK_MODEL"`, not the single per-runner `DEFAULT_MODEL`),
  and the `rate_limit_event` subscription-window parse (BC-61) are all ported with
  `-tree` assertions. BC-33's chunked-usage-sleep is **moot** in v2 (the capacity
  gate is a short `RECLAIM_POLL_INTERVAL` backoff + `STOP_FILE` polled every
  reconcile). Don't re-file these as gaps — see `conformance/COVERAGE-AUDIT.md`.
- **v2 STUCK now AUTHORS a real dossier (claude-tools-69u8).** `_drive_blocked_for_human`
  used to write a body-less `co_store_put` stub ({schema_version,trigger,bead_ref,
  task_ref,principal}) and never call `dg__author` — so a v2 STUCK fork shipped
  neither an agent body nor a jq-fallback body. It now authors through
  `dg_from_worker_ask` in a sourced subshell (runner.sh doesn't source the dossier
  stack), keyed on `stuck-<task_ref>` (§7.4 dedup), with the keyed stub kept only as
  a graceful fallback if the libs can't be sourced. Both runners
  `export DG_AUTHOR_AUTOWIRE=1` at startup so the author picks the real builder when
  claude is reachable (kill-switch `=0`). The dispatch loop now has a source-guard
  (`[[ ${BASH_SOURCE[0]} == ${0} ]]`) so focused tests can source the script without
  entering the state machine — exec-transparent, so conformance is unaffected.
- **Two `runner.sh` names.** The v2 *script* `beads-runner/runner.sh` vs the
  per-workspace *config* `<ws>/.beads/runner.sh` (sourced by both runners) — same
  filename, different role. The collision cleanup is `v2c5`.
- **v2 emits `agent_activity` from the during-task loop (I1, claude-tools-uxvi1).**
  `st_run_task`'s `while kill -0 $CLAUDE_PID` loop calls `activity_report_tick`
  (`lib/activity-report.sh`) every `ACTIVITY_REPORT_INTERVAL` — the sibling ticker
  beside the heartbeat/control beats. It classifies the worker's `STREAM_FILE`
  (D.2 enum + liveness) and **throttled, backgrounded** POSTs `agent-activity-report`.
  Because v2 has **no `tail -f` parser**, this poll IS the activity seam (not a
  second tail). Guarded-optional (BC-43): absent lib / offline transport ⇒ no-op,
  never blocks or crashes the loop.
- **v2 now DRAINS the §1.1 outbox — heartbeats are SHIPPED, not just queued
  (BC-45, claude-tools-zyxz).** v2 generated/queued heartbeats correctly
  (`job_heartbeat`→`la_heartbeat`→`la_report_heartbeat` appends to
  `coordinator-outbox.jsonl`) but for the whole pre-cutover life **never called
  `la_outbox_drain`**, so the hosted engine froze at the *prior* runner's
  heartbeat the instant a workspace ran on v2 (stale Board liveness, frozen
  `current_task_ref`, spurious-'runner stuck' risk). Fixed with one guarded
  `_drain_outbox` seam (`declare -F la_outbox_drain` + non-empty `COORDINATOR_URL`
  + `|| true`) called at **three** v1-cadence sites: `st_reconcile` (once per
  loop, between-task), the **during-task heartbeat branch** (once per
  `HEARTBEAT_INTERVAL` — load-bearing: `st_reconcile` is NOT re-entered during a
  task, so a reconcile-only drain still freezes a `>STALE_AFTER` task), and
  `st_terminal` (final stopped state, mirrors v1 run-beads-tasks.sh:2693).
  Regression-locked by **section D** of `conformance/assertions/bc-45-heartbeat-honesty-tree.sh`
  (the original rig asserted only the *emit* half — the drift's blind spot).
- **§9 audit-coverage marker is refreshed at each inventory publish (v1 only,
  claude-tools-mhcp.3).** `run-beads-tasks.sh` calls `runner_refresh_audit_coverage`
  — a guarded subprocess run of `defer-cascade-audit.sh audit` — immediately BEFORE
  each `la_publish_workspace_inventory` (task pickup + completion). The audit
  overwrite-or-removes the CWD-relative `.beads/runner-logs/audit-coverage.json`
  marker the publisher reads, so the §9 row-4 Queue-Health chip (read/total over
  open future-defer epics) reflects the same queue state the inventory carries.
  Writer + reader in one process / one CWD on purpose ⇒ they can't drift on the
  marker path (the silent-no-chip trap t5ud/mhcp.2 guarded). Best-effort (BC-43):
  the subprocess isolates the audit's exit code (1=cascade, 3=bd hiccup) off the
  loop; `RUNNER_AUDIT_COVERAGE_DISABLED=1` opts out. **v2 (`runner.sh`) publishes no
  workspace_inventory** (a stubbed `la_*` seam in `v2-gap.md`), so there is nothing
  to hook there yet — un-stubbing the v2 inventory publish must port this refresh
  alongside it.
- **v2 watchdog honors agent-action control markers (I4, claude-tools-uxvi4).**
  `_watchdog_loop` (the always-alive subshell that OWNS `CLAUDE_PID` + the staged
  kill) calls `_watchdog_scan_agent_action` each `WATCHDOG_POLL` tick, reading
  `<ws>/.beads/runner-logs/agent-action/<action_id>.json` markers the daemon
  (`agent-action-poll.sh`) drops: **nudge** resets the idle-grace one window (veto,
  no kill); **kill-retry/kill-gate** run the staged SIGINT→SIGKILL and emit
  `WATCHDOG_KILL=1` (reusing the FROZEN §8.1 class — kill-retry re-dispatches the
  reset-to-open bead; kill-gate's daemon-applied `gate:*` label then makes J4 refuse
  re-pickup). The scan's helper echoes go to **stderr** — its stdout is the captured
  action verb. A marker for a different bead is consumed but ignored (stale/late).
- **STUCK_NEEDS_HUMAN auto-flip is recency-gated (I4, must-protect #12).**
  `run-beads-tasks.sh` `detect_worker_stuck_primary` no longer matches
  `STUCK_NEEDS_HUMAN` *anywhere* in notes — the relaxed case-3 fires only on a
  RECENT `STUCK_NEEDS_HUMAN@<epoch>` (within `STUCK_NOTE_RECENT_WINDOW`=1800s) or a
  bare note that is NOT the runner's own `Runner: STUCK_NEEDS_HUMAN at …` audit line
  (`(?<!Runner: )` lookbehind). Closes the HANDOFF "Fix-B over-trigger" (a once-stuck
  bead re-looping forever). **x949 closed the PRODUCER side:** the §7.2 worker-prompt
  fallback (`build_worker_prompt`) now tells the agent to append
  `STUCK_NEEDS_HUMAN@$(date +%s)` (was a BARE note that `has_bare` matched FOREVER),
  so the dominant agent-fallback vector also ages out of the window; the predicate's
  bare-note path stays only for BC-53 back-compat. v2 has no such predicate — its
  STUCK path is `$sig`-file based, already window-bounded by construction.
- **A surfaced human-decision bead must be UN-THRASHABLE (claude-tools-1vnx, both
  runners).** A compliant worker that hits a human fork sets `status=blocked` + a
  `human` label + a structured ask, then ENDS ITS TURN — so `claude -p` exits 0
  (NOT the `WORKER_STUCK_EXIT=7` sentinel, no stuck stream marker). Both runners
  used to fold that to `TASK_NOT_CLOSED`, reset `--status=open`, and (on retry)
  spawn an analysis child whose close re-armed the bead → **thrash** (re-pick →
  re-block → re-misclassify, burning an Opus analysis task per cycle; casualty
  claude-tools-m3xi, re-surfaced 3×). v1's §7.3 preempt SHOULD have caught it via
  `detect_worker_stuck_primary` Case 2 (blocked+human) but its **one-shot
  `bd show` read** was fragile (a transient hiccup / a status flipped away from
  blocked at check time ⇒ miss). Fix: (1) v1 retries that read; (2) v1 adds a
  dispatch-site belt `_bead_blocked_for_human` (ungated by `ASK_BRIAN_ENABLED`,
  retried label+status read, fail-SAFE on an unreadable status) that pins a
  blocked+human-at-exit bead — STUCK_NEEDS_HUMAN recorded, breaker/retry-exempt,
  NO reset, NO analysis; (3) v2 (`runner.sh`) had the IDENTICAL hole — its
  `classify_failure` now reads the sticky `human` label and classifies exit-0
  blocked+human as `STUCK_NEEDS_HUMAN`, reusing the existing exempt STUCK dispatch
  (`_drive_blocked_for_human`). The `human` LABEL is the load-bearing signal
  (sticky/durable, same reasoning as `RUNNER_NO_CLAIM_LABELS`); a reliably
  non-blocked bare `human` label still falls through (the test-stuck-primary-relaxed
  negative posture). Regression-locked by the `bc13-1vnx-…`/`bc13tree-1vnx-…`
  rigs in `bc-13-14-retry-asymmetry{,-tree}.sh` (the new harness verb is the
  `stuck_primary_exit0` claude plan + a real `bd label add` in the fake bd).
- **…and the AGED-OUT not-blocked residual it left (claude-tools-309l, both
  runners).** 1vnx's belt (and v2's `classify_failure`) keyed on `status==blocked`
  + `human`. But the §7.3 Case-3 RELAXED preempt catches a `human`+NOT-blocked slip
  (worker set label+ask note but missed the status flip — the m3xi vector) ONLY
  while the `STUCK_NEEDS_HUMAN` note is RECENT (uxvi4 window, 1800s); once it ages
  out, a still-stuck bead fell back to `TASK_NOT_CLOSED` → reset+analysis. Fix: the
  recognition is now RECENCY-INDEPENDENT, keyed on the **`human` LABEL** (a resolved
  fork has it REMOVED by the answer consequence, so its persistence = still-stuck —
  the label, not the clock, is the freshness signal) **+** the worker's OWN non-audit
  note (the `(?<!Runner: )` lookbehind drops the runner's own residue — the uxvi4
  over-trigger vector). v1: `_bead_blocked_for_human` also fires on `human` +
  `open`/`in_progress` (never `closed` = SUCCESS) + a non-audit note, flips it blocked,
  and — opted-IN only — authors the §7.4-deduped dossier (option **c**: a belt-caught
  fork was otherwise invisible in the Inbox). v2 had **no Case-3 analogue at all** —
  `classify_failure` now recognizes it (helper `_bead_has_stuck_ask_note`) and routes
  through `_drive_blocked_for_human` (flips blocked + authors the 69u8 dossier).
  Does NOT reopen uxvi4 (the over-trigger was the preempt RE-ROUTING on a *resolved*
  bead; this fires only while the label persists, idempotently). Rejected option **a**
  (recency-refresh on every re-pickup — it fights uxvi4). Locked by `bc13-309l-…`/
  `bc13tree-309l-…` (plan `stuck_slipped_aged`) + `lib/test-belt-aged-human.sh`
  (pins the over-trigger boundary: runner-audit-only ⇒ no fire, `closed` ⇒ never pinned).
- **…and that 309l backstop was keyed on a token the escalation protocol never emits
  (claude-tools-gqyp, FIXED, P1).** `_bead_has_stuck_ask_note` (and v1's
  `_bead_blocked_for_human`) greped the notes for the LITERAL string `STUCK_NEEDS_HUMAN`,
  but the human-fork escalation PROTOCOL tells the worker to write a **"HUMAN DECISION
  NEEDED"** structured ask (TL;DR / the ask / options / recommendation / reversibility) —
  NOT that token. Verified on casualty claude-tools-o0yq: its notes carried a full,
  well-formed ask but **0** occurrences of `STUCK_NEEDS_HUMAN` at classify time, so Net 2
  returned false and was effectively DEAD for every canonical human fork — leaving the whole
  net resting on Net 1's single `status==blocked`+`human` `bd show` read, which folds to
  `TASK_NOT_CLOSED` → reset → analysis-child (the 1vnx thrash, residual) whenever that one
  read loses the propagation race / the worker slipped the flip. **The fix (three parts):**
  (1) CONSUMER — both detectors now match `(?<!Runner: )(STUCK_NEEDS_HUMAN|HUMAN DECISION
  NEEDED)`, recognising the protocol's actual ask header AND the legacy token under the same
  Runner-residue guard (recency-independent; the `human` LABEL is still the freshness gate,
  so uxvi4 over-trigger stays closed); (2) PRODUCER — v2 `build_worker_prompt` now mandates
  the worker HEAD its `--append-notes` ask with the verbatim canonical marker `HUMAN DECISION
  NEEDED`, making the contract guaranteed rather than incidental (locked by
  `bc-38-worker-prompt-tree.sh`); (3) Net 1's status read in `classify_failure` now RETRIES a
  degraded read once (mirrors v1's retried reads). Regression-lock: `lib/test-309l-v2-classify.sh`
  + `lib/test-belt-aged-human.sh` (both pin the marker cases + the partial-phrase / no-label
  negatives). The v1 `--append-notes` fallback (run-beads-tasks.sh:2050) still emits
  `STUCK_NEEDS_HUMAN@<epoch>` (load-bearing for the §7.3 recency auto-flip) — both forms are
  now detected.
- **A verified-CLOSED bead zombied back to a false human-fork — the S-2 reconcile
  re-asserted a stale fork record (claude-tools-2z14, FIXED).** The stuck NET above
  is the CLASSIFY side (recognising a worker's fork); this is the RECONCILE side.
  `lib/stuck-routing.sh sr_reconcile_blocked_for_human` re-asserts `status=blocked`
  + `human` from its CONTROL-plane `blocked-for-human` record (`$CO_STORE/blocked-for-
  human/<ref>.json`) "unconditionally, driven by the record, NEVER the bead status"
  — by design, to defeat Dolt lag (the Board never lies, S-2). But the record is
  raised `{resolved:false}` at fork time and is only resolved when the human ANSWERS
  the dossier. When Brian instead **closes the bead out of band** (closes it directly,
  never answers the dossier), the record stays `resolved:false`, so every reconcile
  (~30s, runner `run-beads-tasks.sh:1750` + daemon `hosted-resolution-poll.sh:207`)
  RESURRECTS the closed bead to blocked+human → a false "Brian must decide" in the
  Inbox (uxg1 zombied +18s/+29s after two manual closes; forensics: the closed→blocked
  re-flips carry NO `--reason` and actor=git-user fallback — the bash `bd update`
  signature, NOT a human edit). **uxvl2 (L2 work→control auto-close) shipped the
  ENGINE/dossier half but chose "no bash twin", leaving this local S-2 record without
  the symmetric guard.** Fix: `sr_reconcile_blocked_for_human` now reads the bead
  status FIRST and, on a definite `closed`, hard-deletes the record (the §7.9 work→
  control auto-close, bash twin) instead of re-asserting — guarding BOTH the
  resolved:false re-block AND the resolved:true reopen. Safe vs the anti-lag rationale:
  lag shows a STALE OLD status, never a spurious `closed`; an unreadable status fails
  SAFE to the existing re-assert (the fork must not rot). `sr_drive_bead_blocked` (the
  single work-plane chokepoint) also categorically refuses a closed bead now. **A
  stale record is only RE-ASSERTED, never recreated** (creation needs a fresh fork,
  which a closed bead can't trigger), so deleting the record durably kills a live
  zombie even against old-code runners that have the lib slurped in memory. Lock:
  `lib/test-stuck-routing.sh` (the claude-tools-2z14 section + the preserved
  open-clobber re-assert). The fix is in a SOURCED lib ⇒ live runners get it on the
  next respawn; clean a live zombie by deleting its `<ref>.json` + re-closing.
  **DEFENSE-IN-DEPTH follow-up (claude-tools-d752):** the §7.9 close-branch also now
  FOLDS the bead's work-plane ask — `sr__fold_ask_on_close` appends ONE idempotent
  `FORK-FOLDED-ON-CLOSE …` marker note BEFORE the record delete, so a LEGITIMATE
  later reopen + a fresh worker re-reading the stale body (e.g. uxg1's "needs Brian
  to deploy") can't re-derive the same fork. This guards the OTHER vector (worker
  re-read), NOT the 2z14 one (pure control-plane re-assert, no worker). Best-effort
  (BC-43) + bash-only (the CF reconcile has no live-`bd`/notes plane, so no
  differential twin). The marker text carries NEITHER classify token
  (`STUCK_NEEDS_HUMAN`/`HUMAN DECISION NEEDED`) so the 309l/gqyp net never reads the
  fold itself as a fresh ask. Lock: the `claude-tools-d752` section of
  `lib/test-stuck-routing.sh`.
- **Never gate a lease decision on the transport `rc==4`** — it conflates a
  GENUINE unreachable (curl-fail / no HTTP code) with a REACHABLE 5xx/4xx-other
  AND local jq/mktemp faults (`lib/co-http-transport.sh`). A contended-lease 409
  is rc 1 (correctly distinct). For the AD2.2 unreachable-only posture use the
  `CO_HTTP_UNREACHABLE` sidecar (set 1 only on the curl-failed path), not the rc.
  (claude-tools-ylu2 — caught in review; a reachable 500 must fail CLOSED.)
- **Desired-state is LOCAL-FIRST — the runner OWNS it; the cloud only queues Brian's
  change-requests + caches the observation (claude-tools-dky8/y6j9 — P1 SHIPPED).** The
  motivating scar (break-through-pause): `co_deliver_desired_state` (runner-backend-real.sh)
  USED to do a live `co_request poll` every reconcile and fail-OPEN to `running` on ANY failure —
  baked in TWICE: the adapter's own `|| echo running` returned rc 0, so the
  `safe_capture COORD_UNREACHABLE running` degrade NEVER fired, and the `running` case was a
  no-op `:`, so the break-through was SILENT. One failed poll discarded a 17h `desired=paused`
  history and spawned a worker. **The fix (claude-tools-y6j9):** `co_deliver_desired_state`
  reads local `.co-store/runner_state.desired` FIRST via `co__store_get` (offline — the HTTP
  transport overrides `co_request`, NOT the store primitives); the network is demoted to a
  cold-start SEED used ONLY when there is no local record; the two `safe_capture` fallbacks at
  :2307/:2755 are now FAIL-CLOSED (`paused`, not `running`) and the `*)` unrecognized-desired arm
  HOLDS instead of claiming. runner.sh now `export`s `CO_STORE` at startup (it was set ONLY in
  the :730 stuck subshell — without it the main-loop store read hit the `/tmp` scratch path). A
  present local paused/stopped can no longer be flipped to running by an unreachable/5xx engine.
  **Do NOT re-add a network-authoritative desired read.** Brian's Stop/Run taps ride the
  `agent_actions` transient queue's NEW `set-desired` intent (target `{workspace}`, args
  `{state}`); the DAEMON is the SINGLE consumer (`agent-action-poll.sh`) — it applies the value
  to the same local record (apply-local-before-ack), and both runner + daemon
  (`desired-state-poll.sh`, the cold-start second reader) read local FIRST. The web
  `board/set-desired.js` ALSO keeps the legacy `set-desired` op write (GUI display + live
  old-code back-compat) — purely additive. SPLIT: heartbeat-carries-desired (report the applied
  value as observation) is an INTERFACE §1.1 amendment in its own bead. Regression-lock:
  `lib/test-desired-local-first.sh` + PART H of `daemon/test-m3-desired-state.sh` + the
  set-desired arm of `daemon/test-agent-action-poll.sh`. Sibling local-first beads: bd-ready TTL
  cache (claude-tools-4a2e), lease-envelope cache (claude-tools-h9dl), `.co-store` write-through
  (claude-tools-cx7t).
  **v1 PORTED (claude-tools-efu3):** v1 `run-beads-tasks.sh` has its OWN resolver
  `workspace_desired_state()` (the C2 spare-only gate's input) which used to read network desired
  with a 30s cache and fail-OPEN to empty (⇒ callers treat as running) once the cache aged out —
  the milder, cache-bounded twin of the same break-through. It now reads the local
  `.co-store/records/runner_state.<pref>.json` FIRST via `co__store_get` (network demoted to a
  cold-start seed), and v1 now `export`s `CO_STORE` ONCE at startup (right after `PROJECT_REF`) so
  the main-loop read hits the daemon-written store, not the `/tmp` scratch default (the same
  CO_STORE-export hole y6j9 closed for runner.sh). Regression-lock:
  `lib/test-desired-local-first-v1.sh` (sources the runner with `BEADS_RUNNER_TEST_MODE=1`).
  **CONSUMER GAP now CLOSED (claude-tools-yuwe):** v1's pickup path acts on all three non-running
  desireds — `spare-cycles` (daemon_ask_capacity), `stopped` (idle/skip + the daemon SIGTERM), AND
  `paused`. The paused consumer is the loop-top `runner_should_hold_paused` predicate + gate (called
  AFTER the feedback-return reconcile but BEFORE `select_workable_task`/`lease_acquire`): on
  `desired=paused` it `hb idle`s, sleeps `IDLE_POLL_INTERVAL`, and re-loops, NEVER claiming —
  mirroring v2's `st_reconcile` `paused) … hold` arm. Placed before select so a paused runner never
  pops a crash-orphan off `ORPHANED_IDS` only to drop it, and never churns lease acquire/release.
  PAUSED-ONLY (stopped stays the idle/skip loops + daemon SIGTERM; spare-cycles stays the capacity
  gate). Regression-lock: `lib/test-paused-consumer-v1.sh`. See BC-50.

- **The close-discipline dirty-tree check is BEAD-SCOPED, not whole-tree
  (claude-tools-f4ub).** The working tree is SHARED — a concurrent sibling
  runner / aux/triage session / stray human edit leaves FOREIGN uncommitted
  files this worker never touched. Both checks (the `hooks/close-checklist.sh`
  Stop+PreToolUse hook AND `post_close_audit` in BOTH runners) used to flag ANY
  non-scratch dirty path, so a foreign file caused (1) a false P1
  `DISCIPLINE_BYPASS` regression bead (the claude-tools-uxgpre false positive —
  uxgpre committed clean but a sibling's churn + a stray HANDOFF-UX-V2.md edit
  tripped the audit) AND (2) the hook BLOCKING the close advising "commit it
  under the bead / git restore" — both HARMFUL (commit smuggles a foreign diff
  into this bead's commit; `git restore` DESTROYS another actor's uncommitted
  work). Now a dirty path is the worker's OWN iff it appeared DURING the session
  (absent from the spawn-time baseline the runner snapshots at **claim** to
  `$LOG_DIR/dirty-baseline.txt`, exported ABSOLUTE as `BEADS_DIRTY_BASELINE` so
  the hook subprocess reads the exact file) OR it is in the bead's own commit set
  (`git log --grep=<id> --name-only`). FOREIGN-only dirt ⇒ the audit DOWNGRADES
  to a `FOREIGN_DIRT_AT_CLOSE` forensic incident (no P1 bead, no `Runner:
  DISCIPLINE_BYPASS` marker note) and the hook does NOT block / never
  restore-advises it (option C). No baseline file ⇒ `base_paths` empty ⇒ every
  dirty path is OWN ⇒ the OLD whole-tree behavior, so existing focused rigs are
  unchanged. The classification is TRIPLICATED (hook + v1 + v2) and must stay
  identical (the same deliberate copy-paste as the original dirty grep).
  Residuals (bash-unsolvable, both fail SAFE = keep the net): a foreign file
  dirtied MID-session by a concurrent sibling is absent from the baseline ⇒
  counted OWN; the commit-set rescue is space-blind (porcelain quotes spaced
  paths, `git log` doesn't). Locks: `hooks/test-close-checklist.sh` T25–T28,
  `test-post-close-audit.sh` T9–T10, `conformance/assertions/bc-56-post-close-audit-tree.sh` C7.

## Go deeper

- `beads-runner/BEHAVIORAL-CONTRACT.md` — the full BC-NN contract (read the clause
  before you touch the mechanism).
- `beads-runner/design/v2-gap.md` — the v1↔v2 gap + cutover sizing.
- `docs/HANDOFF-UX-V2.md` §1–§2 (topology + the two epics), §4 (the operational
  gotchas above). `docs/HANDOFF.md` — the older rescue-epic daemon/runner/engine map.
- `docs/runbooks/{runner-status-check,cleanup-orphan-runners,reset-stuck-bead,set-desired-state}.md`.
- `beads-runner/conformance/` — the BC assertion harness (driven by `testing.md`).

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a new BC clause, a moved/renamed `st_*` state, a v2-cutover
status change, a fresh scar, a changed spawn/selection rule. Update the v1-LIVE /
v2-OFFLINE status the moment the cutover lands — that single fact reframes the
whole doc. **Keep it concise — this doc earns its keep only if agents read all of
it.** Delete lines that have gone stale; do not let it grow into a second copy of
BEHAVIORAL-CONTRACT.md. Last substantive update: 2026-06-07 (close-discipline dirty-tree
check is now BEAD-SCOPED, not whole-tree — a FOREIGN uncommitted file no longer trips a false
P1 DISCIPLINE_BYPASS or a harmful hook block; spawn-time `BEADS_DIRTY_BASELINE` snapshot at
claim + bead-commit-set attribution + `FOREIGN_DIRT_AT_CLOSE` downgrade — claude-tools-f4ub;
see the new scar above). Prior: 2026-06-06 (v1 desired-state local-first
ported — `workspace_desired_state` reads `.co-store` runner_state FIRST + CO_STORE exported at
v1 startup; closes the cache-bounded v1 twin of break-through-pause — claude-tools-efu3; sibling of
the v2/daemon claude-tools-y6j9). The v1 paused-CONSUMER gap is now closed too: the loop-top
`runner_should_hold_paused` gate holds a paused v1 runner at idle (never claims), mirroring v2's
st_reconcile — claude-tools-yuwe, regression-lock `lib/test-paused-consumer-v1.sh`. Also landed:
the `bd ready` TTL cache in BOTH runners (claude-tools-4a2e) — v1 file-backed (the `$(next_task)`
subshell), v2 in-memory global, both busted at commit-to-run, BC-06 re-check left uncached
(see the new scar above; locks `lib/test-ready-cache.sh` + `bc-06-blocked-recheck-tree.sh`).
FOLLOW-UP (claude-tools-iu53): v1's file cache SURVIVES the process, so v1 now also busts it ONCE at
startup (after the `BEADS_RUNNER_TEST_MODE` guard, before the main loop) — a respawn within
`READY_CACHE_SECONDS` was serving a prior process's stale ready set and hiding freshly-filed work
(BC-24 cross-run-append RED on `run-beads-tasks.sh`; v2 stayed GREEN — its global is cold per process).
Locked by the new startup-bust assertion in `lib/test-ready-cache.sh` PART B.
