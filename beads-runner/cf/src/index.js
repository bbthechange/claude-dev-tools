// CF.1 (claude-tools-7g0.1) — the Worker: §2.3 authed request endpoint +
// §9.1 THE ONE authenticate(request)->principal chokepoint.
//
// Every inbound control-plane request passes through EXACTLY this one step
// (UI or agent — NO split, C4). On missing/invalid bearer the request is
// rejected with 401 BEFORE the Coordinator DO is ever contacted, so a rejected
// request performs ZERO §4 writes (EXIT crit 2 — structurally, not by
// convention). On success the RESOLVED principal is threaded down to the
// singleton Coordinator DO; there is NO second auth path and NO UI-vs-agent
// branch anywhere.
//
// Differential oracle: lib/coordinator.sh co_authenticate + co_request +
// lib/test-coordinator.sh. Same INTERFACE.md v1 §9.1/§2.3 behavior.
//
// Appendix A: §2.3/§9.1 chokepoint -> a Worker middleware (this file);
// the singleton DO (idFromName("coordinator")) is the single-threaded
// serialiser => §2.1/§7.4 single-writer BY CONSTRUCTION (the AD1 payoff).

import { Coordinator } from "./coordinator.js";
import { PRINCIPAL_V1 } from "./schema.js";

export { Coordinator };

// ── §9.1 the ONE authenticate(request) -> principal ─────────────────────────
// v1 "validity" (verbatim from coordinator.sh co_authenticate): the bearer
// must be present (non-empty); if env.CO_EXPECTED_TOKEN is set it MUST equal
// it (the test/caller knob that drives the invalid-token path, mirroring the
// bash CO_EXPECTED_TOKEN). On success: resolve the CONSTANT principal =
// PRINCIPAL_V1 (AD6 single-user; C7: later = mint real tokens + stop returning
// the constant, with NO schema change). On missing/invalid: null.
//
// The principal is resolved HERE and threaded down — never a hardcoded literal
// at any use site (C7/§9.1). All actors authenticate identically (C4 — no
// UI/agent split, NO §0.C asymmetry enforced).
function authenticate(request, env) {
  const hdr = request.headers.get("authorization") || "";
  const m = hdr.match(/^Bearer\s+(.+)$/i);
  const bearer = m ? m[1] : "";
  if (!bearer) return null;
  const expected = env && env.CO_EXPECTED_TOKEN;
  if (expected && String(expected).length > 0 && bearer !== String(expected)) {
    return null;
  }
  return PRINCIPAL_V1(env);
}

// Singleton Coordinator DO: ONE global instance => single-threaded =>
// every write serialised through one actor (§2.1 / §7.4 / AD1).
function coordinatorStub(env) {
  const id = env.COORDINATOR.idFromName("coordinator");
  return env.COORDINATOR.get(id);
}

export default {
  async fetch(request, env) {
    // §2.3: THE single front door. The chokepoint runs EXACTLY ONCE, at the
    // top, for EVERY request — before any op dispatch, before any DO contact.
    const principal = authenticate(request, env);
    if (!principal) {
      // Rejected BEFORE any §4 write — the DO is never contacted on this path.
      return new Response(
        JSON.stringify({
          ok: false,
          error:
            "co: 401 — bearer token missing/invalid; request rejected (NO §4 write; §9.1/§2.3)",
        }),
        { status: 401, headers: { "content-type": "application/json" } }
      );
    }

    // GET / => health + the four §2 capabilities (still behind the ONE
    // chokepoint above — every inbound request authenticates, no exceptions).
    if (request.method === "GET") {
      const stub = coordinatorStub(env);
      return stub.fetch("https://do/", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ op: "capabilities", args: [], principal }),
      });
    }

    if (request.method !== "POST") {
      return new Response(JSON.stringify({ ok: false, error: "method not allowed" }), {
        status: 405,
        headers: { "content-type": "application/json" },
      });
    }

    // op + args arrive as JSON {op, args:[...]}. The RESOLVED principal is
    // threaded down (§9.1) — the DO trusts it and never re-derives it.
    let payload;
    try {
      payload = await request.json();
    } catch {
      return new Response(JSON.stringify({ ok: false, error: "bad request body" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }
    const op = payload && payload.op;
    const args = (payload && payload.args) || [];

    const stub = coordinatorStub(env);
    return stub.fetch("https://do/", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ op, args, principal }),
    });
  },
};
