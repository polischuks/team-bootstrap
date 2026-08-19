#!/usr/bin/env bash
# tests/preflight-setup.test.sh — B1 substrate for the Phase-0 preflight/setup gate.
#
# Exercises the delivery-lib.sh marker helpers this milestone adds/hardens (delivery-lib.sh is SOURCED,
# has no --self-test of its own, so its behavior is tested here — the established tests/<milestone>.test.sh
# locus, cf. tests/check-seam-ack.test.sh). AC references carried for check-completeness --final:
#   AC-4 (record_preflight write), AC-6/AC-8 (field_in_obj object-scoped read), drift-#2 (read + WRITE).
#
# The load-bearing case is the WRITE-COEXISTENCE regression: record_precond's historical greedy
# end-anchored strip silently deleted any object written after `precond`. record_preflight appends
# `preflight` AFTER `precond`, so an unfixed record_precond wipes the Phase-0 verdict on every normal run
# (self-disarm, P10). The fix is a position-independent _marker_strip_obj_key adopted by BOTH record_*;
# this test proves `preflight` SURVIVES a subsequent record_precond (incl. a `}`-in-gaps variant) and that
# a lone-`precond` round-trip is byte-identical (behavior-preserving for the live deliverability path).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/bin/delivery-lib.sh"

fail=0
_eq() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then echo "  PASS $1"; else
    echo "  FAIL $1 — expected [$2], got [$3]" >&2; fail=$((fail + 1)); fi
}
_valid_json() { # LABEL STRING  (single top-level {…} object, brace-balanced, via python)
  if printf '%s' "$2" | python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1; then
    echo "  PASS $1 (valid json)"; else echo "  FAIL $1 — not valid json: [$2]" >&2; fail=$((fail + 1)); fi
}

# ---------------------------------------------------------------------------------------------------
# Group 1 — field_in_obj: object-scoped scalar read (collision-safe; drift-#2 read side)
# ---------------------------------------------------------------------------------------------------
MK_PC_FIRST='{"run":"r","precond":{"exit":2,"items":[],"ack":true},"preflight":{"exit":1,"gaps":["x"],"ack":false}}'
MK_PF_FIRST='{"run":"r","preflight":{"exit":1,"gaps":["x"],"ack":false},"precond":{"exit":2,"items":[],"ack":true}}'

_eq "field_in_obj precond.exit (precond first)"   2     "$(field_in_obj "$MK_PC_FIRST" precond exit)"
_eq "field_in_obj precond.ack  (precond first)"   true  "$(field_in_obj "$MK_PC_FIRST" precond ack)"
_eq "field_in_obj preflight.exit (precond first)" 1     "$(field_in_obj "$MK_PC_FIRST" preflight exit)"
_eq "field_in_obj preflight.ack  (precond first)" false "$(field_in_obj "$MK_PC_FIRST" preflight ack)"
# order-independence: same per-object answers with preflight written first
_eq "field_in_obj precond.exit (preflight first)"   2     "$(field_in_obj "$MK_PF_FIRST" precond exit)"
_eq "field_in_obj preflight.exit (preflight first)" 1     "$(field_in_obj "$MK_PF_FIRST" preflight exit)"
_eq "field_in_obj preflight.ack (preflight first)"  false "$(field_in_obj "$MK_PF_FIRST" preflight ack)"
# absent object → empty (no false match on the other object's key)
_eq "field_in_obj absent object → empty" "" "$(field_in_obj '{"run":"r","precond":{"exit":0,"ack":false}}' preflight exit)"
# robustness: a gaps string containing '}' and the literal exit/ack must NOT confuse the brace-close
MK_BRACE='{"run":"r","preflight":{"exit":1,"gaps":["a}b exit ack"],"ack":false},"precond":{"exit":2,"items":[],"ack":true}}'
_eq "field_in_obj preflight.exit with '}' in gaps" 1    "$(field_in_obj "$MK_BRACE" preflight exit)"
_eq "field_in_obj precond.exit after '}' object"   2    "$(field_in_obj "$MK_BRACE" precond exit)"

# ---------------------------------------------------------------------------------------------------
# Group 2 — _marker_strip_obj_key: position-independent object strip (drift-#2 write side)
# ---------------------------------------------------------------------------------------------------
_eq "strip precond → preflight survives" \
  '{"run":"r","preflight":{"exit":1,"gaps":["x"],"ack":false}}' \
  "$(_marker_strip_obj_key "$MK_PC_FIRST" precond)"
_eq "strip preflight → precond survives" \
  '{"run":"r","precond":{"exit":2,"items":[],"ack":true}}' \
  "$(_marker_strip_obj_key "$MK_PC_FIRST" preflight)"
# position independence: object in the MIDDLE is removed cleanly (no ',,' / '{,' / ',}')
MK_MID='{"a":1,"precond":{"exit":0,"items":[],"ack":false},"b":2}'
_eq "strip middle object clean" '{"a":1,"b":2}' "$(_marker_strip_obj_key "$MK_MID" precond)"
_valid_json "strip middle object valid" "$(_marker_strip_obj_key "$MK_MID" precond)"
# absent key → unchanged
_eq "strip absent key → unchanged" "$MK_MID" "$(_marker_strip_obj_key "$MK_MID" preflight)"
# '}' inside a gaps string must not truncate the strip early
_eq "strip preflight with '}' in gaps → precond survives whole" \
  '{"run":"r","precond":{"exit":2,"items":[],"ack":true}}' \
  "$(_marker_strip_obj_key "$MK_BRACE" preflight)"

# ---------------------------------------------------------------------------------------------------
# Group 3 — record_preflight + record_precond coexistence (needs an active marker) — the WRITE regression
# ---------------------------------------------------------------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.runs/_st_pf"
printf '%s\n' '{"run":"_st_pf","intends_code":true,"baseline_sha":"abc1234","precond":{"exit":0,"items":[],"ack":false}}' > "$tmp/.runs/_st_pf/RUN"
(
  cd "$tmp" || exit 1
  export TEAM_BOOTSTRAP_RUN=_st_pf
  # a) record a Phase-0 verdict → both objects present, preflight.exit == 0
  record_preflight 0 '[]'
  mk="$(cat .runs/_st_pf/RUN)"
  [ "$(field_in_obj "$mk" preflight exit)" = "0" ] || { echo "  FAIL record_preflight did not write preflight.exit=0" >&2; exit 3; }
  [ "$(field_in_obj "$mk" precond  exit)" = "0" ] || { echo "  FAIL record_preflight clobbered precond" >&2; exit 3; }
  # b) THE REGRESSION: a subsequent record_precond must NOT delete the trailing preflight
  record_precond 2 '"branch x not on origin"'
  mk="$(cat .runs/_st_pf/RUN)"
  [ "$(field_in_obj "$mk" precond  exit)" = "2" ] || { echo "  FAIL record_precond did not set precond.exit=2" >&2; exit 3; }
  [ "$(field_in_obj "$mk" preflight exit)" = "0" ] || { echo "  FAIL SELF-DISARM: record_precond wiped preflight (the blocking bug)" >&2; exit 3; }
  # c) '}'-in-gaps variant survives a record_precond too (write-path brace-close)
  record_preflight 1 '["needs setup } really"]'
  record_precond 0 ''
  mk="$(cat .runs/_st_pf/RUN)"
  [ "$(field_in_obj "$mk" preflight exit)" = "1" ] || { echo "  FAIL preflight with '}' in gaps did not survive record_precond" >&2; exit 3; }
  # d) ack preservation across a re-run
  printf '%s\n' '{"run":"_st_pf","intends_code":true,"baseline_sha":"abc1234","precond":{"exit":0,"items":[],"ack":false},"preflight":{"exit":1,"gaps":[],"ack":true}}' > .runs/_st_pf/RUN
  record_preflight 1 '["still broken"]'
  mk="$(cat .runs/_st_pf/RUN)"
  [ "$(field_in_obj "$mk" preflight ack)" = "true" ] || { echo "  FAIL record_preflight did not preserve ack:true" >&2; exit 3; }
  echo "  PASS write-coexistence (preflight survives record_precond; '}'-in-gaps; ack preserved)"
) || fail=$((fail + 1))

# e) lone-precond round-trip is byte-identical to the historical behavior (behavior-preserving)
tmp2="$(mktemp -d)"; mkdir -p "$tmp2/.runs/_st_lone"
printf '%s\n' '{"run":"_st_lone","intends_code":true,"baseline_sha":"abc1234","precond":{"exit":0,"items":[],"ack":false}}' > "$tmp2/.runs/_st_lone/RUN"
(
  cd "$tmp2" || exit 1
  export TEAM_BOOTSTRAP_RUN=_st_lone
  record_precond 2 '"adv"'
  got="$(cat .runs/_st_lone/RUN)"
  want='{"run":"_st_lone","intends_code":true,"baseline_sha":"abc1234","precond":{"exit":2,"items":["adv"],"ack":false}}'
  [ "$got" = "$want" ] || { echo "  FAIL lone-precond not byte-identical — got [$got]" >&2; exit 3; }
  echo "  PASS lone-precond round-trip byte-identical"
) || fail=$((fail + 1))
rm -rf "$tmp2"

# ---------------------------------------------------------------------------------------------------
# Group 4 — check-preflight.sh detector (B2): its authoritative --self-test + black-box E2E (AC-1/2/9)
# ---------------------------------------------------------------------------------------------------
gate="$here/bin/check-preflight.sh"
if [ ! -x "$gate" ]; then
  echo "  FAIL check-preflight.sh missing/not executable" >&2; fail=$((fail + 1))
else
  if "$gate" --self-test >/dev/null 2>&1; then echo "  PASS check-preflight --self-test"; else
    echo "  FAIL check-preflight --self-test" >&2; fail=$((fail + 1)); fi
  # E2E (AC-9): this repo's COMMITTED scaffold (constitution, specs/, feature.json, docs/adr/, AGENTS.md)
  # is complete; the only variable is an *active* run marker (gitignored, present only during a delivery).
  # Assert hermetically: either setup-ready (marker present → exit 0), OR the sole HARD gap is the run
  # marker (fresh clone / CI). A real scaffold regression (e.g. docs/adr removed) still fails.
  out="$("$gate" "$here" 2>&1)"; rc=$?
  hard="$(printf '%s\n' "$out" | grep -c 'HARD')"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS E2E: setup-ready on this repo (active marker, exit 0)"
  elif printf '%s\n' "$out" | grep -q "no run marker" && [ "$hard" -eq 1 ]; then
    echo "  PASS E2E: this repo's committed scaffold is complete (only gap is the transient run marker)"
  else
    echo "  FAIL E2E: check-preflight found scaffold gap(s) on this repo beyond the run marker (rc=$rc, hard=$hard)" >&2; fail=$((fail + 1)); fi
  # E2E (AC-9): a bare git repo → exit 1 with >=4 named gaps
  bt="$(mktemp -d)"; git -C "$bt" init -q >/dev/null 2>&1
  out="$("$gate" "$bt" 2>&1)"; rc=$?
  gaps="$(printf '%s\n' "$out" | grep -c 'HARD')"
  if [ "$rc" -eq 1 ] && [ "$gaps" -ge 4 ]; then echo "  PASS E2E: fail-closed on bare dir (exit 1, $gaps hard gaps)"; else
    echo "  FAIL E2E: bare dir expected exit 1 with >=4 HARD gaps, got rc=$rc gaps=$gaps" >&2; fail=$((fail + 1)); fi
  rm -rf "$bt"
fi

# ---------------------------------------------------------------------------------------------------
# Group 5 — check-delivery.sh Phase-0 (preflight) enforcement (B3): black-box, in the recognized test
# path. A code-delivering run must have passed Phase 0 or acked a gap (AC-6/AC-7); absent or unreadable
# verdict fail-closes (P10); acked failing verdict is allowed.
# ---------------------------------------------------------------------------------------------------
cd="$here/bin/check-delivery.sh"
_pf_case() { # LABEL RUN_JSON WANT_RC
  local label="$1" runjson="$2" want="$3" d rc
  d="$(mktemp -d)"; mkdir -p "$d/.runs/r"
  printf '%s\n' "$runjson" > "$d/.runs/r/RUN"
  printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$d/.runs/r/batches.jsonl"
  ( cd "$d" && TEAM_BOOTSTRAP_RUN=r "$cd" "$d" ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$want" ]; then echo "  PASS $label"; else
    echo "  FAIL $label — want rc=$want got $rc" >&2; fail=$((fail + 1)); fi
  rm -rf "$d"
}
_pf_case "B3 absent preflight + code batch → blocked (P10 not-run)" \
  '{"run":"r","intends_code":true,"source":"harness"}' 1
_pf_case "B3 failing preflight (exit=1) unacked + code batch → blocked" \
  '{"run":"r","intends_code":true,"source":"harness","preflight":{"exit":1,"gaps":["missing: feature.json"],"ack":false}}' 1
_pf_case "B3 failing preflight ACKED + code batch → allowed" \
  '{"run":"r","intends_code":true,"source":"harness","preflight":{"exit":1,"gaps":["x"],"ack":true}}' 0
_pf_case "B3 present-but-no-exit preflight → blocked (not fail-open)" \
  '{"run":"r","intends_code":true,"source":"harness","preflight":{"gaps":[],"ack":false}}' 1
_pf_case "B3 passing preflight (exit=0) + code batch → allowed" \
  '{"run":"r","intends_code":true,"source":"harness","preflight":{"exit":0,"gaps":[],"ack":false}}' 0

# ---------------------------------------------------------------------------------------------------
# Group 6 — orchestration wiring (B4): the Phase-0 gate must have a CONSUMER, or it is an orphan gate.
# deliver.md must invoke check-preflight at a Phase 0 before Phase A; AGENTS.md must note it.
# ---------------------------------------------------------------------------------------------------
dm="$here/commands/deliver.md"
if grep -q "check-preflight" "$dm" 2>/dev/null; then echo "  PASS deliver.md invokes check-preflight (gate has a consumer)"; else
  echo "  FAIL deliver.md does not invoke check-preflight — Phase-0 gate is an orphan" >&2; fail=$((fail + 1)); fi
if grep -qi "Phase 0" "$dm" 2>/dev/null; then echo "  PASS deliver.md has a Phase 0 section"; else
  echo "  FAIL deliver.md has no Phase 0 section" >&2; fail=$((fail + 1)); fi
if grep -q "check-preflight" "$here/AGENTS.md" 2>/dev/null; then echo "  PASS AGENTS.md notes the Phase-0 gate"; else
  echo "  FAIL AGENTS.md does not note check-preflight" >&2; fail=$((fail + 1)); fi

[ "$fail" -eq 0 ] && { echo "preflight-setup.test.sh: OK"; exit 0; }
echo "preflight-setup.test.sh: $fail failure(s)" >&2; exit 1
