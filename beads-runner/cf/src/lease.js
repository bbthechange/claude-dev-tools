// CF.2 (claude-tools-7g0.2) — the §6.1 / §6.2 / §4.4 global exclusive TTL'd
// LEASE arbitration + the §4.4 monotonic `generation` fencing token + the
// AD2.2 LEASE-half DEGRADED-CLOSED unreachable posture, realized on the CF.1
// substrate.
//
// This is the Cloudflare realization of the bash:
//   lib/coordinator.sh  co__LEASE_TTL / co__epoch_now / co__epoch_to_rfc3339 /
//                        co__lease_acquire_locked / co__lease_renew_locked /
//                        co__lease_release_locked / co__lease_acquire /
//                        co__lease_renew / co__lease_release / co_lease_acquire
//                        (T4.2, claude-tools-am8; lines ~1294-1579)
// and is differential-bound to lib/test-coordinator-lease.sh +
// conformance/assertions/bc-ad2-lease-posture.sh (the AD2.1/AD2.2 forward
// GATE). The CF engine MUST exhibit the SAME INTERFACE.md v1 §6.1/§6.2/§4.4
// (+ §0.5 LEASE_TTL) behaviour as the bash impl + those tests — not a re-spec.
//
// WHY (the honest rationale, kept verbatim from the oracle): BC-04
// (two-runners-one-orphan) is closed ONLY by consulting an authoritative
// exclusive lease on EVERY pickup. The §4.4 monotonic `generation` is the
// fencing token that closes the BC-04 RESIDUAL: a zombie runner whose lease
// expired and was taken over (generation bumped) can no longer renew/release
// the lease the NEW owner now holds. The §6.2 unreachable posture is the
// highest-blast-radius clause and is FROZEN, not left to implementation: the
// lease plane fails DEGRADED-CLOSED (no fresh lease ⇒ no new unsynchronised
// claim ⇒ no BC-04 regression), the EXACT mirror but DELIBERATELY OPPOSITE
// posture of CF.4's capacity half, which fails OPEN.
//
// THE AD1 PAYOFF (the whole point of this tier): the bash impl performs the
// acquire/renew/release as a read-decide-write CRITICAL SECTION taken under
// ONE co__with_lock "lease.<task_ref>" (a hand-rolled §2.1 single-writer-
// per-key advisory latch) — that lock is exactly what makes the BC-04
// concurrent-claim race resolvable to EXACTLY ONE winner. Here there is NO
// hand-rolled latch: the singleton single-threaded Coordinator DO IS the
// global lease mutex. The read-decide-write runs as ONE serialized critical
// section on `co._serialize` (coordinator.js — the SAME tail CF.4/CF.5/CF.6/
// CF.9 chain on), so N concurrent claimants are processed one at a time and
// exactly one wins BY CONSTRUCTION (the substrate-handoff rule: the runtime
// IS the critical section — AD1; "lease single-writer by construction" is the
// stated AD1 win this tier exists to demonstrate).
//
// LEASE IS A §4 RECORD (do NOT get this wrong): `lease` is in the schema.js
// §4 registry at schema_version 1 — it lives in the SAME `records` table as
// the other §4 types (NOT a sibling namespace like capacity_reports /
// stuck_* / forensic_*). So the GRANT and RENEW writes compose on CF.1's ONE
// gated §4 write path `co._writeRecord` (the §0.3 / safe-key / §4 gate then
// the §9.1 RESOLVED-principal stamp — exactly the bash "build the record
// Coordinator-AUTHORED with schema_version:1 + §9.1 principal stamped, then
// co__store_write"). It is deliberately NOT a second raw INSERT that skips
// the gate/stamp (the substrate-handoff invariant: EVERY §4 write composes on
// _writeRecord). RELEASE is an IRRECOVERABLE record removal — a DELETE, NOT a
// tombstone (the bash `rm -f`, mirroring §10.3 destroy): the next acquirer
// sees a free slot. The bash avoids co__store_put for the WRITE only because
// co__store_put would RE-TAKE the same co__with_lock key (self-contention) —
// a hand-rolled-lock artefact that does NOT exist here (_writeRecord takes no
// lock and does not call _serialize), so composing the write on the ONE gated
// path is the correct, faithful, lock-free realization.
//
// §6.1 PRECEDENCE & EVERY-PICKUP CONSULT: the lease is consulted on EVERY
// pickup (acquire IS the chokepoint). The runner acquires it BEFORE
// `bd update --status=in_progress`; lease release OR expiry maps the bead
// back to --status=open — that WORK-PLANE binding is the runner's (the
// §6.1 wiring), THIS tier owns the EXCLUSIVITY decision the binding rests on.
// ORPHAN RECOVERY = an EXPIRED lease (REPLACES the bash startup-snapshot
// mechanism — intent kept, bash mechanism gone, SCAFFOLDING): a lease whose
// expiry has passed is FREE; the next acquirer takes it, so a crashed
// runner's lease self-heals after LEASE_TTL.
//
// MUST-NOT-TOUCH (bound by the CF.2 issue): the substrate store/timer/
// chokepoint (CF.1 — opPoll stays the pure liveness-free TRANSPORT that
// merely SURFACES a stored lease and arbitrates/fences NOTHING; unchanged
// here), reconcile/projection/liveness (CF.3 — only READS a Lease to surface
// it), capacity aggregation (CF.4), forensic (CF.5), Dossier/timer/
// Notification (CF.6/CF.7/CF.9). The §6.2 BOUNDED LOCAL FALLBACK ("continue
// ONLY a task whose still-valid lease the runner ALREADY holds") is the Local
// Agent's (T3 la_lease_fallback_allows) — this tier OWNS the arbitration
// contract that fallback CONSUMES, it does NOT implement the fallback (so the
// unreachable wrapper here simply DENIES; it never consults a cache). §7.6
// BC-38 (the RUNNER worker-prompt guardrail) is NOT a CF engine surface and
// is NOT touched here.
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §6.1/§6.2/§4.4 + §0.5 LEASE_TTL.
// Oracle = coordinator.sh lease ops + test-coordinator-lease.sh +
// bc-ad2-lease-posture.sh. An INTERFACE gap ⇒ reopen claude-tools-65z,
// bump+re-freeze — NEVER diverge, NEVER edit INTERFACE.md. (No gap: §6.1/
// §6.2/§4.4 is a complete, self-consistent exclusive-lease + fencing +
// split-posture contract; `lease` is deliberately a §4 record at v1.)

// safeKey is CF.1's ONE store-owner input-hygiene predicate (schema.js).
// Reuse it (never a duplicated predicate that could drift) — the bash oracle
// gates every lease task_ref through the SAME co__safe_key the §4 store uses
// (test-coordinator-lease.sh asserts the same '../evil' and '..' rejection).
import { safeKey } from "./schema.js";

// The CF.2 op surface. Kept OUT of CF.1's CAPABILITIES (anti-drift: the
// differential asserts lease-* is NOT a §2 capability line — the four §2
// lines stay EXACTLY four, exactly as test-coordinator-lease.sh greps
// co_capabilities). These cross the §2.3 authed channel like every other op,
// behind the ONE §9.1 chokepoint (no second auth path — C4): a no/invalid
// token lease-* is rejected 401 at the Worker BEFORE this module, so it
// writes NOTHING (test-coordinator-lease.sh "no-token ⇒ ZERO lease written").
export const LEASE_OPS = new Set([
  "lease-acquire", // co__lease_acquire — §6.1 acquire / orphan recovery / BC-04
  "lease-renew", // co__lease_renew  — §4.4 renew (heartbeat); stale gen ⇒ reject
  "lease-release", // co__lease_release — §6.1 release ⇒ exclusivity relinquished
]);

// ── §0.5 LEASE_TTL — env-overridable, default 900 (s) ───────────────────────
// 1:1 with bash `co__LEASE_TTL() { echo "${LEASE_TTL:-900}"; }`. Single
// normative definition is INTERFACE.md §0.5; this is an env-overridable
// lookup whose literal default EQUALS the frozen table value (900), NEVER a
// competing normative value. LEASE_TTL (900 s) ≫ CONTROL_POLL_INTERVAL +
// expected blip (§6.2/AD2.2), so a brief outage does not strand in-flight
// work yet a crashed runner's lease still expires for orphan recovery. A
// non-positive / non-numeric override falls back to 900 (defensive; the bash
// `:-` keeps any present non-empty value, and the test only ever sets a
// positive integer — LEASE_TTL=1 for the orphan/poll cases).
function leaseTtl(env) {
  const raw = env && env.LEASE_TTL;
  if (raw === undefined || raw === null || String(raw).length === 0) return 900;
  const n = Number(raw);
  return Number.isFinite(n) && Number.isInteger(n) && n > 0 ? n : 900;
}

// ── co__epoch_now — integer UTC epoch seconds ───────────────────────────────
// The load-bearing TTL datum is the integer epoch (acquired/renewed/expires
// _epoch); the rfc3339 fields are the §4.4 human-facing schema surface.
function epochNow() {
  return Math.floor(Date.now() / 1000);
}

// ── co__epoch_to_rfc3339 — render epoch seconds as RFC-3339 UTC `...Z` ───────
// §0.4 trailing-Z. Mirrors the substrate's ISO rendering (drop millis to a
// bare `...Z`). Empty string on a non-finite input (the epoch fields remain
// the load-bearing datum; rfc3339 is the §4.4 human-facing surface).
function epochToRfc3339(e) {
  if (!Number.isFinite(e)) return "";
  try {
    return new Date(e * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  } catch {
    return "";
  }
}

// ── direct §4 `lease` record read (the co__store_get analogue) ──────────────
// A read is NOT gated (mirrors opGet / co__store_get exactly: no record-type
// check, "reachable, just empty" when absent). Tolerates the `records` table
// being absent (a 401-rejected request never reaches the DO, so a spec may
// observe before the lazy DDL ran — the faithful "absent store ⇒ empty" bash
// analogue, the CF.8 precedent). Returns the parsed object or null.
async function readLease(co, task) {
  let row;
  try {
    row = await co.db
      .prepare("SELECT json FROM records WHERE type = 'lease' AND id = ?")
      .bind(task)
      .first();
  } catch {
    return null; // table not created yet ⇒ empty (no lease held)
  }
  if (!row) return null;
  try {
    const o = JSON.parse(row.json);
    return o && typeof o === "object" && !Array.isArray(o) ? o : null;
  } catch {
    return null;
  }
}

// ── §6.1 acquire decision + §4.4 record write — co__lease_acquire_locked ─────
// Runs INSIDE co._serialize (the AD1 critical section). Precedence is
// IDENTICAL to the bash oracle:
//   • An UNEXPIRED lease held by a DIFFERENT owner ⇒ DENY (BC-04: exactly
//     one owner per task_ref; the loser is denied — observable). `now <
//     expires` ⇒ still valid; `now ≥ expires` ⇒ EXPIRED ⇒ orphan recovery,
//     the bead is free to be re-leased (REPLACES the bash startup-snapshot).
//   • FREE / EXPIRED(orphan recovery) / SAME-owner re-acquire ⇒ GRANT. The
//     generation is STRICTLY MONOTONIC: prev+1 ALWAYS (incl. same-owner
//     re-acquire), so any party still holding gen_prev is fenced on its next
//     renew/release (§4.4 — the BC-04 two-runners-one-orphan residual close).
// The write composes on CF.1's ONE gated §4 path co._writeRecord (the §0.3
// gate + the §9.1 RESOLVED-principal stamp — never the use-site literal, C7).
async function leaseAcquireLocked(co, principal, task, owner) {
  const now = epochNow();
  const ttl = leaseTtl(co.env);
  const prev = await readLease(co, task);
  let genPrev = 0;
  let curOwner = "";
  let expPrev = 0;
  if (prev) {
    const g = Number(prev.generation);
    genPrev = Number.isInteger(g) && g >= 0 ? g : 0;
    curOwner = typeof prev.owner === "string" ? prev.owner : "";
    const e = Number(prev.expires_epoch);
    expPrev = Number.isInteger(e) && e >= 0 ? e : 0;
  }
  // BC-04: an unexpired lease held by a DIFFERENT owner ⇒ DENY (the loser is
  // denied — observable). `now < expires` ⇒ still valid.
  if (curOwner && curOwner !== owner && now < expPrev) {
    return {
      rc: 1,
      error: `co: LEASE acquire ${task} denied-held-by-other (owner=${curOwner}, gen=${genPrev}; BC-04: exactly one owner)`,
    };
  }
  // FREE / EXPIRED(orphan recovery) / SAME-owner re-acquire ⇒ GRANT.
  const gen = genPrev + 1;
  const exp = now + ttl;
  const acqRfc = epochToRfc3339(now);
  const expRfc = epochToRfc3339(exp);
  const rec = {
    task_ref: task,
    schema_version: 1, // §4.4 — the §4 store gate (validateRecord) requires int 1
    owner,
    acquired_at: acqRfc,
    ttl_seconds: ttl,
    expires_at: expRfc,
    renewed_at: acqRfc,
    generation: gen,
    acquired_epoch: now,
    renewed_epoch: now,
    expires_epoch: exp,
  };
  // Compose on the ONE gated §4 write path — §0.3 re-enforced + §9.1 principal
  // stamped THERE (over whatever literal; C7), then the serialised single
  // write. NOT a second raw INSERT (substrate-handoff invariant).
  const w = await co._writeRecord(principal, "lease", task, rec);
  if (!w.ok) return { rc: 4, error: w.msg || "co: lease-acquire — §4 write rejected" };
  // _writeRecord stamped rec.principal in place — echo it so the caller
  // learns its generation + the §9.1 principal (the bash stdout analogue).
  return { rc: 0, lease: rec };
}

// ── §4.4 renew — co__lease_renew_locked ─────────────────────────────────────
// REJECTED (nonzero, no write) iff: no lease to renew; owner mismatch; the
// carried `generation` is STALE (≠ stored — the fencing token); or the lease
// has already EXPIRED (now ≥ expires ⇒ orphan recovery owns it now,
// re-acquire is required). On success bumps renewed_at + expires (now +
// LEASE_TTL), KEEPING owner + generation + acquired_at.
async function leaseRenewLocked(co, principal, task, owner, reqGen) {
  const now = epochNow();
  const ttl = leaseTtl(co.env);
  const prev = await readLease(co, task);
  if (!prev) {
    return { rc: 1, error: `co: LEASE renew ${task} rejected-no-lease` };
  }
  const sOwner = typeof prev.owner === "string" ? prev.owner : "";
  const sgRaw = Number(prev.generation);
  const sGen = Number.isInteger(sgRaw) ? sgRaw : -1;
  const seRaw = Number(prev.expires_epoch);
  const sExp = Number.isInteger(seRaw) && seRaw >= 0 ? seRaw : 0;
  if (sOwner !== owner) {
    return { rc: 1, error: `co: LEASE renew ${task} rejected-owner-mismatch (held by ${sOwner})` };
  }
  // String-compare the carried generation token to the stored one, exactly
  // like the bash `[[ "$req_gen" != "$s_gen" ]]` (so "1" vs 1 is a faithful
  // match — both render identically; a STALE gen is the fence).
  if (String(reqGen) !== String(sGen)) {
    return {
      rc: 1,
      error: `co: LEASE renew ${task} rejected-stale-generation (carried=${reqGen}, current=${sGen}; §4.4 fencing)`,
    };
  }
  if (now >= sExp) {
    return {
      rc: 1,
      error: `co: LEASE renew ${task} rejected-expired (orphan recovery owns it; re-acquire required)`,
    };
  }
  const exp = now + ttl;
  // Keep owner + generation + acquired_at; bump renewed_* + expires_*.
  const rec = {
    ...prev,
    renewed_at: epochToRfc3339(now),
    expires_at: epochToRfc3339(exp),
    renewed_epoch: now,
    expires_epoch: exp,
  };
  // schema_version may be absent on a degraded prior — re-assert v1 so the
  // §4 store gate (validateRecord) passes (the bash record always carries it).
  rec.schema_version = 1;
  const w = await co._writeRecord(principal, "lease", task, rec);
  if (!w.ok) return { rc: 4, error: w.msg || "co: lease-renew — §4 write rejected" };
  return { rc: 0, lease: rec };
}

// ── §6.1 release — co__lease_release_locked ─────────────────────────────────
// §6.1 release ⇒ the bead maps back to --status=open at the WORK plane (that
// transition is the runner's; here we relinquish the EXCLUSIVITY claim).
// IRRECOVERABLE record removal — NOT a tombstone (the bash `rm -f`, mirrors
// §10.3 destroy): the next acquirer sees a free slot. REJECTED iff owner
// mismatch OR a STALE generation (§4.4 fencing: a zombie that lost the lease
// MUST NOT release the lease the new owner now holds). IDEMPOTENT: releasing
// an absent / already-expired-and-gone lease is SUCCESS (expiry already
// mapped it open at the work plane).
async function leaseReleaseLocked(co, task, owner, reqGen) {
  const prev = await readLease(co, task);
  if (!prev) {
    return { rc: 0 }; // nothing held ⇒ release is a no-op (already open)
  }
  const sOwner = typeof prev.owner === "string" ? prev.owner : "";
  const sgRaw = Number(prev.generation);
  const sGen = Number.isInteger(sgRaw) ? sgRaw : -1;
  if (sOwner !== owner) {
    return { rc: 1, error: `co: LEASE release ${task} rejected-owner-mismatch (held by ${sOwner})` };
  }
  if (String(reqGen) !== String(sGen)) {
    return {
      rc: 1,
      error: `co: LEASE release ${task} rejected-stale-generation (carried=${reqGen}, current=${sGen}; §4.4 fencing)`,
    };
  }
  // IRRECOVERABLE removal — NO tombstone (the bash `rm -f "$(co__rec_path
  // lease "$task")"`). The next acquirer sees a free slot.
  await co.db
    .prepare("DELETE FROM records WHERE type = 'lease' AND id = ?")
    .bind(task)
    .run();
  return { rc: 0 };
}

// ── §6.2 / AD2.2 LEASE-half DEGRADED-CLOSED posture — co_lease_acquire ───────
// The §6.2 lease gate as the runner sees it (AD2.2 LEASE half). The EXACT
// mirror of CF.4's askCapacityFailOpen reachable|unreachable shape — but the
// DELIBERATELY OPPOSITE posture (§6.2 freezes BOTH halves so neither is left
// to implementation):
//   unreachable ⇒ DEGRADED-CLOSED: DENY (nonzero) — no Coordinator ⇒ NO fresh
//                 lease. The bounded local fallback (continue ONLY a task
//                 whose still-valid lease the runner ALREADY holds) is the
//                 Local Agent's (T3 la_lease_fallback_allows), NOT decided
//                 here (anti-drift: §6.2 local = T3, MUST-NOT-TOUCH). This is
//                 what keeps a brief outage from reintroducing BC-04 (no new
//                 unsynchronised claim) — the higher-blast-radius plane fails
//                 CLOSED. There is no Coordinator to authenticate against when
//                 it is unreachable, so the posture IS "deny" — `ask` is
//                 NEVER consulted (no front door).
//   reachable   ⇒ arbitrate through the ONE §2.3/§9.1 authed front door:
//                 `ask` performs the real engine call and returns its result.
// (Contrast CF.4's CAPACITY half — askCapacityFailOpen — which fails OPEN:
//  a one-task overshoot is noise, a lower-blast-radius plane.)
// PURE decision logic (no transport): `ask` is supplied by the call site
// (the runner / the differential rig), exactly as bash co_lease_acquire wraps
// `co_request "$bearer" lease-acquire ...` only on the reachable arm and is
// NOT itself routed through co_request / the DO surface.
export async function leaseAcquireDegradedClosed(reach, ask) {
  if (reach === "unreachable") {
    return {
      ok: false,
      rc: 1,
      error:
        "co: LEASE acquire denied-unreachable (§6.2/AD2.2 DEGRADED-CLOSED — no fresh lease; held-lease continuation is the Local Agent's bounded fallback, T3)",
    };
  }
  return await ask();
}

// ── LEASE_OPS dispatch ──────────────────────────────────────────────────────
// acquire/renew/release are a read-decide-write CRITICAL SECTION ⇒ each runs
// INSIDE co._serialize so the singleton single-threaded Coordinator DO
// processes ONE lease critical section at a time (AD1: N concurrent
// claimants ⇒ EXACTLY ONE winner — the BC-04 close, by construction; no
// hand-rolled latch). The §9.1 chokepoint (the Worker, CF.1) has ALREADY
// authenticated + threaded the resolved `principal` — there is NO second
// auth path here (C4).
//
// Response convention (the bash rc + stdout ⇄ HTTP analogue, 1:1 with the
// CF.4/CF.5 sibling precedent):
//   grant/renew (rc 0) ⇒ 200 JSON {ok:true, lease:<§4.4 record>} — the bash
//                         stdout VERBATIM (so the caller learns its
//                         generation + the §9.1 principal).
//   release    (rc 0) ⇒ 200 JSON {ok:true} — exclusivity relinquished
//                         (record gone; incl. the idempotent absent-lease
//                         no-op, the bash `return 0`).
//   denial     (rc 1) ⇒ 409 JSON {ok:false,error:"... <observable marker>"}
//                         — held-by-other / owner-mismatch / stale-generation
//                         / expired-renew / no-lease-renew (the bash nonzero
//                         + stderr marker; NOTHING written).
//   bad arg / unsafe key (rc 2) ⇒ 422 JSON {ok:false,error} (the bash rc-2).
//   §4 write rejected   (rc 4) ⇒ 422 JSON {ok:false,error} (the bash rc-4).
// (The bash rc-3 "could not build the §4.4 record" is a `jq`-build artefact
// with NO analogue here — a JS object literal cannot fail to build — so a
// store-side rejection surfaces as rc 4; both map to 422 and no oracle clause
// exercises rc-3, so the differential is byte-faithful on every reachable rc.)
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleLeaseOp(co, op, args, principal) {
  const a = args || [];

  if (op === "lease-acquire") {
    const task = a[0];
    const owner = a[1];
    if (!task || !owner) {
      return jsonRes({ ok: false, error: "co: lease-acquire needs <task_ref> <owner>" }, 422);
    }
    if (!safeKey(task)) {
      return jsonRes(
        {
          ok: false,
          error: `co: reject — unsafe lease task_ref '${task}' (store-owner input hygiene)`,
        },
        422
      );
    }
    const r = await co._serialize(() => leaseAcquireLocked(co, principal, task, owner));
    if (r.rc === 0) return jsonRes({ ok: true, lease: r.lease }, 200);
    return jsonRes({ ok: false, error: r.error }, r.rc === 1 ? 409 : 422);
  }

  if (op === "lease-renew") {
    const task = a[0];
    const owner = a[1];
    const gen = a[2];
    if (!task || !owner || gen === undefined || gen === null || String(gen).length === 0) {
      return jsonRes({ ok: false, error: "co: lease-renew needs <task_ref> <owner> <generation>" }, 422);
    }
    if (!safeKey(task)) {
      return jsonRes({ ok: false, error: `co: reject — unsafe lease task_ref '${task}'` }, 422);
    }
    const r = await co._serialize(() => leaseRenewLocked(co, principal, task, owner, gen));
    if (r.rc === 0) return jsonRes({ ok: true, lease: r.lease }, 200);
    return jsonRes({ ok: false, error: r.error }, r.rc === 1 ? 409 : 422);
  }

  if (op === "lease-release") {
    const task = a[0];
    const owner = a[1];
    const gen = a[2];
    if (!task || !owner || gen === undefined || gen === null || String(gen).length === 0) {
      return jsonRes({ ok: false, error: "co: lease-release needs <task_ref> <owner> <generation>" }, 422);
    }
    if (!safeKey(task)) {
      return jsonRes({ ok: false, error: `co: reject — unsafe lease task_ref '${task}'` }, 422);
    }
    const r = await co._serialize(() => leaseReleaseLocked(co, task, owner, gen));
    if (r.rc === 0) return jsonRes({ ok: true }, 200);
    return jsonRes({ ok: false, error: r.error }, r.rc === 1 ? 409 : 422);
  }

  return jsonRes({ ok: false, error: `co: unknown lease op '${op}'` }, 400);
}
