/* beads-runner/cf/pages-dev/adapter.js — CF.10 (claude-tools-7g0.10).
 *
 * THE LOCAL WIRING this child owns — and ONLY the wiring. It rewrites the
 * FROZEN Pages proxies' HTTP framing into the FROZEN CF Worker's HTTP framing.
 * It edits NEITHER frozen surface:
 *
 *   • the T6a/T6b proxies (web/board, web/inbox /functions/api/*.js) speak a
 *     REST dialect: `GET|POST {COORDINATOR_URL}/request?op=<op>&…` with the
 *     op's params in the query string (reads) or a NAMED JSON body (writes),
 *     and the server-side bearer on `Authorization`.
 *   • the CF.1 Worker (../src/index.js) speaks `POST / {op,args:[…]}` with
 *     POSITIONAL args (GET / ⇒ capabilities). It is THE §9.1
 *     authenticate(request)->principal chokepoint and owns the singleton
 *     Coordinator DO.
 *
 * Both dialects are Appendix-A NON-NORMATIVE (§0.2; the transport shape was
 * explicitly recorded as "untested live" in the T6b debrief). Reconciling two
 * sibling REALIZATIONS' non-normative framing is realization wiring — NOT an
 * INTERFACE.md gap, so NO claude-tools-65z escalation and NO INTERFACE edit.
 *
 * DISCIPLINE PRESERVED (the whole point):
 *   • The §9.1 chokepoint stays the FROZEN Worker's authenticate(): this
 *     adapter copies the inbound `Authorization` header THROUGH untouched and
 *     never reads, holds, injects, or fabricates the secret (the proxy already
 *     attached the server-side bearer; the client bears none — §9.2). A
 *     `/request` hit with no/invalid bearer is rejected 401 by the FROZEN
 *     Worker exactly as a native hit is — BEFORE any §4 write.
 *   • The op is NEVER chosen here — it is read verbatim from the proxy's
 *     hard-coded `?op=` and forwarded. The adapter cannot widen the op set;
 *     an unmapped op is a 400, never a guess.
 *   • Reads stay reads (GET proxy ops → no write primitive reachable); the
 *     two write ops are exactly the two the proxies own (item-apply,
 *     forensic-dismiss).
 *   • The Coordinator DO + D1 are the byte-unchanged CF.1 engine, re-exported
 *     so wrangler instantiates the SAME single-threaded singleton (the AD1
 *     payoff is untouched). All record logic runs in the FROZEN Worker/DO.
 *
 * COORDINATOR_URL therefore points at THE local CF Worker (this module IS that
 * Worker, with a thin REST front re-frame in front of the unmodified
 * fetch()) — exactly the substrate-handoff seam.
 */

import worker, { Coordinator } from "../src/index.js";

// Re-export the FROZEN DO class so the wrangler.pages-dev.toml binding
// (COORDINATOR -> Coordinator) resolves to the byte-unchanged CF.1 singleton.
export { Coordinator };

function jerr(msg, status) {
  return new Response(JSON.stringify({ ok: false, error: msg }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// op -> positional args, derived ONLY from what the FROZEN proxy transmits.
// These mappings are the differential oracle's `co_request <bearer> <op>
// <args…>` arg order, verbatim:
//   work-snapshot  (proj, beadsStr)   — reconcile.js workSnapshot(co,pr,a0,a1)
//   get            (type, id)         — coordinator.js opGet(a0,a1)
//   item-apply     (did, iid, resp)   — dossier.js itemApply(co,pr,a0,a1,a2)
//   forensic-fetch (blobId)           — forensic.js forensicFetch(co,pr,a0)
//   forensic-dismiss (blobId)         — forensic.js forensicDismiss(co,pr,a0)
//   set-desired    (proj,state,actor) — coordinator.js opSetDesired(pr,a0,a1,a2)
//                                       (F1, Board-side of UX-DESIGN Flow D)
//   item-set-state (did, iid, to)     — dossier.js itemSetState(co,pr,a0,a1,a2)
//                                       (claude-tools-23r, Inbox dismiss-as-stale)
function argsForGet(op, url) {
  const q = url.searchParams;
  if (op === "work-snapshot") {
    // The proxy carries an optional read-only `project` filter and NO inline
    // work plane (a Worker cannot exec `bd`). The empty beads arg is CORRECT
    // and intentional: the Worker self-sources the lifecycle work-truth from
    // the runner-published §4.6 workspace_inventory records when no inline
    // beads are passed (claude-tools-7qf7 — reconcile.js
    // beadsFromWorkspaceInventory). Do NOT try to pass beads here; the adapter
    // stays dumb plumbing and the engine owns the read-join.
    return [q.get("project") || "", ""];
  }
  if (op === "get") return [q.get("type") || "", q.get("id") || ""];
  if (op === "forensic-fetch") return [q.get("id") || ""];
  return null; // unmapped read op — caller emits 400 (never a guess)
}
function argsForPost(op, body) {
  const b = body && typeof body === "object" ? body : {};
  if (op === "item-apply") return [b.dossier_id, b.item_id, b.response];
  if (op === "forensic-dismiss") return [b.id];
  // claude-tools-23r — Inbox "dismiss as stale" affordance. Maps the narrow
  // proxy's named-body {dossier_id,item_id,state} to itemSetState's positional
  // [did, iid, to]. The §5.2 response is intentionally NOT carried: an at-
  // the-shell archive is not a §5.2 decision; the engine's open→expired
  // stateCheck is the only gate. The PROXY (expire.js) hard-codes state to
  // 'expired'; the adapter stays dumb plumbing.
  if (op === "item-set-state") return [b.dossier_id, b.item_id, b.state];
  // L1 follow-up (claude-tools-uxl1b) — the §5.6 defer / escalate verbs. Each
  // narrow proxy (inbox/defer.js, inbox/escalate.js) sends {dossier_id} ONLY;
  // here it unwraps to dossierSetAttention's positional [did]. The engine op
  // (dossier-defer / dossier-escalate) hard-codes the target tier (digest /
  // blocking); the adapter stays dumb plumbing and never picks the op or tier.
  if (op === "dossier-defer" || op === "dossier-escalate") return [b.dossier_id];
  // N2 (claude-tools-uxg1) — the Inbox PWA's Web-Push subscribe/unsubscribe.
  // The browser holds NO secret (§9.1/§9.2): it POSTs the same-origin proxy
  // (web/functions/api/push/*.js), which attaches the server bearer and calls
  // `/request?op=push-subscribe`. Here the named body {endpoint,p256dh,auth}
  // unwraps to handlePushOp's positional [endpoint, p256dh, auth]. The adapter
  // stays dumb plumbing; the engine owns the store + the input gate. (The
  // delivery sweep `notif-deliver` is daemon-native — it hits the Worker root
  // dialect directly and never this `/request` re-frame.)
  if (op === "push-subscribe") return [b.endpoint, b.p256dh, b.auth];
  if (op === "push-unsubscribe") return [b.endpoint];
  // F1 (claude-tools-49w) — Board-side of UX-DESIGN Flow D. The proxy carries
  // the named-JSON-body shape {project_ref, desired:{state,actor}}; here it
  // unwraps to opSetDesired's positional `[proj, state, actor]` (the same
  // `co_request set-desired <proj> <state> <actor>` order the bash oracle
  // uses). The state validation is the PROXY's job (set-desired.js); this
  // adapter is dumb plumbing and stays that way.
  if (op === "set-desired") {
    const d = b.desired && typeof b.desired === "object" ? b.desired : {};
    return [b.project_ref, d.state, d.actor];
  }
  // I2 (claude-tools-x9u) — Flow A intake. The §2.1 `put` op takes positional
  // [type, id, jsonStr]; the proxy sends the named-JSON-body {type, id,
  // record} where `record` is the §4 object to persist. The adapter
  // re-stringifies it because opPut's third arg is a JSON STRING (it parses
  // inside the engine — matches co__store_put's `jq -e .` over a literal).
  // The proxy is responsible for hard-coding the legal type/op pair; the
  // adapter is still dumb plumbing and the engine still owns the schema gate.
  if (op === "put") {
    const rec = b.record && typeof b.record === "object" ? b.record : null;
    return [b.type, b.id, rec === null ? "" : JSON.stringify(rec)];
  }
  return null; // unmapped write op — caller emits 400
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    // NON-`/request` paths are the FROZEN Worker's native dialect — passed
    // straight through UNCHANGED (GET / ⇒ capabilities; POST / {op,args} is
    // how the seed harness, like the bash tests' co_request, plants state).
    if (path !== "/request") {
      return worker.fetch(request, env);
    }

    // ── the proxy REST dialect → native re-frame ──────────────────────────
    const op = url.searchParams.get("op") || "";
    let args;
    if (request.method === "GET") {
      args = argsForGet(op, url);
      if (args === null)
        return jerr(`co: adapter — unsupported GET proxy op '${op}'`, 400);
    } else if (request.method === "POST") {
      let body = null;
      try {
        body = await request.json();
      } catch {
        body = null;
      }
      args = argsForPost(op, body);
      if (args === null)
        return jerr(`co: adapter — unsupported POST proxy op '${op}'`, 400);
    } else {
      return jerr("co: adapter — method not allowed", 405);
    }

    // Forward to the FROZEN Worker in ITS native shape. The Authorization
    // header is copied THROUGH verbatim (present or absent) — the §9.1
    // chokepoint runs in the FROZEN worker.fetch() exactly as before; this
    // adapter never inspects or supplies the bearer.
    const headers = { "content-type": "application/json" };
    const auth = request.headers.get("authorization");
    if (auth) headers["authorization"] = auth;

    const fwd = new Request("https://coordinator.local/", {
      method: "POST",
      headers,
      body: JSON.stringify({ op, args }),
    });
    return worker.fetch(fwd, env);
  },
};
