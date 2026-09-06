#!/usr/bin/env bash
# phase-a-plan-ac-contradiction.test.sh — #132. Phase A's speckit-analyze step must instruct a
# plan-requirement ↔ acceptance-criterion contradiction pass (each FR checked against every AC), so a
# plan FR that contradicts an AC is a Phase-A blocker, not a B3 surprise. Doc/instruction fix: the
# analyze step is model-driven, so the lever is the explicit instruction in commands/deliver.md.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" -ge "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want >=[$2])" >&2; fail=$((fail+1)); fi; }

d="$here/commands/deliver.md"
echo "#132 — deliver.md Phase-A analyze step carries the plan↔AC contradiction pass:"
_chk "$(grep -c '#132' "$d")" 1 "deliver.md cites #132"
_chk "$(grep -ci 'acceptance.criterion contradiction\|contradiction pass' "$d")" 1 "names a plan↔AC contradiction pass"
# the instruction must be attached to the analyze step (cross-artifact consistency guard)
_chk "$(grep -cE 'speckit-analyze.*consistency|consistency guard' "$d")" 1 "the pass is attached to speckit-analyze (the consistency guard)"
# Specific to the #132 instruction — NOT the pre-existing "every acceptance criterion maps to >=1 task"
# (that line would false-pass a looser grep). Require the FR-against-every-AC contradiction phrasing.
_chk "$(grep -ciE 'each plan requirement .*check it against every acceptance criterion|for each plan requirement' "$d")" 1 "requires EACH plan requirement (FR-N) checked against EVERY AC"

if [ "$fail" -eq 0 ]; then echo "phase-a-plan-ac-contradiction.test.sh: OK"; exit 0; fi
echo "phase-a-plan-ac-contradiction.test.sh: $fail case(s) FAILED" >&2; exit 1
