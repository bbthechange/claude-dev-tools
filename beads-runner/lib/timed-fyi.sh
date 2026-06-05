# shellcheck shell=bash
# beads-runner/lib/timed-fyi.sh — T5.4 DURABLE timed-fyi TIMER + S-6
#                                 missed-alarm fire-on-next-poll dedup
#                                 (claude-tools-it2; epic claude-tools-glk).
# ════════════════════════════════════════════════════════════════════════════
# OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
#
#   • §2.2 fire(dossier_id)@T WIRING for the `timed-fyi` auto-proceed window.
#     `timer_fire_at = created_at + window`; window default `TIMED_FYI_DEFAULT`
#     (§0.5), a per-dossier override ∈ (0, `TIMED_FYI_DEFAULT`]; a `null`
#     window ⇒ NO timer (`timer_fire_at` stays null, nothing armed). The
#     §4.1 `tier` drives whether a §2.2 timer is set — only `timed-fyi` arms.
#
#   • The S-6 BACKSTOP. The §2.2 timer is best-effort BY CONTRACT; a missed
#     fire MUST degrade to fire-on-next-poll. `tf_fire` is the SHARED
#     auto-proceed handler the alarm path AND the poll-fallback both invoke;
#     it auto-proceeds each un-objected `fyi-objectable` item by calling the
#     T5.3 idempotent per-Item entrypoint `do_item_apply` with a proceed
#     response. Alarm-fire vs poll-fallback therefore apply each item's
#     consequence EXACTLY ONCE **via the §7.4 per-Item latch (S-6)** — never
#     via timer reliability and never via the best-effort ack.
#
#   • A `timed-fyi` dossier can NEVER stall forever (S-6): every un-objected
#     `fyi-objectable` item auto-proceeds on the window; non-auto-proceeding
#     items (objected, or a non-`fyi-objectable` item carried in a `timed-fyi`
#     dossier) are simply LEFT OPEN — they block neither siblings nor the
#     pipeline (AD7 partial resolution; the §4.1 rollup is never a gate).
#
#   • Consumes the T4 §2.2 timer SURFACE (claude-tools-ick) via the §2.3 authed
#     front door ONLY — `co_request <bearer> timer-arm|timer-due|timer-ack`
#     (never a co__timer_* internal) — and the T5.3 idempotent per-Item apply
#     ENTRYPOINT `do_item_apply` (the §5.3/§7.4/§5.2.2 LOGIC is T5.3's; this
#     file never re-implements it). The §4.1 envelope round-trips through the
#     T5.1 PUBLIC surface (`do_dossier_get` / `do_dossier_put`); the §4.1
#     `timer_fire_at` field is stored-verbatim by T5.1 — T5.4 is the tier that
#     COMPUTES and SETS it (T5.1 header: "§2.2 durable-timer wiring — T5.4").
#
# MUST NOT TOUCH (sibling surfaces — drift is a BLOCKING escalation, §11):
#   • §4.1 envelope / §4.1.1 per-Item record / state-machine + latch/dedup
#     PRIMITIVE internals — T5.1 (claude-tools-fuy). Consumed as a black box
#     via the PUBLIC surface (`do_dossier_get`, `do_dossier_put`, the exposed
#     single-writer `do__with_dossier_lock`, `do__safe_key`); no `do__*_locked`
#     internal is called and the §4 store is never re-implemented.
#   • §5 generation of `body`/`items[]` content — T5.2. The proceed response
#     is the §4.1.1 `.response` RECORD only; NO §5 content is synthesised.
#   • §5.3 apply LOGIC + §7.4 per-Item latch + §5.2.2 deterministic/reconciler
#     routing — T5.3 (claude-tools-o0u). `tf_fire` CALLS `do_item_apply`; it
#     never selects/applies a ConsequenceBlock, flips a latch, or moves a
#     `.state` itself. (A T5.3 §5.2.2-conformance defect that blocked this
#     task — fyi-objectable excluded from the deterministic kind allow-list —
#     was filed as claude-tools-864 and fixed in T5.3's OWNING file
#     consequence.sh, NOT worked around or re-implemented here.)
#   • §7.3/§7.4 DOSSIER-level `task_ref` dedup + S-2 reconcile — T5.5. The S-6
#     dedup this file relies on is the PER-ITEM latch (T5.3), a distinct layer.
#   • §4.3 Notification — T5.6.
#   • The T4 §2.2 timer-surface INTERNALS (`co__timer_*`) — claude-tools-ick.
#     Consumed only through `co_request` (the §2.3 authed front door).
#
# ANTI-DRIFT: binds INTERFACE.md v1 §2.2 / §7.4 (S-6). The timer is
#   best-effort BY CONTRACT — exactly-once is the §7.4 per-Item latch, never
#   timer reliability and never the ack. An INTERFACE gap/contradiction is a
#   BLOCKING §11 escalation (reopen claude-tools-65z, amend+bump+re-freeze,
#   Brian sign-off) — never diverge locally. (No INTERFACE gap was found; the
#   one defect hit was a T5.3 implementation non-conformance, fixed in T5.3.)
#
# Safe to `source` under `set -euo pipefail`: only function definitions below;
# every fallible call is guarded. Requires `jq`.
# ════════════════════════════════════════════════════════════════════════════

# ── consume the T5.3 entrypoint + T5.1 surface + T4 §2.2 timer surface ───────
# Sources consequence.sh (→ dossier.sh → coordinator.sh) the way the focused
# tests do, binding ONLY to the public surface:
#   do_item_apply                  — the T5.3 idempotent per-Item apply (§7.4)
#   do_dossier_get / do_dossier_put— the T5.1 §4.1 envelope round-trip
#   do__with_dossier_lock          — the exposed single-writer critical section
#   do__safe_key                   — the shared id-safety predicate
#   co_request                     — the §2.3 authed front door (timer-* §2.2)
#   co_authenticate                — the ONE §9.1 authenticate→principal step
tf__lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
if ! declare -F do_item_apply >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(tf__lib_dir)/consequence.sh"
fi
# N3 (claude-tools-uxg6) — ready-to-pair's SURFACE fire-action fires the
# blocking `ready_to_pair` notification via the N1 catalog spine `notif_fire`.
# Source notification.sh as the bash twin of cf/src/timer.js importing
# notification.js (guarded; function-only, safe under set -euo pipefail). It
# pulls dossier-gen.sh transitively (its own guard) — unused by pair_surface
# but harmless; co_request/co_authenticate are already in scope via the chain.
if ! declare -F notif_fire >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(tf__lib_dir)/notification.sh"
fi

# ── §0.5 frozen constant — single normative definition is INTERFACE.md ───────
# §0.5 forbids a competing local restatement; each consuming file provides an
# env-overridable lookup defaulting to the §0.5 value (the la__/co__ discipline
# — la__LEASE_TTL, co__FORENSIC_BLOB_TTL). T5.4 is the REAL use site for the
# `timed-fyi` window, so — mirroring that discipline — it is defined HERE.
tf__TIMED_FYI_DEFAULT() { echo "${TIMED_FYI_DEFAULT:-86400}"; }   # §0.5

# ── portable RFC-3339(…Z, §0.4) ↔ epoch arithmetic ───────────────────────────
# created_at + window must be computed without coupling to a T4 internal
# (consume only the §2.2 timer SURFACE). Dual-path GNU(`-d`)/BSD-macOS(`-j`/
# `-r`), exactly the portability shape coordinator.sh's own date helper uses.
# `created_at` is §0.4 RFC-3339 UTC integer-seconds (`…Z`); fractional seconds
# / numeric offsets are OUT OF CONTRACT — the GNU `-d` path tolerates them, the
# BSD literal-format `-j -f` path does not, and an unparseable created_at fails
# CLOSED (tf_arm returns 3, NO timer) rather than guessing a fire time.
tf__rfc_to_epoch() {
  local ts="${1:-}" e
  [[ -n "$ts" ]] || return 1
  e=$(date -u -d "$ts" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
  e=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
  return 1
}
tf__epoch_to_rfc() {
  local ep="${1:-}" r
  [[ "$ep" =~ ^-?[0-9]+$ ]] || return 1
  r=$(date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) && { printf '%s' "$r"; return 0; }
  r=$(date -u -r "$ep"   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) && { printf '%s' "$r"; return 0; }
  return 1
}
tf__now_rfc() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""; }

# ════════════════════════════════════════════════════════════════════════════
# §2.2 fire(dossier_id)@T WIRING — arm the timed-fyi auto-proceed window
# ════════════════════════════════════════════════════════════════════════════
# tf_arm <bearer> <dossier_id> [window]
#   Compute `timer_fire_at = created_at + window` for a `timed-fyi` dossier,
#   STORE it on the §4.1 envelope (via the T5.1 surface, stored-verbatim), and
#   arm the T4 §2.2 one-shot `fire(dossier_id)` via the §2.3 front door. The
#   timer id IS the dossier id (§2.2 `fire(dossier_id)`).
#
#   <window> resolution (the §2.2 / §0.5 contract):
#     • omitted / "" / "default"        ⇒ `TIMED_FYI_DEFAULT` (§0.5)
#     • the literal token `null`        ⇒ NO auto-proceed: `timer_fire_at`
#                                         cleared to null AND any prior §2.2
#                                         arm SOFT-DISARMED (see below); §4.1
#                                         "`null` when no auto-proceed window"
#     • a positive integer N            ⇒ override; MUST be ∈ (0,
#                                         `TIMED_FYI_DEFAULT`] else REJECTED
#                                         (a caller error against the frozen
#                                         range — NOT an INTERFACE gap)
#   A non-`timed-fyi` tier ⇒ NO timer (the §4.1 `tier` drives this); a no-op
#   informational success (a `blocking`/`digest` dossier has no auto-proceed).
#
#   SOFT-DISARM (review claude-tools-it2 #1). The frozen §2.2 surface exposes
#   only arm/due/ack — there is NO disarm primitive (correctly: a missed fire
#   degrading to fire-on-next-poll is the whole S-6 model). So clearing a
#   window that was ALREADY armed cannot "un-arm" the T4 timer; instead the
#   `null` path best-effort `timer-ack`s it — `timer-ack` is precisely the
#   §2.2 "stop the poll-fallback re-surfacing it" primitive (coordinator.sh:
#   co__timer_ack), so an ack'd timer is excluded by `timer-due` and never
#   fires. This is NOT a §2.2 extension and NOT a §11 gap: it uses the
#   surface's stated primitive for its stated purpose. Even if a fire raced
#   the ack, the §7.4 per-Item latch still bounds every item to exactly-once
#   (S-6) — the latch, never the timer, is the correctness mechanism.
#
#   RE-ARM semantics. `tf_arm` is intended to be called ONCE at dossier
#   creation. A live-window re-arm (window→window) deliberately resets the T4
#   timer (un-acks it) — correct while no fire has happened yet. After a fire,
#   a window re-arm would re-surface the dossier on the next poll, but every
#   already-applied item is an idempotent no-op under the §7.4 latch, so the
#   only effect is a redundant poll pass (best-effort timer, by contract).
#
#   The get→set→put runs under the T5.1 single-writer lock so a concurrent
#   sibling-Item write cannot clobber the envelope (AD7 holds under
#   concurrency). NOTE: `tf_arm` never calls `do_item_apply`, so taking the
#   dossier lock here cannot self-deadlock against T5.3's internal lock.
tf_arm() {
  do__with_dossier_lock "${2:-}" tf__arm_locked "$@"
}
tf__arm_locked() {
  local bearer="${1:-}" did="${2:-}" win="${3:-}"
  local rec tier ca def fire_at epoch upd
  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "timed-fyi: arm — dossier '$did' not found OR not authorized (§9.1 chokepoint collapses 401/absent; no second auth path — C4)" >&2; return 1; }

  tier=$(printf '%s' "$rec" | jq -r '.tier // ""' 2>/dev/null) || tier=""
  if [[ "$tier" != "timed-fyi" ]]; then
    # Soft-disarm any stale prior arm (harmless no-op if none — timer-ack
    # returns nonzero when no timer file exists, swallowed). A non-timed-fyi
    # dossier MUST NOT auto-proceed (§4.1 tier drives this).
    co_request "$bearer" timer-ack "$did" >/dev/null 2>&1 || true
    echo "timed-fyi: arm — dossier '$did' tier='$tier' is not 'timed-fyi'; no §2.2 timer set (the §4.1 tier drives this) — no-op" >&2
    return 0
  fi

  def="$(tf__TIMED_FYI_DEFAULT)"

  # null window ⇒ explicit NO auto-proceed (§4.1 timer_fire_at null when no
  # window). Clear the envelope field AND soft-disarm a prior §2.2 arm via
  # the surface's stop-re-surfacing primitive timer-ack (review #1; §2.2 has
  # no disarm — the per-Item §7.4 latch still bounds any race to once).
  if [[ "$win" == "null" ]]; then
    upd=$(printf '%s' "$rec" | jq -c '.timer_fire_at=null' 2>/dev/null) \
      || { echo "timed-fyi: arm — could not clear timer_fire_at" >&2; return 3; }
    do_dossier_put "$bearer" "$upd" >/dev/null || return $?
    co_request "$bearer" timer-ack "$did" >/dev/null 2>&1 || true
    echo "timed-fyi: arm — dossier '$did' window=null ⇒ no §2.2 timer; any prior arm soft-disarmed (timer-ack)" >&2
    return 0
  fi

  # default vs per-dossier override ∈ (0, TIMED_FYI_DEFAULT].
  if [[ -z "$win" || "$win" == "default" ]]; then
    win="$def"
  else
    if [[ ! "$win" =~ ^[0-9]+$ ]]; then
      echo "timed-fyi: arm REJECTED — window '$win' not a non-negative integer of seconds (§0.4 durations are integer seconds)" >&2
      return 2
    fi
    if [[ "$win" -le 0 || "$win" -gt "$def" ]]; then
      echo "timed-fyi: arm REJECTED — window $win out of range; per-dossier override MUST be ∈ (0, TIMED_FYI_DEFAULT=$def] (§2.2/§0.5)" >&2
      return 2
    fi
  fi

  ca=$(printf '%s' "$rec" | jq -r '.created_at // ""' 2>/dev/null) || ca=""
  epoch="$(tf__rfc_to_epoch "$ca")" \
    || { echo "timed-fyi: arm — dossier '$did' created_at '$ca' unparseable (§0.4 RFC-3339 …Z)" >&2; return 3; }
  fire_at="$(tf__epoch_to_rfc "$(( epoch + win ))")" \
    || { echo "timed-fyi: arm — could not derive timer_fire_at" >&2; return 3; }

  # Store timer_fire_at on the §4.1 envelope (T5.1 stores it verbatim) ...
  upd=$(printf '%s' "$rec" | jq -c --arg t "$fire_at" '.timer_fire_at=$t' 2>/dev/null) \
    || { echo "timed-fyi: arm — could not set timer_fire_at" >&2; return 3; }
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?

  # ... and arm the T4 §2.2 one-shot fire(dossier_id) via the §2.3 front door.
  co_request "$bearer" timer-arm "$did" "$fire_at" \
    || { echo "timed-fyi: arm — T4 §2.2 timer-arm failed for '$did'@$fire_at" >&2; return 4; }
  printf '%s' "$fire_at"
}

# ════════════════════════════════════════════════════════════════════════════
# §2.2 / S-6 — the SHARED auto-proceed handler (alarm-fire AND poll-fallback)
# ════════════════════════════════════════════════════════════════════════════
# tf_fire <bearer> <dossier_id>
#   Auto-proceed every un-objected `fyi-objectable` item of <dossier_id> by
#   calling the T5.3 idempotent entrypoint `do_item_apply` with a proceed
#   response. INVOKED IDENTICALLY by the §2.2 alarm path AND the S-6
#   poll-fallback (`tf_poll`) — so a missed alarm degrades to fire-on-next-poll
#   and alarm-then-poll cannot double-apply: exactly-once is the §7.4 per-Item
#   latch inside `do_item_apply`, NOT this handler and NOT the ack.
#
#   An item is auto-proceeded iff: kind == `fyi-objectable` AND state == `open`
#   AND consequence_applied == false. That EXCLUDES:
#     • an OBJECTED item — the human's `decision:"object"` already moved it off
#       `open` (answered/applied via the T5.3 reconciler); never auto-proceeds.
#     • a non-`fyi-objectable` item carried in a `timed-fyi` dossier — left
#       OPEN, untouched (it blocks neither siblings nor the pipeline — AD7).
#   Each kept item is applied INDEPENDENTLY: a per-item failure is observable
#   on stderr and never stops a sibling (AD7 partial resolution). `tf_fire`
#   takes NO dossier lock — `do_item_apply` acquires the T5.1 single-writer
#   lock internally; an outer lock here would self-deadlock that re-entrantly
#   and a stale enumeration is safe (the per-Item latch is the truth).
#   The §2.2 timer is ack'd best-effort at the end ONLY to stop the
#   poll-fallback re-surfacing it; correctness never depends on the ack.
tf_fire() {
  local bearer="${1:-}" did="${2:-}"
  local rec tier ids id rc=0 proceed principal now

  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "timed-fyi: fire — dossier '$did' not found OR not authorized (§9.1 collapses 401/absent — C4)" >&2; return 1; }

  tier=$(printf '%s' "$rec" | jq -r '.tier // ""' 2>/dev/null) || tier=""
  if [[ "$tier" != "timed-fyi" ]]; then
    echo "timed-fyi: fire — dossier '$did' tier='$tier' not 'timed-fyi'; nothing auto-proceeds (§4.1 tier) — no-op" >&2
    return 0
  fi

  # The §9.1-resolved principal (the ONE chokepoint — never a literal at the
  # use site, C7). It tags the synthetic auto-proceed response so the record
  # is self-describing ("not a human turn — the window lapsed un-objected").
  principal="$(co_authenticate "$bearer" 2>/dev/null)" || principal=""
  now="$(tf__now_rfc)"
  proceed=$(jq -cn --arg p "$principal" --arg at "$now" \
    '{decision:"approve", auto_proceed:true, responded_at:$at, principal:$p}' 2>/dev/null) \
    || proceed='{"decision":"approve","auto_proceed":true}'

  # Enumerate the un-objected, unresolved fyi-objectable items (snapshot; the
  # per-Item latch — re-read under do_item_apply's own lock — is the truth).
  ids=$(printf '%s' "$rec" | jq -r '
    .items[]? | select(.kind=="fyi-objectable" and .state=="open"
                        and (.consequence_applied==false)) | .id' 2>/dev/null) || ids=""

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # T5.3 idempotent apply. With the proceed response (decision:"approve",
    # un-edited) an un-objected fyi-objectable routes DETERMINISTIC (T5.3
    # §5.2.2, post claude-tools-864) ⇒ its pre-declared §5.3 block is applied
    # EXACTLY ONCE via the §7.4 per-Item latch; a re-fire (alarm⇄poll, S-6)
    # sees the latch true and no-ops. Per-item failure: observable, sibling
    # continues (AD7) — never silently swallowed.
    if ! do_item_apply "$bearer" "$did" "$id" "$proceed"; then
      echo "timed-fyi: fire — WARN auto-proceed of item '$id' in '$did' returned nonzero (observable, not silent; sibling auto-proceed continues — AD7 partial)" >&2
      rc=5
    fi
  done <<< "$ids"

  # Best-effort ack so the S-6 poll-fallback stops re-surfacing this fire.
  # NEVER the correctness mechanism (that is the §7.4 per-Item latch): a
  # failed/absent ack just means the next poll re-runs tf_fire idempotently.
  co_request "$bearer" timer-ack "$did" >/dev/null 2>&1 || true
  return "$rc"
}

# ════════════════════════════════════════════════════════════════════════════
# N3 (claude-tools-uxg6) — READY-TO-PAIR: a scheduled collaborative-stage
# session. DESIGN N §4 (design/notifications.md). The bash twin of the
# cf/src/timer.js pairArm/pairSurface. Realizes the reserved `kind:"pair"`
# discriminator (INTERFACE §4.1 open C2 seam) as a SCHEDULED SESSION armed on
# the SAME §2.2 timer tf_arm uses, but with the OPPOSITE fire-action: SURFACE
# the session (fire the blocking `ready_to_pair` notification — N2 delivers),
# NEVER auto-proceed. Nothing is consequence-applied on silence; the point is
# to get Brian INTO the session (§4.3). Reuses the timer ARM/DUE primitive but
# NOT tf_fire's §7.4 auto-apply. NOT a §11 amendment (§4.2): no §4 record type,
# pair rides the dossier type + the §2.2 `timers` namespace.
# ════════════════════════════════════════════════════════════════════════════
# pair_arm <bearer> <dossier_id>
#   Arm the §2.2 one-shot fire(dossier_id) at the `kind:"pair"` envelope's
#   `scheduled_at` (the appointment), EXACTLY the timer-arm tf_arm makes for
#   timer_fire_at. COMPUTES nothing and WRITES no envelope field (scheduled_at
#   is the producer's, set at creation). A non-pair dossier or a
#   missing/unparseable scheduled_at is REJECTED — fail CLOSED, NO timer (the
#   tf_arm-on-bad-created_at discipline). Echoes the armed fire_at (scheduled_at).
pair_arm() {
  local bearer="${1:-}" did="${2:-}" rec kind at
  [[ -n "$did" ]] || { echo "ready-to-pair: arm — need <dossier_id>" >&2; return 2; }
  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "ready-to-pair: arm — dossier '$did' not found OR not authorized (§9.1 chokepoint collapses 401/absent; no second auth path — C4)" >&2; return 1; }
  kind=$(printf '%s' "$rec" | jq -r '.kind // ""' 2>/dev/null) || kind=""
  if [[ "$kind" != "pair" ]]; then
    echo "ready-to-pair: arm REJECTED — dossier '$did' kind='$kind' is not 'pair' (pair_arm schedules a collaborative-stage session — §4.2)" >&2
    return 2
  fi
  at=$(printf '%s' "$rec" | jq -r '.scheduled_at // ""' 2>/dev/null) || at=""
  if ! tf__rfc_to_epoch "$at" >/dev/null 2>&1; then
    echo "ready-to-pair: arm REJECTED — dossier '$did' scheduled_at '$at' missing/unparseable (§0.4 RFC-3339 …Z); fail-closed, NO timer" >&2
    return 3
  fi
  co_request "$bearer" timer-arm "$did" "$at" \
    || { echo "ready-to-pair: arm — §2.2 timer-arm failed for '$did'@$at" >&2; return 4; }
  printf '%s' "$at"
}

# ════════════════════════════════════════════════════════════════════════════
# N10-10 (claude-tools-l6vx) — THE PRODUCER (bash twin of cf/src/timer.js
# pairCreate). Build a `kind:"pair"` SESSION CARD and arm it on the §2.2 timer
# at `scheduled_at`, in ONE call. N3 (uxg6) realized the reserved `kind:"pair"`
# discriminator + the arm/surface fire-action + Inbox rendering, but left "a
# real PRODUCER that creates kind:'pair' dossiers" a follow-up — nothing
# PRODUCED one. This is that surface.
# ════════════════════════════════════════════════════════════════════════════
# pair_create <bearer> <bead_ref> <scheduled_at> [tldr] [full_detail] [dossier_id]
#   Compose do_dossier_put (the §4.1 + §5.1-CORE write gate) + pair_arm (§2.2
#   arm) in ONE call, so a CLIENT crash between two manual calls can't strand a
#   written-but-un-armed pair (which would render "upcoming" forever, never
#   promoting / firing the blocking ping). NOT all-or-nothing: a rare arm
#   failure after the write returns nonzero with the dossier written — re-run to
#   re-arm (the deterministic id re-puts + re-arms; idempotent). The
#   envelope is the canonical pair shape (kind:"pair", trigger
#   proactive_checkpoint, tier blocking, a conformant §5 body, items:[]) —
#   byte-identical to the N3 oracle fixture `mkpair`. The id is deterministic
#   (`pair-<bead_ref>` unless an explicit id is passed), so re-running RE-PUTS
#   (re-schedules) the same card. A missing bead_ref / unparseable scheduled_at
#   / unsafe id is REJECTED fail-closed (NO dossier), the pair_arm discipline
#   applied BEFORE the write. Echoes the dossier id on success.
pair_create() {
  local bearer="${1:-}" bref="${2:-}" sa="${3:-}" tldr="${4:-}" fd="${5:-}" did="${6:-}"
  local bound created env id
  [[ -n "$bref" ]] || { echo "ready-to-pair: create — need <bead_ref> (the bead the session pairs on — §4.1)" >&2; return 2; }
  if ! tf__rfc_to_epoch "$sa" >/dev/null 2>&1; then
    echo "ready-to-pair: create REJECTED — scheduled_at '$sa' missing/unparseable (§0.4 RFC-3339 …Z); fail-closed, NO dossier (the pair_arm-on-bad-scheduled_at discipline applied BEFORE the write)" >&2
    return 3
  fi
  id="${did:-pair-$bref}"
  if ! co__safe_key "$id"; then
    echo "ready-to-pair: create REJECTED — dossier id '$id' unsafe ([A-Za-z0-9._-], no '..'; §0.4) — pass an explicit safe <dossier_id> when the bead_ref is not key-safe" >&2
    return 2
  fi
  bound="$(do__bound_sv)" || bound=""
  [[ -n "$bound" ]] || { echo "ready-to-pair: create — 'dossier' absent from the §4 registry (co__schema_version) — store-surface contract gap (§0.5)" >&2; return 4; }
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || created="$sa"
  [[ -n "$tldr" ]] || tldr="pair on $bref"
  [[ -n "$fd"   ]] || fd="A scheduled collaborative-stage working session on $bref."
  env="$(jq -cn --arg id "$id" --argjson sv "$bound" --arg br "$bref" \
               --arg sa "$sa" --arg ca "$created" --arg tldr "$tldr" --arg fd "$fd" '
    { id:$id, schema_version:$sv, kind:"pair", trigger:"proactive_checkpoint",
      bead_ref:$br, tier:"blocking", created_at:$ca, timer_fire_at:null,
      scheduled_at:$sa,
      body:{ dossier_schema_version:$sv, tldr:$tldr, sections:[], diagrams:[], full_detail:$fd },
      items:[] }')" \
    || { echo "ready-to-pair: create — could not assemble the kind:\"pair\" envelope for '$id'" >&2; return 4; }
  # 1) Persist through the §4.1 + §5.1-CORE write gate.
  do_dossier_put "$bearer" "$env" >/dev/null \
    || { echo "ready-to-pair: create — dossier-put rejected the kind:\"pair\" envelope for '$id' (§4.1/§5.1 write gate)" >&2; return 5; }
  # 2) Arm the §2.2 timer at scheduled_at (pair_arm re-reads + validates the
  #    just-written record, so the two steps cannot drift). A rare arm failure
  #    is surfaced; the dossier is written, so re-running re-arms it.
  pair_arm "$bearer" "$id" >/dev/null \
    || { echo "ready-to-pair: create — §2.2 pair_arm failed for '$id' (the dossier is written; re-run to re-arm)" >&2; return 6; }
  printf '%s' "$id"
}

# pair_surface <bearer> <dossier_id>
#   The SURFACE fire-action (opposite of tf_fire's auto-proceed). Fire the
#   blocking `ready_to_pair` notification through the N1 catalog spine
#   (notif_fire) — that EMITS the §4.3 row (tier mirrored; ready_to_pair binds
#   `blocking`), which N2 pushes to the phone. NO item is applied; NO §5.3
#   consequence runs (a pair envelope is not iterated as §5 Items — §4.2). NO
#   timer-ack: per §4.3 timer-ack is the stop-re-surfacing primitive once Brian
#   OPENS the session, so a re-surface (S-6 poll) is harmless — notif_fire is
#   idempotent (one-per-Dossier) and N2's deliver-once ledger guarantees one
#   push. Echoes the fired notification id; a notif_fire failure is OBSERVABLE
#   (a mis-tiered pair dossier the §10.2 guard rejects) and never crashes the
#   poll (returns nonzero, sibling continues — AD7).
pair_surface() {
  local bearer="${1:-}" did="${2:-}" rec kind nid
  [[ -n "$did" ]] || { echo "ready-to-pair: surface — need <dossier_id>" >&2; return 2; }
  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "ready-to-pair: surface — dossier '$did' not found OR not authorized (§9.1 collapses 401/absent — C4)" >&2; return 1; }
  kind=$(printf '%s' "$rec" | jq -r '.kind // ""' 2>/dev/null) || kind=""
  if [[ "$kind" != "pair" ]]; then
    # Not a pair session — nothing to surface (informational no-op success,
    # mirroring tf_fire's non-timed-fyi no-op; the §4.1 kind drives this).
    echo "ready-to-pair: surface — dossier '$did' kind='$kind' not 'pair'; nothing to surface — no-op" >&2
    return 0
  fi
  if nid="$(notif_fire "$bearer" ready_to_pair "$did")"; then
    printf '%s' "$nid"
    return 0
  fi
  echo "ready-to-pair: surface — WARN notif_fire(ready_to_pair,'$did') did not fire; a pair dossier MUST be tier 'blocking' (§10.2 r10). Observable, not silent; idempotent retry is safe (AD7)." >&2
  return 5
}

# ════════════════════════════════════════════════════════════════════════════
# L1 follow-up (claude-tools-653d) — §5.6 SNOOZE (bash twin of cf/src/timer.js
# dossierSnooze / snoozeSurface). The §5.6 verb family's third member
# (do_dossier_defer / do_dossier_escalate are the others, in dossier.sh): DEFER a
# blocking decision card NOW + arm the §2.2 timer to RE-SURFACE it (NOT
# auto-proceed) at a user-set snooze_until — the SAME fire=SURFACE primitive
# ready-to-pair built (pair_surface), a DISTINCT fire handler from tf_fire's
# auto-proceed. `snoozed_until` is the tf_poll routing discriminator (a snoozed
# card keeps its original `kind`, so it cannot route by kind). NO payload
# defaulting (the uxl1b contract). Lives HERE (not dossier.sh) because it consumes
# the §2.2 timer arm + the tf__rfc helpers + the tf_poll routing — all in this
# module (mirroring the CF op riding TIMER_OPS, not DOSSIER_OPS).
# ════════════════════════════════════════════════════════════════════════════
# do_dossier_snooze <bearer> <dossier_id> <snooze_until>
#   DEFER now (tier→digest, out of the foreground) + arm the §2.2 re-surface
#   timer at snooze_until. snooze_until MUST be a FUTURE RFC-3339 …Z (§0.4) —
#   fail-closed (NO write, NO timer) on missing/unparseable/non-future (the
#   tf_arm/pair_arm bad-time discipline; never guess a fire time). Writes BOTH the
#   validated §4.1 timer_fire_at (what the substrate/poll fires on) AND the
#   un-validated snoozed_until (the tf_poll routing discriminator) = snooze_until.
#   NOT idempotent — always (re)writes + (re)arms (a new snooze_until
#   re-schedules). Echoes the armed snooze_until. JS twin: dossierSnooze.
do_dossier_snooze() {
  local bearer="${1:-}" did="${2:-}" su="${3:-}" rec ep now_ep upd
  [[ -n "$did" ]] || { echo "snooze: arm — need <dossier_id> (§4.1)" >&2; return 2; }
  [[ -n "$su"  ]] || { echo "snooze: arm — need <snooze_until> (§0.4 RFC-3339 …Z)" >&2; return 2; }
  ep="$(tf__rfc_to_epoch "$su")" \
    || { echo "snooze: arm REJECTED — snooze_until '$su' unparseable (§0.4 RFC-3339 …Z); fail-closed, NO timer" >&2; return 3; }
  now_ep="$(tf__rfc_to_epoch "$(tf__now_rfc)")" || now_ep=""
  if [[ -n "$now_ep" && "$ep" -le "$now_ep" ]]; then
    echo "snooze: arm REJECTED — snooze_until '$su' is not in the future (a snooze RE-SURFACES later, not now); fail-closed, NO timer" >&2
    return 3
  fi
  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "snooze: arm — dossier '$did' not found OR not authorized (§9.1 chokepoint collapses 401/absent; no second auth path — C4)" >&2; return 1; }
  # DEFER out of the foreground (tier→digest) AND write the re-surface timer
  # fields, in ONE write. snoozed_until is the routing discriminator; timer_fire_at
  # is the validated §4.1 field the substrate/poll fires on — BOTH = snooze_until.
  upd=$(printf '%s' "$rec" | jq -c --arg t "$su" '.tier="digest" | .timer_fire_at=$t | .snoozed_until=$t' 2>/dev/null) \
    || { echo "snooze: arm — could not assemble the snoozed envelope for '$did'" >&2; return 4; }
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?
  # Arm the §2.2 one-shot fire(dossier_id) @ snooze_until via the §2.3 front door.
  co_request "$bearer" timer-arm "$did" "$su" \
    || { echo "snooze: arm — §2.2 timer-arm failed for '$did'@$su" >&2; return 5; }
  printf '%s' "$su"
}

# snooze_surface <bearer> <dossier_id>
#   The §5.6 snooze FIRE-action (mirror of pair_surface: SURFACE, not
#   auto-proceed). RE-tier the card back to the foreground (digest→blocking),
#   CLEAR the snooze fields (timer_fire_at + snoozed_until → null: the timer
#   fired, no longer snoozed), best-effort timer-ack (stop the S-6 poll
#   re-surfacing), and best-effort re-fire the blocking `new_dossier` ping. NO
#   item applied, NO §5.3 consequence (the OPPOSITE of tf_fire's auto-apply). A
#   card no longer snoozed is an informational no-op success (mirroring
#   pair_surface's non-pair no-op). Echoes the fired notification id. JS twin:
#   snoozeSurface. RE-PUSH CAVEAT: a notif already in N2's deliver-once ledger
#   will NOT re-push (the pair_surface property) — observable, never crashes.
snooze_surface() {
  local bearer="${1:-}" did="${2:-}" rec snz upd nid
  [[ -n "$did" ]] || { echo "snooze: surface — need <dossier_id>" >&2; return 2; }
  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "snooze: surface — dossier '$did' not found OR not authorized (§9.1 collapses 401/absent — C4)" >&2; return 1; }
  snz=$(printf '%s' "$rec" | jq -r '.snoozed_until // ""' 2>/dev/null) || snz=""
  if [[ -z "$snz" ]]; then
    # Not (or no longer) snoozed — nothing to surface (informational no-op success).
    echo "snooze: surface — dossier '$did' is not snoozed; nothing to surface — no-op" >&2
    return 0
  fi
  # RE-tier to the foreground + clear the snooze fields, in ONE write.
  upd=$(printf '%s' "$rec" | jq -c '.tier="blocking" | .timer_fire_at=null | .snoozed_until=null' 2>/dev/null) \
    || { echo "snooze: surface — could not re-tier '$did' to blocking" >&2; return 4; }
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?
  # Best-effort disarm the substrate timer (stop the S-6 poll re-surfacing).
  co_request "$bearer" timer-ack "$did" >/dev/null 2>&1 || true
  # Best-effort re-fire the blocking new_dossier ping (the card is tier=blocking
  # after the re-tier, so the §10.2 tier-guard passes; new_dossier binds blocking).
  if nid="$(notif_fire "$bearer" new_dossier "$did")"; then
    printf '%s' "$nid"
    return 0
  fi
  echo "snooze: surface — WARN notif_fire(new_dossier,'$did') did not fire; observable, not silent; idempotent retry is safe (AD7)." >&2
  return 5
}

# ════════════════════════════════════════════════════════════════════════════
# S-6 poll-fallback DRIVER — a missed alarm degrades to fire-on-next-poll
# ════════════════════════════════════════════════════════════════════════════
# tf_poll <bearer> [now_rfc3339]
#   Ask the T4 §2.2 surface (via the §2.3 front door) for every armed, un-acked
#   timer whose fire_at ≤ now (`timer-due` IS the S-6 poll-fallback — T4 has no
#   alarm daemon) and run the kind-routed fire-action for each. The §2.2 timer
#   namespace is SHARED (N3 §4.3): a `kind:"pair"` due timer SURFACES (fire the
#   blocking ready_to_pair notif — NEVER auto-proceed); every other kind runs
#   the SHARED auto-proceed handler tf_fire (itself a no-op on a non-timed-fyi
#   tier). Whether the alarm fired, was suppressed, or raced this poll, the
#   §7.4 per-Item latch makes every auto-proceed exactly-once. Echoes each
#   fired dossier id (observability).
tf_poll() {
  local bearer="${1:-}" now="${2:-}" due id rec kind snz rc=0
  due="$(co_request "$bearer" timer-due "$now" 2>/dev/null)" \
    || { echo "timed-fyi: poll — T4 §2.2 timer-due query failed" >&2; return 1; }
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # ROUTE (DESIGN N §4.3) — the §2.2 namespace is SHARED across THREE
    # fire-actions. Read the due dossier ONCE and route:
    #   • a SNOOZED card (snoozed_until set — §5.6) RE-SURFACES. Checked FIRST: a
    #     snoozed dossier keeps its original `kind` (e.g. "decide"), so it cannot
    #     route by kind, and it MUST NOT fall through to tf_fire (auto-proceed).
    #   • a `kind:"pair"` card SURFACES the blocking ready_to_pair notif.
    #   • everything else runs the SHARED auto-proceed handler tf_fire (itself a
    #     no-op on a non-timed-fyi tier).
    rec=$(do_dossier_get "$bearer" "$id" 2>/dev/null) || rec=""
    kind=$(printf '%s' "$rec" | jq -r '.kind // ""' 2>/dev/null) || kind=""
    snz=$(printf '%s' "$rec" | jq -r '.snoozed_until // ""' 2>/dev/null) || snz=""
    if [[ -n "$snz" ]]; then
      if snooze_surface "$bearer" "$id" >/dev/null; then
        printf '%s\n' "$id"
      else
        echo "timed-fyi: poll — snooze_surface('$id') reported a WARN (notif-fire failure observable; idempotent)" >&2
        printf '%s\n' "$id"; rc=5
      fi
    elif [[ "$kind" == "pair" ]]; then
      if pair_surface "$bearer" "$id" >/dev/null; then
        printf '%s\n' "$id"
      else
        echo "timed-fyi: poll — pair_surface('$id') reported a WARN (notif-fire failure observable; idempotent)" >&2
        printf '%s\n' "$id"; rc=5
      fi
    elif tf_fire "$bearer" "$id"; then
      printf '%s\n' "$id"
    else
      echo "timed-fyi: poll — tf_fire('$id') reported a per-item WARN (S-6 still exactly-once via the §7.4 latch)" >&2
      printf '%s\n' "$id"; rc=5
    fi
  done <<< "$due"
  return "$rc"
}
