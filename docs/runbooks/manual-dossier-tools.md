# Runbook: manually invoke the dossier-builder and upload a dossier

## When

- You want to iterate on the dossier-builder system prompt (`beads-runner/agents/dossier-builder.system.md`) against a real input.
- You want to push a synthetic dossier into the production Cloudflare engine for testing.
- You're debugging why the production path (worker → ask-brian MCP → MCP server dispatches dossier-builder → engine) isn't producing what you'd expect.

## 1. Run the dossier-builder agent in isolation

The dossier-builder agent is normally spawned by the `ask-brian` MCP server with the worker's context. To run it standalone:

```bash
# Construct a sample input matching the documented input shape
cat > /tmp/dbtest-input.json <<'EOF'
{
  "dossier_id": "dossier-test-MANUAL-$(date +%s)",
  "bead_ref": "claude-tools-<some-real-bead>",
  "workspace_dir": "/Users/brianbutler/code/claude-tools",
  "question": "<one-sentence trigger from the worker>",
  "options": [
    { "label": "Option A", "blast_radius": "..." },
    { "label": "Option B", "blast_radius": "..." }
  ],
  "recommendation": "<optional: worker's pick + why>",
  "reversible": "<optional: short note>",
  "context_dump": "<the meaty field: rich unconstrained prose from the worker about what's in its head. Multi-paragraph is fine.>"
}
EOF

# Invoke claude -p directly with the dossier-builder system prompt
claude -p "$(cat /tmp/dbtest-input.json)" \
  --append-system-prompt "$(cat beads-runner/agents/dossier-builder.system.md)" \
  --output-format stream-json --verbose \
  --model claude-sonnet-4-6 \
  --add-dir /Users/brianbutler/code/claude-tools \
  --permission-mode default \
  --disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode Write Edit MultiEdit NotebookEdit BashWriteEdits \
  > /tmp/dbtest-stream.jsonl 2>&1

# Extract the final result (which should be the JSON dossier on stdout)
while IFS= read -r line; do
  r=$(printf '%s' "$line" | jq -r 'select(.type=="result") | .result // empty' 2>/dev/null) || r=""
  [ -n "$r" ] && printf '%s' "$r" > /tmp/dbtest-result.txt
done < /tmp/dbtest-stream.jsonl

cat /tmp/dbtest-result.txt
```

The result may be wrapped in a `\`\`\`json` markdown fence with prose preamble (a known prompt-violation the agent commits sometimes). To extract pure JSON:

```bash
python3 -c '
import re, json, sys
with open("/tmp/dbtest-result.txt") as f:
    text = f.read()
m = re.search(r"```json\s*\n(.*?)\n```", text, re.DOTALL)
if not m:
    m = re.search(r"(\{.*\})\s*$", text, re.DOTALL)
if not m:
    print("no JSON found"); sys.exit(1)
obj = json.loads(m.group(1))
with open("/tmp/dbtest-dossier.json", "w") as out:
    json.dump(obj, out, indent=2)
print("body keys:", list(obj["body"].keys()))
print("sections:", len(obj["body"].get("sections", [])))
print("diagrams:", len(obj["body"].get("diagrams", [])))
print("items:", len(obj.get("items", [])))
'
```

## 2. Upload a dossier to the production engine

You'll need both the bash libs + the dossier output to feed into `engine-bridge.sh write_polished`. The bridge's `write_polished` op takes a generation_input JSON, dispatches `dg_generate` (which calls the author via `DG_AUTHOR_CMD`), validates, persists.

To use your pre-baked dossier (from step 1 above), set `DG_AUTHOR_CMD` to a script that just echoes it:

```bash
# Author-cmd script that ignores stdin and emits our pre-baked content
cat > /tmp/dbtest-author.sh <<'EOF'
#!/usr/bin/env bash
cat /tmp/dbtest-dossier.json
EOF
chmod +x /tmp/dbtest-author.sh

# CRITICAL: the dossier body must include `dossier_schema_version: 2` and
# each item's consequence_block must include `cb_schema_version: 2`. The
# engine's write-gate rejects writes missing these fields. Patch if needed:
jq '
  .body.dossier_schema_version = 2 |
  .items |= map(
    .consequence_block.cb_schema_version = 2 |
    if .options then .options |= map(.consequence_block.cb_schema_version = 2) else . end
  )
' /tmp/dbtest-dossier.json > /tmp/dbtest-dossier-patched.json

# Update author script to point at the patched file
sed -i.bak 's|/tmp/dbtest-dossier.json|/tmp/dbtest-dossier-patched.json|g' /tmp/dbtest-author.sh

# Build the generation_input (envelope-level fields)
DOSSIER_ID="dossier-test-$(date +%s)"
jq -n \
  --arg id "$DOSSIER_ID" \
  --arg bead_ref "<some-bead-ref-that-the-engine-will-accept>" \
  '{id:$id, kind:"overview", trigger:"proactive_checkpoint", bead_ref:$bead_ref,
    tier:"timed-fyi", timer_fire_at:null, source:{}, items:[]}' \
  > /tmp/dbtest-gi.json

# Run engine-bridge.sh write_polished
export COORDINATOR_URL="https://coordinator-cf.bbthechange.workers.dev"
export COORDINATOR_TOKEN="$(security find-generic-password -s "claude-beads-runner.coordinator-token" -w)"
export DG_AUTHOR_CMD="/tmp/dbtest-author.sh"

bash mcp-askbrian/helpers/engine-bridge.sh write_polished "$(cat /tmp/dbtest-gi.json)"
# On success, prints the dossier_id and exits 0.
```

## Valid trigger values

The engine's `validateBody` enforces a closed enum on the envelope's `trigger` field:

- `human_flag` — bd `human` label triggered
- `worker_stuck` — agent's deliberate fork signal
- `stage_gate` — lifecycle stage gate
- `proactive_checkpoint` — Flow F overview

Other values are rejected. Pick whatever fits your test scenario.

## Verifying the upload

```bash
curl -sS -X POST https://coordinator-cf.bbthechange.workers.dev/ \
  -H "Authorization: Bearer $COORDINATOR_TOKEN" \
  -H "content-type: application/json" \
  -d "{\"op\":\"get\",\"args\":[\"dossier\",\"$DOSSIER_ID\"]}" \
  | jq '{id, bead_ref, kind, tier, schema_version, body_keys: (.body|keys), section_count: (.body.sections|length), diagram_count: (.body.diagrams|length), tldr_first_100: (.body.tldr[:100])}'
```

Then look at the Inbox URL — `https://claude-wrangler-inbox.pages.dev/` — to see the dossier rendered on the phone surface. Find it in the list by `bead_ref` or by the title (the tldr, post-`56h` fix).

## Common errors at write time

| Error | Fix |
|---|---|
| `dossier-gen: reject — §4.1 trigger: human_flag\|worker_stuck\|stage_gate\|proactive_checkpoint` | Use one of the valid trigger values |
| `dossier-gen: reject — body missing integer dossier_schema_version (§5.1)` | Patch body with `dossier_schema_version: 2` |
| `dossier-gen: reject — Item '<id>' consequence_block missing integer cb_schema_version (§5.3)` | Patch every consequence_block with `cb_schema_version: 2` |
| `co: 401 — bearer token missing/invalid` | The token is wrong or expired; re-fetch from Keychain |
| `co: adapter - unsupported POST proxy op '<op>'` | The CF.10 adapter doesn't passthrough this op; the request was sent through a Pages Function instead of directly to the Worker |
