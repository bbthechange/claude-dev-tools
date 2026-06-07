# Inbox lifecycle — UX expansion context

Written 2026-05-29. Source: `tmp/changes.md` (sessions 2026-05-23 → 2026-05-28). This doc is the synthesis that the upcoming larger UX expansion will fold into. It is structured around a unifying frame ("the Inbox lifecycle as a five-stage contract") and preserves every concrete item from `tmp/changes.md` — including those that don't fit the unifying frame.

The companion source files are kept on disk (`tmp/changes.md`, `tmp/beads-log-visibility-findings.md`). This doc is the **canonical** rollup; pick items from here rather than re-reading the source.

---

## 1. The unifying frame

**The Inbox is Brian's contract surface with agents.** The Board ("workspace lifecycle") and the Inbox ("waiting on you") together are the only phone-facing artifacts Brian uses to drive the autonomous swarm. Every leak in `tmp/changes.md` is a breach of the Inbox contract.

What look like five independent bugs across Appendices A–E of `tmp/changes.md` are actually **one design problem with five symptoms**: the lifecycle of a dossier on the Inbox has a leak at every stage.

### The five stages

| # | Stage | Question it answers | Today's leak | Owner section below |
|---|---|---|---|---|
| 1 | **Genesis** | How does a dossier reach the Inbox? | Only `worker_stuck` is agent-callable. Three other engine-accepted triggers are unreachable from agents. | §3 |
| 2 | **Presentation** | Can Brian read what's there in <30s without a translator? | Prose mirrors contract vocabulary; fallback template is jargon-heavy; fallback fires more than it should. | §4 |
| 3 | **Interaction** | Does tapping a button do what its label says? | "Dismiss as stale" silently applies the recommendation via an empty-payload fallthrough. | §5 |
| 4 | **State integrity** | Does the renderer agree with the engine after an action? | Render shows `0 / 1 resolved` after engine resolved + re-dispatched. | §6 |
| 5 | **Closure** | When a dossier no longer matters, does it leave? | No work→control reaction; beads closing outside the dossier flow leave dossiers asking dead questions. | §7 |

### The principle each stage instantiates

> "A child closes on what Brian experiences." — recurring rescue-epic discipline.

Stale cards = the surface is lying. Empty-payload fallthroughs = the surface is acting without consent. Jargon prose = the surface isn't reaching its reader. The five stages are five ways the surface can break that promise.

### Foundation layer (orthogonal but load-bearing)

For the Inbox contract to hold, the **runner plane** underneath has to be sound. Three reliability concerns sit underneath (§8):

- Queue starvation (`claude-tools-dzc`, filed P1, one-line fix at `next_task()`).
- Task-close discipline (TASK_NOT_CLOSED dominates thirsty at 124 incidents).
- Cross-process ownership (runner adopts in_progress tasks owned by live external Claude sessions — Mechanism A/B/C in Appendix C).

These don't fit the Inbox-lifecycle frame but they directly cause Inbox symptoms (a worker that doesn't close cleanly leaves a stale bead reference; a runner that double-claims an external agent's task corrupts the dossier↔bead link).

### Items that don't fit the frame at all

§9 catches items that are real but truly orthogonal (ambiguous reconcile log, Board lifecycle spine showing zeros, intake-pipeline retry/parser gaps, deliberately skipped items). They're preserved here so they don't get lost.

---

## 2. Reading map

| If you want… | Go to |
|---|---|
| The 5-stage UX spine | §1 |
| Stage-by-stage detail with all evidence | §3 – §7 |
| Runner-plane foundation work (queue / close / ownership) | §8 |
| Truly orthogonal items | §9 |
| Already-filed beads / state at handoff | §10 |
| Constraints / posture (labelling, web-deploy, secrets) | §11 |
| File-by-file index for fixers | §12 |
| Source documents preserved | §13 |

---

## 3. Stage 1 — Genesis: how dossiers reach the Inbox

**Source:** `tmp/changes.md` Appendix E in full.

### 3.1 The gap

The dossier engine accepts four `trigger` values: `worker_stuck`, `human_flag`, `stage_gate`, `proactive_checkpoint`. The agent-facing surface is **one** channel hardcoded to `worker_stuck`.

- `mcp-askbrian/server.mjs:546-547` hardcodes `kind: "decide"` and `trigger: "worker_stuck"`.
- The MCP tool's `inputSchema` (around `mcp-askbrian/server.mjs:608`) does not accept `trigger` or `kind`.
- The tool requires `bead_ref` (see file-header comment at `mcp-askbrian/server.mjs:30`). A freestanding "I want to tell Brian something" call from outside a bead context is unreachable.

Brian's original requirement — *"any time an agent thinks something happened that I should know about, it can produce a dossier explaining it"* — is structurally **not built**.

`proactive_checkpoint` does exist as a path, but only fires from `beads-runner/daemon/flow-f-overview-poll.sh`, which polls every 60s for closed bd beads carrying the `stage:design` label. Narrow predicate; no agent entry point.

### 3.2 Companion gap on the intake side

`beads-runner/agents/intake-presets.json` has exactly two presets:

- `autonomous-until-stuck` → `entry_stage:impl`, `gate_aggressiveness:auto-advance`
- `collaborative-stage` → `entry_stage:ux`, `gate_aggressiveness:gate-human`

Both produce **bd tasks**. Neither routes a phone intake into the dossier pipeline. Path today:

```
phone /intake → coordinator queue → intake-dispatch-poll.sh
  → specialist.sh --kind=enricher → bd create (a task!)
  → workspace runner picks up the task → worker writes content into bd notes
```

The Inbox UI reads dossiers from the engine; it never sees bd notes. So a phone intake asking for an overview becomes markdown in `bd show` notes that no surface renders.

### 3.3 Trigger table (current reality)

| Trigger | Engine accepts? | Agent-callable in-bead? | Agent-callable freestanding? | Where it actually fires |
|---|---|---|---|---|
| `worker_stuck` | yes | yes (`mcp__askbrian__ask-brian`) | no | worker hits fork → ask-brian MCP → dispatcher in `mcp-askbrian/server.mjs` |
| `human_flag` | yes | no | no | bd `human` label set; daemon flow picks it up |
| `stage_gate` | yes | no | no | stage-transition logic in `beads-runner/gate-policy.sh` |
| `proactive_checkpoint` | yes | **no** | **no** | `beads-runner/daemon/flow-f-overview-poll.sh` — narrow predicate |

The two "no" cells in the bottom row are the gap.

### 3.4 Fix shape (not yet authorized — confirm with Brian before code)

**Gap A — agent-callable proactive dossier:**

1. Extend `mcp-askbrian/server.mjs` `inputSchema` to accept optional `trigger` (default `worker_stuck`) and `kind` (default `decide`). Validate against the engine's closed enums.
2. Branch the dispatch path at the call handler:
   - `worker_stuck` / `human_flag` / `stage_gate` → existing path (poll loop, blocks until answered).
   - `proactive_checkpoint` → write through `engine-bridge.sh write_polished` with `tier=timed-fyi`; **do not enter the poll loop** (FYI is non-blocking); return immediately with dossier id.
3. Loosen the `bead_ref` requirement for `proactive_checkpoint`, OR keep it required and document that FYIs are bead-anchored too.
4. Dossier-id scheme — the `stuck-<bead_ref>` deterministic id won't apply to proactive ones. `overview-<bead_ref>-<timestamp>` or similar. Flow F uses `overview-<bead_ref>` per its dedup; decide whether agent-triggered overviews share that namespace or get their own.

**Gap B — intake-preset for dossier requests:**

> **RESOLVED (claude-tools-uxvl4 / L4, 2026-06-06):** shipped. The open design
> question below was settled in favour of the second option — **skip the
> enricher; branch in the daemon.** What landed:
>
> 1. A new SPECIAL preset row `overview-request` in
>    `beads-runner/agents/intake-presets.json` (mirrored in
>    `web/functions/api/intake/_presets-catalog.js`, lockstep). It carries
>    `entry_stage:null`, `gate_aggressiveness:null`, and a `routing:"overview-fyi"`
>    discriminator (`schema_version` bumped 1→2 for the new optional field). It
>    breaks the reductive (entry_stage, gate) contract on purpose and is exempt
>    from the L1/L2 spine checks in `test-intake-presets.sh` — which gained a new
>    check (10) that every `routing`-set value is branched on by name in the daemon.
> 2. `beads-runner/daemon/intake-dispatch-poll.sh` branches in
>    `daemon_intake_dispatch_one`: `preset == overview-request` →
>    `daemon_intake_dispatch_overview`, which spawns a **dossier-builder** (NOT the
>    enricher), shapes its `{body,items}` into a §4.1 envelope
>    (`kind=overview`, `trigger=proactive_checkpoint`, `tier=timed-fyi`,
>    `bead_ref=`the synthetic intake_id — §4.1 only needs a non-empty string), and
>    emits via the same `dg_generate + no_emit/no_dispatch + tf_arm` sequence Flow F
>    uses. **No `bd create` ever runs** (the s6/s4 invariant: assert no bead). The
>    record is marked `processed` with `dispatch_state:"overview"` +
>    `overview_dossier_id` (NO `enricher_bd_id`), and rides the I3
>    failing(n)→gave_up retry machine on any miscarriage.
> 3. The enricher was therefore NOT extended — it never receives an
>    overview-request (the daemon branches before dispatch). A defensive bullet in
>    `enricher.system.md` documents the bypass.
> 4. `daemon_intake_parse_bd_id` was untouched — the overview path parses the
>    builder's `{body,items}` JSON, not the enricher one-line summary.
>
> The original plan (below) is kept for the record.

1. New row in `beads-runner/agents/intake-presets.json` — e.g. `overview-dossier` with `entry_stage:null` (no bd task produced) and a sentinel `gate_aggressiveness` value meaning "no bead, FYI dossier."
2. Mirror in `beads-runner/web/functions/api/intake/_presets-catalog.js` (the playbook in `intake-presets.md` says "keep in lockstep").
3. Extend `beads-runner/agents/enricher.system.md` with a fourth Step branch: if `preset` is the new overview value, **do not `bd create`**. Instead author the dossier body and push through `engine-bridge.sh write_polished` with `trigger=proactive_checkpoint`. Emit a new stdout summary `enricher: overview → wrote dossier <id> (intake <intake_id>)`.
4. `daemon_intake_parse_bd_id` (`beads-runner/daemon/intake-dispatch-poll.sh:211-229`-ish) needs a new pattern for the overview outcome so it marks the intake processed.

**Open design question (Gap B) — RESOLVED, see the box above:** should overview intakes go through the **enricher** at all (whose contract is "bd is your only writer") or route directly to a **dossier-builder dispatch** in the daemon (skip the enricher entirely)? Author's read in `tmp/changes.md`: skip the enricher; dedup against bd isn't useful for an FYI. Have `intake-dispatch-poll.sh` branch on preset.

### 3.5 Tactical workaround for the existing rhythmGame intakes

Two intakes already landed and have dossier-shaped content sitting in bd notes. The runbook `docs/runbooks/manual-dossier-tools.md` is the exact playbook to push these into the engine manually:

- **rhythmGame-g7n** (overnight, intake `06-17`) — `bd show rhythmGame-g7n` from `/Users/brianbutler/code/rhythmGame` shows a complete done/not-done/next dossier in the notes. Bead is CLOSED, content is committed.
- **rhythmGame-93o** (morning, intake `09-30`) — same shape, REFRESH that diffs against g7n (post-prototype DrawingOverlay + R-restart commits). Worker closed it; commit `950b8d0 bd: refreshed status dossier on rhythmGame-93o`.

Recipe:

1. Reshape the bd-notes markdown into schema (`body.{tldr, sections[], diagrams[], full_detail}` + ≥1 `items[]` with a real `context_anchor`).
2. Apply `body.dossier_schema_version: 2` and `items[].consequence_block.cb_schema_version: 2` (write-gate enforces — `manual-dossier-tools.md:142-149`).
3. Build the generation_input envelope with `kind:"overview"`, `trigger:"proactive_checkpoint"`, `tier:"timed-fyi"`, `bead_ref:"rhythmGame-93o"`.
4. `engine-bridge.sh write_polished "$gi"` with `COORDINATOR_TOKEN` from Keychain.
5. Verify with the curl in the runbook + check `https://claude-wrangler.pages.dev/inbox`.

The tactical upload also smoke-tests the dossier pipeline from a known-good content source — useful sanity check before designing the structural fix.

### 3.6 What was validated this session (don't redo)

- `claude-tools-e5aq` is CLOSED. The `Bash(bd:*)` allowlist fix landed at commit `17129b3 fix(specialist): grant Bash(bd:*) + read-only tooling to all hats`. Enricher now does its job. Live verification: fresh intake at 09:30:15Z produced `rhythmGame-93o` end-to-end in ~3 minutes.
- The 09:30:42Z dispatch produced `outcome=created bd_id=rhythmGame-93o` — full happy path: phone → coordinator → daemon poll → enricher → bd create → worker auto-picks up → worker writes/commits → bead closed.
- Enricher's dedup pass works. The 09:30 intake recognized g7n and structured itself as a delta.
- Overnight stuck-intake (`intake-06-17...`) was retried 19+ times before e5aq landed; ~$1/retry. 20th run (07:35:21Z) succeeded after the fix.

---

## 4. Stage 2 — Presentation: can Brian read what's there

**Source:** `tmp/changes.md` Appendix A §3 bead 1, Appendix B.3, Appendix B.4.

### 4.1 The headline observation

Brian's verbatim feedback on the `claude-tools-7xl` dossier this session: *"soooooo many words to communicate something so simple. let's come back to this, and how to get agents to be more intelligible."*

He gave the same feedback twice in that short session — once on the dossier, once on the agent's first answer to "why isn't the worker allowed to make the call?" (rejected as restating the screenshot's jargon back at him). The pattern is **agent output that mirrors contract vocabulary instead of translating it.**

### 4.2 The concrete `claude-tools-7xl` example

The dossier carried the **FALLBACK AUTHOR** badge — dossier-builder LLM not configured for this run; deterministic template wrote it. The TL;DR read:

> A backstop fired on claude-tools-7xl: the worker reached an interactive fork it must not resolve and slipped past the §7.6 guardrail.

What it should have said (the agent's translation when Brian asked):

> The Phase B verification worker is running on the OLD script; bouncing PID 26420 lets it pick up the new bytes. That bounce kills the in-flight task, so I'm asking before doing it. Recommend: bounce.

The fallback's output is contract-vocabulary-shaped ("backstop fired", "§7.6 guardrail", "worker_stuck") and doesn't translate the actual situation into plain English. Inbox unreadable to its primary user without an interpretation pass from another agent.

### 4.3 The structural cause — fallback fires too often

`DOSSIER_FALLBACK:no_DG_AUTHOR_CMD` is still residual after the cvj/qxz/cxj/3w8/n34/lhc dossier-builder chain was supposed to make agent-authored normal:

- `claude-tools`: 6× (most recent 2026-05-22T17:45:52Z on `claude-tools-240`).
- `thirsty`: 1× (2026-05-23 on `thirsty-4vfi`).
- `hangouts`: 1× (2026-05-22 on `c0b`).
- **NEW evidence:** `claude-tools-7xl` dossier rendered 2026-05-26 carried `FALLBACK AUTHOR` badge, observed live by Brian.

This is the "closed-but-not-shipped" anti-pattern `CLAUDE.md` calls out. Either the fix is incomplete (workspaces missing config), or a code path still emits the fallback when it shouldn't.

> **RESOLVED (claude-tools-uxvl5, 2026-06-01):** it is the **first** — the fix is incomplete. `DG_AUTHOR_CMD` (the bridge to the real dossier-builder agent) was wired **per-call-site**, at only two v1 sites in `run-beads-tasks.sh` (the `sr_route_stuck`/`worker_stuck` backstop at `:2375` and the Flow-G analysis path at `:1125`, both landed 2026-05-23/25 — *before* the 7xl fire, so this is a genuine residual, not a timing gap). Every **other** `dg__author` caller — the `proactive_checkpoint`, `stage_gate`, and any `human_flag`/`worker_stuck` dossier reaching `dg_generate` from a path without its own `export DG_AUTHOR_CMD` subshell — still falls to the jq path and fires `no_DG_AUTHOR_CMD`. The audit log (`dossier-author-audit.jsonl`) confirms it is *actively* firing (426 fires on 2026-06-01; lifetime `no_DG_AUTHOR_CMD`≈2509 vs `agent_ok`≈151), the single most-recent a `stage_gate` overview. A second degradation: `agent_unavailable` ~290×/day means the agent often fails even where wired. **v2 makes it worse, not better** — `runner.sh`'s `_drive_blocked_for_human` (`:644`) writes a *body-less* stub dossier and never calls `dg__author`, so a v2 STUCK fork ships neither an agent body nor a jq-fallback body. The **global** wiring fix (default the bridge once at the `dg__author` chokepoint, or per-runner) + the v2 stub authoring are filed as a follow-up bead — both are larger than this readability bead and touch the §0.2 authoring-seam default. What uxvl5 *did* land: the **readability** of the fallback when it does fire (§4.4) — the jargon Brian saw on 7xl came from `sr_worker_ask` (in `beads-runner/lib/stuck-routing.sh`), now plain-English and guarded by `dg__readability_lint`.

### 4.4 The readability gate (a writer-side rule)

Even agent-authored dossiers should be evaluated against a **human-readability gate**: would a non-author human reading this dossier cold in the Inbox understand (a) what blew up, (b) what they're being asked to decide, and (c) what each option actually does — in <30 seconds and without contract jargon?

Right now the structure (BLOCKING badge, contract section IDs, formal Options list) optimizes for engine round-tripping, not for the human reader.

**Suggested rule of thumb for `beads-runner/agents/dossier-builder.system.md`:** *never name a contract section without translating what it means in the same sentence.* Example: "§7.6 guardrail" → "(the worker isn't allowed to use AskUserQuestion / EnterPlanMode tools, so it can't ask in-band)".

The fallback template needs the same rule, because the fallback path is exactly when readability matters most (the agent author wasn't reachable, so this card is Brian's only signal).

### 4.5 The meta concern — agent intelligibility is recurring

This is broader than dossier templates. Brian wants to come back to it. Capture in `~/.claude/projects/-Users-brianbutler-code-claude-tools/memory/feedback_agent_intelligibility.md` so the conversation doesn't get lost. NOT a bead yet — Brian explicitly parked it.

### 4.6 Filing guidance for the fallback-residual bug

- **Title:** "DOSSIER_FALLBACK:no_DG_AUTHOR_CMD still firing post cvj-chain — author path not reaching dossier-builder agent in all cases"
- **Type:** bug. **Priority:** P2. **Label:** `runner-reliability`. **No `human-triage`.**
- **Investigation pointers:**
  - Grep `no_DG_AUTHOR_CMD` in `beads-runner/run-beads-tasks.sh` — fallback emit site = "what's missing" check.
  - Cross-reference closed cvj/qxz beads for what the agent path was supposed to look like.
  - Sample dossier-author-audit jsonl at `/Users/brianbutler/.cache/claude-tools/dossier-author-audit.jsonl`.
  - Check most-recent fires (`claude-tools-240` 2026-05-22; `claude-tools-7xl` 2026-05-26).
- **DONE (claude-tools-uxvl5):** the **readability** half of this bug is fixed — see the §4.3 RESOLVED note for the root cause of *why it still fires* (per-call-site wiring; v2 stub) and the follow-up bead for the global wiring fix. The fallback emit site is actually the `else reason="no_DG_AUTHOR_CMD"` arm of `dg__author` (in `beads-runner/lib/dossier-gen.sh`), reached from `dg_generate`; the jargon TL;DR Brian saw is `sr_worker_ask` (in `beads-runner/lib/stuck-routing.sh`). Both the `sr_worker_ask` raw material and the `dg_from_worker_ask` synthesized strings (caption + `context_anchor.where` + defaults) are now plain-English and asserted against `dg__readability_lint` (a new advisory lint in `dossier-gen.sh`) in `test-stuck-routing.sh` (failing-then-fixed) and `test-dossier-gen.sh`.

---

## 5. Stage 3 — Interaction: does tapping a button do what it says

**Source:** `tmp/changes.md` Appendix B.1.

### 5.1 What happened

Brian clicked **Dismiss as stale** on the `claude-tools-7xl` worker_stuck dossier in the Inbox. The engine treated that click as an answer to the human-decision fork: empty `{}` payload through the §5.2 decision pipeline → deterministic fallback defaulted to the dossier's printed `recommendation` (`resume`) → runner re-dispatched `claude-tools-7xl` to a fresh worker.

### 5.2 Evidence captured live

The currently-running worker is PID 79346 (`claude -p ...`), whose prompt header reads:

```
═══ HUMAN DECISION — the parked fork on claude-tools-7xl was answered (resume) ═══
A human reviewed the STUCK_NEEDS_HUMAN dossier you raised and DECIDED.
  The ask was: How should the runner proceed on claude-tools-7xl (a human-decision fork)?
  Human chose: (answered — see the dossier)
  Raw response (§5.2): {}
```

`Raw response (§5.2): {}` is the smoking gun. Empty payload, no `pick-option` items selected. Engine took "no items picked" + "dossier exists" + "recommendation present" → "default to recommendation" → `resume`.

Brian: *"oh hm I just dismissed it as stale, which must have triggered that."*

### 5.3 Why this is wrong

- "Dismiss as stale" semantically means *"this card is no longer relevant — drop it."*
- Current behavior treats it as *"apply the recommendation."*
- Opposite intents. A user dismissing a card almost certainly doesn't want destructive/restart actions executed on their behalf.

### 5.4 Fix sketch

- Inbox UI sends a distinct `dismiss_as_stale` action (not an empty resolution payload) to the engine.
- Engine §5.2 pipeline: on `dismiss_as_stale`, resolve the dossier **without consuming the recommendation**, and either (a) drop the bead back to `blocked-for-human` so it doesn't auto-re-dispatch, or (b) close the dossier and leave the bead in whatever pre-dossier status it had.
- §7.4 idempotency latch still flips so the same dossier can't be acted on twice.
- **Empty-payload `{}` should NOT silently fall back to "apply recommendation" anywhere — that is the actual bug, distinct from the UI button label.** Both fix surfaces (UI verb + engine fallthrough) should land together.

### 5.5 Filing guidance

- **Title:** "Inbox 'Dismiss as stale' silently re-applies dossier recommendation (empty payload falls back to recommendation in §5.2)"
- **Priority:** P1 (active behavior diverges from the labeled affordance). **Type:** bug. **Label:** `runner-reliability`. **No `human-triage`** — touches Inbox JS + worker engine, both static-edit-safe.
- **Web-deploy reminder:** Inbox piece is web-track. Per `CLAUDE.md`, an Inbox change is NOT done at commit — it's done when `bash beads-runner/verify-pages-deploy.sh inbox` returns `mismatches=0` against the live `claude-wrangler` Pages host.

### 5.6 Interaction taxonomy (for the larger expansion)

Stage 3's larger lesson: every Inbox button needs an explicit verb that round-trips to a dedicated engine op. Verbs we know we'll want:

- **apply** (`pick` / `approve` / `reject`) — the deterministic path that exists today.
- **dismiss-as-stale** — new; resolves without consuming recommendation.
- **defer** — push out without resolution. **BUILT** (claude-tools-uxl1b): `dossier-defer` → tier=digest.
- **escalate** — promote to higher-attention surface (push notification, etc.). **BUILT** (claude-tools-uxl1b): `dossier-escalate` → tier=blocking.
- **snooze** — like timer expiry, set by user. **BUILT** (claude-tools-653d): `dossier-snooze {dossier_id, snooze_until}` DEFERS now (tier→digest) AND arms the §2.2 timer to RE-SURFACE (not auto-proceed) at `snooze_until`. The re-surface (`snoozeSurface`, the fire=SURFACE primitive ready-to-pair built) re-tiers blocking + re-fires the blocking `new_dossier` ping; it rides a `snoozed_until` envelope discriminator so `fireDueTimers` routes it to surface (not auto-proceed). Lives in `cf/src/timer.js`/`TIMER_OPS` (a timer-arming verb), bash twin `lib/timed-fyi.sh` `do_dossier_snooze`/`snooze_surface`, web proxy `inbox/snooze.js`, UI preset chips. The L2 auto-close discriminator (`beadStatusChanged`) was narrowed from "armed timer ⇒ exempt" to "GENUINELY timed-fyi ⇒ exempt" so a snoozed dead-bead card still auto-closes. KNOWN follow-up: the re-fire restores the blocking lane but does NOT generate a fresh push for a notif already in CF.9's `push_deliveries` deliver-once ledger (the pairSurface property) — a targeted ledger eviction is the clean fix.

No verb may default to another verb's payload. Empty payload = hard reject in §5.2, surfaces an error to the UI.

---

## 6. Stage 4 — State integrity: renderer agrees with engine

**Source:** `tmp/changes.md` Appendix B.2.

### 6.1 What happened

After Brian dismissed the dossier (which the engine processed and used to re-dispatch the worker — see §5), the Inbox UI in the screenshot still showed `0 / 1 resolved` and the BLOCKING badge. Engine's view (worker re-dispatched, `consequence_applied` presumably flipped per §7.4) had diverged from the renderer's view.

### 6.2 Why it matters

If a user comes back and sees `0 / 1 resolved` they'll think the card is still actionable and might click again — a **double-action vector** even though §7.4 dedup should catch it.

### 6.3 Relationship to §5

Closely related to / dependent on Stage 3. If §5's fix lands and dismiss stops mutating engine state, the render/engine drift may also disappear. **Worth checking after §5 lands rather than fixing speculatively.**

### 6.4 The renderer contract (for the larger expansion)

Post-action UI state derives from the engine response, **never** hand-maintained locally. Acquiring stale state should always be a re-fetch, not an in-memory patch. Probably auto-fixed by fixing §5 but worth pinning as a principle.

### 6.5 Filing guidance

- **Title:** "Inbox renders `0 / 1 resolved` after engine has resolved the dossier — render state vs. engine state drift"
- **Priority:** P3. **Type:** bug. **Label:** `runner-reliability`. **No `human-triage`.**
- Consider waiting until Stage 3 lands and re-checking; may auto-resolve.

### 6.6 RESOLVED — re-checked post-L1 (claude-tools-uxa2, 2026-06-07)

Audited after the §5/L1 interaction fixes landed. The drift was **auto-fixed and
is now structurally impossible**: post-action UI state derives entirely from a
RE-FETCH of the §4 record (`app.js refetchAck`/`loadDossier`), never an in-memory
patch. The "N / total resolved" DOM (`progN`) is written in exactly ONE place —
`recount()`, off `curView.items[].terminal` (engine-derived) + staged `formState`
(reset on every re-fetch); `curView` is assigned only by `loadDossier` from
`deriveDossierView` of a fresh GET; the render core is pure (no fetch/exec, no live
state to drift). The §6.4 contract holds. **Regression-locked** by the
`claude-tools-uxa2` section in `beads-runner/lib/test-inbox.sh` (the SAME pure
derive, fed the pre- vs post-resolution engine record, yields `0/1` then `1/1` —
the count moves only because the record moved). No code fix was needed.

---

## 7. Stage 5 — Closure: when a dossier no longer matters, it leaves

**Source:** `tmp/changes.md` Appendix D in full.

### 7.1 The goal

The Inbox (Board → "waiting on you") should contain ONLY things that genuinely need Brian's attention. Today, dossiers persist past their usefulness because the dossier lifecycle is decoupled from the bead lifecycle. We need an automatic mechanism so that when a bead is closed, unblocked, or otherwise resolved outside the dossier-tap path, the corresponding dossier items get marked terminal (`applied` or `expired`) and drop off the Inbox without a human tap.

Direct application of the project North Star: **"a child closes on what Brian experiences."** Stale cards on the Inbox = the surface is lying.

### 7.2 The problem concretely

The CF engine stores dossiers in D1 (`type='dossier'`). The `waiting_on_you` projection (in `beads-runner/cf/src/reconcile.js:476-516`) filters dossiers to those with ≥1 non-terminal item (state ∉ {`applied`,`expired`}). A dossier drops from the Inbox only when every item reaches a terminal state.

Terminal states reachable today:

1. `item-apply` with deterministic response (decision ∈ {`pick`,`approve`,`reject`}) — Brian taps. Item → `applied`.
2. `item-set-state ... expired` — manual admin call (used this session to clear smoke/probe fixtures).
3. Timer expiry (`timer_fire_at` on `timed-fyi`) — auto-expire after deadline.

There is NO mechanism observing bead-side state changes (`bd close <id>`, `bd update --status=open`, etc.). So:

- A bead closed directly by Brian (`bd close hangoutsBackend-c0b` — exact case this session).
- A bead's blocker self-resolves (worker retries and succeeds without revisiting ask-brian).
- A bead deferred or re-scoped manually.

In all three cases the dossier sits on the Inbox forever asking a dead question. Brian had to manually call `item-set-state … expired` on `hangoutsBackend-c0b` — UX equivalent of admitting the surface is broken.

### 7.3 Why this is structural, not cosmetic

S-2 reconcile (in `beads-runner/cf/src/stuck.js`, mirrored in `beads-runner/lib/stuck-routing.sh`) goes ONE direction: the `stuck_bfh` engine record re-asserts `status=blocked` + `human` label on the bead. There is no work→control path; bead state changes do not flow back to the dossier.

### 7.4 What was ruled out this session

**Render-time filtering in `waiting_on_you`.** Tempting (just hide dossiers whose bead is closed) but violates "the renderer is deliberately tolerant; the write gate is authoritative" (memory `4xe-write-gate-render-tolerance.md`). Filtering on render masks the lifecycle bug instead of fixing it.

### 7.5 Four design options (cheapest → most correct)

**Option 1 — Engine-side cron, polls bd remotely.** Engine cron scans `waiting_on_you`; for each dossier, calls back to the workspace's runner endpoint to ask the bead's current status; expires items whose bead is `closed` or no longer `blocked`/`human`.

- ✅ One place to own the logic; works for offline daemons (engine drives read).
- ❌ Requires a new outbound `bead-status-get` endpoint on each runner; lag = poll interval; engine has to know how to reach every workspace.

**Option 2 — Daemon-side push, reuse machine_state telemetry (RECOMMENDED).** Per-workspace daemon already polls bd and publishes `machine_state` (commit `4460d50` "D2 machine_state telemetry — daemon publisher + engine ingest"). Extend the publisher: when a bead with an open dossier transitions, emit `bead-status-changed` over the same channel. Engine handler looks up open dossier items for that `bead_ref` and expires them.

- ✅ Reuses zdxd's auth/principal/transport — minimum new infra; event-driven (~30s lag = poll interval); daemon already reading bd.
- ❌ Doesn't cover beads whose workspace daemon is offline (but: offline daemon ≡ bead can't be making progress, so the gap is mostly fine in practice).

**Option 3 — bd close/update hook.** Hook in the bd plugin surface that fires on `bd close` / `bd update --status=` and POSTs `bead-status-changed` directly. Could live alongside the existing `.beads/runner.sh` allowlist machinery.

- ✅ Zero lag; works without any daemon.
- ❌ Needs hook infrastructure in bd (or CLI wrapper); SECOND source of truth alongside Option 2 — risk of double-fire and contradicting decisions. Useful as future hardening on top of Option 2, not as primary mechanism.

**Option 4 — Lazy reconciliation in work-snapshot.** When CF.3 builds `waiting_on_you`, inline call `bd status` for each waiting dossier's bead and silently filter/expire.

- ✅ Zero new infra.
- ❌ Couples Board render latency to N bd reads; multi-workspace problem (CF needs to reach every workspace); violates the "no-reader-write-path" invariant at `reconcile.js:475` ("CF.3 never produces or interprets Dossier body/items"). Likely a contract violation.

### 7.6 Concrete tasks (Option 2 path)

1. **Engine op: `bead-status-changed`.** New CF op taking `{bead_ref, status, blocked, human_label}`:
   - Look up dossiers where `bead_ref = ?` and ≥1 item is non-terminal.
   - Items in state `open` → transition to `expired` (legal per `open→expired` in `dossier.js` `stateCheck`).
   - Items in state `answered` → transition to `applied` (preserve the recorded decision).
   - Emit one record per transition for audit.
   - Schema: add to `DOSSIER_OPS` in `beads-runner/cf/src/dossier.js:69`; mirror in `beads-runner/lib/coordinator.sh`.

2. **Daemon publisher: emit `bead-status-changed`.** In the publisher that emits `machine_state` (added by zdxd D2 in `beads-runner/daemon/`), add a per-poll diff: for each bead with an open dossier (engine tells daemon via `machine_state` response, or daemon caches an "open-dossier bead_refs" list from last `work-snapshot`), if bd-side status crossed `blocked→open` or `*→closed`, or `human` label removed, publish the event.

3. **Decision-vs-expiry policy.** Bead closed-WITHOUT-decision (the `hangoutsBackend-c0b` case) → items `expired`. Bead unblocked because worker satisfied the fork otherwise → also `expired`. The `applied` path stays reserved for explicit human decisions via the Inbox tap. Reason: `applied` triggers consequence-block apply (`dossier.js:779-795`); auto-applying without a human decision would be wrong on the audit plane.

4. **Idempotency.** Daemon publisher MUST be idempotent — duplicate `bead-status-changed` events for the same `(bead_ref, status)` tuple should be no-ops on the engine side. Existing item state machine is monotonic (INTERFACE.md v1 §4.1.1/§5.2) so re-expiring is naturally rejected; just make the engine return `{ok:true, idempotent:true}` rather than a hard `rej`.

5. **Multi-workspace coverage.** Each workspace's daemon publishes for its own beads. Engine never tries to reach into a workspace it doesn't have telemetry from. Beads whose daemon is offline stay stuck on the Inbox until the daemon comes back — acceptable trade.

### 7.7 Suggested first bead

```
bd create \
  --title="Auto-close dossiers when underlying bead resolves outside the dossier flow" \
  --description="See docs/inbox-lifecycle.md §7 (and tmp/changes.md Appendix D). Implement Option 2: daemon-side push via the zdxd D2 machine_state channel; new engine op 'bead-status-changed' that expires/applies open dossier items for the affected bead_ref. Phased: (1) engine op + tests, (2) daemon publisher, (3) end-to-end test with a real bead-close." \
  --type=feature \
  --priority=2
```

Then break into the four sub-tasks above.

### 7.8 Open questions

- **Q1.** When a bead is `closed` with status `wont_fix`, items `expired` or `applied`? **Recommended: `expired`.** Audit trail reflects "bead was abandoned," not "human ratified abandonment via the dossier."
- **Q2.** What about beads `closed` whose dossier had a `decide` item with `consequence_block` listing `creates: [...]`? Auto-expiring skips those creates. Right call? **Recommended: yes** — bead closed means the human chose not to take that path, regardless of which option's CB it was.
- **Q3.** Should the engine emit a notification (§4.3) when it auto-expires a dossier? **Recommended: silent for now**; audit log row only. The whole point is reducing noise.

### 7.9 Gotchas discovered this session

- **`item-apply` only takes the deterministic path when `decision` is exactly `"pick"`, `"approve"`, or `"reject"`.** Anything else (option ids, `"acknowledge"`, etc.) routes through the §5.2.2 reconciler, which CLONES the dossier into `<did>-fu-<iid>` with the item carried in `state=open`. This session: first apply created 3 clone dossiers; second apply with `{decision:"pick", selected_option_id:"opt-3"}` finally went through. Whatever the new `bead-status-changed` op does, it must NOT route through `item-apply` for the auto-close case (use `item-set-state` directly).

- **The write gate refuses v1 dossiers.** `validateEnvelope` rejects `schema_version: 1` with no override flag. If `bead-status-changed` finds a v1 dossier (one historical, `dSPINE`, was deleted by direct D1 DELETE this session), it must skip rather than crash. Or separately add a v1-purge pass.

- **Cross-workspace dossiers exist.** The Inbox shows dossiers from `claude-tools`, `thirsty`, `hangoutsBackend` (and more). Fix has to be daemon-local but cross-workspace overall.

- **S-2 reconcile path is ONE-WAY (control→work).** Adding the inverse (work→control) does NOT mean reusing S-2's machinery — it's deliberately one-direction. The new flow is a NEW reconciler.

### 7.10 What was cleaned up this session (don't redo)

This session reduced the Inbox from 19 → 2 cards:

- 12× `item-set-state … expired/applied` on smoke/probe/fix test fixtures.
- 1× direct D1 DELETE of `dSPINE` (v1 schema; write-gate refused). Command: `wrangler d1 execute coordinator-records -c wrangler.production.toml --remote --command "DELETE FROM records WHERE type='dossier' AND id='dSPINE';"`.
- 3× legitimate decisions applied: `analysis-thirsty-4vfi` (approve), `stuck-claude-tools-fyx` (pick C — workspace-only patch + file bd upstream + keep cascade for ir7), `stuck-claude-tools-0wu` (pick A — restrict stuck-restart to all-open items).
- 1× `item-set-state … expired` on `stuck-hangoutsBackend-c0b` (the case motivating this whole design).

### 7.11 Remaining cards on the Inbox

Need the new auto-close mechanism OR a manual tap:

- `stuck-claude-tools-7xl` (2026-05-24, real).
- `stuck-thirsty-9wgz` (2026-05-20, real, different workspace).

### 7.12 Key files for Stage 5

- `beads-runner/cf/src/dossier.js` — Dossier op surface. Lines: `DOSSIER_OPS` set (69), `validateEnvelope` (138), `stateCheck` (524 — legal item transitions: `open→answered→applied | open→expired`), `isDeterministic` (539 — gate for §5.2.2 apply-vs-reconciler split), `itemApply` (737), `itemSetState` (816 — admin-only poke we used), `emitFollowup` (689 — generates `-fu-` clones).
- `beads-runner/cf/src/reconcile.js:476-516` — `waiting_on_you` projection.
- `beads-runner/cf/src/stuck.js` — S-2 control→work reconcile (existing direction).
- `beads-runner/daemon/` — per-machine daemon; zdxd D2 publisher is the channel to extend.
- `beads-runner/cf/wrangler.production.toml` — DB id `c80f8fb8-da0c-40b1-8051-70ff4ec5dd51`. Plain `wrangler.toml` has a fake local placeholder; production ops need `-c wrangler.production.toml`.
- `docs/runbooks/manual-dossier-tools.md` — manual builder/upload runbook.
- `docs/runbooks/inspect-engine-records.md` — read-side ops (work-snapshot, get, etc.).
- `docs/runbooks/reset-stuck-bead.md` — existing precedent (`stuck-resolve` + `stuck-reconcile`).

---

## 8. Runner-plane foundation

Three reliability issues sit underneath the Inbox lifecycle. They don't fit the 5-stage frame but they cause Inbox symptoms.

### 8.1 Queue starvation — `claude-tools-dzc` (FILED, P1)

**Source:** `tmp/changes.md` Appendix A §1 and §2.

**Symptom:** `claude-tools` runner (PID 26420 at the time) was looping with 158 epic-skip cycles in a single detached log (`detached-20260524T003251Z.log`). Top of `bd ready` was two P2 epics (`claude-tools-1y0`, `claude-tools-ir7`); the runner picked the top each cycle, `validate_task` returned 1 (epic = not workable), `SKIP_BACKOFF` slept 30s before re-querying — which returned the same epic. Queue starved, runner alive but doing nothing.

**Root cause:** `next_task()` at `beads-runner/run-beads-tasks.sh:609` calls `bd ready --json` with no epic filter, even though `bd ready --help` documents `--exclude-type=epic` natively.

**Prior fix `claude-tools-g20` (commit `5981fec`)** added `hb idle + SKIP_BACKOFF` — stopped the hot-spin CPU burn but did NOT add "advance past unworkable top-of-queue." Queue still starved, just more politely.

**The fix is one line at `beads-runner/run-beads-tasks.sh:609`:**

```diff
-  bd ready --json 2>/dev/null || echo "[]"
+  bd ready --exclude-type=epic --json 2>/dev/null || echo "[]"
```

Keep the application-layer `validate_task` epic check at line ~665 as defense-in-depth.

**Why this is safe for the autonomous runner to fix itself:** bash slurps long-running top-level scripts into memory at startup. Editing `run-beads-tasks.sh` mid-run does NOT affect the running process. Worker is a child of the running runner, can freely Edit + git commit + close in one cycle. Patched line activates on NEXT runner restart (operator stop+relaunch, daily cron, or `touch .stop-beads` graceful stop). No `kill`/`restart` from the worker.

**Cross-workspace impact:** ALL three live runners (`claude-tools`, `thirsty`, `hangoutsBackend`) execute the SAME script — `/Users/brianbutler/code/claude-tools/beads-runner/run-beads-tasks.sh`. Confirmed by `ps` on each workspace's `detached-runner.pid`. One fix covers all three. (`inviterProject/hangouts/android/run-beads-tasks.sh` is a stale unrelated copy; ignore.)

**Related queue-shaping done this session:** `claude-tools-1y0` was demoted P2 → P3 to push it below workable P3 tasks so the runner can advance while `dzc` waits to land. Purely queue-shaping, no code change implied.

### 8.2 Task-close discipline — TASK_NOT_CLOSED dominates thirsty

**Source:** `tmp/changes.md` Appendix A §3 bead 2.

**Why it's worth filing:** TASK_NOT_CLOSED is the #1 failure mode in thirsty by a wide margin (124 vs. 13 of the next most common). Top per-bead offenders: `thirsty-hs88` (7), `thirsty-vefd` (6), `thirsty-hs88.2` (5), `thirsty-gwq5` (5), `thirsty-8zrk` (5). Smaller volumes in claude-tools (39) and hangouts (2).

**Pattern:** agent finishes work without calling `bd close`. The runner classifies this and retries, burning cycles.

**Filing guidance:** P2 or P3, type=bug, label=runner-reliability. **No `human-triage`.** File in `claude-tools` (runner code lives here) since it's a cross-workspace problem rooted in shared runner behavior.

**Suggested title:** "TASK_NOT_CLOSED dominates thirsty (124 incidents) — agents finish work without calling bd close"

**Investigation pointers:**
- Grep `TASK_NOT_CLOSED` in `beads-runner/run-beads-tasks.sh` — main sites at line ~714 (classifier) and ~1934 (per-task handler).
- Look at one of the top offenders (`thirsty-hs88`) — `bd show` its notes/history.
- Investigation angles:
  1. Closing-protocol prompt reinforcement (does the worker prompt clearly tell the agent it MUST call `bd close` to terminate?)
  2. Could the runner auto-classify "committed code AND task still open" as a softer terminal state and auto-close it after some safety check?
  3. Could a `PostToolUse` hook on `git commit` check for an unclosed bead and warn the agent?

**Cross-reference:** the open bead `claude-tools-0wu` is the "stuck-restart op" feature — its own NOTES show 5 self-attempts each hit TASK_NOT_CLOSED, so this pattern affects beads designed to address related problems. The fix for `0wu` is blocked partly by this same issue.

### 8.3 Cross-process ownership — runner adopts external in_progress

**Source:** `tmp/changes.md` Appendix C in full.

#### 8.3.1 The bug

**Symptom:** an interactive (non-runner) Claude session creates a bd task, sets it `--status=in_progress`, and starts working. The beads-runner later picks the same task up — duplicates work, fights the live agent over commits.

**Root cause** in `beads-runner/run-beads-tasks.sh:599-605` (`ORPHANED_IDS` snapshot at startup) + `:608-630` (`next_task()` drains orphans before consulting `bd ready`). `BEHAVIORAL-CONTRACT.md` `BC-02`/`BC-04` document this design and explicitly admit the residual: *"the two-runners-one-orphan race is residual and unguarded."*

The lease seam at `:257-265` was *designed* to close this (`AD2.1`) but there is no `lease` binary on `PATH` anywhere — `command -v lease` returns false → `lease_acquire_ok` always returns 0. **Lease protection is dormant.** CF-side machinery exists (`co__lease_release`, `cf/src/lease.js`) but no client.

The one working defense today is `RUNNER_NO_CLAIM_LABELS` at `:86, :660-676` — refuses tasks carrying `human-live-session` / `human-triage` / `human-action`. Mechanism B below leans on this gate.

#### 8.3.2 Why a simple age-based fix doesn't work

The naive fix is "only adopt in_progress tasks where `updated_at` is older than threshold N." This can't simultaneously satisfy "fast crash recovery" and "never steal from a live but quiet agent" because `updated_at` is a passive signal.

- **Tight threshold (e.g., 30 min):** long-running interactive agent deep in a tool call gets adopted while alive. `mcp__askbrian__ask-brian` waits up to 6h on Brian's phone (`.beads/runner.sh` `IDLE_TIMEOUT=21600` is wired for this); code-reviewer subagent runs 5-15 minutes; context-heavy synthesis can exceed 30 minutes.
- **Loose threshold (e.g., 2h):** a crashed worker (context overflow exits `claude -p` immediately) waits 2h before the runner notices. Exactly the latency orphan recovery is trying to fix.

`updated_at` doesn't measure liveness, only activity. Need an active liveness probe.

#### 8.3.3 Mechanism A — PID-based claim files

**Purpose:** distinguish "this runner's crashed worker" (adopt instantly) from "another live runner's in-flight task" (skip).

**Design:**

- When the runner sets `bd update --status=in_progress` (`run-beads-tasks.sh:1512`), also write:
  ```
  .beads/runner-logs/claims/<task-id>.json
  { "runner_id": "<la_runner_id>", "pid": <$$>, "host": "<hostname>", "started_at": "<ISO8601>", "workspace": "<PROJECT_REF>" }
  ```
  Use `la_runner_id` / `la_principal` from `lib/local-agent.sh` for workspace identity. Use the script's `$$` (the runner PID), not the child `claude-p` PID — runner is what we're asking "are you alive?"
- Remove the claim file on (a) task close success path, (b) `cleanup()` SIGINT/SIGTERM trap (`:378-407`), (c) `_final_subshell_reap` EXIT trap (`:131`).
- Replace snapshot logic at `:599-605` with claim-file walk:
  1. List `in_progress` tasks as today.
  2. For each, check `.beads/runner-logs/claims/<id>.json`:
     - **No claim file** → set in_progress by something other than a runner (interactive session, manual `bd update`). **DO NOT adopt.** Mechanism B's label gate handles it; Mechanism C's sweep catches stragglers.
     - **Claim file with our `runner_id` + alive PID** (`kill -0 "$pid"`) → another instance of this workspace's runner is alive. Skip.
     - **Claim file with our `runner_id` + dead PID** → our previous self crashed. Adopt instantly. Remove stale claim file.
     - **Claim file with a different `runner_id`** → another workspace's runner. If coordinator reachable, call `work-snapshot` (`cf/src/reconcile.js:643-720`) to check liveness; if `live` (within STALE_AFTER), skip; if stale, adopt and remove the foreign claim. If coordinator unreachable, default skip (DEGRADED-CLOSED, matches `lease_acquire_ok`'s design intent at `:251-253`).

**Why claim files, not the existing `current-task` pointer at `:1511`:** `current-task` is a single string per workspace, doesn't survive crash (wiped at `:339`), no PID. Claim files are per-task JSON, durable through crashes (cleanup trap removes on clean exit but crash leaves them — presence is the crash signal). Under `.beads/runner-logs/` they inherit `.gitignore` + `LOG_RETENTION_DAYS` rotation.

**Failure modes:**
- *PID reuse:* include `started_at`; compare against `ps -o lstart= -p $pid`. Optional refinement — even without it, "alive PID we didn't track" defaults to skip (safe direction).
- *Filesystem race on simultaneous close:* `rm -f` is idempotent. Acceptable.
- *Workspace identity drift:* match on `workspace`/`PROJECT_REF` as a backstop, not just `runner_id`.

**Patch sites:**
- `:1512` — after `bd update --status=in_progress`: write claim file.
- `:1769` (per-task `in_progress`→close transition; any post-close success path) — remove claim file.
- `:380-388` (`cleanup()` SIGINT/SIGTERM): remove claim file for `CURRENT_TASK_ID`.
- `:131-139` (`_final_subshell_reap` EXIT trap): same, idempotent.
- `:599-605` — replace snapshot with claim-file walk.
- `:614-628` — keep `bd show` recheck as defense-in-depth.

#### 8.3.4 Mechanism B — PreToolUse hook for `bd update --status=in_progress`

**Purpose:** when a non-runner agent sets a task in_progress, auto-attach `human-live-session` so the existing `RUNNER_NO_CLAIM_LABELS` gate catches it without depending on the agent remembering.

**Design:**

- New PreToolUse hook on Bash matching `bd update * --status=in_progress` and `bd update * --claim` (verify against `bd update --help` and `beads:update` skill semantics — `--claim` sets the same state).
- Hook detects "am I inside the runner?" via env. Runner exports `RUNNER_PID=$$` near `:309` (state-block). Presence ⇒ pass through unchanged. Absence ⇒ interactive Claude session ⇒ run `bd label add <task-id> human-live-session` then exit 0 (allow original `bd update` to proceed).
- Runner does NOT strip `human-live-session` from tasks it owns — label survives once applied. Correct for live external work. Mechanism C sweep handles stranded labels.

**Files:**
- New hook: `beads-runner/hooks/auto-label-live-session.sh`.
- Wire into project settings.json as PreToolUse Bash matcher with regex `^bd update .* --status=in_progress( |$)` OR `^bd update .* --claim( |$)`.
- Verify `RUNNER_PID` propagation: `grep -n "env -i\|env -u" beads-runner/run-beads-tasks.sh` — if anything strips env, pass `RUNNER_PID` explicitly via `EXTRA_CLAUDE_FLAGS` or spawn site.

**The critical test case:** if `RUNNER_PID` doesn't reach the spawned `claude` child's env, runner-owned tasks get auto-labelled and the runner refuses its own work — instant deadlock.

> **IMPLEMENTATION NOTE (claude-tools-n6ek, shipped on the v2 `runner.sh`):** the
> `RUNNER_PID` framing above is the v1 plan. On the v2 runner the
> runner-identity marker is **`BEADS_RUNNER_SESSION=1`** (set as a command-prefix
> env on `claude -p` at `runner.sh:2121`) plus **`CURRENT_TASK_ID`** (exported at
> `runner.sh:2006`) — both already reach the worker AND its PreToolUse hook
> subprocesses (the same `BEADS_RUNNER_SESSION` marker `close-checklist.sh:101`
> relies on), so **no new `RUNNER_PID` export was needed**. The hook
> (`auto-label-live-session.sh`) passes through with NO label when EITHER is
> present; detection is env-ONLY (it deliberately does not read the
> `current-task` file, which would false-positive interactive sessions in a
> workspace where the runner ever ran). For the §8.3.7 test, "set the runner
> marker, exec" means `BEADS_RUNNER_SESSION=1` / `CURRENT_TASK_ID=<id>`, not
> `RUNNER_PID`.

#### 8.3.5 Mechanism C — Triage sweep for stranded `human-live-session` tasks

**Purpose:** catch edge case where an interactive agent crashes (machine reboot, Claude Code quit) leaving a task `in_progress + human-live-session`. Runner refuses by label; task would otherwise rot forever.

**Design:**

- Periodic sweep (`/loop` skill cron, `/schedule`, or piggybacked on `lib/timed-fyi.sh` cadence) that:
  1. `bd list --status=in_progress --label=human-live-session --json`.
  2. For each, check claim file + coordinator heartbeat + `updated_at`.
  3. If clearly stranded (no claim file, no live heartbeat, no recent activity over ~4h), file a triage bead asking a subagent to either reopen (clear label) or close (work was finished).
- Implementation: standalone `beads-runner/sweep-stranded-live-sessions.sh`. Ship the script; scheduling can come later.
- Triage subagent's filed bead has NO `human-triage` label (per §11 labelling principle). If subagent is genuinely unsure, files a follow-up `human-action` bead — that's the warranted use.

> **IMPLEMENTATION NOTE (claude-tools-uxc3, SHIPPED):** the standalone
> `beads-runner/sweep-stranded-live-sessions.sh` exists with three verbs:
> `sweep` (find + file a triage bead per new strand), `scan` (dry-run, files
> nothing), `list` (machine-readable stranded ids). Exit 0 = clean, 1 = at
> least one stranded found (a scheduler signal, not an error). It NEVER mutates
> the stranded bead (the hard C-3 invariant); the triage bead it files carries
> the audit data + a `STRANDED_TASK=<id>` dedup marker, the
> `stranded-live-session-triage` label, a non-blocking `discovered-from` dep
> back to the strand, and NO `human-triage`. Two deliberate refinements of the
> step-2/3 wording above: (a) "no claim file" is read as **no LIVE claim** — a
> stale dead-pid Mechanism-A claim is itself a crash signal, so it still counts
> as stranded (its details are captured as audit data, not used to skip);
> (b) **coordinator heartbeat is NOT consulted** — the live work-snapshot tracks
> runner, not interactive-session, liveness and is offline-unsafe here, so the
> sweep gates on the two robust offline signals (claim liveness + `updated_at`
> staleness, default `STRANDED_STALE_HOURS=4`) and records the coordinator
> cross-check as a follow-up, the same posture uxc1 took for §8.3.3
> cross-workspace liveness. Regression test: `test-sweep-stranded-live-sessions.sh`
> (`top` tier). Scheduling remains unfiled (the C-3 stretch goal).

#### 8.3.6 Edge cases the (A)+(B)+(C) stack handles

| Scenario | Handled by | Outcome |
|---|---|---|
| Runner crashed mid-task (context overflow, SIGKILL, OOM) | (A) PID check | Stale claim file, dead PID → adopted on next startup. No latency. |
| Runner crashed AND machine rebooted | (A) PID check | New PID space; old PID definitely dead → adopted. |
| Two runners launched in same workspace (rare race) | (A) PID check | Second runner sees alive PID, skips. No double-claim. |
| Interactive agent in another Claude session sets in_progress | (B) PreToolUse hook | `human-live-session` auto-applied; gate refuses on every loop. |
| Interactive agent crashes/closes window mid-task | (B) leaves label stranded; (C) sweep | Worst case: task waits hours for cleanup, never duplicated. |
| Manual `bd update --status=in_progress` from terminal (Brian) | (B) hook fires same way | Auto-labelled. Brian lifts manually if he wants the runner to pick it up. |
| Cross-workspace runner already working on the task | (A) foreign claim file + optional `work-snapshot` | Skip if alive; adopt if coordinator says stale; degraded-closed offline. |
| `bd close` interrupted between status flip and bd write | claim file cleanup in `cleanup()` trap | File removed; next startup correctly doesn't adopt a closed task. |
| **CRITICAL:** Hook in (B) misfires inside the runner (env not passed) | RUNNER_PID propagation | Runner-owned tasks auto-labelled, runner refuses own work — instant deadlock. **Most important test case.** |

#### 8.3.7 Test plan

**Mechanism A (claim files):**
- Unit-level: temp dir, run `run-beads-tasks.sh` against synthetic bd shim, `kill -9` mid-task, relaunch, observe orphan adopted.
- Two runners same workspace: second declines because first's PID is alive.
- Forge foreign claim file: declined when coordinator says foreign runner live; adopted (and foreign claim removed) when stale or coordinator absent.
- Add conformance assertion under `beads-runner/conformance/assertions/` mirroring BC-02/BC-04 fixtures. Draft BC amendment in `BEHAVIORAL-CONTRACT.md`: "startup snapshot = PID-validated orphans; tasks without my claim file are NOT my orphans."

**Mechanism B (hook):**
- `bd update <id> --status=in_progress` in plain Claude session, no `RUNNER_PID` in env → bead acquires `human-live-session`.
- Same call from inside a runner-spawned worker (set `RUNNER_PID`, exec) → NO label added.
- Verify label gate at `:660-676` still skips labelled task in normal runner loop.

**Mechanism C (sweep):**
- Seed `in_progress + human-live-session` with no claim file, `updated_at` 6h ago → sweep files triage bead, original untouched.
- Same with `updated_at` 5 min ago → no triage bead (still live).

#### 8.3.8 Out of scope this round

- **Activating the lease.** Bigger lift; (A)+(B) stack covers practical failure modes. File a separate epic if multi-workspace coordination needs further hardening.
- **Modifying `bd ready` or beads core to filter in_progress differently.** Beads' own semantics (in_progress hidden from `bd ready`) are correct; bug is in the runner's orphan-recovery layer.
- **Anything in `beads-runner/web/**`.** Patches don't touch web code.

#### 8.3.9 Suggested beads (no `human-triage`)

All autonomous-claim-eligible. File in `claude-tools`.

**Bead C-1 — Mechanism A: PID-based claim files**
- **Title:** "Runner adopts in_progress tasks owned by live external agents — add PID claim files to validate orphans before adoption"
- **Type:** bug. **Priority:** P1 (active duplicate-work hazard). **Labels:** `runner-reliability` only.
- **Description:** Symptom from §8.3.1; cite `:599-605` and `BC-04` residual. Link to this section.
- **Acceptance:**
  - Claim file written at `bd update --status=in_progress` in runner path; removed on close / cleanup / EXIT trap.
  - Startup orphan adoption uses claim-file walk, not wholesale snapshot.
  - `kill -0` liveness check; `started_at` PID-reuse mitigation is stretch goal.
  - New conformance assertion: no claim = skip, claim+alive = skip, claim+dead = adopt.
  - `BEHAVIORAL-CONTRACT.md` BC-02 sub-clause or new BC amendment.

**Bead C-2 — Mechanism B: PreToolUse hook**
- **Title:** "PreToolUse hook auto-applies `human-live-session` when a non-runner agent sets bd in_progress"
- **Type:** bug. **Priority:** P2. **Labels:** `runner-reliability`. Cross-link to C-1.
- **Acceptance:**
  - Hook script in `beads-runner/hooks/`, wired via project settings.json.
  - `RUNNER_PID=$$` exported by `run-beads-tasks.sh` near `:309`, verified to reach the spawned `claude` child's env (the critical test case).
  - Hook applies label on `bd update --status=in_progress` and `--claim` when RUNNER_PID absent; pass-through when present.

**Bead C-3 — Mechanism C: triage sweep for stranded live-session tasks** *(SHIPPED: claude-tools-uxc3 — see the §8.3.5 implementation note)*
- **Title:** "Periodic sweep files triage for stranded `human-live-session` tasks (interactive agent crashed)"
- **Type:** task. **Priority:** P2. **Labels:** `runner-reliability`. Cross-link to C-2.
- **Acceptance:**
  - Standalone `beads-runner/sweep-stranded-live-sessions.sh`.
  - Files a triage bead with audit data (last activity, claim file state, coordinator state); does NOT itself flip status or clear labels.
  - Scheduled invocation can be a stretch goal; ship script first.

---

## 9. Orthogonal items (preserved, don't fit the frame)

### 9.1 Runner-log incident counts and recently-fixed bugs

**Source:** `tmp/changes.md` Appendix A §1.

Incident type counts (all time, per workspace) from `${workspace}/.beads/runner-logs/incidents.log`:

| Workspace | TASK_NOT_CLOSED | UNKNOWN_FAILURE | exceeded_max_retries | DOSSIER_FALLBACK | STUCK_NEEDS_HUMAN | Other |
|---|---|---|---|---|---|---|
| claude-tools | 39 | 55 | 22 | 6 | 2 | RATE_LIMIT×4, STUCK_AUTOFLIP×2 |
| thirsty | **124** | 13 | 5 | 1 | 2 | TOOL_ERROR:subagent×20, WATCHDOG_KILL×1, RATE_LIMIT×1 |
| hangouts | 2 | 1 | 0 | 1 | 1 | STUCK_AUTOFLIP×1 |

Recently fixed (closed beads, no log recurrence — **do NOT re-file**):

| Bead | Commit | What it fixed in logs |
|---|---|---|
| `claude-tools-g20` | `5981fec` | Hot-spin on epic skip (residual = `dzc` in §8.1) |
| `claude-tools-h7n` | `a656293` | Watchdog killing on empty ACTIVITY_FILE |
| `claude-tools-yva`, `claude-tools-8mb` | `9254a21`, `6fd2d21` | TAIL/WATCHDOG subshell leaks (PG-isolation + SIGTERM reap) |
| `claude-tools-7v5` | `c4bfd20` | Mid-task HB so long tasks don't false-stale on the Board |
| `claude-tools-qxz` / `3gg` storm | various | 20+ UNKNOWN_FAILURE chain — MCP registration mismatch |
| `claude-tools-giu` | `1e84fe1` | Runner exiting instead of idling on empty queue |

### 9.2 Deliberately skipped (do NOT file)

**TOOL_ERROR:subagent-unavailable: code-reviewer (thirsty).** 20 incidents, all dated 2026-05-02 and 2026-05-03, zero recurrence since. Self-resolved (likely subagent registration drift fixed by an update). Filing now would just add noise.

### 9.3 Ambiguous — investigate before filing

**"FEEDBACK RETURN ... reconciled 1 blocked-for-human bead(s)" appears every skip loop.**

In `claude-tools/.beads/runner-logs/detached-20260524T003251Z.log`, every skip-loop iteration (158 of them) logged:

```
FEEDBACK RETURN (§7.3/S-2/I4) [M4 daemon-owned]: reconciled 1 blocked-for-human bead(s) — the daemon captured the answer continuously; this loop top just lifted the bead to open so the splice below resumes the agent with the decision.
```

Code at `beads-runner/run-beads-tasks.sh:1116`. Two interpretations:

1. **Real bug:** the same bead is being lifted to `open` every loop and the daemon is re-flipping it back to `blocked-for-human` between loops. Visible as a single bead with rapid status churn in bd history.
2. **Cosmetic:** the counter `${SR_LIFTED:-0}` is misreported (always "1" regardless of actual lifts). Just log noise.

**Investigation before filing:** Pick the bead ID this is reconciling (instrumentation may be needed; or check daemon log at same timestamps). If the same bead ID repeats across all 158 lines → real bug, file. If varied / inactive → cosmetic; consider filing a P4 "tighten log message" or leave it.

### 9.4 Related open beads (don't duplicate)

Already-filed beads that touch adjacent seams:

- `claude-tools-kct` (P3) — Investigate `rate_limit_event` stream events in runner logs (up to 19 events in a single thirsty log; 14 in claude-tools). Recommended exposing as distinct phase in heartbeat parser.
- `claude-tools-0wu` (P3) — Dedicated `stuck-restart` op. Blocked partly by §8.2 (TASK_NOT_CLOSED kept failing its own attempts).
- `claude-tools-7my` (P3, runner-reliability) — Empirically pin `bd ready` ordering. Doc-only; closes cleanly if `dzc` (§8.1) lands.
- `claude-tools-507` (P3, runner-reliability) — Verify `next_task()` doesn't filter on assignee. Doc-only; closes cleanly if `dzc` lands.
- `claude-tools-g2s` (P3) — Board soft "thinking" visual state 90-180s heartbeat age. Child of demoted `1y0` epic.
- `claude-tools-u4ms` (P1, still open) — Exclude `.beads/issues.jsonl` from the post-close `dirty_tree` audit. Fix locations: `beads-runner/hooks/close-checklist.sh:259-261` and `beads-runner/run-beads-tasks.sh:1127-1129`. Pattern caused 9 false-positive discipline-bypass cascades in rhythmGame overnight.

### 9.5 Intake-pipeline gaps (other than Gap B)

**Source:** `tmp/changes.md` Appendix E.7.

Surfaced this session, demoted in urgency once happy path was confirmed. Real but lower-priority than the Stage 1 work:

1. **`intake-dispatch-poll.sh` has no max-retry cap.** `beads-runner/daemon/intake-dispatch-poll.sh:356, 361` — comments say "next cadence retries". When the e5aq permission bug was live, 19 enrichers × ~$1 each burned on one intake before the fix. Need a cap + a "give up after N" state. → **DONE (claude-tools-uxvl3 / L3):** `INTAKE_MAX_ATTEMPTS` (default 3) caps it; each failed dispatch increments `dispatch_attempts`, and reaching the cap sets a terminal `gave_up:true` (the dispatch loop then skips it). The give-up + `failing(n)` states surface on the phone (item 4).
2. **`daemon_intake_parse_bd_id` parser only recognizes 3 canonical patterns** (`enricher: created|dedup|refuse`). Any other terminal state (e.g. "enricher: blocked → permissions denied") is unrecognized → record stays unprocessed → infinite retry. Add a canonical `enricher: error → <reason>` pattern + give-up path. → **PARTIAL (L3):** the infinite-retry half is closed (an unparseable summary now counts as a failed attempt and reaches `gave-up` at the cap, instead of looping forever); the `enricher: error → <reason>` happy-path parser is still unfiled (the cap is the safety net under it).
3. **Enricher cannot Read `agents/intake-presets.json`** — its prompt at `beads-runner/agents/enricher.system.md:54` instructs "Before you label, Read the catalog" but `specialist.sh:280` only `--add-dir`s the workspace (e.g. rhythmGame), not the claude-tools repo where the catalog lives. The prompt has an inline fallback table covering both current presets, so this hasn't bitten yet — but the moment a third preset ships (e.g., Gap B's `overview-dossier`), it will. Fix options: embed JSON in prompt at launch; add `--add-dir`; remove the "read catalog" instruction.
4. **No visible-to-user trace of intake state.** The 19 failed retries last night were invisible to Brian — nothing surfaced in the Board or Inbox to say "your intake is failing." Intake state needs a phone-readable surface. → **DONE (claude-tools-uxvl3 / L3):** the daemon writes the state thread onto each intake-request (`dispatch_state` ∈ received→enriching→created / failing / gave_up + `dispatch_attempts`/`last_error`/`gave_up_at`); `workSnapshot()` projects a top-level `intake[]` lane (Contract B.1 amend); the **Workspaces hub** (`web/workspaces/`) renders the per-workspace thread + a global "phone intakes failing/gave-up" leak counter. Surfaced on Workspaces, NOT the Inbox — a gave-up intake should escalate via the L4 overview-dossier path (claude-tools-uxvl4), not be faked as a dossier in the WAITING-ON-YOU lane.

### 9.6 Board lifecycle spine shows zeros

**Source:** `tmp/changes.md` Appendix E.8.

Brian's screenshot of `https://claude-wrangler.pages.dev/board/` showed `IDEA 0 / UX 0 / DESIGN 0 / IMPL 0 / DOCS 0 / TESTS 0 / DONE 0` across ALL workspaces, with most runners shown as "stale (last seen Xh ago)" — claude-tools 1h, hangoutsBackend 12h, test-canary-lv9c 3d.

Brian: *"I don't think the lifecycle spine works, but that's not related to the dossier upload machinery in any way."*

Noted so the next agent doesn't conflate them. Lifecycle-spine bug is a separate Board↔coordinator data-pipeline issue (likely affecting all workspaces' work_snapshot push, or the projection at the coordinator that derives stage counts). Out of scope for the Stage 1–5 work but explicitly real.

### 9.7 Companion source — runner log visibility findings

**Source:** `tmp/changes.md` Appendix A end-note.

`tmp/beads-log-visibility-findings.md` (written 2026-05-28). Covers: log format / tag taxonomy from `run-beads-tasks.sh:1422-1502`; stream-event distribution; **measured inter-event gap percentiles** from 3 real multi-MB logs (p50 1s, p99 40-742s, max 666-3269s in-task); concrete legitimate >60s gap examples; verdict that liveness/stuck-detection is **regex-parseable** (no LLM needed) but semantic phase ("implementing" vs "reviewing") is not; recommended heartbeat silence window of **90s soft / 180s hard** (NOT 60s — 60s would have fired ~56 false-stuck signals across the 3 logs); inter-task gap causes (dominated by `USAGE_SLEEP_SECONDS=1800`); recommended parser regex set; failure-mode shapes seen (`UNKNOWN_FAILURE.jsonl`, API retry storms, context overflow, watchdog kills); open follow-ups including `claude-tools-kct` (investigate `rate_limit_event` stream events) and an unsurveyed `incidents.log` per-project.

Preserved file on disk; don't re-derive.

---

## 10. State at handoff (2026-05-28)

**Source:** `tmp/changes.md` Appendix A §9 and Appendix B.5.

- All three workspaces' runners execute `/Users/brianbutler/code/claude-tools/beads-runner/run-beads-tasks.sh` (verified via `ps`).
- `claude-tools` runner was no longer stuck on the epic-skip loop after `1y0` was demoted — observed processing real work (86k-token cache reads in stream).
- `bd ready` in `claude-tools` after the changes:
  - Top: `claude-tools-dzc` P1 (the new bead — runner WILL pick this up next; safe per §8.1's bash-slurp note)
  - Then: `claude-tools-7my`, `claude-tools-507`, `claude-tools-kct`, `claude-tools-brz`, `claude-tools-8ag`, `claude-tools-g2s`, `claude-tools-1y0`
- `bd ready` in `thirsty` and `hangoutsBackend` was not modified this session.
- **`claude-tools-7xl` status:** as of session end (2026-05-26 ~01:14), bead is **NOT closed**. Worker on PID 79346 was re-dispatched via §5's empty-payload bug and is running on the NEW script (mtime advanced to `May 26 01:03:21 2026`, prior PID 26420 gone). Three outcomes possible: (1) worker passes probes and closes 7xl cleanly — best case, accidental dismiss-as-stale unblocked Phase B; (2) worker fails a probe and self-rolls-back per ROLLBACK PROCEDURE; (3) worker gets stuck on a different fork and files a fresh dossier. **Next agent: check `bd show claude-tools-7xl` and `ps -p 79346` first.**

---

## 11. Constraints / posture

### 11.1 The labelling principle (CRITICAL — do NOT regress)

**Source:** `tmp/changes.md` Appendix A §4.

**DO NOT reflexively add `human-triage` / `human-action` / `human-live-session` labels** (or defer) to beads just because the fix touches `beads-runner/`. Filing a bead is for it to be picked up; over-labelling defeats the point and accumulates an un-actionable backlog that clogs the queue.

Brian, verbatim:

> *"so... it can't get fixed unless I do it manually? why did you create a beads task at all then? Isn't it something that can get fixed by an agent and then I restart the runner at some point and the fix gets picked up? If I ask you to create a beads task, the whole point is for it to get picked up, so if you're just going to mark it as human-only and defer it, you should just tell me this isn't a thing that can go into beads. this is how we end up with a long backlog of beads tasks that can't be actioned and the queue gets blocked"*

And:

> *"We REALLY want this to not become a habit. Does ir7 actually require a human? are there other tasks that might have been tagged reflexively as human that are going to keep this bad habit going forward whenever an agent reads them?"*

Saved to memory at `~/.claude/projects/-Users-brianbutler-code-claude-tools/memory/feedback_beads_human_triage_label.md`.

**Why the reflex is tempting:** `claude-tools-ir7`'s epic description has a "⚠️ HUMAN-TRIAGE BEFORE RUNNER-ELIGIBLE" preamble. Easy to read as "all runner-reliability bugs need human triage." That reading is **wrong**.

**What ir7 actually meant:** only 2 of ir7's 6 children carried `human-triage`:
- `claude-tools-av7` (closed) — "runner auto-claims & auto-defers type==epic to self-stop"
- `claude-tools-ah8` (closed) — "bd ready surfaces bare epics; no in-bd dependency can hide them"

The other four (`1yt`, `fyx`, `tkf`, `vb7`) had ONLY `runner-reliability` and were auto-claimed and closed normally.

**The distinguishing property of av7/ah8:** the FIX itself interacted with the runner's live-mutating data plane (status / Deferred date) — i.e., the bug class and the patch touched the same seam the runner was actively writing while the patch needed to land. THAT's the human-triage warrant. Not "touches runner code."

**Audit results:** project-wide search for any beads with `human-triage` / `human-action` / `human-live-session` labels: **exactly ONE bead** (`claude-tools-bzc`, "live end-to-end run — HUMAN GATE" — legitimately operator-only). No backlog of reflexively-blocked beads. Don't START a habit.

**Decision rule:**
- **Default: no label, P1 if urgent, P2 otherwise.** Let the autonomous runner pick it up.
- **Add `human-triage` ONLY if** the fix itself would interact with the running runner's in-flight state.
- **If unsure: ask. Don't reflex-label.**
- If a bead truly can't be auto-claimed, don't file it as a bead at all — say so and let Brian decide.

### 11.2 Web-track close discipline

**Source:** project `CLAUDE.md`, surfaced in `tmp/changes.md` Appendix B.1 and Appendix C.6.

Any bd task touching `beads-runner/web/**` is NOT done when code is committed — it is done when the deployed Cloudflare Pages site serves the new bytes. `bd close` without a deploy is the exact failure mode that closed-but-not-shipped beads (F1/F2/F3/G1/L3) hit and that `claude-tools-bgw` exists to prevent.

Board, Inbox, and Intake are routes inside ONE unified Pages project, `claude-wrangler` (consolidation in `claude-tools-b59`). One deploy ships all three.

**Required steps before `bd close` on a web-track task:**

1. **Deploy** the unified Pages project:
   ```bash
   (cd beads-runner/web && npx wrangler pages deploy . --project-name claude-wrangler)
   ```
2. **Verify** the deploy landed — deployed bytes must match committed bytes:
   ```bash
   bash beads-runner/verify-pages-deploy.sh          # all three routes
   bash beads-runner/verify-pages-deploy.sh board    # or just one
   ```
   Passing run prints `mismatches=0`. Any `DRIFT` or `MISS` line means deploy didn't land; re-deploy and re-verify before closing.

### 11.3 Secrets handling

- **Coordinator token** lives in macOS Keychain at service `claude-beads-runner.coordinator-token`. Never hardcode, never put in agent context.
- Token-in-MCP-config security wart: production `mcp__askbrian__ask-brian` registration requires `COORDINATOR_TOKEN` via `claude mcp add -e COORDINATOR_TOKEN=...`, which lands the token in `~/.claude.json`. Same token as Keychain. Worth migrating the MCP server to read from Keychain at startup instead. Not blocking, but a real cleanup.

### 11.4 Bd discipline

- `bd` is THE task tracker. Do not use TodoWrite / TaskCreate / markdown TODO lists. `bd create` / `bd ready` / `bd close`.
- Use `bd remember` for persistent insights, not `MEMORY.md` files.

### 11.5 Git workflow

- Work is NOT done until `git push` succeeds. `bd dolt push` followed by `git push`.
- The dolt-push hint that appears on some `bd update` calls is a non-fatal warning; local update lands regardless. Pull/push at session end.

### 11.6 MCP server scope

The `mcp-askbrian` server is registered at **user scope** (`claude mcp add askbrian --scope user`) and runs in production. Changes affect every workspace, not just one. Test in isolation before pushing changes that touch the call handler.

### 11.7 "Wired but not actually live" failure-mode pattern

**Source:** `tmp/changes.md` Appendix A loose threads.

Five separate bugs in 24 hours during the rescue were the same shape: a bd task closes when code lands + local tests pass, but the live production wiring/deploy/registration is missing. User sees the feature on their phone behaving as if it never existed.

Instances:
- `claude-tools-4xe` (engine-vs-renderer conformance — earlier rescue)
- `claude-tools-2dk` (Cloudflare adapter passthrough for `set-desired`)
- `claude-tools-bgw` (Pages static-asset deploy gap)
- `claude-tools-56h` (work-snapshot projection drops user-facing fields)
- `claude-tools-qxz` (MCP tool registered but not in runner allowlist)

`bgw`'s fix includes the discipline note in §11.2. Pattern likely extends beyond web tasks — any production-touching task should probably have a probe-call acceptance gate before close. Worth a deliberate discipline conversation later.

### 11.8 Fix B over-trigger on persistent notes

**Source:** `tmp/changes.md` Appendix A loose threads.

`claude-tools-2ir` ("Fix B") relaxed `detect_worker_stuck_primary` to auto-flip `status=blocked` when an agent set the `human` label and a STUCK_NEEDS_HUMAN note but missed step 1. Implementation tests for the literal string `STUCK_NEEDS_HUMAN` anywhere in the bd notes — including stale text from prior attempts. Once a bead has had a stuck attempt, any subsequent re-pickup that re-applies the human label triggers the auto-flip even if the underlying problem is resolved.

Practical symptom: `claude-tools-240` keeps getting re-blocked even after manual reset, until the agent actually succeeds in calling ask-brian (which doesn't add the human label, so auto-flip doesn't fire). Worth tightening Fix B predicate to "recent" (e.g., last N seconds) rather than "any presence anywhere in notes."

### 11.9 Multiple runner accumulation

**Source:** `tmp/changes.md` Appendix A loose threads.

Across recent sessions, runner instances accumulated repeatedly. Causes:
- Daemon respawning when desired-state stays `running` and pidfile points at a dead pid (correct behavior).
- Watchdog subshells outliving their parent claude (`t7i`, closed).
- Manual launches not tracked by daemon's adopt logic.

`runbooks/cleanup-orphan-runners.md` documents cleanup. As of 2026-05-23 this was actively recurring — `pgrep -fl run-beads-tasks` showed 20+ live instances after extended autonomous operation. Daemon's adopt logic needs hardening; cleanup runbook is a workaround, not a fix.

### 11.10 Dossier-cleanup hygiene (shipped)

**Source:** `tmp/changes.md` Appendix A loose threads.

`claude-tools-23r` shipped a "Dismiss as stale" affordance in the Inbox (POSTs `/api/expire` to flip every open item to state=expired, gated behind `window.confirm`). `claude-tools-vxs` had earlier cleaned up duplicate sources. Stale dossiers from prior testing can now be dismissed from the UI rather than wedging the lane. **Note:** this is the same surface as the §5 (Stage 3) bug — the dismiss affordance shipped but its semantics are wrong.

### 11.11 The closing-gate test

**Source:** `tmp/changes.md` Appendix A loose threads.

`claude-tools-bzc` requires Brian to experience the full dossier loop end-to-end on his phone. Per the 8bm/38y churn-stop precedent it is DEFERRED until 2030-01-01 rather than left open to be re-triaged each session. The un-defer is a deliberate human-initiated action: `bd undefer claude-tools-bzc claude-tools-kie`, reclaim, drive the live session. If/when it passes (all 9 acceptance criteria — workspace registration, phone toggle, real dossier with real Mermaid, phone answer, mid-task daemon surgery, resume, stop/restart from phone, no ssh) the kie epic closes.

### 11.12 Things deferred to the future

**Source:** `tmp/changes.md` Appendix A loose threads.

- **`claude-tools-r0m`** — cross-workspace agent-to-agent communication (frontend agent asks backend agent a question via MCP). Deferred until 2030; revisit post-Z if manual-relay pain persists.
- **`claude-tools-bcm`** — Claude Agent SDK + `canUseTool` research. Deferred until post-June-15-2026 when SDK pricing may change. If SDK becomes subscription-covered then, evaluate migrating from the MCP-blocking pattern.
- **The terminology-doc decision** — set up as the closing-gate fixture (`claude-tools-240`); now closed + deferred alongside bzc. The actual architectural choice (where the per-workspace glossary lives, what format, how agents reference it) hasn't been made — it surfaces again when bzc un-defers and the live session asks Brian to pick.

### 11.13 Related memories worth checking

- `4xe-write-gate-render-tolerance.md` — never re-add a render refusal; fix at write/state plane.
- `feedback_beads_human_triage_label.md` — don't reflexively apply `human-triage` on runner bugs.
- `test-i3-partc-token-artifact.md` — lone `test-i3-stuck-dossier.sh` PART C fail is keychain-only-token harness artifact, not a regression.
- `feedback_agent_intelligibility.md` — pending; capture from §4.5.

---

## 12. File-by-file index for fixers

### 12.1 Runner script (`beads-runner/run-beads-tasks.sh`)

| Line(s) | Symbol / purpose | Used by |
|---|---|---|
| `:86, :660-676` | `RUNNER_NO_CLAIM_LABELS` gate (skips `human-live-session`, etc.) | §8.3 Mechanism B leans on this |
| `:131-145` | `_final_subshell_reap` EXIT trap | §8.3 Mechanism A claim-file removal site |
| `:257-265` | Dormant `lease_acquire_ok` | §8.3 context — why we're not just turning on lease |
| `:309` | State-block (where to export `RUNNER_PID=$$`) | §8.3 Mechanism B |
| `:339` | `current-task` pointer wipe | §8.3 context — claim files are durable |
| `:378-407` (`:380-388`) | `cleanup()` SIGINT/SIGTERM trap | §8.3 Mechanism A claim-file removal site |
| `:599-605` | Startup `ORPHANED_IDS` snapshot | §8.3 Mechanism A replace site |
| `:608-630` (`:609`) | `next_task()` — calls `bd ready --json` | §8.1 `dzc` fix; §8.3 context |
| `:614-628` | `bd show` recheck (defense-in-depth) | §8.3 Mechanism A — keep |
| `:665` | `validate_task` epic check | §8.1 — keep as defense-in-depth |
| `:714` | TASK_NOT_CLOSED classifier | §8.2 |
| `:1116` | `FEEDBACK RETURN (§7.3/S-2/I4)` log emit | §9.3 ambiguous log line |
| `:1127-1129` | Post-close `dirty_tree` audit | §9.4 `u4ms` |
| `:1422-1502` | Log tag taxonomy | §9.7 companion findings |
| `:1504-1512` (`:1511, :1512`) | Claim-write site (`bd update --status=in_progress`) | §8.3 Mechanism A patch site |
| `:1528-1547` | Watchdog math (already fixed by `h7n`) | §9.1 |
| `:1769` | Per-task in_progress→close transition | §8.3 Mechanism A removal site |
| `:1934` | Per-task handler for TASK_NOT_CLOSED | §8.2 |
| `grep no_DG_AUTHOR_CMD` | Fallback emit site | §4 |
| `grep TASK_NOT_CLOSED` | Classifier + handler | §8.2 |

### 12.2 Cloudflare Worker (engine)

| File | Purpose |
|---|---|
| `beads-runner/cf/src/dossier.js` | Dossier op surface (§7) |
| `beads-runner/cf/src/dossier.js:69` | `DOSSIER_OPS` set (add `bead-status-changed` here) |
| `beads-runner/cf/src/dossier.js:138` | `validateEnvelope` (refuses v1) |
| `beads-runner/cf/src/dossier.js:524` | `stateCheck` (legal transitions) |
| `beads-runner/cf/src/dossier.js:539` | `isDeterministic` (§5.2.2 gate) |
| `beads-runner/cf/src/dossier.js:689` | `emitFollowup` (generates `-fu-` clones) |
| `beads-runner/cf/src/dossier.js:737` | `itemApply` |
| `beads-runner/cf/src/dossier.js:779-795` | Consequence-block apply |
| `beads-runner/cf/src/dossier.js:816` | `itemSetState` (admin) |
| `beads-runner/cf/src/reconcile.js:475` | "no-reader-write-path" invariant (§7.5 Option 4) |
| `beads-runner/cf/src/reconcile.js:476-516` | `waiting_on_you` projection |
| `beads-runner/cf/src/reconcile.js:643-720` | `work-snapshot` (§8.3 cross-workspace check) |
| `beads-runner/cf/src/stuck.js` | S-2 control→work reconcile (§7.3) |
| `beads-runner/cf/wrangler.production.toml` | DB id `c80f8fb8-da0c-40b1-8051-70ff4ec5dd51` |

### 12.3 MCP server

| File | Purpose |
|---|---|
| `mcp-askbrian/server.mjs:30` | File-header: bead_ref REQUIRED |
| `mcp-askbrian/server.mjs:546-547` | Hardcoded `kind: "decide"` / `trigger: "worker_stuck"` (§3.1) |
| `mcp-askbrian/server.mjs:608` | `inputSchema` (no `trigger`/`kind` param) |
| `mcp-askbrian/helpers/engine-bridge.sh` (`:89` `cmd_write_polished`, `:110` `cmd_poll_once`) | Bridge dispatch (§3.4) |

### 12.4 Daemon

| File | Purpose |
|---|---|
| `beads-runner/daemon/daemon.sh` + `beads-runner/daemon/*.sh` | Per-machine daemon |
| `beads-runner/daemon/flow-f-overview-poll.sh` | ONE existing proactive-overview path (§3.1) |
| `beads-runner/daemon/intake-dispatch-poll.sh:211-229`-ish | `daemon_intake_parse_bd_id` (§3.4 Gap B; §9.5 gap 2) |
| `beads-runner/daemon/intake-dispatch-poll.sh:356, 361` | Retry comments (§9.5 gap 1) |

### 12.5 Agents

| File | Purpose |
|---|---|
| `beads-runner/agents/dossier-builder.system.md` | Dossier-builder prompt; overview shape at `:152, :198` (§3.1; §4.4) |
| `beads-runner/agents/enricher.system.md:54` | "Before you label, Read the catalog" (§9.5 gap 3) |
| `beads-runner/agents/enricher.system.md:98` | Enricher's only writer (`bd` subprocess) (§3.2) |
| `beads-runner/agents/intake-presets.json` | Intake-preset catalog (§3.2) |
| `beads-runner/agents/intake-presets.md` | One-PR-to-add playbook (§3.2) |
| `beads-runner/agents/specialist.sh:280` | `--add-dir` workspace only (§9.5 gap 3) |
| `beads-runner/web/functions/api/intake/_presets-catalog.js` | Lockstep mirror of intake-presets.json (§3.4 Gap B) |

### 12.6 Conformance + contracts

| File | Purpose |
|---|---|
| `beads-runner/BEHAVIORAL-CONTRACT.md` §2 (`BC-02` – `BC-08b`) | Design contract; BC-04 admits two-runners-one-orphan residual (§8.3) |
| `beads-runner/conformance/assertions/bc-08b-no-claim-label-gate.sh` | Pattern for new BC-02-amendment assertion (§8.3.7) |
| `beads-runner/lib/local-agent.sh:330-450` | `la_report_heartbeat`, `la_publish_workspace_inventory`, `current_task_ref` (§8.3) |
| `beads-runner/hooks/close-checklist.sh` | Existing PreToolUse hook on bd — pattern for §8.3 Mechanism B |
| `beads-runner/hooks/close-checklist.sh:259-261` | `dirty_tree` audit (§9.4 `u4ms`) |

### 12.7 Per-workspace runbooks

| File | Purpose |
|---|---|
| `docs/HANDOFF.md` | Broader operational map |
| `docs/runbooks/daemon-control.md` | Stop/start/check daemon |
| `docs/runbooks/manual-dossier-tools.md:120-127, :142-149` | Manual dossier upload recipe (§3.5) |
| `docs/runbooks/inspect-engine-records.md` | Read-side ops |
| `docs/runbooks/reset-stuck-bead.md` | `stuck-resolve` + `stuck-reconcile` precedent |
| `docs/runbooks/cleanup-orphan-runners.md` | Workaround for §11.9 |

### 12.8 Logs / data planes (per workspace)

| Path | Purpose |
|---|---|
| `<workspace>/.beads/runner-logs/incidents.log` | Running tally per workspace |
| `<workspace>/.beads/runner-logs/detached-*.log` | Raw streams |
| `<workspace>/.beads/runner-logs/claims/` (proposed) | §8.3 Mechanism A claim files |
| `~/.cache/claude-tools/dossier-author-audit.jsonl` | Fallback-fire audit trail (§4.6) |
| `~/.cache/claude-tools/daemon-logs/` | Daemon logs |
| `~/.config/claude-tools/workspaces.json` | Daemon workspace registry |

---

## 13. Source documents

- `tmp/changes.md` — original five-appendix handoff (kept on disk). This doc is the canonical rollup; prefer it.
- `tmp/beads-log-visibility-findings.md` — companion runner-log analysis (§9.7). Kept on disk.
- `docs/HANDOFF.md` — broader operational map.
- `~/.claude/projects/-Users-brianbutler-code-claude-tools/memory/` — feedback / project memories.
- `bd memories` — persistent insights from prior sessions.

---

## 14. Suggested filing order

If you are an agent picking this up to actually file the work, suggested order (autonomous-claim-eligible, no `human-triage` per §11.1):

1. **Stage 5** auto-close engine op + daemon publisher (§7.7) — biggest UX win for Inbox cleanliness; reuses zdxd D2 infra.
2. **Stage 3** "Dismiss as stale" + empty-payload guard (§5.5) — P1 active misbehavior.
3. **Mechanism A** PID-based claim files (§8.3.9 C-1) — P1 active duplicate-work hazard.
4. **Stage 2** DOSSIER_FALLBACK residual (§4.6) — P2; add new evidence list including `claude-tools-7xl`.
5. **Stage 2** readability-gate rule in dossier-builder + fallback template (§4.4) — P3 if filed as scope under #4.
6. **Stage 1** Gap A MCP `trigger`/`kind` extension (§3.4) — confirm scope with Brian first.
7. **Mechanism B** PreToolUse hook (§8.3.9 C-2) — P2; pairs with the live-session label gate.
8. **Stage 1** Gap B intake preset for overview-dossier (§3.4) — confirm scope with Brian first.
9. **§8.2** TASK_NOT_CLOSED investigation (§8.2) — P2/P3 depending on chosen angle.
10. **Mechanism C** stranded-live-session sweep (§8.3.9 C-3) — P2; depends on C-2.
11. **Stage 4** render-vs-engine drift (§6.5) — P3; check after Stage 3 lands; may auto-resolve.
12. Tactical: rhythmGame manual dossier upload (§3.5) — optional smoke test before §3.4 structural fix.
13. §9.5 intake-pipeline gaps (retry cap, parser, enricher catalog read, intake state surface).
14. §9.3 "FEEDBACK RETURN" log line — investigate before filing.

None carry `human-triage`. Stage 1 Gaps A and B are the only items Brian explicitly said to confirm scope on before code; everything else is autonomous.
