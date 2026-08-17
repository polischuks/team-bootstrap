#!/usr/bin/env bash
# tests/check-seam-ack.test.sh — behavioral test for Gate C (bin/check-seam-ack.sh).
#
# Runs the gate's authoritative --self-test (AC fixtures live there, AC-7) plus a black-box smoke.
# AC reference carried for check-completeness --final: AC-5.
#
# AC-5 — with high_risk_seams recorded, closing a batch whose files intersect a seam's paths but with
#        NO matching seam_acks entry → exit 1; with the ack (naming the seam + a resolvable commit) →
#        exit 0; a batch touching no flagged seam → exit 0.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-seam-ack.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }
if "$gate" --self-test >/dev/null 2>&1; then echo "  PASS check-seam-ack --self-test"; else
  echo "  FAIL check-seam-ack --self-test" >&2; fail=$((fail + 1)); fi
[ "$fail" -eq 0 ] && { echo "check-seam-ack.test.sh: OK"; exit 0; }
echo "check-seam-ack.test.sh: $fail failure(s)" >&2; exit 1
