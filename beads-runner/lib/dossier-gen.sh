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
dg__author() {
  local gi="${1:-}" sv; sv="$(dg__sv)"
  if [[ -n "${DG_AUTHOR_CMD:-}" ]]; then
    # Provider-agnostic swap (§0.2): a real model emits the same §5 CONTENT.
    # Still ONE call; output goes through the SAME frozen §5 gate downstream.
    printf '%s' "$gi" | "${DG_AUTHOR_CMD}" 2>/dev/null
    return $?
  fi
  # Default single-pass deterministic transform of the §7.2 raw material.
  printf '%s' "$gi" | jq -c --argjson sv "$sv" '
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
                diagrams:$diagrams, full_detail:$full },
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
        | [ { caption: "Decision fork — pick one option (§7.2 worker-stuck)",
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
          source:{ tldr:(.tldr // .ask // "Worker reached a fork it must not resolve."),
                   ask:(.ask // .tldr // "Pick how to proceed."),
                   options:(.options // []),
                   diagrams:$diagrams,
                   recommendation:(.recommendation // null),
                   reversible:(.reversible // "Unspecified by the worker ask (§7.2).") },
          items:[ { id:($did + "-d1"),
                    kind:"pick-option",
                    framing:{ ask:(.ask // .tldr // "Pick how the worker should proceed."),
                              why:(.recommendation.why // "The worker reached a decision it must not make unilaterally (§7.2).") },
                    context_anchor:{ where:("Worker fork on " + $bref + " — a blocked decision the runner cannot resolve (§7.2 worker-driven STUCK)."),
                                     expansion:(.tldr // .ask // "The worker emitted a structured ask and exited; this is the pick-one decision it could not make.") },
                    options:(.options // []),
                    recommendation:(.recommendation // null),
                    reversible:(.reversible // "Unspecified by the worker ask (§7.2).") } ] }' 2>/dev/null) || gi=""
  [[ -n "$gi" ]] || { echo "dossier-gen: reject — could not build generation input from the §7.2 ask" >&2; return 3; }
  dg_generate "$bearer" "$gi"
}
