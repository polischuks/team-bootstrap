#!/usr/bin/env bash
# tests/gates-wiring.test.sh — integration test for the closure-fidelity gates.
#
# Asserts the three new gates are actually WIRED into verify-batch and that every gate's --self-test
# passes and gate-integrity is clean. Carries the AC-7 / AC-8 tokens for check-completeness --final.
#
# AC-7 — each gate ships --self-test; check-gate-integrity clean; existing gate self-tests unregressed.
# AC-8 — A, B(per-batch), C wired into verify-batch.sh (B --final invoked by deliver.md separately).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# AC-8 — the three gates are wired into verify-batch.sh
for g in check-enforcement check-completeness check-seam-ack; do
  if grep -q "$g.sh" "$here/bin/verify-batch.sh"; then echo "  PASS AC-8 $g wired into verify-batch"; else
    echo "  FAIL AC-8 $g NOT wired into verify-batch" >&2; fail=$((fail + 1)); fi
done

# AC-7 — every gate with a --self-test passes it
for s in check-enforcement check-completeness check-seam-ack check-tdd check-diff-coverage \
         check-mutation check-version-sync check-delivery check-role-triples check-context-phrasing check-role-liveness \
         verify-batch; do
  if grep -q -- '--self-test' "$here/bin/$s.sh" 2>/dev/null; then
    if "$here/bin/$s.sh" --self-test >/dev/null 2>&1; then echo "  PASS AC-7 $s --self-test"; else
      echo "  FAIL AC-7 $s --self-test" >&2; fail=$((fail + 1)); fi
  fi
done

# AC-7 — gate-integrity clean on this repo
if "$here/bin/check-gate-integrity.sh" "$here" >/dev/null 2>&1; then echo "  PASS AC-7 gate-integrity clean"; else
  echo "  FAIL AC-7 gate-integrity" >&2; fail=$((fail + 1)); fi

[ "$fail" -eq 0 ] && { echo "gates-wiring.test.sh: OK"; exit 0; }
echo "gates-wiring.test.sh: $fail failure(s)" >&2; exit 1
