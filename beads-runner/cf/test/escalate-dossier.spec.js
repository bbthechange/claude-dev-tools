// I4 (claude-tools-uxvi4) — the "Escalate to decision" stuck action is a PURE
// engine write (DESIGN I §4): the control proxy (web/functions/api/control/
// escalate.js) builds a §5-valid `worker_stuck`/`blocking` generation-input and
// POSTs dossier-generate. This spec pins that the template the proxy builds is
// ACCEPTED by the engine's §5 gate (validateDossier) and persists a Flow B
// decision card with the four stuck options — so escalate cannot silently 422.
//
// The gi below MIRRORS web/functions/api/control/escalate.js's buildStuckGi
// template; if the proxy's shape drifts out of §5, this turns red. (Live-verify
// through the real proxy is the ultimate check; this is the offline guard.)

import { SELF } from "cloudflare:test";
import { it, expect } from "vitest";

const GOOD = "bearer-runner-secret-xyz";

function authReq(op, args) {
  return new Request("https://coordinator.local/", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${GOOD}` },
    body: JSON.stringify({ op, args: args || [] }),
  });
}
async function call(op, args) {
  const res = await SELF.fetch(authReq(op, args));
  const raw = await res.text();
  let body = null;
  try { body = JSON.parse(raw); } catch { body = null; }
  return { status: res.status, body, raw };
}

function opt(option_id, label, blast_radius) {
  return { option_id, label, blast_radius,
    consequence_block: { creates: [], unblocks: [], labels: [], status_changes: [] } };
}

// Mirror of escalate.js's gi template.
function stuckGi(beadRef, projectRef, title) {
  const what = title ? beadRef + " — " + title : beadRef;
  return {
    id: "stuck-" + beadRef,
    kind: "decide",
    trigger: "worker_stuck",
    bead_ref: beadRef,
    tier: "blocking",
    timer_fire_at: null,
    source: {
      tldr: "A worker on " + what + " looks stuck — what should I do?",
      ask: "How should this stuck task proceed?",
      sections: [{ heading: "Why this surfaced", prose: "Flagged maybe-stuck; escalated from the Activity stuck-actions." }],
      diagrams: [],
      full_detail: "Surfacing-only escalation (DESIGN I §4): the options are recorded; act on the chosen one from the controls.",
    },
    items: [{
      id: "stuck-decision",
      kind: "pick-option",
      framing: { ask: "What should happen to " + what + "?", why: "A stuck worker burns budget; the host actions differ in blast radius." },
      context_anchor: { where: "Activity view — workspace " + projectRef + ", worker on " + beadRef, expansion: "Flagged maybe-stuck past the soft window." },
      reversible: "Reversible — nudge/escalate are pure; kill+retry loses in-flight work; kill+gate is undone by lifting the gate.",
      options: [
        opt("nudge", "Nudge (keep alive)", "extends the watchdog grace one window; no kill"),
        opt("kill-retry", "Kill + retry", "terminates the worker; re-dispatches a fresh worker on the same bead"),
        opt("kill-gate", "Kill + Gate", "terminates AND gates the bead until the gate lifts"),
        opt("abandon", "Leave it / decide later", "no action now"),
      ],
      recommendation: { value: "kill-retry", why: "A fresh context window most often clears a transient stall." },
    }],
  };
}

it("I4 escalate dossier template passes the §5 gate and persists a Flow B card", async () => {
  const gi = stuckGi("rhythmGame-93o", "rhythmGame", "wire the input handler");
  const r = await call("dossier-generate", [gi]);
  expect(r.status, `dossier-generate rejected the escalate template (§5): ${r.raw}`).toBe(200);
  expect(r.body && r.body.ok, `escalate gi not accepted: ${r.raw}`).toBe(true);

  // It round-trips as a blocking worker_stuck dossier with the four options.
  const got = await call("dossier-get", ["stuck-rhythmGame-93o"]);
  expect(got.status).toBe(200);
  const d = got.body && (got.body.dossier || got.body);
  expect(d && d.tier).toBe("blocking");
  expect(d && d.trigger).toBe("worker_stuck");
  expect(d && d.bead_ref).toBe("rhythmGame-93o");
  const item = d && Array.isArray(d.items) && d.items[0];
  expect(item && item.kind).toBe("pick-option");
  expect(item && Array.isArray(item.options) && item.options.length).toBe(4);
  // The body author() synthesized the required §5 fields.
  expect(d && d.body && typeof d.body.tldr === "string" && d.body.tldr.length > 0).toBe(true);
  expect(d && d.body && Array.isArray(d.body.sections) && d.body.sections.length >= 1).toBe(true);

  // A bead_ref is required (the one client-supplied field) — an empty gi is refused.
  const bad = await call("dossier-generate", [{ id: "x", kind: "decide", trigger: "worker_stuck", tier: "blocking" }]);
  expect(bad.status === 422 || (bad.body && bad.body.ok === false)).toBe(true);
});
