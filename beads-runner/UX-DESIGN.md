# Beads Runner — UX Design

Status: draft · Scope: user flows, not implementation/architecture
Owner: Brian · Last updated: 2026-05-15

This document maps the **user experience** of expanding the beads-runner from a
single-machine headless task loop into a system that runs your idea→test
pipeline autonomously and surfaces only the moments that genuinely need you.

It deliberately stops at the UX boundary. Where a UX requirement forces a
design/architecture decision, the requirement is recorded here and the decision
is flagged as deferred — not solved.

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

Each project is a controllable unit, state ∈
`{running, paused, spare-only, stopped}`, settable by **you** (Board toggle) or
**an agent in that workspace** (e.g. analysis agent: "blocked on a human
decision → pause this runner, save cycles").

Two UX requirements that are easy to get wrong:

- **Honest state.** The Board shows *actual* runner state, not desired. A
  toggle whose effect is graceful/polled must render `stopping…` → `stopped`,
  never optimistic.
- **The "remote-control a non-headless Claude" idea is reframed.** Driving a
  GUI remotely is a rabbit hole. The underlying need is "occasionally take over
  / intervene in a running task." Serve it with: **escalate this task to a
  decision dossier** (reuses Flow B entirely) as the primary path, and an
  attach-mode hand-off (tmux/ssh) as a secondary, later option.

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
