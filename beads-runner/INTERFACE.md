# Beads Runner — Cross-Tier Interface Contract

**Version: `v2` · Status: FROZEN (gated checkpoint claude-tools-65z — re-frozen 2026-05-17; v1 signed off by Brian 2026-05-16)**
Owner: Brian · Produced: 2026-05-16 · Sourced from: `DESIGN.md` v2 (architecture
decisions), `UX-DESIGN.md` (§0 requirement provenance), `BEHAVIORAL-CONTRACT.md`
(SCAR regression gate), `research/headless-stuck-signal.md` (AD3 basis).

**Pre-freeze amendment (2026-05-16, before any freeze/close):** §4.1/§4.1.1,
§5 (§5.1–§5.3), §7.4 re-synced to **DESIGN.md AD7** (the Dossier model — committed `71d08f5`,
*after* the v2 draft this contract was first written against) per the
SCHEMA-CORRECTION note on claude-tools-65z; §9.1/§4.2 corrected to **not**
over-bind the DESIGN-C4-deferred trust asymmetry. That resync happened
*before* the freeze gate (clean source-resync, never a re-freeze): the
anti-drift process working as intended — the authoritative source moved, the
keystone re-synced, *then* the gate. **This `v1` was FROZEN** (Brian
sign-off, 2026-05-16); any further change is the §11 BLOCKING-escalation
protocol (reopen claude-tools-65z, bump version, re-freeze).

**§11 amendment → `v2` (2026-05-17, Brian pre-authorized — NOT a silent edit).**
Trigger: dogfooding a live dossier on a phone exposed that §5.1
`diagrams[].content` was an unconstrained string, so the §0.A-core *diagrams*
tier was satisfiable by ASCII/prose and the Inbox dumped it into a `<pre>`
with **no diagram rendering at all** — the §0.A diagram requirement was
under-delivered in lockstep across contract/generator/renderer. Amendment:
§5.1 `diagrams[].content` is now constrained to **Mermaid** source (a text
diagram language — LLM-authorable, deterministically SVG-renderable,
git-friendly; format ratified by Brian 2026-05-17); DESIGN AD7 updated in
lockstep; the bound dossier schema version bumped `1 → 2`. **Coarse-bump
note (deliberate, per §0.5/§0.3 single-source design):** the §5
`dossier_schema_version`, the §4.1 Dossier-envelope `schema_version`, and the
§5.3 `cb_schema_version` all track ONE normative source (the §4 record-type
registry — "a future bump is one §0/§11 registry edit, never a drift"); the
amend therefore moves the whole Dossier artifact `1 → 2` in one edit. This is
the *designed* bump mechanism, not over-scope: a v1 consumer MUST reject a v2
Dossier (§0.3) — correct, because a v1 renderer cannot honor the new diagram
contract; generator + renderer are upgraded in the same lockstep. Brian
pre-authorized this amend+bump+re-freeze with "no back-and-forth" (the
Mermaid format was a settled decision; this is its execution). The genuine
human-on-phone proof that a real Mermaid diagram renders is epic
claude-tools-8bm's sole closing gate (I5), not this freeze. **This `v2` is
now FROZEN**; any further change repeats the §11 protocol.

> **This document is the single versioned source of truth for every cross-tier
> contract in the beads-runner overhaul (epic claude-tools-glk).** Every
> downstream task (T1a/T1b/T2/T3/T4/T5/T6a/T6b) BINDS to the section numbers
> here and MUST NOT unilaterally change them.
>
> **Immutability.** Once this task (claude-tools-65z) is closed under its gated
> checkpoint, `INTERFACE.md` is **frozen** at its current version (now `v2`,
> the Mermaid §5.1 amendment). A needed change is a **BLOCKING escalation**:
> reopen claude-tools-65z, amend, bump the document version and the affected
> `*_schema_version`, re-freeze, and only then may downstream proceed. **No
> local divergence is ever permitted.** Downstream tasks cite
> "`INTERFACE.md §N`" (current frozen version) in their OWNS/EXIT criteria.

---

## §0. Conventions

**§0.1 Normative keywords.** MUST / MUST NOT / SHALL / SHALL NOT are binding
contract terms. SHOULD is a strong default a tier may deviate from only with a
documented reason that does not change an observable cross-tier behavior.

**§0.2 Provider-agnostic rule (swappability guardrail; DESIGN §7).** This
contract is expressed in abstract capabilities. **No Cloudflare primitive
(Durable Object, D1, Pages, `setAlarm`, KV, R2) appears in any normative
clause.** The Cloudflare realization is non-normative — see Appendix A. A tier
that leaks a provider primitive into a cross-tier signature violates this
contract.

**§0.3 Versioning.** The document carries one version (`v2`; `v1`→`v2` was the
§11 Mermaid §5.1 amendment — see the header record). Every persisted store
record and the dossier carry an integer `schema_version` (or
`*_schema_version`). Consumers bind to a schema version; they MUST reject an
unknown higher version rather than best-effort-parse it. Bumping any
`schema_version` requires the §0 freeze/escalation protocol. The Dossier
artifact's bound version is now `2` (§4.1/§5.1/§5.3 all track the one §4
registry source — see §5.1 and the header coarse-bump note).

**§0.4 Identifiers & time.** `bead_ref`/`task_ref` = the beads issue id string
(e.g. `claude-tools-65z`). Idempotency is **two-layer (AD3.4):** the
**dossier-level double-trigger dedup key = `task_ref`** (one fork ⇒ one
dossier, §7.4); the **per-Item application idempotency key = the Item `id`**
(one item response ⇒ applied once, §4.1/§5/§7.4). All timestamps are RFC-3339
UTC strings (`...Z`). All durations are integer seconds.

**§0.5 Frozen constants.** Every numeric value in this contract lives once in
the table below as its single normative definition. A clause referencing a
constant names it and MUST NOT restate the literal as a competing normative
value; a parenthetical gloss of the value for readability (e.g. "`LEASE_TTL`
(`900` s)") is permitted. Changing a constant is a §0 escalation.

| Constant | Value | Governs | Source |
|---|---|---|---|
| `CONTROL_POLL_INTERVAL` | `60` s | desired-state poll *during* a task; stop honored ≤ this | S-5, BC-33 |
| `HEARTBEAT_INTERVAL` | `60` s | actual-state+liveness heartbeat cadence; lease renew | DESIGN §7 |
| `RECLAIM_POLL_INTERVAL` | `60` s | Local Agent re-checks for new ready work after a clean drain | UX §0.A |
| `LEASE_TTL` | `900` s | lease lifetime; ≫ blip + poll (AD2.2) | AD2.2 |
| `STALE_AFTER` | `180` s | Board renders `stale (last seen…)` past this since `last_heartbeat_at` | S-1, C6 |
| `TIMED_FYI_DEFAULT` | `86400` s | default `timed-fyi` auto-proceed window; per-dossier override ∈ (0, 86400] | D5, §0.B |
| `FORENSIC_BLOB_TTL` | `3600` s | redacted forensic blob hard-delete deadline | AD4 |
| `USAGE_THRESHOLD` | `70` (%) | hard 5h/7d ceiling gate; `0` disables | BC-34 |
| `USAGE_CACHE_SECONDS` | `300` s | Local Agent usage-poll TTL cache | BC-34 |
| `SPARE_RAMP_PER_DAY` | `14.2` (%) | spare-cycles daily ramp of the 7d budget | UX §0.A, Flow C |
| `WORKER_STUCK_EXIT` | `7` | worker deliberate-stuck sentinel exit (≠ BC-21 0–4) | AD3.1, research Q4 |
| `PRINCIPAL_V1` | `"brian"` | the constant principal stamped on every control record | AD6, C7 |

---

## §1. Topology & the Local Agent ↔ Coordinator boundary

*(Satisfies: DESIGN §2, AD1; UX §0.A. Bound by: T3, T4.)*

Three tiers (DESIGN §2). The **Work plane** is beads/Dolt, unchanged
(eventual). The **Local Agent** (one per computer) is the machine-local
measurement & supervision authority (strong, machine-local). The
**Coordinator** (hosted) is the global serialization & decision authority
(strong). The **Board** is a read-only projection (§4.5).

**§1.1 Directionality (normative).**

- **UP — Local Agent → Coordinator (the only things that flow up):**
  1. **Capacity report** — the result of the machine-local usage poll, as a
     coarse cost-class verdict (§6.3). The Coordinator never reads a Keychain
     or an Anthropic usage API; it aggregates what Local Agents report.
  2. **Terminal-reason report** — the BC-21 class **or** `STUCK_NEEDS_HUMAN`,
     observed by the Local Agent from the *runner process exit code* before the
     process is gone (§8). This is the re-home of BC-21: a control-plane
     **record**, not an unobservable OS exit status (S-7).
  3. **Actual-state + liveness heartbeat** (§4.2), **work-snapshot publish**
     (§4.5), and **lease acquire/renew/release requests** (§6).
- **DOWN — Coordinator → Local Agent / runner (the only things that flow
  down):**
  1. **Desired-state** (§4.2 `desired`) delivered on reconnect/poll. The
     Coordinator owns desired-state; the Local Agent never originates it.
  2. **Lease grants / renewals / expiry notifications** (§6).
- **NEVER crosses this boundary:** raw stream-json, file bodies, Keychain
  material, or any provider primitive. Forensic content crosses only via the
  §10 redacted-blob path, runner→Coordinator, redacted *before* transit.

**§1.2 Empty-queue is not project death (UX §0.A — claude-tools-giu).**
The runner *process* now idles in place on a drained `bd ready`: it reports
`actual=idle` and re-polls `bd ready` every `IDLE_POLL_INTERVAL` /
`RECLAIM_POLL_INTERVAL` seconds, picking up new ready work **without** an
external respawn. Inside the idle wait the runner still honors `.stop-beads`
and Coordinator `desired=stopped` (both end the runner cleanly within one
poll interval); `desired=paused` is folded into the regular `st_reconcile`
hold path. This collapses the v1 design that satisfied UX §0.A by exiting
on drain and relying on the Local Agent to relaunch (each cycle paid the
claude+lib startup cost, was perceptible churn, and broke whenever the
relaunch path drifted). The BC-21 exit-code table (drain ⇒ 0) is preserved
as a testable SCAR via `RUNNER_EXIT_ON_DRAIN=1` — the conformance harness
sets this so the exit-code contract is still exercised; any external
supervisor that depended on exit 0 ≡ drained can opt in the same way.

---

## §2. Control-plane capabilities (the four) & connection model

*(Satisfies: DESIGN §7, AD1, AD6; S-5, S-6, BC-33. Bound by: T2, T3, T4, T5.)*

The Coordinator MUST expose exactly these four capabilities; nothing else in
this contract assumes any other coordinator primitive.

**§2.1 — Small strongly-consistent store.** Holds the §4 records
(**Dossier{body, items[]}** per AD7, RunnerState, Notification, Lease,
work-snapshot). Strong consistency is required for Lease and for each
Dossier **Item's** application (single-writer-per-Item semantics underpin §6
exclusivity and the §7.4 per-Item idempotency latch).

**§2.2 — Durable one-shot timer.** `fire(dossier_id) at T`. Used for the
`timed-fyi` auto-proceed window. **S-6 backstop (normative):** the timer is
best-effort; a missed fire MUST degrade to *fire-on-next-poll*. The **per-Item**
idempotency latch (§4.1/§7.4) makes alarm-fire and poll-fallback apply each
auto-proceeding item's consequence **exactly once**. A `timed-fyi` dossier MUST
NOT be able to stall forever; non-auto-proceeding items simply stay open without
blocking siblings or the pipeline (AD7 partial resolution).

**§2.3 — Authed request endpoint with one `authenticate(request) → principal`
chokepoint.** Every inbound control-plane request passes through exactly one
authentication step that resolves a `principal` (§9). No second auth path, no
UI-vs-agent split (C4 seam).

**§2.4 — Deliver-desired-state-on-reconnect.** On any runner/Local-Agent poll
or reconnect, the Coordinator returns the current `RunnerState.desired` and any
lease state for that runner. This is reconciliation (desired-state mutation),
**not** a durable command queue.

**§2.5 Connection / cadence model (S-5; BC-33).**
- *Between tasks:* the runner polls for new work (event-driven on task
  completion; idle reclaim per §1.2).
- *During a task:* the runner additionally polls desired-state every
  `CONTROL_POLL_INTERVAL`. A stop request MUST be **detected ≤
  `CONTROL_POLL_INTERVAL`** so the Board honestly renders `stopping…`
  immediately (Flow D / §4.2 `actual`). "Stop *after* current task" remains the
  completion semantic — a stop does not kill mid-task work (BC-33's other
  half) — but it must be *observed* within the interval, not at end-of-task.

---

## §3. The runner's six jobs

*(Satisfies: DESIGN §7. Bound by: T2 (caller), T3/T4 (callees).)*

Each job is a call from the runner against the §2 capabilities (via the Local
Agent where the job is machine-local). Per loop / per the §2.5 cadences:

| # | Job | Direction | Contract |
|---|---|---|---|
| 1 | **claim-lease** | up→down | Acquire an exclusive lease on the candidate `task_ref` (§6) **before** `bd update --status=in_progress` (AD2.1). No lease ⇒ do not run it. |
| 2 | **ask-capacity** | up→down | "May I start a task of cost-class C?" (§6.3). Coarse verdict. Failure posture per §6.2 (fail-OPEN). |
| 3 | **heartbeat-actual-state(+liveness)** | up | Every `HEARTBEAT_INTERVAL`, write `RunnerState.actual` + `last_heartbeat_at` (§4.2). Renews held leases. |
| 4 | **reconcile-desired-state** | down | Read `RunnerState.desired` (§2.4) at §2.5 cadence; act on `paused/stopped/spare-cycles`. |
| 5 | **publish-work-snapshot** | up | Publish the read-only projection (§4.5). Dolt remains work-truth — this is a projection, not a second source. |
| 6 | **report-terminal-reason** | up | A **last durable write** of the BC-21 class **or** `STUCK_NEEDS_HUMAN` *before* the runner process exits, via the Local Agent which observes the process exit code (§8; S-7). |

A tier MUST NOT add a seventh cross-tier job without a §0 escalation.

---

## §4. Store schemas

*(Satisfies: task OWNS bullet 1; DESIGN §7, AD7, C2/C3/C4/C6 seams, AD2.1, S-1.
Bound by: T4 (owns the store), T2/T3 (writers), T5 (Dossier/Notification),
T6a/T6b (readers, projection only).)*

Notation is a **schema** (field · type · semantics), not source code. Unknown
higher `schema_version` ⇒ reject (§0.3). Every record carries
`principal: PRINCIPAL_V1` (§9).

### §4.1 Dossier  (`schema_version: 2`) — AD7

**The Inbox unit is a Dossier, not "a Decision" (AD7).** A depth-tiered `body`
⊃ N **independently-respondable** `items[]`. Partial/iterative resolution is
first-class: a dossier may be left partly answered (approve 6, edit 3, feedback
2, return later) **without blocking unanswered items or the pipeline**. The
`body`/`items[]` *shape* is defined in §5 (carries `dossier_schema_version`);
this is the stored envelope.

| Field | Type | Semantics |
|---|---|---|
| `id` | string | Dossier id. |
| `schema_version` | int | `2`. (v2: §11 Mermaid amendment; bumped in lockstep with `dossier_schema_version`/`cb_schema_version` — one §4 registry source, §0.5/§0.3.) |
| `principal` | string | `PRINCIPAL_V1`. |
| `kind` | enum **(open, C2 seam)** | Interaction mode: `"decide"` implemented v1; `"pair"` **implemented (N3, claude-tools-uxg6)** — a scheduled collaborative-stage *session* (DESIGN N §4 / `design/notifications.md`), armed on the §2.2 timer with a SURFACE fire-action (not auto-proceed). Realizing the reserved open-enum value is **not** a §11 amendment (the C2 seam was left open for exactly this; no `schema_version` bump). Open discriminator (not a closed shape). Distinct from per-Item `kind` (§5). |
| `trigger` | enum | `human_flag` \| `worker_stuck` \| `stage_gate` \| `proactive_checkpoint` (Flow B/F triggers). |
| `bead_ref` | string | The anchor bead whose lifecycle this dossier belongs to (the forked bead for `worker_stuck`; the stage/epic bead for a review/overview). |
| `tier` | enum | `blocking` \| `timed-fyi` \| `digest` (§0.B; Flow F). Drives the **single** Notification (C3) and whether a §2.2 timer is set. |
| `created_at` | ts | — |
| `timer_fire_at` | ts \| null | For `timed-fyi`: `created_at + window` (window default `TIMED_FYI_DEFAULT`, per-dossier override ∈ (0, `TIMED_FYI_DEFAULT`]). The §2.2 `fire(dossier_id)` target. `null` when no auto-proceed window. |
| `scheduled_at` | ts | **`kind:"pair"` only (N3, claude-tools-uxg6).** The appointment time of the ready-to-pair session. The §2.2 `fire(dossier_id)` target `pair-arm` arms (the pair analogue of `timer_fire_at`); the fire-action **SURFACES** the session (fires the blocking `ready_to_pair` notification — N2 delivers) rather than auto-proceeding. A field on the open `kind:"pair"` shape (C2 seam); **absent on `kind:"decide"`** — no `schema_version` bump (DESIGN N §4.2/§4.3). |
| `body` | object | The §5 progressive-disclosure body (`tldr` · `sections[]` · `diagrams[]` · `full_detail` — **all mandatory**, AD7). |
| `items[]` | `Item[]` | The §5 Items. **Each carries its own `state`, `response`, and `consequence_applied` latch** — application + idempotency are **per-Item** (AD1/AD3.4 DO-per-Item). |
| `state` | **derived** | Rollup only, **informational, never a pipeline gate**: `open` while ≥1 item is non-terminal; `resolved` when every item is terminal (`applied`/`expired`). Unanswered items never block siblings or the pipeline (AD7). |

### §4.1.1 Item (per-Item state — defined in §5, stored within `items[]`)

Each Item independently carries: `state ∈ { open → answered → applied | open →
expired }`; `response | null`; **`consequence_applied: bool`** — the **per-Item
idempotency latch** (AD3.4 DO-per-Item; §7.4 / S-6), single-writer-set, flips
false→true exactly once; `applied_at: ts | null`. One item's resolution applies
**that item's** `consequence_block` and no other (partial application clean by
construction — AD1 per-Item DO).

### §4.2 RunnerState  (`schema_version: 1`)

| Field | Type | Semantics |
|---|---|---|
| `project_ref` | string | The controllable unit (Flow D). |
| `schema_version` | int | `1`. |
| `principal` | string | `PRINCIPAL_V1`. |
| `desired` | enum | `running` \| `paused` \| `spare-cycles` \| `stopped`. **Coordinator-owned** (§1.1). |
| `actual` | enum | `starting` \| `running` \| `idle` \| `stopping` \| `stopped` \| `crashed`. **Runner-reported.** `desired ≠ actual` is legal and rendered honestly (principle 4). |
| `last_heartbeat_at` | ts | **The S-1 liveness datum** (C6: liveness is *data*, in v1). |
| `liveness` | derived | `live` if `now − last_heartbeat_at ≤ STALE_AFTER`, else `stale`. The Board renders `stale (last seen Nh ago)` distinctly from `actual: running` (§4.5, T6a). Derived at read time; not stored. |
| `current_task_ref` | string \| null | — |
| `last_desired_actor` | string | The actor of the last `desired` change. **C4 seam, captured-not-enforced:** v1 records the actor and authorizes **every** actor **equally** through the one §9 chokepoint (DESIGN C4: "v1 MUST capture actor, authorize all equally"). The downgrade-only-for-agents / promote-only-for-human **asymmetry is DESIGN-C4-DEFERRED (§0.C)** and **MUST NOT** be enforced in v1 — later = one `if` at the chokepoint, no schema change. |
| `updated_at` | ts | — |

### §4.3 Notification  (`schema_version: 1`)

| Field | Type | Semantics |
|---|---|---|
| `id` | string | — |
| `schema_version` | int | `1`. |
| `principal` | string | `PRINCIPAL_V1`. |
| `dossier_ref` | string | The Dossier it announces. **One Notification per Dossier** (C3; AD7 — terse notification, the dossier *body* carries the content, principle 2). Not one-per-Item. |
| `tier` | enum | `blocking` \| `timed-fyi` \| `digest`. |
| `created_at` | ts | **Creation ≠ dispatch** (C3 seam): a row exists before any send. |
| `dispatched` | bool | Set true on send. Fire-and-forget is forbidden. |
| `dispatched_at` | ts \| null | — |
| `channel` | string \| null | Opaque transport tag. Later read-side digest rollup needs **no schema change** (C3). |

### §4.4 Lease  (`schema_version: 1`)

| Field | Type | Semantics |
|---|---|---|
| `task_ref` | string | The bead under exclusive lease. |
| `schema_version` | int | `1`. |
| `principal` | string | `PRINCIPAL_V1`. |
| `owner` | string | `runner_id` holding it. |
| `acquired_at` | ts | — |
| `ttl_seconds` | int | `LEASE_TTL`. |
| `expires_at` | ts | `renewed_at + ttl_seconds`. |
| `renewed_at` | ts | Bumped by job 3 every `HEARTBEAT_INTERVAL`. |
| `generation` | int | Monotonic fencing token. A renew/release with a stale `generation` is rejected — this closes the BC-04 *two-runners-one-orphan* race the bash script left **residual** (BEHAVIORAL-CONTRACT §18). |

### §4.5 work-snapshot  (`schema_version: 1`) — read-only projection

A projection joining Work plane (beads) + Coordinator state. **No write path
from any reader** (T6a/T6b are presentation-only). Dolt stays work-truth (no
plane-split). Per-project, it carries: the `RunnerState` (`desired` + `actual`
+ `liveness` derived); the capacity strip (`5h%`, `7d%`, `today_spare_line%`
vs `actual_7d%`, per-project mode — §6.3/Flow C); the lifecycle columns
(`idea│ux│design│impl│docs│tests│done`) keyed by each bead's `stage:` label
(C1 seam); the **WAITING-ON-YOU** lane = `Dossier`s with ≥1 still-open item for this
principal (a partly-answered dossier still shows until its last item resolves —
AD7);
per-bead failure metadata for Flow G tiers 1–2 (class + retry-state +
`Runner:` note timeline — synced metadata, always remote-available; the
forensic stream is **not** in the projection — §10). Each card: `title ·
stage · priority · runner state · age · the one thing it waits on`, plus a
per-card boolean **`verified`** (the §3 *done·code vs done·verified* sub-state;
uxg2).

**Lifecycle work-truth source on the GET path (claude-tools-7qf7).** The Work
plane is supplied as an inline `beads` arg when a publisher passes one (the
differential oracle + tests). The **production Board GET path passes none** (a
Worker cannot exec `bd`; the cf/pages-dev adapter sends an empty beads arg). So
when no inline beads are supplied, the CF read producer derives the lifecycle
work-truth from the already-published **§4.6 `workspace_inventory`** records
(`reconcile.js` `beadsFromWorkspaceInventory`) — a reprojection of
runner-published work-truth, never fabricated. `verified` rides through from the
§4.6 entries. (The bash oracle has no `workspace_inventory` store, so this
stored fallback is CF-side production infra with no bash twin; the projection
SHAPE stays parallel.)

### §4.6 *workspace_inventory* (`schema_version: 1`)

**v1 WRITE endpoint landed (claude-tools-8dfb, epic claude-tools-vvgy).** The
reservation promised "adding the *workspace_inventory* producer later is a
normal feature task, not a §0/§11 contract amendment"; this is that landing.
Per-workspace bead inventory: "what's done, what's ready, what's blocked in
this workspace." Producer: the workspace runner (it has `bd` and the working
copy — separate child of vvgy; not yet wired). Cadence target: every `300` s
(slower than `HEARTBEAT_INTERVAL` (`60` s), faster than ad-hoc). Transport: the
same Local-Agent outbox path as heartbeats, distinct `report` discriminator
(`"report":"workspace_inventory"` → hosted op `workspace-inventory-put` →
`reconcile.js` handler). Consumer: a future workspace-detail UI route + the
projection join (separate child of vvgy). **Explicitly NOT muxed into
`RunnerState` (§4.2)** — keeping inventory and heartbeat separate lets them
evolve on independent cadences and keeps the hot heartbeat read path lean.

Wire shape (v1, validated at the engine WRITE boundary; one row per workspace,
keyed by `project_ref`, overwritten on each write — this is a periodic
snapshot, not history):

```
{
  "report": "workspace_inventory",
  "schema_version": 1,
  "principal":  "<resolved principal>",   // §9.1: wire literal OVERWRITTEN at the chokepoint
  "runner_id":  "<runner id>",
  "project_ref":"<workspace bd prefix>",  // safeKey; the §4 record id
  "observed_at":"<RFC-3339 UTC ...Z>",    // §0.4; pre-2024 rejected (S-1 freshness)
  "counts":      { "open": int, "ready": int, "in_progress": int, "blocked": int },
  "in_progress_beads": [ { "bead_ref": str, "title": str, "stage": str, "verified"?: bool } ],
  "top_n_beads":       [ { "bead_ref": str, "title": str, "status": str, "stage": str, "verified"?: bool } ]
}
```

`counts` MUST contain all four integer keys (missing or non-int ⇒ reject).
`in_progress_beads` MAY be empty but is REQUIRED. `top_n_beads` MAY be empty
but is REQUIRED (no hard cap at the write boundary — bounding is the
producer's concern; full inventory is **not** the goal of this record — that
is a Work-plane query, not a control-plane projection).

**`verified` (optional, claude-tools-7qf7).** Each bead entry MAY carry a
boolean `verified` — the §3 / UX-DESIGN-V2 *done·code vs done·verified* source
signal. Producer reads it from the bead's `verified` **label** (the same
label-read as `stage:*`); the label is stamped when the production/contract
probe passes (web track: deploy + `verify-pages-deploy.sh mismatches=0`;
contract track: a live integration probe — the CLAUDE.md "Web/Pages
task-acceptance discipline"). **Strict boolean, default false** (absent /
non-bool ⇒ false — un-probed is *not* verified). This is **additive at v1 — no
`schema_version` bump** (same posture as the §4.5 projection card that added
`verified` in uxg2, and the §4.1 `kind:"pair"`/`scheduled_at` fields in uxg6:
an optional field a v1 consumer simply ignores is not a breaking change; only a
version bump is, §0.3). The hosted §4.5 GET-path lifecycle join reads it back
(`reconcile.js` `beadsFromWorkspaceInventory` → `workSnapshot`) so the Board's
`done` column can light up `done·verified` from live, runner-published
work-truth.

### §4.7 *task_progress* — RESERVED (no producer/consumer)

**Reservation only: name + intent claimed; no `schema_version`, no producer, no
consumer yet.** Reserving the name is not a schema change; bumping a version is
(§0.3). Future record type for per-workspace "what is the current task actually
doing right now." Producer target: the workspace runner, by parsing its own
stream-json output via the existing parser at
`run-beads-tasks.sh:1446-1525`. **Tap point:** the upstream `STREAM_FILE`
(`run-beads-tasks.sh:1417`) — the temp file written by `claude -p`, **before**
the bash parser's line-mangling. Tapping the `detached-*.log` instead drops
multi-line assistant message bodies (lesson from the spelunk report). Cadence
target: every `60` s while a task is in flight, written sibling to but
**independent from** the §4.2 heartbeat (same separation rationale as
*workspace_inventory* — heartbeat and progress evolve on independent cadences;
this is **not** a `RunnerState` mux). Consumer target: a future per-workspace
progress badge on the Board (§4.5) and the rich workspace-detail view. Shape:
TBD when the producer lands; should include `current_tool_name` (string, e.g.
`"Bash"` or `"Edit"`), `last_event_kind` (enum:
`assistant`|`tool_use`|`tool_result`|`system`|`result`), `last_event_at`
(RFC-3339 UTC `...Z`, §0.4), `api_retry_in_progress` (bool, with attempt count
from the parser's `RATE_LIMIT`/`SERVER_ERROR` markers in `SIGNAL_FILE`).
**Redaction discipline (§10 boundary).** Content snippets (tool inputs,
assistant text) MUST be summarized to safe presentation metadata at the
runner, **before write** — *task_progress* is the boundary where stream
content meets the hosted engine, and per §10.2 the engine MUST never see raw
user content. **Regex spec** for the runner-side line-prefix parser (from the
spelunk report): tag/timestamp extraction
`^\s*\[(\d\d:\d\d:\d\d)\]\s*(\[[a-z_:]+\])?`; tool name from
`"name": "([A-Za-z_]+)"` in `tool_use` payloads; API retry from
`API retry \((\d+)/(\d+)\): (\S+)`. This reservation makes "add the
*task_progress* producer later" a normal feature task, not a §0/§11 contract
amendment.

---

## §5. Dossier schema — body ⊃ items[] (AD7 — versioned, §0.A, NOT tradeable)

*(Satisfies: task OWNS bullet 2; DESIGN AD7 + §5 C5, AD3.1; UX §0.A
"strong human-interaction support / multi-step doc-gen / inline-edit +
approval-checkboxes / proactive understanding", Flow B/F, principle 3.
Bound by: T5 (sole producer), T6b (sole renderer). Consumers — applier, Inbox
UI, reconciler — bind to **this schema and its item-granularity**, never
"the passes." The number of generation passes is the tradeable §0.C
mechanism; **the schema and its item-granularity are §0.A and MUST NOT be
shrunk to a decision-singular shape** — that cannot express a 15-item mixed
review or a standalone design overview, the regression AD7 fixes.)*

`Dossier`, `dossier_schema_version: 2` = a depth-tiered **`body`** ⊃ N
independently-respondable **`items[]`**.

### §5.1 `body` — progressive disclosure, **all tiers mandatory** (AD7)

The generator MUST produce **every** tier; none is optional. This is the
"easy to skim *and* easy to get the full picture" §0.A requirement.

| Field | Type | Semantics |
|---|---|---|
| `dossier_schema_version` | int | `2`. (v2: §11 Mermaid amendment. The §4.1 Dossier-envelope `schema_version`, this `dossier_schema_version`, and §5.3 `cb_schema_version` all track the ONE §4 registry source — §0.5/§0.3 single-source; a bump moves the whole artifact `1 → 2` in one §11 edit.) |
| `tldr` | string | One sentence + what is being asked, overall. The skim entry point (notification body draws from this; the notification stays terse — content lives here, principle 2). |
| `sections[]` | array | `{ heading: string, prose: string }` — skimmable headers with enough text under each to convey the point without the full detail. |
| `diagrams[]` | array | `{ caption: string, content: string }`. **`content` MUST be valid Mermaid diagram source** (v2 §11 amendment; format ratified 2026-05-17). Mermaid is a text diagram language — LLM-authorable, deterministically renderable to SVG, git-friendly. `content` MUST begin with a Mermaid diagram-type header (optionally preceded by a `---`…`---` frontmatter block and/or a `%%{init:…}%%` directive): `graph`/`flowchart`, `sequenceDiagram`, `classDiagram`, `stateDiagram`/`stateDiagram-v2`, `erDiagram`, `journey`, `gantt`, `pie`, `mindmap`, `timeline`, `gitGraph`, `quadrantChart`, `requirementDiagram`, `C4Context`/`C4Container`/`C4Component`, `sankey-beta`, `xychart-beta`, `block-beta`. Free prose or ASCII art is a **contract violation**, not a wording nit — exactly as a contextless `context_anchor` is (§5.2): the generator MUST reject it, never best-effort-pass it. The renderer (T6b/Inbox) MUST render it as an actual diagram (SVG), **never** as source text in a `<pre>`. `diagrams[]` MUST be present (≥1 entry) when the matter is structural; the array is `[]` ONLY when genuinely non-structural. |
| `full_detail` | string | Stand-alone prose: enough that when skimming the headers + glancing at diagrams is insufficient, this alone conveys the full picture. **Not optional.** |

### §5.2 `items[]` — N independently-respondable Items (AD7)

Each Item is resolved **on its own**; resolving one neither blocks nor depends
on another (partial/iterative resolution — AD7; "your no as cheap as your
yes" — principle 3: approve-the-good / feedback-the-rest in one pass).

| Field | Type | Semantics |
|---|---|---|
| `id` | string | Per-Item idempotency key (§0.4; AD3.4 DO-per-Item). |
| `kind` | enum | `approve-reject` \| `pick-option` \| `approve-recommendation` \| `freeform-edit` \| `fyi-objectable`. **The Item's `kind` IS its response affordance** — "the doc IS the form" (Flow B step 4); T6b renders the control from `kind`. |
| `framing` | object | The per-item ask + why, self-contained. |
| `context_anchor` | object | **MANDATORY — self-contained-context invariant (AD7).** `{ where: string (where this sits in the lifecycle/design), link?: string, expansion: string }`. An item whose ask is not understandable without external context (e.g. *"reached the auth boundary, pick one"*) is a **contract violation**, not a wording nit. T5 MUST emit it; T6b MUST render it inline. |
| `options` | `Option[]` \| absent | For `pick-option`: `{ option_id, label, blast_radius (what it unblocks/forecloses), consequence_block }`. |
| `recommendation` | object \| absent | For `pick-option`/`approve-recommendation`: `{ value, why }`; editable inline (T6b). |
| `consequence_block` | `ConsequenceBlock` | Pre-declared, machine-applyable (§5.3). For `pick-option` the chosen option's block is used. |
| `reversible` | string | What this item's choice forecloses / how reversible. |
| `state` | enum | `open` → `answered` → `applied`; or `open` → `expired` (auto-proceed). **Per-Item.** |
| `response` | object \| null | `{ decision: "approve"\|"reject"\|"pick"\|"edit"\|"freeform"\|"object", selected_option_id?, edited_value?, freeform_text?, responded_at, principal }`. |
| `consequence_applied` | bool | **Per-Item idempotency latch** (§4.1.1 / §7.4 / S-6). |
| `applied_at` | ts \| null | — |

**§5.2.1 Profiles (AD7 — emergent from body+item-mix; all first-class).**
A *decision dossier* = deep-enough body + decision item(s) (e.g. a
`worker_stuck` fork = one `pick-option`). A *UX/design review* = body + many
mixed items (the 15-question scenario: `approve-reject` per flow +
`pick-option`/`approve-recommendation` per question + `freeform-edit`). The
proactive **Flow F "understand how it fits" overview = a deep `body` + zero or
all-`fyi-objectable` items** — a **first-class profile, core, not a tier
variant** (UX §0.A "trigger proactively to give him an understanding"). No
schema branch per profile — same `body`⊃`items[]`, different population.

**§5.2.2 Deterministic vs reconciler is PER-ITEM (Flow B step 5).** A
pure `approve-reject` / `pick-option` / `approve-recommendation` (un-edited)
response ⇒ **deterministically apply that item's `consequence_block`**,
idempotently (§7.4). A `freeform-edit` / edited / `object` response ⇒ a
reconciler interprets **that item** vs. its options and MAY emit a follow-up
dossier — scoped to the item, never re-opening resolved siblings.
`fyi-objectable` items auto-proceed on the §2.2 timer unless objected
(idempotent per-Item, S-6); non-auto-proceeding items left open never block
siblings or the pipeline (AD7).

### §5.3 ConsequenceBlock  (`cb_schema_version: 2`) — per-Item, machine-applyable

Pre-declared per Item/option (§0.B / principle 5) so the common path is
**deterministic and instantly trustworthy**; applied idempotently per-Item by
T5 (§7.4):

| Field | Type | Semantics |
|---|---|---|
| `cb_schema_version` | int | `2`. (v2: bumped in lockstep — the ConsequenceBlock shape is unchanged, but the whole Dossier artifact tracks one §4 registry source; §0.5/§0.3 single-source coarse bump, see the header note.) |
| `creates` | array | `{ title, type, priority, labels[], description, deps[] }` — new beads. |
| `unblocks` | string[] | `bead_ref`s to unblock. |
| `labels` | array | `{ bead_ref, add[], remove[] }`. |
| `status_changes` | array | `{ bead_ref, to_status }`. |

Application is **per-Item**: resolving item *X* applies only *X*'s block and
flips only *X*'s `consequence_applied` latch (AD1 DO-per-Item ⇒ partial
application clean by construction).

---

## §6. Lease ↔ beads-status binding · unreachable posture · coarse capacity

*(Satisfies: task OWNS bullet 4; AD2, AD2.1, AD2.2, AD2.3; BC-04, BC-09,
BC-15, BC-35, BC-34. Bound by: T4 (arbitration), T3 (local fallback +
measurement), T2 (consumes the verdict).)*

**§6.1 Lease ↔ beads-status binding & precedence (AD2.1).**
- The lease is acquired **before** `bd update --status=in_progress`. Lease
  release or expiry maps the bead back to `--status=open` (binds the strong
  plane onto the eventual-plane SCAR transitions BC-15 / BC-09 / BC-35).
- **Precedence on disagreement:** the **lease is authoritative for
  exclusivity** (who may run it); **beads status is authoritative for work
  truth** (done / blocked / open). Neither store alone answers both. A
  rewrite MUST consult the lease on *every* pickup — this is what actually
  closes BC-04 (the bash startup-snapshot never did; BEHAVIORAL-CONTRACT
  §18). Orphan recovery = an **expired lease** (replaces the BC-02/03/04
  startup-`in_progress`-snapshot mechanism; the *intent* survives, the bash
  mechanism does not — SCAFFOLDING).

**§6.2 Unreachable posture — split by plane (AD2.2).** Highest blast radius;
frozen here, not left to implementation.
- **Capacity check fails OPEN.** Coordinator-unreachable ⇒ proceed (a
  one-task overshoot is noise; BC-34 intent preserved at the Local Agent).
- **Lease fails DEGRADED-CLOSED with a bounded local fallback.** On
  Coordinator-unreachable a runner MAY continue **only** a task whose lease
  it *already holds and is still valid* (`now < expires_at`); the Local Agent
  enforces this from the locally-cached lease. It MUST NOT claim a *new* task
  without a fresh lease. `LEASE_TTL` (`900` s) ≫ `CONTROL_POLL_INTERVAL` +
  expected blip, so a brief outage does not strand in-flight work yet a
  crashed runner's lease still expires for orphan recovery. This preserves
  BC-34 (in-flight work survives a blip) without reintroducing BC-04 (no new
  unsynchronized claims).

**§6.3 Coarse capacity (AD2.3).** `ask-capacity` takes a deliberately coarse
`cost_class ∈ { standard, low_priority }` (mapped from bead priority;
`low_priority` = backfill-only). Verdict ∈ `{ ok, over }`.
- `standard` is gated **only** by the hard ceiling: the 5h **or** 7d window's
  integer-truncated utilization ≥ `USAGE_THRESHOLD` ⇒ `over` (BC-34 verbatim,
  measured by the Local Agent; `USAGE_THRESHOLD = 0` disables; result TTL-
  cached `USAGE_CACHE_SECONDS`).
- `low_priority` additionally gated by the spare-cycles line: day *N* of the
  7d window allows ≤ *N* × `SPARE_RAMP_PER_DAY` of the 7d budget; low-priority
  work backfills unused capacity and **never** starves the weekly cap.
- **Rationale (honest, AD2.3):** coarseness is justified **not** by "tasks are
  small" (BC-13/22 show tasks run long) but because the 14.2%/day line is a
  *soft ramp*; the hard 5h/7d ceiling (BC-34) is the real guard.

---

## §7. STUCK_NEEDS_HUMAN contract

*(Satisfies: task OWNS bullet 5; AD3.1–3.5; BC-10, BC-11, BC-13, BC-14; UX
Flow B; research Q4/Q5. Bound by: T2 (worker prompt + backstop + classifier),
T5 (Dossier DO — per-Item routing/dedup), T1a/T1b (assertions).)*

**§7.1 Frozen classification precedence (extends BC-10).** The classifier
scans accumulated signal markers and returns the **first match** in this
**frozen order** (BC-10's order, with `STUCK_NEEDS_HUMAN` inserted):

```
AUTH_FAILURE → BILLING_ERROR → STUCK_NEEDS_HUMAN → CONTEXT_OVERFLOW →
MAX_OUTPUT_TOKENS → SERVER_ERROR → WATCHDOG_KILL → RATE_LIMIT →
UNKNOWN_FAILURE   ;  then (exit-0, no marker, bead not closed) → TASK_NOT_CLOSED
```

`STUCK_NEEDS_HUMAN` slots **immediately below the two fleet-fatal classes**
(`AUTH_FAILURE`, `BILLING_ERROR` — "runner is dead, only you can fix";
fleet-wide, so they win) and **above every per-task content class and above
`TASK_NOT_CLOSED`** (AD3.2 mandates "high … above `TASK_NOT_CLOSED`"; a
genuine human-decision request MUST NOT be masked by a per-task content
failure or by the exit-0 "agent forgot to close" path the research shows it
otherwise becomes). The order **is** the logic (BC-10); reordering is a §0
escalation.

**§7.2 Detection — two independent triggers (AD3.1, AD3.3; research Q4).**
- **Primary (worker-driven, instructed — AD3.1):** on a fork it must not
  resolve the worker MUST, in order: `bd update <id> --status=blocked` →
  write the structured ask (TL;DR · ask · options · recommendation+why ·
  reversible) into the bead (`--design` / `--append-notes`) →
  `bd label add <id> human` → exit `WORKER_STUCK_EXIT`. The structured ask is
  the raw material the §5 dossier builder consumes. **The human-needed signal
  is the `human` LABEL, not `bd human <id>`** — `human` is a command GROUP and
  `bd human <id>` silently no-ops in this bd build (the §7.2 PRIMARY detector /
  `bd human list` key on the label). Owner decision, commit 9377103 "I5
  rehearsal" D4 (a real prompt-vs-CLI divergence the live run surfaced).
- **Backstop (runner-side, zero model trust — AD3.3):** the runner scans the
  final `result.permission_denials[]` for `AskUserQuestion` / `ExitPlanMode`,
  **and** scans the stream for the `"Entered plan mode."` tool_result (the
  EnterPlanMode silent-no-op residual gap; `--disallowedTools` is the
  *guardrail*, this scan is the *backstop* — defense in depth). Either ⇒
  `STUCK_NEEDS_HUMAN`, **overriding the false exit-0/`is_error:false`
  success.**

**§7.3 Backstop drives the bead (AD3.3).** When a backstop fires (worker
slipped past the prohibition) it MUST itself drive the bead to
blocked-for-human (status=blocked + the `human` label); otherwise the fork
rots (UX principle 7). The runner sets the label with `bd label add <id>
human` (the real signal — see §7.2) and also fires the legacy `bd human <id>`
form belt-and-suspenders (a harmless no-op in this bd build, kept as an
observable for any older watcher keying on that literal invocation). The
**Coordinator owns "blocked-for-human"** and reconciles `status=blocked` + the
`human` label back into beads (control→work; S-2) — the worker does **not**
write Dolt as the source of truth, so Dolt lag is invisible to the
human-latency path (the §1 promise; the Board never lies — S-2).

**§7.4 Idempotency — two layers (AD3.4).** AD3.4 mandates dedup at **both**
granularities; both are normative:
- **Dossier level (the STUCK double-trigger — preserved SCAR-intent AD3.1):**
  worker-self-signal **+** backstop on the **same fork** dedupe via a
  single-writer record **keyed on `task_ref`** ⇒ **one fork ⇒ one Dossier**
  (a `worker_stuck` dossier typically carries one `pick-option` item). Two
  triggers never make two dossiers.
- **Per-Item level (AD7 / AD1 DO-per-Item):** each Item's
  `consequence_applied` latch (§4.1.1) flips false→true **exactly once**,
  keyed on the **Item `id`** ⇒ **one item response ⇒ applied once**, robust
  to double-tap by the human or `timer-fire` racing `poll-fallback` (S-6 /
  §2.2). Partial application is clean by construction: resolving 6 of 15
  items applies exactly those 6 blocks, each once; the other 9 stay open and
  block nothing (AD7 partial resolution).

**§7.5 Breaker- and retry-exempt (AD3.2; BC-13/14).** `STUCK_NEEDS_HUMAN` is
**retry-exempt** (like `CONTEXT_OVERFLOW` vs BC-13 — no retry; it is not an
error to retry) and **circuit-breaker-exempt** (like `CONTEXT_OVERFLOW` vs
BC-14 — it MUST NOT advance the consecutive-failure breaker). Without this, N
legitimate human-decision tasks trip the BC-14 breaker and stop the fleet —
turning the normal path into an outage. It does **not** add a runner exit code
(§8): the runner blocks the bead and moves on (like a blocking analysis
child), runner process continues.

**§7.6 Guardrail (AD3.5).** Workers run with `--disallowedTools
AskUserQuestion EnterPlanMode ExitPlanMode` and keep `--output-format
stream-json` (`text` hides `permission_denials[]`; the backstop needs it).
The guardrail removes the interactive tools from the advertised set; the
instructed primary path (§7.2) is still required (a bare prohibition is
empirically insufficient — research Q5).

---

## §8. Terminal-reason / exit-code re-home

*(Satisfies: task OWNS bullet 3 (job 6) & bullet 6; BC-21; DESIGN §6, §7,
S-7. Bound by: T3 (observes exit code, reports), T2 (produces exit codes),
T1a (BC-21 assertion).)*

**§8.1 BC-21 runner exit-code table is preserved verbatim** as the
process-level contract a supervisor switches on:

| Exit | Condition |
|---|---|
| `0` | Normal end: `bd ready` empty (BC-05) **or** graceful stop consumed |
| `1` | `SIGINT`/`SIGTERM` (interrupt cleanup — BC-35) |
| `2` | Consecutive-failure circuit breaker tripped (BC-14) |
| `3` | `AUTH_FAILURE` (terminal) |
| `4` | `BILLING_ERROR` (terminal) |

`STUCK_NEEDS_HUMAN` adds **no** runner exit code (§7.5). `WORKER_STUCK_EXIT`
(`7`) is the *worker* (`claude -p`) sentinel, an internal detection input —
not the BC-21 runner contract; it is chosen to not collide with 0–4.

**§8.2 Re-home (S-7).** A heartbeat-absence channel structurally cannot
distinguish `AUTH=3` from `clean=0`. Therefore `report-terminal-reason`
(§3 job 6) is a **last durable control-plane write before the process exits**,
performed via the Local Agent which observes the actual process exit code
(BC-21 re-homed from an unobservable OS code to an observable record). The
record carries the BC-21 class **or** `STUCK_NEEDS_HUMAN`. "Exited because
AUTH(3)" becomes a control-plane fact, not lost process state.

---

## §9. Auth — `authenticate(request) → principal` & token storage

*(Satisfies: task OWNS bullet 8; AD6; C4/C7 seams. Bound by: T4 (chokepoint),
T3 (token storage), T6a/T6b (bearer the token).)*

**§9.1 Chokepoint.** Every control-plane request (UI or agent — **no split**,
C4) passes through exactly one `authenticate(request) → principal` step.
v1 resolves a **constant** `principal = PRINCIPAL_V1` after validating a
bearer token's presence/validity. Every §4 record is stamped with the
resolved principal; all downstream binds to the resolved principal, never a
hardcoded literal at the use site (C7: later = mint real tokens + stop
returning the constant; **no migration**, no schema change). **C4 seam
(captured, not enforced):** every `RunnerState.desired` change records its
actor (§4.2 `last_desired_actor`) and is authorized through this **one**
chokepoint with **all actors treated equally in v1** (DESIGN C4: "v1 MUST
capture actor, authorize all equally; MUST NOT split UI vs agent code
paths"). The downgrade-only-for-agents / promote-only-for-human asymmetry is
**DESIGN-C4-DEFERRED (§0.C)** and **MUST NOT** be baked into this frozen
contract — it is later = one `if` at this chokepoint, no schema or interface
change. (Corrected pre-freeze: an earlier draft over-bound this §0.C-deferred
behavior as v1-normative.)

**§9.2 Token lifecycle & storage location (not deferred — AD6).** v1 uses
long-lived static per-runner bearer secrets. Rotation/revocation is deferred;
the **storage location is NOT deferred**: the per-runner bearer token is
stored in the **same machine secure-store family as the BC-34 credential
path** — the macOS Keychain — under a **distinct** generic-password service
**`claude-beads-runner.coordinator-token`** with `account = runner_id`
(separate from Anthropic's `"Claude Code-credentials"` entry). The Local Agent
owns reading it (the same tier that owns the BC-34 Keychain path). No token
in env vars, source, beads, or any committable location.

---

## §10. Forensic boundary — concrete values

*(Satisfies: task OWNS bullet 7; AD4; BC-27; UX Flow G, D6. Bound by: T2/T3
(redaction at the runner), T4 (encrypted transient store + delete), T6b
(on-demand fetch UI), T1b (BC-27 assertion).)*

**Provenance (honest, AD4):** UX D6 ("never persisted server-side") was
**explicitly relaxed by Brian** in design ("fine for the box to touch
forensic content; don't over-index"). The numbers below are this contract's
job (AD4: "given a number in the interface contract, not left undefined").

**§10.1 BC-27 preserved verbatim.** The on-disk `.beads/runner-logs/`
self-gitignoring boundary (`*` + `!.gitignore`) is unchanged: raw stream-json /
ps / lsof / incidents.log **never enter a committable path**. The §10 redacted
blob is a **separate, transient, encrypted** object — it does **not** weaken
BC-27; it is the single controlled crossing of the sync boundary that Flow G
tier-3 describes.

**§10.2 Redaction AT the runner, BEFORE transit (Flow G tier-3).** The runner
(Local Agent tier) produces the redacted blob from the local stream-json;
**raw stream-json never leaves the machine.** The redacted blob contains
exactly: the `tool_use` sequence (tool names + inputs with file **paths**
kept, file **contents** removed), `tool_result` entries with `is_error:true`,
and the **last assistant turn** (final text). Every stripped body (file
contents, large `tool_result` bodies) is replaced by a placeholder carrying
`{ byte_length, sha256_prefix(12) }` so size is visible and content is not.

**§10.3 Coordinator-side handling — concrete contract.**
- **TTL:** the redacted blob is hard-deleted at the **earlier** of
  `created_at + FORENSIC_BLOB_TTL` (`3600` s) **or** an explicit user
  "dismiss / done with forensic" action.
- **Encryption:** stored encrypted at rest with a server-managed key
  (AES-256-equivalent); the storage layer holds **ciphertext only**; the key
  is never exposed to the Board/client; transport is the §2.3 authed channel.
- **Delete guarantee:** "delete" = irrecoverable destruction of the
  ciphertext object (not a tombstone / soft-delete). A deletion emits a
  control-plane **audit event** containing **no forensic content** (ids +
  timestamps only).
- **Fetch:** Flow G tier-3 is an explicit, authed, on-demand pull (§9). It is
  never auto-fetched, never in the §4.5 projection, never in a digest/notify
  body (notifications triage, never carry content — principle 2).

---

## §11. Downstream binding map & change protocol

*(Anti-drift: each task cites the INTERFACE.md sections it owns/binds, at the
current frozen version — now `v2`.)*

| Task | Binds / owns INTERFACE.md §§ |
|---|---|
| T1a (ooc) | §3, §7.1, §7.5, §8.1 — assertions cite these as literal close-criteria |
| T1b (crq) | §6.1/6.2, §7 (cross-tier), §8.2, §10.1 — observability/security/STUCK e2e |
| T2 (34h) | §2.5, §3 (caller), §7.1/7.2/7.5/7.6, §8.1 — runner state machine; stubs match §2–§6 signatures |
| T3 (3al) | §1.1 (up), §6.2 (local fallback), §6.3 (measurement), §8.2, §9.2, §10.2 — Local Agent |
| T4 (cbv) | §2.1–2.4, §4 (store owner), §6.1 (arbitration), §9.1, §10.3 — Coordinator |
| T5 (40c) | §2.2, §4.1/§4.1.1/§4.3, §5 (body+§5.2 items+§5.3 ConsequenceBlock; sole producer), §7.3/7.4 — **Dossier DO, per-Item** |
| T6a (p2m) | §4.2 (`liveness`), §4.5 (projection, read-only) — Board |
| T6b (xre) | §5 (sole renderer; §5.1 body tiers + §5.2 per-Item affordances + §5.2.1 profiles), §4.5, §10.3 (fetch UI) — Inbox + Flow G |
| vkc (8bm) | §5.1 `diagrams[].content` = Mermaid (the v2 amend); generator emits/validates it, Inbox renders it as SVG — bound to the re-frozen §5.1 + bumped dossier schema version |

**§11 amendment ledger.**

| Version | Date | Change | Authorization |
|---|---|---|---|
| `v1` | 2026-05-16 | Initial freeze (post AD7 pre-freeze resync). | Brian sign-off (gated checkpoint claude-tools-65z) |
| `v2` | 2026-05-17 | §5.1 `diagrams[].content` constrained to Mermaid; DESIGN AD7 lockstep; Dossier bound schema version `1 → 2` (coarse single-source bump per §0.5/§0.3). | Brian pre-authorized "no back-and-forth"; format ratified 2026-05-17 (claude-tools-65z reopened §11, re-frozen) |

**Change protocol (anti-drift, normative).** This document is **immutable
once claude-tools-65z is closed under its gated checkpoint**. Any tier that
finds the contract insufficient or contradictory MUST: (1) **stop** — not
diverge locally; (2) reopen claude-tools-65z; (3) amend the affected
section + bump the document version and the affected `*_schema_version`;
(4) re-run the §0 freeze (Brian sign-off, or a pre-authorized settled
decision executed and announced — the v2 Mermaid amend precedent);
(5) only then resume, citing the new version. A local divergence is a
contract violation, not a shortcut.

---

## Appendix A — Non-normative Cloudflare realization

Informational only; **not part of any contract** (§0.2). §2.1 store →
Durable Object state + D1; §2.2 timer → a DO `setAlarm()`, with the S-6
poll-fallback making the free-tier alarm's non-contractual reliability safe;
§4.1 Dossier → **one DO per dossier-Item** (AD1/AD7; single-threaded ⇒ §7.4
per-Item idempotency + partial application *by construction*); the §2.2 timer
→ a DO `setAlarm()` keyed `fire(dossier_id)`, dedup'd per-Item against the
S-6 poll-fallback; §2.3 chokepoint → a Worker middleware; §4.5 projection /
§10 transient blob → D1 / encrypted object store; web app → Pages. The
**SPOF of the singleton Coordinator DO is acknowledged** (AD1) and mitigated
by §6.2 (unreachable posture) + §2.2 (S-6 backstop), not waved away. A
provider swap changes only this appendix.

## Appendix B — Provenance & SCAR-consistency cross-reference

Each INTERFACE section names the DESIGN AD(s) and BEHAVIORAL-CONTRACT BC(s)
it satisfies in its own header (above). Consistency summary for the reviewer
(EXIT criterion 3): §6.1/§8.1 preserve BC-02/03/04/05/09/15/21/35 **intent**
while replacing the bash startup-snapshot **mechanism** (correctly: those are
SCAR-intent / SCAFFOLDING-mechanism per BEHAVIORAL-CONTRACT §2, §6, and the
§18 BC-04-residual sharpening — §6.1 *strengthens* BC-04, contradicting no
SCAR). §7.1 extends the BC-10 ordered-precedence SCAR exactly as BC-10/11's
own annotations anticipate ("now includes `STUCK_NEEDS_HUMAN`, AD3.2");
§7.5 matches BC-13/14's annotated retry/breaker exemption. §6.3 preserves
BC-34 fail-open + TTL-cache verbatim at the Local Agent. §10.1 preserves
BC-27 verbatim and adds an orthogonal transient path (AD4 relaxation of D6,
provenance recorded). No clause requires transcribing a SCAFFOLDING
mechanism; every SCAFFOLDING reference (bash snapshot, signal-file IPC,
sed-scrape, heredoc templating) is explicitly replaced, not ported.

**Pre-freeze resync (no SCAR impact).** §4.1/§5/§7.4 now realize the **AD7
Dossier model** (DESIGN `71d08f5`): body⊃items[], per-Item state +
per-Item idempotency latch, mandatory `context_anchor` self-contained-context
invariant, partial/iterative resolution, the Flow F overview profile. This
touches no BC (the dossier/decision layer is new surface, not characterized
in BEHAVIORAL-CONTRACT) and **preserves the AD3.1/AD3.4 STUCK SCAR-intent**:
"one fork ⇒ one dossier" survives as the §7.4 *dossier-level* double-trigger
dedup; the per-Item latch is the *added* AD3.4 second layer, not a
replacement. §9.1/§4.2 corrected to keep the C4 **seam** (actor captured,
single chokepoint) while **not** enforcing the C4-DEFERRED trust asymmetry in
v1 (DESIGN C4: "authorize all equally; later = one `if`") — removing an
earlier over-binding of a §0.C-deferred behavior into the frozen contract.

**v2 §11 Mermaid amend (no SCAR impact).** Constraining §5.1
`diagrams[].content` to Mermaid touches **no BC** — the dossier/diagram layer
is new surface, uncharacterized in BEHAVIORAL-CONTRACT (same standing as the
AD7 resync). It *strengthens* the §0.A "diagrams" requirement (a string that
could be ASCII prose now MUST be renderable Mermaid) without weakening any
SCAR. The coarse `1 → 2` artifact bump is the §0.5/§0.3 single-source design
working as intended ("a future bump is one §0/§11 registry edit"); §5.3's
ConsequenceBlock shape is byte-unchanged — only its version literal tracks the
one source. Reviewer EXIT-3 check for v2: confirm Mermaid is required (not
SHOULD), the reject-non-Mermaid mirrors the §5.2 contextless-anchor
contract-violation discipline, the renderer-as-SVG clause is normative, and
no §5.2/§5.3/§7.4 per-Item semantics changed.
