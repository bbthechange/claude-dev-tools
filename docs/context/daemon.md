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
  `notif-delivery-poll.sh` (N2) + `m6-dispatch.sh` (M6 bd-surgery).
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
| `desired-state-poll.sh` | **M3**: `daemon_m3_reconcile_all` → per-workspace `fetch_desired` (engine RunnerState) → spawn/SIGTERM state machine. Adopts the runner pidfile `<ws>/.beads/runner-logs/detached-runner.pid` (written by `launch-detached.sh`) as authoritative liveness. |
| `usage-poll.sh` | **M2**: one Keychain read + one Anthropic usage API call per machine, verdict written atomically to `$DAEMON_CACHE_DIR/capacity.json`; workspaces read it via `la__capacity_via_daemon`. Also the D2 machine-state producer (`_machine_state_emit`) + the daemon's outbox drain (`daemon_outbox_drain_once`). |
| `hosted-resolution-poll.sh` | **M4**: per-workspace poll for phone-answered dossiers; captures the resume-answer into the workspace store, flips the S-2 bfh record, and **classifies M5 vs M6** dispatch (`daemon_dispatch_for_state`). |
| `m6-dispatch.sh` | **M6**: when an answered dossier lands while the runner is busy on a DIFFERENT task, launch a short-lived READ-ONLY `claude -p` (reconciler hat) that does `bd` bookkeeping only (no Write/Edit, no commit). Daemon owns its lifecycle (`daemon_m6_kill_all` on exit). |
| `intake-dispatch-poll.sh` | **I3**: poll engine `intake-pending`; for each request whose `project_ref` is registered here, dispatch the enricher hat (`specialist.sh --kind=enricher`) → new bd task, then mark the record processed. Flow A. |
| `flow-f-overview-poll.sh` | **P1**: walk each workspace for closed beads with `stage:design`; dispatch a dossier-builder and push a `timed-fyi` overview dossier. Seed-flag suppresses the first-run backlog. |
| `work-control-reconcile-poll.sh` | **L2**: ask engine for BLOCKING dossiers still on the Inbox whose bead resolved outside the tap; publish `bead_status_changed` onto the daemon outbox so the engine expires the stale card. |
| `notif-delivery-poll.sh` | **N2**: rings the engine `notif-deliver` op — blocking sweep (~30s) + digest sweep (~daily). VAPID private key + ledger stay server-side; this only triggers. See `notifications.md`. |
| `launchd-plist.template` / `render-plist.sh` | The LaunchAgent definition + the ONE token-substitution function (`render_daemon_plist`) shared by install + drift-check. `EnvironmentVariables` (e.g. `USAGE_THRESHOLD=95`) load at bootstrap only. |
| `install.sh` / `uninstall.sh` | Render plist → `~/Library/LaunchAgents/` → `launchctl bootout` then `bootstrap` (bootout-first is load-bearing for env reload). |
| `check-plist-drift.sh` | Compares installed + launchd-loaded env against what `install.sh` would render now; prints `mismatches=0` when in sync. |

## Contracts & invariants (don't break these)

- **The per-workspace runner pidfile is the ONE liveness oracle.** Use
  `<ws>/.beads/runner-logs/detached-runner.pid` (written by `launch-detached.sh`)
  for `kill -0` / `kill -TERM`, never a `pgrep` count. Process-name matching
  inflates the count and mis-fires spawn/kill. M3 adopts whatever pidfile a prior
  boot left and reconciles off it.
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
- **README scope drift.** `daemon/README.md` is framed as "M1 skeleton, jobs land
  later" — that framing is stale; M2–M6 + I3/P1/L2/N2 all landed. Trust the code +
  this doc over the README's "what this is NOT — yet" section.

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
update: 2026-05-31.
