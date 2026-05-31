# Beads Runner — UX Design v2 (the overhaul)

Status: draft · Owner: Brian · Author: UX agent · Date: 2026-05-29
Scope: **user flows**, not UI styling and not implementation/architecture.
There is a separate UI agent and a separate software-architect agent; this
doc stops at the UX boundary and only flags feasibility where it matters.

> **Relationship to v1.** This supersedes `beads-runner/UX-DESIGN.md` for the
> overhaul scope. v1's Flows A–G are carried forward (compressed) and remain
> the contract for the parts that don't change; everything new in this
> overhaul is Flows H–L plus the surface model in §2 and the cross-cutting
> sections. Where v1 and v2 disagree, v2 wins **only inside the four spine
> decisions in §0.D**. v1's §0 provenance split is preserved and extended,
> not replaced. v1 is frozen-with-amend-ledger; this doc is the live design
> surface for the overhaul.

---

## 0. Provenance — read this first

This is the authoritative source for **what Brian required** vs. **what an
agent proposed**. Downstream agents do the extra defensive work (harden it,
treat it as fixed) **only for Brian-tagged items**. Everything else is a
proposal: keep it if it serves a Brian requirement, trade it off freely
otherwise.

**Tag legend** (used inline throughout):

| Tag | Meaning | How to treat it |
|---|---|---|
| **[Brian]** | Direct requirement/decision from Brian (v1 brief, this overhaul's brief, or the §0.D spine answers) | Protect rigorously |
| **[thirsty]** | Observed from real usage in the thirsty FE/BE transcripts — evidence-backed but *inferred*, not stated | Strong prior; not a hard constraint |
| **[UX]** | This UX agent's elaboration | Trade off freely; don't defend for its own sake |
| **[prior]** | A prior agent's elaboration carried from v1 / inbox-lifecycle.md | Trade off freely |

### 0.A — Carried forward from v1 (unchanged, still Brian-direct)

The v1 §0.A/§0.B requirements still hold. In brief (see v1 for full text):
end-to-end lifecycle tracking (idea→ux→design→[scaffold?]→impl→docs→tests);
remote per-project start/stop controllable by Brian *and* by agents; one
central runner per computer that owns capacity; capacity visible in the UI;
remote idea intake; strong human-interaction support (tagged human-decision
blocking, the multi-step decision document, easy inline/checkbox response,
proactive "understand the design" docs); runner keeps running when idle;
spare-cycles weekly ramp (14.2%/day); kanban per workspace; failure details
viewable locally + remotely. Response surface = mobile-friendly web app;
tiered silence (real decisions block, FYIs auto-proceed); pre-declared
per-option consequences; reachable off-network and while the laptop sleeps.

### 0.B — New direct requirements (this overhaul, from Brian) — protect rigorously

Verbatim-faithful restatement of the eight asks in the overhaul brief:

- **B1 — The Blueprint.** A much better diagram, kept up to date per
  workspace, **plus** an up-to-date human-facing design ("basically a
  dossier") that explains how everything fits together and includes the
  diagram. Both kept current **as beads tasks are done.** The diagram's
  look/feel/behavior is specified in `~/Downloads/HANDOFF.md` (the
  Diagrammer). Auto-generation must be *good* — it involves **deciding what
  to call things and how to group entities into a good mental model** — and
  there must be a way to **customize** it.
- **B2 — Automated cross-workspace sync.** Especially FE↔BE coordination.
  Shape: like the ask-brian MCP — an agent asks a question via MCP, which
  routes to an agent in the other workspace. That responder may run **in
  parallel** with whatever's happening there, and **must not be able to
  modify code** so it can't conflict with in-progress work.
- **B3 — Parallel runners when possible.** Code-writing agents run
  **serially**; other agents (intake, Blueprint update, etc.) may run **in
  parallel** with them. (Brian: focus on the UX of this, not the tech.)
- **B4 — Monitoring of in-progress tasks.** Both the tool watching tasks and
  the GUI surfacing enough. Agents and the script still get stuck; that must
  be **visible from the GUI and actionable.**
- **B5 — Notifications when a new action is required** (e.g. a new dossier).
- **B6 — Workspace view.** Show what's in progress, done, ready, not ready,
  deferred. Show gates. Show the diagram for that workspace (or a link).
- **B7 — Per-task status from logs.** Parse the logs so we can tell whether a
  task is writing code, executing tests, stuck, etc. (Signal basis is in
  `docs/inbox-lifecycle.md` §9.7 / the log-visibility findings.)
- **B8 — Gates.** Agents defer things and the deferrals aren't visible. Show
  what's deferred and what's blocked; a tool to block/unblock; a **named gate
  Brian can add/remove from the GUI** that agents can read/write and the
  runner respects; with an **explanation of why it's blocked and what would
  unblock it.**

### 0.C — Direct decisions (this session, from Brian) — same status as 0.B

The four spine decisions from the §0 clarifying round:

- **C1 — Surfaces: a richer multi-view app.** The v1 "two surfaces only"
  rule is **lifted.** The app may have as many views as the system needs.
  (UX still keeps the *spirit*: see §2 — everything is one tap from a
  workspace hub; no scavenger hunts.)
- **C2 — The persistent living design+map is called the "Blueprint."** Not
  "dossier." "Dossier" stays reserved for the ephemeral Inbox decision card.
- **C3 — Gates: one unified *presentation*, honest about the tech.** We
  cannot change beads. Beads has its own `blocked` (must be blocked on
  another task) and its own deferral. We add **our own native unified hold,
  written as a label on the task, which the runner reads and respects** — and
  it **coexists** with beads' built-in blocked. So the user-facing "what's
  holding this?" view is a *unification over three mechanisms*, only one of
  which (our native gate label) is fully ours to control. (§7.)
- **C4 — Cross-workspace sync: always FYI Brian.** Every cross-workspace
  exchange surfaces to Brian as an FYI he can read but that auto-proceeds on
  silence. (§8 leans hard on digest-batching so "always" ≠ 45 pings —
  flagged there as the load-bearing mechanism.)

### 0.D — The four spine decisions, as design constraints

| # | Decision | Drives |
|---|---|---|
| C1 | Richer multi-view app | §2 surface model |
| C2 | "Blueprint" = the living design+map | §6 (Flow H) |
| C3 | Unified Hold view over beads-blocked + beads-defer + native gate label | §7 (Flow J) |
| C4 | Cross-workspace exchanges always FYI Brian, batched | §8 (Flow K) |

### 0.E — Elaborations in this doc (proposals; trade off freely)

Not asked for; added here as connective UX tissue. **[UX]** unless tagged
**[thirsty]**/**[prior]**. The big ones: the Workspace-hub navigation (§2);
the Blueprint as the spine that *situates* decisions, live work, and
cross-workspace coupling (§6); the Activity view's derived activity-state
enum (§5.x / Flow I); the Hold/Gate/Checkpoint vocabulary split (§7); the
Queue-Health panel (§9, motivated by **[thirsty]**); the "done = shipped &
verified" sub-state (§3); the notification-trigger catalog (§10).

---

## 1. The reframe (extended)

v1 framed the system as an **attention router**: do everything autonomously
except the moments that genuinely need Brian, and package those so he
resolves them in ~60s from his phone. That still holds and is still the
north star — **every flow is judged by whether it reduces the number, size,
or cost of Brian's interruptions.** [Brian]

This overhaul adds two jobs the router didn't have, both straight from the
brief and both confirmed by the thirsty evidence:

1. **Keeper of the shared mental model.** The system maintains a living
   picture of each workspace (the **Blueprint**) so Brian never has to ask
   "how does this fit together?" and so agents share one vocabulary. [Brian B1]
2. **Cross-workspace coordinator.** The system handles the mechanical FE↔BE
   courier work itself and only pulls Brian in on real conflicts. [Brian B2]
   The thirsty transcripts show this courier work was ~30% of build-phase
   messages and largely mechanical. [thirsty]

One sentence: **v1 routed attention; v2 also keeps the map and runs the
relays.**

---

## 2. Surfaces & navigation (the richer multi-view app) [Brian C1]

The two-surface constraint is lifted. But "richer" must not become "go hunt
for it." The discipline that replaces the two-surface rule:

> **The Workspace is the hub. Everything about a workspace is one tap from
> its card. The only *global* surfaces are the ones that are inherently
> cross-workspace.** [UX]

### 2.1 The view map

```
┌── GLOBAL (cross-workspace by nature) ───────────────────────────────┐
│  • INBOX        — everything waiting on you (decisions, FYIs, pairs) │  [Brian]
│  • WORKSPACES   — the hub: one card per workspace, health at a glance│  [Brian B6]
│  • CAPACITY     — the central runner: 5h / 7d / spare line / modes   │  [Brian]
│  • CROSS-WS     — FE↔BE coupling map + the relay log                 │  [Brian B2/C4]
└─────────────────────────────────────────────────────────────────────┘
        │ tap a workspace card
        ▼
┌── WORKSPACE VIEW (facets of ONE workspace) ─────────────────────────┐
│  • BOARD      — lifecycle columns + queue health                    │  [Brian B6]
│  • BLUEPRINT  — the living map + the design prose that explains it   │  [Brian B1]
│  • ACTIVITY   — in-progress agents, liveness, what each is doing     │  [Brian B4/B7]
│  • GATES      — the unified Hold view: what's held and why           │  [Brian B8]
└─────────────────────────────────────────────────────────────────────┘
```

Five global views, four workspace facets. That's the whole app. Each facet
is a tab/section within the workspace view; switching facets never leaves the
workspace context.

### 2.2 What each surface answers in 5 seconds

| Surface | The one question it answers |
|---|---|
| **Inbox** | "Is anything waiting on me?" [Brian] |
| **Workspaces** | "Which workspaces are healthy / busy / stuck / need me?" [Brian B6] |
| **Capacity** | "How much Claude budget is left, and what's each project's mode?" [Brian] |
| **Cross-WS** | "Are the workspaces in sync, and did any relay need me?" [Brian B2] |
| Board | "Where is each task in the lifecycle, and is the queue healthy?" [Brian B6] |
| Blueprint | "How does this system fit together, right now?" [Brian B1] |
| Activity | "What is each running agent doing, and is anything stuck?" [Brian B4/B7] |
| Gates | "What's held, why, and what would release it?" [Brian B8] |

### 2.3 The Inbox is still the product [Brian, carried]

Lifting the surface constraint does **not** demote the Inbox. It remains the
single ranked, batched action queue and the only surface Brian is *required*
to look at. The other views are pull, not push — he visits them when curious;
the Inbox comes to him. Cross-cutting principle 1 (v1) is unchanged.

### 2.4 Local == remote [Brian, carried]

Every surface is a route in one responsive, mobile-friendly web app over the
beads read-model + a thin control/notify channel. Reachable off-network and
while the laptop sleeps (v1 §0.B; the *how* is architecture, deferred). There
is no separate "local" UI — local and remote are the same views.

---

## 3. The lifecycle spine (carried, with one refinement)

The spine is unchanged and still Brian-direct: it is simultaneously the Board
columns, the dependency template intake stamps on every idea, and the
checkpoint map.

```
 idea → ux → design → [scaffold?] → impl → docs → tests → done
   │     │      │                    │              │        │
   └auto  └CKPT  └CKPT (big ones)    └auto          └auto    └ verified?
          (you)  (you)                              (unit/integ/
                                                    e2e-agent + e2e-you)
```

**Refinement [UX], motivated by [HANDOFF]+[thirsty]:** `done` carries a
**verified** sub-state. The recurring "wired but not actually live" failure
(5 bugs in 24h; thirsty's contract-drift leaks) means "code landed + local
tests pass" is **not** the same as "shipped and verified." So a card in
`done` shows one of:

- **done · code** — committed, local checks green, *not* yet probe-verified.
- **done · verified** — the production probe passed (web track: deploy +
  `verify-pages-deploy.sh mismatches=0`; contract track: integration probe
  against the live contract).

This is a *display* distinction, not a new stage. It exists so Brian can see
at a glance whether the queue's "done" is real done. [thirsty: "closing on
code lands + tests pass without integration verification" is the dominant
leak.]

**Source signal [claude-tools-7qf7].** `verified` is a per-bead boolean carried
on the work-truth: a bead earns it via a **`verified` label** stamped when the
probe in the parenthetical above passes (web track: deploy +
`verify-pages-deploy.sh mismatches=0`; contract track: a live integration
probe). The label is the simplest signal that matches the existing producer
(which already reads `stage:*` labels) and stays reversible — the projection
consumes only a boolean, so the *source* of that boolean (label today; a
runner-stamped probe-result join later) can change without touching the §4.5
contract. Flow: `verified` label → §4.6 `workspace_inventory` producer → engine
→ §4.5 projection card → Board `done` split. Absent ⇒ `done · code` (the honest
default — un-probed is **not** verified). The stamping moment is the
already-mandated CLAUDE.md "Web/Pages task-acceptance discipline": a web/contract
task is done **only** when the deployed bytes/contract verify, so that same
green probe is what adds the label.

**Vocabulary note:** the lifecycle decision points above are **Checkpoints**
(the old v1 "GATE (you)"). They are *touchpoints that produce a decision*.
They are **not** the same thing as **Gates** (§7), which are *holds that
suppress pickup*. This doc keeps the two words apart deliberately; see §7.1.

---

## 4. Flows A–G (carried from v1, compressed) + the leaks this overhaul closes

The v1 flows stand. Summarized here with the concrete *leaks* that
`docs/inbox-lifecycle.md` identified, which this overhaul must close.

### Flow A — Idea intake [Brian, carried]
Phone: one text box + project picker ("or let it pick") + tap an
**entry-intent preset** (a named bundle of *entry stage* + *gate
aggressiveness*). Enricher hat dedups, pulls context, produces a structured
bd task. Two first-class modes: *autonomous-until-stuck* and
*collaborative-stage* (a scheduled pairing session in the Inbox, not a
dossier).

- **Leak to close [prior]:** add a third preset, **overview-request**, that
  produces **no bd task** and instead routes to a Blueprint refresh / FYI
  dossier (inbox-lifecycle §3.4 Gap B). Today a phone intake asking for an
  overview becomes bd notes nothing renders.
- **Leak to close [prior]:** intake state must be **phone-visible**. The
  thirsty-night episode burned 19 silent enricher retries (~$1 each) with
  nothing on any surface saying "your intake is failing" (inbox-lifecycle
  §9.5). Intake gets a small status thread on the Workspaces/Inbox surface:
  *received → enriching → created bd-X* / *failing (n retries)* / *gave up*.

### Flow B — The decision loop (the heart) [Brian, carried]
Trigger → detect & block (worker stops clean) → **dossier build** (a fresh
dossier-builder agent dispatched by the ask-brian MCP, fed the worker's rich
`context_dump`) → notify (triage only) → respond (~60s) → interpret & unblock
(deterministic for checkbox; reconciler hat for freeform) → confirm.

Leaks to close, all from `docs/inbox-lifecycle.md`:

- **Readability gate [prior/thirsty].** Brian's verbatim: *"soooo many words
  to communicate something so simple."* The dossier-builder **and** the
  fallback template must pass a human-readability gate: a cold reader
  understands (a) what blew up, (b) what they're deciding, (c) what each
  option does — in <30s, **without contract jargon.** Rule of thumb: *never
  name an internal section/ID without translating it in the same sentence.*
  (§4.2/§4.4 of inbox-lifecycle.) This dovetails with the dossier-builder
  knowing Brian's reading habits: enumerate options, show the *why*, allow
  one-character votes. [thirsty]
- **Verb taxonomy / "Dismiss as stale" bug [prior].** Every Inbox button maps
  to a distinct engine verb. No verb may default to another's payload. Known
  verbs: **apply** (pick/approve/reject), **dismiss-as-stale** (resolve
  *without* consuming the recommendation), **defer/snooze**, **escalate**.
  The current "Dismiss as stale" silently re-applies the recommendation via
  an empty-payload fallthrough — a P1 misbehavior this overhaul fixes
  (inbox-lifecycle §5).
- **Auto-close on bead resolution [prior].** When a bead is closed/unblocked
  *outside* the dossier tap-path, its dossier must leave the Inbox
  automatically (expire), never sit asking a dead question (inbox-lifecycle
  §7). "A child closes on what Brian experiences." This is the single biggest
  Inbox-cleanliness win.
- **State integrity [prior].** Post-action UI state derives from the engine
  response, never a local in-memory patch. No `0/1 resolved` after the engine
  resolved (inbox-lifecycle §6).

### Flow C — Capacity & spare cycles [Brian, carried]
Coordinator is the single usage authority; runners ask "may I start a task of
cost-class C?" before each task. Per-project modes `full | spare-cycles |
paused`. Spare-cycles = the 14.2%/day linear ramp. Brian sees 5h / 7d / spare
line / per-project mode on the always-visible Capacity strip. Agents may
downgrade/pause their own env; only Brian promotes to `full`.

### Flow D — Remote runner control [Brian, carried] (extended in §5 for parallelism)
Per-workspace `desired ∈ {running, paused, spare-only, stopped}`, set by Brian
or by an agent in that workspace. **Honest state**: the Board shows *actual*,
renders `stopping…`/`starting…`, never optimistic. "Remote-control a
non-headless Claude" stays reframed to dossier-escalation (primary) +
attach-mode (later). The §5 Activity view extends this to *multiple* agents
per workspace.

### Flow E — The Board [Brian, carried] (extended in §9 with Queue Health)
Read-model over beads. Pinned "WAITING ON YOU" lane on top; lifecycle columns;
each card shows title · stage · prio · runner/activity state · age · **the one
thing it waits on**. §9 adds the Queue-Health panel.

### Flow F — Proactive "how it fits together" [Brian, carried] → now feeds the Blueprint
When a stage like `design` completes, the system proactively builds an
overview and pushes it as `timed-fyi` (auto-proceeds in 24h). In v2 this is
**unified with the Blueprint** (§6.5): the Flow F dossier *is* the
notification that the Blueprint changed, deep-linking to the changed area.

### Flow G — Failure visibility [Brian, carried]
Progressive disclosure across a security boundary: Glance (Board badge +
plain-English class) → Summary (synced metadata, human-worded) → Forensic
(stream-json, local full / remote redacted, on-demand, never persisted).
Failure→Inbox tier mapping unchanged. Sharpest principle, carried: **surface
silent failures loudest** — loud failures self-heal, silent ones rot.

---

## 5. Flow I — Parallel runners & the Activity view [Brian B3/B4/B7]

> Combines three asks: parallel runners (B3), in-progress monitoring (B4),
> and per-task status-from-logs (B7). They're one surface: the **Activity**
> facet of a workspace.

### 5.1 The model: one serial writer lane + a parallel auxiliary pool [Brian B3]

Per workspace, the Activity view shows two lanes:

```
WORKSPACE: rhythmGame                                   runner: running ●
┌── WRITER LANE (serial — exactly one) ───────────────────────────────┐
│  ● rhythmGame-93o  "DrawingOverlay restart"   impl   ✎ writing code  │
│       2m12s in · touching: Gameplay ▸ Input · liveness ●            │
└─────────────────────────────────────────────────────────────────────┘
┌── AUXILIARY POOL (parallel — read-only or non-code) ────────────────┐
│  ◐ blueprint-update  "refresh map after 93o"   ⟳ updating Blueprint │
│  ◐ enricher          "intake 09-30"            ▣ enriching intake    │
│  ◐ xws-responder     "answering BE query"      👁 read-only answer    │
└─────────────────────────────────────────────────────────────────────┘
```

- **Writer lane** holds **exactly one** code-writing agent. The UI makes the
  singularity obvious ("serial — exactly one"). This is the constraint Brian
  set: code writers don't run concurrently in a workspace. [Brian B3]
- **Auxiliary pool** holds any number of agents that **don't write code into
  the working tree**: Blueprint updaters, enrichers, cross-workspace
  responders (read-only, §8), test-only runs that don't edit source, doc
  agents. They run in parallel with the writer. [Brian B3]
- The distinction the UI draws is *write-capability*, because that's the
  thing that can conflict. An auxiliary that needs to write code doesn't
  belong in the pool — it becomes a bead for the writer lane.

### 5.2 Per-agent activity state, derived from the log stream [Brian B7]

Each running agent shows a derived **activity state**. The signal basis is in
`docs/inbox-lifecycle.md` §9.7: liveness is **regex-parseable** from the
tool-use stream; semantic phase is *not* fully parseable but a coarse,
**tool-derived** state is. [prior — feasibility confirmed]

| Activity state | Derived from | Icon idea |
|---|---|---|
| **writing code** | `Edit`/`Write`/`MultiEdit` tool calls | ✎ |
| **running tests** | `Bash` calls matching test runners | ▶ |
| **exploring** | `Read`/`Grep`/`Glob` dominate | 🔍 |
| **thinking** | no tool events for 90–180s (soft window) | ◌ |
| **waiting on you** | blocked in an ask-brian MCP call | ⏸ |
| **rate-limited** | `rate_limit_event` stream events | ⏳ |
| **maybe stuck** | no events past 180s (hard window) | ⚠ |

**Liveness dot** is separate and blunt: green (<90s since last event), amber
(90–180s — the "thinking" soft state, already planned as `claude-tools-g2s`),
red (>180s — surfaces as **maybe stuck**). The 90/180 thresholds are
[prior]'s measured recommendation (60s would false-fire ~56× across 3 real
logs); do not tighten without re-measuring.

**Honesty rule [UX]:** "running tests" / "writing code" are *derived
heuristics*, labeled as such — never claimed as ground truth the way a
semantic LLM read would be. The Activity card may show "looks like: running
tests" rather than asserting it. This respects the [prior] finding that
semantic phase isn't regex-knowable.

### 5.3 Stuck must be visible AND actionable [Brian B4]

When an agent goes **maybe stuck** (red) or the runner itself wedges, it
surfaces in three places, loudest-first: the Activity card (⚠), the Workspace
card health pip, and — if it crosses the failure→tier mapping — the Inbox.
[Brian B4: "visible from the GUI"]

From a stuck card, Brian (or an agent) can act **[Brian B4: "actionable"]**:

| Action | What it does |
|---|---|
| **Nudge** | poke the agent (re-prompt / continue) without killing it |
| **Escalate to decision** | convert the stuck task into a Flow B dossier (reuses the v1 "intervene in a running task" reframe) |
| **Kill + retry** | terminate and re-dispatch a fresh worker on the same bead |
| **Kill + Gate** | terminate and place a **Gate** (§7) with a reason, so it stops being retried until the gate lifts |
| **Attach** | (secondary, later) tmux/ssh hand-off for a live take-over (v1 §7 deferred) |

The runner *also* watches autonomously (the watchdog already does): the GUI
surfacing is the *new* part, plus making the four actions tappable rather than
ssh-only. [Brian B4]

### 5.4 Monitoring the runner/script itself, not just agents [Brian B4]
Brian called out "the script gets stuck on something" separately from agents.
The Workspace card therefore shows **runner health** distinct from **agent
activity**: runner process alive? heartbeat fresh? last pickup when? stuck in
a skip-loop (the `dzc` epic-skip starvation shape)? A starved-but-alive runner
(looping with nothing to do) reads as **idle**, a wedged runner reads as
**stuck** — and both are visible without ssh. [Brian B4; thirsty "look into
why the runner did X" courier pattern]

---

## 6. Flow H — The Blueprint (living design + map) [Brian B1]

> The centerpiece of the overhaul. The Blueprint is the **persistent,
> always-current** picture of a workspace: an interactive **map** plus the
> **design prose** that explains it. It is *not* a dossier (dossiers are
> ephemeral decision cards). [Brian C2]

### 6.1 What it is

Per workspace, one Blueprint = **Map + Narrative**, kept in sync with the
built system and updated **as beads tasks complete.** [Brian B1]

- **Map** — the interactive diagram from the Diagrammer spec
  (`~/Downloads/HANDOFF.md`). Its IP, which transfers directly and which the
  UI/architect agents must preserve:
  - **Mental-model decomposition** — top level is **product domains**, not
    infrastructure (Posts & Feed, Messaging…), plus the client, the stores,
    and each external vendor as its own box. Queues are **edges, not nodes.**
  - **Grow-to-fit nested layout** — drill into any box to see what's inside;
    opening a node grows it and reflows siblings ("room to drill in").
  - **Edge resolution + density** — the legibility IP: resolve each edge to
    its deepest *visible* ancestor; bundle duplicates; at macro show only
    domain↔domain edges; focused, show only edges touching the focused
    subtree. This is what stops "arrows from everywhere to everywhere."
  - **APIs as boundary boxes** — a route renders as a small box straddling a
    domain's border, depicting "the way in"; when open, it arrows to the
    internal capability it calls.
  - **Focus / dim / drill** — click a node to focus (zoom-to-fit + dim
    everything not connected); drill-out auto-collapses what focus opened but
    preserves manual/locked state.
- **Narrative** — the human-facing design prose Brian asked for: explains how
  it fits together, in plain language, **including** the diagram. Skimmable
  the dossier way: TL;DR → headings → the map → drill-down detail. Expands
  acronyms on first use. [Brian B1]

### 6.2 Always-current, updated as tasks complete [Brian B1]

The Blueprint is derived from **source + bd state**, not hand-authored (the
Diagrammer's own "rebuild note": real version ingests from IaC/OpenAPI/
AST/handler scan — that's architecture, flagged, deferred). The UX
requirement: **when a bead completes that changes the structure, the
Blueprint updates** — by a **Blueprint-updater auxiliary agent** running in
parallel with the writer (§5.1, an explicit B3 parallel use case). [Brian
B1/B3]

What counts as "changes the structure" (so we don't redraw on every typo
fix) [UX]: a task closing in `design`/`impl`/`docs`, or any task whose diff
adds/removes a domain, endpoint, store, external dependency, or cross-domain
edge. Trivial closes don't trigger a redraw.

### 6.3 The hard part Brian flagged: naming & grouping [Brian B1]

Brian: making the diagram understandable *"involves deciding what to call
things, how to group entities in a way that creates a good mental model."*
The auto-generator must be good at this, and customizable. UX requirements
(the algorithm/LLM is architecture; these are the *experience* constraints):

1. **Good defaults.** The generator proposes domain names and groupings using
   the mental-model rules above (product domains, capabilities not Lambda
   names, vendors as boxes). [Brian B1]
2. **Human overrides are first-class and sticky [Brian B1: "customize"].**
   Brian (or an agent on his behalf) can **rename** a node, **regroup**
   nodes into/out of a domain, **pin** a layout, **hide** noise, or **split/
   merge** domains. Overrides persist as a **customization layer** on top of
   the derived map.
3. **The updater never clobbers an override.** Like the Diagrammer's
   `autoOpened` vs. manual distinction: auto-regeneration respects locked
   names/groupings and only reflows the un-pinned, un-renamed parts. If the
   source genuinely outgrows an override (a renamed domain was deleted), the
   conflict surfaces as a **small FYI** ("your custom name 'Billing' no longer
   maps to any code — keep / drop?"), never a silent revert. [UX]
4. **Customization is cheap and in-place.** Editing a name/grouping happens on
   the map itself (tap a node → rename/regroup), not in a config file Brian
   has to find. [UX, honoring "easy to customize"]

This naming/grouping customization layer is the per-workspace **glossary**
that v1 left as the unresolved "terminology-doc decision" (HANDOFF §"things
deferred"). v2 gives it a home: it lives *in the Blueprint*. [UX]

### 6.4 The Blueprint shows live work and situates decisions [UX]

Two integrations that make the Blueprint the spine rather than a static
picture — both already anticipated by the Diagrammer's toggles:

- **In-flight overlay.** The Diagrammer has a beads overlay toggle. The
  Blueprint lights up the domains currently being worked (from §5 Activity),
  so Brian can *see where the swarm is.* Two agents touching the same domain
  is a visible collision-risk signal (and the reason auxiliaries are
  read-only). [UX, B3/B4 tie-in]
- **Decisions are situated on the map.** A Flow B decision dossier can embed a
  **focused slice** of the Blueprint (the Diagrammer's `?focus=<id>`
  deep-link) so a decision shows *where in the system it sits*. This is the
  bridge between the ephemeral dossier and the persistent Blueprint: the
  dossier borrows a focus-view; it doesn't duplicate the map. [UX]

### 6.5 Notification: the Blueprint changed [Brian B1/B5]

When the Blueprint materially changes, Brian gets the **Flow F overview
dossier** as a `timed-fyi` — unified, not a second mechanism. Title = the
one-line "what changed about the architecture"; body = TL;DR + the changed
focus-slice; deep-links into the Blueprint. Auto-proceeds in 24h. This is
exactly Brian's "trigger this proactively to give him an understanding of how
things are designed and fit together" (v1 §0.A) made concrete. [Brian]

### 6.6 Where the Blueprint appears
Primarily the **Blueprint facet** of the workspace view (§2). The Workspace
card shows a thumbnail + "updated 2h ago." The Board's `done`-verified cards
can deep-link to the area of the map they changed. [Brian B6: "show the
diagram for that workspace or a link to the diagram."]

---

## 7. Flow J — Gates: the unified Hold view [Brian B8 / C3]

> Brian: deferrals aren't visible; he wants to see what's deferred and
> blocked, a tool to block/unblock, a **named gate addable/removable from the
> GUI** that agents read/write and the runner respects, with a **why** and a
> **what-would-unblock**. And (C3) it must be honest about the tech: we can't
> change beads; our native hold is a **label the runner reads**, coexisting
> with beads' built-in `blocked`.

### 7.1 Vocabulary (fixing a real collision)

The existing code already overloads "gate" two ways (see
`agents/gate-defer.md`'s own warning). This doc fixes the user-facing words:

| User-facing term | Means | Backed by |
|---|---|---|
| **Hold** | Umbrella: *any reason a ready-looking task isn't being worked.* | (presentation only) |
| → **Dependency hold** | blocked on another task | beads native `blocked` — **we read, can't change** [C3] |
| → **Scheduled hold** | deferred until a date | beads native deferral — **we read, can't change** [C3] |
| → **Gate** | a **named** hold with a reason + unblock condition, GUI-addable/removable, agent-read/writable, **runner-respected** | **our native `gate:<id>` label** [C3] + `gate-defer.sh` |
| **Checkpoint** | a lifecycle decision point (old "GATE (you)") — produces a *decision*, not a hold | `preset:*` + `gate-policy.sh` |

**Gate ≠ Checkpoint.** A Checkpoint is a touchpoint; a Gate is a suppression.
They interact (a Checkpoint can *place* a Gate), but they're different nouns.
The internal `gate-policy.sh` "pickup gate" is a **Checkpoint** in user terms;
the internal `gate:<id>` "cohort gate" is a **Gate.** [UX — the architect
should keep the code names but the UI uses Hold/Gate/Checkpoint.]

### 7.2 The Gates facet: one view over three mechanisms [Brian B8 / C3]

The Gates facet (per workspace; also a global rollup) lists **every held
task**, unified, each row showing:

```
┌── HELD IN rhythmGame ───────────────────────────────────────────────┐
│ ⛔ Gate  "audio-redesign"   3 tasks   set by: you · 4d ago           │
│     why: waiting on the audio-engine decision                       │
│     unblocks when: that decision lands (or you lift this)           │
│     [ lift gate ]  [ edit why ]                                     │
│ ⛓ Dependency  rhythmGame-77p   blocked on rhythmGame-77a (open)     │
│     unblocks when: 77a closes            (beads-native — read-only) │
│ ⏰ Scheduled  rhythmGame-5kq   deferred until 2026-07-01            │
│     unblocks when: that date    (beads-native; gate-owned? → 'x')  │
└─────────────────────────────────────────────────────────────────────┘
```

- **All three hold types appear together**, so "what's deferred / what's
  blocked" is one glance. [Brian B8]
- **Only Gates are fully editable from the GUI** (add / remove / edit why /
  edit unblock-condition), because only Gates are our own label. Dependency
  and Scheduled holds are shown **read-only with their native unblock
  condition** (the blocking task; the date) and the honest note that they're
  beads-native. [Brian C3 — "coexist with built-in beads blocked."]
- A Scheduled hold that was set *on behalf of a Gate* (the `gate:<id>` defer
  coupling in `gate-defer.sh`) is shown **under its Gate**, so lifting the
  Gate visibly clears the defers it owns. This is the existing apply/lift
  mechanic surfaced. [prior + Brian B8]

### 7.3 The Gate object [Brian B8]

A **Gate** is the named hold Brian asked for. It carries, beyond today's bare
`gate:<id>` label + defer date:

- **name** — `gate:<id>` (lowercase/digits/hyphens, per `gate-defer.md`).
- **why** — free text: *why is this held.* **(new metadata this overhaul
  adds — today the label has no reason field.)** [Brian B8]
- **unblock condition** — free text or a structured ref: *what would release
  it* (e.g. "the audio-engine decision lands", or a bead ref, or a date).
  [Brian B8]
- **owner** — human or agent, and which. So Brian can see *an agent placed
  this* (the thirsty "you didn't tell me about the blocker" / invisible-defer
  class — now every agent-placed hold is visible with its reason). [Brian B8;
  thirsty]
- **scope** — one task or a cohort (named gate over many tasks; lifting once
  releases all — the existing cohort mechanic).

### 7.4 Who can do what [Brian B8]

| Actor | Can | Via |
|---|---|---|
| **Brian (GUI)** | add a Gate, set/edit why + unblock, lift a Gate, see all holds | the Gates facet [Brian: "add/remove from gui"] |
| **Agents** | place a Gate with a why + unblock; read existing Gates before deciding | `gate-defer.sh` + the label [Brian: "agents can write and read"] |
| **The runner** | refuses to pick up a Gated task | label check on pickup (like `RUNNER_NO_CLAIM_LABELS`) [Brian: "have the runner respect them"] |

**The agent-write path is the thirsty fix.** Today agents defer things
invisibly; v2 requires that **an agent that holds work places a Gate with a
why** — and that placement is *visible on the Gates facet and (if it holds
significant work) an FYI on the Inbox* (§10). No more silent deferrals.
[Brian B8; thirsty]

### 7.5 Gates feed the Board's "one thing it waits on" [UX]
Every Board card that is held shows *which* hold and its unblock condition in
the card's "waiting on" field — so the Board never shows a stalled task
without saying why. This is the same data as the Gates facet, surfaced inline.
Directly answers the thirsty "why is `bd ready` empty / showing only epics"
class without Brian having to ask an agent. [thirsty]

---

## 8. Flow K — Cross-workspace sync (FE↔BE) [Brian B2 / C4]

> An agent in workspace A asks a question that depends on workspace B; a
> **read-only** agent spawns in B to answer; the answer returns to A. Every
> exchange **FYIs Brian** (C4). It's the ask-brian pattern pointed sideways.

### 8.1 The flow

```
Agent in A (e.g. FE) hits a B-dependent question
   │  "is the cancel endpoint deployed? what's its response shape?"
   ▼
mcp__ask-workspace  (sibling of ask-brian)            [Brian B2: "via MCP"]
   │  routes to workspace B
   ▼
READ-ONLY responder spawns in B  (parallel; cwd B; Read/Grep/Glob/bd-read
   │  only — NO Write/Edit/Bash-that-mutates)         [Brian B2: "can't modify code"]
   │  answers from B's code + docs + bd + Blueprint
   ▼
answer returns to A's agent as the tool_result        [like ask-brian]
   │  A continues in-session (no exit/respawn)
   ▼
FYI lands on Brian's Inbox (timed-fyi, BATCHED)        [Brian C4]
   "FE asked BE: cancel endpoint? → BE: deployed since cmt X, shape {…}.
    FE proceeding."   auto-proceeds on silence
```

- The responder runs **in parallel** with B's writer (it's an auxiliary in
  B's pool, §5.1) and is **read-only**, so it cannot conflict with B's
  in-progress work. [Brian B2 — both constraints explicit]
- The asking agent **blocks** on the answer like ask-brian does, then resumes
  in the same session. [UX, mirrors the validated ask-brian shape]

### 8.2 "Always FYI" survives only because of batching [Brian C4; UX flag]

Brian chose: **every** exchange FYIs him. The thirsty data shows this is
high-volume (~45 FE↔BE coordination messages over the build). So the
**load-bearing mechanism that makes "always FYI" not become 45 pings is
digest-batching**: exchanges accrue into the existing `timed-fyi`/`digest`
tiers and roll up ("BE↔FE: 6 syncs today — all resolved, none needed you").
Brian can expand the digest to read each. **This batching is not optional**;
without it C4 reproduces the courier-overload it was meant to remove.
[UX — explicit flag; honoring C4]

### 8.3 The 20% that escalates [thirsty]

If the read-only responder detects a **conflict** (the two workspaces
disagree on a contract) or a **missing design** (neither side has decided the
shape), it does **not** silently answer. It escalates to a **blocking Flow B
dossier** so Brian rules — preserving exactly the cases where the thirsty
transcripts show his mediation *caught* something (the post-feed schema drift;
the saly epoch-bump call). The split: mechanical sync → FYI; real conflict →
decision. [thirsty: "handle the 80% mechanical, escalate the 20% conflict."]

### 8.4 The Cross-WS global view [UX, B6-adjacent]

A global surface (§2) shows:

- **Coupling map** — a federated Blueprint slice: A's domains ↔ B's domains
  via the APIs that cross. (The Diagrammer already models APIs as boundary
  boxes and externals as boxes; a sibling workspace is just another boundary.)
  Lets Brian *see* FE↔BE coupling. [UX]
- **The relay log** — the running list of exchanges and their outcomes
  (resolved / escalated). This is the auditable record so Brian can trust the
  80% he's no longer couriering actually happened. [UX; thirsty "trust it
  landed without checking" = cross-cutting principle, applied to relays]

### 8.5 Guardrails carried from thirsty
- **Workspace-scope check on claims [thirsty]:** a task that references a
  cross-repo ID and isn't a tracking-only task is flagged, not silently
  claimed by the wrong workspace's runner (the "why is there a backend task in
  the frontend tracking" frustration).
- This flow is the productization of `claude-tools-r0m` (deferred to 2030 in
  v1). The thirsty findings argue it's far higher-value than that deferral
  implies; Brian's B2 ask makes it in-scope now. [thirsty / Brian B2]

---

## 9. Queue Health (Board extension) [thirsty]

> Not in Brian's explicit list, but the thirsty transcripts show him asking
> the same queue-health questions over and over that no current view answers.
> Folded into the Board facet, not a new surface. **[thirsty]** — trade off
> freely, but high-evidence.

The Board's lifecycle columns get a **Queue-Health** strip answering, at a
glance, the questions Brian repeatedly had to ask an agent and then *distrust*
the answer:

| Question Brian kept asking [thirsty] | What the strip shows |
|---|---|
| "Why is `bd ready` empty / only epics?" | An **empty-queue explainer**: how many ready, how many held (by hold type → links to Gates), how many hidden because a parent is deferred |
| "Are these epics done or do they have hidden deferred children?" | Per-epic: ready-children count; **epics with 0 ready children flagged** |
| "Net open tasks per day — trending up or down?" | A **net-velocity** number (created − closed / day). **Positive trend = runaway-expansion alarm** (the "8 hours, more open than we started" episode) |
| "Did the audit actually read everything?" | When an agent audit reports N items, the **coverage ratio** (read / total) is surfaced, not just the conclusion |

The net-velocity alarm and the empty-queue explainer are the two highest-value
items — they turn "Brian notices from feel" into "the Board tells him."
[thirsty: the single most important data point was runaway task creation.]

---

## 10. Notifications [Brian B5]

> "Notifications for when there's a new action required (like a new dossier)."
> Carries v1's three-tier model and extends the trigger catalog. The Inbox is
> still where actions live; notifications only *triage*, never carry content
> (v1 principle 2).

### 10.1 Tiers (carried)

| Tier | On silence | Notify |
|---|---|---|
| `blocking` | hard-blocks until answered | ping now |
| `timed-fyi` | auto-proceeds after window (24h default; builder may shorten); reversible | next digest |
| `digest` | proceeds; informational | daily roll-up |

### 10.2 Trigger catalog (what fires a notification in v2)

| Event | Tier | Source |
|---|---|---|
| New decision dossier (worker stuck / checkpoint / human flag) | blocking | Flow B [Brian B5] |
| Blueprint materially changed | timed-fyi | Flow H/F [Brian B1/B5] |
| Cross-workspace exchange | timed-fyi, **batched** | Flow K [Brian C4] |
| Cross-workspace **conflict** / missing design | blocking | Flow K §8.3 [thirsty] |
| Task **maybe stuck** (not auto-recoverable) | timed-fyi or blocking per failure→tier map | Flow I [Brian B4] |
| Runner wedged / starved | blocking (systemic) | Flow I §5.4 [Brian B4] |
| Intake failing / gave up | timed-fyi | Flow A leak [prior] |
| Queue-health alarm (runaway net-velocity; whole epic gated) | timed-fyi | §9 [thirsty] |
| Agent placed a Gate holding significant work | timed-fyi | Flow J §7.4 [Brian B8] |
| Ready-to-pair (collaborative stage) | blocking-ish (scheduled session) | Flow A [Brian] |

### 10.3 Batching is the spine [Brian, carried + C4]
Cross-cutting principle 1 ("never ping twice for what could be one digest")
is doubly load-bearing now that cross-workspace exchanges always FYI. The
notification layer batches aggressively: N pending → 1 digest. [Brian C4 flag,
§8.2.]

---

## 11. Cross-cutting principles (v1 carried + v2 additions)

Carried from v1 (still Brian-direct or accepted):
1. **The Inbox is the product.** One ranked, batched queue.
2. **Every ask is a standalone dossier:** TL;DR → decision → expandable
   context. Notifications triage; never carry content.
3. **Your "no" is as cheap as your "yes."** Reject/edit is one tap.
4. **Honest state everywhere.** Desired vs. actual always distinguished; no
   optimistic control UI.
5. **Pre-declare consequences** so the common decision is deterministic.
6. **Silence is a valid input.** Reversible + timed-auto-proceed; specific
   gates opt into hard-block.
7. **Surface silent failures loudest.**

Added in v2:
8. **Nothing is held invisibly. [Brian B8]** Every hold has a why and an
   unblock condition, visible on the Gates facet; agent-placed holds are as
   visible as human ones.
9. **The map is always honest. [Brian B1]** The Blueprint reflects the system
   as built; customizations are sticky and never silently reverted; a
   customization that no longer maps to code surfaces as an FYI, not a
   silent change.
10. **Derived status is labeled as derived. [UX/prior]** Log-parsed activity
    ("looks like running tests") and liveness windows are heuristics, shown as
    such — never asserted with the confidence of ground truth.
11. **Done means verified. [thirsty]** "Code landed + local tests pass" shows
    as `done · code`; only a production/contract probe earns `done · verified`.
12. **Mechanical handoffs are automated; conflicts escalate. [thirsty/B2]**
    The 80% cross-workspace courier work happens silently-but-logged; the 20%
    real conflict becomes a decision.

---

## 12. Coverage & traceability

Every Brian ask → where it's handled. (Built so the completeness can be
checked, per the thirsty "did you actually cover everything?" instinct.)

| Brian ask | Tag | Handled in |
|---|---|---|
| Better diagram + living design, kept current, customizable | B1 | §6 Flow H |
| Cross-workspace sync, read-only responder, via MCP | B2 | §8 Flow K |
| Parallel runners (writer serial, aux parallel) | B3 | §5.1 Flow I |
| Monitoring in-progress, visible + actionable | B4 | §5.2–5.4 Flow I |
| Notifications for new required action | B5 | §10 |
| Workspace view (progress/done/ready/not-ready/deferred, gates, diagram) | B6 | §2 + Board/Gates/Blueprint facets |
| Per-task status from logs (writing/testing/stuck) | B7 | §5.2 Flow I |
| Gates: visible holds, add/remove, why + unblock, runner respects | B8 | §7 Flow J |
| Surfaces: richer multi-view app | C1 | §2 |
| Name the living design "Blueprint" | C2 | §6 |
| Gates unified presentation over beads-native + native label | C3 | §7.1–7.2 |
| Cross-workspace always-FYI | C4 | §8.2 |

| Planned leak (inbox-lifecycle.md) | Handled in |
|---|---|
| Overview-request intake → no bd task | §4 Flow A |
| Intake state invisible | §4 Flow A |
| Dossier readability gate | §4 Flow B |
| "Dismiss as stale" verb bug | §4 Flow B |
| Auto-close dossier on bead resolution | §4 Flow B |
| Render-vs-engine drift | §4 Flow B |
| Board lifecycle spine shows zeros | §9 (Board data pipeline; UI/arch) |

---

## 13. Deferred (UX requirement recorded; decision is design/architecture)

- **Coordinator reachability** (off-network, laptop asleep) — carried from
  v1; the *how* is architecture.
- **Blueprint source-ingestion** — deriving nodes/edges/APIs from
  IaC/OpenAPI/AST/handlers (Diagrammer "rebuild note"). UX requires "always
  current"; the ingestion mechanism is architecture.
- **Map deep-link `?focus=<id>`** — required by §6.4 (decisions situated on
  the map) and the Diagrammer's top "known gap." UX-required; implementation
  deferred.
- **Attach-mode take-over** (tmux/ssh) — secondary to dossier-escalation;
  carried from v1.
- **Per-workspace glossary format** — v1's unresolved terminology-doc choice;
  §6.3 gives it a *home* (the Blueprint customization layer); the storage
  format/location is architecture.
- **Semantic phase detection** — "writing code" vs "reviewing" beyond the
  coarse tool-derived enum needs more than regex (an LLM read); §5.2 ships the
  regex-derivable coarse states only. Richer phase = later.

---

## 14. Open questions for Brian (small, non-blocking)

These don't block the architect/UI agents but are worth a later one-tap
answer:

1. **Gate placement authority.** Should *any* agent be able to place a Gate,
   or only specific hats (e.g. a worker that genuinely can't proceed)? Default
   assumed: any agent, but every placement is visible + FYI'd if it holds
   significant work. [§7.4]
2. **Blueprint customization conflict default.** When a customization no
   longer maps to code, default to *keep + FYI* (vs. auto-drop)? Assumed:
   keep + FYI. [§6.3]
3. **Net-velocity alarm threshold.** What net-open/day trend should trip the
   runaway alarm? Assumed: any sustained positive trend over a few days; tune
   from real data. [§9]
4. **Cross-WS digest cadence.** Daily roll-up of relays, or per-N-exchanges?
   Assumed: daily digest + immediate escalation on conflict. [§8.2]
