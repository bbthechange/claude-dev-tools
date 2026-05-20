#!/bin/bash
# beads-runner/daemon/install.sh — install + launchctl-load the per-user
# LaunchAgent for the beads-runner daemon (M1, claude-tools-gim).
#
# WHAT IT DOES
#   1. substitutes @@…@@ tokens in launchd-plist.template
#   2. writes the result to ~/Library/LaunchAgents/com.beads-runner.daemon.plist
#   3. `launchctl bootstrap` / `load` the plist into the user's GUI domain
#   4. prints a one-liner status so the operator can verify
#
# IDEMPOTENT: re-running this script overwrites the plist and re-loads it.

set -euo pipefail

DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$DAEMON_DIR/launchd-plist.template"
DAEMON_SH="$DAEMON_DIR/daemon.sh"

LABEL="com.beads-runner.daemon"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.cache/claude-tools/daemon-logs"
CONFIG_DIR="$HOME/.config/claude-tools"

if [ ! -f "$TEMPLATE" ]; then
  echo "install: FATAL: template missing at $TEMPLATE" >&2
  exit 1
fi
if [ ! -x "$DAEMON_SH" ] && [ ! -r "$DAEMON_SH" ]; then
  echo "install: FATAL: daemon.sh missing at $DAEMON_SH" >&2
  exit 1
fi

chmod +x "$DAEMON_SH" 2>/dev/null || true

mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$HOME/Library/LaunchAgents"

# Token substitution. Use bash parameter expansion so we never need a shell
# escape for the substituted paths.
plist_body="$(cat "$TEMPLATE")"
plist_body="${plist_body//@@DAEMON_SH@@/$DAEMON_SH}"
plist_body="${plist_body//@@LOG_DIR@@/$LOG_DIR}"
plist_body="${plist_body//@@HOME@@/$HOME}"

printf '%s\n' "$plist_body" > "$PLIST_DEST"
echo "install: wrote $PLIST_DEST"

# If the agent is already loaded, unload first so the new plist takes effect.
UID_NUM="$(id -u)"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "install: existing agent found; bootstrapping out before reload"
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
fi

# `bootstrap` is the modern verb (10.10+); fall back to `load` on older OSes.
if launchctl bootstrap "gui/$UID_NUM" "$PLIST_DEST" 2>/dev/null; then
  echo "install: bootstrapped agent into gui/$UID_NUM"
else
  echo "install: bootstrap failed; falling back to launchctl load"
  launchctl load "$PLIST_DEST"
fi

# Kickstart so RunAtLoad fires immediately on first install too.
launchctl kickstart -k "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true

sleep 1
echo "install: status:"
launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
  | grep -E '^\s*(state|pid|program|stdout path|stderr path)' \
  || echo "  (launchctl print returned nothing — check $LOG_DIR/stderr.log)"

echo
echo "install: done. To view logs:"
echo "  tail -F $LOG_DIR/stdout.log"
echo "install: to uninstall:"
echo "  $DAEMON_DIR/uninstall.sh"
