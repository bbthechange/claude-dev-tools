# shellcheck shell=bash
# beads-runner/lib/consequence.sh — T5.3 IDEMPOTENT per-Item CONSEQUENCE APPLIER
#                                   (claude-tools-o0u; epic claude-tools-glk).
# ════════════════════════════════════════════════════════════════════════════
# OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
#
#   • §5.3 ConsequenceBlock APPLICATION. Given a per-Item `ConsequenceBlock`
#     (`cb_schema_version 1`: creates / unblocks / labels / status_changes) it
#     applies it against the WORK PLANE (beads/Dolt) via the ESTABLISHED `bd`
#     surface — control→work (§1.1, §7.3). The same bd CLI surface
#     run-beads-tasks.sh uses; best-effort-guarded the SAME way (a work-plane
#     blip never strands the control-plane latch). §0.3 is bound on the block:
#     a `cb_schema_version` ≠ the bound value is REJECTED, never best-parsed.
#
#   • §7.4 PER-ITEM idempotency LAYER (the apply LOGIC, AD3.4 per-Item /
#     AD1 DO-per-Item). The `consequence_applied` latch (the T5.1 §4.1.1
#     STRUCTURE) flips false→true EXACTLY ONCE keyed on the Item `id` (§0.4).
#     The whole read→route→APPLY→latch→state→persist runs inside the T5.1
#     per-dossier single-writer critical section (`do__with_dossier_lock`) so
#     a human DOUBLE-TAP and a §2.2 timer-fire racing the poll-fallback (S-6)
#     each apply the consequence EXACTLY ONCE: a second caller takes the lock
#     AFTER the first, sees the latch already true, and returns idempotent
#     success having applied NOTHING. "One item response ⇒ applied once."
#     ORDERING: the work-plane apply runs BEFORE the latch flips (apply-then-
#     latch, both under the one lock) — the latch claims "applied" only after
#     the bd surface has been driven, never before.
#
#   • REALIZATION BOUNDARY (honest, non-normative — the §0.2/Appendix-A
#     discipline T5.1 uses for AD1 single-threadedness). The NORMATIVE
#     exactly-once §7.4 legislates is the LATCH (the strongly-consistent
#     CONTROL plane, §2.1) — delivered here under the single-writer lock. The
#     ConsequenceBlock targets the EVENTUAL WORK plane (beads/Dolt, §1); the
#     established surface (run-beads-tasks.sh) treats every `bd` call as
#     non-fatal (`|| true`) precisely because that plane is eventual and a
#     blip MUST NOT kill the path. So a work-plane op that fails mid-apply is
#     applied AT-MOST-ONCE and is made OBSERVABLE (a WARN on stderr, never
#     swallowed) rather than silently retried — retry is unsafe because `bd`
#     ops are not idempotent (a re-run `bd create` duplicates a bead). A
#     transactional work-plane outbox is the non-normative Cloudflare
#     realisation; the frozen §7.4/§5.3 text does not legislate work-plane-
#     outage-mid-apply, so this is a documented realisation choice, NOT a
#     local interface divergence (no §11 gap to amend).
#
#   • §5.2.2 PER-ITEM routing (Flow B step 5). A PURE un-edited
#     `approve-reject` / `pick-option` / `approve-recommendation` response ⇒
#     DETERMINISTICALLY apply that item's pre-declared block, idempotently
#     (§0.B / principle 5 — the common path is deterministic and instantly
#     trustworthy). A `freeform-edit` / edited / `object` response ⇒ the
#     RECONCILER path: emit a follow-up Dossier SCOPED TO THIS ITEM (the item
#     + its response carried VERBATIM for interpretation), NEVER re-opening
#     resolved siblings. A `decision:"object"` on a `fyi-objectable` item
#     (the human objected to an auto-proceed) routes here too — the OBJECTION
#     is interpreted by the reconciler. The auto-proceed TIMING / unobjected
#     fire of a `fyi-objectable` item is the §2.2 timer (T5.4) calling THIS
#     entrypoint with a proceed response; T5.3 owns only the idempotent apply,
#     never the timer (the §2.2 boundary).
#
#   • STRICT per-Item scope (AD1 DO-per-Item ⇒ partial application clean BY
#     CONSTRUCTION): resolving item X applies ONLY X's block, flips ONLY X's
#     latch, moves ONLY X's state. Sibling Items are byte-identical across the
#     write. Resolving 6 of 15 leaves the other 9 open, blocking nothing (AD7).
#
#   • The idempotent per-Item apply ENTRYPOINT `do_item_apply` — the single
#     surface T5.4 (the §2.2 timed auto-proceed) calls on alarm-fire AND on
#     poll-fallback; idempotent by construction so S-6 needs no extra dedup.
#
# MUST NOT TOUCH (sibling surfaces — drift is a BLOCKING escalation, §11):
#   • §4.1 envelope / §4.1.1 per-Item record / per-Item STATE-MACHINE
#     INTERNALS + the latch/dedup PRIMITIVE structures — T5.1 (claude-tools-
#     fuy). This file is a CONSUMER of T5.1's PUBLIC surface only
#     (`do_dossier_get`, `do_dossier_put`, the PURE `do_item_state_check`, and
#     the exposed single-writer critical-section primitive
#     `do__with_dossier_lock`). It NEVER re-implements the §4 store, the
#     envelope/§4.1.1 validation, or the state-machine legality table; it
#     NEVER calls a T5.1 `do__*_locked` internal. The latch+state+block
#     ORCHESTRATION is exactly the "§7.4 apply LOGIC (T5.3)" T5.1's header
#     hands off — owned HERE, atomically, under T5.1's lock.
#   • §5 GENERATION of `body` / `items[]` §5 content — T5.2 (claude-tools-9gt).
#     This file binds the FROZEN §5.3 schema ONLY; it NEVER synthesises
#     tldr/sections/diagrams/full_detail or any §5 item field. The reconciler
#     follow-up carries the original item's §5 fields VERBATIM (copied, never
#     generated) under an OPAQUE reconcile-pointer body; turning that into a
#     full §5 dossier is T5.2 (generation) / T5.5 (reconcile LOGIC).
#   • §2.2 durable-timer WIRING — T5.4 (claude-tools-it2). This file EXPOSES
#     the idempotent entrypoint; it arms/acks NO timer and reads no
#     `timer_fire_at`.
#   • §7.4 DOSSIER-level `task_ref` dedup + §7.3 S-2 reconcile control→work
#     for the STUCK double-trigger — T5.5 (claude-tools-j7f). That is the
#     DISTINCT (dossier-level) latch; this file is the PER-ITEM layer only and
#     never consults/writes the `task_ref` dedup record.
#   • §4.3 Notification — T5.6 (claude-tools-ks2).
#   • T4 store INTERNALS — reached only transitively through the T5.1 surface.
#
# ANTI-DRIFT: binds INTERFACE.md v1 §5.3 / §7.4 (per-Item layer) / §5.2.2 /
#   §0.4 / §0.3. An interface gap or contradiction is a BLOCKING escalation
#   (reopen claude-tools-65z, amend+bump+re-freeze, Brian sign-off) — never
#   diverge locally.
#
# Safe to `source` under `set -euo pipefail`: only function definitions below;
# every fallible call is guarded. Requires `jq` and the `bd` CLI on PATH (the
# established work-plane surface; the focused test injects a logging fake the
# SAME way the conformance harness / test-local-agent.sh do).
# ════════════════════════════════════════════════════════════════════════════

# ── consume the T5.1 substrate PUBLIC surface ────────────────────────────────
# This file is a CONSUMER of T5.1 (claude-tools-fuy). It sources dossier.sh
# (which transitively sources the T4 coordinator.sh) the way the focused T5.1
# test does, binding ONLY to its public surface:
#   do_dossier_get / do_dossier_put — the §4.1 envelope round-trip (control)
#   do_item_state_check             — the PURE §4.1.1/§5.2 legality table
#   do__with_dossier_lock           — the exposed single-writer critical
#                                     section (the SAME primitive T5.1's own
#                                     latch/state ops and the T4 store/Lease
#                                     stand on; reused, not re-implemented)
#   do__bound_sv                    — the §0.3 bound schema version (read from
#                                     the T4 §4 registry, never restated)
con__lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
if ! declare -F do_dossier_get >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(con__lib_dir)/dossier.sh"
fi

# ════════════════════════════════════════════════════════════════════════════
# §5.3 ConsequenceBlock → WORK PLANE via the established `bd` surface
# ════════════════════════════════════════════════════════════════════════════
# do__bd <args...> — the ONE work-plane chokepoint. Bare `bd` (the established
#   surface run-beads-tasks.sh uses); NON-FATAL exactly as that script guards
#   every bd call (`|| true`) so a work-plane blip never kills the per-Item
#   apply path. UNLIKE a blind `2>/dev/null`, a nonzero `bd` is surfaced as a
#   WARN on stderr (observable, NEVER silent — the realisation-boundary
#   discipline in the header): on the eventual work plane a failed op is
#   at-most-once, but it MUST be visible, not swallowed. Overridable on PATH
#   for the focused test (the conformance / test-local-agent fake-bin pattern).
do__bd() {
  local rc=0
  bd "$@" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "consequence: WARN — work-plane \`bd ${1:-}\` exited $rc (eventual plane, §1; non-fatal per the established surface) — ConsequenceBlock may be incompletely applied; observable, not silent" >&2
  fi
  return 0
}

# do__cb_validate <cb_json> — bind the FROZEN §5.3 schema. The block MUST be a
#   JSON object whose `cb_schema_version` is an integer EQUAL to the bound
#   value (§0.3: an unknown-higher cb version is REJECTED, never best-effort-
#   parsed); the four action arrays, when present, MUST be arrays. Returns 0
#   iff well-formed; a §-cited diagnostic + nonzero otherwise (NO bd op runs).
do__cb_validate() {
  local cb="${1:-}" bound; bound="$(do__bound_sv)"
  printf '%s' "$cb" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "consequence: reject — ConsequenceBlock not an object (§5.3)" >&2; return 2; }
  local sv
  sv=$(printf '%s' "$cb" | jq -r '
        if (.cb_schema_version|type)=="number"
           and (.cb_schema_version == (.cb_schema_version|floor))
        then .cb_schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "consequence: reject — ConsequenceBlock missing integer cb_schema_version (§5.3 'int' / §0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "consequence: reject — cb_schema_version $sv is an unknown higher version (bound=$bound; §0.3, never best-effort-parse)" >&2; return 3
  fi
  if [[ "$sv" -ne "$bound" ]]; then
    echo "consequence: reject — cb_schema_version $sv unsupported (binds v$bound only; §0.3)" >&2; return 3
  fi
  printf '%s' "$cb" | jq -e '
    (((.creates)        // []) | type=="array") and
    (((.unblocks)       // []) | type=="array") and
    (((.labels)         // []) | type=="array") and
    (((.status_changes) // []) | type=="array")' >/dev/null 2>&1 || {
    echo "consequence: reject — §5.3 creates/unblocks/labels/status_changes must each be arrays" >&2; return 3; }
  return 0
}

# do__apply_cb <cb_json> — APPLY a §5.3 ConsequenceBlock against the WORK
#   PLANE (control→work). Pure-side-effect on beads; no control-plane write
#   here (the caller, holding the single-writer lock, owns the latch/state).
#     creates[]        → bd create … ; each deps[] → bd dep add <new> <dep>
#                        (the new id scraped from `✓ Created issue: <id> — …`
#                        — the SAME scrape run-beads-tasks.sh uses)
#     unblocks[]       → bd update <ref> --status=open  (BC-15 release-to-open;
#                        the inverse of the §7.3 status=blocked STUCK fork —
#                        control→work)
#     labels[]         → bd update <ref> --add-label … --remove-label …
#     status_changes[] → bd update <ref> --status <to_status>
#   Deterministic field order; an absent array is a no-op. Empty block ⇒ a
#   clean no-op (a pre-declared "reject ⇒ nothing happens" block is valid §5.3).
#   §5.3 lists { title, type, priority, labels[], description, deps[] } with NO
#   declared defaults — an ABSENT type/priority/description is OMITTED from the
#   `bd create` invocation (bd's own default applies), NEVER synthesised here:
#   inventing a §5.3 value would be content the applier must only BIND, not
#   author (anti-drift — §5 authorship is T5.2).
do__num() {  # echo a non-negative int, 0 on any non-numeric/empty (real guard)
  local v="${1:-0}"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'; }
do__apply_cb() {
  local cb="${1:-}" n i

  # creates[] — { title, type, priority, labels[], description, deps[] }
  n=$(do__num "$(printf '%s' "$cb" | jq -r '((.creates)//[])|length' 2>/dev/null)")
  for ((i=0; i<n; i++)); do
    local title typ pri desc lbls out newid d dn dj args
    title=$(printf '%s' "$cb" | jq -r --argjson i "$i" '.creates[$i].title // ""' 2>/dev/null)
    typ=$(printf '%s' "$cb"   | jq -r --argjson i "$i" '.creates[$i].type     // ""' 2>/dev/null)
    pri=$(printf '%s' "$cb"   | jq -r --argjson i "$i" 'if (.creates[$i].priority|type)=="number" then (.creates[$i].priority|tostring) else "" end' 2>/dev/null)
    desc=$(printf '%s' "$cb"  | jq -r --argjson i "$i" '.creates[$i].description // ""' 2>/dev/null)
    lbls=$(printf '%s' "$cb"  | jq -r --argjson i "$i" '((.creates[$i].labels)//[])|join(",")' 2>/dev/null)
    [[ -n "$title" ]] || continue
    # Omit absent §5.3 fields — never synthesise a default value.
    args=(create --title "$title")
    [[ -n "$typ"  ]] && args+=(--type "$typ")
    [[ -n "$pri"  ]] && args+=(-p "$pri")
    [[ -n "$lbls" ]] && args+=(--labels "$lbls")
    [[ -n "$desc" ]] && args+=(-d "$desc")
    out=$(do__bd "${args[@]}")
    # Scrape the new id (BC-18 stdout shape) — identical to run-beads-tasks.sh.
    newid=$(printf '%s' "$out" | sed -n 's/.*issue: \([^ ]*\).*/\1/p' | head -1)
    if [[ -n "$newid" ]]; then
      dn=$(do__num "$(printf '%s' "$cb" | jq -r --argjson i "$i" '((.creates[$i].deps)//[])|length' 2>/dev/null)")
      for ((dj=0; dj<dn; dj++)); do
        d=$(printf '%s' "$cb" | jq -r --argjson i "$i" --argjson j "$dj" '.creates[$i].deps[$j]' 2>/dev/null)
        [[ -n "$d" ]] && do__bd dep add "$newid" "$d"
      done
    fi
  done

  # unblocks[] — bead_refs released back to open (BC-15; control→work)
  while IFS= read -r ref; do
    [[ -n "$ref" ]] && do__bd update "$ref" --status=open
  done < <(printf '%s' "$cb" | jq -r '((.unblocks)//[])[]' 2>/dev/null)

  # labels[] — { bead_ref, add[], remove[] }
  n=$(do__num "$(printf '%s' "$cb" | jq -r '((.labels)//[])|length' 2>/dev/null)")
  for ((i=0; i<n; i++)); do
    local ref args a
    ref=$(printf '%s' "$cb" | jq -r --argjson i "$i" '.labels[$i].bead_ref // ""' 2>/dev/null)
    [[ -n "$ref" ]] || continue
    args=()
    while IFS= read -r a; do [[ -n "$a" ]] && args+=(--add-label "$a"); done \
      < <(printf '%s' "$cb" | jq -r --argjson i "$i" '((.labels[$i].add)//[])[]' 2>/dev/null)
    while IFS= read -r a; do [[ -n "$a" ]] && args+=(--remove-label "$a"); done \
      < <(printf '%s' "$cb" | jq -r --argjson i "$i" '((.labels[$i].remove)//[])[]' 2>/dev/null)
    [[ ${#args[@]} -gt 0 ]] && do__bd update "$ref" "${args[@]}"
  done

  # status_changes[] — { bead_ref, to_status }
  n=$(do__num "$(printf '%s' "$cb" | jq -r '((.status_changes)//[])|length' 2>/dev/null)")
  for ((i=0; i<n; i++)); do
    local ref to
    ref=$(printf '%s' "$cb" | jq -r --argjson i "$i" '.status_changes[$i].bead_ref // ""' 2>/dev/null)
    to=$(printf '%s' "$cb"  | jq -r --argjson i "$i" '.status_changes[$i].to_status // ""' 2>/dev/null)
    [[ -n "$ref" && -n "$to" ]] && do__bd update "$ref" --status="$to"
  done
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# §5.2.2 PER-ITEM routing — pure-deterministic vs. reconciler
# ════════════════════════════════════════════════════════════════════════════
# do__is_deterministic <item_json> <response_json> — 0 iff this is the PURE
#   un-edited common path: decision ∈ {approve,reject,pick}, NO `edited_value`,
#   item `kind` ∈ {approve-reject,pick-option,approve-recommendation}. Anything
#   else — decision ∈ {edit,freeform,object}, an `edited_value` present, or a
#   `freeform-edit`/`fyi-objectable` kind — is the RECONCILER path. PURE.
do__is_deterministic() {
  local item="${1:-}" resp="${2:-}" dec kind edited
  dec=$(printf '%s'  "$resp" | jq -r '.decision // ""' 2>/dev/null) || dec=""
  kind=$(printf '%s' "$item" | jq -r '.kind // ""'     2>/dev/null) || kind=""
  edited=$(printf '%s' "$resp" | jq -r 'if has("edited_value") and .edited_value!=null then "y" else "n" end' 2>/dev/null) || edited="n"
  case "$kind" in approve-reject|pick-option|approve-recommendation) : ;; *) return 1 ;; esac
  [[ "$edited" == "n" ]] || return 1
  case "$dec" in approve|reject|pick) return 0 ;; *) return 1 ;; esac
}

# do__select_cb <item_json> <response_json> — echo the §5.3 block to apply.
#   `pick-option` ⇒ the CHOSEN option's `consequence_block` (matched on
#   `response.selected_option_id`); every other deterministic kind ⇒ the
#   item's own pre-declared `consequence_block`. Nonzero if unresolvable.
do__select_cb() {
  local item="${1:-}" resp="${2:-}" kind sel cb
  kind=$(printf '%s' "$item" | jq -r '.kind // ""' 2>/dev/null) || kind=""
  if [[ "$kind" == "pick-option" ]]; then
    sel=$(printf '%s' "$resp" | jq -r '.selected_option_id // ""' 2>/dev/null) || sel=""
    [[ -n "$sel" ]] || { echo "consequence: pick-option response has no selected_option_id (§5.2)" >&2; return 2; }
    cb=$(printf '%s' "$item" | jq -c --arg s "$sel" \
           'first((.options // [])[] | select(.option_id==$s) | .consequence_block) // empty' 2>/dev/null) || cb=""
    [[ -n "$cb" ]] || { echo "consequence: selected_option_id '$sel' not among this item's options (§5.2)" >&2; return 2; }
  else
    cb=$(printf '%s' "$item" | jq -c '.consequence_block // empty' 2>/dev/null) || cb=""
    [[ -n "$cb" ]] || { echo "consequence: item has no consequence_block (§5.2/§5.3)" >&2; return 2; }
  fi
  printf '%s' "$cb"
}

# do__emit_followup <bearer> <dossier_json> <item_json> <response_json>
#   The RECONCILER path's emitted artifact: a follow-up Dossier SCOPED TO THIS
#   ITEM. The original item's §5 fields are carried VERBATIM (copied, NEVER
#   synthesised — §5 generation is T5.2); `body` is an OPAQUE reconcile-pointer
#   (NOT §5 content). The carried item gets a fresh deterministic id and is
#   reset to a clean `open` §4.1.1 record (its OWN latch). Sibling Items of the
#   original are NOT carried and NOT touched — "scoped to the item, never
#   re-opening resolved siblings" (§5.2.2). Deterministic follow-up id so a
#   double-tap can never fork two follow-ups. Persisted via the T5.1 surface.
do__emit_followup() {
  local bearer="${1:-}" doss="${2:-}" item="${3:-}" resp="${4:-}"
  local odid oiid fid sv now env
  odid=$(printf '%s' "$doss" | jq -r '.id'       2>/dev/null) || odid=""
  oiid=$(printf '%s' "$item" | jq -r '.id'       2>/dev/null) || oiid=""
  # Guard the follow-up namespace: the same-item double-fork is already barred
  # by the per-Item latch (the entrypoint never reaches here twice for one
  # item). do__safe_key (T5.1) additionally rejects odid/oiid that could path-
  # escape or collide the `<odid>-fu-<oiid>` / `<oiid>-r1` namespace.
  do__safe_key "$odid" || { echo "consequence: reconciler — unsafe dossier id '$odid' for the follow-up namespace ([A-Za-z0-9._-], no '..')" >&2; return 2; }
  do__safe_key "$oiid" || { echo "consequence: reconciler — unsafe Item id '$oiid' for the follow-up namespace ([A-Za-z0-9._-], no '..')" >&2; return 2; }
  fid="${odid}-fu-${oiid}"
  sv="$(do__bound_sv)"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  # Carry §5 fields verbatim; reset ONLY the §4.1.1 record fields + a fresh id.
  env=$(jq -cn \
        --arg fid "$fid" --argjson sv "$sv" --arg now "$now" \
        --argjson doss "$doss" --argjson item "$item" --argjson resp "$resp" \
        --arg oiid "$oiid" '
        ($item
          | .id = ($oiid + "-r1")
          | .state = "open" | .response = null
          | .consequence_applied = false | .applied_at = null) as $carry
        | { id:$fid, schema_version:$sv,
            kind:($doss.kind), trigger:($doss.trigger),
            bead_ref:($doss.bead_ref), tier:($doss.tier),
            created_at:$now, timer_fire_at:null,
            body:{ reconcile_of:($doss.id), reconcile_item:$oiid,
                   reason:"freeform/edited/object — needs interpretation (§5.2.2 reconciler); §5 generation = T5.2/T5.5",
                   prior_response:$resp },
            items:[ $carry ] }' 2>/dev/null) || env=""
  [[ -n "$env" ]] || { echo "consequence: reconciler — could not build follow-up envelope" >&2; return 3; }
  do_dossier_put "$bearer" "$env" >/dev/null || return $?
  printf '%s' "$fid"
}

# ════════════════════════════════════════════════════════════════════════════
# THE IDEMPOTENT PER-ITEM APPLY ENTRYPOINT  (§5.3 + §7.4 per-Item + §5.2.2)
# ════════════════════════════════════════════════════════════════════════════
# do_item_apply <bearer> <dossier_id> <item_id> [response_json]
#
#   The single entrypoint a human-response path AND T5.4's §2.2 timed
#   auto-proceed (alarm-fire AND poll-fallback) call. Idempotent BY
#   CONSTRUCTION: the whole read→route→apply→latch→state→persist runs inside
#   the T5.1 per-dossier single-writer critical section, so a double-tap or an
#   alarm racing the poll-fallback (S-6) applies the consequence EXACTLY ONCE.
#
#   • Already-applied (latch true OR state `applied`) ⇒ return 0 having applied
#     NOTHING (the idempotent no-op the second caller hits).
#   • `expired` ⇒ rejected (an auto-proceed already lapsed is not an apply).
#   • `open` ⇒ requires <response_json> (records it, open→answered legal).
#     `answered` ⇒ uses the already-recorded `.response`.
#   • DETERMINISTIC (§5.2.2) ⇒ apply the selected §5.3 block to the work plane,
#     flip the latch, answered→applied — ONE atomic envelope write.
#   • RECONCILER (§5.2.2) ⇒ emit the item-scoped follow-up Dossier, flip the
#     latch (the consequence "reconciler dispatched" is itself exactly-once),
#     answered→applied. Resolved siblings untouched.
#   STRICT per-Item scope: only the target item's fields change; every sibling
#   is byte-identical across the write (AD1/AD7 partial application clean).
do_item_apply() {
  do__with_dossier_lock "${2:-}" do__item_apply_locked "$@"
}
do__item_apply_locked() {
  local bearer="${1:-}" did="${2:-}" iid="${3:-}" resp="${4:-}"
  local rec item st la now cb fid upd

  rec="$(do_dossier_get "$bearer" "$did")" \
    || { echo "consequence: apply — dossier '$did' not found OR not authorized (the §9.1 chokepoint collapses 401 and absent; no second auth path is added here — C4 seam)" >&2; return 1; }
  item=$(printf '%s' "$rec" | jq -c --arg i "$iid" \
           'first(.items[]? | select(.id==$i)) // empty' 2>/dev/null) || item=""
  [[ -n "$item" ]] || { echo "consequence: apply — Item '$iid' not in '$did' (§0.4)" >&2; return 1; }

  st=$(printf '%s' "$item" | jq -r '.state' 2>/dev/null) || st=""
  la=$(printf '%s' "$item" | jq -r '.consequence_applied' 2>/dev/null) || la=""

  # ── §7.4 PER-ITEM IDEMPOTENCY LAYER — the exactly-once gate ───────────────
  # Under the single-writer lock: a second caller (human double-tap, OR §2.2
  # alarm racing poll-fallback — S-6) sees the latch already true / state
  # already applied and returns idempotent success having applied NOTHING.
  if [[ "$la" == "true" || "$st" == "applied" ]]; then
    return 0
  fi
  if [[ "$st" == "expired" ]]; then
    echo "consequence: apply REJECTED — Item '$iid' is expired (auto-proceed already lapsed; §4.1.1/§5.2)" >&2
    return 2
  fi

  # ── record the response / open→answered (T5.1 PURE legality table) ────────
  if [[ "$st" == "open" ]]; then
    [[ -n "$resp" ]] || { echo "consequence: apply — open Item '$iid' needs a response_json (§4.1.1 .response)" >&2; return 2; }
    printf '%s' "$resp" | jq -e 'type=="object"' >/dev/null 2>&1 \
      || { echo "consequence: apply — response must be a JSON object (§4.1.1 .response)" >&2; return 2; }
    do_item_state_check open answered \
      || { echo "consequence: apply — open→answered illegal (T5.1 §4.1.1/§5.2)" >&2; return 2; }
  elif [[ "$st" == "answered" ]]; then
    # Use the already-recorded response; a passed response_json (e.g. a retry
    # carrying the same body) is ignored — the recorded one is authoritative.
    resp=$(printf '%s' "$item" | jq -c '.response // empty' 2>/dev/null) || resp=""
    [[ -n "$resp" ]] || { echo "consequence: apply — answered Item '$iid' has no recorded .response (§4.1.1)" >&2; return 2; }
  else
    echo "consequence: apply REJECTED — Item '$iid' in unexpected state '$st'" >&2
    return 2
  fi

  # answered→applied must be legal (T5.1 pure checker — no state-machine
  # re-implementation here; we only CONSULT the frozen legality table).
  do_item_state_check answered applied \
    || { echo "consequence: apply — answered→applied illegal (T5.1 §4.1.1/§5.2)" >&2; return 2; }

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  if do__is_deterministic "$item" "$resp"; then
    # ── §5.2.2 DETERMINISTIC: apply the pre-declared §5.3 block ─────────────
    cb="$(do__select_cb "$item" "$resp")" || return $?
    do__cb_validate "$cb" || return $?
    do__apply_cb "$cb"                       # control→work (best-effort bd)
    # ONE atomic envelope write: record response (if newly answered), flip the
    # §4.1.1 latch, stamp applied_at, answered→applied — ONLY this item.
    upd=$(printf '%s' "$rec" | jq -c \
            --arg i "$iid" --argjson r "$resp" --arg at "$now" '
            .items |= map(if .id==$i
              then (.response=$r | .consequence_applied=true
                    | .applied_at=$at | .state="applied")
              else . end)' 2>/dev/null) \
      || { echo "consequence: apply — could not update Item record" >&2; return 3; }
    do_dossier_put "$bearer" "$upd" >/dev/null || return $?
    return 0
  fi

  # ── §5.2.2 RECONCILER: emit the item-scoped follow-up Dossier ────────────
  # The consequence here IS "reconciler dispatched"; it too is exactly-once
  # (the same latch gates it). Resolved siblings are never re-opened.
  fid="$(do__emit_followup "$bearer" "$rec" "$item" "$resp")" || return $?
  upd=$(printf '%s' "$rec" | jq -c \
          --arg i "$iid" --argjson r "$resp" --arg at "$now" --arg fu "$fid" '
          .items |= map(if .id==$i
            then (.response=($r + {reconcile_followup:$fu})
                  | .consequence_applied=true
                  | .applied_at=$at | .state="applied")
            else . end)' 2>/dev/null) \
    || { echo "consequence: apply — could not update Item record (reconciler)" >&2; return 3; }
  do_dossier_put "$bearer" "$upd" >/dev/null || return $?
  return 0
}
