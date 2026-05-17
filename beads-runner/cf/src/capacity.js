// CF.4 (claude-tools-7g0.4) — the §6.3 / §6.2 Coordinator-side COARSE
// capacity aggregation + the AD2.2 capacity-half fail-OPEN posture, realized
// on the CF.1 substrate.
//
// This is the Cloudflare realization of the bash:
//   lib/coordinator.sh  co__capacity_* / co__ask_capacity / co_ask_capacity
//                        (T4.4, claude-tools-d7x; lines ~696-927:
//                        capacity_dir / class_ok / path / report / write /
//                        any_over / ask_capacity / co_ask_capacity)
// and is differential-bound to lib/test-coordinator-capacity.sh +
// conformance/assertions/bc-34-usage-fail-open.sh. The CF engine MUST exhibit
// the SAME INTERFACE.md v1 §6.3/§6.2 (+ §0.5 USAGE_THRESHOLD) behaviour as the
// bash impl + those tests — not a re-spec.
//
// WHY (the honest rationale, AD2.3 — kept verbatim from the oracle): the
// Coordinator never reads a Keychain or an Anthropic usage API (§1.1). It
// AGGREGATES the coarse cost-class verdicts the Local Agents (T3) report UP
// (§1.1 item 1; produced by T3's la_report_capacity, consumed here VERBATIM).
// The 5h/7d hard ceiling (BC-34) is the real guard; the 14.2%/day spare line
// is a soft ramp. Both numbers were MEASURED at the Local Agent and are
// already encoded in the reported coarse verdict — this tier AGGREGATES that
// verdict, it does NOT (and MUST NOT) re-measure.
//
// CRITICAL BOUNDARY (the substrate-handoff discipline, kept verbatim): a
// capacity report is a §1.1 UP report, NOT a §4 store record. It lives in a
// SEPARATE `capacity_reports` namespace (the §10.3-forensic / dossier-dedup
// "NOT a §4 record" precedent). It is deliberately NOT routed through CF.1's
// `_writeRecord` / the §4 `records` table / `validateRecord` / `schemaVersion`
// — `capacity` is ABSENT from the schema.js §4 registry and MUST stay absent
// (so `get capacity <id>` is "reachable, just empty" and `put capacity ...`
// is `unknown_type`, structurally proving "never a §4 record / never in the
// §4.5 projection / never in a §4.3 Notification body"). The §6.3 ingest
// re-enforces §0.3 (unknown HIGHER schema_version REJECTED, never best-effort)
// + the §6.3 closed enums EXACTLY as the §4 store does, and §9.1 stamps the
// RESOLVED principal over whatever literal the report carried (C7).
//
// THE AD1 PAYOFF (same as CF.5/CF.6/CF.9): the bash impl performs the
// latest-wins ingest as read-prev-observed_at → compare → write under
// co__with_lock; here that read-modify-write runs as ONE serialized critical
// section on the singleton single-threaded Coordinator DO (`co._serialize`,
// coordinator.js — the SAME tail CF.5/CF.6/CF.9 chain on), so a racing
// straggler can never interleave between the observed_at compare and the
// write. No hand-rolled latch (the substrate-handoff rule: the runtime IS the
// critical section — AD1). ask-capacity is a pure read-only aggregation ⇒ no
// serialize (mirrors forensic-audit / notification's pure-op short-circuit).
//
// §6.2 / AD2.2 POSTURE CONTRAST (do NOT get this backwards): the capacity
// half fails OPEN — Coordinator-unreachable ⇒ PROCEED (verdict `ok`). A
// one-task overshoot is noise; the BC-34 hard-ceiling intent is preserved AT
// THE LOCAL AGENT (T3). This is the EXACT mirror — but the DELIBERATELY
// OPPOSITE posture — of CF.2's LEASE half, which fails DEGRADED-CLOSED (a
// higher-blast-radius plane). §6.2 freezes BOTH halves so neither is left to
// implementation. The fail-OPEN decision is a RUNNER-side control-flow choice
// made BEFORE deciding to contact the Coordinator (an "unreachable" op call
// is a contradiction — there is no front door to POST to). It is exported
// here as the pure `askCapacityFailOpen` decision wrapper (the analogue of
// bash co_ask_capacity, which likewise lives in coordinator.sh next to
// co__ask_capacity but is NOT routed through co_request / the DO surface).
//
// MUST-NOT-TOUCH (bound by the CF.4 issue): substrate store/timer (CF.1),
// lease (CF.2), the §4.5 projection capacity STRIP render (CF.3 — this owns
// the VERDICT, CF.3 renders the strip), forensic (CF.5), Dossier (CF.6). The
// Local-Agent MEASUREMENT side (Keychain / usage poll / 5h-7d numbers /
// spare-ramp math / USAGE_CACHE_SECONDS / SPARE_RAMP_PER_DAY) stays bash
// (§1.1 — not a CF surface). This module defines NO usage-cache / spare-ramp
// LOOKUP and touches NO Keychain / usage API — it AGGREGATES, it never
// measures (the run-differential.sh source-discipline gate proves this by
// structure, the bash test-coordinator-capacity.sh EXIT-4 analogue).
//
// ANTI-DRIFT: binds FROZEN INTERFACE.md v1 §6.3/§6.2 + §0.5 USAGE_THRESHOLD.
// Oracle = coordinator.sh co__capacity_* / co__ask_capacity / co_ask_capacity
// + test-coordinator-capacity.sh + bc-34-usage-fail-open.sh. An INTERFACE gap
// ⇒ reopen claude-tools-65z, bump+re-freeze — NEVER diverge, NEVER edit
// INTERFACE.md. (No gap: §6.3/§6.2 is a complete, self-consistent coarse-
// aggregation + fail-open contract; `capacity` is deliberately NOT a §4 type.)

// safeKey is CF.1's ONE store-owner input-hygiene predicate (schema.js). Reuse
// it (never a duplicated predicate that could drift) — the bash oracle gates
// every capacity report runner_id through the SAME co__safe_key the §4 store
// uses (test-coordinator-capacity.sh asserts the same '..'/'/' rejection).
import { safeKey } from "./schema.js";

// The CF.4 op surface. Kept OUT of CF.1's CAPABILITIES (anti-drift: the
// differential asserts capacity is NOT a §2 capability line — the four §2
// lines stay EXACTLY four, exactly as test-coordinator-capacity.sh greps
// co_capabilities). These cross the §2.3 authed channel like every other op,
// behind the ONE §9.1 chokepoint (no second auth path — C4).
export const CAPACITY_OPS = new Set([
  "report-capacity", // co__capacity_report — §1.1 ingest the upward coarse report
  "ask-capacity", // co__ask_capacity — §6.3 aggregated verdict ok|over
]);

// ── §0.5 USAGE_THRESHOLD — env-overridable, default 70; an integer 0 disables
// 1:1 with bash `co__USAGE_THRESHOLD() { echo "${USAGE_THRESHOLD:-70}"; }`
// (`:-` keeps a present non-empty value, so an explicit "0" is honoured — the
// gate-disable arm EXIT-2 exercises). Single normative definition is
// INTERFACE.md §0.5; this is an env-overridable lookup whose literal default
// EQUALS the frozen table value, never a competing normative value. The
// disable test is the bash one VERBATIM: the value must be an all-digits
// integer string AND numerically 0 (`[[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -eq 0
// ]]`) — a non-numeric value leaves the gate ENABLED, exactly like bash.
function usageThresholdDisabled(env) {
  const raw = env && env.USAGE_THRESHOLD;
  const t = raw === undefined || raw === null || String(raw).length === 0 ? "70" : String(raw);
  return /^[0-9]+$/.test(t) && Number(t) === 0;
}

// ── lazy + idempotent DDL — the SEPARATE §1.1-report namespace ──────────────
// Mirrors CF.1's `ensureSchema` discipline (CREATE TABLE IF NOT EXISTS, lazy,
// per-instance memoised) so CF.4 is locally-runnable with NO account and NO
// manual migrate step. The canonical migration ships in
// migrations/0005_capacity.sql for the a53 deploy path. `capacity_reports` is
// a SEPARATE namespace from `records`/`timers`/`work_plane_ops`/`forensic_*`
// — NOT a §4 record (the §10.3 "not a §4 record" precedent CF.1/CF.5/CF.6
// already document). One row per (cost_class, runner_id) — the cost_class is
// a fixed closed enum, the runner_id the only variable component and
// safeKey-validated at ingest, so no key collision is possible (the bash
// one-file-per-(runner_id,cost_class) shape). `verdict` is a denormalised
// column (extracted at ingest from the verbatim json) ONLY so the aggregation
// query is a clean indexed read — the byte-faithful T3 line is kept in `json`
// for the §9.1 stamp + the latest-wins observed_at compare.
function ensureCapacitySchema(co) {
  if (!co._capacitySchemaReady) {
    co._capacitySchemaReady = co.db
      .prepare(
        "CREATE TABLE IF NOT EXISTS capacity_reports (cost_class TEXT NOT NULL, runner_id TEXT NOT NULL, verdict TEXT NOT NULL, observed_at TEXT, json TEXT NOT NULL, PRIMARY KEY (cost_class, runner_id))"
      )
      .run();
  }
  return co._capacitySchemaReady;
}

// The §6.3 cost_class is a CLOSED enum (INTERFACE.md §6.3): exactly
// {standard, low_priority}. An unknown class is rejected at the door (it is a
// contract value, not free text) — never silently treated as `standard`.
// 1:1 with bash co__capacity_class_ok.
function capacityClassOk(cc) {
  return cc === "standard" || cc === "low_priority";
}

// ── §1.1 INGEST (report-capacity) — co__capacity_report VERBATIM ────────────
// Enforces, in the SAME order as the bash oracle (so a rejection on the
// earlier gate wins identically):
//   1. valid JSON object with report=="capacity";
//   2. §0.3 — integer schema_version bound to v1: a string "1" / float / bool
//      is rejected (the in-jq type check), an unknown HIGHER version is
//      REJECTED (never best-effort-parsed), any other value unsupported;
//   3. §6.3 closed-enum cost_class ∈ {standard,low_priority} and verdict ∈
//      {ok,over}; non-empty safeKey runner_id (the §1.1 stamp / store-owner
//      input hygiene — the SAME co__safe_key the §4 store uses);
//   4. §9.1 — STAMP `principal` with the RESOLVED principal (overwrite
//      whatever the report carried — never trust the use-site literal, C7).
// The LATEST report per (runner_id,cost_class) wins: a stored report with a
// strictly-newer observed_at is NOT clobbered by an older straggler (RFC-3339
// UTC strings sort lexicographically, so a string compare IS the time
// compare; only skip when BOTH observed_at are non-empty AND the new one is
// strictly older — the exact bash condition). Returns { rc:0 } on a write OR
// a kept-newer-stored skip (both bash `return 0`), { rc:3 } on any rejection
// (NOTHING written), { rc:2 } on a missing arg. NOTE (anti-drift): no
// measurement here — it stores the verdict the Local Agent already computed;
// it never derives one.
async function capacityReport(co, principal, jsonStr) {
  if (jsonStr === undefined || jsonStr === null || String(jsonStr).length === 0) {
    return { rc: 2 }; // co: report-capacity needs <report_json>
  }
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    return { rc: 3 }; // not a §1.1 capacity report (invalid JSON)
  }
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    Array.isArray(parsed) ||
    parsed.report !== "capacity"
  ) {
    return { rc: 3 }; // report!="capacity" / not an object — §1.1 reject
  }
  // §0.3 — integer schema_version; unknown HIGHER ⇒ reject, never best-effort.
  const sv = parsed.schema_version;
  const isInt = typeof sv === "number" && Number.isFinite(sv) && Math.floor(sv) === sv;
  if (!isInt) {
    return { rc: 3 }; // missing integer schema_version (§1.1/§0.3)
  }
  if (sv > 1) {
    return { rc: 3 }; // unknown higher version (bound=1; §0.3 reject)
  }
  if (sv !== 1) {
    return { rc: 3 }; // unsupported (binds v1 only; §0.3)
  }
  const cc = parsed.cost_class;
  const vd = parsed.verdict;
  const rid = parsed.runner_id;
  if (!capacityClassOk(cc)) {
    return { rc: 3 }; // cost_class not in {standard,low_priority} (§6.3 closed enum)
  }
  if (vd !== "ok" && vd !== "over") {
    return { rc: 3 }; // verdict not in {ok,over} (§6.3)
  }
  if (typeof rid !== "string" || rid.length === 0 || !safeKey(rid)) {
    return { rc: 3 }; // runner_id missing/unsafe (§1.1 stamp; input hygiene)
  }
  // §9.1 stamp: the RESOLVED principal, overwriting anything the report put.
  parsed.principal = principal;
  const nobs = typeof parsed.observed_at === "string" ? parsed.observed_at : "";
  // Latest-wins: keep the report with the newer observed_at. Only an older
  // straggler (BOTH non-empty AND strictly older) is dropped — the exact bash
  // `[[ -n "$pobs" && -n "$nobs" && "$nobs" < "$pobs" ]]` condition.
  const prev = await co.db
    .prepare("SELECT observed_at FROM capacity_reports WHERE cost_class = ? AND runner_id = ?")
    .bind(cc, rid)
    .first();
  if (prev) {
    const pobs = typeof prev.observed_at === "string" ? prev.observed_at : "";
    if (pobs.length > 0 && nobs.length > 0 && nobs < pobs) {
      return { rc: 0 }; // an older straggler ⇒ keep the newer stored report
    }
  }
  await co.db
    .prepare(
      "INSERT OR REPLACE INTO capacity_reports (cost_class, runner_id, verdict, observed_at, json) VALUES (?, ?, ?, ?, ?)"
    )
    .bind(cc, rid, vd, nobs, JSON.stringify(parsed))
    .run();
  return { rc: 0 };
}

// co__capacity_any_over — true iff ANY current Local-Agent report for
// <cost_class> carries verdict "over". Pure aggregation over the stored
// coarse verdicts (no measurement). The denormalised `verdict` column makes
// this the clean indexed read of the bash per-file `.verdict == "over"` loop.
async function capacityAnyOver(co, cc) {
  const row = await co.db
    .prepare("SELECT 1 AS x FROM capacity_reports WHERE cost_class = ? AND verdict = 'over' LIMIT 1")
    .bind(cc)
    .first();
  return !!row;
}

// ── §6.3 AGGREGATE (ask-capacity <cost_class>) — co__ask_capacity VERBATIM ──
// Returns { verdict:"ok"|"over", rc:0|1 } (the SAME proceed/halt convention as
// the Local Agent's la_capacity_check, so a caller can branch on the rc as
// well as the token), or { reject:true } on a bad enum (the bash rc-2 stderr
// path). The §6.3 rc↔token bijection is TOTAL (ok⟺0, over⟺1) — the dispatch
// returns the bare token as the text/plain body (the bash stdout VERBATIM,
// the forensic-precedent stdout⇄body mapping) and the bijection makes the rc
// recoverable from it, so an HTTP status need not also encode it (`over` is a
// valid verdict — "you must halt" — NOT a transport error; only the bad-enum
// reject maps to a non-2xx, the bash rc-2 analogue).
async function askCapacity(co, cc) {
  // co__ask_capacity's `local cc="${1:-standard}"` VERBATIM: co_request routes
  // this as `co__ask_capacity "${1:-}"`, so a missing/empty cost_class arg
  // defaults to `standard` and gets a REAL aggregated verdict (NOT a reject).
  // `${1:-}` ⇒ "" when absent, and `${1:-standard}` triggers on empty-too ⇒
  // "standard". A present-but-unknown class (e.g. "bulk") is NOT defaulted —
  // it falls through to the closed-enum reject (the bash rc-2), exactly like
  // the oracle. (report-capacity does NOT default — bash validates that
  // cost_class from the JSON body, never from an arg.)
  if (cc === undefined || cc === null || String(cc).length === 0) {
    cc = "standard";
  }
  if (!capacityClassOk(cc)) {
    return { reject: true }; // ask-capacity cost_class not in {standard,low_priority}
  }
  // §6.3 / EXIT-2 — USAGE_THRESHOLD=0 disables the hard ceiling GLOBALLY ⇒
  // capacity is always ok (the same gate-disable the Local Agent applies; NOT
  // a re-measurement — the shared §0.5 constant). When disabled the LA also
  // emits NO reports, so this short-circuit is the consistent global view.
  if (usageThresholdDisabled(co.env)) {
    return { verdict: "ok", rc: 0 };
  }
  // `standard` is gated ONLY by the hard ceiling (aggregated coarse verdict).
  // ANY standard `over` ⇒ over for BOTH classes: a hit hard ceiling on
  // standard means no spare capacity at all, so low_priority (backfill-only)
  // is certainly over — it NEVER starves the weekly cap (the bash falls
  // through to `echo over; return 1` for either cc).
  if (await capacityAnyOver(co, "standard")) {
    return { verdict: "over", rc: 1 };
  }
  // `low_priority` is ADDITIONALLY gated by the spare-cycles line: the LA
  // already encoded the day-N ≤ N×SPARE_RAMP_PER_DAY soft line into this
  // coarse verdict — aggregated here, NEVER re-measured.
  if (cc === "low_priority" && (await capacityAnyOver(co, "low_priority"))) {
    return { verdict: "over", rc: 1 };
  }
  // No report for the class (gate enabled) ⇒ ok: nothing has been reported
  // over; the real guard is the LA's hard ceiling, which WOULD have reported
  // over (AD2.3 honest rationale: the 14.2%/day line is a soft ramp, the
  // 5h/7d ceiling is the real guard).
  return { verdict: "ok", rc: 0 };
}

// ── §6.2 / AD2.2 capacity-half fail-OPEN posture — co_ask_capacity VERBATIM ─
// The §6.2 capacity gate as the runner sees it. The EXACT mirror of
// local-agent.sh's la_lease_fallback_allows reachable|unreachable shape — but
// the DELIBERATELY OPPOSITE posture:
//   unreachable ⇒ FAIL OPEN: verdict "ok", rc 0 (PROCEED). A one-task
//                 overshoot is noise; the BC-34 hard-ceiling intent is
//                 preserved AT THE LOCAL AGENT (T3). There is no Coordinator
//                 to authenticate against when it is unreachable — the
//                 posture IS "proceed", not "ask" (even an empty bearer
//                 proceeds; no front door is consulted).
//   reachable   ⇒ ask through the ONE §2.3/§9.1 authed front door — `ask`
//                 performs the real engine call and returns its
//                 { verdict, rc } (or a reject).
// (Contrast CF.2's LEASE half — la_lease_fallback_allows — which fails
//  DEGRADED-CLOSED: a different, higher-blast-radius plane, a different
//  posture. §6.2 freezes BOTH halves so neither is left to implementation.)
// This is PURE decision logic (no transport): `ask` is supplied by the call
// site (the runner / the differential rig), exactly as bash co_ask_capacity
// wraps `co_request "$bearer" ask-capacity "$cc"` only on the reachable arm.
export async function askCapacityFailOpen(reach, ask) {
  if (reach === "unreachable") {
    return { verdict: "ok", rc: 0 }; // §6.2 / AD2.2 capacity-half fail-OPEN
  }
  return await ask();
}

// ── CAPACITY_OPS dispatch ───────────────────────────────────────────────────
// report-capacity is a latest-wins read-modify-write ⇒ runs INSIDE
// co._serialize so the singleton single-threaded DO processes one ingest
// critical section at a time (AD1: the observed_at compare + the write never
// interleave with a racing straggler for the same key). ask-capacity is a
// pure read-only aggregation ⇒ NO serialize (the forensic-audit /
// notification pure-op short-circuit precedent). The §9.1 chokepoint (the
// Worker, CF.1) has ALREADY authenticated + threaded the resolved `principal`
// — there is NO second auth path here (C4); a no-token / invalid-token
// capacity op is rejected 401 at the Worker BEFORE this module, so it writes
// NOTHING (test-coordinator-capacity.sh EXIT-4 "no-token wrote NOTHING").
//
// Response convention (the bash rc+stdout ⇄ HTTP analogue, 1:1 with CF.5):
//   report-capacity → rc 0 ⇒ text("",200) (bash: rc 0, no stdout — incl. the
//                      kept-newer-stored idempotent skip); a reject ⇒ EMPTY
//                      non-2xx (bash: "empty stdout + nonzero rc", NOTHING
//                      written) — 422 for an arg/contract reject (the rc-2/3
//                      analogue).
//   ask-capacity    → the bare verdict token "ok"|"over" as text/plain 200
//                      (bash stdout VERBATIM; the §6.3 rc↔token bijection
//                      makes the bash rc recoverable — see askCapacity); a
//                      bad-enum reject ⇒ 422 (the bash rc-2 stderr analogue).
function textRes(s, status = 200) {
  return new Response(s, { status, headers: { "content-type": "text/plain" } });
}
function jsonRes(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleCapacityOp(co, op, args, principal) {
  const a = args || [];
  await ensureCapacitySchema(co);

  if (op === "report-capacity") {
    const r = await co._serialize(() => capacityReport(co, principal, a[0]));
    if (r.rc === 0) return textRes("", 200); // rc 0, no stdout (incl. idempotent skip)
    return textRes("", 422); // reject — empty body, NOTHING written (rc 2/3)
  }

  if (op === "ask-capacity") {
    const r = await askCapacity(co, a[0]);
    if (r.reject) return textRes("", 422); // bad enum — the bash rc-2 analogue
    return textRes(r.verdict, 200); // "ok"|"over" — bash stdout VERBATIM
  }

  return jsonRes({ ok: false, error: `co: unknown capacity op '${op}'` }, 400);
}
