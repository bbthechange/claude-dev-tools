# Beads Runner — UX Design

Status: draft (§11-amended 2026-05-20: Flows A/D/F bound to daemon + write-proxies + enricher hat per epic claude-tools-kie) · Scope: user flows, not implementation/architecture
Owner: Brian · Last updated: 2026-05-20

> **§11 amendment ledger (this document).**
> Per INTERFACE.md §11 change-protocol discipline applied to UX-DESIGN:
>
> | Date | Change | Authorization |
> |---|---|---|
> | 2026-05-20 | Flows A / D / F bound to the post-8bm shape (per-machine daemon, `/api/set-desired` + `/api/intake` write proxies, enricher as the 7th specialist hat, Flow F trigger = bd stage transition + overview profile + `timed-fyi` 24h tier). UX semantics unchanged; the amends are doc→code traceability so a future reader can find the wiring from §4 flows to the M / S / I / F / P tracks under epic claude-tools-kie. | Brian, epic claude-tools-kie scope (children D3/D4) |

This document maps the **user experience** of expanding the beads-runner from a
single-machine headless task loop into a system that runs your idea→test
pipeline autonomously and surfaces only the moments that genuinely need you.

It deliberately stops at the UX boundary. Where a UX requirement forces a
design/architecture decision, the requirement is recorded here and the decision
is flagged as deferred — not solved.

---

## 0. Requirement provenance — read this first

This separates **what Brian asked for** from **what the design agent added**.
It is the authoritative source for that distinction; the rest of the document
elaborates but does not change it.

**Instruction to downstream agents:** do the extra defensive work — guarding a
requirement against compromise, hardening it, treating it as a fixed constraint
— **only for items in §0.A and §0.B**. Everything in §0.C is a proposal:
implement it if it serves an A/B requirement, trade it off or drop it freely
otherwise, and do not spend effort protecting it for its own sake.

### 0.A — Direct requirements (from Brian; protect rigorously)

Stated explicitly in the original brief or follow-ups:

- **End-to-end lifecycle tracking:** idea → UX → design → (scaffold *only* if a
  new project, not for a feature on an existing one) → implementation → docs →
  tests, where tests = unit + integration + e2e-that-future-agents-can-run +
  manual-e2e. Reflected in the tool the way Brian already works.
- **Remote start/stop of the runner**, per project, so he can choose which
  projects pick up tasks — controllable both **by him** and **by agents in a
  workspace** (an agent can start/stop for its own env).
- **One central runner per computer** that checks Claude capacity; the runner
  in each environment checks with that central one before working.
- **Capacity is visible in the UI.**
- **The central runner is the sync + remote control/viewing backbone** (Brian's
  own hypothesis, stated as a likely role).
- **Remote idea intake:** he types what he wants from a beads task and sends it;
  a local agent reads it, pulls in the correct documents (existing design for
  it, project context docs, etc.), and creates a beads task that then gets
  picked up.
- **Strong human-interaction support**, specifically all of:
  - Reads tags on issues for when a human decision is needed, blocks on that,
    possibly sends a notification.
  - A **multi-step document-generation process** for human decisions: (1) first
    pass against project goals/designs to filter out anything already answered
    and to identify what extra context this adds; (2) a readability pass —
    concise, all context, well organized, skimmable but with drill-down detail
    (summaries → headings → diagrams → detail), states why it needs his action;
    minimal jargon/acronyms.
  - Easy to respond to: inline editing, and approval checkboxes.
  - When marked human-review-needed, a script triggers the workflow, creates
    the document, sends it to him; when he responds, the right workflow is
    triggered to unblock / create new beads tasks.
  - Also trigger this proactively to give him an understanding of how things
    are designed and fit together.
- **Runner keeps running when out of tasks** and picks tasks up once added.
- **Spare-cycles mode** with the exact weekly ramp: 100% / 7 days = 14.2%/day;
  day 1 use up to 14.2%, day 2 up to 28.4%, etc. Low-priority tasks run only
  when there are spare cycles.
- **Kanban/board per workspace**, viewable locally and remotely, tracked in the
  idea → ux → design → impl → test lifecycle.
- **Failure details viewable locally and remotely** when a beads task fails.

Asked for, but Brian himself flagged as probably not possible — treat as a
**goal to satisfy by other means, not a hard requirement**:

- The runner starts a *non-headless* Claude Code instance in a project with
  remote control. (See §6 D7 / §7 for the reframe.)

### 0.B — Direct decisions (from Brian; same status as 0.A)

Chosen by Brian when asked:

- **Response surface = mobile-friendly web app** hosting both Inbox and Board.
- **Intake gate = human-tapped entry-intent preset at capture**, extensible
  preset list. (Brian's refinement of the original "hybrid by size" choice.)
- **Silence behavior = tiered**: real decisions hard-block, FYIs auto-proceed.
- **Decision consequences = pre-declared per option; an interpreting agent runs
  only for freeform/edited responses.**
- **`timed-fyi` window = 24h global default** (builder may shorten).
- **Remote forensic failure view = redacted, on-demand, never persisted** is
  sufficient for now.
- **UX requirement (design deferred):** the web app must be reachable
  off-network and while the laptop is asleep.

### 0.C — Design-agent elaborations (proposals; trade off freely)

Not asked for; added by the design agent as UX structure. Useful, but not to
be defended for their own sake:

- The "attention router" reframe and the **two-surfaces-only** constraint
  (Inbox + Board as named, exclusive surfaces).
- Naming the decision/idea queue "the Inbox" as a distinct product concept.
- The lifecycle **gate map** (which transitions auto-advance vs. `GATE (you)`)
  and using the lifecycle as a dependency template — Brian asked for the
  *tracking*, not this specific gating model.
- **Notification batching** ("3 pending → 1 digest") and the formal three-tier
  model (`blocking` / `timed-fyi` / `digest`) — the tiering of *silence* is
  0.B; this packaging of *notifications* is elaboration.
- Formalizing the document process into named **Pass 1–4** (Brian specified the
  passes' intent; the structure/labels are elaboration).
- "Worker stops clean / no burning cycles," **honest desired-vs-actual state**
  rendering, the **single-usage-authority** model, and the agent/human **trust
  boundary** (agents may downgrade own env; only Brian promotes to `full`).
- The **failure → Inbox tier mapping** table and the "surface silent failures
  loudest" principle.
- Treating **collaborative stage** ("go over the UI with an agent") as a
  distinct first-class interaction mode.
- The cross-cutting principles list (§5) as a whole.

---

## 1. The reframe: an attention router

Today's script optimizes machine throughput (fresh context per task, retries,
watchdog, failure classification). The expansion optimizes **your** throughput.
Your scarcest resource is not Claude capacity — it is your decisions and your
attention.

> The system does everything autonomously **except** the moments that genuinely
> need you — and it packages those moments so you can resolve them in ~60
> seconds from your phone, batched, without ever having to go ask "what's
> happening?"

Every flow in this document is judged by one metric: **does it reduce the
number, size, or cost of your interruptions?**

---

## 2. Actors and surfaces

You touch exactly **two surfaces**. Everything else is machinery you should
never have to look at directly.

| Actor | Role | You see it? |
|---|---|---|
| **You** (remote, async) | Inject ideas, make decisions, set policy | — |
| **The Inbox** | Decisions + ideas, in and out | ✅ surface 1 |
| **The Board** | Situational awareness, lifecycle-tracked | ✅ surface 2 |
| Central coordinator | Capacity authority + control plane + sync backbone | only via Board status strip |
| Per-project runners | Today's script, generalized + remotely controllable | only as a state/toggle on the Board |
| Worker agents | Ephemeral task executors | never |
| Specialist agents | Intake-enricher, dossier-builder, stage agents (ux/design/impl/docs/test) | never directly |

Both surfaces are routes in **one responsive web app**, mobile-friendly,
rendering over the beads read model plus a thin control/notify channel.

Design rule: if a flow forces you onto a third surface, the flow is wrong.

---

## 3. The lifecycle spine

The single most powerful organizing concept. It is simultaneously the **Board
columns**, the **dependency template** intake stamps onto every idea, and the
**gate map** (which transitions auto-advance vs. need you).

```
 idea ──▶ ux ──▶ design ──▶ [scaffold?] ──▶ impl ──▶ docs ──▶ tests ──▶ done
   │       │        │                         │                 │
   └ gate  └ GATE   └ GATE                     └ auto            └ auto
   (auto)  (you)    (you, big ones)                          (unit/integ/
                                                              e2e-agent +
                                                              e2e-manual ↩ you)
```

Each stage = a bead with a `stage:` label + a matching specialist agent + a
gate policy. Most transitions auto-advance; the few `GATE (you)` transitions
are exactly your decision touchpoints. "Manual e2e" is itself a human-task
type that routes to your Inbox like a decision.

---

## 4. The flows

### Flow A — Idea intake (raw thought → pipelined work)

You declare **entry intent** at capture time by tapping a preset, rather than
the system guessing the size. Each preset is a named bundle of two dials:
**entry stage** + **gate aggressiveness**. The preset list is extensible — add
more as usage reveals them.

```
You (phone): one text box + project picker ("or let it pick")
             + tap an ENTRY-INTENT preset
        │   [voice→text ok; this must be ~5s of effort]
        ▼
Enricher agent (in project context):
   • dedup: is this already bead-123? → propose augment, not duplicate
   • pull: project goals, existing design docs, related code, related beads
   • produce structured proposal: title · the "why" · entry stage (from
     preset) · acceptance criteria · deps · priority
        │
        ▼
   gate policy comes from the tapped preset, not a size classifier:
   ┌─ "Send it down the pipeline until it gets reasonably stuck"
   │     → maximally autonomous; no gate until a worker genuinely
   │       can't proceed → then a dossier (Flow B)
   ├─ "I need to go over the UI with an agent"
   │     → enters at `ux`; the ux stage is a *collaborative* session
   │       with you, not autonomous — scheduled into the Inbox
   └─ (more presets added with use)
        ▼
Bead created, stage-labeled, on the Board, runner-eligible
```

Two interaction modes fall out of the presets and both must be first-class:

- **Autonomous-until-stuck** — the default workhorse. No touchpoint until a
  real blocker.
- **Collaborative stage** — you explicitly want to be *in* a stage (e.g. work
  the UX with an agent), not just approve its output. This is a different
  touchpoint from a dossier: it is a scheduled working session, surfaced in the
  Inbox as "ready to pair on X" rather than "decide X."

Enricher edge cases route to the Inbox as **one** tiny question, never a guess:
ambiguous project, looks-like-a-duplicate, too vague to scope.

**Binding to implementation (§11 amend 2026-05-20).** The intake path above is
realized by three concrete pieces, end-to-end:

1. **Phone-UI intake page** — a third route in the web app at `/intake` (a
   sibling of Board and Inbox): one text-area + a project picker
   ("or let it pick") + an entry-intent preset chooser. Mobile-friendly,
   ~5s of effort. (Track **I1**, e.g. `claude-tools-tbl`.)
2. **`/api/intake` write proxy** — a server-side Pages Function (modeled on the
   existing inbox-respond proxy) that holds the bearer, accepts
   `{idea_text, project_ref|null, preset}`, and writes an `intake-request` row
   to the engine. The phone never holds the engine bearer; the proxy does.
   (Track **I2**, e.g. `claude-tools-x9u`.)
3. **The enricher agent** — a *fresh `claude -p` session* launched **inside
   the chosen workspace** (cwd + `--add-dir` + workspace `CLAUDE.md`
   available), with **kind = `enricher`**. This is the **7th specialist hat
   (added to D3's list of 6)** — the same one-binary, kind-selected-system-prompt
   model as the ux/design/impl/docs/tests/reconciler hats; the enricher hat is
   the dedup + context-gather + structured-proposal step described in the
   diagram above, and it produces the `bd create` call (title, why, entry
   stage from the preset, acceptance, deps, priority). Dispatch is owned by
   the per-machine daemon (Flow D / M-track), which observes `intake-request`
   the same way it observes desired-state and hosted-resolution rows. Tracks
   **I3** (dispatch, e.g. `claude-tools-06i`) and **S3** (the enricher hat
   itself, e.g. `claude-tools-bnq`).

The two named presets (autonomous-until-stuck, collaborative-stage) are the
seed catalog; preset extensibility is track **I4** (`claude-tools-vvh`). Both
reduce to (entry stage, gate aggressiveness) per §7.

---

### Flow B — The decision loop (the heart)

```
TRIGGER: bd `human` flag · worker hits a fork it can't resolve ·
         stage GATE reached · proactive "understand the design" checkpoint
   │
   ▼
1. DETECT & BLOCK
   bead → blocked. The worker that raised it stops *clean* (no burning
   cycles waiting). Runner moves on / pauses per project policy.
   │
   ▼
2. DOSSIER BUILD  (multi-pass agent, explicit passes)
   Pass 1 — Dedup vs canon: load goals + design docs; delete anything
            already answered; isolate the *actual delta / new info*.
   Pass 2 — Framing: the ask · options · recommendation + why ·
            blast radius (each option → what it unblocks / forecloses) ·
            what's reversible. Each option emits a machine-applyable
            consequence block (creates / unblocks / labels).
   Pass 3 — Readability: TL;DR (1 sentence + the ask) → skimmable
            headings → diagram if structural → drill-down detail.
            Expand every acronym on first use; reading-level pass.
   Pass 4 — Respondability: render response affordances *into* the doc —
            per-decision approve/reject, inline-editable recommendation,
            freeform note. The doc IS the form.
   │
   ▼
3. NOTIFY  (triage only, never content)
   title = the one-line ask · body = TL;DR · deep link to dossier
   BATCHED: 3 pending → 1 digest, not 3 pings
   TIERED:  blocking → ping now · timed-fyi → digest · digest → daily roll-up
   │
   ▼
4. RESPOND  (web app, phone, ~60s)
   skim TL;DR → tap approve  /  edit recommendation inline  /  note
   │
   ▼
5. INTERPRET & UNBLOCK
   pure checkbox  → deterministic: apply the option's pre-declared
                    consequence block — instant, trustworthy
   freeform/edits → reconciler agent interprets vs the options,
                    may emit a follow-up dossier if you opened a new Q
   │
   ▼
6. CONFIRM  (lightweight ack — so you trust it landed without checking)
   "Approved B · created 3 impl tasks · runner picked up the first"
```

---

### Flow C — Capacity & spare cycles

- **Coordinator is the single usage authority.** Runners stop self-polling the
  usage API; they ask the coordinator *"may I start a task of cost-class C?"*
  before each task. (Today every runner polls independently — N runners, N
  polls, races, no global view.)
- **Per-project mode:** `full` (run to hard ceiling) · `spare-cycles` (only
  within today's envelope) · `paused`.
- **Spare-cycles math:** linear daily ramp — day 1 allow ≤14.2% of the 7d
  budget, day 2 ≤28.4%, … Low-priority work backfills unused capacity without
  ever starving the weekly cap. `full` runners gate on the hard ceiling;
  `spare` runners gate on *today's line vs. actual 7d utilization*.
- **You see** (Board status strip, glanceable): 5h gauge · 7d gauge · today's
  spare line vs. actual · per-project mode.
- **You control:** flip any project's mode remotely. Agents may
  downgrade/pause their *own* env (trust-safe); only you can promote to `full`
  (trust boundary).

---

### Flow D — Remote runner control

Each project is a controllable unit, **`desired` ∈
`{running, paused, spare-only, stopped}`** per workspace, settable by **you**
(Board toggle) or **an agent in that workspace** (e.g. analysis agent: "blocked
on a human decision → pause this runner, save cycles").

Two UX requirements that are easy to get wrong:

- **Honest state.** The Board shows *actual* runner state, not desired. A
  toggle whose effect is graceful/polled must render `stopping…` → `stopped`,
  never optimistic.
- **The "remote-control a non-headless Claude" idea is reframed.** Driving a
  GUI remotely is a rabbit hole. The underlying need is "occasionally take over
  / intervene in a running task." Serve it with: **escalate this task to a
  decision dossier** (reuses Flow B entirely) as the primary path, and an
  attach-mode hand-off (tmux/ssh) as a secondary, later option.

**Binding to implementation (§11 amend 2026-05-20).** "Remote start/stop"
(§0.A) is realized by a closed loop between the phone, a write proxy, the
engine, and the per-machine daemon. Each step has a named owner so a future
reader can trace the flow from UX to code:

1. **Phone → write proxy.** The Board toggle POSTs to
   **`/api/set-desired`**, a Pages Function modeled on the existing
   inbox-respond proxy (server-side bearer; HARD-CODED literal `op =
   'set-desired'`). Payload: `{project_ref, desired:{state, actor}}`.
   The phone never holds the engine bearer; the proxy does. (Track **F1**,
   e.g. `claude-tools-49w`.)
2. **Engine: set-desired op.** The proxy invokes the engine's **`set-desired`**
   operation, which writes the new `desired` value into the per-workspace
   `runner_state` row (a single write; the engine returns the new
   `runner_state` JSON for the Board to render).
3. **Daemon honors the desired state on its poll.** The per-machine daemon
   (M-track) polls each registered workspace's `runner_state` on a fixed
   interval and **converges actual → desired** by spawning or killing the
   workspace runner process it owns:
   - `desired = running` → the daemon **spawns** the workspace runner if it is
     not already alive (`run-beads-tasks.sh` in that workspace).
   - `desired = paused` → the daemon stops handing the workspace new tasks
     (the in-flight task finishes; no new pickup) — runner process stays up
     so it can resume cheaply.
   - `desired = spare-only` → like `paused` for `full`-mode work but the
     runner keeps picking up tasks that fit today's spare-cycles envelope
     (Flow C math).
   - `desired = stopped` → the daemon **kills** the workspace runner cleanly
     (drains the current task, then exits the runner process; nothing is left
     on the machine spinning).

   Tracks **M1** (`claude-tools-gim`, daemon skeleton + launchd plist),
   **M3** (`claude-tools-cgh`, the desired-state poll itself), and **F3**
   (`claude-tools-6mx`, the end-to-end honors-transitions check).
4. **Board re-renders honestly.** The Board reads the same `runner_state`
   projection (Flow E) and shows `desired` separately from `actual`. A toggle
   that has been written but not yet honored shows `stopping…` / `starting…`
   — never optimistic, never out-of-sync with what the daemon is actually
   doing. (Track **F2**, e.g. `claude-tools-8fh`.)

**Why this binding matters.** Pre-amend, "remote start/stop" was structurally
impossible: the Local Agent was a library sourced *into* each workspace
runner, so a stopped workspace had nothing left on the machine to restart it.
The §0.A "one central runner per computer" requirement is what justifies
promoting the Local Agent to a real per-machine daemon process, and the
daemon is what makes Flow D's `stopped → running` round-trip possible at all.
(Background: epic claude-tools-kie, audit point #2.)

---

### Flow E — The Board (situational awareness)

Its #1 job is not task management. It answers, in 5 seconds: *"is anything
waiting on me, and is the machine healthy?"*

```
┌─ STATUS STRIP ─ cap 5h 31% · 7d 44% (spare line 51%) · 3 runners up · ⚠ 2 decisions · ⚠ 1 silent fail
├─ ⬛ WAITING ON YOU ───────────────────────  (pinned lane, always top)
│     bead-204  "Auth: cookie vs token?"   P1   2h
├─ idea │ ux │ design │ impl │ docs │ tests │ done
│   ▢▢    ▢     ▢▢      ▢▢▢   ▢      ▢       …
└─ each card: title · stage · prio · runner state · age · the one thing it waits on
```

Built as a **read model over beads** (already git-backed / Dolt-synced). That
sync is the remote backbone — "remote" needs a read-model + thin control/notify
channel, not a new datastore. Local and remote are the same view.

---

### Flow F — Proactive "how it fits together" docs

Same dossier machinery as Flow B, different trigger and tier: when a stage like
`design` completes, the system proactively builds a "here's how this is going
to fit together" dossier and pushes it as **timed-fyi** ("object within 24h or
it proceeds"). Architectural visibility without going to ask.

**Binding to implementation (§11 amend 2026-05-20).** Three named pieces, all
already-present surface — Flow F is mostly *wiring*, not new machinery:

- **Trigger = a bd task transitioning.** Concretely: a bd task with
  `stage = design` closing fires the trigger (until the L-track adds `stage`
  as a first-class field, label-based detection on `stage:design` is the
  floor; same observable). The trigger enqueues a dossier-build request
  with `profile = overview` and `tier = timed-fyi`. Other stage transitions
  (e.g. impl closing, a milestone closing) reuse the same trigger shape;
  the design-closing case is the seed. (Track **P1**, e.g.
  `claude-tools-3pq`.) The observer ideally lives in the per-machine
  daemon (M-track) so it fires even when no workspace runner is on the
  bead; an interim hook in `run-beads-tasks.sh`'s post-task path is
  acceptable as a stopgap.
- **Dossier profile = "deep body + zero or all-`fyi-objectable` items."**
  This is a first-class profile already named in DESIGN AD7 / INTERFACE
  §5.2.1 (not a tier variant): a deep `tldr` + `sections[]` +
  `diagrams[]` (Mermaid per the §11 v2 amend) + `full_detail`, with either
  no `items[]` (pure FYI) or items all of kind `fyi-objectable` (each
  individually objectable inside the 24h window). The B-track
  dossier-builder agent (e.g. `claude-tools-bvj`) emits this profile
  unchanged — no new schema, no new code path.
- **Tier = the existing `timed-fyi` 24h tier (auto-proceeds on silence).**
  Flow F dossiers ride the §0.B / D5 tier as-is: global 24h default,
  reversible, **auto-proceeds if Brian doesn't object** within the window.
  No special handling — silence is a valid input (cross-cutting principle 6)
  here exactly as it is for ordinary Flow B `timed-fyi` items. Notification
  stays one-per-dossier per principle 2. (Track **P2**, e.g.
  `claude-tools-0wy`, integrates Flow F dossiers with the existing tier
  mechanism without modifying it.)

So the full chain: **bd task closes (P1 observer) → daemon enqueues an
overview-profile dossier-build (B-track) → dossier lands on Brian's phone
as `timed-fyi` (P2) → 24h silence auto-proceeds.** Brian gets architectural
visibility "without going to ask" (§0.A); the pipeline does not deadlock if
he doesn't read it.

Three notification tiers, used everywhere:

| Tier | Behavior on silence | Notify |
|---|---|---|
| `blocking` | hard-blocks until answered | ping now |
| `timed-fyi` | auto-proceeds after window (global default 24h; builder may shorten); reversible | next digest |
| `digest` | proceeds; informational only | daily roll-up |

---

### Flow G — Failure visibility (local + remote)

All the data already exists in the runner (classification, `incidents.log`,
per-bead `Runner:` notes, preserved stream-json, ps/lsof snapshots). The gap is
UX: local-only, scattered, and the richest artifact is deliberately un-syncable
(stream-json contains raw file contents and model output; the script
self-gitignores it on purpose). So this flow is **progressive disclosure across
a security boundary**.

```
1. GLANCE   Board card: ⚠ badge + plain-English class + retry state
            Status strip: "⚠ 2 failing · 1 silent"
                │  synced metadata — always available remote
                ▼
2. SUMMARY  tap card → failure summary:
            • what happened, in human words
              ("WATCHDOG_KILL" → "Stuck 10m with no output, killed")
            • when · which attempt · what the runner did next
              (retried / spawned analysis task / stopped runner)
            • the bead's Runner: note timeline, inline
                │  synced metadata — always available remote
                ▼
3. FORENSIC stream-json + proc/lsof snapshot
            LOCAL:  full access (on disk)
            REMOTE: explicit "fetch forensic log" action → pulled
                    on-demand over the authed app channel, REDACTED
                    (tool_use sequence + errors + last assistant turn;
                    file bodies stripped), never persisted server-side
```

**Architectural line that drives the UX:** failure *metadata* rides the beads
sync and is always visible everywhere; the forensic *stream* never does. Remote
failure viewing is two-tier by necessity. 90% of the time the tier-2
human-worded summary is enough.

**Failure → Inbox tier mapping** (this makes failures actionable, not just
visible):

| Classification | Tier | Why |
|---|---|---|
| `AUTH_FAILURE`, `BILLING_ERROR` | `blocking`, ping now | Runner is dead; only you can fix |
| Circuit-breaker trip (N consecutive) | `blocking`, ping now | Systemic; everything stalling |
| `CONTEXT_OVERFLOW`, `MAX_OUTPUT_TOKENS`, repeated `UNKNOWN` | `digest` | Self-heals via analysis task |
| `RATE_LIMIT` | none (Board strip only) | Routine; notifying would spam |
| `TOOL_ERROR` scan hits (subagent missing, MCP down, perm denied) | `timed-fyi` | Looks green but isn't — silent failures deserve *more* visibility than loud ones |

Sharpest insight: the runner already distinguishes "failed loudly" from
"succeeded but silently did the wrong thing." Loud failures self-heal via
analysis tasks; **silent ones just rot**, so the UX must surface them more
prominently, not less. A loud failure's analysis task is just a blocking child
bead — it already appears in the Board's WAITING lane and opens as a dossier.
No new surface; failure visibility is mostly re-rendering existing data through
the two existing surfaces, split across the sync boundary.

---

## 5. Cross-cutting principles

1. **The Inbox is the product.** One ranked, batched queue. Never ping twice
   for things that could be one digest.
2. **Every ask is a standalone dossier:** TL;DR → decision → expandable
   context. Notifications triage; they never carry content.
3. **Your "no" must be as cheap as your "yes."** Reject/edit is one tap, never
   a penalty path.
4. **Honest state everywhere** — desired vs. actual is always distinguished; no
   optimistic UI for control.
5. **Pre-declare consequences** so the common decision is deterministic and
   instantly trustworthy; interpreting-agents only for freeform.
6. **Silence is a valid input.** Reversible + timed-auto-proceed so an
   unanswered question never deadlocks the pipeline; specific gates opt into
   hard-block.
7. **Surface the silent failures loudest.** Loud failures self-heal; silent
   ones rot.

---

## 6. Decisions log

| # | Decision | Rationale |
|---|---|---|
| D1 | Response surface = **mobile-friendly web app**, hosting both Inbox and Board | Full control over inline edit/checkboxes/board; one surface for everything |
| D2 | Intake gate = **human-tapped entry-intent preset at capture**, extensible list | Evolved from "auto-classify by size": you declare what you want from the system; preset = entry stage + gate aggressiveness |
| D3 | Silence default = **tiered** (`blocking` holds, `timed-fyi` proceeds, `digest` informational) | Pipeline keeps flowing on low-stakes; never silently commits a real fork |
| D4 | Consequences = **pre-declared per option; reconciler agent only for freeform** | Checkbox responses are deterministic and instant; freeform keeps an escape hatch |
| D5 | `timed-fyi` window = **global 24h default; dossier-builder may shorten** | Simple default, time-sensitive items can tighten it |
| D6 | Remote forensic view = **redacted (tool seq + errors + last turn, file bodies stripped); on-demand pull, never persisted** | Enough for ~90% of triage; respects the stream-json sensitivity boundary |
| D7 | "Remote-control non-headless Claude" → **reframed to dossier-escalation** (attach-mode is a later secondary) | Avoids the GUI-remoting rabbit hole; reuses Flow B |

---

## 7. Deferred (UX requirement recorded; decision is design territory)

- **Coordinator reachability.** UX requirement: the web app must be reachable
  **off the local network and even while the laptop is asleep**. This rules out
  hosting the app on the Mac. The how (always-on relay the Mac pushes to, hosted
  coordinator, etc.) is a design/architecture decision, out of scope here.
- **Entry-intent preset catalog.** Start with the two named in Flow A; grow the
  list from real usage. Each new preset must reduce to (entry stage, gate
  aggressiveness) so the spine stays legible.
- **Attach-mode hand-off** (tmux/ssh take-over) — secondary to dossier
  escalation; revisit only if dossier-escalation proves insufficient.
