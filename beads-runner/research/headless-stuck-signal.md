# Headless `claude -p` behavior on AskUserQuestion / EnterPlanMode / ExitPlanMode, and the deliberate stuck-signal path

Status: research complete · Owner: Brian · bead: claude-tools-ton
Scope: forward-looking research only — no changes to `run-beads-tasks.sh` or system design.

## TL;DR

In headless `claude -p`, attempting an interactive tool is a **SOFT FAIL, not a
crash**: the harness auto-rejects it, hands the model an `is_error: true`
tool_result, and the **session still exits 0 with `result.is_error: false` and
`stop_reason: end_turn`**. Empirically the model then emits a one-line "the user
declined / dismissed" shrug and ends the turn — it does **not** spontaneously
fall back to any deliberate signal. From the runner's side that lands as
`TASK_NOT_CLOSED` → blind retry loop, never Flow B.

Therefore: **we cannot rely on the model self-recovering. We must instruct it to
never take the interactive path and always take a deliberate `bd`-based
stuck-signal — and back that with a runner-side `permission_denials[]` scan,**
because the soft-fail is invisible to exit-code/`is_error` classification.

Environment for all evidence below: **claude 2.1.142 (Claude Code)**, macOS
(darwin 25.5.0), model `claude-sonnet-4-6`, throwaway dir `/tmp/headless-probe`
(git-init'd, isolated; this repo untouched). Tool-availability behavior is a
harness concern and is expected to be model-independent; it is **version- and
undocumented-behavior-dependent and must be re-verified on every `claude`
upgrade.**

---

## Q1 — What happens when a headless `claude -p` agent attempts AskUserQuestion?

**Answer: SOFT FAIL.** The tool is advertised in the `init` event's tool list,
the model can call it, the harness immediately auto-rejects the interactive
prompt, and the model receives an **error tool_result it can see and react to**.
The process exits **0** and reports **success**.

Command (stream-json, default permission mode):

```bash
claude -p 'Call the AskUserQuestion tool RIGHT NOW. Ask "Pick a color: red or blue?" ...' \
  --output-format stream-json --verbose --model claude-sonnet-4-6 --max-turns 6
# EXIT=0
```

Stream excerpts:

```jsonc
// init advertises the interactive tools:
{"subtype":"init", ... "tools":[ ... "AskUserQuestion","EnterPlanMode","ExitPlanMode" ...]}

// model calls it:
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion",
  "input":{"questions":[{"question":"Pick a color: red or blue?","options":[...]}]}}]}}

// harness auto-rejects — MODEL-VISIBLE error tool_result:
{"type":"user","message":{"content":[{"type":"tool_result",
  "content":"Answer questions?","is_error":true,
  "tool_use_id":"toolu_01612ySAu4DrDr5RaQ1YRpVL"}]}}

// model's reaction — a passive shrug, then it ENDS THE TURN:
{"type":"assistant","message":{"content":[{"type":"text",
  "text":"The user was prompted with the question. It seems the question prompt
          was dismissed or not answered. Let me know if you'd like me to ask
          again or proceed with something else."}]}}

// final result — SUCCESS, exit 0, but a structured denial record is present:
{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn",
 "num_turns":2,"terminal_reason":"completed",
 "permission_denials":[{"tool_name":"AskUserQuestion",
   "tool_use_id":"toolu_01612ySAu4DrDr5RaQ1YRpVL",
   "tool_input":{"questions":[{"question":"Pick a color: red or blue?", ...}]}}]}
```

Two facts that drive everything else:

1. The failure is **soft** (model sees `is_error:true` "Answer questions?") but
   the **process is indistinguishable from success** at the exit-code / `result`
   level (`exit 0`, `subtype:success`, `is_error:false`, `end_turn`).
2. There **is** a precise machine-readable trace: the final `result` event's
   **`permission_denials[]`** array names `AskUserQuestion` and echoes the full
   `tool_input`. This is the hook for a deterministic runner-side backstop.

---

## Q2 — Same for EnterPlanMode and ExitPlanMode under `claude -p`

These two behave **differently from each other** — and EnterPlanMode is the
nastier one.

### EnterPlanMode → **SILENT SUCCESS (no-op for the runner)**

```bash
claude -p 'Call the EnterPlanMode tool RIGHT NOW as your very first action ...' \
  --output-format stream-json --verbose --model claude-sonnet-4-6 --max-turns 6
# ENTERPLAN_EXIT=0
```

```jsonc
{"tool_use":"EnterPlanMode","input":{}}
// tool_result is NOT an error — it succeeds:
{"type":"tool_result","is_error":null,
 "content":"Entered plan mode. You should now focus on exploring the codebase
            ... DO NOT write or edit any files yet. ... use ExitPlanMode ..."}
{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn",
 "num_turns":3,"terminal_reason":"completed","permission_denials":[]}
```

EnterPlanMode **actually works** in headless `-p`. It flips the agent into a
read-only planning posture and returns planning instructions. With nothing left
to do, the model ends the turn. Net effect for the runner: **exit 0, no denial,
no error, zero work done** — a true silent no-op. This is the single residual
gap that the `permission_denials[]` backstop does *not* catch (see Q4).

### ExitPlanMode → **SOFT FAIL** (both in- and out-of-plan-mode)

Out of plan mode (model never entered it):

```jsonc
{"type":"tool_result","is_error":true,
 "content":"<tool_use_error>You are not in plan mode. This tool is only for
            exiting plan mode after writing a plan...</tool_use_error>"}
{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn"}
// EXITPLAN_EXIT=0
```

Genuinely in plan mode (`--permission-mode plan`, model wrote a plan file then
called ExitPlanMode):

```jsonc
{"tool_use":"ExitPlanMode"}
{"type":"tool_result","is_error":true,"content":"Exit plan mode?"}
{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn",
 "terminal_reason":"completed","permission_denials":["ExitPlanMode"]}
// EXITPLAN_INPLAN_EXIT=0
```

ExitPlanMode is a soft fail with the *same shape as AskUserQuestion*: model-
visible `is_error:true` tool_result ("Exit plan mode?"), exit 0, success — and,
when genuinely in plan mode, **recorded in `permission_denials[]` as
`ExitPlanMode`**. So the same backstop that catches AskUserQuestion catches a
real plan-approval attempt too.

---

## Q3 — Does behavior differ by `--output-format`, `--permission-mode`, or version?

**Substance is identical across every combination tested. Only *observability*
differs.** All ran exit 0 / soft-fail.

| Variant | tool_result seen by model | exit | `result.is_error` | `permission_denials[]` |
|---|---|---|---|---|
| AskUserQuestion · stream-json · default | `is_error:true` "Answer questions?" | 0 | false | `["AskUserQuestion"]` |
| AskUserQuestion · stream-json · **acceptEdits** (runner's actual mode) | `is_error:true` "Answer questions?" | 0 | false | `["AskUserQuestion"]` |
| AskUserQuestion · **json** | (collapsed) | 0 | false | `["AskUserQuestion"]` |
| AskUserQuestion · **text** | (collapsed) | 0 | n/a in output | **not exposed** |
| ExitPlanMode · in plan mode · stream-json | `is_error:true` "Exit plan mode?" | 0 | false | `["ExitPlanMode"]` |
| EnterPlanMode · stream-json · default | succeeds (no error) | 0 | false | `[]` |

Key implications:

- **`--permission-mode` (`default` vs `acceptEdits`) does not change it.** The
  runner already uses `--permission-mode acceptEdits` (`run-beads-tasks.sh:21`)
  and gets the exact same soft-fail + `permission_denials` record.
- **`--output-format` only changes whether you get a structured signal.**
  - `stream-json` (what the runner uses, `:643`) and `json` both expose
    `permission_denials[]` with the full tool_input → **machine-detectable.**
  - `text` collapses everything to the model's final prose ("The user declined
    to answer the question.") → **no structured signal; would require regexing
    free text.** Another reason the runner must stay on stream-json.
- **`--permission-mode plan` does not auto-park the worker in plan mode** in
  `-p`; the worker had to construct the plan itself, and the gate is the
  ExitPlanMode soft-fail, not an automatic block.
- **Version:** claude **2.1.142**. None of this is documented as a stable
  contract (see "Documentation cross-check"); treat as empirical and re-verify
  on upgrade.

### Bonus — `--disallowedTools` (a candidate guardrail)

```bash
claude -p 'Call AskUserQuestion RIGHT NOW ...' --output-format stream-json \
  --disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode ... # EXIT=0
```

With these disallowed, the `init` tool list shows **`[]`** for all three — they
are **not advertised at all**, the model **cannot even attempt** the call (no
`tool_use`, no `permission_denials`), and it falls back to asking in prose then
exits 0. So `--disallowedTools` is a clean **guardrail** (it removes the
EnterPlanMode silent-stall temptation entirely) but is **not itself a
stuck-signal** — the model still just shrugs in prose. It must be paired with
the instructed deliberate path.

---

## Q4 — Most reliable way for a headless worker to DELIBERATELY signal a structured decision request

Evaluated against what headless agents demonstrably do reliably (run a CLI,
write a file) vs. unreliably (reason gracefully about a soft tool error):

| Option | Reliability in headless `-p` | Verdict |
|---|---|---|
| **A. `bd` path**: `bd update <id> --status=blocked`, write the structured ask to `--design`/`--append-notes`, `bd human <id>`, then **exit non-zero** | High — these are deterministic CLI calls, the agent's bread and butter; lands directly on the beads sync backbone that Flow B / the Board already read | **Recommended (primary)** |
| B. Structured artifact a coordinator consumes | Medium — works, but invents a second channel the Board/Inbox don't already read; duplicates what a bead note already is (UX-DESIGN §"no new surface") | Redundant with A |
| C. Exit-code + signal-file convention | High mechanically, but is a *runner-detection* convention, not something the model emits well on its own; best used as the **backstop**, not the worker's primary act | Use as backstop, not primary |
| Rely on model self-recovering from the soft fail | **None** — empirically it shrugs and exits 0 (see Q1, Q5) | Rejected |

**Recommendation — two complementary layers:**

**Primary (worker-driven, instructed):** When the worker hits a fork it must not
resolve, instruct it to, in order:
1. `bd update <id> --status=blocked`
2. write the structured ask (TL;DR · the ask · options · recommendation + why ·
   what's reversible) into the bead via `bd update <id> --design=...` /
   `--append-notes=...` — this is the raw material Flow B's dossier builder
   consumes;
3. `bd human <id>` — the **documented Flow B `human`-flag trigger**
   (UX-DESIGN.md §Flow B: "TRIGGER: bd `human` flag · worker hits a fork it
   can't resolve");
4. **exit with a non-zero code** (and/or emit the agreed signal-file token) so
   the runner does not see a bare exit-0.

This is reliable precisely because it is a sequence of deterministic CLI
actions — the category of thing headless agents do dependably — rather than
"notice a soft error and improvise the right recovery," which they demonstrably
do not. It also requires **no new surface**: the ask rides the beads sync that
the Board/Inbox already render.

**Backstop (runner-side, defense-in-depth, zero model cooperation):** Because a
worker may still slip and call the interactive tool, the runner should — exactly
like the existing `scan_stream_for_tool_errors` backstop
(`run-beads-tasks.sh:~463`) — scan the final `result` event's
**`permission_denials[]`** for `AskUserQuestion` / `ExitPlanMode`. If present,
classify as a new terminal state (e.g. `STUCK_NEEDS_HUMAN`) that **overrides the
exit-0/`is_error:false` "success"**, flips the bead to `blocked` + `bd human`,
and routes to Flow B instead of the blind `TASK_NOT_CLOSED` retry. This is
deterministic and trustworthy because the denial record is structured and always
present in stream-json/json.

**Residual gap:** EnterPlanMode leaves **no** denial and exits 0 (Q2). Close it
with `--disallowedTools EnterPlanMode` (and `ExitPlanMode`, `AskUserQuestion`)
for workers — which removes the tools from the advertised set entirely (Q3
bonus) — and/or scan the stream for the `"Entered plan mode."` tool_result.

> These are recommendations for a later task. Per scope, this research does **not**
> implement them in `run-beads-tasks.sh`.

---

## Q5 — Can we RELY on the model noticing the failed AskUserQuestion and falling back, or must we INSTRUCT it to always take the deliberate path?

**Decision: INSTRUCT. We cannot rely on fallback.** This falls directly out of
Q1: the failure is *soft* (so in principle the model could react), but in every
single run — across stream-json / json / text and default / acceptEdits — the
model's actual reaction was a passive closing sentence followed by ending the
turn with **`stop_reason: end_turn`, exit 0, `subtype: success`**:

- "It seems the question prompt was dismissed or not answered. Let me know if
  you'd like me to ask again or proceed with something else."
- "The user declined to answer the question."
- "The question was presented. It appears the user dismissed or cancelled the
  prompt."

In **no** run did it spontaneously block the bead, write a structured ask, raise
`bd human`, or emit any deliberate stuck-signal. It gave up and exited cleanly.

Why this is the worst outcome (grounded in the runner): `classify_failure()`
(`run-beads-tasks.sh:319-329`) on `exit 0` checks bead status; the worker did
**not** close the bead, so it returns **`TASK_NOT_CLOSED`** → handled at
`:863-874` as "PARTIAL: exited 0 but task still open" → **retry once, then spawn
a generic analysis task**. The fork that genuinely needs a human becomes an
"agent forgot to finish" retry loop that re-hits the same fork every time and
**never reaches Flow B / `bd human`**. This is exactly the "succeeded but
silently did the wrong thing → silent failures just rot" failure class that
UX-DESIGN.md Flow G / principle 7 flags as the most dangerous.

Consequence for the worker prompt: the existing line — *"Do NOT use
EnterPlanMode or ExitPlanMode... Do NOT use AskUserQuestion... Just execute the
work directly."* (`run-beads-tasks.sh:612`) — is **necessary, not optional**, and
research shows a bare prohibition is **insufficient**: with no positive
alternative, the model improvises the silent-shrug-exit-0. The prohibition must
be paired with an explicit positive instruction — *"when you hit a fork you must
not resolve, do NOT ask; instead `bd update --status=blocked` + write the
structured ask + `bd human <id>` + exit non-zero"* — i.e. the Q4 primary path.

---

## Documentation cross-check

Anthropic's headless / SDK docs describe `-p`/`--print` and `--permission-mode`
for non-interactive runs and the existence of `permission_denials` /
`canUseTool`-style gating, but **do not document the specific behavior of
AskUserQuestion / EnterPlanMode / ExitPlanMode when invoked with no human
attached** — there is no published contract that it is a soft fail vs. hard
fail, nor that EnterPlanMode silently succeeds, nor that a denial is surfaced in
the final `result.permission_denials[]`. All of the above is therefore treated
as **empirical, version-pinned (2.1.142), and subject to change without
notice**; the runner's safety must not depend on it staying soft — hence the
deterministic `permission_denials[]` backstop *and* the `--disallowedTools`
guardrail, neither of which assumes graceful model behavior.

---

## Single clear recommendation

1. **Rely-vs-instruct: INSTRUCT.** Never let the worker take the interactive
   path; never assume it recovers from the soft fail. Replace the bare
   prohibition with a prohibition **+ a positive deliberate path**.
2. **Stuck-signal mechanism (primary):** worker does
   `bd update <id> --status=blocked` → writes structured ask into the bead
   (`--design`/`--append-notes`) → `bd human <id>` → **exit non-zero**. Reliable
   (deterministic CLI), and rides the beads backbone Flow B already consumes.
3. **Backstop (runner, no model trust):** scan the final `result` event's
   `permission_denials[]` for `AskUserQuestion`/`ExitPlanMode`; treat as
   `STUCK_NEEDS_HUMAN`, override the false exit-0 success, route to Flow B.
4. **Guardrail:** run workers with
   `--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode` to remove the
   tools entirely and close the EnterPlanMode silent-no-op gap (the one case
   with no denial record). Keep `--output-format stream-json` — `text` hides the
   structured signal.

Implementation of 1–4 is deliberately out of scope for this bead (research
only); these are inputs to the runner-overhaul / conformance-contract work.
