// I4 (claude-tools-uxvi4) — the "Escalate to decision" stuck action is a PURE
// engine write (DESIGN I §4): the control proxy (web/functions/api/control/
// escalate.js) builds a §5-valid `worker_stuck`/`blocking` generation-input and
// POSTs dossier-generate. This spec pins that the template the proxy builds is
// ACCEPTED by the engine's §5 gate (validateDossier) and persists a Flow B
// decision card with the four stuck options — so escalate cannot silently 422.
//
// claude-tools-x949: this imports the REAL shared builder (web/shared/
// stuck-dossier.js) that escalate.js uses — NOT a hand-copied mirror — so a
// drift out of §5 reds this offline gate instead of hiding until live-verify.

import { SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { buildStuckGi } from "../../web/shared/stuck-dossier.js";

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

it("I4 escalate dossier template passes the §5 gate and persists a Flow B card", async () => {
  const gi = buildStuckGi({ beadRef: "rhythmGame-93o", projectRef: "rhythmGame", title: "wire the input handler" });
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
