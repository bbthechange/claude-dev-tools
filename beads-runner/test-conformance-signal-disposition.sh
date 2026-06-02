#!/bin/bash
# test-conformance-signal-disposition.sh — top-tier regression lock for
# claude-tools-54ei.
#
# WHAT IT PINS: the conformance harness (conformance/lib/harness.sh:_spawn_runner)
# must launch the runner-under-test with a TRAPPABLE INT/HUP/QUIT disposition even
# when the GATE itself was launched with those signals already SIG_IGN.
#
# WHY IT EXISTS (the silent-when-wrong scar): POSIX says a signal that is SIG_IGN
# on entry to a shell CANNOT be trapped or reset from within bash — so the runner's
# `trap cleanup INT TERM` (v1) / `trap _on_signal INT TERM HUP` (v2) becomes a SILENT
# no-op and the runner ignores `kill -INT/-HUP` entirely. A worker-driven gate runs
# inside a detached runner (launch-detached.sh: `nohup … &` ⇒ HUP ignored; an async
# list ⇒ INT/QUIT ignored), and that disposition is INHERITED all the way down to
# the runner-under-test. That made BC-35 RED in the gate (INT v1+v2, HUP v2) while
# GREEN from a clean interactive shell — a launch artifact, not the scenario BC-35
# models. `_spawn_runner` now resets the disposition to SIG_DFL via an external exec
# helper (perl/python3) before exec'ing the runner. This test reproduces the gate's
# SIG_IGN context and asserts the reset holds — so a future refactor that drops it
# turns RED here deterministically, instead of bc-35 silently passing standalone and
# failing only inside the real gate.
#
# Counts as ONE top-tier unit (pass == exit 0). Auto-enrolled by glob (testing.md).

set -u

# Re-exec ourselves with INT/HUP/QUIT IGNORED to faithfully reproduce the
# worker/gate context (an async-launched / nohup'd ancestor). `exec` preserves the
# ignore across the bash that follows — exactly how the real gate inherits it.
if [[ "${_SIGDISPO_REEXEC:-}" != 1 ]]; then
  export _SIGDISPO_REEXEC=1
  trap '' INT HUP QUIT
  exec bash "$0" "$@"
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If no external reset helper exists, the fix cannot apply (the harness degrades to
# a plain `exec bash`, correct only when signals are at default). On such a box the
# real gate's bc-35 would also be unfixable — that is an environment limitation, not
# a regression, so SKIP cleanly rather than emit a false red.
if ! command -v perl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: no perl/python3 — signal-disposition reset helper unavailable (not a regression)"
  exit 0
fi

# shellcheck source=/dev/null
source "$DIR/conformance/lib/harness.sh"

PASS=0; FAIL=0
ck() { local m="$1"; shift; if "$@"; then echo "  ok  : $m"; PASS=$((PASS+1)); else echo "  FAIL: $m"; FAIL=$((FAIL+1)); fi; }

# Precondition: prove we really are in the ignored-INT context, else the test is
# vacuous. Attempt to install an INT trap; if it does NOT register, INT was SIG_IGN
# on entry (the gate context we want).
trap 'true' INT; _probe="$(trap -p INT)"; trap - INT
if [[ -n "$_probe" ]]; then
  echo "SKIP: INT is trappable in this context (not the SIG_IGN gate scenario) — test vacuous here"
  exit 0
fi

H_init_test "sigdispo-54ei"

# A trivial stand-in runner: trap INT → exit 1 (the BC-35 contract shape), announce
# READY, then block on a hung child (mirrors BC-35's in-flight worker). If the
# harness launches it with INT still ignored, the trap is a no-op and it never prints
# STUB_TRAPPED_INT — it would only die to SIGKILL.
STUB="$WORKDIR/stub-runner.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
trap 'echo STUB_TRAPPED_INT; exit 1' INT
echo STUB_READY
sleep 10 &
wait "$!"
echo STUB_FELL_THROUGH
EOF
chmod +x "$STUB"
RUNNER="$STUB"

run_runner_bg
for _ in $(seq 1 60); do grep -q STUB_READY "$HARNESS_OUT/runner.out" 2>/dev/null && break; sleep 0.25; done
ck "stub runner started (READY)"                 grep -q STUB_READY "$HARNESS_OUT/runner.out"

kill -INT "$RUNNER_PID" 2>/dev/null
wait_runner_exit 10

ck "INT trap FIRED in the runner-under-test (SIG_DFL reset worked)" grep -q STUB_TRAPPED_INT "$HARNESS_OUT/runner.out"
ck "runner-under-test exited 1 on INT (BC-21 §8.1 row 1)"           test "${RUN_EXIT:-x}" -eq 1
ck "runner did NOT fall through (INT was honored, not ignored)"     bash -c '! grep -q STUB_FELL_THROUGH "'"$HARNESS_OUT"'/runner.out"'

H_cleanup

echo "── test-conformance-signal-disposition: pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
