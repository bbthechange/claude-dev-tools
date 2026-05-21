# Beads Runner — Architecture & Decisions

Status: draft (v2 — adversarial review integrated; AD7 §11-amended 2026-05-17: `diagrams[].content` = Mermaid, Dossier schema `1→2`; AD7 §11-amended 2026-05-20: v1 dossier-item author surface committed to a fresh **dossier-builder agent dispatched by the `ask-brian` MCP server**, with the worker's rich `context_dump` as raw material — see §3.1 (this amend **supersedes** an in-flight earlier 2026-05-20 amend that misstated the author as the worker itself in-session; that amend is reverted as a design correction, see §3.1 historical note); AD1/§2/§7 §11-amended 2026-05-20: Local Agent is a per-machine daemon process (launchd LaunchAgent on macOS / systemd user service on linux), NOT a library sourced into the workspace runner — see §3.2; new AD8 — resume dispatch and parallel-work boundary, see §3.3) · Scope: **architecture/design only** (deliberately *not* UX) · Owner: Brian · Last updated: 2026-05-20

This is the architecture counterpart to `UX-DESIGN.md`. That doc is user-flows
only and is the authoritative source for requirement provenance (its §0). This
doc records the **design decisions and the extension seams**, and binds to:

- `UX-DESIGN.md` — user flows; §0 = what Brian asked for vs. agent elaboration.
- `BEHAVIORAL-CONTRACT.md` — pre-rewrite characterization; the **regression
  gate** (SCAR = preserve behavior; SCAFFOLDING = do not port the mechanism).
- `research/headless-stuck-signal.md` — empirical headless `claude -p` behavior;
  basis for AD3.

> **v2 note:** §2 reintroduces the per-computer **Local Agent** tier (a §0.A
> requirement the v1 draft silently dropped). Many decisions below resolve at
> that tier — read §2 first.
>
> **§11 amend 2026-05-20 (AD1/§2/§7):** the Local Agent is a per-machine
> **daemon process** (launchd LaunchAgent on macOS / systemd user service on
> linux), NOT a library sourced into the workspace runner. v1 wording that
> allowed a sourced library to claim it satisfied the tier is retracted —
> see §3.2. New AD8 (§3.3) names the resume-dispatch + bd-surgery parallel-
> work boundary the daemon makes possible. Both amends are doc-only; M-track
> tasks under epic [[claude-tools-kie]] own the behavior.

---

## 1. The frame

The expansion is a **topology change, not a feature addition**. Today's
`run-beads-tasks.sh` is a single imperative process with all state, authority,
and lifecycle local. The target is distributed. The script is read for its scar
tissue (`BEHAVIORAL-CONTRACT.md`) and largely **not reused as code**.

---

## 2. The three-tier topology (foundational)

UX §0.A explicitly requires *"one central runner **per computer** that checks
Claude capacity; the runner in each environment checks with that central one
before working"* and *"the central runner is the sync + remote control/viewing
backbone."* That is a two-authority model, because **capacity and credentials
are machine-local** (BC-34: the OAuth token is the local Keychain's; the 5h/7d
window is that machine's account). A single hosted coordinator cannot see a
machine's Keychain or its true rate-limit state. So three tiers:

| Tier | What it owns | Consistency | Where |
|---|---|---|---|
| **Work plane** | beads/Dolt — issues, deps, notes, labels | eventual | Dolt (unchanged) |
| **Local Agent** (one per computer, **a per-machine daemon process** — §11 amend 2026-05-20, see §3.2) | A long-lived supervisor process distinct from every workspace runner (`pid_daemon ≠ pid_any_runner`), owning: (1) **Keychain + real usage poll** — *one* Anthropic-API caller per machine, not N (no per-workspace duplication of the BC-34 query); (2) **workspace registry** — the durable list of workspaces this machine is responsible for + their `desired`/`actual` snapshot; (3) **desired-state poll per workspace** — the §7-S5 reconcile-desired-state job runs in the daemon, not in each workspace runner, so `stopped → running` / `paused → running` round-trips survive a dead/absent runner (Flow D); (4) **runner supervisor** — spawn / kill / restart the workspace runner subprocess; observes its exit code (BC-21) and writes the terminal-reason record (§8) **before** the runner is gone; (5) **hosted-resolution poll** — observes Coordinator-side answered dossiers and drives resume dispatch into the affected workspace (AD8); (6) **BC-34 fail-open** + bounded **local lease fallback** (C-2). Reports capacity + terminal-reason + heartbeat **upward** (§7). | strong, machine-local | the Mac (launchd LaunchAgent — AD1) / linux host (systemd user service) |
| **Coordinator** (hosted) | global lease arbitration across machines; Decision DOs + durable timers; RunnerState (desired/actual/**liveness**); Notification; **work-snapshot projection** | strong | Cloudflare (AD1) |
| **Board** | a projection joining Work + Coordinator | read-only | derived |

The Local Agent is the per-machine measurement & supervision authority; the
Coordinator is the global serialization & decision authority; the human-latency
path never touches Dolt merge semantics. The reconciliation model still
eliminates a durable command queue (desired-state mutation, not a queued msg).

---

## 3. Settled architecture decisions

| # | Decision | Rationale / consequence |
|---|---|---|
| **AD1** | **Topology = Cloudflare hosted Coordinator + a per-computer Local Agent (§2).** Coordinator = Workers + Durable Objects + D1 + Pages. **Local Agent = a per-machine *supervisor process* (NOT a library)** — concretely a **launchd LaunchAgent on macOS** (the only mechanism that satisfies the §0.A "reachable while the laptop is logged in but the user is away from keyboard + auto-restart on crash" promise; a launchd LaunchAgent runs in the user's GUI session, restarts on crash via `KeepAlive`, and is the supported way to keep a per-user supervisor alive without root). The portable abstraction is *"per-machine supervisor process";* on linux the same role rides a **systemd user service** (`systemctl --user`). The daemon has its own pidfile (`~/.beads-runner/daemon.pid`), its own logs, and its own lifecycle independent of every workspace runner it spawns. **§11 amend 2026-05-20 (see §3.2):** v1's §2 wording allowed `lib/local-agent.sh` (a pure sourced bash library) to claim it satisfied "one central runner per computer" — that close (claude-tools-3al) is now retracted as topology; the library remains useful and the daemon `source`s it, but the Local Agent **tier** is the daemon process, never the library. | $0 at this workload; a **DO-per-dossier-Item (AD7)** makes the per-item consequence applier idempotent *by construction* (single-threaded — supports partial/iterative dossier resolution), and `setAlarm()` is the `timed-fyi` timer. **SPOF acknowledged:** the singleton Coordinator DO is a single point of failure on free-tier infra with non-contractual alarm reliability; mitigated by the C-2 unreachable posture and the S-6 timer backstop, not waved away. **A second SPOF is acknowledged at the Local Agent tier:** if the daemon dies, every workspace on that machine goes dark for new desired-state transitions until launchd/systemd restarts it (`KeepAlive=true` / `Restart=always` is the mitigation; the daemon's own crash-loop trip is logged but does NOT escalate to the Coordinator beyond a heartbeat-absence — by design, because a Local-Agent-down machine is structurally unable to report up). |
| **AD2** | **Coordinator lease = global exclusivity + orphan recovery. Capacity = a separate, deliberately coarse gate.** Plus the two sub-decisions below. | Resolves BC-04 multi-runner race *only if* the lease is consulted on every pickup and the binding/unreachable rules below hold. |
| **AD2.1** | **Lease ↔ beads-status binding.** Acquire the lease **before** `bd update --status=in_progress`; lease release/expiry maps to `--status=open` (binds the strong-plane authority onto the eventual-plane SCAR transitions BC-15/BC-09/BC-35). **Precedence on disagreement:** lease wins for *exclusivity* (who may run it); beads status wins for *work truth* (done/blocked/open). | Removes the dual-source-of-truth ambiguity: ownership = lease; work state = beads. Neither store alone answers both. |
| **AD2.2** | **Unreachable posture (split by plane).** *Capacity* check fails **open** (a one-task overshoot is noise; BC-34 intent). *Lease* fails **degraded-closed with a bounded local fallback:** on Coordinator-unreachable a runner may continue **only** a task whose lease it *already holds and is still valid* (Local Agent enforces; lease TTL ≫ expected blip + poll interval), and may **not** claim a *new* task without a fresh lease. | This is the highest-blast-radius decision. It preserves BC-34 (in-flight work survives a blip) without reintroducing BC-04 (no new unsynchronized claims). Not left to implementation. |
| **AD2.3** | Coarse-capacity rationale. | Justified **not** by "tasks are small" (unproven; BC-13/22 show tasks run long) but by: the spare-cycles 14.2%/day line is a *soft ramp*, not a hard cap; the hard 5h/7d ceiling (BC-34, measured by the Local Agent) is the real guard. Same decision, honest rationale. |
| **AD3** | **Worker stuck-signal = instruct + deterministic backstops + guardrail**, with the contract below. | From `research/headless-stuck-signal.md`. |
| **AD3.1** | **Worker path:** prohibition **+ positive path** — on a fork it must not resolve, the worker emits the structured ask; the **Coordinator** (not the worker writing Dolt as truth) owns "blocked-for-human" and reconciles `status=blocked`+`bd human` back into beads (control→work; S-2). | Keeps the human-latency path on the strong plane; Dolt lag is invisible to it (the §2 promise). |
| **AD3.2** | **`STUCK_NEEDS_HUMAN` is a first-class terminal class:** slots **high in the BC-10 precedence chain** (above `TASK_NOT_CLOSED`); **breaker-exempt** (like CONTEXT_OVERFLOW vs BC-14) and **retry-exempt** (like overflow vs BC-13). | Without this, N legitimate human-decision tasks trip the BC-14 breaker and stop the fleet — turning the normal path into an outage. |
| **AD3.3** | **Backstops (two, deterministic):** (a) scan final `result.permission_denials[]` for `AskUserQuestion`/`ExitPlanMode`; (b) scan the stream for the `"Entered plan mode."` tool_result (the EnterPlanMode silent-no-op the research flags as the residual gap — `--disallowedTools` is the *guardrail*, this scan is the *backstop*; defense-in-depth, same as AskUserQuestion). When a backstop fires it **must itself drive the bead to blocked-for-human** (worker slipped ⇒ rot otherwise). | Drops the v1 overclaim that `--disallowedTools` is "the only" EnterPlanMode defense — it is undocumented/version-pinned (O-1). |
| **AD3.4** | **Double-trigger idempotency:** worker-self-signal + backstop on the same fork de-dupe at the **dossier** level keyed on task ID; per-Item application de-dupes at the DO-per-Item level (AD7) keyed on item ID. | One fork ⇒ one dossier; one item response ⇒ applied once. |
| **AD3.5** | Guardrail: `--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode`, keep `--output-format stream-json`. | |
| **AD4** | **Forensic boundary** — Flow G UX kept; **BC-27 git-containment scar preserved verbatim** (post-mortem never enters a committable path). | **Provenance (honest):** UX §0.B D6 ("never persisted server-side") was **explicitly relaxed by Brian in design discussion** ("fine for the box to touch forensic content; don't over-index"), *not* "design-agent over-reach." Concrete rules: file bodies stripped **at the runner before transit** (Flow G tier-3 redaction); Coordinator may hold the redacted blob with a **defined short TTL + server-side encryption + guaranteed delete**; "briefly" is given a number in the interface contract, not left undefined. |
| **AD5** | **Scope cuts (§4).** | Correction: the per-computer Local Agent tier (§2) is a **restoration of a §0.A requirement**, not a cut — the v1 draft's "scope cuts touch nothing in §0.A/§0.B" was wrong about topology. Scope cuts C1–C7 otherwise stand. |
| **AD6** | **Auth = single-user v1 over a principal-based seam.** One human credential + per-runner bearer tokens, all resolved through one `authenticate(request) → principal` chokepoint; every control-plane record carries `principal` (constant in v1). **Token lifecycle:** long-lived static secrets in v1, stored via the **same machine secure-store as BC-34's credential path** (Local Agent owns it); rotation/revocation deferred, but the storage location is **not** deferred. | Same chokepoint as C4 — one seam serves asymmetric-trust *and* multi-user (C7). |
| **AD7** | **Dossier model = a depth-tiered body ⊃ N independently-respondable Items.** The Inbox unit is a **Dossier**, not "a Decision." It has: (1) a **body** with first-class progressive-disclosure tiers — `tldr` · `sections[]` (skimmable headers) · `diagrams[]` · `full_detail` (enough prose to stand alone when skimming is insufficient); none optional, the generator must produce all tiers. **`diagrams[].content` MUST be Mermaid source** (v2 §11 amendment, Brian-ratified 2026-05-17): the §0.A "diagrams" requirement is a *rendered diagram a human sees on a phone*, not a renderable-someday string — so the contract constrains it to a text diagram language (Mermaid: LLM-authorable, deterministic SVG, git-friendly), the generator rejects non-Mermaid (prose/ASCII) exactly as it rejects a contextless `context_anchor`, and the renderer paints it as SVG, never a `<pre>` of source. The Dossier bound schema version is `2` (the §5.1 `dossier_schema_version`, §4.1 envelope `schema_version`, and §5.3 `cb_schema_version` track ONE registry source — INTERFACE §0.5/§0.3 — so the §11 bump moves the whole artifact `1 → 2` in one edit). (2) **`items[]`**, each `{id, kind ∈ approve-reject \| pick-option \| approve-recommendation \| freeform-edit \| fyi-objectable, framing, context_anchor, options?, recommendation?, consequence_block, state}`. **Partial/iterative resolution is first-class:** a dossier may be left partly answered (approve 6, edit 3, feedback 2, return later) without blocking unanswered items or the pipeline. **Self-contained-context invariant:** every item's `framing` MUST carry a `context_anchor` (link/expansion into where it sits in the lifecycle/design) — a contextless ask like *"reached the auth boundary, pick one"* is a contract violation, not just poor wording. **Profiles:** a decision dossier = body + decision items; a UX/design review = body + many mixed items; the proactive **Flow F "understand how it fits" overview = a deep body + zero or all-`fyi-objectable` items** (a first-class profile — UX §0.A "trigger proactively to give him an understanding"; *core, not a tier variant*). Notification stays one-per-dossier (C3 holds; principle 2 — the notification is terse, the **dossier body is not**). | This is the §0.A "strong human-interaction support / multi-step doc-gen / inline-edit + approval-checkboxes / proactive understanding" requirement made precise. The v1 C5 schema (single `consequence_block`) **could not express** a 15-item mixed-affordance review or a standalone design overview; AD7 is the corrected schema T0 must freeze. Per-Item DO (AD1) makes partial application idempotent; deterministic-vs-reconciler (Flow B step 5) runs per-Item; "your no as cheap as your yes" (principle 3) = approve-the-good / feedback-the-rest in one pass. |
| **AD8** | **Resume dispatch and the parallel-work boundary** (§11 amend 2026-05-20, see §3.3). When the daemon's hosted-resolution poll (§2 Local-Agent job 5) observes an answered dossier whose `task_ref` belongs to a workspace this machine owns: **(a) if the workspace runner is idle/parked** (no `claude -p` in flight; the runner is between tasks or has cleanly exited per BC-05), the daemon writes the resume-answer file to the workspace's resume directory as today and lets the runner re-dispatch in-band (the existing AD3.1 / §3.1 mechanism). **(b) If the workspace runner is busy** running a different task (a long worker is mid-flight), the daemon launches a **fresh `claude -p` IN the workspace cwd in `bd-surgery` mode** to apply the answered dossier's `consequence_block` side-effects. `bd-surgery` mode = `--add-dir` scoped to the workspace, but the workspace's source tree mounted **read-only outside `.beads/`** (the surgical session can read context for grounding, can write `bd`/dossier/notes, but cannot edit code). **Why the boundary.** We deliberately do **not** run code-editing work in parallel against the same workspace — we lack git-worktree machinery to fan out edit branches and merge back, and parallel writes to the same tree are a category of foot-gun the v1 scope refuses to take on. The honest scope of "parallel work" in v1 is therefore: *one code-editing worker per workspace at a time, plus N concurrent bd-surgery sessions that can answer dossiers, file follow-ups, update stage, and record decisions without touching code.* This is not a workaround — it is the contract: bd-surgery is the named, bounded affordance for "answer this while something else is running." | The §0.A "remote control" + AD7 "partial/iterative dossier resolution" requirements demand that an answered dossier-Item can be **applied promptly**, not buffered until the workspace runner happens to be idle. Without (b), every answer for a workspace with a running long task waits behind that task — which collapses the dossier latency promise. The bd-surgery read-only-outside-`.beads/` constraint is what makes (b) safe without a worktree: the surgical session physically cannot create a divergent edit against the in-flight worker's tree. **Build pointer:** the M-track owns implementation (`claude-tools-cgh` desired-state poll, `claude-tools-gim` daemon skeleton, plus a new M-track issue for the bd-surgery mode wrapper); this AD is doc-only — the behavior is the M-track's. |

---

## 3.1 AD7 §11 amend — v1 dossier-author surface committed (2026-05-20, re-amended)

> **§11 amendment, Brian-ratified 2026-05-20 (re-amended same-day).** AD7
> (and §5 C5 below) had deliberately left the dossier *producer* swappable
> behind the schema seam. This block **commits** the v1 producer and demotes
> the existing jq path to fallback. Bound to research outcome
> [[research/mcp-interactive-tool.md]] (epic claude-tools-kie, child R1 =
> claude-tools-59o); supersedes the pre-R1 "real `claude -p` agent as a
> separate post-hoc process" sketch.
>
> **Historical note (in-flight design correction).** A first version of this
> amend (commit `4ece326`, child claude-tools-9zk, 2026-05-20 03:55) wrongly
> committed the author surface to *the worker itself, in-session*. That
> framing was overruled the same day on token-economics grounds before the
> implementation tracks (B1/B2/B4) bound to it; the implementation tracks
> shipped the correct architecture (see "Why a separate builder, dispatched
> by the MCP server" below) and the bd memory
> `architecture-refinement-brian-2026-05-20-the-mcp` records the rationale.
> This re-amend reverts the misstatement so DESIGN.md matches what was
> actually built (`mcp-askbrian/server.mjs` + `beads-runner/agents/dossier-
> builder.system.md` + the B4 worker prompt in `beads-runner/lib/run-beads-
> tasks.sh`). The seam and the schema were never affected; only the
> *producer-identity* line is corrected.

**Commit: the v1 dossier-item author is a fresh `claude -p` dossier-builder
agent dispatched by the `ask-brian` MCP server before the engine write, with
the worker's rich `context_dump` as raw material.** The worker is a fresh
`claude -p` session running the bd task inside the workspace cwd. When it
hits a fork it must not resolve, it calls `mcp__askbrian__ask-brian` with a
structured ask whose load-bearing field is `context_dump` (rich, unconstrained
prose: code paths inspected, alternatives considered, related decisions, why
the worker can't resolve this itself). The MCP server's handler then runs the
five steps from claude-tools-bvj (B2) in order: **(1) authoring dispatch** —
spawn a fresh `claude -p` running the dossier-builder agent system prompt
(`beads-runner/agents/dossier-builder.system.md`, B1) with the worker's input
on stdin, time-budgeted (`BUILDER_TIMEOUT_MS`; default 90s), `--add-dir` to
the workspace so the builder can `Read`/`Grep`/`Glob` the actual code and
docs; **(2) write to the hosted engine first** — engine-bridge writes the
builder's polished `{body, items[]}` (or the B3 jq fallback shape on builder
failure) durably cloud-side **before** the poll loop starts; **(3) notify the
phone**; **(4) poll for answer** every `POLL_INTERVAL_MS` until any item moves
to `answered`/`applied`; **(5) return the answer to the worker** as the
tool_result, so the worker continues in-session with Brian's decision. Per R1
this blocks cleanly for ≥30 min wall-clock with no observable ceiling;
SIGSTOP / lid-close survives because the dossier was written *before* the
poll loop, so a daemon-resume backstop can splice the answer into a
re-dispatch if the tool call is ever killed. Concretely:

- **Author = a fresh `claude -p` dossier-builder agent (small context,
  ~30–50k) dispatched by the MCP server before the engine write, with the
  worker's `context_dump` as raw material.** The builder reads the project's
  design docs, `CLAUDE.md`, the bead and its dependency graph, and recent code
  touching the area (see `beads-runner/agents/dossier-builder.system.md` Step
  1) to author a polished four-tier body (`tldr` / `sections[]` / Mermaid
  `diagrams[]` / `full_detail`) plus per-item `consequence_block`s. The
  builder is **not** the worker, and **not** a post-hoc agent re-launched
  after the worker exits — it runs concurrently with the (now-blocked) worker,
  inside the same MCP tool call, and exits when its single JSON envelope is on
  stdout.
- **Why a separate builder, dispatched by the MCP server.** A 600k-context
  worker doing the full author job (read docs, perfect Mermaid, polished
  headers, conformant dossier shape) costs more total budget than splitting
  the work: (a) the worker dumps rich context cheaply — it's already great at
  *"what do I know"* and has the freshest possible understanding of the fork
  it just hit; (b) a fresh small-context builder agent does focused authoring
  with that dump + targeted reads as input. Separation of concerns is
  preserved (the worker doesn't switch hats mid-task) **and** the worker
  session is preserved (the same agent that hit the fork is the same agent
  that acts on the answer — no 600k of context lost to a re-spawn). This is
  the rationale recorded in the bd memory
  `architecture-refinement-brian-2026-05-20-the-mcp`; it is also strictly
  better than the post-hoc-reconstructive design (which was the pre-R1
  framing) because the builder has the worker's brain-dump rather than
  exit-time crumbs.
- **Write surface = the `ask-brian` MCP server.** Single stdio MCP tool,
  registered at user scope so every `claude -p` invocation has it. The tool
  body owns the builder dispatch + the durable engine write + the notify +
  the poll loop + the answer return — the five steps above.
- **`inputSchema` as built in B2:**
  `{ question: string, context_dump: string, bead_ref: string, options?:
  [{label, blast_radius}], recommendation?: string, reversible?: string }`,
  with `question` + `context_dump` + `bead_ref` required. `context_dump` is
  the **load-bearing field**, not a hint: it carries the worker's 600k of
  context cheaply so the small-context builder can author from it. The
  optional `question` / `options` / `recommendation` / `reversible` fields are
  structured hints layered on top of the dump, not substitutes for it. (See
  `mcp-askbrian/server.mjs` `ListToolsRequestSchema` handler for the
  authoritative shape.)
- **Schema bound = AD7 v2.** The MCP path produces one v2 dossier per call —
  the builder authors a full four-tier `body` plus `items[]` (one item per
  worker call in v1; the builder may emit several if the worker's ask
  factors). The body tiers are first-class for worker-stuck dossiers, not a
  thin stub — the builder system prompt makes "all four tiers mandatory" a
  contract (`beads-runner/agents/dossier-builder.system.md`, "Stakes" §3).
- **jq `dg__author` = the fallback / shape-coercer (B3).** It is **not** the
  v1 primary author. It runs on two cases: (a) the builder dispatch fails
  (timeout / non-zero exit / malformed JSON envelope) — the MCP server falls
  back to the jq shape-coercer so the engine write still lands and the worker
  is not left hanging; (b) the worker slipped to a forbidden interactive tool
  and never made an MCP call (the [[research/headless-stuck-signal]]
  `permission_denials[]` backstop fires runner-side and must still produce a
  dossier from the bd task + the slipped `tool_input` — jq does that
  minimally). The agent's failure is the fallback's success case — the
  pipeline degrades gracefully to a thin dossier rather than silently
  dropping the ask.
- **Flow F overview dossiers (the deep-body profile) keep their own author
  surface, named separately.** The Flow F trigger (a bd stage transition,
  e.g. `stage = design` closing — UX-DESIGN Flow F §11 amend, P-track) fires
  a one-shot enricher pass that authors a deep four-tier body around zero or
  all-`fyi-objectable` items. That pass is structurally similar to the
  ask-brian builder (small-context `claude -p`, AD7 v2 output, same engine
  write path) but the trigger and the prompt are separate; the AD7 schema is
  unchanged either way.

**The worker-stuck signal mechanism stays unchanged.** Instruct + guardrail
(`--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode`) +
`permission_denials[]` backstop + EnterPlanMode-tool_result stream scan are
correct per [[research/headless-stuck-signal]] (AD3 / AD3.3 / AD3.5) and are
not modified by this amend. The primary path is the positive R1 path (worker
calls `ask-brian` → MCP dispatches builder → builder authors → MCP writes
engine → MCP returns answer) and the negative-path backstops are *defense in
depth* for when the worker slips, not the main producer.

**Bind / build pointers.** R1: `claude-tools-59o` (closed; research in
`beads-runner/research/mcp-interactive-tool.md`) — the MCP-blocking primitive
this whole flow depends on. Builder system prompt: `claude-tools-n34` (B1) →
`beads-runner/agents/dossier-builder.system.md`. MCP server: `claude-tools-bvj`
(B2) → `mcp-askbrian/server.mjs`. Worker prompt update teaching the worker to
call `ask-brian` with a rich `context_dump`: `claude-tools-cf6` (B4) →
`beads-runner/lib/run-beads-tasks.sh`. jq fallback: `claude-tools-95m` (B3).
Rationale of record: bd memory
`architecture-refinement-brian-2026-05-20-the-mcp`. This DESIGN amend is
doc-only — the B-track owns the behavior, and the behavior is what shipped.

---

## 3.2 AD1 §11 amend — Local Agent is a per-machine daemon process, not a library (2026-05-20)

> **§11 amendment, Brian-ratified 2026-05-20.** AD1 and §2 are explicitly
> retracted **only as to mechanism** — the *topology* (three tiers; Local
> Agent as the machine-local measurement & supervision authority) stands
> unchanged. What is retracted is the v1 wording's permissiveness about
> *what physically realizes* that tier: a sourced bash library is **not** a
> per-machine supervisor, because it has no independent lifecycle — when
> the workspace runner exits, the "Local Agent" exits with it, and Flow D's
> `stopped → running` round-trip becomes structurally impossible.
> Bound to epic [[claude-tools-kie]] audit; supersedes the close artifact of
> claude-tools-3al (the T3 "per-computer Local Agent" task) **as a topology
> claim** — see "Retraction" below.

**Commit: the Local Agent tier is a per-machine daemon process** —
concretely a **launchd LaunchAgent on macOS** (the only supported,
restart-on-crash, runs-in-the-user-GUI-session-without-root mechanism
that satisfies §0.A "central runner per computer + reachable while away
from keyboard"); on linux the same role rides a **systemd user service**
(`systemctl --user`). The portable abstraction stays *"per-machine
supervisor process"* — the OS-specific realization is the appendix
detail, exactly as the Coordinator's Cloudflare realization is appendix
detail.

**Concretely the daemon owns (mirrors the §2 table row):**

- **The Anthropic-API usage poll** — *one* caller per machine, not N.
  The §6.3 capacity verdict is computed by the daemon's poll loop with
  the §0.5 `USAGE_CACHE_SECONDS` TTL; workspace runners ask the *daemon*
  for the verdict, never the Anthropic API directly. (Closes the
  pre-amend foot-gun where N concurrent runner processes could each
  source `lib/local-agent.sh` and each fire its own usage probe.)
- **The workspace registry** — durable list of `{workspace_id, path,
  desired, actual, last_heartbeat_at}` rows, one per workspace this
  machine supervises. The registry is what makes a Local Agent
  *machine-scoped* rather than workspace-scoped; without it there is no
  place to say "this machine owns workspaces A, B, C."
- **Desired-state poll per workspace** — §7 job 4 (`reconcile-desired-
  state`) now runs in the daemon, not in the workspace runner. The
  daemon polls the Coordinator at `CONTROL_POLL_INTERVAL` for each
  registered workspace's `RunnerState.desired` and acts on it
  (spawn / kill / pause / spare-cycles). This is what makes Flow D
  work end-to-end: a `stopped → running` transition is observed by
  the daemon even though no workspace runner exists at that moment.
- **Runner supervisor** — spawn / kill / restart the workspace runner
  subprocess (`run-beads-tasks.sh` per workspace); observes the runner
  process exit code (BC-21) and writes the §8 terminal-reason
  control-plane record **before** the runner is gone.
- **Hosted-resolution poll** — observes Coordinator-side answered
  dossiers and drives resume dispatch into the affected workspace, per
  AD8 (idle → resume-answer file; busy → bd-surgery `claude -p`).
- **BC-34 fail-open + bounded local lease fallback (C-2)** — unchanged
  in semantics; just lives in the daemon now.

**The library `lib/local-agent.sh` remains useful — and the daemon
`source`s it.** The library is the per-machine functions
(`la__USAGE_THRESHOLD`, `la__capacity_verdict`, `la__report_terminal_reason`, etc.)
factored out of the daemon for testability. The retraction is about
**topology** ("the per-machine supervisor process is a real process with
its own pidfile and lifecycle, distinct from every workspace runner"),
not about the library's existence. The §3 BC-21 / §8 re-home contract is
unchanged at the **abstraction** level — only the binding moves: it is
the daemon's exit-code observation, not "a sourced helper called from
inside the runner."

**Retraction (named and bounded).** Task `claude-tools-3al` (T3:
"per-computer Local Agent") was closed on `lib/local-agent.sh` — a pure
sourced bash library. The conformance gates that close passed (BC-21 /
BC-34 derivatives) were gates on **behavior**, not on the **existence of
a per-machine supervisor process**, so the topology promise slipped
through. The library work is **kept**; the topology claim that it
satisfied §0.A "one central runner per computer" is **retracted**.
M-track tasks under epic [[claude-tools-kie]] (`claude-tools-gim` daemon
skeleton + launchd plist, `claude-tools-cgh` desired-state poll, et al.)
are the honest realization of the tier and they alone close the §0.A
topology requirement. **Conformance addendum:** the M-track must add an
assertion of the form *"there exists a daemon process whose pid is in
`~/.beads-runner/daemon.pid` and is not equal to the pid of any
registered workspace runner"* — a topology gate at last, so this class
of misinterpretation cannot pass behavior-only gates again. The
assertion is M-track's to write; this §3.2 binds it as a
contract-attached gate, not a nice-to-have.

**What this means for the rest of the document.**

- **§2 table row "Local Agent"** is amended above to enumerate the
  daemon's responsibilities (the five-job list).
- **AD1** (above) names the launchd LaunchAgent / systemd user service
  realization explicitly and acknowledges the second SPOF
  (Local-Agent-down).
- **§6 conformance gate** below adds: a Local-Agent-process-exists
  topology assertion (M-track owns; this §3.2 makes it normative).
- **§7 "the runner's six jobs"** is amended below to move
  *report-terminal-reason* + *heartbeat-actual-state* explicit
  ownership to the daemon. Jobs 1 (claim-lease) and 2 (ask-capacity)
  remain initiated by the workspace runner against the daemon (the
  runner is the requester; the daemon is the per-machine answerer);
  job 4 (reconcile-desired-state) moves wholly into the daemon, since
  it must run even when no runner is up.

**Bind / build pointers.** M-track skeleton + plist:
`claude-tools-gim`. Desired-state poll: `claude-tools-cgh`. End-to-end
Flow D honors-transitions check: `claude-tools-6mx`. Workspace registry:
new M-track issue under [[claude-tools-kie]]. This §3.2 is doc-only —
the behavior change is the M-track's.

---

## 3.3 AD8 §11 — resume dispatch and the bd-surgery parallel-work boundary (2026-05-20)

> **§11 amendment, Brian-ratified 2026-05-20.** New AD8 (above) is added
> as a §11 amendment in the same batch as §3.2: the §3.2 daemon is what
> *makes* the §3.3 / AD8 affordance physically realizable (a process
> outside the workspace runner can spawn a sibling `claude -p` into the
> workspace cwd; a sourced library inside the runner could not). AD8 is
> the **boundary statement** for what "parallel work" honestly means in
> v1, given that we lack git-worktree machinery.

**The two-case dispatch (AD8 restated).**

1. *Runner idle/parked:* daemon writes the resume-answer file to the
   workspace's resume directory; the runner picks it up on its next
   tick and re-dispatches in-band. This is **the existing path** (AD3.1
   / §3.1's MCP-author path's natural completion); §3.3 just names it
   as case (a).
2. *Runner busy:* daemon spawns a fresh `claude -p` in the workspace
   cwd, with the workspace's `CLAUDE.md` and `.beads/` writable and the
   rest of the source tree mounted **read-only**. This `bd-surgery`
   session applies the answered dossier-Item's `consequence_block`
   side-effects (bd updates, decisions, dossier acks, notes, follow-ups)
   without ever editing code. It exits when the consequence-block
   application is done.

**Why read-only outside `.beads/`.** This is the load-bearing
constraint, not a stylistic preference. The in-flight worker on the
busy runner has a live working tree it is editing; a parallel
code-editing session against the same tree creates merge conflict
states the v1 has no machinery to resolve. By **mechanically forbidding**
the surgical session from writing outside `.beads/` (filesystem-level,
not policy-level — `--add-dir` + a chrooted-style read-only mount or an
LSM hook), we make the parallel-safety property an enforced contract,
not a hoped-for behavior. *Worktrees would lift this constraint;
they are out of scope for v1.* When git-worktree machinery lands, AD8
case (b) widens to allow code edits inside a worktree branch; the
constraint is real, the scope is bounded.

**Build pointers.** M-track owns the daemon side (spawn, sandbox); a
new M-track issue under [[claude-tools-kie]] for the `bd-surgery` mode
wrapper itself (the `claude -p` invocation profile + the read-only
mount machinery). A B-track follow-up may extend the worker-prompt
system message for surgical sessions (a thinner prompt, since
surgical sessions apply pre-decided side-effects rather than authoring
new ones). This §3.3 is doc-only.

---

## 4. Scope cuts (descoped from v1)

**DEFER** = build later as a separate layer · **DROP** = cut · **SIMPLIFY** =
keep requirement, shrink mechanism. §0 status cited (0.C = tradeable).

| # | Item | §0 | Verdict | Why safe |
|---|---|---|---|---|
| C1 | Autonomous staged pipeline + gate map | 0.C | **DEFER** | Tracking ≠ auto-driving. But the v1 gate policy is **not** "always manual" — see §5 C1 (S-3 fix). |
| C2 | Collaborative-stage interactive mode | 0.C | **DROP/DEFER** | Same class as the non-headless item Brian flagged impossible. |
| C3 | Notification batching / digest | 0.C | **DROP** | Silence *tiers* (0.B) kept; batching premature. |
| C4 | Asymmetric agent/human trust boundary | 0.C | **DROP** | §0.A wants symmetric control; asymmetry is 0.C. |
| C5 | 4-pass dossier orchestration | 0.C/A·B | **SIMPLIFY** | One structured generation; frozen schema = the **AD7 dossier model** (body⊃items), not decision-singular. The *passes* are 0.C; the *schema* is §0.A. |
| C6 | "Honest desired-vs-actual" UI polish | mixed | **SPLIT** | Backbone kept; **liveness is data, not polish** (S-1 fix in §5 C6). |

**Irreducible (§0.A/§0.B, cannot cut):** human-decision doc-gen quality loop;
spare-cycles 14.2%/day gate; the Coordinator + Local Agent tiers.

---

## 5. Deferred ≠ rewrite-later — the extension seams

> **Rule: defer *behavior*, not *data*.** Every deferred feature has its data
> shape + single chokepoint in v1, wired to a trivial policy. The
> rewrite-forcing mistake is deferring the *seam*.

### C1 — Autonomous staged pipeline + gate map
**Seam:** `stage` is a first-class enumerated field on every bead; every stage
change goes through one **"advance stage" operation** recording its trigger;
the gate map is an explicit policy function keyed by `(stage, transition)`.
**v1 MUST** model stages as data, route all transitions through the one op, and
ship the gate policy as the **minimum honest realization of the
"autonomous-until-stuck" preset** (a §0.A default-workhorse intent): transitions
**auto-advance by default**; `GATE (you)` fires only on (a) the explicitly
collaborative preset, (b) a worker `STUCK_NEEDS_HUMAN`, (c) the proactive
design-checkpoint FYI. *(S-3: an "always-manual" v1 policy would gate every
stage boundary, starving the runner — directly conflicting with §0.A "runner
keeps running" and the autonomous-until-stuck preset. Still a constant table,
no engine — just the **correct** constant.)*
**v1 MUST NOT** allow ad-hoc free-text stage labels or an all-manual policy.
Later pipeline = a richer gate-policy table behind the same op.

### C2 — Collaborative-stage interactive mode
**Seam:** decision/Inbox entity carries a `kind` discriminator (`decide`, later
`pair`); runner-control already has the pause/hand-off path.
**v1 MUST** make the decision entity typed with an open `kind`; implement only
`decide`. **MUST NOT** model decisions as a closed shape. Later = new `kind` +
D7 attach-mode.

### C3 — Notification batching / digest
**Seam:** notification is a **persisted, tiered record**; creation ≠ dispatch.
**v1 MUST** write each as `{tier, decision-ref, created-at, dispatched?}`, send
one. **MUST NOT** fire-and-forget. Later = read-side rollup; no schema change.

### C4 — Asymmetric trust boundary
**Seam:** all runner-state changes go through one "set state" op recording the
**actor**, single authorization checkpoint. **v1 MUST** capture actor, authorize
all equally. **MUST NOT** split UI vs agent code paths. Later = one `if`.

### C5 — Dossier generation (4-pass → one call)
**Seam:** freeze the versioned **AD7 dossier schema** — `{body:{tldr,
sections[], diagrams[], full_detail}, items:[{id, kind, framing,
context_anchor, options?, recommendation?, consequence_block, state}]}` — and
the producer is swappable behind it. **v1 MUST** version that schema; downstream
(applier, Inbox UI, reconciler) binds to the schema, never "the passes," and
must support **partial dossier resolution** + the **self-contained-context
invariant** (every item carries a `context_anchor`). The *number of generation
passes* is the tradeable 0.C mechanism; the *schema and its item-granularity*
are §0.A and not tradeable. **MUST NOT** ship a decision-singular schema (one
`consequence_block`) — it cannot express a multi-item review or a standalone
design overview (the regression this revision fixes). **§11 amend 2026-05-20
(see §3.1; re-amended same-day, see §3.1 historical note):** the v1
*producer* is now committed — for worker-stuck dossiers, the producer is **a
fresh `claude -p` dossier-builder agent dispatched by the `ask-brian` MCP
server before the engine write, with the worker's rich `context_dump` as raw
material** (per R1, `claude-tools-59o` / `beads-runner/research/mcp-
interactive-tool.md`; per B1/B2/B4, `claude-tools-n34` / `claude-tools-bvj` /
`claude-tools-cf6`); for Flow F overview dossiers, the producer is a
separately-named enricher pass at the trigger point. jq `dg__author` is
demoted to the fallback / shape-coercer. The seam stays — only the v1 choice
is committed.

### C6 — Honest-state: backbone + **liveness is data**
**v1 MUST** carry, in the control-plane store, not just `desired`+`actual` but a
Coordinator-side **`last_heartbeat_at`/liveness** so the Board renders
`stale (last seen Nh ago)` distinctly from `actual: running`. *(S-1: an offline
runner's last-pushed snapshot is stale; rendering it without a staleness marker
is exactly the optimistic UI principle 4 forbids. Liveness is a third dimension
the desired/actual model does not carry — it is **data**, in v1, per the
defer-behavior-not-data rule.)* Only the transitional-state *rendering* polish
is deferred; the liveness datum is not.

### C7 — Multi-user (rides the C4 seam — AD6)
**Seam:** one `authenticate → principal` chokepoint; every control record
carries `principal`. **v1 MUST** stamp a constant, route every request through
the one step, bind downstream to the resolved principal. **MUST NOT** add
roles/login/sharing/partitioning. Later = mint tokens + stop hardcoding the
constant. No migration.

---

## 6. Conformance gate

Passes iff every **SCAR** has an equivalent observable behavior under its
black-box repro and no **SCAFFOLDING** mechanism is transcribed. Highest-risk
(silent when wrong): **BC-21** (exit codes — **re-homed**: see §7 job 6, the
Local Agent observes the process exit code and reports terminal-reason; a
heartbeat-absence channel structurally cannot distinguish AUTH=3 from clean=0),
**BC-27** (security boundary; AD4), **BC-10/11** (classification precedence —
now includes `STUCK_NEEDS_HUMAN`, AD3.2), **BC-13/14** (retry asymmetry —
`STUCK_NEEDS_HUMAN` is breaker/retry-exempt, AD3.2), **BC-34** (fail-open —
lives in the Local Agent; AD2.2 split posture). **§11 amend 2026-05-20 — Local
Agent *topology* gate (§3.2):** a new conformance assertion must verify that
the Local Agent exists as a **distinct process** on the machine
(`pid_daemon = $(cat ~/.beads-runner/daemon.pid)` is alive **and**
`pid_daemon ≠ pid_any_registered_workspace_runner`). This closes the
behavior-only-gate loophole that allowed claude-tools-3al's library close to
pass while delivering nothing that would survive a workspace runner exiting
(M-track owns implementation; this gate is the contract binding so a
behavior-only pass cannot ever again be conflated with a topology promise).
**O-1 probe:** AD3's
`--disallowedTools`/`permission_denials[]`/`"Entered plan mode."` assumptions
are undocumented and version-pinned (claude 2.1.142); the conformance harness
includes a probe re-asserted on every `claude` upgrade (the research doc's
commands as a regression script).

---

## 7. The control-plane interface (settled)

Provider-agnostic — no Cloudflare primitive leaks into runner/Local-Agent/web
contracts (swappability guardrail):

1. small strongly-consistent store (**Dossier{body, items[]}** per AD7 / RunnerState{desired,actual,**liveness**} / Notification / lease / work-snapshot),
2. durable one-shot timer (`fire(dossierId) at T`) **+ S-6 backstop** (a missed alarm degrades to fire-on-next-poll; the idempotent DO-per-Item dedups alarm-fire vs poll-fallback so `timed-fyi` is *eventually* applied exactly once even if the free-tier alarm is unreliable — never an infinite stall),
3. authed request endpoint with one `authenticate(request) → principal` chokepoint (AD6),
4. deliver-desired-state-on-reconnect.

**Connection model (S-5 corrected):** poll *between tasks* for **new work**;
**plus** a bounded-cadence (~60s) desired-state poll *during* a task for
**control responsiveness**. BC-33's actual lesson is that coarse control latency
*was the bug* (chunked checking so stop is honored ≤60s even mid-wait) — so a
multi-hour task must not make "pause this project" take hours. "Stop *after*
current task" remains the task-*completion* semantic (don't kill mid-work,
BC-33's other half); "stop *requested*" must be **detected ≤60s** so the Board
honestly renders `stopping…` immediately (Flow D).

**The six jobs (per loop / per the cadences above) — ownership split by tier
(§11 amend 2026-05-20, see §3.2):**

| # | Job | Owner | Notes |
|---|---|---|---|
| 1 | **claim-lease** | workspace runner (requester) → daemon (answerer) → Coordinator | The runner asks the daemon for a lease before `bd update --status=in_progress` (AD2.1); the daemon proxies to the Coordinator and enforces the bounded local fallback (AD2.2 / C-2) without re-implementing global arbitration. |
| 2 | **ask-capacity** | workspace runner → **daemon (one Anthropic-API caller per machine)** | The runner does not call the Anthropic usage API directly; it asks the daemon for the §6.3 coarse cost-class verdict. The daemon owns the poll + the §0.5 `USAGE_CACHE_SECONDS` TTL + BC-34 fail-open. |
| 3 | **heartbeat-actual-state(+liveness)** | **daemon (per workspace)** | The daemon writes `RunnerState.actual` + `last_heartbeat_at` upward for every workspace it supervises, every `HEARTBEAT_INTERVAL`. This is in the daemon because the heartbeat must continue while the workspace runner is restarting / between tasks / parked — a runner-owned heartbeat would silently lapse during exactly those transitions. |
| 4 | **reconcile-desired-state** | **daemon (per workspace)** | The daemon polls each workspace's `RunnerState.desired` at `CONTROL_POLL_INTERVAL`, acts on `paused/stopped/spare-cycles/running` (spawn / kill / restart the workspace runner subprocess). **This is the load-bearing reason the Local Agent must be a real daemon process, not a sourced library** (§3.2): a sourced library cannot observe a desired-state change when the workspace runner is `stopped`, because there is no runner to source it. Flow D's `stopped → running` round-trip lives here. |
| 5 | **publish-work-snapshot** | workspace runner → daemon → Coordinator | The runner produces the §4.5 read-only projection; the daemon forwards it (so the publish surface is unified per machine). |
| 6 | **report-terminal-reason** | **daemon (observes BC-21 exit code of the runner subprocess + the `WORKER_STUCK_EXIT` / `STUCK_NEEDS_HUMAN` sentinel)** | A last durable write of the BC-21 class + `STUCK_NEEDS_HUMAN` *before* the runner is gone, via the daemon which sees the process exit code (S-7). "Exited because AUTH(3)" becomes a control-plane record, not an unobservable process code. **This job moves to the daemon by force of physics:** the actor that observes "the runner just exited with code N" must be a *different* process than the runner itself. A sourced helper inside the runner dies the same moment the runner does and cannot make the durable write. |

Board reads one surface (the Coordinator); the work-snapshot is a read-only
projection (Dolt remains work truth — no plane-split violation).

**Status: foundational architecture closed (v2).** Open work is contract spec +
build, not decisions. **Build sequence + anti-drift** is the beads epic (see the
tracker); the keystone is a single frozen, versioned `INTERFACE.md` that every
later task binds to and may not unilaterally change. The standing trap: building
the visible web/dossier layer before the schema + reconciliation + lease/posture
model under it is proven against `BEHAVIORAL-CONTRACT.md`.
