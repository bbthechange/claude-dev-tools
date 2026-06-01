# Behavioral Conformance Contract — `run-beads-tasks.sh`

> **Status:** Pre-rewrite characterization. READ-ONLY. This document describes the
> *current observable behavior* of `beads-runner/run-beads-tasks.sh` exactly as it
> exists today (**2603 lines**, refreshed against the script at this commit). It
> contains **no design, no architecture, and no proposals.** It is the gate the
> planned rewrite must pass: every item marked **SCAR** is a behavior that encodes
> a production failure lesson and must survive (semantically — not necessarily
> line-for-line); every item marked **SCAFFOLDING** is a bash/CLI implementation
> artifact that must *not* be ported faithfully (re-implement idiomatically;
> copying it forward is cargo-culting).
>
> **Refresh note (history, not a behavior):** the first cut of this contract was
> written 2026-05-15 against a 930-line script (commit `7b47437`). The script has
> since ~quadrupled to 2603 lines across ~40 commits (idle-on-empty-queue,
> `RUNNER_NO_CLAIM_LABELS` gate, watchdog Task-awareness, `POST_TERMINAL_GRACE`
> SIGKILL backstop, process-group subshell isolation + EXIT-trap reap, mid-task
> heartbeat, lease/capacity/desired-state seams, `select_workable_task`
> anti-starvation, `detect_worker_stuck_primary` + the ask-brian/dossier spine,
> `post_close_audit`, Node-v25 PATH prime, …). A prior refresh (against a
> 2477-line cut) added **BC-43…BC-65** for behavior introduced since the 930-line
> original. **This revision (claude-tools-c8c) re-verifies every entry's `file:line`
> ref against the current 2603-line script.** The +124-line net drift to the prior
> (2477→2601) cut came from four commits (per-commit insertion counts shown): `uxg8` (cross-WS scope check, +81 → BC-08d),
> `zfxe` (honest capacity-deny diagnostics, +34 → BC-34/BC-49), `2fkp` (shared
> `build-settings.sh` for the close-hook `--settings`, +26 → BC-65/BC-43), and
> `m0yv` (gate-wait discipline in the worker prompt, +5 → BC-38); a **final +2** came
> from `02ec` (a worker-prompt commit-discipline mandate inserted at current lines
> 1798–1799 → BC-38), shifting **every `file:line` ref ≥ 1798 by +2**. All prior BC-IDs
> are preserved for referential stability; assertions were re-confirmed against the
> code (only BC-36's embedded numbers were stale, now corrected), and the ≥1798 refs
> were re-derived against the 2603-line script via an 8-way independent re-verification
> (one read-only agent per BC cluster) with **0 assertion regressions** (see §22).
>
> Classification key:
> - **SCAR** — observable behavior born of a real failure. Losing it re-learns the lesson in prod.
> - **SCAFFOLDING** — mechanism dictated by bash/CLI limits. The *intent* may be a scar; the *mechanism* must be rebuilt, not transcribed.
> - **SCAR (intent) / SCAFFOLDING (mechanism)** — used where the behavior must survive but the specific implementation must not.
> - Variants **SCAR (security)** / **SCAR (posture)** mark containment boundaries and fail-open postures.
>
> Each entry: **Assertion** (testable, black-box) · **Repro** (how to trigger without reading source) · **Source** (file:line) · **Classification** + one-line justification.
>
> **One pattern pervades the current script and the synthesizer must read it into every "seam" entry below:** nearly every reach toward the distributed system
> (`lease`, `la_*` capacity/heartbeat, `co_request` desired-state, `sr_*` stuck-routing, `dg_*` dossier, `no_emit` notification) is wrapped in `command -v X >/dev/null 2>&1 || return 0` (or an equivalent `declare -F` guard). **A bare `bash run-beads-tasks.sh` with none of those libs present runs fully standalone and fail-open**: it leases-as-proceed, capacity-as-proceed, treats desired-state as `running`, idles on drain forever, and skips all ask-brian/inventory/feedback/dossier work. `ASK_BRIAN_ENABLED` (default `0`) is the master kill-switch for the entire stuck/dossier/ask-brian spine. This standalone-degradation posture is itself a SCAR (BC-43) and is the implicit fallback clause of every seam entry.

---

## 1. Core invariant

### BC-01 — Fresh process + fresh context per task
**Assertion:** Every task is executed by a brand-new `claude -p` process invocation. No conversation, context, or memory carries between tasks. There is no `--continue`/`--resume`; a task that fails and is retried starts from an empty context window the next time.
**Repro:** Queue two tasks. Observe two distinct `claude` PIDs; the second has zero knowledge of the first's conversation.
**Source:** lines 1–3 (header intent); 1893–1904 (per-task `claude -p` spawn inside the main loop).
**Classification:** **SCAR.** This is the entire reason the runner exists — to defeat autocompact drift by never sharing a context window across tasks. A rewrite that pools/threads context across tasks defeats the tool's purpose.
**Note (doc drift, not a behavior change):** The header comment still says "clean 200k context window" but `DEFAULT_MODEL=opus[1m]` (line 63, 1M window). The invariant is *fresh context per task*, independent of window size. The one deliberate exception that prepends prior state is the I4 resume splice (BC-55) — a single human answer, not a prior conversation.

---

## 2. Task selection & orphan recovery

### BC-02 — Startup in_progress snapshot = crash orphans; later in_progress = other agents
**Assertion:** Tasks that are `in_progress` *at script startup* are treated as orphans from a previous crashed run and are eligible for resumption. Tasks that become `in_progress` *after* startup are assumed owned by another agent and are never adopted (they are not in `ORPHANED_IDS`).
**Repro:** Set a task to `in_progress`, start the runner → it resumes that task. While the runner is running, set a *different* task `in_progress` → the runner ignores it.
**Source:** 651–657 (startup snapshot), 660–682 (`next_task` drains orphans before `bd ready`).
**Classification:** **SCAR.** Crash recovery — without it, a crashed run permanently strands its in-flight task as `in_progress` (invisible to `bd ready`, never retried).

#### BC-02a — Adoption is PID-claim-validated (claude-tools-uxc1, Mechanism A, inbox-lifecycle §8.3.3)
**Amendment to BC-02.** "in_progress at startup ⇒ crash orphan" is too coarse: a task is also `in_progress` when a LIVE external Claude session, another LIVE runner in the same workspace, or a manual `bd update` set it. Adopting those is the duplicate-work / commit-fight hazard (the residual BC-04 flagged, amplified by parallel runners). The runner therefore stamps a per-task **PID claim file** under `LOG_DIR/claims/<id>.json` (`{runner_id, pid:$$, host, started_at, workspace}`) at the `in_progress` write, and removes it on close / failure-reset / teardown (the same three sites as the lease release + the `current-task` pointer). The startup snapshot adopts an in_progress bead into `ORPHANED_IDS` **only** when its claim proves it is THIS workspace's runner's crash orphan:
- **no claim file** → set by a non-runner (interactive / manual) → **SKIP**;
- **our `runner_id` + LIVE pid** (`kill -0`) → a live sibling runner owns it → **SKIP**;
- **a FOREIGN `runner_id`/`workspace`** → another runner → **SKIP** (default-closed; the cross-workspace coordinator-liveness refinement is a §8.3.3 follow-up);
- **our `runner_id` + DEAD pid** → our previous self crashed here → **ADOPT** (instant, no age heuristic).

**Read-only walk:** the snapshot never deletes a claim (deleting would strand the one-per-loop-drained orphans 2..K, BC-04, with no claim if a second crash hit before re-claim). A resumed orphan's stale dead-pid claim is retired when it is actually re-claimed (`write_task_claim` overwrites it with the live pid) or by `LOG_RETENTION_DAYS` rotation. **Write ordering:** the claim is stamped BEFORE the `in_progress` write (it is pid-keyed, not status-keyed), so a crash in that window leaves the bead `open` (recoverable via `bd ready`), never `in_progress`-with-no-claim (which the walk would skip → strand). **PID reuse:** an alive-but-recycled pid resolves to SKIP (safe direction); the `started_at`/`ps -o lstart` disambiguation is the §8.3.3 stretch goal — recorded in the claim, not yet consulted. **Residuals:** (a) a claim for a bead a human closed out-of-band then re-`in_progress`ed interactively can false-adopt — that interactive case is Mechanism B's (`human-live-session` label gate) job (A+B+C are layered by design); (b) the DEGRADED class keeps the bead `in_progress` and its claim so a future runner re-adopts it once this runner's pid dies.
**Source:** runner.sh `_adopt_orphan_by_claim` / `write_task_claim` / `remove_task_claim`; st_starting snapshot walk; st_claim write; st_post_task / `_terminal_fatal` / `runner_teardown` removal.
**Conformance:** `conformance/assertions/bc-uxc1-claim-validated-adoption-tree.sh` (the no-claim/live/foreign/dead matrix + claim lifecycle); `bc-orphan-recovery-tree.sh` now plants the leftover dead-pid claim each crash orphan would have.
**Classification:** **SCAR.** Without it the runner adopts externally-owned in-flight work.

### BC-03 — Empty-orphan-list guard
**Assertion:** When there are no `in_progress` tasks at startup, the runner does **not** attempt `bd show ""`. It proceeds straight to `bd ready`.
**Repro:** Start the runner with zero `in_progress` tasks; no spurious `bd show` with an empty ID occurs.
**Source:** 655–657. `read -ra` on empty input yields a 1-element array `("")`; line 657 detects exactly that shape (`${#ORPHANED_IDS[@]} -eq 1 && -z "${ORPHANED_IDS[0]}"`) and resets to an empty array.
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The intent — "no orphans ⇒ skip orphan processing" — must survive. The `read -ra` empty-field quirk (`read` cannot distinguish "empty" from "one empty field") is a pure bash artifact; a rewrite with a real list type has no such hazard and must not transcribe this guard.

### BC-04 — One orphan resumed per loop iteration; status re-checked at resume time
**Assertion:** `next_task()` resumes **at most one** orphan per main-loop iteration (the first still-`in_progress` one), preserving the remaining orphans for subsequent iterations. Before resuming any orphan it re-queries `bd show` for that orphan's *current* status:
- still `in_progress` → resume it (emit its JSON), keep untouched orphans after it for later;
- status changed to anything else non-empty (e.g. another agent closed it) → **drop** it from the orphan list;
- `bd show` returns no parseable status → **keep** it for a later retry (a flaky `bd show` must not lose an orphan).
After the orphan list is exhausted, fall through to `bd ready` (or `[]` if that fails).
**Repro:** Seed three orphans A,B,C. Close B externally before the runner reaches it. Observe: A resumed loop 1; B silently dropped; C resumed a later loop. Make `bd show` fail transiently for A → A is retried on the next loop, not lost.
**Source:** 660–682 (esp. 668–679 status branch, 670–671 tail-preservation, 683–695 fall-through to epic-filtered `bd ready`).
**Classification:** **SCAR.** The re-check is a TOCTOU defense; the keep-on-bad-`bd show` and one-per-loop draining are deliberate.
**Precise scope of the race this closes (honest limitation):** The recheck closes the window where an orphan *no longer needs work* (closed/advanced by something else between the startup snapshot and the — potentially 30-minute, usage-gated — first loop). It does **not** by itself prevent two runners from both resuming the *same still-`in_progress` orphan* (both observe `in_progress`). **Update vs the original finding:** that residual two-runners-one-orphan race is now closed by the §6.1 lease binding (BC-48) when the `lease` seam is present — a global exclusive lease is acquired *before* the `in_progress` write, so the second runner's `lease acquire` fails. Standalone (no `lease` command) the race remains residual, exactly as before.

### BC-05 — Empty `bd ready`: idle-on-drain by default (UX §0.A), legacy exit-0 opt-in
**Assertion:** When no orphan and no workable ready task is available, the **default** behavior (UX §0.A) is to **idle**: print one "No more ready tasks — idling…" line (suppressed thereafter via `IDLE_NOTIFIED`), `hb idle`, poll on an interval, and pick up new ready work without an external respawn. `.stop-beads` and Coordinator `desired=stopped` end the runner cleanly within one poll interval. The legacy SCAR — drain ⇒ exit 0 — is opt-in via `RUNNER_EXIT_ON_DRAIN=1` (the conformance harness sets this so the BC-21 exit-code table is still exercised end-to-end).
**Repro (default):** Run with an empty/all-blocked queue and `RUNNER_EXIT_ON_DRAIN` unset → runner stays alive, logs `idling`, and picks up tasks added after the drain. **(legacy SCAR):** Same setup with `RUNNER_EXIT_ON_DRAIN=1` → runner prints "No more ready tasks." and exits 0.
**Source:** 1505–1566 (idle branch); legacy exit gate 1520–1525 and 1563; `IDLE_NOTIFIED` 1534/1537/1565; startup `.stop-beads` rm 329.
**Classification:** **SCAR.** The "drain ⇒ exit 0" path is the *outward* contract a coordinator depends on (BC-21) and must remain testable. The behavior Brian protects (UX §0.A: "Runner keeps running when out of tasks and picks tasks up once added.") is the *default* in production. Issue: claude-tools-giu. See BC-51 for the two-tier `SEL_RC` (genuine drain vs all-candidates-unworkable) this branch keys on.

### BC-51 — `select_workable_task`: skip past an unworkable `bd ready[0]` instead of starving the queue
**Assertion:** Selection is **not** a raw `.[0]` pick of `bd ready`. `select_workable_task()` walks the whole `next_task()` array in `bd ready` order and selects the **first** candidate that `validate_task` accepts, then narrows `TASK_JSON` to that single element so every downstream `.[0]` read is unchanged. It returns a three-valued code consumed by the idle branch (BC-05): **0** a workable bead was selected; **1** the ready set is genuinely empty (a real drain); **2** the ready set is non-empty but *every* candidate is unworkable. While scanning past an unworkable candidate it emits `hb idle` to keep actual-state warm. The all-unworkable case (`SEL_RC=2`) idles with a shorter `SKIP_BACKOFF` poll (default 30s) vs the genuine-drain poll (default `IDLE_POLL_INTERVAL` 60s).
**Repro:** Put one unworkable bead (a `RUNNER_NO_CLAIM_LABELS` task, a parent with open children, a late-blocked dep, or a stray epic) at `bd ready[0]` with workable beads below it → the runner builds the workable bead, not nothing. Leave only unworkable candidates → runner idles + re-polls instead of hot-spinning on `.[0]`.
**Source:** 866–886 (`select_workable_task`); idle two-tier poll 1527–1564.
**Classification:** **SCAR.** A single unworkable head was observed starving 39 skip-loops / 0 builds live on 2026-05-30 (the claude-tools-uxqj / claude-tools-dzc starvation class, generalized from epics to any unworkable head). The `hb idle` while-scanning is the claude-tools-g20 hot-spin/GUI-staleness guard.

### BC-52 — Epics are filtered from `bd ready` client-side (the `bd` flag is a no-op) plus a defense-in-depth skip
**Assertion:** `next_task()` excludes epics from the ready queue with a **client-side `jq` filter** (`select((.issue_type // .type // "") != "epic")`) because `bd v1.0.2`'s `--exclude-type=epic` flag is passed but does **not** actually filter (verified empirically 2026-05-24). `validate_task` independently skips epics again as defense-in-depth, accepting **both** `bd` JSON shapes (`bd show` wraps the object in a one-element array and names the field `issue_type`; `bd list` uses top-level `type`).
**Repro:** Put an epic at the top of `bd ready` → it is not selected and not executed (no "skipping parent" noise required — it's filtered before selection). Point `bd` at a version where the flag works → the client-side filter is harmless redundancy.
**Source:** 683–695 (query-layer filter), 738–753 (validate_task epic skip + dual-shape parse).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** "Never feed a container to an agent" is the scar; the `--exclude-type=epic` + redundant `jq` belt-and-suspenders compensates for a specific `bd` CLI quirk and must be re-verified against the real `bd` contract, not transcribed.

---

## 3. Workability validation (TOCTOU)

### BC-06 — `validate_task` re-checks `bd blocked` (deps added after `bd ready`)
**Assertion:** Even though the task came from `bd ready`, immediately before execution the runner re-queries `bd blocked`; if the task now appears blocked it is **skipped with no failure counted** (no `FAILED++`, no retry tracking, no circuit-breaker effect — a message then `return 1` → cost-free `continue` at the call site).
**Repro:** Between `bd ready` returning task X and the runner starting it, add a dependency that blocks X. Observe X skipped, not failed.
**Source:** 730–736 (blocked re-check); cost-free skip via `select_workable_task` (866–886) + idle/continue (1505–1566).
**Classification:** **SCAR.** Closes the TOCTOU window between the `bd ready` snapshot and execution.

### BC-07 — `bd show --children` self-inclusion is filtered out
**Assertion:** When checking whether a task is a parent/container, the task itself is excluded from its own children list before counting (`map(select(.id? != $id))`), and the `{<parent-id>: [children]}` object shape `bd` returns is flattened to just the children array; any `jq` error fails **closed** (treated as zero children).
**Repro:** A leaf task with no children must not be treated as its own parent. (Observable only as the *absence* of false "skipping parent task" on childless tasks.)
**Source:** 755–766.
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** Compensates for a `bd` CLI quirk (`--children` includes self, wraps in a keyed object). The compensation must survive *as long as `bd` behaves this way*; the `jq` filter is mechanism a rewrite must re-derive from the real `bd` contract.

### BC-08 — All-children-closed ⇒ auto-close the parent; otherwise skip it
**Assertion:** If a task has children and **all** are closed, the runner auto-closes the parent (`bd close --reason="All children completed"`) and skips it. If some children are still open, the parent is skipped with a "N of M children still open" message. Either way the parent is never executed and no failure is counted.
**Repro:** Create parent P with two children; close both; run with P ready → P is auto-closed. Leave one open → P is skipped, not run, not failed.
**Source:** 767–778.
**Classification:** **SCAR.** Prevents feeding a container task to an agent (nothing concrete to do) and prevents stale parents lingering after their work is done.

### BC-08b — `RUNNER_NO_CLAIM_LABELS` hard label gate (claude-tools-noj, claude-tools-tkf)
**Assertion:** As the **first** check in `validate_task` (before deps/epic/parent), the runner reads `bd label list <id> --json` and, if the task carries **any** label in `RUNNER_NO_CLAIM_LABELS` (default `human-live-session,human-triage,human-action`; comma-separated, surrounding whitespace stripped via `##`/`%%`), the task is **skipped with no failure counted** (same cost-free `return 1` as BC-06/07/08). The check runs every loop, so a runner cannot grandfather in a previously-claimed task by holding state; the gate is sticky across `bd` reloads because the runner never removes labels (only a human can). A project `.beads/runner.sh` may **extend** the gate (e.g. an FE-rooted workspace appending `backend`) via the env override.
**Repro:** Label a ready task `human-live-session` (or `human-triage`/`human-action`) → `bd ready` still surfaces it, but the runner prints `Skipping: label '<name>' present (RUNNER_NO_CLAIM_LABELS …)` and continues; the bead stays open for Brian to claim from his phone.
**Source:** config default 68–86; gate 703–728 (runs ahead of deps/epic/parent).
**Classification:** **SCAR.** Closes the failure class proved by claude-tools-240 (four consecutive `TASK_NOT_CLOSED` cycles in one night re-claiming a one-shot live-session fixture) and the tkf class (FE sessions auto-claiming `backend`/`human-action` work). Description text + priority + status/defer flips were all ignored under load; only a labelled refusal is durable. The gate sits **before** dependency/epic checks so a gated task with open deps is skipped silently rather than logging "blocked" noise.

### BC-08d — cross-workspace scope check (claude-tools-uxg8, GAP G8)
**Assertion:** As the **last** check in `validate_task` (after deps/epic/parent — the bead is otherwise claimable by here), the runner flags a bead whose **title or description references a cross-repo id**: a `<sibling-prefix>-<shortid>` token whose prefix is one of `RUNNER_SIBLING_PREFIXES` (comma-separated, default **empty**) and is not the bead's own (local) prefix. A flagged bead is **skipped with no failure counted** (same cost-free `return 1` as BC-08b) and a loud, actionable line is printed naming the cross-repo id — it is **flagged, not silently claimed** by the wrong workspace's runner. A bead carrying any label in `RUNNER_TRACKING_ONLY_LABELS` (default `tracking-only`) is **exempt** — a coordination/tracking bead is meant to reference sibling ids. With `RUNNER_SIBLING_PREFIXES` empty (the single-repo default) the check is a **complete no-op** (no `bd` calls, behaviour unchanged). The local prefix is derived from the bead's own id (`${task_id%-*}`), so no extra config identifies "us". The token matcher uses a left word-boundary so ordinary hyphenated prose (`read-only`, `skip-not-fail`) and own-prefix refs are never false-positives. Like BC-08b the flag is sticky across `bd` reloads (the runner never edits labels) and, per the uxqj starvation contract, a flagged bead at `ready[0]` does not starve a workable bead below it.
**Repro:** In a workspace declaring `RUNNER_SIBLING_PREFIXES=thirsty-be`, file a ready bead whose description says "FE side of thirsty-be-12f" → `bd ready` still surfaces it, but the runner prints `Skipping: references cross-repo id 'thirsty-be-12f' (workspace-scope check …). Not claimed.` and continues; the bead stays open for a human to re-home or label `tracking-only`. Add the `tracking-only` label → it is claimed normally with a `Note:` line instead.
**Source:** config default 87–107; check at the tail of `validate_task` (780–838, after the parent/epic gate, before `return 0`). Design: UX-DESIGN-V2.md §8.5 / design/cross-ws.md §2.4. Conformance: `conformance/assertions/bc-xws-scope-check.sh`.
**Classification:** **SCAR.** Closes the silent-misclaim hazard §8.5 names ("why is there a backend task in the frontend tracking") — a FE runner silently claiming a bead whose code lives in the BE repo burns a worker + per-dossier spend and bails with nothing written. Amplified by parallel FE/BE runners. (BC-08c is reserved for J4 gate-respect, gates.md §5.2.)

---

## 4. Failure classification

### BC-09 — Exit 0 ≠ success; truth is `bd` task status
**Assertion:** A `claude` exit code of 0 is **not** trusted as success. `classify_failure` (the signal-file classifier) queries the task's `bd` status:
- `status == closed` → `SUCCESS`;
- status empty (`bd show` failed/unreadable) → `SUCCESS` (explicit **fail-open**, with a stderr note "Could not verify task status — assuming success");
- any other status (open/in_progress) → `TASK_NOT_CLOSED` (a distinct class, not generic failure).
The class→action **dispatch** on this string lives in the main loop (BC-13/BC-21 region).
**Repro:** Make the agent exit 0 without calling `bd close` → classified `TASK_NOT_CLOSED`, not success. Make `bd show` fail on an exit-0 task → classified `SUCCESS` (fail-open).
**Source:** 897–907 (exit-0 branch; fail-open stderr echo at 902); consumed at 2285.
**Classification:** **SCAR.** Agents routinely exit 0 having "finished" without closing the issue; trusting exit code would silently mark incomplete work done. The fail-open-on-empty-status is itself a deliberate scar (a `bd` outage must not convert every success into a phantom failure).
*(Stale-comment note, not a behavior: a comment now at line 1267 inside `post_close_audit` still cites "line 743" for this fail-open; the actual echo is now line 902.)*

### BC-10 — Classification order is correctness, not cosmetics
**Assertion:** A single session can append **multiple** signal markers to the signal file (e.g. a transient `rate_limit` api_retry followed by a terminal context overflow). On non-zero exit, `classify_failure` scans them with **anchored greps** (`^MARKER=`) in a fixed precedence and returns the **first match**, deliberately ordered most-decisive/terminal first:
`AUTH_FAILURE → BILLING_ERROR → CONTEXT_OVERFLOW → MAX_OUTPUT_TOKENS → SERVER_ERROR → WATCHDOG_KILL → RATE_LIMIT → UNKNOWN_FAILURE`
where `MAX_OUTPUT_TOKENS` matches any of three markers: `MAX_OUTPUT_TOKENS=`, `RESULT_STOP_REASON=max_tokens`, `RESULT_STOP_REASON=length`. No match (or an absent signal file) ⇒ `UNKNOWN_FAILURE`.
**Repro:** Produce a session that emits a `rate_limit` api_retry and then overflows context. It must classify `CONTEXT_OVERFLOW` (terminal), not `RATE_LIMIT` (which would retry forever).
**Source:** 914–930 (ordered greps in `classify_failure`); marker emission in the parser at 1945–2011 (esp. 1956–1968 api_retry, 1994–2011 result).
**Classification:** **SCAR.** Reordering these silently changes behavior from "stop/escalate" to "retry forever" for any multi-signal session. The order *is* the logic. **(Sharpening vs the original entry:** `SERVER_ERROR` sits **after** the full `MAX_OUTPUT_TOKENS` triple; the eight output classes and their order are confirmed.)

### BC-11 — Context overflow ("Prompt is too long") is a first-class terminal class
**Assertion:** An API context overflow surfaces as an **errored result** (`is_error=true`) whose `stop_reason` is `stop_sequence` (NOT `max_tokens`/`length`) and whose result text matches `prompt is too long` or `context_length_exceeded` (case-insensitive). The parser pattern-matches this **guarded by `is_error==true`** (so a normal summary that quotes the phrase is not misclassified) and emits `CONTEXT_OVERFLOW=1`. Classification places `CONTEXT_OVERFLOW` *before* `MAX_OUTPUT_TOKENS`. Without this explicit pattern-match the failure has no token stop-reason match, falls through to `UNKNOWN_FAILURE`, and is retried — each retry re-overflowing deterministically at the same point.
**Repro:** Give a task a prompt/description large enough to exceed the model window. Confirm: result `is_error=true`, `stop_reason=stop_sequence`, text "Prompt is too long"; classified `CONTEXT_OVERFLOW`; **not** retried (goes straight to an analysis child — see BC-17).
**Source:** 920–922 (ordering in classifier), 2008–2010 (parser pattern-match + `is_error` guard).
**Classification:** **SCAR.** A documented, specific production incident (infinite identical re-overflow). The `is_error` guard is also a scar.

### BC-12 — `max_output_tokens` arrives via two independent paths
**Assertion:** `MAX_OUTPUT_TOKENS` is detected whether the limit surfaces as a `system`/`api_retry` event with `error=max_output_tokens` (parser emits the `MAX_OUTPUT_TOKENS=` marker directly), or as a `result` event with `stop_reason` of `max_tokens` or `length` (parser emits `RESULT_STOP_REASON=…`, which the classifier translates). All three collapse to the single class `MAX_OUTPUT_TOKENS`.
**Repro:** Trigger output-token exhaustion via each path; both classify identically.
**Source:** 1967 (api_retry path), 2000 (result-stop-reason path), 922–924 (classifier collapse).
**Classification:** **SCAR.** The dual path is a real observation about how the SDK reports the same condition; collapsing one path loses detections.

---

## 5. Retry / circuit-breaker semantics

### BC-13 — Per-class retry asymmetry
**Assertion:** Different failure classes have deliberately different retry treatment at the dispatch `case`:
- **RATE_LIMIT:** task reset to `open`; `LAST_FAILED_ID` is **not** set, so the rate-limit attempt is *invisible to the per-task retry counter* (it does not consume a retry); sets `USAGE_CACHE_TIME=0` to force a fresh usage check next loop. No notification (routine).
- **CONTEXT_OVERFLOW / MAX_OUTPUT_TOKENS:** **skip retry entirely** — escalate straight to an analysis child, then `LAST_FAILED_ID=""`, `FAIL_COUNT=0` (retrying re-overflows identically).
- **TASK_NOT_CLOSED:** retry **once** (set `LAST_FAILED_ID`), then on the second consecutive occurrence create an analysis child.
- **Generic (SERVER_ERROR / WATCHDOG_KILL / UNKNOWN / fallthrough):** advances the consecutive-failure breaker **only if the task differs from the last failed task**, then records the task as last-failed.
- **Top-of-loop retry gate:** when the *same* task is re-picked, `FAIL_COUNT` increments; at `MAX_RETRIES` (default 2) the task is reset to `open`, an `exceeded_max_retries` analysis child is created, and counters reset.
**Repro:** Rate-limit a task 5×: never "exhausted". Overflow a task once: an analysis child appears immediately, no retry. Fail a task generically twice (same task): the 2nd does *not* advance the breaker; a 3rd pick hits `MAX_RETRIES`.
**Source:** 1618–1635 (top-of-loop `MAX_RETRIES` gate), 2459–2468 (RATE_LIMIT), 2470–2496 (overflow/max-tokens skip), 2498–2515 (task-not-closed retry-once), 2517–2529 (generic distinct-task breaker increment).
**Classification:** **SCAR.** Each asymmetry encodes a specific lesson: rate-limit retries are infinite-by-design and must not burn the retry budget; overflow retries are pure waste; "exited 0 but open" is usually a one-off "forgot `bd close`".

### BC-14 — Consecutive-failure circuit breaker counts *distinct* tasks only, resets on success
**Assertion:** The breaker (`CONSECUTIVE_FAILURES >= MAX_CONSECUTIVE_FAILURES`, default 3 → exit 2) is advanced **only** by the generic-failure branch, and **only when the failing task differs from the previously failed task**. It is reset to 0 **only on `SUCCESS`**. RATE_LIMIT, CONTEXT_OVERFLOW, MAX_OUTPUT_TOKENS, TASK_NOT_CLOSED, and STUCK (BC-53) do not advance it. Consequence: a storm of context overflows across many distinct tasks does **not** trip the breaker (each spawns an analysis child instead); the breaker specifically catches "many *different* tasks failing with generic/unknown errors" (its stated purpose, printed verbatim on abort: "Stopping to avoid closing healthy tasks as skipped").
**Repro:** Fail 3 *different* tasks with generic errors and no intervening success → runner stops, exit 2. Fail the *same* task 3× generically → breaker does *not* trip (the per-task `MAX_RETRIES` path handles it). Alternate fail/success → breaker never trips.
**Source:** 2517–2529 (distinct-task increment), 2414 (`SUCCESS` resets), 2544–2559 (breaker + rationale string), config default line 62.
**Classification:** **SCAR.** The "distinct task" and "reset on success" rules are precise and load-bearing; a naive "any failure increments" breaker would stop healthy runs on a single flaky task.

### BC-15 — A failed task is released to `open` (never left `in_progress`)
**Assertion:** Every non-success terminal handling resets the task with `bd update --status=open` (not `in_progress`), returning it to the `bd ready` pool. **The single exception is the deliberate-stuck path (BC-53):** a worker that intentionally set the bead `blocked`+`human` is left blocked-for-human, *not* reset to open.
**Repro:** Fail a task by any class; immediately observe its `bd` status is `open`. Trigger a deliberate stuck (exit 7 / blocked+human) → status stays `blocked`.
**Source:** 2426, 2444, 2462, 2473, 2485, 2501, 2520 (uniform `--status=open`); STUCK bypass 2407–2408.
**Classification:** **SCAR.** `in_progress` would make a just-failed task indistinguishable from work-in-flight / a future orphan. The §6.1 lease release (BC-48) pairs each `open` reset so the strong plane and the bead status stay bound.

### BC-16 — Retry timing is "next time this task is selected", not "immediately"
**Assertion:** A failed task reset to `open` re-enters the `bd ready` pool; it is *not* an orphan (orphans are snapshotted only at startup). Whether the failed task is retried on the very next iteration depends on `bd ready` ordering and workability — other higher-ranked workable tasks run first. The per-task retry counter therefore tracks "consecutive *selections* of the same task", which may be interleaved with other tasks.
**Repro:** Fail task X while higher-priority workable task Y is ready → Y runs next, not X; X's `FAIL_COUNT` does not advance until X is selected again.
**Source:** 1618–1635 (`LAST_FAILED_ID` equality gate), 651–657 (orphan snapshot is startup-only).
**Classification:** **SCAR.** Retry/breaker semantics are coupled to selection ordering, not wall-clock immediacy. **(Correction vs the original entry:** selection is no longer "always `.[0]` of `next_task()`" — `select_workable_task` (BC-51) picks the first *workable* candidate, orphans-first and epic-filtered, then narrows to one element. The FAIL_COUNT-tracks-consecutive-selections coupling is unchanged.)**

---

## 6. Exit codes — external contract

### BC-21 — Exact, distinct exit codes per terminal condition
**Assertion:** The runner's process exit code is a stable signal a supervisor can switch on:
| Exit | Condition | Source |
|------|-----------|--------|
| **0** | Normal end: queue drained with `RUNNER_EXIT_ON_DRAIN=1`, **or** graceful stop file consumed (`break`/`break 3`). Falls off the end of the script after the `while` loop. | 1429/1447/1525/1544/1551/1563/1612 (`break`), 2579–2603 (tail; no literal `exit 0`) |
| **1** | `SIGINT`/`SIGTERM` received → `cleanup()` trap. | 411–440 (`exit 1` 439) |
| **2** | Consecutive-failure circuit breaker tripped. | 2544–2559 (`exit 2` 2558) |
| **3** | `AUTH_FAILURE` (terminal). | 2423–2439 (`exit 3` 2438) |
| **4** | `BILLING_ERROR` (terminal). | 2441–2457 (`exit 4` 2456) |
**Repro:** Drive each condition; assert `$?`.
**Classification:** **SCAR.** These codes are an outward-facing contract — a coordinator distinguishing "stop everything, credentials are bad (3)" from "queue drained (0)" depends on them. Each terminal path also emits a matching `la_report_terminal_reason` telemetry record (BC-63).
**Correction (the original "no EXIT trap" finding is now WRONG):** There **is** a `trap _final_subshell_reap EXIT` (line 447) in addition to `trap cleanup INT TERM` (line 441). `_final_subshell_reap` (the subshell PG-reap, BC-44) runs on **every** exit path — clean drain, exit 2/3/4, after `cleanup`'s `exit 1`, *and* on an unguarded `set -e` abort. So the leaked-subshell hazard the original entry flagged is **closed**. What remains asymmetric is `runner_cleanup` (the project hook), not the EXIT trap — see BC-36. `WORKER_STUCK_EXIT=7` (line 108) is the **worker's** deliberate-stuck sentinel, never an exit code the *runner* process returns.

---

## 7. Watchdog

### BC-22 — Idle-stream watchdog with snapshot-before-signal and staged kill
**Assertion:** A background watchdog subshell polls every **15s** while the `claude` PID is alive (re-checks `kill -0` and breaks on a missing PID or on `.stop-beads`). "Idle" = seconds since the last *stream line* was parsed (the parser stamps `ACTIVITY_FILE` on every line; initialized at spawn). Behavior:
- `IDLE >= 180s` (hardcoded literal, not configurable): print a soft "No activity for Ns — possibly stuck" warning, keep waiting.
- `IDLE >= EFFECTIVE_TIMEOUT` (see BC-22 addendum; default 600s with no in-flight subagents): emit `WATCHDOG_KILL=1`; **before sending any signal**, snapshot the process — `ps -o pid,stat,etime,pcpu,pmem,command` and `lsof` filtered to `TCP|IPv|PIPE` (with a literal "(no matching fds)" fallback) into `PROC_SNAPSHOT` (lsof on a dying process returns nothing useful, so order matters); then **staged kill**: `SIGINT` first (gives the SDK a chance to flush in-flight HTTP-retry state to stderr, which is merged into the stream file), poll up to **10×1s**, then `SIGKILL` if still alive.
**Repro:** Make the agent hang silently (no stream output) for >600s. Observe: soft warning at ≥180s; at ≥`EFFECTIVE_TIMEOUT` a `PROC_SNAPSHOT` with ps+lsof captured *before* the process dies; `SIGINT` then (≤10s later) `SIGKILL`; classification `WATCHDOG_KILL`.
**Source:** 2058–2159 (loop; threshold 2129, soft warning 2156, snapshot 2137–2143, staged kill 2148–2153).
**Classification:** **SCAR.** Snapshot-before-SIGINT and SIGINT-before-SIGKILL are explicitly hard-won (post-mortem evidence is destroyed if you signal first; SDK retry state is only flushed on graceful interrupt). The 180s-vs-`EFFECTIVE_TIMEOUT` two-tier, the 15s poll, and the 10×1s grace are tuned values. **SCAFFOLDING:** the bash subshell/`kill -0` loop mechanism itself.
**Note:** "Idle" proxies "stuck" via *stream silence*; because stdout+stderr are merged (BC-39), even SDK retry noise counts as activity. A long single tool call that emits no stream lines looks idle — this is why the default timeout is a generous 600s.

### BC-22 addendum — Task-subagent-aware idle (claude-tools-idg)
**Assertion:** Task tool subagents are IN-API constructs inside the `claude` process; the parent stream goes byte-silent while it waits on the model. The watchdog maintains a live in-flight set as the **line count of `TASK_INFLIGHT_FILE`** (`wc -l`, default 0 when empty/absent), a file the parser maintains from `task_notification`/`task_updated` events (BC-60). When `inflight > 0` the effective kill threshold is `EFFECTIVE_TIMEOUT = IDLE_TIMEOUT × IDLE_TIMEOUT_INFLIGHT_MULT` (env-overridable, default 6 ⇒ 3600s on stock 600s). The kill is **stretched, not paused** — a genuinely deadlocked bg-Bash that registered as in-flight (the D5 2026-05-20 case) still dies eventually.
**Repro:** Emit a `task_notification status=in_progress`, then silence; observe NO kill at `IDLE_TIMEOUT`. Emit a terminal `task_updated`, then silence; observe the kill resumes at the unstretched `IDLE_TIMEOUT`.
**Source:** 2119–2129 (`EFFECTIVE_TIMEOUT` math); config 109/117; parser maintenance of `TASK_INFLIGHT_FILE` (BC-60).
**Classification:** **SCAR.** Stretch-not-pause is the load-bearing discipline — paused-on-inflight loses the backstop entirely.

### BC-59 — Post-terminal SIGKILL backstop (independent of idle) (claude-tools-td0y / t7i / krxv)
**Assertion:** The watchdog has a **second, independent kill trigger**. The parser stamps `POST_TERMINAL_FILE` once (idempotent `! -e` guard) on the first stream line containing `"terminal_reason"` or `"type":"result"`. On each 15s tick, *before* the idle check, the watchdog reads that stamp; if the process is still alive **`POST_TERMINAL_GRACE` (default 60s) after the SDK's terminal record**, it appends `POST_TERMINAL_KILL=1`, appends a children-of-claude snapshot to `PROC_SNAPSHOT`, and sends a **straight `SIGKILL`** (no SIGINT stage) and breaks. This is INDEPENDENT of `IDLE_TIMEOUT` and **cannot be masked by `IDLE_TIMEOUT_INFLIGHT_MULT`** — it targets a known-*completed* task whose Node process won't exit (the krxv incident: a `run_in_background:true` Bash poller keeps Node alive). Combined with the watchdog's own `kill -0` re-check it embodies the t7i "watchdog can outlive its claude child" defense.
**Repro:** Have the SDK emit its terminal record, then keep the process alive (e.g. an orphaned bg poller) >60s → straight SIGKILL, `POST_TERMINAL_KILL=1` marker, post-terminal proc snapshot appended.
**Source:** parser stamp 1936–1943; watchdog branch 2082–2099; config 127.
**Classification:** **SCAR.** A real wedge-recovery path; removing it re-introduces the krxv hang. The straight-SIGKILL (vs the idle path's SIGINT-first) is deliberate — the task is already contract-done, so there is no in-flight state worth flushing.

### BC-60 — In-flight tracking, per-line activity stamp, and the malformed-timestamp guard
**Assertion:** Three parser/watchdog mechanics underpin BC-22/BC-22-addendum/BC-59:
- **`ACTIVITY_FILE`** is overwritten with `date +%s` as the **first action for every stream line** (any byte = alive); seeded once at spawn.
- **`TASK_INFLIGHT_FILE`** holds one line per in-flight Task subagent: a `task_notification`/`task_updated` with status `in_progress` adds the `task_id` (`grep -qxF || echo >>`); any of `completed|stopped|killed|failed|cancelled` removes it (`grep -vxF` → `mv`). Single-writer (the one parser loop).
- **Epoch-floor guard (claude-tools-h7n):** every reader of a timestamp file (`watchdog idle`, `watchdog post-terminal`, `HB Mode A`) rejects a value that is not all-digits or `< 1704067200` (2024-01-01) and `continue`s, so a partial/empty read can't make `IDLE = now` (~56yr) and trigger an instant false-positive kill.
**Repro:** Race the watchdog against an empty `ACTIVITY_FILE` → the tick is skipped, not a spurious kill. Emit `task_notification in_progress` then `task_updated completed` → the inflight count rises then falls by one.
**Source:** `ACTIVITY_FILE` stamp 1914/1926; `TASK_INFLIGHT_FILE` 1913/1976–1989; epoch-floor guards 2109/2084/2200.
**Classification:** **SCAR.** The activity-on-any-byte liveness definition, the set-membership inflight tracking, and the epoch-floor guard are each direct fixes for a specific false-kill / missed-kill failure mode.

---

## 8. Analysis-task escalation

### BC-17 — Failed task is *blocked by* a fresh analysis child; infinite chains are guarded
**Assertion:** On the escalating classes (`exceeded_max_retries`, `MAX_OUTPUT_TOKENS`, `CONTEXT_OVERFLOW`, second `TASK_NOT_CLOSED`), `create_analysis_task` creates a new beads issue titled "Analyze failure: <title>", priority 1, labels `model:opus,analysis`, then runs `bd dep add <failed-task> <analysis-task>` so the **failed task is blocked by the analysis task** (it won't be re-picked until the analysis is resolved), and appends a note to the failed task pointing at the analysis ID. **Guard:** if the failing task already carries the `analysis` label, no analysis child is created (prevents infinite analysis-of-analysis chains).
**Repro:** Overflow a normal task → an `analysis`/`model:opus` child exists, original task now blocked by it. Overflow a task that already has the `analysis` label → no new child; message "Skipping analysis task creation — this is already an analysis task".
**Source:** 1013–1019 (label guard), 1037–1044 (create), 1053 (dep add), 1058 (note); call sites 1627, 2477-area, 2492-area, 2509-area.
**Classification:** **SCAR.** The escalate-don't-loop pattern and the analysis-of-analysis guard are direct responses to runaway failure loops.

### BC-18 — Analysis ID is scraped from `bd create` human stdout via `sed`
**Assertion:** The new analysis task's ID is extracted by `sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1` against `bd create`'s human-readable stdout. If the regex fails to match, the runner prints a warning and returns without dependency wiring (the analysis task exists but does not block the parent). A failing `bd dep add` is also warned-but-not-fatal.
**Repro:** Change `bd create`'s output format → dependency wiring silently breaks (analysis task orphaned, parent not blocked).
**Source:** 1046–1055. (The same scrape pattern recurs in `post_close_audit`'s regression-bead create, ~1364.)
**Classification:** **SCAFFOLDING.** Brittle CLI-output scraping; must **not** be ported. A rewrite must obtain the new ID structurally (JSON/return value). The *intent* (analysis-exists-yet-parent-unblocked is a tolerated, warned degraded state, not a crash) is a real fail-soft posture to preserve.

### BC-19 — Salvage guidance is embedded in the failure-reason string (esp. context overflow)
**Assertion:** The `reason` passed into the analysis task carries actionable salvage instructions for the next agent. The generic `create_analysis_task` description template (built from `$reason`) instructs the investigator to inspect `git log`/`git diff` for already-committed work, decide split-vs-design-first-vs-fresh-retry, and **`bd dep add` any new tasks back onto the failed task before closing**. The **CONTEXT_OVERFLOW-specific** salvage prose (re-scope to only the remaining steps, do not redo committed work, split if too large, **relabel the re-scoped task `model:opus`**) is supplied by the **caller's reason string** at the overflow dispatch arm, not inside `create_analysis_task`.
**Repro:** Trigger `CONTEXT_OVERFLOW`; read the analysis task's description — it contains the git-salvage + re-scope + relabel guidance.
**Source:** 1021–1034 (generic template + closing dep-add instruction); the overflow-specific reason is composed at the CONTEXT_OVERFLOW dispatch arm (2482–2493 region). **v2 (claude-tools-v2cut.4):** the FULL salvage reason — incl. the restored `relabel … model:opus` sentence — is composed at `runner.sh` st_post_task's CONTEXT_OVERFLOW arm and embedded into the analysis bead's description by `create_analysis_task`. The sentence was truncated in the pre-BC-32 skeleton (per-task `model:` labels did nothing then) and is RESTORED now that BC-32 makes the relabel meaningful. (`bc-19-overflow-salvage-tree.sh`.)
**Classification:** **SCAR.** The salvage text encodes the specific recovery procedure for partial-progress-then-overflow; losing it makes the next agent redo or discard completed work. **SCAFFOLDING (mechanism):** the heredoc/`read -r -d ''` templating. **(Correction vs the original entry:** the per-class salvage prose lives in the *caller's reason*, not in `create_analysis_task`'s body, which is generic and reason-driven.)**

### BC-54 — Runner-killed beads surface as Inbox analysis dossiers (Flow-G) — guarded, idempotent
**Assertion:** After the analysis bead is created and dep-wired, `create_analysis_task` best-effort emits a Flow-G Inbox **analysis dossier** for the runner-killed bead, **only when `dg_from_analysis_task` is present** (absent ⇒ the whole block is skipped and the function behaves exactly as BC-17/18/19). When present: it derives a normalized classification token from `$reason`, pulls the bead's `Runner:`-prefixed notes (falling back to `[]` on any `bd`/jq shape change so the dossier still renders), and calls `dg_from_analysis_task` with a **deterministic dossier id `analysis-<task_id>`** (one dossier per failed bead, idempotent). If `lib/dg-author-bridge.sh` is executable, it exports `DG_AUTHOR_CMD`/`DG_AUTHOR_TIMEOUT_SEC` (default 300)/`DG_AUTHOR_BRIDGE_WORKSPACE` (`=$PWD`) *inside the dossier-call subshell only*, so a real dossier-builder agent authors it; otherwise `dg` falls back to a deterministic jq author. On success, if `no_emit` exists, it pairs **one** §4.3 Notification (idempotent, non-blocking; failure is a WARN, never an abort).
**Repro:** With the dossier libs present, fail a normal task → a dossier `analysis-<task_id>` appears in the Inbox and one notification fires; re-fail the same task → same id (idempotent). With the libs absent → only the BC-17/18/19 analysis bead.
**Source:** 1060–1133 (gate 1068; bridge 1109–1116; emit 1125–1128).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The intent (claude-tools-vez G2: every runner-killed bead surfaces a human-readable Inbox dossier; claude-tools-ccnl/5me: author via the real builder) must survive; the `command -v` gating, subshell env scoping, `analysis-<task_id>` id scheme, and jq note-extraction are mechanism. The deterministic-idempotent id and "dossier failure never blocks the analysis bead" fail-soft posture are intent worth preserving.

---

## 9. Observability (incidents, notes, notifications, tool-error scan)

### BC-23 — Uniform, greppable beads note on every non-success
**Assertion:** Every non-success classification appends a note to the task in the fixed form `Runner: <CLASSIFICATION> at <HH:MM:SSZ>` (UTC, time-only) + ` — log: <path>` or ` — no stream preserved` (when the path arg is `-`). Written via `bd update --append-notes … || true` (fail-open). This is a deliberate observability contract — a human/tool greps `bd show` for `Runner:`.
**Repro:** Fail a task; `bd show` it; the note matches the `Runner: <CLASS> at …` shape.
**Source:** 1161–1172 (`append_runner_note`), called from every failure branch + the max-retries gate.
**Classification:** **SCAR.** The uniform prefix is the audit seam; ad-hoc note text would break grep-based triage. *(Note the deliberate lowercase `Runner: tool-error …` variant from `scan_tool_errors` (BC-25), and the `Runner: DISCIPLINE_BYPASS …` variant from `post_close_audit` (BC-56) — the same greppable family, different tags.)*

### BC-24 — Append-only cross-run incidents log + per-run summary
**Assertion:** Every non-success classification (and `scan_tool_errors`/`post_close_audit` findings) appends a 4-field TAB row `<ISO-8601-UTC-ts>\t<task>\t<class>\t<logpath|->` to `.beads/runner-logs/incidents.log` (append-only, **exempt from age-rotation** — confirmed at the prune site, which excludes `incidents.log`) and to an in-memory `INCIDENTS` array printed as an "Incidents this run (N):" summary at every terminal exit (normal end, breaker, AUTH, BILLING). Its purpose is to surface silently-retried failures (e.g. a watchdog kill) that would otherwise vanish when the next attempt succeeds. The classification column is an **open tag vocabulary** (`<CLASS>`, `TOOL_ERROR:…`, `DISCIPLINE_BYPASS:…`, `WRONG_NODE_CRASH:…`, `STUCK_AUTOFLIP:…`), not an enum.
**Repro:** Cause a watchdog kill then let the retry succeed → run still ends with an "Incidents this run" block and a persistent `incidents.log` row.
**Source:** 1151–1157 (`record_incident`), 1177–1188 (`print_incidents_summary`), 363–364 (rotation excludes `incidents.log`), `INCIDENTS_LOG` 374; summary printed at 2433/2451/2553/2581.
**Classification:** **SCAR.** "A later success must not erase the fact that an earlier attempt failed" is the explicit lesson; the rotation exemption is itself a deliberate forensic-durability scar.

### BC-25 — `scan_tool_errors`: pattern-matched, side-effect-only, never changes classification/exit
**Assertion:** On **every** task including `SUCCESS` and STUCK (called unconditionally after the dispatch), the stream is scanned for `tool_result` entries with `is_error:true`. It is a **cheap pre-filter** (`grep -qF '"is_error":true'`, skip the `jq` pass entirely if absent) then a `jq` extraction handling `content` as string *or* array. Only three **pattern-matched** signatures are surfaced — subagent-not-found (`Agent type 'X' not found`), permission (`Permission denied|is not allowed`), MCP-down (`MCP server.*(unavailable|failed|not connected)`). It **never** changes the classification or the exit code; it only appends a beads note + incident row (+ a `notify_user` for the subagent case only). Raw `is_error` counts are deliberately *not* used (they would be dominated by routine probes: Read-on-missing-file, grep-no-match).
**Repro:** Have an agent invoke a missing subagent but recover and exit 0/closed → classification is `SUCCESS`, exit unchanged, **but** a `TOOL_ERROR:subagent-unavailable …` incident + beads note + desktop notification are produced.
**Source:** 1197–1237 (definition; patterns self-flagged brittle at ~1215), invoked at 2536 (outside the dispatch `case`). **v2 (claude-tools-v2cut.4):** ported to `runner.sh`'s §8.2 observability block, called UNCONDITIONALLY after the st_post_task dispatch case (AUTH/BILLING `exit` before it, exactly as v1). (`bc-25-scan-tool-errors-tree.sh`.)
**Classification:** **SCAR (intent).** "An inline-recovered tool failure still means the agent didn't do what we asked — surface it without failing the run" and "pattern-match, never raw-count" are the lessons. **SCAFFOLDING (mechanism):** the specific regex strings are CLI-format-coupled and brittle by the code's own admission and must not be transcribed as-is.

### BC-26 — Notification policy: routine classes are deliberately silent
**Assertion:** `notify_user` (terminal bell + macOS `osascript`, best-effort, double-quote-escaped, never fails the run; silent no-op when `osascript` is absent) is invoked for: `AUTH_FAILURE`, `BILLING_ERROR`, `MAX_OUTPUT_TOKENS`, `CONTEXT_OVERFLOW`, generic failures, `exceeded_max_retries`, subagent-unavailable (`scan_tool_errors`), discipline-bypass (`post_close_audit`), and the consecutive-breaker stop. It is **deliberately NOT** invoked for `SUCCESS`, `RATE_LIMIT`, the *first* `TASK_NOT_CLOSED`, or the deliberate-stuck path (which routes through `no_emit`/dossier instead) — these are routine/expected/handled-elsewhere and notifying would spam.
**Repro:** Rate-limit a task → no desktop notification. Auth-fail → notification.
**Source:** 1391–1400 (`notify_user`); noisy call sites 2429/2447/2476/2488/2523/1626 + 1227 (subagent) + 1386 (discipline); silent: 2466 (rate-limit), 2507 (first task-not-closed), SUCCESS (none). **v2 (claude-tools-v2cut.4):** `notify_user` ported to `runner.sh`; noisy call sites are the AUTH/BILLING/MAXTOK/OVERFLOW/generic arms in st_post_task + exceeded_max_retries in st_claim + the breaker + subagent (scan_tool_errors) + discipline (post_close_audit); RATE_LIMIT / first TASK_NOT_CLOSED / SUCCESS / STUCK stay silent. (`bc-26-notify-policy-tree.sh`.)
**Classification:** **SCAR.** The *silence* choices are the lesson (alert fatigue from routine retries). **SCAFFOLDING:** `osascript`/bell is platform-specific mechanism. **No remote/push transport exists in `notify_user`** — remote signalling is the separate `la_report_*` seam (BC-63).

### BC-61 — `rate_limit_event` is a subscription-window snapshot, collapsed to one line (NOT a 429)
**Assertion:** The parser treats `rate_limit_event` stream entries as Claude-Code **subscription-window** quota snapshots (5h/7d), distinct from a real 429 throttle (which arrives as `api_retry.error=rate_limit` → the `RATE_LIMIT` class). It branches on `.rate_limit_info.status`: `allowed` → ONE terse `[rate_limit] … ok` line (anti-spam); `allowed_warning` → a loud one-line `[rate_limit:WARN]` with utilization/threshold/resetsAt; `rejected|exceeded` → a `[rate_limit:QUOTA]` line **plus** emits `RATE_LIMIT_QUOTA=<type>` to the signal file (forward-compat; this status is not observed today). No classification marker is emitted for the `allowed`/`allowed_warning` cases.
**Repro:** Feed repeated `rate_limit_event` `allowed` entries → a single collapsed log line, no marker, classification unaffected.
**Source:** 2015–2042 (`rate_limit_event` case; `RATE_LIMIT_QUOTA=` at 2036). **v2 (claude-tools-v2cut.4):** ported as a `rate_limit_event` case in `runner.sh`'s `parse_stream_signals` (post-hoc, not v1's live tail — same observable log line); emits no classifier marker for allowed/allowed_warning and the forward-compat RATE_LIMIT_QUOTA is not a classify_failure input. (`bc-61-rate-limit-event-tree.sh`.)
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** "Don't conflate subscription-window with 429" + the visible 7-day-quota warning are intent (claude-tools-t5k); the per-status log formatting is mechanism.

### BC-62 — Node-v25 wrong-node crash post-run backstop
**Assertion:** On `CLAUDE_EXIT != 0` and when `node25_check_wrong_node_crash` is defined, the runner scans the (fully-flushed) stream file; on a hit it emits a LOUD task-attributed stderr block, appends a row to `$LOG_DIR/wrong-node-crash.log`, and pushes a `WRONG_NODE_CRASH:<ver>` entry into the in-memory `INCIDENTS` summary. It **does not mutate `CLAUDE_EXIT`** — control falls through to normal classification (so a wrong-node crash still classifies via the signal chain, typically `UNKNOWN_FAILURE`).
**Repro:** Launch under a Node version such that the PATH prime (BC-47) can't resolve an LTS binary and `claude` crashes at startup → the wrong-node block fires; classification and exit semantics are unchanged.
**Source:** 2259–2283.
**Classification:** **SCAR (intent).** A diagnostic backstop for a known environment incompatibility (claude-tools-4tj); guarded-optional and exit-untouched, so it is purely an observability surface.

### BC-63 — `la_report_terminal_reason` telemetry mirrors the exit codes (guarded-optional)
**Assertion:** At every terminal path the runner fires a guarded `la_report_terminal_reason <REASON> <code> <task_id> <project_ref>` (the "last durable control-plane write before exit"; the REASON/code pair is the load-bearing contract, with the active `CURRENT_TASK_ID`/`PROJECT_REF` appended as positional context): `INTERRUPTED 1` (INT/TERM), `CIRCUIT_BREAKER 2`, `AUTH_FAILURE 3`, `BILLING_ERROR 4`, `CLEAN 0` (drain), and `STUCK_NEEDS_HUMAN` (no code). Absent lib ⇒ no-op, runner unchanged. This is the heartbeat-absence channel that lets a supervisor read "why did it stop" out-of-band even when it can't read the exit code.
**Repro:** With the `la_*` lib present, drive each terminal condition → the matching terminal-reason record is written before exit.
**Source:** 431–432 (interrupt), 2381–2382 (stuck), 2435–2436 (auth), 2453–2454 (billing), 2555–2556 (breaker), 2585–2586 (clean).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The out-of-band terminal-reason signal mirrors BC-21 and is a real cross-tier contract; the `command -v`-guarded `la_*` call is no-op-fallback mechanism.

---

## 10. Post-mortem artifact policy & security boundary

### BC-27 — `LOG_DIR` is a self-gitignoring SECURITY boundary
**Assertion:** `.beads/runner-logs/` gets a `.gitignore` of exactly `*` + `!.gitignore`, created if absent, so **every** artifact written there (stream-json, ps/lsof snapshots, incidents.log, preflight.log, wrong-node-crash.log, current-task) is git-ignored regardless of whether the parent `.beads/` is tracked. Stream-json files contain raw model output, file contents, and tool results — they must never be committed.
**Repro:** `git status` after a run that preserved a stream → the stream file is not listed; `.beads/runner-logs/.gitignore` exists with `*` / `!.gitignore`.
**Source:** 350–358.
**Classification:** **SCAR (security).** A containment boundary, not a convenience. A rewrite that writes post-mortem artifacts to any committable location leaks source code, tool I/O, and potentially secrets into git history. Must survive in spirit and strength.

### BC-28 — Selective stream preservation by class; proc snapshot kept only for `WATCHDOG_KILL` classification
**Assertion:** The full stream-json is copied to `LOG_DIR` (via `preserve_stream`, a pure `cp`+echo-path helper) **only** for serious classes: `WATCHDOG_KILL`, `UNKNOWN_FAILURE`, `SERVER_ERROR`, `MAX_OUTPUT_TOKENS`, `CONTEXT_OVERFLOW`. Routine/transient classes (`RATE_LIMIT`, `TASK_NOT_CLOSED`, `SUCCESS`, `AUTH`, `BILLING`) get **no** stream copy (disk-spam avoidance) but still get an incident row + beads note. The `PROC_SNAPSHOT` (written by the watchdog, BC-22/BC-59) is retained iff the final classification is exactly `WATCHDOG_KILL`, and deleted otherwise — keyed on *classification*, not on *whether the watchdog fired*: if the watchdog killed the process but a more-decisive earlier signal (e.g. `SERVER_ERROR`) wins classification, the proc snapshot is discarded.
**Repro:** `RATE_LIMIT` → no `.jsonl` in `LOG_DIR`, but an incident row exists. `WATCHDOG_KILL` → both `.jsonl` and `.proc.txt` retained. Watchdog kills but classified `SERVER_ERROR` → `.jsonl` kept, `.proc.txt` deleted.
**Source:** 1141–1146 (`preserve_stream`), 2393–2400 (preservation class list), 2538–2542 (proc snapshot retention keyed on classification).
**Classification:** **SCAR.** The class list is a tuned cost/value policy; the proc-snapshot-keyed-on-classification edge is a precise, non-obvious behavior.

### BC-29 — Per-iteration timestamped artifact basenames prevent retry collisions
**Assertion:** Artifact filenames embed a per-iteration UTC timestamp (`LOG_BASE="<TASK_ID>-<ITER_TS>"`, `ITER_TS=date -u +%Y%m%dT%H%M%SZ`, set fresh inside the loop), and preservation appends the class (`<TASK_ID>-<ITER_TS>-<CLASS>.jsonl`), so repeated attempts of the same task do not overwrite each other's preserved streams/snapshots.
**Repro:** Fail the same task twice with a preserved class → two distinct `.jsonl` files.
**Source:** 1855–1857 (per-iteration set), 2395 (preserve call with class suffix).
**Classification:** **SCAR.** Without it, the second failure's post-mortem clobbers the first's — exactly when you most need both.

---

## 11. Log-dir lifecycle

### BC-30 — Age-based rotation runs exactly once per invocation (cannot race active runs)
**Assertion:** Pruning of artifacts older than `LOG_RETENTION_DAYS` (default 14; excludes `.gitignore` and `incidents.log`) runs **once at startup**, never per-iteration, so it cannot delete artifacts a concurrently-running invocation is actively producing.
**Repro:** Run a long invocation; its in-progress artifacts are never pruned mid-run by itself.
**Source:** 360–365. **v2 (claude-tools-v2cut.4):** ported into `runner.sh` `st_starting` (reached EXACTLY once: STARTING→RECONCILE never returns), runs before the orphan snapshot. (`bc-30-rotation-once-tree.sh`.)
**Classification:** **SCAR.** "Rotate at startup, not in the loop" is explicitly to avoid racing active runs — a per-iteration prune is a footgun a rewrite could re-introduce.

### BC-31 — Preflight asset snapshot surfaces silent agent failure from line 1 (but does not abort)
**Assertion:** Before any task runs, the runner writes `preflight.log` (pwd, `.claude/agents` listing, `.claude/skills` listing, `claude --version`, `bd version`) and prints a one-line `Pre-flight: N project agent(s), M project skill(s)` count. This makes "wrong cwd / empty `.claude/agents` ⇒ agents that worked interactively silently fail inside `claude`" obvious immediately. It is **diagnostic only** — a count of `0` does **not** abort the run; the runner proceeds regardless. `preflight.log` is overwritten each run (vs. `incidents.log` which appends).
**Repro:** Run from a directory with no `.claude/agents` → "Pre-flight: 0 project agent(s) …" printed, run still proceeds.
**Source:** 376–403. **v2 (claude-tools-v2cut.4):** ported into `runner.sh` `st_starting` — `preflight.log` + the one-line count, non-aborting. (`bc-31-preflight-nonaborting-tree.sh`.)
**Classification:** **SCAR.** Born of a silent-failure incident (agents resolve relative to cwd). The *non-aborting* nature is itself characterized behavior — a rewrite that turns this into a hard gate is a behavior change, not a faithful port.

---

## 12. Model selection

### BC-32 — Label-driven model with `opus`→`opus[1m]` upgrade and deliberate `sonnet` non-upgrade
**Assertion:** The model is read from a `model:<X>` label on the task (via `bd label list` + `jq` `sub("model:";"")`), defaulting to `DEFAULT_MODEL` (`opus[1m]`). A bare `model:opus` is upgraded to `opus[1m]` (the 1M-context variant; bare `opus` is the 200K alias). `sonnet` and `sonnet[1m]` are **left exactly as-is** — `sonnet[1m]` deliberately not auto-selected because it requires "extra usage" which this org has disabled. Consequence: a `model:sonnet` task runs on the 200K window (this is *why* the CONTEXT_OVERFLOW salvage guidance tells agents to relabel `model:opus`).
**Repro:** Label a task `model:opus` → it runs `opus[1m]`. Label `model:sonnet` → runs `sonnet` (200K), not upgraded. No label → `opus[1m]`.
**Source:** 1574–1579; interacts with BC-19 and BC-58. **v2 (claude-tools-v2cut.4):** ported as `_resolve_task_model` (`runner.sh`), called per-task at the top of st_run_task; it re-resolves TASK_MODEL (label→default, bare-opus→opus[1m], sonnet untouched) AND the BC-58-coupled TASK_PERMISSION_FLAGS, and the spawn now passes `--model "$TASK_MODEL"` (was the single per-runner DEFAULT_MODEL). The multi-`model:`-label edge is reproduced verbatim (the contract's "Finding" — not fixed). (`bc-32-model-selection-tree.sh`.)
**Classification:** **SCAR.** Both the silent `opus→opus[1m]` upgrade and the deliberate refusal to touch `sonnet` encode org-billing and window-size lessons.
**Finding (edge, still present):** If a task carries **multiple** `model:` labels, the `jq` emits one per line and `TASK_MODEL` becomes a newline-containing string passed verbatim to `claude --model` — undefined/broken behavior. No first-match guard. Characterized as-is, not proposed for fix.

### BC-58 — Per-task permission-mode auto-selection (Opus → `--permission-mode auto`)
**Assertion:** Each task is run with `TASK_PERMISSION_FLAGS`, a copy of the workspace `PERMISSION_FLAGS` (`--permission-mode acceptEdits` + the curated allowlist). **Except:** when not `--yolo` and `TASK_MODEL` matches `opus*`, `TASK_PERMISSION_FLAGS` is replaced wholesale by `(--permission-mode auto)`. All non-Opus models keep the workspace `acceptEdits` allowlist. Under `--yolo` the override is skipped entirely so `--dangerously-skip-permissions` flows through (yolo wins).
**Repro:** `model:opus` task, no `--yolo` → driven with `--permission-mode auto`. `model:sonnet` → keeps `acceptEdits` + allowlist. `--yolo` → all tasks keep `--dangerously-skip-permissions`.
**Source:** 1581–1592.
**Classification:** **SCAR.** The Opus-only `auto` and the deliberate Sonnet exclusion (Sonnet silently downgrades `auto`→`default` in headless, which would strand it and trip the watchdog) are load-bearing (claude-tools-qcoe); the `opus*)` glob is the documented forward-compat seam.

---

## 13. Graceful stop, usage gating & capacity

### BC-33 — Graceful stop is detected promptly even during a 30-minute usage sleep
**Assertion:** `touch .stop-beads` stops the runner *after the current task finishes*. The usage-over-threshold wait does **not** `sleep` for the full `USAGE_SLEEP_SECONDS` in one call — it sleeps in 60s chunks, checking the stop file each chunk, and uses `break 3` to escape the chunk loop, the usage loop, **and** the main loop at once. So a stop request is honored within ≤60s even mid-usage-sleep (a naive single `sleep 1800` would make stop take up to 30 minutes). The stop file is also checked at the top of every main-loop iteration and is removed at startup (clean slate) and on detection.
**Repro:** Push the runner over the usage threshold (long sleep); `touch .stop-beads`; it exits within ~60s, not 30min.
**Source:** 329 (startup rm), 1425–1430 (top-of-loop check), 1439–1451 (chunked sleep + `break 3` at 1447).
**Classification:** **SCAR.** The chunked-sleep + `break 3` is a direct responsiveness fix. **SCAFFOLDING:** `break 3` level-count is bash-loop-nesting mechanism. **v2 (claude-tools-v2cut.4) — CONFIRMED moot:** v2 has NO long usage sleep. The capacity gate (`st_claim` `job_ask_capacity`) releases the lease and sleeps a short `RECLAIM_POLL_INTERVAL` (60 s) then re-reconciles; `STOP_FILE` is polled at the top of every `st_reconcile` and observed mid-task by the watchdog (→ STOP_REQUESTED, honored after the task). So a stop is honored ≤ `RECLAIM_POLL_INTERVAL` STRUCTURALLY, and the chunked-sleep + `break 3` SCAFFOLDING is correctly NOT ported. No new -tree assertion (the responsiveness is covered by the existing stop/idle rigs, e.g. bc-05).

### BC-34 — Usage check posture is fail-OPEN on every credential/API error, with a TTL cache
**Assertion:** The usage gate (`USAGE_THRESHOLD`, default 70; `0` disables entirely) is a TTL-cached wrapper (`USAGE_CACHE_SECONDS`, default 300) around a verdict. When the Local-Agent lib is present it delegates to `la_capacity_check standard`; otherwise it falls back to the inline path: read an OAuth token from the macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`) and call the Anthropic OAuth usage API. **Every** failure mode in the fallback — keychain unreadable, no token, `curl` failure — returns "ok to proceed" (**fail-OPEN**) with a stderr note; a usage-check outage must never halt task processing. Over-threshold (either the 5-hour OR 7-day window's integer-truncated utilization ≥ threshold) → pause and re-poll every `USAGE_SLEEP_SECONDS`. Cache TTL is force-expired (`USAGE_CACHE_TIME=0`) after a sleep and after a `RATE_LIMIT`.
**Honest-diagnostic addendum (claude-tools-zfxe):** when the verdict is `over`, the pause line names *which* gate held and the numbers it held on — not a fixed threshold string. `check_usage` carries the verdict's reason + percentages into three file-scope sidecar globals `USAGE_REASON` / `USAGE_PCT_5H` / `USAGE_PCT_7D`, set on **both** paths: the `la_capacity_check`-delegated path (from `LA_CAPACITY_REASON`/`_PCT_5H`/`_PCT_7D`) and the inline keychain/API fallback (`USAGE_REASON=5h_hard_ceiling` or `7d_hard_ceiling` per the window that tripped; numbers from the parsed utilizations). They init `ok`/empty at file scope and are **retained across the `USAGE_CACHE_SECONDS` TTL window** — a cached `over` hit serves the same window's last-written values rather than recomputing — so the loop-top pause line reads `Capacity verdict=over reason=<token> (5h=N% 7d=M%) — sleeping …` instead of the **removed** `Above ${USAGE_THRESHOLD}% usage` line, which was a *lie*: the daemon-side cost-class gate could deny (e.g. 5h=12%, 7d=85%, threshold 95) while neither window exceeded `USAGE_THRESHOLD`.
**Repro:** Break keychain access (with the LA lib absent) → runner logs "Could not read credentials … skipping" and proceeds. Set threshold 0 → no usage calls at all. Trip a deny where neither window exceeds `USAGE_THRESHOLD` (a cost-class gate) → the pause line names `reason=cost_class_not_allowed` with the real 5h/7d numbers, never `Above 95% usage`.
**Source:** 458–460 (sidecar globals init), 464–542 (`check_usage`; LA delegation 490–503 incl. reason/number capture 493/499–500, inline fallback 505–541 incl. capture 530/534/539), 1439 (loop-top pause line naming the gate), 1440 (force-fresh after sleep), 2467 (force-fresh after rate-limit).
**Classification:** **SCAR (posture).** Fail-open is the load-bearing decision; the TTL cache is a tuned anti-hammer measure. The honest-diagnostic posture — name the gate that *actually held* and the numbers it held on, never a hardcoded threshold string that can lie (claude-tools-zfxe) — is itself a SCAR. **SCAFFOLDING:** macOS-Keychain extraction and the bash sidecar-global plumbing are platform/mechanism; a rewrite must preserve fail-open and the honest-verdict surface, not the globals.

### BC-49 — Per-pickup daemon ask-capacity gate (C1/C2): deny → release lease + backoff; unreachable → local fallback → proceed
**Assertion:** After the lease is held and **before** the `bd update --status=in_progress` write, the runner consults capacity via `daemon_ask_capacity "$TASK_COST_CLASS" "$WORKSPACE_DESIRED"`, switching on its return code: **0** allowed → proceed; **1** denied → log the single-token reason verbatim (`5h_hard_ceiling` / `7d_hard_ceiling` / `spare_cycles_today_exhausted` / `cost_class_not_allowed` / `spare_only_standard_disallowed`), `lease_release_seam`, `sleep CAPACITY_DENY_BACKOFF` (default 60), `continue` (the bead stays open, not claimed); **2** daemon unreachable → fall back to the local `la_capacity_check` (guarded), and on its denial release lease + sleep + continue. `daemon_ask_capacity` returns **2** (`daemon_unreachable`) when the `la__capacity_via_daemon` seam is absent — standalone runners skip to the local fallback, which is itself skipped (proceed) if `la_capacity_check` is also absent. C2: a `spare-cycles` desired-state forbids any non-`low_priority` pickup regardless of machine-wide slack. On the **rc-2 daemon-unreachable→local-fallback denial**, the release-lease-and-backoff log line names the gate that held — `Capacity DENIED by local fallback for <id> (cost=<class>, reason=${LA_CAPACITY_REASON}, 5h=N% 7d=M%) …` — reading the `LA_CAPACITY_REASON`/`_PCT` sidecars `la_capacity_check` now sets alongside its exit code, rather than a bare `DENIED` (claude-tools-zfxe).
**Repro:** Daemon present + over-ceiling cost class → denied, lease released, bead stays open, 60s backoff. Daemon lib absent → unreachable → local check → both libs absent → pickup proceeds (fully fail-open standalone).
**Source:** 544–611 (`daemon_ask_capacity`), 1650–1704 (call site + lease-release-on-deny; the local-fallback deny line names reason + 5h/7d at 1698), config `CAPACITY_DENY_BACKOFF` line 67.
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The per-pickup ask-capacity moment + the observable verbatim reason + the release-lease-cleanly-on-deny posture are the C1/C2 distributed-coordination intent (claude-tools-g98/oil); the standalone proceed-when-both-seams-absent is the scaffolding that keeps a bare runner working.

### BC-50 — `workspace_desired_state` resolver: fail-open `running`, cached, `stopped` ends the runner
**Assertion:** `workspace_desired_state()` resolves the workspace's coordinator desired-state (`running|paused|spare-cycles|stopped`) via the `co_request` seam, cached for `DESIRED_STATE_CACHE_SECONDS` (default 30). It is best-effort **fail-OPEN**: an empty echo (no `co_request` seam, no `PROJECT_REF`, empty/garbled response, or any unrecognized value) is treated by callers as `running`. The idle loop (BC-05) and the per-pickup gate (BC-49) consume it; a `stopped` desired-state ends the runner cleanly within one poll interval. Standalone runs (no coordinator) always see empty ⇒ no spare-only gate and no remote stop — they idle until `.stop-beads`.
**Repro:** With a coordinator returning `desired=stopped`, an idling runner exits within one poll interval. With no `co_request` seam, the runner never observes a remote stop.
**Source:** 613–647.
**Classification:** **SCAR (posture).** Fail-open-to-running mirrors the rewrite's `st_reconcile` posture (engine-unreachable ⇒ keep working); the cache shields the coordinator from per-pickup hammering. Characterized as current observable behavior; no coordinator design implied.

---

## 14. Interrupt cleanup, the EXIT trap, and subshell reaping

### BC-35 — `INT`/`TERM` resets the in-flight task to `open` and does not strand it
**Assertion:** On `SIGINT`/`SIGTERM` the `cleanup()` trap: kills the live `claude` PID (and waits); **if a task is in flight** resets it via `bd update --status=open` ("Interrupted — resetting <id> to open") and `lease_release_seam`s it (§6.1 release ⇒ open); runs `runner_cleanup`; emits the `stopping` heartbeat + `INTERRUPTED 1` terminal-reason (guarded); removes the usage cache + signal/post-terminal/hook-settings files + the `current-task` pointer; prints results; exits 1. `CURRENT_TASK_ID` is set when a task starts (1706) and cleared after it finishes (2570), so the reset fires only for a genuinely-in-flight task.
**Repro:** `Ctrl-C` mid-task → that task's status is `open` (not stranded `in_progress`), exit code 1.
**Source:** 411–440, 1706 / 2572.
**Classification:** **SCAR.** Ctrl-C must not strand the active task as a phantom `in_progress`.

### BC-36 — `runner_cleanup` runs on interrupt and fatal exits but NOT on normal completion (asymmetry persists); the EXIT trap closes the subshell-leak gap
**Assertion:** `runner_cleanup` (the project hook) is invoked from `cleanup()` (INT/TERM, line 422) and before the three fatal exits (AUTH 2430, BILLING 2448, breaker 2550). It is **not** invoked on the normal/graceful path (queue drained or stop file → `break` → fall off end at 2577–2603), and **not** on an unguarded `set -e` abort.
**Repro:** Define a noisy `runner_cleanup` in `.beads/runner.sh`; let the queue drain normally → `runner_cleanup` does *not* run. Ctrl-C → it does.
**Source:** 133 (default no-op), 422, 2430/2448/2550, 2577–2603 (no `runner_cleanup` on normal end).
**Classification:** **SCAR (as a characterized hazard).** The `runner_cleanup` coverage asymmetry is real and must be a *conscious* decision in the rewrite, not silently inherited.
**Correction vs the original "no EXIT trap" finding:** there **is** a `trap _final_subshell_reap EXIT` (line 447). So the *subshell*-leak gap the original entry flagged is now **closed** — `_final_subshell_reap` runs on every exit path including a `set -e` abort. What is *not* covered on a `set -e` abort is the `CURRENT_TASK_ID → open` reset (that lives only in `cleanup`, INT/TERM-only), so an abrupt `set -e` failure can still leave a task `in_progress` even though its subshells are reaped.

### BC-44 — Process-group isolation + EXIT-trap reap of TAIL/WATCHDOG/HB subshells
**Assertion:** Each per-task background subshell (the stream-parser `tail` pipe, the watchdog, the heartbeat) is spawned under `set -m` so the subshell leader's PID equals its PGID. They are reaped two ways: (1) the **per-task reap** after `wait`, in spawn-reverse order HB → WATCHDOG → TAIL, signals the **negative PID** (`kill -TERM -- -$PID` then, after a grace, `kill -KILL -- -$PID`, each with a pid-only fallback) so reparented `sleep`/`tail -f`/`jq` grandchildren are reached; (2) the **`trap _final_subshell_reap EXIT`** (line 447) PG-kills `WATCHDOG_PID`/`TAIL_PID`/`HB_PID` plus `pkill -P $$` on **every** exit path (clean drain, breaker exit 2, after `cleanup`'s exit 1, `set -e` abort), idempotently.
**Repro:** Kill the runner abruptly mid-task → no orphaned `tail -f` left spinning on a deleted streamfile fd reparented to PID 1 (the historical ~211-accumulated-tails leak is prevented).
**Source:** 152–174 (`_final_subshell_reap`), 447 (EXIT trap), 1922/2059/2178 (`set -m` spawn), 2217–2256 (per-task PG reap).
**Classification:** **SCAR.** A real resource-leak fix (claude-tools-yva/8mb/9254a21); `pkill -P` alone misses reparented grandchildren. The negative-PID/`set -m` machinery is load-bearing. **SCAFFOLDING (mechanism):** the specific bash job-control idioms must be rebuilt, not transcribed, in a non-bash runtime.

---

## 15. Config seam & startup wiring

### BC-37 — Per-project override seam: `.beads/runner.sh`, hooks, env vars, `--yolo`
**Assertion:** The runner is configurable without editing the script:
- If `.beads/runner.sh` exists it is `source`d after defaults, able to override `PERMISSION_FLAGS`, `EXTRA_CLAUDE_FLAGS`, `PROMPT_EXTRA`, all `MAX_*`/`USAGE_*`/`IDLE_TIMEOUT`/`LOG_*`/`DEFAULT_MODEL`/`ASK_BRIAN_ENABLED`/`RUNNER_NO_CLAIM_LABELS`/`RUNNER_SIBLING_PREFIXES`/`RUNNER_TRACKING_ONLY_LABELS` values, and define `runner_setup`/`runner_cleanup` hooks (no-ops by default; `runner_setup` runs once after preflight, `runner_cleanup` per BC-36).
- Those knobs are also plain env-overridable (`${VAR:-default}`).
- Default `PERMISSION_FLAGS` = `--permission-mode acceptEdits` + a hand-curated `--allowedTools` allowlist (git/bd, git-recoverable file ops, read/inspect utils, text processing, env checks, curl/python for skills).
- First arg `--yolo` replaces the allowlist with `--dangerously-skip-permissions` and relabels the run "all permissions bypassed".
- `PROMPT_EXTRA`, if set, is appended to the worker prompt (after token substitution, so its tokens are not substituted).
**Repro:** Drop a `.beads/runner.sh` setting `MAX_RETRIES=5` and a `runner_setup` that echoes → both take effect. Pass `--yolo` → "Running: all permissions bypassed".
**Source:** 18–129 (defaults), 178–183 (config source), 290–296 (yolo), 407 (`runner_setup`), 1814–1819 (`PROMPT_EXTRA`).
**Classification:** **SCAR.** The scoped-default allowlist encodes "these tools are safe / git-recoverable" judgements; the `--yolo` escape hatch and source-able config seam are deliberate product surface.

### BC-43 — Optional lib seams degrade to a working standalone runner (absent ⇒ runner unchanged)
**Assertion:** Four optional libs are conditionally sourced (`[[ -f $LIB ]]`) from the runner's own `lib/` dir: `local-agent.sh` (LA — capacity/heartbeat/terminal-reason), `stuck-routing.sh` (SR — §7.3 stuck spine + I4 resume), `notification.sh` (NO — `no_emit`), `co-http-transport.sh` (CT — authed HTTPS that overrides the in-process `co_request` iff `COORDINATOR_URL` is set). **Every consumer call is `command -v`/`declare -F`-guarded**, so a missing lib leaves the runner byte-for-byte unchanged (standalone/oracle/conformance runs). `PROJECT_REF` defaults to `basename "$(pwd)"`. This standalone-degradation posture is the implicit fallback of every distributed-seam entry (BC-48/49/50/53/54/63). **A fifth optional lib, `hooks/build-settings.sh`, is sourced in a *separate* `[[ -f ]]` block (claude-tools-2fkp) and is NOT one of these four — its degrade differs (it drops close-hook enforcement, not "byte-for-byte unchanged"); it is characterized with the close-discipline behavior it governs, BC-65.**
**Repro:** Run with none of `lib/{local-agent,stuck-routing,notification,co-http-transport}.sh` present → identical task-processing behavior, with all heartbeat/capacity/stuck/notification work silently skipped.
**Source:** 185–239 (lib sourcing), 240–242 (`PROJECT_REF`).
**Classification:** **SCAR (posture).** "An absent coordination lib never changes core behavior" is the load-bearing modularity decision; a rewrite that hard-couples to the distributed tier breaks the standalone path that conformance and bare workspaces depend on.

### BC-47 — Node v25 PATH prime is sourced *unconditionally* (a missing lib must fail loudly)
**Assertion:** `lib/node25-prime.sh` is sourced **without** a `[[ -f ]]` guard (unlike the optional libs in BC-43) and `node25_prime_path` is called at startup, because a daemon-launched PATH resolves `claude` to system Node v25, which crashes the CLI at startup. The lib **is** the fix, so a missing lib is a real regression that should fail loudly, not silently degrade to a stripped-PATH `claude`. The scoped skip env var `RUNNER_SKIP_NVM_PRIME` stays caller-local. A post-run backstop (BC-62) catches a wrong-node crash that slips through.
**Repro:** Remove `lib/node25-prime.sh` → the runner errors at startup (no silent degrade). Run on a machine where the daemon PATH leads to Node v25 → the prime resolves an LTS `claude` and the CLI starts.
**Source:** 298–314.
**Classification:** **SCAR.** The unconditional source is itself the contract — the same bug bit three sibling scripts (claude-tools-4tj/18c). A rewrite must preserve "this dependency is mandatory and loud," not treat it as optional plumbing.

---

## 16. Worker prompt & spawn

### BC-38 — Worker prompt forbids human-in-the-loop and prescribes debrief-then-close
**Assertion:** The prompt handed to each `claude` session (a literal-quoted heredoc): states it is running non-interactively; **explicitly forbids `EnterPlanMode`/`ExitPlanMode` and `AskUserQuestion`** ("there is no human to approve plans / answer"); instructs "just execute the work directly"; instructs the agent to follow the task description exactly; and requires, **before** closing, a debrief note via `bd update <id> --append-notes="<debrief>"` (what was done, difficulties, unexpected behavior, timing, uncertainties, follow-ups — "be honest, this is for the human reviewing later"), then `bd close <id>`. The prompt also pins a **gate-wait discipline** clause (claude-tools-m0yv), spliced between "Follow the instructions … exactly" and the debrief instruction, governing how the worker consumes any long-running command (the offline gate `bash beads-runner/run-tests.sh`, a build, a deploy-verify): **run it EXACTLY ONCE** (prefer the fast `--changed` pre-close path); **NEVER relaunch a quiet gate** (a quiet gate is normal — some tiers run for minutes with sparse output — and silence is not evidence it is wedged); **NEVER pipe it through a non-streaming `tail -N`** (which buffers ALL input and emits nothing until the pipe closes, so the worker sees zero output and wrongly concludes the gate stalled) — instead watch the live stream (`tee`/`tail -f`, or redirect/`run_in_background`); and to WAIT use a non-blocking pattern (`run_in_background` + poll, or `until <done-condition>; do sleep N; done`), **never `sleep N; <cmd>`** (the harness blocks sleep-chaining). This is a *consumption-side* lesson: a worker previously ran the gate as `run-tests.sh 2>&1 | tail -40`, saw nothing for a 15+ min gate, declared it wedged, and relaunched it — stampeding `run-tests.sh` into a multi-way pile-up (the singleton-lock backstop is the separate claude-tools-fm4r). **The prompt additionally pins a commit-message discipline clause** (claude-tools-02ec, current line 1798): the worker MUST reference the **FULL bead id** in its work commit's subject or body, because the close-discipline audit greps `git log` for the full id and a short conventional-commit scope alone (`feat(xyz): …`) does **not** match — tripping a false `close_without_commit` that files a spurious P1 regression bead (the very check BC-56 runs); it explicitly forbids leaning on a separate empty "carry full bead id" commit afterward. The block is byte-identical in this runner and `runner.sh` and pinned in both BC-38 conformance assertions so drift fails conformance. Task ID/title/description are substituted into the template by literal global string replacement.
**Repro:** Inspect the prompt for any task: contains the no-plan/no-ask prohibition, the gate-wait discipline (literal strings `Run it EXACTLY ONCE`, `buffers ALL its input and emits nothing until the pipe closes`, `run_in_background`, `the harness blocks sleep-chaining`), the commit-message discipline (literal `Commit-message discipline:` / `reference the FULL bead id`), and the debrief-then-close instruction.
**Source:** 1782–1805 (heredoc); gate-wait discipline block 1793–1796; commit-discipline mandate 1798; substitution 1809–1812. Conformance: `conformance/assertions/bc-38-worker-prompt.sh`.
**Classification:** **SCAR (current behavior).** The no-plan/no-ask rule and the mandatory honest debrief are deliberate and load-bearing for unattended runs and human review.
**Flag (context change, characterized — not designed here):** This behavior's *premise* — "there is no human to answer" (stated unconditionally at 1788) — is precisely the assumption whose context changes in the planned rewrite. **Today that premise is already partially contradicted within the same prompt:** when `ASK_BRIAN_ENABLED=1`, the `ASKBRIAN_BLOCK` (BC-55) is spliced two lines below it, introducing an async human reachable via `mcp__askbrian__ask-brian` / a `STUCK_NEEDS_HUMAN` bead note. Per scope, the replacement is **not** designed here. **SCAFFOLDING (mechanism):** the heredoc + `${PROMPT//BEADS_ID/…}` global token substitution is brittle (a literal `BEADS_ID`/`BEADS_TITLE`/`BEADS_DESC` inside a task description would be wrongly substituted; substitution is global) and must not be ported as-is.

### BC-46 — `GUARDRAIL_FLAGS` removes the interactive tools at the tool layer (belt-and-suspenders with BC-38)
**Assertion:** `claude` is launched with `--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode` (`GUARDRAIL_FLAGS`), removing the three interactive tools from the worker's advertised set at the **tool layer** — complementing BC-38's prompt-level prohibition. `GUARDRAIL_FLAGS` is kept **separate** from `EXTRA_CLAUDE_FLAGS` precisely so a project `.beads/runner.sh` that overrides `EXTRA_CLAUDE_FLAGS` wholesale cannot drop the guardrail.
**Repro:** Inspect the spawned `claude` argv → `--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode` present even when a project overrides `EXTRA_CLAUDE_FLAGS`.
**Source:** 39–49 (definition + rationale), 1899 (expansion at spawn).
**Classification:** **SCAR (posture).** A bare prohibition is empirically insufficient (research Q5) — remove the tool AND forbid it in prose. The frozen-contract guardrail (§7.6/AD3.5) survives project config by construction.

### BC-55 — Async-human seam at the prompt layer: conditional `ASKBRIAN_BLOCK` + I4 resume splice
**Assertion:** Two prompt-layer behaviors exist **only** when `ASK_BRIAN_ENABLED=1` (default 0):
- **`ASKBRIAN_BLOCK`** — a large instruction block (literal-quoted heredoc) read into `ASKBRIAN_BLOCK` and substituted into the prompt; empty string otherwise. It frames `mcp__askbrian__ask-brian` as a **last resort** after a mandatory research checklist, enumerates what is / is not a "real fork," documents the tool inputs and that it BLOCKS until Brian answers, warns against duplicate dossiers (claude-tools-88e), and gives a `STUCK_NEEDS_HUMAN` bead-note + `human`-label **fallback** for when the MCP tool is unregistered.
- **I4 resume splice** — when a previously-parked fork has been answered (`sr_resume_answer "$TASK_ID"` succeeds), the formatted human directive is **prepended** to the prompt (highest salience), mirrored into bead notes (`HUMAN_DECISION (I4 resume …)`, truncated), and one-shot **consumed** (`sr_consume_resume_answer`) so a later pickup never re-injects it. Every `sr_*` call is guarded — absent lib ⇒ silent no-op.
**Repro:** Set `ASK_BRIAN_ENABLED=1` → the prompt contains the research-first ask-brian block. Park a task at a fork, answer it, let it return to `bd ready` → its next run's prompt begins with Brian's directive. Default (0) → neither appears.
**Source:** 1731–1780 (ASKBRIAN_BLOCK), 1790/1809 (inject), 1821–1851 (I4 resume splice).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The async-human-escalation *policy* (research-first, real-fork definition, `STUCK_NEEDS_HUMAN` fallback, answer-changes-next-action) is load-bearing intent (claude-tools cvj/fcd931f/88e + the I4 acceptance); the heredoc/token-splice/`sr_*` guards are mechanism. **Flag (context change):** this is the prompt-layer half of the async-human round-trip the rewrite's context changes — characterized factually, not designed here.

---

## 17. Distributed-system seams (current observable behavior only)

> Characterized FACTUALLY as what the running script does today; the distributed design is explicitly **out of scope**. Every seam below has the BC-43 standalone fallback.

### BC-48 — §6.1 lease ↔ beads-status binding (acquire before `in_progress`, release ⇒ open)
**Assertion:** A GLOBAL EXCLUSIVE lease is acquired via `lease_acquire_ok "$TASK_ID"` **before** the bead transitions to `in_progress`; a non-zero `lease acquire` means **must-not-claim** (the runner backs off `LEASE_DENY_BACKOFF`, default 3s, and continues without claiming). Release (`lease_release_seam`) pairs every acquire — at task end, on a capacity deny (BC-49), on a failure reset to open (BC-15), and on interrupt (BC-35) — so a released/expired lease maps the bead back toward open. **Standalone fallback:** if no `lease` command exists, `lease_acquire_ok` returns 0 (proceed) and `lease_release_seam` is a no-op. This is the seam that closes the BC-04 residual two-runners-one-orphan race when present.
**Repro:** With a `lease` command present, start two runners against the same queue → only the lease holder claims a given bead; the other backs off. With no `lease` command → both proceed (standalone, residual race as in BC-04).
**Source:** 278–286 (`lease_acquire_ok`/`lease_release_seam`); acquire/deny at the pickup (1644-area); releases at 420 (interrupt) / 1684 & 1699 (capacity-deny) / 2564 (per-task end) / 2434 & 2452 & 2554 (fatal-exit).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The acquire-before-`in_progress` + release-pairs-open binding is the strong-plane intent (claude-tools-am8); this file owns only the WORK-PLANE binding, not the arbitration/fallback mechanism (which the `lease` seam provides), and the standalone-proceed default is load-bearing for bare runs.

### BC-53 — `detect_worker_stuck_primary`: a deliberately-stuck worker is routed to a human, not retried
**Assertion:** `detect_worker_stuck_primary` recognizes a worker that **deliberately** signals "stuck / needs human" and treats it as an intentional act, not a failure. Gated on `ASK_BRIAN_ENABLED=1` (else returns 1, no-op). It fires (echoes `worker_stuck`) on ANY of: (1) `exit_code == WORKER_STUCK_EXIT` (default 7); (2) canonical bead state `status==blocked` AND a `human` label; (3) **relaxed** — a `human` label + a `STUCK_NEEDS_HUMAN` note even when status is not blocked, in which case it **auto-flips** the bead to `blocked` (best-effort) and logs a `STUCK_AUTOFLIP` incident + note. In the dispatch, a fired stuck (and the `sr_scan_backstop` permission-slip backstop) **bypasses the entire classification `case`**: the bead is NOT reset to open (BC-15 exception), NO breaker/retry counter advances, NO `notify_user`. STUCK is outranked only by `AUTH_FAILURE`/`BILLING_ERROR` (the two fleet-fatal classes); it preempts `TASK_NOT_CLOSED`.
**Repro:** With `ASK_BRIAN_ENABLED=1`: a worker exits 7 (or leaves the bead `blocked`+`human`, or `human`+`STUCK_NEEDS_HUMAN` note) → bead stays blocked-for-human, no retry/penalty, routed to the stuck spine (BC-54). With `ASK_BRIAN_ENABLED=0` → falls through to normal classification.
**Source:** 962–1005 (`detect_worker_stuck_primary`; gate 969–971; relaxed auto-flip 993–1003); consumed 2285–2386, bypass 2407–2409.
**Classification:** **SCAR (posture).** Grounded in concrete post-mortems (claude-tools-wwl/2ir/cf6): agents reliably do 3 of 4 stuck-protocol steps but slip the status flip, so the runner trusts the label, auto-flips, and logs every slip. **Flag (context change):** this is the async-human seam the rewrite's context changes — characterized factually, not designed.

### BC-54 (routing) — see §8 BC-54
The stuck-routing spine (`sr_route_stuck` → dossier → `no_emit` notification) that consumes BC-53 is documented as **BC-54** under Analysis-task escalation (it shares the dossier mechanism with the runner-killed-bead path). Cross-referenced here because BC-53 (detection) and BC-54 (routing) are two halves of one §7.3 behavior; the master switch is `ASK_BRIAN_ENABLED`.

---

## 18. Post-close discipline

### BC-56 — `post_close_audit`: a SUCCESS that didn't ship is surfaced as a discipline-bypass regression bead
**Assertion:** On the **SUCCESS path only** (after the bead is re-verified `closed`), `post_close_audit` audits whether the just-closed bead followed close-discipline. Opt-out via `RUNNER_SKIP_POST_CLOSE_AUDIT` (default OFF — production always audits; the conformance harness opts out, mirroring `RUNNER_EXIT_ON_DRAIN`). It runs up to four checks (each fail-open / skipped when its tool is absent): **close_without_commit** (no `git log --grep=<id>` commit in the last hour — the BC-38/claude-tools-02ec worker-prompt commit-discipline mandate exists precisely to make this full-id grep match), **dirty_tree** (`git status --porcelain` with `.beads/issues.jsonl`, `.beads/*-debrief.txt`, `.beads/runner-logs/`, `.stop-beads` excluded — `issues.jsonl` is excluded because `bd close` itself dirties it; Dolt is authoritative, claude-tools-u4ms), **wrapup_not_invoked** (only if a `wrapup` skill exists and the notes lack a `wrapup-reviewed:` marker), **missing_debrief** (notes empty or `< 40` chars). On any violation it, in order: **files a P1 `discipline-bypass`-labelled regression bead first** (so the note can carry the real id or honestly admit the create failed), **records a `DISCIPLINE_BYPASS:<checks>` incident**, **appends a `Runner: DISCIPLINE_BYPASS …` marker note** to the original bead, and **`notify_user`s**. It **never reopens** the original bead.
**Repro:** Have a worker `bd close` a bead without committing (or with a dirty tree / no debrief) → a P1 `discipline-bypass` regression bead is filed, an incident + note recorded, a notification fires; the original bead stays closed.
**Source:** 1251–1387 (definition), 2420 (SUCCESS call site).
**Classification:** **SCAR.** Directly mitigates the "closed-but-not-shipped" failure mode (the Stop-hook-bypass-via-block-cap close, claude-tools-apen/td0y; the same scar CLAUDE.md's web-acceptance discipline and claude-tools-bgw guard). The `RUNNER_SKIP_POST_CLOSE_AUDIT` env seam and the `sed`-scraped regression id are SCAFFOLDING (mechanism); the file-bead-before-note ordering is a deliberate honesty scar.

---

## 19. Per-task state hygiene

### BC-57 — `TASK_COST_CLASS` is recomputed every iteration (no cross-iteration leak)
**Assertion:** `TASK_COST_CLASS` is **unconditionally reassigned** every loop iteration and never carries across loops. A caller-exported startup value is snapshotted once into `TASK_COST_CLASS_OVERRIDE` (the escape hatch) and re-applied each iteration; otherwise `TASK_PRIORITY >= 3 → low_priority`, else `standard`. Guarding on "empty" would latch a prior pickup's value (a P3 leaking `low_priority` onto a following P2).
**Repro:** Run a P3 task then a P2 with no override → P2 computes `standard`, not the prior `low_priority`. Export `TASK_COST_CLASS=low_priority` → every iteration forced to it.
**Source:** 1421 (override snapshot), 1666–1672 (per-iteration recompute).
**Classification:** **SCAR.** The unconditional recompute is a deliberate correctness fix (claude-tools-hkwg) feeding the capacity gate (BC-49).

### BC-64 — `current-task` pointer: exported env + file fallback, cleared at startup / loop-end / interrupt
**Assertion:** At task pickup (after lease+capacity pass, before the `in_progress` write) `CURRENT_TASK_ID` is set and **exported** so the `claude -p` worker and its hook subprocesses inherit it, and the id is also written to `$LOG_DIR/current-task` (best-effort) as a file fallback. The pointer is cleared at **startup** (a previous runner that died without clearing), at **loop-end** (2570–2573), and on **interrupt** (437), so a between-tasks close-discipline hook can never enforce against a stale bead on the first tool call of the next task.
**Repro:** During a run, a hook subprocess reads `$CURRENT_TASK_ID` (env) or `$LOG_DIR/current-task` (file) and gets the active id; after a task ends or the runner dies, the pointer is gone.
**Source:** 367–372 (startup clear), 1706–1713 (set/export/file), 437 (interrupt clear), 2572–2575 (loop-end clear).
**Classification:** **SCAR.** Born of the claude-tools-td0y stale-pointer incident (the close hook enforcing against the wrong bead). The env+file dual surface is hook-visibility plumbing (SCAFFOLDING mechanism); the clear-on-every-boundary discipline is the scar.

### BC-65 — Close-checklist hook wired via `--settings` only when present and runnable
**Assertion:** A close-discipline hook is wired into the worker via `--settings <generated file>` (`HOOK_SETTINGS_FLAGS`) **only** when the close-checklist hook is executable AND the `build_hook_settings` builder function is defined AND that builder succeeds (it `return 1`s when `jq` is missing or the write fails); otherwise the flag array is empty and the worker runs without it. The `--settings` JSON shape (a `PreToolUse` matcher on `Bash` plus an empty-matcher `Stop` hook) is **no longer inlined as jq** — it now lives in the shared, optionally-sourced `hooks/build-settings.sh` (claude-tools-2fkp) so it stays byte-identical between this runner and the v2 `runner.sh`. That helper is sourced in its own `[[ -f ]]`-guarded block (distinct from BC-43's four `lib/` libs, and with a **different degrade**: unlike those, an absent builder does NOT leave the runner byte-for-byte unchanged — it drops `--settings`/close-hook enforcement, leaving the prompt-instructed discipline + the post-terminal watchdog (BC-59) as the only backstops). Two env vars are exported into the child at spawn: `BEADS_RUNNER_SESSION=1` and `POST_TERMINAL_FILE=<path>`.
**Repro:** Remove/`chmod -x` the close-checklist hook, OR remove `jq`, OR remove `hooks/build-settings.sh` → the worker spawns with no `--settings` and no close-hook enforcement, run otherwise unchanged.
**Source:** 316–326 (optional `hooks/build-settings.sh` source + its degrade comment), 1879–1891 (`HOOK_SETTINGS_FLAGS` via `command -v build_hook_settings` guard + return-code gate; `build_hook_settings` call 1885–1886), 1893–1903 (spawn + exported env); the `--settings` JSON shape lives in `hooks/build-settings.sh`'s `build_hook_settings` (jq precondition `command -v jq || return 1` now inside it).
**Classification:** **SCAR (intent) / SCAFFOLDING (mechanism).** The runtime enforcement of close-discipline is the intent (paired with BC-56's post-hoc audit); the `--settings`-file generation, the new `command -v build_hook_settings` indirection (claude-tools-2fkp), and the executable/`jq`/builder-present preconditions are mechanism. The anti-drift extraction (one shape, both runners) is itself worth preserving in spirit.

---

## 20. Heartbeat & liveness

### BC-45 — Heartbeat keeps the Board honest: live-while-working, stale-while-stuck
**Assertion:** `hb()` emits one §4.2 actual-state line via `la_report_heartbeat` (and drains the durable outbox when a hosted `COORDINATOR_URL` is configured); it is a **guarded no-op** when `la_report_heartbeat` is absent. Beyond state-transition heartbeats (`running`/`idle`/`stopping`), a **mid-task heartbeat subshell** emits `hb running "$TASK_ID"` every `HEARTBEAT_INTERVAL` (60s) **during** a task, gated on stream activity: if a Task subagent is in-flight it emits unconditionally; otherwise it emits only while the last stream line is within `HEARTBEAT_GAP_TOL` (90s). So a task longer than the Board's `STALE_AFTER` (≈180s) stays `live` while genuinely working, but a stuck worker (no activity, no inflight) stops heartbeating and goes `stale` honestly.
**Repro:** Run a >180s task with stream gaps ≤90s → Board shows it `live` throughout. Wedge the worker (no output, no inflight) → heartbeats stop and the Board reads `stale` after `STALE_AFTER`.
**Source:** 255–261 (`hb`), 2178–2211 (mid-task HB subshell), config `HEARTBEAT_INTERVAL`/`HEARTBEAT_GAP_TOL` inlined at use (2180–2181).
**Classification:** **SCAR (posture).** The externally-observed liveness/staleness honesty is a behavioral contract (claude-tools-7v5); a rewrite must keep "emit while working, fall silent when stuck," not a naive always-on heartbeat that would mask a wedge.

---

## 21. Implementation scaffolding inventory (must NOT be ported faithfully)

These are bash/CLI artifacts. Their *intent* may be a scar (cross-referenced); the *mechanism* must be rebuilt idiomatically, not transcribed.

### BC-39 — stdout+stderr are merged into one stream file by design
**Assertion:** `claude` is launched with `> "$STREAM_FILE" 2>&1` — stderr (SDK HTTP-retry state) is deliberately interleaved into the same file the parser/classifier read. The watchdog's SIGINT-before-SIGKILL (BC-22) exists specifically so this stderr flushes before the kill. A side effect: pure SDK noise on stderr resets the watchdog idle clock (BC-60).
**Source:** 1893–1903.
**Classification:** **SCAR (intent: stderr must be captured & classifiable) / SCAFFOLDING (mechanism: shell fd redirection into a tail-`-f`'d tempfile).**

### BC-40 — Signal-file IPC between parser/watchdog and classifier
**Assertion:** The stream-parser subshell and the watchdog communicate failure signals to the classifier by **appending lines to a shared tempfile** (`SIGNAL_FILE`), which `classify_failure` greps *after* both background jobs are joined. `ACTIVITY_FILE` is a single-value tempfile overwritten by the parser and read by the watchdog (benign timestamp race). `TASK_INFLIGHT_FILE` (BC-60) is a third tempfile with set-membership semantics, and `POST_TERMINAL_FILE` (BC-59) a fourth (single idempotent stamp). Markers accumulate (`>>`); the ordered grep (BC-10) disambiguates.
**Source:** parser appends 1963–2036; watchdog appends `WATCHDOG_KILL=1`/`POST_TERMINAL_KILL=1` (2131 / 2088); join-then-classify 2215–2285.
**Classification:** **SCAR (intent: capture-then-classify with a strict happens-before — classify only after the process exits and background jobs are joined) / SCAFFOLDING (mechanism: tempfile-as-IPC, `tail -f` subshell, PG-reap of the orphaned `tail` child).**

### BC-41 — `RESULT_IS_ERROR=` is written to the signal file but never consumed from it
**Assertion:** The parser writes `RESULT_IS_ERROR=<bool>` to the signal file for every `result` event, but `classify_failure` never reads it — the `is_error` value is only used *inline within the parser subshell* to gate `CONTEXT_OVERFLOW` detection. The signal-file `RESULT_IS_ERROR=` line is effectively dead data. *(Re-verified: still true.)*
**Source:** 1999 (write) vs. 893–931 (classifier never greps `RESULT_IS_ERROR`).
**Classification:** **SCAFFOLDING.** Dead/vestigial output; a rewrite must not preserve it as if load-bearing.

### BC-42 — Pervasive fail-open guards (`|| true`, `2>/dev/null`) under `set -euo pipefail`
**Assertion:** Nearly every `bd`/IO/seam call is wrapped so its failure cannot abort the runner (`… 2>/dev/null || true`, `|| echo "[]"`, `command -v X || return 0`, the `${arr[@]+"${arr[@]}"}` unset-safe array expansion, the `set -e`-safe `rc=…; ec=$?` capture around capacity/desired-state). The operating posture: a `bd`/network/IO/lib hiccup degrades gracefully (skip / assume-success / proceed) rather than crashing the loop.
**Source:** throughout (representative: 285, 419, 437, 695, 761, 798, 1058, 1382, 2426, 2564, and every `command -v`-guarded seam).
**Classification:** **SCAR (posture: tolerate transient infra failure, never crash the runner on it) / SCAFFOLDING (mechanism: shell error-suppression idioms).** A rewrite must preserve the *posture* explicitly (typed error handling), not by blanket exception-swallowing.

### BC-NEW-SPAWN — Exact `claude` invocation flag assembly
**Assertion:** The backgrounded spawn passes, in order: `-p "$PROMPT"`, `--output-format stream-json`, `--verbose`, `--model "$TASK_MODEL"`, then four unset-safe array expansions — `GUARDRAIL_FLAGS` (BC-46), `EXTRA_CLAUDE_FLAGS` (default `--no-chrome`, project-overridable), `TASK_PERMISSION_FLAGS` (BC-58), `HOOK_SETTINGS_FLAGS` (BC-65) — redirected `> "$STREAM_FILE" 2>&1 &`. `--output-format stream-json` is load-bearing (a `text` format would hide the `permission_denials[]` the §7.2 backstop needs); `--verbose` is required by stream-json.
**Source:** 1893–1903; defaults 20–49.
**Classification:** **SCAR (intent: the guarantees — interactive tools removed, headless permission posture, stream-json so denials survive, close-hook enforcement) / SCAFFOLDING (mechanism: the array-expansion idioms).**

---

## 22. Additional findings & corrections vs the prior (930-line) contract

Confirmations/corrections surfaced in the line-by-line re-pass (also summarized in the bd debrief note):

- **BC-21 / BC-36 — the "no EXIT trap" finding is now WRONG.** A `trap _final_subshell_reap EXIT` (line 447) runs the subshell PG-reap on every exit path (BC-44). The *subshell*-leak gap is closed; what remains asymmetric is `runner_cleanup` (INT/TERM + 3 fatal exits only) and the `CURRENT_TASK_ID→open` reset (INT/TERM only — a `set -e` abort still strands the task, though its subshells are now reaped).
- **BC-04 residual race — now closed when the lease seam is present** (BC-48). The two-runners-one-orphan race the original entry flagged as residual is closed by the §6.1 lease (acquire-before-`in_progress`); standalone it remains residual.
- **BC-16 — "always takes `.[0]` of `next_task()`" is stale.** Selection is `select_workable_task`'s first-*workable* scan over an orphans-first, epic-filtered queue (BC-51/BC-52), narrowed to one element. The FAIL_COUNT-tracks-consecutive-selections coupling is unchanged.
- **BC-19 — class-specific salvage prose lives in the caller's reason string,** not in `create_analysis_task` (whose template is generic/reason-driven).
- **BC-10 — `SERVER_ERROR` sits after the full `MAX_OUTPUT_TOKENS` triple;** marker greps are anchored (`^MARKER=`); eight output classes confirmed.
- **BC-09 stale comment** at line 1267 (`post_close_audit`) still cites "line 743" for the fail-open echo, which is now line 902. Cosmetic only.
- **New behavior added since the prior contract** (BC-43…BC-65): optional lib seams + standalone posture (BC-43), Node-v25 unconditional prime (BC-47), EXIT-trap PG subshell reap (BC-44), lease binding (BC-48), per-pickup capacity gate (BC-49) + desired-state resolver (BC-50), `select_workable_task` anti-starvation + two-tier idle (BC-51) + epic filtering (BC-52), `detect_worker_stuck_primary` (BC-53) + dossier spine (BC-54) + prompt-layer ask-brian/I4 resume (BC-55), `post_close_audit` (BC-56), `TASK_COST_CLASS` per-iteration recompute (BC-57), per-task permission-mode auto (BC-58), `POST_TERMINAL_GRACE` SIGKILL backstop (BC-59) + inflight/activity/epoch-floor (BC-60), `rate_limit_event` collapse (BC-61), Node-v25 post-run backstop (BC-62), terminal-reason telemetry (BC-63), `current-task` pointer hygiene (BC-64), close-hook `--settings` wiring (BC-65), heartbeat liveness (BC-45), `GUARDRAIL_FLAGS` (BC-46), spawn flag assembly (BC-NEW-SPAWN).
- **Master kill-switch:** `ASK_BRIAN_ENABLED` (default 0) makes the entire stuck/dossier/ask-brian/I4 spine (BC-53/54/55, the I4 reconcile/poll, the §7.3 backstop) a no-op — a workspace opts in by setting it AND allowlisting `mcp__askbrian__ask-brian`.

### Re-verification pass — 2603-line script (claude-tools-c8c)

- **Every entry's `file:line` ref re-derived against the current 2603-line script** (the final `02ec` +2 is the closing bullet below). The +124-line drift to the earlier (2477→2601) refresh came from four commits — `uxg8` (+81), `zfxe` (+34), `2fkp` (+26), `m0yv` (+5) — so nearly every ref at/below the `validate_task` tail (~line 712) shifted by +80…+124. Refs above that point (config block 20–108, defaults, `GUARDRAIL_FLAGS` 39–49) did not move.
- **Only BC-36 was `assertion_ok=false`,** and purely because its *embedded* numbers (the `cleanup()`/fatal-exit/normal-end lines) were stale; the factual claims held and the numbers are now corrected. Every other assertion re-confirmed against the code unchanged. Stale *inline* refs also fixed in BC-21 (exit-code table + footnote), BC-35, BC-44, BC-64, and the BC-09 footnote (the in-script comment now at line 1267 still cites "line 743"; the real fail-open echo is line 902 — the footnote was doubly stale).
- **`zfxe` (claude-tools-zfxe) folded into BC-34 + BC-49:** the over-verdict pause line and the daemon-unreachable local-fallback deny line now name the gate that *actually held* + the 5h/7d numbers (via the `USAGE_REASON`/`USAGE_PCT_5H`/`USAGE_PCT_7D` sidecar globals, retained across the TTL window); the old `Above ${USAGE_THRESHOLD}% usage` line was removed as a lie. No control flow changed.
- **`2fkp` (claude-tools-2fkp) folded into BC-65 (+ a note on BC-43):** the close-hook `--settings` JSON shape moved from inline jq into the shared, separately-`[[ -f ]]`-sourced `hooks/build-settings.sh` (`build_hook_settings`), adding a third precondition (`command -v build_hook_settings`) and a third degrade case; its degrade (drop hook enforcement) differs from BC-43's four libs (byte-for-byte unchanged), so it is characterized with BC-65, not counted among BC-43's four.
- **`m0yv` (claude-tools-m0yv) folded into BC-38:** the shared worker prompt now pins a **gate-wait discipline** clause (run a long command once; never pipe through non-streaming `tail -N`; `run_in_background`/`until` to wait; never relaunch a quiet gate; never `sleep N; cmd`) — a consumption-side scar from a `run-tests.sh` relaunch-stampede, pinned byte-identically in the BC-38 conformance assertion.
- **Doc-staleness flagged, not behavior:** `la_report_terminal_reason` is now called with 4 positional args (`<REASON> <code> <task_id> <project_ref>`), not the 2-arg shorthand the BC-63 prose used (REASON/code contract intact); `create_analysis_task` exports a third subshell var `DG_AUTHOR_BRIDGE_WORKSPACE=$PWD` beyond the two BC-54 listed.
- **`02ec` (claude-tools-02ec) — the final +2 reconciliation:** a worker-prompt **commit-message discipline** mandate (the work commit MUST carry the FULL bead id in its subject or body, or the close-discipline `git log --grep` trips a false `close_without_commit` → spurious P1 regression bead; folded into BC-38, paired with the BC-56 audit it satisfies) was inserted at current lines **1798–1799**, shifting **every `file:line` ref ≥ 1798 by +2** (refs ≤ 1797 unmoved). All ≥1798 refs were re-derived against the 2603-line script by an **8-way independent re-verification** (one read-only agent per BC cluster, 68 entries, 237 file reads): **0 assertion regressions**. The only *beyond-+2* corrections were two **pre-existing** stale refs the pass caught — BC-26's two `silent:` notify refs (`2457`→`2466`, `2496`→`2507`), which never tracked the 2601 cut and are now pinned to the actual no-notify comment lines.

---

## Conformance checklist (what the rewrite's gate must assert)

A rewrite passes this contract iff, for every **SCAR** entry above, an equivalent observable behavior is demonstrable by its black-box repro, **and** for every **SCAFFOLDING** entry the mechanism is *not* transcribed (re-implemented idiomatically, with the cross-referenced scar intent preserved where noted). The highest-risk regressions — silent when wrong — are:

- the exit-code table (**BC-21**) and its telemetry mirror (**BC-63**);
- the `LOG_DIR` security boundary (**BC-27**);
- the classification precedence (**BC-10/BC-11/BC-12**);
- the per-class retry asymmetry + distinct-task breaker (**BC-13/BC-14**);
- the two watchdog kill triggers — idle (**BC-22**, stretched by **BC-22-addendum/BC-60**) and post-terminal (**BC-59**) — which are independent and must both survive;
- the deliberate-stuck-is-not-a-failure routing (**BC-53/BC-54**) and the closed-but-not-shipped audit (**BC-56**);
- the standalone-degradation posture (**BC-43**) — a rewrite that hard-couples to the distributed tier breaks the bare-runner and conformance paths.

`SCAR (intent) / SCAFFOLDING (mechanism)` entries are the explicit "preserve the behavior, rebuild the bash" cases. The worker-prompt no-human premise (**BC-38**) and its prompt-layer async-human seam (**BC-55**), and the worker-stuck detection (**BC-53**), are the marked places where the rewrite's *context* changes — documented factually here, **not** designed.
