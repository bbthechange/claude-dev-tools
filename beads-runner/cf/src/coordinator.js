// CF.1 (claude-tools-7g0.1) — the Coordinator Durable Object.
//
// THE foundation substrate. The singleton instance (idFromName("coordinator"))
// is single-threaded, so every write is serialised through ONE actor =>
// §2.1 / §7.4 single-writer-per-(type,id) BY CONSTRUCTION. This is the AD1
// payoff: it REPLACES the bash co__with_lock hand-rolled advisory lock — there
// is no lock here because the runtime gives us the critical section for free.
//
// Differential oracle: lib/coordinator.sh substrate (co__store_put /
// co__store_get / co__set_desired / co__poll / co__timer_* / co_capabilities)
// + lib/test-coordinator.sh. Same INTERFACE.md v1 §-clause behavior, not a
// re-spec. Binds FROZEN §2.1–2.4 / §4 / §0.3 / §9.1 / Appendix A.
//
// MUST-NOT-TOUCH siblings (deliberately ABSENT here): lease arbitration/fencing
// (CF.2), reconcile semantics + work-snapshot projection + S-1 liveness (CF.3),
// capacity aggregation (CF.4), forensic store (CF.5), Dossier body/items +
// fire(dossier_id) + per-Item latch (CF.6/CF.7), Notification dispatch (CF.9).
// This is the substrate and nothing else.

// PRINCIPAL_V1 is deliberately NOT imported here: the DO trusts the principal
// the ONE §9.1 chokepoint (the Worker) resolved and threaded down — it never
// re-derives it (no second auth path, C4).
import { schemaVersion, safeKey, validateRecord } from "./schema.js";
// CF.6 (claude-tools-7g0.6) — the Dossier/Item logic layered ON this
// substrate. It is a SEPARATE module (mirroring how bash dossier.sh/
// dossier-gen.sh/consequence.sh are separate libs that source coordinator.sh
// and consume its public surface). The CF.1 ops below are byte-unchanged; CF.6
// ops are dispatched in a dedicated guard so this substrate stays untouched.
import { DOSSIER_OPS, handleDossierOp } from "./dossier.js";
// CF.9 (claude-tools-7g0.9) — the §4.3 Notification, layered ON this
// substrate (a SEPARATE module, mirroring bash notification.sh sourcing
// coordinator.sh + consuming its public surface). It composes notification
// creation/dispatch through this DO's ONE write path `_writeRecord`; it adds
// NO §4 record type (`notification` is ALREADY in the schema.js registry) and
// NO new DDL (it reuses the `records` table). Its ops are dispatched in a
// dedicated guard so this substrate stays untouched.
import { NOTIFICATION_OPS, handleNotificationOp } from "./notification.js";
// CF.5 (claude-tools-7g0.5) — the §10.3 forensic transient store, layered ON
// this substrate (a SEPARATE module). CRITICAL: it is NOT a §4 record — it is
// deliberately NOT routed through `_writeRecord` / the `records` table /
// `validateRecord` (the §10.3 transient encrypted namespace + content-free
// audit + server master key are its OWN D1 tables, lazy-DDL'd in the module).
// Its ops are dispatched in a dedicated guard so this substrate stays
// untouched and `forensic` stays ABSENT from the §4 registry (structurally
// "never in the §4.5 projection / a §4.3 Notification body").
import { FORENSIC_OPS, handleForensicOp } from "./forensic.js";

export class Coordinator {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.db = env.DB;
    this._schemaReady = null;
    // CF.6: lazy DDL for the work-plane sink + the single-threaded-actor
    // serialization tail (the AD1 payoff — see _serialize / dossier.js).
    this._dossierSchemaReady = null;
    this._dossierTail = Promise.resolve();
  }

  // §2.1 store realisation (Appendix A: "DO state + D1"). The §4 records live
  // in D1; this DO is the single-threaded serialiser in front of it. Lazy,
  // idempotent DDL keeps the substrate locally-runnable with NO account and NO
  // manual migrate step (the canonical migration file ships for the a53 deploy
  // path). `timers` is a SEPARATE namespace from `records` — the §2.2 timer is
  // not a §4 record (mirrors the bash store/timers/ split, anti-drift).
  ensureSchema() {
    if (!this._schemaReady) {
      this._schemaReady = (async () => {
        await this.db
          .prepare(
            "CREATE TABLE IF NOT EXISTS records (type TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (type, id))"
          )
          .run();
        await this.db
          .prepare(
            "CREATE TABLE IF NOT EXISTS timers (timer_id TEXT PRIMARY KEY, fire_at TEXT NOT NULL, armed_at TEXT, acked INTEGER NOT NULL DEFAULT 0)"
          )
          .run();
      })();
    }
    return this._schemaReady;
  }

  // ── CF.6 (claude-tools-7g0.6) work-plane sink DDL — lazy + idempotent ─────
  // `work_plane_ops` is the §5.3 ConsequenceBlock control→work sink: one row
  // per `bd <args>` line, the exact analogue of the bash tests' PATH-injected
  // logging `bd` fake writing $BD_LOG. It is NOT a §4 record (a Worker cannot
  // exec `bd`; this is the LOCAL realisation, documented in dossier.js) — a
  // SEPARATE namespace from `records`/`timers`, mirroring the bash store split
  // and the §10.3-forensic-blob "not a §4 record" precedent. The canonical
  // migration ships in migrations/0002_dossier.sql for the a53 deploy path.
  _ensureDossierSchema() {
    if (!this._dossierSchemaReady) {
      this._dossierSchemaReady = this.db
        .prepare(
          "CREATE TABLE IF NOT EXISTS work_plane_ops (id INTEGER PRIMARY KEY AUTOINCREMENT, line TEXT NOT NULL)"
        )
        .run();
    }
    return this._dossierSchemaReady;
  }

  // ── CF.6 THE AD1 PAYOFF — the single-threaded executor, made explicit ─────
  // CF.1's singleton Coordinator DO is ONE actor. A per-Item op is a
  // read→route→apply→latch→state→persist over the §4.1 envelope in D1; D1 is a
  // binding (not ctx.storage), so its awaits are NOT input-gated. This chains
  // every dossier critical section onto a single per-instance tail so the ONE
  // actor runs exactly one at a time — realising the AD1 "single-threaded DO
  // per dossier-Item" so per-Item idempotency + partial application are TRUE
  // BY CONSTRUCTION. This is NOT the bash per-dossier `mkdir` advisory lock
  // (no per-resource key, no test-and-set): it is the one actor's own
  // single-threadedness, held across the D1-await boundary. The chain never
  // breaks on a rejected/throwing section (the tail always resolves).
  _serialize(fn) {
    const prev = this._dossierTail;
    let release;
    this._dossierTail = new Promise((res) => {
      release = res;
    });
    const run = prev.then(
      () => fn(),
      () => fn()
    );
    run.then(
      () => release(),
      () => release()
    );
    return run;
  }

  // The DO front door. The Worker (§9.1 chokepoint) has ALREADY authenticated
  // and resolved the principal; it threads {op,args,principal} here. There is
  // NO second auth path (C4): the DO trusts the resolved principal the one
  // chokepoint passed down and never re-derives it.
  async fetch(request) {
    await this.ensureSchema();
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "bad request body" }, 400);
    }
    const { op, args = [], principal } = body || {};

    // ── CF.6 (claude-tools-7g0.6) Dossier/Item op guard ──────────────────────
    // CF.6 ops are handled by the dedicated dossier module so the CF.1
    // substrate switch below stays byte-identical (its differential vs
    // coordinator.sh + test-coordinator.sh must not regress). The §9.1
    // chokepoint (the Worker) has ALREADY authenticated + threaded `principal`
    // — no second auth path is added here (C4). The work-plane sink DDL is
    // lazy + idempotent, exactly like the §4 store DDL.
    if (DOSSIER_OPS.has(op)) {
      await this._ensureDossierSchema();
      return await handleDossierOp(this, op, args, principal);
    }

    // ── CF.9 (claude-tools-7g0.9) Notification op guard ──────────────────────
    // The §4.3 Notification, dispatched by its dedicated module so the CF.1
    // substrate switch below stays byte-identical. No DDL: notification
    // records live in the existing `records` table (`notification` is an
    // ALREADY-registered §4 type — CF.9 adds none). The §9.1 chokepoint (the
    // Worker) has ALREADY authenticated + threaded `principal` — no second
    // auth path (C4); the module composes every write through `_writeRecord`.
    if (NOTIFICATION_OPS.has(op)) {
      return await handleNotificationOp(this, op, args, principal);
    }

    // ── CF.5 (claude-tools-7g0.5) §10.3 forensic transient-store op guard ────
    // The forensic store is dispatched by its dedicated module so the CF.1
    // substrate switch below stays byte-identical. It is NOT a §4 record: the
    // module owns its OWN transient encrypted D1 namespace + content-free
    // audit + server master key (lazy + idempotent DDL there), deliberately
    // BYPASSING `_writeRecord`/`records`/`validateRecord` so the §10.3
    // transient path is a SEPARATE add that does NOT weaken §10.1/BC-27. The
    // §9.1 chokepoint (the Worker) has ALREADY authenticated + threaded
    // `principal` — no second auth path (C4); a no/invalid-token forensic-* is
    // rejected 401 at the Worker BEFORE this guard and before any decryption.
    if (FORENSIC_OPS.has(op)) {
      return await handleForensicOp(this, op, args, principal);
    }

    try {
      switch (op) {
        case "put":
          return await this.opPut(principal, args[0], args[1], args[2]);
        case "get":
          return await this.opGet(args[0], args[1]);
        case "set-desired":
          return await this.opSetDesired(principal, args[0], args[1], args[2]);
        case "poll":
          return await this.opPoll(principal, args[0], args[1]);
        case "timer-arm":
          return await this.opTimerArm(args[0], args[1]);
        case "timer-due":
          return await this.opTimerDue(args[0]);
        case "timer-ack":
          return await this.opTimerAck(args[0]);
        case "capabilities":
          return text(CAPABILITIES);
        default:
          return json(
            {
              error:
                "co: unknown op (substrate §2 surfaces: put|get|set-desired|poll|timer-arm|timer-due|timer-ack|capabilities)",
            },
            400
          );
      }
    } catch (e) {
      return json({ error: `co: internal — ${e && e.message ? e.message : e}` }, 500);
    }
  }

  // ── §2.1 / §4 STORE OWNER: the ONE write path — §0.3 gate then §9.1 stamp ──
  // _writeRecord is the single hosted analogue of co__store_put: it runs the
  // §0.3 / safe-key / §4 gate (validateRecord — same precedence + messages as
  // the bash gate) and ONLY on pass stamps the RESOLVED principal, OVERWRITING
  // whatever literal the record carried (C7 — never a trusted use-site
  // literal), then performs the serialised single write. EVERY persist path
  // (put AND set-desired) composes on this, exactly as the bash impl composes
  // co__set_desired on co__store_put — no second write path can skip the gate.
  // Returns {ok:true} or {ok:false,code,msg} (nothing persisted on reject).
  async _writeRecord(principal, type, id, obj) {
    const v = validateRecord(type, id, obj);
    if (!v.ok) return { ok: false, code: v.code, msg: v.msg };
    obj.principal = principal; // §9.1 stamp — after the gate, before the write
    // Single-threaded DO turn => this upsert IS the serialised single write
    // for (type,id). No co__with_lock needed: the runtime is the critical
    // section (the AD1 payoff replacing the bash advisory lock).
    await this.db
      .prepare("INSERT OR REPLACE INTO records (type, id, json) VALUES (?, ?, ?)")
      .bind(type, id, JSON.stringify(obj))
      .run();
    return { ok: true };
  }

  // §2.1 / §4: put. Precedence is IDENTICAL to coordinator.sh co__store_put —
  //   1. known §4 type;  2. safe id;  3. valid JSON + §4 schema_version:int
  //   bound to v1 (higher => reject, never best-effort-parse);  4. §9.1 stamp.
  // The type + safe-id gates run on the RAW args BEFORE the JSON is parsed, so
  // an unknown-type / unsafe-id rejection wins over a parse failure, matching
  // the bash order (co__schema_version + co__safe_key precede the jq parse).
  async opPut(principal, type, id, jsonStr) {
    if (schemaVersion(type) === null) {
      return json({ ok: false, code: "unknown_type", error: `co: reject — unknown §4 record type '${type}'` }, 422);
    }
    if (!safeKey(id)) {
      return json(
        {
          ok: false,
          code: "unsafe_id",
          error: `co: reject — unsafe record id '${id}' (allowed [A-Za-z0-9._-], no '..'; store-owner input hygiene)`,
        },
        422
      );
    }
    let obj;
    try {
      obj = JSON.parse(jsonStr);
    } catch {
      return json({ ok: false, code: "invalid_json", error: `co: reject — ${type} record is not valid JSON` }, 422);
    }
    const r = await this._writeRecord(principal, type, id, obj);
    if (!r.ok) return json({ ok: false, code: r.code, error: r.msg }, 422);
    return json({ ok: true });
  }

  // §2.1 / §4: get — echo the stored record, or 404 (reachable, just empty).
  // Mirrors co__store_get EXACTLY: it does NO record-type check — a get on an
  // unknown type or a missing id is identically "reachable, just empty" (the
  // bash co__store_get returns 1 on a non-existent path with no type gate).
  async opGet(type, id) {
    const row = await this.db
      .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
      .bind(type, id)
      .first();
    if (!row) return json({ ok: false, found: false }, 404);
    return text(row.json);
  }

  // ── §9.1 C4 seam: captured-not-enforced desired-state actor capture ───────
  // Mirrors co__set_desired EXACTLY: capture desired + last_desired_actor +
  // updated_at, merged best-effort onto the prior RunnerState envelope. There
  // is deliberately NO branch on `actor` and NO UI-vs-agent path — every actor
  // is authorised IDENTICALLY (the §0.C downgrade/promote asymmetry is
  // §0.C-DEFERRED and MUST NOT be enforced in v1). A corrupt/absent prior
  // record MUST NOT wedge the control path: degrade to a fresh base so
  // last_desired_actor is still captured. Principal is stamped (§9.1), never a
  // literal here.
  async opSetDesired(principal, proj, desired, actor) {
    if (!proj || !desired) {
      return json({ ok: false, error: "co: set-desired needs <proj> <state> <actor>" }, 422);
    }
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const row = await this.db
      .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
      .bind("runner_state", proj)
      .first();
    let base = {};
    if (row) {
      try {
        const prev = JSON.parse(row.json);
        if (prev && typeof prev === "object" && !Array.isArray(prev)) base = prev;
      } catch {
        base = {}; // corrupt prior => fresh base (graceful degrade, EXIT crit 4)
      }
    }
    base.project_ref = proj;
    base.schema_version = 1;
    base.desired = desired;
    base.last_desired_actor = actor; // captured verbatim, NO actor branch
    base.updated_at = now;
    // Compose on the ONE write path — same as the bash co__set_desired ending
    // in co__store_put. This routes `proj` through the safe-key gate and the
    // §0.3 schema check (an unsafe proj id is rejected, nothing written, just
    // like the oracle) and applies the §9.1 stamp there, not here.
    const r = await this._writeRecord(principal, "runner_state", proj, base);
    if (!r.ok) return json({ ok: false, code: r.code, error: r.msg }, 422);
    return json({ ok: true });
  }

  // ── §2.4 deliver-desired-state-on-reconnect — TRANSPORT ONLY ──────────────
  // Returns the STORED RunnerState.desired and the raw stored Lease record (if
  // a lease_id is given). Pure transport: it returns what is stored and
  // enqueues nothing. It runs NO reconcile, derives NO `liveness`, and
  // arbitrates NO lease (those SEMANTICS are CF.3 / CF.2 — the output carries
  // NO 'liveness' key, asserted by the differential test).
  async opPoll(principal, proj, leaseId) {
    const rsRow = await this.db
      .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
      .bind("runner_state", proj)
      .first();
    let runnerState = null;
    if (rsRow) {
      try {
        runnerState = JSON.parse(rsRow.json);
      } catch {
        runnerState = null;
      }
    }
    let lease = null;
    if (leaseId) {
      const lRow = await this.db
        .prepare("SELECT json FROM records WHERE type = ? AND id = ?")
        .bind("lease", leaseId)
        .first();
      if (lRow) {
        try {
          lease = JSON.parse(lRow.json);
        } catch {
          lease = null;
        }
      }
    }
    const desired =
      runnerState && typeof runnerState === "object" ? runnerState.desired ?? null : null;
    return json({ principal, desired, runner_state: runnerState, lease });
  }

  // ── §2.2 durable one-shot timer — CAPABILITY SURFACE ONLY ─────────────────
  // arm/due/ack, mirroring co__timer_arm / co__timer_due / co__timer_ack. The
  // armed record is the OPAQUE shape {timer_id,fire_at,armed_at,acked} with NO
  // dossier/item/consequence coupling — fire(dossier_id) wiring and the
  // per-Item exactly-once latch are CF.6/CF.7 (the differential test asserts
  // this opaque boundary). setAlarm() is the Appendix-A alarm capability; the
  // timer-due poll-fallback below IS the S-6 'missed fire => fire-on-next-poll'
  // backstop that makes the alarm's non-contractual reliability safe.
  async opTimerArm(tid, fireAt) {
    if (!tid || !fireAt) {
      return json({ ok: false, error: "co: timer_arm needs <id> <fire_at>" }, 422);
    }
    // Same store-owner input hygiene as §4 record ids — reuse the ONE
    // safeKey definition (no duplicated predicate that could drift from it).
    if (!safeKey(tid)) {
      return json({ ok: false, error: `co: reject — unsafe timer id '${tid}'` }, 422);
    }
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    await this.db
      .prepare(
        "INSERT OR REPLACE INTO timers (timer_id, fire_at, armed_at, acked) VALUES (?, ?, ?, 0)"
      )
      .bind(tid, fireAt, now)
      .run();
    // §2.2 alarm capability surface (Appendix A: a DO setAlarm()). Best-effort
    // schedule. The alarm() handler is a no-op marker here: the
    // Dossier-specific fire(dossier_id) + per-Item latch are CF.6/CF.7
    // (MUST-NOT-TOUCH). Correctness never depends on the alarm — timer-due is
    // the deterministic S-6 backstop, exactly like the bash impl.
    try {
      const t = Date.parse(fireAt);
      if (!Number.isNaN(t)) await this.ctx.storage.setAlarm(t);
    } catch {
      /* alarm is a non-contractual convenience; the poll-fallback is the contract */
    }
    return json({ ok: true });
  }

  // S-6 poll-fallback: surface every armed, un-acked timer whose fire_at <= now
  // on the NEXT poll, deterministically, with no alarm daemon. Newline-joined
  // timer_ids (matches the bash co__timer_due stdout the test greps with -qx).
  async opTimerDue(now) {
    const ts = now || new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const { results } = await this.db
      .prepare("SELECT timer_id FROM timers WHERE acked = 0 AND fire_at <= ? ORDER BY timer_id")
      .bind(ts)
      .all();
    const ids = (results || []).map((r) => r.timer_id);
    return text(ids.join("\n") + (ids.length ? "\n" : ""));
  }

  async opTimerAck(tid) {
    if (!tid) return json({ ok: false }, 422);
    const r = await this.db
      .prepare("UPDATE timers SET acked = 1 WHERE timer_id = ?")
      .bind(tid)
      .run();
    const changed = r && r.meta && typeof r.meta.changes === "number" ? r.meta.changes : 0;
    return json({ ok: changed > 0, changed });
  }

  // §2.2 alarm() handler — present so setAlarm() is a real capability surface.
  // Intentionally a no-op: the Dossier-specific fire(dossier_id) consequence
  // and the per-Item exactly-once latch are CF.6/CF.7 (MUST-NOT-TOUCH). The
  // S-6 contract is satisfied by the timer-due poll-fallback, not by this.
  async alarm() {
    /* no dossier semantics here — CF.6/CF.7 own fire(dossier_id) + the latch */
  }
}

// EXACT four §2 capability lines from coordinator.sh co_capabilities (the
// differential test greps for '§2.1 store' / '§2.2 durable one-shot' /
// '§2.3 authed' / '§2.4 deliver-desired' and asserts exactly four '§2' lines).
export const CAPABILITIES = [
  "§2.1 store                       : POST / put|get   (Coordinator DO + D1)",
  "§2.2 durable one-shot timer      : POST / timer-arm|timer-due|timer-ack  (DO setAlarm + S-6 poll-fallback)",
  "§2.3 authed endpoint (§9.1 choke): the Worker  (the ONE authenticate->principal step)",
  "§2.4 deliver-desired-state       : POST / poll      (transport; set-desired captures C4 actor)",
].join("\n");

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
function text(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
