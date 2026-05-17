/* beads-runner/cf/pages-dev/seed.mjs — CF.10 (claude-tools-7g0.10).
 *
 * Plants the LOCAL demo/e2e state directly on the FROZEN engine via its
 * NATIVE dialect (POST {base}/ {op,args} + Bearer) — the 1:1 analogue of how
 * the differential oracle (lib/test-inbox.sh / cf/test/dossier.spec.js) seeds
 * with `co_request <bearer> <op> <args…>`. This is a TEST HARNESS step, NOT a
 * proxy: the proxies are one-op-each readers/writers; seeding state is exactly
 * what the bash tests do directly against co_request. It deliberately does
 * NOT go through /request (that is the proxy dialect) and never through the
 * Pages proxies.
 *
 * Fixtures mirror the FROZEN oracle (dossier.spec.js gItemAr/SRC_STRUCT/gi):
 * a `dossier-generate` with TWO approve-reject items so that after the Inbox
 * answers ONE, the OTHER stays open ⇒ a PARTLY-ANSWERED dossier that the
 * §4.5 WAITING-ON-YOU lane keeps showing (AD7) — EXIT crit 1.
 *
 * Usage:  node seed.mjs <coordinator_base_url> <bearer> [dossier_id]
 */

const BASE = (process.argv[2] || "").replace(/\/+$/, "");
const BEARER = process.argv[3] || "";
const DID = process.argv[4] || "dRT";
if (!BASE || !BEARER) {
  console.error("seed.mjs: need <coordinator_base_url> <bearer>");
  process.exit(2);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
async function call(op, args) {
  // Retry transient connection resets: wrangler dev can drop the socket once
  // right after its first bundle even after the port is answering (the window
  // verify.sh's stable-readiness gate also guards). A few short retries make
  // the seed robust without masking a real failure (status is still surfaced).
  let res, lastErr;
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      res = await fetch(BASE + "/", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: "Bearer " + BEARER,
        },
        body: JSON.stringify({ op, args: args || [] }),
      });
      break;
    } catch (e) {
      lastErr = e;
      if (attempt === 5) throw e;
      await sleep(400 * attempt);
    }
  }
  if (!res) throw lastErr || new Error("fetch failed");
  const raw = await res.text();
  let body = null;
  try {
    body = JSON.parse(raw);
  } catch {
    /* text/plain ops (get/forensic) — raw is the payload */
  }
  return { status: res.status, raw, body };
}
function ok(r) {
  if (r.status === 200 && r.body === null) return true; // text/plain 2xx
  return !!(r.body && r.body.ok === true) || (r.status >= 200 && r.status < 300);
}
function die(label, r) {
  console.error(`seed.mjs: ${label} FAILED — status=${r.status} body=${r.raw}`);
  process.exit(1);
}

// ── §1.1 heartbeat report (recent observed_at ⇒ a LIVE running runner) ──────
function nowISO() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}
const HB = JSON.stringify({
  report: "heartbeat",
  schema_version: 1,
  principal: "literal-overwritten-by-§9.1",
  runner_id: "hostA",
  project_ref: "projA",
  actual: "running",
  current_task_ref: "claude-tools-99",
  observed_at: nowISO(),
});

// ── §5 generation input (oracle fixtures: gItemAr / SRC_STRUCT / gi) ────────
const CBG = {
  cb_schema_version: 1,
  creates: [{ title: "follow-up from dossier", type: "task" }],
  unblocks: ["claude-tools-dep"],
  labels: [],
  status_changes: [],
};
const gItemAr = (id) => ({
  id,
  kind: "approve-reject",
  framing: { ask: "Approve the static-bearer auth boundary?", why: "Unblocks T3." },
  context_anchor: {
    where: "design stage — the §9.1 coordinator boundary",
    expansion: "v1 is a constant principal; this fixes the C7 seam shape.",
  },
  reversible: "Reversible — a config seam in v1.",
  consequence_block: CBG,
});
const SRC_STRUCT = {
  tldr: "Pick the auth boundary for the coordinator.",
  ask: "Which token model does v1 adopt?",
  sections: [
    { heading: "Context", prose: "The runner reached the §9.1 chokepoint and must not guess." },
    { heading: "Trade-offs", prose: "Static bearer vs per-call mint — load-bearing for C7." },
  ],
  diagrams: [{ caption: "Auth flow", content: "runner -> [authenticate] -> principal" }],
  full_detail:
    "Standalone: v1 uses a constant principal; the pick fixes the C7 seam so later is one if at the chokepoint, no migration.",
  structural: true,
};
const GI = {
  id: DID,
  kind: "decide",
  trigger: "worker_stuck",
  bead_ref: "claude-tools-99",
  tier: "blocking",
  timer_fire_at: null,
  source: SRC_STRUCT,
  items: [gItemAr("a1"), gItemAr("a2")],
};

const RED = JSON.stringify({
  redacted: true,
  tool_use: ["Read(x.ts)"],
  errors: ["WATCHDOG"],
  last_turn: "…",
});

(async () => {
  let r;
  r = await call("set-desired", ["projA", "running", "ui:brian-laptop"]);
  if (!ok(r)) die("set-desired projA", r);

  r = await call("heartbeat", [HB]);
  if (!ok(r)) die("heartbeat projA", r);

  r = await call("dossier-generate", [GI]);
  if (!ok(r)) die("dossier-generate " + DID, r);
  const genId = (r.body && r.body.id) || DID;

  r = await call("forensic-put", ["fb-1", DID, RED]);
  if (!ok(r)) die("forensic-put fb-1", r);

  console.log(
    JSON.stringify({
      ok: true,
      dossier_id: genId,
      forensic_blob: "fb-1",
      runner: "projA",
    })
  );
})().catch((e) => {
  console.error("seed.mjs: unexpected error — " + (e && e.message ? e.message : e));
  process.exit(1);
});
