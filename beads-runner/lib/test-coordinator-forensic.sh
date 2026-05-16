#!/bin/bash
# beads-runner/lib/test-coordinator-forensic.sh — focused unit test for the
# §10.3 Coordinator-side forensic transient store (T4.5, claude-tools-guq).
#
# T4.5's OWN test surface. Deliberately NOT a member of the T1 conformance
# suite (beads-runner/conformance/, owned by T1a/T1b) and it does NOT touch
# T4.1's test-coordinator.sh (claude-tools-ick) — anti-drift: each tier its
# own focused test. It exercises ONLY the §10.3 surface on coordinator.sh.
#
# Asserts the EXIT CRITERIA T4.5 owns against INTERFACE.md v1 §10.3:
#   1. The redacted blob is stored CIPHERTEXT-ONLY; the server key is NEVER
#      returned to a client (any surface) and the keyfile is mode 600.
#   2. Hard-delete at the EARLIER of created_at + FORENSIC_BLOB_TTL (§0.5)
#      OR an explicit dismiss; a deleted blob is IRRECOVERABLE — no
#      soft-delete tombstone is fetchable.
#   3. A delete emits a control-plane AUDIT EVENT — ids + timestamps + reason
#      ONLY; assert CONTENT-FREE (no plaintext, no ciphertext, no key).
#   4. Fetch requires §9 auth and is ON-DEMAND only; the blob NEVER appears
#      in the §4.5 projection (poll) or any §4.3 Notification body.
#   5. Anti-drift: SEPARATE transient object under machine-scratch CO_STORE
#      (does not weaken the §10.1/BC-27 on-disk boundary — that lives in
#      run-beads-tasks.sh, asserted by T1b bc-27); NOT a §4 record type;
#      redaction is NOT re-derived here (consumed verbatim from T2/T3 §10.2).
#
# Self-contained: its own CO_STORE under mktemp; its own env vocabulary,
# sharing NO state with the T1 conformance harness or T4.1's test.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator.sh"
[[ -f "$LIB" ]] || { echo "FATAL: coordinator.sh not found at $LIB"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
ck()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

# In-process predicates (no `bash -c` quoting hazards: captured values are
# compared in the current shell, where they expand normally).
has()       { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }   # $2 ⊇ $1
hasnt()     { case "$2" in *"$1"*) return 1;; *) return 0;; esac; }
eq()        { [[ "$1" == "$2" ]]; }
nz()        { [[ -n "$1" ]]; }
zz()        { [[ -z "$1" ]]; }
line_in()   { printf '%s\n' "$2" | grep -qx "$1"; }
rejected()  { ! co_request "$@" >/dev/null 2>&1; }
file_has()  { grep -qF "$1" "$2" 2>/dev/null; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CO_STORE="$WORK/store"          # hosted store realised in scratch (never the repo)
unset CO_EXPECTED_TOKEN PRINCIPAL_V1 FORENSIC_BLOB_TTL 2>/dev/null || true

# shellcheck source=/dev/null
source "$LIB"

GOOD="bearer-runner-secret-xyz"        # a present, valid v1 bearer
MARK="SECRET-FORENSIC-MARKER-9f3a17b2" # a plaintext canary that MUST stay sealed
# A §10.2-shaped redacted blob, consumed VERBATIM (paths kept, file contents
# already stripped to {byte_length,sha256_prefix} BY THE RUNNER — not here).
BLOB='{"tool_use":[{"name":"Read","input":{"file_path":"/etc/app/cfg"}}],"tool_result":[{"is_error":true}],"stripped":{"redacted":true,"byte_length":4096,"sha256_prefix":"deadbeefcafe"},"last_assistant":"'"$MARK"'"}'

echo "── EXIT-1: stored CIPHERTEXT-ONLY; server key never returned; keyfile 0600 ──"
out="$(co_request "$GOOD" forensic-put b1 claude-tools-aaa "$BLOB" 2>/dev/null)"
ck "forensic-put returns the blob id (not ciphertext, not key)" eq "$out" "b1"
ENC="$CO_STORE/forensic/b1.enc"; META="$CO_STORE/forensic/b1.meta"
ck "ciphertext object written"                      test -f "$ENC"
ck "content-free meta written"                      test -f "$META"
metakeys="$(jq -r '[keys[]]|sort|join(",")' "$META" 2>/dev/null || true)"
ck "meta is content-free (ids + timestamps only, no blob body)" \
   eq "$metakeys" "blob_id,created_at,created_epoch,dossier_ref,expires_epoch,principal"
ck "meta carries NO plaintext canary" \
   bash -c '! grep -qF "$1" "$2"' _ "$MARK" "$META"
ck "at-rest object does NOT contain the plaintext canary" \
   bash -c '! grep -qF "$1" "$2"' _ "$MARK" "$ENC"
encbytes="$(cat "$ENC" 2>/dev/null)"
ck "at-rest object differs from the plaintext (encrypted)"   hasnt "$MARK" "$encbytes"
ck "ciphertext carries the openssl Salted__ header (AES-256/PBKDF2)" \
   has "U2FsdGVk" "$encbytes"
# The server-managed key: a SERVER SECRET, never on any surface, mode 600,
# OUTSIDE the forensic/ ciphertext namespace.
KF="$CO_STORE/.forensic-master.key"
ck "server key file exists"                          test -s "$KF"
mode="$(stat -f '%Lp' "$KF" 2>/dev/null || stat -c '%a' "$KF" 2>/dev/null)"
ck "server key file is mode 600"                     eq "$mode" "600"
ck "server key lives OUTSIDE the forensic/ ciphertext namespace" \
   bash -c '! test -e "$1"' _ "$CO_STORE/forensic/.forensic-master.key"
KEYVAL="$(cat "$KF" 2>/dev/null)"
ck "server key value is non-empty"                   nz "$KEYVAL"
ck "no file under forensic/ contains the key" \
   bash -c '! grep -rqF "$1" "$2" 2>/dev/null' _ "$KEYVAL" "$CO_STORE/forensic/"
# No surface returns the key.
ck "forensic-put output never contains the key"      hasnt "$KEYVAL" "$out"
fetched="$(co_request "$GOOD" forensic-fetch b1 2>/dev/null)"
ck "forensic-fetch returns the §10.2 blob (the ONE crossing)"  has "$MARK" "$fetched"
ck "forensic-fetch output never contains the key"    hasnt "$KEYVAL" "$fetched"
fp="$(jq -r '.tool_use[0].input.file_path' <<<"$fetched" 2>/dev/null)"
sp="$(jq -r '.stripped.sha256_prefix' <<<"$fetched" 2>/dev/null)"
ck "fetched blob is the VERBATIM §10.2 shape (path kept)"      eq "$fp" "/etc/app/cfg"
ck "fetched blob keeps the runner's pre-stripped placeholder"  eq "$sp" "deadbeefcafe"
caps="$(co_capabilities 2>/dev/null)"
ncaps="$(grep -c '§2' <<<"$caps" || true)"
ck "co_capabilities (T4.1) still EXACTLY four §2 lines (untouched)"  eq "$ncaps" "4"
ck "co_capabilities never leaks the key"             hasnt "$KEYVAL" "$caps"

echo "── EXIT-2: hard-delete at EARLIER(created_at+TTL, dismiss); irrecoverable ──"
# (a) explicit-dismiss arm — fetch works first, then dismiss destroys it.
co_request "$GOOD" forensic-put b2 claude-tools-bbb "$BLOB" >/dev/null 2>&1
pre="$(co_request "$GOOD" forensic-fetch b2 2>/dev/null)"
ck "pre-dismiss fetch returns the blob"              nz "$pre"
co_request "$GOOD" forensic-dismiss b2 >/dev/null 2>&1
ck "dismiss ⇒ ciphertext object destroyed"           bash -c '! test -f "$1"' _ "$CO_STORE/forensic/b2.enc"
ck "dismiss ⇒ meta destroyed"                        bash -c '! test -f "$1"' _ "$CO_STORE/forensic/b2.meta"
ck "dismissed blob fetch ⇒ nonzero (gone)"           rejected "$GOOD" forensic-fetch b2
post="$(co_request "$GOOD" forensic-fetch b2 2>/dev/null)"
ck "dismissed blob fetch ⇒ EMPTY (no tombstone returned)"      zz "$post"
tomb="$(ls "$CO_STORE"/forensic/b2.* 2>/dev/null || true)"
ck "NO soft-delete tombstone left in forensic/ (b2.*)"         zz "$tomb"
ck "re-dismiss of an already-gone blob is idempotent success" \
   co_request "$GOOD" forensic-dismiss b2
# (b) TTL arm — FORENSIC_BLOB_TTL=0 ⇒ expires at creation ⇒ next access deletes
# (the EARLIER-of bound holds lazily, even with no sweep daemon).
( export FORENSIC_BLOB_TTL=0; source "$LIB"
  co_request "$GOOD" forensic-put b3 claude-tools-ccc "$BLOB" >/dev/null 2>&1 )
ck "TTL-expired blob fetch ⇒ nonzero"                rejected "$GOOD" forensic-fetch b3
ck "TTL-expired fetch HARD-DELETED the ciphertext"   bash -c '! test -f "$1"' _ "$CO_STORE/forensic/b3.enc"
tomb3="$(ls "$CO_STORE"/forensic/b3.* 2>/dev/null || true)"
ck "TTL-expired blob leaves NO tombstone (b3.*)"     zz "$tomb3"
# (c) proactive sweep arm — mirrors the §2.2 S-6 poll-fallback.
( export FORENSIC_BLOB_TTL=0; source "$LIB"
  co_request "$GOOD" forensic-put b4 claude-tools-ddd "$BLOB" >/dev/null 2>&1 )
swept="$(co_request "$GOOD" forensic-sweep 2>/dev/null)"
ck "forensic-sweep reports the expired blob id"      line_in b4 "$swept"
ck "swept blob ciphertext destroyed"                 bash -c '! test -f "$1"' _ "$CO_STORE/forensic/b4.enc"
# A NOT-yet-expired blob (default 3600 s) survives a sweep (EARLIER-of holds).
co_request "$GOOD" forensic-put b5 claude-tools-eee "$BLOB" >/dev/null 2>&1
co_request "$GOOD" forensic-sweep >/dev/null 2>&1
ck "un-expired blob survives a sweep (TTL not reached)"        test -f "$CO_STORE/forensic/b5.enc"
keep="$(co_request "$GOOD" forensic-fetch b5 2>/dev/null)"
ck "un-expired blob still fetchable"                 nz "$keep"

echo "── EXIT-3: delete emits a CONTENT-FREE control-plane audit event ──"
aud="$(co_request "$GOOD" forensic-audit 2>/dev/null)"
ck "audit log has ≥1 deletion event"                 nz "$aud"
last="$(printf '%s\n' "$aud" | tail -1)"
ev="$(jq -r '.event' <<<"$last" 2>/dev/null)"
da="$(jq -r '.deleted_at' <<<"$last" 2>/dev/null)"
rs="$(jq -r '.reason' <<<"$last" 2>/dev/null)"
ck "audit event is forensic_blob_deleted"            eq "$ev" "forensic_blob_deleted"
ck "audit event carries a deleted_at UTC timestamp"  has "Z" "$da"
ck "audit event records a reason (dismiss|ttl)"      bash -c 'case "$1" in dismiss|ttl) exit 0;; *) exit 1;; esac' _ "$rs"
# CONTENT-FREE: every line's keys ⊆ the allowed control-plane set; NO
# plaintext canary, NO ciphertext, NO key anywhere in the whole audit log.
extra="$(printf '%s\n' "$aud" | jq -c '[keys[]]-["event","blob_id","dossier_ref","created_at","deleted_at","reason","principal"]' 2>/dev/null | grep -vx '\[\]' || true)"
ck "audit keys ⊆ {event,blob_id,dossier_ref,created_at,deleted_at,reason,principal}"  zz "$extra"
AUDLOG="$CO_STORE/forensic-audit.jsonl"
ck "audit log contains NO plaintext forensic canary"  bash -c '! grep -qF "$1" "$2"' _ "$MARK" "$AUDLOG"
ck "audit log contains NO ciphertext (no Salted__ b64)" \
   bash -c '! grep -q "U2FsdGVk" "$1"' _ "$AUDLOG"
ck "audit log never leaks the server key"             bash -c '! grep -qF "$1" "$2"' _ "$KEYVAL" "$AUDLOG"

echo "── EXIT-4: fetch requires §9 auth, is on-demand; never in §4.5 / notify ──"
co_request "$GOOD" forensic-put b6 claude-tools-fff "$BLOB" >/dev/null 2>&1
# §9 auth: a no-token / bad-token fetch is rejected at the ONE chokepoint
# BEFORE any decryption — no plaintext can leak.
ck "no-token forensic-fetch ⇒ rejected (nonzero)"     rejected "" forensic-fetch b6
leak="$(co_request "" forensic-fetch b6 2>/dev/null)"
ck "no-token forensic-fetch ⇒ NO plaintext leaked"    zz "$leak"
ck "invalid-token forensic-fetch ⇒ rejected" \
   bash -c 'source "$1"; CO_EXPECTED_TOKEN=expected co_request wrong forensic-fetch b6 >/dev/null 2>&1; [[ $? -ne 0 ]]' _ "$LIB"
ck "no-token forensic-put ⇒ rejected (authed channel only)"   rejected "" forensic-put zz d "$BLOB"
# On-demand only: the blob is a SEPARATE namespace, never auto-surfaced.
co_request "$GOOD" set-desired projF running "agent-1" >/dev/null 2>&1
co_request "$GOOD" put lease projF '{"schema_version":1,"task_ref":"projF"}' >/dev/null 2>&1
poll="$(co_request "$GOOD" poll projF projF 2>/dev/null)"
ck "§2.4 poll output never contains the blob canary"  hasnt "$MARK" "$poll"
ck "§2.4 poll output never contains the blob id b6"   hasnt "b6" "$poll"
# Build a §4.5 work_snapshot + §4.3 Notification — the blob is in NEITHER.
co_request "$GOOD" put work_snapshot snapF '{"schema_version":1,"cards":[]}' >/dev/null 2>&1
co_request "$GOOD" put notification ntfF '{"schema_version":1,"tier":"blocking","dossier_ref":"claude-tools-fff"}' >/dev/null 2>&1
ws="$(co_request "$GOOD" get work_snapshot snapF 2>/dev/null)"
nt="$(co_request "$GOOD" get notification ntfF 2>/dev/null)"
ck "§4.5 work_snapshot body has NO forensic canary"   hasnt "$MARK" "$ws"
ck "§4.3 notification body has NO forensic canary"    hasnt "$MARK" "$nt"
ck "the §4 records/ dir holds NO forensic canary (separate namespace)" \
   bash -c '! grep -rqF "$1" "$2" 2>/dev/null' _ "$MARK" "$CO_STORE/records/"
crossing="$(co_request "$GOOD" forensic-fetch b6 2>/dev/null)"
ck "on-demand fetch still works (the ONLY way the blob crosses)"  has "$MARK" "$crossing"

echo "── EXIT-5: anti-drift — separate scratch object, NOT §4, no re-redaction ──"
fdir="$(co__forensic_dir)"
ck "forensic store dir resolves UNDER machine-scratch CO_STORE (not the repo)" \
   eq "$fdir" "$CO_STORE/forensic"
sv="$(co__schema_version forensic 2>/dev/null || true)"
ck "'forensic' is NOT a §4 record type (absent from co__schema_version)"  zz "$sv"
ck "a forensic blob is NOT reachable via the §4 get path"     rejected "$GOOD" get forensic b6
# Anti-drift, proved BEHAVIOURALLY (a source grep would be defeated by this
# file's own correct anti-drift prose): the §10.2 blob is consumed VERBATIM —
# what was put is byte-identical to what is fetched. If T4.5 re-derived
# redaction (T2/T3's job; raw stream-json never leaves the machine) the
# round-trip would NOT be byte-identical.
co_request "$GOOD" forensic-put bv claude-tools-verbatim "$BLOB" >/dev/null 2>&1
verb="$(co_request "$GOOD" forensic-fetch bv 2>/dev/null)"
ck "§10.2 blob round-trips BYTE-IDENTICAL (stored verbatim, NOT re-derived)" \
   eq "$verb" "$BLOB"
ck "unsafe forensic blob id ('..') rejected at the door"      rejected "$GOOD" forensic-put ".." d "$BLOB"
ck "unsafe forensic blob id ('/') rejected at the door"       rejected "$GOOD" forensic-fetch "../../etc/x"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " test-coordinator-forensic (T4.5, claude-tools-guq):  PASS=$PASS  FAIL=$FAIL"
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
