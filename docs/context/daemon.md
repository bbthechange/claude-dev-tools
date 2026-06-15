# Context: The per-machine daemon (Local Agent)

> One-liner: **one long-lived supervisor process per computer** — a launchd
> LaunchAgent that owns the workspace registry, spawns/kills the per-workspace
> runners to match engine desired-state, and polls Cloudflare for answered
> dossiers / intake / notifications. `pid_daemon ≠ pid_any_runner`.

**Read this doc when** your task touches: anything under `beads-runner/daemon/`,
a `*-poll.sh` job or its cadence, the launchd plist / install / drift check, the
workspace registry, or the M3 spawn/kill reconcile that keeps a runner alive.

**Owns / scope (the files this doc covers):**
- `daemon/daemon.sh` — the supervisor: pidfile, signal handlers, the heartbeat
  loop that drives every poll on its own cadence.
- `daemon/*-poll.sh` — the job family: `usage-poll.sh` (M2), `desired-state-poll.sh`
  (M3), `hosted-resolution-poll.sh` (M4), `intake-dispatch-poll.sh` (I3),
  `flow-f-overview-poll.sh` (P1), `work-control-reconcile-poll.sh` (L2),
  `notif-delivery-poll.sh` (N2), `timer-due-poll.sh` (N10-11) + `m6-dispatch.sh`
  (M6 bd-surgery).
- `daemon/workspace-registry.sh` — load/parse `~/.config/claude-tools/workspaces.json`.
- `daemon/install.sh` `uninstall.sh` `launchd-plist.template` `render-plist.sh`
  `check-plist-drift.sh` — the LaunchAgent install + drift-detector.
- `daemon/README.md` (authoritative; note its M1-scope framing is dated — the
  five jobs all landed).

**Not here (go to the right doc):**
- The per-workspace runner the daemon spawns/kills (`run-beads-tasks.sh`,
  `runner.sh`, `launch-detached.sh`) → `runner.md`. The daemon is the supervisor;
  the runner is the supervised.
- The engine it polls (`work-snapshot`, RunnerState, dossier records, the
  `intake-pending` / `notif-deliver` / `bead-status-changed` ops) →
  `engine-cloudflare.md`.
- The bash transport + caps it sources (`co-http-transport.sh`, `local-agent.sh`,
  `coordinator.sh` oracle) → `lib-shared.md`.
- The notification DELIVERY pipeline end-to-end (`notif-delivery-poll.sh` is the
  daemon's slice — it only *rings* the engine) → `notifications.md`.
- The worker/aux personas the polls dispatch (enricher, reconciler/bd-surgery,
  dossier-builder via `specialist.sh`) → `worker-agents.md`.

---

## Mental model

Three facts explain the daemon:

1. **It is a LaunchAgent, not a LaunchDaemon (AD1).** It runs in Brian's GUI login
   session — so it has macOS Keychain access and the user's network reachability,
   not root. launchd `KeepAlive=true` restarts it on crash; `RunAtLoad=true`
   starts it at login. This is the only mechanism satisfying the "reachable while
   the laptop is logged in but Brian is away from keyboard, auto-restart on crash"
   promise. A second SPOF is acknowledged here: daemon down ⇒ that machine goes
   dark for new desired-state transitions until launchd relaunches it.

2. **One heartbeat loop, many cadenced polls.** `daemon.sh main()` loops every
   `HEARTBEAT_INTERVAL` (10s) and, on each tick, fires any poll whose interval has
   elapsed (`_last_*_poll` timestamps gate them). Most polls also fire **at boot**
   (the `|| [ "$_last_*" -eq 0 ]` arm) so a state change that happened while the
   daemon was down is reconciled promptly — the one exception is the notif *digest*
   sweep, deliberately seeded-not-fired at boot to avoid dumping a backlog.

3. **Observe-first, single-writer.** The daemon never writes a heartbeat for a
   runner or re-derives state it doesn't own. On a Coordinator-unreachable poll it
   takes **no action** (won't spawn, won't kill on uncertainty — the next cadence
   retries). When it SIGTERMs a runner, the *runner* writes its own
   `actual=stopped`. The daemon is a supervisor, not the source of truth.

The **M3 reconcile** is the load-bearing job: `desired=running` (or `spare-cycles`)
+ no live runner ⇒ spawn via `launch-detached.sh`; `desired=stopped` + live runner
⇒ SIGTERM it; `paused` ⇒ leave alive but don't spawn a dead one. This is the loop
that makes `stopped → running` round-trips from the phone survive a dead/absent
runner (Flow D), bounded to ≤ one `DESIRED_STATE_POLL_INTERVAL` (60s).

## Key files

| File | Role |
|---|---|
| `daemon.sh` | The supervisor. pidfile (single-instance, refuses double-start), `trap` handlers (TERM/INT = drain, HUP = reload registry), the `main()` heartbeat loop that gates every poll by cadence. Sources every `*-poll.sh`. |
| `workspace-registry.sh` | `registry_load`/`registry_count` → parses `workspaces.json` into `REGISTRY_DIRS[]`/`REGISTRY_PROJECT_REFS[]`/`REGISTRY_COORDINATOR_URLS[]`/`REGISTRY_TOKEN_KEYCHAIN_ITEMS[]`. The daemon's index of "workspaces this machine owns." |
| `desired-state-poll.sh` | **M3**: `daemon_m3_reconcile_all` → per-workspace `fetch_desired` (engine RunnerState) → spawn/SIGTERM state machine. Adopts the runner pidfile `<ws>/.beads/runner-logs/detached-runner.pid` (written by `launch-detached.sh`) as authoritative liveness. `daemon_m3_spawn` also honors the v2 cutover marker `use-runner-v2` (`daemon_m3_uses_v2` ⇒ spawn `runner.sh` with `RUNNER_BACKEND=real`; absent ⇒ v1 byte-for-byte unchanged — claude-tools-v2c4). |
| `usage-poll.sh` | **M2**: one Keychain read + one Anthropic usage API call per machine, verdict written atomically to `$DAEMON_CACHE_DIR/capacity.json`; workspaces read it via `la__capacity_via_daemon`. Also the D2 machine-state producer (`_machine_state_emit`) + the daemon's outbox drain (`daemon_outbox_drain_once`). |
| `aux-dispatch-gate.sh` | **I5-cap** (claude-tools-pof7): the aux-pool budget guard. `daemon_aux_capacity_ok [cost_class]` reads `capacity.json` (same 2× `USAGE_CACHE_SECONDS` staleness as `la__capacity_via_daemon`) and SUPPRESSES on a fresh over-budget signal; `daemon_aux_dispatch_guard <kind> <cmd…>` is the run-iff-allowed wrapper. Gates on the **cheaper `low_priority`** class (dropped before the writer's `standard`); **fail-OPEN** on a missing/stale signal (the daemon is the cache producer). Pure read — no record/table (Contract A.2). I5 (uxvi5) consumes it; strict no-op until then. |
| `hosted-resolution-poll.sh` | **M4**: per-workspace poll for phone-answered dossiers; captures the resume-answer into the workspace store, flips the S-2 bfh record, and **classifies M5 vs M6** dispatch (`daemon_dispatch_for_state`). |
| `m6-dispatch.sh` | **M6**: when an answered dossier lands while the runner is busy on a DIFFERENT task, launch a short-lived READ-ONLY `claude -p` (reconciler hat) that does `bd` bookkeeping only (no Write/Edit, no commit). Daemon owns its lifecycle (`daemon_m6_kill_all` on exit). |
| `intake-dispatch-poll.sh` | **I3**: poll engine `intake-pending`; for each request whose `project_ref` is registered here, dispatch the enricher hat (`specialist.sh --kind=enricher`) → new bd task, then mark the record processed. Flow A. **L4 (claude-tools-uxvl4) branch:** if `preset == overview-request` (the SPECIAL no-bd-task catalog preset, `routing:"overview-fyi"`), `daemon_intake_dispatch_one` routes to `daemon_intake_dispatch_overview` INSTEAD of the enricher — it spawns a **dossier-builder** (`specialist.sh --kind=dossier-builder`), shapes its `{body,items}` into a `kind=overview`/`trigger=proactive_checkpoint`/`tier=timed-fyi` §4.1 envelope (`bead_ref` = the synthetic intake_id; §4.1 only needs a non-empty string), and emits via the SAME `dg_generate + no_emit/no_dispatch + tf_arm` sequence as Flow F (kept intake-local in `_daemon_intake_overview_engine_write`; override hook `DAEMON_INTAKE_OVERVIEW_ENGINE_OVERRIDE`). **No `bd create` ever runs** — the record is marked `processed` with `dispatch_state:"overview"` + `overview_dossier_id` (NO `enricher_bd_id`), and miscarriages ride the same failing(n)→gave_up retry machine. A clean builder refusal is terminal (processed, no retry). |
| `flow-f-overview-poll.sh` | **P1**: walk each workspace for closed beads with `stage:design`; dispatch a dossier-builder and push a `timed-fyi` overview dossier. Seed-flag suppresses the first-run backlog. **Also hosts the H5 (claude-tools-uxvh5) blueprint-update trigger path** — `daemon_blueprint_update_should_trigger` (coarse gate: `stage:design\|impl\|docs`), `daemon_blueprint_update__shape_timed_fyi` (the §6.5 unification: a Blueprint change shapes the SAME `kind=overview`/`timed-fyi` gi as the Flow F overview — NOT a 2nd mechanism), and the synchronous `daemon_blueprint_update_dispatch_one` (spawn the read-only `blueprint-update` hat → on a material change `blueprint-put` + emit ONE timed-fyi via the shared `_daemon_flow_f_engine_write`). **I5 (`uxvi5`) made it LIVE + PARALLEL** (canary now `DAEMON_BLUEPRINT_UPDATE_DISABLED=0`): `daemon_blueprint_update_poll_once` (wired into the main loop on `BLUEPRINT_UPDATE_POLL_INTERVAL`, 60s + boot-fire) walks each workspace for NEW closed structural beads (`stage:design\|impl\|docs`) and **detaches** a read-only hat per bead via the M6 nohup/disown idiom (`daemon_bu_dispatch_detached`) so it runs truly parallel to the per-workspace serial writer. Every spawn is routed through the **I5-cap capacity gate** (`daemon_aux_capacity_ok`, `low_priority`), **deduped per bead** (`$DAEMON_CACHE_DIR/blueprint-update-fired/`, plus a first-run seed flag that suppresses the backlog — same shape as `flow-f-overview-fired/`), and **single-flight** via a per-bead pidfile (`$DAEMON_CACHE_DIR/blueprint-update-dispatch/pids/`). The aux NEVER takes the writer lease and is read-only BY CONSTRUCTION (specialist.sh `blueprint-update` permission set). Drain hook: `daemon_bu_kill_all` (in `on_exit`). Off-switch: set `DAEMON_BLUEPRINT_UPDATE_DISABLED=1`. **fyi-pending lane (claude-tools-49rx):** a material change does `blueprint-put` FIRST then ONE timed-fyi; if that emit transiently fails the unit stashes the shaped gi in `DAEMON_BLUEPRINT_UPDATE_LAST_GI`, the markability policy parks a `fyi-pending` marker (`$DAEMON_BU_PENDING_DIR`, SEPARATE from `fired/`), and the poll re-emits ONLY the FYI next cadence (`daemon_bu_retry_pending_fyi`, checked BEFORE `already_fired`, no hat, not capacity-gated) → on success promotes to a `fired` marker. Closes the "transient FYI failure → hat regen is idempotent → ping silently lost" edge. |
| `work-control-reconcile-poll.sh` | **L2**: ask engine for the TIMER-LESS dossiers still on the Inbox (`daemon_wc__select_open_beads`: tier ∈ {blocking, **digest**} — timed-fyi EXCLUDED, it rides its own §2.2 timer) whose bead resolved outside the tap; publish `bead_status_changed` onto the daemon outbox so the engine expires the stale card. **digest was added (claude-tools-o2mk)** because a §5.6-DEFERRED card is lowered blocking→digest WITHOUT arming a timer (digest≡no-armed-timer: `timer.js` tfArm soft-disarms every non-timed-fyi tier, so the tier predicate is exact with no Contract-B field). Engine re-checks per dossier as defense-in-depth (`beadStatusChanged` skips only `timer_fire_at != null`). **claude-tools-fyci** then made `dossierSetAttention` (defer/escalate) null `timer_fire_at` + soft-disarm when it moves a card OUT of timed-fyi, so digest≡no-armed-timer holds for the STORED record too — closing the one former row where the engine's `timer_fire_at` skip and this daemon tier predicate disagreed. See bd memory l2-autoclose-tier-scoping. |
| `notif-delivery-poll.sh` | **N2**: rings the engine `notif-deliver` op — blocking sweep (~30s) + digest sweep (~daily). VAPID private key + ledger stay server-side; this only triggers. See `notifications.md`. |
| `attention-poll.sh` | **iz36** (claude-tools-iz36): the MACHINE-ATTENTION observability poll. Reads the engine's top-level `work-snapshot.attention` field (singleton call, the N2 workspace[0] pattern; ~60s + boot-fire) and emits an EDGE-triggered structured `WARN MACHINE ATTENTION workspace=… kind=stale-runner …` per sustained wanted-running-but-wedged runner — the observability half of the jzzw incident (the daemon log was its diagnosis site). Markers in `$DAEMON_CACHE_DIR/attention-fired/` dedup (no 60s storm), re-log at most hourly while ongoing (`DAEMON_ATTENTION_RELOG_SECONDS`, 0 disables), and `RESOLVED` + remove on clear. Observe-first: an empty/unreachable snapshot does NOT flap RESOLVED. Off-switch `DAEMON_ATTENTION_DISABLED=1`. The detection is the consumer SCAFFOLD the deferred digest PHONE-push follow-up extends. Defines `daemon_attention_poll_once`. |
| `timer-due-poll.sh` | **N10-11** (claude-tools-buoz): the §2.2 timer CLOCK. Rings the engine's COMPOSITE `timed-fyi-poll` driver op (~60s + boot-fire) — that op (`cf/src/timer.js` `fireDueTimers`) lists every due §2.2 timer and FIRES it server-side, ROUTING by the dossier's §4.1 kind: `kind:"pair"` ⇒ `pairSurface` (ready-to-pair surface + blocking notif), else ⇒ `fireDossier` (timed-fyi S-6 auto-proceed). Rings the COMPOSITE op, NEVER the bare substrate `timer-due` (which only LISTS ids — does not fire). No `now` arg (engine owns the clock). Singleton-DO call (workspace[0] url+bearer, N2 pattern), not per-workspace. There is NO alarm daemon — this poll IS the S-6 backstop. Closed audit gap wzejgmopj (engine timer.js was live but nothing rang it in prod). |
| `launchd-plist.template` / `render-plist.sh` | The LaunchAgent definition + the ONE token-substitution function (`render_daemon_plist`) shared by install + drift-check. `EnvironmentVariables` (e.g. `USAGE_THRESHOLD=95`) load at bootstrap only. |
| `install.sh` / `uninstall.sh` | Render plist → `~/Library/LaunchAgents/` → `launchctl bootout` then `bootstrap` (bootout-first is load-bearing for env reload). |
| `check-plist-drift.sh` | Compares installed + launchd-loaded env against what `install.sh` would render now; prints `mismatches=0` when in sync. |

## Contracts & invariants (don't break these)

- **The per-workspace runner pidfile is the ONE liveness oracle.** Use
  `<ws>/.beads/runner-logs/detached-runner.pid` (written by `launch-detached.sh`)
  for `kill -0` / `kill -TERM`, never a `pgrep` count. Process-name matching
  inflates the count and mis-fires spawn/kill. M3 adopts whatever pidfile a prior
  boot left and reconciles off it.
- **Daemon↔runner rendezvous files live at the FIXED `.beads/runner-logs` path,
  never under a per-workspace `LOG_DIR` override.** `agent-action-poll.sh`'s
  `daemon_aa_control_marker_dir` hardcodes `<ws>/.beads/runner-logs/agent-action`
  (the I4 stuck-action control markers the runner watchdog reads) — this is
  INTENTIONAL and frozen (design/agent-action.md §4), not a stray literal: the
  daemon supervises many workspaces and never sources `<ws>/.beads/runner.sh`, so
  it cannot know a workspace's `LOG_DIR`. Do NOT "fix" it toward `LOG_DIR`; the
  symmetry is held on the RUNNER side instead (runner.sh `st_run_task` pins its
  watchdog scan dir to the same fixed path — claude-tools-wqx7). Same principle as
  the `detached-runner.pid` rendezvous `launch-detached.sh` pins there.
- **`coordinator_token_keychain` is a Keychain item NAME, never the token.** It is
  dereferenced at use time via `security find-generic-password -s <item> -w`. No
  bearer ever lands in `workspaces.json` (BC-34 / §9.2 posture).
- **Observe-first on uncertainty.** A poll that can't reach the Coordinator does
  NOTHING (no spawn, no kill) — the daemon is more conservative than the runner's
  fail-OPEN. A running runner keeps running; a dead one stays dead.
- **Single-writer:** the daemon SIGTERMs; the runner writes its own terminal
  heartbeat. Never have the daemon write an `actual` state for a runner.
- **Every poll returns 0 / `|| true`.** One workspace's failure must not abort the
  driver or the heartbeat loop. Per-workspace errors are logged and retried next
  cadence.
- **Plist env loads at bootstrap, not edit.** Editing `launchd-plist.template` is a
  SILENT no-op until `install.sh` re-renders AND bootout→bootstraps. `.stop-beads`
  cycles the *runner*, not the LaunchAgent.

## Common changes (recipes)

**Adding a new daemon poll job:**
1. New `daemon/<job>-poll.sh` exporting `daemon_<job>_poll_once` (always returns 0).
   Resolve the workspace via `REGISTRY_*` arrays; reach the engine the way
   `notif-delivery-poll.sh` does (workspace[0] `coordinator_url` + Keychain bearer
   → `co_request`) for a singleton call, or per-workspace like M3.
2. Add a `BEADS_DAEMON_<JOB>_POLL_INTERVAL` env + default near the top of `daemon.sh`.
3. `.` source it in `daemon.sh` (after the registry + transport sources).
4. Add a `_last_<job>_poll` var + a cadence gate in `main()`'s loop (copy an existing
   block; add the `|| [ "$_last_<job>_poll" -eq 0 ]` boot arm unless boot-fire would
   dump a backlog — see the digest sweep counter-example).
5. Add a focused `test-<job>.sh` (auto-enrolls into the `daemon` tier by glob).
6. **Run the gate:** `bash beads-runner/run-tests.sh --tier daemon` (or `--changed`).

**Changing a cadence or a plist env value:** edit the default in `daemon.sh` (env
overrides win) for a cadence; for a plist env, edit the template AND
`bash beads-runner/daemon/install.sh` to re-render + re-bootstrap, then
`bash beads-runner/daemon/check-plist-drift.sh` until it prints `mismatches=0`.
The drift check is the "done means verified" gate for any plist change.

## Gotchas / scars

- **A long-lived daemon runs STALE in-memory code (claude-tools-jzzw, incident
  2026-06-14).** `daemon.sh` sources every `*-poll.sh` ONCE at boot; the running
  process never re-reads them. So a daemon that booted before a poll landed silently
  lacks that poll forever. Real failure: the daemon booted Jun 1, the agent-action
  queue poll (I4) landed Jun 2 + local-first M3 (y6j9) Jun 6 — so for ~2 weeks every
  phone Run/Stop tap piled up un-acked in the engine `agent_actions` queue (the daemon
  that should drain it didn't have the drainer), no local `runner_state.*.json` was
  ever written, and runners wedged (process alive, heartbeat stale for days). FIRST
  CHECK when "taps do nothing": `ps -p $(cat ~/.cache/claude-tools/daemon.pid) -o lstart`
  vs the mtime of `daemon/*.sh` — if the process predates the code, `launchctl
  kickstart -k gui/$UID/com.beads-runner.daemon` and it self-heals (drains the queue,
  writes local desired, respawns runners). NOTE `kickstart -k` also reaps runners
  sharing the daemon's process group, so they ALL respawn fresh (a feature here).
  **FIXED (jzzw): the daemon now SELF-DETECTS this and re-execs.** Each heartbeat
  (gated by `STALENESS_CHECK_INTERVAL`, 60s) `daemon_reexec_if_stale` compares the
  newest mtime of its sourced files (`daemon.sh` + `*-poll.sh` glob + the named
  non-poll helpers; `test-*.sh` and operator scripts excluded) against the captured
  `DAEMON_SELF_START_EPOCH`; on a strictly-newer-and-not-future mtime it logs
  `STALE SOURCE DETECTED` and `exec`s `/bin/bash daemon.sh` (same PID under launchd,
  fresh source). `exec` skips the EXIT trap, so the pidfile is left in place —
  `acquire_pidfile` reclaims its OWN pid post-exec (the `existing == $$` arm). The
  future-mtime guard (`newest ≤ now`) prevents a clock-skew re-exec loop; the child
  recomputes a fresh epoch because `DAEMON_SELF_START_EPOCH` is NOT exported.
  Off-switch `BEADS_DAEMON_SELF_REEXEC=0`. NOTE the self re-exec only refreshes the
  DAEMON's code (not the runners — `exec` doesn't reap the process group the way
  `kickstart -k` does); a stale-RUNNER detector is a separate open follow-up. `main`
  is now guarded (`[[ BASH_SOURCE == $0 ]]`) so tests can source daemon.sh.
- **Process-count inflation.** Do not count `claude`/`run-beads-tasks` processes to
  decide liveness — the authoritative signal is the per-workspace
  `detached-runner.pid`. A `pgrep` heuristic double-counts and mis-spawns.
- **Plist drift (claude-tools-6s6x).** Template said `USAGE_THRESHOLD=95`, the live
  daemon enforced the old `85` for hours because nobody re-bootstrapped. The fix
  is `render-plist.sh` as the single substitution source + `check-plist-drift.sh`
  as the detector + bootout-before-bootstrap in `install.sh`. Treat any plist edit
  as not-done until `mismatches=0`.
- **SIGHUP reloads the registry, doesn't restart.** `kill -HUP "$(cat ~/.cache/claude-tools/daemon.pid)"`
  re-reads `workspaces.json` and resets M3's per-workspace last-observed-desired
  memory (so a removed workspace doesn't keep a phantom slot). No process bounce.
- **Boot-fire vs backlog dump.** Most polls intentionally fire at boot to catch
  state changes from the down-window; the notif *digest* sweep is the deliberate
  exception (seed-only at boot) — N pending must fold to ONE push, never N
  (must-protect #5).
- **The daemon outbox is separate from the workspace outbox.** `usage-poll.sh`
  appends capacity + machine_state lines to its OWN outbox; `daemon_outbox_drain_once`
  (run every heartbeat) ships them. `run-beads-tasks.sh` drains only the *workspace*
  outbox — forgetting the daemon drain left `machines[]` empty in the projection
  (claude-tools-1p0u).
- **Hat stdout drifts a prose preamble (claude-tools-03q2).** The `blueprint-update`
  hat is told to print EXACTLY one JSON object, but opus prepended a sentence
  ('… Emitting v1.') before it — the old strict `jq type=="object"` parse failed
  ⇒ silent `parse-failed`, no write, no FYI. `daemon_blueprint_update_dispatch_one`
  now parses via `daemon_blueprint_update__extract_json` (raw bytes first, then a
  first-`{`…last-`}` slice) with a SLURP single-object guard (`jq -cs length==1`)
  so a multi-value drift — array-of-objects, two bare objects — fails safe instead
  of silently picking the first value. Any new "parse a hat's single-JSON stdout"
  site should reuse this tolerant pattern, not a bare `type=="object"`.
- **README scope drift.** `daemon/README.md` is framed as "M1 skeleton, jobs land
  later" — that framing is stale; M2–M6 + I3/P1/L2/N2 all landed. Trust the code +
  this doc over the README's "what this is NOT — yet" section.
- **A material-change blueprint redraw writes the map BEFORE the ping, so a
  transient ping failure must NOT re-run the hat (claude-tools-49rx).** The hat's
  regen is idempotent: once the map is written it reports `material_change=false`,
  so re-running it on the next cadence yields `no-change` (terminal) and the owed
  `timed-fyi` overview ping is silently lost. The fix is the `fyi-pending` lane:
  `daemon_blueprint_update_dispatch_one` stashes the shaped gi in
  `DAEMON_BLUEPRINT_UPDATE_LAST_GI` on a map-written-FYI-lost `fyi-failed`;
  `daemon_bu__mark_by_outcome` parks a marker in `$DAEMON_BU_PENDING_DIR` (kept
  SEPARATE from `fired/` so `already_fired` stays an O(1) `-f` check and a pending
  bead is NOT read as done); `daemon_bu__poll_workspace` checks
  `daemon_bu_pending_exists` FIRST and re-emits ONLY the FYI (idempotent — the
  deterministic id `overview-<bead_ref>` upserts at both engines), promoting to a
  `fired` marker on success. Any future "write-then-notify" daemon step where the
  write is idempotent but the notify is owed should reuse this park-and-retry-only
  shape, not a terminal marker on the notify failure. (A pending marker for a bead
  that later leaves the structural-close set is an orphaned file, same cosmetic
  property as `fired/`; not GC'd, not a correctness issue.)
- **Don't capture a per-workspace poll's count via `$(…)` if it also `log`s
  (claude-tools-uxvi5).** `log()` writes to stdout (launchd captures it), so a
  driver doing `c="$(daemon_*__poll_workspace "$i")"` SWALLOWS every per-bead
  `log` line into `$c` AND pollutes the count (no longer a bare integer ⇒ the
  `=~ ^[0-9]+$` guard zeroes it ⇒ the summary line never fires, and the
  fire-and-forget launch trace never reaches the daemon log). Both the I5
  blueprint-update poll and its Flow-F sibling now report the count via a GLOBAL
  (`DAEMON_BU_WS_DISPATCH_COUNT` / `DAEMON_FLOW_F_WS_DISPATCH_COUNT`) and call the
  per-workspace function DIRECTLY (not in a subshell) so its `log` lines survive.
  Any new per-workspace poll that both logs and counts must do the same.

- **The daemon is the SECOND desired-state reader AND the SINGLE change-request consumer
  (claude-tools-dky8/y6j9 P1 SHIPPED).** M3 `daemon_m3_reconcile_workspace` now reads
  `daemon_m3_read_local_desired` (a direct `.co-store/records/runner_state.<pref>.json` read)
  FIRST; the old network `daemon_m3_fetch_desired` is demoted to a cold-start SEED used ONLY when
  the local read is empty — so a present local paused/stopped survives a Coordinator-unreachable
  window (the break-through-pause fix, daemon half; the daemon's observe-first no-action-on-empty
  posture is unchanged and was always correct — it was the RUNNER's fail-OPEN that was wrong).
  Brian's Stop/Run taps ride the `agent_actions` queue's NEW `set-desired` intent (NOT a new §4
  record): `agent-action-poll.sh` `daemon_aa_dispatch_one` gains a `set-desired` arm →
  `daemon_aa_set_local_desired` writes the LOCAL record via the in-process `co__set_desired`
  (apply-local-BEFORE-ack; deliberately does NOT source co-http-transport, so the write lands
  locally not on the cloud; `co__ensure_store` first since the store was inert in PROD). The
  daemon is the SINGLE local-desired writer (a STOPPED/dead runner can't apply "running" to
  itself) — the live runner just READS local on its own reconcile, so they cannot disagree. Both
  pin `CO_STORE` to the shared `<ws>/.beads/runner-logs/.co-store` (the
  `hosted-resolution-poll.sh:122` rendezvous precedent). Regression-lock: PART H of
  `test-m3-desired-state.sh` (also made hermetic — it now `unset`s COORDINATOR_URL like
  test-agent-action-poll.sh) + the set-desired arm of `test-agent-action-poll.sh`.

## Go deeper

- `beads-runner/daemon/README.md` — on-disk layout, registry schema, operator
  runbook (install/verify/stop/uninstall/SIGHUP).
- `docs/runbooks/daemon-control.md` — install, start, stop, inspect; the `launchctl
  print gui/$UID/com.beads-runner.daemon` verification commands.
- `beads-runner/DESIGN.md` §3.2 / §3.3 / §7 + AD1 / AD8 — the five daemon jobs, the
  LaunchAgent-not-LaunchDaemon decision, the resume-dispatch + M5/M6 boundary.
- `beads-runner/MACHINE-STATE.md` (D2) — the frozen machine-state contract the
  usage poll's `_machine_state_emit` producer binds.

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a new poll job + its cadence env, a changed liveness oracle, a
moved/renamed helper, a fresh plist scar, a new invariant. **Keep it concise — this
doc earns its keep only if agents read all of it.** Delete lines that have gone
stale; don't let it grow into a copy of DESIGN.md or the README. Last substantive
update: 2026-06-14 (iz36: `attention-poll.sh` — the machine-attention observability
poll reads the engine `work-snapshot.attention` field and edge-WARNs each sustained
wanted-running-but-wedged runner; the jzzw incident follow-up #3). Prior:
2026-06-14 (jzzw: the daemon SELF-STALENESS re-exec — `daemon_reexec_if_stale`
self-heals a daemon running code older than its source; the `expired`-status
`agent_actions` TTL/GC engine-side bounds the queue so taps can't replay en masse;
`agent-action-poll.sh` logs a `WARN ... queue BACKLOG` when a large pending batch
lands — see the FIXED scar above). Prior: 2026-06-06 (local-first: the daemon is the
second desired-state reader + the cold-start change-request consumer —
claude-tools-dky8 / P1 claude-tools-y6j9). Prior:
2026-06-05 (claude-tools-49rx added the blueprint-update `fyi-pending`
lane — a transient timed-fyi failure after the map write parks the gi and
re-emits ONLY the FYI next cadence instead of re-running the now-idempotent hat;
the write-then-notify scar above). Prior: 2026-06-04 (I5/`uxvi5` made the
blueprint-update path LIVE + PARALLEL —
`daemon_blueprint_update_poll_once` detaches a read-only hat per NEW structural
close, capacity-gated + per-bead-deduped + drain-killed; canary flipped to 0; the
swallowed-poll-count scar above. Prior: 2026-06-03 N10-11 `timer-due-poll.sh`).
