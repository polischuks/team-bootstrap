#!/usr/bin/env bash
# reviewer-set-single-source.test.sh — issue #70: the required-reviewer set check-review-ack ENFORCES at
# close must be the SAME set check-role-dispatch reports/accepts. They used to size the panel independently:
# check-role-dispatch read the diff-sized set (required_roles_recorded / required_roles_for_batch) while
# check-review-ack fell back to the blanket mandated_roles(pipeline). In verify-batch, check-review-ack runs
# BEFORE record_required_roles and check-role-dispatch runs AFTER — so on the same batch+diff review-ack
# enforced the full panel and failed while role-dispatch accepted the sized subset and passed. A batch then
# failed review-ack for a role the sizing said it did not need, after the whole gate cascade had already run.
#
# This test pins the single source: for one batch+diff, the set both gates enforce is required_review_roles,
# so covering exactly that set satisfies BOTH gates — and review-ack never demands a role role-dispatch
# didn't report.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/../bin"
fail=0
_chk() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (got exit $2 want $3)" >&2; fail=$((fail + 1)); fi; }

T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  printf 'base\n' > f && git add . && git commit -qm base ) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
( cd "$T" && printf 'x\n' >> f && git add . && git commit -qm b1 ) >/dev/null 2>&1
c1="$(cd "$T" && git rev-parse --short HEAD)"
export TEAM_BOOTSTRAP_RUN=r
# enforce mode via a TEMP marker — never touch the shipped references/role-dispatch-enforce (R4-1).
export TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER="$T/enforce"; : > "$T/enforce"

# full run, small batch: required_roles_for_batch sizes it BELOW the full blanket panel.
AOK='"review_acks":[{"batch":"B1","reviewer":"code-reviewer","context":"clean","commit":"'"$c1"'","verdict":"go"}]'
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","builder":"orchestrator","baseline_sha":"%s",%s}\n' "$base" "$AOK" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced","commit_shas":["%s"]}\n' "$c1" > "$T/.runs/r/batches.jsonl"

# The set the sizing (announce hook check-review-batch + record_required_roles) computes for this batch.
sized="$( cd "$T" && bash -c '. "'"$BIN"'/delivery-lib.sh"; required_roles_for_batch B1' )"
echo "sized required_roles_for_batch(B1) = [$sized]  (blanket mandated_roles(full)=[integration-verifier architecture-reviewer regression-guardian code-reviewer])"
# Sanity: the sized set must be a PROPER SUBSET of the blanket panel, else there is no divergence to prove.
case " $sized " in *" integration-verifier "*|*" architecture-reviewer "*|*" regression-guardian "*)
  echo "  FAIL fixture: sized set is not below the full panel (got [$sized]) — cannot exercise #70" >&2; fail=$((fail + 1)) ;;
esac

# Dispatch EXACTLY the roles the sizing says this batch needs (nothing from the blanket-only remainder).
: > "$T/.runs/r/dispatch.jsonl"
for role in $sized; do
  case "$role" in
    code-reviewer) slug=tb-code-reviewer ;;   # bare code-reviewer is a generic; tb-code-reviewer attributes
    *)             slug="$role" ;;
  esac
  printf '{"batch":"B1","subagent_type":"%s"}\n' "$slug" >> "$T/.runs/r/dispatch.jsonl"
done

# --- verify-batch order: check-review-ack runs BEFORE record_required_roles (recorded ABSENT here) -------
ra_before="$( cd "$T" && "$BIN/check-review-ack.sh" . >/dev/null 2>&1; echo $? )"
_chk "check-review-ack (recorded absent, its real window) accepts the sized set" "$ra_before" 0

# --- record_required_roles, then check-role-dispatch runs (recorded PRESENT) ----------------------------
( cd "$T" && bash -c '. "'"$BIN"'/delivery-lib.sh"; record_required_roles B1' )
rd_after="$( cd "$T" && "$BIN/check-role-dispatch.sh" . >/dev/null 2>&1; echo $? )"
_chk "check-role-dispatch (recorded present) accepts the sized set" "$rd_after" 0

# The core invariant: a batch that satisfies role-dispatch also satisfies review-ack, in BOTH windows.
ra_after="$( cd "$T" && "$BIN/check-review-ack.sh" . >/dev/null 2>&1; echo $? )"
_chk "check-review-ack (recorded present) still accepts the sized set" "$ra_after" 0

# And the single-source helper the gates read agrees with the announce-time sizing.
rrr="$( cd "$T" && bash -c '. "'"$BIN"'/delivery-lib.sh"; required_review_roles B1' )"
_chk "required_review_roles(B1) == sized announce set" "$rrr" "$sized"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "reviewer-set-single-source.test.sh: OK"; exit 0; fi
echo "reviewer-set-single-source.test.sh: $fail case(s) FAILED" >&2; exit 1
