#!/usr/bin/env bash
# tests/milestone-final.test.sh — closed-loop-fidelity acceptance assertions not colocated with a single
# gate's black-box test: AC-5 (disposition re-open on new commit), AC-8 (marker-gated skip), AC-9 (each new
# gate self-tests + shellcheck clean), AC-10 (gates wired in verify-batch), AC-11 (coverage/mutation
# superseded — honestly undeclared). Each AC is asserted here so check-completeness --final can map it.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# AC-5 — a disposition_waiver whose commit predates the batch's newest commit (HEAD) is voided → exit 1.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo a > f && git add . && git commit -qm c0; echo b >> f && git add . && git commit -qm c1 ) >/dev/null 2>&1
C0="$(cd "$T" && git rev-parse --short HEAD~1)"
printf '{"run":"r","intends_code":true,"builder":"orchestrator","review_findings":[{"id":"F1","severity":"MEDIUM","disposition":"downgraded"}],"disposition_waivers":[{"finding":"F1","approver":"code-reviewer","category":"accepted_risk","reason":"x","commit":"%s","expires":"2999-01-01"}]}\n' "$C0" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-18 "$here/bin/check-disposition.sh" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS AC-5 stale-commit disposition waiver → voided → exit 1"; else
  echo "  FAIL AC-5 stale-commit expected 1, got $rc" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

# AC-8 — both new gates skip (exit 0) with no active marker.
rc9=0
( TEAM_BOOTSTRAP_RUN=__none__ "$here/bin/check-disposition.sh" "$here" >/dev/null 2>&1 ) || rc9=$?
( TEAM_BOOTSTRAP_RUN=__none__ "$here/bin/check-review-ack.sh" "$here" >/dev/null 2>&1 ) || rc9=$?
if [ "$rc9" -eq 0 ]; then echo "  PASS AC-8 no-marker → both gates skip (exit 0)"; else
  echo "  FAIL AC-8 skip expected 0, got $rc9" >&2; fail=$((fail + 1)); fi

# AC-9 — each new/changed gate's --self-test passes and is shellcheck-clean.
ac9=0
for g in check-enforcement check-disposition check-review-ack; do
  bash "$here/bin/$g.sh" --self-test >/dev/null 2>&1 || ac9=1
  shellcheck --severity=error "$here/bin/$g.sh" >/dev/null 2>&1 || ac9=1
done
if [ "$ac9" -eq 0 ]; then echo "  PASS AC-9 new gates self-test + shellcheck clean"; else
  echo "  FAIL AC-9 a new gate self-test/shellcheck failed" >&2; fail=$((fail + 1)); fi

# AC-10 — disposition + review-ack are wired into verify-batch's gate list.
if grep -q 'check-disposition.sh' "$here/bin/verify-batch.sh" && grep -q 'check-review-ack.sh' "$here/bin/verify-batch.sh"; then
  echo "  PASS AC-10 disposition + review-ack wired in verify-batch"; else
  echo "  FAIL AC-10 a new gate is not wired into verify-batch" >&2; fail=$((fail + 1)); fi

# AC-11 — coverage/mutation backstop superseded: team-bootstrap declares NO Coverage:/Mutation: (honest,
# host has no bash coverage/mutation tool) — a declared-but-toolless command would be the vacuous gate.
if ! grep -qiE '^[[:space:]]*[-*]?[[:space:]]*(Coverage|Mutation):' "$here/AGENTS.md"; then
  echo "  PASS AC-11 no Coverage:/Mutation: declared (superseded backstop, honest)"; else
  echo "  FAIL AC-11 AGENTS.md unexpectedly declares Coverage:/Mutation:" >&2; fail=$((fail + 1)); fi

[ "$fail" -eq 0 ] && { echo "milestone-final.test.sh: OK"; exit 0; }
echo "milestone-final.test.sh: $fail failure(s)" >&2; exit 1
