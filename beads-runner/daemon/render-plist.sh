# beads-runner/daemon/render-plist.sh — single source of truth for turning
# launchd-plist.template into the concrete plist body.
#
# WHY THIS EXISTS (claude-tools-6s6x)
#   install.sh WRITES the rendered plist; check-plist-drift.sh COMPARES the
#   installed/loaded plist against what install.sh *would* write now. If the
#   two callers substituted tokens differently, the drift check would
#   false-positive on every run. Defining the substitution once — here — keeps
#   "expected bytes" defined in exactly one place (same discipline as
#   verify-pages-deploy.sh: deployed bytes must match committed bytes).
#
# This file only defines a function; sourcing it has no side effects.

# render_daemon_plist TEMPLATE DAEMON_SH LOG_DIR HOME
#   Echoes the template body with the @@…@@ tokens substituted, exactly as
#   install.sh writes it to ~/Library/LaunchAgents/com.beads-runner.daemon.plist.
render_daemon_plist() {
  local tmpl="$1" daemon_sh="$2" log_dir="$3" home="$4"
  local body
  body="$(cat "$tmpl")"
  # bash parameter expansion so we never need a shell escape for the paths.
  body="${body//@@DAEMON_SH@@/$daemon_sh}"
  body="${body//@@LOG_DIR@@/$log_dir}"
  body="${body//@@HOME@@/$home}"
  printf '%s\n' "$body"
}
