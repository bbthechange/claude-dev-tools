// CF.1 (claude-tools-7g0.1) — §0.5 frozen constants + §4 record-type registry
// + §0.3 version binding + store-owner input hygiene.
//
// Differential oracle: lib/coordinator.sh co__PRINCIPAL_V1 / co__schema_version
// / co__safe_key / the §0.3 schema_version gate inside co__store_put, plus
// lib/test-coordinator.sh. This module MUST exhibit the SAME §-clause behavior.
// It binds FROZEN INTERFACE.md v1 §0.3 / §0.5 / §4 — no re-spec.

// ── §0.5 frozen constants ───────────────────────────────────────────────────
// Single normative definition is INTERFACE.md §0.5. This is an env-overridable
// lookup whose literal default EQUALS the frozen table value (PRINCIPAL_V1 =
// "brian"), never a competing normative value. Mirrors coordinator.sh
// co__PRINCIPAL_V1 (`echo "${PRINCIPAL_V1:-brian}"`).
export function PRINCIPAL_V1(env) {
  const v = env && env.PRINCIPAL_V1;
  return v && String(v).length > 0 ? String(v) : "brian";
}

// ── §4 record-type registry & schema versions ───────────────────────────────
// Every §4 record type binds to ONE schema_version (all `1` in INTERFACE.md
// v1). Unknown type => null (rejected at the door). Adding a type or bumping a
// version is the §0/§11 freeze-escalation protocol, never a local edit.
// 1:1 with coordinator.sh co__schema_version.
const SCHEMA_VERSIONS = {
  dossier: 1,        // §4.1 Dossier envelope (body/items producer = CF.6)
  runner_state: 1,   // §4.2 RunnerState
  notification: 1,   // §4.3 Notification (creation/dispatch = CF.9)
  lease: 1,          // §4.4 Lease (arbitration/fencing = CF.2)
  work_snapshot: 1,  // §4.5 work-snapshot (projection producer = CF.3)
};

export function schemaVersion(type) {
  return Object.prototype.hasOwnProperty.call(SCHEMA_VERSIONS, type)
    ? SCHEMA_VERSIONS[type]
    : null;
}

// ── store-owner input hygiene (co__safe_key) ────────────────────────────────
// A record/timer id reaches the store through the §2.3 front door. As the §2.1
// store owner we reject an id that is not a safe key BEFORE building any key:
// non-empty, no ".." segment, only [A-Za-z0-9._-]. (A DO/D1 key has no
// filesystem shape, so this is input hygiene, not a leaked provider concern —
// but it must stay behaviorally identical to the bash oracle, which the
// differential test asserts with the same '/' and '..' cases.)
export function safeKey(k) {
  if (typeof k !== "string" || k.length === 0) return false;
  if (k.includes("..")) return false;
  return /^[A-Za-z0-9._-]+$/.test(k);
}

// ── §0.3 schema_version gate (the co__store_put precedence, verbatim) ────────
// Returns { ok:true } or { ok:false, code, msg }. Enforces, in the SAME order
// as co__store_put:
//   1. known §4 record type;
//   2. safe id;
//   3. §4 `schema_version : int` — must be a JSON *integer number* (a string
//      "1", a float, or a bool is rejected, mirroring the in-jq type check);
//      an unknown HIGHER version is REJECTED (never best-effort-parsed); the
//      substrate knows only v1 so any other value is unsupported => reject.
// It does NOT stamp principal — that is the §9.1 step the DO applies after this
// gate passes (kept as separate concerns exactly like the bash impl).
export function validateRecord(type, id, obj) {
  const bound = schemaVersion(type);
  if (bound === null) {
    return { ok: false, code: "unknown_type", msg: `co: reject — unknown §4 record type '${type}'` };
  }
  if (!safeKey(id)) {
    return {
      ok: false,
      code: "unsafe_id",
      msg: `co: reject — unsafe record id '${id}' (allowed [A-Za-z0-9._-], no '..'; store-owner input hygiene)`,
    };
  }
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
    return { ok: false, code: "not_json_object", msg: `co: reject — ${type} record is not a JSON object` };
  }
  const sv = obj.schema_version;
  // §4 mandates `schema_version : int`. A JSON string "1", a float, or a bool
  // MUST NOT slip past (the bash impl does this type-check inside jq so a bare
  // `"1"` does not flatten to a passing numeric).
  const isInt = typeof sv === "number" && Number.isFinite(sv) && Math.floor(sv) === sv;
  if (!isInt) {
    return {
      ok: false,
      code: "missing_schema_version",
      msg: `co: reject — ${type} record missing integer schema_version (§4 'int' / §0.3)`,
    };
  }
  if (sv > bound) {
    return {
      ok: false,
      code: "higher_version",
      msg: `co: reject — ${type} schema_version ${sv} is an unknown higher version (bound=${bound}; §0.3 reject, never best-effort-parse)`,
    };
  }
  if (sv !== bound) {
    return {
      ok: false,
      code: "unsupported_version",
      msg: `co: reject — ${type} schema_version ${sv} unsupported (substrate binds v${bound} only; §0.3)`,
    };
  }
  return { ok: true };
}
