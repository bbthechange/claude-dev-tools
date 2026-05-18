# Beads Runner — Architecture & Decisions

Status: draft (v2 — adversarial review integrated; AD7 §11-amended 2026-05-17: `diagrams[].content` = Mermaid, Dossier schema `1→2`) · Scope: **architecture/design only** (deliberately *not* UX) · Owner: Brian · Last updated: 2026-05-17

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
| **Local Agent** (one per computer) | Keychain + real usage poll + **BC-34 fail-open**; runner **process supervision incl. exit-code observation (BC-21)**; bounded **local lease fallback** (C-2); reports capacity + terminal-reason **upward** | strong, machine-local | the Mac (and any other runner host) |
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
| **AD1** | **Topology = Cloudflare hosted Coordinator + a per-computer Local Agent (§2).** Coordinator = Workers + Durable Objects + D1 + Pages. | $0 at this workload; a **DO-per-dossier-Item (AD7)** makes the per-item consequence applier idempotent *by construction* (single-threaded — supports partial/iterative dossier resolution), and `setAlarm()` is the `timed-fyi` timer. **SPOF acknowledged:** the singleton Coordinator DO is a single point of failure on free-tier infra with non-contractual alarm reliability; mitigated by the C-2 unreachable posture and the S-6 timer backstop, not waved away. |
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
design overview (the regression this revision fixes).

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
lives in the Local Agent; AD2.2 split posture). **O-1 probe:** AD3's
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

**The runner's six jobs (per loop / per the cadences above):** claim-lease ·
ask-capacity · heartbeat-actual-state(+liveness) · reconcile-desired-state ·
publish-work-snapshot · **report-terminal-reason** (a last durable write of the
BC-21 class + `STUCK_NEEDS_HUMAN` *before* exit, via the Local Agent which sees
the process exit code — so "exited because AUTH(3)" is a control-plane record,
not an unobservable process code; S-7). Board reads one surface (the
Coordinator); the work-snapshot is a read-only projection (Dolt remains work
truth — no plane-split violation).

**Status: foundational architecture closed (v2).** Open work is contract spec +
build, not decisions. **Build sequence + anti-drift** is the beads epic (see the
tracker); the keystone is a single frozen, versioned `INTERFACE.md` that every
later task binds to and may not unilaterally change. The standing trap: building
the visible web/dossier layer before the schema + reconciliation + lease/posture
model under it is proven against `BEHAVIORAL-CONTRACT.md`.
