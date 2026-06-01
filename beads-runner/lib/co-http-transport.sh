# shellcheck shell=bash
# beads-runner/lib/co-http-transport.sh — I1 (claude-tools-txj; epic claude-tools-8bm).
#
# THE HOSTED TRANSPORT. When COORDINATOR_URL is set, this OVERRIDES the
# in-process bash co_request (lib/coordinator.sh) with one that does authed
# HTTPS to the DEPLOYED coordinator, translating the engine's HTTP contract
# (HTTP status + JSON envelope) back into the FROZEN in-process co_request
# contract (bash rc + BARE stdout + stderr diagnostics) every reused subsystem
# (dossier.sh / dossier-gen.sh / notification.sh / timed-fyi.sh /
# stuck-routing.sh / consequence.sh) and the local-agent §1.1 outbox depend on.
#
# It is the exact 5-point spec the I0 disconnection audit handed off
# (claude-tools-4ih → tmp/i0/i0-disconnection-audit.md), closing D0–D6:
#
#   D0 AUTH      per-workspace bearer, §9.2 server-side only: resolved from the
#                Local Agent Keychain (la_coordinator_token) or COORDINATOR_TOKEN,
#                NEVER from the placeholder bearer the libs/tests carry, NEVER
#                logged. (The deployed Worker enforces CO_EXPECTED_TOKEN; the
#                libs' "bearer-runner-secret-xyz" 401s — that IS the
#                disconnection. This supplies the real per-workspace token.)
#   D1 RC        HTTP status → bash rc, NOT curl's transport rc — op-aware,
#                preserving the FULL in-process op-class rc contract:
#                  2xx ⇒ 0  (ack {ok:false}, e.g. timer-ack absent ⇒ 1)
#                  2xx ask-capacity ⇒ 0 ok / 1 over (the §6.3 token↔rc
#                        bijection — body still passes through verbatim)
#                  401 ⇒ 1  (auth-fail, exactly bash co_request's 401 rc)
#                  404 ⇒ 1  (absent — exactly bash co__store_get's rc)
#                  409 ⇒ 1  (lease DENIAL — routine contention, the bash
#                        co__lease_* rc 1, NOT a transport failure)
#                  422 ⇒ 2 | 3 by the bash precedence, op-aware (store-owner
#                        unknown_type/unsafe_id ⇒ 2 ; schema/json ⇒ 3 ;
#                        report-capacity reject ⇒ 3 ; arity/lease ⇒ 2)
#                  5xx / transport ⇒ 4 (the bash co__store_write failure rc) —
#                        always a LOUD nonzero, never a masked success.
#   D2 ENVELOPE  per-op-class normalisation. DATA-200 bodies (get-present,
#                timer-due, poll, reconcile, work-snapshot, capabilities,
#                forensic-fetch/audit, ask-capacity) pass through stdout
#                VERBATIM (from the temp file — timer-due's trailing "\n" is
#                byte-identical to bash co__timer_due). lease-acquire/
#                lease-renew UNWRAP `.lease` (the bash oracle emits the bare
#                §4.4 record for `generation` fencing, not the {ok:…}
#                wrapper). All OTHER ACK envelopes ({ok:…}) are SUPPRESSED to
#                empty stdout. An {ok:…} envelope NEVER reaches a reused jq
#                parse (the root cause of the I0 rc-3 §0.3 misclassification).
#   D3 STDERR    the envelope `error` / diagnostic is re-routed to STDERR;
#                stdout is kept bare on every non-data path (the reused readers
#                `2>/dev/null` and trust empty-stdout-on-failure).
#   D4 PUT-OUT   put/ack stdout kept bare (suppressed) for any future reader.
#   D5 TIMER-DUE a non-200 on timer-due maps to a LOUD nonzero rc, so the
#                timed-fyi S-6 poll-fallback `|| { … return 1; }` fires instead
#                of silently treating a 401 envelope as "no timers due".
#   D6 TRANSPORT this file IS the HTTP co_request that did not exist; it is
#                activated by COORDINATOR_URL — no in-process co_request edit,
#                no config flip inside the FROZEN libs.
#
# DIALECT (deliberate, audited): native  POST {COORDINATOR_URL%/}/  {op,args:[…]}
# + `Authorization: Bearer <token>`. This is the FROZEN CF.1 Worker's FULL op
# surface — the one the CF.11 differential rig proved behaviour-equivalent to
# the bash oracle. The deployed adapter (cf/pages-dev/adapter.js) passes every
# non-`/request` path STRAIGHT THROUGH to that byte-unchanged Worker, so a
# native `put` lands in the SAME singleton Coordinator DO + the SAME hosted D1
# the deployed Inbox reads back through its `/request?op=get` proxy front. The
# `/request?op=` REST front is the screens-only NARROW proxy dialect and
# structurally cannot carry put / timer-* / heartbeat (adapter argsForGet/Post
# map only get/work-snapshot/forensic-fetch/item-apply/forensic-dismiss) — so
# the reused control-plane seam MUST use the native dialect. Same engine, same
# store, same DO: a native-put dossier IS the dossier the Inbox renders.
#
# Safe to `source` under `set -euo pipefail`. STRICTLY NO-OP unless
# COORDINATOR_URL is set & non-empty: absent it, the in-process bash
# co_request stays untouched (the 507-green lib suite + the T1 conformance
# harness are byte-unaffected — they never set COORDINATOR_URL). Requires
# `curl` + `jq` (already required by the reused libs).

# ── activation gate ──────────────────────────────────────────────────────────
# Only override co_request when a per-workspace hosted endpoint is configured.
# This keeps every existing oracle/conformance run (no COORDINATOR_URL) on the
# in-process bash dispatcher byte-for-byte.
if [[ -n "${COORDINATOR_URL:-}" ]]; then

# co_http__base — COORDINATOR_URL with any trailing slash trimmed (we POST to
# "<base>/" — the FROZEN Worker's native front door, NOT "/request").
co_http__base() { printf '%s' "${COORDINATOR_URL%/}"; }

# co_http__token — the per-workspace bearer (§9.2). Priority:
#   1. COORDINATOR_TOKEN env  — the explicit server-side binding the local
#      `cf/pages-dev/serve.sh` / verify.sh / a test harness injects.
#   2. la_coordinator_token   — the Local Agent's macOS-Keychain §9.2 store
#      (service "claude-beads-runner.coordinator-token"), if local-agent.sh is
#      sourced. This is where the REAL per-workspace production token lives,
#      out of agent context BY DESIGN.
# Echoes NOTHING when neither is present — the request then carries no bearer
# and the Worker 401s LOUDLY (mapped rc 1), never a silent pseudo-success. The
# value is NEVER echoed to stdout/stderr by this transport.
co_http__token() {
  if [[ -n "${COORDINATOR_TOKEN:-}" ]]; then printf '%s' "${COORDINATOR_TOKEN}"; return 0; fi
  if declare -F la_coordinator_token >/dev/null 2>&1; then la_coordinator_token; return 0; fi
  printf ''
}

# co_http__op_is_data <op> — DATA-200 op-class predicate (D2). For these the
# 200 body IS the payload a reused reader consumes and MUST pass through
# stdout verbatim. Everything else is an ACK op (200 ⇒ {ok:…} envelope ⇒
# SUPPRESS to empty stdout). `get` additionally has the 404-absent path; the
# status map below handles that uniformly.
co_http__op_is_data() {
  case "$1" in
    # ask-capacity is body-passthrough too, but its rc is token-derived
    # (over⇒1) — handled as an explicit special case in the 2xx arm, NOT here.
    # I3 (claude-tools-06i) — `intake-pending` returns a JSON array of records;
    # the daemon poll consumes that stdout verbatim, so it is DATA-200 too.
    get|timer-due|poll|reconcile|work-snapshot|capabilities|forensic-fetch|forensic-audit|intake-pending) return 0 ;;
    *) return 1 ;;
  esac
}

# co_http__rc_from_422 <body> <op> — map a 422 reject to the bash rc
# precedence. The deployed engine returns a 422 for: (a) §4 store-owner
# rejects WITH a schema.js `code`; (b) arity/bad-arg rejects with NO code
# (timer-*/set-desired/lease — bash rc 2); (c) report-capacity / ask-capacity
# rejects with an EMPTY body (capacity.js textRes("",422)). The bash
# co__store_put / co__capacity_report precedence:
#   unknown_type | unsafe_id                                   ⇒ 2
#   invalid_json | not_json_object | missing_schema_version |
#   higher_version | unsupported_version                        ⇒ 3
#   report-capacity, ANY 422 (bash co__capacity_report reject)  ⇒ 3
#   no code, other ops (timer-*/set-desired/lease arity)        ⇒ 2
#   any other / unparseable                                     ⇒ 3  (the §0.3
#     conservative reject — never best-effort-treat-as-success)
co_http__rc_from_422() {
  local body="$1" op="${2:-}" code
  # report-capacity's reject is an EMPTY-body 422 with no code, but the bash
  # co__capacity_report reject precedence is rc 3 (only its missing-arg is
  # rc 2, and the I1 drain never sends an arg-less report). Op-specific.
  if [[ "$op" == "report-capacity" ]]; then printf '3'; return 0; fi
  code="$(printf '%s' "$body" | jq -r 'if type=="object" then (.code // "") else "" end' 2>/dev/null)" || code=""
  case "$code" in
    unknown_type|unsafe_id) printf '2' ;;
    invalid_json|not_json_object|missing_schema_version|higher_version|unsupported_version) printf '3' ;;
    "") printf '2' ;;            # arity/bad-args 422 (timer-*/set-desired/lease): bash rc 2
    *)  printf '3' ;;            # unknown code ⇒ §0.3 conservative reject
  esac
}

# ── THE OVERRIDE: HTTP co_request, FROZEN in-process contract preserved ───────
# Signature IDENTICAL to lib/coordinator.sh co_request:
#     co_request <bearer> <op> [args…]
# The reused libs pass the placeholder bearer they carry; the HOSTED transport
# IGNORES it for auth (D0) and uses the resolved per-workspace token instead —
# UNLESS no per-workspace token resolves, in which case the passed bearer is
# used verbatim (so an explicitly-empty bearer still drives the 401 path for
# tests, and a test that injects a known token still works). Either way the
# real §9.1 authenticate() runs server-side in the FROZEN Worker.
co_request() {
  local passed="${1:-}" op="${2:-}"; shift 2 2>/dev/null || true

  # §6.2/AD2.2 sidecar (claude-tools-ylu2): a PRECISE Coordinator-unreachable
  # signal for the runner's bounded-local-lease fallback. The rc alone is too
  # coarse — `return 4` below also covers a REACHABLE 5xx/4xx-other (the engine
  # answered, with an error) and local jq/mktemp faults, neither of which is
  # unreachability. The §6.2 LEASE plane must fail CLOSED on those (refuse), and
  # open the bounded fallback ONLY when the Coordinator genuinely cannot be
  # reached. Reset to 0 here; set to 1 ONLY on the curl-failed / no-HTTP-code
  # path below. (A contended-lease 409 is rc 1, never 4 — already excluded.)
  CO_HTTP_UNREACHABLE=0

  local bearer; bearer="$(co_http__token)"
  [[ -n "$bearer" ]] || bearer="$passed"

  # Build {op, args:[…]} with POSITIONAL args verbatim — exactly the in-process
  # co_request case-dispatch arg order / the adapter's documented mapping.
  local body
  body="$(jq -cn --arg op "$op" '{op:$op, args:$ARGS.positional}' --args "$@" 2>/dev/null)" \
    || { echo "co: transport — could not build request body for op '$op'" >&2; return 4; }

  local tmp http rc
  tmp="$(mktemp 2>/dev/null)" || { echo "co: transport — mktemp failed" >&2; return 4; }
  if [[ -n "$bearer" ]]; then
    http="$(curl -sS -m 25 -o "$tmp" -w '%{http_code}' \
              -X POST "$(co_http__base)/" \
              -H 'content-type: application/json' \
              -H "authorization: Bearer ${bearer}" \
              --data-binary "$body" 2>/dev/null)"
    rc=$?
  else
    # No bearer at all — mirrors the in-process empty-bearer reject path; the
    # Worker 401s with no Authorization header (still a clean mapped rc 1).
    http="$(curl -sS -m 25 -o "$tmp" -w '%{http_code}' \
              -X POST "$(co_http__base)/" \
              -H 'content-type: application/json' \
              --data-binary "$body" 2>/dev/null)"
    rc=$?
  fi

  # `resp` (trailing-newline-stripped) is ONLY for envelope/jq inspection on
  # the non-data paths — jq is whitespace-insensitive so the strip is moot
  # there. A DATA-op body is emitted from the temp FILE verbatim (below) so
  # timer-due's trailing "\n" is byte-identical to the bash co__timer_due
  # stdout (issue: never feed a `$(…)`-stripped body to a newline-split
  # consumer). The file is removed on every return path.
  local resp; resp="$(cat "$tmp" 2>/dev/null)"

  # Transport itself failed (DNS/TLS/timeout/connection) — curl nonzero or no
  # HTTP code. LOUD rc 4 (the co__store_write failure analog), bare stdout,
  # diagnostic to stderr. NEVER curl's rc 0 masquerading as success (D1).
  if [[ "$rc" -ne 0 || -z "$http" ]]; then
    rm -f "$tmp" 2>/dev/null
    CO_HTTP_UNREACHABLE=1   # §6.2/AD2.2 — GENUINE unreachable (curl failed / no HTTP code); the ONLY rc-4 path the runner's bounded local fallback may act on
    echo "co: transport — unreachable (curl rc=$rc http=${http:-none}) op='$op'" >&2
    return 4
  fi

  case "$http" in
    2*)
      # ── lease-acquire / lease-renew: 200 {ok:true,lease:<§4.4 record>}.
      #    The bash oracle emits the BARE granted/renewed record on stdout so
      #    the caller learns its `generation` (fencing). Unwrap `.lease` —
      #    suppressing it (the generic ACK path) would silently break every
      #    lease consumer (the I0 D2/D4 class, on the lease op).
      if [[ "$op" == "lease-acquire" || "$op" == "lease-renew" ]]; then
        printf '%s' "$resp" | jq -ce 'if type=="object" and (.lease!=null) then .lease else empty end' 2>/dev/null
        rm -f "$tmp" 2>/dev/null
        return 0
      fi
      # ── ask-capacity: text/plain 200 "ok"|"over". Body passes through
      #    VERBATIM (bash stdout), AND the rc is token-derived — over ⇒ 1,
      #    ok ⇒ 0 (the §6.3 bash co__ask_capacity proceed/halt bijection; the
      #    generic DATA path would wrongly return rc 0 for "over").
      if [[ "$op" == "ask-capacity" ]]; then
        cat "$tmp"; rm -f "$tmp" 2>/dev/null
        [[ "$resp" == "over" ]] && return 1
        return 0
      fi
      if co_http__op_is_data "$op"; then
        # DATA-200: the body IS the payload — pass through VERBATIM from the
        # file (rc 0). Byte-identical to the in-process bare-stdout contract:
        # get-present ⇒ the record JSON; timer-due ⇒ newline-joined ids with
        # the SAME trailing newline as bash co__timer_due; poll/reconcile/
        # work-snapshot ⇒ the JSON projection.
        cat "$tmp"; rm -f "$tmp" 2>/dev/null
        return 0
      fi
      rm -f "$tmp" 2>/dev/null
      # ACK-200: {ok:…} acknowledgement — SUPPRESS to empty stdout (D2/D4).
      # {ok:false} (timer-ack on an absent timer, …) ⇒ rc 1 — the bash
      # "absent" nonzero. {ok:true} / no `ok` / empty body ⇒ rc 0.
      local okf
      okf="$(printf '%s' "$resp" | jq -r 'if type=="object" then (.ok|tostring) else "true" end' 2>/dev/null)" || okf="true"
      if [[ "$okf" == "false" ]]; then return 1; fi
      return 0
      ;;
    401)
      # Auth-fail — EXACTLY bash co_request's 401 path: rc 1, NOTHING on
      # stdout, the diagnostic on stderr. The reused `… 2>/dev/null || return 1`
      # now cleanly classifies this as absent/unreachable, NOT the I0 rc-3
      # §0.3-corrupt misclassification (D0/D2/D3 closed).
      rm -f "$tmp" 2>/dev/null
      echo "co: 401 — bearer token missing/invalid; request rejected (NO §4 write; §9.1/§2.3)" >&2
      return 1
      ;;
    404)
      # Absent — EXACTLY bash co__store_get's rc: empty stdout + rc 1. The
      # do_dossier_get/no_get `|| return 1` fires as clean "absent".
      rm -f "$tmp" 2>/dev/null
      return 1
      ;;
    409)
      # LEASE DENIAL (lease.js: rc 1 ⇒ 409). EXACTLY bash co__lease_* rc 1:
      # empty stdout + rc 1 + the observable marker on stderr. This is a
      # ROUTINE contended-lease outcome, NOT a transport failure — mapping it
      # to the loud rc 4 would make every contended acquire look like an
      # outage to the §6.1 arbitration caller.
      rm -f "$tmp" 2>/dev/null
      printf '%s' "$resp" | jq -r 'if type=="object" and (.error|type)=="string" then "co: \(.error)" else empty end' >&2 2>/dev/null || true
      return 1
      ;;
    422)
      # §0.3 / store-owner-input-hygiene / capacity reject. Bare stdout; the
      # engine's `error` to stderr; rc by the bash precedence, op-aware (D1).
      rm -f "$tmp" 2>/dev/null
      printf '%s' "$resp" | jq -r 'if type=="object" and (.error|type)=="string" then "co: \(.error)" else empty end' >&2 2>/dev/null || true
      return "$(co_http__rc_from_422 "$resp" "$op")"
      ;;
    *)
      # 5xx / 4xx-other — LOUD rc 4 (co__store_write failure analog). Bare
      # stdout; diagnostic to stderr. timer-due non-200 lands here / on 401 ⇒
      # the S-6 poll-fallback `||` fires (D5: no silent stall).
      rm -f "$tmp" 2>/dev/null
      printf '%s' "$resp" | jq -r 'if type=="object" and (.error|type)=="string" then "co: \(.error)" else empty end' >&2 2>/dev/null || true
      echo "co: transport — unexpected HTTP $http for op '$op'" >&2
      return 4
      ;;
  esac
}

# ── §1.1 / §2.4 — the Local Agent OUTBOX DRAIN (the second I1 deliverable) ────
# local-agent.sh writes the machine-local append-only §1.1 UP queue
# ($LOG_DIR/coordinator-outbox.jsonl: one JSON report per line). With no
# hosted Coordinator that queue only ever grew; this is the drainer that —
# when COORDINATOR_URL is set — pushes each line to the deployed engine over
# the SAME authed HTTP co_request above, dispatched by the line's `report`
# discriminator to its hosted op (the §2.4 "Coordinator drains on reconnect"
# realised as the runner-side push):
#     report=="capacity"           → co_request … report-capacity        <line>  (capacity.js)
#     report=="heartbeat"          → co_request … heartbeat              <line>  (reconcile.js)
#     report=="machine_state"      → co_request … report-machine-state   <line>  (machine-state.js)
#     report=="workspace_inventory"→ co_request … workspace-inventory-put<line>  (claude-tools-8dfb)
#     report=="bead_status_changed"→ co_request … bead-status-changed     <line>  (claude-tools-uxvl2 / dossier.js — L2 work→control auto-close)
# A line with any other `report` (e.g. the §8.2 terminal-reason re-home, whose
# authoritative sink is the LOCAL $LOG_DIR/terminal-reason file + the
# heartbeat-absence channel — there is deliberately NO hosted terminal-reason
# op) is LEFT IN PLACE and noted, never force-fit onto an op that would 422.
#
# Signature: la_outbox_drain <bearer> [outbox_path]
#   - <bearer>           passed to co_request (the HTTP transport may swap it
#                        for the resolved per-workspace token; if both are
#                        empty the Worker 401s LOUDLY — clean rc 1).
#   - [outbox_path]      OPTIONAL: explicit path to the §1.1 outbox file. When
#                        absent, falls back to la__outbox() (the workspace
#                        runner's outbox at $LOG_DIR/coordinator-outbox.jsonl).
#                        Passed explicitly by the daemon to drain its OWN
#                        machine-wide outbox ($DAEMON_CACHE_DIR/coordinator-
#                        outbox.jsonl) — the same drainer logic, just a
#                        different durable queue (the M2 daemon owns capacity
#                        + machine_state emit; the workspace owns heartbeat +
#                        terminal-reason).
#
# Contract: at-least-once with a rewrite-survivors tail. Each successfully
# pushed line is dropped; a line whose push fails (incl. the by-design 401
# until the real token is provisioned) is RETAINED so a later drain retries —
# the §1.1 queue is durable, a transient outage or a missing token never
# loses a report. Returns 0 if the queue is now empty (all drained or none
# present), 1 if any line was retained (caller may retry later); never aborts.
la_outbox_drain() {
  local bearer="${1:-}" obx="${2:-}" kept rc=0
  if [[ -z "$obx" ]]; then
    if ! declare -F la__outbox >/dev/null 2>&1; then
      echo "co: outbox-drain — local-agent.sh not sourced (no la__outbox) and no outbox path passed; nothing to drain" >&2
      return 0
    fi
    obx="$(la__outbox)"
  fi
  [[ -f "$obx" ]] || return 0          # no queue ⇒ nothing to do (clean)

  kept="$(mktemp 2>/dev/null)" || { echo "co: outbox-drain — mktemp failed" >&2; return 1; }

  local line report op
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    report="$(printf '%s' "$line" | jq -r 'if type=="object" then (.report // "") else "" end' 2>/dev/null)" || report=""
    case "$report" in
      capacity)            op="report-capacity" ;;
      heartbeat)           op="heartbeat" ;;
      machine_state)       op="report-machine-state" ;;
      workspace_inventory) op="workspace-inventory-put" ;;
      bead_status_changed) op="bead-status-changed" ;;   # claude-tools-uxvl2 (L2 work→control auto-close)
      *)
        # No hosted op for this report kind — retain verbatim, do not 422 it.
        echo "co: outbox-drain — retaining line with no hosted op (report='${report:-<none>}')" >&2
        printf '%s\n' "$line" >> "$kept"
        rc=1
        continue
        ;;
    esac
    if co_request "$bearer" "$op" "$line" >/dev/null 2>&1; then
      :                                # pushed ⇒ drop (do not re-queue)
    else
      printf '%s\n' "$line" >> "$kept" # push failed ⇒ retain for a later drain
      rc=1
    fi
  done < "$obx"

  # Atomically replace the queue with the survivors (empty file if all drained).
  if mv -f "$kept" "$obx" 2>/dev/null; then :; else rm -f "$kept" 2>/dev/null; fi
  return "$rc"
}

fi  # COORDINATOR_URL gate
