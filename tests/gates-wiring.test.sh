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

# AC-7 — every gate is WIRED, and declares a self-test.
#
# This file used to RUN each gate's --self-test here. bin/run-tests.sh already runs every
# bin/*.sh --self-test, so that loop re-executed a subset of what had just run and added no coverage.
# It was not free: check-role-liveness --self-test alone measures ~62s, so the suite paid ~124s of its
# ~244s for one member executed twice (issue #51).
#
# What is unique to this file is the WIRING question — is the gate actually invoked by verify-batch —
# which is a grep, in milliseconds. Whether the gate PASSES is answered once, where it belongs.
for s in check-enforcement check-completeness check-seam-ack check-tdd check-diff-coverage \
         check-mutation check-version-sync check-delivery check-role-triples check-context-phrasing check-role-liveness \
         verify-batch; do
  [ -f "$here/bin/$s.sh" ] || { echo "  FAIL AC-7 $s: script missing" >&2; fail=$((fail + 1)); continue; }
  # A gate that lost its --self-test stops being independently checkable; that is a wiring fact too.
  grep -q -- '--self-test' "$here/bin/$s.sh" 2>/dev/null \
    || { echo "  FAIL AC-7 $s declares no --self-test" >&2; fail=$((fail + 1)); continue; }
  # verify-batch is the invoker itself, so it is not expected to invoke itself.
  if [ "$s" != "verify-batch" ]; then
    grep -q "$s.sh" "$here/bin/verify-batch.sh" 2>/dev/null \
      || { echo "  FAIL AC-7 $s is not invoked from verify-batch.sh" >&2; fail=$((fail + 1)); continue; }
  fi
  echo "  PASS AC-7 $s wired + self-testable"
done

# The claim above is only worth anything if run-tests really does run every self-test. Assert it,
# rather than assuming it — dropping the loop here is safe ONLY because that sweep exists.
if grep -qE 'bin/\*\.sh|for f in .*bin' "$here/bin/run-tests.sh" 2>/dev/null \
   && grep -q -- '--self-test' "$here/bin/run-tests.sh" 2>/dev/null; then
  echo "  PASS AC-7 run-tests sweeps bin/*.sh --self-test (so this file need not)"
else
  echo "  FAIL AC-7 run-tests does NOT sweep bin/*.sh --self-test — dropping the loop here loses coverage" >&2
  fail=$((fail + 1))
fi

# AC-7 — gate-integrity clean on this repo
if "$here/bin/check-gate-integrity.sh" "$here" >/dev/null 2>&1; then echo "  PASS AC-7 gate-integrity clean"; else
  echo "  FAIL AC-7 gate-integrity" >&2; fail=$((fail + 1)); fi

[ "$fail" -eq 0 ] && { echo "gates-wiring.test.sh: OK"; exit 0; }
echo "gates-wiring.test.sh: $fail failure(s)" >&2; exit 1
