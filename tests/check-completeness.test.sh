#!/usr/bin/env bash
# tests/check-completeness.test.sh — behavioral test for Gate B (bin/check-completeness.sh).
#
# Runs the gate's authoritative --self-test (AC fixtures live there, AC-7) plus a black-box smoke.
# AC references carried for check-completeness --final: AC-3, AC-4.
#
# AC-3 — a closing batch whose ledger task_ids include an unchecked [ ] task in tasks.md → exit 1;
#        all [x] → exit 0 (per-batch completeness).
# AC-4 — check-completeness --final: any remaining [ ] in tasks.md, or any AC-N in spec.md not
#        referenced by a test-path file → exit 1; complete + all ACs referenced → exit 0.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-completeness.sh"
fail=0

[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

if "$gate" --self-test >/dev/null 2>&1; then echo "  PASS check-completeness --self-test"; else
  echo "  FAIL check-completeness --self-test" >&2; fail=$((fail + 1)); fi

# black-box smoke — per-batch: an unchecked task_id in the batch → exit 1 (AC-3)
T="$(mktemp -d)"; mkdir -p "$T/.runs/r" "$T/specs/demo"
printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md"}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","task_ids":["T001"],"status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
printf '# Tasks\n\n- [ ] **T001** unchecked\n' > "$T/specs/demo/tasks.md"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$gate" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS smoke: unchecked task_id → exit 1 (AC-3)"; else
  echo "  FAIL smoke: unchecked task_id expected 1, got $rc (AC-3)" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "check-completeness.test.sh: OK"; exit 0; }
echo "check-completeness.test.sh: $fail failure(s)" >&2; exit 1
