#!/usr/bin/env bash
# tests/check-review-ack.test.sh — behavioral test for Gate C / independent review-ack
# (bin/check-review-ack.sh, milestone closed-loop-fidelity, batch C1).
#
# A kind:code batch cannot close without a recorded, independent, clean-context adversarial review of the
# diff (reviewer ≠ builder, verdict:go, commit anchored). Runs the gate's authoritative --self-test + a
# black-box smoke. AC references for check-completeness --final: AC-6, AC-7, AC-8.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-review-ack.sh"
fail=0

[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

# 1) authoritative fixtures
if "$gate" --self-test >/dev/null 2>&1; then echo "  PASS check-review-ack --self-test"; else
  echo "  FAIL check-review-ack --self-test" >&2; fail=$((fail + 1)); fi

# 2) black-box smoke — a kind:code batch with NO review_acks entry → exit 1 (AC-6)
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"builder":"orchestrator"}\n' > "$T/.runs/r/RUN"
printf '{"id":"C1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$gate" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS smoke: kind:code + no review_acks → exit 1 (AC-6)"; else
  echo "  FAIL smoke: no review_acks expected exit 1, got $rc (AC-6)" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "check-review-ack.test.sh: OK"; exit 0; }
echo "check-review-ack.test.sh: $fail failure(s)" >&2; exit 1
