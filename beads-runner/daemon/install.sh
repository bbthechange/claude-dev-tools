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

# Shared token-substitution (single source of truth; check-plist-drift.sh
# renders identically so it can compare installed vs expected — claude-tools-6s6x).
# shellcheck source=render-plist.sh
. "$DAEMON_DIR/render-plist.sh"

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

# Render the plist via the shared substitution function.
render_daemon_plist "$TEMPLATE" "$DAEMON_SH" "$LOG_DIR" "$HOME" > "$PLIST_DEST"
echo "install: wrote $PLIST_DEST"

# If the agent is already loaded, bootout FIRST, then bootstrap fresh. This is
# load-bearing for EnvironmentVariables (USAGE_THRESHOLD, etc.): launchd reads
# the plist's env at bootstrap time only, and bootstrap-over-an-already-loaded
# agent does NOT reliably reload changed env. Editing launchd-plist.template
# alone is a silent no-op until install.sh re-renders AND re-bootstraps — that
# was the claude-tools-6s6x bug (template said 95, live daemon kept enforcing
# 85 for hours). bootout→bootstrap makes re-running this script an unambiguous
# env reload.
UID_NUM="$(id -u)"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "install: existing agent found; bootstrapping out before reload"
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  # bootout is ASYNC — teardown may not be complete when it returns, and a
  # bootstrap that races it fails ("Bootstrap failed: 5: I/O error" / "service
  # already loaded"), which would leave the daemon DOWN. Wait for the service
  # to actually disappear (up to ~5s) before re-bootstrapping.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
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

# Surface the env launchd actually loaded so re-running this script after a
# template edit is self-verifying (claude-tools-6s6x acceptance: confirm the
# changed key by `launchctl print | grep`). If a value here doesn't match the
# template you just edited, the bootout/bootstrap above didn't take. Scoped to
# the loaded `environment = {` block — NOT the `default environment` section,
# which carries a bare PATH that would otherwise print alongside the real one.
echo "install: loaded EnvironmentVariables:"
launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
  | awk '/^[[:space:]]*environment = \{[[:space:]]*$/{f=1;next} f&&/^[[:space:]]*\}[[:space:]]*$/{f=0} f' \
  | grep -E 'USAGE_THRESHOLD|PATH|HOME' \
  | sed 's/^[[:space:]]*/  /' \
  || echo "  (none reported)"

echo
echo "install: done. To view logs:"
echo "  tail -F $LOG_DIR/stdout.log"
echo "install: to uninstall:"
echo "  $DAEMON_DIR/uninstall.sh"
