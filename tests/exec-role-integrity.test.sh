#!/usr/bin/env bash
# tests/exec-role-integrity.test.sh — integration test for the harness-verified role-execution gate
# (milestone exec-role-integrity, v2.21.0). End-to-end: the PreToolUse[Agent] dispatch recorder feeds
# the role-dispatch gate, and the gate is wired into verify-batch.
#
# Carries the AC tokens for check-completeness --final (every AC-N referenced by a test-path file):
#   AC-1 — full/mvp kind:code batch with ZERO reviewer-typed dispatch records → gate exit 1 + loud msg;
#          ≥1 such record → exit 0; a builder-typed dispatch does NOT satisfy it.
#   AC-2 — a review_acks entry with no corresponding reviewer-typed dispatch record → check-review-ack fails
#          (corroboration; asserted in Batch C — tests/check-review-ack.test.sh / its --self-test).
#   AC-3 — single-thread pipeline or non-kind:code batch → gate skips (exit 0).
#   AC-4 — the degradation message is surfaced to the user (stdout), not only stderr.
#   AC-5 — record-dispatch + check-role-dispatch ship --self-test; check-gate-integrity clean; gate wired.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

# --- AC-5: both new scripts exist and pass their own --self-test ----------------
for s in record-dispatch check-role-dispatch; do
  if [ -x "$here/bin/$s.sh" ] || [ -f "$here/bin/$s.sh" ]; then
    if bash "$here/bin/$s.sh" --self-test >/dev/null 2>&1; then echo "  PASS AC-5 $s --self-test"; else
      echo "  FAIL AC-5 $s --self-test" >&2; fail=$((fail + 1)); fi
  else echo "  FAIL AC-5 $s missing" >&2; fail=$((fail + 1)); fi
done

# --- AC-5: the gate is wired into verify-batch.sh -------------------------------
if grep -q 'check-role-dispatch.sh' "$here/bin/verify-batch.sh"; then echo "  PASS AC-5 gate wired into verify-batch"; else
  echo "  FAIL AC-5 gate NOT wired into verify-batch" >&2; fail=$((fail + 1)); fi

# --- AC-5: check-gate-integrity clean on this repo -----------------------------
if bash "$here/bin/check-gate-integrity.sh" "$here" >/dev/null 2>&1; then echo "  PASS AC-5 gate-integrity clean"; else
  echo "  FAIL AC-5 gate-integrity" >&2; fail=$((fail + 1)); fi

# --- end-to-end: recorder feeds the gate ---------------------------------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"

# a reviewer-typed dispatch payload (PreToolUse[Agent].tool_input.subagent_type ∈ review-set)
rev='{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review the diff"}}'
bld='{"tool_name":"Agent","tool_input":{"subagent_type":"backend-developer","prompt":"build the endpoint"}}'
_rec() { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r "$here/bin/record-dispatch.sh" >/dev/null 2>&1 ); echo $?; }
_gate() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }

# AC-1 — before any reviewer dispatch, a full/code batch → gate fails (degraded to single-thread)
_chk "AC-1 full+code, zero reviewer dispatch → gate fail" "$(_gate)" 1
# recorder ignores a builder-typed dispatch (AC-1 negative: builder does not satisfy)
_chk "AC-1 record a builder-typed dispatch → non-blocking exit 0" "$(_rec "$bld")" 0
_chk "AC-1 builder-only dispatch → gate still fails" "$(_gate)" 1
# recorder records a reviewer-typed dispatch → gate now passes
_chk "AC-1 record a reviewer-typed dispatch → non-blocking exit 0" "$(_rec "$rev")" 0
_chk "AC-1 ≥1 reviewer dispatch → gate passes" "$(_gate)" 0

# AC-4 — the degradation message reaches STDOUT (user-visible), not only stderr
printf '{"run":"r2","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN2" 2>/dev/null || true
mkdir -p "$T/.runs/r2"
printf '{"run":"r2","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r2/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r2/batches.jsonl"
msg="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r2 "$here/bin/check-role-dispatch.sh" . 2>/dev/null )"
case "$msg" in *degrad*|*single-thread*) echo "  PASS AC-4 degradation message on stdout" ;; *) echo "  FAIL AC-4 no user-visible message on stdout (got: $msg)" >&2; fail=$((fail + 1)) ;; esac

# AC-3 — a single-thread run → skip (exit 0) even with zero reviewer dispatch
mkdir -p "$T/.runs/st"
printf '{"run":"st","pipeline":"single-thread","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/st/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/st/batches.jsonl"
_chk "AC-3 single-thread pipeline → gate skips" "$( cd "$T" && TEAM_BOOTSTRAP_RUN=st "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1; echo $? )" 0

rm -rf "$T"
[ "$fail" -eq 0 ] && { echo "exec-role-integrity.test.sh: OK"; exit 0; }
echo "exec-role-integrity.test.sh: $fail failure(s)" >&2; exit 1
