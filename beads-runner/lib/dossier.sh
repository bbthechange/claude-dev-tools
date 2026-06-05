# shellcheck shell=bash
# beads-runner/lib/dossier.sh — T5.1 Dossier/Item DO SUBSTRATE
#                               (claude-tools-fuy; epic claude-tools-glk).
# ════════════════════════════════════════════════════════════════════════════
# OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
#
#   • §4.1  Dossier envelope (schema_version 1): id, kind (OPEN-discriminator
#           C2 seam), trigger, bead_ref, tier, created_at, timer_fire_at,
#           body, items[], and the DERIVED rollup `state`.
#   • §4.1.1 Item per-Item record stored WITHIN items[]: `state`,
#           `response|null`, `consequence_applied:bool`, `applied_at:ts|null`,
#           plus the per-Item idempotency KEY `id` (§0.4 / §5.2).
#   • The per-Item STATE MACHINE — the ONLY legal transitions are
#           open → answered → applied   and   open → expired.
#           Every other transition (incl. a no-op same-state move) is rejected.
#   • The TWO idempotency-latch PRIMITIVES as single-writer STRUCTURES (the
#     apply / dedup LOGIC is the siblings' — see MUST-NOT below):
#       – per-Item `consequence_applied` latch: flips false→true EXACTLY ONCE,
#         single-writer-set; a second structural writer is REJECTED (§7.4
#         per-Item layer / §4.1.1 / S-6).
#       – the dossier-level task_ref DEDUP RECORD structure: a single-writer
#         create-once binding task_ref → dossier_id (§0.4 two-layer key model:
#         per-Item key = Item `id`; dossier-level key = `task_ref`; §7.4
#         dossier layer — one fork ⇒ one Dossier). A second structural writer
#         binding the SAME task_ref to a DIFFERENT dossier is REJECTED.
#   • DERIVED rollup `state`: `open` while ≥1 item is non-terminal,
#           `resolved` when every item is terminal (applied|expired).
#           INFORMATIONAL ONLY — it is NEVER a pipeline gate (AD7): no
#           function in this file branches on it to block an Item op.
#   • §0.3  reject-unknown-higher `schema_version` for the Dossier record
#           (bound on BOTH the write and the read path — never best-effort-
#           parse a higher version).
#   • DESIGN AD1 (DO-per-Item single-threaded ⇒ idempotency BY CONSTRUCTION),
#           AD7 (body ⊃ items[] envelope, partial resolution first-class),
#           the C2 kind-open-discriminator seam.
#   • §0.2  PROVIDER-AGNOSTIC: a bash lib mirroring coordinator.sh
#           conventions. NO provider primitive in any surface (Appendix A is
#           non-normative). The §4.1 envelope round-trips through the T4
#           §2.1/§4 store SURFACE — `co_request put|get dossier` — and the
#           ONE §9.1 `authenticate(request)→principal` chokepoint.
#
# MUST NOT TOUCH (sibling surfaces — drift is a BLOCKING escalation):
#   • §5 generation of `body`/`items[]` content — T5.2. This file round-trips
#     an OPAQUE body and validates only the per-Item RECORD fields it OWNS
#     (§4.1.1); it NEVER synthesises tldr/sections/diagrams/full_detail or any
#     §5 item field (kind/framing/context_anchor/options/recommendation/…).
#   • §5.3 ConsequenceBlock APPLICATION + §7.4 per-Item apply LOGIC — T5.3.
#     `do_item_latch` flips ONLY the boolean latch; it selects/creates/unblocks
#     /relabels NOTHING and does NOT move `state`.
#   • §2.2 durable-timer wiring — T5.4. `timer_fire_at` is stored verbatim;
#     no timer is armed/acked here.
#   • §7.3/§7.4 dossier-level DEDUP LOGIC + S-2 reconcile — T5.5. This file is
#     the single-writer STRUCTURE only; which trigger wins / reconcile back
#     into beads is T5.5.
#   • §4.3 Notification — T5.6.
#   • T4 store INTERNALS — consume the §2.1/§4 SURFACE (`co_request`,
#     `co_authenticate`, `co_store_dir`, `co__schema_version`); never
#     reimplement the record store or add a §4 record type (that is a §0/§11
#     escalation). The dedup record is a T5-owned sibling namespace, exactly
#     as the §10.3 forensic blob is — NOT a §4 record type.
#
# ANTI-DRIFT: binds INTERFACE.md v1 §4.1/§4.1.1/§0.3/§0.4/§0.2. An interface
#   gap or contradiction is a BLOCKING escalation (reopen claude-tools-65z,
#   amend+bump+re-freeze, Brian sign-off) — never diverge locally.
#
# Safe to `source` under `set -euo pipefail`: only function definitions
# below; every fallible call is guarded. Requires `jq`.
# ════════════════════════════════════════════════════════════════════════════

# ── consume the T4 §2.1/§4 store + §9.1 chokepoint SURFACE ───────────────────
# This file is a CONSUMER of T4 (claude-tools-ick). It sources coordinator.sh
# the way the focused T4 tests do, binding to its public surface ONLY:
#   co_request  — the §2.3 authed front door (put|get dossier …)
#   co_authenticate — the ONE §9.1 authenticate(request)→principal chokepoint
#   co_store_dir    — the store LOCATION (one store, no plane-split); the
#                     dedup sibling namespace lives under it, mirroring the
#                     §10.3 forensic namespace precedent
#   co__schema_version — the §4 registry; the dossier bound version is read
#                     FROM it (single normative definition — no competing
#                     local restatement; §0.3/§0.5 anti-drift discipline)
# It does NOT redefine, wrap, or reach past these into T4 internals.
do__lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
if ! declare -F co_request >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(do__lib_dir)/coordinator.sh"
fi

# ── §0.3 bound schema_version — READ from the T4 §4 registry ─────────────────
# §0.3 binds a consumer to a schema version; §0.5 forbids a competing local
# restatement of a value with a single normative definition. The Dossier's
# bound version is defined ONCE, in T4's co__schema_version registry. This
# substrate READS it there rather than restating `1`, so a future bump is a
# single registry edit under the §0/§11 protocol, never a drift here.
do__bound_sv() { co__schema_version dossier; }

# ════════════════════════════════════════════════════════════════════════════
# §4.1 / §4.1.1 — ENVELOPE + per-Item RECORD validation
# ════════════════════════════════════════════════════════════════════════════
# do_dossier_validate <json>
#   Returns 0 iff <json> is a well-formed §4.1 envelope carrying well-formed
#   §4.1.1 Item records. On any violation: a §-cited diagnostic on stderr and
#   a nonzero return — the caller MUST NOT persist a rejected envelope.
#
#   §0.3 is enforced HERE: schema_version MUST be an integer EQUAL to the
#   bound version; an unknown HIGHER version is rejected as "unknown higher"
#   (never best-effort-parsed); any other value is unsupported → reject.
#
#   `kind` is the C2 OPEN discriminator: validated as a present non-empty
#   string ONLY. v1 implements "decide"; "pair" is reserved-not-implemented.
#   An UNKNOWN kind is NOT rejected (open shape, not a closed enum) — closing
#   it would be the very C2 regression this seam exists to prevent.
#
#   `body` is OPAQUE here: asserted to be an object so the envelope is
#   well-formed, but its §5 shape (tldr/sections/diagrams/full_detail and
#   body.dossier_schema_version) is T5.2's — NEVER inspected or synthesised.
do_dossier_validate() {
  local json="${1:-}" bound; bound="$(do__bound_sv)"
  if [[ -z "$bound" ]]; then
    echo "dossier: reject — 'dossier' absent from the T4 §4 registry (co__schema_version) — store-surface contract gap" >&2
    return 2
  fi
  printf '%s' "$json" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier: reject — not a JSON object (§4.1 envelope)" >&2; return 2; }

  # §0.3 schema_version — integer, type-checked IN jq so a string "1"/float/
  # bool cannot slip past (mirrors the T4 co__store_put §0.3 discipline).
  local sv
  sv=$(printf '%s' "$json" | jq -r '
        if (.schema_version|type)=="number"
           and (.schema_version == (.schema_version|floor))
        then .schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "dossier: reject — missing integer schema_version (§4.1 'int' / §0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "dossier: reject — schema_version $sv is an unknown higher version (bound=$bound; §0.3 reject, never best-effort-parse)" >&2
    return 3
  fi
  if [[ "$sv" -ne "$bound" ]]; then
    echo "dossier: reject — schema_version $sv unsupported (substrate binds v$bound only; §0.3)" >&2
    return 3
  fi

  # §4.1 envelope fields. `kind` = OPEN C2 discriminator (present non-empty
  # string only — unknown values are NOT rejected). `timer_fire_at` is
  # stored-verbatim here (the §2.2 timer is T5.4); only its shape (string|
  # null, key present) is the substrate's concern.
  local errs
  errs=$(printf '%s' "$json" | jq -r '
    [ (if (.id|type)=="string"  and (.id|length)>0  then empty else "§4.1 id: non-empty string required" end),
      (if (.kind|type)=="string" and (.kind|length)>0 then empty else "§4.1 kind: non-empty string required (C2 open discriminator)" end),
      (if (.trigger|type)=="string" and ((.trigger)|IN("human_flag","worker_stuck","stage_gate","proactive_checkpoint")) then empty else "§4.1 trigger: human_flag|worker_stuck|stage_gate|proactive_checkpoint" end),
      (if (.bead_ref|type)=="string" and (.bead_ref|length)>0 then empty else "§4.1 bead_ref: non-empty string required" end),
      (if (.tier|type)=="string" and ((.tier)|IN("blocking","timed-fyi","digest")) then empty else "§4.1 tier: blocking|timed-fyi|digest" end),
      (if (.created_at|type)=="string" and (.created_at|length)>0 then empty else "§4.1 created_at: RFC-3339 string required" end),
      (if (has("timer_fire_at")) and ((.timer_fire_at|type)=="string" or (.timer_fire_at==null)) then empty else "§4.1 timer_fire_at: string|null (key required)" end),
      (if (.body|type)=="object" then empty else "§4.1 body: object required (opaque here — §5 shape is T5.2)" end),
      (if (.items|type)=="array" then empty else "§4.1 items[]: array required (may be empty — Flow F overview, §5.2.1)" end)
    ] | .[]' 2>/dev/null) || errs="§4.1 envelope: unparseable"
  if [[ -n "$errs" ]]; then
    echo "dossier: reject — $errs" >&2; return 3
  fi

  # §4.1.1 per-Item RECORD fields ONLY (state · response|null ·
  # consequence_applied:bool · applied_at:ts|null) + the §0.4 per-Item key
  # `id`. §5 item content (kind/framing/context_anchor/options/…) is T5.2 —
  # deliberately NOT inspected here (anti-drift: validating it would bind §5).
  local ierrs
  ierrs=$(printf '%s' "$json" | jq -r '
    .items | to_entries[] | .key as $i | .value |
    [ (if type=="object" then empty else "§4.1.1 items[\($i)]: object required" end),
      (if (.id|type)=="string" and (.id|length)>0 then empty else "§4.1.1 items[\($i)].id: non-empty string (§0.4 per-Item key)" end),
      (if (.state|type)=="string" and ((.state)|IN("open","answered","applied","expired")) then empty else "§4.1.1 items[\($i)].state: open|answered|applied|expired" end),
      (if (has("response")) and ((.response|type)=="object" or (.response==null)) then empty else "§4.1.1 items[\($i)].response: object|null (key required)" end),
      (if (.consequence_applied|type)=="boolean" then empty else "§4.1.1 items[\($i)].consequence_applied: boolean latch required" end),
      (if (has("applied_at")) and ((.applied_at|type)=="string" or (.applied_at==null)) then empty else "§4.1.1 items[\($i)].applied_at: ts|null (key required)" end)
    ] | .[]' 2>/dev/null) || ierrs="§4.1.1 items[]: unparseable"
  if [[ -n "$ierrs" ]]; then
    echo "dossier: reject — $ierrs" >&2; return 3
  fi

  # §0.4 per-Item idempotency key MUST be unique within items[] (one item id
  # ⇒ one latch; a duplicate id would make the per-Item latch ambiguous).
  local dup
  dup=$(printf '%s' "$json" | jq -r '
    ([.items[].id] | group_by(.) | map(select(length>1) | .[0]) | .[]?)' 2>/dev/null) || dup=""
  if [[ -n "$dup" ]]; then
    echo "dossier: reject — duplicate Item id '$dup' within items[] (§0.4 per-Item key must be unique)" >&2; return 3
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# DERIVED rollup state — §4.1 (AD7). INFORMATIONAL, NEVER A GATE.
# ════════════════════════════════════════════════════════════════════════════
# do_dossier_rollup <json>  →  prints  open | resolved
#   PURE derivation: `open` while ≥1 item is non-terminal (open|answered);
#   `resolved` when EVERY item is terminal (applied|expired). A zero-item
#   envelope is vacuously `resolved` (a Flow F all-fyi-objectable overview may
#   carry zero items — §5.2.1; still informational only).
#
#   AD7 INVARIANT (enforced by STRUCTURE, asserted by test): this value is
#   computed and surfaced but NOTHING in this file ever branches on it to
#   permit/deny an Item op. Resolving 6 of 15 items NEVER blocks the other 9;
#   a `resolved` rollup NEVER blocks a late op. It is a read-side projection
#   datum (T6a renders it), not a pipeline gate.
do_dossier_rollup() {
  printf '%s' "${1:-}" | jq -r '
    if (.items|type)!="array" then "open"
    elif any(.items[]?; .state=="open" or .state=="answered") then "open"
    else "resolved" end' 2>/dev/null || printf 'open'
}

# do__stamp_rollup <json> — return <json> with the DERIVED `.state` set to the
# freshly-computed rollup. Called on every write AND every read so a stored
# `.state` is never trusted as authoritative (it is derived, §4.1).
do__stamp_rollup() {
  local json="$1" r; r="$(do_dossier_rollup "$json")"
  printf '%s' "$json" | jq -c --arg s "$r" '.state=$s' 2>/dev/null || printf '%s' "$json"
}

# ════════════════════════════════════════════════════════════════════════════
# SINGLE-WRITER critical section — the structure the §7.4 latches stand on
# ════════════════════════════════════════════════════════════════════════════
# A per-Item op (latch flip, state move) is a READ-DECIDE-WRITE of the §4.1
# envelope. AD1 ("DO-per-Item single-threaded ⇒ idempotency BY CONSTRUCTION")
# is realised in the *non-normative* Cloudflare DO by a single-threaded
# executor (Appendix A, §0.2) — this bash skeleton has NO such executor, so
# the read-decide-write MUST be serialised explicitly or the false→true-ONCE
# / no-lost-update guarantees fail under a concurrent caller (e.g. S-6
# timer-fire racing poll-fallback, §2.2). It is serialised the SAME way the
# T4 store (`co__with_lock`, coordinator.sh) and the T4 Lease primitive — the
# sibling with the identical reject-the-second-writer requirement — do it,
# and the same way PRIMITIVE 2 (`do_dedup_record`) below does: the portable
# `mkdir` atomic test-and-set. The lock is keyed on the DOSSIER id because
# the envelope (all `items[]`) is the storage granularity here — a per-Item
# lock would not stop two sibling-Item writers clobbering the one envelope
# file; the per-dossier lock makes the envelope a single-writer object, which
# is what makes BOTH the per-Item latch exactly-once AND AD7 partial
# resolution (resolve 6 of 15, the other 9 untouched) hold under concurrency.
# Consuming the T4 store SURFACE for persistence (co_request) does not give
# the substrate an atomic compare-and-set across its OWN get→put gap — that
# gap is the substrate's to close, exactly as T4's Lease closes its own.
do__lock_dir() {
  local d; d="$(co_store_dir 2>/dev/null)" || d="${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"
  printf '%s/dossier-locks' "$d"
}
# do__with_dossier_lock <dossier_id> <cmd...> — run <cmd...> holding the
# exclusive per-dossier lock. Bounded spin (never deadlock the skeleton);
# the lock is released on EVERY path (success, reject, error).
do__with_dossier_lock() {
  local did="${1:-}"; shift || true
  do__safe_key "$did" || { echo "dossier: unsafe dossier id '$did' ([A-Za-z0-9._-], no '..')" >&2; return 2; }
  local ld; ld="$(do__lock_dir)"; mkdir -p "$ld" 2>/dev/null || true
  local lockd="$ld/.lock.$did" i=0
  until mkdir "$lockd" 2>/dev/null; do
    i=$((i+1)); [[ $i -ge 200 ]] && break    # bounded; single-host skeleton
    sleep 0.01 2>/dev/null || true
  done
  local rc=0
  "$@" || rc=$?
  rmdir "$lockd" 2>/dev/null || true
  return "$rc"
}

# ════════════════════════════════════════════════════════════════════════════
# §4.1 ENVELOPE round-trip through the T4 §2.1/§4 store SURFACE
# ════════════════════════════════════════════════════════════════════════════
# do_dossier_put <bearer> <json>
#   Validate (§4.1/§4.1.1/§0.3) → stamp the DERIVED rollup → persist via the
#   T4 front door `co_request <bearer> put dossier <id> <json>`. T4 re-enforces
#   §0.3 and STAMPS `principal` (§9.1) — this substrate NEVER stamps principal
#   itself (no second auth path; the resolved principal is bound at the T4
#   chokepoint, never a literal at this use site — C7). A validation failure
#   returns nonzero having performed NO write. Echoes the id on success.
do_dossier_put() {
  local bearer="${1:-}" json="${2:-}" id canon
  do_dossier_validate "$json" || return $?
  id=$(printf '%s' "$json" | jq -r '.id' 2>/dev/null) || id=""
  [[ -n "$id" ]] || { echo "dossier: reject — no id (§4.1)" >&2; return 3; }
  canon="$(do__stamp_rollup "$json")"
  co_request "$bearer" put dossier "$id" "$canon" || return $?
  printf '%s' "$id"
}

# do_dossier_get <bearer> <id>
#   Fetch via `co_request <bearer> get dossier <id>`, then BIND §0.3 on the
#   READ path too (reject an unknown-higher version rather than best-effort-
#   parse it) and RE-DERIVE `.state` (never trust a stored rollup — §4.1).
#   Echoes the §0.3-checked, rollup-refreshed record; nonzero if absent or
#   §0.3-rejected.
do_dossier_get() {
  local bearer="${1:-}" id="${2:-}" raw bound sv
  raw="$(co_request "$bearer" get dossier "$id" 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  bound="$(do__bound_sv)"
  sv=$(printf '%s' "$raw" | jq -r '
        if (.schema_version|type)=="number"
           and (.schema_version == (.schema_version|floor))
        then .schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "dossier: reject (read) — stored record missing integer schema_version (§0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "dossier: reject (read) — schema_version $sv is an unknown higher version (bound=$bound; §0.3, never best-effort-parse)" >&2; return 3
  fi
  do__stamp_rollup "$raw"
}

# ════════════════════════════════════════════════════════════════════════════
# Per-Item STATE MACHINE — the ONLY legal transitions
# ════════════════════════════════════════════════════════════════════════════
# do_item_state_check <from> <to>   → 0 iff the transition is LEGAL
#   The ENTIRE legal set (INTERFACE §4.1.1/§5.2):
#       open → answered    answered → applied    open → expired
#   EVERYTHING else — including a same-state no-op (open→open), a skip
#   (open→applied), a terminal escape (applied→*, expired→*), and an unknown
#   state — is ILLEGAL. PURE: no I/O, no store, side-effect free.
do_item_state_check() {
  case "${1:-}|${2:-}" in
    open\|answered)   return 0 ;;
    answered\|applied) return 0 ;;
    open\|expired)    return 0 ;;
    *) return 1 ;;
  esac
}

# do_item_set_state <bearer> <dossier_id> <item_id> <to_state> [response_json]
#   Move ONE Item's `state` token through the state machine. Reads the
#   Dossier via the T4 surface, locates the Item by `id` (§0.4 per-Item key),
#   checks the transition with do_item_state_check, and on ILLEGAL transition
#   REJECTS (nonzero, NO write). On a legal transition it sets `.state` and —
#   if a response_json is supplied — stores it verbatim in the §4.1.1
#   `.response` FIELD (the substrate field; the §5.2.2 INTERPRETATION of a
#   response — deterministic-apply vs reconciler — is T5.3, NOT here), then
#   re-derives the rollup and persists via the T4 front door.
#
#   ORTHOGONALITY (anti-drift): this NEVER touches `consequence_applied`
#   (that is the separate latch primitive) and NEVER selects/applies a
#   ConsequenceBlock (§5.3 = T5.3). Coupling the state move to the latch is
#   §7.4 apply LOGIC — a sibling's, not the substrate's.
#
#   The get→check→put critical section runs under the per-dossier
#   single-writer lock (do__with_dossier_lock) so a concurrent sibling-Item
#   writer cannot clobber the shared envelope — AD7 partial resolution holds
#   under concurrency, not only single-threaded.
do_item_set_state() {
  do__with_dossier_lock "${2:-}" do__item_set_state_locked "$@"
}
do__item_set_state_locked() {
  local bearer="${1:-}" did="${2:-}" iid="${3:-}" to="${4:-}" resp="${5:-}"
  local rec cur upd
  rec="$(do_dossier_get "$bearer" "$did")" || { echo "dossier: set-state — dossier '$did' not found" >&2; return 1; }
  printf '%s' "$rec" | jq -e --arg i "$iid" 'any(.items[]?; .id==$i)' >/dev/null 2>&1 \
    || { echo "dossier: set-state — Item '$iid' not in '$did' (§0.4)" >&2; return 1; }
  cur=$(printf '%s' "$rec" | jq -r --arg i "$iid" '.items[] | select(.id==$i) | .state' 2>/dev/null) || cur=""
  if ! do_item_state_check "$cur" "$to"; then
    echo "dossier: set-state REJECTED — illegal transition ${cur}->${to} for Item '${iid}' (legal: open->answered->applied | open->expired; §4.1.1/§5.2)" >&2
    return 2
  fi
  if [[ -n "$resp" ]]; then
    printf '%s' "$resp" | jq -e 'type=="object"' >/dev/null 2>&1 \
      || { echo "dossier: set-state — response must be a JSON object|absent (§4.1.1 .response)" >&2; return 2; }
    upd=$(printf '%s' "$rec" | jq -c --arg i "$iid" --arg s "$to" --argjson r "$resp" \
            '.items |= map(if .id==$i then (.state=$s | .response=$r) else . end)' 2>/dev/null) \
      || { echo "dossier: set-state — could not update Item" >&2; return 3; }
  else
    upd=$(printf '%s' "$rec" | jq -c --arg i "$iid" --arg s "$to" \
            '.items |= map(if .id==$i then .state=$s else . end)' 2>/dev/null) \
      || { echo "dossier: set-state — could not update Item" >&2; return 3; }
  fi
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# L1 follow-up (claude-tools-uxl1b) §5.6 — DEFER / ESCALATE attention verbs
# ════════════════════════════════════════════════════════════════════════════
# do_dossier_defer    <bearer> <dossier_id>   → tier="digest"   ("push out")
# do_dossier_escalate <bearer> <dossier_id>   → tier="blocking" ("promote")
#   Adjust the §4.1 attention tier AND DISARM the §2.2 auto-proceed timer — the
#   two remaining Inbox verbs as DISTINCT ops (no verb defaults to another's
#   payload — the L1 empty-payload bug class). NO §5.2 response, NO §5.3
#   ConsequenceBlock, NO per-Item state move: items[]/response/
#   consequence_applied all round-trip verbatim. The verbs toggle the two
#   human-managed attention levels — foreground `blocking` ⟷ background
#   `digest` — and NEVER target the `timed-fyi` auto-proceed lane (pushing a
#   decision INTO timed-fyi would arm a silent auto-apply — the §5.6/L1
#   hazard). Because both targets are non-auto-proceed tiers, a real move ALSO
#   nulls timer_fire_at + soft-disarms any prior arm (claude-tools-fyci) — so a
#   deferred/escalated ARMED timed-fyi card cannot strand a stale fire time (the
#   digest+armed-timer edge that split o2mk's L2 auto-close discriminators).
#   Total + idempotent: already at the target tier ⇒ success with NO write (so a
#   no-op move never even re-touches an already-null timer). Runs under the
#   per-dossier single-writer lock (a tier move is a read-decide-write of the
#   shared envelope, exactly like do_item_set_state). JS twin: cf/src/dossier.js
#   dossierSetAttention (same targets, same idempotency, same disarm).
do_dossier_defer()    { do__with_dossier_lock "${2:-}" do__dossier_set_attention_locked "${1:-}" "${2:-}" digest; }
do_dossier_escalate() { do__with_dossier_lock "${2:-}" do__dossier_set_attention_locked "${1:-}" "${2:-}" blocking; }
do__dossier_set_attention_locked() {
  local bearer="${1:-}" did="${2:-}" target="${3:-}" rec from upd
  rec="$(do_dossier_get "$bearer" "$did")" || { echo "dossier: attention — dossier '$did' not found" >&2; return 1; }
  from=$(printf '%s' "$rec" | jq -r '.tier // ""' 2>/dev/null) || from=""
  if [[ "$from" == "$target" ]]; then
    return 0      # idempotent: already at the target attention tier, NO write
  fi
  # Move .tier AND null timer_fire_at in the SAME write (claude-tools-fyci): the
  # target is always a non-auto-proceed tier (digest|blocking), which §4.1 MUST
  # NOT carry an armed §2.2 timer — so a deferred/escalated ARMED timed-fyi card
  # cannot strand a stale fire time.
  upd=$(printf '%s' "$rec" | jq -c --arg t "$target" '.tier=$t | .timer_fire_at=null' 2>/dev/null) \
    || { echo "dossier: attention — could not set tier for '$did'" >&2; return 3; }
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?
  # Soft-disarm any prior §2.2 arm — mirrors tf_arm's non-timed-fyi path (§2.2
  # has no disarm; timer-ack stops the poll-fallback re-surfacing). Best-effort.
  co_request "$bearer" timer-ack "$did" >/dev/null 2>&1 || true
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# PRIMITIVE 1 — the per-Item `consequence_applied` LATCH  (§7.4 / §4.1.1)
# ════════════════════════════════════════════════════════════════════════════
# do_item_latch <bearer> <dossier_id> <item_id>
#   The single-writer-set per-Item idempotency latch PRIMITIVE. Flips THAT
#   Item's `consequence_applied` false→true EXACTLY ONCE and stamps
#   `applied_at`. A SECOND structural writer (latch already true) is REJECTED
#   (nonzero, NO write) — this IS the "one item response ⇒ applied once"
#   structure §7.4 stands on. AD1 single-threadedness is the *non-normative*
#   Cloudflare-DO realisation (Appendix A, §0.2); this bash skeleton has no
#   single-threaded executor, so false→true-ONCE is made true under
#   concurrency by running the get→decide→put under the per-dossier
#   single-writer lock (do__with_dossier_lock) — the SAME mkdir
#   test-and-set the T4 store / T4 Lease / PRIMITIVE 2 use. Without it the
#   S-6 timer-fire-vs-poll-fallback race (§2.2) would double-apply.
#
#   PRIMITIVE ONLY (anti-drift): it flips the boolean and stamps the
#   timestamp — it selects/creates/unblocks/relabels NOTHING (no
#   ConsequenceBlock; §5.3 apply LOGIC = T5.3) and does NOT move `.state`
#   (the state machine is the orthogonal primitive). A caller wanting
#   answered→applied calls do_item_set_state AND this latch — that
#   ORCHESTRATION is the §7.4 apply LOGIC (T5.3), not the substrate.
do_item_latch() {
  do__with_dossier_lock "${2:-}" do__item_latch_locked "$@"
}
do__item_latch_locked() {
  local bearer="${1:-}" did="${2:-}" iid="${3:-}" rec already upd now
  rec="$(do_dossier_get "$bearer" "$did")" || { echo "dossier: latch — dossier '$did' not found" >&2; return 1; }
  printf '%s' "$rec" | jq -e --arg i "$iid" 'any(.items[]?; .id==$i)' >/dev/null 2>&1 \
    || { echo "dossier: latch — Item '$iid' not in '$did' (§0.4)" >&2; return 1; }
  already=$(printf '%s' "$rec" | jq -r --arg i "$iid" \
              '.items[] | select(.id==$i) | .consequence_applied' 2>/dev/null) || already=""
  if [[ "$already" == "true" ]]; then
    echo "dossier: latch REJECTED — Item '$iid' consequence_applied already true (single-writer-set; false→true ONCE; §7.4 per-Item / §4.1.1)" >&2
    return 2
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  upd=$(printf '%s' "$rec" | jq -c --arg i "$iid" --arg at "$now" \
          '.items |= map(if .id==$i then (.consequence_applied=true | .applied_at=$at) else . end)' 2>/dev/null) \
    || { echo "dossier: latch — could not set latch" >&2; return 3; }
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# PRIMITIVE 2 — the dossier-level task_ref DEDUP RECORD structure  (§0.4/§7.4)
# ════════════════════════════════════════════════════════════════════════════
# §0.4 two-layer key model: the DOSSIER-level double-trigger dedup key =
# `task_ref` (the per-Item key is the Item `id`, handled by PRIMITIVE 1). §7.4
# dossier layer: worker-self-signal + backstop on the SAME fork must collapse
# to ONE Dossier — "two triggers never make two dossiers". This file provides
# the single-writer create-once STRUCTURE that property stands on; WHICH
# trigger wins and the S-2 reconcile back into beads is the dedup LOGIC =
# T5.5 (MUST-NOT-TOUCH here).
#
# It is NOT a §4 record type (absent from the T4 co__schema_version registry —
# adding one is a §0/§11 escalation, MUST-NOT). It is a T5-owned sibling
# namespace under the SAME store the §4 records use (one store, no plane-
# split), EXACTLY mirroring the §10.3 forensic-blob precedent (its own
# namespace, explicitly not a §4 record). Single-writer is the portable
# mkdir atomic test-and-set — the SAME primitive T4's co__with_lock uses.
do__dedup_dir() {
  local d; d="$(co_store_dir 2>/dev/null)" || d="${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"
  printf '%s/dossier-dedup' "$d"
}
do__safe_key() {  # mirror co__safe_key: no '/'/'..'; [A-Za-z0-9._-] only
  local k="${1:-}"
  [[ -n "$k" ]] || return 1
  [[ "$k" == *".."* ]] && return 1
  [[ "$k" =~ ^[A-Za-z0-9._-]+$ ]]
}

# do_dedup_record <bearer> <task_ref> <dossier_id>
#   Single-writer CREATE-ONCE bind task_ref → dossier_id.
#     • first writer for task_ref            ⇒ create + return 0
#     • re-create, SAME dossier_id           ⇒ idempotent success (return 0):
#       one fork ⇒ one Dossier already holds — NOT a second writer
#     • second writer, DIFFERENT dossier_id  ⇒ REJECTED (nonzero, NO
#       overwrite): the "two triggers never make two dossiers" STRUCTURE
#   Authenticates through the ONE §9.1 chokepoint `co_authenticate` (NO second
#   auth path) and stamps the RESOLVED principal (§9.1; never a literal here).
do_dedup_record() {
  local bearer="${1:-}" tref="${2:-}" did="${3:-}" principal dir lock rc=0 cur
  principal="$(co_authenticate "$bearer" 2>/dev/null)" || principal=""
  if [[ -z "$principal" ]]; then
    echo "dossier: dedup 401 — bearer missing/invalid; rejected (NO write; §9.1/§2.3)" >&2; return 1
  fi
  [[ -n "$tref" && -n "$did" ]] || { echo "dossier: dedup — need <task_ref> <dossier_id> (§0.4)" >&2; return 2; }
  do__safe_key "$tref" || { echo "dossier: dedup — unsafe task_ref key '$tref' ([A-Za-z0-9._-], no '..')" >&2; return 2; }
  dir="$(do__dedup_dir)"; mkdir -p "$dir" 2>/dev/null || true
  local path="$dir/$tref.json"
  lock="$dir/.create.$tref"
  local i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [[ $i -ge 200 ]] && break
    sleep 0.01 2>/dev/null || true
  done
  if [[ -f "$path" ]]; then
    cur=$(jq -r '.dossier_id // ""' "$path" 2>/dev/null) || cur=""
    if [[ "$cur" == "$did" ]]; then
      rc=0                          # idempotent: same fork ⇒ same Dossier
    else
      echo "dossier: dedup REJECTED — task_ref '$tref' already bound to dossier '$cur' (one fork ⇒ one Dossier; §0.4/§7.4 dossier layer; LOGIC=T5.5)" >&2
      rc=2
    fi
  else
    local now tmp
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    tmp="$path.$$.tmp"
    if jq -cn --arg tr "$tref" --arg d "$did" --arg p "$principal" --arg at "$now" \
         '{task_ref:$tr,dossier_id:$d,principal:$p,created_at:$at}' > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$path" 2>/dev/null; then
      rc=0
    else
      rm -f "$tmp" 2>/dev/null; echo "dossier: dedup — write failed for '$tref'" >&2; rc=4
    fi
  fi
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# do_dedup_get <task_ref> — echo the bound dossier_id (so a sibling's §7.4/S-2
# dedup LOGIC can CONSULT the structure), or return 1 if no binding exists.
# Read-only; takes no bearer (no write, no §4 record — a structure consult).
do_dedup_get() {
  local tref="${1:-}" path
  do__safe_key "$tref" || return 1
  path="$(do__dedup_dir)/$tref.json"
  [[ -f "$path" ]] || return 1
  jq -r '.dossier_id // empty' "$path" 2>/dev/null || return 1
}
