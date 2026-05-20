#!/bin/bash
# beads-runner/daemon/uninstall.sh — unload + remove the per-user
# LaunchAgent for the beads-runner daemon (M1, claude-tools-gim).
#
# Leaves logs and the workspace registry in place (those are operator data,
# not install artifacts). If you want them gone too:
#   rm -rf ~/.cache/claude-tools/daemon-logs
#   rm    ~/.cache/claude-tools/daemon.pid     # only if the daemon is stopped
#   rm    ~/.config/claude-tools/workspaces.json

set -euo pipefail

LABEL="com.beads-runner.daemon"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "uninstall: bootstrapping out gui/$UID_NUM/$LABEL"
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || \
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
else
  echo "uninstall: agent not loaded; skipping bootout"
fi

if [ -f "$PLIST_DEST" ]; then
  rm -f "$PLIST_DEST"
  echo "uninstall: removed $PLIST_DEST"
else
  echo "uninstall: $PLIST_DEST already absent"
fi

# If the daemon is somehow still running (e.g. launched manually), the
# pidfile will still be present; we leave it to the daemon's EXIT trap to
# clean up. Just point at it for the operator.
PIDFILE="$HOME/.cache/claude-tools/daemon.pid"
if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "uninstall: daemon still running (pid=$pid). To stop: kill $pid"
  else
    echo "uninstall: stale pidfile present at $PIDFILE (daemon not alive); safe to rm"
  fi
fi

echo "uninstall: done."
