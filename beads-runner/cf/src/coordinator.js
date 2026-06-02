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
import { DOSSIER_OPS, handleDossierOp, dossierWriteBodyOk } from "./dossier.js";
// CF.9 (claude-tools-7g0.9) — the §4.3 Notification, layered ON this
// substrate (a SEPARATE module, mirroring bash notification.sh sourcing
// coordinator.sh + consuming its public surface). It composes notification
// creation/dispatch through this DO's ONE write path `_writeRecord`; it adds
// NO §4 record type (`notification` is ALREADY in the schema.js registry) and
// NO new DDL (it reuses the `records` table). Its ops are dispatched in a
// dedicated guard so this substrate stays untouched.
import { NOTIFICATION_OPS, handleNotificationOp } from "./notification.js";
// N2 (claude-tools-uxg1) — phone DELIVERY transport (DESIGN N §2), layered ON
// this substrate (a SEPARATE module). It is NOT a §4 record: the push-
// subscription store + the deliver-once ledger are the module's OWN transient
// `push_subscriptions`/`push_deliveries` namespaces (lazy + idempotent DDL
// there), the forensic.js / capacity.js / machine-state.js "NOT a §4 record"
// precedent — so `push_subscription` stays ABSENT from the schema.js §4
// registry. It REUSES the K3 rollup engine (notification.js groupDigests/
// digestCopy) verbatim for the digest cadence and makes NO INTERFACE §4.3
// change. Its ops are dispatched in a dedicated guard so this substrate stays
// untouched. The §9.1 chokepoint (the Worker) has ALREADY authenticated +
// threaded `principal` — no second auth path (C4).
import { PUSH_OPS, handlePushOp } from "./push.js";
// CF.5 (claude-tools-7g0.5) — the §10.3 forensic transient store, layered ON
// this substrate (a SEPARATE module). CRITICAL: it is NOT a §4 record — it is
// deliberately NOT routed through `_writeRecord` / the `records` table /
// `validateRecord` (the §10.3 transient encrypted namespace + content-free
// audit + server master key are its OWN D1 tables, lazy-DDL'd in the module).
// Its ops are dispatched in a dedicated guard so this substrate stays
// untouched and `forensic` stays ABSENT from the §4 registry (structurally
// "never in the §4.5 projection / a §4.3 Notification body").
import { FORENSIC_OPS, handleForensicOp } from "./forensic.js";
// CF.3 (claude-tools-7g0.3) — §4.2 RunnerState reconcile semantics + S-1
// liveness derivation + the §4.5 read-only work-snapshot projection PRODUCER,
// layered ON this substrate (a SEPARATE module, mirroring how bash
// reconcile/work-snapshot logic lives in coordinator.sh alongside the store).
// It LAYERS on this DO's `opPoll` §2.4 TRANSPORT (byte-unchanged, stays
// liveness-free — the CF.1 differential asserts that opaque boundary) and
// composes the §1.1 heartbeat WRITE through this DO's ONE write path
// `_writeRecord` (§0.3 re-enforced + §9.1 principal stamped THERE — C7); it
// adds NO §4 record type (`runner_state`/`work_snapshot` are ALREADY in the
// schema.js registry) and NO new DDL (reuses the `records` table). Its ops are
// dispatched in a dedicated guard so this substrate stays untouched.
import { RECONCILE_OPS, handleReconcileOp } from "./reconcile.js";
// CF.8 (claude-tools-7g0.8) — §7.2/§7.3/§7.4(dossier-level) STUCK_NEEDS_HUMAN
// cross-tier routing, layered ON this substrate (a SEPARATE module, mirroring
// bash stuck-routing.sh sourcing dossier-gen.sh + consuming its public
// surface). It composes the §5 generation / dossier-get / item-set-state
// THROUGH CF.6's public `handleDossierOp` (never CF.6 internals); its
// dossier-level `task_ref` dedup + the blocked-for-human control plane are its
// OWN sibling D1 namespace (lazy + idempotent DDL there) — NOT §4 record types
// (the §4 registry is CF.1's, unchanged). Its ops are dispatched in a
// dedicated guard so this substrate stays untouched.
import { STUCK_OPS, handleStuckOp } from "./stuck.js";
// CF.7 (claude-tools-7g0.7) — §2.2 fire(dossier_id) timer WIRING + the S-6
// fire-on-next-poll backstop + timed-fyi auto-proceed, layered ON this
// substrate (a SEPARATE module, mirroring bash timed-fyi.sh sourcing
// consequence.sh + consuming the §2.2 timer surface). It consumes this DO's
// EXPOSED §2.2 capability (opTimerArm/opTimerDue/opTimerAck — byte-unchanged
// below; the `timers` namespace shape is untouched) and CF.6's PUBLIC
// `handleDossierOp` (`item-apply`); it adds NO §4 record type and NO DDL. Its
// ops are dispatched in a dedicated guard so this substrate stays untouched;
// `alarmFire` wires the §2.2 setAlarm() callback CF.1 left as a no-op marker.
import { TIMER_OPS, handleTimerOp, alarmFire } from "./timer.js";
// CF.4 (claude-tools-7g0.4) — §6.3/§6.2 coordinator-side COARSE capacity
// aggregation + the AD2.2 capacity-half fail-OPEN posture, layered ON this
// substrate (a SEPARATE module, mirroring how the bash co__capacity_* /
// co__ask_capacity / co_ask_capacity live in coordinator.sh alongside the
// store but consume its public surface). It adds NO §4 record type: a §1.1
// capacity report is NOT a §4 record — `capacity_reports` is the module's OWN
// sibling D1 namespace (lazy + idempotent DDL there), the §10.3-forensic /
// dossier-dedup "NOT a §4 record" precedent — so `capacity` stays ABSENT from
// the schema.js §4 registry and is structurally never in the §4.5 projection.
// Its ops are dispatched in a dedicated guard so this substrate stays
// untouched. The §9.1 chokepoint (the Worker) has ALREADY authenticated +
// threaded `principal` — no second auth path (C4). The §6.2 fail-OPEN
// reachable|unreachable wrapper (askCapacityFailOpen) is RUNNER-side decision
// logic, NOT a DO op (an "unreachable" op call is a contradiction) — exactly
// as bash co_ask_capacity is NOT routed through co_request.
import { CAPACITY_OPS, handleCapacityOp } from "./capacity.js";
// C12 (claude-tools-zdxd.3) — MACHINE-STATE.md v1 (D2) per-machine telemetry
// channel, layered ON this substrate (a SEPARATE module, mirroring how the
// parallel §1.1 capacity report lives in capacity.js). It adds NO §4 record
// type: a D2 machine_state report is NOT a §4 record — `machine_state_reports`
// is the module's OWN sibling D1 namespace (lazy + idempotent DDL there), the
// capacity_reports / forensic / dossier-dedup "NOT a §4 record" precedent —
// so `machine_state` stays ABSENT from the schema.js §4 registry and is
// structurally never in the §4.5 projection. Its ops are dispatched in a
// dedicated guard so this substrate stays untouched. The §9.1 chokepoint
// (the Worker) has ALREADY authenticated + threaded `principal` — no second
// auth path (C4); a no/invalid-token op is rejected 401 at the Worker BEFORE
// this guard, so it writes NOTHING.
import { MACHINE_STATE_OPS, handleMachineStateOp } from "./machine-state.js";
// CF.2 (claude-tools-7g0.2) — the §6.1/§6.2/§4.4 global exclusive TTL'd LEASE
// arbitration + the §4.4 monotonic `generation` fencing token + the AD2.2
// LEASE-half DEGRADED-CLOSED unreachable posture, layered ON this substrate
// (a SEPARATE module, mirroring how the bash co__lease_* / co_lease_acquire
// live in coordinator.sh alongside the store but consume its public surface).
// `lease` is an ALREADY-registered §4 type (schema.js, v1) — CF.2 adds NO §4
// record type and NO new DDL: a Lease lives in the existing `records` table,
// so the grant/renew writes compose on this DO's ONE gated §4 write path
// `_writeRecord` (§0.3 re-enforced + §9.1 principal stamped THERE — C7), and
// release is an IRRECOVERABLE record DELETE (the bash `rm -f`, NOT a
// tombstone). The acquire/renew/release read-decide-write CRITICAL SECTION
// runs on this DO's single-threaded `_serialize` tail — the singleton DO IS
// the global lease mutex, so N concurrent claimants resolve to EXACTLY ONE
// winner BY CONSTRUCTION (the AD1 payoff replacing the bash co__with_lock
// "lease.<task>" hand-rolled latch — the BC-04 close). Its ops are dispatched
// in a dedicated guard so this substrate stays untouched. The §9.1 chokepoint
// (the Worker) has ALREADY authenticated + threaded `principal` — no second
// auth path (C4). The §6.2 DEGRADED-CLOSED reachable|unreachable wrapper
// (leaseAcquireDegradedClosed) is RUNNER-side decision logic, NOT a DO op (an
// "unreachable" op call is a contradiction) — exactly as bash co_lease_acquire
// is NOT routed through co_request.
import { LEASE_OPS, handleLeaseOp } from "./lease.js";
// K2 (claude-tools-uxvk2) — DESIGN K §3 cross-workspace `relay_log` transient +
// the relay-log-append/-tail ops, layered ON this substrate (a SEPARATE
// module, the capacity.js/machine-state.js/forensic.js shape). It adds NO §4
// record type: a cross-WS relay exchange is NOT a §4 record — `relay_log` is
// the module's OWN sibling D1 namespace (lazy + idempotent DDL there), the
// forensic_audit / capacity_reports "append-only, not a §4 record" precedent
// (Contract A.2) — so `relay_log` stays ABSENT from the schema.js §4 registry
// and is structurally never in the §4.5 projection / a §4.3 Notification body
// (it must NEVER page anyone by itself; the batched FYI is K3's job). Its ops
// are dispatched in a dedicated guard so this substrate stays untouched. The
// §9.1 chokepoint (the Worker) has ALREADY authenticated + threaded
// `principal` — no second auth path (C4); a no/invalid-token relay op is
// rejected 401 at the Worker BEFORE this guard, so it writes NOTHING.
import { RELAY_OPS, handleRelayOp } from "./relay.js";

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

    // ── N2 (claude-tools-uxg1) push DELIVERY op guard ────────────────────────
    // Web Push subscription store + the delivery sweep (notif-deliver),
    // dispatched by its dedicated module so the CF.1 substrate switch below
    // stays byte-identical. NOT a §4 record / NO §4 DDL: subscriptions + the
    // deliver-once ledger live in the module's OWN transient namespaces (lazy +
    // idempotent DDL there), so `push_subscription` stays ABSENT from the §4
    // registry/projection (the §10.3 "not a §4 record" precedent). The §9.1
    // chokepoint (the Worker) has ALREADY authenticated + threaded `principal`
    // — no second auth path (C4); a no/invalid-token push-* op is rejected 401
    // at the Worker BEFORE this guard, so it writes NOTHING and sends NOTHING.
    if (PUSH_OPS.has(op)) {
      return await handlePushOp(this, op, args, principal);
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

    // ── CF.3 (claude-tools-7g0.3) reconcile / liveness / work-snapshot guard ─
    // §4.2 reconcile SEMANTICS + S-1 liveness + the §4.5 read-only projection
    // PRODUCER, dispatched by its dedicated module so the CF.1 substrate
    // switch below stays byte-identical (its differential vs coordinator.sh +
    // test-coordinator.sh must not regress — opPoll in particular stays the
    // pure liveness-free transport). No DDL: runner_state lives in the
    // existing `records` table (`runner_state`/`work_snapshot` are
    // ALREADY-registered §4 types — CF.3 adds none). The §9.1 chokepoint (the
    // Worker) has ALREADY authenticated + threaded `principal` — no second
    // auth path (C4); the heartbeat WRITE composes through `_writeRecord`,
    // reconcile/work-snapshot are READ-ONLY (the §4.5 no-reader-write-path
    // invariant holds BY CONSTRUCTION).
    if (RECONCILE_OPS.has(op)) {
      return await handleReconcileOp(this, op, args, principal);
    }

    // ── CF.8 (claude-tools-7g0.8) STUCK_NEEDS_HUMAN cross-tier routing guard ─
    // §7.2/§7.3/§7.4(dossier-level): one-fork-one-Dossier dedup + the
    // backstop-drives-the-bead + the S-2 control→work reconcile, dispatched by
    // its dedicated module so the CF.1 substrate switch below stays
    // byte-identical. No §4 record type added: the dossier-level `task_ref`
    // dedup + the COORDINATOR-owned blocked-for-human are its OWN sibling
    // namespace (the dossier-dedup / §10.3-forensic "NOT a §4 record"
    // precedent); §5 generation / dossier-get / item-set-state are composed
    // THROUGH CF.6's public `handleDossierOp`. The §9.1 chokepoint (the
    // Worker) has ALREADY authenticated + threaded `principal` — no second
    // auth path (C4).
    if (STUCK_OPS.has(op)) {
      return await handleStuckOp(this, op, args, principal);
    }

    // ── CF.7 (claude-tools-7g0.7) §2.2 timer / S-6 / timed-fyi op guard ──────
    // fire(dossier_id) WIRING + the S-6 fire-on-next-poll backstop + timed-fyi
    // auto-proceed, dispatched by its dedicated module so the CF.1 substrate
    // switch below stays byte-identical. No §4 record type / no DDL: it
    // consumes this DO's EXPOSED §2.2 surface (opTimerArm/opTimerDue/
    // opTimerAck) + CF.6's public `handleDossierOp` (`item-apply` — the §7.4
    // per-Item latch is CF.6's, never re-implemented). The §9.1 chokepoint
    // (the Worker) has ALREADY authenticated + threaded `principal` — no
    // second auth path (C4).
    if (TIMER_OPS.has(op)) {
      await this._ensureDossierSchema();
      return await handleTimerOp(this, op, args, principal);
    }

    // ── CF.4 (claude-tools-7g0.4) §6.3/§6.2 capacity aggregation guard ───────
    // The coarse cost-class verdict aggregation + the AD2.2 capacity-half
    // fail-OPEN posture, dispatched by its dedicated module so the CF.1
    // substrate switch below stays byte-identical. No §4 record type / no §4
    // DDL: a §1.1 capacity report is NOT a §4 record — the module owns its OWN
    // `capacity_reports` namespace (lazy + idempotent DDL there), so
    // `capacity` stays ABSENT from the §4 registry/projection (the §10.3
    // "not a §4 record" precedent). The §9.1 chokepoint (the Worker) has
    // ALREADY authenticated + threaded `principal` — no second auth path
    // (C4); a no/invalid-token capacity op is rejected 401 at the Worker
    // BEFORE this guard, so it writes NOTHING.
    if (CAPACITY_OPS.has(op)) {
      return await handleCapacityOp(this, op, args, principal);
    }

    // ── C12 (claude-tools-zdxd.3) MACHINE-STATE.md v1 (D2) telemetry guard ───
    // The per-machine telemetry channel — a §1.1 UP report carrying the
    // human-facing 5h/7d numbers the Board renders. Dispatched by its
    // dedicated module so this CF.1 substrate switch stays byte-identical.
    // NO §4 record type / NO §4 DDL: a D2 machine_state report is NOT a §4
    // record — the module owns its OWN `machine_state_reports` namespace
    // (lazy + idempotent DDL there), so `machine_state` stays ABSENT from
    // the §4 registry/projection. SEPARATE from CAPACITY_OPS above: the
    // gate keeps emitting the verdict via report-capacity; THIS channel is
    // display telemetry (§0.C Path B).
    if (MACHINE_STATE_OPS.has(op)) {
      return await handleMachineStateOp(this, op, args, principal);
    }

    // ── CF.2 (claude-tools-7g0.2) §6.1/§6.2/§4.4 LEASE arbitration guard ─────
    // The global exclusive TTL'd lease + the §4.4 monotonic `generation`
    // fencing token, dispatched by its dedicated module so the CF.1 substrate
    // switch below stays byte-identical (its differential vs coordinator.sh +
    // test-coordinator.sh must not regress). NO §4 record type / NO new DDL:
    // `lease` is an ALREADY-registered §4 type living in the existing
    // `records` table (ensureSchema above already DDL'd it), so the grant/
    // renew writes compose on this DO's ONE gated `_writeRecord` path and
    // release is an irrecoverable DELETE. The acquire/renew/release
    // read-decide-write runs on `_serialize` (the AD1 payoff: the singleton
    // single-threaded DO IS the global lease mutex — N concurrent claimants
    // ⇒ EXACTLY ONE winner BY CONSTRUCTION, the BC-04 close). The §9.1
    // chokepoint (the Worker) has ALREADY authenticated + threaded
    // `principal` — no second auth path (C4); a no/invalid-token lease op is
    // rejected 401 at the Worker BEFORE this guard, so it writes NOTHING.
    if (LEASE_OPS.has(op)) {
      return await handleLeaseOp(this, op, args, principal);
    }

    // ── K2 (claude-tools-uxvk2) DESIGN K §3 cross-WS relay_log op guard ──────
    // The append-only cross-workspace relay log + its B.3 tail projection,
    // dispatched by its dedicated module so the CF.1 substrate switch below
    // stays byte-identical. NOT a §4 record / NO §4 DDL: a relay exchange is
    // NOT a §4 record — the module owns its OWN `relay_log` namespace (lazy +
    // idempotent DDL there), so `relay_log` stays ABSENT from the §4
    // registry/projection (the forensic_audit / capacity_reports "append-only,
    // not a §4 record" precedent — Contract A.2). The §9.1 chokepoint (the
    // Worker) has ALREADY authenticated + threaded `principal` — no second
    // auth path (C4); a no/invalid-token relay op is rejected 401 at the
    // Worker BEFORE this guard, so it writes NOTHING.
    if (RELAY_OPS.has(op)) {
      return await handleRelayOp(this, op, args, principal);
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
        case "intake-pending":
          // I3 (claude-tools-06i) — daemon scan of unprocessed intake-request
          // records. Hard-coded type + processed=false filter (cannot be
          // turned into a generic listing surface).
          return await this.opIntakePending();
        default:
          return json(
            {
              error:
                "co: unknown op (substrate §2 surfaces: put|get|set-desired|poll|timer-arm|timer-due|timer-ack|capabilities|intake-pending)",
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
    // claude-tools-4xe — the §5.1-core conformance gate, now on the RIGHT
    // boundary: the engine's ONE dossier write path. Was render-side only, so
    // the engine ACCEPTED bodies the Inbox could never render (agent got a
    // false-success put; human hit a wall). Every dossier write — dossier-put,
    // generic put, internal re-put — composes through _writeRecord, so this is
    // the single chokepoint. The §5.2.2 opaque reconcile-pointer is the ONE
    // contract-defined exemption (handled inside dossierWriteBodyOk).
    if (type === "dossier") {
      const bv = dossierWriteBodyOk(obj && obj.body);
      if (!bv.ok) return { ok: false, code: "non_conformant_body", msg: bv.msg };
    }
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

  // I3 (claude-tools-06i) — list unprocessed intake-request records as a JSON
  // array, ordered lexicographically by id (which is timestamp-prefixed, so
  // this is FIFO across phone taps). NARROW by construction: hard-coded type
  // `intake-request` + hard-coded `processed=false` filter — cannot be turned
  // into a generic listing surface. A record whose `processed` flag is missing
  // or non-boolean is treated as ALREADY PROCESSED (conservative: better to
  // leak one stuck record than re-dispatch every malformed record forever).
  async opIntakePending() {
    const rows = await this.db
      .prepare("SELECT json FROM records WHERE type = ? ORDER BY id ASC")
      .bind("intake-request")
      .all();
    const out = [];
    const list = (rows && rows.results) || [];
    for (const row of list) {
      try {
        const r = JSON.parse(row.json);
        if (r && typeof r === "object" && r.processed === false) out.push(r);
      } catch {
        // skip corrupt row
      }
    }
    return text(JSON.stringify(out));
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

  // §2.2 setAlarm() callback — CF.1 left this a no-op MARKER explicitly for
  // CF.7. CF.7 wires fire(dossier_id) here: it fires every DUE timed-fyi
  // dossier through the SAME shared auto-proceed handler the S-6 timer-due
  // poll-fallback runs, so alarm-fire vs poll-fallback applies each item's
  // consequence EXACTLY ONCE via CF.6's §7.4 per-Item latch. Correctness does
  // NOT depend on this firing (the alarm is best-effort BY CONTRACT — the
  // deterministic backstop is the timer-due poll-fallback, S-6). The lazy
  // idempotent DDL is ensured here too (fetch() is not the entrypoint on this
  // path — the runtime invokes the DO directly, with no request/principal;
  // alarmFire resolves the §0.5 v1 principal internally, keeping this
  // substrate free of a PRINCIPAL_V1 import / second auth path — C4).
  async alarm() {
    await this.ensureSchema();
    await this._ensureDossierSchema();
    await alarmFire(this);
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
