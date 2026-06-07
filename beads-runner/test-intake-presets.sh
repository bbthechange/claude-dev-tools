#!/usr/bin/env bash
# beads-runner/test-intake-presets.sh — I4 anti-drift harness
# (claude-tools-vvh; epic claude-tools-kie).
#
# Asserts the three places that name the entry-intent preset catalog
# agree on what's in it. The canonical file is
# `agents/intake-presets.json`; the Pages-side mirror is
# `web/functions/api/intake/_presets-catalog.js`; the L2 gate-policy
# script keeps a `PRESET_ENUM` array in `gate-policy.sh`. Adding a
# preset is documented in `agents/intake-presets.md` as a one-PR change
# — this harness is what fails the PR if a step is skipped.
#
# What it checks:
#   1. agents/intake-presets.json parses + each row has the v1 schema
#      fields (value, label, sublabel, entry_stage, gate_aggressiveness,
#      description).
#   2. Every row's `entry_stage` is in the L1 STAGE_ENUM (the spine).
#   3. Every row's `gate_aggressiveness` is in the L2 verdict surface
#      (auto-advance | gate-human).
#   4. The Pages-side mirror (_presets-catalog.js, via PRESETS[]) lists
#      the same values in the same order as the canonical JSON.
#   5. gate-policy.sh's PRESET_ENUM carries every catalog value WITH the
#      same gate_aggressiveness (the `value:gate` self-describing enum —
#      claude-tools-uxgpre). A missing value OR a mismatched gate token is
#      DRIFT.
#   6. schema_version agrees between the JSON (`schema_version`) and the
#      mirror (`SCHEMA_VERSION`) — a frozen-schema lockstep axis.
#   7. The catalog has no DUPLICATE preset `value`s (two radios / two
#      allowlist entries with the same key is an extensibility footgun).
#   8. gate-policy.sh actually RESOLVES a correct, non-empty verdict for
#      every catalog preset (driven via a fake `bd` on PATH) — proving a
#      preset that ships in the catalog + PRESET_ENUM is wired end-to-end
#      through L2, not just present as data. This is the "added the data,
#      forgot the wiring" failure this harness now owns (uxgpre).
#   9. enricher.system.md names every NORMAL catalog value (one-PR step).
#  10. Every SPECIAL catalog value (a row with `routing` set — schema_version 2,
#      claude-tools-uxvl4) is branched on BY NAME in daemon/intake-dispatch-
#      poll.sh. A special preset breaks the reductive (entry_stage, gate)
#      contract on purpose (no bd task; daemon-side routing), so it is EXEMPT
#      from checks 2/3/5/8/9 — but it MUST carry entry_stage:null +
#      gate_aggressiveness:null + a known `routing`, AND the daemon must know
#      how to dispatch it (else an overview-request would fall through to the
#      enricher and choke). This check closes that gap.
#
# Run: bash test-intake-presets.sh
# Exit: 0 on ALL PASS, 1 on any failure (with a clear "DRIFT:" line).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$REPO_DIR/agents/intake-presets.json"
MIRROR="$REPO_DIR/web/functions/api/intake/_presets-catalog.js"
GATE="$REPO_DIR/gate-policy.sh"
ENRICHER="$REPO_DIR/agents/enricher.system.md"
DISPATCH="$REPO_DIR/daemon/intake-dispatch-poll.sh"

# A SPECIAL preset (schema_version 2, claude-tools-uxvl4) carries a non-empty
# `routing` discriminator and breaks the reductive (entry_stage, gate) contract:
# no bd task, daemon-side routing. The known routing values (closed set — adding
# one is a deliberate change wired through the daemon). Used to drive the
# exemptions + the daemon-branch lockstep check below.
KNOWN_ROUTING=(overview-fyi)

PASS=0
FAIL=0

ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "test-intake-presets.sh: needs jq" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "test-intake-presets.sh: needs node" >&2; exit 2; }

echo "── canonical JSON: schema + value enums"

[[ -f "$JSON" ]] || { bad "agents/intake-presets.json missing"; exit 1; }
if ! jq -e . "$JSON" >/dev/null 2>&1; then
  bad "agents/intake-presets.json does not parse as JSON"
  exit 1
fi
ok "agents/intake-presets.json parses"

# STAGE_ENUM is the L1 spine; mirror it here so this harness does not
# depend on sourcing bd-stage.sh / gate-policy.sh just to know the enum.
# bd-stage.sh / gate-policy.sh anti-drift is enforced by test-gate-policy.sh.
STAGE_ENUM_HARNESS=(idea ux design impl docs tests)
GATE_VERDICTS=(auto-advance gate-human)

rows="$(jq -r '.presets | length' "$JSON")"
if [[ "$rows" -lt 1 ]]; then
  bad "catalog has zero presets (v1 needs at least one)"
else
  ok "catalog has $rows preset(s)"
fi

# No duplicate preset values: a repeated `value` would render two radios with
# the same key and create two write-allowlist entries — an extensibility
# footgun the catalog-driven UI cannot disambiguate (uxgpre).
dup_vals="$(jq -r '.presets[].value' "$JSON" | sort | uniq -d)"
if [[ -z "$dup_vals" ]]; then
  ok "all preset values are unique"
else
  bad "DRIFT: duplicate preset value(s) in catalog: $(printf '%s' "$dup_vals" | tr '\n' ' ')"
fi

i=0
while [[ "$i" -lt "$rows" ]]; do
  row="$(jq -c ".presets[$i]" "$JSON")"
  val="$(printf '%s' "$row" | jq -r '.value')"
  routing="$(printf '%s' "$row" | jq -r '.routing // ""')"

  # Always-required fields (present for EVERY row, normal or special).
  for k in value label sublabel description; do
    v="$(printf '%s' "$row" | jq -r --arg k "$k" '.[$k] // empty')"
    if [[ -z "$v" ]]; then
      bad "row $i missing required field '$k'"
    fi
  done

  es="$(printf '%s' "$row" | jq -r '.entry_stage // "null"')"
  ga="$(printf '%s' "$row" | jq -r '.gate_aggressiveness // "null"')"

  if [[ -n "$routing" ]]; then
    # ── SPECIAL preset (routing set) — exempt from the L1/L2 reductive contract.
    # It MUST instead carry the special shape: entry_stage:null,
    # gate_aggressiveness:null, and a KNOWN routing value. The daemon-branch
    # lockstep is checked in its own section below.
    found=0
    for r in "${KNOWN_ROUTING[@]}"; do [[ "$r" == "$routing" ]] && { found=1; break; }; done
    if [[ $found -eq 1 ]]; then
      ok "row $i ($val): SPECIAL preset, routing=$routing is a known value (exempt from stage/gate spine)"
    else
      bad "DRIFT: row $i ($val): routing='$routing' is NOT a known special routing (${KNOWN_ROUTING[*]}) — add the daemon branch + extend KNOWN_ROUTING"
    fi
    es_raw="$(printf '%s' "$row" | jq -c '.entry_stage')"
    ga_raw="$(printf '%s' "$row" | jq -c '.gate_aggressiveness')"
    [[ "$es_raw" == "null" ]] && ok "row $i ($val): SPECIAL preset entry_stage is null (no bd task)" \
      || bad "DRIFT: row $i ($val): SPECIAL preset must have entry_stage:null (got $es_raw)"
    [[ "$ga_raw" == "null" ]] && ok "row $i ($val): SPECIAL preset gate_aggressiveness is null (no L2 gate)" \
      || bad "DRIFT: row $i ($val): SPECIAL preset must have gate_aggressiveness:null (got $ga_raw)"
    i=$((i+1))
    continue
  fi

  # ── NORMAL preset — must reduce to (entry_stage ∈ STAGE_ENUM, gate ∈ verdicts).
  for k in entry_stage gate_aggressiveness; do
    v="$(printf '%s' "$row" | jq -r --arg k "$k" '.[$k] // empty')"
    if [[ -z "$v" ]]; then
      bad "row $i ($val) missing required field '$k' (a NORMAL preset must reduce to the spine; set `routing` to make it special)"
    fi
  done

  found=0
  for s in "${STAGE_ENUM_HARNESS[@]}"; do
    [[ "$s" == "$es" ]] && { found=1; break; }
  done
  if [[ $found -eq 1 ]]; then
    ok "row $i ($val): entry_stage=$es is in L1 STAGE_ENUM"
  else
    bad "DRIFT: row $i ($val): entry_stage=$es is NOT in L1 STAGE_ENUM (${STAGE_ENUM_HARNESS[*]})"
  fi

  found=0
  for g in "${GATE_VERDICTS[@]}"; do
    [[ "$g" == "$ga" ]] && { found=1; break; }
  done
  if [[ $found -eq 1 ]]; then
    ok "row $i ($val): gate_aggressiveness=$ga is in L2 verdict surface"
  else
    bad "DRIFT: row $i ($val): gate_aggressiveness=$ga is NOT in (${GATE_VERDICTS[*]})"
  fi

  i=$((i+1))
done

echo "── Pages-side mirror agrees with canonical JSON"

[[ -f "$MIRROR" ]] || { bad "_presets-catalog.js mirror missing"; exit 1; }

# Compare via node — it imports the ES module and dumps the field tuples
# to a stable representation we can diff against jq's view of the JSON.
# NB: entry_stage/gate_aggressiveness may be null (a SPECIAL preset) and routing
# may be absent (a NORMAL preset). Normalise null/absent → "" on BOTH sides so a
# legitimate null doesn't read as a spurious "null" vs "" mismatch: jq `// ""`
# and JS `?? ''` both collapse null/missing to "". `routing` is included so a
# routing drift between the JSON and the mirror is caught here (schema_version 2).
canon_dump="$(jq -r '.presets[] | "\(.value)|\(.label)|\(.sublabel)|\(.entry_stage // "")|\(.gate_aggressiveness // "")|\(.routing // "")|\(.description)"' "$JSON")"
mirror_dump="$(cd "$(dirname "$MIRROR")" && node --input-type=module -e "
import('./_presets-catalog.js').then(m => {
  const rows = m.PRESETS.map(p =>
    [p.value, p.label, p.sublabel, p.entry_stage ?? '', p.gate_aggressiveness ?? '', p.routing ?? '', p.description].join('|')
  );
  process.stdout.write(rows.join('\n'));
});
" 2>/dev/null)"

if [[ "$canon_dump" == "$mirror_dump" ]]; then
  ok "mirror PRESETS[] matches agents/intake-presets.json (same values, same order)"
else
  bad "DRIFT: mirror PRESETS[] differs from agents/intake-presets.json"
  printf '    canonical:\n%s\n' "$canon_dump" | sed 's/^/      /' >&2
  printf '    mirror:\n%s\n' "$mirror_dump" | sed 's/^/      /' >&2
fi

# schema_version is the frozen-shape contract; it must agree between the JSON
# (`schema_version`) and the mirror (exported `SCHEMA_VERSION`). The PRESETS[]
# diff above would not catch a schema bump on one side only (uxgpre).
json_sv="$(jq -r '.schema_version // empty' "$JSON")"
mirror_sv="$(cd "$(dirname "$MIRROR")" && node --input-type=module -e "
import('./_presets-catalog.js').then(m => process.stdout.write(String(m.SCHEMA_VERSION)));
" 2>/dev/null)"
if [[ -n "$json_sv" && "$json_sv" == "$mirror_sv" ]]; then
  ok "schema_version matches (JSON=$json_sv, mirror SCHEMA_VERSION=$mirror_sv)"
else
  bad "DRIFT: schema_version mismatch — JSON='$json_sv' vs mirror SCHEMA_VERSION='$mirror_sv'"
fi

echo "── gate-policy.sh PRESET_ENUM carries every catalog value:gate"

[[ -f "$GATE" ]] || { bad "gate-policy.sh missing"; exit 1; }

# PRESET_ENUM is now the self-describing `value:gate_aggressiveness` enum
# (uxgpre). Parse the array body and assert every catalog row appears with the
# SAME gate token — a missing value OR a mismatched gate is DRIFT.
gate_enum_line="$(grep -E '^PRESET_ENUM=\(' "$GATE" | head -1)"
if [[ -z "$gate_enum_line" ]]; then
  bad "gate-policy.sh has no PRESET_ENUM=(...) line — cannot check"
else
  enum_body="${gate_enum_line#PRESET_ENUM=(}"
  enum_body="${enum_body%)}"
  while IFS='|' read -r v ga; do
    [[ -n "$v" ]] || continue
    want="$v:$ga"
    found_exact=0 found_val=0 gate_in_enum=""
    # NB: `$enum_body` is intentionally UNquoted here — it is a single-line,
    # space-separated literal of safeKey-clean `value:gate` tokens (no glob
    # chars, no embedded whitespace), so word-splitting is the parse. (The
    # runtime gate-policy.sh iterates the real array `"${PRESET_ENUM[@]}"`
    # quoted; only this harness re-parses the source line.)
    for entry in $enum_body; do
      [[ "$entry" == "$want" ]] && { found_exact=1; break; }
      if [[ "${entry%%:*}" == "$v" ]]; then found_val=1; gate_in_enum="${entry#*:}"; fi
    done
    if [[ $found_exact -eq 1 ]]; then
      ok "gate-policy.sh PRESET_ENUM has '$want' (value:gate matches catalog)"
    elif [[ $found_val -eq 1 ]]; then
      bad "DRIFT: gate-policy.sh PRESET_ENUM has '$v' but gate '$gate_in_enum' != catalog gate_aggressiveness '$ga'"
    else
      bad "DRIFT: gate-policy.sh PRESET_ENUM is missing '$want' (catalog row, not in enum)"
    fi
  done < <(jq -r '.presets[] | select((.routing // "") == "") | "\(.value)|\(.gate_aggressiveness)"' "$JSON")
fi

echo "── gate-policy.sh resolves a correct verdict for every catalog preset"

# The end-to-end proof (uxgpre): drive the REAL `decide` path with a minimal
# fake `bd` on PATH (same precedent as test-gate-policy.sh) so a preset that
# ships in the catalog + PRESET_ENUM but is NOT actually resolvable by
# gate-policy.sh is caught here — not silently degraded to a fail-CLOSED
# "unrecognized-verdict" at runtime. Expected verdict is derived from the
# catalog's gate_aggressiveness: auto-advance → `auto-advance`; gate-human →
# `gate-human:<value>`.
if [[ ! -x "$GATE" ]]; then
  bad "gate-policy.sh not executable — cannot drive decide"
else
  GPWORK="$(mktemp -d 2>/dev/null)" || { echo "test-intake-presets.sh: mktemp failed" >&2; exit 70; }
  # Trap-based cleanup (matches test-gate-policy.sh) so the temp dir is removed
  # even if a future check between here and the explicit rm adds an early exit.
  trap 'rm -rf "$GPWORK"' EXIT
  GPBIN="$GPWORK/bin"; mkdir -p "$GPBIN"
  # Fake bd: `bd label list gp-<preset> --json` → ["preset:<preset>"]. The bead
  # id encodes the preset value as the suffix after `gp-`.
  cat > "$GPBIN/bd" <<'BDEOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "label" && "${2:-}" == "list" ]]; then
  bead="${3:-}"; preset="${bead#gp-}"
  printf '["preset:%s"]\n' "$preset"; exit 0
fi
exit 0
BDEOF
  chmod +x "$GPBIN/bd"
  while IFS='|' read -r v ga; do
    [[ -n "$v" ]] || continue
    case "$ga" in
      auto-advance) want="auto-advance" ;;
      gate-human)   want="gate-human:$v" ;;
      *)            want="__unsupported_gate:$ga" ;;
    esac
    got="$(PATH="$GPBIN:$PATH" "$GATE" decide "gp-$v" 2>/dev/null)"
    if [[ -n "$got" && "$got" == "$want" ]]; then
      ok "gate-policy decide preset:$v → '$got' (matches gate_aggressiveness=$ga)"
    else
      bad "DRIFT: gate-policy decide preset:$v → '$got' but catalog gate_aggressiveness=$ga expects '$want'"
    fi
  done < <(jq -r '.presets[] | select((.routing // "") == "") | "\(.value)|\(.gate_aggressiveness)"' "$JSON")
  rm -rf "$GPWORK"
fi

echo "── enricher.system.md mentions every catalog value (one-PR playbook step 3)"

if [[ ! -f "$ENRICHER" ]]; then
  bad "agents/enricher.system.md missing"
else
  # The playbook step 3 says: "Add one bullet to the enricher hat's
  # 'Entry stage label' resolution table". The hat picks (stage, gate)
  # off the preset, so a row that is not named in the prompt is a row
  # the hat doesn't know how to resolve. Closing that with a grep is
  # the cheapest enforcement we can offer (vs. relying on reviewer
  # attention, the failure mode the review flagged).
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if grep -qF "$v" "$ENRICHER"; then
      ok "enricher.system.md mentions '$v'"
    else
      bad "DRIFT: enricher.system.md does NOT mention '$v' (catalog row, not in resolution table)"
    fi
  done < <(jq -r '.presets[] | select((.routing // "") == "") | .value' "$JSON")
fi

echo "── SPECIAL presets (routing set) are branched on by name in the daemon"

# A special preset makes NO bd task and is NOT routed to the enricher — the
# daemon (intake-dispatch-poll.sh) must branch on its VALUE and route it
# elsewhere (overview-request → a proactive_checkpoint timed-fyi dossier). If a
# special preset shipped in the catalog WITHOUT a daemon branch, an
# overview-request intake would fall through to the enricher (which would try to
# bd-create from a null entry_stage and choke). Grep is the cheapest lockstep:
# the daemon source must mention the special value. (claude-tools-uxvl4 / L4.)
special_vals="$(jq -r '.presets[] | select((.routing // "") != "") | .value' "$JSON")"
if [[ -z "$special_vals" ]]; then
  ok "no SPECIAL presets in the catalog (daemon-branch check vacuously holds)"
elif [[ ! -f "$DISPATCH" ]]; then
  bad "daemon/intake-dispatch-poll.sh missing — cannot verify special-preset branch wiring"
else
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if grep -qF "$v" "$DISPATCH"; then
      ok "intake-dispatch-poll.sh branches on special preset '$v'"
    else
      bad "DRIFT: special preset '$v' has no branch in daemon/intake-dispatch-poll.sh (it would fall through to the enricher and choke)"
    fi
  done < <(printf '%s\n' "$special_vals")
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "test-intake-presets.sh: ALL PASS ($PASS checks)"
  exit 0
else
  echo "test-intake-presets.sh: $FAIL FAIL, $PASS PASS" >&2
  exit 1
fi
