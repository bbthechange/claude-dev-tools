#!/usr/bin/env node
// mcp-ask-workspace — stdio MCP server exposing ONE tool: ask-workspace.
//
// "The ask-brian pattern pointed sideways" (DESIGN K §0; claude-tools-uxvk1).
// A FORK of mcp-askbrian/server.mjs: an agent in workspace A hits a question
// whose answer lives in a sibling workspace B and calls this tool. The server:
//
//   1. ROUTE — resolve B's local path from the daemon workspace registry
//      (~/.config/claude-tools/workspaces.json) by `to_ws` == project_ref.
//      `from_ws` is NOT a trusted input — it is resolved server-side from this
//      server's own cwd/PROJECT_REF (the same resolveProjectRef ask-brian
//      ships), exactly as the engine overwrites a wire principal.
//   2. SPAWN A READ-ONLY RESPONDER — a fresh `claude -p` via the
//      `specialist.sh --kind=xws-responder` hat at `cwd = B` (the reconciler/
//      enricher read-only permission set + a no-recursion guard; DESIGN K §2.1).
//      It runs PARALLEL to B's serial writer and is safe to do so because it is
//      read-only (takes no writer lease, cannot touch the tree). Time-budgeted;
//      BLOCKS until it returns one of two verdicts.
//   3. THE VERDICT SPLIT (DESIGN K §1.4 / §2.2):
//        • answer  (the mechanical 80%) → relay-log-append(resolved) + a batched
//          `timed-fyi` notification (emit_fyi → xws:<from_ws>; DESIGN K §4.2 item
//          1, claude-tools-mhcp.1) so K3's rollup batches it, then return the
//          answer to A as the tool_result. A resumes in-session.
//        • escalate (a conflict or missing design — the 20%) → reuse the
//          INHERITED ask-brian dossier-publish-and-block path VERBATIM
//          (id_for → write_fallback → poll), relay-log-append(escalated +
//          dossier_ref), and return Brian's ruling to A as the tool_result.
//          (DESIGN K §5 / claude-tools-uxvk4 owns the conflict/missing-design
//          dossier refinement + conformance; K1 routes the verdict through the
//          inherited path so the server is complete and shippable.)
//   4. RETURN — { content:[{type:"text", text}] } with isError UNSET so
//      tool_result.is_error is null per R1 Q1 (the runner's
//      scan_stream_for_tool_errors must treat null as success) — fork-parity
//      with the ask-brian request/response framing.
//
// Same-machine assumption (DESIGN K §1.2, made explicit): A and B are two
// workspaces the same daemon manages on one host. A `to_ws` with no registry
// row returns a terse, actionable error — NEVER a fabricated answer.
//
// Auth: COORDINATOR_URL + COORDINATOR_TOKEN passed via the user-scope
// `claude mcp add ask-workspace --scope user -e …` flags (the relay ops are
// CF-only; the escalation leg is the inherited engine bridge).

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "node:child_process";
import { mkdirSync, appendFileSync, existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

// ── paths ───────────────────────────────────────────────────────────────────
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// The engine bridge: id_for/write_polished/write_fallback/poll_once for the §5
// ESCALATION leg + relay_log_append/-tail for the answer leg. Overridable so the
// K4 (claude-tools-uxvk4) conformance test can drive the FULL escalate→blocking-
// dossier→ruling round-trip deterministically — stubbing out the slow jq store
// ops the real bridge inherits from ask-brian — exactly as XWS_SPECIALIST_BIN
// stubs the responder. Unset in prod ⇒ the real engine-bridge.sh is used.
const BRIDGE_PATH =
  process.env.XWS_BRIDGE_BIN || join(__dirname, "helpers", "engine-bridge.sh");
// The read-only responder is spawned through the canonical hat shim
// (specialist.sh --kind=xws-responder) so the permission lockdown lives in ONE
// place (DESIGN K §2.1; must-protect #11). Overridable for the offline smoke.
const DEFAULT_SPECIALIST_BIN = resolve(
  __dirname,
  "..",
  "beads-runner",
  "agents",
  "specialist.sh",
);
const SPECIALIST_BIN = process.env.XWS_SPECIALIST_BIN || DEFAULT_SPECIALIST_BIN;

// The daemon workspace registry (project_ref → dir). Overridable for tests.
const REGISTRY_PATH =
  process.env.XWS_REGISTRY_PATH ||
  join(homedir(), ".config", "claude-tools", "workspaces.json");

// ── tunables ────────────────────────────────────────────────────────────────
// Same headroom rationale as the ask-brian builder (claude-tools-cxj): a real
// read-only responder run (Read/Grep over B + a verdict) is bounded at 5 min;
// a genuine hang is killed at the ceiling, not mid-thought.
const RESPONDER_TIMEOUT_MS = parseInt(
  process.env.RESPONDER_TIMEOUT_MS || "300000",
  10,
);
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || "1000", 10);
const POLL_MAX_MS = parseInt(
  process.env.POLL_MAX_MS || String(6 * 60 * 60 * 1000), // 6h hard ceiling
  10,
);
// Optional model override for the responder; absent ⇒ specialist.sh's default.
const RESPONDER_MODEL = process.env.RESPONDER_MODEL || "";
const CHILD_OUTPUT_CAP_BYTES = parseInt(
  process.env.CHILD_OUTPUT_CAP_BYTES || String(4 * 1024 * 1024),
  10,
);

// ── logging ─────────────────────────────────────────────────────────────────
const LOG_DIR = join(homedir(), ".cache", "claude-tools");
const LOG_PATH = join(LOG_DIR, "mcp-ask-workspace.log");
try {
  mkdirSync(LOG_DIR, { recursive: true });
} catch {}

function logLine(obj) {
  const line = JSON.stringify({ ts: new Date().toISOString(), pid: process.pid, ...obj }) + "\n";
  try {
    appendFileSync(LOG_PATH, line);
  } catch {}
  try {
    process.stderr.write(line);
  } catch {}
}

function hash(s) {
  return createHash("sha256").update(String(s || "")).digest("hex").slice(0, 16);
}

// CF.1's safeKey predicate, mirrored Node-side so we never hand the registry /
// filesystem a `to_ws` the engine would reject anyway: [A-Za-z0-9._-], no "..".
function safeKey(k) {
  return typeof k === "string" && k.length > 0 && /^[A-Za-z0-9._-]+$/.test(k) && !k.includes("..");
}

// PROJECT_REF resolution = `from_ws` (DESIGN K §1.1: from_ws is resolved
// server-side, never a trusted input): env → cwd's .beads/runner.sh PROJECT_REF=
// line → basename(cwd). Same resolver ask-brian ships.
function resolveProjectRef(cwd) {
  if (process.env.PROJECT_REF) return process.env.PROJECT_REF;
  const cfg = join(cwd, ".beads", "runner.sh");
  if (existsSync(cfg)) {
    try {
      const txt = readFileSync(cfg, "utf8");
      const m = txt.match(/^\s*PROJECT_REF\s*=\s*["']?([^"'\s#]+)/m);
      if (m) return m[1];
    } catch {}
  }
  return basename(cwd);
}

// ── routing — registry lookup (DESIGN K §1.2) ────────────────────────────────
// Resolve `to_ws` → B's absolute dir from the daemon workspace registry. Returns
// { ok:true, dir } or { ok:false, reason } — a miss is a terse, actionable
// error (A proceeds on its own judgment or files a bead), NEVER a fabricated
// answer. Same-machine only; cross-machine is the deferred §13 bucket.
function resolveWorkspaceDir(to_ws) {
  if (!existsSync(REGISTRY_PATH)) {
    return { ok: false, reason: `workspace registry not found at ${REGISTRY_PATH} (is the daemon configured on this machine?)` };
  }
  let reg;
  try {
    reg = JSON.parse(readFileSync(REGISTRY_PATH, "utf8"));
  } catch (e) {
    return { ok: false, reason: `workspace registry ${REGISTRY_PATH} is not valid JSON: ${String(e).slice(0, 120)}` };
  }
  const rows = (reg && Array.isArray(reg.workspaces)) ? reg.workspaces : [];
  const row = rows.find((r) => r && r.project_ref === to_ws);
  if (!row) {
    const known = rows.map((r) => r && r.project_ref).filter(Boolean).join(", ") || "(none)";
    return { ok: false, reason: `no workspace registered with project_ref='${to_ws}' on this machine. Known: ${known}.` };
  }
  const dir = row.dir || "";
  if (!dir || !existsSync(dir)) {
    return { ok: false, reason: `workspace '${to_ws}' resolves to dir='${dir}' which does not exist on this machine.` };
  }
  try {
    if (!statSync(dir).isDirectory()) {
      return { ok: false, reason: `workspace '${to_ws}' dir='${dir}' is not a directory.` };
    }
  } catch {
    return { ok: false, reason: `workspace '${to_ws}' dir='${dir}' is not statable.` };
  }
  return { ok: true, dir };
}

// ── graceful-shutdown latch (inherited from ask-brian) ───────────────────────
const SHUTDOWN_DRAIN_MS = parseInt(process.env.SHUTDOWN_DRAIN_MS || "25000", 10);
let in_flight = 0;
let shutting_down = false;
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    if (shutting_down) return;
    shutting_down = true;
    logLine({ event: "signal", sig, in_flight, drain_cap_ms: SHUTDOWN_DRAIN_MS });
    const t0 = Date.now();
    const wait = setInterval(() => {
      if (in_flight === 0 || Date.now() - t0 >= SHUTDOWN_DRAIN_MS) {
        clearInterval(wait);
        logLine({ event: "shutdown_exit", drained: in_flight === 0, remaining_in_flight: in_flight });
        process.exit(0);
      }
    }, 200);
  });
}

// ── child-process helpers ───────────────────────────────────────────────────
function runBridge(subcmd, args, { stdin } = {}) {
  return new Promise((resolveP) => {
    const child = spawn("bash", [BRIDGE_PATH, subcmd, ...args], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
    let out = "";
    let err = "";
    let capped = false;
    const onChunk = (which) => (d) => {
      if (capped) return;
      if (which === "stdout") out += d.toString();
      else err += d.toString();
      if (out.length + err.length > CHILD_OUTPUT_CAP_BYTES) {
        capped = true;
        try {
          child.kill("SIGKILL");
        } catch {}
      }
    };
    child.stdout.on("data", onChunk("stdout"));
    child.stderr.on("data", onChunk("stderr"));
    child.on("error", (e) => resolveP({ rc: -1, stdout: "", stderr: String(e) }));
    child.on("close", (code) =>
      resolveP({
        rc: capped ? -1 : (code ?? -1),
        stdout: out,
        stderr: capped ? err + "\n[mcp-ask-workspace: bridge output capped]" : err,
      }),
    );
    if (stdin != null) {
      try {
        child.stdin.write(stdin);
      } catch {}
    }
    try {
      child.stdin.end();
    } catch {}
  });
}

// runResponder — spawn the read-only responder via specialist.sh at cwd = B and
// block until it returns a verdict (or times out). specialist.sh runs `claude -p`
// with the xws-responder hat and prints the model's final result text on stdout;
// we parse that text (fence-strip + first-JSON-object) into a verdict object.
// Returns:
//   { ok:true,  verdict }                 — parsed a {verdict: answer|escalate}
//   { ok:false, reason, raw, spawnFail }  — no parseable verdict; spawnFail=true
//                                           means infra (no output / timeout /
//                                           nonzero exit with nothing usable).
function runResponder({ workspaceDir, responderInput }) {
  return new Promise((resolveP) => {
    if (!existsSync(SPECIALIST_BIN)) {
      resolveP({ ok: false, reason: `specialist shim not found at ${SPECIALIST_BIN}`, spawnFail: true, elapsedMs: 0 });
      return;
    }
    const args = [
      SPECIALIST_BIN,
      "--kind",
      "xws-responder",
      "--workspace",
      workspaceDir,
    ];
    if (RESPONDER_MODEL) args.push("--model", RESPONDER_MODEL);

    const t0 = Date.now();
    // detached:true makes the bash child its OWN process-group leader, so we can
    // signal the WHOLE tree. specialist.sh runs the real `claude -p` inside a
    // `( cd …; claude … )` subshell — a SIGTERM/SIGKILL to the bash pid alone
    // does NOT reach that grandchild (it reparents to init and keeps burning its
    // max-turns token budget for the full timeout). The ask-brian fork source
    // spawns `claude` directly so `child.kill` suffices; the specialist.sh
    // indirection re-introduces the grandchild, so we group-kill here.
    const child = spawn("bash", args, {
      stdio: ["pipe", "pipe", "pipe"],
      cwd: workspaceDir,
      env: process.env,
      detached: true,
    });
    // Kill the responder's whole process group (bash + the claude grandchild).
    // Fall back to a direct child kill if the group send fails (e.g. the child
    // never became a group leader).
    const killTree = (sig) => {
      try {
        if (child.pid) process.kill(-child.pid, sig);
      } catch {}
      try {
        child.kill(sig);
      } catch {}
    };
    let stdoutBuf = "";
    let stderrBuf = "";
    let capped = false;
    let finished = false;
    const finish = (payload) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolveP({ ...payload, elapsedMs: Date.now() - t0 });
    };
    const timer = setTimeout(() => {
      killTree("SIGTERM");
      setTimeout(() => killTree("SIGKILL"), 5000);
      finish({ ok: false, reason: `responder timed out after ${RESPONDER_TIMEOUT_MS}ms`, spawnFail: true });
    }, RESPONDER_TIMEOUT_MS);

    const onChunk = (which) => (d) => {
      if (capped) return;
      if (which === "stdout") stdoutBuf += d.toString();
      else stderrBuf += d.toString();
      if (stdoutBuf.length + stderrBuf.length > CHILD_OUTPUT_CAP_BYTES) {
        capped = true;
        killTree("SIGKILL");
        finish({ ok: false, reason: `responder output exceeded ${CHILD_OUTPUT_CAP_BYTES} bytes; killed`, spawnFail: true });
      }
    };
    child.stdout.on("data", onChunk("stdout"));
    child.stderr.on("data", onChunk("stderr"));
    child.on("error", (e) => finish({ ok: false, reason: `responder spawn error: ${e.message}`, spawnFail: true }));
    child.on("close", (code) => {
      if (finished) return;
      const text = stdoutBuf.trim();
      if (!text) {
        finish({
          ok: false,
          reason: `responder produced no output (exit ${code}); stderr: ${stderrBuf.trim().slice(0, 300)}`,
          spawnFail: true,
        });
        return;
      }
      // The responder spec says: ONE JSON object on stdout, no fence, no
      // narration. Be defensive about a stray fence / leading sentence.
      const cleaned = stripJsonFence(text).trim();
      let verdict = null;
      try {
        verdict = JSON.parse(cleaned);
      } catch {
        const extracted = extractFirstJsonObject(cleaned);
        if (extracted) {
          try {
            verdict = JSON.parse(extracted);
          } catch {}
        }
      }
      if (!verdict || typeof verdict !== "object" || (verdict.verdict !== "answer" && verdict.verdict !== "escalate")) {
        // Output present but not a clean verdict — the model said SOMETHING.
        // Not a spawn failure: the caller escalates-to-safe (§2.2 conservative
        // default), never fabricates an answer.
        finish({ ok: false, reason: "responder output is not a {verdict: answer|escalate} object", raw: cleaned.slice(0, 600), spawnFail: false });
        return;
      }
      finish({ ok: true, verdict });
    });
    try {
      child.stdin.write(responderInput);
    } catch {}
    try {
      child.stdin.end();
    } catch {}
  });
}

function stripJsonFence(s) {
  const m = s.match(/^```(?:json)?\s*\n([\s\S]*?)\n```\s*$/);
  return m ? m[1] : s;
}

function extractFirstJsonObject(s) {
  const start = s.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') {
      inStr = true;
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return s.slice(start, i + 1);
    }
  }
  return null;
}

// ── responder input assembly ─────────────────────────────────────────────────
// The stdin the xws-responder hat reads: the cross-WS question + the asking
// agent's framing. from_ws/to_ws are server-resolved; the responder answers
// ONLY from B's evidence (question-in/answer-out).
function buildResponderInput({ from_ws, to_ws, workspace_dir, args }) {
  return JSON.stringify({
    role: "cross-workspace-responder",
    from_ws,
    to_ws,
    workspace_dir,
    question: args.question,
    context_dump: args.context_dump || "",
    bead_ref: args.bead_ref,
  });
}

// ── escalation worker_ask normalization (inherited from ask-brian, fed by the
//    responder's structured escalate verdict instead of the raw tool args) ────
function emptyCB() {
  return { creates: [], unblocks: [], labels: [], status_changes: [] };
}
function normalizeOptions(options) {
  if (!Array.isArray(options)) return [];
  return options.map((o, i) => {
    const opt = o && typeof o === "object" ? o : {};
    const option_id = opt.option_id || opt.id || `opt-${i + 1}`;
    const label = opt.label || option_id;
    const blast_radius = opt.blast_radius || "(blast radius not provided by the responder)";
    const consequence_block =
      opt.consequence_block && typeof opt.consequence_block === "object" ? opt.consequence_block : emptyCB();
    return { option_id, label, blast_radius, consequence_block };
  });
}
function normalizeRecommendation(rec, opts) {
  const fallbackWhy = "The responder emitted this as its recommendation in the escalate verdict; the human is asked to confirm.";
  if (!rec) return opts.length > 0 ? { value: opts[0].option_id, why: fallbackWhy } : null;
  if (typeof rec === "string") return { value: rec, why: fallbackWhy };
  if (typeof rec === "object") {
    const value = rec.value || rec.option_id || (opts[0] && opts[0].option_id) || "";
    const why = rec.why && String(rec.why).trim() ? rec.why : fallbackWhy;
    return { value, why };
  }
  return { value: String(rec), why: fallbackWhy };
}
// Map the responder's escalate verdict onto the §5 worker_ask the inherited
// write_fallback (dg_from_worker_ask) consumes. The conflict/missing-design
// framing becomes the dossier the human rules on.
function escalateToWorkerAsk({ from_ws, to_ws, verdict }) {
  const summary = verdict.summary || `Cross-workspace ${verdict.reason || "conflict"} between ${from_ws} and ${to_ws}.`;
  const claims = Array.isArray(verdict.conflicting_claims) ? verdict.conflicting_claims : [];
  const askLines = [summary];
  if (claims.length) askLines.push("Conflicting claims:\n- " + claims.join("\n- "));
  const ask = askLines.join("\n\n");
  const options = normalizeOptions(verdict.options);
  return {
    tldr: summary,
    ask,
    options,
    recommendation: normalizeRecommendation(verdict.recommendation, options),
    reversible: verdict.reversible || `A cross-workspace ${verdict.reason || "contract"} decision; picking a side foreclues the other until re-opened.`,
  };
}

function formatOneAnswer(ans) {
  const parts = [];
  const label = ans.chosen_label || ans.chosen || "(answered)";
  parts.push(`Brian's answer: ${label}`);
  if (ans.chosen && ans.chosen !== label) parts.push(`Selected option_id: ${ans.chosen}`);
  if (ans.chosen_blast_radius) parts.push(`Blast radius: ${ans.chosen_blast_radius}`);
  if (ans.free_text) parts.push(`Free-text note: ${ans.free_text}`);
  return parts.join("\n");
}
function formatRuling(payload) {
  const items = Array.isArray(payload && payload.items) ? payload.items : [];
  if (items.length === 0) return "Brian's ruling: (the dossier resolved with no per-item decision — see his Inbox).";
  if (items.length === 1) return formatOneAnswer(items[0]);
  const blocks = [`Brian answered all ${items.length} items in this dossier. Apply ALL of them; do not re-ask any item.`, ""];
  items.forEach((ans, i) => {
    blocks.push(`── Item ${i + 1}/${items.length} (${ans.item_id || "?"}) ──`);
    if (ans.ask) blocks.push(`Ask: ${ans.ask}`);
    blocks.push(formatOneAnswer(ans));
    blocks.push("");
  });
  return blocks.join("\n").trimEnd();
}

function formatAnswerVerdict({ to_ws, verdict }) {
  const parts = [`Workspace ${to_ws} answered:`, "", String(verdict.answer || "(no answer text)")];
  const ev = Array.isArray(verdict.evidence) ? verdict.evidence.filter(Boolean) : [];
  if (ev.length) parts.push("", `Evidence: ${ev.join(", ")}`);
  return parts.join("\n");
}

// Append one relay_log row (tolerant: a relay-append miss is logged, never
// fails the tool call — the answer/ruling already landed in A and the dossier,
// on escalate, is durable cloud-side; the relay log is an audit trail).
async function relayAppend({ exchange_id, from_ws, to_ws, question, answer, outcome, dossier_ref, call_id }) {
  const exchange = {
    exchange_id,
    project_ref: from_ws,
    from_ws,
    to_ws,
    question: question || "",
    answer: answer || "",
    outcome,
    dossier_ref: dossier_ref || "",
  };
  const r = await runBridge("relay_log_append", [JSON.stringify(exchange)]);
  if (r.rc !== 0) {
    logLine({ event: "relay_append_warn", call_id, outcome, rc: r.rc, stderr: (r.stderr || "").slice(0, 200) });
  } else {
    logLine({ event: "relay_append_ok", call_id, exchange_id, outcome });
  }
}

// Emit ONE digest-eligible timed-fyi notification for an ANSWERED exchange
// (DESIGN K §4.2 item 1; claude-tools-mhcp.1) so K3's read-side rollup
// (no_digest) batches it into ONE daily digest entry — the C4 "always FYI"
// promise for the mechanical-80% answer path (without it, ONLY the 20%
// escalations notify, via the inherited dossier emit). The bridge builds the
// cross-WS channel (xws:<from_ws>) and stamps `ref`=the exchange_id (the relay
// row this FYI announces; the digest expands via relay-log-tail). Tolerant like
// relayAppend: a miss is logged, NEVER fails the tool — the answer already
// landed in A and the relay row is the durable audit trail; an FYI is a
// notification, never a gate.
async function emitFyi({ exchange_id, from_ws, call_id }) {
  const r = await runBridge("emit_fyi", [from_ws, exchange_id]);
  if (r.rc !== 0) {
    logLine({ event: "emit_fyi_warn", call_id, from_ws, rc: r.rc, stderr: (r.stderr || "").slice(0, 200) });
  } else {
    logLine({ event: "emit_fyi_ok", call_id, exchange_id, from_ws });
  }
}

// ── the one tool ────────────────────────────────────────────────────────────
const TOOL_NAME = "ask-workspace";

const server = new Server(
  { name: "ask-workspace", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: TOOL_NAME,
      description:
        "Ask an agent in a SIBLING workspace a question whose answer lives in that workspace's code/docs/bd (e.g. 'is the cancel endpoint deployed and what's its response shape?'). Routes to the target workspace, spawns a READ-ONLY responder there, and BLOCKS until it answers. The mechanical 80% returns the answer directly as the tool_result; a real cross-workspace contract conflict or a missing design escalates to a blocking decision for Brian and returns his ruling. Use for genuine cross-workspace dependencies — not for questions you can answer from your own workspace.",
      inputSchema: {
        type: "object",
        properties: {
          to_ws: {
            type: "string",
            description: "The TARGET workspace's project_ref (the daemon registry key, e.g. 'BE'). The question is routed there.",
          },
          question: {
            type: "string",
            description: "One-sentence question for the target workspace (e.g. 'Is DELETE /orders/:id deployed and what does it return?').",
          },
          context_dump: {
            type: "string",
            description: "Your framing and assumptions from THIS workspace (what you assume the contract is, why you're asking) so the responder can detect a conflict.",
          },
          bead_ref: {
            type: "string",
            description: "The bd issue id YOU (the asking workspace) are working on. Used for relay attribution + one-fork-one-dossier dedupe on escalation.",
          },
        },
        required: ["to_ws", "question", "context_dump", "bead_ref"],
      },
    },
  ],
}));

function textResult(text) {
  // R1 Q1: leave isError UNSET so tool_result.is_error is null (NOT false).
  return { content: [{ type: "text", text }] };
}

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (shutting_down) {
    return textResult(
      "mcp-ask-workspace: server is shutting down; ask-workspace declined to start. Re-issue once it resumes.",
    );
  }
  in_flight++;
  try {
    const args = (req.params && req.params.arguments) || {};
    if (!args.to_ws || !args.question || !args.bead_ref) {
      return textResult("mcp-ask-workspace: 'to_ws', 'question', and 'bead_ref' are required.");
    }
    if (!safeKey(args.to_ws)) {
      return textResult(
        `mcp-ask-workspace: to_ws='${args.to_ws}' is not a safe registry key (A–Z, a–z, 0–9, ._-, no '..').`,
      );
    }

    const workspace_dir = process.cwd();
    const from_ws = resolveProjectRef(workspace_dir);
    const call_id = hash(`${from_ws}|${args.to_ws}|${args.bead_ref}|${Date.now()}`);
    const exchange_id = `xws-${hash(`${from_ws}|${args.to_ws}|${args.bead_ref}|${args.question}`)}`;
    logLine({
      event: "call_start",
      call_id,
      from_ws,
      to_ws: args.to_ws,
      bead_ref: args.bead_ref,
      question_len: (args.question || "").length,
      dump_hash: hash(args.context_dump || ""),
    });

    // Step 1: ROUTE — resolve B's dir from the registry.
    const routed = resolveWorkspaceDir(args.to_ws);
    if (!routed.ok) {
      logLine({ event: "route_miss", call_id, to_ws: args.to_ws, reason: routed.reason });
      return textResult(
        `mcp-ask-workspace: could not route to workspace '${args.to_ws}': ${routed.reason} Proceed on your own judgment or file a bead — no answer was fabricated.`,
      );
    }
    const b_dir = routed.dir;

    // Step 2: SPAWN the read-only responder at cwd = B and BLOCK.
    const responderInput = buildResponderInput({ from_ws, to_ws: args.to_ws, workspace_dir: b_dir, args });
    logLine({ event: "responder_spawn", call_id, b_dir, timeout_ms: RESPONDER_TIMEOUT_MS });
    const resp = await runResponder({ workspaceDir: b_dir, responderInput });
    logLine({
      event: "responder_done",
      call_id,
      ok: resp.ok,
      elapsed_ms: resp.elapsedMs,
      verdict: resp.ok ? resp.verdict.verdict : null,
      reason: resp.ok ? null : resp.reason,
      raw_preview: resp.raw || null,
    });

    // Infra failure (no output / timeout / spawn error): actionable error to A,
    // never a fabricated answer and never a phantom Brian-page on infra noise.
    if (!resp.ok && resp.spawnFail) {
      return textResult(
        `mcp-ask-workspace: the responder in '${args.to_ws}' could not be reached (${resp.reason}). Proceed on your own judgment or file a bead — no answer was fabricated.`,
      );
    }

    // Determine the verdict. A non-spawn-fail !ok (model emitted non-verdict
    // output) is treated as escalate-to-safe — the conservative default (§2.2).
    let verdict;
    if (resp.ok) {
      verdict = resp.verdict;
    } else {
      verdict = {
        verdict: "escalate",
        reason: "missing_design",
        summary: `The responder in '${args.to_ws}' did not return a clean answer/escalate verdict for: ${args.question}`,
        conflicting_claims: [],
        options: [],
        recommendation: "",
      };
      logLine({ event: "escalate_to_safe", call_id, raw_preview: resp.raw || null });
    }

    // ── Step 3a: the ANSWER path (the mechanical 80%) ────────────────────────
    if (verdict.verdict === "answer") {
      const answerText = formatAnswerVerdict({ to_ws: args.to_ws, verdict });
      await relayAppend({
        exchange_id,
        from_ws,
        to_ws: args.to_ws,
        question: args.question,
        answer: String(verdict.answer || ""),
        outcome: "resolved",
        call_id,
      });
      // Always-FYI: batched timed-fyi so K3's rollup has a cross-WS row to
      // batch (DESIGN K §4.2 item 1; claude-tools-mhcp.1). After the relay
      // append so the audit row exists first; tolerant (never fails the tool).
      await emitFyi({ exchange_id, from_ws, call_id });
      logLine({ event: "answer_returned", call_id, exchange_id });
      return textResult(answerText);
    }

    // ── Step 3b: the ESCALATE path (the 20%) — reuse the ask-brian dossier
    //    publish-and-block path VERBATIM (DESIGN K §5). ────────────────────────
    const idR = await runBridge("id_for", [args.bead_ref]);
    if (idR.rc !== 0 || !idR.stdout.trim()) {
      logLine({ event: "id_for_fail", call_id, rc: idR.rc, stderr: idR.stderr });
      return textResult(
        `mcp-ask-workspace: escalation needed but could not derive a dossier id for bead_ref='${args.bead_ref}' (rc=${idR.rc}). The responder flagged: ${verdict.summary || verdict.reason}`,
      );
    }
    const dossier_id = idR.stdout.trim();
    const worker_ask = escalateToWorkerAsk({ from_ws, to_ws: args.to_ws, verdict });

    const w = await runBridge("write_fallback", [dossier_id, args.bead_ref, JSON.stringify(worker_ask)]);
    if (w.rc !== 0 || !w.stdout.trim()) {
      logLine({ event: "escalate_write_fail", call_id, rc: w.rc, stderr: (w.stderr || "").slice(0, 400) });
      return textResult(
        `mcp-ask-workspace: a cross-workspace ${verdict.reason || "conflict"} was detected but the blocking dossier could not be persisted (rc=${w.rc}). Detail: ${verdict.summary || ""}`,
      );
    }
    const did = w.stdout.trim();
    logLine({ event: "escalate_write_ok", call_id, dossier_id: did });

    // Relay row records the escalation BEFORE the poll (DESIGN K §5.2): one row,
    // final outcome known (the dossier exists), dossier_ref linked.
    await relayAppend({
      exchange_id,
      from_ws,
      to_ws: args.to_ws,
      question: args.question,
      answer: verdict.summary || "",
      outcome: "escalated",
      dossier_ref: did,
      call_id,
    });

    // Poll for Brian's ruling, then return it as the tool_result.
    const t0 = Date.now();
    let cycles = 0;
    let ruling = null;
    while (Date.now() - t0 < POLL_MAX_MS) {
      cycles++;
      const p = await runBridge("poll_once", [did]);
      if (p.rc === 0 && p.stdout.trim()) {
        try {
          ruling = JSON.parse(p.stdout);
          break;
        } catch (e) {
          logLine({ event: "poll_parse_fail", call_id, error: String(e).slice(0, 200) });
        }
      } else if (p.rc !== 0 && cycles % 30 === 1) {
        logLine({ event: "poll_transport_warn", call_id, cycle: cycles, rc: p.rc, stderr: (p.stderr || "").slice(0, 200) });
      }
      if (cycles % 30 === 1) {
        logLine({ event: "poll_still_waiting", call_id, cycle: cycles, elapsed_ms: Date.now() - t0 });
      }
      await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    }

    if (!ruling) {
      logLine({ event: "poll_ceiling_hit", call_id, cycles });
      return textResult(
        `mcp-ask-workspace: a cross-workspace ${verdict.reason || "conflict"} escalated to Brian but no ruling came within the ${Math.round(POLL_MAX_MS / 1000)}s ceiling. The dossier (${did}) is durable on the engine; the daemon-resume path re-dispatches this worker with the ruling once Brian responds.`,
      );
    }

    const rulingText = formatRuling(ruling);
    logLine({ event: "ruling_returned", call_id, dossier_id: did, elapsed_ms: Date.now() - t0 });
    return textResult(
      `Your cross-workspace question to '${args.to_ws}' surfaced a ${verdict.reason || "conflict"} and was escalated to Brian, who ruled:\n\n${rulingText}`,
    );
  } finally {
    in_flight--;
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
logLine({ event: "connected", specialist_bin: SPECIALIST_BIN, registry: REGISTRY_PATH });
