#!/bin/bash
# beads-runner/daemon/test-check-plist-drift.sh — offline coverage for the
# daemon plist-drift detector and install.sh's self-healing reload
# (claude-tools-6s6x).
#
# WHAT THIS PROVES
#   PART 0 — files exist, parse (bash -n), and install.sh sources the shared
#            renderer + boots out BEFORE bootstrap (the acceptance-#1
#            "re-running install.sh replaces the daemon with fresh env"
#            guarantee — without that order, env never reloads).
#   PART A — in sync (installed plist == rendered template, live env matches):
#            mismatches=0, exit 0.
#   PART B — THE BUG: template edited (USAGE_THRESHOLD 85→95) but install.sh
#            never re-run, so the installed plist AND the live daemon are still
#            85. Both comparisons must DRIFT; exit non-zero.
#   PART C — install.sh ran (installed plist == 95) but bootstrap-over-existing
#            didn't reload env, so the LIVE daemon is still 85. The file
#            comparison is clean; the live comparison must DRIFT; exit non-zero.
#   PART D — the `default environment` PATH section of `launchctl print` must
#            NOT false-positive against the daemon's homebrew PATH (regression
#            guard: the live lookup is scoped to the `environment = {` block).
#   PART E — not installed / not loaded ⇒ NOTE only, mismatches=0, exit 0
#            (the script can't know if a machine is meant to run the daemon).
#   PART F — acceptance #1: the REAL install.sh, run against a fake launchctl in
#            a temp HOME, boots out an already-loaded daemon BEFORE bootstrapping
#            (the new-pid mechanism), WAITS for the async teardown before
#            re-bootstrapping, and renders the plist; on a not-loaded daemon it
#            skips bootout. Proves the reload mechanism without bouncing the
#            live production daemon.
#   PART G — a <string> tag inside an EnvironmentVariables comment must NOT be
#            mistaken for a real env value (no false DRIFT).
#   PART H — a template key absent from a LOADED daemon's env is DRIFT, not a
#            NOTE (catches a bootstrap that didn't reload a newly-added key).
#
# Run: bash beads-runner/daemon/test-check-plist-drift.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT_SH="$HERE/check-plist-drift.sh"
INSTALL_SH="$HERE/install.sh"
RENDER_SH="$HERE/render-plist.sh"

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
has() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing '$2')";; esac; }
nothas() { case "$1" in *"$2"*) bad "$3 (unexpectedly contains '$2')";; *) ok "$3";; esac; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (got '$1' want '$2')"; }

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " daemon plist-drift detector — claude-tools-6s6x"
echo "════════════════════════════════════════════════════════════════════"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOME_OVR="$WORK/home"; mkdir -p "$HOME_OVR"
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
LAUNCHCTL_OUT="$WORK/launchctl.out"

# Fake launchctl: prints the canned `launchctl print` text if $LAUNCHCTL_OUT is
# a non-empty file, else exits 1 (daemon not loaded). Ignores its args.
cat > "$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
if [ -n "${LAUNCHCTL_OUT:-}" ] && [ -s "$LAUNCHCTL_OUT" ]; then
  cat "$LAUNCHCTL_OUT"; exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/launchctl"

# A template with @@HOME@@ token (exercises the shared renderer) + a policy env.
write_template() { # $1 = USAGE_THRESHOLD value
  cat > "$WORK/template" <<EOF
<plist><dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin</string>
    <key>HOME</key>
    <string>@@HOME@@</string>
    <!-- a comment mentioning USAGE_THRESHOLD must not poison the parse -->
    <key>USAGE_THRESHOLD</key>
    <string>$1</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>@@HOME@@</string>
</dict></plist>
EOF
}

# A rendered installed plist (HOME substituted) with a chosen threshold.
write_installed() { # $1 = USAGE_THRESHOLD value
  cat > "$WORK/installed.plist" <<EOF
<plist><dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin</string>
    <key>HOME</key>
    <string>$HOME_OVR</string>
    <key>USAGE_THRESHOLD</key>
    <string>$1</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$HOME_OVR</string>
</dict></plist>
EOF
}

# Canned `launchctl print` output. Deliberately includes inherited/default
# environment sections (with a CONFLICTING bare PATH) to prove the live lookup
# ignores them. $1 = the USAGE_THRESHOLD the live daemon actually loaded.
write_live() { # $1 = live USAGE_THRESHOLD value
  cat > "$LAUNCHCTL_OUT" <<EOF
com.beads-runner.daemon = {
	state = running
	pid = 4242
	inherited environment = {
		SSH_AUTH_SOCK => /var/run/whatever
	}
	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}
	environment = {
		OSLogRateLimit => 64
		PATH => /opt/homebrew/bin:/usr/bin
		HOME => $HOME_OVR
		USAGE_THRESHOLD => $1
		XPC_SERVICE_NAME => com.beads-runner.daemon
	}
}
EOF
}

run_drift() { # runs check-plist-drift.sh with overrides; sets $OUT and $RC
  OUT="$(PATH="$FAKEBIN:$PATH" \
         HOME="$HOME_OVR" \
         LAUNCHCTL_OUT="$LAUNCHCTL_OUT" \
         TEMPLATE="$WORK/template" \
         PLIST_DEST="$WORK/installed.plist" \
         DAEMON_SH="$HERE/daemon.sh" \
         LOG_DIR="$HOME_OVR/.cache/logs" \
         LABEL="com.beads-runner.daemon" \
         bash "$DRIFT_SH" 2>&1)"
  RC=$?
}

# ════════════════════════════════════════════════════════════════════════════
# PART 0 — files exist, parse, and install.sh is wired for a fresh env reload
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART 0 — files parse + install.sh self-healing reload (static) ──"
[[ -f "$DRIFT_SH" ]]   && ok "check-plist-drift.sh present"   || bad "check-plist-drift.sh missing"
[[ -f "$RENDER_SH" ]]  && ok "render-plist.sh present"        || bad "render-plist.sh missing"
bash -n "$DRIFT_SH"  2>/dev/null && ok "check-plist-drift.sh parses" || bad "check-plist-drift.sh syntax"
bash -n "$RENDER_SH" 2>/dev/null && ok "render-plist.sh parses"      || bad "render-plist.sh syntax"
bash -n "$INSTALL_SH" 2>/dev/null && ok "install.sh parses"          || bad "install.sh syntax"

grep -q "render_daemon_plist" "$RENDER_SH" \
  && ok "render-plist.sh defines render_daemon_plist" || bad "render-plist.sh defines render_daemon_plist"
grep -q "render-plist.sh" "$INSTALL_SH" \
  && ok "install.sh sources the shared renderer" || bad "install.sh sources render-plist.sh"
grep -q "render_daemon_plist" "$INSTALL_SH" \
  && ok "install.sh renders via render_daemon_plist" || bad "install.sh calls render_daemon_plist"

# bootout must come BEFORE bootstrap, or re-running install.sh won't reload env.
# anchor on the actual command (takes a "gui/... target); header comments use
# backticks, so they don't match.
boot_out_line="$(grep -n 'launchctl bootout "gui' "$INSTALL_SH" | head -1 | cut -d: -f1)"
boot_strap_line="$(grep -n 'launchctl bootstrap "gui' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$boot_out_line" && -n "$boot_strap_line" && "$boot_out_line" -lt "$boot_strap_line" ]]; then
  ok "install.sh boots out (line $boot_out_line) before bootstrap (line $boot_strap_line)"
else
  bad "install.sh bootout-before-bootstrap order (out=$boot_out_line strap=$boot_strap_line)"
fi

# ════════════════════════════════════════════════════════════════════════════
# PART A — in sync
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART A — in sync (installed == template == live) ──"
write_template 95; write_installed 95; write_live 95
run_drift
eq "$RC" "0" "exit 0 when in sync"
has "$OUT" "mismatches=0" "reports mismatches=0"
nothas "$OUT" "DRIFT" "no DRIFT line when in sync"

# ════════════════════════════════════════════════════════════════════════════
# PART B — THE BUG: template edited, install.sh never re-run
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART B — template=95 but installed+live still 85 (install.sh not run) ──"
write_template 95; write_installed 85; write_live 85
run_drift
[[ "$RC" -ne 0 ]] && ok "exit non-zero on drift" || bad "exit non-zero on drift (got $RC)"
has "$OUT" "DRIFT   installed plist: USAGE_THRESHOLD='85'" "DRIFT names stale installed plist value"
has "$OUT" "DRIFT   live daemon: USAGE_THRESHOLD='85'" "DRIFT names stale live daemon value"
has "$OUT" "re-run install.sh" "DRIFT line points at the fix"
nothas "$OUT" "mismatches=0" "does NOT report mismatches=0"

# ════════════════════════════════════════════════════════════════════════════
# PART C — install.sh ran (plist=95) but bootstrap didn't reload env (live=85)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART C — installed plist=95 but live daemon still 85 (stale bootstrap) ──"
write_template 95; write_installed 95; write_live 85
run_drift
[[ "$RC" -ne 0 ]] && ok "exit non-zero when only the live env is stale" || bad "exit non-zero (got $RC)"
has "$OUT" "DRIFT   live daemon: USAGE_THRESHOLD='85'" "DRIFT catches stale live env even when file is clean"
nothas "$OUT" "DRIFT   installed plist" "no false DRIFT on the (clean) installed plist"

# ════════════════════════════════════════════════════════════════════════════
# PART D — default-environment PATH must not false-positive
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo '── PART D — launchctl-print default-environment PATH ignored ──'
write_template 95; write_installed 95; write_live 95
run_drift
nothas "$OUT" "DRIFT   live daemon: PATH" "live PATH lookup ignores the bare default-environment PATH"
has "$OUT" "mismatches=0" "still in sync (PATH not a false drift)"

# ════════════════════════════════════════════════════════════════════════════
# PART E — not installed / not loaded ⇒ NOTE, not drift
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART E — not installed / not loaded ⇒ NOTE only ──"
write_template 95
rm -f "$WORK/installed.plist"   # not installed
: > "$LAUNCHCTL_OUT"            # not loaded (empty ⇒ fake launchctl exits 1)
run_drift
eq "$RC" "0" "exit 0 when neither installed nor loaded"
has "$OUT" "NOTE    daemon not installed" "NOTE for missing plist"
has "$OUT" "NOTE    daemon not loaded" "NOTE for unloaded daemon"
has "$OUT" "mismatches=0" "not-installed/not-loaded is not drift"

# ════════════════════════════════════════════════════════════════════════════
# PART F — install.sh reload sequence (acceptance #1, offline + production-safe)
#   Runs the REAL install.sh against a fake launchctl in a temp HOME and asserts
#   the bootout-before-bootstrap SEQUENCE (the mechanism that yields a new pid —
#   the literal new-pid check is the manual on-host acceptance step, which no
#   offline test can do without bouncing the live daemon), that it WAITS for the
#   async bootout teardown before re-bootstrapping (no bootout/bootstrap race),
#   and that on a not-loaded daemon it skips bootout. The fake models teardown:
#   `bootout` marks the service gone, so the settle-loop `print` sees it
#   disappear; `bootstrap` brings it back.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART F — install.sh boots out, waits for teardown, then bootstraps ──"
FAKEBIN2="$WORK/bin2"; mkdir -p "$FAKEBIN2"
LCTL_SEQ="$WORK/lctl.seq"
GONE="$WORK/lctl.gone"
cat > "$FAKEBIN2/launchctl" <<'EOF'
#!/bin/bash
# fake launchctl for install.sh: records the subcommand sequence and models the
# async teardown — bootout marks the service gone (so the settle-loop print sees
# it disappear), bootstrap brings it back. Loaded iff FAKE_LOADED=1.
printf '%s\n' "$1" >> "$LCTL_SEQ"
case "$1" in
  bootout)   : > "$LCTL_GONE"; exit 0 ;;
  bootstrap) rm -f "$LCTL_GONE"; exit 0 ;;
  print)
    [ "${FAKE_LOADED:-0}" = "1" ] || exit 1
    [ -f "$LCTL_GONE" ] && exit 1
    printf 'state = running\npid = 9999\nUSAGE_THRESHOLD => 95\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN2/launchctl"

run_install() { # $1 = FAKE_LOADED ; sets $IOUT, $IRC, rewrites $LCTL_SEQ
  : > "$LCTL_SEQ"; rm -f "$GONE"
  local ihome="$WORK/inst-home"; rm -rf "$ihome"; mkdir -p "$ihome"
  IOUT="$(PATH="$FAKEBIN2:$PATH" HOME="$ihome" LCTL_SEQ="$LCTL_SEQ" LCTL_GONE="$GONE" FAKE_LOADED="$1" \
          bash "$INSTALL_SH" 2>&1)"
  IRC=$?
}

# already-loaded ⇒ bootout precedes bootstrap (the new-pid mechanism)
run_install 1
eq "$IRC" "0" "install.sh exits 0 (already-loaded reload)"
has "$IOUT" "bootstrapping out before reload" "logs the bootout-before-reload step"
ilo="$(grep -n '^bootout$'   "$LCTL_SEQ" | head -1 | cut -d: -f1)"
ils="$(grep -n '^bootstrap$' "$LCTL_SEQ" | head -1 | cut -d: -f1)"
if [[ -n "$ilo" && -n "$ils" && "$ilo" -lt "$ils" ]]; then
  ok "bootout ($ilo) precedes bootstrap ($ils) on an already-loaded daemon"
else
  bad "bootout-before-bootstrap (out=$ilo strap=$ils); seq: $(tr '\n' ',' < "$LCTL_SEQ")"
fi
# the settle loop must poll (a `print`) between bootout and bootstrap
settle="$(grep -n '^print$' "$LCTL_SEQ" | awk -F: -v a="$ilo" -v b="$ils" '$1>a&&$1<b{print $1; exit}')"
[[ -n "$settle" ]] && ok "settle-loop print ($settle) waits for teardown before bootstrap" \
  || bad "settle-loop polled between bootout and bootstrap; seq: $(tr '\n' ',' < "$LCTL_SEQ")"
grep -q '^kickstart$' "$LCTL_SEQ" && ok "kickstart fired after bootstrap" || bad "kickstart fired"
[[ -f "$WORK/inst-home/Library/LaunchAgents/com.beads-runner.daemon.plist" ]] \
  && ok "rendered plist written to LaunchAgents" || bad "rendered plist written"
grep -q 'USAGE_THRESHOLD' "$WORK/inst-home/Library/LaunchAgents/com.beads-runner.daemon.plist" 2>/dev/null \
  && ok "rendered plist carries the template env (USAGE_THRESHOLD)" || bad "rendered plist carries env"

# not-loaded ⇒ no bootout, straight to bootstrap (first install)
run_install 0
eq "$IRC" "0" "install.sh exits 0 (fresh install)"
grep -q '^bootout$' "$LCTL_SEQ" && bad "no bootout when nothing is loaded" || ok "no bootout when nothing is loaded"
grep -q '^bootstrap$' "$LCTL_SEQ" && ok "bootstraps on a fresh install" || bad "bootstraps on a fresh install"

# ════════════════════════════════════════════════════════════════════════════
# PART G — a comment carrying a literal <string> tag must NOT false-DRIFT
#   The parser strips XML comments first, so a sample value inside a comment
#   between a <key> and its real <string> can't emit a spurious stale pair.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART G — <string> inside an EnvironmentVariables comment is ignored ──"
cat > "$WORK/template" <<EOF
<plist><dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>@@HOME@@</string>
    <!-- earlier default was <string>85</string> — must NOT be parsed -->
    <key>USAGE_THRESHOLD</key>
    <string>95</string>
  </dict>
</dict></plist>
EOF
write_installed 95   # PATH/HOME/USAGE_THRESHOLD=95 (superset is fine; expected keys all match)
write_live 95
run_drift
eq "$RC" "0" "exit 0 — comment <string> not mistaken for the real value"
has "$OUT" "mismatches=0" "no false drift from a <string> inside a comment"
nothas "$OUT" "USAGE_THRESHOLD='85'" "stale comment value never becomes the expected value"

# ════════════════════════════════════════════════════════════════════════════
# PART H — a template key absent from a LOADED daemon's env is DRIFT (not a NOTE)
#   Catches: install.sh wrote the new key to the plist (path A clean) but the
#   bootstrap didn't actually reload, so launchd never loaded it.
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "── PART H — new template key missing from loaded live env ⇒ DRIFT ──"
cat > "$WORK/template" <<EOF
<plist><dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>USAGE_THRESHOLD</key>
    <string>95</string>
    <key>NEW_KNOB</key>
    <string>on</string>
  </dict>
</dict></plist>
EOF
cat > "$WORK/installed.plist" <<EOF
<plist><dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>USAGE_THRESHOLD</key>
    <string>95</string>
    <key>NEW_KNOB</key>
    <string>on</string>
  </dict>
</dict></plist>
EOF
cat > "$LAUNCHCTL_OUT" <<EOF
com.beads-runner.daemon = {
	state = running
	environment = {
		USAGE_THRESHOLD => 95
	}
}
EOF
run_drift
[[ "$RC" -ne 0 ]] && ok "exit non-zero when a loaded daemon is missing a template key" || bad "exit non-zero (got $RC)"
has "$OUT" "DRIFT   live daemon: NEW_KNOB absent from loaded env" "absent key on a loaded daemon is DRIFT"
nothas "$OUT" "DRIFT   installed plist" "installed plist (which has the key) is not flagged"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " check-plist-drift acceptance: PASS=$PASS FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "✓ claude-tools-6s6x — plist-drift detector catches template-vs-applied env drift"
