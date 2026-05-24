#!/usr/bin/env bash
# Heal a workspace-identity mismatch between .beads/metadata.json and the
# embedded Dolt DB's _project_id. See docs/runbooks/heal-beads-identity-mismatch.md
# for background and when to use this.

set -euo pipefail

VERBOSE=0
DRY_RUN=0
PROBE_ID=""

usage() {
  cat <<'EOF'
Usage: heal-beads-identity-mismatch.sh [--verbose] [--dry-run] [--probe <bead-id>]

Heals a mismatch between .beads/metadata.json's project_id (canonical,
git-tracked) and the embedded Dolt DB's _project_id (local-only). Run
from inside the workspace whose .beads/ is mismatched. Only supports
embedded mode (dolt_mode=embedded, is_redirected=false).

  --verbose       Print every SQL the script considers, including no-ops.
  --dry-run       Diagnose and print the planned UPDATE, do not execute.
  --probe <id>    Bead ID to use for the post-heal write probe. Defaults
                  to the first ready bead found via 'bd ready'.

Exit codes:
  0  Heal succeeded (post-heal probe write worked without override).
  1  Generic failure / preflight failed.
  2  Not in embedded mode (dolt_mode != embedded) or redirected workspace.
  3  No mismatch detected — nothing to heal.
  4  Heal SQL ran but the post-heal probe still mismatched.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --probe) PROBE_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { printf '[heal-identity] %s\n' "$*" >&2; }
vlog() { (( VERBOSE )) && log "$*" || true; }

command -v bd   >/dev/null || { log "bd not on PATH"; exit 1; }
command -v dolt >/dev/null || { log "dolt not on PATH (brew install dolt)"; exit 1; }
command -v jq   >/dev/null || { log "jq not on PATH"; exit 1; }

# -- Preflight: must be embedded mode, not redirected ----------------------
CTX_JSON="$(BEADS_SKIP_IDENTITY_CHECK=1 bd context --json)"
DOLT_MODE="$(jq -r '.dolt_mode'      <<<"$CTX_JSON")"
REDIRECTED="$(jq -r '.is_redirected' <<<"$CTX_JSON")"
BEADS_DIR="$(jq -r '.beads_dir'      <<<"$CTX_JSON")"
DB_NAME="$(jq -r '.database'         <<<"$CTX_JSON")"
META_PROJECT_ID="$(jq -r '.project_id' <<<"$CTX_JSON")"

if [[ "$REDIRECTED" == "true" ]]; then
  log "workspace is a worktree redirect (is_redirected=true) — fix the main workspace, not this one"
  exit 2
fi
if [[ "$DOLT_MODE" != "embedded" ]]; then
  log "dolt_mode=$DOLT_MODE — this script only supports embedded mode"
  exit 2
fi

DATA_DIR="$BEADS_DIR/embeddeddolt"
if [[ ! -d "$DATA_DIR/$DB_NAME/.dolt" ]]; then
  log "embedded DB not found at $DATA_DIR/$DB_NAME/.dolt"
  exit 1
fi

vlog "beads_dir=$BEADS_DIR"
vlog "data_dir=$DATA_DIR  db=$DB_NAME"
vlog "metadata.json project_id=$META_PROJECT_ID"

# -- Confirm there IS a mismatch (do not heal blindly) ---------------------
PROBE_OUT="$(bd context >/dev/null 2>&1 && bd list --status=open --json 2>&1 || true)"
MISMATCH_OUT="$(bd update --notes "identity-heal preflight probe" --dry-run dummy 2>&1 || true)"
# `bd update --dry-run` may or may not exist depending on version; fall back to
# parsing the canonical error text from any write.
if ! grep -q "workspace identity mismatch" <<<"$MISMATCH_OUT"; then
  # Try a real probe write (and immediately roll it back is impossible — we
  # use a no-op note). If this succeeds, identity is already healthy.
  NOOP_OUT="$(bd kv set _identity_heal_probe "$(date -u +%s)" 2>&1 || true)"
  if grep -q "workspace identity mismatch" <<<"$NOOP_OUT"; then
    : # confirmed mismatch — fall through
  else
    log "no mismatch detected (writes succeed without override). Nothing to heal."
    bd kv clear _identity_heal_probe >/dev/null 2>&1 || true
    exit 3
  fi
fi

# Extract the DB-side _project_id from the error text (most reliable source).
DB_PROJECT_ID="$(grep -oE 'database _project_id:[[:space:]]+[0-9a-f-]+' <<<"$NOOP_OUT$MISMATCH_OUT" \
                 | head -1 \
                 | awk '{print $NF}')"
if [[ -z "$DB_PROJECT_ID" ]]; then
  log "could not extract DB _project_id from error output; aborting"
  log "raw output:"
  log "$NOOP_OUT"
  exit 1
fi

log "MISMATCH detected:"
log "  metadata.json project_id: $META_PROJECT_ID  (canonical, git-tracked)"
log "  database _project_id    : $DB_PROJECT_ID  (local DB)"
log "Plan: rewrite DB _project_id to match metadata.json."

if (( DRY_RUN )); then
  log "DRY RUN — not modifying the DB."
  log "Manual command equivalent:"
  echo "  dolt --data-dir '$DATA_DIR' sql -q \"USE \\\`$DB_NAME\\\`; UPDATE settings SET value='$META_PROJECT_ID' WHERE name='project_id'; UPDATE _metadata SET _project_id='$META_PROJECT_ID';\""
  exit 0
fi

# -- Stop any bd-managed Dolt process for this workspace -------------------
# Embedded mode doesn't run a long-lived server, but a `bd dolt start` may
# have left one. Best-effort.
if [[ -f "$BEADS_DIR/dolt-server.pid" ]]; then
  pid="$(cat "$BEADS_DIR/dolt-server.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    vlog "stopping bd-managed dolt server pid=$pid"
    bd dolt stop >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    sleep 1
  fi
fi

# -- Discover which table/column holds _project_id -------------------------
# bd has stored project_id in two places across versions:
#   - a `settings` (or `bd_settings`) row with name='project_id'
#   - a `_metadata` row with column `_project_id`
# We probe both and UPDATE whichever exists.
SHOW_TABLES="$(dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; SHOW TABLES;" --result-format=csv 2>/dev/null || true)"
vlog "tables in $DB_NAME:"
vlog "$SHOW_TABLES"

UPDATED=0
heal_via_settings() {
  local tbl="$1"
  local n; n=$(dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; SELECT COUNT(*) FROM \`$tbl\` WHERE name='project_id';" --result-format=csv 2>/dev/null | tail -1)
  if [[ "${n:-0}" =~ ^[1-9] ]]; then
    log "updating $tbl.value WHERE name='project_id' (rows=$n)"
    dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; UPDATE \`$tbl\` SET value='$META_PROJECT_ID' WHERE name='project_id';"
    UPDATED=1
  fi
}
heal_via_metadata() {
  local tbl="$1"
  local n; n=$(dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; SELECT COUNT(*) FROM \`$tbl\`;" --result-format=csv 2>/dev/null | tail -1)
  if [[ "${n:-0}" =~ ^[1-9] ]]; then
    log "updating $tbl._project_id (rows=$n)"
    dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; UPDATE \`$tbl\` SET _project_id='$META_PROJECT_ID';"
    UPDATED=1
  fi
}

# Best-effort across known schema names
for t in settings bd_settings beads_settings; do
  grep -qx "$t" <<<"$SHOW_TABLES" && heal_via_settings "$t" || true
done
for t in _metadata metadata bd_metadata _project_metadata; do
  grep -qx "$t" <<<"$SHOW_TABLES" && heal_via_metadata "$t" || true
done

if (( ! UPDATED )); then
  log "no known settings/metadata table found — falling back to broad scan"
  while IFS= read -r tbl; do
    [[ -z "$tbl" || "$tbl" == "Tables_in_${DB_NAME}" ]] && continue
    cols="$(dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; SHOW COLUMNS FROM \`$tbl\`;" --result-format=csv 2>/dev/null || true)"
    if grep -q "^_project_id," <<<"$cols"; then
      log "found _project_id column on $tbl — updating"
      dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; UPDATE \`$tbl\` SET _project_id='$META_PROJECT_ID';"
      UPDATED=1
    fi
  done <<<"$SHOW_TABLES"
fi

if (( ! UPDATED )); then
  log "no rows updated — schema may have changed; inspect manually"
  log "  dolt --data-dir '$DATA_DIR' sql -q \"USE \\\`$DB_NAME\\\`; SHOW TABLES;\""
  exit 1
fi

# Commit the change so it persists in the embedded DB's working set
dolt --data-dir "$DATA_DIR" sql -q "USE \`$DB_NAME\`; CALL DOLT_COMMIT('-Am', 'heal: rewrite _project_id to match metadata.json');" >/dev/null 2>&1 || true

# -- Post-heal probe -------------------------------------------------------
bd kv clear _identity_heal_probe >/dev/null 2>&1 || true
if bd kv set _identity_heal_probe "$(date -u +%s)" >/dev/null 2>&1; then
  bd kv clear _identity_heal_probe >/dev/null 2>&1 || true
  log "OK — post-heal write succeeded without BEADS_SKIP_IDENTITY_CHECK."
  exit 0
else
  log "post-heal probe STILL fails — heal incomplete"
  log "re-run with --verbose and inspect dolt schema manually"
  exit 4
fi
