#!/usr/bin/env bash
# tests/marker-cli.test.sh — issue #72: the sanctioned marker-edit CLI (bin/marker.sh).
#
# Recording an ack or waiver used to require hand-editing the machine-owned .runs/<run>/RUN JSON against
# an unstated shape contract; a malformed hand-edit fails silently or cascades. bin/marker.sh is the
# single owner of that contract: it writes the correct shape through the existing delivery-lib marker
# helpers and validates the result still parses.
#
# The load-bearing assertions are GATE-ACCEPTANCE, not field-presence: each writer is driven through the
# CLI and then the REAL gate that reads the field is run and must FLIP from block(1) to allow(0) —
#   precond.ack        → check-delivery.sh   (1 → 0)
#   preflight waiver   → check-delivery.sh   (1 → 0)
#   enforcement waiver → check-enforcement.sh(1 → 0)
# gate_integrity_waiver / role_verdict_waiver route to the already-proven record_governed_waiver, so they
# are checked against the VERBATIM predicate their gates decide on (governed_waiver_ok over field_in_obj,
# from check-gate-integrity.sh:468 / check-role-verdict.sh:230). Rejection cases prove a malformed input
# (non-date expires, empty reason, bad category, non-bool) is REFUSED and leaves the marker byte-identical.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$here/bin/delivery-lib.sh"
CLI="$here/bin/marker.sh"
CD="$here/bin/check-delivery.sh"
CE="$here/bin/check-enforcement.sh"
# shellcheck source=bin/delivery-lib.sh
. "$LIB"

fail=0
_eq() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 — expected [$2], got [$3]" >&2; fail=$((fail + 1)); fi; }
_rc() { if [ "$2" = "$3" ]; then echo "  PASS $1 (rc $3)"; else echo "  FAIL $1 — expected rc $2, got $3" >&2; fail=$((fail + 1)); fi; }
_json() { if printf '%s' "$2" | python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1; then echo "  PASS $1 (valid json)"; else echo "  FAIL $1 — not valid json: [$2]" >&2; fail=$((fail + 1)); fi; }
_newrepo() { # → temp dir with a git repo + .runs/r/
  local d; d="$(mktemp -d)"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ) >/dev/null 2>&1
  mkdir -p "$d/.runs/r"; printf '%s' "$d"
}

echo "== Group 1: _json_scalar_set (core scalar splicer) =="
_eq "replace bool"            '{"a":1,"ack":true}'        "$(_json_scalar_set '{"a":1,"ack":false}' ack true)"
_eq "replace string"          '{"by":"new","x":1}'        "$(_json_scalar_set '{"by":"old","x":1}' by '"new"')"
_eq "insert into non-empty"   '{"a":1,"ack":true}'        "$(_json_scalar_set '{"a":1}' ack true)"
_eq "insert into empty obj"   '{"ack":true}'              "$(_json_scalar_set '{}' ack true)"
_eq "spaced replace normalises" '{ "x": 1, "ack":true}'   "$(_json_scalar_set '{ "x": 1, "ack": false }' ack true)"
# prefix-collision: setting enforcement_ack must not touch enforcement_ack_by
_eq "prefix collision safe" \
  '{"enforcement_ack":true,"enforcement_ack_by":"f"}' \
  "$(_json_scalar_set '{"enforcement_ack":false,"enforcement_ack_by":"f"}' enforcement_ack true)"

echo "== Group 2: _marker_set_obj_scalar (nested, array-preserving) =="
MK='{"run":"r","precond":{"exit":2,"items":["a]b"],"ack":false},"preflight":{"exit":0,"gaps":[],"ack":false}}'
OUT="$(_marker_set_obj_scalar "$MK" precond ack true)"
_json "nested set stays valid" "$OUT"
_eq  "precond.ack flipped"        true  "$(field_in_obj "$OUT" precond ack)"
_eq  "preflight.ack untouched"    false "$(field_in_obj "$OUT" preflight ack)"
if printf '%s' "$OUT" | grep -qF '"items":["a]b"]'; then echo "  PASS items array preserved verbatim"; else echo "  FAIL items array mangled: $OUT" >&2; fail=$((fail + 1)); fi
_rc "absent object → rc1" 1 "$( _marker_set_obj_scalar '{"run":"r"}' precond ack true >/dev/null 2>&1; echo $? )"

echo "== Group 3: precond.ack via CLI — check-delivery flips 1 → 0 =="
D="$(_newrepo)"
printf '%s\n' '{"run":"r","intends_code":true,"source":"harness","precond":{"exit":2,"items":[],"ack":false},"preflight":{"exit":0,"gaps":[],"ack":false}}' > "$D/.runs/r/RUN"
printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$D/.runs/r/batches.jsonl"
_rc "check-delivery BLOCKS unacked advisory" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CD" . ) >/dev/null 2>&1; echo $? )"
_rc "marker set precond.ack true"            0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" set precond.ack true ) >/dev/null 2>&1; echo $? )"
_eq "precond.ack recorded true" true "$(field_in_obj "$(cat "$D/.runs/r/RUN")" precond ack)"
_json "marker valid after set" "$(cat "$D/.runs/r/RUN")"
_rc "check-delivery ACCEPTS after ack"       0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CD" . ) >/dev/null 2>&1; echo $? )"
rm -rf "$D"

echo "== Group 4: preflight waiver via CLI — check-delivery flips 1 → 0 =="
D="$(_newrepo)"
printf '%s\n' '{"run":"r","intends_code":true,"source":"harness","preflight":{"exit":1,"gaps":["missing: feature.json"],"ack":false}}' > "$D/.runs/r/RUN"
printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$D/.runs/r/batches.jsonl"
_rc "check-delivery BLOCKS failing preflight" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CD" . ) >/dev/null 2>&1; echo $? )"
_rc "marker waive preflight"                  0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" waive preflight founder "scaffold gap" 2999-01-01 ) >/dev/null 2>&1; echo $? )"
MKPF="$(cat "$D/.runs/r/RUN")"
_eq "preflight.ack true"    true       "$(field_in_obj "$MKPF" preflight ack)"
_eq "preflight.by"          founder    "$(field_in_obj "$MKPF" preflight by)"
_eq "preflight.expires"     2999-01-01 "$(field_in_obj "$MKPF" preflight expires)"
_eq "preflight.exit preserved" 1       "$(field_in_obj "$MKPF" preflight exit)"
_json "marker valid after waive" "$MKPF"
_rc "check-delivery ACCEPTS waived preflight" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CD" . ) >/dev/null 2>&1; echo $? )"
rm -rf "$D"

echo "== Group 5: enforcement waiver via CLI — check-enforcement flips 1 → 0 =="
D="$(_newrepo)"   # no AGENTS.md ⇒ all three dimensions gapped; no seams/rank ⇒ host_structural is exempt
printf '%s\n' '{"run":"r","intends_code":true,"source":"harness"}' > "$D/.runs/r/RUN"
_rc "check-enforcement BLOCKS unwaived gaps" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CE" . ) >/dev/null 2>&1; echo $? )"
_rc "marker waive enforcement host_structural" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" waive enforcement founder "no cov/mut tool on host" 2999-01-01 host_structural ) >/dev/null 2>&1; echo $? )"
MKEN="$(cat "$D/.runs/r/RUN")"
_eq "enforcement_ack true"          true            "$(field_bool "$MKEN" enforcement_ack)"
_eq "enforcement_ack_category"      host_structural "$(field_str "$MKEN" enforcement_ack_category)"
_eq "enforcement_ack_by"            founder         "$(field_str "$MKEN" enforcement_ack_by)"
_json "marker valid after enforcement waive" "$MKEN"
_rc "check-enforcement ACCEPTS host_structural waiver" 0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CE" . ) >/dev/null 2>&1; echo $? )"
_rc "bad category refused" 1 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" waive enforcement founder why 2999-01-01 bogus ) >/dev/null 2>&1; echo $? )"
rm -rf "$D"

echo "== Group 6: gate_integrity_waiver / role_verdict_waiver via CLI — gate reader accepts =="
_gate_accepts() { # MK KEY → rc of the verbatim gate predicate (governed_waiver_ok over field_in_obj)
  local mk="$1" key="$2"
  governed_waiver_ok "$(field_in_obj "$mk" "$key" ack)" "$(field_in_obj "$mk" "$key" by)" \
                     "$(field_in_obj "$mk" "$key" reason)" "$(field_in_obj "$mk" "$key" expires)"
}
for target in "gate-integrity:gate_integrity_waiver" "role-verdict:role_verdict_waiver"; do
  sub="${target%%:*}"; key="${target#*:}"
  D="$(_newrepo)"
  printf '%s\n' '{"run":"r","intends_code":true,"source":"harness"}' > "$D/.runs/r/RUN"
  _rc "gate reader REJECTS before $sub waive" 1 "$( _gate_accepts "$(cat "$D/.runs/r/RUN")" "$key"; echo $? )"
  _rc "marker waive $sub"                     0 "$( ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" waive "$sub" founder "governed reason" 2999-01-01 ) >/dev/null 2>&1; echo $? )"
  MK6="$(cat "$D/.runs/r/RUN")"
  _json "marker valid after $sub waive" "$MK6"
  _rc "gate reader ACCEPTS after $sub waive"  0 "$( _gate_accepts "$MK6" "$key"; echo $? )"
  rm -rf "$D"
done

echo "== Group 7: malformed input REFUSED, marker byte-identical =="
D="$(_newrepo)"
BEFORE='{"run":"r","intends_code":true,"source":"harness"}'
printf '%s\n' "$BEFORE" > "$D/.runs/r/RUN"
_run() { ( cd "$D" && TEAM_BOOTSTRAP_RUN=r bash "$CLI" "$@" ) >/dev/null 2>&1; echo $?; }
_rc "expired expires refused"  1  "$(_run waive role-verdict who why 2000-01-01)"
_rc "non-date expires refused" 1  "$(_run waive role-verdict who why not-a-date)"
_rc "empty reason refused"     1  "$(_run waive role-verdict who '' 2999-01-01)"
_rc "wrong arity refused"      64 "$(_run waive role-verdict who why)"
_rc "non-bool ack refused"     64 "$(_run set precond.ack maybe)"
_rc "unknown subcommand"       64 "$(_run frobnicate)"
_rc "unknown waive target"     64 "$(_run waive nonexistent who why 2999-01-01)"
_eq "marker unchanged after all refusals" "$BEFORE" "$(cat "$D/.runs/r/RUN")"
rm -rf "$D"

if [ "$fail" -eq 0 ]; then echo "marker-cli.test.sh: OK"; exit 0; fi
echo "marker-cli.test.sh: $fail assertion(s) FAILED" >&2; exit 1
