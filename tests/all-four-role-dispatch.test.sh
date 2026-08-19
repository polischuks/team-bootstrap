#!/usr/bin/env bash
# all-four-role-dispatch.test.sh — Batch A: per-role attribution primitives.
# Exercises delivery-lib's role_of_slug / mandated_roles / roles_covered + the column-1 parser
# change (a tab-bearing dedicated slug records via is_review_type). Milestone all-four-role-dispatch.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/../bin/delivery-lib.sh"

fail=0
_chk() { # _chk GOT WANT MSG
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got '[$1]' want '[$2]')" >&2; fail=$((fail + 1)); fi
}

echo "role_of_slug — dedicated slugs attribute, generics do not:"
_chk "$(role_of_slug integration-verifier)"              "integration-verifier"  "bare integration-verifier → role"
_chk "$(role_of_slug team-bootstrap:integration-verifier)" "integration-verifier" "prefixed integration-verifier → role"
_chk "$(role_of_slug architecture-reviewer)"             "architecture-reviewer" "architecture-reviewer → role"
_chk "$(role_of_slug regression-guardian)"               "regression-guardian"   "regression-guardian → role"
_chk "$(role_of_slug tb-code-reviewer)"                  "code-reviewer"         "tb-code-reviewer → code-reviewer role (collision-free, B2)"
_chk "$(role_of_slug code-reviewer)"                     ""                      "bare host code-reviewer → NO role (generic, AC-10)"
_chk "$(role_of_slug independent-reviewer)"              ""                      "independent-reviewer → NO role (generic, B4)"
_chk "$(role_of_slug backend-developer)"                 ""                      "builder → NO role"
_chk "$(role_of_slug '')"                                ""                      "empty slug → empty"

echo "is_review_type — the tab-bearing dedicated slug still RECORDS (column-1 parse, B1 DOA fix):"
is_review_type tb-code-reviewer          && echo "  PASS tb-code-reviewer is a review type (recorded)" || { echo "  FAIL tb-code-reviewer not recorded — DOA" >&2; fail=$((fail + 1)); }
is_review_type integration-verifier      && echo "  PASS integration-verifier is a review type" || { echo "  FAIL integration-verifier not recorded" >&2; fail=$((fail + 1)); }
is_review_type code-reviewer             && echo "  PASS host code-reviewer still a review type (inherited)" || { echo "  FAIL code-reviewer regressed" >&2; fail=$((fail + 1)); }
is_review_type backend-developer         && { echo "  FAIL builder counted as review type" >&2; fail=$((fail + 1)); } || echo "  PASS backend-developer NOT a review type"

echo "mandated_roles — full=4, mvp=subset, else empty:"
_chk "$(mandated_roles full)"  "integration-verifier architecture-reviewer regression-guardian code-reviewer" "full → all four"
_chk "$(mandated_roles mvp)"   "code-reviewer regression-guardian"  "mvp → subset"
_chk "$(mandated_roles single-thread)" "" "single-thread → empty"
_chk "$(mandated_roles '')"    ""  "empty pipeline → empty"

echo "roles_covered — distinct attributed roles for a batch, generics/empty dropped:"
T="$(mktemp -d)"; mkdir -p "$T/.runs/tr"
printf '{"run":"tr","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/tr/RUN"
# four distinct dedicated dispatches + one builder + one generic → covers all four roles, builder/generic dropped
{
  printf '{"batch":"A","subagent_type":"tb-code-reviewer"}\n'
  printf '{"batch":"A","subagent_type":"integration-verifier"}\n'
  printf '{"batch":"A","subagent_type":"team-bootstrap:architecture-reviewer"}\n'
  printf '{"batch":"A","subagent_type":"regression-guardian"}\n'
  printf '{"batch":"A","subagent_type":"backend-developer"}\n'
  printf '{"batch":"A","subagent_type":"code-reviewer"}\n'
  printf '{"batch":"B","subagent_type":"integration-verifier"}\n'
} > "$T/.runs/tr/dispatch.jsonl"
covered="$( cd "$T" && TEAM_BOOTSTRAP_RUN=tr bash -c '. "'"$here"'/../bin/delivery-lib.sh"; roles_covered A' )"
# order-independent check: all four present, nothing else
miss=0; for r in integration-verifier architecture-reviewer regression-guardian code-reviewer; do
  case " $covered " in *" $r "*) ;; *) miss=1 ;; esac; done
[ "$miss" = 0 ] && echo "  PASS roles_covered A → all four roles" || { echo "  FAIL roles_covered A missing a role (got '$covered')" >&2; fail=$((fail + 1)); }
# 4× one role → just that role (AC-4 substrate)
printf '{"batch":"C","subagent_type":"tb-code-reviewer"}\n%.0s' 1 2 3 4 >> "$T/.runs/tr/dispatch.jsonl"
c4="$( cd "$T" && TEAM_BOOTSTRAP_RUN=tr bash -c '. "'"$here"'/../bin/delivery-lib.sh"; roles_covered C' )"
_chk "$c4" "code-reviewer" "4× tb-code-reviewer → {code-reviewer} only (not a bare count)"
rm -rf "$T"

echo "role_floor_mode (Batch B) — FLOOR override > committed marker presence:"
B="$(mktemp -d)"
unset TEAM_BOOTSTRAP_ROLE_FLOOR; export TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER="$B/enforce"; rm -f "$B/enforce"
_chk "$(role_floor_mode)"                                  "warn"    "no marker → warn"
touch "$B/enforce"
_chk "$(role_floor_mode)"                                  "enforce" "marker present → enforce"
_chk "$(TEAM_BOOTSTRAP_ROLE_FLOOR=warn role_floor_mode)"   "warn"    "FLOOR=warn beats marker-present"
rm -f "$B/enforce"
_chk "$(TEAM_BOOTSTRAP_ROLE_FLOOR=enforce role_floor_mode)" "enforce" "FLOOR=enforce beats marker-absent"

echo "missing_roles (Batch B) — mandated − covered:"
mkdir -p "$B/.runs/br"
printf '{"run":"br","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$B/.runs/br/RUN"
{ printf '{"batch":"B1","subagent_type":"integration-verifier"}\n'
  printf '{"batch":"B1","subagent_type":"architecture-reviewer"}\n'
  printf '{"batch":"B1","subagent_type":"regression-guardian"}\n'
  printf '{"batch":"B1","subagent_type":"tb-code-reviewer"}\n'
  printf '{"batch":"B2","subagent_type":"tb-code-reviewer"}\n'; } > "$B/.runs/br/dispatch.jsonl"
m_all="$( cd "$B" && TEAM_BOOTSTRAP_RUN=br bash -c '. "'"$here"'/../bin/delivery-lib.sh"; missing_roles full B1' )"
_chk "$m_all" "" "full, all four covered → nothing missing"
m_one="$( cd "$B" && TEAM_BOOTSTRAP_RUN=br bash -c '. "'"$here"'/../bin/delivery-lib.sh"; missing_roles full B2 | grep -c integration-verifier' )"
_chk "$m_one" "1" "full, only code role covered → integration-verifier is missing"
m_mvp="$( cd "$B" && TEAM_BOOTSTRAP_RUN=br bash -c '. "'"$here"'/../bin/delivery-lib.sh"; missing_roles mvp B2' )"
_chk "$m_mvp" "regression-guardian" "mvp, only code role covered → regression-guardian missing"
rm -rf "$B"

if [ "$fail" -eq 0 ]; then echo "all-four-role-dispatch.test.sh: OK"; exit 0; fi
echo "all-four-role-dispatch.test.sh: $fail case(s) FAILED" >&2; exit 1
