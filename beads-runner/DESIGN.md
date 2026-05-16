# Beads Runner — Architecture & Decisions

Status: draft · Scope: **architecture/design only** (deliberately *not* UX) · Owner: Brian · Last updated: 2026-05-15

This is the architecture counterpart to `UX-DESIGN.md`. That doc is user-flows
only and is the authoritative source for requirement provenance (its §0). This
doc records the **design decisions and the extension seams**, and binds to two
companion artifacts:

- `UX-DESIGN.md` — user flows; §0 = what Brian asked for vs. agent elaboration.
- `BEHAVIORAL-CONTRACT.md` — the pre-rewrite characterization; the **regression
  gate** the rewrite must pass (SCAR = preserve behavior; SCAFFOLDING = do not
  port the mechanism).
- `research/headless-stuck-signal.md` — empirical headless `claude -p` behavior;
  basis for AD3.

---

## 1. The frame

The expansion is a **topology change, not a feature addition**. Today's
`run-beads-tasks.sh` is a single imperative process with all state, authority,
and lifecycle local. The target is a distributed system: a hosted coordinator,
N controllable runners, an async human, durable timers, a web app. Almost every
risk is a consequence of that shift. The existing script is read carefully for
its scar tissue (`BEHAVIORAL-CONTRACT.md`) and largely **not reused as code**.

---

## 2. The plane split (foundational)

| Plane | What | Consistency | Store |
|---|---|---|---|
| **Work** | beads/Dolt, exactly as today — issues, deps, notes, labels | eventually consistent | Dolt (unchanged) |
| **Control/decision** | RunnerState (desired+actual), Decision (+versioned consequence blocks), Notification, task leases, capacity gate, durable timers | strong, idempotent | coordinator (AD1) |
| **Board** | a *projection* that joins Work + Control | read-only view | derived |

The human-latency-sensitive path ("did my approval land", "is the runner
actually paused") never touches Dolt merge semantics. The UX doc's "thin
control/notify channel" is explicitly **rejected as under-specified**: that
channel is the spine (auth, bidirectional, durable timers, capacity, decisions)
and is designed as a real—if small—service, not a relay.

**Consequence already banked:** the desired/actual reconciliation model
eliminates the need for a durable command queue. A pause/stop issued while the
laptop sleeps is not a queued message — it is a mutation to desired-state; the
offline runner reconciles by reading desired-state on reconnect.

---

## 3. Settled architecture decisions

| # | Decision | Rationale / consequence |
|---|---|---|
| **AD1** | **Topology = Cloudflare** (Workers + Durable Objects + D1 + Pages). | $0 at this workload and *architecturally* the cleanest: a **Durable Object per decision** makes the consequence applier idempotent **by construction** (single-threaded) and `DO.setAlarm()` **is** the `timed-fyi` durable timer (native primitive). These were two of the highest "must get right" risks; the topology choice dissolves both. No inactivity-pause edge (vs. Supabase); less wiring/IAM (vs. AWS). Free-tier SQLite-backed DOs are explicitly never charged. |
| **AD2** | **Coordinator-issued task lease = single authority for exclusivity + orphan recovery. Capacity is a *separate, deliberately coarse* gate.** | Resolves `BEHAVIORAL-CONTRACT.md` **BC-04**: the two-runners-one-orphan race was tolerable single-runner, fatal multi-runner. A runner requests an exclusive TTL'd lease on a *task ID*; orphan = expired lease (replaces the startup `in_progress` snapshot heuristic BC-02/03/04 — intent preserved, bash mechanism discarded). **Capacity is decoupled**: tasks are small relative to the weekly budget, so admission is a yes/no "under threshold?" check at claim time + record-actual-after. No reservation math, no in-flight ledger; a one-task overshoot at the line is noise, not a bug. Preserves the fail-open posture (BC-34): a capacity-check outage must never halt the fleet. |
| **AD3** | **Worker stuck-signal = instruct (not rely) + deterministic backstop + guardrail.** | From `research/headless-stuck-signal.md`: interactive tools soft-fail but the process is **indistinguishable from success** (exit 0, `is_error:false`), and the model does **not** self-recover. So: **(a)** worker prompt keeps the prohibition **and adds a positive path** — on a fork it must not resolve: `bd update --status=blocked` → write the structured ask into the bead → `bd human <id>` → exit non-zero; **(b)** runner backstop scans the final `result.permission_denials[]` (structured, deterministic — *more* robust than the brittle BC-25 text scan) → new terminal class `STUCK_NEEDS_HUMAN` that overrides the false exit-0 and routes to Flow B instead of `TASK_NOT_CLOSED` rot; **(c)** guardrail `--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode`, keep `--output-format stream-json`. (c) is the only thing that closes the EnterPlanMode *silent no-op* gap. This is a **new SCAR-class requirement** added to the rewrite gate (correctly absent from the contract, which characterizes only the old script). |
| **AD4** | **Forensic boundary simplified** (relaxes UX-doc D6). | The "redacted, on-demand, never persisted server-side" constraint was design-agent over-reach past UX, not a Brian requirement. Model is now: **one authenticated boundary; the coordinator may receive and briefly hold forensic blobs with a short retention.** Flow G's progressive-disclosure *UX* stays. **BC-27 still holds**: the git-containment scar (post-mortem artifacts never enter a committable path) is preserved verbatim; only the never-touch-server constraint is dropped. |
| **AD5** | **Scope cuts** (see §4). | Removes most of the project's *novel* risk while touching nothing in `UX-DESIGN.md` §0.A/§0.B. |
| **AD6** | **Auth = single-user v1 over a principal-based seam.** One human credential + per-runner bearer tokens, all resolved through **one `authenticate(request) → principal` chokepoint**; every control-plane record carries a `principal` field, hardcoded to a single constant in v1. | Single-user now, but multi-user later must not require a migration. This is **the same chokepoint as C4** (record-actor + single authorization point) — one seam serves *both* the deferred asymmetric-trust feature and deferred multi-user. Marginal cost ≈ a field + a function boundary. See seam C7. |

---

## 4. Scope cuts (descoped from v1)

Verdicts: **DEFER** = build later as a separate layer · **DROP** = cut from v1 ·
**SIMPLIFY** = keep requirement, shrink mechanism. Justification column cites the
UX-doc §0 status (0.C = design-agent elaboration, freely tradeable).

| # | Item | §0 | Verdict | Why safe |
|---|---|---|---|---|
| C1 | Autonomous staged pipeline + gate map | 0.C | **DEFER** | §0.A asks for lifecycle *tracking*, not autonomous stage-driving. Biggest single de-risk. |
| C2 | Collaborative-stage interactive mode | 0.C | **DROP/DEFER** | Same class as the non-headless-Claude item Brian already flagged impossible; headless research confirms. |
| C3 | Notification batching / digest | 0.C | **DROP** | Silence *tiers* (0.B) kept; *batching* is premature for a personal system. |
| C4 | Asymmetric agent/human trust boundary | 0.C | **DROP** | §0.A wants *symmetric* control by Brian AND agents; asymmetry is a 0.C nicety. |
| C5 | 4-pass dossier orchestration | 0.C labels / A·B intent | **SIMPLIFY** | Keep filter+readability (0.A) + consequence block (0.B) + inline response (0.A); one structured generation, not 4 chained agents. |
| C6 | "Honest desired-vs-actual" UI polish | mixed | **SPLIT** | Backbone is load-bearing (kept, AD2). Only the transitional-state UI rendering is deferred. |

**Irreducible (hard but §0.A/§0.B — cannot be cut):** the human-decision
doc-gen quality loop (the product); the spare-cycles 14.2%/day gate (math
trivial, gate coarse per AD2); the coordinator itself (AD1).

---

## 5. Deferred ≠ rewrite-later — the extension seams

> **Unifying rule: defer *behavior*, not *data*.** Every deferred feature must
> have its data shape and its single chokepoint present in v1, wired to a
> trivial/constant policy. The rewrite-forcing mistake is deferring the *seam*.

### C1 — Autonomous staged pipeline + gate map
**Seam:** `stage` is a first-class enumerated field on every bead from day 1;
*every* stage change — even manual — goes through one **"advance stage"
operation** that records what triggered it; the gate map is an explicit policy
function keyed by `(stage, transition)` (v1's is the constant "always manual").
**v1 MUST:** model stages as structured data; route all transitions through the
one operation. **v1 MUST NOT:** allow ad-hoc free-text stage labels edited
directly (no chokepoint ⇒ nothing for later auto-progression to hook ⇒ rewrite).
Later pipeline = an agent emitting the same transition events + a non-trivial
gate-policy table.

### C2 — Collaborative-stage interactive mode
**Seam:** the decision/Inbox entity carries a `kind` discriminator
(`decide`, later `pair`); runner-control already has a pause/hand-off path
(built for Flow D regardless).
**v1 MUST:** make the decision entity a typed record with an open `kind`;
implement only `decide`. **v1 MUST NOT:** model decisions as a single closed
shape. Later collaborative-stage = a new `kind` + the D7 attach-mode hand-off;
no schema migration.

### C3 — Notification batching / digest
**Seam:** a notification is a **persisted, tiered record**; *creation* is
separate from *dispatch*.
**v1 MUST:** write each notification as a row `{tier, decision-ref, created-at,
dispatched?}`; send one immediately. **v1 MUST NOT:** fire-and-forget with no
record. Batching later = a pure read-side rollup over existing rows; zero schema
change.

### C4 — Asymmetric trust boundary
**Seam:** all runner-state changes go through one "set state" operation that
records the **actor** (Brian vs. which agent), with a single authorization
checkpoint.
**v1 MUST:** capture actor identity; authorize all actors equally through that
one checkpoint. **v1 MUST NOT:** let the UI and in-workspace agents mutate state
via different code paths. Asymmetric policy later = one `if` in the checkpoint.

### C5 — Dossier generation (4-pass → one call)
**Seam:** freeze the **output schema**
`{filtered_context, framing, consequence_block, response_affordances}`,
versioned; the producer is swappable behind it.
**v1 MUST:** define/version that schema; everything downstream binds to the
schema, never to "the passes." If quality later needs separate orchestrated
passes, only the producer changes — same contract, no downstream churn.

### C6 — Honest-state UI polish
**No seam work needed** — the model case of correct deferral. The backbone
(AD2) already carries both `desired` and `actual`; the deferred polish is pure
rendering over data v1 already exposes.

### C7 — Multi-user (rides the C4 seam — AD6)
**Seam:** one `authenticate(request) → principal` chokepoint; every
control-plane record (Decision, RunnerState, Notification, lease,
work-snapshot) carries a `principal` field. This is **not a new seam** — it is
C4's record-actor + single-authorization-checkpoint generalized: the same field
and chokepoint serve "asymmetric trust later" *and* "multi-user later."
**v1 MUST:** stamp `principal` (a constant) on every control record; route every
request through the one `authenticate → principal` step; downstream code binds
to the resolved `principal`, never an implicit "it's Brian." Per-runner tokens
are already principal-scoped.
**v1 MUST NOT:** add roles/RBAC, login/session/OAuth, sharing/visibility logic,
or per-user data partitioning. Authorization stays "known principal ⇒ allowed"
(the C4 symmetric checkpoint).
**Multi-user later =** mint more human tokens + stop hardcoding the `principal`
constant (derive it from auth) + optionally add a visibility filter. No schema
migration, no query rewrite, no endpoint surgery.

---

## 6. Conformance gate

The rewrite passes iff every **SCAR** in `BEHAVIORAL-CONTRACT.md` has an
equivalent observable behavior under its black-box repro, and no **SCAFFOLDING**
mechanism is transcribed. Highest-risk regressions (silent when wrong):
**BC-21** (exit-code contract), **BC-27** (LOG_DIR security boundary — also
AD4), **BC-10/BC-11** (classification precedence), **BC-13/BC-14** (per-class
retry asymmetry). Plus the AD3 `STUCK_NEEDS_HUMAN` behavior as a new SCAR-class
requirement.

---

## 7. The control-plane interface (settled)

Provider-agnostic capabilities — no Cloudflare primitive leaks into the runner
or web-app contracts (the guardrail that keeps the provider swappable when
free-tier terms move):

1. small strongly-consistent store (Decision / RunnerState / Notification / lease / work-snapshot),
2. durable one-shot timer (`fire(decisionId) at T`),
3. authed request endpoint with one `authenticate(request) → principal` chokepoint (AD6),
4. deliver-desired-state-on-reconnect.

**Connection model: poll, between tasks** — not a persistent socket. The runner
already has a between-tasks checkpoint (today it polls usage there). Control
latency = "takes effect at the next task boundary," which is exactly the
semantics already committed (BC-33 graceful-stop-after-current-task; honest
state "may lag"). A hibernating WebSocket is a later latency optimization behind
this same interface, not a v1 requirement.

**The runner's five jobs against this interface (per loop):** claim-lease ·
ask-capacity · heartbeat-actual-state · reconcile-desired-state ·
publish-work-snapshot. The Board reads one surface (the coordinator) because the
web app cannot reach Dolt; the snapshot is a read-only projection (beads/Dolt
remains source of truth for work — does not violate the §2 plane split).

**Status: foundational architecture is closed.** AD1–AD6 + the scope cuts + the
seams (C1–C7) + this interface settle every load-bearing decision. What remains
is detailed contract spec and build sequencing — not open questions. Suggested
order (each de-risks the next, nothing built twice): (1) freeze the store
schemas + the dossier output schema (C5) + the interface contract; (2) runner
refactored into a state machine with the five jobs, coordinator as a no-op stub,
proving it still passes `BEHAVIORAL-CONTRACT.md`; (3) coordinator (lease +
coarse capacity + reconcile); (4) decision/dossier DO + timer + idempotent
applier; (5) web app over the projection (Board, then Inbox). The trap to avoid
remains: building the visible web/dossier layer before the schema and
reconciliation model under it are proven.
