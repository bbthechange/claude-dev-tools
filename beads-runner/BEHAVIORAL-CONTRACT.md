# Behavioral Conformance Contract — `run-beads-tasks.sh`

> **Status:** Pre-rewrite characterization. READ-ONLY. This document describes the
> *current observable behavior* of `beads-runner/run-beads-tasks.sh` exactly as it
> exists at the commit this was written against (930 lines). It contains **no
> design, no architecture, and no proposals.** It is the gate the planned rewrite
> must pass: every item marked **SCAR** is a behavior that encodes a production
> failure lesson and must survive (semantically — not necessarily line-for-line);
> every item marked **SCAFFOLDING** is a bash/CLI implementation artifact that
> must *not* be ported faithfully (re-implement idiomatically; copying it forward
> is cargo-culting).
>
> Classification key:
> - **SCAR** — observable behavior born of a real failure. Losing it re-learns the lesson in prod.
> - **SCAFFOLDING** — mechanism dictated by bash/CLI limits. The *intent* may be a scar; the *mechanism* must be rebuilt, not transcribed.
> - **SCAR (intent) / SCAFFOLDING (mechanism)** — used where the behavior must survive but the specific implementation must not.
>
> Each entry: **Assertion** (testable, black-box) · **Repro** (how to trigger without reading source) · **Source** (file:line) · **Classification** + one-line justification.

---

## 1. Core invariant

### BC-01 — Fresh process + fresh context per task
**Assertion:** Every task is executed by a brand-new `claude -p` process invocation. No conversation, context, or memory carries between tasks. There is no `--continue`/`--resume`; a task that fails and is retried starts from an empty context window the next time.
**Repro:** Queue two tasks. Observe two distinct `claude` PIDs; the second has zero knowledge of the first's conversation.
**Source:** lines 1–3 (header intent), 642–649 (per-task `claude -p` spawn inside the main loop).
**Classification:** **SCAR.** This is the entire reason the runner exists — it exists to defeat autocompact drift by never sharing a context window across tasks. A rewrite that pools/threads context across tasks defeats the tool's purpose.
**Note (doc drift, not a behavior change):** The header comment says "clean 200k context window" but `DEFAULT_MODEL=opus[1m]` (1M window). The invariant is *fresh context per task*, independent of window size.

---

## 2. Task selection & orphan recovery

### BC-02 — Startup in_progress snapshot = crash orphans; later in_progress = other agents
**Assertion:** Tasks that are `in_progress` *at script startup* are treated as orphans from a previous crashed run and are eligible for resumption. Tasks that become `in_progress` *after* startup are assumed owned by another agent and are never adopted (they are not in `ORPHANED_IDS`).
**Repro:** Set a task to `in_progress`, start the runner → it resumes that task. While the runner is running, set a *different* task `in_progress` → the runner ignores it.
**Source:** 239–243 (snapshot), 248–272 (`next_task` drains orphans before `bd ready`).
**Classification:** **SCAR.** Crash recovery — without it, a crashed run permanently strands its in-flight task as `in_progress` (invisible to `bd ready`, never retried).

### BC-03 — Empty-orphan-list guard
**Assertion:** When there are no `in_progress` tasks at startup, the runner does **not** attempt `bd show ""`. It proceeds straight to `bd ready`.
**Repro:** Start the runner with zero `in_progress` tasks; no spurious `bd show` with an empty ID occurs.
**Source:** 243–245. `read -ra` on empty input yields a 1-element array `("")`; line 245 detects exactly that shape and resets to an empty array.
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The intent — "no orphans ⇒ skip orphan processing" — must survive. The `read -ra … ${#==1 && -z [0]}` quirk is a pure bash artifact (`read` cannot distinguish "empty" from "one empty field"); a rewrite with a real list type has no such hazard and must not transcribe this guard.

### BC-04 — One orphan resumed per loop iteration; status re-checked at resume time
**Assertion:** `next_task()` resumes **at most one** orphan per main-loop iteration (the first still-`in_progress` one), preserving the remaining orphans for subsequent iterations. Before resuming any orphan it re-queries `bd show` for that orphan's *current* status:
- still `in_progress` → resume it (emit its JSON), keep untouched orphans after it for later;
- status changed to anything else non-empty (e.g. another agent closed it) → **drop** it from the orphan list;
- `bd show` returns no parseable status → **keep** it for a later retry (a flaky `bd show` must not lose an orphan).
After the orphan list is exhausted, fall through to `bd ready` (or `[]` if that fails).
**Repro:** Seed three orphans A,B,C. Close B externally before the runner reaches it. Observe: A resumed loop 1; B silently dropped; C resumed a later loop. Make `bd show` fail transiently for A → A is retried on the next loop, not lost.
**Source:** 248–272 (esp. 256–267 status branch, 258–259 tail-preservation, 271 fall-through).
**Classification:** **SCAR.** The re-check is a TOCTOU defense; the keep-on-bad-`bd show` and one-per-loop draining are deliberate.
**Precise scope of the race this closes (honest limitation, not a redesign):** The recheck closes the window where an orphan *no longer needs work* (closed/advanced by something else between the startup snapshot and the — potentially 30-minute, usage-gated — first loop). It does **not** prevent two runners from both resuming the *same still-`in_progress` orphan* (both observe `in_progress`). The seed's phrasing "closes the snapshot→first-loop race" is correct only for the status-changed case; the two-runners-one-orphan race is residual and uncharacterized by any guard in this script.

### BC-05 — Empty `bd ready`: idle-on-drain by default (UX §0.A), legacy exit-0 opt-in
**Assertion:** When no orphan and no ready task is available, the **default** behavior (UX §0.A) is to **idle**: print one "idling…" line, heartbeat `idle`, poll every `IDLE_POLL_INTERVAL` / `RECLAIM_POLL_INTERVAL` seconds, and pick up new ready work without an external respawn. `.stop-beads` and Coordinator `desired=stopped` end the runner cleanly within one poll interval. The legacy SCAR — drain ⇒ exit 0 — is opt-in via `RUNNER_EXIT_ON_DRAIN=1` (the conformance harness sets this so the BC-21 exit-code table is still exercised end-to-end).
**Repro (default):** Run with an empty/all-blocked queue and `RUNNER_EXIT_ON_DRAIN` unset → runner stays alive, logs `idling`, and picks up tasks added after the drain.
**Repro (legacy SCAR):** Same setup with `RUNNER_EXIT_ON_DRAIN=1` → runner prints "No more ready tasks." and exits 0.
**Source (rewrite):** `runner.sh` `st_drained` — opt-in legacy path goes to `TERMINAL`; default path heartbeats idle, sleeps `RECLAIM_POLL_INTERVAL`, transitions back to `RECONCILE` (which already honors `STOP_FILE` and `desired=stopped`). `IDLE_ANNOUNCED` keeps the log to one line per idle spell; `st_claim` clears it.
**Source (v1):** `run-beads-tasks.sh` main loop — empty `TASK_ID` either `break` (legacy opt-in) or enters the idle-poll loop that checks `.stop-beads` + `workspace_desired_state` every `IDLE_POLL_INTERVAL`.
**Classification:** **SCAR.** The "drain ⇒ exit 0" code path is the *outward* contract a coordinator depends on (BC-21) and must remain testable. The behavioral contract Brian protects (UX §0.A: "Runner keeps running when out of tasks and picks tasks up once added.") is the *default* in production; the legacy exit is preserved as an opt-in for conformance + any external supervisor that still treats exit 0 as "drained." Issue: claude-tools-giu.

---

## 3. Workability validation (TOCTOU)

### BC-06 — `validate_task` re-checks `bd blocked` (deps added after `bd ready`)
**Assertion:** Even though the task came from `bd ready`, immediately before execution the runner re-queries `bd blocked`; if the task now appears blocked it is **skipped with no failure counted** (no `FAILED++`, no retry tracking, no circuit-breaker effect — a blank line then `continue`).
**Repro:** Between `bd ready` returning task X and the runner starting it, add a dependency that blocks X. Observe X skipped, not failed.
**Source:** 279–285 (blocked re-check), 576–580 (skip path = `continue`, cost-free).
**Classification:** **SCAR.** Closes the TOCTOU window between the `bd ready` snapshot and execution; without it the runner would start a task whose dependency is unmet.

### BC-07 — `bd show --children` self-inclusion is filtered out
**Assertion:** When checking whether a task is a parent/container, the task itself is excluded from its own children list before counting.
**Repro:** A leaf task with no children must not be treated as its own parent. (Observable only as the *absence* of false "skipping parent task" on childless tasks.)
**Source:** 288–293 (`jq 'select(.id != $id)'`).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** Compensates for a `bd` CLI quirk (`--children` includes self). The compensation must survive *as long as `bd` behaves this way*; the `jq` filter itself is mechanism. A rewrite must verify the underlying `bd` contract rather than transcribe the filter blindly.

### BC-08 — All-children-closed ⇒ auto-close the parent; otherwise skip it
**Assertion:** If a task has children and **all** are closed, the runner auto-closes the parent (`bd close --reason="All children completed"`) and skips it. If some children are still open, the parent is skipped with a "N of M children still open" message. Either way the parent is never executed and no failure is counted.
**Repro:** Create parent P with two children; close both; run the runner with P ready → P is auto-closed. Leave one open → P is skipped, not run, not failed.
**Source:** 287–305, plus 576–580 (cost-free skip).
**Classification:** **SCAR.** Prevents the runner from feeding a container task to an agent (which would have nothing concrete to do) and prevents stale parents lingering after their work is done.

### BC-08b — `RUNNER_NO_CLAIM_LABELS` hard label gate (claude-tools-noj, claude-tools-tkf)
**Assertion:** Before the dependency / epic / parent checks, `validate_task` reads `bd label list <id> --json` and, if the task carries **any** label in `RUNNER_NO_CLAIM_LABELS` (default `human-live-session,human-triage,human-action`; comma-separated, surrounding whitespace stripped), the task is **skipped with no failure counted** (no `FAILED++`, no retry, no circuit-breaker, no incident — same cost-free `continue` as BC-06/07/08). The check runs on every loop, so a runner cannot grandfather in a previously-claimed task by holding state; the gate is sticky across bd reloads because the label can only be lifted by a human (the runner never removes labels). A project `.beads/runner.sh` may **extend** the gate (e.g. an FE-rooted workspace appending `backend` so its sandbox refuses backend-impl beads) without editing the runner.
**Repro:** Label a ready task `human-live-session` (or `human-triage` / `human-action`) → `bd ready` still surfaces it, but the runner prints `Skipping: label '<name>' present (RUNNER_NO_CLAIM_LABELS — human-driven fixture, not for autonomous claim)` and continues; the bead stays open for Brian to claim from his phone.
**Source:** runner config block (`RUNNER_NO_CLAIM_LABELS` default), `validate_task` head (label scan + skip).
**Classification:** **SCAR.** Closes the failure class proved by claude-tools-240 (closing-gate fixture for bzc) — four consecutive `TASK_NOT_CLOSED` cycles in a single night (06:23/06:44/08:02/08:24Z, 2026-05-22) where the runner kept re-claiming a fixture explicitly designed for a one-shot live session with Brian on his phone. tkf documented the adjacent class: FE-rooted sessions auto-claiming `backend`-labelled work AND auto-claiming the very `human-action` blocker filed to stop the loop, 6+ failed iterations each — description text + priority + status flips were all ignored under load; only a labelled refusal is durable. `human-action` is universal (lives in the default); `backend` is workspace-specific (FE-rooted configs extend the gate). The gate intentionally lives **before** the dependency/epic checks so a gated task with open deps is still skipped silently rather than logging "blocked" noise.

---

## 4. Failure classification

### BC-09 — Exit 0 ≠ success; truth is `bd` task status
**Assertion:** A `claude` exit code of 0 is **not** trusted as success. The runner queries the task's `bd` status:
- `status == closed` → `SUCCESS`;
- status empty (`bd show` failed) → `SUCCESS` (explicit **fail-open**, with a stderr note "Could not verify task status — assuming success");
- any other status (open/in_progress) → `TASK_NOT_CLOSED` (a distinct class, not generic failure).
**Repro:** Make the agent exit 0 without calling `bd close` → classified `TASK_NOT_CLOSED`, not success. Make `bd show` fail on an exit-0 task → classified `SUCCESS` (fail-open).
**Source:** 318–330.
**Classification:** **SCAR.** Agents routinely exit 0 having "finished" without closing the issue; trusting exit code would silently mark incomplete work done. The fail-open-on-empty-status is itself a deliberate scar (a `bd` outage must not convert every success into a phantom failure).

### BC-10 — Classification order is correctness, not cosmetics
**Assertion:** A single session can append **multiple** signal markers to the signal file (e.g. a transient `rate_limit` api_retry followed by a terminal context overflow). Classification scans them in a fixed precedence and returns the **first match**, deliberately ordered most-decisive/terminal first:
`AUTH_FAILURE → BILLING_ERROR → CONTEXT_OVERFLOW → MAX_OUTPUT_TOKENS → SERVER_ERROR → WATCHDOG_KILL → RATE_LIMIT → UNKNOWN_FAILURE`
where `MAX_OUTPUT_TOKENS` matches any of three markers: `MAX_OUTPUT_TOKENS=`, `RESULT_STOP_REASON=max_tokens`, `RESULT_STOP_REASON=length`.
**Repro:** Produce a session that emits a `rate_limit` api_retry and then overflows context. It must classify `CONTEXT_OVERFLOW` (terminal), not `RATE_LIMIT` (which would retry forever).
**Source:** 332–353 (ordered greps), 671–688 (api_retry → markers), 690–707 (result → markers).
**Classification:** **SCAR.** Reordering these silently changes behavior from "stop/escalate" to "retry forever" for any multi-signal session. The order *is* the logic.

### BC-11 — Context overflow ("Prompt is too long") is a first-class terminal class
**Assertion:** An API context overflow surfaces as an **errored result** (`is_error=true`) whose `stop_reason` is `stop_sequence` (NOT `max_tokens`/`length`) and whose result text contains "prompt is too long" (or, defensively, "context_length_exceeded"). The parser pattern-matches this (case-insensitive, **guarded by `is_error==true`** so a normal summary that quotes the phrase is not misclassified) and emits `CONTEXT_OVERFLOW=1`. Classification places `CONTEXT_OVERFLOW` *before* `MAX_OUTPUT_TOKENS`. Without this explicit pattern-match the failure has no token stop-reason match, falls through to `UNKNOWN_FAILURE`, and is retried — each retry re-overflowing deterministically at the same point.
**Repro:** Give a task a prompt/description large enough to exceed the model window. Confirm: result `is_error=true`, `stop_reason=stop_sequence`, text "Prompt is too long"; classified `CONTEXT_OVERFLOW`; **not** retried (goes straight to an analysis child — see BC-17).
**Source:** 339–342 (ordering + rationale), 697–707 (parser pattern-match + `is_error` guard).
**Classification:** **SCAR.** This is a documented, specific production incident (infinite identical re-overflow). The `is_error` guard is also a scar (prevents a benign summary from tripping it).

### BC-12 — `max_output_tokens` arrives via two independent paths
**Assertion:** `MAX_OUTPUT_TOKENS` is detected whether the limit surfaces as a `system/api_retry` event with `error=max_output_tokens`, or as a `result` event with `stop_reason` of `max_tokens` or `length`. All three collapse to the single class `MAX_OUTPUT_TOKENS`.
**Repro:** Trigger output-token exhaustion via each path; both classify identically.
**Source:** 684 (api_retry path), 344–346 (result-stop-reason paths).
**Classification:** **SCAR.** The dual path is a real observation about how the SDK reports the same condition; collapsing one path loses detections.

---

## 5. Retry / circuit-breaker semantics

### BC-13 — Per-class retry asymmetry
**Assertion:** Different failure classes have deliberately different retry treatment:
- **RATE_LIMIT:** task reset to `open`; `LAST_FAILED_ID` is **not** set, so the rate-limit attempt is *invisible to the per-task retry counter* (it does not consume a retry); forces a fresh usage check next loop. No notification (routine).
- **CONTEXT_OVERFLOW / MAX_OUTPUT_TOKENS:** **skip retry entirely** — `LAST_FAILED_ID=""`, `FAIL_COUNT=0`, escalate straight to an analysis child (retrying re-overflows identically).
- **TASK_NOT_CLOSED:** retry **once**, then on the second consecutive occurrence create an analysis child.
- **Generic (SERVER_ERROR / WATCHDOG_KILL / UNKNOWN / fallthrough):** counts toward the consecutive-failure circuit breaker **only if the task differs from the last failed task**, then records the task as last-failed.
- **Generic via the top-of-loop retry gate:** when the *same* task is re-picked, `FAIL_COUNT` increments; at `MAX_RETRIES` (default 2) the task is reset to `open`, an `exceeded_max_retries` analysis child is created, and counters reset.
**Repro:** Rate-limit a task 5×: it is never "exhausted". Overflow a task once: an analysis child appears immediately, no retry. Fail a task generically twice (same task): the 2nd does *not* advance the breaker; a 3rd pick hits `MAX_RETRIES`.
**Source:** 582–599 (top-of-loop `MAX_RETRIES` gate), 824–833 (RATE_LIMIT, esp. 830 comment), 835–861 (overflow/max-tokens skip), 863–880 (task-not-closed retry-once), 882–894 (generic, distinct-task breaker increment).
**Classification:** **SCAR.** Each asymmetry encodes a specific lesson: rate-limit retries are infinite-by-design and must not burn the retry budget; overflow retries are pure waste; "exited 0 but open" is usually a one-off "forgot `bd close`".

### BC-14 — Consecutive-failure circuit breaker counts *distinct* tasks only, resets on success
**Assertion:** The circuit breaker (`CONSECUTIVE_FAILURES >= MAX_CONSECUTIVE_FAILURES`, default 3 → exit 2) is advanced **only** by the generic-failure branch, and **only when the failing task differs from the previously failed task**. It is reset to 0 **only on `SUCCESS`**. RATE_LIMIT, CONTEXT_OVERFLOW, MAX_OUTPUT_TOKENS, TASK_NOT_CLOSED do not advance it. Consequence: a storm of context overflows across many distinct tasks does **not** trip the breaker (each spawns an analysis child instead); the breaker specifically catches "many *different* tasks failing with generic/unknown errors" (its stated purpose: "avoid closing healthy tasks as skipped" — i.e. a systemic fault like auth drift or disk-full marching through and burning the queue).
**Repro:** Fail 3 *different* tasks with generic errors and no intervening success → runner stops, exit 2. Fail the *same* task 3× generically → breaker does *not* trip (the per-task `MAX_RETRIES` path handles it). Alternate fail/success → breaker never trips.
**Source:** 882–894 (distinct-task increment), 787–794 (`SUCCESS` resets), 908–919 (breaker + rationale comment 911–912).
**Classification:** **SCAR.** The "distinct task" and "reset on success" rules are precise and load-bearing; a naive "any failure increments" breaker would stop healthy runs on a single flaky task.

### BC-15 — A failed task is released to `open` (never left `in_progress`)
**Assertion:** Every non-success terminal handling resets the task with `bd update --status=open` (not `in_progress`), returning it to the `bd ready` pool and ensuring it is not later mistaken for an active task or a crash orphan.
**Repro:** Fail a task by any class; immediately observe its `bd` status is `open`.
**Source:** 587, 799, 813, 827, 838, 850, 866, 885 (uniform `--status=open`).
**Classification:** **SCAR.** The choice of `open` (vs. leaving `in_progress`) is deliberate: `in_progress` would make a just-failed task indistinguishable from work-in-flight / a future orphan.

### BC-16 — Retry timing is "next time this task is `bd ready`'s `.[0]`", not "immediately"
**Assertion:** A failed task reset to `open` re-enters the `bd ready` pool; it is *not* an orphan (orphans are snapshotted only at startup). The runner always takes `.[0]` of `next_task()`. Whether the failed task is retried on the very next iteration depends on `bd ready` ordering — other higher-ranked ready tasks run first. The per-task retry counter therefore tracks "consecutive *picks* of the same task", which may be interleaved with other tasks.
**Repro:** Fail task X while higher-priority task Y is ready → Y runs next, not X; X's `FAIL_COUNT` does not advance until X is `.[0]` again.
**Source:** 553–554 (`.[0]` selection), 583–599 (`LAST_FAILED_ID` equality gate), 239–245 (orphan snapshot is startup-only).
**Classification:** **SCAR.** Subtle but real: retry/breaker semantics are coupled to `bd ready` ordering, not wall-clock immediacy. A rewrite that assumes "failed task retried immediately" changes counting behavior.

---

## 6. Exit codes — external contract

### BC-21 — Exact, distinct exit codes per terminal condition
**Assertion:** The runner's process exit code is a stable signal a supervisor can switch on:
| Exit | Condition | Source |
|------|-----------|--------|
| **0** | Normal end: `bd ready` empty ("No more ready tasks") **or** graceful stop file consumed. Falls off end of script. | 533, 559, 927–930 |
| **1** | `SIGINT`/`SIGTERM` received → `cleanup()` trap. | 147–162 |
| **2** | Consecutive-failure circuit breaker tripped. | 908–919 |
| **3** | `AUTH_FAILURE` (terminal). | 796–808 |
| **4** | `BILLING_ERROR` (terminal). | 810–822 |
**Repro:** Drive each condition; assert `$?`.
**Classification:** **SCAR.** These codes are an outward-facing contract. `AUTH=3`, `BILLING=4`, `breaker=2`, `signal=1`, `clean=0` must be preserved exactly — a coordinator distinguishing "stop everything, credentials are bad (3)" from "queue drained (0)" depends on them.
**Finding (gap, see BC-33):** There is **no `EXIT` trap**. Only `INT`/`TERM` are trapped. A `set -e` abort mid-script (e.g. an unguarded command failing) exits with that command's status and runs *no* cleanup — leaving `CURRENT_TASK_ID` stranded `in_progress` and temp files undeleted. This is an honest characterization of current behavior, not a proposal.

---

## 7. Watchdog

### BC-22 — Idle-stream watchdog with snapshot-before-signal and staged kill
**Assertion:** A background watchdog polls every 15s while the `claude` PID is alive. "Idle" = seconds since the last *stream line* was parsed (the stream parser stamps `ACTIVITY_FILE` on every line; initialized at spawn). Behavior:
- `IDLE >= 180s` (hardcoded, not configurable): print a soft "No activity for Ns — possibly stuck" warning, keep waiting.
- `IDLE >= IDLE_TIMEOUT` (default 600s, env-overridable): emit `WATCHDOG_KILL=1`; **before sending any signal**, snapshot the process — `ps -o pid,stat,etime,pcpu,pmem,command` and `lsof` filtered to `TCP|IPv|PIPE` — into `PROC_SNAPSHOT` (lsof on a dying process returns nothing useful, so order matters); then **staged kill**: `SIGINT` first (gives the SDK a chance to flush in-flight HTTP-retry state to stderr, which is merged into the stream file), poll up to 10×1s, then `SIGKILL` if still alive.
**Repro:** Make the agent hang silently (no stream output) for >600s. Observe: soft warning at ≥180s; at ≥600s a `PROC_SNAPSHOT` with ps+lsof captured *before* the process dies; `SIGINT` then (≤10s later) `SIGKILL`; classification `WATCHDOG_KILL`.
**Source:** 719–760.
**Classification:** **SCAR.** Snapshot-before-SIGINT and SIGINT-before-SIGKILL are explicitly hard-won (post-mortem evidence is destroyed if you signal first; SDK retry state is only flushed on graceful interrupt). The 180s-vs-IDLE_TIMEOUT two-tier and the 15s poll cadence are tuned values. **SCAFFOLDING:** the bash subshell/`kill -0` loop mechanism itself.
**Note:** "Idle" proxies "stuck" via *stream silence*. A long single tool call that emits no stream lines looks idle — this is why the default timeout is a generous 600s. A rewrite must preserve "silence ⇒ stuck after a long grace period", not a tighter heartbeat that would kill legitimately-slow tools.

### BC-22 addendum — Task-subagent-aware idle (claude-tools-idg)
**Assertion:** Task tool subagents are IN-API constructs inside the `claude` process — neither stream growth nor process-tree CPU reliably reflects their progress while the parent waits on the model. The stream itself carries the signal: `{"type":"system","subtype":"task_notification","task_id":"…","status":"in_progress",…}` on start and `{"type":"system","subtype":"task_updated","task_id":"…","patch":{"status":"completed|stopped|killed|failed|cancelled"}}` on terminal. The watchdog replays those events to maintain a live in-flight set; when `inflight > 0` the effective kill threshold is `IDLE_TIMEOUT × IDLE_TIMEOUT_INFLIGHT_MULT` (env-overridable, default 6 ⇒ 1h on stock 600s). The kill is **stretched, not paused** — a genuinely deadlocked bg-Bash that registered as in-flight (the D5 2026-05-20 case) still dies eventually.
**Repro:** Emit a `task_notification status=in_progress`, then silence with no tree CPU; observe NO kill at `IDLE_TIMEOUT` (the legitimate long-subagent case). Emit a terminal `task_updated`, then silence; observe the kill resumes at the unstretched `IDLE_TIMEOUT` (the stuck case after subagent finished).
**Source:** `runner.sh` (`_inflight_tasks`, `_watchdog_loop`); `run-beads-tasks.sh` (parser `task_notification|task_updated` branch + watchdog `EFFECTIVE_TIMEOUT`); `conformance/assertions/bc-22-watchdog-tree.sh::bc22tree_inflight_subagent`.
**Classification:** **SCAR.** Stretch-not-pause is the load-bearing discipline — paused-on-inflight loses the backstop entirely, which would re-introduce the failure mode the watchdog exists to prevent.

---

## 8. Analysis-task escalation

### BC-17 — Failed task is *blocked by* a fresh analysis child; infinite chains are guarded
**Assertion:** On the escalating classes (`exceeded_max_retries`, `MAX_OUTPUT_TOKENS`, `CONTEXT_OVERFLOW`, second `TASK_NOT_CLOSED`), the runner creates a new beads issue titled "Analyze failure: <title>", priority 1, labels `model:opus,analysis`, then runs `bd dep add <failed-task> <analysis-task>` so the **failed task is blocked by the analysis task** (it won't be re-picked until the analysis is resolved), and appends a note to the failed task pointing at the analysis ID. **Guard:** if the failing task itself carries the `analysis` label, no analysis child is created (prevents infinite analysis-of-analysis chains).
**Repro:** Overflow a normal task → an `analysis`/`model:opus` child exists, original task now blocked by it. Overflow a task that already has the `analysis` label → no new child; message "Skipping analysis task creation — this is already an analysis task".
**Source:** 355–407 (creation + label guard 361–367 + dep-add 401), 591 / 842 / 857–858 / 874 (call sites).
**Classification:** **SCAR.** The escalate-don't-loop pattern and the analysis-of-analysis guard are direct responses to runaway failure loops.

### BC-18 — Analysis ID is scraped from `bd create` human stdout via `sed`
**Assertion:** The new analysis task's ID is extracted by `sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1` against `bd create`'s human-readable stdout ("✓ Created issue: prefix-abc — title"). If the regex fails to match, the runner prints a warning and skips the dependency wiring (the analysis task exists but does not block the parent).
**Repro:** Change `bd create`'s output format → dependency wiring silently breaks (analysis task orphaned, parent not blocked).
**Source:** 384–399.
**Classification:** **SCAFFOLDING.** This is brittle CLI-output scraping and must **not** be ported. A rewrite must obtain the new ID structurally (JSON/return value). Faithfully transcribing the `sed` re-imports a latent breakage coupled to `bd`'s cosmetic output.

### BC-19 — Salvage guidance is embedded in the failure-reason string (esp. context overflow)
**Assertion:** The `reason` passed into the analysis task's description carries actionable salvage instructions for the next agent. For `CONTEXT_OVERFLOW` specifically it is a long directive: inspect `git log`/`git diff` for work the overflowed agent already committed/staged, **re-scope to only the remaining steps (do not redo completed work)**, split if inherently too large, and **relabel the re-scoped task `model:opus`** (overflow-prone tasks are usually `model:sonnet`/200K). The generic analysis description also instructs the investigator to `bd dep add` any new tasks back onto the failed task before closing.
**Repro:** Trigger `CONTEXT_OVERFLOW`; read the analysis task's description — it contains the git-salvage + re-scope + relabel guidance verbatim.
**Source:** 369–382 (generic template), 854–858 (context-overflow reason).
**Classification:** **SCAR.** The salvage text encodes the specific recovery procedure for partial-progress-then-overflow; losing it makes the next agent redo or discard completed work. **SCAFFOLDING (mechanism):** the heredoc/`read -r -d ''` templating itself.

---

## 9. Observability (incidents, notes, notifications, tool-error scan)

### BC-23 — Uniform, greppable beads note on every non-success
**Assertion:** Every non-success classification appends a note to the task in the fixed form `Runner: <CLASSIFICATION> at <HH:MM:SSZ> — log: <path>` (or `— no stream preserved`). This is a deliberate observability contract — a human/tool greps `bd show` for `Runner:`.
**Repro:** Fail a task; `bd show` it; the note matches the `Runner: <CLASS> at …` shape.
**Source:** 432–445 (`append_runner_note`), called from every failure branch + the max-retries gate.
**Classification:** **SCAR.** The uniform prefix is the audit seam; ad-hoc note text would break grep-based triage.

### BC-24 — Append-only cross-run incidents log + per-run summary
**Assertion:** Every non-success classification appends a TSV row `<utc-ts>\t<task>\t<class>\t<logpath|->` to `.beads/runner-logs/incidents.log` (append-only, **exempt from age-rotation** — it persists across runs as the audit trail) and to an in-memory list printed as an "Incidents this run (N):" summary at every terminal exit (normal end, breaker, AUTH, BILLING). Its purpose is to surface silently-retried failures (e.g. a watchdog kill) that would otherwise vanish when the next attempt succeeds.
**Repro:** Cause a watchdog kill then let the retry succeed → run still ends with an "Incidents this run" block and a persistent `incidents.log` row.
**Source:** 421–430 (`record_incident`), 447–461 (`print_incidents_summary`), 106 (rotation explicitly excludes `incidents.log`), summary printed at 806/820/917/929.
**Classification:** **SCAR.** "A later success must not erase the fact that an earlier attempt failed" is the explicit lesson.

### BC-25 — `scan_tool_errors`: pattern-matched, side-effect-only, never changes classification/exit
**Assertion:** After classification (on **every** task including `SUCCESS`), the stream is scanned for `tool_result` entries with `is_error:true`. It is a **cheap pre-filter** (`grep -qF '"is_error":true'`, skip the `jq` pass entirely if absent) then a `jq` extraction handling `content` as string *or* array. Only three **pattern-matched** signatures are surfaced — subagent-not-found (`Agent type 'X' not found`), permission (`Permission denied|is not allowed`), MCP-down (`MCP server.*(unavailable|failed|not connected)`). It **never** changes the classification or the exit code; it only appends a beads note + incident row (+ a notification for the subagent case). Raw `is_error` counts are deliberately *not* used (they would be dominated by routine probes: Read-on-missing-file, grep-no-match).
**Repro:** Have an agent invoke a missing subagent but recover and exit 0/closed → classification is `SUCCESS`, exit unchanged, **but** a `TOOL_ERROR:subagent-unavailable …` incident + beads note + desktop notification are produced.
**Source:** 463–510, invoked at 900.
**Classification:** **SCAR (intent).** "An inline-recovered tool failure still means the agent didn't do what we asked — surface it without failing the run" is the lesson, as is "pattern-match, never raw-count". **SCAFFOLDING (mechanism):** the specific regex strings are CLI-format-coupled and brittle by the code's own admission ("Update if drift observed") and must not be transcribed as-is.

### BC-26 — Notification policy: routine classes are deliberately silent
**Assertion:** `notify_user` (terminal bell + macOS `osascript`, best-effort, double-quote-escaped, never fails the run) is invoked for: `AUTH_FAILURE`, `BILLING_ERROR`, `MAX_OUTPUT_TOKENS`, `CONTEXT_OVERFLOW`, generic failures, `exceeded_max_retries`, subagent-unavailable, and the consecutive-breaker stop. It is **deliberately NOT** invoked for `SUCCESS`, `RATE_LIMIT`, or the *first* `TASK_NOT_CLOSED` — these are routine/expected and notifying would spam.
**Repro:** Rate-limit a task → no desktop notification. Auth-fail → notification.
**Source:** 512–523 (`notify_user`), call/no-call sites: silent at 824–833 (rate-limit), 863–880 (first task-not-closed), 787–794 (success); noisy elsewhere.
**Classification:** **SCAR.** The *silence* choices are the lesson (alert fatigue from routine retries). **SCAFFOLDING:** `osascript`/bell is platform-specific mechanism.

---

## 10. Post-mortem artifact policy & security boundary

### BC-27 — `LOG_DIR` is a self-gitignoring SECURITY boundary
**Assertion:** `.beads/runner-logs/` contains a `.gitignore` of exactly `*` + `!.gitignore`, created if absent, so **every** artifact written there (stream-json, ps/lsof snapshots, incidents.log, preflight.log) is git-ignored regardless of whether the parent `.beads/` is tracked. Stream-json files contain raw model output, file contents, and tool results — they must never be committed.
**Repro:** `git status` after a run that preserved a stream → the stream file is not listed; `.beads/runner-logs/.gitignore` exists with `*` / `!.gitignore`.
**Source:** 93–101.
**Classification:** **SCAR (security).** This is a containment boundary, not a convenience. A rewrite that writes post-mortem artifacts to any committable location leaks source code, tool I/O, and potentially secrets into git history. Must survive in spirit and in strength.

### BC-28 — Selective stream preservation by class; proc snapshot kept only for `WATCHDOG_KILL` classification
**Assertion:** The full stream-json is copied to `LOG_DIR` **only** for serious classes: `WATCHDOG_KILL`, `UNKNOWN_FAILURE`, `SERVER_ERROR`, `MAX_OUTPUT_TOKENS`, `CONTEXT_OVERFLOW`. Routine/transient classes (`RATE_LIMIT`, `TASK_NOT_CLOSED`, `SUCCESS`) get **no** stream copy (disk-spam avoidance) but still get an incident row + beads note. The `PROC_SNAPSHOT` is written only by the watchdog; it is retained iff the final classification is exactly `WATCHDOG_KILL`, and deleted otherwise — note this keys on *classification*, not on *whether the watchdog fired*: if the watchdog killed the process but a more-decisive earlier signal (e.g. `SERVER_ERROR`) wins classification, the proc snapshot is discarded.
**Repro:** `RATE_LIMIT` → no `.jsonl` in `LOG_DIR`, but an incident row exists. `WATCHDOG_KILL` → both `.jsonl` and `.proc.txt` retained. Watchdog kills but classified `SERVER_ERROR` → `.jsonl` kept, `.proc.txt` deleted.
**Source:** 773–785 (preservation class list), 902–906 (proc snapshot retention keyed on classification).
**Classification:** **SCAR.** The class list is a tuned cost/value policy (disk spam was a real problem; losing post-mortems on serious failures was also a real problem). The proc-snapshot-keyed-on-classification edge is a precise, non-obvious behavior.

### BC-29 — Per-iteration timestamped artifact basenames prevent retry collisions
**Assertion:** Artifact filenames embed a per-iteration UTC timestamp (`<TASK_ID>-<ITER_TS>`), so repeated attempts of the same task do not overwrite each other's preserved streams/snapshots.
**Repro:** Fail the same task twice with a preserved class → two distinct `.jsonl` files.
**Source:** 635–638.
**Classification:** **SCAR.** Without it, the second failure's post-mortem clobbers the first's — exactly when you most need both.

---

## 11. Log-dir lifecycle

### BC-30 — Age-based rotation runs exactly once per invocation (cannot race active runs)
**Assertion:** Pruning of artifacts older than `LOG_RETENTION_DAYS` (default 14; excludes `.gitignore` and `incidents.log`) runs **once at startup**, never per-iteration, so it cannot delete artifacts a concurrently-running invocation is actively producing.
**Repro:** Run a long invocation; its in-progress artifacts are never pruned mid-run by itself.
**Source:** 103–108.
**Classification:** **SCAR.** "Rotate at startup, not in the loop" is explicitly to avoid racing active runs — a per-iteration prune is a footgun a rewrite could re-introduce.

### BC-31 — Preflight asset snapshot surfaces silent agent failure from line 1 (but does not abort)
**Assertion:** Before any task runs, the runner writes `preflight.log` (pwd, `.claude/agents` listing, `.claude/skills` listing, `claude --version`, `bd version`) and prints a one-line `Pre-flight: N project agent(s), M project skill(s)` count. This makes "wrong cwd / empty `.claude/agents` ⇒ agents that worked interactively silently fail inside `claude`" obvious immediately. It is **diagnostic only** — a count of `0` does **not** abort the run; the runner proceeds regardless.
**Repro:** Run from a directory with no `.claude/agents` → "Pre-flight: 0 project agent(s) …" printed, run still proceeds.
**Source:** 112–139.
**Classification:** **SCAR.** Born of a silent-failure incident (agents resolve relative to cwd). The *non-aborting* nature is itself characterized behavior — a rewrite that turns this into a hard gate is a behavior change, not a faithful port. `preflight.log` is overwritten each run (vs. `incidents.log` which appends).

---

## 12. Model selection

### BC-32 — Label-driven model with `opus`→`opus[1m]` upgrade and deliberate `sonnet` non-upgrade
**Assertion:** The model is read from a `model:<X>` label on the task (via `bd label list` + `jq`), defaulting to `DEFAULT_MODEL` (`opus[1m]`). A bare `model:opus` is upgraded to `opus[1m]` (the 1M-context variant; bare `opus` is the 200K alias). `sonnet` and `sonnet[1m]` are **left exactly as-is** — `sonnet[1m]` deliberately not auto-selected because it requires "extra usage" which this org has disabled. Consequence: a `model:sonnet` task runs on the 200K window (this is *why* the CONTEXT_OVERFLOW salvage guidance tells agents to relabel `model:opus`).
**Repro:** Label a task `model:opus` → it runs `opus[1m]`. Label `model:sonnet` → runs `sonnet` (200K), not upgraded. No label → `opus[1m]`.
**Source:** 564–570; interacts with BC-19 (854–858).
**Classification:** **SCAR.** Both the silent `opus→opus[1m]` upgrade and the deliberate refusal to touch `sonnet` encode org-billing and window-size lessons; a rewrite that "helpfully" upgrades sonnet breaks under the disabled-extra-usage constraint.
**Finding (edge, beyond seed):** If a task carries **multiple** `model:` labels, the `jq` emits one per line and `TASK_MODEL` becomes a newline-containing string passed verbatim to `claude --model` — undefined/broken behavior. The current script has no first-match guard here. Characterized as-is, not proposed for fix.

---

## 13. Graceful stop & usage gating

### BC-33 — Graceful stop is detected promptly even during a 30-minute usage sleep
**Assertion:** `touch .stop-beads` stops the runner *after the current task finishes*. The usage-over-threshold wait does **not** `sleep` for the full `USAGE_SLEEP_SECONDS` in one call — it sleeps in 60s chunks, checking the stop file each chunk, and uses `break 3` to escape the chunk loop, the usage loop, **and** the main loop at once. So a stop request is honored within ≤60s even mid-usage-sleep (a naive single `sleep 1800` would make stop take up to 30 minutes). The stop file is also checked at the top of every main-loop iteration and is removed at startup (clean slate) and on detection.
**Repro:** Push the runner over the usage threshold (long sleep); `touch .stop-beads`; it exits within ~60s, not 30min.
**Source:** 71–72 (startup rm), 527–534 (top-of-loop check), 537–551 (chunked sleep + `break 3`).
**Classification:** **SCAR.** The chunked-sleep + `break 3` is a direct responsiveness fix; collapsing it to one `sleep` re-introduces the 30-minute-to-stop bug. **SCAFFOLDING:** `break 3` level-count is bash-loop-nesting mechanism.

### BC-34 — Usage check posture is fail-OPEN on every credential/API error, with a TTL cache
**Assertion:** The usage gate (`USAGE_THRESHOLD`, default 70; `0` disables entirely) reads an OAuth token from the macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`) and calls the Anthropic OAuth usage API. **Every** failure mode — keychain unreadable, no token, `curl` failure — returns "ok to proceed" (**fail-OPEN**) with a stderr note; a usage-check outage must never halt task processing. The result ("over"/"ok") is cached to a tempfile for `USAGE_CACHE_SECONDS` (default 300) to avoid hammering the API every loop. Over-threshold (either the 5-hour OR 7-day window's integer-truncated utilization ≥ threshold) → pause and re-poll every `USAGE_SLEEP_SECONDS`. Cache TTL is force-expired (`USAGE_CACHE_TIME=0`) after a sleep and after a `RATE_LIMIT` so the next check is fresh.
**Repro:** Break keychain access → runner logs "Could not read credentials … skipping" and proceeds. Set threshold 0 → no usage calls at all.
**Source:** 164–235 (`check_usage`), 537–539 (force-fresh after sleep), 832 (force-fresh after rate-limit).
**Classification:** **SCAR (posture).** Fail-open is the load-bearing decision (the alternative — fail-closed — would let a credential hiccup silently stop all work). The TTL cache is a tuned anti-hammer measure. **SCAFFOLDING:** macOS-Keychain extraction is platform-specific mechanism; a rewrite needs an equivalent credential source but must preserve fail-open.

---

## 14. Interrupt cleanup & the EXIT-trap gap

### BC-35 — `INT`/`TERM` resets the in-flight task to `open` and does not strand it
**Assertion:** On `SIGINT`/`SIGTERM` the `cleanup()` trap: kills the live `claude` PID (and waits), and **if a task is currently in flight** resets it via `bd update --status=open` ("Interrupted — resetting <id> to open"), runs `runner_cleanup`, removes the usage cache + signal file, prints results, and exits 1. `CURRENT_TASK_ID` is set when a task starts (601) and cleared after it finishes (923), so the reset fires only for a genuinely-in-flight task.
**Repro:** `Ctrl-C` mid-task → that task's status is `open` (not stranded `in_progress`), exit code 1.
**Source:** 145–162, 601 / 922–923.
**Classification:** **SCAR.** Ctrl-C must not strand the active task as a phantom `in_progress` (which would later masquerade as a crash orphan / be invisible to `bd ready`).

### BC-36 — `runner_cleanup` runs on interrupt and fatal exits but NOT on normal completion (asymmetry)
**Assertion:** `runner_cleanup` (the project hook) is invoked from `cleanup()` (INT/TERM, 157) and before the three fatal exits (AUTH 803, BILLING 817, breaker 914). It is **not** invoked on the normal/graceful path (queue drained or stop file → `break` → fall off end at 927–930). There is **no `EXIT` trap**, so an abrupt `set -e` abort also runs no cleanup at all.
**Repro:** Define a noisy `runner_cleanup` in `.beads/runner.sh`; let the queue drain normally → `runner_cleanup` does *not* run. Ctrl-C → it does.
**Source:** 50–52, 145–162, 803/817/914, 927–930 (no cleanup on normal end), 162 (`trap … INT TERM` only — no EXIT).
**Classification:** **SCAR (as a characterized hazard).** Documenting current behavior factually: cleanup coverage is asymmetric and an unguarded `set -e` failure leaks. This is *behavior the rewrite must consciously decide about*, not silently inherit — flagged here precisely because a faithful port would carry the gap forward unexamined.

---

## 15. Config seam

### BC-37 — Per-project override seam: `.beads/runner.sh`, hooks, env vars, `--yolo`
**Assertion:** The runner is configurable without editing the script:
- If `.beads/runner.sh` exists it is `source`d after defaults, able to override `PERMISSION_FLAGS`, `EXTRA_CLAUDE_FLAGS`, `PROMPT_EXTRA`, all `MAX_*`/`USAGE_*`/`IDLE_TIMEOUT`/`LOG_*`/`DEFAULT_MODEL` values, and define `runner_setup`/`runner_cleanup` hooks (no-ops by default; `runner_setup` runs once after preflight, `runner_cleanup` per BC-36).
- `MAX_RETRIES`, `MAX_CONSECUTIVE_FAILURES`, `DEFAULT_MODEL`, `USAGE_*`, `IDLE_TIMEOUT`, `LOG_RETENTION_DAYS` are also plain env-overridable (`${VAR:-default}`).
- Default `PERMISSION_FLAGS` = `--permission-mode acceptEdits` + a hand-curated `--allowedTools` allowlist (git/bd, git-recoverable file ops, read/inspect utils, text processing, env checks, curl/python for skills).
- First arg `--yolo` replaces the allowlist with `--dangerously-skip-permissions` and relabels the run "all permissions bypassed".
- `PROMPT_EXTRA`, if set, is appended to the worker prompt.
**Repro:** Drop a `.beads/runner.sh` setting `MAX_RETRIES=5` and a `runner_setup` that echoes → both take effect. Pass `--yolo` → "Running: all permissions bypassed".
**Source:** 18–69 (defaults, config source, yolo), 143 (`runner_setup`), 626–631 (`PROMPT_EXTRA`).
**Classification:** **SCAR.** The scoped-default allowlist encodes "these tools are safe / git-recoverable" judgements; the `--yolo` escape hatch and the source-able config seam are deliberate product surface. The specific allowlist contents are tuned policy (SCAR), not incidental.

---

## 16. Worker prompt

### BC-38 — Worker prompt forbids human-in-the-loop and prescribes debrief-then-close
**Assertion:** The prompt handed to each `claude` session: states it is running non-interactively; **explicitly forbids `EnterPlanMode`/`ExitPlanMode` and `AskUserQuestion`** ("there is no human to approve plans / answer"); instructs "just execute the work directly"; instructs the agent to follow the task description exactly; and requires, **before** closing, a debrief note via `bd update <id> --append-notes="<debrief>"` (what was done, difficulties, unexpected behavior, timing if notable, uncertainties, follow-ups — "be honest, this is for the human reviewing later"), then `bd close <id>`. Task ID/title/description are substituted into the template by literal string replacement.
**Repro:** Inspect the prompt for any task: contains the no-plan/no-ask prohibition and the debrief-then-close instruction.
**Source:** 604–631.
**Classification:** **SCAR (current behavior).** The no-plan/no-ask rule and the mandatory honest debrief are deliberate and load-bearing for unattended runs and for human review.
**Flag (context change, characterized — not designed here):** This behavior's *premise* — "there is no human, ever" — is precisely the assumption whose context changes in the planned rewrite (an async human is reachable via a different channel). Per scope, the replacement is **not** designed here; this entry documents the current behavior factually and marks it as the explicit place where the rewrite's context diverges. **SCAFFOLDING (mechanism):** the heredoc + `${VAR//BEADS_ID/…}` token substitution is a brittle templating artifact (a literal `BEADS_ID` occurring in a task description would be wrongly substituted; substitution is global) and must not be ported as-is.

---

## 17. Implementation scaffolding inventory (must NOT be ported faithfully)

These are bash/CLI artifacts. Their *intent* may be a scar (cross-referenced); the *mechanism* must be rebuilt idiomatically, not transcribed.

### BC-39 — stdout+stderr are merged into one stream file by design
**Assertion:** `claude` is launched with `> "$STREAM_FILE" 2>&1` — stderr (SDK HTTP-retry state) is deliberately interleaved into the same file the parser/classifier read. The watchdog's SIGINT-before-SIGKILL (BC-22) exists specifically so this stderr flushes before the kill.
**Source:** 642–648, 744–746.
**Classification:** **SCAR (intent: stderr must be captured & classifiable) / SCAFFOLDING (mechanism: shell fd redirection into a tail-`-f`'d tempfile).**

### BC-40 — Signal-file IPC between parser/watchdog and classifier
**Assertion:** The stream-parser subshell and the watchdog communicate failure signals to the classifier by **appending lines to a shared tempfile** (`SIGNAL_FILE`), which `classify_failure` greps *after* both background jobs are joined. `ACTIVITY_FILE` is a single-value tempfile overwritten by the parser and read by the watchdog (benign timestamp race). Markers accumulate (`>>`); the ordered grep (BC-10) is what disambiguates.
**Source:** 651–717 (parser appends), 730 (watchdog appends `WATCHDOG_KILL=1`), 762–771 (join then classify).
**Classification:** **SCAR (intent: capture-then-classify with a strict happens-before — classify only after the process exits and background jobs are joined) / SCAFFOLDING (mechanism: tempfile-as-IPC, `tail -f` subshell, `pkill -P` to reap the orphaned `tail` child, `sleep 1` to let final lines flush).**

### BC-41 — `RESULT_IS_ERROR=` is written to the signal file but never consumed from it
**Assertion:** The parser writes `RESULT_IS_ERROR=<bool>` to the signal file for every `result` event (695), but `classify_failure` never reads `RESULT_IS_ERROR` from the file — the `is_error` value is only used *inline within the parser subshell* to gate `CONTEXT_OVERFLOW` detection (704). The signal-file `RESULT_IS_ERROR=` line is effectively dead data.
**Source:** 695 vs. 315–353 (classifier never greps `RESULT_IS_ERROR`).
**Classification:** **SCAFFOLDING.** Dead/vestigial output; a rewrite must not preserve it as if load-bearing. (Flagged for honesty; not a behavior with external effect.)

### BC-42 — Pervasive fail-open guards (`|| true`, `2>/dev/null`) under `set -euo pipefail`
**Assertion:** Nearly every `bd`/IO call is wrapped so its failure cannot abort the runner (`… 2>/dev/null || true`, `|| echo "[]"`, etc.). The operating posture is: a `bd`/network/IO hiccup degrades gracefully (skip/assume-success/proceed) rather than crashing the loop.
**Source:** throughout (e.g. 155, 243, 254, 281, 290, 321, 363, 401, 444, 587, 602, 766–768).
**Classification:** **SCAR (posture: tolerate transient infra failure, never crash the runner on it) / SCAFFOLDING (mechanism: shell error-suppression idioms).** A rewrite must preserve the *posture* explicitly (typed error handling), not by blanket exception-swallowing.

---

## 18. Additional findings beyond the seed list

Confirmations/corrections and net-new behaviors discovered in the line-by-line pass (also summarized in the bd debrief note):

- **BC-04 race scoping (correction/sharpening of seed #2):** the status-recheck closes the *status-changed* race only; the *two-runners-one-orphan* race is residual and unguarded. Seed wording was imprecise; corrected here.
- **BC-09 (sharpening of seed #5):** empty `bd show` status fails **open to SUCCESS** with an explicit stderr note — not merely "default to success" silently.
- **BC-14 (sharpening of seed #6/#8):** the consecutive breaker is advanced *only* by the generic branch *and only for a distinct task*, and reset *only* by SUCCESS — so a multi-task CONTEXT_OVERFLOW storm never trips it. This is more specific than the seed's "generic failures count toward consecutive breaker only if task differs".
- **BC-16 (new):** retry/breaker counting is coupled to `bd ready` ordering ("same task = same `.[0]` pick"), not wall-clock immediacy.
- **BC-21 / BC-36 (new):** **no `EXIT` trap.** Cleanup is asymmetric — runs on INT/TERM and the three fatal exits, *not* on normal/graceful completion, and *not at all* on an unguarded `set -e` abort (which would strand `CURRENT_TASK_ID` `in_progress`). Characterized as a current hazard the rewrite must consciously decide about.
- **BC-28 (new edge):** `PROC_SNAPSHOT` retention keys on final *classification* `== WATCHDOG_KILL`, not on *whether the watchdog fired* — a watchdog kill that classifies as `SERVER_ERROR` (more-decisive earlier signal) discards the proc snapshot.
- **BC-31 (sharpening of seed #15):** preflight is **diagnostic-only and non-aborting** — `0` agents still proceeds. A rewrite that hard-gates on this is a behavior change.
- **BC-32 (new edge):** multiple `model:` labels on one task produce a newline-containing `--model` argument (undefined/broken). No first-match guard exists.
- **BC-36 (new):** `runner_cleanup` does **not** run on normal completion (only INT/TERM + fatal exits).
- **BC-41 (new):** `RESULT_IS_ERROR=` written to the signal file is dead data (consumed only inline in the parser, never from the file by the classifier).
- **TASK_NOT_CLOSED gate timing (confirmation of seed #5 nuance):** the class's own `LAST_FAILED_ID` retry-once gate (escalate on 2nd consecutive occurrence) fires *before* the top-of-loop `MAX_RETRIES` gate would (which needs `FAIL_COUNT >= 2`, i.e. a 3rd pick) — so for TASK_NOT_CLOSED the effective escalation is "2nd occurrence", exactly as the source comment (870–872) claims. Confirmed.
- **`bd close` with no children counted as cost-free (confirmation/extension of seed #3):** the validate-fail path (blocked OR parent) is a bare `continue` — no `FAILED++`, no `LAST_FAILED_ID`, no breaker effect. Skipped tasks are entirely free w.r.t. retry/breaker accounting. Confirmed and made explicit (BC-06/BC-08).

---

## Conformance checklist (what the rewrite's gate must assert)

A rewrite passes this contract iff, for every **SCAR** entry above, an equivalent observable behavior is demonstrable by its black-box repro, **and** for every **SCAFFOLDING** entry the mechanism is *not* transcribed (re-implemented idiomatically, with the cross-referenced scar intent preserved where noted). The exit-code table (BC-21), the LOG_DIR security boundary (BC-27), the classification precedence (BC-10/BC-11), and the per-class retry asymmetry (BC-13/BC-14) are the highest-risk regressions — they are silent when wrong.
