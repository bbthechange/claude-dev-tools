// CF.8 (claude-tools-7g0.8) — STUCK_NEEDS_HUMAN cross-tier ROUTING, realized on
// the CF.1 substrate. The Cloudflare realization of the bash:
//   lib/stuck-routing.sh  (T5.5 §7.4 dossier-level double-trigger dedup +
//                           §7.3 backstop-drives-the-bead + S-2/AD3.1
//                           control→work reconcile)
// and is differential-bound to lib/test-stuck-routing.sh + the STUCK-e2e
// forward GATE conformance/assertions/bc-stuck-cross-tier.sh (§7.2/§7.3). The
// CF engine MUST exhibit the SAME INTERFACE.md v1 §7.2/§7.3/§7.4(dossier-level)
// behaviour as that oracle — not a re-spec.
//
// OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
//   • §7.4 DOSSIER-level double-trigger dedup. The worker-self-signal (§7.2
//     primary) AND the runner backstop (§7.2 backstop) on the SAME fork
//     collapse to ONE Dossier via the §0.4 two-layer key model's *dossier*
//     layer: key = `task_ref` (DISTINCT from CF.6's per-Item key = Item `id`).
//     The deterministic dossier id is a pure function of `task_ref`, so both
//     triggers compute the SAME id; `dedupRecord`'s single-writer create-once
//     contract collapses them to ONE Dossier ⇒ "two triggers never make two
//     dossiers" (AD3.4 / preserved AD3.1 SCAR-intent).
//   • §7.3 backstop-drives-the-bead. A fired backstop drives the bead to
//     blocked-for-human (status=blocked + `bd human`) — otherwise the fork
//     rots (UX principle 7).
//   • S-2 / AD3.1 control→work reconcile. The COORDINATOR owns
//     "blocked-for-human": `bfhRaise` writes the control-plane SOURCE OF
//     TRUTH; `reconcileBlockedForHuman` asserts that truth back into beads
//     DRIVEN BY THE CONTROL-PLANE RECORD, never by the bead's possibly-stale
//     work-plane status — so work-plane (Dolt) lag is invisible to the
//     human-latency path (the Board never lies — the §1 promise; S-2).
//   • Routes the §7.2 worker structured ask into the CF.6 generator
//     (`dossier-from-worker-ask` → a `worker_stuck` decision dossier, one
//     `pick-option` Item). Generation is best-effort relative to the §7.3
//     drive: the bead-not-rotting guarantee never depends on generation.
//
// THE AD1 PAYOFF (same structural argument CF.1 `_writeRecord` / CF.6 make):
// the bash skeleton hand-rolls a per-`task_ref` `mkdir` advisory lock so the
// dedup/blocked-for-human create-once is single-writer. Here there is NO such
// lock: the dedup + blocked-for-human bindings are D1 rows with a `task_ref`
// PRIMARY KEY, so `INSERT … ON CONFLICT(task_ref) DO NOTHING` IS the atomic
// test-and-set ("one fork ⇒ one binding" BY CONSTRUCTION of the key
// constraint, not a ported compare-and-set). This module therefore does NOT
// use `co._serialize` (and MUST NOT — it delegates the §5 generation /
// dossier-get / item-set-state to CF.6's `handleDossierOp`, which serializes
// those dossier critical sections itself; an outer serialize around an inner
// serialize would self-deadlock on the one shared dossier tail).
//
// REALIZATION BOUNDARY (honest, non-normative — the §0.2/Appendix-A discipline
// CF.6/CF.5 document): §7.3/§7.4 legislate the strongly-consistent CONTROL
// plane — delivered here on the single-threaded singleton DO + the `task_ref`
// PK. The §7.3 bead drive + the S-2 reconcile target the EVENTUAL WORK plane
// (beads/`bd`). A Worker cannot exec `bd`; the work-plane sink here is
// `stuck_work_plane` (one row per `bd <args>` line, verbatim — the EXACT
// analogue of the bash test's PATH-injected logging `bd` fake writing
// $BD_HUMAN/$BD_LOG) plus `stuck_bead_status` (the per-bead status projection
// — the `$BDST/<id>` analogue, the readable `bd show` truth a later writer /
// Dolt lag can clobber out from under us). The real hosted `bd` wiring is a
// deploy-path concern, not this LOCAL-emulation child; a documented
// realisation choice, NOT an INTERFACE divergence (no §11 gap).
//
// MUST-NOT-TOUCH (bound by the CF.8 issue): the per-Item latch + Dossier
// PRODUCTION — CF.6 (consumed ONLY via its public `handleDossierOp` surface:
// `dossier-from-worker-ask` / `dossier-get` / `item-set-state`, exactly as
// bash stuck-routing.sh sources dossier-gen.sh and calls dg_from_worker_ask /
// do_dossier_get / do_item_set_state — never CF.6 internals). The CF.8
// dossier-level `task_ref` dedup is a DISTINCT key space from CF.6's per-Item
// `id` latch — never collide them. The CF.1 substrate (store/auth/§9.1
// chokepoint) — LAYERED on, never altered: these four tables are a SEPARATE
// namespace from `records`/`timers` (mirroring the bash store split + the
// §10.3-forensic / dossier-dedup "NOT a §4 record type" precedent — absent
// from schema.js's §4 registry; adding one is a §0/§11 escalation). The §9.1
// chokepoint stays the ONE Worker step (CF.1) — the resolved `principal` is
// threaded down and trusted, NEVER re-derived here (no second auth path — C4).
// The §7.1 classification precedence + §7.5 retry/breaker exemption + the §7.2
// worker-prompt/backstop DETECTION wiring are the RUNNER/T1a/T2 frozen surface
// — this owns ONLY the cross-tier dossier OUTCOME, never the classifier.
// Notification = CF.9; the §2.2 timer = CF.7.
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §7.2/§7.3/§7.4 (dossier-level) +
// §0.4/§0.2. The cb_schema_version tracks the ONE bound source (schema.js
// `schemaVersion("dossier")`), never a competing literal (§0.5). Oracle =
// lib/stuck-routing.sh + lib/test-stuck-routing.sh + bc-stuck-cross-tier.sh.
// An INTERFACE gap ⇒ reopen claude-tools-65z, bump+re-freeze — NEVER diverge,
// NEVER edit INTERFACE.md.

import { schemaVersion, safeKey } from "./schema.js";
// CF.6's public op surface — the ONLY way this consumes the §5 generator /
// dossier read / per-Item state move (1:1 with bash stuck-routing.sh sourcing
// dossier-gen.sh and calling its public functions; never a reach past it).
import { handleDossierOp } from "./dossier.js";

// The CF.8 op surface. Disjoint from the CF.1 substrate switch and every
// sibling op set (DOSSIER_OPS/NOTIFICATION_OPS/FORENSIC_OPS/RECONCILE_OPS) —
// dispatched in a dedicated guard so the CF.1 substrate stays byte-identical.
// Kept OUT of CF.1's CAPABILITIES (anti-drift: not a §2 capability line).
export const STUCK_OPS = new Set([
  "stuck-route", // sr_route_stuck            — §7.4 dedup + §7.3 drive + route
  "stuck-reconcile", // sr_reconcile_blocked_for_human — S-2 control→work
  "stuck-resolve", // sr_human_resolve         — record the human decision
  "stuck-restart", // sr_stuck_restart        — wipe bfh + expire open items
  "stuck-dedup-record", // do_dedup_record    — the §7.4 dossier dedup STRUCTURE
  "stuck-dedup-get", // do_dedup_get           — read-only structure consult
  "stuck-bfh-get", // sr_bfh_get               — read-only control-plane truth
  "stuck-scan-backstop", // sr_scan_backstop   — §7.2 backstop FIRE recognition
  "stuck-worker-ask", // sr_worker_ask         — synthesised §7.2 raw ask (pure)
]);

// RFC-3339 UTC `…Z`, seconds precision — matches the substrate's own
// timestamp shape (opSetDesired) and the bash `+%Y-%m-%dT%H:%M:%SZ`.
function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}

// ── lazy + idempotent DDL — the SEPARATE T5-owned namespace ─────────────────
// Mirrors CF.1's `ensureSchema` / CF.5's `ensureForensicSchema` discipline
// (CREATE TABLE IF NOT EXISTS, lazy, per-instance memoised) so CF.8 is
// locally-runnable with NO account and NO manual migrate step. The canonical
// migration ships in migrations/0004_stuck.sql for the a53 deploy path. NONE
// of these four is a §4 record (absent from schema.js's §4 registry — the
// dossier-dedup / §10.3-forensic "NOT a §4 record" precedent CF.1/CF.6/CF.5
// already document; adding a §4 type is a §0/§11 escalation, MUST-NOT):
//   • stuck_dedup        — the §7.4 dossier-level dedup binding (the bash
//                          `dossier-dedup` namespace analogue). `task_ref` PK
//                          IS the single-writer create-once test-and-set.
//   • stuck_bfh          — the COORDINATOR-owned blocked-for-human control
//                          plane (the bash `blocked-for-human` namespace);
//                          the S-2 SOURCE OF TRUTH the reconcile drives from.
//   • stuck_bead_status  — the per-bead WORK-plane status projection (the bash
//                          test fake's `$BDST/<id>` analogue; the readable
//                          `bd show` truth a later writer / Dolt lag clobbers).
//   • stuck_work_plane   — append-only `bd <args>` line log (the bash test
//                          fake's $BD_HUMAN/$BD_LOG analogue; §7.3 drive
//                          evidence). Its OWN table, not CF.6's
//                          work_plane_ops (the same sibling-namespace
//                          discipline bash stuck-routing.sh keeps vs
//                          dossier.sh's dossier-dedup).
function ensureStuckSchema(co) {
  if (!co._stuckSchemaReady) {
    co._stuckSchemaReady = (async () => {
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS stuck_dedup (task_ref TEXT PRIMARY KEY, json TEXT NOT NULL)"
        )
        .run();
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS stuck_bfh (task_ref TEXT PRIMARY KEY, json TEXT NOT NULL)"
        )
        .run();
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS stuck_bead_status (bead_ref TEXT PRIMARY KEY, status TEXT NOT NULL)"
        )
        .run();
      await co.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS stuck_work_plane (id INTEGER PRIMARY KEY AUTOINCREMENT, line TEXT NOT NULL)"
        )
        .run();
    })();
  }
  return co._stuckSchemaReady;
}

// ── §0.4 the dossier-level dedup KEY model ───────────────────────────────────
// The dossier-level double-trigger dedup key = `task_ref` (the per-Item key is
// the Item `id`, CF.6 — a DISTINCT latch on a DISTINCT child). The
// deterministic dossier id is a pure function of `task_ref`, so the worker
// self-signal and the runner backstop on the SAME fork compute the SAME id and
// the create-once contract collapses them to ONE Dossier. The id MUST satisfy
// the same `safeKey` predicate ([A-Za-z0-9._-], no '..'); `task_ref` already
// does, the `stuck-` prefix keeps it so and namespaces it away from any
// worker-chosen id. 1:1 with bash `sr_dossier_id_for`.
export function stuckDossierIdFor(tref) {
  if (typeof tref !== "string" || tref.length === 0) return null;
  if (!safeKey(tref)) return null;
  return `stuck-${tref}`;
}

// The §5.3-shaped pre-declared block every synthesised option carries. ONE
// bound source for cb_schema_version (schema.js `schemaVersion("dossier")` —
// the SAME value CF.6's boundSv binds; §0.5: never a competing literal even
// though the bash oracle writes the bound value 1 inline).
function emptyCb() {
  return {
    cb_schema_version: schemaVersion("dossier"),
    creates: [],
    unblocks: [],
    labels: [],
    status_changes: [],
  };
}

// ── do_dedup_record — single-writer CREATE-ONCE bind task_ref → dossier_id ───
//   • first writer for task_ref            ⇒ create + ok
//   • re-create, SAME dossier_id           ⇒ idempotent success (one fork ⇒
//     one Dossier already holds — NOT a second writer)
//   • second writer, DIFFERENT dossier_id  ⇒ REJECTED (no overwrite): the
//     "two triggers never make two dossiers" STRUCTURE
// The `task_ref` PRIMARY KEY + `ON CONFLICT DO NOTHING` IS the atomic
// test-and-set (the bash `mkdir` advisory-lock analogue made structural — the
// AD1 payoff). The §9.1 chokepoint already resolved `principal`; it is stamped
// here, never re-derived (C4) and never a use-site literal (C7).
async function dedupRecord(co, principal, tref, did) {
  if (!principal) {
    return { ok: false, code: "unauthorized" }; // defensive — Worker 401s first
  }
  if (!tref || !did) return { ok: false, code: "need_args" };
  if (!safeKey(tref)) return { ok: false, code: "unsafe_key" };
  const rec = JSON.stringify({
    task_ref: tref,
    dossier_id: did,
    principal,
    created_at: nowIso(),
  });
  // Atomic create-once: only the FIRST writer's row survives; a racing/second
  // writer's INSERT is a no-op (the PK conflict IS the test-and-set).
  await co.db
    .prepare(
      "INSERT INTO stuck_dedup (task_ref, json) VALUES (?, ?) ON CONFLICT(task_ref) DO NOTHING"
    )
    .bind(tref, rec)
    .run();
  const row = await co.db
    .prepare("SELECT json FROM stuck_dedup WHERE task_ref = ?")
    .bind(tref)
    .first();
  let cur = "";
  if (row) {
    try {
      cur = JSON.parse(row.json).dossier_id || "";
    } catch {
      cur = "";
    }
  }
  if (cur === did) return { ok: true }; // created OR idempotent same-fork
  // A DIFFERENT id is already bound — REJECTED, nothing overwritten (DO NOTHING
  // already guaranteed no overwrite). One fork ⇒ one Dossier (§7.4 dossier).
  return { ok: false, code: "rejected_different_id", bound: cur };
}

// do_dedup_get — echo the bound dossier_id (so the §7.4/S-2 LOGIC can CONSULT
// the structure), or null. Read-only structure consult (no §4 read, no write).
async function dedupGet(co, tref) {
  if (!tref || !safeKey(tref)) return null;
  const row = await co.db
    .prepare("SELECT json FROM stuck_dedup WHERE task_ref = ?")
    .bind(tref)
    .first();
  if (!row) return null;
  try {
    const id = JSON.parse(row.json).dossier_id;
    return typeof id === "string" && id.length > 0 ? id : null;
  } catch {
    return null;
  }
}

// ── the COORDINATOR-owned blocked-for-human namespace (S-2 source of truth) ──
// sr__raise_bfh: single-writer CREATE-ONCE control-plane record. First writer
// for task_ref creates {resolved:false}; a re-raise (same task_ref, EITHER
// trigger) is IDEMPOTENT (the existing record stands — one fork ⇒ one
// blocked-for-human, the §7.4 dossier-layer property at the control plane).
async function bfhRaise(co, principal, tref, did, trig) {
  if (!principal) return { ok: false, code: "unauthorized" };
  if (!tref || !did) return { ok: false, code: "need_args" };
  if (!safeKey(tref)) return { ok: false, code: "unsafe_key" };
  const rec = JSON.stringify({
    task_ref: tref,
    dossier_id: did,
    principal,
    trigger: trig || "",
    raised_at: nowIso(),
    resolved: false,
    resolved_at: null,
  });
  // Create-once: the existing record stands on a re-raise (idempotent — one
  // fork ⇒ one blocked-for-human). The PK is the atomic test-and-set.
  await co.db
    .prepare(
      "INSERT INTO stuck_bfh (task_ref, json) VALUES (?, ?) ON CONFLICT(task_ref) DO NOTHING"
    )
    .bind(tref, rec)
    .run();
  return { ok: true };
}

// sr_bfh_get — echo the blocked-for-human record (so the S-2 reconcile / a
// Board projection can CONSULT the control-plane truth), or null. Read-only.
async function bfhGet(co, tref) {
  if (!tref || !safeKey(tref)) return null;
  const row = await co.db
    .prepare("SELECT json FROM stuck_bfh WHERE task_ref = ?")
    .bind(tref)
    .first();
  if (!row) return null;
  try {
    return JSON.parse(row.json);
  } catch {
    return null;
  }
}

// sr__resolve_bfh — flip resolved:false→true under the PK (single-writer).
// This is the control-plane decision — the NEXT reconcile lifts the work-plane
// block (S-2 control→work). Absent record ⇒ idempotent success (nothing to
// resolve), exactly as the bash oracle (rc=0).
async function bfhResolve(co, tref) {
  if (!tref || !safeKey(tref)) return { ok: false, code: "unsafe_key" };
  const row = await co.db
    .prepare("SELECT json FROM stuck_bfh WHERE task_ref = ?")
    .bind(tref)
    .first();
  if (!row) return { ok: true }; // nothing to resolve ⇒ idempotent (bash rc=0)
  let obj;
  try {
    obj = JSON.parse(row.json);
  } catch {
    return { ok: false, code: "corrupt" };
  }
  obj.resolved = true;
  obj.resolved_at = nowIso();
  await co.db
    .prepare("UPDATE stuck_bfh SET json = ? WHERE task_ref = ?")
    .bind(JSON.stringify(obj), tref)
    .run();
  return { ok: true };
}

// ── the WORK-plane projection (the bash test fake's $BDST + $BD_HUMAN) ───────
// `wpLog` records each `bd <args>` line verbatim into stuck_work_plane (the
// $BD_LOG/$BD_HUMAN analogue — §7.3 drive evidence + the `bd human` flag).
// `setBeadStatus` upserts the per-bead status projection (the `$BDST/<id>`
// analogue — the readable `bd show` truth). They are NOT the S-2 source of
// truth: the reconcile is DRIVEN BY stuck_bfh, never by reading these (a
// clobbered/lagged work-plane status is corrected, never trusted — S-2).
async function wpLog(co, argv) {
  await co.db
    .prepare("INSERT INTO stuck_work_plane (line) VALUES (?)")
    .bind(argv.join(" "))
    .run();
}
async function setBeadStatus(co, tref, status) {
  await co.db
    .prepare(
      "INSERT INTO stuck_bead_status (bead_ref, status) VALUES (?, ?) ON CONFLICT(bead_ref) DO UPDATE SET status = excluded.status"
    )
    .bind(tref, status)
    .run();
}

// sr_drive_bead_blocked — the work-plane PROJECTION of the control-plane truth
// (§7.3): drive the bead to blocked-for-human (status=blocked + `bd human`)
// for IMMEDIATE honesty so the fork does not rot before the next reconcile.
// Best-effort + idempotent — the stuck_bfh record remains the SOURCE OF TRUTH
// (S-2): a lost/lagged work-plane write is re-asserted by the reconcile.
async function driveBeadBlocked(co, tref) {
  if (!tref) return;
  await wpLog(co, ["update", tref, "--status=blocked"]);
  await setBeadStatus(co, tref, "blocked");
  await wpLog(co, ["human", tref]);
}

// ── §7.2 backstop FIRE recognition (for the §7.3 drive mandate ONLY) ─────────
// 1:1 with bash `sr_scan_backstop`. Recognises the two §7.2-defined
// runner-side backstop fire conditions in the final claude stream (the
// zero-model-trust signal that the worker slipped past the §7.6 guardrail):
//   • a result.permission_denials[] entry for AskUserQuestion / ExitPlanMode
//   • a tool_result whose content carries the "Entered plan mode." residual
// Recognition SOLELY to discharge §7.3 — it is NOT the §7.1 classifier (that
// is byte-untouched T2/T1a) and is intentionally precise so it matches ONLY a
// genuine backstop fire. Accepts the slurped stream as an array of event
// objects (or a JSON-array / newline-delimited string), mirroring the bash
// `jq -s` slurp of the JSONL stream file.
function scanBackstop(stream) {
  let events = [];
  if (Array.isArray(stream)) {
    events = stream;
  } else if (typeof stream === "string" && stream.length > 0) {
    try {
      const p = JSON.parse(stream);
      events = Array.isArray(p) ? p : [p];
    } catch {
      events = stream
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l.length > 0)
        .map((l) => {
          try {
            return JSON.parse(l);
          } catch {
            return null;
          }
        })
        .filter((e) => e !== null);
    }
  }
  // (1) permission_denials[] on the result line (zero model trust).
  for (const e of events) {
    if (
      e &&
      e.type === "result" &&
      e.permission_denials != null &&
      Array.isArray(e.permission_denials) &&
      e.permission_denials.some(
        (d) =>
          d &&
          (d.tool === "AskUserQuestion" ||
            d.tool === "ExitPlanMode" ||
            d.tool_name === "AskUserQuestion" ||
            d.tool_name === "ExitPlanMode")
      )
    ) {
      return { fired: true, token: "permission_denials" };
    }
  }
  // (2) "Entered plan mode." tool_result residual (EnterPlanMode silent no-op).
  for (const e of events) {
    if (e && e.type === "tool_result") {
      const c = e.content == null ? "" : e.content;
      const s = typeof c === "string" ? c : JSON.stringify(c);
      if (/Entered plan mode\./.test(s)) {
        return { fired: true, token: "entered_plan_mode" };
      }
    }
  }
  return { fired: false, token: null };
}

// sr_worker_ask — a fired BACKSTOP means the worker slipped WITHOUT writing the
// §7.2 structured ask, so a minimal, contract-valid ask is synthesised here as
// raw material for CF.6 (the dossier builder owns the §5 authoring; this only
// supplies the §7.2 raw shape). One contract-valid pick-option (≥1 option with
// a machine-applyable §5.3 block + recommendation{value,why}) so CF.6 can
// author a `worker_stuck` dossier. 1:1 with bash `sr_worker_ask`.
function workerAsk(tref, rtext) {
  let tldr = `A backstop fired on ${tref}: the worker reached an interactive fork it must not resolve and slipped past the §7.6 guardrail.`;
  if (rtext) tldr = `${tldr} Worker said: ${rtext}`;
  return {
    tldr,
    ask: `How should the runner proceed on ${tref} (a human-decision fork)?`,
    options: [
      {
        option_id: "resume",
        label: "I have unblocked it — resume the task",
        blast_radius: "Re-queues the task as-is once a human resolves the fork.",
        consequence_block: emptyCb(),
      },
      {
        option_id: "abandon",
        label: "Abandon / re-scope this task",
        blast_radius: "Leaves the bead blocked-for-human pending a human re-scope.",
        consequence_block: emptyCb(),
      },
    ],
    recommendation: {
      value: "resume",
      why: "The fork is a human decision, not a task failure; resume once decided (§7.5 retry-exempt).",
    },
    reversible:
      "Fully reversible — no consequence is applied until a human picks an option (§5.3 = CF.6).",
  };
}

// dossier-get via CF.6's public op (the bash `do_dossier_get` consult). 200 ⇒
// the Dossier exists; 404 ⇒ absent. Never reaches past handleDossierOp.
async function dossierExists(co, principal, did) {
  const res = await handleDossierOp(co, "dossier-get", [did], principal);
  return res.status === 200;
}

// ════════════════════════════════════════════════════════════════════════════
// §7.4 + §7.3 + route — THE single STUCK routing entry (port of
// sr_route_stuck). `trigger` is free-form provenance (`worker_stuck` for the
// §7.2 primary; `backstop:<which>` for a fired backstop). Steps, in the bash
// order:
//   1. Derive the deterministic dossier id from `task_ref` (§0.4) — both
//      triggers on the SAME fork compute the SAME id.
//   2. dedupRecord binds task_ref→id create-once; a re-bind with the SAME id
//      is idempotent ⇒ the §7.4 dossier-layer "two triggers never two".
//   3. Raise the blocked-for-human record (S-2 source of truth) and drive the
//      bead (§7.3) — the bead-not-rotting guarantees, BEFORE generation so
//      they never depend on it.
//   4. Generate the Dossier ONLY if one does not already exist for this id
//      (CF.6 `dossier-from-worker-ask`). The second trigger finds it present
//      and SKIPS generation — one fork ⇒ ONE Dossier.
// Returns { ok:true, dossier_id } once the bead is driven + bfh raised (the
// §7.3/S-2 OUTCOME), even if best-effort generation later failed — the fork
// must never rot on a generation hiccup.
// ════════════════════════════════════════════════════════════════════════════
async function routeStuck(co, principal, tref, trig, ask) {
  if (!tref) {
    return { ok: false, error: "stuck: route — need <task_ref>" };
  }
  const did = stuckDossierIdFor(tref);
  if (!did) {
    return { ok: false, error: `stuck: route — unsafe task_ref '${tref}' (§0.4)` };
  }
  const trigger = trig || "worker_stuck";

  // §7.4 dossier-layer: create-once bind. With the deterministic id a
  // same-fork re-trigger is idempotent; a different id for the same task_ref
  // cannot happen here (id is a pure function of task_ref). A store hiccup is
  // non-fatal — the §7.3 fork-must-not-rot guarantee still proceeds.
  await dedupRecord(co, principal, tref, did);

  // §7.3 / S-2 — raise the control-plane truth, then project it to the bead.
  await bfhRaise(co, principal, tref, did, trigger);
  await driveBeadBlocked(co, tref);

  // Route the §7.2 ask into CF.6 — ONLY on the first trigger (one Dossier).
  if (!(await dossierExists(co, principal, did))) {
    const a = ask && typeof ask === "object" ? ask : workerAsk(tref);
    // Best-effort, exactly as bash `dg_from_worker_ask … || echo warn`: the
    // §7.3 drive already discharged the fork-not-rot guarantee BEFORE this, so
    // a generation hiccup never rots the fork. The try/catch makes that
    // structural — independent of whether CF.6's handleDossierOp surfaces an
    // error as a non-2xx Response (it does) or ever throws.
    try {
      await handleDossierOp(co, "dossier-from-worker-ask", [did, tref, a], principal);
    } catch {
      /* generation deferred; the §7.3/S-2 OUTCOME already stands */
    }
  }

  return { ok: true, dossier_id: did };
}

// ════════════════════════════════════════════════════════════════════════════
// S-2 / AD3.1 — control→work reconcile (port of
// sr_reconcile_blocked_for_human). The COORDINATOR reconciles its
// blocked-for-human records back into beads. DRIVEN BY THE CONTROL-PLANE
// RECORD, never by the bead's work-plane status (which may lag or have been
// clobbered) — so work-plane (Dolt) lag is INVISIBLE to the human-latency
// path:
//   • resolved:false ⇒ (re-)assert the work-plane block (status=blocked +
//     `bd human`) unconditionally and idempotently — a lagged/clobbered bead
//     is corrected here (the Board never lies, S-2).
//   • resolved:true  ⇒ the human decided: LIFT the work-plane block
//     (status=open so the task re-enters the ready set) and hard-delete the
//     record (the fork is closed). Idempotent: a missing record / already
//     lifted is a no-op.
// With no <task_ref> it sweeps every record. Returns the count acted on;
// always ok (a reconcile never aborts the runner).
// ════════════════════════════════════════════════════════════════════════════
async function reconcileBlockedForHuman(co, principal, only) {
  let rows;
  if (only) {
    if (!safeKey(only)) return { ok: true, n: 0 };
    const { results } = await co.db
      .prepare("SELECT json FROM stuck_bfh WHERE task_ref = ?")
      .bind(only)
      .all();
    rows = results || [];
  } else {
    const { results } = await co.db
      .prepare("SELECT json FROM stuck_bfh ORDER BY task_ref")
      .all();
    rows = results || [];
  }
  let n = 0;
  for (const r of rows) {
    let obj;
    try {
      obj = JSON.parse(r.json);
    } catch {
      continue;
    }
    const tref = obj && typeof obj.task_ref === "string" ? obj.task_ref : "";
    if (!tref) continue;
    const resolved = obj.resolved === true;
    if (resolved) {
      // Human decided ⇒ lift the block (control→work). Driven by the record,
      // NOT by reading bead status — Dolt lag cannot make this lie.
      await wpLog(co, ["update", tref, "--status=open"]);
      await setBeadStatus(co, tref, "open");
      await co.db
        .prepare("DELETE FROM stuck_bfh WHERE task_ref = ?")
        .bind(tref)
        .run();
    } else {
      // Still blocked-for-human ⇒ re-assert the work-plane truth idempotently.
      await wpLog(co, ["update", tref, "--status=blocked"]);
      await setBeadStatus(co, tref, "blocked");
      await wpLog(co, ["human", tref]);
    }
    n += 1;
  }
  return { ok: true, n };
}

// sr_human_resolve — the human-approval entry. Records the decision on the
// control plane (`bfhResolve`) so the next reconcile lifts the work-plane
// block (S-2). If an item is named, the per-Item state is moved open→answered
// via CF.6's public `item-set-state` so the CF.6/CF.7 applier (a sibling,
// orthogonal) can later apply the chosen §5.3 block — this NEVER applies a
// consequence or flips the per-Item latch (CF.6's). Idempotent.
async function humanResolve(co, principal, tref, did, iid, resp) {
  if (!tref) {
    return { ok: false, error: "stuck: resolve — need <task_ref>" };
  }
  if (did && iid) {
    // Best-effort, exactly as bash `do_item_set_state … || true`: the
    // human-decision record (bfhResolve, below) is the durable truth; a
    // state-move hiccup must NOT lose the decision. The try/catch makes that
    // ordering structural — `bfhResolve` always runs even if the delegated
    // item-set-state ever throws (independent of CF.6's error surfacing).
    const args =
      resp !== undefined && resp !== null
        ? [did, iid, "answered", resp]
        : [did, iid, "answered"];
    try {
      await handleDossierOp(co, "item-set-state", args, principal);
    } catch {
      /* the decision is recorded below regardless (S-2 durability) */
    }
  }
  const r = await bfhResolve(co, tref);
  if (!r.ok) {
    return { ok: false, error: `stuck: resolve — could not record decision for '${tref}'` };
  }
  return { ok: true };
}

// ════════════════════════════════════════════════════════════════════════════
// sr_stuck_restart — the operator "wipe + re-run from scratch" entry point.
// Distinct from `stuck-resolve` (which carries a human decision; with an item
// arg flips the item open→answered, recording a no-op decision otherwise).
// Restart instead:
//   1. Expires every still-open dossier item via the existing open→expired
//      transition (CF.6 `item-set-state`, the same path §5.2 dismiss-as-stale
//      uses). Items already in answered/applied/expired are left untouched —
//      the monotonic state machine forbids reverse transitions (§4.1.1/§5.2),
//      and respecting that preserves the audit history Option A protects.
//   2. Flips the stuck_bfh record resolved:false→true (same path
//      `humanResolve(tref-only)` uses). The next §S-2 reconcile then LIFTS
//      the work-plane block (status=open, drops `human`) and hard-deletes the
//      record — the bead re-enters the ready set for a fresh agent pickup.
// Idempotent. Best-effort per-item expiry: a single item failing (e.g.
// already-answered race) does not abort the wipe — the bfh flip still runs
// so the bead can be re-armed. Absent dossier / absent bfh ⇒ ok no-op.
// ════════════════════════════════════════════════════════════════════════════
async function restartStuck(co, principal, tref) {
  if (!principal) return { ok: false, code: "unauthorized" };
  if (!tref) return { ok: false, error: "stuck: restart — need <task_ref>" };
  if (!safeKey(tref)) return { ok: false, code: "unsafe_key" };
  const did = stuckDossierIdFor(tref);
  let expired = 0;
  if (did) {
    const dres = await handleDossierOp(co, "dossier-get", [did], principal);
    if (dres.status === 200) {
      let rec = null;
      try {
        rec = JSON.parse(await dres.text());
      } catch {
        rec = null;
      }
      const items = rec && Array.isArray(rec.items) ? rec.items : [];
      for (const it of items) {
        if (!it || typeof it.id !== "string") continue;
        if (it.state !== "open") continue;
        try {
          const r = await handleDossierOp(co, "item-set-state", [did, it.id, "expired"], principal);
          if (r.status === 200) expired += 1;
        } catch {
          /* best-effort: bfh flip below still re-arms the bead */
        }
      }
    }
  }
  const r = await bfhResolve(co, tref);
  if (!r.ok) {
    return { ok: false, error: `stuck: restart — could not flip bfh for '${tref}'` };
  }
  return { ok: true, expired };
}

// ════════════════════════════════════════════════════════════════════════════
// THE CF.8 DISPATCHER — called from the Coordinator DO for every STUCK_OPS op.
// The §9.1 chokepoint (the Worker, CF.1) has ALREADY authenticated + threaded
// the resolved `principal` — there is NO second auth path here (C4); a
// no/invalid-token stuck-* is rejected 401 at the Worker BEFORE this guard.
// This module does NOT use `co._serialize`: its create-once is structural (the
// `task_ref` PK), and it delegates §5 generation / dossier-get /
// item-set-state to CF.6's `handleDossierOp`, which serializes those dossier
// critical sections itself (an outer serialize would self-deadlock on the one
// shared dossier tail). `co._ensureDossierSchema()` is invoked first (idempotent
// + cached) so a delegated dossier op never races its own lazy DDL.
// ════════════════════════════════════════════════════════════════════════════
export async function handleStuckOp(co, op, args, principal) {
  const a = args || [];
  try {
    await ensureStuckSchema(co);
    // Pure recognition — no store, mirrors notification.js's pure short-circuit.
    if (op === "stuck-scan-backstop") {
      return jsonRes(scanBackstop(a[0]));
    }
    if (op === "stuck-worker-ask") {
      return jsonRes({ ok: true, ask: workerAsk(a[0], a[1]) });
    }
    // CF.6 delegations need its lazy work-plane DDL ready (idempotent+cached).
    await co._ensureDossierSchema();

    if (op === "stuck-route") {
      const r = await routeStuck(co, principal, a[0], a[1], a[2]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "stuck-reconcile") {
      const r = await reconcileBlockedForHuman(co, principal, a[0]);
      return jsonRes(r, 200);
    }
    if (op === "stuck-resolve") {
      const r = await humanResolve(co, principal, a[0], a[1], a[2], a[3]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "stuck-restart") {
      const r = await restartStuck(co, principal, a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "stuck-dedup-record") {
      const r = await dedupRecord(co, principal, a[0], a[1]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "stuck-dedup-get") {
      const id = await dedupGet(co, a[0]);
      if (id === null) return jsonRes({ ok: false, found: false }, 404);
      return textRes(id);
    }
    if (op === "stuck-bfh-get") {
      const rec = await bfhGet(co, a[0]);
      if (rec === null) return jsonRes({ ok: false, found: false }, 404);
      return textRes(JSON.stringify(rec));
    }
    return jsonRes({ ok: false, error: `co: unknown stuck op '${op}'` }, 400);
  } catch (e) {
    return jsonRes(
      { ok: false, error: `co: stuck internal — ${e && e.message ? e.message : e}` },
      500
    );
  }
}
