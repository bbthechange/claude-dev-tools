#!/bin/bash
# beads-runner/lib/test-agent-action-proxy.sh — I4 (claude-tools-uxvi4).
#
# The Pages WRITE proxies for the Activity stuck actions (design/agent-action.md
# §5): web/functions/api/control/agent-action.js + escalate.js. The flow-d
# precedent tests the engine/daemon FLOW via the oracle; this pins the PROXY
# logic itself — the cheap-first gate + the §9.1/§2.4 server-side discipline:
#   • the intent allowlist (only nudge/kill-retry/kill-gate; escalate/gate-* 422)
#   • owner:"you" is stamped SERVER-SIDE (the client cannot pick it)
#   • required-field gates (bead_ref; kill-gate needs gate_id+date)
#   • escalate builds a worker_stuck/blocking gi with the four pick-options
#   • the op is HARD-CODED (agent-action / dossier-generate) — never client-chosen
# Driven by node with a stubbed global fetch (no network, no Cloudflare account).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AA_JS="$REPO/web/functions/api/control/agent-action.js"
ESC_JS="$REPO/web/functions/api/control/escalate.js"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[[ -f "$AA_JS"  ]] || { bad "agent-action.js proxy missing at $AA_JS"; echo "RESULT: 0 passed, 1 failed"; exit 1; }
[[ -f "$ESC_JS" ]] || { bad "escalate.js proxy missing at $ESC_JS"; echo "RESULT: 0 passed, 1 failed"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "  (skip) node not available"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

TMP="$(mktemp -d)"; SCRIPT="$TMP/drive.mjs"
cat > "$SCRIPT" <<NODE
import { onRequestPost as agentAction } from "file://$AA_JS";
import { onRequestPost as escalate }   from "file://$ESC_JS";

let captured = null;
globalThis.fetch = async (url, init) => {
  captured = { url: String(url), body: JSON.parse(init.body) };
  // Echo a plausible engine success so the proxy returns 200.
  const op = new URL(String(url)).searchParams.get("op");
  const payload = op === "dossier-generate" ? { ok: true, id: "stuck-x" } : { ok: true, action_id: "a-1" };
  return new Response(JSON.stringify(payload), { status: 200, headers: { "content-type": "application/json" } });
};

const ENV = { COORDINATOR_URL: "https://co.example", COORDINATOR_TOKEN: "tok" };
const ctx = (body) => ({ env: ENV, request: { json: async () => body } });
async function status(fn, body) { captured = null; const r = await fn(ctx(body)); return { status: r.status, body: JSON.parse(await r.text()) }; }

let pass = 0, fail = 0;
const ck = (name, cond) => { if (cond) { pass++; console.log("  OKK " + name); } else { fail++; console.log("  BADD " + name); } };

// ── agent-action proxy ──────────────────────────────────────────────────────
let r = await status(agentAction, { intent: "escalate", workspace: "w", target: { bead_ref: "w-1" } });
ck("escalate is rejected by the agent-action proxy (422) — it is a dossier write, not an intent", r.status === 422 && r.body.ok === false);

r = await status(agentAction, { intent: "gate-apply", workspace: "w", target: { bead_ref: "w-1" } });
ck("gate-apply is 422 here (it belongs to the Gates facet, not Activity)", r.status === 422);

r = await status(agentAction, { intent: "nudge", workspace: "" , target: { bead_ref: "w-1" } });
ck("missing workspace ⇒ 400", r.status === 400);

r = await status(agentAction, { intent: "nudge", workspace: "w", target: {} });
ck("missing target.bead_ref ⇒ 400", r.status === 400);

r = await status(agentAction, { intent: "kill-gate", workspace: "w", target: { bead_ref: "w-1", gate_id: "g1" }, args: {} });
ck("kill-gate without args.date ⇒ 422 (gate-defer couples label+defer)", r.status === 422);

r = await status(agentAction, { intent: "nudge", workspace: "w", target: { bead_ref: "w-1" }, args: { reason: "x" } });
ck("valid nudge ⇒ 200 + forwarded to op=agent-action", r.status === 200 && /op=agent-action/.test(captured.url));
ck("owner:'you' is stamped SERVER-SIDE (client cannot override it)", captured.body.action.owner === "you");
ck("the forwarded envelope carries intent+workspace+target", captured.body.action.intent === "nudge" && captured.body.action.workspace === "w" && captured.body.action.target.bead_ref === "w-1");

// A client trying to smuggle owner:'agent:x' is overwritten to 'you' (GUI proxy).
r = await status(agentAction, { intent: "kill-retry", workspace: "w", target: { bead_ref: "w-1" }, owner: "agent:evil" });
ck("kill-retry valid ⇒ 200", r.status === 200);
ck("a client-sent owner is ignored — proxy stamps 'you'", captured.body.action.owner === "you");

// ── escalate proxy ──────────────────────────────────────────────────────────
r = await status(escalate, { project_ref: "w" });
ck("escalate without bead_ref ⇒ 400", r.status === 400);

r = await status(escalate, { bead_ref: "w-1", project_ref: "w", title: "do the thing" });
ck("escalate ⇒ 200 + forwarded to op=dossier-generate (a pure engine write)", r.status === 200 && /op=dossier-generate/.test(captured.url));
const gi = captured.body.gi;
ck("escalate builds a worker_stuck / blocking decide dossier for the bead", gi && gi.trigger === "worker_stuck" && gi.tier === "blocking" && gi.kind === "decide" && gi.bead_ref === "w-1");
ck("escalate dossier has a pick-option item with the four stuck options", gi && gi.items[0].kind === "pick-option" && gi.items[0].options.length === 4);
ck("escalate id is stable per bead (dedup-friendly)", gi && gi.id === "stuck-w-1");

console.log("NODE_RESULT " + pass + " " + fail);
NODE

OUT="$(node "$SCRIPT" 2>&1)" || { echo "$OUT"; bad "node driver crashed"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; rm -rf "$TMP"; exit 1; }
while IFS= read -r line; do
  case "$line" in
    "  OKK "*)  ok "${line#  OKK }" ;;
    "  BADD "*) bad "${line#  BADD }" ;;
  esac
done <<< "$OUT"
rm -rf "$TMP"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
printf '  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "════════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
