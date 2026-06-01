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
  fails CLOSED — no new unsynchronised claim, no BC-04 regression.
- **`LOG_DIR` is a self-gitignoring SECURITY boundary** (BC-27): raw model
  output / stream files must never reach git. The dirty-tree close audit excludes
  `.beads/issues.jsonl` (bd writes it as a side-effect — BC-56/u4ms).
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
- **Never gate a lease decision on the transport `rc==4`** — it conflates a
  GENUINE unreachable (curl-fail / no HTTP code) with a REACHABLE 5xx/4xx-other
  AND local jq/mktemp faults (`lib/co-http-transport.sh`). A contended-lease 409
  is rc 1 (correctly distinct). For the AD2.2 unreachable-only posture use the
  `CO_HTTP_UNREACHABLE` sidecar (set 1 only on the curl-failed path), not the rc.
  (claude-tools-ylu2 — caught in review; a reachable 500 must fail CLOSED.)

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
BEHAVIORAL-CONTRACT.md. Last substantive update: 2026-05-31.
