// CF.2 (claude-tools-7g0.2) — DIFFERENTIAL conformance test.
//
// Mirrors lib/test-coordinator-lease.sh EXIT-1..4 + the §9.1/anti-drift block
// clause-for-clause, PLUS the conformance/assertions/bc-ad2-lease-posture.sh
// AD2.1/AD2.2 §6.1/§6.2 OUTCOME — asserted against the REAL CF engine
// (Worker → §9.1 chokepoint → singleton single-threaded Coordinator DO → D1)
// under the SAME workerd+miniflare runtime `wrangler dev` uses, with NO
// Cloudflare account. One linear flow (the bash script is linear;
// per-file isolatedStorage gives this single test the bash test's
// fresh-mktemp-store analogue). The CF engine MUST exhibit the SAME
// INTERFACE.md v1 §6.1/§6.2/§4.4 behaviour as coordinator.sh asserts.
//
// EXIT-3's "bc-ad2-lease-posture.sh run against the CF engine" is realized
// HERE as this differential spec asserting the SAME AD2.1/AD2.2 §6.1/§6.2
// OUTCOME against the real CF engine (the CF.1/CF.3/CF.8 differential
// precedent — the literal conformance harness re-pointing at the CF engine is
// CF.11's stated integration scope; the gate BEHAVIOUR is provided here, and
// the bash baseline stays GATE-MET, untouched).
//
// `env` (the D1 binding the singleton DO writes through) is used ONLY to
// drive the §0.5 LEASE_TTL knob (the bash test's `export LEASE_TTL=1`
// analogue) and to count rows for the "wrote NOTHING" invariants — EXACTLY
// mirroring the bash test setting env + reading the store directly. No
// non-contract debug surface is added to the engine.

import { env, SELF } from "cloudflare:test";
import { it, expect } from "vitest";
import { leaseAcquireDegradedClosed } from "../src/lease.js";
import { askCapacityFailOpen } from "../src/capacity.js"; // EXIT-4 posture contrast
import { schemaVersion } from "../src/schema.js"; // 'lease' §4 registry parity

const GOOD = "bearer-runner-secret-xyz"; // a present, valid v1 bearer

let PASS = 0;
let FAIL = 0;
const fails = [];
function ck(name, cond) {
  if (cond) {
    PASS++;
    // eslint-disable-next-line no-console
    console.log(`  ✓ ${name}`);
  } else {
    FAIL++;
    fails.push(name);
    // eslint-disable-next-line no-console
    console.log(`  ✗ ${name}`);
  }
}

function authReq(bearer, op, args) {
  const headers = { "content-type": "application/json" };
  if (bearer !== null) headers["authorization"] = `Bearer ${bearer}`;
  return new Request("https://coordinator.local/", {
    method: "POST",
    headers,
    body: JSON.stringify({ op, args: args || [] }),
  });
}
async function call(bearer, op, args) {
  const res = await SELF.fetch(authReq(bearer, op, args));
  const ct = res.headers.get("content-type") || "";
  const raw = await res.text();
  let body = null;
  if (ct.includes("application/json")) {
    try {
      body = JSON.parse(raw);
    } catch {
      body = null;
    }
  }
  return { status: res.status, raw, body };
}

// The raw stored §4.4 Lease record exactly the way `co_request GOOD get lease
// <task>` does (the get op echoes the stored JSON, or 404 = absent ⇒ free).
async function getLease(task) {
  const r = await call(GOOD, "get", ["lease", task]);
  if (r.status !== 200) return null;
  try {
    return JSON.parse(r.raw);
  } catch {
    return null;
  }
}
const acquire = (bearer, task, owner) => call(bearer, "lease-acquire", [task, owner]);
const renew = (bearer, task, owner, gen) => call(bearer, "lease-renew", [task, owner, String(gen)]);
const release = (bearer, task, owner, gen) =>
  call(bearer, "lease-release", [task, owner, String(gen)]);
// granted/renewed ⇒ 200 {ok:true,lease}; a denial ⇒ non-2xx {ok:false}
// (the bash rc 0 stdout-record vs nonzero stderr-marker analogue).
const granted = (r) => r.status === 200 && r.body && r.body.ok === true;
const denied = (r) => r.status >= 400 && r.body && r.body.ok === false;

// The §6.2 posture through the REAL exported wrapper (the bash co_lease_acquire
// analogue — runner-side decision logic, NOT a DO op). `reach` undefined or
// "reachable" ⇒ arbitrate through the front door; only "unreachable"
// short-circuits — and MUST NOT call `ask` (no front door when unreachable).
async function coLeaseAcquire(reach, bearer, task, owner) {
  return leaseAcquireDegradedClosed(reach, () => acquire(bearer, task, owner));
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

it("CF.2 §6.1/§6.2/§4.4 lease arbitration is behaviour-identical to lib/coordinator.sh lease ops + test-coordinator-lease.sh + bc-ad2-lease-posture.sh", async () => {
  // ── EXIT-1: BC-04 RACE — N concurrent claims ⇒ EXACTLY ONE winner ─────────
  // 5 owners claim raceT concurrently. The singleton single-threaded
  // Coordinator DO + the _serialize critical section make this resolve to
  // EXACTLY ONE winner BY CONSTRUCTION (the AD1 payoff replacing the bash
  // co__with_lock "lease.<task>" hand-rolled latch — the BC-04 close).
  const owners = ["ownerA", "ownerB", "ownerC", "ownerD", "ownerE"];
  const results = await Promise.all(owners.map((o) => acquire(GOOD, "raceT", o)));
  const grants = results.filter(granted);
  const denies = results.filter(denied);
  ck("exactly ONE concurrent claimant acquired the lease (BC-04)", grants.length === 1);
  ck("every other concurrent claimant was DENIED (4 of 5)", denies.length === 4);
  const rWinner = grants.length === 1 ? grants[0].body.lease.owner : "<none>";
  const stored = await getLease("raceT");
  ck("the stored lease owner is the sole winner", !!stored && stored.owner === rWinner);
  ck("winner's record carries generation 1 (first grant)", !!stored && stored.generation === 1);
  ck("denied claimant carries the BC-04 observable marker", denies.every((d) => /denied-held-by-other/.test(d.body.error || "")));

  // ── EXIT-1: §4.4 GENERATION fencing — stale generation REJECTED ──────────
  let a = await acquire(GOOD, "fenceT", "runnerA");
  ck("first acquire ⇒ generation 1", granted(a) && a.body.lease.generation === 1);
  // SAME owner re-acquires its still-valid lease ⇒ generation STRICTLY bumps
  // (isolates the fencing TOKEN from the owner string — bash gen 1→2).
  a = await acquire(GOOD, "fenceT", "runnerA");
  ck("same-owner re-acquire ⇒ generation strictly monotonic (1→2)", granted(a) && a.body.lease.generation === 2);
  // A renew/release carrying the STALE gen 1 is REJECTED even though the
  // owner matches — proving `generation`, not just owner, is the fence (§4.4).
  ck("renew with STALE generation 1 ⇒ REJECTED (owner matches)", denied(await renew(GOOD, "fenceT", "runnerA", 1)));
  ck("release with STALE generation 1 ⇒ REJECTED", denied(await release(GOOD, "fenceT", "runnerA", 1)));
  ck("lease still HELD after the stale renew/release (not destroyed)", (await getLease("fenceT")) !== null);
  ck("renew with CURRENT generation 2 ⇒ accepted", granted(await renew(GOOD, "fenceT", "runnerA", 2)));
  ck("release with CURRENT generation 2 ⇒ accepted", (await release(GOOD, "fenceT", "runnerA", 2)).status === 200);
  ck("release ⇒ exclusivity relinquished (record gone — binds ⇒open)", (await getLease("fenceT")) === null);

  // ── EXIT-2: §6.1 binding, the §4.4 record shape & precedence ─────────────
  const arec = await acquire(GOOD, "bindT", "runner7");
  const L = granted(arec) ? arec.body.lease : {};
  ck("acquire returns the §4.4 record (task_ref)", L.task_ref === "bindT");
  ck("owner captured", L.owner === "runner7");
  ck("schema_version is integer 1 (§4.4)", L.schema_version === 1);
  ck("ttl_seconds == LEASE_TTL default (900, §0.5)", L.ttl_seconds === 900);
  ck("expires_at present (RFC-3339 …Z, §0.4)", typeof L.expires_at === "string" && /Z$/.test(L.expires_at));
  ck("§9.1 principal STAMPED (brian), not a literal", L.principal === "brian");
  // The lease is consulted on EVERY pickup: a 2nd DIFFERENT owner is denied
  // while it is held (lease authoritative for EXCLUSIVITY — precedence).
  ck("2nd different owner DENIED while held (every-pickup consult)", denied(await acquire(GOOD, "bindT", "runner9")));
  ck("the holder is unchanged after the denied claim", (await getLease("bindT")).owner === "runner7");
  // Idempotent + correctness edges.
  ck("release of an ABSENT lease ⇒ idempotent success", (await release(GOOD, "neverT", "runnerX", 1)).status === 200);
  ck("renew with NO lease ⇒ REJECTED", denied(await renew(GOOD, "neverT", "runnerX", 1)));
  ck("release by a NON-owner ⇒ REJECTED", denied(await release(GOOD, "bindT", "intruder", 1)));
  ck("the held lease survived the non-owner release attempt", (await getLease("bindT")).owner === "runner7");

  // ── EXIT-3: ORPHAN RECOVERY = an EXPIRED lease (no bash snapshot) ─────────
  // The bash test's `export LEASE_TTL=1; ... sleep 2` analogue. Epoch-second
  // granularity ⇒ wait > 1s past the floor (2200ms guarantees expiry).
  env.LEASE_TTL = "1";
  const oa = await acquire(GOOD, "orphanT", "crashedRunner");
  ck("crashed owner holds the lease (gen 1)", granted(oa) && oa.body.lease.generation === 1);
  await wait(2200); // the lease (TTL=1s) is now EXPIRED — orphan recovery is due
  const nrec = await acquire(GOOD, "orphanT", "freshRunner");
  ck("expired lease re-acquired by a NEW owner (orphan recovery)", granted(nrec) && nrec.body.lease.owner === "freshRunner");
  ck("generation strictly monotonic across takeover (1→2)", granted(nrec) && nrec.body.lease.generation === 2);
  // THE residual close: the zombie crashedRunner (still thinks it holds gen1)
  // can renew/release NOTHING — the new owner's lease is fenced.
  ck("zombie's stale-generation renew ⇒ REJECTED (BC-04 residual close)", denied(await renew(GOOD, "orphanT", "crashedRunner", 1)));
  ck("zombie's stale-generation release ⇒ REJECTED", denied(await release(GOOD, "orphanT", "crashedRunner", 1)));
  ck("the new owner's lease survives the zombie (still freshRunner)", (await getLease("orphanT")).owner === "freshRunner");
  delete env.LEASE_TTL; // restore the §0.5 default (900) for the rest

  // ── EXIT-4: §6.2 AD2.2 LEASE half — DEGRADED-CLOSED (mirror of capacity) ──
  // reachable ⇒ arbitrated through the ONE §2.3/§9.1 front door (granted).
  let v = await coLeaseAcquire("reachable", GOOD, "reachT", "runnerR");
  ck("reachable ⇒ arbitrated through the front door (granted)", v.status === 200 && v.body && v.body.ok === true);
  ck("reachable grant persisted", (await getLease("reachT")) !== null && (await getLease("reachT")).owner === "runnerR");
  // unreachable ⇒ DEGRADED-CLOSED: deny, and MUST NOT contact the engine (no
  // front door when unreachable). A spy proves `ask` is never invoked — the
  // posture IS deny (the bounded held-lease continuation is the Local Agent's
  // T3 fallback, NOT decided here — anti-drift §6.2 local = T3).
  let asked = false;
  const spyAsk = async () => {
    asked = true;
    return await acquire(GOOD, "unreachT", "runnerU");
  };
  v = await leaseAcquireDegradedClosed("unreachable", spyAsk);
  ck("co_lease_acquire unreachable ⇒ nonzero (DEGRADED-CLOSED)", v.ok === false && v.rc !== 0);
  ck("unreachable denial is observable (denied-unreachable)", /denied-unreachable/.test(v.error || ""));
  ck("unreachable ⇒ the engine is NEVER consulted (the posture IS deny)", asked === false);
  ck("unreachable ⇒ NO lease record was written (no new claim)", (await getLease("unreachT")) === null);
  // The posture IS deny — even an empty/null bearer denies (no Coordinator to
  // authenticate against when unreachable; no front door is consulted).
  v = await coLeaseAcquire("unreachable", "", "unreachT2", "runnerU");
  ck("unreachable + no bearer ⇒ still denied (no auth when unreachable)", v.ok === false && v.rc !== 0);
  v = await coLeaseAcquire("unreachable", null, "unreachT3", "runnerU");
  ck("unreachable + null bearer ⇒ still denied", v.ok === false && v.rc !== 0);
  ck("unreachable bearer-less attempts wrote NOTHING", (await getLease("unreachT2")) === null && (await getLease("unreachT3")) === null);
  // default reach ⇒ reachable (a runner that does NOT pass the flag arbitrates).
  v = await coLeaseAcquire(undefined, GOOD, "dfltReachT", "runnerD");
  ck("default reach=reachable (arbitrated ⇒ granted)", v.status === 200 && v.body && v.body.ok === true);
  // Same SHAPE, OPPOSITE posture: the CAPACITY half fails OPEN where the LEASE
  // half fails CLOSED — §6.2 freezes BOTH so neither is left to implementation.
  let capAsked = false;
  const cap = await askCapacityFailOpen("unreachable", async () => {
    capAsked = true;
    return { verdict: "over", rc: 1 };
  });
  const lease = await leaseAcquireDegradedClosed("unreachable", async () => ({ ok: true, rc: 0 }));
  ck("co_ask_capacity unreachable ⇒ ok rc 0 (capacity fails OPEN — contrast)", cap.verdict === "ok" && cap.rc === 0 && capAsked === false);
  ck("capacity-half rc 0 vs lease-half rc≠0 (deliberately opposite)", cap.rc === 0 && lease.rc !== 0);

  // ── §9.1 chokepoint + store-owner input hygiene + anti-drift ─────────────
  // no/invalid token ⇒ rejected 401 at the Worker BEFORE any §4 write (one
  // chokepoint; the DO is never contacted on the rejected path).
  ck("no-token lease-acquire ⇒ REJECTED (§9.1)", (await acquire(null, "authT", "runnerZ")).status === 401);
  ck("no-token lease-acquire ⇒ ZERO lease written (before-any-write)", (await getLease("authT")) === null);
  env.CO_EXPECTED_TOKEN = "expected";
  ck("invalid-token lease-acquire ⇒ REJECTED", (await acquire("wrong", "authT2", "runnerZ")).status === 401);
  delete env.CO_EXPECTED_TOKEN;
  ck("invalid-token lease-acquire ⇒ still ZERO lease written", (await getLease("authT2")) === null);
  // store-owner input hygiene — the SAME co__safe_key the §4 store uses.
  ck("unsafe task_ref ('../evil') ⇒ rejected at the door", denied(await acquire(GOOD, "../evil", "o")));
  ck("unsafe task_ref ('..') ⇒ rejected at the door", denied(await acquire(GOOD, "..", "o")));
  ck("no stray lease record escaped for the unsafe key", (await getLease("evil")) === null);
  const cntRej = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM records WHERE type='lease' AND id IN ('authT','authT2','../evil','..','evil')"
  ).first();
  ck("rejected lease writes left ZERO rows in the §4 store", cntRej && cntRej.n === 0);
  // CF.1 co_capabilities UNTOUCHED — lease-* is NOT a fifth §2 capability.
  const caps = await call(GOOD, "capabilities", []);
  ck("co_capabilities (CF.1) still EXACTLY four §2 lines", (caps.raw.match(/§2/g) || []).length === 4);
  ck("lease-* is NOT advertised as a §2 capability", !caps.raw.includes("lease-acquire"));
  // 'lease' IS a §4 record type schema_version 1 (the registry — co__schema_version parity).
  ck("'lease' is a §4 record type, schema_version 1 (registry intact)", schemaVersion("lease") === 1);
  // Anti-drift: CF.1 opPoll stays the pure liveness-free TRANSPORT — it
  // SURFACES a stored lease verbatim and arbitrates/fences NOTHING (even an
  // EXPIRED one); only acquire does orphan recovery.
  env.LEASE_TTL = "1";
  await acquire(GOOD, "pollT", "pollOwner");
  await wait(2200); // pollT's lease is now EXPIRED — transport must NOT fence it
  const pj = await call(GOOD, "poll", ["pollT", "pollT"]);
  ck("co__poll SURFACES the stored lease verbatim (transport)", pj.body && pj.body.lease && pj.body.lease.owner === "pollOwner");
  ck("co__poll did NOT expire/orphan-recover it (no arbitration)", pj.body && pj.body.lease && pj.body.lease.generation === 1);
  ck("co__poll output carries NO 'liveness' (CF.3 boundary intact)", pj.body && !("liveness" in pj.body));
  delete env.LEASE_TTL;

  // ── bc-ad2-lease-posture.sh §6.1/§6.2 AD2.1/AD2.2 OUTCOME (vs the engine) ──
  // AD2.1 §6.1: a lease acquire is observable and a lease release is paired
  // — the acquire-BEFORE-`bd --status=in_progress` ORDERING is the runner's
  // §6.1 WORK-PLANE wiring (run-beads-tasks.sh; bash baseline GATE-MET, the
  // literal harness re-point is CF.11's integration scope). THIS tier owns
  // the EXCLUSIVITY decision the binding rests on; the engine PROVIDES the
  // acquire→release primitives §6.1 orders.
  const ad21 = await acquire(GOOD, "ad21T", "runnerOrder");
  ck("AD2.1: a lease acquire is observable (gates the §6.1 acquire-before-in_progress order)", granted(ad21));
  ck("AD2.1: lease release pairs it (binds release⇒open at the work plane)", (await release(GOOD, "ad21T", "runnerOrder", ad21.body.lease.generation)).status === 200 && (await getLease("ad21T")) === null);
  // AD2.2 §6.2: Coordinator-unreachable + NO held lease ⇒ MUST NOT claim a
  // NEW task (the highest-blast-radius invariant: no new unsynchronised claim
  // ⇒ no BC-04 regression). The "held still-valid lease MAY continue" bounded
  // local fallback is the Local Agent's (T3 la_lease_fallback_allows) — this
  // tier OWNS the arbitration the fallback CONSUMES, it does NOT implement it
  // (so the wrapper DENIES a NEW claim; that IS "must not claim without a
  // fresh lease"). T3's cached-lease continuation is exercised by the
  // conformance `lease` fake-bin shim on the bash runner path (GATE-MET on
  // the baseline, deliberately untouched here — EXIT-4 "bash unaffected").
  let ad22Asked = false;
  const ad22 = await leaseAcquireDegradedClosed("unreachable", async () => {
    ad22Asked = true;
    return await acquire(GOOD, "ad22T", "runnerNoLease");
  });
  ck("AD2.2: unreachable + no held lease ⇒ a NEW lease is DENIED (denied-unreachable)", ad22.ok === false && /denied-unreachable/.test(ad22.error || ""));
  ck("AD2.2: the unclaimed task was NEVER driven (no fresh lease ⇒ no NEW claim)", ad22Asked === false && (await getLease("ad22T")) === null);

  expect(FAIL, `differential clauses failed: ${fails.join("; ")}`).toBe(0);
});
