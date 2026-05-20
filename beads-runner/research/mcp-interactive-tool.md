# A custom MCP tool can host the interactive human-decision channel for `claude -p` (and for interactive Claude Code)

Status: research complete · Owner: Brian · bead: claude-tools-59o
Scope: forward-looking research only — no changes to `run-beads-tasks.sh` or system design.

## TL;DR

**Recommendation A — adopt it.** A custom stdio MCP server exposing a single
poll-and-return tool ("ask-brian") **blocks `claude -p` cleanly for at least
30 minutes wall-clock** with no harness timeout, no retry, no transport kill, no
keepalive issue, and **no observable ceiling** in our probes (the 30-min probe
returned `exit 0` with `result.is_error: false`, `stop_reason: end_turn`,
`permission_denials: []` — same shape as a one-second call). Sequential
multi-question flows in a single session work too: 3 `ask-brian` calls in series
each block ~31s, and the agent threads earlier answers into later questions
before exiting cleanly. `--permission-mode default` and `acceptEdits` are
indistinguishable for MCP tool calls. The hybrid case (same MCP server reachable
from `claude -p` *and* from interactive Claude Code) works by construction:
nothing distinguishes a `-p` invocation from an interactive one at the MCP
transport boundary, and the same `--mcp-config /abs/path.json` (or user-scope
`claude mcp add --scope user …`) makes the tool available in every session.

So: **the interactive-question channel can live inside an MCP tool** with no
need for the Agent SDK (`canUseTool`) or any API/Console billing, and the same
tool serves both headless workers and any interactive session in which Brian
mid-conversation says "route questions through ask-brian instead of asking me
here." This is the path.

The discipline constraint is preserved by **prompt language, not by mechanism**:
the worker prompt (and any interactive in-conversation instruction) must keep
the bar exactly where it is today — "call `ask-brian` ONLY when there is a
genuine fork the agent must not resolve, not for ordinary hard work or as a
substitute for thinking" — see [[the-bar-stays]] below. The MCP path does
nothing to lower that bar; if anything, the easier round-trip makes it more
important to keep the prompt strict.

Environment for all evidence below: **claude 2.1.142 (Claude Code)**, macOS
(darwin 25.5.0), model `claude-sonnet-4-6`, throwaway dirs `/tmp/mcp-probe`,
`/tmp/mcp-probe-{B,C,D,E,H}` (all git-init'd, isolated; this repo untouched
during probing). MCP server is ~80 lines of Node using
`@modelcontextprotocol/sdk` over stdio; the tool writes the question to
`question.txt` and polls `answer.txt` every 1s until present, no native
blocking. Cross-version stability is a harness concern and is **version- and
undocumented-behavior-dependent — re-verify on every `claude` upgrade** (same
caveat as [[headless-stuck-signal]] §Documentation cross-check).

---

## Q1 — Does an MCP tool that blocks for N seconds work at all in `claude -p`?

**Answer: yes, identical shape to any other tool call.** With
`--mcp-config /tmp/mcp-probe/.mcp.json --strict-mcp-config` and
`--allowedTools "mcp__askbrian__ask-brian" "Bash"`, the agent calls the tool,
the MCP server's poll loop blocks for the wall-clock between question-write and
answer-write, and the tool_result lands as the model's next observation. Probe
**p1-30s-default** (`/tmp/mcp-probe/stream-p1-30s-default.jsonl`):

```jsonc
{"subtype":"init", ..., "mcp_servers":[{"name":"askbrian","status":"connected"}],
                       ...,"permissionMode":"default"}

// agent first resolves the deferred MCP tool schema via ToolSearch (1 turn of overhead, see Q7):
{"tool_use":"ToolSearch","input":{"query":"select:mcp__askbrian__ask-brian", ...}}

// then the actual call:
{"tool_use":"mcp__askbrian__ask-brian",
 "input":{"question":"What is your favorite color?"}}

// 31s of wall-clock pass (server log: "STILL_WAITING elapsedMs=30031" …
// "ANSWERED elapsedMs=31034"). MCP server returns the answer string:
{"tool_result":"blue","is_error":null,"tool_use_id":"toolu_01FNc3..."}

// agent acts on it and ends the turn:
{"tool_use":"Bash","input":{"command":"echo \"GOT_ANSWER=blue\""}}
{"tool_result":"GOT_ANSWER=blue","is_error":false}

{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn",
 "num_turns":4,"duration_ms":49142,"permission_denials":[]}
// EXIT=0
```

Two facts to carry into the contract:

1. **The MCP tool_result has `is_error: null`** (not `false`). Native tools
   (Bash here) emit `is_error: false`. This is the MCP SDK's defaulting
   behavior, not a misconfiguration — the runner's `scan_stream_for_tool_errors`
   logic (the existing backstop at `run-beads-tasks.sh:~463`) must treat `null`
   as success, **not** as a missing field that should be flagged.
2. **`permission_denials[]` stays empty** when the MCP tool is allowed and the
   call returns. This is the opposite of [[headless-stuck-signal]]'s
   `AskUserQuestion` case, which always populates `permission_denials[]`. Both
   facts together mean a successful `ask-brian` round-trip is **structurally
   identical** to any other normal tool call — the runner needs no new
   detection logic to *accept* this path; the detection logic from the prior
   research stays in place to *reject* the still-forbidden interactive tools.

---

## Q2 — Is there a timeout ceiling? (5 min / 15 min / 30 min)

**Answer: no ceiling observed up to 30 minutes wall-clock.** Three probes in
isolated dirs, each blocking the MCP tool for the named duration:

| Probe | block | `result.duration_ms` | `is_error` | `stop_reason` | `permission_denials` |
|---|---:|---:|---|---|---|
| **p2-5min-default** (`/tmp/mcp-probe`) | 301s | 313,230 ms | false | end_turn | `[]` |
| **p3-15min-default** (`/tmp/mcp-probe-B`) | 901s | 912,660 ms | false | end_turn | `[]` |
| **p4-30min-default** (`/tmp/mcp-probe-C`) | 1801s | 1,810,302 ms | false | end_turn | `[]` |

Each is *identical in shape* to the 30-second probe — same init event, same
`ToolSearch + ask-brian + Bash` arc, same `result` envelope, same `exit 0`. The
server log confirms the polling loop ran the full duration ("STILL_WAITING
elapsedMs=…" every 30s) and never observed a forced disconnect or signal from
the parent.

**What did NOT happen during any long block** (all directly checked):

- No `stderr` from `claude` (run-logs are empty after the
  `[probe] starting claude…` header).
- No retry — exactly one `tool_use` event per call across every probe.
- No `result.subtype` other than `success`; no `is_error: true` envelope.
- No MCP transport error, no "server disconnected" message, no `init`
  reconnection event.
- No partial / truncated stream-json (final `result` event present in every
  file).

The contract is therefore: **for any wait Brian could reasonably impose by
answering on his phone, the tool call survives intact.** A 30-minute upper bound
is far past the "few-minutes to answer one notification" SLO Flow B is designed
around, and is more than enough for the "stepped away from desk" scenario from
the additional probe.

> The probes did not search for the *exact* ceiling — they established
> "≥30 min works, no failure surface visible." Re-running with hours-long blocks
> would be worthwhile only if a real use-case demanded it; today's design does
> not.

---

## Q3 — Sequential multi-question flow in one session

**Answer: works exactly as the additional-probe description hoped.** Probe
**p5-multi-30s-default** (`/tmp/mcp-probe-D/stream-p5-multi-30s-default.jsonl`)
chained three `ask-brian` calls in one session, each waited ~31s for the
answer, and the agent **incorporated each previous answer into the next
question** before calling out again:

```jsonc
{"text":"Step 1: asking about favorite color."}
{"tool_use":"mcp__askbrian__ask-brian",
 "input":{"question":"Question 1: What is your favorite color?"}}
{"tool_result":"blue"}

{"text":"Step 2: incorporating \"blue\" into the next question."}
{"tool_use":"mcp__askbrian__ask-brian",
 "input":{"question":"Question 2: You said your favorite color is blue. What is one object that is that color?"}}
{"tool_result":"sky"}

{"text":"Step 3: incorporating both \"blue\" and \"sky\" into the final question."}
{"tool_use":"mcp__askbrian__ask-brian",
 "input":{"question":"Question 3: You named sky as the blue object. Where do you usually keep it?"}}
{"tool_result":"bedroom"}

{"tool_use":"Bash",
 "input":{"command":"echo \"ANSWERS color=blue object=sky location=bedroom\""}}
{"tool_result":"ANSWERS color=blue object=sky location=bedroom","is_error":false}

{"result":"success","is_error":false,"stop_reason":"end_turn",
 "num_turns":6,"duration_ms":109717,"permission_denials":[]}
// EXIT=0
```

This is the property that makes the MCP path strictly more capable than a
single-turn dossier-and-redispatch: the worker can converge on a decision over
multiple interactions inside ONE session, keeping the model's whole reasoning
context in scope. The model is the one deciding whether the prior answer
sufficed or another question is needed — it is not the runner stitching N
disconnected one-shot sessions together.

Implication for [[B4-worker-stuck]] and [[B1-dossier-builder]]: the dossier
need not pre-enumerate every possible question; the worker can ask the *first*
fork, get an answer, do more work, hit a *second* fork that only exists in
light of the first answer, and ask again — all in one bead's run.

---

## Q4 — Does `--permission-mode` matter? (default vs `acceptEdits`)

**Answer: no — substance and observability are identical.** Probe
**p6-30s-acceptEdits** (`/tmp/mcp-probe-E`) is byte-for-byte the same arc as
the default-mode p1 probe with one cosmetic difference (`permissionMode` in
`init` reads `acceptEdits` vs `default`); same `tool_use` sequence, same
`tool_result` shape, same `permission_denials: []`, same `exit 0`. The runner's
existing `--permission-mode acceptEdits` (`run-beads-tasks.sh:21`) is fine; this
research surfaces no reason to change it.

| Variant | mcp_server status | tool_result | exit | `is_error` | `permission_denials` |
|---|---|---|---:|---|---|
| p1 · `default` | connected | "blue" | 0 | false | `[]` |
| p6 · `acceptEdits` | connected | "blue" | 0 | false | `[]` |

This is consistent with the prior [[headless-stuck-signal]] finding that
permission mode does not shape the soft-fail / structured-denial behavior of
interactive tools either — `--permission-mode` is orthogonal to tool-call
substance in `-p`.

---

## Q5 — Hybrid: same MCP server in interactive Claude Code AND `claude -p`

**Answer: yes — by the architecture of MCP, with one Brian-side install
command.** MCP servers are configured at one of three scopes (project / user /
local) and are loaded into **every** Claude Code session at startup,
interactive or `-p` alike. There is nothing in the MCP transport layer that
distinguishes "is the human attached to this session" from "is the human
absent." From the MCP server's perspective both look identical: it gets a
`tools/call` JSON-RPC message and returns a `tools/call` response.

**Directly verified here** (`/tmp/mcp-probe-H/stream-hybrid.jsonl`): a
`claude -p` invocation **from a different cwd** (`/tmp/hybrid-caller`, no
`.mcp.json` of its own) loaded the MCP server via an absolute
`--mcp-config /tmp/mcp-probe-H/.mcp.json`, advertised
`tools_mcp=['mcp__askbrian__ask-brian']` in the `init` event, called the tool,
got the answer, exited 0. This is the structural equivalent of "the same MCP
server is reachable from any session, regardless of working directory" — which
is exactly what user-scope registration delivers automatically.

**Not directly verified here** (would require an attended interactive
terminal): an actual interactive Claude Code session is, by definition, run by
a human at a TTY. To prove the in-conversation flow end-to-end Brian should run
the following once:

```bash
# 1) Register the server at USER scope so EVERY future session sees it.
claude mcp add --scope user \
  -e PROBE_DIR=/tmp/mcp-probe-H \
  askbrian-probe -- node /tmp/mcp-probe-H/ask-brian-server.mjs

# 2) Confirm it's listed:
claude mcp list   # → "askbrian-probe: stdio · ✓ Connected" (line will appear)

# 3) Start an interactive Claude Code session in any dir and say:
#    "When you have questions for me during this session, call
#    mcp__askbrian-probe__ask-brian instead of asking me directly here.
#    Now: <some task that requires a decision>."
#
# Then in another shell, simulate answering:
echo "your-answer-here" > /tmp/mcp-probe-H/answer.txt
```

Step 3 is the only step this research cannot drive itself; everything *before*
step 3 (configuration, advertisement to the session, MCP `init` connection) is
mechanical and is provably the same whether the session is `-p` or interactive,
because the same `~/.claude.json` user-scope `mcpServers` entry is what
populates both — there is no separate "interactive MCP config" surface.

> Caveat (auto-classifier): user-scope registration is a persistent config
> change (`~/.claude.json` mutation), and the auto-mode classifier in this
> research session refused to make it on my behalf. That's the right default
> for an agent and is unrelated to the technical viability — the one-line
> command above is what an interactive Brian-driven setup would run. After
> deciding to adopt, register it once and it is in place for every session.

### Q5a — Laptop sleep mid-call (the "Brian on the bus" case)

**Answer: the tool call survives a paused MCP process up to at least 5 minutes
of frozen wall-clock, and the design degrades gracefully past that via the
existing daemon resume path.**

Real macOS sleep pauses every user-space process, so the *adversarial* variant
is "pause the MCP server child while the parent claude (the MCP client) is
still alive and could enforce a timeout." Probe **s1-stop120s** SIGSTOPped the
MCP server pid ~10s into its poll loop, held it for 120s, SIGCONT'd, wrote the
answer; **s2-stop300s** repeated with 300s. Both exited 0 with the answer
delivered:

```text
# s2-stop300s coordinator timeline:
03:03:14  claude -p starts
03:03:22  question.txt appears (MCP tool called)
03:03:32  SIGSTOP ask-brian-server.mjs pid 10281
03:08:32  SIGCONT pid 10281 after 300s pause
03:08:34  write answer.txt "after-5min-sleep"
03:08:35  server log: ANSWERED elapsedMs=313595 a="after-5min-sleep"
03:08:40  claude exits rc=0  (result.duration_ms=325172, permission_denials=[])
```

No transport-level keepalive fired, no MCP `init` reconnect was attempted, no
heartbeat killed the call. `claude -p` simply waited for stdio to become
readable again — which on real laptop sleep it will, when both processes
resume together.

**The 30-minute Q2 ceiling is the upper bound that matters for sleep too**, by
construction: real sleep advances wall-clock for both endpoints together, so
the relevant question is "how long is the tool call alive measured by
wall-clock between question and answer," which Q2 already answered for the
"laptop awake, Brian on his phone" case. The SIGSTOP probes additionally rule
out the more adversarial "client still ticking while server frozen" failure
mode.

**Beyond the 30-min envelope:** if Brian is away long enough that even the
relaxed envelope is exceeded, the **resume-with-context** mechanism in the
daemon (the same shape as today's worker-stuck flow) catches the case: the
worker bead's `--design` carries the structured ask; the dossier has already
been written to the hosted engine the moment the MCP call began (because the
server's first action is the write-to-engine, which is durable cloud-side); if
the parked tool call is eventually killed for any reason, the daemon notices
the answer arrived in the engine, kills the session, and re-dispatches the
worker with the answer spliced into context. Same shape as today, just
triggered later and by a less catastrophic event. So: **MCP is the happy path,
daemon resume is the safety net for the long tail** — same architecture, no new
build for the safety net.

---

## Q6 — What if the MCP server crashes mid-call?

Not directly tested but worth pre-empting in the contract. The expected
behaviors based on the SDK and on what *was* observed:

- **Server SIGSEGV / process exit mid-tool-call**: stdio EOF reaches the
  claude-side MCP client; the in-flight `tools/call` resolves with an error
  tool_result (model-visible). Behavior should match the soft-fail shape from
  [[headless-stuck-signal]] but with an MCP-specific error string — runner-side
  detection should treat any `is_error: true` on `mcp__askbrian__*` as a
  STUCK-equivalent failure that needs a restart cycle, not a content failure to
  hand back to the model.
- **Server hangs (no stdout, no stderr, no exit)**: this is exactly the
  SIGSTOP case from Q5a — claude waits forever. The daemon-resume path is the
  backstop here, gated on wall-clock-since-question-written rather than on any
  signal claude itself emits.

Recommendation: B4 implementer should **explicitly test SIGKILL of the MCP
server mid-call once** before shipping, to capture the precise tool_result
shape on this path; doing it now would expand scope beyond R1.

---

## Q7 — Side observation: `ToolSearch` adds 1 turn of overhead

Every probe shows the agent first calling
`ToolSearch(query="select:mcp__askbrian__ask-brian")` before the real MCP
call. This is the Claude Code harness's **deferred-tools resolution** — MCP
tool schemas are not loaded into the prompt at session start, only the *names*
are; the agent has to ask `ToolSearch` to load the schema before invoking the
tool. Effect: every session that uses `ask-brian` for the first time spends
**one turn (~1–3s)** on ToolSearch. After that the schema is in context and
later calls in the same session are direct (see Q3 — the multi-question probe
only has *one* ToolSearch turn, at the start, not one per `ask-brian` call).

Implications for the runner contract: **count this turn against
`--max-turns`**. The current worker runs with `--max-turns 200`
(`run-beads-tasks.sh:~640`), so a single extra turn is irrelevant — but B4
should not set the new structured-ask flow's `--max-turns` so tight that the
ToolSearch turn becomes the cause of a `max_turns` termination.

---

## Implementation contract — what B1/B4 actually build

Spelling this out so the recommendation is unambiguous for the downstream
beads:

1. **MCP server surface (B4-adjacent).** A stdio MCP server, single tool name
   `ask-brian` (or whatever final name lands), inputSchema:
   `{question: string, options?: string[], recommendation?: string, why?: string}`
   — the extra fields ride into the hosted-engine dossier so the Inbox renders
   the full ask, not just the literal `question` string. The server's
   `tools/call` handler:
   - **First action: write to the hosted engine** (the dossier write, durable
     cloud-side). This is what makes laptop sleep / process death survivable —
     the question is persisted *before* the poll loop starts.
   - Then poll a local "answer-arrived" surface every 1s.
   - Return the answer string as `content[0].text`. No `isError` set →
     `is_error: null` in the stream (Q1) — runner accepts this as success.

2. **Worker prompt (B1).** Keep today's prohibition on
   `AskUserQuestion/EnterPlanMode/ExitPlanMode` exactly as-is (the
   [[headless-stuck-signal]] research is unchanged by this finding). The
   positive instruction shifts from "do `bd update --status=blocked` +
   `bd human` + exit non-zero" to **"call `mcp__askbrian__ask-brian` with a
   structured ask; the tool will return Brian's answer; continue working with
   that answer."** Multi-question is allowed (Q3) — if a *second* fork emerges
   after the *first* answer, ask again rather than burning a whole
   stuck/redispatch cycle.

3. **Runner behavior (no change required to detection paths).** The
   `permission_denials[]` backstop from [[headless-stuck-signal]] stays in
   place — it catches the *forbidden* interactive tools if a worker slips. The
   MCP success path is structurally indistinguishable from any other tool call
   (Q1), so the runner needs no new "accept" logic. The only new awareness is
   the `is_error: null` MCP convention noted in Q1 — verify the existing
   `scan_stream_for_tool_errors` does not mistake null for "missing/anomalous."

4. **The bar stays exactly where it is (`the-bar-stays`).** [[the-bar-stays]]
   This research changes the *mechanism* of asking, not the *threshold* for
   asking. Today's worker prompt says: ask for human input ONLY when there is a
   genuine fork the agent must not resolve, not for ordinary hard work or as a
   substitute for thinking. Carry that sentence into the B1 prompt verbatim,
   replacing only the mechanic (`ask-brian` MCP tool) without softening the
   threshold. The cheaper round-trip makes prompt strictness *more* important,
   not less; if the threshold drifts, the failure mode is "Brian's phone
   becomes a chat console," which we explicitly do not want.

---

## Documentation cross-check

The MCP SDK and Claude Code MCP docs describe the stdio transport, the
`tools/list` / `tools/call` shape, and the user/project/local config scopes.
None of them document an upper bound on tool-call wall-clock duration, a stdio
keepalive interval, or a behavior on stdio pause/resume. The findings here are
therefore **empirical, version-pinned (claude 2.1.142, `@modelcontextprotocol/sdk`
current as of 2026-05-20), and subject to change without notice** — re-run the
30-min Q2 probe and the SIGSTOP Q5a probe on every `claude` upgrade. The
runner's safety must not depend on the "no ceiling" finding staying true —
hence the daemon-resume backstop in Q5a.

---

## Single clear recommendation

**Adopt the MCP-tool-blocking path as the interactive human-decision channel.**
Concretely:

1. **Build the MCP server.** Single stdio server, single `ask-brian` tool;
   first action of the tool body writes the structured ask to the hosted
   engine; then poll-and-return on the answer surface. ~80 lines of code (see
   `/tmp/mcp-probe/ask-brian-server.mjs` for a working reference).
2. **Register at user scope** (`claude mcp add --scope user askbrian -- node
   /path/to/server.mjs`) so it is in every session — `-p` worker, interactive,
   any future tool — without per-project setup. This makes the hybrid case
   (Brian-mid-conversation "route through ask-brian while I'm away") a free
   capability that requires no further build.
3. **Update worker prompt (B1)** to instruct calling `mcp__askbrian__ask-brian`
   as the positive deliberate path, while keeping today's prohibition on
   `AskUserQuestion/EnterPlanMode/ExitPlanMode` and the [[the-bar-stays]] bar
   verbatim. Multi-question in one session is allowed; serialize when the
   worker genuinely needs a second decision after acting on the first.
4. **Keep the existing `permission_denials[]` backstop and `--disallowedTools`
   guardrail** from [[headless-stuck-signal]] as-is — this research finding
   complements that one, it does not replace it. The MCP path is the *positive*
   instruction; the deny-list and the denial-scan remain the *negative*
   instructions.
5. **Keep the daemon-resume long-tail backstop.** If a tool call ever does get
   killed (SIGKILL of the server, OS crash, hours-long lid-close past our
   30-min observed envelope), the dossier was already written cloud-side at
   the start of the call (point 1), so the daemon's existing resume-with-
   context mechanism can splice the answer into the next worker dispatch with
   no work lost.
6. **Re-run probes on every `claude` upgrade.** Specifically the 30-min Q2
   probe and the 5-min SIGSTOP Q5a probe — they are the load-bearing claims
   about an undocumented harness behavior.

Implementation of 1–6 is deliberately out of scope for this bead (research
only); these are inputs to [[B1-dossier-builder]] (`claude-tools-n34`) and
[[B4-worker-stuck]] (`claude-tools-cf6`). The Agent SDK / `canUseTool` path
(R2) remains paused per the subscription/API billing finding referenced in the
bead — there is no longer a reason to revisit it pre-R1-ship, because MCP gives
us the interactive channel inside the subscription envelope.
