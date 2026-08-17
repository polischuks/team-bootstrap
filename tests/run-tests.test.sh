#!/usr/bin/env bash
# TDD test for bin/run-tests.sh (milestone closed-loop-fidelity, batch A1).
#
# The runner's behavioral cases live in its own --self-test (red/green suite aggregation over temp
# fixtures). This test-path file (a) makes the batch's red step "touch a test file" so check-tdd's
# F1 (red-touches-tests) is satisfied, and (b) asserts the runner is present and its self-test green.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fail=0

if [ ! -f "$root/bin/run-tests.sh" ]; then
  echo "FAIL: bin/run-tests.sh missing" >&2; exit 1
fi
if bash "$root/bin/run-tests.sh" --self-test >/dev/null 2>&1; then
  echo "PASS: run-tests.sh --self-test green"
else
  echo "FAIL: run-tests.sh --self-test red" >&2; fail=1
fi
exit "$fail"
