#!/usr/bin/env bash
# tests/marker-review-seam-ack.test.sh — issue #98: validated marker writers for the remaining close-time
# facts the orchestrator used to HAND-WRITE as raw JSON into .runs/<run>/RUN — review_acks, seam_acks, and
# the pipeline setter. bin/marker.sh owns the shape contract for these exactly as it already does for
# precond.ack / preflight / enforcement (issue #72); this suite proves the new writers through the REAL
# gates that read the fields, not by field-presence alone:
#   review-ack  → check-review-ack.sh  flips block(1) → allow(0)
#   seam-ack    → check-seam-ack.sh    flips block(1) → allow(0)
#   set pipeline→ refuses `auto`/arbitrary, accepts full|mvp|single-thread
# Rejection cases prove a malformed write (a missing required field) is REFUSED with a message NAMING the
# field, and leaves the marker byte-identical (no half-written / forged marker).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$here/bin/delivery-lib.sh"
CLI="$here/bin/marker.sh"
CRA="$here/bin/check-review-ack.sh"
CSA="$here/bin/check-seam-ack.sh"
# shellcheck source=bin/delivery-lib.sh
. "$LIB"

fail=0
_eq() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 — expected [$2], got [$3]" >&2; fail=$((fail + 1)); fi; }
_rc() { if [ "$2" = "$3" ]; then echo "  PASS $1 (rc $3)"; else echo "  FAIL $1 — expected rc $2, got $3" >&2; fail=$((fail + 1)); fi; }
_json() { if printf '%s' "$2" | python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1; then echo "  PASS $1 (valid json)"; else echo "  FAIL $1 — not valid json: [$2]" >&2; fail=$((fail + 1)); fi; }
_has() { if printf '%s' "$3" | grep -qiF "$2"; then echo "  PASS $1 (names '$2')"; else echo "  FAIL $1 — stderr did not name '$2': [$3]" >&2; fail=$((fail + 1)); fi; }

echo "== Group 1: review-ack via CLI — check-review-ack flips 1 → 0 =="
D="$(mktemp -d)"
( cd "$D" && git init -q && git config user.email t@t && git config user.name t
  echo a > f.txt && git add . && git commit -qm c0
  echo b >> f.txt && git add . && git commit -qm c1 ) >/dev/null 2>&1
BASE="$(cd "$D" && git rev-parse --short HEAD~1)"; C1="$(cd "$D" && git rev-parse --short HEAD)"
mkdir -p "$D/.runs/r"
# single-thread: inline reviewers dispatch nothing, so the review_acks artifact alone can flip the gate
# (no full/mvp dispatch corroboration needed) — this isolates the WRITER under test.
printf '%s\n' '{"run":"r","pipeline":"single-thread","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$BASE"'"}' > "$D/.runs/r/RUN"
printf '%s\n' '{"id":"C1","kind":"code","status":"announced"}' > "$D/.runs/r/batches.jsonl"
_rc "check-review-ack BLOCKS (no review_acks)" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CRA" . ) >/dev/null 2>&1; echo $? )"
_rc "marker review-ack" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" review-ack --batch C1 --reviewer code-reviewer --context clean --verdict go --commit "$C1" ) >/dev/null 2>&1; echo $? )"
MKRA="$(cat "$D/.runs/r/RUN")"
_json "marker valid after review-ack" "$MKRA"
if printf '%s' "$MKRA" | grep -qE '"review_acks":\['; then echo "  PASS review_acks array present"; else echo "  FAIL review_acks not written: $MKRA" >&2; fail=$((fail + 1)); fi
_rc "check-review-ack ACCEPTS after ack" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CRA" . ) >/dev/null 2>&1; echo $? )"
# self-review (reviewer == builder) refused
BEFORE_SELF="$(cat "$D/.runs/r/RUN")"
_rc "self-review (reviewer==builder) refused" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" review-ack --batch C1 --reviewer orchestrator --context clean --verdict go --commit "$C1" ) >/dev/null 2>&1; echo $? )"
rm -rf "$D"

echo "== Group 2: malformed review-ack REFUSED, names the missing field, marker byte-identical =="
D="$(mktemp -d)"
( cd "$D" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ) >/dev/null 2>&1
mkdir -p "$D/.runs/r"
BEFORE='{"run":"r","pipeline":"single-thread","intends_code":true,"builder":"orchestrator"}'
printf '%s\n' "$BEFORE" > "$D/.runs/r/RUN"
err="$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" review-ack --batch C1 --reviewer code-reviewer --context clean --verdict go ) 2>&1 1>/dev/null )"; rc=$?
_rc "missing --commit refused" 64 "$rc"
_has "missing --commit names 'commit'" "commit" "$err"
err2="$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" review-ack --reviewer code-reviewer --context clean --verdict go --commit deadbeef ) 2>&1 1>/dev/null )"; rc2=$?
_rc "missing --batch refused" 64 "$rc2"
_has "missing --batch names 'batch'" "batch" "$err2"
# bad verdict vocabulary refused
_rc "bad verdict refused" 64 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" review-ack --batch C1 --reviewer r --context clean --verdict maybe --commit deadbeef ) >/dev/null 2>&1; echo $? )"
_eq "marker unchanged after refusals" "$BEFORE" "$(cat "$D/.runs/r/RUN")"
rm -rf "$D"

echo "== Group 3: seam-ack via CLI — check-seam-ack flips 1 → 0 =="
D="$(mktemp -d)"
( cd "$D" && git init -q && git config user.email t@t && git config user.name t
  echo base > seed && git add . && git commit -qm base ) >/dev/null 2>&1
base="$(cd "$D" && git rev-parse --short HEAD)"
( cd "$D" && mkdir -p src && echo x > src/app.py && git add . && git commit -qm "touch seam" ) >/dev/null 2>&1
code="$(cd "$D" && git rev-parse --short HEAD)"
mkdir -p "$D/.runs/r"
printf '%s\n' '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}' > "$D/.runs/r/batches.jsonl"
SEAM='"high_risk_seams":[{"seam":"marker-rewrite","paths":["src/app.py","src/lib.py"]}]'
printf '%s\n' "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM}" > "$D/.runs/r/RUN"
_rc "check-seam-ack BLOCKS (no seam_acks)" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CSA" . ) >/dev/null 2>&1; echo $? )"
_rc "marker seam-ack" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" seam-ack --seam marker-rewrite --commit "$code" --note "src/app.py:1 read the rewrite" ) >/dev/null 2>&1; echo $? )"
MKSA="$(cat "$D/.runs/r/RUN")"
_json "marker valid after seam-ack" "$MKSA"
# seam THEN commit adjacency is load-bearing for check-seam-ack's _ack_commits parse
if printf '%s' "$MKSA" | grep -qE '"seam":[[:space:]]*"marker-rewrite"[[:space:]]*,[[:space:]]*"commit":'; then echo "  PASS seam_acks seam→commit order emitted"; else echo "  FAIL seam_acks order wrong: $MKSA" >&2; fail=$((fail + 1)); fi
_rc "check-seam-ack ACCEPTS after ack" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CSA" . ) >/dev/null 2>&1; echo $? )"
rm -rf "$D"

echo "== Group 4: malformed seam-ack REFUSED, names the missing field, marker byte-identical =="
D="$(mktemp -d)"
( cd "$D" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ) >/dev/null 2>&1
mkdir -p "$D/.runs/r"
BEFORE='{"run":"r","intends_code":true,"source":"harness"}'
printf '%s\n' "$BEFORE" > "$D/.runs/r/RUN"
err="$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" seam-ack --seam marker-rewrite --commit abc123 ) 2>&1 1>/dev/null )"; rc=$?
_rc "missing --note refused" 64 "$rc"
_has "missing --note names 'note'" "note" "$err"
err2="$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" seam-ack --commit abc123 --note n ) 2>&1 1>/dev/null )"; rc2=$?
_rc "missing --seam refused" 64 "$rc2"
_has "missing --seam names 'seam'" "seam" "$err2"
_eq "marker unchanged after refusals" "$BEFORE" "$(cat "$D/.runs/r/RUN")"
rm -rf "$D"

echo "== Group 5: guarded pipeline setter — refuses auto/arbitrary, accepts the vocabulary =="
D="$(mktemp -d)"
( cd "$D" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ) >/dev/null 2>&1
mkdir -p "$D/.runs/r"
BEFORE='{"run":"r","intends_code":true,"source":"harness"}'
printf '%s\n' "$BEFORE" > "$D/.runs/r/RUN"
_rc "pipeline=auto refused"    64 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" set pipeline auto ) >/dev/null 2>&1; echo $? )"
_rc "pipeline=banana refused"  64 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" set pipeline banana ) >/dev/null 2>&1; echo $? )"
_eq "marker unchanged after refused pipeline" "$BEFORE" "$(cat "$D/.runs/r/RUN")"
_rc "pipeline=full accepted"   0  "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" set pipeline full ) >/dev/null 2>&1; echo $? )"
MKPP="$(cat "$D/.runs/r/RUN")"
_json "marker valid after pipeline set" "$MKPP"
_eq "pipeline recorded full" full "$(field_str "$MKPP" pipeline)"
# replace an existing pipeline value (mvp, single-thread also accepted)
_rc "pipeline=mvp accepted"          0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" set pipeline mvp ) >/dev/null 2>&1; echo $? )"
_eq "pipeline replaced with mvp" mvp "$(field_str "$(cat "$D/.runs/r/RUN")" pipeline)"
_rc "pipeline=single-thread accepted" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" set pipeline single-thread ) >/dev/null 2>&1; echo $? )"
_eq "pipeline replaced with single-thread" single-thread "$(field_str "$(cat "$D/.runs/r/RUN")" pipeline)"
rm -rf "$D"

if [ "$fail" -eq 0 ]; then echo "marker-review-seam-ack.test.sh: OK"; exit 0; fi
echo "marker-review-seam-ack.test.sh: $fail assertion(s) FAILED" >&2; exit 1
