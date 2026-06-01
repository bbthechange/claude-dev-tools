# shellcheck shell=bash
# beads-runner/lib/dossier-gen.sh — T5.2 DOSSIER GENERATION: ONE structured
#                                   generation emitting the §5 body⊃items[]
#                                   (claude-tools-9gt; epic claude-tools-glk).
# ════════════════════════════════════════════════════════════════════════════
# OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
#
#   • §5 SOLE PRODUCER of the Dossier `body` ⊃ `items[]`
#     (`dossier_schema_version` 1). The whole §5 schema is produced by ONE
#     structured generation — `dg_generate` is a SINGLE call emitting the
#     entire body+items[], NOT four chained agents. The number of generation
#     passes is the tradeable §0.C mechanism (here: a single deterministic
#     authoring seam, swappable for a real model — §0.2); the SCHEMA and its
#     item-granularity are §0.A and are NEVER shrunk to a decision-singular
#     shape (the exact AD7 regression — PROHIBITED).
#
#   • §5.1 `body` — ALL FOUR tiers MANDATORY (AD7): `tldr` (non-empty),
#     `sections[]` (≥1 `{heading,prose}`, each non-empty — the skimmable
#     deep body), `diagrams[]` (`{caption,content}`; `content` MUST be
#     Mermaid source — v2 §11 amendment, prose/ASCII REJECTED; `[]` ONLY
#     when the matter is genuinely non-structural — a structural source MUST
#     yield ≥1 diagram), `full_detail` (non-empty stand-alone prose). None
#     optional. `dossier_schema_version` stamped from the single bound
#     source (§0.5; v2 = `2`, the §11 coarse single-source bump).
#
#   • §5.2 `items[]` — N independently-respondable Items. `kind` is the
#     CLOSED §5.2 response-affordance enum (distinct from the §4.1 dossier
#     `kind` C2 OPEN seam — that is T5.1's). MANDATORY
#     `context_anchor{where,expansion}` self-contained-context invariant: a
#     contextless ask is a CONTRACT VIOLATION, not a wording nit — an Item
#     lacking a non-empty `where`+`expansion` is REJECTED and NOTHING is
#     written (the "rejected" arm of the contract's "rejected/repaired";
#     synthesising context would paper over a contract violation — the
#     substrate's reject-malformed-never-best-effort discipline). `framing`
#     {ask(+why)} self-contained; `reversible` non-empty; `options`/
#     `recommendation` present per `kind`.
#
#   • §5.2.1 PROFILES — decision dossier (deep body + a `pick-option`, e.g.
#     `worker_stuck`), mixed multi-item UX/design review, and the Flow F
#     proactive overview (deep body + zero or all-`fyi-objectable` items).
#     ALL first-class, EMERGENT from body-depth × item-mix — NO schema branch
#     per profile: every profile flows through the SAME `dg__validate_dossier`
#     over the SAME `body`⊃`items[]` shape.
#
#   • §5.3 `ConsequenceBlock` (`cb_schema_version` 1) PRE-DECLARED per
#     Item/option, emitted MACHINE-APPLYABLE: T5.2 binds the FROZEN §5.3
#     schema as its producer-side gate (object; integer `cb_schema_version`
#     == the single bound version, §0.3; creates/unblocks/labels/
#     status_changes each an array). For `pick-option` EACH option carries
#     its own applyable block (the chosen-option block T5.3 selects at apply).
#
#   • Consumes the §7.2 worker structured ask (TL;DR · ask · options ·
#     recommendation+why · reversible) as RAW generation material
#     (`dg_from_worker_ask` → a `worker_stuck` decision dossier). Writes
#     THROUGH the T5.1 §4.1 envelope (`do_dossier_put`) — which re-enforces
#     §4.1/§0.3 and stamps `principal` at the ONE §9.1 chokepoint (no second
#     auth path; never a literal principal at this use site — C7).
#
# MUST NOT TOUCH (sibling surfaces — drift is a BLOCKING escalation, §11):
#   • §4.1 envelope / §4.1.1 per-Item record / per-Item STATE-MACHINE +
#     latch/dedup PRIMITIVE internals — T5.1 (claude-tools-fuy). This file is
#     a CONSUMER of T5.1's PUBLIC surface ONLY (`do_dossier_put`,
#     `do_dossier_validate`, `do__bound_sv`, `do__safe_key`); it NEVER
#     re-implements the §4 store, the envelope/§4.1.1 validation, the
#     state-machine legality table, or a `do__*_locked` internal. Emitted
#     Items carry a CLEAN §4.1.1 record (`state:"open"`, `response:null`,
#     `consequence_applied:false`, `applied_at:null`) — the substrate owns
#     their lifecycle thereafter.
#   • §5.3 ConsequenceBlock APPLICATION + §7.4 per-Item apply LOGIC + §5.2.2
#     deterministic/reconciler ROUTING — T5.3 (claude-tools-o0u). This file
#     binds the §5.3 SHAPE it must EMIT; it applies NOTHING, selects no
#     chosen block, flips no latch, moves no `.state`.
#   • §2.2 durable-timer WIRING — T5.4 (claude-tools-it2). `timer_fire_at` is
#     pass-through here (default `null`); T5.4 COMPUTES/ARMS it. No timer is
#     armed/acked/read here.
#   • §7.3/§7.4 DOSSIER-level `task_ref` dedup + S-2 reconcile — T5.5
#     (claude-tools-j7f). `dg_generate` is given the dossier `id`; WHICH
#     trigger wins / one-fork-one-dossier dedup / reconcile-back is T5.5.
#   • §4.3 Notification — T5.6 (claude-tools-ks2).
#   • §5 RENDERING (the body tiers / per-`kind` affordance controls / profile
#     presentation) — T6b (claude-tools-xre). This file is PRODUCER ONLY.
#   • T4 store INTERNALS — reached only transitively through the T5.1 surface.
#
# ANTI-DRIFT: binds INTERFACE.md v1 §5 / §5.1 / §5.2 / §5.2.1 / §5.3 / §0.3 /
#   §0.4 / §0.5 / §0.2. Consumers bind to THIS schema + item-granularity,
#   never the pass count. Shrinking the schema to a decision-singular shape is
#   the AD7 regression and is PROHIBITED. An interface gap/contradiction is a
#   BLOCKING §11 escalation (reopen claude-tools-65z, amend+bump+re-freeze,
#   Brian sign-off) — never diverge locally.
#
# Safe to `source` under `set -euo pipefail`: only function definitions below;
# every fallible call is guarded. Requires `jq`.
# ════════════════════════════════════════════════════════════════════════════

# ── consume the T5.1 substrate PUBLIC surface ────────────────────────────────
# Sources dossier.sh (→ coordinator.sh transitively) the way the focused tests
# do, binding ONLY to its public surface:
#   do_dossier_put       — the §4.1 envelope write (re-validates §4.1/§0.3;
#                          stamps principal at the ONE §9.1 chokepoint)
#   do_dossier_validate  — the §4.1 envelope + §4.1.1 record-shape validator
#                          (reused, NOT re-implemented; body/items §5 CONTENT
#                          is opaque to it — that CONTENT gate is THIS file's)
#   do__bound_sv         — the single bound schema version, read from the T4
#                          §4 registry (§0.5: no competing local literal; the
#                          §5 sub-versions track this one source — the same
#                          precedent T5.3/consequence.sh set for cb_schema_*)
#   do__safe_key         — the shared id-safety predicate ([A-Za-z0-9._-])
dg__lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
if ! declare -F do_dossier_put >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(dg__lib_dir)/dossier.sh"
fi

# §0.5 single normative §5 schema version. §5.1 `dossier_schema_version` and
# §5.3 `cb_schema_version` are §5-internal versions (NOT §4 record types, so
# absent from the T4 co__schema_version registry). Per §0.5 a value with a
# single normative definition MUST NOT be restated as a competing literal; T5.3
# (consequence.sh) already binds `cb_schema_version` to `do__bound_sv`, so the
# whole §5 schema tracks ONE source — a future bump is one §0/§11 registry edit,
# never a drift here.
dg__sv() { do__bound_sv; }

# ── §5.1 diagrams[].content = Mermaid (v2 §11 amendment) ─────────────────────
# dg__is_mermaid <content>
#   0 iff <content> is plausibly Mermaid SOURCE — i.e. after an optional
#   `---`…`---` frontmatter block and any leading blank / `%%`-comment /
#   `%%{init:…}%%`-directive lines, the first meaningful line begins with a
#   Mermaid diagram-type keyword. This is the producer-side "looks like
#   Mermaid" gate (the §5.2 contextless-anchor discipline applied to diagrams:
#   prose / ASCII art is a contract violation, REJECTED — never
#   best-effort-passed). The authoritative parse is the renderer's (Mermaid →
#   SVG on the phone, INTERFACE §5.1); this gate only keeps non-Mermaid out.
#
#   ASCII-ONLY / LOCALE-INVARIANT by design: whitespace is exactly U+0020 +
#   U+0009 (never `[[:space:]]`, which is locale-dependent), and the keyword
#   must be a full token followed by an ASCII space/tab/colon OR end-of-line
#   (no open `.*`). This makes the verdict byte-identical to the JS ports in
#   cf/src/dossier.js + web/inbox/inbox-view.js (the §8bm differential-
#   equivalence requirement — no Unicode-line-separator / locale divergence).
dg__is_mermaid() {
  local c="${1:-}" line seen_fm=0 in_fm=0
  local SP=$' \t'   # ASCII space + tab ONLY — NOT [[:space:]] (locale-bound)
  local kw='graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|quadrantChart|requirementDiagram|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment|sankey-beta|xychart-beta|block-beta|zenuml|architecture-beta|packet-beta'
  [[ -z "$c" ]] && return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                                  # strip a trailing CR (CRLF)
    [[ "$line" =~ ^[$SP]*$ ]] && continue                 # blank (ASCII sp/tab only)
    if [[ $seen_fm -eq 0 && $in_fm -eq 0 && "$line" =~ ^[$SP]*---[$SP]*$ ]]; then
      in_fm=1; seen_fm=1; continue                        # open YAML frontmatter
    fi
    if [[ $in_fm -eq 1 ]]; then
      [[ "$line" =~ ^[$SP]*---[$SP]*$ ]] && in_fm=0        # close frontmatter
      continue
    fi
    [[ "$line" =~ ^[$SP]*%% ]] && continue                # %% comment / %%{init}%% directive
    # first meaningful line: a Mermaid keyword as a FULL token (ASCII sp/tab/
    # colon delimiter OR end-of-line) — no open wildcard ⇒ no JS-regex `.`
    # divergence on U+2028/U+2029.
    [[ "$line" =~ ^[$SP]*($kw)([$SP:]|$) ]] && return 0
    return 1
  done <<< "$c"
  return 1                                              # only frontmatter/comments/blanks ⇒ no diagram
}

# ════════════════════════════════════════════════════════════════════════════
# §5.3 ConsequenceBlock — producer-side MACHINE-APPLYABLE gate
# ════════════════════════════════════════════════════════════════════════════
# dg__cb_applyable <cb_json>
#   Binds the FROZEN §5.3 schema T5.2 must EMIT (independently of T5.3's apply
#   binding — each tier binds the frozen schema, no shared private reach-in):
#   a JSON object whose `cb_schema_version` is an integer EQUAL to the bound
#   value (§0.3: unknown-higher REJECTED, never best-effort-parsed) and whose
#   creates/unblocks/labels/status_changes, when present, are each arrays.
#   0 iff machine-applyable; a §-cited diagnostic + nonzero otherwise.
dg__cb_applyable() {
  local cb="${1:-}" tag="${2:-§5.3 ConsequenceBlock}" bound sv
  bound="$(dg__sv)"
  if [[ -z "$bound" ]]; then
    echo "dossier-gen: reject — 'dossier' absent from the T4 §4 registry — store-surface contract gap (§0.5)" >&2
    return 2
  fi
  printf '%s' "$cb" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — $tag not a JSON object (§5.3)" >&2; return 3; }
  sv=$(printf '%s' "$cb" | jq -r '
        if (.cb_schema_version|type)=="number"
           and (.cb_schema_version == (.cb_schema_version|floor))
        then .cb_schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "dossier-gen: reject — $tag missing integer cb_schema_version (§5.3 'int' / §0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "dossier-gen: reject — $tag cb_schema_version $sv is an unknown higher version (bound=$bound; §0.3, never best-effort-parse)" >&2; return 3
  fi
  if [[ "$sv" -ne "$bound" ]]; then
    echo "dossier-gen: reject — $tag cb_schema_version $sv unsupported (binds v$bound only; §0.3)" >&2; return 3
  fi
  printf '%s' "$cb" | jq -e '
    (((.creates)        // []) | type=="array") and
    (((.unblocks)       // []) | type=="array") and
    (((.labels)         // []) | type=="array") and
    (((.status_changes) // []) | type=="array")' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — $tag creates/unblocks/labels/status_changes must each be arrays (§5.3 machine-applyable)" >&2; return 3; }
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# §5.1 body — all four tiers MANDATORY (AD7)
# ════════════════════════════════════════════════════════════════════════════
# dg__validate_body <body_json>
#   0 iff <body_json> is a well-formed §5.1 body with EVERY tier present and
#   non-empty: `dossier_schema_version` int == bound (§0.3); `tldr` non-empty
#   string; `sections[]` an array of ≥1 `{heading,prose}` each non-empty (the
#   skimmable DEEP body — an empty sections[] is the decision-singular AD7
#   regression and is REJECTED); `diagrams[]` an array of `{caption,content}`
#   each non-empty (the array itself MAY be `[]` — that is the genuinely-
#   non-structural case; the structural-source ⇒ ≥1-diagram policy is the
#   GENERATOR's, asserted by test) AND each `content` MUST be Mermaid source
#   (v2 §11 amendment — prose/ASCII REJECTED, §5.1); `full_detail` non-empty
#   string.
dg__validate_body() {
  local b="${1:-}" bound sv
  bound="$(dg__sv)"
  if [[ -z "$bound" ]]; then
    echo "dossier-gen: reject — 'dossier' absent from the T4 §4 registry — store-surface contract gap (§0.5)" >&2
    return 2
  fi
  printf '%s' "$b" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — body not a JSON object (§5.1)" >&2; return 3; }
  sv=$(printf '%s' "$b" | jq -r '
        if (.dossier_schema_version|type)=="number"
           and (.dossier_schema_version == (.dossier_schema_version|floor))
        then .dossier_schema_version else empty end' 2>/dev/null) || sv=""
  if [[ -z "$sv" || ! "$sv" =~ ^[0-9]+$ ]]; then
    echo "dossier-gen: reject — body missing integer dossier_schema_version (§5.1 'int' / §0.3)" >&2; return 3
  fi
  if [[ "$sv" -gt "$bound" ]]; then
    echo "dossier-gen: reject — dossier_schema_version $sv is an unknown higher version (bound=$bound; §0.3, never best-effort-parse)" >&2; return 3
  fi
  if [[ "$sv" -ne "$bound" ]]; then
    echo "dossier-gen: reject — dossier_schema_version $sv unsupported (binds v$bound only; §0.3)" >&2; return 3
  fi
  local errs
  errs=$(printf '%s' "$b" | jq -r '
    [ (if (.tldr|type)=="string" and ((.tldr|gsub("^\\s+|\\s+$";""))|length)>0
         then empty else "§5.1 tldr: non-empty string required (the skim entry point — AD7)" end),
      (if (.sections|type)=="array" and (.sections|length)>0
         then empty else "§5.1 sections[]: ≥1 {heading,prose} required (the deep skimmable body; an empty sections[] is the decision-singular AD7 regression — PROHIBITED)" end),
      (if (.diagrams|type)=="array"
         then empty else "§5.1 diagrams[]: array required ([] ONLY when genuinely non-structural — AD7)" end),
      (if (.full_detail|type)=="string" and ((.full_detail|gsub("^\\s+|\\s+$";""))|length)>0
         then empty else "§5.1 full_detail: non-empty stand-alone prose required (NOT optional — AD7)" end)
    ] | .[]' 2>/dev/null) || errs="§5.1 body: unparseable"
  if [[ -n "$errs" ]]; then echo "dossier-gen: reject — $errs" >&2; return 3; fi
  # Each declared section / diagram must itself be non-empty (a heading with no
  # prose, or a captioned-but-empty diagram, is not the §5.1 "enough text to
  # convey the point" tier — AD7).
  local serrs
  serrs=$(printf '%s' "$b" | jq -r '
    (.sections | to_entries[] | .key as $i | .value |
       [ (if (.heading|type)=="string" and ((.heading|gsub("^\\s+|\\s+$";""))|length)>0 then empty else "§5.1 sections[\($i)].heading: non-empty string" end),
         (if (.prose|type)=="string"   and ((.prose|gsub("^\\s+|\\s+$";""))|length)>0   then empty else "§5.1 sections[\($i)].prose: non-empty string (enough text to convey the point without full_detail)" end) ] | .[]),
    (.diagrams | to_entries[] | .key as $i | .value |
       [ (if (.caption|type)=="string" and ((.caption|gsub("^\\s+|\\s+$";""))|length)>0 then empty else "§5.1 diagrams[\($i)].caption: non-empty string" end),
         (if (.content|type)=="string" and ((.content|gsub("^\\s+|\\s+$";""))|length)>0 then empty else "§5.1 diagrams[\($i)].content: non-empty string" end) ] | .[])
    ' 2>/dev/null) || serrs="§5.1 sections/diagrams: unparseable"
  if [[ -n "$serrs" ]]; then echo "dossier-gen: reject — $serrs" >&2; return 3; fi
  # §5.1 v2 (§11 Mermaid amendment): each diagram's `content` MUST be Mermaid
  # source — prose / ASCII art is a contract violation, REJECTED (the §5.2
  # contextless-anchor discipline). The renderer (T6b) is the authoritative
  # parse; this is the producer gate that keeps non-Mermaid out of the store.
  local ndg i dc
  ndg=$(printf '%s' "$b" | jq -r '(.diagrams // []) | length' 2>/dev/null) || ndg=0
  [[ "$ndg" =~ ^[0-9]+$ ]] || ndg=0
  i=0
  while [[ "$i" -lt "$ndg" ]]; do
    dc=$(printf '%s' "$b" | jq -r ".diagrams[$i].content // \"\"" 2>/dev/null) || dc=""
    if ! dg__is_mermaid "$dc"; then
      echo "dossier-gen: reject — §5.1 diagrams[$i].content: MUST be Mermaid source (v2 §11) — prose/ASCII is a contract violation, not a wording nit; expected a Mermaid diagram-type header (graph/flowchart/sequenceDiagram/… optionally after ---frontmatter--- or %%{init}%%)" >&2
      return 3
    fi
    i=$((i+1))
  done
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# §5.2 Item — kind enum · MANDATORY context_anchor · framing · reversible ·
#             per-kind options/recommendation · machine-applyable §5.3 block
# ════════════════════════════════════════════════════════════════════════════
# dg__validate_item <item_json>
#   0 iff the Item satisfies §5.2 (the §5 CONTENT gate T5.1 deliberately does
#   NOT do — dossier.sh treats items[] §5 content as opaque). REJECTS (nonzero,
#   a §-cited diagnostic) on ANY violation; the caller MUST NOT emit it.
#
#   • `id` non-empty string (the §0.4 per-Item key; safe-key shaped).
#   • `kind` ∈ the CLOSED §5.2 enum (the response affordance; distinct from
#     the §4.1 dossier `kind` OPEN C2 seam — that one is T5.1's).
#   • `framing` an object carrying a non-empty `ask` (+ optional `why`) —
#     "the per-item ask + why, self-contained" (§5.2).
#   • `context_anchor` MANDATORY: object with non-empty `where` AND non-empty
#     `expansion` (optional `link`). The self-contained-context invariant —
#     a contextless ask is a CONTRACT VIOLATION (§5.2/AD7), REJECTED here.
#   • `reversible` non-empty string (what the choice forecloses / how
#     reversible — §5.2).
#   • `consequence_block` pre-declared & MACHINE-APPLYABLE (§5.3). For
#     `pick-option`: `options[]` ≥1 `{option_id,label,blast_radius,
#     consequence_block(applyable)}` AND `recommendation{value,why}`; for
#     `approve-recommendation`: `recommendation{value,why}`. Every other kind:
#     the item's own `consequence_block` applyable.
dg__validate_item() {
  local it="${1:-}" id kind cerr
  printf '%s' "$it" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — Item not a JSON object (§5.2)" >&2; return 3; }

  id=$(printf '%s' "$it" | jq -r 'if (.id|type)=="string" then .id else "" end' 2>/dev/null) || id=""
  if [[ -z "$id" ]]; then
    echo "dossier-gen: reject — §5.2 Item.id: non-empty string required (§0.4 per-Item key)" >&2; return 3
  fi
  do__safe_key "$id" || { echo "dossier-gen: reject — §5.2 Item.id '$id' unsafe ([A-Za-z0-9._-], no '..'; §0.4 per-Item key)" >&2; return 3; }

  kind=$(printf '%s' "$it" | jq -r '.kind // ""' 2>/dev/null) || kind=""
  case "$kind" in
    approve-reject|pick-option|approve-recommendation|freeform-edit|fyi-objectable) : ;;
    *) echo "dossier-gen: reject — §5.2 Item.kind '$kind' not in the CLOSED enum (approve-reject|pick-option|approve-recommendation|freeform-edit|fyi-objectable)" >&2; return 3 ;;
  esac

  local errs
  errs=$(printf '%s' "$it" | jq -r '
    [ (if (.framing|type)=="object"
           and (.framing.ask|type)=="string"
           and ((.framing.ask|gsub("^\\s+|\\s+$";""))|length)>0
         then empty else "§5.2 framing: object with a non-empty .ask required (the per-item ask + why, self-contained)" end),
      (if (.context_anchor|type)=="object"
           and (.context_anchor.where|type)=="string"
           and ((.context_anchor.where|gsub("^\\s+|\\s+$";""))|length)>0
           and (.context_anchor.expansion|type)=="string"
           and ((.context_anchor.expansion|gsub("^\\s+|\\s+$";""))|length)>0
         then empty else "§5.2 context_anchor{where,expansion}: MANDATORY non-empty — a contextless ask is a CONTRACT VIOLATION, not a wording nit (AD7 self-contained-context invariant); REJECTED, nothing written" end),
      (if (.reversible|type)=="string" and ((.reversible|gsub("^\\s+|\\s+$";""))|length)>0
         then empty else "§5.2 reversible: non-empty string required (what the choice forecloses / how reversible)" end)
    ] | .[]' 2>/dev/null) || errs="§5.2 Item: unparseable"
  if [[ -n "$errs" ]]; then echo "dossier-gen: reject — Item '$id': $errs" >&2; return 3; fi

  # Per-`kind` options/recommendation + the machine-applyable §5.3 block(s).
  if [[ "$kind" == "pick-option" ]]; then
    local nopt o oid
    nopt=$(printf '%s' "$it" | jq -r 'if (.options|type)=="array" then (.options|length) else -1 end' 2>/dev/null) || nopt=-1
    if [[ ! "$nopt" =~ ^[0-9]+$ || "$nopt" -lt 1 ]]; then
      echo "dossier-gen: reject — Item '$id': §5.2 pick-option needs options[] (≥1 {option_id,label,blast_radius,consequence_block})" >&2; return 3
    fi
    printf '%s' "$it" | jq -e '(.recommendation|type)=="object"
        and (.recommendation.value|type)=="string" and ((.recommendation.value|gsub("^\\s+|\\s+$";""))|length)>0
        and (.recommendation.why|type)=="string"   and ((.recommendation.why|gsub("^\\s+|\\s+$";""))|length)>0' >/dev/null 2>&1 \
      || { echo "dossier-gen: reject — Item '$id': §5.2 pick-option needs recommendation{value,why} (non-empty; editable inline — T6b)" >&2; return 3; }
    for ((o=0; o<nopt; o++)); do
      oid=$(printf '%s' "$it" | jq -r --argjson o "$o" '.options[$o].option_id // ""' 2>/dev/null) || oid=""
      printf '%s' "$it" | jq -e --argjson o "$o" '
          (.options[$o].option_id|type)=="string" and ((.options[$o].option_id|gsub("^\\s+|\\s+$";""))|length)>0
          and (.options[$o].label|type)=="string" and ((.options[$o].label|gsub("^\\s+|\\s+$";""))|length)>0
          and (.options[$o].blast_radius|type)=="string" and ((.options[$o].blast_radius|gsub("^\\s+|\\s+$";""))|length)>0' >/dev/null 2>&1 \
        || { echo "dossier-gen: reject — Item '$id' options[$o]: §5.2 {option_id,label,blast_radius} each non-empty required" >&2; return 3; }
      local ocb
      ocb=$(printf '%s' "$it" | jq -c --argjson o "$o" '.options[$o].consequence_block // empty' 2>/dev/null) || ocb=""
      [[ -n "$ocb" ]] || { echo "dossier-gen: reject — Item '$id' option '$oid': §5.2 every option MUST pre-declare a consequence_block (the chosen-option block T5.3 applies)" >&2; return 3; }
      cerr=$(dg__cb_applyable "$ocb" "Item '$id' option '$oid' consequence_block" 2>&1) || { echo "$cerr" >&2; return 3; }
    done
    # A duplicate option_id makes T5.3's chosen-block selection ambiguous.
    local dup
    dup=$(printf '%s' "$it" | jq -r '([.options[].option_id] | group_by(.) | map(select(length>1)|.[0]) | .[]?)' 2>/dev/null) || dup=""
    [[ -z "$dup" ]] || { echo "dossier-gen: reject — Item '$id': duplicate option_id '$dup' (chosen-option block must be unambiguous — §5.2/§5.3)" >&2; return 3; }
  else
    if [[ "$kind" == "approve-recommendation" ]]; then
      printf '%s' "$it" | jq -e '(.recommendation|type)=="object"
          and (.recommendation.value|type)=="string" and ((.recommendation.value|gsub("^\\s+|\\s+$";""))|length)>0
          and (.recommendation.why|type)=="string"   and ((.recommendation.why|gsub("^\\s+|\\s+$";""))|length)>0' >/dev/null 2>&1 \
        || { echo "dossier-gen: reject — Item '$id': §5.2 approve-recommendation needs recommendation{value,why} (non-empty)" >&2; return 3; }
    fi
    local icb
    icb=$(printf '%s' "$it" | jq -c '.consequence_block // empty' 2>/dev/null) || icb=""
    [[ -n "$icb" ]] || { echo "dossier-gen: reject — Item '$id': §5.2/§5.3 a pre-declared consequence_block is required (kind '$kind')" >&2; return 3; }
    cerr=$(dg__cb_applyable "$icb" "Item '$id' consequence_block" 2>&1) || { echo "$cerr" >&2; return 3; }
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# §5.2.1 PROFILES are EMERGENT — ONE validator, NO per-profile schema branch
# ════════════════════════════════════════════════════════════════════════════
# dg__validate_dossier <envelope_json>
#   The SINGLE §5 gate every profile flows through (decision dossier / mixed
#   review / Flow F overview — §5.2.1). Layered, no re-implementation:
#     1. T5.1 `do_dossier_validate` — the §4.1 envelope + §4.1.1 record shape
#        (reused as a black box; body/items §5 CONTENT is opaque to it).
#     2. §5.1 `dg__validate_body` on `.body`.
#     3. §5.2 `dg__validate_item` on EVERY item — `items[]` MAY be empty (a
#        Flow F all-/zero-`fyi-objectable` overview, §5.2.1) and that is
#        valid: zero items ⇒ zero per-item checks, SAME shape, NO branch.
#   There is deliberately NO `if profile == …` anywhere: the profile is read
#   off body-depth × item-mix by humans/T6b, never off a schema discriminator.
dg__validate_dossier() {
  local env="${1:-}" body n i it
  do_dossier_validate "$env" || return $?          # §4.1/§4.1.1 (T5.1, reused)
  body=$(printf '%s' "$env" | jq -c '.body // empty' 2>/dev/null) || body=""
  [[ -n "$body" ]] || { echo "dossier-gen: reject — no .body (§5.1)" >&2; return 3; }
  dg__validate_body "$body" || return $?           # §5.1 (all four tiers)
  n=$(printf '%s' "$env" | jq -r 'if (.items|type)=="array" then (.items|length) else -1 end' 2>/dev/null) || n=-1
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "dossier-gen: reject — items[] not an array (§5.2)" >&2; return 3; }
  for ((i=0; i<n; i++)); do
    it=$(printf '%s' "$env" | jq -c --argjson i "$i" '.items[$i]' 2>/dev/null) || it=""
    dg__validate_item "$it" || return $?           # §5.2 (per-Item content)
  done
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# READABILITY LINT (claude-tools-uxvl5; inbox-lifecycle §4.4) — ADVISORY, NOT a
# write gate
# ════════════════════════════════════════════════════════════════════════════
# dg__readability_lint <dossier_envelope | body | §7.2_worker_ask JSON>
#   The §4.4 cold-reader gate as a deterministic check: a non-author reading
#   this dossier on a phone must learn what blew up / what they're deciding /
#   what each option does in <30s WITHOUT contract jargon. It flags untranslated
#   internal-jargon TOKENS in the HUMAN-FACING prose only — never the by-design
#   machine fields (`trigger`/`kind`/`option_id`/`recommendation.value`/
#   `authored_by_reason`), which are closed enums the Inbox renderer translates
#   to plain English itself (web/inbox/inbox-view.js). It accepts any of three
#   shapes: a full §4.1 envelope, a bare §5.1 body, or the raw §7.2 worker-ask
#   sr_worker_ask emits — pulling whichever reader-facing fields are present.
#
#   DELIBERATELY ADVISORY. Per the write-gate/render-tolerance discipline
#   (memory 4xe-write-gate-render-tolerance) the write path rejects on SCHEMA,
#   the renderer stays tolerant, and NEITHER refuses a dossier on prose style.
#   This lint is the §4.4 writer-side rule made checkable: it is asserted in
#   tests (the deterministic fallback template MUST pass it) and is available to
#   an author as a self-check. dg_generate / do_dossier_put NEVER call it — a
#   jargon-y dossier still ships (honest-thin beats refused), it just fails CI.
#
#   Flagged token classes (unambiguous internal jargon with no place in
#   human-facing prose, per the dossier-builder rule "don't write AD7/BC-34/§5.2"):
#     • the section symbol  §
#     • contract IDs:  AD<n>[.<n>]  ·  BC[-]<n>  ·  S-2  ·  T<n>[.<n>|<letter>]
#       (the T-form is single-digit-after-T so ISO timestamps like `…T17:45`,
#        which have two digits, are NOT matched)
#     • internal enum/state/reason tokens:  worker_stuck · human_flag ·
#       proactive_checkpoint · stage_gate · STUCK_NEEDS_HUMAN ·
#       WORKER_STUCK_EXIT · TASK_NOT_CLOSED · DOSSIER_FALLBACK ·
#       no_DG_AUTHOR_CMD · DG_AUTHOR_CMD · blocked-for-human
#   0 = clean; 1 = jargon found (offending tokens listed on stderr);
#   2 = unparseable input.
dg__readability_lint() {
  local j="${1:-}" prose hits
  printf '%s' "$j" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: readability-lint — input not a JSON object (§4.4)" >&2; return 2; }
  # Gather ONLY reader-facing strings, tolerant of all three shapes (envelope /
  # bare body / raw §7.2 ask). `?` guards every optional path so a missing field
  # is silently skipped, never an error. By-design enum fields are NOT gathered.
  prose=$(printf '%s' "$j" | jq -r '
    [ .body?.tldr, .tldr?,
      (.body?.sections[]? | .heading, .prose),
      .body?.full_detail?,
      (.body?.diagrams[]?.caption),
      (.items[]? | .framing?.ask, .framing?.why,
                   .context_anchor?.where, .context_anchor?.expansion,
                   .reversible?, .recommendation?.why,
                   (.options[]? | .label, .blast_radius)),
      .ask?, .reversible?, .recommendation?.why?,
      (.options[]? | .label, .blast_radius)
    ] | map(select(type=="string")) | .[]' 2>/dev/null) || prose=""
  [[ -n "$prose" ]] || return 0   # nothing reader-facing to lint
  local pat='§|\b(AD[0-9]+(\.[0-9]+)*|BC-?[0-9]+|S-2|T[0-9](\.[0-9]+|[a-z])?)\b|\b(worker_stuck|human_flag|proactive_checkpoint|stage_gate|STUCK_NEEDS_HUMAN|WORKER_STUCK_EXIT|TASK_NOT_CLOSED|DOSSIER_FALLBACK|no_DG_AUTHOR_CMD|DG_AUTHOR_CMD|blocked-for-human)\b'
  hits=$(printf '%s\n' "$prose" | grep -oE "$pat" 2>/dev/null | sort -u | tr '\n' ' ')
  if [[ -n "${hits// /}" ]]; then
    echo "dossier-gen: readability-lint — untranslated internal jargon in human-facing prose (§4.4): ${hits% }" >&2
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# The single AUTHORING seam — ONE pass, swappable (§0.2 / §0.C)
# ════════════════════════════════════════════════════════════════════════════
# dg__author <generation_input_json>  →  { body, items[] }  (§5 CONTENT only)
#   ONE structured generation, NOT four chained agents. The pass count is the
#   tradeable §0.C mechanism: by default a single DETERMINISTIC transform of
#   the §7.2 raw material into the §5 shape; if `DG_AUTHOR_CMD` is set it is
#   invoked instead (a real model — provider-agnostic §0.2, STILL one call,
#   STILL the same frozen schema). The output is VALIDATED by the caller
#   against the frozen §5 gate regardless of which authored it (the schema is
#   the contract, never the generator).
#
#   The generation input (T5.2's OWN input contract — NOT the frozen §5
#   schema) carries the §7.2 raw material under `.source`:
#     { tldr?, sections?[], diagrams?[], structural?:bool, full_detail?,
#       ask?, options?[], recommendation?{value,why}, reversible? }
#   and an `.items[]` spec (each: kind + framing + context_anchor +
#   reversible + options?/recommendation? + consequence_block). `.items` MAY
#   be `[]` (the Flow F overview profile — §5.2.1). The default author fills
#   any absent MANDATORY §5.1 tier deterministically from the raw material so
#   the four-tier invariant always holds; it NEVER invents a missing
#   `context_anchor` (that omission is a CONTRACT VIOLATION the §5.2 gate
#   REJECTS — papering it over would defeat the self-contained-context
#   invariant).
#
# B3 (claude-tools-95m): The jq path is the EXPLICIT FALLBACK / shape-coercer
# for B2's `DG_AUTHOR_CMD` agent shim. If the shim is unset, errors, times out,
# or produces output that is not a `{body, items[]}` object, the jq path runs
# instead so the worker still gets a contract-valid (if lower-quality) dossier.
# Every fallback fire writes an audit record AND records an incident — silent
# fallback would mask the agent being broken, which is the bug we're killing.
# A `body.authored_by` field ("agent" | "fallback") + `body.authored_by_reason`
# is stamped into the output so the Inbox renderer can badge degraded-author
# dossiers (claude-tools-95m: "lower-quality, not just renders as if normal").
dg__author() {
  local gi="${1:-}" sv; sv="$(dg__sv)"
  local did reason out rc t0 elapsed_ms timeout_sec
  local pre_author_by pre_author_reason
  # claude-tools-69u8: localize the authoring-seam env so the chokepoint
  # auto-wire below is PER-CALL — it never leaks to the caller or a later call.
  local DG_AUTHOR_CMD="${DG_AUTHOR_CMD:-}" DG_AUTHOR_TIMEOUT_SEC="${DG_AUTHOR_TIMEOUT_SEC:-}"
  did="$(printf '%s' "$gi" | jq -r '.id // ""' 2>/dev/null)" || did=""
  # claude-tools-xdo: optional caller-supplied AUTHORING HINT on .source. When
  # the gi was assembled from a pre-authored body (the MCP write_polished path
  # hands the dossier-builder subprocess's body straight through), the jq path
  # below is a shape-coercer, NOT a degraded fallback. The hint lets that jq
  # path stamp body.authored_by accurately and skips the no_DG_AUTHOR_CMD
  # incident-fire (which would be misleading — the agent that authored is the
  # builder, not DG_AUTHOR_CMD).
  pre_author_by="$(printf '%s' "$gi" | jq -r '.source.authored_by // ""' 2>/dev/null)" || pre_author_by=""
  pre_author_reason="$(printf '%s' "$gi" | jq -r '.source.authored_by_reason // ""' 2>/dev/null)" || pre_author_reason=""
  # ── claude-tools-69u8: GLOBAL wiring at the ONE chokepoint ──────────────────
  # Historically DG_AUTHOR_CMD was exported PER-CALL-SITE (run-beads-tasks.sh
  # :1125/:2375), so every OTHER dg__author caller (the Flow F overview, the v2
  # STUCK path, any future site) silently fell to the jq path and fired
  # DOSSIER_FALLBACK:no_DG_AUTHOR_CMD. Default it HERE instead — once — to the
  # colocated real-agent bridge, GATED so it stays HERMETIC and cheap:
  #   • opt-in  DG_AUTHOR_AUTOWIRE=1  — the offline unit tests never set it, so
  #     they keep the pure jq path + the no_DG_AUTHOR_CMD assertion (test (1)).
  #     A runner/daemon turns it ON once at startup (kill-switch: set it to 0).
  #   • claude reachable — else the bridge would just fail to agent_unavailable;
  #     skipping keeps the jq path (no pointless spawn, no false "agent" badge).
  #   • NOT pre-authored — a gi whose .source already carries a builder body
  #     (the Flow F / MCP §xdo path) must NOT re-spawn a second builder.
  #   • bridge executable — overridable via DG_AUTHOR_BRIDGE_PATH (prod swap +
  #     hermetic test seam); defaults to the sibling lib/dg-author-bridge.sh.
  if [[ -z "$DG_AUTHOR_CMD" && "${DG_AUTHOR_AUTOWIRE:-0}" == "1" && -z "$pre_author_by" ]]; then
    local _dg_bridge="${DG_AUTHOR_BRIDGE_PATH:-$(dg__lib_dir)/dg-author-bridge.sh}"
    if [[ -x "$_dg_bridge" ]] && command -v "${CLAUDE_BIN:-claude}" >/dev/null 2>&1; then
      DG_AUTHOR_CMD="$_dg_bridge"
      DG_AUTHOR_TIMEOUT_SEC="${DG_AUTHOR_TIMEOUT_SEC:-300}"
    fi
  fi
  if [[ -n "${DG_AUTHOR_CMD:-}" ]]; then
    # Provider-agnostic swap (§0.2): a real model emits the same §5 CONTENT.
    # Still ONE call; output goes through the SAME frozen §5 gate downstream.
    # B3: capture rc + stdout, bound runtime, validate shape, fall through to
    # the jq path on ANY failure — agent_unavailable / agent_timeout /
    # agent_invalid_output. Each fallback fire is audited + incidented so we
    # see when the agent is silently broken vs. genuinely working.
    timeout_sec="${DG_AUTHOR_TIMEOUT_SEC:-90}"
    t0=$(date +%s 2>/dev/null || echo 0)
    if command -v timeout >/dev/null 2>&1; then
      out=$(printf '%s' "$gi" | timeout "${timeout_sec}s" "${DG_AUTHOR_CMD}" 2>/dev/null); rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
      out=$(printf '%s' "$gi" | gtimeout "${timeout_sec}s" "${DG_AUTHOR_CMD}" 2>/dev/null); rc=$?
    else
      out=$(printf '%s' "$gi" | "${DG_AUTHOR_CMD}" 2>/dev/null); rc=$?
    fi
    elapsed_ms=0
    if [[ "$t0" -gt 0 ]]; then
      local t1; t1=$(date +%s 2>/dev/null || echo "$t0")
      elapsed_ms=$(( (t1 - t0) * 1000 ))
    fi
    # rc=124 is the GNU `timeout` SIGTERM-fired exit; treat anything ≥124 as a
    # timeout to also catch the SIGKILL escalation (137).
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      reason="agent_timeout"
    elif [[ "$rc" -ne 0 ]]; then
      reason="agent_unavailable"
    elif ! printf '%s' "$out" | jq -e 'type=="object" and (.body|type)=="object" and (.items|type)=="array"' >/dev/null 2>&1; then
      reason="agent_invalid_output"
    else
      # Agent path succeeded. Stamp authored_by="agent" so the renderer knows
      # this dossier is NOT degraded. Use //= so a fixture that already set it
      # wins (lets tests prove specific values round-trip).
      dg__audit_fallback "agent_ok" "$did" "$gi" "$elapsed_ms" || true
      printf '%s' "$out" | jq -c '
        .body = ( (.body // {})
                  | (.authored_by //= "agent")
                  | (.authored_by_reason //= "agent_ok") )' 2>/dev/null
      return 0
    fi
    # Falling through — agent failed. Audit + incident (loud, not silent).
    dg__audit_fallback "$reason" "$did" "$gi" "$elapsed_ms" || true
  else
    reason="no_DG_AUTHOR_CMD"
    # claude-tools-xdo: if the caller pre-authored .source (MCP write_polished
    # path), the jq pass is just shape-coercion — don't fire an incident.
    [[ -n "$pre_author_by" ]] || dg__audit_fallback "$reason" "$did" "$gi" "0" || true
  fi
  # Default single-pass deterministic transform of the §7.2 raw material.
  # Stamps body.authored_by="fallback" + the specific reason so the Inbox can
  # badge "degraded author" (B3 / claude-tools-95m).
  printf '%s' "$gi" | jq -c --argjson sv "$sv" --arg reason "$reason" \
                              --arg pre_by "$pre_author_by" --arg pre_reason "$pre_author_reason" '
    .source as $s
    | ($s.tldr // $s.ask // "Decision required.") as $tldr
    | ( if ($s.sections|type)=="array" and ($s.sections|length)>0 then $s.sections
        elif ($s.options|type)=="array" and ($s.options|length)>0
          then [ { heading:"Options",
                   prose:( [ $s.options[]
                             | (.label // .option_id // "option")
                               + (if (.blast_radius|type)=="string" then " — " + .blast_radius else "" end) ]
                           | join("; ") ) },
                 { heading:"Recommendation",
                   prose:( (($s.recommendation.value // "—") | tostring)
                           + " — " + (($s.recommendation.why // "") | tostring) ) } ]
        else [ { heading:"Summary", prose:($s.ask // $tldr) } ] end ) as $sections
    | ( if ($s.diagrams|type)=="array" then $s.diagrams else [] end ) as $diagrams
    | ( $s.full_detail
        // ( ($s.ask // $tldr)
             + (if ($s.reversible|type)=="string" then "\n\nReversibility: " + $s.reversible else "" end) ) ) as $full
    | { body: { dossier_schema_version:$sv, tldr:$tldr, sections:$sections,
                diagrams:$diagrams, full_detail:$full,
                authored_by:(if ($pre_by|length)>0 then $pre_by else "fallback" end),
                authored_by_reason:(if ($pre_reason|length)>0 then $pre_reason else $reason end) },
        items: [ (.items // [])[]
                 | . + { consequence_block:
                           ( if .kind=="pick-option" then (.consequence_block // {})
                             else ( .consequence_block
                                    | if type=="object" then (.cb_schema_version //= $sv) else . end ) end ) }
                 | if .kind=="pick-option" and (.options|type)=="array"
                     then .options |= map(.consequence_block |= (if type=="object" then (.cb_schema_version //= $sv) else . end))
                     else . end ] }' 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# B3 (claude-tools-95m) — fallback-fire AUDIT: never silent, always observable
# ════════════════════════════════════════════════════════════════════════════
# dg__audit_fallback <reason> <dossier_id_or_blank> <generation_input> <elapsed_ms>
#   Writes ONE JSON line to $DG_AUDIT_LOG (default
#   $HOME/.cache/claude-tools/dossier-author-audit.jsonl). The line carries
#   ts / id / reason / gi_size_bytes / gi_hash + the elapsed_ms for the agent
#   call (0 for the no-agent / fall-through paths). The generation input is
#   NOT stored verbatim — only a redacted short slice plus its sha256 prefix
#   (the worker dump can be megabytes and may carry secrets). On a workspace
#   that has the runner's record_incident wired (it sources runner.sh or
#   run-beads-tasks.sh), the fallback ALSO records an incident so it surfaces
#   in the runner's per-run incident summary. Best-effort: a failure to write
#   the audit/incident NEVER fails the author call — silent observability is
#   a worse bug than a missed log line.
dg__audit_fallback() {
  local reason="${1:-unknown}" did="${2:-}" gi="${3:-}" elapsed_ms="${4:-0}"
  local log_path="${DG_AUDIT_LOG:-$HOME/.cache/claude-tools/dossier-author-audit.jsonl}"
  local dir="${log_path%/*}"
  [[ -n "$dir" && "$dir" != "$log_path" ]] && mkdir -p "$dir" 2>/dev/null || true
  local ts gi_size gi_hash gi_redact line
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  gi_size=$(printf '%s' "$gi" | wc -c 2>/dev/null | awk '{print $1}')
  [[ -z "$gi_size" ]] && gi_size=0
  if command -v shasum >/dev/null 2>&1; then
    gi_hash=$(printf '%s' "$gi" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,16)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    gi_hash=$(printf '%s' "$gi" | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}')
  else
    gi_hash=""
  fi
  # Redacted slice: the bead_ref + trigger + tier + tldr (first 120 chars) —
  # forensically useful for "which dossier failed and which fork" without
  # leaking the worker brain-dump. Falls back to "" if jq is missing fields.
  gi_redact=$(printf '%s' "$gi" | jq -c '{
      bead_ref:(.bead_ref // ""),
      trigger:(.trigger // ""),
      tier:(.tier // ""),
      tldr:((.source.tldr // .source.ask // "") | tostring | .[0:120]),
      item_count:((.items // []) | length)
    }' 2>/dev/null) || gi_redact='{}'
  line=$(jq -cn \
    --arg ts "$ts" --arg id "$did" --arg reason "$reason" \
    --arg gi_hash "$gi_hash" --argjson gi_size "$gi_size" \
    --argjson gi_redact "${gi_redact:-{\}}" --argjson elapsed_ms "${elapsed_ms:-0}" \
    --arg cmd "${DG_AUTHOR_CMD:-}" '
    { ts:$ts, dossier_id:$id, reason:$reason, elapsed_ms:$elapsed_ms,
      author_cmd_set:(($cmd|length)>0),
      gi_size_bytes:$gi_size, gi_hash:$gi_hash, gi_redact:$gi_redact }' 2>/dev/null) \
    || line='{"ts":"","reason":"'"$reason"'","note":"audit-line-build-failed"}'
  printf '%s\n' "$line" >> "$log_path" 2>/dev/null || true
  # Runner-side incident: only on a real fallback fire (NOT on agent_ok). The
  # incident summary surfaces this at the end of every runner sweep so a
  # silently-broken agent is loud.
  if [[ "$reason" != "agent_ok" ]] && command -v record_incident >/dev/null 2>&1; then
    record_incident "${did:--}" "DOSSIER_FALLBACK:$reason" "$log_path" 2>/dev/null || true
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# THE single structured-generation ENTRYPOINT  (§5 sole producer)
# ════════════════════════════════════════════════════════════════════════════
# dg_generate <bearer> <generation_input_json>
#
#   ONE call → ONE §5 `body`⊃`items[]` Dossier, validated against the FROZEN
#   §5 gate, written THROUGH the T5.1 §4.1 envelope. NOT four chained agents.
#
#   generation_input_json (T5.2's input contract):
#     { id, kind?, trigger, bead_ref, tier, timer_fire_at?, source{…}, items[] }
#   `id`/`trigger`/`bead_ref`/`tier` are §4.1 envelope fields (the caller /
#   the §7.4 layer = T5.5 supplies the id — WHICH-trigger-wins/dedup is T5.5,
#   not here). `kind` defaults to "decide" (§4.1 OPEN C2 seam; T5.1 owns it).
#   `timer_fire_at` is pass-through (default `null`; T5.4 COMPUTES/ARMS it).
#
#   Steps: author the §5 CONTENT once (`dg__author`) → assemble the §4.1
#   envelope with each Item given a CLEAN §4.1.1 record (`open`/`null`/`false`
#   /`null` — the substrate owns the lifecycle thereafter) → REJECT on ANY
#   §5 violation via `dg__validate_dossier` (NO write; a missing
#   `context_anchor` is a contract violation, refused here) → persist via the
#   T5.1 `do_dossier_put` (re-validates §4.1/§0.3; stamps `principal` at the
#   ONE §9.1 chokepoint — no second auth path, never a literal here).
#   Echoes the dossier id on success.
#
#   PROFILES are EMERGENT (§5.2.1): zero items + deep body ⇒ Flow F overview;
#   many mixed-kind items ⇒ review; one `pick-option` + deep body ⇒
#   `worker_stuck` decision — ALL through this ONE path, NO schema branch.
dg_generate() {
  local bearer="${1:-}" gi="${2:-}" content body items env id sv now
  printf '%s' "$gi" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — generation input not a JSON object" >&2; return 2; }

  id=$(printf '%s' "$gi" | jq -r '.id // ""' 2>/dev/null) || id=""
  [[ -n "$id" ]] || { echo "dossier-gen: reject — generation input has no dossier id (§4.1; the §7.4 dedup layer = T5.5 supplies it)" >&2; return 2; }

  content="$(dg__author "$gi")" || content=""
  printf '%s' "$content" | jq -e 'type=="object" and (.body|type)=="object" and (.items|type)=="array"' >/dev/null 2>&1 \
    || { echo "dossier-gen: reject — authoring did not yield {body,items[]} (§5)" >&2; return 3; }
  body=$(printf '%s' "$content" | jq -c '.body' 2>/dev/null)
  items=$(printf '%s' "$content" | jq -c '.items' 2>/dev/null)

  sv="$(dg__sv)"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  # Assemble the §4.1 envelope. Each Item gets a CLEAN §4.1.1 record — T5.1
  # owns its state machine/latch thereafter (we never set state past `open`).
  env=$(printf '%s' "$gi" | jq -c \
        --argjson sv "$sv" --arg now "$now" \
        --argjson body "$body" --argjson items "$items" '
        { id:.id,
          schema_version:$sv,
          kind:(.kind // "decide"),
          trigger:.trigger,
          bead_ref:.bead_ref,
          tier:.tier,
          created_at:(.created_at // $now),
          timer_fire_at:(.timer_fire_at // null),
          body:$body,
          items:[ $items[]
                  | . + { state:"open", response:null,
                          consequence_applied:false, applied_at:null } ] }' 2>/dev/null) || env=""
  [[ -n "$env" ]] || { echo "dossier-gen: reject — could not assemble the §4.1 envelope" >&2; return 3; }

  # REJECT on ANY §5 violation BEFORE any write (a missing context_anchor is a
  # contract violation, not a wording nit — refused here, nothing persisted).
  dg__validate_dossier "$env" || return $?

  # Persist THROUGH the T5.1 surface (re-enforces §4.1/§0.3; §9.1 principal).
  do_dossier_put "$bearer" "$env" >/dev/null || return $?
  printf '%s' "$id"
}

# ════════════════════════════════════════════════════════════════════════════
# §7.2 worker structured-ask CONSUMPTION → a worker_stuck decision dossier
# ════════════════════════════════════════════════════════════════════════════
# dg_from_worker_ask <bearer> <dossier_id> <bead_ref> <structured_ask_json>
#   The concrete §7.2 path: the worker's blocked-fork ask
#     { tldr, ask, options[]:{option_id,label,blast_radius,consequence_block},
#       recommendation:{value,why}, reversible }
#   is consumed as RAW material to generate a §5.2.1 *decision dossier* — a
#   deep body + ONE `pick-option` Item (one fork ⇒ one pick-option, §5.2.1).
#   This is generation only; the dossier-level one-fork-one-dossier dedup and
#   the S-2 reconcile-back are T5.5 (the caller passes the dedup'd id).
dg_from_worker_ask() {
  local bearer="${1:-}" did="${2:-}" bref="${3:-}" ask="${4:-}" gi
  printf '%s' "$ask" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — worker structured ask not a JSON object (§7.2)" >&2; return 2; }
  [[ -n "$did" && -n "$bref" ]] || { echo "dossier-gen: reject — need <dossier_id> <bead_ref> (§7.2/§7.4: id is the dedup'd one — T5.5)" >&2; return 2; }
  # ── §5.1 diagrams[] for the §7.2 worker-stuck dossier (claude-tools-8bm I5):
  # vkc made diagrams[].content a RENDERABLE Mermaid format and built the
  # Inbox SVG renderer, but NOTHING on the §7.2 worker-stuck generation path
  # ever PRODUCED a diagram — sr_worker_ask carries no `diagrams`, dg__author
  # passes `source.diagrams // []` straight through, so every real stuck
  # dossier reached the phone with diagrams:[] and the renderer was dead code
  # (a verified-but-disconnected gap — exactly epic 8bm's reason to exist). A
  # decision fork IS structural (§5.1/AD7: [] is ONLY the genuinely-
  # non-structural case — a pick-one human fork is not that), so synthesize a
  # real Mermaid `flowchart` of the fork: the ask → a decision node → one
  # branch per option → that option's blast-radius leaf, the recommended
  # option visually marked. Labels are sanitized to a Mermaid-safe ASCII
  # subset and bracket-quoted so the strict-mode renderer parses them; the
  # synthesized content begins with `flowchart` so it passes dg__is_mermaid
  # and the frozen §5.1 v2 gate. Generated here (not in dg__author) so the
  # default deterministic author keeps passing source.diagrams through and a
  # DG_AUTHOR_CMD model swap still gets the same structural input.
  local diagrams_json
  diagrams_json=$(printf '%s' "$ask" | jq -c '
    # Mermaid-safe label: collapse to a printable ASCII subset, drop the
    # characters Mermaid treats specially inside node text, clamp length.
    def mm: ( . // "" ) | tostring
            | gsub("[\\r\\n]+"; " ")
            | gsub("[^A-Za-z0-9 ,.:;/_+%()=&@#-]"; " ")
            | gsub(" +"; " ")
            | gsub("^ +| +$"; "")
            | .[0:90]
            | if . == "" then "(unspecified)" else . end;
    ( .options // [] ) as $opts
    | ( .recommendation.value // "" ) as $rec
    | if ($opts | length) == 0 then []
      else
        [ "flowchart TD",
          "  A[\"" + ((.ask // .tldr // "Decision required") | mm) + "\"]",
          "  D{\"Human decides\"}",
          "  A --> D"
        ]
        + ( [ $opts | to_entries[]
              | .key as $i | .value as $o
              | ( "O" + ($i|tostring) ) as $on
              | ( "B" + ($i|tostring) ) as $bn
              | ( if ($o.option_id // "") == $rec and $rec != ""
                  then "  D ==>|recommended| " + $on + "([\"" + (($o.label // $o.option_id // "Option") | mm) + "\"])"
                  else "  D -->|option| "      + $on + "([\"" + (($o.label // $o.option_id // "Option") | mm) + "\"])"
                  end ),
                "  " + $on + " --> " + $bn + "[\"" + (($o.blast_radius // "Blast radius unspecified") | mm) + "\"]"
              ] | flatten )
        | [ { caption: "What you are deciding and where each option leads",
              content: join("\n") } ]
      end' 2>/dev/null) || diagrams_json="[]"
  # Harden: only feed VALID JSON to the --argjson below. Any jq hiccup ⇒ the
  # safe genuinely-non-structural [] (the §5.1 gate accepts []; the fork still
  # routes — sr_route_stuck already drove the bead BEFORE generation, so a
  # diagram-synthesis miss never rots the fork).
  printf '%s' "$diagrams_json" | jq -e 'type=="array"' >/dev/null 2>&1 || diagrams_json="[]"
  gi=$(printf '%s' "$ask" | jq -c \
        --arg did "$did" --arg bref "$bref" --argjson diagrams "$diagrams_json" '
        { id:$did, kind:"decide", trigger:"worker_stuck",
          bead_ref:$bref, tier:"blocking", timer_fire_at:null,
          source:{ tldr:(.tldr // .ask // "A worker stopped at a decision only you can make."),
                   ask:(.ask // .tldr // "Pick how to proceed."),
                   options:(.options // []),
                   diagrams:$diagrams,
                   recommendation:(.recommendation // null),
                   reversible:(.reversible // "The worker did not say what is reversible here.") },
          items:[ { id:($did + "-d1"),
                    kind:"pick-option",
                    framing:{ ask:(.ask // .tldr // "Pick how the worker should proceed."),
                              why:(.recommendation.why // "The worker hit a decision it is not allowed to make on its own, so it stopped and handed it to you.") },
                    context_anchor:{ where:("A worker on " + $bref + " stopped at a decision the runner cannot make on its own and parked the task for you."),
                                     expansion:(.tldr // .ask // "The worker wrote down the choice it was facing and stopped; this is the decision it could not make on its own.") },
                    options:(.options // []),
                    recommendation:(.recommendation // null),
                    reversible:(.reversible // "The worker did not say what is reversible here.") } ] }' 2>/dev/null) || gi=""
  [[ -n "$gi" ]] || { echo "dossier-gen: reject — could not build generation input from the §7.2 ask" >&2; return 3; }
  dg_generate "$bearer" "$gi"
}

# ════════════════════════════════════════════════════════════════════════════
# Flow G — runner-killed bead → analysis dossier (G2 / claude-tools-vez)
# ════════════════════════════════════════════════════════════════════════════
# dg_from_analysis_task <bearer> <dossier_id> <bead_ref> <analysis_input_json>
#   Flow G step 2: a runner failure that triggers create_analysis_task ALSO
#   writes ONE §5 dossier so the failed bead surfaces in the Inbox as a
#   human-readable failure summary, not just a queued analysis bead. The
#   dossier shape is EMERGENT (§5.2.1 — no schema branch): a deep body with a
#   "Runner timeline" section grouped by attempt, plus ONE
#   `approve-recommendation` Item so Brian can ack the analysis.
#
#   analysis_input_json:
#     { task_title, reason, classification?, analysis_task_id?, analysis_desc?,
#       runner_notes: [ "Runner: …", … ] }
#
#   trigger="human_flag" (the runner is flagging this bead for human review —
#   the closest fit in the §4.1 trigger enum; analysis ISN'T a separate
#   trigger). tier="blocking". diagrams[]=[] is permissible (§5.1 AD7: a
#   failure summary is non-structural — there is no fork to diagram).
#
#   The Item's consequence_block is the zero-effect shape — approving is just
#   an acknowledgement; the actual analysis bead has already been created by
#   the caller (run-beads-tasks.sh `create_analysis_task`). No auto-applied
#   side effects beyond the ack itself.
dg_from_analysis_task() {
  local bearer="${1:-}" did="${2:-}" bref="${3:-}" ai="${4:-}" gi
  printf '%s' "$ai" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "dossier-gen: reject — analysis input not a JSON object" >&2; return 2; }
  [[ -n "$did" && -n "$bref" ]] || {
    echo "dossier-gen: reject — need <dossier_id> <bead_ref>" >&2; return 2; }

  # Group runner_notes[] into ATTEMPTS for the timeline section. Each terminal
  # classification line (not `tool-error`) closes an attempt; intervening
  # `tool-error` lines fold under the next attempt as intra-attempt errors.
  # Output: a prose string like
  #   "Attempt 1 — 19:42:55Z · TASK_NOT_CLOSED — no stream preserved
  #    Attempt 2 — 19:48:12Z · WATCHDOG_KILL — log: .beads/logs/foo.jsonl
  #        tool errors: permission-denied (×3); mcp-unavailable (×1)"
  local timeline
  timeline=$(printf '%s' "$ai" | jq -r '
    def parse_line:
      . as $raw
      | capture("^Runner:\\s+(?<rest>.*)$"; "x") // null
      | if . == null then null
        else .rest as $r
          | if ($r | test("^tool-error\\s+"; "x")) then
              { kind:"tool", text: ($r | sub("^tool-error\\s+"; "")) }
            else
              # Terminal classification: "<CLASS> at <HH:MM:SSZ> [— <tail>]"
              # The class token is the leading uppercase-or-underscore run; the
              # tail is anything after the timestamp (em-dash, ASCII dash, or
              # bare). Whatever lives there is rendered verbatim.
              ( $r | capture("^(?<cls>[A-Z][A-Z0-9_:]*)\\s+at\\s+(?<ts>\\S+)(?:[\\s—-]+(?<tail>.*))?$"; "x") ) as $m
              | if $m then { kind:"term", cls:$m.cls, ts:$m.ts,
                             tail:(($m.tail // "") | sub("^\\s+";"") | sub("\\s+$";"")) }
                else { kind:"term", cls:"UNCLASSIFIED", ts:"", tail:$r }
                end
            end
        end;
    ( .runner_notes // []
      | map( select(type=="string") | parse_line )
      | map(select(. != null)) ) as $events
    | reduce $events[] as $e ([{attempts:[], pending:[]}];
        if $e.kind == "tool" then
          .[0].pending += [$e.text] | .
        else
          .[0].attempts += [ { ts:$e.ts, cls:$e.cls, tail:$e.tail, tools:.[0].pending } ]
          | .[0].pending = []
          | .
        end )
    | .[0] as $g
    | ( $g.attempts | to_entries
        | map(
            ( "Attempt " + ((.key+1)|tostring)
              + " — " + (if .value.ts != "" then .value.ts else "(no timestamp)" end)
              + " · " + .value.cls
              + (if .value.tail != "" then " — " + .value.tail else "" end)
            )
            + ( if (.value.tools|length) > 0
                then "\n    tool errors during this attempt: " + (.value.tools | join("; "))
                else "" end )
          )
        | join("\n") ) as $body
    | ( if ($g.pending|length) > 0
        then ( if $body == "" then "" else $body + "\n" end )
             + "Intra-attempt tool errors after the last terminal line: "
             + ($g.pending | join("; "))
        else $body end )
    | if . == "" then "No Runner: notes recorded yet on this bead." else . end
  ' 2>/dev/null) || timeline="(timeline unavailable — runner_notes failed to parse)"

  # Plain-English class summary mirrors the inbox-view.js CLASS_PLAIN map so
  # the human sees the same words on phone and in this body. Kept here (NOT
  # imported) because dossier-gen.sh is bash + jq and cannot share JS; the
  # mapping is short and stable. An unknown class passes through verbatim.
  local plain_summary
  plain_summary=$(printf '%s' "$ai" | jq -r '
    ( .classification // .reason // "UNKNOWN_FAILURE" ) as $c
    | { AUTH_FAILURE: "Auth is broken — the runner is dead until you fix it.",
        BILLING_ERROR: "Billing failed — the runner is dead until you fix it.",
        STUCK_NEEDS_HUMAN: "A worker hit a fork it must not decide — it needs you.",
        CONTEXT_OVERFLOW: "Ran out of context — an analysis task will re-scope to remaining work.",
        MAX_OUTPUT_TOKENS: "Hit the output ceiling — an analysis task will split the work.",
        SERVER_ERROR: "Upstream server error after retries — needs eyes.",
        WATCHDOG_KILL: "Stuck with no output — the watchdog killed it.",
        RATE_LIMIT: "Rate-limited — routine; backs off and retries.",
        UNKNOWN_FAILURE: "Failed for an unclassified reason — analysis will investigate.",
        TASK_NOT_CLOSED: "Exited clean but left the bead open — looked green, isn’t."
      } as $m
    | ($m[$c] // ($c + " — see analysis task for details."))' 2>/dev/null) || plain_summary="Failure details — see analysis task."

  # Build the generation-input. The §5 schema requires sections[]≥1 with non-
  # empty heading+prose; the source's `sections` array is consumed by
  # dg__author verbatim (line 451). diagrams:[] is valid for non-structural.
  gi=$(printf '%s' "$ai" | jq -c \
        --arg did "$did" --arg bref "$bref" \
        --arg plain "$plain_summary" --arg timeline "$timeline" '
        . as $a
        | ( .task_title // $bref ) as $title
        | ( .reason // .classification // "unknown" ) as $reason
        | ( .analysis_task_id // "" ) as $atid
        | ( .analysis_desc // "" ) as $adesc
        | ( "Runner-killed bead " + $bref + " — " + $reason
            + (if $atid != "" then ". Analysis task " + $atid + " is queued." else "." end) ) as $tldr
        | ( "What failed: " + $plain
            + (if $atid != ""
               then "\n\nAn analysis task (" + $atid + ") has been created and depends on "
                    + $bref + ". A fresh agent will inspect the failure and propose next steps "
                    + "(split, redesign, retry, or re-scope) before " + $bref + " runs again."
               else "\n\nA fresh-context analysis is recommended before retrying this bead." end)
          ) as $full
        | [ { heading:"What failed",
              prose:($plain
                + "\n\nClassification: " + $reason
                + ".\nBead: " + $bref + " (" + $title + ").") },
            { heading:"Runner timeline",
              prose:$timeline },
            { heading:"Analysis plan",
              prose:( if $adesc != "" then $adesc
                      else "An analysis task has been queued (or will be queued) to investigate this failure with a fresh agent on a clean context window. Approving below acknowledges the analysis is in flight; no other action is required." end ) }
          ] as $sections
        | { id:$did, kind:"decide", trigger:"human_flag",
            bead_ref:$bref, tier:"blocking", timer_fire_at:null,
            source:{ tldr:$tldr,
                     ask:("Acknowledge the analysis on " + $bref + "?"),
                     sections:$sections,
                     diagrams:[],
                     full_detail:$full,
                     structural:false },
            items:[ { id:($did + "-ack"),
                      kind:"approve-recommendation",
                      framing:{ ask:("Approve the analysis on " + $bref + "?"),
                                why:"The runner could not complete this bead unattended; a fresh-context analysis is the next safe step. Approving is an acknowledgement — the analysis task is already queued." },
                      context_anchor:{ where:("Runner-killed bead " + $bref + " — " + $reason),
                                       expansion:("The runner classified this failure as " + $reason + ". " + $plain + " The Runner: note timeline above shows what each attempt did before the runner gave up.") },
                      recommendation:{ value:"acknowledge",
                                       why:"Acknowledge the queued analysis so the failure stops looking silent on the Board." },
                      reversible:"Fully reversible — acknowledgement applies no consequence on the work plane; the analysis bead is already independent of this dossier.",
                      consequence_block:{ creates:[], unblocks:[], labels:[], status_changes:[] } } ] }' 2>/dev/null) || gi=""
  [[ -n "$gi" ]] || { echo "dossier-gen: reject — could not build analysis-task generation input" >&2; return 3; }
  dg_generate "$bearer" "$gi"
}
