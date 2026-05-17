// CF.7 (claude-tools-7g0.7) — §2.2 durable timer fire(dossier_id) WIRING +
// the S-6 fire-on-next-poll backstop + timed-fyi auto-proceed, realized on the
// CF.1 substrate and consuming CF.6's idempotent per-Item apply entrypoint.
//
// This is the Cloudflare realization of the bash T5.4:
//   lib/timed-fyi.sh  (tf_arm — §2.2 fire(dossier_id) WIRING;
//                       tf_fire — the SHARED alarm/poll auto-proceed handler;
//                       tf_poll — the S-6 poll-fallback DRIVER)
// and is differential-bound to lib/test-timed-fyi.sh.
//
// THE S-6 MODEL (why this is safe): the §2.2 one-shot timer is realized as the
// CF.1 substrate's `ctx.storage.setAlarm()` capability — best-effort BY
// CONTRACT (free-tier alarms are non-contractual). The DEterministic backstop
// is CF.1's `timer-due` poll-fallback: an armed, un-acked timer whose fire_at
// has passed surfaces on EVERY poll, so a missed/suppressed alarm degrades to
// fire-on-next-poll. `fireDossier` is the ONE auto-proceed handler invoked
// IDENTICALLY by the alarm() path AND the poll-fallback; exactly-once is CF.6's
// §7.4 per-Item latch INSIDE `item-apply` (re-checked under the single-threaded
// actor), NEVER timer reliability and NEVER the best-effort ack — proven by
// re-firing after the ack is lost and under an 8-way alarm⇄poll race.
//
// REALIZATION MAP (the §2.3-front-door analogue — same discipline dossier.js
// documents for its read path): the bash impl consumes the §2.2 timer surface
// via `co_request <bearer> timer-arm|timer-due|timer-ack` (the §2.3 authed
// front door) and the T5.3 entrypoint via `do_item_apply`. Here the §9.1
// chokepoint is the Worker (CF.1) — it has ALREADY authenticated and threaded
// `principal`; this module consumes the SUBSTRATE timer capability via the
// Coordinator's exposed `opTimerArm/opTimerDue/opTimerAck` methods (the CF
// realization of "the §2.2 surface", exactly as dossier.js consumes CF.1's
// `_writeRecord`), and CF.6 via its PUBLIC `handleDossierOp` entrypoint
// (`dossier-get` / `dossier-put` / `item-apply`) — NEVER a CF.6 internal and
// NEVER its `_serialize` (each handleDossierOp call is its OWN single-threaded
// critical section; nesting would self-deadlock the one actor's tail). No new
// §4 record type; no new DDL; the §2.2 timer is the CF.1 `timers` namespace,
// untouched in shape (the CF.1 differential asserts that opaque boundary).
//
// MUST-NOT-TOUCH (bound by the CF.7 issue): the per-Item apply LOGIC + latch is
// CF.6 (this CALLS `item-apply`; it never selects/applies a §5.3 block, flips a
// latch, or moves a state). The substrate timer SURFACE (arm/due/ack rows) is
// CF.1 — consumed as the bare capability, never re-implemented; opTimerArm's
// `setAlarm()` is CF.1's. STUCK routing = CF.8. Notification = CF.9. The §9.1
// chokepoint stays the ONE Worker step — no second auth path is added (C4); the
// alarm() entrypoint has NO request (the runtime invokes the DO directly), so
// it tags the synthetic auto-proceed with the §0.5 single-user principal v1
// resolves to (AD6) — NOT an authentication and NOT the correctness mechanism.
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §2.2 / S-6 (§7.4) / §5.2.2
// (fyi-objectable) + TIMED_FYI_DEFAULT (§0.5) + Appendix A (DO setAlarm). The
// timer is best-effort BY CONTRACT — exactly-once is the §7.4 per-Item latch,
// never timer reliability and never the ack. Oracle = lib/timed-fyi.sh +
// lib/test-timed-fyi.sh. An INTERFACE gap is a §11 escalation (reopen
// claude-tools-65z, bump+re-freeze) — never diverge, never edit INTERFACE.md.

import { PRINCIPAL_V1 } from "./schema.js";
import { handleDossierOp } from "./dossier.js";

// ── the CF.7 op surface. Kept OUT of CF.1's CAPABILITIES (anti-drift: the
//    differential asserts tf_arm/tf_fire/tf_poll are NOT §2 capability lines,
//    exactly as test-timed-fyi.sh EXIT-5 does for the bash tf_* functions). ──
export const TIMER_OPS = new Set([
  "timed-fyi-arm", // tf_arm  — §2.2 fire(dossier_id) WIRING
  "timed-fyi-fire", // tf_fire — the SHARED alarm/poll auto-proceed handler
  "timed-fyi-poll", // tf_poll — the S-6 poll-fallback DRIVER (timer-due driven)
]);

// ── §0.5 frozen constant — single normative definition is INTERFACE.md ───────
// §0.5 forbids a competing local restatement; every consuming file provides an
// env-overridable lookup whose literal default EQUALS the §0.5 table value
// (the schema.js PRINCIPAL_V1 / bash la__/co__/tf__ discipline). T5.4 is the
// REAL use site for the `timed-fyi` window, so — mirroring that discipline and
// the bash `tf__TIMED_FYI_DEFAULT` (`echo "${TIMED_FYI_DEFAULT:-86400}"`) — it
// is defined HERE, env-overridable, never a hardcoded use-site literal.
export function timedFyiDefault(env) {
  const v = env && env.TIMED_FYI_DEFAULT;
  const n = v !== undefined && v !== null && String(v).length > 0 ? Number(v) : NaN;
  return Number.isFinite(n) ? n : 86400; // §0.5
}

// ── portable RFC-3339(…Z, §0.4) ↔ epoch arithmetic ───────────────────────────
// created_at + window, computed without coupling to a substrate internal.
// `created_at` is §0.4 RFC-3339 UTC integer-seconds (`…Z`). An unparseable
// created_at fails CLOSED (arm REJECTED, NO timer) rather than guessing a fire
// time — the bash tf__rfc_to_epoch behavior (return 3, no timer).
function rfcToEpochSec(ts) {
  if (typeof ts !== "string" || ts.length === 0) return null;
  const ms = Date.parse(ts);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}
function epochSecToRfc(ep) {
  if (!Number.isFinite(ep)) return null;
  const d = new Date(ep * 1000);
  const s = d.toISOString();
  return Number.isNaN(d.getTime()) ? null : s.replace(/\.\d{3}Z$/, "Z");
}
function nowRfc() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

// ── consume CF.6 via its PUBLIC handleDossierOp ONLY (never an internal) ─────
async function dossierGet(co, principal, did) {
  const res = await handleDossierOp(co, "dossier-get", [did], principal);
  if (res.status !== 200) return null;
  try {
    return JSON.parse(await res.text());
  } catch {
    return null;
  }
}
async function dossierPut(co, principal, env) {
  const res = await handleDossierOp(co, "dossier-put", [env], principal);
  return res.status === 200;
}
async function itemApply(co, principal, did, iid, resp) {
  const res = await handleDossierOp(co, "item-apply", [did, iid, resp], principal);
  return res.status === 200; // 200 = applied OR idempotent no-op (§7.4 latch)
}

// ── consume the CF.1 substrate §2.2 timer SURFACE as the bare capability ─────
// (the §2.3-front-door → co.opTimer* analogue; never re-implemented, never the
// `timers` table shape — CF.1 owns that, its differential asserts it opaque).
async function timerArm(co, tid, fireAt) {
  const res = await co.opTimerArm(tid, fireAt);
  return res.status === 200;
}
async function timerDue(co, now) {
  const res = await co.opTimerDue(now);
  const raw = await res.text();
  return raw.split("\n").filter(Boolean);
}
async function timerAck(co, tid) {
  // Best-effort ONLY (stop the poll-fallback re-surfacing a consumed fire);
  // NEVER the correctness mechanism — a failed/absent ack just re-runs
  // fireDossier idempotently on the next poll (the §7.4 per-Item latch is the
  // truth). Swallow everything, exactly as the bash `|| true`.
  try {
    await co.opTimerAck(tid);
  } catch {
    /* non-fatal — S-6 correctness rides the per-Item latch, not the ack */
  }
}

// ════════════════════════════════════════════════════════════════════════════
// §2.2 fire(dossier_id)@T WIRING — arm the timed-fyi auto-proceed window
// (port of tf_arm + tf__arm_locked). The timer id IS the dossier id.
// ════════════════════════════════════════════════════════════════════════════
// Returns { ok:true, fire_at:<rfc>|null } on success (fire_at echoes the
// computed @T, mirroring bash tf_arm's stdout; null = a no-op informational
// success — non-timed-fyi tier or window=null), or { ok:false, msg } REJECT
// (out-of-range/malformed window, missing dossier, unparseable created_at) —
// a REJECT performs NO envelope write and arms NO timer (bash parity).
async function tfArm(co, principal, did, winArg) {
  const rec = await dossierGet(co, principal, did);
  if (!rec) {
    return {
      ok: false,
      msg: `timed-fyi: arm — dossier '${did}' not found OR not authorized (§9.1 chokepoint collapses 401/absent; no second auth path — C4)`,
    };
  }

  const tier = typeof rec.tier === "string" ? rec.tier : "";
  if (tier !== "timed-fyi") {
    // A non-timed-fyi dossier MUST NOT auto-proceed (§4.1 tier drives this).
    // Soft-disarm any stale prior arm (harmless no-op if none).
    await timerAck(co, did);
    return { ok: true, fire_at: null };
  }

  const def = timedFyiDefault(co.env);

  // null window ⇒ explicit NO auto-proceed (§4.1 timer_fire_at null when no
  // window). Clear the envelope field AND soft-disarm a prior §2.2 arm via the
  // surface's stop-re-surfacing primitive timer-ack (§2.2 has no disarm; the
  // per-Item §7.4 latch still bounds any race to once). Bash tf_arm review #1.
  if (winArg === "null" || winArg === null) {
    const w = await dossierPut(co, principal, { ...rec, timer_fire_at: null });
    if (!w) return { ok: false, msg: `timed-fyi: arm — could not clear timer_fire_at for '${did}'` };
    await timerAck(co, did);
    return { ok: true, fire_at: null };
  }

  // default vs per-dossier override ∈ (0, TIMED_FYI_DEFAULT].
  let win;
  if (winArg === undefined || winArg === "" || winArg === "default") {
    win = def;
  } else {
    const s = String(winArg);
    if (!/^[0-9]+$/.test(s)) {
      return {
        ok: false,
        msg: `timed-fyi: arm REJECTED — window '${s}' not a non-negative integer of seconds (§0.4 durations are integer seconds)`,
      };
    }
    win = Number(s);
    if (win <= 0 || win > def) {
      return {
        ok: false,
        msg: `timed-fyi: arm REJECTED — window ${win} out of range; per-dossier override MUST be ∈ (0, TIMED_FYI_DEFAULT=${def}] (§2.2/§0.5)`,
      };
    }
  }

  const epoch = rfcToEpochSec(rec.created_at);
  if (epoch === null) {
    return {
      ok: false,
      msg: `timed-fyi: arm — dossier '${did}' created_at '${rec.created_at}' unparseable (§0.4 RFC-3339 …Z)`,
    };
  }
  const fireAt = epochSecToRfc(epoch + win);
  if (fireAt === null) {
    return { ok: false, msg: `timed-fyi: arm — could not derive timer_fire_at for '${did}'` };
  }

  // Store timer_fire_at on the §4.1 envelope (CF.6 stores it verbatim) ...
  const w = await dossierPut(co, principal, { ...rec, timer_fire_at: fireAt });
  if (!w) return { ok: false, msg: `timed-fyi: arm — could not set timer_fire_at for '${did}'` };

  // ... and arm the §2.2 one-shot fire(dossier_id) on the substrate surface.
  if (!(await timerArm(co, did, fireAt))) {
    return { ok: false, msg: `timed-fyi: arm — §2.2 timer-arm failed for '${did}'@${fireAt}` };
  }
  return { ok: true, fire_at: fireAt };
}

// ════════════════════════════════════════════════════════════════════════════
// §2.2 / S-6 — the SHARED auto-proceed handler (alarm-fire AND poll-fallback)
// (port of tf_fire). Auto-proceed every un-objected fyi-objectable OPEN item by
// calling CF.6's idempotent `item-apply` with a proceed response. INVOKED
// IDENTICALLY by the alarm() path AND the S-6 poll-fallback — so a missed alarm
// degrades to fire-on-next-poll and alarm⇄poll cannot double-apply:
// exactly-once is CF.6's §7.4 per-Item latch, NOT this handler and NOT the ack.
// ════════════════════════════════════════════════════════════════════════════
// An item auto-proceeds iff: kind == fyi-objectable AND state == open AND
// consequence_applied == false. That EXCLUDES an OBJECTED item (the human's
// decision:"object" already moved it off open via CF.6's reconciler) and a
// non-fyi-objectable sibling carried in a timed-fyi dossier (LEFT OPEN — it
// blocks neither siblings nor the pipeline, AD7 partial resolution).
async function fireDossier(co, principal, did) {
  const rec = await dossierGet(co, principal, did);
  if (!rec) {
    return {
      ok: false,
      msg: `timed-fyi: fire — dossier '${did}' not found OR not authorized (§9.1 collapses 401/absent — C4)`,
    };
  }
  const tier = typeof rec.tier === "string" ? rec.tier : "";
  if (tier !== "timed-fyi") {
    // nothing auto-proceeds (§4.1 tier) — informational no-op success.
    return { ok: true, fired: did, warned: false };
  }

  // The synthetic auto-proceed response — self-describing ("not a human turn —
  // the window lapsed un-objected"). `principal` is the §9.1-resolved value
  // threaded in (poll path) or the §0.5 v1 principal (alarm path); never a
  // literal at the use site (C7). fyi-objectable + decision:"approve" +
  // un-edited routes DETERMINISTIC in CF.6 (§5.2.2) ⇒ its pre-declared §5.3
  // block applied EXACTLY ONCE via the §7.4 per-Item latch.
  const proceed = {
    decision: "approve",
    auto_proceed: true,
    responded_at: nowRfc(),
    principal,
  };

  // Snapshot the un-objected, unresolved fyi-objectable items; the per-Item
  // latch — re-read under item-apply's own single-threaded section — is the
  // truth (a stale enumeration is safe; this handler takes NO outer section).
  const ids = (Array.isArray(rec.items) ? rec.items : [])
    .filter(
      (it) =>
        it &&
        it.kind === "fyi-objectable" &&
        it.state === "open" &&
        it.consequence_applied === false
    )
    .map((it) => it.id);

  let warned = false;
  for (const id of ids) {
    // Per-item failure: observable, sibling auto-proceed CONTINUES (AD7
    // partial) — never silently swallowed, never aborts the dossier.
    const ok = await itemApply(co, principal, did, id, proceed);
    if (!ok) warned = true;
  }

  // Best-effort ack so the S-6 poll-fallback stops re-surfacing this fire.
  // NEVER the correctness mechanism (that is the §7.4 per-Item latch): a
  // failed/absent ack just means the next poll re-runs fireDossier
  // idempotently (every already-applied item is a latch no-op).
  await timerAck(co, did);
  return { ok: true, fired: did, warned };
}

// ════════════════════════════════════════════════════════════════════════════
// S-6 poll-fallback DRIVER — a missed alarm degrades to fire-on-next-poll
// (port of tf_poll). Ask the substrate §2.2 surface for every armed, un-acked
// timer whose fire_at ≤ now (`timer-due` IS the S-6 poll-fallback — there is no
// alarm daemon) and run fireDossier for each. Whether the alarm fired, was
// suppressed, or raced this poll, CF.6's §7.4 per-Item latch makes every
// auto-proceed exactly-once. Returns the fired dossier ids (observability).
// ════════════════════════════════════════════════════════════════════════════
async function fireDueTimers(co, principal, now) {
  const due = await timerDue(co, now);
  const fired = [];
  let warned = false;
  for (const id of due) {
    const r = await fireDossier(co, principal, id);
    fired.push(id);
    if (r && r.warned) warned = true;
  }
  return { ok: true, fired, warned };
}

// ── the §2.2 setAlarm() entrypoint — wired from the Coordinator DO `alarm()` ─
// CF.1 deliberately left `alarm()` a no-op MARKER for CF.7. The runtime invokes
// the DO directly here: there is NO request and NO bearer to authenticate (so
// this is NOT a second auth path — C4), and correctness does NOT depend on this
// path firing (the deterministic backstop is the timer-due poll-fallback, S-6).
// It runs the SAME shared handler the poll-fallback runs, so the §7.4 per-Item
// latch makes alarm-fire vs poll-fallback exactly-once. The synthetic
// auto-proceed is tagged with the §0.5 single-user principal v1 resolves to
// (AD6) — resolved HERE (not in coordinator.js) so the substrate keeps its "no
// PRINCIPAL_V1 import / no second auth path" discipline and the §0.C grep.
export async function alarmFire(co) {
  return fireDueTimers(co, PRINCIPAL_V1(co.env));
}

// ════════════════════════════════════════════════════════════════════════════
// THE CF.7 DISPATCHER — called from the Coordinator DO for every TIMER_OPS op.
// The §9.1 chokepoint (the Worker) has ALREADY authenticated + threaded
// `principal`; no second auth path here (C4). This module takes NO co._serialize
// of its own — each handleDossierOp call is its own single-threaded critical
// section (nesting would self-deadlock the one actor's tail).
// ════════════════════════════════════════════════════════════════════════════
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleTimerOp(co, op, args, principal) {
  const a = args || [];
  try {
    if (op === "timed-fyi-arm") {
      const r = await tfArm(co, principal, a[0], a[1]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "timed-fyi-fire") {
      const r = await fireDossier(co, principal, a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    if (op === "timed-fyi-poll") {
      const r = await fireDueTimers(co, principal, a[0]);
      return jsonRes(r, r.ok ? 200 : 422);
    }
    return jsonRes({ ok: false, error: `co: unknown timer op '${op}'` }, 400);
  } catch (e) {
    return jsonRes(
      { ok: false, error: `co: timer internal — ${e && e.message ? e.message : e}` },
      500
    );
  }
}
