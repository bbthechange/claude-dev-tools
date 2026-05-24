# machine_state telemetry — D2 contract (epic: capacity-surfacing)

**Version: `v1` · Status: FROZEN (Brian sign-off 2026-05-24)**
Owner: Brian · Produced: 2026-05-24 · Sourced from: `INTERFACE.md` v2 §4.5
(the work-snapshot projection slot that already names `5h%`, `7d%`,
`today_spare_line%`, `actual_7d%`), `cf/src/capacity.js` (the §1.1/§6.3 gate
contract this MUST stay parallel to but separate from), `daemon/usage-poll.sh`
(the producer this binds to).

This is the **freeze artifact for the capacity-surfacing epic**. It is not an
INTERFACE.md amendment — INTERFACE.md §4.5 already specifies that the
work-snapshot's capacity strip carries the 5h/7d numbers; the gap this epic
closes is that no one ever defined the channel those numbers travel on. D2
*is* that channel definition. If D2 ever conflicts with INTERFACE.md §4.5
the conflict ⇒ reopen claude-tools-65z and amend INTERFACE.md, never edit
this doc silently.

Every implementation file (daemon publisher, engine ingest, snapshot
projection, board renderer, conformance tests) MUST bind to this doc by
name in its anti-drift banner — see §B (Binding map). An agent that
encounters a gap MUST reopen D2, never diverge.

---

## §0. Purpose & scope

### §0.A What this is

A one-way *upward* telemetry channel from the per-machine daemon to the
hosted Coordinator, carrying the human-facing per-machine usage numbers
(5h%, 7d%, spare ramp, threshold in effect) so the Board can render them
faithfully and the user can see *how close to the cap* their machine is —
not just the binary "ok/over" the §6.3 gate produces.

The channel is **separate from §1.1 capacity reports** (Path B in the
epic-planning conversation; §0.D rationale below). The gate continues to
run on §1.1's coarse `verdict ∈ {ok, over}` exactly as it does today;
display reads this channel. Two channels, two cadences, one freeze each.

### §0.B What this is NOT

- NOT a §4 store record. `machine_state` is a §1.1-style UP report in a
  separate namespace, exactly the precedent `capacity_reports` set
  (cf/src/capacity.js banner: "a §1.1 UP report, NOT a §4 store record …
  lives in a SEPARATE `capacity_reports` namespace"). It MUST be absent
  from `schema.js`'s §4 registry. `put machine_state …` ⇒ `unknown_type`;
  `get machine_state …` ⇒ "reachable, just empty".
- NOT a gate signal. The §6.3 `ask-capacity` aggregation does not read
  this channel. A future maintainer who tries to "unify" the two channels
  by routing the gate through telemetry is reintroducing the failure mode
  this separation prevents (§0.D).
- NOT a measurement primitive. The daemon measures (Keychain + Anthropic
  usage API + spare-ramp math); this channel *transports* the
  already-measured numbers. The engine never measures.
- NOT per-workspace. One record per `runner_id` (= machine), period. The
  Board renders one strip per machine, not one per workspace. See §3.B.

### §0.C Why a separate channel (Path B rationale)

The §1.1 capacity-report contract is deliberately a tight closed-enum gate
signal: `cost_class ∈ {standard, low_priority}`, `verdict ∈ {ok, over}`,
nothing else. cf/src/capacity.js enforces it with §0.3 strictness
(unknown HIGHER schema_version REJECTED). Display data evolves on a
*different* cadence than gate logic — over the next year the Board will
plausibly want to surface daemon uptime, workspace counts, queue depth,
disk pressure, etc. Routing that growth through §1.1 would either (a)
force INTERFACE.md amends for every display tweak or (b) erode the §1.1
closed-enum discipline that makes the gate auditable today. A separate
namespace pays a small one-time cost (a second ingest path) to keep both
contracts independently evolvable.

### §0.D Why §4.5 doesn't already mandate this shape

INTERFACE.md §4.5 names the fields the projection MUST carry (`5h%`,
`7d%`, `today_spare_line%` vs `actual_7d%`) but is silent on the
*transport* — how those numbers reach the projection. §4.5 is a read-side
contract; D2 is the producer-side contract that satisfies it. The two
bind cleanly: §4.5 says "the strip MUST contain 5h%/7d%"; D2 says "here
is how the strip gets them, here is what 'missing' looks like, here is
the staleness flag the strip needs."

---

## §1. The upward report (wire format)

The daemon emits one `machine_state` record per poll cycle into the same
outbox the existing capacity reports use
(`$DAEMON_CACHE_DIR/coordinator-outbox.jsonl`), drained by the same
upload mechanism. Cadence matches `USAGE_POLL_TTL_SECONDS` (default 300s).

### §1.1 Required fields (closed)

| Field | Type | Semantics |
|---|---|---|
| `report` | string literal | `"machine_state"` (the dispatch discriminator; the §1.1-style namespace key) |
| `schema_version` | integer | `1`. §0.3 strictness applies (unknown HIGHER ⇒ REJECT, never best-effort). |
| `principal` | string | `PRINCIPAL_V1`. STAMPED at ingest per §9.1 — whatever the report carries is OVERWRITTEN with the resolved principal. |
| `runner_id` | string | `hostname` of the producing machine. `safeKey()`-validated at ingest (same predicate the §4 store + §1.1 capacity reports use — never a duplicated predicate that could drift). |
| `observed_at` | ISO-8601 UTC string | The moment the daemon measured. Latest-wins per `runner_id`: strictly-older straggler is dropped (the exact bash `pobs/nobs` compare from capacity.js capacityReport). |
| `pct_5h` | number `[0, 200]` | The 5-hour quota utilisation %, as the Anthropic usage API returned it. Float OK. Out-of-range ⇒ REJECT. |
| `pct_7d` | number `[0, 200]` | The 7-day quota utilisation %. Same rules. |
| `spare_ramp_today` | integer `[0, 100]` | The day-N × `SPARE_RAMP_PER_DAY` soft line, as computed by the daemon. Out-of-range ⇒ REJECT. |
| `threshold_in_effect` | integer `[0, 100]` | The `USAGE_THRESHOLD` value the daemon is currently honouring. `0` = gate disabled (§0.5 EXIT-2 arm). Surfacing this lets the Board colour-band against the *actual* threshold without a redeploy if it ever moves. |

### §1.2 Optional fields (closed — adding one MUST amend D2)

| Field | Type | Semantics |
|---|---|---|
| `gate_disabled` | boolean | Convenience mirror of `threshold_in_effect === 0`. The Board MAY render off either. |
| `keychain_ok` | boolean | The daemon read the Keychain successfully this cycle. `false` ⇒ the daemon failed open (BC-34) and the percentages are stale-from-last-success or zeroed; the Board surfaces the breadcrumb. |
| `usage_api_ok` | boolean | Same shape for the Anthropic usage API call. |

Adding a field to §1.1 or §1.2 = a D2 amend (small ceremony: bump D2 to
v2, update fixture, update conformance test, re-freeze). Adding a field
WITHOUT amending D2 is the failure mode this contract exists to prevent.

### §1.3 Closed-enum reminder

`report` is a closed literal: exactly `"machine_state"`. Anything else ⇒
the ingest does not route here (it falls through to the existing CAPACITY
or §4 dispatchers, which reject it as unknown). This is the structural
proof that `machine_state` is its own namespace.

### §1.4 Rejection rules (mirror cf/src/capacity.js capacityReport)

In the SAME ORDER as capacity reports, so a rejection on the earlier
gate wins identically:

1. invalid JSON / not an object / `report !== "machine_state"` ⇒ rc 3, NOTHING written
2. `schema_version` not an integer ⇒ rc 3
3. `schema_version > 1` (unknown higher) ⇒ rc 3 (§0.3 — never best-effort)
4. `schema_version !== 1` ⇒ rc 3
5. `runner_id` missing / non-string / unsafeKey ⇒ rc 3
6. `observed_at` missing / non-string ⇒ rc 3
7. any required §1.1 numeric field missing / wrong type / out of range ⇒ rc 3
8. otherwise ⇒ stamp principal (§9.1), store, rc 0

Idempotent latest-wins skip (older straggler, both `observed_at` non-empty,
new < prev): rc 0, no write. Same convention as capacity reports.

---

## §2. Storage (engine side)

### §2.1 Namespace

New table `machine_state_reports` (mirrors `capacity_reports`):

```sql
CREATE TABLE IF NOT EXISTS machine_state_reports (
  runner_id   TEXT NOT NULL PRIMARY KEY,
  observed_at TEXT NOT NULL,
  json        TEXT NOT NULL
)
```

One row per `runner_id`. The `json` column is the byte-faithful stamped
record (verbatim from §1.1's principal-stamped payload). Denormalised
columns (`observed_at`) exist only for the latest-wins read; everything
else flows through `json`.

### §2.2 DDL discipline

Lazy `ensureMachineStateSchema(co)`, idempotent, per-instance memoised —
same pattern as `ensureCapacitySchema` in cf/src/capacity.js. Canonical
migration ships in `migrations/000X_machine_state.sql` for the deploy
path.

### §2.3 Concurrency

The ingest is a read-modify-write (observed_at compare + insert-or-replace).
It runs INSIDE `co._serialize` exactly like `capacityReport` does — the
substrate IS the critical section (AD1; no hand-rolled latch).

### §2.4 Ops dispatch

New op set `MACHINE_STATE_OPS = { "report-machine-state", "get-machine-states" }`:

- `report-machine-state <json>` — §1.1 ingest. Body is the JSON string.
  Response convention 1:1 with `report-capacity`: rc 0 ⇒ `text("", 200)`;
  reject ⇒ `text("", 422)`.
- `get-machine-states` — pure read aggregation, returns
  `{ machines: [ <stamped record>, … ] }` ordered by `runner_id`. Pure
  read ⇒ no serialize (the forensic-audit / notification short-circuit
  precedent). Used by the snapshot projection (§3); usable directly for
  debugging.

`MACHINE_STATE_OPS` MUST stay out of CF.1's `CAPABILITIES` (the four §2
capability lines stay exactly four — same anti-drift discipline
capacity.js documents).

---

## §3. Snapshot projection (read side)

### §3.A Top-level `machines[]`

`workSnapshot` (cf/src/reconcile.js) gains a TOP-LEVEL `machines` array,
peer to `projects` and `waiting_on_you`. NOT nested per-project —
machine-state is per-machine, period (§0.B).

```jsonc
{
  "machines": [
    {
      "runner_id": "macbook-pro.local",
      "observed_at": "2026-05-24T06:38:20Z",
      "pct_5h": 24.0,
      "pct_7d": 82.0,
      "spare_ramp_today": 56,
      "threshold_in_effect": 70,
      "gate_disabled": false,
      "keychain_ok": true,
      "usage_api_ok": true,
      "fresh": true,
      "age_seconds": 42
    }
  ],
  "projects": [ … ],
  "waiting_on_you": [ … ]
}
```

`fresh` and `age_seconds` are computed at projection time
(`now − observed_at`); `fresh = age_seconds ≤ 2 × USAGE_POLL_TTL_SECONDS`.
The Board never has to know the TTL constant — it reads `fresh`. Adjusting
the freshness cutoff is a snapshot-side change, no Board redeploy.

### §3.B What `projects[].capacity_strip` becomes

The per-project `capacity_strip` block in `workSnapshot` is **deprecated
in this epic** (its only consumer was the per-runner pill, removed in §4).
Two acceptable end states:

1. **Drop the block entirely** from the projection — cleanest, but a
   schema-shape change that any current Board build relying on its
   presence would see as missing.
2. **Stub it to `null`** and grep the Board to confirm no consumer.

The implementation step (C3) MUST pick one and document the choice in its
bead. §4.5 wording (which names the strip's fields) is satisfied by
`machines[]` carrying them — the *strip* in the §4.5 sense is the
per-machine header, not the per-project pill.

### §3.C Empty-state semantics

`machines: []` is honest and legal — it means the engine has no fresh
report from any machine (daemon never ran, daemon dead and reports aged
out, …). The Board MUST render an explicit "no telemetry yet" banner in
this case (§4.D). Never a phantom "ok".

---

## §4. Render contract (Board)

Same render-tolerance discipline as the 4xe write-gate / render-tolerance
memory: **write-side strict, read-side tolerant**. The Board NEVER
refuses to render because a field is missing or stale.

### §4.A The strip

One strip per `machines[]` entry, rendered ABOVE the workspace grid
(not inside any workspace card). Format:

```
runner_id · 5h <pct>% · 7d <pct>% · ramp <pct>% · <allowed_classes> · observed <age> ago
```

Two-machine future: two strips, stacked, same shape. The data shape
already supports it (§2.1 PRIMARY KEY runner_id); the Board just iterates.

### §4.B Colour banding (driven by `threshold_in_effect`, not a Board constant)

- `pct_<n> < 0.5 × threshold_in_effect` ⇒ green
- `0.5 × threshold_in_effect ≤ pct_<n> < threshold_in_effect` ⇒ amber
- `pct_<n> ≥ threshold_in_effect` ⇒ red

If the threshold moves from 70 → 85 via env, the Board re-bands on next
snapshot tick. No Board redeploy.

### §4.C Staleness

- `fresh === true` ⇒ render normally.
- `fresh === false` ⇒ render numbers grayed; append "stale <age>" badge.
- `keychain_ok === false` ⇒ append "keychain unreadable" breadcrumb
  (numbers may still be the last-known-good; surfacing the breadcrumb is
  what prevents silent rot).
- `usage_api_ok === false` ⇒ same for "usage API failed".

### §4.D Gate-disabled

`threshold_in_effect === 0` or `gate_disabled === true` ⇒ render the
numbers in a neutral (un-banded) palette with a "gate disabled" chip.
NEVER hide the strip — useful info, not a void.

### §4.E Missing fields

If `pct_5h` or `pct_7d` is missing from a record (shouldn't happen given
§1.4 rejection rules, but defensive), render `—` for that number and a
"partial" breadcrumb. Never collapse the entire strip to "unknown" if
ANY field is present. The lesson from the current `capacity: unknown`
pill is: degrade per-field, not all-or-nothing.

### §4.F The per-project pill comes off

The existing per-runner `rcap` pill in `web/board/app.js:258-259`
("capacity: <verdict>") is REMOVED in this epic. The §6.3 verdict still
exists in the snapshot (driven by §1.1 capacity reports, unchanged) and
is used internally by the over-capacity warn pill at
`board-view.js:464` — that warn pill stays as-is. Only the redundant
per-row "capacity: unknown" text comes off.

---

## §A. Fixture

The canonical fixture lives at
`beads-runner/test-fixtures/machine-state-v1.json`. It is the SINGLE
source of truth that every test (producer-side, ingest-side,
projection-side, render-side) loads from. Changing a field in the fixture
breaks every test that doesn't change in lockstep — that's the
drift-blocker.

Adding a field to the fixture = a D2 amend.

---

## §B. Binding map (which files bind to this contract)

Every file below MUST carry a banner identifying D2 as its frozen oracle.
The banner format is the cf/src/capacity.js precedent verbatim:

```
// ANTI-DRIFT: binds FROZEN MACHINE-STATE.md v1 (D2).
// Oracle = MACHINE-STATE.md + test-fixtures/machine-state-v1.json + <local test>.
// A D2 gap ⇒ reopen D2, bump+re-freeze — NEVER diverge, NEVER edit MACHINE-STATE.md silently.
```

| File | Binding |
|---|---|
| `daemon/usage-poll.sh` (new `_machine_state_emit` helper) | producer (§1) |
| `cf/src/machine-state.js` (new file) | ingest + ops dispatch (§2) |
| `cf/src/schema.js` | MUST NOT add `machine_state` to the §4 registry (§0.B structural absence) |
| `cf/src/reconcile.js` workSnapshot | projection (§3) |
| `web/board/board-view.js` deriveRunner / deriveSnapshot | view-model (§4) |
| `web/board/app.js` render | DOM (§4) |
| `cf/migrations/000X_machine_state.sql` | DDL (§2.2) |
| each test under `cf/test/` and `daemon/test-*` that touches this channel | conformance (§A fixture) |

A file in the binding map that lacks the banner = a drift entry-point.
The C5 conformance bead asserts the banner is present in every listed
file via a simple grep.

---

## §C. Change protocol

D2 evolves via a tiny version-bump ceremony, modeled on INTERFACE.md
§0.3 but lighter (D2 is epic-scoped, not product-frozen):

1. Open the change as a D2-amend bead.
2. Bump `Version: v1 → v2` in the header, dated, with a short rationale
   block in this doc explaining the trigger (the dogfooding lesson, the
   new field, the loosened predicate).
3. Update the fixture in lockstep.
4. Update the conformance test in lockstep.
5. Update each binding-map file's banner to reference v2.
6. Re-freeze (Brian sign-off line on the version banner).

A field added without this ceremony ⇒ a drift incident; document it as
such, revert, and run the ceremony.

---

## §D. Out of scope (deliberate non-extensions for v1)

These belong in future D2 amends or sibling D2-style docs, not in v1:

- **Daemon uptime / cycle-count.** Useful, not load-bearing. Add when
  there's a use case (likely the first time a daemon-died incident
  silently produces stale telemetry for hours and we wish the Board had
  surfaced it).
- **Per-workspace queue depth.** Belongs in `workspace_inventory`
  (INTERFACE.md §4.6 RESERVED), not here. Keep workspace-scoped facts
  out of the machine-scoped channel.
- **Multi-account fingerprint.** Today `runner_id = hostname` and there's
  one Anthropic account per machine. If/when a machine ever serves two
  accounts, `runner_id` will need to become `hostname + account_fp` — a
  D2 amend, but the §2.1 PRIMARY KEY shape already accommodates it.
- **Cost-class breakdown of pct_5h/pct_7d.** Anthropic's usage API
  returns aggregate; a per-class breakdown would be a separate field
  set. Not v1.
