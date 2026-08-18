#!/usr/bin/env bash
# tests/check-disposition.test.sh — behavioral test for Gate B / disposition governance
# (bin/check-disposition.sh, milestone closed-loop-fidelity, batch B1).
#
# A fired finding of severity ≥ MEDIUM cannot be self-dispositioned to non-blocking: a downgrade is
# valid only as a governed waiver (independent approver ≠ builder, category, reason, unexpired, current
# commit). Runs the gate's authoritative --self-test (AC fixtures) + a black-box smoke.
# AC references for check-completeness --final: AC-4, AC-5, AC-8.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-disposition.sh"
fail=0

[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

# 1) authoritative fixtures
if "$gate" --self-test >/dev/null 2>&1; then echo "  PASS check-disposition --self-test"; else
  echo "  FAIL check-disposition --self-test" >&2; fail=$((fail + 1)); fi

# 2) black-box smoke — a MEDIUM finding downgraded with NO waiver → exit 1 (AC-4)
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"builder":"orchestrator","review_findings":[{"id":"F1","severity":"MEDIUM","disposition":"downgraded"}]}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$gate" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS smoke: MEDIUM downgraded + no waiver → exit 1 (AC-4)"; else
  echo "  FAIL smoke: MEDIUM downgraded + no waiver expected exit 1, got $rc (AC-4)" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "check-disposition.test.sh: OK"; exit 0; }
echo "check-disposition.test.sh: $fail failure(s)" >&2; exit 1
