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

## Q6 — What if the MCP server crashes mid-call? (SIGKILL probe, B5)

**Answer (now evidence-backed): the tool_result is `is_error: true` with
`content: "MCP error -32000: Connection closed"` (a *string*, not the usual
`content[]` array), the model is then free to retry, claude's MCP client
**auto-respawns the stdio server process** on the retry, and the session ends
with a normal `result` envelope (`subtype: success, is_error: false,
stop_reason: end_turn, permission_denials: []`, exit 0) regardless of whether
the retry succeeded or the model gave up.** R1's prediction was directionally
right but materially incomplete on three points (model-decided retry, automatic
server respawn, no non-zero exit) — corrections inline below.

Performed against B5's probe sandbox (`/Users/brianbutler/code/claude-tools/.b5-probe`):
same shape as R1 — single stdio MCP server `ask-brian`, writes
`question.txt`, polls `answer.txt`, returns answer; same `claude 2.1.142`;
model `claude-opus-4-7[1m]`; `--strict-mcp-config --permission-mode acceptEdits
--allowedTools "mcp__askbrian__ask-brian" "Bash"`.

### Probe matrix

| Probe | When the SIGKILL lands | What we observed | Final `result` envelope | exit |
|---|---|---|---|---|
| **p1-kill-mid** | ~10s into the poll loop, server pid known via pidfile, no answer ever planted | Error tool_result → model retried → claude **auto-respawned** the server (new pid, fresh `STARTED`/`CONNECTED` lines ~3s later) → retry polled indefinitely → after coordinator-imposed wall-clock SIGTERM, second call also resolved as `Connection closed` → model produced a brief text and ended | `subtype: success, is_error: false, stop_reason: end_turn, num_turns: 4, duration_ms: 322229, permission_denials: []` | 0 |
| **p2-retry-recovers** | ~10s into the poll loop, then `answer.txt` planted as soon as the respawn appeared | First call errored → model retried → respawned server got the (re-written) question and the planted answer → normal text tool_result back → Bash echo → end | `subtype: success, is_error: false, stop_reason: end_turn, num_turns: 5, duration_ms: 22995, permission_denials: []` | 0 |
| **p3-kill-early** | Before `question.txt` was ever written (server held in a pre-write sleep, killed ~2s in) | Same error tool_result → **model chose not to retry** ("The `mcp__askbrian__ask-brian` tool failed with 'MCP error -32000: Connection closed' — the MCP server appears to be down, so there's no answer to echo.") → end turn | `subtype: success, is_error: false, stop_reason: end_turn, num_turns: 3, duration_ms: 15087, permission_denials: []` | 0 |

The answerer-process variant from the bead's spec was skipped — the engine-side
answer surface is not plumbed into the probe (R1 didn't need it either), and
the variants above already isolate the stdio-EOF path the engine-write failure
would reduce to.

### Precise shape of the failed `tool_result` (the load-bearing fact for B2)

From every probe, byte-for-byte the same shape:

```jsonc
{"type":"user",
 "message":{
   "role":"user",
   "content":[{
     "type":"tool_result",
     "tool_use_id":"toolu_01McHFFAraosjxqzVdaspD17",
     "content":"MCP error -32000: Connection closed",   // ← string, not [{type:"text",text:"..."}]
     "is_error":true
   }]
 },
 // sibling field, sibling of message:
 "tool_use_result":"Error: MCP error -32000: Connection closed",
 ...
}
```

Three details B2 should not get wrong:

1. **`is_error: true` literally** — not `null`, not `false`, not absent. This is
   the inverse of the Q1 success shape (`is_error: null`) and the inverse of
   native-tool success (`is_error: false`). The `null`/`true`/`false` triple
   is real and must all be handled by `scan_stream_for_tool_errors`.
2. **`content` is a JSON *string*, not an array of typed blocks.** A successful
   MCP call returns `content:[{type:"text",text:"…"}]`; a failed MCP call
   returns `content:"MCP error -32000: …"`. A jq path that assumes `content[0].text`
   will throw on the failure path. Use `if (.content|type)=="string" then .content
   else .content[0].text end`, or scan `.content|tostring` for the literal
   `"Connection closed"` substring.
3. **The sibling `tool_use_result` is a *string* on this path** (`"Error: MCP
   error -32000: Connection closed"`), not an object like on success. Same
   caveat for any jq path that assumed `.tool_use_result.<something>`.

The error code (`-32000`) and message (`Connection closed`) are
JSON-RPC-2.0-shaped — they come from the MCP SDK's client-side detection of
stdio EOF on an in-flight `tools/call`, not from our server.

### Three behaviors that overturn the R1 prediction

R1 §Q6 (now this section's old body) said: *"runner-side detection should
treat any `is_error: true` on `mcp__askbrian__*` as a STUCK-equivalent failure
that needs a restart cycle, not a content failure to hand back to the model."*
The probes show that contract is **too simple** on three axes:

- **Claude already runs a "restart cycle" of its own.** On the retry attempt
  in p1 and p2, the MCP client respawned the stdio server process from scratch
  — new pid, new `STARTED`/`CONNECTED`/`CALL` lifecycle in the server log,
  about 3s after the SIGKILL. The runner does **not** have to kill the
  session and re-dispatch to "restart" the server; claude does it for us. The
  runner-level restart cycle is only needed when claude's own respawn does not
  produce a final success — i.e. when the *session* has irrecoverably failed,
  not when the *call* failed once.
- **Whether the model retries at all is non-deterministic.** Same model
  (`claude-opus-4-7`), same probe scaffold, same MCP error string: p1 and p2
  retried, p3 did not. Treat retry-vs-give-up as a model-policy variable, not
  a harness guarantee. The B2 contract must not depend on "claude will retry";
  it must look at *what actually happened in the stream*.
- **The session never exits non-zero on MCP failure.** All three probes end
  with `result.is_error: false`, `stop_reason: end_turn`, exit 0 — even when
  the model gave up because the tool truly stayed broken (p3) and even when
  the wall-clock had to be cut by an external SIGTERM (p1). `permission_denials`
  stays `[]` in every case. The two backstop signals the runner already relies
  on for headless-stuck detection (non-zero exit, populated
  `permission_denials[]`) **do not fire on MCP failure**. R1's "treat is_error
  true as STUCK" instinct was right; the *mechanism* must be a stream scan,
  not an exit-code or permission-denials check.

### Corrected runner-side detection contract (for B2)

Scan the stream-json for tool_result events whose tool corresponds to an
`mcp__*` tool call (resolve via `tool_use_id`) **and** match either:

- `is_error: true` with `content` (as string) containing
  `MCP error -32000: Connection closed`, OR
- any future MCP-transport error code in the `-32xxx` range with `is_error: true`
  and `content` as a bare string (i.e. the MCP-SDK transport-error shape, not a
  tool-body-emitted content error).

Then classify by **what happened next in the same stream** for that tool name:

| Subsequent same-tool result in stream | Classification | Action |
|---|---|---|
| A later `is_error: false` (or `null`) MCP tool_result with a normal `content[]` text array | **Self-healed** (claude's auto-respawn + model retry worked) | Log a transient-failure warning; do **not** kill the session. Idempotency note for the engine: the MCP server's first-action dossier write ran twice — the engine writer must be replay-safe by content hash or write-once, since R1's contract §1 made the dossier write the server's first action. |
| Another `Connection closed` error, then the session ends with `stop_reason: end_turn` | **Model gave up cleanly** | Treat as STUCK-equivalent: the worker's bead has a question in flight cloud-side; daemon-resume must catch the eventual answer and re-dispatch the worker. Do *not* close the bead as completed just because exit is 0. |
| Stream ends with no further same-tool event AND no `result` envelope | **Session hung** (the `mcp__askbrian__ask-brian` retry is blocked, no signal) | Wall-clock cap from outside; treat as STUCK-equivalent and SIGTERM the session. Observed once (p1 before our coordinator's SIGTERM at 240s of dead-retry waiting). |
| Stream ends with `result.is_error: false stop_reason: end_turn` and the only same-tool result was the `Connection closed` one (no retry attempted) | **Model declined to retry** | Same as "model gave up cleanly" — daemon-resume is the recovery path. |

The detection cannot live in `scan_stream_for_tool_errors`'s current shape (which
only flags the *first* tool failure) — it has to keep state per `tool_use_id`
across the whole stream. The simplest implementation is a single jq pass at
session end that walks all `tool_result` events tagged `mcp__*` and classifies
the *last* one per tool-name.

### Side observations

- **Server log evidence of the auto-respawn** (p1, abridged): pid `25753`
  `STARTED → CONNECTED → CALL → STILL_WAITING` → SIGKILL by us → ~3s later
  pid `25808` `STARTED → CONNECTED → CALL → WROTE_QUESTION → STILL_WAITING…`
  No reconnect signal was visible in the stream-json — the new connection is a
  fresh process invisible to the model and detectable only by externally
  observing the OS-level pid lifecycle. **Implication for B2**: the MCP
  server's `tools/call` handler MUST be safe to run twice in quick succession
  (idempotent dossier write), because claude's retry will invoke a fresh
  process that has none of the first process's state.
- **`run-*.log` (claude's own stderr) is empty on all three failure paths.**
  No MCP transport warning to stderr, no "respawning server" log line, no
  exit-time complaint. The only externally-visible signal of the failure is
  the stream-json itself — which makes the stream-scan detection above the
  *only* runner-side mechanism that can see what happened.
- **No transport-level "init" reconnection event in stream-json.** The
  `system/init` event with `mcp_servers: [{status: "connected"}]` only fires
  once at session start. The respawn is silent in the stream — `tools/call`
  is reissued on the fresh pipe and either succeeds or errors again, no
  separate "server reconnected" signal. This is a contrast with how the runner
  might naively probe MCP health post-failure.

### What the daemon-resume backstop still needs to catch

Two cases from the matrix where the worker session ended cleanly (exit 0) but
the dossier remained unanswered cloud-side:

- p3 (model declined to retry): worker session is done; the cloud has a
  dossier with no answer yet. Daemon's existing resume-with-context flow
  triggers when the answer arrives and re-dispatches the worker. **Same shape
  as the parked-tool-call backstop from Q5a — the case has not actually
  changed; only the trigger went from "30-min envelope exceeded" to "model
  gave up early on transport failure."**
- p1 (model retried, retry hung past wall-clock): when an outer mechanism
  (the worker bead's hard wall-clock cap, or a `bd` watchdog) eventually
  SIGTERMs the worker, the second MCP call resolves as `Connection closed`,
  the model ends with `end_turn`, exit 0. Same recovery path as p3.

So: **runner does not need a new restart mechanism**; it needs (a) the
stream-scan classifier above, and (b) the dossier-write idempotency note
forwarded to B2 so the cloud engine handles the duplicate write on auto-retry.
The daemon-resume path stays exactly as designed.

### Artifacts

Probe scripts, stream-json captures, and server logs are in
`/Users/brianbutler/code/claude-tools/.b5-probe/` (local to this repo, gitignored).
The throwaway sandbox was used in lieu of `/tmp/mcp-probe*` because this
session's tool sandbox declined to write under `/tmp`.

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
