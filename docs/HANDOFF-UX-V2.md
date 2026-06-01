# Handoff — UX v2 expansion: tracking, anti-drift, and how to drive it

Last updated: 2026-05-31 · Author: the "architect" session
Audience: the next agent (or human) picking up the UX v2 overhaul — to keep it
on-track, keep the parallel agents from drifting apart, and expand/adapt it.

> **Read order:** this doc → `docs/HANDOFF.md` (the older rescue-epic operational
> map; still the source of truth for the daemon/runner/engine plumbing) →
> `beads-runner/UX-DESIGN-V2.md` (the WHAT) → `beads-runner/UX-V2-ARCHITECTURE.md`
> (the anti-drift contracts) → the four design docs in `beads-runner/design/`.

---

## 0. The one-paragraph picture

There is a large UX expansion in flight, filed as epic **`claude-tools-mhcp`**
(label `ux-v2`). It is being built **autonomously** by the beads runner swarm —
many fresh `claude -p` workers, one bead at a time per workspace. My job this
session was **not** to write the features; it was to (1) decompose the UX doc
into beads sized for one agent each, (2) write a **contracts layer** so the
independent agents don't drift apart, (3) **review** what the swarm produced
before it compounds, (4) **fill coverage gaps** so we don't ship "a shadow of
the experience," and (5) keep the queue/branch/process plumbing healthy so work
actually flows. A second epic, **`claude-tools-v2cut`**, finishes and cuts over
the v2 runner rewrite (the runner features land there, not on live v1). This doc
is how to keep doing all of that.

---

## 1. System topology — the mental model you MUST have

Three tiers, three separate programs (do not conflate them — the naming bites
everyone):

```
┌─ PER-MACHINE DAEMON ── one per computer, launchd LaunchAgent ───────────┐
│  beads-runner/daemon/daemon.sh  (com.beads-runner.daemon)               │
│  • auto-restarts on login/reboot (launchd)                              │
│  • owns the workspace registry (~/.config/claude-tools/workspaces.json) │
│  • polls Cloudflare for desired-state per workspace                     │
│  • SPAWNS / SIGTERMs the per-workspace runners (launch-detached.sh)     │
│  • polls Cloudflare for answered dossiers; dispatches read-only aux     │
└─────────────────────────────────────────────────────────────────────────┘
        │ desired=running + no runner ⇒ M3 respawn (≤60s)
        ▼
┌─ PER-WORKSPACE RUNNER ── one per project ──────────────────────────────┐
│  beads-runner/run-beads-tasks.sh   ← "v1" (default — 4 of 5 workspaces) │
│  beads-runner/runner.sh            ← "v2" (state machine — PILOTING     │
│                                       LIVE on rhythmGame; per-workspace  │
│                                       use-runner-v2 marker (v2c4)        │
│  • while-loop: bd ready → pick → spawn one worker → repeat              │
│  • per-bead auto-commit on whatever branch HEAD is on                   │
└─────────────────────────────────────────────────────────────────────────┘
        │ one fresh process per task
        ▼
┌─ PER-TASK WORKER ── ephemeral `claude -p` ─────────────────────────────┐
│  does the actual bead; calls ask-brian MCP when it hits a human fork    │
└─────────────────────────────────────────────────────────────────────────┘
```

**Naming traps that cost me real time — internalize these:**
- **"the runner"** = the *per-workspace* task loop (`run-beads-tasks.sh`). The
  *central* per-computer thing is **the daemon**, never called "the runner."
- **v1 vs v2** is a split *inside* the per-workspace runner only. v1
  (`run-beads-tasks.sh`) is LIVE; v2 (`runner.sh`) is the not-yet-deployed
  rewrite. The daemon has no v1/v2 fork.
- **`runner.sh`** (the v2 script) vs **`<workspace>/.beads/runner.sh`** (the
  per-workspace *config* file v1 reads) — same filename, totally different role.
- **"restart the runner"** is automatic: the daemon respawns it whenever
  `desired=running` and no runner is alive. You control the *branch* it comes
  back on, not the start itself.

Engine = Cloudflare Worker `coordinator-cf.bbthechange.workers.dev` (singleton
Durable Object + D1). Phone-facing web app is Cloudflare Pages project
`claude-wrangler` (Board/Inbox/Intake today; the v2 app-shell adds more).

---

## 2. The two epics

### `claude-tools-mhcp` — the UX v2 overhaul (label `ux-v2`)
The WHAT is `beads-runner/UX-DESIGN-V2.md` (Flows A–L, surfaces §2, lifecycle
§3, queue-health §9, notifications §10, principles §11, coverage §12, open
questions §14). Tracks:
- **H** Blueprint (living design+map) · **J** Gates/unified-Hold · **I**
  Activity/parallel-runners/monitoring · **K** Cross-workspace sync · **Q**
  Queue-health · **L** Inbox/intake leak-fixes · **N** Notifications · **C**
  the app-shell (built once, gates every facet UI).
- Each track had a **DESIGN bead** (delegate-able) that produced a design doc in
  `beads-runner/design/{blueprint,gates,activity,cross-ws,notifications}.md`,
  then **impl beads** blocked on that design. Designs are all closed.

### `claude-tools-v2cut` — finish + cut over the v2 runner (label `v2-cutover`)
Decision (Brian, 2026-05-30): build the new **runner-touching** features on the
clean v2 state machine *while it's offline*, then one controlled cutover —
rather than patching the live v1 loop that launches this project's own agents.
Phases `v2c0…v2c5` (gap-analysis → port-forward → finish-seams → conformance-
GREEN → staged cutover → retire v1). `v2c0`/`v2c2` done; gap analysis is in
`beads-runner/design/v2-gap.md`. **The two ux-v2 runner beads `uxvj4` (gate
pickup) and `uxvi1` (activity log-parser) are gated behind `v2c3`** (v2
conformance-green) so they land on v2, not v1. `uxvi5` (parallel aux dispatch)
is daemon work, unaffected.
- **Bar for cutover (do not soften):** v2 is rewrite-complete + was conformance-
  green when its epic `glk` closed, BUT it drifted behind v1 and its green
  harness may not cover v1's battle-fixes. `v2c3` acceptance = "v2 provably
  matches-or-exceeds v1," not "old harness still passes" — audit harness
  coverage, regression-lock every ported fix.

---

## 3. The anti-drift method — THIS is the core of what to continue

The failure mode this whole apparatus fights is **drift**: N parallel fresh-
context agents each build half a seam and the halves don't meet. This repo has a
documented scar (the "wired-but-not-actually-live" family: `4xe 2dk bgw 56h
qxz`). The defense, in order of leverage:

### 3.1 The contracts doc is law: `beads-runner/UX-V2-ARCHITECTURE.md`
Four contracts every bead conforms to. A bead violating them is *wrong*, not
creative. When reviewing or filing, check against these:
- **Contract A** — backend op/data conventions. The end-to-end "adding an op"
  checklist (module → coordinator guard → Pages function → **local adapter** →
  migration → **live-verify before close**). A.2 = the §4-record-vs-transient
  decision rule. A.3 = the projection-field rule (56h fix). *The adapter and
  live-verify steps are the ones agents forget.*
- **Contract B** — the read-model projection (`work-snapshot`). ONE JSON shape
  is the backend↔frontend seam. **Each track owns a named sub-object**
  (`activity`, `holds`, `queue_health`, `blueprint_meta`) so four agents editing
  `reconcile.js workSnapshot()` don't collide. New UI field ⇒ named in B ⇒
  emitted by `workSnapshot()`. Never read a key B doesn't promise.
- **Contract C** — the app-shell. `web/shared/` (net/dom/tokens/shell), the
  Workspace-hub nav (5 global + 4 facet routes), pure `deriveXView` UMD +
  Node-test pattern. Built once (C-shell, done); every facet UI plugs in.
- **Contract D** — vocabulary & closed enums. Blueprint vs Dossier; Hold/Gate/
  Checkpoint (fixes the real "gate" collision); the activity-state enum
  (90/180 liveness thresholds — measured, do NOT tighten).

### 3.2 Beads dependencies ARE the drift guard — wire them, trust them
- **DESIGN beads block their impl beads.** Impl can't be claimed until its
  design is done. (This is "the whole point of beads" — Brian's words.)
- **C-shell blocks every facet UI.**
- **Reconciliation/gap work blocks the specific dependents it touches**, never a
  blanket freeze. *(I tried a blanket `human-action` HOLD bead once; Brian
  rightly rejected it — it leaves you coming back to nothing. Use targeted
  `blocked-by` edges; let everything else flow.)*
- Verify with `bd dep tree <epic>` and `bd dep cycles` after wiring.

### 3.3 Review the swarm's output before it compounds
The high-value recurring task. When asked to "check progress / make sure things
fit," run **two audits** (I did this with parallel general-purpose agents):
1. **Design-quality audit** — do the produced design docs conform to A/B/C/D? Are
   they substantive or a shadow? Do their self-proposed impl splits DIVERGE from
   the filed beads (reconcile if so)? Do sibling designs agree where they touch
   (e.g. who spawns the xws-responder — K1 vs I5)?
2. **Coverage audit** — go section-by-section through UX-DESIGN-V2 and map every
   capability → a bead or a **GAP**. Lean toward flagging; a false "covered" is a
   wasted weekend. This is how the gap beads below got found.

### 3.4 Gaps found + filed this session (so you don't re-discover them)
Real coverage holes the audits caught, now beads under `mhcp`:
- **push DELIVERY to the phone** (N1 only wired triggers; nothing delivered) →
  `uxg1`/N2 (built on the n2 branch) + DESIGN N.
- **done·code vs done·verified** Board sub-state (`uxg2`, done) — the anti-
  "wired-but-not-live" feature itself.
- **dossier↔Blueprint focus bridge** `?focus=` (`uxg3`).
- **preserve Flow G failure view through the shell rebuild** (`uxg4`, done).
- **Blueprint in-flight overlay** (`uxg5`).
- **ready-to-pair scheduled session** (`uxg6`/N3).
- **cross-WS scope-check guardrail** (`uxg8`, done).
- **control-plane `agent-action` op** — J3 lift-gate and I4 stuck-actions both
  need a host-side executor the web tier can't do; neither design froze it
  (`uxcap`, done).
- **L1 shipped 2 of 5 verbs** — defer/escalate still open (`uxl1b`, done).
- **inbox state-integrity re-check** post-L1 (`uxa2`).

---

## 4. Operational gotchas learned the hard way this session

These cost real time or caused real breakage. Heed them.

1. **Tool-output channel buffers badly.** Results frequently arrive ~8 calls
   late, and **batching multiple bash calls amplifies it and has caused a
   cancelled-cascade that left a half-finished merge**. → **Use sequential,
   single bash commands for anything stateful (git, bd writes).** Write results
   to a `tmp/*.txt` file and read it back when you need to be sure.
2. **`bd update --labels` silently no-ops** — it appeared to set labels but
   `bd label list` showed none. → Use **`bd label add <id> <label>`**, verify
   with `bd label list`.
3. **`bd create --id <x> --parent <y>` errors** ("cannot specify both"). →
   `bd create --id <x> …` then `bd update <x> --parent <y>` as two steps.
4. **`bd create` can time out mid-batch (~2min default)** and silently drop the
   rest. → Create in small sequential groups; verify count after.
5. **Don't trust your own read of bd state mid-buffering.** I twice misreported
   ("I2 auto-closed with no design" — it hadn't; counts frozen) off stale/partial
   output. Re-verify from a file before acting.
6. **MERGE DISCIPLINE (I broke this — learn from it):** I committed AND pushed a
   merge with **unresolved conflict markers** (Edit had silently failed on `§`/
   em-dash chars) → broken `adapter.js` on origin/main. The correct order is
   **resolve → `git grep -lE '^<<<<<<< |^>>>>>>> '` (zero) → `node --check` any
   .js → THEN commit → push**, and *preview first* with `git merge-tree
   --write-tree A B` (rc 0 = clean). When Edit fails on special chars, use `sed`
   to strip just the marker lines (keeps the union).
7. **Do git surgery in an isolated worktree while a worker is live** —
   `git worktree add /tmp/ct-x <branch>`, operate there, never `checkout` the
   live tree under a running worker. Remove with `git worktree remove --force` +
   `git worktree prune`.
8. **Queue starvation by a no-claim bead at `ready[0]`** (`uxqj`, fixed): the v1
   runner's `next_task`/`validate_task` skip-then-`return` means a single
   `human-action`/`human-triage` TASK at the top of `bd ready` starves every
   workable bead below it (epics are query-filtered, but tasks aren't). → Keep
   human-action beads **deferred out of the ready queue** (`bd update <id>
   --defer <date>`), not just labeled. I starved the queue for ~25min by filing
   a P1 human-action `uxdec` at the top.
9. **Workers wander off `main`.** The runner does NOT branch, but a worker can
   `git checkout -b` and leave the tree on a feature branch; then every
   subsequent bead auto-commits there until a human notices. Root-cause bead
   `claude-tools-trunkpin` (pin HEAD to main at loop top). To switch back
   safely: `.stop-beads` (graceful) → wait for runner down → `desired=stopped`
   (freeze respawn) → checkout/merge main in worktree-discipline → `rm
   .stop-beads` → `desired=running` (daemon respawns on main).
10. **Process counts look inflated** (`pgrep` shows many runners/daemons) —
    partly your own subshells, partly the known runner-accumulation loose thread
    (HANDOFF). Use the per-workspace pidfile
    `.beads/runner-logs/detached-runner.pid` for the authoritative "is MY
    workspace's runner alive" check, not raw `pgrep` counts.

---

## 5. Current state (2026-05-31) + how to re-derive it

**Re-derive (always trust these over this doc's frozen numbers):**
```bash
git branch --show-current; git fetch -q origin; \
  [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] && echo SYNCED
bd list --label ux-v2 --json | jq -r 'group_by(.status)[]|"\(.[0].status): \(length)"'
bd list --label v2-cutover --json | jq -r 'group_by(.status)[]|"\(.[0].status): \(length)"'
bd ready --json | jq -r '.[]|"P\(.priority) \(.id) \(.title)"'
bd dep cycles
cat .beads/runner-logs/detached-runner.pid   # this ws's runner pid
```

**Snapshot at handoff:**
- Working tree on **`main`**, `7ae4c0e`, **== origin/main**. Runner respawned on
  main (daemon), alive. Worktrees back to 1.
- **ux-v2 (`mhcp`):** 35 total — ~17 closed, ~33 open/blocked/deferred (the 4
  designs + C-shell + many impl/gap beads closed). 1 deferred = `uxdec`
  (decisions), 1 blocked.
- **v2-cutover (`v2cut`):** 4 closed (`v2c0`, `v2c2`, plus `2fkp`, `5jt6`), 5
  open (`v2c1` port-forward, `v2c3` conformance-gate, `v2c4` staged cutover,
  `v2c5` retire-v1, + the epic).
- Branches: `main` (live), `n2-uxg1-push-delivery` (already merged into main —
  stale, safe to delete), `i5-rehearsal-deploy-divergence-fixes` (stale). `n3`
  deleted this session.

---

## 6. Open decisions for Brian (do not guess — they gate impl)
Tracked in **`claude-tools-uxdec`** (deferred to 2026-06-02 to keep it out of the
runner's hot queue; un-defer/surface when Brian's ready):
1. **v1-vs-v2 runner fork** for `uxvj4`/`uxvi1`/`uxvi5` — current default: build
   on v2 behind `v2c3` (the `v2cut` epic). Confirm.
2. **§14.1 gate placement authority** — any agent (assumed) vs specific hats.
3. **§14.2 Blueprint customization-conflict default** — keep+FYI (assumed) vs
   auto-drop.
4. **§14.3 net-velocity alarm threshold** / **§14.4 cross-WS digest cadence** —
   tunable, assumed defaults fine.
5. **xws-responder spawn owner** — resolved to K1 (MCP-spawned, blocking path);
   I5 drops it from its "spawns" list. (Noted on `uxvk1`/`uxvi5`.)

---

## 7. Reliability backlog (open `runner-reliability` beads)
Foundation that makes the swarm trustworthy; mostly outside `mhcp` by design:
- **`trunkpin`** — workers leave tree off main (pin HEAD to main in the loop).
- **`fxsweep`** — `test-bd-ready-ordering.sh` fixtures leak to live bd on SIGKILL
  (trap doesn't survive -9); add a startup self-heal sweep.
- **`uxc1`** (Mechanism A, PID claim files) + **`uxc3`** (Mechanism C, stranded-
  session sweep) — cross-process ownership; runner can adopt a live external
  agent's in_progress task (dup-work hazard), amplified by parallel runners.
- **`1xx1`** — dismissed worker_stuck fork leaves a permanent local bfh record.
- Pattern worth filing if you see it again: a **pre-commit/merge guard** that
  rejects commits containing conflict markers + runs `node --check` on changed
  `.js` (would have caught my broken merge — same "enforce in a hook, not by
  discipline" lesson as the close/gate hooks).

---

## 8. How to expand or adapt the project

- **Adding a new capability/flow:** decide which track it extends (or a new
  letter). Write/extend the design doc in `beads-runner/design/` first, conform
  it to A/B/C/D, then file impl beads `--blocked-by` the design. New UI data ⇒
  add a named sub-object to Contract B + emit from `workSnapshot()`.
- **Adding an engine op:** follow Contract A.1 end-to-end (module + guard +
  Pages fn + **adapter** + migration + **live-verify**). Templates: smallest
  clean §4-record module is `cf/src/lease.js`; transient-table precedent is
  `cf/src/machine-state.js` / `capacity.js`.
- **Anything touching `web/**`:** not done at commit — done when `wrangler pages
  deploy` + `verify-pages-deploy.sh` prints `mismatches=0` (CLAUDE.md / the bgw
  lesson).
- **Anything touching the runner:** prefer landing it on **v2** behind `v2c3`,
  not the live v1 loop. If it must go on v1 (e.g. an urgent starvation fix),
  remember editing the running script is safe (bash slurps at startup; takes
  effect next respawn) but keep ir7 self-modification discipline.
- **Keep designs and impl from drifting:** re-run the two audits (§3.3) whenever
  a batch of beads closes. Reconcile any design's self-proposed split against the
  filed beads. Add `blocked-by` edges for newly-discovered couplings; never a
  blanket freeze.
- **Session close discipline** (CLAUDE.md): file follow-ups, run gates if code
  changed, `git pull --rebase` → `bd dolt push` → `git push` → confirm "up to
  date." Work isn't done until pushed.

---

## 9. Key files index (UX v2 specific; see docs/HANDOFF.md for the rest)
| What | Where |
|---|---|
| The WHAT (UX flows) | `beads-runner/UX-DESIGN-V2.md` |
| The anti-drift contracts (A/B/C/D) | `beads-runner/UX-V2-ARCHITECTURE.md` |
| Design docs (the delegated outputs) | `beads-runner/design/{blueprint,gates,activity,cross-ws,notifications}.md` |
| v2 runner gap analysis | `beads-runner/design/v2-gap.md` |
| Inbox/intake leak source (Flow A/B detail) | `docs/inbox-lifecycle.md` |
| Diagrammer spec (Blueprint map IP) | `~/Downloads/HANDOFF.md` |
| Older operational handoff (daemon/runner/engine) | `docs/HANDOFF.md` + `docs/runbooks/` |
| v1 runner (live) | `beads-runner/run-beads-tasks.sh` |
| v2 runner (rewrite target) | `beads-runner/runner.sh` |
| Engine | `beads-runner/cf/src/*.js` (reconcile.js = work-snapshot) |
| bd memories (persistent insights) | `bd memories` / `bd prime` |
| This session's switch plan (example) | `tmp/SWITCH-TO-MAIN-PLAN.md` |

---

*Maintainer note: the durable value here is §1 (topology), §3 (anti-drift
method), and §4 (gotchas). Counts in §5 go stale immediately — re-derive them.*
