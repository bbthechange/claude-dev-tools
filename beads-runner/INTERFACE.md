# Beads Runner — Cross-Tier Interface Contract

**Version: `v1` · Status: DRAFT-PENDING-FREEZE (gated checkpoint — claude-tools-65z)**
Owner: Brian · Produced: 2026-05-16 · Sourced from: `DESIGN.md` v2 (architecture
decisions), `UX-DESIGN.md` (§0 requirement provenance), `BEHAVIORAL-CONTRACT.md`
(SCAR regression gate), `research/headless-stuck-signal.md` (AD3 basis).

> **This document is the single versioned source of truth for every cross-tier
> contract in the beads-runner overhaul (epic claude-tools-glk).** Every
> downstream task (T1a/T1b/T2/T3/T4/T5/T6a/T6b) BINDS to the section numbers
> here and MUST NOT unilaterally change them.
>
> **Immutability.** Once this task (claude-tools-65z) is closed under its gated
> checkpoint (Brian sign-off), `INTERFACE.md v1` is **frozen**. A needed change
> is a **BLOCKING escalation**: reopen claude-tools-65z, amend, bump the
> document version (`v2`) and the affected `*_schema_version`, re-freeze, and
> only then may downstream proceed. **No local divergence is ever permitted.**
> Downstream tasks cite "`INTERFACE.md v1 §N`" in their OWNS/EXIT criteria.

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

**§0.3 Versioning.** The document carries one version (`v1`). Every persisted
store record and the dossier carry an integer `schema_version` (or
`*_schema_version`). Consumers bind to a schema version; they MUST reject an
unknown higher version rather than best-effort-parse it. Bumping any
`schema_version` requires the §0 freeze/escalation protocol.

**§0.4 Identifiers & time.** `bead_ref`/`task_ref` = the beads issue id string
(e.g. `claude-tools-65z`) — it is also the Decision idempotency key (§7.4). All
timestamps are RFC-3339 UTC strings (`...Z`). All durations are integer seconds.

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
| `TIMED_FYI_DEFAULT` | `86400` s | default `timed-fyi` auto-proceed window; per-decision override ∈ (0, 86400] | D5, §0.B |
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

**§1.2 Empty-queue is not project death (reconciles BC-05 with UX §0.A).**
The runner *process* preserves BC-05/BC-21 verbatim: a drained `bd ready`
exits **0**. UX §0.A ("runner keeps running when out of tasks; picks tasks up
once added") is satisfied **at the Local Agent tier, not by changing the exit
contract**: on a clean exit-0 drain the Local Agent keeps the project eligible
and re-launches the runner when new ready work appears, polling every
`RECLAIM_POLL_INTERVAL`, **unless** `RunnerState.desired ∈ {paused, stopped}`.
The exit-0 supervisor signal (BC-21) is therefore preserved and the requirement
is met without contradiction. The relaunch mechanism is T3's; this clause fixes
only the *contract*: exit-0-on-drain ≠ stop the project.

---

## §2. Control-plane capabilities (the four) & connection model

*(Satisfies: DESIGN §7, AD1, AD6; S-5, S-6, BC-33. Bound by: T2, T3, T4, T5.)*

The Coordinator MUST expose exactly these four capabilities; nothing else in
this contract assumes any other coordinator primitive.

**§2.1 — Small strongly-consistent store.** Holds the §4 records (Decision,
RunnerState, Notification, Lease, work-snapshot). Strong consistency is required
for Lease and Decision (single-writer semantics underpin §6 exclusivity and
§7.4 idempotency).

**§2.2 — Durable one-shot timer.** `fire(decision_id) at T`. Used for the
`timed-fyi` auto-proceed window. **S-6 backstop (normative):** the timer is
best-effort; a missed fire MUST degrade to *fire-on-next-poll*. The §7.4
idempotency latch makes alarm-fire and poll-fallback apply the consequence
**exactly once**. A `timed-fyi` decision MUST NOT be able to stall forever.

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

*(Satisfies: task OWNS bullet 1; DESIGN §7, C2/C3/C4/C6 seams, AD2.1, S-1.
Bound by: T4 (owns the store), T2/T3 (writers), T5 (Decision/Notification),
T6a/T6b (readers, projection only).)*

Notation is a **schema** (field · type · semantics), not source code. Unknown
higher `schema_version` ⇒ reject (§0.3). Every record carries
`principal: PRINCIPAL_V1` (§9).

### §4.1 Decision  (`schema_version: 1`)

| Field | Type | Semantics |
|---|---|---|
| `id` | string | **= `bead_ref`** (the idempotency key — §7.4). One bead ⇒ one Decision. |
| `schema_version` | int | `1`. |
| `principal` | string | `PRINCIPAL_V1`. |
| `kind` | enum **(open)** | `"decide"` implemented v1. `"pair"` **reserved, not implemented** (C2 seam — the discriminator exists; the shape is open, not closed). |
| `trigger` | enum | `human_flag` \| `worker_stuck` \| `stage_gate` \| `proactive_checkpoint` (Flow B/F triggers). |
| `bead_ref` | string | The bead this decision blocks. |
| `tier` | enum | `blocking` \| `timed-fyi` \| `digest` (§0.B; Flow F). |
| `state` | enum | `open` → `answered` → `applied`; or `open` → `expired` (timed-fyi auto-proceed). |
| `created_at` | ts | — |
| `timer_fire_at` | ts \| null | For `timed-fyi`: `created_at + window` (window default `TIMED_FYI_DEFAULT`, per-decision override ∈ (0, `TIMED_FYI_DEFAULT`]). The §2.2 timer target. `null` for `blocking`. |
| `dossier` | object | The §5 dossier (carries its own `dossier_schema_version`). |
| `chosen_option_id` | string \| null | Set on answer; indexes into `dossier.framing.options[]`. |
| `response` | object \| null | `{ mode: "checkbox"\|"edit"\|"freeform", selected_option_id?, edited_recommendation?, freeform_text?, responded_at, principal }`. |
| `consequence_applied` | bool | **Idempotency latch** (§7.4 / S-6). Single-writer-set; flips false→true exactly once. |
| `applied_at` | ts \| null | — |

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
| `last_desired_actor` | string | The actor of the last `desired` change (C4 seam — actor captured, authorized uniformly via §9; agents may downgrade/pause own env, only Brian promotes to `running`/`full`). |
| `updated_at` | ts | — |

### §4.3 Notification  (`schema_version: 1`)

| Field | Type | Semantics |
|---|---|---|
| `id` | string | — |
| `schema_version` | int | `1`. |
| `principal` | string | `PRINCIPAL_V1`. |
| `decision_ref` | string | The Decision it announces. **One Notification per Decision** (C3). |
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
(C1 seam); the **WAITING-ON-YOU** lane = open `Decision`s for this principal;
per-bead failure metadata for Flow G tiers 1–2 (class + retry-state +
`Runner:` note timeline — synced metadata, always remote-available; the
forensic stream is **not** in the projection — §10). Each card: `title ·
stage · priority · runner state · age · the one thing it waits on`.

---

## §5. Dossier output schema (C5 — versioned)

*(Satisfies: task OWNS bullet 2; DESIGN C5, AD3.1; UX Flow B/F. Bound by: T5
(sole producer), T6b (sole renderer). Consumers bind to **this schema**, never
"the passes" — the 4-pass orchestration is SIMPLIFIED to one structured
generation; the producer is swappable behind this frozen shape.)*

`dossier` object, `dossier_schema_version: 1`:

| Field | Type | Semantics |
|---|---|---|
| `dossier_schema_version` | int | `1`. |
| `filtered_context` | object | `{ tldr: string (≤1 sentence + the ask), delta: string (only the *new* info after dedup vs goals/design docs), references: string[] }`. (Pass-1 intent: canon dedup.) |
| `framing` | object | `{ ask: string, options: Option[], recommendation: { option_id, why: string }, reversible: string }`. (Pass-2 intent.) |
| `framing.options[]` | `Option` | `{ option_id: string, label: string, blast_radius: string (what it unblocks/forecloses), consequence_block: ConsequenceBlock }`. |
| `readability` | object | `{ headings: Heading[], diagram?: string, acronyms_expanded: bool }` — skimmable headings → drill-down; acronyms expanded on first use. (Pass-3 intent.) |
| `response_affordances` | object | `{ per_option_approve: bool, recommendation_editable: bool, freeform_allowed: bool }` — **the doc IS the form** (Flow B step 4). T6b renders these as inline approve/reject + editable recommendation + freeform note. |

### §5.1 ConsequenceBlock  (`cb_schema_version: 1`) — machine-applyable

Pre-declared per option (§0.B / principle 5) so the pure-checkbox path is
**deterministic** (Flow B step 5; applied idempotently by T5 per §7.4):

| Field | Type | Semantics |
|---|---|---|
| `cb_schema_version` | int | `1`. |
| `creates` | array | `{ title, type, priority, labels[], description, deps[] }` — new beads. |
| `unblocks` | string[] | `bead_ref`s to unblock. |
| `labels` | array | `{ bead_ref, add[], remove[] }`. |
| `status_changes` | array | `{ bead_ref, to_status }`. |

Freeform/edited responses do **not** auto-apply a ConsequenceBlock: a
reconciler interprets them vs. the options and MAY emit a follow-up dossier
(Flow B step 5). Only the pre-declared block is the deterministic path.

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
T5 (Decision DO routing/dedup), T1a/T1b (assertions).)*

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
  reversible) into the bead (`--design` / `--append-notes`) → `bd human <id>`
  → exit `WORKER_STUCK_EXIT`. The structured ask is the raw material the §5
  dossier builder consumes.
- **Backstop (runner-side, zero model trust — AD3.3):** the runner scans the
  final `result.permission_denials[]` for `AskUserQuestion` / `ExitPlanMode`,
  **and** scans the stream for the `"Entered plan mode."` tool_result (the
  EnterPlanMode silent-no-op residual gap; `--disallowedTools` is the
  *guardrail*, this scan is the *backstop* — defense in depth). Either ⇒
  `STUCK_NEEDS_HUMAN`, **overriding the false exit-0/`is_error:false`
  success.**

**§7.3 Backstop drives the bead (AD3.3).** When a backstop fires (worker
slipped past the prohibition) it MUST itself drive the bead to
blocked-for-human (status=blocked + `bd human`); otherwise the fork rots
(UX principle 7). The **Coordinator owns "blocked-for-human"** and reconciles
`status=blocked` + `bd human` back into beads (control→work; S-2) — the worker
does **not** write Dolt as the source of truth, so Dolt lag is invisible to
the human-latency path (the §1 promise; the Board never lies — S-2).

**§7.4 Idempotency — double-trigger dedup (AD3.4).** Worker-self-signal and
backstop on the **same fork** dedupe via the per-Decision single-writer record
**keyed on `task_ref`** (= `Decision.id`, §4.1). The `consequence_applied`
latch (§4.1) flips false→true exactly once. **One fork ⇒ one dossier ⇒ one
consequence application**, regardless of: double trigger (AD3.4), double-tap by
the human, or `timer-fire` racing `poll-fallback` (S-6 / §2.2).

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
returning the constant; **no migration**, no schema change). The
**actor-authorization asymmetry** is normative and lives in §4.2
(`last_desired_actor`): every `RunnerState.desired` change is authorized
through this one chokepoint; an agent MAY downgrade/pause **its own** env,
but only the `PRINCIPAL_V1` human MAY promote to `running` (the C4/Flow-D
trust boundary — uniform code path, one authorization point, not a UI-vs-agent
split).

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

*(Anti-drift: each task cites the INTERFACE.md v1 sections it owns/binds.)*

| Task | Binds / owns INTERFACE.md v1 §§ |
|---|---|
| T1a (ooc) | §3, §7.1, §7.5, §8.1 — assertions cite these as literal close-criteria |
| T1b (crq) | §6.1/6.2, §7 (cross-tier), §8.2, §10.1 — observability/security/STUCK e2e |
| T2 (34h) | §2.5, §3 (caller), §7.1/7.2/7.5/7.6, §8.1 — runner state machine; stubs match §2–§6 signatures |
| T3 (3al) | §1.1 (up), §6.2 (local fallback), §6.3 (measurement), §8.2, §9.2, §10.2 — Local Agent |
| T4 (cbv) | §2.1–2.4, §4 (store owner), §6.1 (arbitration), §9.1, §10.3 — Coordinator |
| T5 (40c) | §2.2, §4.1/§4.3, §5 (sole producer), §7.3/7.4 — Decision/dossier DO |
| T6a (p2m) | §4.2 (`liveness`), §4.5 (projection, read-only) — Board |
| T6b (xre) | §5 (sole renderer), §4.5, §10.3 (fetch UI) — Inbox + Flow G |

**Change protocol (anti-drift, normative).** This document is **immutable
once claude-tools-65z is closed under its gated checkpoint**. Any tier that
finds the contract insufficient or contradictory MUST: (1) **stop** — not
diverge locally; (2) reopen claude-tools-65z; (3) amend the affected
section + bump the document version and the affected `*_schema_version`;
(4) re-run the §0 freeze (Brian sign-off); (5) only then resume, citing the
new version. A local divergence is a contract violation, not a shortcut.

---

## Appendix A — Non-normative Cloudflare realization

Informational only; **not part of any contract** (§0.2). §2.1 store →
Durable Object state + D1; §2.2 timer → a DO `setAlarm()`, with the S-6
poll-fallback making the free-tier alarm's non-contractual reliability safe;
§4.1 Decision → **one DO per Decision** (single-threaded ⇒ §7.4 idempotency
*by construction*); §2.3 chokepoint → a Worker middleware; §4.5 projection /
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
