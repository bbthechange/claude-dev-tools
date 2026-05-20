# shellcheck shell=bash
# beads-runner/daemon/workspace-registry.sh — load + parse the per-machine
# workspace registry at ~/.config/claude-tools/workspaces.json.
#
# WHY THIS EXISTS (M1 scope, claude-tools-gim)
#   The daemon needs an index of "workspaces this machine is responsible
#   for" so M3's desired-state poll can iterate them. This file owns the
#   on-disk schema + the load/parse surface. M1 ships the schema + loader;
#   the consumers (capacity poll M2, desired-state poll M3, hosted-resolution
#   poll M4) wire against this surface in their own issues.
#
# SCHEMA — ~/.config/claude-tools/workspaces.json
#   {
#     "workspaces": [
#       {
#         "project_ref":              "<opaque coordinator-side ref>",
#         "dir":                      "<absolute path to workspace root>",
#         "coordinator_url":          "<https://… (optional)>",
#         "coordinator_token_keychain": "<keychain item name (optional)>"
#       },
#       ...
#     ]
#   }
#
# SECRETS POLICY
#   `coordinator_token_keychain` is the NAME of a macOS Keychain item, NOT
#   the token itself. Tokens NEVER live in this JSON. M2/M3 read the actual
#   bearer via `security find-generic-password -s <item> -w`. This mirrors
#   the BC-34 / §9.2 credential posture already used by lib/local-agent.sh.
#
# RELATIONSHIP TO .beads/runner.sh
#   The per-workspace runner config — env vars, project-local overrides —
#   stays in `<workspace>/.beads/runner.sh` (the existing source of truth
#   the workspace runner sources at startup). This registry is the
#   **daemon's index** of workspaces, NOT a replacement for runner.sh. The
#   daemon dereferences the workspace by `dir` and the workspace runner
#   continues to read its own `.beads/runner.sh`. Two files; no overlap.
#
# DEPENDENCIES
#   `jq` for JSON parsing. Same dependency the rest of beads-runner already
#   carries (runner.sh, lib/*.sh).

# Loaded-registry state — exported as arrays so callers can iterate without
# re-parsing JSON on every job. Reset by registry_load.
REGISTRY_LOADED=0
REGISTRY_PROJECT_REFS=()
REGISTRY_DIRS=()
REGISTRY_COORDINATOR_URLS=()
REGISTRY_TOKEN_KEYCHAIN_ITEMS=()

registry_reset() {
  REGISTRY_LOADED=0
  REGISTRY_PROJECT_REFS=()
  REGISTRY_DIRS=()
  REGISTRY_COORDINATOR_URLS=()
  REGISTRY_TOKEN_KEYCHAIN_ITEMS=()
}

# registry_load <path-to-workspaces.json>
#   Returns 0 on successful load (file present, valid JSON, schema ok).
#   Returns 1 if the file is missing or unparsable (caller decides whether
#   that is fatal — for M1's empty loop it is NOT fatal).
registry_load() {
  local path="$1"
  registry_reset

  if [ ! -f "$path" ]; then
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "workspace-registry: FATAL: jq not installed" >&2
    return 1
  fi
  if ! jq -e . "$path" >/dev/null 2>&1; then
    echo "workspace-registry: FATAL: $path is not valid JSON" >&2
    return 1
  fi
  if ! jq -e '.workspaces | type == "array"' "$path" >/dev/null 2>&1; then
    echo "workspace-registry: FATAL: $path missing .workspaces[] array" >&2
    return 1
  fi

  local n i
  n="$(jq -r '.workspaces | length' "$path")"
  i=0
  while [ "$i" -lt "$n" ]; do
    local pref dir curl tk
    pref="$(jq -r ".workspaces[$i].project_ref // \"\"" "$path")"
    dir="$(jq -r ".workspaces[$i].dir // \"\"" "$path")"
    curl="$(jq -r ".workspaces[$i].coordinator_url // \"\"" "$path")"
    tk="$(jq -r ".workspaces[$i].coordinator_token_keychain // \"\"" "$path")"

    if [ -z "$pref" ] || [ -z "$dir" ]; then
      echo "workspace-registry: WARN: workspaces[$i] missing project_ref or dir; skipping" >&2
      i=$((i + 1))
      continue
    fi

    REGISTRY_PROJECT_REFS+=("$pref")
    REGISTRY_DIRS+=("$dir")
    REGISTRY_COORDINATOR_URLS+=("$curl")
    REGISTRY_TOKEN_KEYCHAIN_ITEMS+=("$tk")
    i=$((i + 1))
  done

  REGISTRY_LOADED=1
  return 0
}

registry_count() {
  echo "${#REGISTRY_PROJECT_REFS[@]}"
}
