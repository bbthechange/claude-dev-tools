#!/bin/bash
# beads-runner/daemon/check-plist-drift.sh — shout when the daemon's launchd
# config has drifted from the committed template (claude-tools-6s6x).
#
# THE BUG THIS CATCHES
#   Editing launchd-plist.template (e.g. USAGE_THRESHOLD 85→95) and cycling with
#   `.stop-beads` is a SILENT NO-OP for the daemon. `.stop-beads` cycles the
#   workspace runner loop, not the LaunchAgent. launchd loads EnvironmentVariables
#   from the RENDERED plist at ~/Library/LaunchAgents/ at *bootstrap* time only.
#   Until daemon/install.sh re-renders AND re-bootstraps, the live daemon keeps
#   enforcing the old value — the template change is committed but never applied
#   (the bgw "config committed, prod wiring not applied" pattern on the daemon
#   axis). This script is the "Done means verified" detector for that.
#
# WHAT IT CHECKS (EnvironmentVariables only — the documented failure surface)
#   A. installed plist file (~/Library/LaunchAgents/...) vs what install.sh would
#      render from the current template. Mismatch ⇒ template edited, install.sh
#      not re-run.
#   B. the env launchd ACTUALLY loaded (`launchctl print`) vs the current
#      template. Mismatch (wrong value OR an expected key absent from a LOADED
#      daemon) ⇒ install.sh ran but bootstrap-over-existing didn't reload env
#      (the ambiguity the bug report worried about).
#   Comments/whitespace are ignored — only env keys/values are compared, so a
#   cosmetic template edit doesn't false-alarm.
#
#   (A) is the AUTHORITATIVE file check; (B) confirms the live env and assumes
#   launchd echoes EnvironmentVariables verbatim under `environment = {` (true
#   on current macOS — if a future launchd ever normalizes a value like PATH,
#   (B) could flag it, which is a signal worth investigating, not noise).
#
# EXIT 0 if in sync (prints `mismatches=0`); non-zero (and prints each DRIFT
# line) otherwise. NOTE lines (daemon not installed / not loaded) are
# informational and do NOT count as drift — this script can't know whether a
# given machine is supposed to run the daemon.
#
# Usage:
#   bash beads-runner/daemon/check-plist-drift.sh
#
# Testability: TEMPLATE, PLIST_DEST, LABEL, DAEMON_SH, LOG_DIR and HOME are all
# overridable via env; `launchctl` is resolved on PATH (shim it in tests).

set -u

DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=render-plist.sh
. "$DAEMON_DIR/render-plist.sh"

LABEL="${LABEL:-com.beads-runner.daemon}"
TEMPLATE="${TEMPLATE:-$DAEMON_DIR/launchd-plist.template}"
DAEMON_SH="${DAEMON_SH:-$DAEMON_DIR/daemon.sh}"
LOG_DIR="${LOG_DIR:-$HOME/.cache/claude-tools/daemon-logs}"
PLIST_DEST="${PLIST_DEST:-$HOME/Library/LaunchAgents/$LABEL.plist}"

if [ ! -f "$TEMPLATE" ]; then
  echo "check-plist-drift: FATAL: template missing at $TEMPLATE" >&2
  exit 2
fi

# Parse the EnvironmentVariables <key>/<string> pairs from a plist body on
# stdin → "KEY<TAB>VALUE" lines. Pure bash. Assumes the plist is machine-
# rendered one-tag-per-line with flat string-only env values (which launchd
# EnvironmentVariables must be). XML comments are stripped FIRST — even a
# comment carrying a literal <string>…</string> can't emit a spurious pair.
_parse_env_pairs() {
  local line key="" in_env=0 armed=0 val in_comment=0
  while IFS= read -r line; do
    # Skip XML comments (single- or multi-line) so prose like a sample
    # <string>old value</string> inside a comment can't poison the parse.
    if [ "$in_comment" = 1 ]; then
      case "$line" in *"-->"*) in_comment=0 ;; esac
      continue
    fi
    case "$line" in
      *"<!--"*"-->"*) continue ;;          # whole-line comment
      *"<!--"*)       in_comment=1; continue ;;  # comment opens here
    esac
    case "$line" in
      *"<key>EnvironmentVariables</key>"*) armed=1; continue ;;
    esac
    if [ "$armed" = 1 ]; then
      case "$line" in *"<dict>"*) in_env=1; armed=0; continue ;; esac
    fi
    if [ "$in_env" = 1 ]; then
      case "$line" in
        *"</dict>"*) in_env=0; continue ;;
        *"<key>"*"</key>"*) key="${line#*<key>}"; key="${key%%</key>*}" ;;
        *"<string>"*"</string>"*)
          val="${line#*<string>}"; val="${val%%</string>*}"
          printf '%s\t%s\n' "$key" "$val"
          key=""                            # consume the key (no mis-pairing)
          ;;
      esac
    fi
  done
}

# Look up a value by key in "KEY<TAB>VALUE" pairs read from stdin.
# Prints the value and returns 0 if found; returns 1 (prints nothing) if not.
_pairs_lookup() {
  local key="$1" k v
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$key" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# Isolate the `environment = {` block of `launchctl print` (stdin) — the env
# launchd actually LOADED. Deliberately NOT `inherited environment` or
# `default environment` (launchd's own sections — `default environment` carries
# a bare PATH that would false-positive against our homebrew PATH). Emits the
# leading-trimmed `KEY => VALUE` lines inside the block.
_live_env_block() {
  local line trimmed in_block=0
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
    if [ "$in_block" = 0 ]; then
      [ "$trimmed" = "environment = {" ] && in_block=1
      continue
    fi
    [ "$trimmed" = "}" ] && { in_block=0; continue; }
    printf '%s\n' "$trimmed"
  done
}

# Value launchd loaded for a key, parsed from a pre-extracted env block.
# Block lines look like:  USAGE_THRESHOLD => 95
# Prints the value (trimmed) or nothing if the key isn't present.
_live_env_value() {
  local key="$1" block="$2" hit
  hit="$(printf '%s\n' "$block" | grep -E "^${key} => " | head -1)" || true
  [ -z "$hit" ] && return 0
  hit="${hit#*=> }"
  hit="${hit%"${hit##*[![:space:]]}"}"          # trim trailing whitespace
  printf '%s' "$hit"
}

rendered="$(render_daemon_plist "$TEMPLATE" "$DAEMON_SH" "$LOG_DIR" "$HOME")"

# Expected env (key→value) from the current template.
declare -a EXP_KEYS=() EXP_VALS=()
while IFS=$'\t' read -r k v; do
  [ -z "$k" ] && continue
  EXP_KEYS+=("$k"); EXP_VALS+=("$v")
done < <(printf '%s\n' "$rendered" | _parse_env_pairs)

mismatches=0
checked=0

echo "check-plist-drift: template=$TEMPLATE"
echo "check-plist-drift: plist=$PLIST_DEST"

# ── A. installed plist file vs rendered template ───────────────────────────
if [ ! -f "$PLIST_DEST" ]; then
  echo "NOTE    daemon not installed (no plist at $PLIST_DEST) — run install.sh"
else
  installed_pairs="$(cat "$PLIST_DEST" | _parse_env_pairs)"
  for i in "${!EXP_KEYS[@]}"; do
    k="${EXP_KEYS[$i]}"; want="${EXP_VALS[$i]}"
    checked=$((checked + 1))
    if got="$(printf '%s\n' "$installed_pairs" | _pairs_lookup "$k")"; then
      if [ "$got" != "$want" ]; then
        echo "DRIFT   installed plist: $k='$got' but template wants '$want' — re-run install.sh"
        mismatches=$((mismatches + 1))
      fi
    else
      echo "DRIFT   installed plist: $k absent (template wants '$want') — re-run install.sh"
      mismatches=$((mismatches + 1))
    fi
  done
fi

# ── B. live launchd-loaded env vs rendered template ────────────────────────
UID_NUM="$(id -u)"
live="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null || true)"
if [ -z "$live" ]; then
  echo "NOTE    daemon not loaded in launchd (gui/$UID_NUM/$LABEL) — start with install.sh"
else
  live_block="$(printf '%s\n' "$live" | _live_env_block)"
  for i in "${!EXP_KEYS[@]}"; do
    k="${EXP_KEYS[$i]}"; want="${EXP_VALS[$i]}"
    checked=$((checked + 1))
    if printf '%s\n' "$live_block" | grep -qE "^${k} =>"; then
      got="$(_live_env_value "$k" "$live_block")"
      if [ "$got" != "$want" ]; then
        echo "DRIFT   live daemon: $k='$got' but template wants '$want' — re-run install.sh to re-bootstrap"
        mismatches=$((mismatches + 1))
      fi
    else
      # The template defines this key but the LOADED daemon doesn't carry it —
      # launchd echoes every EnvironmentVariables key it loaded, so an absent
      # one means the bootstrap never picked it up. (A) is authoritative for the
      # installed FILE; this is the live-bootstrap-didn't-take signal.
      echo "DRIFT   live daemon: $k absent from loaded env (template wants '$want') — re-run install.sh to re-bootstrap"
      mismatches=$((mismatches + 1))
    fi
  done
fi

echo "check-plist-drift: checked=$checked mismatches=$mismatches"
if [ "$mismatches" -gt 0 ]; then
  echo "check-plist-drift: DRIFT detected — the live daemon does not match the committed template."
  echo "  Fix:  bash $DAEMON_DIR/install.sh   (it boots out + re-bootstraps with the new env)"
  exit 1
fi
exit 0
