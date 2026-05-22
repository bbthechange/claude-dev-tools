#!/bin/bash
# beads-runner/lib/node25-prime.sh — Node v25 PATH prime + LOUD wrong-Node
# crash detector, shared across the three `claude -p` spawn sites.
#
# WHY THIS FILE EXISTS
#   The same daemon-launched-PATH bug bit three siblings: specialist.sh
#   (claude-tools-3kd, commit a857038), run-beads-tasks.sh (claude-tools-4tj,
#   commit 9d6589b), and now runner.sh (claude-tools-18c). At three copies the
#   shared helper pays off: there is exactly one body of regex/version logic to
#   keep in sync as the claude CLI × Node-version envelope evolves.
#
# THE BUG (one paragraph, so future readers don't have to spelunk three commits):
#   A daemon-launched process inherits a stripped PATH that resolves `claude` to
#   a system install running under /usr/local/bin/node (or /opt/homebrew/bin/
#   node) — currently v25.2.1. Node v25 is incompatible with the claude CLI: it
#   crashes at startup with `TypeError: Cannot read properties of undefined
#   (reading 'prototype')` from cli.js. The crash output (Node stack trace +
#   "Node.js v25.x.y" banner) lands in the merged stdout/stderr stream file as
#   if it were the agent's reply, exit is nonzero, and the caller's failure
#   path silently kicks in — degrading every spawn into a hot retry loop or a
#   jq fallback with no visible signal that Node 25 is the cause.
#
# THE FIX (two parts, both required):
#   1. node25_prime_path — pre-spawn: if `node --version` is v25+, prepend the
#      nvm default-alias bin to PATH so the spawned claude binds to nvm's
#      node (currently v23.11.1). Non-invasive when current node is already
#      < v25 (interactive session, test fixture, OS without nvm).
#   2. node25_check_wrong_node_crash — post-spawn backstop: if claude exits
#      nonzero AND the stream carries the TypeError + Node v25+ banner, the
#      caller emits its scoped LOUD output (stderr block + sticky log line +
#      structured event/incident). Even after the prime, an unforeseen launch
#      environment could reintroduce the wrong-Node case — this detector is
#      the backstop that ensures it is heard immediately, not weeks later.

# ── node25_prime_path [skip_flag] ─────────────────────────────────────────────
# Caller passes its scoped skip env var value as $1 so each caller's test rig
# can force-skip the prime under its own name (SPECIALIST_SKIP_NVM_PRIME=1,
# RUNNER_SKIP_NVM_PRIME=1, etc.) without leaking a single shared knob between
# unrelated test surfaces.
node25_prime_path() {
  [[ "${1:-0}" == "1" ]] && return 0
  local node_major
  node_major="$(node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')"
  [[ -n "$node_major" && "$node_major" -ge 25 ]] || return 0

  local nvm_dir_resolved="${NVM_DIR:-$HOME/.nvm}"
  [[ -d "$nvm_dir_resolved/versions/node" ]] || return 0

  local _ver=""
  local _alias_file="$nvm_dir_resolved/alias/default"
  if [[ -f "$_alias_file" ]]; then
    _ver="$(head -1 "$_alias_file" 2>/dev/null)"
    # Follow alias chain (e.g. default -> lts/iron -> 23.11.1) — bounded hops.
    local _i
    for _i in 1 2 3 4 5; do
      [[ -n "$_ver" && -f "$nvm_dir_resolved/alias/$_ver" ]] || break
      _ver="$(head -1 "$nvm_dir_resolved/alias/$_ver" 2>/dev/null)"
    done
  fi
  _ver="${_ver#v}"
  # If alias resolution didn't yield an X.Y.Z literal, pick the highest
  # installed version that is NOT itself in the wrong-node range (v25+).
  if [[ ! "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    _ver="$(ls -1 "$nvm_dir_resolved/versions/node" 2>/dev/null \
              | sed 's/^v//' \
              | awk -F. '$1 < 25' \
              | sort -V | tail -1)"
  fi
  if [[ -n "$_ver" && -d "$nvm_dir_resolved/versions/node/v$_ver/bin" ]]; then
    PATH="$nvm_dir_resolved/versions/node/v$_ver/bin:$PATH"
    export PATH
  fi
}

# ── node25_check_wrong_node_crash <stream_file> ───────────────────────────────
# Bounded prefix+suffix scan of the merged stdout/stderr stream a `claude -p`
# spawn produced. If both signatures are present (TypeError on cli.js plus a
# "Node.js v25+" banner in the tail), echoes the detected Node version (e.g.
# "Node.js v25.2.1") on stdout and returns 0. Otherwise echoes nothing and
# returns 1. The caller is responsible for the scoped LOUD output — each caller
# attributes the crash differently (specialist.sh names a $KIND in its summary
# log; the runners attribute it to a $TASK_ID and append to INCIDENTS) and the
# fix-hint text is caller-specific, so this helper deliberately does NOT print
# anything to stderr or write any log file itself.
#
# We do NOT mutate the caller's exit code: the caller's existing rc!=0 path
# must still run (so any downstream fallback still fires); the LOUD output is
# additive surface so the crash leaves visible fingerprints instead of silently
# degrading into UNKNOWN_FAILURE-and-retry.
node25_check_wrong_node_crash() {
  local stream_file="$1"
  [[ -n "$stream_file" && -s "$stream_file" ]] || return 1
  local _head_blob _tail_blob
  _head_blob="$(head -c 16384 "$stream_file" 2>/dev/null)"
  _tail_blob="$(tail -c 4096  "$stream_file" 2>/dev/null)"
  printf '%s%s' "$_head_blob" "$_tail_blob" \
    | grep -qE "TypeError: Cannot read properties of undefined \(reading 'prototype'\)" 2>/dev/null \
    || return 1
  printf '%s' "$_tail_blob" \
    | grep -qE "Node\.js v(2[5-9]|[3-9][0-9])\." 2>/dev/null \
    || return 1
  local _node_seen
  _node_seen="$(printf '%s' "$_tail_blob" | grep -oE "Node\.js v[0-9.]+" | tail -1)"
  printf '%s' "${_node_seen:-unknown}"
  return 0
}
