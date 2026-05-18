# shellcheck shell=bash
# beads-runner/lib/stuck-routing.sh — T5.5 STUCK_NEEDS_HUMAN DO ROUTING:
#                                     §7.4 dossier-level double-trigger dedup +
#                                     §7.3 backstop-drives-the-bead +
#                                     S-2/AD3.1 control→work reconcile
#                                     (claude-tools-j7f; epic claude-tools-glk).
# ════════════════════════════════════════════════════════════════════════════
# OWNS (INTERFACE.md v1 — bound to section numbers, never re-stated locally):
#
#   • §7.4 DOSSIER-level double-trigger dedup LOGIC. The worker-self-signal
#     (§7.2 primary) AND the runner backstop (§7.2 backstop) on the SAME fork
#     collapse to ONE Dossier via the §0.4 two-layer key model's *dossier*
#     layer: key = `task_ref` (distinct from the T5.3 per-Item key = Item
#     `id`). The single-writer create-once STRUCTURE is T5.1's
#     `do_dedup_record`; THIS file is the LOGIC: it derives the deterministic
#     dossier id from `task_ref` so both triggers compute the SAME id, binds
#     it once, and generates the Dossier ONLY on the first trigger ⇒ "two
#     triggers never make two dossiers" (AD3.4 / preserved AD3.1 SCAR-intent).
#
#   • §7.3 backstop-drives-the-bead. A fired backstop (the worker slipped
#     past the §7.6 guardrail) MUST ITSELF drive the bead to
#     blocked-for-human (status=blocked + `bd human`) — otherwise the fork
#     rots (UX principle 7). `sr_scan_backstop` recognises the §7.2-defined
#     fire conditions SOLELY to discharge this §7.3 drive mandate + the §7.4
#     dedup + S-2 reconcile (the cross-tier OUTCOME the rig bundles as
#     "§7.2 two triggers + §7.3 backstop-drives-bead"). It does NOT classify
#     (classify_failure / the §7.1 precedence chain is byte-untouched — T2/
#     T1a), advances NO §7.5 breaker/retry counter, and DELIBERATELY does
#     NOT handle the worker-driven primary (`WORKER_STUCK_EXIT`) path — that
#     is the §7.1 classification slot, owned by T2.
#
#   • S-2 / AD3.1 control→work reconcile. The COORDINATOR owns
#     "blocked-for-human": `sr__raise_bfh` writes a control-plane
#     blocked-for-human record (the SOURCE OF TRUTH), and
#     `sr_reconcile_blocked_for_human` asserts that truth back into beads
#     (control→work) DRIVEN BY THE CONTROL-PLANE RECORD, never by the bead's
#     possibly-stale Dolt status. The worker does NOT write Dolt as the
#     source of truth, so Dolt lag is invisible to the human-latency path —
#     the Board never lies (the §1 promise; S-2).
#
#   • Routes the §7.2-produced worker structured ask into the T5.2 generator
#     (`dg_from_worker_ask` → a `worker_stuck` decision dossier, typically
#     one `pick-option` Item). Generation is best-effort relative to the §7.3
#     drive: the bead-not-rotting guarantee never depends on generation.
#
# MUST NOT TOUCH (sibling surfaces — drift is a BLOCKING escalation, §11):
#   • §7.1 classification precedence + §7.2 worker prompt + §7.5 breaker/
#     retry exemption + §7.6 guardrail — T2/T1a. This file CONSUMES the
#     terminal-reason / structured-ask; it never owns or alters classification
#     and never advances a breaker/retry counter.
#   • §4.1 envelope / per-Item state machine / the two idempotency-latch
#     PRIMITIVES — T5.1 (consumed: `do_dedup_record`/`do_dedup_get`,
#     `do_dossier_get`, `do_item_set_state`).
#   • §5 generation internals — T5.2 (routed-to: `dg_from_worker_ask`).
#   • §5.3 per-Item apply + §7.4 per-Item latch — T5.3.
#   • §2.2 timer — T5.4. §4.3 Notification — T5.6.
#   • T4 store / §9.1 chokepoint internals — consumed via the §2.1/§2.3
#     surface only (`co_store_dir`, `co_authenticate`); the blocked-for-human
#     namespace is a T5-owned sibling namespace under the SAME store, exactly
#     mirroring the T5.1 `dossier-dedup` / §10.3 `forensic` precedent — it is
#     NOT a §4 record type (adding one is a §0/§11 escalation).
#
# ANTI-DRIFT: binds INTERFACE.md v1 §7.3 / §7.4 (dossier-level) / §0.4 / §0.2.
# An interface gap is a BLOCKING escalation (reopen claude-tools-65z, amend +
# bump, re-freeze) — never a local divergence.
set -u

# ── consumer binding: T5.2 generator → T5.1 substrate → T4 store ─────────────
# Bind ONLY to the public surface; never reach past it into a sibling's
# internals (the same discipline dossier-gen.sh / consequence.sh set).
sr__lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }
if ! declare -F dg_from_worker_ask >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(sr__lib_dir)/dossier-gen.sh"          # → dossier.sh → coordinator.sh
fi

# ── §0.4 the dossier-level dedup KEY model ───────────────────────────────────
# §0.4: the dossier-level double-trigger dedup key = `task_ref` (the per-Item
# key is the Item `id`, T5.3 — a DISTINCT latch on a DISTINCT child). The
# deterministic dossier id is a pure function of `task_ref`, so the worker
# self-signal and the runner backstop on the SAME fork compute the SAME id and
# `do_dedup_record`'s create-once/idempotent-same-id contract collapses them to
# ONE Dossier. The id MUST satisfy the T5.1/T4 `do__safe_key`/`co__safe_key`
# predicate ([A-Za-z0-9._-], no '..'); `task_ref` already does, the `stuck-`
# prefix keeps it so and namespaces it away from any worker-chosen id.
sr_dossier_id_for() {
  local tref="${1:-}"
  [[ -n "$tref" ]] || return 1
  do__safe_key "$tref" || return 1
  printf 'stuck-%s' "$tref"
}

# ── the COORDINATOR-owned blocked-for-human namespace (S-2 source of truth) ──
# A T5-owned sibling namespace under the SAME store the §4 records use (one
# store, no plane split), EXACTLY mirroring T5.1's `dossier-dedup` and the
# §10.3 `forensic` precedent. It is NOT a §4 record type (absent from the T4
# co__schema_version registry — adding one is a §0/§11 escalation, MUST-NOT).
sr__bfh_dir() {
  local d; d="$(co_store_dir 2>/dev/null)" || d="${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"
  printf '%s/blocked-for-human' "$d"
}

# sr_bfh_get <task_ref> — echo the blocked-for-human record JSON (so the S-2
# reconcile / a Board projection can CONSULT the control-plane truth), or
# return 1 if no record exists. Read-only; no bearer (a structure consult, not
# a §4 read — mirrors T5.1 `do_dedup_get`).
sr_bfh_get() {
  local tref="${1:-}" path
  do__safe_key "$tref" 2>/dev/null || return 1
  path="$(sr__bfh_dir)/$tref.json"
  [[ -f "$path" ]] || return 1
  cat "$path" 2>/dev/null || return 1
}

# sr__raise_bfh <bearer> <task_ref> <dossier_id> <trigger>
#   Single-writer CREATE-ONCE control-plane blocked-for-human record — the
#   S-2 SOURCE OF TRUTH the reconcile drives from. First writer for task_ref
#   creates {resolved:false}; a re-raise (same task_ref, EITHER trigger) is
#   IDEMPOTENT (the existing record stands — one fork ⇒ one blocked-for-human,
#   the §7.4 dossier-layer property at the control plane). Authenticates
#   through the ONE §9.1 chokepoint `co_authenticate` (NO second auth path)
#   and stamps the RESOLVED principal (never a literal here — C7).
sr__raise_bfh() {
  local bearer="${1:-}" tref="${2:-}" did="${3:-}" trig="${4:-}" principal dir lock path now rc=0
  principal="$(co_authenticate "$bearer" 2>/dev/null)" || principal=""
  [[ -n "$principal" ]] || { echo "stuck-routing: bfh 401 — bearer missing/invalid; rejected (NO write; §9.1/§2.3)" >&2; return 1; }
  [[ -n "$tref" && -n "$did" ]] || { echo "stuck-routing: bfh — need <task_ref> <dossier_id> (§7.3/S-2)" >&2; return 2; }
  do__safe_key "$tref" || { echo "stuck-routing: bfh — unsafe task_ref key '$tref'" >&2; return 2; }
  dir="$(sr__bfh_dir)"; mkdir -p "$dir" 2>/dev/null || true
  path="$dir/$tref.json"; lock="$dir/.raise.$tref"
  local i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [[ $i -ge 200 ]] && break
    sleep 0.01 2>/dev/null || true
  done
  if [[ -f "$path" ]]; then
    rc=0                                  # idempotent: one fork ⇒ one bfh
  else
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    local tmp="$path.$$.tmp"
    if jq -cn --arg tr "$tref" --arg d "$did" --arg p "$principal" \
         --arg tg "$trig" --arg at "$now" \
         '{task_ref:$tr,dossier_id:$d,principal:$p,trigger:$tg,
           raised_at:$at,resolved:false,resolved_at:null}' > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$path" 2>/dev/null; then
      rc=0
    else
      rm -f "$tmp" 2>/dev/null; echo "stuck-routing: bfh — write failed for '$tref'" >&2; rc=4
    fi
  fi
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# sr__resolve_bfh <task_ref>  (internal; the human-approval transition)
#   Flip an existing blocked-for-human record resolved:false→true under the
#   per-task-ref lock (single-writer). This is the control-plane decision —
#   the NEXT reconcile lifts the work-plane block (S-2 control→work). Absent
#   record / already-resolved ⇒ idempotent success.
sr__resolve_bfh() {
  local tref="${1:-}" dir lock path now upd rc=0
  do__safe_key "$tref" 2>/dev/null || return 1
  dir="$(sr__bfh_dir)"; path="$dir/$tref.json"
  [[ -f "$path" ]] || return 0           # nothing to resolve ⇒ idempotent
  lock="$dir/.raise.$tref"
  local i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [[ $i -ge 200 ]] && break
    sleep 0.01 2>/dev/null || true
  done
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  upd=$(jq -c --arg at "$now" '.resolved=true | .resolved_at=$at' "$path" 2>/dev/null) || upd=""
  if [[ -n "$upd" ]]; then printf '%s' "$upd" > "$path" 2>/dev/null || rc=4; else rc=4; fi
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# sr_drive_bead_blocked <task_ref>  (§7.3)
#   The work-plane PROJECTION of the control-plane truth: drive the bead to
#   blocked-for-human (status=blocked + `bd human`) for IMMEDIATE honesty so
#   the fork does not rot before the next reconcile. Best-effort and idempotent
#   (`bd` is fail-open under the runner's guards) — the control-plane bfh
#   record raised by `sr__raise_bfh` remains the SOURCE OF TRUTH (S-2): a lost
#   or lagged work-plane write is re-asserted by the reconcile, never trusted.
sr_drive_bead_blocked() {
  local tref="${1:-}"
  [[ -n "$tref" ]] || return 1
  command -v bd >/dev/null 2>&1 || return 0
  bd update "$tref" --status=blocked >/dev/null 2>&1 || true
  bd human "$tref"                   >/dev/null 2>&1 || true
  return 0
}

# ── §7.2 backstop FIRE recognition (for the §7.3 drive mandate ONLY) ─────────
# sr_scan_backstop <stream_file>
#   Recognises the two §7.2-defined runner-side backstop fire conditions in
#   the final claude stream — the zero-model-trust signal that the worker
#   slipped past the §7.6 guardrail:
#     • a `result.permission_denials[]` entry for AskUserQuestion / ExitPlanMode
#     • a `tool_result` whose content carries the "Entered plan mode."
#       silent-no-op residual (the EnterPlanMode gap the research flags)
#   Echoes a short fired-trigger token + returns 0 on a fire; nonzero + no
#   output otherwise. This is recognition SOLELY to discharge §7.3 ("a fired
#   backstop MUST itself drive the bead") — it is NOT the §7.1 classifier
#   (classify_failure is byte-untouched) and is intentionally precise so it
#   matches ONLY a genuine backstop fire (no false-positive on benign
#   tool_result errors / normal results).
sr_scan_backstop() {
  local sf="${1:-}"
  [[ -n "$sf" && -f "$sf" ]] || return 1
  # permission_denials[] on the result line (zero model trust).
  if jq -e -s 'any(.[]?; (.type=="result")
                  and (.permission_denials != null)
                  and (any(.permission_denials[]?;
                       (.tool=="AskUserQuestion") or (.tool=="ExitPlanMode")
                       or (.tool_name=="AskUserQuestion") or (.tool_name=="ExitPlanMode"))))' \
       "$sf" >/dev/null 2>&1; then
    echo "permission_denials"; return 0
  fi
  # "Entered plan mode." tool_result residual (EnterPlanMode silent no-op).
  if jq -e -s 'any(.[]?; (.type=="tool_result")
                  and ((.content // "") | tostring | test("Entered plan mode\\.")))' \
       "$sf" >/dev/null 2>&1; then
    echo "entered_plan_mode"; return 0
  fi
  return 1
}

# ── the §7.2 worker structured-ask, consumed as raw material ─────────────────
# sr_worker_ask <task_ref> [result_text]
#   The §7.2 primary path has the worker write the structured ask
#   (TL;DR · ask · options · recommendation+why · reversible) into the bead
#   (`--design`/`--append-notes`) before it exits. A fired BACKSTOP means the
#   worker slipped WITHOUT writing one — so a minimal, contract-valid ask is
#   synthesised here as raw material for T5.2 (the dossier builder owns the
#   §5 authoring; this only supplies the §7.2 raw shape, never §5 content).
#   Echoes a structured-ask JSON object dg_from_worker_ask accepts.
sr_worker_ask() {
  local tref="${1:-}" rtext="${2:-}"
  local cb tldr
  tldr="A backstop fired on $tref: the worker reached an interactive fork it must not resolve and slipped past the §7.6 guardrail."
  [[ -n "$rtext" ]] && tldr="$tldr Worker said: $rtext"
  # One contract-valid pick-option so T5.2 can author a worker_stuck dossier
  # (§5.2 pick-option needs ≥1 option with a machine-applyable §5.3 block +
  # recommendation{value,why}). The choice itself is the human's; the runner
  # only frames "resume vs abandon", each pre-declaring its §5.3 consequence.
  # No hardcoded cb_schema_version: this is §7.2 RAW material, not authored §5.
  # The dossier builder (dg_from_worker_ask) stamps the bound version via its
  # `cb_schema_version //= sv` — pinning a literal here would break under the
  # §0/§11 single-source bump (v2: pinning 1 would be rejected vs bound 2).
  cb='{"creates":[],"unblocks":[],"labels":[],"status_changes":[]}'
  jq -cn --arg tref "$tref" --arg tldr "$tldr" --argjson cb "$cb" '
    { tldr:$tldr,
      ask:("How should the runner proceed on " + $tref + " (a human-decision fork)?"),
      options:[
        { option_id:"resume", label:"I have unblocked it — resume the task",
          blast_radius:"Re-queues the task as-is once a human resolves the fork.",
          consequence_block:$cb },
        { option_id:"abandon", label:"Abandon / re-scope this task",
          blast_radius:"Leaves the bead blocked-for-human pending a human re-scope.",
          consequence_block:$cb }
      ],
      recommendation:{ value:"resume",
        why:"The fork is a human decision, not a task failure; resume once decided (§7.5 retry-exempt)." },
      reversible:"Fully reversible — no consequence is applied until a human picks an option (§5.3 = T5.3)." }'
}

# ════════════════════════════════════════════════════════════════════════════
# §7.4 + §7.3 + route — THE single STUCK routing entry
# ════════════════════════════════════════════════════════════════════════════
# sr_route_stuck <bearer> <task_ref> <trigger> [structured_ask_json]
#   The one-fork-one-dossier LOGIC. `trigger` is free-form provenance
#   (`worker_stuck` for the §7.2 primary the runner CONSUMES as a
#   terminal-reason; `backstop:<which>` for a fired backstop). Steps:
#     1. Derive the deterministic dossier id from `task_ref` (§0.4) — both
#        triggers on the SAME fork compute the SAME id.
#     2. `do_dedup_record` (T5.1 STRUCTURE) binds task_ref→id create-once;
#        a re-bind with the SAME id is idempotent success ⇒ the §7.4
#        dossier-layer "two triggers never make two dossiers".
#     3. Raise the COORDINATOR-owned blocked-for-human record (S-2 source of
#        truth) and drive the bead (§7.3) — these are the bead-not-rotting
#        guarantees and run BEFORE generation so they never depend on it.
#     4. Generate the Dossier ONLY if one does not already exist for this id
#        (`dg_from_worker_ask`, T5.2). The second trigger finds it present and
#        SKIPS generation — one fork ⇒ ONE Dossier.
#   Echoes the dossier id. Returns 0 once the bead is driven + bfh raised
#   (the §7.3/S-2 OUTCOME), even if best-effort generation later failed —
#   the fork must never rot on a generation hiccup.
sr_route_stuck() {
  local bearer="${1:-}" tref="${2:-}" trig="${3:-worker_stuck}" ask="${4:-}"
  local did rc
  [[ -n "$bearer" && -n "$tref" ]] || { echo "stuck-routing: route — need <bearer> <task_ref>" >&2; return 2; }
  did="$(sr_dossier_id_for "$tref")" || { echo "stuck-routing: route — unsafe task_ref '$tref' (§0.4)" >&2; return 2; }

  # §7.4 dossier-layer: single-writer create-once bind (T5.1 STRUCTURE). The
  # deterministic id makes a same-fork re-trigger an idempotent success; a
  # DIFFERENT id for the same task_ref would be REJECTED by the structure
  # (cannot happen here — id is a pure function of task_ref).
  do_dedup_record "$bearer" "$tref" "$did" >/dev/null 2>&1 || {
    # The only nonzero with our deterministic id is auth/store failure; the
    # §7.3 fork-must-not-rot guarantee still proceeds via the bead drive.
    echo "stuck-routing: route — dedup bind unavailable for '$tref'; proceeding with §7.3 drive (fork must not rot)" >&2
  }

  # §7.3 / S-2 — raise the control-plane truth, then project it to the bead.
  sr__raise_bfh "$bearer" "$tref" "$did" "$trig" || true
  sr_drive_bead_blocked "$tref"

  # Route the §7.2 ask into T5.2 — ONLY on the first trigger (one Dossier).
  if ! do_dossier_get "$bearer" "$did" >/dev/null 2>&1; then
    [[ -n "$ask" ]] || ask="$(sr_worker_ask "$tref")"
    if ! dg_from_worker_ask "$bearer" "$did" "$tref" "$ask" >/dev/null 2>&1; then
      echo "stuck-routing: route — T5.2 generation deferred for '$tref' (best-effort; §7.3 drive already done)" >&2
    fi
  fi

  printf '%s' "$did"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# S-2 / AD3.1 — control→work reconcile (the Board never lies under Dolt lag)
# ════════════════════════════════════════════════════════════════════════════
# sr_reconcile_blocked_for_human <bearer> [task_ref]
#   The COORDINATOR reconciles its blocked-for-human records back into beads.
#   It is DRIVEN BY THE CONTROL-PLANE RECORD, never by the bead's Dolt status
#   (which may lag or have been clobbered) — so Dolt lag is INVISIBLE to the
#   human-latency path:
#     • record resolved:false  ⇒ (re-)assert the work-plane block
#       (status=blocked + `bd human`) unconditionally and idempotently —
#       a lagged/clobbered bead is corrected here (the Board never lies, S-2).
#     • record resolved:true   ⇒ the human decided: LIFT the work-plane block
#       (status=open so the task re-enters the ready set; the per-Item §5.3
#       consequence application is T5.3's, orthogonal) and hard-delete the
#       record (the fork is closed). Idempotent: a missing record / already
#       lifted is a no-op.
#   With no <task_ref> it sweeps every record. Echoes the count of records
#   acted on; always returns 0 (a reconcile never aborts the runner).
sr_reconcile_blocked_for_human() {
  local bearer="${1:-}" only="${2:-}" dir n=0 f tref resolved did
  command -v bd >/dev/null 2>&1 || { echo 0; return 0; }
  dir="$(sr__bfh_dir)"
  [[ -d "$dir" ]] || { echo 0; return 0; }
  local files=()
  if [[ -n "$only" ]]; then
    do__safe_key "$only" 2>/dev/null || { echo 0; return 0; }
    [[ -f "$dir/$only.json" ]] && files=("$dir/$only.json")
  else
    for f in "$dir"/*.json; do [[ -e "$f" ]] && files+=("$f"); done
  fi
  for f in "${files[@]:-}"; do
    [[ -e "$f" ]] || continue
    tref=$(jq -r '.task_ref // ""' "$f" 2>/dev/null) || tref=""
    [[ -n "$tref" ]] || continue
    resolved=$(jq -r '.resolved // false' "$f" 2>/dev/null) || resolved="false"
    if [[ "$resolved" == "true" ]]; then
      # Human decided ⇒ lift the block (control→work). Driven by the record,
      # NOT by reading bead status — Dolt lag cannot make this lie.
      bd update "$tref" --status=open >/dev/null 2>&1 || true
      rm -f "$f" 2>/dev/null || true
    else
      # Still blocked-for-human ⇒ re-assert the work-plane truth idempotently.
      bd update "$tref" --status=blocked >/dev/null 2>&1 || true
      bd human "$tref"                   >/dev/null 2>&1 || true
    fi
    n=$((n+1))
  done
  echo "$n"
  return 0
}

# sr_human_resolve <bearer> <task_ref> [dossier_id] [item_id] [response_json]
#   The human-approval entry. Records the decision on the control plane
#   (`sr__resolve_bfh`) so the next `sr_reconcile_blocked_for_human` lifts the
#   work-plane block (S-2). If an item is named, the per-Item state is moved
#   open→answered via the T5.1 substrate (`do_item_set_state`) so the T5.3
#   applier (a sibling, orthogonal) can later apply the chosen §5.3 block —
#   this file NEVER applies a consequence or flips the per-Item latch (T5.3).
#   Idempotent. Returns 0 on a recorded decision.
sr_human_resolve() {
  local bearer="${1:-}" tref="${2:-}" did="${3:-}" iid="${4:-}" resp="${5:-}"
  [[ -n "$bearer" && -n "$tref" ]] || { echo "stuck-routing: resolve — need <bearer> <task_ref>" >&2; return 2; }
  if [[ -n "$did" && -n "$iid" ]]; then
    if [[ -n "$resp" ]]; then
      do_item_set_state "$bearer" "$did" "$iid" answered "$resp" >/dev/null 2>&1 || true
    else
      do_item_set_state "$bearer" "$did" "$iid" answered >/dev/null 2>&1 || true
    fi
  fi
  sr__resolve_bfh "$tref" || { echo "stuck-routing: resolve — could not record decision for '$tref'" >&2; return 4; }
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# I4 — the FEEDBACK RETURN PATH: the parked runner observes the human's phone
#      answer in the HOSTED engine and resumes the agent WITH it (epic 8bm).
# ════════════════════════════════════════════════════════════════════════════
# The closed loop's return leg, the slice epic 8bm names "never been wired":
# §7.3 PARKS the fork (sr__raise_bfh {resolved:false} + the bead driven
# blocked) and the runner moves on (§7.5). When Brian answers on his phone the
# deployed Inbox `/api/respond` proxy POSTs the FROZEN `item-apply` op to the
# HOSTED engine (web/inbox/functions/api/respond.js) — the §5.2 response is
# recorded on the Item and §5.2.2/§7.4 moves it open→answered→applied IN THE
# HOSTED ENGINE. Nothing on the runner side ever LOOKED there: the local S-2
# bfh record stayed {resolved:false} forever, so `sr_reconcile_blocked_for_
# human` never lifted the bead and the agent never resumed. I4 adds the AWAIT
# (poll the hosted Dossier over the SAME §2.1 `co_request get dossier` read
# surface the I1 transport carries → the deployed engine) and the RESUME (the
# human's decision, captured the moment it is observed, is handed to the
# re-dispatched agent so it ACTS on the answer instead of re-hitting the fork).
#
# ANTI-DRIFT: this is a CONSUMER of the already-frozen surfaces — `do_dossier_
# get`/`do_dossier_rollup` (§2.1/§4.1 reads, T5.1) + the existing S-2 bfh
# namespace + `sr__resolve_bfh`. It introduces NO §4 record type and NO new op
# (the resume-answer file is a T5-owned SIBLING namespace under the SAME store,
# exactly the `blocked-for-human` / `dossier-dedup` / §10.3 `forensic`
# precedent). It NEVER applies a §5.3 consequence or flips a §7.4 per-Item
# latch (T5.3 owns that, applied IN the hosted engine by `item-apply`); it
# only READS the post-apply Item state to know the human decided, and never
# aborts the runner (a poll hiccup leaves the fork PARKED — it must not rot,
# never falsely resume).

# sr__answer_dir — the resume-answer sibling namespace (mirrors sr__bfh_dir).
# Holds the human decision captured at observation time so it SURVIVES the
# `sr_reconcile_blocked_for_human` resolved:true hard-delete of the bfh record
# and is self-contained for the resume prompt (no second hosted fetch needed).
sr__answer_dir() {
  local d; d="$(co_store_dir 2>/dev/null)" || d="${CO_STORE:-${TMPDIR:-/tmp}/claude-beads-coordinator}"
  printf '%s/blocked-for-human-answer' "$d"
}

# sr_resume_answer <task_ref> — echo the captured resume-answer record JSON
#   (so the runner can splice the human decision into the resumed agent's
#   prompt), or return 1 if no answer is pending for this task_ref. Read-only.
sr_resume_answer() {
  local tref="${1:-}" path
  do__safe_key "$tref" 2>/dev/null || return 1
  path="$(sr__answer_dir)/$tref.json"
  [[ -f "$path" ]] || return 1
  cat "$path" 2>/dev/null || return 1
}

# sr_consume_resume_answer <task_ref> — one-shot delete of the resume-answer
#   record once it has been spliced into a resumed run, so a later unrelated
#   pickup of the same bead never re-injects a stale decision. Idempotent.
sr_consume_resume_answer() {
  local tref="${1:-}" path
  do__safe_key "$tref" 2>/dev/null || return 0
  path="$(sr__answer_dir)/$tref.json"
  rm -f "$path" 2>/dev/null || true
  return 0
}

# sr_format_resume_directive <task_ref>
#   Render the captured decision as the human-readable RESUME block the runner
#   prepends to the worker prompt — the "demonstrably changes what the agent
#   does next" payload. Self-contained from the answer record (no hosted
#   fetch). Echoes the block; returns 1 if there is no pending answer.
sr_format_resume_directive() {
  local tref="${1:-}" rec
  rec="$(sr_resume_answer "$tref")" || return 1
  printf '%s' "$rec" | jq -r '
    "═══ HUMAN DECISION — the parked fork on " + (.task_ref // "this task")
      + " was answered (resume) ═══",
    "A human reviewed the STUCK_NEEDS_HUMAN dossier you raised and DECIDED. Do",
    "NOT re-raise the fork. Act on this decision and complete the task:",
    "",
    "  The ask was: " + (.ask // "(see the bead notes / your earlier structured ask)"),
    "  Human chose: " + (.chosen_label // .chosen // "(see response below)")
      + (if (.chosen_blast_radius // "") != "" then "  — " + .chosen_blast_radius else "" end),
    (if (.free_text // "") != "" then "  Human note: " + .free_text else empty end),
    "  Raw response (§5.2): " + (.response | tojson),
    "",
    "Proceed under this decision. The dossier item has already been applied in",
    "the hosted engine (§5.2.2/§7.4); your job is to carry the work forward",
    "under the human decision above and then close the bead as normal."
  ' 2>/dev/null || return 1
}

# sr_poll_hosted_resolution <bearer> [task_ref]
#   THE I4 AWAIT. For each still-PARKED fork (a local S-2 bfh record with
#   resolved:false), READ the Dossier back from the engine over the §2.1
#   `co_request get dossier` surface (→ the HOSTED deployed engine when the I1
#   COORDINATOR_URL transport is configured; the in-process store otherwise —
#   the §0.2-nonnormative transport boundary, unchanged). If the human has
#   answered on the phone, `item-apply` has moved an Item to answered|applied
#   (and the §4.1 rollup to `resolved`) IN THE ENGINE. On observing that:
#     1. Capture the decision into the resume-answer sibling namespace BEFORE
#        anything else (it must survive the bfh hard-delete the reconcile does).
#     2. `sr__resolve_bfh` flip the S-2 record resolved:false→true — the NEXT
#        `sr_reconcile_blocked_for_human` then lifts the work-plane block
#        (bead → open, re-enters `bd ready`) and the runner re-dispatches it
#        with the captured answer (the RESUME).
#   Hosted unreachable / 401 / not-yet-answered ⇒ the fork stays PARKED (it
#   MUST NOT rot, and MUST NOT falsely resume — the §7.3 discipline mirrored on
#   the return leg). Idempotent (an already-captured / already-resolved fork is
#   skipped without a re-fetch). With no <task_ref> it sweeps every parked
#   record. Echoes the count of forks newly observed-resolved; ALWAYS returns 0
#   (a poll never aborts the runner — exactly like the reconcile).
sr_poll_hosted_resolution() {
  local bearer="${1:-}" only="${2:-}" dir adir n=0 f tref did dossier rolled
  command -v do_dossier_get >/dev/null 2>&1 || { echo 0; return 0; }
  [[ -n "$bearer" ]] || bearer="bearer-runner-stuck"
  dir="$(sr__bfh_dir)"
  [[ -d "$dir" ]] || { echo 0; return 0; }
  adir="$(sr__answer_dir)"; mkdir -p "$adir" 2>/dev/null || true
  local files=()
  if [[ -n "$only" ]]; then
    do__safe_key "$only" 2>/dev/null || { echo 0; return 0; }
    [[ -f "$dir/$only.json" ]] && files=("$dir/$only.json")
  else
    for f in "$dir"/*.json; do [[ -e "$f" ]] && files+=("$f"); done
  fi
  for f in "${files[@]:-}"; do
    [[ -e "$f" ]] || continue
    tref=$(jq -r '.task_ref // ""'   "$f" 2>/dev/null) || tref=""
    did=$(jq -r  '.dossier_id // ""' "$f" 2>/dev/null) || did=""
    [[ -n "$tref" && -n "$did" ]] || continue
    [[ "$(jq -r '.resolved // false' "$f" 2>/dev/null)" == "true" ]] && continue
    # Already captured (a prior poll observed it) ⇒ just ensure the S-2 flip is
    # recorded (idempotent — covers a crash between capture and resolve) and
    # skip the network read.
    if [[ -f "$adir/$tref.json" ]]; then
      sr__resolve_bfh "$tref" || true
      continue
    fi
    # Observe the engine. NONZERO/empty (hosted 401, unreachable, not yet
    # persisted) ⇒ the fork stays PARKED for the next poll (must not rot).
    dossier="$(do_dossier_get "$bearer" "$did" 2>/dev/null)" || continue
    [[ -n "$dossier" ]] || continue
    printf '%s' "$dossier" | jq -e 'type=="object"' >/dev/null 2>&1 || continue
    rolled="$(do_dossier_rollup "$dossier" 2>/dev/null)"   # self-defaults to 'open'
    # Decided iff an Item the human acted on is terminal-or-answered, OR the
    # whole Dossier rolled up resolved. An untouched fork (Brian has not
    # answered) is NOT decided — the parked agent correctly stays parked.
    local decided_item
    decided_item="$(printf '%s' "$dossier" | jq -c '
      ( .items // [] ) | map(select(.state=="answered" or .state=="applied")) | .[0] // empty
    ' 2>/dev/null)" || decided_item=""
    if [[ -z "$decided_item" && "$rolled" != "resolved" ]]; then
      continue
    fi
    # If the rollup says resolved but every Item is `expired` (timed-FYI / no
    # human decision), there is no answer to act on — the reconcile still lifts
    # it via the timer path; the resume directive only fires on a real human
    # response. Fall back to the first non-open Item otherwise.
    if [[ -z "$decided_item" ]]; then
      decided_item="$(printf '%s' "$dossier" | jq -c '
        ( .items // [] ) | map(select(.state!="open")) | .[0] // empty' 2>/dev/null)" || decided_item=""
    fi
    # All-`expired` (timed-FYI / no human decision): there is nothing to
    # SPLICE — flip S-2 so the reconcile lifts the bead via the timer path,
    # but do NOT count it in `n` (n = forks with a captured human DECISION the
    # runner will resume WITH; the bead-lift is separately reported by the
    # reconcile's own count). Keeps the runner's "will RESUME with the
    # decision" line honest.
    [[ -n "$decided_item" ]] || { sr__resolve_bfh "$tref" || true; continue; }
    # Build a self-contained, human-readable answer record: the chosen option's
    # label/blast-radius is resolved HERE (from the Item's own §5.2 options[])
    # so the resume prompt needs no second hosted fetch.
    local iid rec now
    iid=$(printf '%s' "$decided_item" | jq -r '.id // ""' 2>/dev/null) || iid=""
    # Same UTC timestamp idiom as the frozen sr__raise_bfh/sr__resolve_bfh
    # siblings (forensic consistency across the bfh + answer namespaces).
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    # jq `//` only short-circuits on null/false (NOT ""), so empty-string
    # fall-through is done explicitly via `select(.!="")` (yields nothing when
    # empty ⇒ the next `//` alternative is taken). Keeps the captured decision
    # honest whether the §5.2 response is a pick (selected_option_id), an
    # approve/reject (decision), or an edited/freeform (free_text) shape.
    rec="$(printf '%s' "$decided_item" | jq -c --arg tref "$tref" --arg did "$did" --arg at "$now" '
      def nz: select((. // "") != "");
      ( .response // {} ) as $r
      | ( ($r.selected_option_id | nz) // "" ) as $sel
      | ( ($r.decision | nz) // "" ) as $dec
      | ( ( .options // [] ) | map(select(.option_id==$sel)) | .[0] // {} ) as $opt
      | ( ($sel | nz) // ($dec | nz) // "" ) as $chosen
      | { task_ref:$tref, dossier_id:$did, item_id:(.id // ""),
          ask:( (.framing.ask | nz) // (.context_anchor.where | nz) // "" ),
          response:$r,
          chosen:$chosen,
          chosen_label:( ($opt.label | nz) // ($chosen | nz) // "(answered — see the dossier)" ),
          chosen_blast_radius:( $opt.blast_radius // "" ),
          free_text:( ($r.free_text | nz) // ($r.note | nz) // ($r.edited_value | nz) // ($r.text | nz) // "" ),
          decided_at:$at }' 2>/dev/null)" || rec=""
    [[ -n "$rec" ]] || rec="$(jq -cn --arg tref "$tref" --arg did "$did" --arg iid "$iid" --arg at "$now" \
        '{task_ref:$tref,dossier_id:$did,item_id:$iid,ask:"",response:{},chosen:"",chosen_label:"(answered — see the dossier)",chosen_blast_radius:"",free_text:"",decided_at:$at}' 2>/dev/null)"
    # Capture FIRST (must outlive the reconcile delete), THEN flip S-2.
    local atmp="$adir/$tref.json.$$.tmp"
    if printf '%s' "$rec" > "$atmp" 2>/dev/null && mv -f "$atmp" "$adir/$tref.json" 2>/dev/null; then
      sr__resolve_bfh "$tref" || true
      n=$((n+1))
    else
      rm -f "$atmp" 2>/dev/null || true
      # Could not persist the capture ⇒ do NOT flip S-2 (resuming without the
      # answer would defeat the point); leave PARKED for the next poll.
      echo "stuck-routing: poll — could not capture the resume-answer for '$tref'; left PARKED for the next poll (the fork must not resume without the decision)" >&2
    fi
  done
  echo "$n"
  return 0
}
