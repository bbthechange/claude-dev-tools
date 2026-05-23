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
#   5. gate-policy.sh's PRESET_ENUM contains every catalog value.
#
# Run: bash test-intake-presets.sh
# Exit: 0 on ALL PASS, 1 on any failure (with a clear "DRIFT:" line).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$REPO_DIR/agents/intake-presets.json"
MIRROR="$REPO_DIR/web/functions/api/intake/_presets-catalog.js"
GATE="$REPO_DIR/gate-policy.sh"
ENRICHER="$REPO_DIR/agents/enricher.system.md"

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

i=0
while [[ "$i" -lt "$rows" ]]; do
  row="$(jq -c ".presets[$i]" "$JSON")"
  for k in value label sublabel entry_stage gate_aggressiveness description; do
    v="$(printf '%s' "$row" | jq -r --arg k "$k" '.[$k] // empty')"
    if [[ -z "$v" ]]; then
      bad "row $i missing required field '$k'"
    fi
  done

  es="$(printf '%s' "$row" | jq -r '.entry_stage')"
  ga="$(printf '%s' "$row" | jq -r '.gate_aggressiveness')"
  val="$(printf '%s' "$row" | jq -r '.value')"

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
canon_dump="$(jq -r '.presets[] | "\(.value)|\(.label)|\(.sublabel)|\(.entry_stage)|\(.gate_aggressiveness)|\(.description)"' "$JSON")"
mirror_dump="$(cd "$(dirname "$MIRROR")" && node --input-type=module -e "
import('./_presets-catalog.js').then(m => {
  const rows = m.PRESETS.map(p =>
    [p.value, p.label, p.sublabel, p.entry_stage, p.gate_aggressiveness, p.description].join('|')
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

echo "── gate-policy.sh PRESET_ENUM covers every catalog value"

[[ -f "$GATE" ]] || { bad "gate-policy.sh missing"; exit 1; }

gate_enum_line="$(grep -E '^PRESET_ENUM=\(' "$GATE" | head -1)"
if [[ -z "$gate_enum_line" ]]; then
  bad "gate-policy.sh has no PRESET_ENUM=(...) line — cannot check"
else
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if grep -qE "PRESET_ENUM=\([^)]*\<${v}\>" "$GATE"; then
      ok "gate-policy.sh PRESET_ENUM contains '$v'"
    else
      bad "DRIFT: gate-policy.sh PRESET_ENUM is missing '$v' (catalog row, not in enum)"
    fi
  done < <(jq -r '.presets[].value' "$JSON")
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
  done < <(jq -r '.presets[].value' "$JSON")
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "test-intake-presets.sh: ALL PASS ($PASS checks)"
  exit 0
else
  echo "test-intake-presets.sh: $FAIL FAIL, $PASS PASS" >&2
  exit 1
fi
