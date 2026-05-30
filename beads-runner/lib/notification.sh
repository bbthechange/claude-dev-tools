# shellcheck shell=bash
# beads-runner/lib/notification.sh — T5.6 NOTIFICATION: §4.3 persisted tiered
#                                    record, one-per-Dossier, creation≠dispatch
#                                    (claude-tools-ks2; epic claude-tools-glk).
# ════════════════════════════════════════════════════════════════════════════
# OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
#
#   • §4.3 Notification record (`schema_version` 1): id, principal,
#     dossier_ref, tier ∈ {blocking, timed-fyi, digest}, created_at,
#     dispatched:bool, dispatched_at:ts|null, channel (opaque tag)|null.
#     A Notification carries EXACTLY these fields and NOTHING else — there is
#     structurally NO place for content: the §5 dossier *body* carries the
#     content (UX principle 2). `no__validate` REJECTS any key outside the
#     §4.3 closed set, so "the notification stays terse" is an enforced
#     invariant, not a convention.
#
#   • EXACTLY ONE Notification per Dossier (C3; AD7 — NOT one-per-Item). A
#     15-item dossier yields ONE Notification. Enforced by STRUCTURE: the
#     notification id is DETERMINISTICALLY derived from the dossier id
#     (`no__notif_id`), so re-emit binds the SAME store record — a second
#     emit for the same dossier is an idempotent no-op (created_at and the
#     dispatch latch are NEVER reset), never a second row, and items[] is
#     never iterated.
#
#   • The §4.1 `tier` drives the SINGLE Notification: `no_emit` MIRRORS the
#     dossier's §4.1 tier onto the §4.3 record (read off the T5.1 store; the
#     tier is NOT recomputed here — §4.1 is T5.1's). It records the tier; it
#     does NOT set a §2.2 timer (the §4.1 tier ALSO drives whether a timer is
#     set, but that decision is T5.4's — MUST-NOT below).
#
#   • creation≠dispatch — the C3 seam, NORMATIVE. `no_emit` creates the row
#     with `created_at` set and `dispatched=false` BEFORE any send;
#     `dispatched`/`dispatched_at` flip ONLY in `no_dispatch`, and only
#     false→true EXACTLY ONCE (single-writer-set, mirroring the T5.1 per-Item
#     latch). Fire-and-forget is FORBIDDEN: `no_dispatch` REJECTS when no row
#     exists — a Notification row MUST precede any send.
#
#   • Emitted AT dossier creation: `no_for_generation` consumes the T5.2
#     creation hook (`dg_generate`) and the T5.1 store, creating the ONE
#     Notification immediately after the §5 dossier is persisted — the row
#     exists before any dispatch (C3). `channel` is an OPAQUE transport tag
#     stored verbatim and never interpreted, so a later read-side digest
#     rollup needs NO schema change (C3).
#
#   • §0.3 reject-unknown-higher `schema_version` for the Notification record,
#     bound on BOTH the write path (re-enforced by the T4 store) and the read
#     path (`no_get` — never best-effort-parse a higher stored version). The
#     bound version is READ from the T4 §4 registry (`co__schema_version
#     notification`), never restated as a competing local literal (§0.5).
#
#   • §0.2 PROVIDER-AGNOSTIC: a bash lib mirroring the sibling conventions
#     (dossier.sh / timed-fyi.sh). NO provider primitive in any surface. The
#     §4.3 record round-trips through the T4 §2.1/§4 store SURFACE
#     (`co_request put|get notification`) and the ONE §9.1
#     `authenticate(request)→principal` chokepoint — principal is stamped
#     THERE, never a literal at this use site (C7).
#
# MUST NOT TOUCH (sibling surfaces — drift is a BLOCKING escalation, §11):
#   • §4.1 envelope / §4.1.1 per-Item record / state-machine + latch/dedup
#     PRIMITIVE internals — T5.1 (claude-tools-fuy). Consumed as a black box
#     via the PUBLIC surface ONLY (`do_dossier_get`, `do__safe_key`); the §4
#     store / envelope validation is NEVER re-implemented.
#   • §5 generation of `body`/`items[]` content — T5.2 (claude-tools-9gt).
#     `no_for_generation` CONSUMES the `dg_generate` creation hook; it
#     synthesises NO §5 content and never inspects the body (the Notification
#     deliberately cannot carry it — principle 2).
#   • §5.3 apply LOGIC + §7.4 per-Item latch — T5.3 (claude-tools-o0u).
#   • §2.2 timer-set logic — T5.4 (claude-tools-it2). The §4.1 tier ALSO
#     drives whether a §2.2 timer is set, but that decision is T5.4's; this
#     file RECORDS the tier on the Notification and arms/acks NO timer.
#   • §7.3/§7.4 STUCK + dossier-level dedup/reconcile — T5.5.
#   • The actual transport/dispatch MECHANISM beyond the `dispatched` latch —
#     C3 DEFERS the channel (out of v1 scope). `no_dispatch` flips the latch
#     and stores the opaque `channel` tag verbatim; it sends NOTHING.
#   • T4 store INTERNALS — consume the §2.1/§4 SURFACE (`co_request`,
#     `co_authenticate`, `co_store_dir`, `co__schema_version`); never
#     reimplement the record store or add a §4 record type. `notification` is
#     ALREADY a registered §4 type (T4, coordinator.sh) — this file adds NO
#     §4 type and does NOT edit the registry.
#
# ANTI-DRIFT: binds INTERFACE.md v1 §4.3 / §0.3 / §0.5 / §0.2.
#   one-per-Dossier + creation≠dispatch are NORMATIVE (C3). An INTERFACE
#   gap/contradiction is a BLOCKING §11 escalation (reopen claude-tools-65z,
#   amend+bump+re-freeze, Brian sign-off) — never diverge locally. (No
#   INTERFACE gap was found: §4.3 is a complete, self-consistent schema and
#   `notification` is already in the T4 §4 registry.)
#
# Safe to `source` under `set -euo pipefail`: only function definitions below;
# every fallible call is guarded. Requires `jq`.
# ════════════════════════════════════════════════════════════════════════════

# ── consume the T5.2 creation hook + T5.1 store + T4 §2.1/§4 / §9.1 surface ───
# Sources dossier-gen.sh (→ dossier.sh → coordinator.sh transitively) the way
# the focused sibling tests do, binding ONLY to the public surface:
#   dg_generate      — the T5.2 §5 sole-producer creation hook (consumed by
#                      no_for_generation; NEVER re-implemented)
#   do_dossier_get   — the T5.1 §4.1 envelope read (the dossier `tier` the
#                      single Notification mirrors is read off THIS, not
#                      recomputed — §4.1 is T5.1's)
#   do__safe_key     — the shared id-safety predicate ([A-Za-z0-9._-])
#   co_request       — the §2.3 authed front door (put|get notification …)
#   co_authenticate  — the ONE §9.1 authenticate(request)→principal chokepoint
#   co_store_dir     — the store LOCATION (the single-writer lock namespace
#                      lives under it, mirroring the dossier-locks precedent)
#   co__schema_version — the §4 registry; the notification bound version is
#                      READ from it (single normative definition — §0.3/§0.5)
no__lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
if ! declare -F dg_generate >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(no__lib_dir)/dossier-gen.sh"
fi

# ── §0.3 bound schema_version — READ from the T4 §4 registry (§0.5) ───────────
# §0.3 binds a consumer to a schema version; §0.5 forbids a competing local
# restatement. The Notification's bound version is defined ONCE, in T4's
# co__schema_version registry (`notification`). This file READS it there
# rather than restating `1` — the SAME discipline do__bound_sv set for the
# dossier — so a future bump is a single registry edit under §0/§11, never a
# drift here.
no__bound_sv() { co__schema_version notification; }

# ── one-per-Dossier id derivation (the C3 / AD7 structural guarantee) ─────────
# The notification id is DETERMINISTICALLY derived from the dossier id. A
# second emit for the same dossier therefore binds the SAME store record (one
# row), never a per-Item row and never a duplicate — this IS "exactly one
# Notification per Dossier" by construction, not by a count. The dossier id is
# a §0.4 safe key and the `notif.` prefix is safe, so the result is a safe
# store/lock key.
no__notif_id() { printf 'notif.%s' "${1:-}"; }

# ════════════════════════════════════════════════════════════════════════════
# §4.3 — record-shape + §0.3 validation (the terse-by-structure invariant)
# ════════════════════════════════════════════════════════════════════════════
# no__validate <json>
#   Returns 0 iff <json> is a well-formed §4.3 Notification. On any violation:
#   a §-cited diagnostic on stderr + nonzero — the caller MUST NOT persist it.
#
#   §0.3 is enforced HERE: schema_version MUST be an integer EQUAL to the
#   bound version; an unknown HIGHER version is rejected as "unknown higher"
#   (never best-effort-parsed) — the SAME jq type-checked discipline T5.1 and
#   the T4 store use (a string "1"/float/bool cannot slip past).
#
#   The §4.3 field set is CLOSED. `principal` is permitted (a §4.3 field,
#   stamped at the §9.1 chokepoint by the T4 store — never a literal here, so
#   it may be absent at validate-time, before the put). ANY key outside the
#   §4.3 set is REJECTED: a Notification structurally CANNOT carry a body /
#   content field — the §5 dossier body carries the content (principle 2).
no__validate() {
  local json="${1:-}" bound; bound="$(no__bound_sv)"
  if [[ -z "$bound" ]]; then
    echo "notification: reject — 'notification' absent from the T4 §4 registry (co__schema_version) — store-surface contract gap" >&2
    return 2
  fi
  printf '%s' "$json" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "notification: reject — not a JSON object (§4.3)" >&2; return 2; }

  # §0.3 schema_version — integer, type-checked IN jq (mirrors T5.1/T4 §0.3).
  local sv
  sv=$(printf '%s' "$json" | jq -r '
        if (.schema_version|type)=="number"
           and (.schema_version == (.schema_version|floor))
        then .schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "notification: reject — missing integer schema_version (§4.3 'int' / §0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "notification: reject — schema_version $sv is an unknown higher version (bound=$bound; §0.3 reject, never best-effort-parse)" >&2
    return 3
  fi
  if [[ "$sv" -ne "$bound" ]]; then
    echo "notification: reject — schema_version $sv unsupported (binds v$bound only; §0.3)" >&2
    return 3
  fi

  # §4.3 field shapes. dispatched_at/channel keys MUST be present (string|
  # null) so the C3 creation≠dispatch state is explicit, not inferred from a
  # missing key.
  local errs
  errs=$(printf '%s' "$json" | jq -r '
    [ (if (.id|type)=="string" and (.id|length)>0 then empty else "§4.3 id: non-empty string required" end),
      (if (.dossier_ref|type)=="string" and (.dossier_ref|length)>0 then empty else "§4.3 dossier_ref: non-empty string required (the Dossier it announces; one-per-Dossier)" end),
      (if (.tier|type)=="string" and ((.tier)|IN("blocking","timed-fyi","digest")) then empty else "§4.3 tier: blocking|timed-fyi|digest (mirrors the §4.1 dossier tier)" end),
      (if (.created_at|type)=="string" and (.created_at|length)>0 then empty else "§4.3 created_at: RFC-3339 string required (creation≠dispatch: a row exists before any send — C3)" end),
      (if (.dispatched|type)=="boolean" then empty else "§4.3 dispatched: boolean required (false at creation; fire-and-forget forbidden — C3)" end),
      (if (has("dispatched_at")) and ((.dispatched_at|type)=="string" or (.dispatched_at==null)) then empty else "§4.3 dispatched_at: ts|null (key required)" end),
      (if (has("channel")) and ((.channel|type)=="string" or (.channel==null)) then empty else "§4.3 channel: opaque string|null (key required; later digest rollup needs no schema change — C3)" end)
    ] | .[]' 2>/dev/null) || errs="§4.3 record: unparseable"
  if [[ -n "$errs" ]]; then
    echo "notification: reject — $errs" >&2; return 3
  fi

  # CLOSED §4.3 field set — a Notification NEVER carries content (principle 2:
  # the §5 dossier body carries it). An extra key (body/content/payload/…) is
  # a structural violation of "the notification stays terse" — REJECTED.
  local extra
  extra=$(printf '%s' "$json" | jq -r '
    keys[] | select(. as $k | ["id","schema_version","principal","dossier_ref","tier","created_at","dispatched","dispatched_at","channel"] | index($k) | not)' 2>/dev/null) || extra=""
  if [[ -n "$extra" ]]; then
    echo "notification: reject — key(s) outside the closed §4.3 set: $(printf '%s' "$extra" | tr '\n' ' ')— a Notification carries NO content (the §5 dossier body does — principle 2)" >&2
    return 3
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# SINGLE-WRITER critical section — the structure the C3 latch stands on
# ════════════════════════════════════════════════════════════════════════════
# Both no_emit (create-once: one fork ⇒ one Notification) and no_dispatch
# (dispatched false→true EXACTLY ONCE) are a READ-DECIDE-WRITE of the §4.3
# record. Consuming the T4 store SURFACE for persistence does not give this
# file an atomic compare-and-set across its OWN get→put gap — that gap is
# this file's to close, EXACTLY as T5.1's dossier substrate closes its own
# (dossier.sh: "that gap is the substrate's to close"). It is serialised the
# SAME way (the portable `mkdir` atomic test-and-set the T4 store, the T4
# Lease, and the T5.1 dossier lock all use), keyed on the notification id.
no__lock_dir() {
  local d; d="$(co_store_dir 2>/dev/null)" || d="${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"
  printf '%s/notification-locks' "$d"
}
# no__with_notif_lock <notif_id> <cmd...> — run <cmd...> holding the exclusive
# per-notification lock. Bounded spin (never deadlock the skeleton); released
# on EVERY path (success, reject, error).
no__with_notif_lock() {
  local nid="${1:-}"; shift || true
  do__safe_key "$nid" || { echo "notification: unsafe notification id '$nid' ([A-Za-z0-9._-], no '..')" >&2; return 2; }
  local ld; ld="$(no__lock_dir)"; mkdir -p "$ld" 2>/dev/null || true
  local lockd="$ld/.lock.$nid" i=0
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
# §4.3 READ — §0.3 bound on the read path too
# ════════════════════════════════════════════════════════════════════════════
# no_get <bearer> <notif_id>
#   Fetch via `co_request <bearer> get notification <id>`, then BIND §0.3 on
#   the READ path (reject an unknown-higher stored version rather than
#   best-effort-parse it — the SAME defense do_dossier_get adds for the
#   dossier). Echoes the §0.3-checked record; nonzero if absent or rejected.
no_get() {
  local bearer="${1:-}" nid="${2:-}" raw bound sv
  raw="$(co_request "$bearer" get notification "$nid" 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  bound="$(no__bound_sv)"
  sv=$(printf '%s' "$raw" | jq -r '
        if (.schema_version|type)=="number"
           and (.schema_version == (.schema_version|floor))
        then .schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "notification: reject (read) — stored record missing integer schema_version (§0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "notification: reject (read) — schema_version $sv is an unknown higher version (bound=$bound; §0.3, never best-effort-parse)" >&2; return 3
  fi
  printf '%s' "$raw"
}

# no_get_for_dossier <bearer> <dossier_id> — the one Notification announcing
# <dossier_id> (id derived deterministically — one-per-Dossier). Read-only.
no_get_for_dossier() {
  no_get "${1:-}" "$(no__notif_id "${2:-}")"
}

# ════════════════════════════════════════════════════════════════════════════
# §4.3 EMIT — the C3 creation seam: ONE Notification, dispatched=false
# ════════════════════════════════════════════════════════════════════════════
# no_emit <bearer> <dossier_id>
#   Create the SINGLE §4.3 Notification announcing <dossier_id> (C3; AD7 —
#   NOT one-per-Item). Reads the §4.1 envelope via the T5.1 surface, MIRRORS
#   its `tier` onto the §4.3 record, and persists with `created_at`=now,
#   `dispatched=false`, `dispatched_at=null`, `channel=null` — the row exists
#   BEFORE any send (creation≠dispatch, the C3 seam). It sends NOTHING and
#   flips NO latch.
#
#   ONE-PER-DOSSIER + idempotency: the notification id is derived
#   deterministically from the dossier id, under the single-writer lock:
#     • first emit            ⇒ create + echo the notif id (return 0)
#     • re-emit, SAME dossier ⇒ idempotent success: created_at and the
#       dispatch latch are NEVER reset (one fork ⇒ one Notification already
#       holds — NOT a second row, NOT a re-creation)
#     • a notif id already bound to a DIFFERENT dossier ⇒ REJECTED (defensive;
#       cannot arise from deterministic derivation, but never silently
#       clobbered)
#   items[] is NEVER iterated — a 15-item dossier yields exactly ONE row.
#
#   Echoes the notification id on success.
no_emit() {
  no__with_notif_lock "$(no__notif_id "${2:-}")" no__emit_locked "$@"
}
no__emit_locked() {
  local bearer="${1:-}" did="${2:-}" rec tier nid existing erc now out
  [[ -n "$did" ]] || { echo "notification: emit — need <dossier_id> (§4.3 dossier_ref)" >&2; return 2; }

  # Read the §4.1 envelope via the T5.1 surface. §9.1 collapses 401/absent
  # (no second auth path — C4): a missing OR unauthorized dossier is one
  # rejection. The single Notification mirrors the §4.1 tier read off HERE;
  # the tier is NEVER recomputed (that is T5.1's, §4.1).
  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "notification: emit — dossier '$did' not found OR not authorized (§9.1 chokepoint collapses 401/absent; no second auth path — C4)" >&2; return 1; }
  tier=$(printf '%s' "$rec" | jq -r '.tier // ""' 2>/dev/null) || tier=""
  if [[ -z "$tier" ]]; then
    echo "notification: emit — dossier '$did' has no §4.1 tier (the single Notification mirrors it — C3)" >&2; return 3
  fi

  nid="$(no__notif_id "$did")"

  # One-per-Dossier: if the row already exists for THIS dossier, idempotent
  # success — created_at and the dispatch latch are NEVER reset (re-emit is
  # not a re-creation; one fork ⇒ one Notification). A different dossier_ref
  # under the same id is a collision — REJECTED, never clobbered.
  #
  # §0.3 read-rc DISCRIMINATION: no_get returns 1 = truly ABSENT (safe to
  # create), 3 = a row EXISTS but is unknown-higher / unreadable under the
  # bound schema. Collapsing those would let the create path SILENTLY CLOBBER
  # a forward-version row (destroying it + resetting created_at/the latch) —
  # the exact "never best-effort-parse, never silently destroy an
  # unknown-higher record" violation §0.3 forbids. Only rc 1 ⇒ create; any
  # other nonzero ⇒ a row exists we must NOT overwrite.
  existing="$(no_get "$bearer" "$nid" 2>/dev/null)"; erc=$?
  if [[ "$erc" -eq 0 && -n "$existing" ]]; then
    local ebound; ebound=$(printf '%s' "$existing" | jq -r '.dossier_ref // ""' 2>/dev/null) || ebound=""
    if [[ "$ebound" == "$did" ]]; then
      printf '%s' "$nid"; return 0
    fi
    echo "notification: emit REJECTED — notification '$nid' already bound to dossier '$ebound' (one Notification per Dossier; NOT clobbered — §4.3/C3)" >&2
    return 2
  elif [[ "$erc" -ne 1 ]]; then
    echo "notification: emit REJECTED — a stored Notification '$nid' exists but is not readable under the bound schema (§0.3 unknown-higher/malformed); NOT clobbered (never best-effort-parse, never silently destroy a forward-version record)" >&2
    return 3
  fi

  # Create the §4.3 row: created_at set, dispatched=false, dispatched_at=null,
  # channel=null — BEFORE any send (the C3 creation≠dispatch seam). principal
  # is NOT stamped here (no second auth path; the T4 store stamps the §9.1
  # resolved principal — C7). The record carries ONLY §4.3 fields (terse by
  # structure — principle 2).
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  out=$(jq -cn --arg id "$nid" --argjson sv "$(no__bound_sv)" \
        --arg dref "$did" --arg tier "$tier" --arg at "$now" '
        { id:$id, schema_version:$sv, dossier_ref:$dref, tier:$tier,
          created_at:$at, dispatched:false, dispatched_at:null,
          channel:null }' 2>/dev/null) || out=""
  [[ -n "$out" ]] || { echo "notification: emit — could not assemble the §4.3 record" >&2; return 3; }
  no__validate "$out" || return $?

  # Persist via the T4 front door (re-enforces §0.3; stamps `principal` at the
  # ONE §9.1 chokepoint — no second auth path, never a literal here — C7).
  co_request "$bearer" put notification "$nid" "$out" >/dev/null || return $?
  printf '%s' "$nid"
}

# no_for_generation <bearer> <generation_input_json>
#   The C3 creation hook: consume the T5.2 §5 sole-producer `dg_generate`
#   (ONE structured generation → the §4.1/§5 dossier, persisted via T5.1),
#   then create the SINGLE §4.3 Notification for the freshly-created dossier.
#   The Notification row therefore exists immediately at dossier creation,
#   BEFORE any send (creation≠dispatch — C3). Echoes the notification id.
#
#   dg_generate is consumed as a black box (its §5/§4.1 schema is T5.2/T5.1's
#   — never re-implemented or inspected here; the Notification cannot carry
#   the body anyway — principle 2). The dossier id is the one dg_generate
#   echoes (the §7.4 dedup layer = T5.5 supplies it upstream).
#
#   C3 RESIDUAL (observable, never silent): if dg_generate PERSISTS the
#   dossier but the subsequent no_emit fails, a dossier exists with NO
#   Notification — the "row exists at creation, before any send" invariant is
#   momentarily unmet. There is no dossier-delete surface here (that is not
#   T5.6's; deleting a T5.1 envelope would touch a sibling surface), so the
#   correct posture is the sibling "observable, not swallowed" discipline
#   (timed-fyi WARN): a LOUD §-cited diagnostic naming the un-announced
#   dossier + a nonzero return, so the operator / the T5.5 reconcile layer
#   can act and a retry is safe (no_emit is idempotent — one-per-Dossier).
no_for_generation() {
  local bearer="${1:-}" gi="${2:-}" did rc nrc
  did="$(dg_generate "$bearer" "$gi")"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "notification: for-generation — T5.2 dg_generate did not produce a dossier (no Notification emitted)" >&2
    return "$rc"
  fi
  [[ -n "$did" ]] || { echo "notification: for-generation — dg_generate produced an empty dossier id" >&2; return 3; }
  no_emit "$bearer" "$did"; nrc=$?
  if [[ "$nrc" -ne 0 ]]; then
    echo "notification: for-generation — WARN dossier '$did' WAS created (T5.2) but no_emit FAILED (rc $nrc): a dossier exists with NO §4.3 Notification — the C3 'row exists at creation' invariant is unmet for '$did'. Observable, NOT silent; no_emit is idempotent (one-per-Dossier) so a retry is safe; T5.5 reconcile/operator can re-emit." >&2
    return "$nrc"
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# §4.3 DISPATCH — the C3 latch: dispatched false→true EXACTLY ONCE
# ════════════════════════════════════════════════════════════════════════════
# no_dispatch <bearer> <notif_id> [channel]
#   Flip <notif_id>'s `dispatched` false→true EXACTLY ONCE and stamp
#   `dispatched_at`; record the OPAQUE `channel` tag verbatim (default: keep
#   null when omitted). This is the ONLY place dispatched/dispatched_at flip
#   (creation≠dispatch — C3).
#
#   fire-and-forget is FORBIDDEN (C3): if NO row exists, REJECT — a
#   Notification row MUST precede any send (`no_emit` it first). A SECOND
#   dispatch (latch already true) is REJECTED (single-writer-set; false→true
#   ONCE — the SAME structure as the T5.1 per-Item consequence latch). NO
#   write on either rejection.
#
#   `channel` is an OPAQUE transport tag: stored verbatim, NEVER interpreted.
#   The actual transport MECHANISM is C3-DEFERRED (out of v1 scope) — this
#   flips the latch and records the tag; it sends nothing. A later read-side
#   digest rollup keys off this tag with NO schema change (C3).
no_dispatch() {
  no__with_notif_lock "${2:-}" no__dispatch_locked "$@"
}
no__dispatch_locked() {
  local bearer="${1:-}" nid="${2:-}" channel="${3:-}" rec rrc already upd now
  [[ -n "$nid" ]] || { echo "notification: dispatch — need <notif_id> (§4.3)" >&2; return 2; }

  # fire-and-forget FORBIDDEN: the row MUST exist (creation≠dispatch — C3).
  # §0.3 read-rc DISCRIMINATION (same as no_emit): no_get rc 1 = truly ABSENT
  # ⇒ the genuine fire-and-forget rejection; rc 3 = a row EXISTS but is
  # unknown-higher / unreadable under the bound schema ⇒ a §0.3 rejection, NOT
  # "no row" (mis-reporting it as absent would invite a clobbering no_emit).
  rec="$(no_get "$bearer" "$nid" 2>/dev/null)"; rrc=$?
  if [[ "$rrc" -eq 1 ]]; then
    echo "notification: dispatch REJECTED — no Notification '$nid' exists; fire-and-forget is forbidden — a row MUST precede any send (creation≠dispatch — C3). no_emit it first." >&2
    return 1
  elif [[ "$rrc" -ne 0 ]]; then
    echo "notification: dispatch REJECTED — stored Notification '$nid' is not readable under the bound schema (§0.3 unknown-higher/malformed); NOT dispatched (never best-effort-parse a forward-version record)" >&2
    return 3
  fi

  already=$(printf '%s' "$rec" | jq -r '.dispatched' 2>/dev/null) || already=""
  if [[ "$already" == "true" ]]; then
    echo "notification: dispatch REJECTED — '$nid' already dispatched (single-writer-set; dispatched flips false→true ONCE — C3)" >&2
    return 2
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  # channel: opaque, stored verbatim; null when the caller omits it.
  if [[ -n "$channel" ]]; then
    upd=$(printf '%s' "$rec" | jq -c --arg at "$now" --arg ch "$channel" \
            '.dispatched=true | .dispatched_at=$at | .channel=$ch' 2>/dev/null) || upd=""
  else
    upd=$(printf '%s' "$rec" | jq -c --arg at "$now" \
            '.dispatched=true | .dispatched_at=$at' 2>/dev/null) || upd=""
  fi
  [[ -n "$upd" ]] || { echo "notification: dispatch — could not set the dispatched latch" >&2; return 3; }
  no__validate "$upd" || return $?
  co_request "$bearer" put notification "$nid" "$upd" >/dev/null || return $?
  return 0
}

# no_dispatch_for_dossier <bearer> <dossier_id> [channel] — dispatch the one
# Notification announcing <dossier_id> (id derived — one-per-Dossier).
no_dispatch_for_dossier() {
  no_dispatch "${1:-}" "$(no__notif_id "${2:-}")" "${3:-}"
}

# ════════════════════════════════════════════════════════════════════════════
# K3 (claude-tools-uxvk3) — the always-FYI DIGEST ROLLUP (read-side, shared
# with N1). NO schema change: the §4.3 `channel` field ALREADY exists (the
# `channel` clause in no__validate + the closed §4.3 set above) and is the only
# thing the rollup keys off — "a later read-side digest rollup keys off this
# tag with NO schema change (C3)" (no_dispatch comment). This is a pure READ:
# it enumerates the §4.3 notification records and groups DIGEST-ELIGIBLE ones
# by `channel`. It adds NO §4 record type, edits NO registry, touches NO write
# path. K3 OWNS the cross-WS `xws:` channel convention + the rollup copy; the
# ENGINE (no__group_digests) is channel-agnostic so N1 reuses it verbatim.
#
# TIER DISCIPLINE (D.2 — the whole point): ONLY `timed-fyi`/`digest`-tier
# notifications roll up. A `blocking` notification is NEVER swept into a digest
# (mechanical sync → batched FYI; real conflict → an immediate decision). A
# `channel=null` record is likewise excluded (no group to join).
# ════════════════════════════════════════════════════════════════════════════

# [free] K3 defaults (named constants, cross-ws.md §9 "deliberately free").
# Digest CADENCE is daily (UX-DESIGN-V2 §8.2 / ARCH §14.4 "assumed daily").
NO_DIGEST_CADENCE="${NO_DIGEST_CADENCE:-daily}"
# CHANNEL GRANULARITY for cross-WS: `xws:<project_ref>` (the coarser §4.2
# option); finer `xws:<from>:<to>` is [free] — a caller may pass a finer
# channel verbatim and the engine groups on whatever opaque string is stored.
NO__XWS_PREFIX="xws:"

# no__xws_channel <project_ref> — the cross-WS channel convention (K3-OWNED):
# "xws:<project_ref>", the opaque `channel` tag a cross-WS exchange stamps on
# its timed-fyi notification so the rollup groups its syncs into ONE digest
# entry. 1:1 with JS `xwsChannel`.
no__xws_channel() { printf '%s%s' "$NO__XWS_PREFIX" "${1:-}"; }

# no__digest_copy <channel> <count> — the K3-OWNED rollup summary copy: the
# "BE↔FE: N syncs — all resolved, none needed you." one-liner for a digest
# group. The cross-WS phrasing applies to `xws:`-prefixed channels; any other
# channel degrades to a generic "<channel>: N updates" line (channel-agnostic
# engine — N1's non-xws channels still get an honest summary). 1:1 with JS
# `digestCopy`. NEVER carries dossier content (the digest is the SUMMARY; the
# relay-log-tail/dossier is the detail behind it — principle 2).
no__digest_copy() {
  local ch="${1:-}" n="${2:-0}" noun ref gnoun
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if [[ "$n" -eq 1 ]]; then noun="sync"; else noun="syncs"; fi
  if [[ "$ch" == "$NO__XWS_PREFIX"* ]]; then
    ref="${ch#"$NO__XWS_PREFIX"}"
    printf '%s: %s %s — all resolved, none needed you.' "$ref" "$n" "$noun"
    return 0
  fi
  if [[ "$n" -eq 1 ]]; then gnoun="update"; else gnoun="updates"; fi
  printf '%s: %s %s.' "$ch" "$n" "$gnoun"
}

# no__group_digests [channel_prefix]  (reads §4.3 records on stdin, one JSON
# per line) — the GENERIC rollup ENGINE (channel-agnostic — N1 reuses it).
# Group DIGEST-ELIGIBLE notification records by `channel` into one entry per
# channel. DIGEST-ELIGIBLE = tier ∈ {timed-fyi, digest} (EXCLUDE blocking —
# never rolled up) AND a non-null, non-empty `channel`. Optional <channel_prefix>
# filters to channels starting with it (e.g. "xws:" for cross-WS only),
# mirroring relay-log-tail's optional filter. Deterministic order: channel asc,
# then id asc within `dossier_refs`. Emits ONE JSON object:
#   { "digests": [ { channel, count, tier, dossier_refs:[...] } ] }
# `tier` reports "digest" if a channel mixes both tiers (the broader bucket);
# `dossier_refs` is a list of REFS (UI expands via relay-log-tail/dossier) —
# NEVER content (principle 2).
no__group_digests() {
  local prefix="${1:-}"
  jq -cs --arg prefix "$prefix" '
    [ .[]
      | select(type=="object")
      | select((.tier|type)=="string" and (.tier|IN("timed-fyi","digest")))
      | select((.channel|type)=="string" and (.channel|length)>0)
      | select(($prefix|length)==0 or (.channel|startswith($prefix)))
    ]
    | group_by(.channel)
    | map({
        channel: (.[0].channel),
        count: (length),
        tier: (if any(.[]; .tier=="digest") then "digest" else "timed-fyi" end),
        dossier_refs: (
          [ .[] | { id: ((.id // "")|tostring), ref: ((.dossier_ref // "")|tostring) } ]
          | sort_by(.id, .ref)
          | map(.ref)
          | map(select(.!=""))
        )
      })
    | sort_by(.channel)
    | { digests: . }'
}

# no_digest <bearer> [channel_prefix] — the read-side rollup op. Enumerate
# every §4.3 notification record from the §4 store (mirroring NCOUNT's store
# layout: records/notification.*.json), read each under the §0.3-bound read
# path (no_get rejects unknown-higher/unreadable rows; those are SKIPPED, never
# best-effort-parsed), and feed the readable records to the channel-agnostic
# no__group_digests engine. Pure READ — no lock, no write. Echoes the
# { "digests":[...] } projection. <channel_prefix> (optional) scopes to e.g.
# "xws:" for cross-WS only.
no_digest() {
  local bearer="${1:-}" prefix="${2:-}" store f rec
  store="$(co_store_dir 2>/dev/null)" || store="${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"
  {
    for f in "$store"/records/notification.*.json; do
      [[ -e "$f" ]] || continue
      # derive the notif id from the filename (records/notification.<id>.json),
      # then read THROUGH the §0.3-bound read path so an unknown-higher /
      # unreadable row is skipped (never best-effort-parsed — §0.3).
      local base nid
      base="${f##*/}"; base="${base%.json}"; nid="${base#notification.}"
      rec="$(no_get "$bearer" "$nid" 2>/dev/null)" || continue
      [[ -n "$rec" ]] || continue
      printf '%s\n' "$rec"
    done
  } | no__group_digests "$prefix"
}
