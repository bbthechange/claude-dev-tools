# Context: Worker personas + dispatch/gating policy

> One-liner: the **hats** a bd task can be dispatched as (ux/design/impl/docs/
> tests/reconciler/enricher) + the special **dossier-builder** + the lifecycle/
> gate/claim policy the runner consults. The hat is the PROMPT, not the process —
> one shim (`specialist.sh`) launches a fresh `claude -p` against a workspace.

**Read this doc when** your task touches: a `*.system.md` persona prompt, the
`specialist.sh` launcher / its permission discipline, the lifecycle stage spine,
the gate policy, claim-eligibility / capacity / defer rules, or the intake preset
catalog — anything under `beads-runner/agents/`.

**Owns / scope (the files this doc covers):**
- `agents/{ux,design,impl,docs,tests,reconciler,enricher}.system.md` — the seven
  hat personas. Each is short (1 paragraph) and is the *only* thing that differs
  between hats; same shim, same lifecycle, same permission discipline.
- `agents/dossier-builder.system.md` — the escalation-authoring agent (~28k).
  **Its prompt lives here; it is dispatched by the MCP server, not the runner.**
- `agents/specialist.sh` — the ONE shim: `specialist.sh --kind=<hat> --workspace=…`.
- Policy/reference: `agents/lifecycle.md`, `gate-policy.md`, `claim-eligibility.md`,
  `capacity.md`, `intake-presets.{md,json}`, `defer-cascade-audit.md`, `gate-defer.md`.

**Not here (go to the right doc):**
- The MCP server that *dispatches* the dossier-builder, writes the dossier to the
  engine, and blocks for Brian's answer → `docs/context/mcp-askbrian.md`.
- The runner loop that *spawns* hat workers per bd task and consults the gate →
  `docs/context/runner.md`.
- The hosted engine that stores dossiers/runner-state and the `gate-policy.sh` /
  `bd-stage.sh` / `capacity.json` consumers → `docs/context/engine-cloudflare.md`
  and `docs/context/daemon.md`.
- The frozen vocabulary, closed enums, and A/B/C/D contracts → `docs/context/contracts-and-design.md`.

---

## Mental model

Three facts explain almost everything here:

1. **The hat is the prompt, not the process** (`specialist.sh:5-13`). The whole
   fleet — ux, design, impl, docs, tests, reconciler, enricher, dossier-builder —
   is ONE binary that runs `claude -p` against a workspace with the system prompt
   selected by `--kind` from `<dir>/<kind>.system.md`. **Adding a hat = adding one
   `.system.md` file + one row to the `case` statement.** A missing prompt errors
   loudly (exit 2) — a quiet default is never allowed. The `--kind` enum is closed
   and validated: `ux|design|impl|docs|tests|reconciler|enricher|dossier-builder`.

2. **Two dispatch paths, one shim.** The *work hats* (ux/design/impl/docs/tests)
   and the *bd-surgery hats* (reconciler/enricher) are dispatched by the runner or
   daemon as the body of a bd task / stage transition / intake. The
   **dossier-builder is the exception**: it is dispatched by the **ask-brian MCP
   server** (see `mcp-askbrian.md`), not the runner. A worker hit a fork, called
   `ask-brian`, and the server spawns a *fresh* builder to author the dossier from
   the worker's context dump — because a 600k-token stuck worker is the wrong agent
   to also write the polished phone document. (Rationale: bd memory
   `architecture-refinement-brian-2026-05-20`; the builder being a separate fresh
   agent is why its prompt is so explicit about gathering its own context.)

3. **Permission discipline is keyed by kind** (`specialist.sh:181-213`). Three tiers:
   - **work hats** (ux/design/impl/docs/tests): reads + writes + broad Bash
     (`node/npm/wrangler/git/…`), `--permission-mode acceptEdits`. They do real work.
   - **bd-surgery + builder** (reconciler/enricher/dossier-builder): reads +
     `Bash(bd:*)` + read-only git, **no file writes outside `.beads/`** (Write/Edit/
     MultiEdit/NotebookEdit/BashWriteEdits disallowed). The `bd` subprocess is their
     only writer; the dossier-builder emits its document on **stdout** (the hosted
     engine is the writer). `--permission-mode default`.
   - All hats inherit the §7.6 guardrail: `--disallowedTools AskUserQuestion
     EnterPlanMode ExitPlanMode` (same as the per-task worker).

## Key files

| File | Role |
|---|---|
| `specialist.sh` | The ONE shim. Validates `--kind`, resolves `<kind>.system.md`, applies per-kind allow/deny tool sets, runs `claude -p` in a subshell `cd`'d to the workspace, logs a structured event line + the full stream-json to `.beads/runner-logs/` (self-gitignored, BC-27). Exit code = the underlying `claude` exit (BC-09: not a verdict on its own). |
| `ux.system.md` | UX hat: the user's *path* through the product — flows/touchpoints, not visuals. Hard line: exactly TWO surfaces (Inbox, Board); a flow needing a third is wrong. Flags arch decisions to the `design` hat, doesn't make them. |
| `design.system.md` | Design hat: technical design (data shapes, interfaces) as an AD-style decisions log w/ traceability to the UX requirement. May amend prior decisions *visibly*; never silently rewrites a frozen section. No code. |
| `impl.system.md` | Impl hat: smallest composable diff that satisfies the acceptance criteria. Design is frozen/contract. On a real fork the design didn't cover → raise a **stuck-signal** (Flow B dossier), never silently diverge. |
| `docs.system.md` | Docs hat: docs a future agent + forgotten-Brian can use. Expand acronyms on first use, WHY before HOW, skimmable. |
| `tests.system.md` | Tests hat: verify *observable behavior* vs acceptance criteria; prefer real integration over mocks (a mocked-happy green is worse than no test). If a behavior can't be tested headlessly, say so + write a manual-e2e checklist. |
| `reconciler.system.md` | Reconciler hat: a Flow B dossier came back with freeform text/an edit; emit the `bd create/update/dep/label` calls that answer implies. **No code, no project tree** — bd is the only side effect. Conservative: file a follow-up dossier rather than guess. |
| `enricher.system.md` | Enricher hat (Flow A intake): turn a phone-captured idea sentence into a structured bd task. **Dedup is the load-bearing job** — augment an existing bead before assuming new. Sets the entry stage from the tapped preset. Reads input JSON `{intake_id, idea_text, project_ref, preset, …}`. |
| `dossier-builder.system.md` | The escalation author. Reads worker context-dump JSON on stdin, emits ONE dossier JSON on stdout (or `{"refuse":true,…}`). Server-validated minimums: ≥3 bespoke sections, ≥1 Mermaid diagram, ≥500-char `full_detail`, ≥1 item. Output contract is the first 60 lines — read it. |
| `lifecycle.md` | L1: the closed stage spine `idea→ux→design→impl→docs→tests→done`, realized as `stage:<value>` bd labels via the one chokepoint `bd-stage.sh set`. |
| `gate-policy.md` | L2: the constant `(stage,transition)→{auto-advance, gate-human}` table the runner consults via `gate-policy.sh decide <id>`. |
| `claim-eligibility.md` | Empirical contract for `bd ready` ordering (priority-asc, deterministic, created-at-desc tiebreak) — what `next_task()` relies on. |
| `capacity.md` | The spare-only daily-ramp gate (`spare_ramp_today`, UI `spare-only` ↔ wire `spare-cycles`). |
| `intake-presets.{md,json}` | Closed entry-intent preset catalog; each preset reduces to `(entry_stage, gate_aggressiveness)`. **The JSON wins** on drift. |
| `defer-cascade-audit.md` / `gate-defer.md` | bd defer hygiene: diagnose a silent parent→child defer cascade; couple a defer to its owning `gate:<id>` so lifting the gate reverses it. `gate-defer.sh apply` also takes `--why/--unblock/--owner/--scope` (claude-tools-escz) → writes the Gate's metadata via the J1 `gate-meta-set` op in the same call (an agent places a Gate *with a why*). |

## Contracts & invariants (don't break these)

- **Hat enum is closed.** `specialist.sh`'s `--kind` case + the `.system.md` files
  are the source of truth; a kind not in the enum is rejected (exit 2). A missing
  prompt file is a *visible* failure, never a quiet default.
- **No-write hats physically cannot write outside `.beads/`.** reconciler / enricher
  / dossier-builder rely on the `bd` subprocess + stdout; tool-level disallow
  (NO_CODE_EDITS) is the enforcement. Don't grant them Write/Edit "to make a fix."
- **Bash is REQUIRED for the bd-surgery + builder hats** (claude-tools-lhc/e5aq).
  Without `Bash(bd:*)` they cannot follow their own Step-1 "walk the bd graph"
  instruction — the scar was 192 permission denials, zero beads created.
- **The stage spine is a closed enum, one stage per bead.** Every change goes
  through `bd-stage.sh set`; freeform `stage:foo` is rejected. Don't add a stage casually.
- **Default is auto-advance** (gate-policy). The only enforced *pickup* gate is the
  `collaborative-stage` preset → "ready to pair" Inbox item. `STUCK_NEEDS_HUMAN`
  and the Flow F design-checkpoint FYI are runtime/observer paths, NOT pickup gates.
- **Preset catalog reduces to two axes** `(entry_stage, gate_aggressiveness)`. A
  preset that can't reduce to that pair does not belong in the catalog — design it first.
- **The dossier-builder's output thresholds are server-validated.** Failing them
  ⇒ the MCP server falls back to the deterministic jq path and ships a
  "FALLBACK AUTHOR" badge. Emitting `{"body":{},"items":[]}` to satisfy the JSON
  contract is the WRONG response; refuse honestly instead.
- **Readability gate (claude-tools-uxvl5; inbox-lifecycle §4.4).** The builder
  prompt rule #4 is now the explicit cold-reader gate: a non-author must learn
  what blew up / what to decide / what each option does in <30s with no jargon —
  *never name an internal section/ID/state without translating it in the same
  sentence.* It is **checkable**: `dg__readability_lint` (in `lib/dossier-gen.sh`)
  flags untranslated jargon (`§`, contract IDs, raw enum/state tokens) in the
  reader-facing prose, and the deterministic fallback template
  (`sr_worker_ask` + `dg_from_worker_ask`) is held to it in tests. **Advisory,
  not a write gate** (4xe write-gate/render-tolerance: write rejects on schema,
  not prose style). The `no_DG_AUTHOR_CMD` fallback **still fires** for any
  `dg__author` caller without `DG_AUTHOR_CMD` wired (it's per-call-site, not
  global) and v2's `_drive_blocked_for_human` ships a body-less stub — both are a
  filed follow-up; uxvl5 only fixed the *readability* of the fallback, not how
  often it fires.

## Common changes (recipes)

**Add a hat:** create `agents/<kind>.system.md` (one tight paragraph in the voice
of the existing seven — read 2-3 first); add `<kind>` to BOTH `case` statements in
`specialist.sh` (the validation guard ~line 105 and the permission `case` ~line 181);
decide its tier (work / bd-surgery). Run `bash beads-runner/agents/test-specialist.sh`.

**Edit a persona:** edit only the prose. The personas are deliberately short so
agents read all of it — don't bloat them into a re-spec of UX-DESIGN/DESIGN. Keep
the hard constraints (two-surface limit; frozen-design; dedup-first; no-code-for-
reconciler) — they are the whole point of the hat.

**Add an intake preset:** add the row to `intake-presets.json` (single source of
truth) reducing to `(entry_stage, gate_aggressiveness)`; mirror the human table in
`intake-presets.md`; the enricher consumes it on next intake. A preset meaning
"still autonomous" needs no gate-policy.sh change (absence-of-`preset:*` defaults
to autonomous).

**Gate / test before close:** `bash beads-runner/run-tests.sh --changed` — the
`agents` tier auto-enrolls `test-specialist.sh`. See `docs/context/testing.md`.
Personas are prompt text with no live-deploy step, so the offline gate is the bar
here (unlike web tasks — the bgw deploy-then-verify lesson is `web-shell.md`).

## Gotchas / scars

- **The builder is dispatched by the MCP server, not the runner.** A change to
  *when/whether* the builder runs lives in `mcp-askbrian/` (see `mcp-askbrian.md`);
  only its *prompt* lives here. Don't wire builder-dispatch into `specialist.sh`.
- **The builder must not answer the question.** Its single most common production
  failure is emitting a prose recommendation / "the user dismissed the prompt" to
  stdout instead of composing the dossier JSON *about* the fork. The first 60 lines
  of `dossier-builder.system.md` are an OUTPUT CONTRACT enumerating the wrong shapes
  — preserve them.
- **`--permission-mode default` in `claude -p` denies un-allowlisted tools instantly.**
  That is why every hat carries an explicit `COMMON_ALLOWED` list (claude-tools-e5aq).
  Removing a tool from it silently breaks the hat with no error.
- **Node v25 crashes the `claude` CLI at startup.** `specialist.sh` sources
  `lib/node25-prime.sh` and prepends nvm bin; a daemon-launched PATH otherwise
  resolves system-node v25 (claude-tools-3kd). The wrong-node detector logs LOUDLY.
- **bd defer cascades silently.** An open child with zero blockers can still be
  invisible to `bd ready` because an *ancestor* carries a future `defer_until`.
  `defer-cascade-audit.sh` makes it visible; `gate-defer.sh` couples a defer to its
  gate so lifting reverses it. Neither mutates beyond what it's told.

## Go deeper

- `docs/HANDOFF.md` — "Specialist hats" + "Dossier-builder agent" sections (the
  component vocabulary list pins the canonical names: "workspace runner",
  "dossier-builder agent", "ask-brian MCP tool", …).
- `beads-runner/UX-DESIGN.md` §2.1 "The hat model" + §0.A/0.C (Flow A intake, preset catalog).
- `beads-runner/DESIGN.md` §5 C1 (stage as a first-class field; the gate seam).
- `agents/lifecycle.md` + `gate-policy.md` — the authoritative stage/gate policy.
- `beads-runner/agents/test-specialist.sh` — the conformance harness for the shim.
- bd memories: `architecture-refinement-brian-2026-05-20` (why the builder is a
  separate fresh agent); claude-tools-cvj/lhc/e5aq scars (builder JSON-only, Bash-required).

## Keeping this doc current

When you finish a task in this area, append anything a future agent will need and
didn't find here: a new hat + its tier, a moved/renamed prompt, a changed
permission set, a new gate/preset rule, a fresh scar. **Keep it concise — this doc
earns its keep only if agents read all of it.** Delete lines that have gone stale;
don't let it grow into a copy of the `.system.md` prompts or UX-DESIGN.md.
Last substantive update: 2026-05-31.
