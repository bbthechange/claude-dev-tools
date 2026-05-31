#!/bin/bash
# beads-runner/lib/git-pin-main.sh — pin the runner's working tree back to the
# trunk branch (default `main`) at the top of every task loop, shared between
# the v1 runner (run-beads-tasks.sh) and the v2 runner (runner.sh).
#
# WHY THIS FILE EXISTS (claude-tools-trunkpin)
#   The runner NEVER creates branches — it does a per-bead auto-commit onto
#   whatever branch HEAD points at. So when a worker manually `git checkout -b`s
#   a feature branch mid-task and never returns the tree to main (observed
#   2026-05-31: the tree sat on n3-uxg6-ready-to-pair, and earlier on
#   n2-uxg1-push-delivery), EVERY subsequent bead piles its auto-commit onto
#   that feature branch until a human notices and merges+switches by hand.
#   Worker discipline is exactly the wrong place to enforce this — it already
#   failed. So we enforce it IN THE LOOP — the same "enforce in the loop, not by
#   worker discipline" lesson as the gate/close hooks: at the top of each
#   iteration, before the next bead is claimed, pin HEAD back to trunk so a
#   wandered-off tree self-heals within ONE iteration instead of bleeding
#   indefinitely.
#
# THE GUARD (why this is safe to run every iteration)
#   We switch ONLY when ALL of these hold, else we no-op — and the common
#   already-on-trunk case is a SILENT no-op so the loop logs stay quiet:
#     1. cwd is inside a git work tree                     (else: not our repo)
#     2. the trunk branch exists as a local ref            (else: a fresh/CI repo
#        — e.g. the conformance harness's bare `git init` with no commit and no
#        `main` ref — there is nothing to pin to)
#     3. HEAD is NOT already on trunk                      (on-trunk ⇒ silent)
#     4. the work tree is CLEAN (`git status --porcelain` empty)
#   If HEAD is off-trunk/detached but the tree is DIRTY we do NOT switch (a
#   `git checkout` could fail or strand uncommitted work) — instead we emit a
#   LOUD warning every iteration so the degraded state is heard, not silent, and
#   we self-heal automatically on the first iteration the worker leaves clean.
#
#   NOTE: switching does NOT recover commits already stranded on the feature
#   branch — those stay on that ref for a human to merge (exactly as in the
#   trunkpin manual recovery: "merged n3 into main, pushed, deleted n3").
#   Pinning STOPS THE BLEED (future beads land on trunk); it is deliberately
#   NOT an auto-merge — merge conflicts are not the loop's call to make.

# ── pin_head_to_main [skip_flag] [trunk_branch] ──────────────────────────────
# $1 = caller-scoped skip flag VALUE. Callers pass "${RUNNER_SKIP_PIN_MAIN:-0}"
#      so each test rig can force-skip the self-heal under its own name without
#      leaking one shared knob between surfaces (mirrors node25_prime_path).
# $2 = trunk branch override; defaults to $RUNNER_MAIN_BRANCH, then `main`.
# ALWAYS returns 0 — this is a best-effort self-heal that must NEVER abort the
# caller's loop (v1 runs under `set -euo pipefail`, v2 under `set -uo pipefail`).
pin_head_to_main() {
  [[ "${1:-0}" == "1" ]] && return 0
  local trunk="${2:-${RUNNER_MAIN_BRANCH:-main}}"

  # (1) inside a git work tree at all?
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  # (2) does the trunk ref exist locally? A fresh `git init` with no commits, a
  #     detached CI checkout, or a worktree lacking the branch all land here —
  #     nothing to pin to, so stay silent.
  if ! git show-ref --verify --quiet "refs/heads/$trunk"; then
    return 0
  fi
  # (3) current branch, or the literal "HEAD" when detached.
  local cur
  cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "HEAD")"
  if [[ "$cur" == "$trunk" ]]; then
    return 0                                    # already pinned — silent no-op
  fi

  # (4) off-trunk/detached: only self-heal when the work tree is fully clean.
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "runner: WARNING HEAD is on '${cur}' (not '${trunk}') AND the work tree is DIRTY —" \
         "NOT switching (a checkout could fail or strand uncommitted work). New per-bead" \
         "commits will land on '${cur}', not '${trunk}', until the tree is clean (claude-tools-trunkpin)." >&2
    return 0
  fi

  if git checkout "$trunk" >/dev/null 2>&1; then
    echo "runner: pinned HEAD back to '${trunk}' (was on '${cur}', tree clean) — self-heal of a" \
         "wandered-off working tree (claude-tools-trunkpin). NOTE: any commits made on '${cur}'" \
         "remain on that branch for a human to merge." >&2
  else
    echo "runner: WARNING wanted to pin HEAD from '${cur}' back to '${trunk}' but" \
         "'git checkout ${trunk}' failed — leaving HEAD on '${cur}' (claude-tools-trunkpin)." >&2
  fi
  return 0
}
