# shellcheck shell=bash
# beads-runner/lib/coordinator.sh — the hosted Coordinator SKELETON
# (T4.1, claude-tools-ick). The foundation child of T4 (claude-tools-cbv);
# every other T4 child binds onto the substrate this file stands up.
#
# WHAT THIS IS (DESIGN §2 "Coordinator" row; AD1; epic claude-tools-glk):
#   The global serialization & decision authority (hosted, strong). This file
#   is the SUBSTRATE ONLY: the hosted shell + the four §2 capabilities reachable
#   as surfaces + the ONE §9.1 auth→principal chokepoint + the §4 record store.
#   It deliberately contains NO arbitration, NO aggregation, NO reconcile
#   semantics, NO dossier production — those are siblings (see ANTI-DRIFT).
#
# BINDS — INTERFACE.md v1 (FROZEN), the sections this file OWNS per §11:
#   §2.1  — small strongly-consistent store: persist the §4 records with
#           strong consistency for Lease + per-Item single-writer (the store
#           serialises every write per (type,id) key).
#   §2.2  — durable one-shot timer CAPABILITY SURFACE ONLY: fire(id)@T plus the
#           S-6 'missed fire ⇒ degrade to fire-on-next-poll' contract. The
#           Dossier-specific fire(dossier_id) wiring + the per-Item idempotency
#           latch are T5 — NOT here (see ANTI-DRIFT).
#   §2.3  — authed request endpoint, and §9.1 the ONE
#           authenticate(request)→principal chokepoint: validate a bearer
#           token's presence/validity, resolve the constant
#           principal=PRINCIPAL_V1. No second auth path; no UI-vs-agent split
#           (C4 seam). Every §4 write happens AFTER this step (no/invalid
#           token ⇒ rejected BEFORE any write).
#   §2.4  — deliver-desired-state-on-reconnect TRANSPORT: a poll returns the
#           stored RunnerState.desired + any stored lease state. Reconciliation
#           (desired-state mutation), not a durable command queue. The
#           reconcile SEMANTICS + liveness derivation are T4.3, NOT here.
#   §4    — STORE OWNER: schema persistence; §0.3 reject-unknown-higher
#           schema_version; §9.1 principal-stamp on EVERY record (the resolved
#           principal, never a hardcoded literal at the use site — C7).
#   §9.1  — the chokepoint + the C4 seam captured-not-enforced: a
#           RunnerState.desired change records last_desired_actor and is
#           authorised through this ONE step with ALL actors treated equally.
#           The §0.C-deferred downgrade/promote asymmetry is NOT enforced (no
#           `if` on actor anywhere below).
#
# ANTI-DRIFT — MUST NOT TOUCH sibling surfaces (binds to INTERFACE.md v1):
#   • lease ARBITRATION / generation fencing (§6.1/§4.4 acquire/renew/release
#     precedence, the monotonic fencing token logic) — T4.2 (claude-tools-am8).
#     This file only PERSISTS a Lease *record* like any other §4 record; it
#     never arbitrates one.
#   • capacity aggregation (§6.3/§6.2 capacity, ask-capacity) — T4.4.
#   • RunnerState reconcile SEMANTICS + work-snapshot PROJECTION + S-1 liveness
#     derivation (§4.2/§4.5/§2.4-semantics) — T4.3 (claude-tools-l9o). This
#     file captures `desired`/`last_desired_actor` and round-trips the §4.5
#     envelope; it derives NO `liveness`, runs NO desired↔actual reconcile.
#   • forensic transient store (§10.3) — T4.5.
#   • Dossier §5 body+items production + §2.2 fire(dossier_id) + per-Item latch
#     (§4.1/§4.1.1/§5/§7.4) — T5. The store round-trips a Dossier *envelope*;
#     it never GENERATES body/items and never implements the per-Item latch.
#   • §4.5 projection RENDERING — T6a.
#   Consumes T3's §1.1 UPWARD contract verbatim (the Local Agent reports up;
#   this file is the down/serialisation side — it never reads a Keychain or a
#   usage API, §1.1).
#
# PROVIDER-AGNOSTIC (§0.2, swappability guardrail). No Cloudflare primitive
# appears in any surface below. The Cloudflare realisation is non-normative
# (INTERFACE.md Appendix A) — see the APPENDIX-A map at the foot of this file.
# The skeleton realises the store on the local filesystem; a provider swap
# changes only the co__store_* / co__timer_* internals, never a signature.
#
# Safe to `source` under `set -euo pipefail`: only function/constant
# definitions below; every fallible call is guarded. Frozen numeric constants
# are env-overridable lookups whose literal default EQUALS the INTERFACE.md
# §0.5 table value (never a competing normative value).

# ── §0.5 frozen constants (single normative definition is INTERFACE.md §0.5;
#    these are env-overridable lookups defaulting to the frozen value) ─────────
co__PRINCIPAL_V1() { echo "${PRINCIPAL_V1:-brian}"; }   # §0.5 PRINCIPAL_V1
# §0.5 FORENSIC_BLOB_TTL (3600 s) — the §10.3 redacted-blob hard-delete
# deadline. Env-overridable lookup whose literal default EQUALS the frozen
# §0.5 table value (single normative definition is INTERFACE.md §0.5; this is
# NOT a competing normative value). T4.5 uses this surface, so — unlike
# LEASE_TTL — it is defined here, mirroring local-agent.sh's "define the
# §0.5 lookup for the surfaces you actually use" anti-drift discipline.
co__FORENSIC_BLOB_TTL() { echo "${FORENSIC_BLOB_TTL:-3600}"; }   # §0.5
# §0.5 USAGE_THRESHOLD (70 %, `0` disables) — the hard 5h/7d ceiling gate.
# T4.4 (claude-tools-d7x) owns §6.3 coordinator-side `ask-capacity`, whose
# EXIT criterion 2 requires USAGE_THRESHOLD=0 to disable the ceiling GLOBALLY
# (the same gate-disable semantic the Local Agent applies, §6.3 / la_capacity_
# check threshold-0 early return — NOT a re-measurement). A REAL use site (not
# a dead lookup) ⇒ defined here, mirroring co__FORENSIC_BLOB_TTL's discipline.
# Single normative definition is INTERFACE.md §0.5; this is an env-overridable
# lookup whose literal default EQUALS the frozen table value, NEVER a competing
# normative value.
# (§0.5 USAGE_CACHE_SECONDS and SPARE_RAMP_PER_DAY are deliberately NOT defined
#  here: the usage-poll TTL cache AND the spare-cycles MEASUREMENT are the
#  Local Agent's — T3, §6.3 local. This tier ONLY aggregates the reported
#  coarse verdict, NEVER measures (task MUST-NOT-TOUCH), so it has no use site
#  for either; a dead lookup would falsely imply this file measures the ramp —
#  anti-drift.)
co__USAGE_THRESHOLD() { echo "${USAGE_THRESHOLD:-70}"; }   # §0.5 (0 disables)
# (§0.5 LEASE_TTL is deliberately NOT defined here: this skeleton persists a
#  Lease *record* but never arbitrates one, so it has no LEASE_TTL use site.
#  T4.2 — claude-tools-am8 — owns lease arbitration and defines its own
#  env-overridable §0.5 LEASE_TTL lookup, the way local-agent.sh does for the
#  surfaces it actually uses. A dead lookup here would falsely imply lease TTL
#  is handled in this file — anti-drift.)

# ── store location ───────────────────────────────────────────────────────────
# The Coordinator is HOSTED (Appendix A: a Durable Object's state + D1). The
# skeleton realises that strongly-consistent store on the local filesystem.
# Default is a machine-scratch path — NEVER a committable repo path (the store
# is hosted control-plane state, not work-truth: Dolt stays work-truth, no
# plane-split). CO_STORE overrides it (the test points it at an mktemp dir).
co_store_dir() { printf '%s' "${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"; }

co__ensure_store() {
  local d; d="$(co_store_dir)"
  # `forensic/` is a SEPARATE namespace from `records/` (§4 store) and
  # `timers/` (§2.2): the §10.3 redacted blob is a transient encrypted object,
  # NOT a §4 record — it is never in the §4.5 projection (anti-drift, T4.3/T6a).
  mkdir -p "$d/records" "$d/timers" "$d/forensic" 2>/dev/null || true
  printf '%s' "$d"
}

# ── §4 record-type registry & schema versions ────────────────────────────────
# Every §4 record type binds to ONE schema_version (all `1` in INTERFACE.md
# v1). A consumer binds to a schema version and MUST reject an unknown HIGHER
# version rather than best-effort-parse it (§0.3). Adding a type or bumping a
# version is the §0/§11 freeze-escalation protocol, never a local edit.
co__schema_version() {
  case "$1" in
    dossier)       echo 1 ;;   # §4.1 Dossier envelope (body/items prod = T5)
    runner_state)  echo 1 ;;   # §4.2 RunnerState
    notification)  echo 1 ;;   # §4.3 Notification
    lease)         echo 1 ;;   # §4.4 Lease (arbitration = T4.2)
    work_snapshot) echo 1 ;;   # §4.5 work-snapshot (projection render = T6a)
    *)             echo "" ;;  # unknown type
  esac
}

# ── strong consistency primitive (§2.1) ──────────────────────────────────────
# A per-key advisory lock so every write to a given (type,id) is serialised —
# this is the single-writer-per-key semantics §2.1 requires for Lease and for
# each Dossier Item's application. `mkdir` is the atomic test-and-set (portable;
# no flock on macOS). Best-effort bounded spin; the skeleton is single-host.
co__with_lock() {
  local key="$1"; shift
  local lockd; lockd="$(co__ensure_store)/.lock.$key"
  local i=0
  until mkdir "$lockd" 2>/dev/null; do
    i=$((i+1)); [[ $i -ge 200 ]] && break    # ~bounded; never deadlock the skeleton
    sleep 0.01 2>/dev/null || true
  done
  local rc=0
  "$@" || rc=$?
  rmdir "$lockd" 2>/dev/null || true
  return "$rc"
}

# co__safe_key — a record/timer id (and the lock key derived from it) reaches
# the store through the §2.3 front door. As the §2.1 store owner this file
# rejects an id that is not a safe key BEFORE taking the lock or building a
# path: no `/` (path traversal), no `..` segment, only [A-Za-z0-9._-]. The
# hosted realisation (a DO/D1 key, Appendix A) has no filesystem shape, so this
# is skeleton input hygiene, not a leaked provider concern.
co__safe_key() {
  local k="${1:-}"
  [[ -n "$k" ]] || return 1
  [[ "$k" == *".."* ]] && return 1
  [[ "$k" =~ ^[A-Za-z0-9._-]+$ ]]
}

co__rec_path() { printf '%s/records/%s.%s.json' "$(co__ensure_store)" "$1" "$2"; }

# ── §2.1 / §4 STORE OWNER — put/get with §0.3 + §9.1 enforcement ──────────────
# co__store_put <principal> <type> <id> <json>
#   Persists a §4 record. Enforces, in order:
#     1. known record type (§4 registry);
#     2. §0.3 — the record's schema_version MUST equal the bound version; an
#        unknown HIGHER version is REJECTED (never best-effort-parsed), and the
#        skeleton knows only v1 so any other value is unsupported → reject;
#     3. §9.1 — STAMP `principal` with the RESOLVED principal passed down from
#        the chokepoint (the caller never supplies a literal that is trusted;
#        whatever `principal` the json carried is overwritten). Every persisted
#        §4 record therefore carries principal = the resolved principal.
#   Writes atomically (temp + mv) under the per-key lock. Returns nonzero and
#   writes NOTHING on any rejection.
# NOTE (anti-drift): this round-trips whatever §4-shaped envelope it is given.
#   It does NOT generate Dossier body/items (T5), derive liveness or run a
#   reconcile (T4.3), arbitrate a Lease (T4.2), or aggregate capacity (T4.4).
co__store_put() {
  local principal="$1" type="$2" id="$3" json="$4"
  local bound; bound="$(co__schema_version "$type")"
  if [[ -z "$bound" ]]; then
    echo "co: reject — unknown §4 record type '$type'" >&2; return 2
  fi
  if ! co__safe_key "$id"; then
    echo "co: reject — unsafe record id '$id' (allowed [A-Za-z0-9._-], no '..'; store-owner input hygiene)" >&2
    return 2
  fi
  # §4 mandates `schema_version : int`; §0.3 binds the consumer to that integer
  # version. The type-check is done IN jq so a JSON *string* `"1"`, a float, or
  # a bool is rejected (a `jq -r` of "1" would otherwise flatten to the bare
  # text 1 and slip past a shell numeric test). Must be a number equal to its
  # own floor — i.e. a true integer.
  local sv
  sv=$(printf '%s' "$json" | jq -r '
        if type=="object"
           and (.schema_version|type)=="number"
           and (.schema_version == (.schema_version|floor))
        then .schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "co: reject — $type record missing integer schema_version (§4 'int' / §0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "co: reject — $type schema_version $sv is an unknown higher version (bound=$bound; §0.3 reject, never best-effort-parse)" >&2
    return 3
  fi
  if [[ "$sv" -ne "$bound" ]]; then
    echo "co: reject — $type schema_version $sv unsupported (skeleton binds v$bound only; §0.3)" >&2
    return 3
  fi
  # §9.1 stamp: the RESOLVED principal, overwriting anything the caller put.
  local stamped
  stamped=$(printf '%s' "$json" | jq -c --arg p "$principal" '.principal=$p' 2>/dev/null) || {
    echo "co: reject — $type record is not valid JSON" >&2; return 3
  }
  co__with_lock "$type.$id" co__store_write "$type" "$id" "$stamped"
}

co__store_write() {
  local type="$1" id="$2" json="$3" path tmp
  path="$(co__rec_path "$type" "$id")"
  tmp="$path.$$.tmp"
  printf '%s\n' "$json" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 4; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 4; }
  return 0
}

# co__store_get <type> <id> — echo the stored record JSON, or return 1.
co__store_get() {
  local type="$1" id="$2" path
  path="$(co__rec_path "$type" "$id")"
  [[ -f "$path" ]] || return 1
  cat "$path" 2>/dev/null || return 1
}

# ── §2.2 durable one-shot timer — CAPABILITY SURFACE ONLY ─────────────────────
# fire(id)@T plus the S-6 backstop: a missed fire MUST degrade to
# fire-on-next-poll. The skeleton has no alarm daemon (capability surface
# only); `co__timer_due` IS the poll-fallback — an armed timer whose time has
# passed and that has not been acked is surfaced on every poll, so a missed
# alarm never strands. `co__timer_ack` lets a consumer record consumption.
#
# ANTI-DRIFT: `timer_id` is OPAQUE here. The Dossier-specific fire(dossier_id)
# wiring AND the per-Item idempotency latch that makes alarm-fire vs
# poll-fallback apply a consequence EXACTLY ONCE are T5 (§4.1/§5/§7.4). This
# file provides only the generic surface (arm / due / ack); it implements no
# dossier semantics and no exactly-once latch.
co__timer_path() { printf '%s/timers/%s.json' "$(co__ensure_store)" "$1"; }

# co__timer_arm <timer_id> <fire_at_rfc3339>
co__timer_arm() {
  local tid="$1" fire_at="$2" p tmp now
  [[ -n "$tid" && -n "$fire_at" ]] || { echo "co: timer_arm needs <id> <fire_at>" >&2; return 2; }
  co__safe_key "$tid" || { echo "co: reject — unsafe timer id '$tid' (allowed [A-Za-z0-9._-], no '..')" >&2; return 2; }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  p="$(co__timer_path "$tid")"; tmp="$p.$$.tmp"
  jq -cn --arg id "$tid" --arg fa "$fire_at" --arg at "$now" \
     '{timer_id:$id,fire_at:$fa,armed_at:$at,acked:false}' > "$tmp" 2>/dev/null \
     || { rm -f "$tmp" 2>/dev/null; return 3; }
  mv -f "$tmp" "$p" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 3; }
  return 0
}

# co__timer_due [now_rfc3339] — print the timer_id of every armed, un-acked
# timer whose fire_at ≤ now. This is the S-6 poll-fallback: it surfaces a
# missed fire on the NEXT poll, deterministically, with no alarm daemon.
co__timer_due() {
  local now="${1:-}" d
  [[ -n "$now" ]] || now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  d="$(co__ensure_store)/timers"
  [[ -d "$d" ]] || return 0
  local f
  for f in "$d"/*.json; do
    [[ -e "$f" ]] || continue
    jq -r --arg now "$now" \
       'if (.acked|not) and (.fire_at <= $now) then .timer_id else empty end' \
       "$f" 2>/dev/null || true
  done
}

# co__timer_ack <timer_id> — mark consumed so the poll-fallback stops
# re-surfacing it. (The exactly-once *latch* keyed on the Item id is T5; this
# is only the ack surface a consumer builds that latch on.)
co__timer_ack() {
  local tid="$1" p tmp
  [[ -n "$tid" ]] || return 2
  co__safe_key "$tid" || { echo "co: reject — unsafe timer id '$tid'" >&2; return 2; }
  p="$(co__timer_path "$tid")"; [[ -f "$p" ]] || return 1
  tmp="$p.$$.tmp"
  jq -c '.acked=true' "$p" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 3; }
  mv -f "$tmp" "$p" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 3; }
  return 0
}

# ── §9.1 THE ONE authenticate(request) → principal chokepoint ────────────────
# Every inbound control-plane request passes through EXACTLY this one step
# (UI or agent — NO split, C4). v1 validates a bearer token's
# presence/validity and resolves the CONSTANT principal = PRINCIPAL_V1
# (AD6 single-user; C7: later = mint real tokens + stop returning the constant,
# no schema change). "Validity" in v1: the token must be present (non-empty);
# if CO_EXPECTED_TOKEN is set, it must equal it (lets a caller/test drive the
# invalid-token path). The per-runner bearer SECRET itself lives in the Local
# Agent's Keychain (§9.2 — that is T3, not this file).
#
# On success: echoes the resolved principal, returns 0.
# On missing/invalid: echoes NOTHING, returns 1 — the caller MUST reject the
# request BEFORE any §4 write (enforced structurally by co_request below).
co_authenticate() {
  local bearer="${1:-}"
  [[ -n "$bearer" ]] || { return 1; }
  if [[ -n "${CO_EXPECTED_TOKEN:-}" && "$bearer" != "${CO_EXPECTED_TOKEN}" ]]; then
    return 1
  fi
  printf '%s' "$(co__PRINCIPAL_V1)"
  return 0
}

# ── §2.3 the authed request endpoint (the single front door) ─────────────────
# co_request <bearer_token> <op> [args...]
#   THE control-plane entrypoint. It calls the §9.1 chokepoint EXACTLY ONCE at
#   the top; on auth failure it returns 1 having performed NO §4 write (EXIT
#   crit 2 — rejected BEFORE any write). On success it dispatches the op with
#   the RESOLVED principal threaded down to the store stamp (§9.1 — downstream
#   binds to the resolved principal, never a literal at the use site).
#   There is NO second auth path and NO UI-vs-agent branch (C4 seam).
#
#   ops:
#     put  <type> <id> <json>          → §2.1/§4 persist a §4 record
#     get  <type> <id>                 → §2.1/§4 read a §4 record
#     set-desired <proj> <state> <actor>
#                                      → §9.1 C4 seam: capture a desired change
#     poll <proj> [lease_id]           → §2.4 deliver desired + lease state
#     timer-arm <id> <fire_at>         → §2.2 arm one-shot
#     timer-due [now]                  → §2.2 S-6 poll-fallback
#     timer-ack <id>                   → §2.2 mark consumed
#     forensic-put <id> <dossier> <redacted_json>
#                                      → §10.3 store the redacted blob
#                                        ENCRYPTED (ciphertext only)
#     forensic-fetch <id>              → §10.3 explicit authed on-demand pull
#                                        (the ONE controlled sync crossing)
#     forensic-dismiss <id>            → §10.3 "done with forensic" ⇒ hard-delete
#     forensic-sweep [now_epoch]       → §10.3 TTL poll-fallback hard-delete
#     forensic-audit [n]               → §10.3 content-free deletion audit log
#     report-capacity <report_json>    → §1.1 ingest the upward coarse
#                                        capacity report (T3 shape, verbatim)
#     ask-capacity <cost_class>        → §6.3 aggregated verdict ok|over
#                                        (rc 0=ok, 1=over)
#   The forensic-* and capacity ops cross the §2.3 authed channel like every
#   other op (§10.3 / §1.1 "transport is the §2.3 authed channel"); they are
#   NOT one of the four §2 capabilities (those stay exactly four —
#   co_capabilities, T4.1). §6.2's Coordinator-unreachable FAIL-OPEN posture
#   is the co_ask_capacity wrapper (no front door exists when unreachable).
co_request() {
  local bearer="${1:-}" op="${2:-}"; shift 2 2>/dev/null || true
  local principal
  if ! principal="$(co_authenticate "$bearer")" || [[ -z "$principal" ]]; then
    echo "co: 401 — bearer token missing/invalid; request rejected (NO §4 write; §9.1/§2.3)" >&2
    return 1
  fi
  # Defaulted expansions: this file is sourced under `set -euo pipefail`, so a
  # caller that omits a trailing arg must NOT trip `set -u` here — the op
  # handler validates arity and returns its own diagnostic instead.
  case "$op" in
    put)         co__store_put "$principal" "${1:-}" "${2:-}" "${3:-}" ;;
    get)         co__store_get "${1:-}" "${2:-}" ;;
    set-desired) co__set_desired "$principal" "${1:-}" "${2:-}" "${3:-}" ;;
    poll)        co__poll "$principal" "${1:-}" "${2:-}" ;;
    timer-arm)   co__timer_arm "${1:-}" "${2:-}" ;;
    timer-due)   co__timer_due "${1:-}" ;;
    timer-ack)   co__timer_ack "${1:-}" ;;
    forensic-put)     co__forensic_put "$principal" "${1:-}" "${2:-}" "${3:-}" ;;
    forensic-fetch)   co__forensic_fetch "$principal" "${1:-}" ;;
    forensic-dismiss) co__forensic_dismiss "$principal" "${1:-}" ;;
    forensic-sweep)   co__forensic_sweep "$principal" "${1:-}" ;;
    forensic-audit)   co__forensic_audit_tail "${1:-}" ;;
    report-capacity)  co__capacity_report "$principal" "${1:-}" ;;
    ask-capacity)     co__ask_capacity "${1:-}" ;;
    *)           echo "co: unknown op '$op' (§2 surfaces: put|get|set-desired|poll|timer-arm|timer-due|timer-ack; §10.3: forensic-put|forensic-fetch|forensic-dismiss|forensic-sweep|forensic-audit; §6.3: report-capacity|ask-capacity)" >&2; return 2 ;;
  esac
}

# ── §9.1 C4 seam: captured-not-enforced desired-state actor capture ──────────
# co__set_desired <principal> <project_ref> <desired> <actor>
#   Records a RunnerState.desired change. Per DESIGN C4 / INTERFACE §4.2 &
#   §9.1, v1 MUST capture the actor (`last_desired_actor`) and authorise EVERY
#   actor EQUALLY through the one chokepoint. Observe: there is deliberately NO
#   `if` on `actor` and NO UI-vs-agent code path anywhere here — the
#   downgrade-only-for-agents / promote-only-for-human asymmetry is
#   §0.C-DEFERRED and MUST NOT be enforced in v1 (later = one `if` at the
#   chokepoint, no schema change).
#
# ANTI-DRIFT: this captures `desired` + `last_desired_actor` + `updated_at`
#   ONLY. It does NOT set/derive `actual` or `liveness` and runs NO
#   desired↔actual reconcile — those SEMANTICS are T4.3. It merely persists
#   the §4.2 envelope as the store owner + records the C4-seam actor.
co__set_desired() {
  local principal="$1" proj="$2" desired="$3" actor="$4" now prev base
  [[ -n "$proj" && -n "$desired" ]] || { echo "co: set-desired needs <proj> <state> <actor>" >&2; return 2; }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  prev="$(co__store_get runner_state "$proj" 2>/dev/null)" || prev=""
  # desired-state is Coordinator-owned (§4.2); the merge onto a prior envelope
  # is best-effort, NOT load-bearing. A corrupt/absent prior record MUST NOT
  # wedge the desired-state control path (pause/stop) — fall back to a fresh
  # base so last_desired_actor is still captured (EXIT crit 4), mirroring
  # co__poll's graceful degradation rather than hard-failing.
  if ! printf '%s' "$prev" | jq -e 'type=="object"' >/dev/null 2>&1; then
    prev='{}'
  fi
  # Merge onto the (sanitised) prior envelope; set ONLY the C4-seam + desired
  # fields. Note there is NO branch on $actor — all actors authorised equally.
  base=$(printf '%s' "$prev" | jq -c \
            --argjson sv 1 \
            --arg proj "$proj" \
            --arg d "$desired" \
            --arg a "$actor" \
            --arg at "$now" \
            '. + {project_ref:$proj, schema_version:$sv, desired:$d,
                  last_desired_actor:$a, updated_at:$at}' 2>/dev/null) \
    || { echo "co: set-desired — could not build RunnerState envelope" >&2; return 3; }
  co__store_put "$principal" runner_state "$proj" "$base"
}

# ── §2.4 deliver-desired-state-on-reconnect — TRANSPORT ONLY ─────────────────
# co__poll <principal> <project_ref> [lease_id]
#   On a runner/Local-Agent poll/reconnect, return the current
#   RunnerState.desired and any stored lease state. This is reconciliation
#   (desired-state mutation surfaced), NOT a durable command queue: it returns
#   what is STORED, it enqueues nothing.
#
# ANTI-DRIFT: pure transport. It returns the stored `desired` and the raw
#   stored Lease record (if a lease_id is given). It runs NO reconcile, derives
#   NO `liveness`, and arbitrates NO lease — §2.4 SEMANTICS are T4.3, lease
#   arbitration is T4.2.
co__poll() {
  local principal="$1" proj="$2" lease_id="${3:-}" rs lease
  rs="$(co__store_get runner_state "$proj" 2>/dev/null || echo 'null')"
  [[ -n "$rs" ]] || rs='null'
  if [[ -n "$lease_id" ]]; then
    lease="$(co__store_get lease "$lease_id" 2>/dev/null || echo 'null')"
  else
    lease='null'
  fi
  [[ -n "$lease" ]] || lease='null'
  jq -cn \
     --argjson rs "$rs" \
     --argjson ls "$lease" \
     --arg p "$principal" \
     '{principal:$p,
       desired:(if ($rs|type)=="object" then ($rs.desired // null) else null end),
       runner_state:$rs,
       lease:$ls}' 2>/dev/null \
    || printf '{"principal":"%s","desired":null,"runner_state":null,"lease":null}' "$principal"
}

# ════════════════════════════════════════════════════════════════════════════
# §10.3 — Coordinator-side forensic transient store  (T4.5, claude-tools-guq)
# ════════════════════════════════════════════════════════════════════════════
# OWNS INTERFACE.md v1 §10.3 — coordinator-side handling of the §10.2
# runner-redacted blob. Flow G tier-3's ONE controlled crossing of the sync
# boundary, under AD4's concrete numbers (the contract's job, not "briefly"):
#
#   • ENCRYPTED AT REST, server-managed key (AES-256). The storage layer holds
#     CIPHERTEXT ONLY; the key is a server secret NEVER returned to any
#     Board/client surface; transport is the §2.3 authed channel (every
#     forensic-* op dispatches through co_request, behind the ONE §9.1
#     chokepoint — there is no second auth path).
#   • TTL hard-delete at the EARLIER of created_at + FORENSIC_BLOB_TTL
#     (§0.5, 3600 s) OR an explicit user "dismiss / done with forensic".
#   • DELETE = IRRECOVERABLE destruction of the ciphertext object — NOT a
#     tombstone / soft-delete. A deletion emits a control-plane AUDIT EVENT
#     with NO forensic content (ids + timestamps + reason only).
#   • FETCH = explicit, authed, on-demand pull (§9). NEVER auto-fetched,
#     NEVER in the §4.5 projection, NEVER in a digest/notify body.
#
# §10.1 BC-27 PRESERVED VERBATIM: this is a SEPARATE transient encrypted
#   object under the machine-scratch CO_STORE — it does NOT touch and does NOT
#   weaken the on-disk `.beads/runner-logs/` `*`+`!.gitignore` boundary
#   (that boundary lives in run-beads-tasks.sh; asserted by T1b bc-27).
#
# ANTI-DRIFT: T4.5 RECEIVES the already-§10.2-redacted blob and stores it
#   VERBATIM. It MUST NOT re-derive redaction (no la_redaction_placeholder, no
#   stream-json parsing — raw stream-json never leaves the machine; that is
#   T2/T3). The blob is NOT a §4 record type (absent from co__schema_version),
#   never round-trips co__store_put, and is never read by co__poll / a
#   work_snapshot — so it is structurally absent from the §4.5 projection
#   (T4.3/T6a) and from §4.3 Notification bodies.

co__forensic_dir()      { printf '%s/forensic' "$(co__ensure_store)"; }
# The server-managed key is a SERVER SECRET. It lives OUTSIDE the `forensic/`
# ciphertext namespace (so "the storage layer holds ciphertext only" is true of
# that namespace), mode 600, and is NEVER echoed through any surface. In the
# Appendix-A hosted realisation this is a Worker/KMS secret, never the
# encrypted object store; here it is a 0600 scratch file.
co__forensic_keyfile()  { printf '%s/.forensic-master.key' "$(co__ensure_store)"; }
co__forensic_auditlog() { printf '%s/forensic-audit.jsonl' "$(co__ensure_store)"; }
co__forensic_enc_path() { printf '%s/%s.enc'  "$(co__forensic_dir)" "$1"; }
co__forensic_meta_path(){ printf '%s/%s.meta' "$(co__forensic_dir)" "$1"; }

# Encryption is a HARD security boundary: if no AES-256 primitive is available
# the store FAILS CLOSED (put returns nonzero, writes nothing) — it MUST NEVER
# silently degrade to plaintext at rest. (Contrast BC-34's deliberate
# fail-OPEN for the usage gate: a different domain, a different posture.)
co__forensic_have_crypto() { command -v openssl >/dev/null 2>&1; }

# Generate the 256-bit server master key once, mode 600, if absent. Never
# printed, never returned by any op. umask keeps the create-race tight.
co__forensic_ensure_key() {
  local kf; kf="$(co__forensic_keyfile)"
  [[ -s "$kf" ]] && return 0
  co__forensic_have_crypto || return 1
  ( umask 077
    openssl rand -hex 32 > "$kf" 2>/dev/null ) || { rm -f "$kf" 2>/dev/null; return 1; }
  chmod 600 "$kf" 2>/dev/null || true
  [[ -s "$kf" ]]
}

# AES-256-CBC + PBKDF2 (random salt) under the server key read from a FILE
# (never the cmdline ⇒ never in `ps`). base64-armoured so the at-rest object
# is unambiguously ciphertext text. stdin = plaintext, stdout = ciphertext.
co__forensic_encrypt() {
  local kf; kf="$(co__forensic_keyfile)"
  openssl enc -aes-256-cbc -pbkdf2 -salt -a -pass "file:$kf" 2>/dev/null
}
co__forensic_decrypt() {
  local kf; kf="$(co__forensic_keyfile)"
  openssl enc -d -aes-256-cbc -pbkdf2 -a -pass "file:$kf" -in "$1" 2>/dev/null
}

# A content-free control-plane audit line: ids + timestamps + reason + the
# §9.1 resolved principal ONLY. NO forensic content, NO ciphertext, NO key.
# Append-only (§10.3).
co__forensic_audit() {
  local event="$1" blob_id="$2" dossier_ref="$3" created_at="$4" reason="$5" principal="$6"
  local now line log; log="$(co__forensic_auditlog)"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  line=$(jq -cn \
      --arg ev "$event" --arg bid "$blob_id" --arg dref "$dossier_ref" \
      --arg ca "$created_at" --arg da "$now" --arg rs "$reason" --arg p "$principal" \
      '{event:$ev, blob_id:$bid, dossier_ref:$dref,
        created_at:$ca, deleted_at:$da, reason:$rs, principal:$p}' 2>/dev/null) \
    || line="{\"event\":\"$event\",\"blob_id\":\"$blob_id\",\"deleted_at\":\"$now\"}"
  printf '%s\n' "$line" >> "$log" 2>/dev/null || true
}

# IRRECOVERABLE destruction (§10.3): unlink the ciphertext AND its meta — NO
# tombstone, NO soft-delete marker left behind — then emit the content-free
# audit event from the meta's ids/timestamps (read BEFORE unlink). Idempotent:
# already-gone is success (a TTL sweep and a dismiss may race; the contract is
# "destroyed", not "destroyed exactly once by me").
co__forensic_destroy() {
  local blob_id="$1" reason="$2" principal="$3" mp ep dref ca
  co__safe_key "$blob_id" || return 2
  mp="$(co__forensic_meta_path "$blob_id")"; ep="$(co__forensic_enc_path "$blob_id")"
  [[ -f "$ep" || -f "$mp" ]] || return 0          # already irrecoverable ⇒ ok
  dref=$(jq -r '.dossier_ref // ""' "$mp" 2>/dev/null || echo "")
  ca=$(jq -r '.created_at // ""'   "$mp" 2>/dev/null || echo "")
  rm -f "$ep" "$mp" 2>/dev/null || true           # NO tombstone written
  co__forensic_audit "forensic_blob_deleted" "$blob_id" "$dref" "$ca" "$reason" "$principal"
  [[ ! -f "$ep" && ! -f "$mp" ]]
}

# co__forensic_put <principal> <blob_id> <dossier_ref> <redacted_json>
#   Store the ALREADY-§10.2-redacted blob ENCRYPTED. Ciphertext-only at rest;
#   a content-free meta (ids + timestamps) sits alongside for TTL math + audit.
#   NO redaction is performed or re-derived here (anti-drift — verbatim
#   consume of the §10.2 shape; the bytes are opaque to this tier).
co__forensic_put() {
  local principal="$1" blob_id="$2" dossier_ref="$3" redacted="$4"
  [[ -n "$blob_id" && -n "$redacted" ]] || { echo "co: forensic-put needs <id> <dossier> <redacted_json>" >&2; return 2; }
  co__safe_key "$blob_id" || { echo "co: reject — unsafe forensic blob id '$blob_id'" >&2; return 2; }
  if ! co__forensic_have_crypto || ! co__forensic_ensure_key; then
    echo "co: forensic-put FAIL-CLOSED — no AES-256 primitive; refusing plaintext at rest (§10.3)" >&2
    return 5
  fi
  local dir ep mp etmp mtmp now epoch ttl exp
  dir="$(co__forensic_dir)"; mkdir -p "$dir" 2>/dev/null || true
  ep="$(co__forensic_enc_path "$blob_id")"; mp="$(co__forensic_meta_path "$blob_id")"
  etmp="$ep.$$.tmp"
  printf '%s' "$redacted" | co__forensic_encrypt > "$etmp" 2>/dev/null || {
    rm -f "$etmp" 2>/dev/null
    echo "co: forensic-put — encryption failed; nothing written (fail-closed)" >&2; return 5; }
  [[ -s "$etmp" ]] || { rm -f "$etmp" 2>/dev/null; echo "co: forensic-put — empty ciphertext; refused" >&2; return 5; }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  epoch=$(date +%s 2>/dev/null || echo 0)
  ttl="$(co__FORENSIC_BLOB_TTL)"
  exp=$(( epoch + ttl ))
  mtmp="$mp.$$.tmp"
  jq -cn --arg bid "$blob_id" --arg dref "$dossier_ref" --arg ca "$now" \
         --arg p "$principal" --argjson ce "$epoch" --argjson ee "$exp" \
     '{blob_id:$bid, dossier_ref:$dref, created_at:$ca,
       created_epoch:$ce, expires_epoch:$ee, principal:$p}' \
     > "$mtmp" 2>/dev/null \
     || { rm -f "$etmp" "$mtmp" 2>/dev/null; echo "co: forensic-put — meta build failed" >&2; return 5; }
  mv -f "$etmp" "$ep" 2>/dev/null && mv -f "$mtmp" "$mp" 2>/dev/null || {
    rm -f "$etmp" "$mtmp" "$ep" "$mp" 2>/dev/null; return 5; }
  printf '%s' "$blob_id"
  return 0
}

# co__forensic_fetch <principal> <blob_id>
#   §9 explicit authed on-demand pull — the ONE controlled crossing. Returns
#   the decrypted §10.2 redacted blob (NEVER the key). A blob that is gone OR
#   past its TTL returns NOTHING and nonzero: a destroyed blob is irrecoverable
#   and there is no fetchable tombstone. Reaching the TTL on a fetch hard-
#   deletes lazily (the EARLIER-of bound holds even with no sweep — analogous
#   to the §2.2 S-6 poll-fallback).
co__forensic_fetch() {
  local principal="$1" blob_id="$2" ep mp exp now
  [[ -n "$blob_id" ]] || { echo "co: forensic-fetch needs <id>" >&2; return 2; }
  co__safe_key "$blob_id" || { echo "co: reject — unsafe forensic blob id '$blob_id'" >&2; return 2; }
  ep="$(co__forensic_enc_path "$blob_id")"; mp="$(co__forensic_meta_path "$blob_id")"
  [[ -f "$ep" && -f "$mp" ]] || return 1          # gone ⇒ irrecoverable, no tombstone
  exp=$(jq -r '.expires_epoch // 0' "$mp" 2>/dev/null || echo 0)
  now=$(date +%s 2>/dev/null || echo 0)
  if [[ "$now" -ge "$exp" ]]; then
    co__forensic_destroy "$blob_id" "ttl" "$principal" >/dev/null 2>&1 || true
    return 1                                       # TTL reached ⇒ treated as deleted
  fi
  co__forensic_decrypt "$ep" || return 1
}

# co__forensic_dismiss <principal> <blob_id>
#   The explicit user "dismiss / done with forensic" action ⇒ hard-delete now
#   (the other arm of the EARLIER-of). Idempotent: dismissing an absent /
#   already-gone blob is success ("done with forensic" is satisfied).
co__forensic_dismiss() {
  local principal="$1" blob_id="$2"
  [[ -n "$blob_id" ]] || { echo "co: forensic-dismiss needs <id>" >&2; return 2; }
  co__safe_key "$blob_id" || { echo "co: reject — unsafe forensic blob id '$blob_id'" >&2; return 2; }
  co__forensic_destroy "$blob_id" "dismiss" "$principal"
}

# co__forensic_sweep <principal> [now_epoch]
#   TTL poll-fallback (mirrors co__timer_due): hard-delete every blob whose
#   expires_epoch ≤ now and print its id. Deterministic, no daemon — a missed
#   sweep never strands a blob past TTL (next sweep OR next fetch destroys it).
co__forensic_sweep() {
  local principal="$1" now="${2:-}" d f bid exp
  [[ -n "$now" ]] || now=$(date +%s 2>/dev/null || echo 0)
  d="$(co__forensic_dir)"; [[ -d "$d" ]] || return 0
  for f in "$d"/*.meta; do
    [[ -e "$f" ]] || continue
    bid=$(jq -r '.blob_id // ""'      "$f" 2>/dev/null || echo "")
    exp=$(jq -r '.expires_epoch // 0' "$f" 2>/dev/null || echo 0)
    [[ -n "$bid" ]] || continue
    if [[ "$now" -ge "$exp" ]]; then
      co__forensic_destroy "$bid" "ttl" "$principal" >/dev/null 2>&1 && printf '%s\n' "$bid"
    fi
  done
}

# co__forensic_audit_tail [n] — the content-free deletion audit (observability;
# ids + timestamps + reason, by construction NO forensic content / ciphertext).
co__forensic_audit_tail() {
  local n="${1:-}" log; log="$(co__forensic_auditlog)"
  [[ -f "$log" ]] || return 0
  if [[ -n "$n" && "$n" =~ ^[0-9]+$ ]]; then
    tail -n "$n" "$log" 2>/dev/null || true
  else
    cat "$log" 2>/dev/null || true
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# §6.3 / §6.2 — coordinator-side COARSE capacity aggregation  (T4.4, d7x)
# ════════════════════════════════════════════════════════════════════════════
# OWNS INTERFACE.md v1 §6.3 (coordinator-side coarse-capacity aggregation) +
# §6.2 (the AD2.2 capacity-half unreachable posture). The Coordinator must
# answer "may I start a task of cost-class C?" GLOBALLY — but it NEVER reads a
# Keychain or an Anthropic usage API (§1.1). It AGGREGATES the coarse cost-class
# verdicts the Local Agents report UP (§1.1 item 1; produced by T3's
# la_report_capacity, consumed here VERBATIM).
#
#   • §1.1 INGEST (report-capacity): receive the upward coarse capacity report
#     through the ONE §2.3/§9.1 authed front door. The §1.1 report shape is the
#     T3 contract VERBATIM:
#        {report:"capacity", schema_version:1, principal, runner_id,
#         cost_class ∈ {standard,low_priority}, verdict ∈ {ok,over},
#         observed_at}
#     §0.3 is enforced exactly as the §4 store does (an unknown HIGHER
#     schema_version is REJECTED, never best-effort-parsed); §9.1 stamps the
#     RESOLVED principal over whatever the report carried. The LATEST report
#     per (runner_id, cost_class) wins (a recovered runner that re-reports `ok`
#     supersedes its earlier `over` — newest observed_at).
#
#   • §6.3 AGGREGATE (ask-capacity <cost_class>): verdict ∈ {ok,over}.
#       - USAGE_THRESHOLD=0 ⇒ the hard ceiling is DISABLED globally ⇒ always
#         `ok` (EXIT crit 2; the same gate-disable semantic the Local Agent
#         applies — §6.3; NOT a re-measurement; shared §0.5 constant).
#       - `standard` is gated ONLY by the hard ceiling: `over` iff ANY current
#         Local-Agent `standard` report is `over`. The 5h-OR-7d integer-
#         truncated utilisation ≥ USAGE_THRESHOLD test was MEASURED by the
#         Local Agent (T3, BC-34 verbatim) and is already encoded in the
#         reported coarse verdict — this tier AGGREGATES it, it does NOT
#         re-measure (task MUST-NOT-TOUCH; §1.1 "aggregates what LAs report").
#       - `low_priority` is ADDITIONALLY gated by the spare-cycles line: `over`
#         iff ANY `low_priority` report is `over` (the LA already encoded the
#         day-N ≤ N×SPARE_RAMP_PER_DAY soft line into that verdict) OR
#         `standard` aggregates to `over` (backfill-only: low-priority work
#         NEVER starves the weekly cap — a hit hard ceiling on standard means
#         no spare capacity at all, so low_priority is certainly over).
#       - No report for the class (and the gate enabled) ⇒ `ok`: nothing has
#         been reported `over`; the real guard is the LA's hard ceiling, which
#         WOULD have reported `over` (AD2.3 honest rationale: the 14.2%/day
#         line is a soft ramp, the 5h/7d ceiling is the real guard).
#
#   • §6.2 UNREACHABLE POSTURE (AD2.2 capacity half): the capacity check FAILS
#     OPEN. Coordinator-unreachable ⇒ PROCEED (verdict `ok`). A one-task
#     overshoot is noise; the BC-34 intent is preserved AT THE LOCAL AGENT
#     (T3) — this is the exact mirror of la_lease_fallback_allows' reachable|
#     unreachable shape for the LEASE half (which fails DEGRADED-CLOSED — a
#     deliberately DIFFERENT posture for the higher-blast-radius plane).
#
# ANTI-DRIFT: this tier ONLY aggregates the reported coarse verdict; it NEVER
#   measures (no Keychain, no usage API, no 5h/7d numbers, no spare-ramp math
#   — all of that is T3 §6.3-local, MUST-NOT-TOUCH). A capacity report is a
#   §1.1 UP report, NOT a §4 store record: it lives in a SEPARATE `capacity/`
#   namespace (mirroring `forensic/`), is ABSENT from co__schema_version, never
#   round-trips co__store_put, and is never read by co__poll / a work_snapshot
#   — so it is structurally absent from the §4.5 projection (T4.3/T6a). It is
#   NOT one of the four §2 capabilities (those stay exactly four —
#   co_capabilities, untouched); it crosses the §2.3 authed channel like every
#   other op, behind the ONE §9.1 chokepoint (no second auth path).

co__capacity_dir() { printf '%s/capacity' "$(co__ensure_store)"; }

# The §6.3 cost_class is a CLOSED enum (INTERFACE.md §6.3): exactly
# {standard, low_priority}. An unknown class is rejected at the door (it is a
# contract value, not free text) — never silently treated as `standard`.
co__capacity_class_ok() { [[ "$1" == "standard" || "$1" == "low_priority" ]]; }

# capacity/<cost_class>/<runner_id>.json — one file per (runner_id,cost_class):
# the cost_class is a fixed enum (a safe subdir name); the runner_id is the
# only variable component and is co__safe_key-validated, so no key collision
# and no path traversal is possible.
co__capacity_path() {
  local cc="$1" rid="$2"
  printf '%s/%s/%s.json' "$(co__capacity_dir)" "$cc" "$rid"
}

# co__capacity_report <principal> <report_json>
#   §1.1 INGEST of one upward coarse capacity report (T3's la_report_capacity
#   shape, consumed VERBATIM). Enforces, in order:
#     1. valid JSON object with report=="capacity";
#     2. §0.3 — integer schema_version; an unknown HIGHER version is REJECTED
#        (never best-effort-parsed), exactly as the §4 store does. The §1.1
#        capacity report binds to schema_version 1;
#     3. closed-enum cost_class ∈ {standard,low_priority} and verdict ∈
#        {ok,over}; non-empty runner_id (the §1.1 stamp);
#     4. §9.1 — STAMP `principal` with the RESOLVED principal (overwrite
#        whatever the report carried — never trust the use-site literal, C7).
#   The LATEST report per (runner_id,cost_class) wins: a stored report with a
#   strictly-newer observed_at is NOT clobbered by an older straggler (the
#   §1.1 UP queue drains in order, but compare defensively). Writes atomically
#   (temp + mv) under the per-key lock. Returns nonzero, writes NOTHING, on any
#   rejection. NOTE (anti-drift): no measurement here — it stores the verdict
#   the Local Agent already computed; it never derives one.
co__capacity_report() {
  local principal="$1" json="$2"
  [[ -n "$json" ]] || { echo "co: report-capacity needs <report_json>" >&2; return 2; }
  local parsed
  parsed=$(printf '%s' "$json" | jq -c '
        if type=="object" and .report=="capacity" then . else empty end' 2>/dev/null) \
    || parsed=""
  if [[ -z "$parsed" ]]; then
    echo "co: reject — not a §1.1 capacity report (report!=\"capacity\" / invalid JSON)" >&2
    return 3
  fi
  # §0.3 — integer schema_version; unknown HIGHER ⇒ reject, never best-effort.
  local sv
  sv=$(printf '%s' "$parsed" | jq -r '
        if (.schema_version|type)=="number"
           and (.schema_version == (.schema_version|floor))
        then .schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "co: reject — capacity report missing integer schema_version (§1.1/§0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt 1 ]]; then
    echo "co: reject — capacity report schema_version $sv is an unknown higher version (bound=1; §0.3 reject, never best-effort-parse)" >&2
    return 3
  fi
  if [[ "$sv" -ne 1 ]]; then
    echo "co: reject — capacity report schema_version $sv unsupported (binds v1 only; §0.3)" >&2; return 3
  fi
  local cc vd rid
  cc=$(printf '%s'  "$parsed" | jq -r '.cost_class // ""' 2>/dev/null) || cc=""
  vd=$(printf '%s'  "$parsed" | jq -r '.verdict   // ""' 2>/dev/null) || vd=""
  rid=$(printf '%s' "$parsed" | jq -r '.runner_id // ""' 2>/dev/null) || rid=""
  if ! co__capacity_class_ok "$cc"; then
    echo "co: reject — capacity report cost_class '$cc' not in {standard,low_priority} (§6.3 closed enum)" >&2; return 3
  fi
  if [[ "$vd" != "ok" && "$vd" != "over" ]]; then
    echo "co: reject — capacity report verdict '$vd' not in {ok,over} (§6.3)" >&2; return 3
  fi
  if [[ -z "$rid" ]] || ! co__safe_key "$rid"; then
    echo "co: reject — capacity report runner_id '$rid' missing/unsafe (§1.1 stamp; store-owner input hygiene)" >&2; return 3
  fi
  # §9.1 stamp: the RESOLVED principal, overwriting anything the report put.
  local stamped
  stamped=$(printf '%s' "$parsed" | jq -c --arg p "$principal" '.principal=$p' 2>/dev/null) || {
    echo "co: reject — capacity report is not valid JSON (post-parse)" >&2; return 3; }
  co__with_lock "capacity.$cc.$rid" co__capacity_write "$cc" "$rid" "$stamped"
}

co__capacity_write() {
  local cc="$1" rid="$2" json="$3" dir path tmp prev pobs nobs
  dir="$(co__capacity_dir)/$cc"
  mkdir -p "$dir" 2>/dev/null || true
  path="$(co__capacity_path "$cc" "$rid")"
  # Latest-wins: keep the report with the newer observed_at. RFC-3339 UTC
  # strings sort lexicographically, so a string compare is the time compare.
  if [[ -f "$path" ]]; then
    nobs=$(printf '%s' "$json" | jq -r '.observed_at // ""' 2>/dev/null) || nobs=""
    pobs=$(jq -r '.observed_at // ""' "$path" 2>/dev/null) || pobs=""
    if [[ -n "$pobs" && -n "$nobs" && "$nobs" < "$pobs" ]]; then
      return 0     # an older straggler ⇒ keep the newer stored report
    fi
  fi
  tmp="$path.$$.tmp"
  printf '%s\n' "$json" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 4; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 4; }
  return 0
}

# co__capacity_any_over <cost_class> — 0 (true) iff ANY current Local-Agent
# report for <cost_class> carries verdict "over". Pure aggregation over the
# stored coarse verdicts (no measurement).
co__capacity_any_over() {
  local cc="$1" dir f vd
  dir="$(co__capacity_dir)/$cc"
  [[ -d "$dir" ]] || return 1
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    vd=$(jq -r '.verdict // ""' "$f" 2>/dev/null) || vd=""
    [[ "$vd" == "over" ]] && return 0
  done
  return 1
}

# co__ask_capacity <cost_class> — the §6.3 AGGREGATED verdict.
#   Echoes "ok" | "over"; returns 0 for ok, 1 for over (the same proceed/halt
#   convention as the Local Agent's la_capacity_check, so a caller can branch
#   on the rc as well as the stdout token).
co__ask_capacity() {
  local cc="${1:-standard}"
  if ! co__capacity_class_ok "$cc"; then
    echo "co: ask-capacity cost_class '$cc' not in {standard,low_priority} (§6.3 closed enum)" >&2
    return 2
  fi
  # §6.3 / EXIT crit 2 — USAGE_THRESHOLD=0 disables the hard ceiling GLOBALLY
  # ⇒ capacity is always ok (the same gate-disable the Local Agent applies;
  # not a re-measurement — the shared §0.5 constant). When disabled the LA
  # also emits NO reports, so this short-circuit is the consistent global view.
  local threshold; threshold="$(co__USAGE_THRESHOLD)"
  if [[ "$threshold" =~ ^[0-9]+$ ]] && [[ "$threshold" -eq 0 ]]; then
    echo ok; return 0
  fi
  # `standard` is gated ONLY by the hard ceiling (aggregated coarse verdict).
  if co__capacity_any_over standard; then
    if [[ "$cc" == "standard" ]]; then echo over; return 1; fi
    # `low_priority` ADDITIONALLY: a hit hard ceiling on standard ⇒ no spare
    # capacity at all ⇒ low_priority is certainly over (backfill-only; it
    # never starves the weekly cap).
    echo over; return 1
  fi
  if [[ "$cc" == "low_priority" ]] && co__capacity_any_over low_priority; then
    # The LA already encoded the day-N ≤ N×SPARE_RAMP_PER_DAY soft line into
    # this coarse verdict — aggregated here, never re-measured.
    echo over; return 1
  fi
  echo ok; return 0
}

# co_ask_capacity <bearer> <cost_class> [reachable|unreachable]
#   The §6.2 capacity gate as the runner sees it (AD2.2 CAPACITY HALF). This
#   is the exact mirror of local-agent.sh's la_lease_fallback_allows
#   reachable|unreachable shape — but the OPPOSITE posture, deliberately:
#     unreachable ⇒ FAIL OPEN: echo "ok", return 0 (PROCEED). A one-task
#                   overshoot is noise; the BC-34 hard-ceiling intent is
#                   preserved AT THE LOCAL AGENT (T3). There is no Coordinator
#                   to authenticate against when it is unreachable — the
#                   posture IS "proceed", not "ask".
#     reachable   ⇒ ask through the ONE §2.3/§9.1 authed front door
#                   (co_request → co__ask_capacity); the aggregated verdict.
#   (Contrast the LEASE half — la_lease_fallback_allows — which fails
#    DEGRADED-CLOSED: a different, higher-blast-radius plane, a different
#    posture. §6.2 freezes BOTH halves so neither is left to implementation.)
co_ask_capacity() {
  local bearer="${1:-}" cc="${2:-standard}" reach="${3:-reachable}"
  if [[ "$reach" == "unreachable" ]]; then
    echo ok; return 0                       # §6.2 / AD2.2 capacity-half fail-OPEN
  fi
  co_request "$bearer" ask-capacity "$cc"
}

# ── EXIT-criterion-1 introspection: the four §2 capabilities are reachable ────
# Prints the four §2 capability surfaces and the function realising each, so
# "the shell stands up and the four capabilities are reachable surfaces" is
# observable/testable.
co_capabilities() {
  cat <<'EOF'
§2.1 store                       : co_request <tok> put|get   (co__store_put / co__store_get)
§2.2 durable one-shot timer      : co_request <tok> timer-arm|timer-due|timer-ack
§2.3 authed endpoint (§9.1 choke): co_request  (the ONE co_authenticate→principal step)
§2.4 deliver-desired-state       : co_request <tok> poll      (transport; set-desired captures C4 actor)
EOF
}

# ── APPENDIX A — non-normative Cloudflare realisation map (INTERFACE §0.2) ────
# Informational ONLY; part of NO contract. A provider swap changes ONLY the
# co__store_* / co__timer_* / co__forensic_* internals — never a signature:
#   §2.1 store        → a Durable Object's transactional state + D1
#   §2.2 timer        → a DO setAlarm(); the co__timer_due poll-fallback is the
#                       S-6 backstop that makes the free-tier alarm's
#                       non-contractual reliability safe
#   §2.3/§9.1 choke   → a Worker middleware (one authenticate→principal)
#   §2.4 poll         → the DO reconnect handler returning desired + lease
#   record store      → DO state / D1 rows (one DO per dossier-Item is AD1/AD7,
#                       realised in T5 — NOT here)
#   §10.3 forensic    → an encrypted object store (R2/D1) for the ciphertext +
#                       a Worker/KMS-held server key (NEVER the object store);
#                       co__forensic_sweep is the TTL backstop, mirroring the
#                       §2.2 poll-fallback so a missed sweep never strands a
#                       blob past FORENSIC_BLOB_TTL
# The SPOF of the singleton Coordinator DO is acknowledged (AD1) and mitigated
# by §6.2 (unreachable posture — T3/T4.2) + §2.2 S-6 backstop, not waved away.
