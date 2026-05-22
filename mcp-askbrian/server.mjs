#!/usr/bin/env node
// mcp-askbrian — stdio MCP server exposing ONE tool: ask-brian.
//
// On tools/call the handler runs the five steps from claude-tools-bvj
// (B2; epic claude-tools-kie), bound to the R1 contract
// (beads-runner/research/mcp-interactive-tool.md "Implementation contract"):
//
//   1. AUTHORING DISPATCH — spawn a fresh `claude -p` running the
//      dossier-builder agent (B1's system prompt, beads-runner/agents/
//      dossier-builder.system.md) with the worker's structured input on
//      stdin. Time-budgeted (BUILDER_TIMEOUT_MS; default 300s).
//   2. WRITE TO HOSTED ENGINE FIRST — engine-bridge.sh write_polished
//      (builder's {body, items[]}) OR write_fallback (B3 jq path) lands the
//      dossier durable cloud-side BEFORE the poll loop starts.
//   3. NOTIFY THE PHONE — emit_and_dispatch inside the bridge.
//   4. POLL FOR ANSWER — engine-bridge.sh poll_once every POLL_INTERVAL_MS
//      (default 1000ms) until any item moves to answered|applied.
//   5. RETURN TO THE WORKER — { content:[{type:"text", text}] } with
//      isError unset, so tool_result.is_error is null per R1 Q1 (the runner's
//      scan_stream_for_tool_errors must treat null as success).
//
// Auth: COORDINATOR_URL + COORDINATOR_TOKEN passed via the user-scope
// `claude mcp add askbrian --scope user -e …` -e flags. The bridge falls back
// to the in-process bash store when COORDINATOR_URL is unset (matches the
// runner's standalone path; useful for the local smoke test).
//
// Workspace identification: bead_ref is a REQUIRED tool input (the worker
// running on a specific bead knows it). The deterministic dossier id is
// derived `stuck-<bead_ref>` to match sr_route_stuck so an MCP-side and a
// runner-side trigger on the SAME fork collapse to ONE dossier (§7.4).

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "node:child_process";
import { mkdirSync, appendFileSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

// ── paths ───────────────────────────────────────────────────────────────────
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const BRIDGE_PATH = join(__dirname, "helpers", "engine-bridge.sh");
const DEFAULT_BUILDER_PROMPT = resolve(
  __dirname,
  "..",
  "beads-runner",
  "agents",
  "dossier-builder.system.md",
);
const BUILDER_PROMPT_PATH =
  process.env.DOSSIER_BUILDER_PROMPT_PATH || DEFAULT_BUILDER_PROMPT;

// ── tunables ────────────────────────────────────────────────────────────────
// Default 300s (5 min): a real builder run with Opus 4.7 1M + the full
// dossier-builder.system.md + Read/Grep workspace exploration takes ~182s
// (claude-tools-cxj 6-minute probe). 90s SIGTERM'd the builder mid-thought
// every time, masking the agent-authored path entirely. 300s gives ~65%
// headroom over observed and bounds a genuine hang at 5 min, not 90s.
const BUILDER_TIMEOUT_MS = parseInt(
  process.env.BUILDER_TIMEOUT_MS || "300000",
  10,
);
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || "1000", 10);
const POLL_MAX_MS = parseInt(
  process.env.POLL_MAX_MS || String(6 * 60 * 60 * 1000), // 6h hard ceiling
  10,
);
// Pin to claude-opus-4-7 by default (claude-tools-cvj followup). The
// production 240/5os runs used the inherited default model (likely Sonnet
// or Haiku), which produced markdown prose ('The three...') in ~27s rather
// than the JSON dossier the prompt demands — same prompt under Opus 4.7
// produced the polished JSON in ~78-180s. Faster models do not follow the
// long-preamble system prompt as reliably; cost trade-off is acknowledged.
// Override via env DOSSIER_BUILDER_MODEL if a cheaper model proves reliable.
const BUILDER_MODEL = process.env.DOSSIER_BUILDER_MODEL || "claude-opus-4-7";
const CLAUDE_BIN = process.env.CLAUDE_BIN || "claude";
// Soft cap on child stdout/stderr so a runaway builder cannot exhaust the
// Node heap before BUILDER_TIMEOUT_MS fires. Past the cap we SIGKILL the
// child and treat the call as a builder failure (fallback takes over).
const CHILD_OUTPUT_CAP_BYTES = parseInt(
  process.env.CHILD_OUTPUT_CAP_BYTES || String(4 * 1024 * 1024),
  10,
);

// ── logging ─────────────────────────────────────────────────────────────────
const LOG_DIR = join(homedir(), ".cache", "claude-tools");
const LOG_PATH = join(LOG_DIR, "mcp-askbrian.log");
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

// PROJECT_REF resolution (description "ancillary responsibilities"): env →
// cwd's .beads/runner.sh PROJECT_REF= line → basename(cwd). Forensic-only
// here; the bead_ref carries the load-bearing identity into the dossier.
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

// ── graceful-shutdown latch ─────────────────────────────────────────────────
// Per the task description: "SIGTERM should allow in-flight tool calls to
// finish (the engine write is durable; the worker would lose only the
// answer-return if killed mid-poll; daemon resume catches that)." So:
//   • new tools/call after a signal returns a terse apology immediately
//   • in-flight calls keep polling until they observe an answer or the poll
//     ceiling hits — they do NOT abort on the signal
//   • a hard cap (SHUTDOWN_DRAIN_MS) bounds the drain so a service-manager
//     SIGKILL doesn't replace this process while it's still spinning
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
        logLine({
          event: "shutdown_exit",
          drained: in_flight === 0,
          remaining_in_flight: in_flight,
        });
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
        stderr: capped ? err + "\n[mcp-askbrian: bridge output capped]" : err,
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

function runBuilder({ workspaceDir, builderInput }) {
  return new Promise((resolveP) => {
    if (!existsSync(BUILDER_PROMPT_PATH)) {
      resolveP({
        ok: false,
        reason: `builder system prompt not found at ${BUILDER_PROMPT_PATH}`,
        elapsedMs: 0,
      });
      return;
    }
    // claude -p with the builder prompt appended as system, --add-dir so the
    // builder can Read/Grep the workspace, --output-format=json so we get a
    // single envelope back. We use --append-system-prompt rather than
    // --system-prompt so the harness's default tool surface (Read/Grep/Glob/
    // Bash — what the builder spec promises) stays available.
    const args = [
      "-p",
      // claude-tools-cvj third-pass: switched from --append-system-prompt to
      // --system-prompt (replace). When the dossier-builder.system.md was
      // APPENDED to Claude Code's default helpful-assistant system prompt,
      // the default persona kept winning on juicy real-decision inputs —
      // the model would treat the worker_ask JSON as "user pasted a
      // document, what do I think?" and emit markdown commentary
      // ("Since you've pasted it to me without a question, two options:..."
      // observed verbatim on 240 at 10:50Z) instead of composing a JSON
      // dossier. Replacing the system prompt removes the competing persona;
      // only the dossier-builder role is active. --allowedTools handles the
      // tool surface explicitly so we don't lose Read/Grep/Glob/Bash.
      "--system-prompt",
      `@${BUILDER_PROMPT_PATH}`,
      "--add-dir",
      workspaceDir,
      "--output-format",
      "json",
      "--permission-mode",
      "acceptEdits",
      // claude-tools-cvj followup: --permission-mode acceptEdits alone does NOT
      // auto-grant Bash in non-interactive `-p` mode — the harness emits the
      // canonical refusal "The user does not have permission to grant this
      // tool" and the builder gives up in ~27s before writing any JSON. The
      // dossier-builder.system.md spec explicitly requires Read/Grep/Glob/Bash
      // for its breadth-first context gather. Allowlist them explicitly so the
      // builder can `bd show`, `git log`, grep the workspace, etc.
      "--allowedTools",
      "Read",
      "Grep",
      "Glob",
      "Bash",
      // claude-tools-cvj second-pass: the dossier-builder.system.md prompt
      // tells the model "Don't call EnterPlanMode, ExitPlanMode, or
      // AskUserQuestion" but the model honored it only ~50% of the time
      // (observed on 240 — 07:45 succeeded; 08:04 emitted "The user
      // dismissed the question prompt without answering. I'll wait for
      // direct input on the three forks rather than guess" via an
      // AskUserQuestion call denied by the harness, then fell to fallback).
      // Block at the harness layer so prompt drift doesn't bite.
      "--disallowedTools",
      "AskUserQuestion",
      "EnterPlanMode",
      "ExitPlanMode",
      "--max-turns",
      "30",
    ];
    if (BUILDER_MODEL) args.push("--model", BUILDER_MODEL);

    const t0 = Date.now();
    const child = spawn(CLAUDE_BIN, args, {
      stdio: ["pipe", "pipe", "pipe"],
      cwd: workspaceDir,
      env: process.env,
    });
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
      try {
        child.kill("SIGTERM");
      } catch {}
      // Hard kill 5s after SIGTERM if it didn't take.
      setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {}
      }, 5000);
      finish({ ok: false, reason: `builder timed out after ${BUILDER_TIMEOUT_MS}ms` });
    }, BUILDER_TIMEOUT_MS);

    const onChunk = (which) => (d) => {
      if (capped) return;
      if (which === "stdout") stdoutBuf += d.toString();
      else stderrBuf += d.toString();
      if (stdoutBuf.length + stderrBuf.length > CHILD_OUTPUT_CAP_BYTES) {
        capped = true;
        try {
          child.kill("SIGKILL");
        } catch {}
        finish({
          ok: false,
          reason: `builder output exceeded ${CHILD_OUTPUT_CAP_BYTES} bytes; killed`,
        });
      }
    };
    child.stdout.on("data", onChunk("stdout"));
    child.stderr.on("data", onChunk("stderr"));
    child.on("error", (e) => finish({ ok: false, reason: `builder spawn error: ${e.message}` }));
    child.on("close", (code) => {
      if (finished) return;
      if (code !== 0) {
        finish({
          ok: false,
          reason: `builder exit ${code}; stderr: ${stderrBuf.trim().slice(0, 500)}`,
        });
        return;
      }
      // claude -p --output-format=json emits one envelope on stdout; the
      // model's text output is `.result`. Parse it; treat any failure as a
      // builder refusal so the fallback path takes over.
      let envelope = null;
      try {
        envelope = JSON.parse(stdoutBuf);
      } catch (e) {
        finish({ ok: false, reason: `builder envelope not JSON: ${String(e).slice(0, 200)}` });
        return;
      }
      const text = (envelope && (envelope.result || envelope.text || "")) || "";
      if (!text) {
        finish({ ok: false, reason: "builder produced no .result text" });
        return;
      }
      // The builder spec says: emit ONE JSON object on stdout, no fence, no
      // narration. Be defensive: strip a leading ```json fence if the model
      // added one, then parse the first JSON object found.
      const cleaned = stripJsonFence(text).trim();
      let dossier = null;
      try {
        dossier = JSON.parse(cleaned);
      } catch (e) {
        const extracted = extractFirstJsonObject(cleaned);
        if (extracted) {
          try {
            dossier = JSON.parse(extracted);
          } catch {}
        }
        if (!dossier) {
          // claude-tools-cvj followup: capture the leading 500 chars of the
          // builder's result text so the next non-JSON failure is
          // self-diagnosing. The 07:11/07:28 failures cost an hour of
          // hypothesis-spelunking that one log line would have shortened.
          finish({
            ok: false,
            reason: `builder output not JSON: ${String(e).slice(0, 200)}`,
            body_preview: cleaned.slice(0, 500),
            model: envelope.model || null,
          });
          return;
        }
      }
      // claude-tools-cvj second-pass: validate the builder produced
      // substantive content. The 10:38 240 attempt emitted technically-valid
      // but vacuous JSON (`{body: {}, items: []}`) that passed JSON.parse
      // but produced a fallback-shape dossier badged as "agent" — worse
      // than an honest fallback because the bad shape masquerades as good.
      // Quality gate: a worker-stuck dossier MUST carry ≥3 sections,
      // ≥1 item, and ≥500 chars of full_detail. Anything thinner is the
      // model punting; treat it as a builder failure so the jq fallback
      // produces an honest deterministic shape and the badge matches.
      if (dossier.refuse !== true) {
        const body = dossier.body || {};
        const sections = Array.isArray(body.sections) ? body.sections : [];
        const items = Array.isArray(dossier.items) ? dossier.items : [];
        const full_detail = String(body.full_detail || "");
        const thin = sections.length < 3 || items.length < 1 || full_detail.length < 500;
        if (thin) {
          finish({
            ok: false,
            reason: `builder produced thin output (sections=${sections.length}, items=${items.length}, full_detail_len=${full_detail.length}) — minimum 3/1/500 required`,
            body_preview: cleaned.slice(0, 500),
            model: envelope.model || null,
          });
          return;
        }
      }
      finish({ ok: true, dossier });
    });
    try {
      child.stdin.write(builderInput);
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
  // Find the first balanced { … } block in s. Sufficient for "model added a
  // sentence before/after the JSON" — not a full parser.
  const start = s.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c === "\\") {
        esc = true;
      } else if (c === '"') {
        inStr = false;
      }
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

// ── input normalization ─────────────────────────────────────────────────────
// The MCP tool input is deliberately lenient (a worker under pressure can't
// be asked to author the §5.2/§5.3 CB schema by hand). Normalize here so
// both the builder path and the B3 jq fallback see a worker_ask that passes
// dg_from_worker_ask's validation: every option carries an empty-but-shaped
// consequence_block, and recommendation has BOTH non-empty value and why.
function emptyCB() {
  return { creates: [], unblocks: [], labels: [], status_changes: [] };
}

function normalizeOptions(options) {
  if (!Array.isArray(options)) return [];
  return options.map((o, i) => {
    const opt = o && typeof o === "object" ? o : {};
    const option_id = opt.option_id || opt.id || `opt-${i + 1}`;
    const label = opt.label || option_id;
    const blast_radius = opt.blast_radius || "(blast radius not provided by the worker)";
    const consequence_block =
      opt.consequence_block && typeof opt.consequence_block === "object"
        ? opt.consequence_block
        : emptyCB();
    return { option_id, label, blast_radius, consequence_block };
  });
}

function normalizeRecommendation(rec, opts) {
  const fallbackWhy =
    "The worker emitted this as its recommendation in the structured ask; the human is asked to confirm.";
  if (!rec) {
    if (opts.length > 0) {
      return { value: opts[0].option_id, why: fallbackWhy };
    }
    return null;
  }
  if (typeof rec === "string") {
    return { value: rec, why: fallbackWhy };
  }
  if (typeof rec === "object") {
    const value = rec.value || rec.option_id || (opts[0] && opts[0].option_id) || "";
    const why = rec.why && String(rec.why).trim() ? rec.why : fallbackWhy;
    return { value, why };
  }
  return { value: String(rec), why: fallbackWhy };
}

function buildWorkerAsk(args) {
  const options = normalizeOptions(args.options);
  return {
    tldr: args.question,
    ask: args.question,
    options,
    recommendation: normalizeRecommendation(args.recommendation, options),
    reversible: args.reversible || "Reversibility not specified by the worker ask.",
  };
}

// ── builder input assembly ──────────────────────────────────────────────────
// Shape matches the B1 (claude-tools-n34) dossier-builder system prompt's
// declared stdin schema — top-level question / options / recommendation /
// reversible plus the load-bearing context_dump (the rich worker brain-dump
// the builder organizes into the four-tier body).
function buildBuilderInput({ dossier_id, bead_ref, workspace_dir, args, worker_ask }) {
  return JSON.stringify({
    dossier_id,
    bead_ref,
    workspace_dir,
    question: args.question,
    options: worker_ask.options,
    recommendation: worker_ask.recommendation,
    reversible: worker_ask.reversible,
    context_dump: args.context_dump || "",
  });
}

// ── generation-input assembly (for dg_generate via the bridge) ──────────────
function assembleGenerationInput({ dossier_id, bead_ref, dossier, worker_ask }) {
  const body = dossier.body || {};
  const items = Array.isArray(dossier.items) ? dossier.items : [];
  // source.* feeds dg__author; the polished body's tiers are kept by passing
  // sections/diagrams/full_detail through verbatim (see lib/dossier-gen.sh
  // dg__author — it preserves source.sections/diagrams/full_detail when
  // present, and uses tldr/ask/recommendation/reversible only as fallback).
  const source = {
    tldr: body.tldr || worker_ask.ask || "Decision required.",
    ask: worker_ask.ask || body.tldr || "",
    sections: Array.isArray(body.sections) ? body.sections : undefined,
    diagrams: Array.isArray(body.diagrams) ? body.diagrams : undefined,
    full_detail: body.full_detail,
    options: worker_ask.options || [],
    recommendation: worker_ask.recommendation || null,
    reversible: worker_ask.reversible || "",
    // claude-tools-xdo: the polished body was authored by the dossier-builder
    // subprocess (an agent) BEFORE this call hands off to dg_generate. The
    // bridge env has no DG_AUTHOR_CMD, so dg__author's jq path is just a
    // shape-coercer here, not a degraded fallback. Stamping this hint lets the
    // jq path label the body authored_by="agent" so the Inbox renderer doesn't
    // badge MCP-polished dossiers as "fallback author".
    authored_by: "agent",
    authored_by_reason: "mcp_polished_builder",
  };
  // Drop undefined keys so the bridge's jq doesn't see literal null fields
  // where source.sections is expected to be array-or-absent.
  for (const k of Object.keys(source)) if (source[k] === undefined) delete source[k];

  return JSON.stringify({
    id: dossier_id,
    kind: "decide",
    trigger: "worker_stuck",
    bead_ref,
    tier: "blocking",
    timer_fire_at: null,
    source,
    items,
  });
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

function formatAnswer(payload) {
  // The text the worker sees as its tool_result. claude-tools-88e: a dossier
  // can have N>1 items; the bridge returns {items:[...]} with all answered
  // entries in one shot. For a single-item dossier we keep the old terse
  // shape; for multi-item we header + per-item blocks so the worker can act
  // on every answer without re-asking.
  const items = Array.isArray(payload && payload.items) ? payload.items : [];
  if (items.length === 0) {
    // Defensive: an empty payload should not have escaped poll_once, but if
    // it does, surface that the dossier was resolved with no decisions.
    return "Brian's answer: (the dossier resolved with no per-item decision — see the dossier in his Inbox for context).";
  }
  if (items.length === 1) {
    return formatOneAnswer(items[0]);
  }
  const blocks = [
    `Brian answered all ${items.length} items in this dossier. Each item's answer is below — apply ALL of them; do not re-ask any item.`,
    "",
  ];
  items.forEach((ans, i) => {
    blocks.push(`── Item ${i + 1}/${items.length} (${ans.item_id || "?"}) ──`);
    if (ans.ask) blocks.push(`Ask: ${ans.ask}`);
    blocks.push(formatOneAnswer(ans));
    blocks.push("");
  });
  return blocks.join("\n").trimEnd();
}

// ── the one tool ────────────────────────────────────────────────────────────
const TOOL_NAME = "ask-brian";

const server = new Server(
  { name: "askbrian", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: TOOL_NAME,
      description:
        "Ask Brian a question that the agent must NOT resolve unilaterally (an irreversible product / architecture / scope decision). Provides the worker's rich context to a dossier-builder, persists a polished decision dossier to Brian's hosted engine, notifies his phone, and BLOCKS until Brian taps an answer. Use ONLY for genuine human-decision forks — not for ordinary hard work and not as a substitute for thinking.",
      inputSchema: {
        type: "object",
        properties: {
          question: {
            type: "string",
            description: "One-sentence framing of the decision Brian needs to make.",
          },
          context_dump: {
            type: "string",
            description:
              "Rich, unconstrained dump of context from the worker's window: code paths inspected, alternatives considered, related decisions, the reason the agent cannot resolve this itself.",
          },
          bead_ref: {
            type: "string",
            description:
              "The bd issue id the worker is stuck on (e.g. claude-tools-abc). Required so the dossier dedupes on one-fork-one-dossier (§7.4).",
          },
          options: {
            type: "array",
            description:
              "Each option Brian could pick. label is what he taps; blast_radius is one sentence on what the option unblocks and what it forecloses.",
            items: {
              type: "object",
              properties: {
                option_id: { type: "string" },
                label: { type: "string" },
                blast_radius: { type: "string" },
              },
              required: ["label", "blast_radius"],
            },
          },
          recommendation: {
            type: "string",
            description: "The worker's recommended option_id (or short freeform) and one sentence of why.",
          },
          reversible: {
            type: "string",
            description: "What the choice forecloses vs. what stays open. 'Fully reversible' is fine when true.",
          },
        },
        required: ["question", "context_dump", "bead_ref"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (shutting_down) {
    return {
      content: [
        {
          type: "text",
          text: "mcp-askbrian: server is shutting down; ask-brian declined to start. Re-issue once the daemon resumes (the worker bead's design carries the structured ask).",
        },
      ],
    };
  }
  in_flight++;
  try {
    const args = (req.params && req.params.arguments) || {};
    if (!args.question || !args.bead_ref) {
      return {
        content: [
          {
            type: "text",
            text: "mcp-askbrian: 'question' and 'bead_ref' are required.",
          },
        ],
      };
    }
    const workspace_dir = process.cwd();
    const project_ref = resolveProjectRef(workspace_dir);
    const call_id = hash(`${args.bead_ref}|${args.question}|${Date.now()}`);
    logLine({
      event: "call_start",
      call_id,
      bead_ref: args.bead_ref,
      project_ref,
      question_len: (args.question || "").length,
      dump_hash: hash(args.context_dump || ""),
      workspace_dir,
    });

    // Step 0: derive the deterministic dossier id (matches sr_dossier_id_for).
    const idR = await runBridge("id_for", [args.bead_ref]);
    if (idR.rc !== 0 || !idR.stdout.trim()) {
      logLine({ event: "id_for_fail", call_id, rc: idR.rc, stderr: idR.stderr });
      return {
        content: [
          {
            type: "text",
            text: `mcp-askbrian: could not derive a dossier id for bead_ref='${args.bead_ref}' (engine-bridge id_for rc=${idR.rc}). Check that bead_ref is safe-key shaped (A–Z, a–z, 0–9, ._-).`,
          },
        ],
      };
    }
    const dossier_id = idR.stdout.trim();

    // Step 1: AUTHORING DISPATCH (Brian's 2026-05-20 refinement) — spawn the
    // fresh dossier-builder. Time-budgeted; on timeout/failure we fall back
    // to the jq-deterministic path (B3) so the worker still gets a dossier.
    const worker_ask = buildWorkerAsk(args);
    const builderInput = buildBuilderInput({
      dossier_id,
      bead_ref: args.bead_ref,
      workspace_dir,
      args,
      worker_ask,
    });
    logLine({ event: "builder_spawn", call_id, timeout_ms: BUILDER_TIMEOUT_MS });
    const builder = await runBuilder({ workspaceDir: workspace_dir, builderInput });
    logLine({
      event: "builder_done",
      call_id,
      ok: builder.ok,
      elapsed_ms: builder.elapsedMs,
      reason: builder.ok ? null : builder.reason,
      refused: builder.ok && builder.dossier && builder.dossier.refuse === true,
      // claude-tools-cvj followup: surface the builder's raw .result on failure
      // so next-time diagnosis is one log line away.
      body_preview: builder.body_preview || null,
      model: builder.model || null,
    });

    // Step 2: WRITE TO HOSTED ENGINE FIRST.
    let did = "";
    let write_path = "";
    if (builder.ok && builder.dossier && builder.dossier.refuse !== true) {
      const gi = assembleGenerationInput({
        dossier_id,
        bead_ref: args.bead_ref,
        dossier: builder.dossier,
        worker_ask,
      });
      const w = await runBridge("write_polished", [gi]);
      if (w.rc === 0 && w.stdout.trim()) {
        did = w.stdout.trim();
        write_path = "polished";
      } else {
        logLine({
          event: "write_polished_fail",
          call_id,
          rc: w.rc,
          stderr: w.stderr.slice(0, 500),
        });
      }
    }
    if (!did) {
      // Fallback: B3 jq path. dg_from_worker_ask binds the same §5 gate.
      const w = await runBridge("write_fallback", [
        dossier_id,
        args.bead_ref,
        JSON.stringify(worker_ask),
      ]);
      if (w.rc === 0 && w.stdout.trim()) {
        did = w.stdout.trim();
        write_path = "fallback";
        logLine({ event: "write_fallback_ok", call_id, dossier_id: did });
      } else {
        logLine({
          event: "write_fallback_fail",
          call_id,
          rc: w.rc,
          stderr: w.stderr.slice(0, 500),
        });
        return {
          content: [
            {
              type: "text",
              text: `mcp-askbrian: could not persist the dossier (fallback rc=${w.rc}). Detail: ${w.stderr.trim().slice(0, 400)}`,
            },
          ],
        };
      }
    }
    logLine({ event: "engine_write_ok", call_id, dossier_id: did, write_path });

    // Step 3: NOTIFY — emit + dispatch handled inside the bridge's write
    // sub-commands so the §4.3 Notification row exists at creation (C3).
    // Step 4: POLL FOR ANSWER. R1 says block as long as needed; we cap at
    // POLL_MAX_MS as a defensive ceiling.
    const t0 = Date.now();
    let cycles = 0;
    let answer = null;
    while (Date.now() - t0 < POLL_MAX_MS) {
      cycles++;
      const p = await runBridge("poll_once", [did]);
      if (p.rc === 0 && p.stdout.trim()) {
        try {
          answer = JSON.parse(p.stdout);
          break;
        } catch (e) {
          logLine({ event: "poll_parse_fail", call_id, error: String(e).slice(0, 200) });
        }
      } else if (p.rc !== 0) {
        // Transport hiccup (hosted unreachable / 401) — keep polling per R1
        // §Q5a "must not rot". Log once per 30 cycles to avoid log-spam.
        if (cycles % 30 === 1) {
          logLine({
            event: "poll_transport_warn",
            call_id,
            cycle: cycles,
            rc: p.rc,
            stderr: p.stderr.slice(0, 200),
          });
        }
      }
      if (cycles % 30 === 1) {
        logLine({ event: "poll_still_waiting", call_id, cycle: cycles, elapsed_ms: Date.now() - t0 });
      }
      await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    }

    if (!answer) {
      logLine({ event: "poll_ceiling_hit", call_id, cycles, elapsed_ms: Date.now() - t0 });
      return {
        content: [
          {
            type: "text",
            text: `mcp-askbrian: no answer within the ${Math.round(POLL_MAX_MS / 1000)}s poll ceiling. The dossier (${did}) is durable on Brian's engine; the daemon-resume path will re-dispatch this worker with the answer once Brian responds.`,
          },
        ],
      };
    }

    const text = formatAnswer(answer);
    const answeredItems = Array.isArray(answer && answer.items) ? answer.items : [];
    logLine({
      event: "answer_returned",
      call_id,
      dossier_id: did,
      item_count: answeredItems.length,
      items: answeredItems.map((a) => ({ item_id: a.item_id, chosen: a.chosen })),
      elapsed_ms: Date.now() - t0,
    });
    // R1 Q1: leave isError unset so tool_result.is_error is null (NOT false).
    return { content: [{ type: "text", text }] };
  } finally {
    in_flight--;
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
logLine({ event: "connected", builder_prompt: BUILDER_PROMPT_PATH });
