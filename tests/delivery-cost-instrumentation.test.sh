#!/usr/bin/env bash
# tests/delivery-cost-instrumentation.test.sh — behavioural test for issue #61 (delivery cost is
# unmeasurable: delivery-metrics reports no wall-time, no per-batch/per-role breakdown).
#
# The instrument records two honest, harness-observable wall-clock facts and surfaces them:
#   - record-dispatch.sh (PreToolUse[Agent]) stamps each review dispatch with `ts` (epoch seconds).
#   - verify-batch.sh stamps each batch close with `closed_at` (epoch seconds) — covered by that
#     script's own --self-test, where stamp_batch_closed is in scope.
#   - delivery-metrics.sh turns those two into per-batch wall-time, per-role dispatch timing, run
#     total wall-time, and an orchestrator-vs-review split.
#
# TOKENS are deliberately NOT asserted: a bash hook cannot see per-subagent token usage (that is the
# harness's, not the plugin's). This test pins the wall-time instrument only — the honest half.
#
# DETERMINISM: the repo forbids reading the real clock inside its self-test/fixtures (it breaks
# determinism). Every timestamp here is INJECTED via TB_NOW_EPOCH (for the recorder) or hand-written
# into the fixture ledgers (for the metrics reader). No assertion reads the wall clock.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
disp_hook="$here/bin/record-dispatch.sh"
metrics="$here/bin/delivery-metrics.sh"
fail=0
[ -x "$disp_hook" ] || { echo "FAIL: $disp_hook missing/not executable" >&2; exit 1; }
[ -x "$metrics" ]   || { echo "FAIL: $metrics missing/not executable" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
_chk()      { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got '$1' want '$2')" >&2; fail=$((fail + 1)); fi; }
_contains() { case "$1" in *"$2"*) echo "  PASS $3" ;; *) echo "  FAIL $3 (missing '$2')" >&2; fail=$((fail + 1)) ;; esac; }

# --- 1. record-dispatch stamps a DETERMINISTIC ts on each review dispatch (per-role timing) ---------
D1="$T/rec"; mkdir -p "$D1/.runs/r"
( cd "$D1" && git init -q && git config user.email t@t && git config user.name t \
  && echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
base="$( cd "$D1" && git rev-parse --short HEAD )"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$D1/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$D1/.runs/r/batches.jsonl"
( cd "$D1" && printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}' \
    | TEAM_BOOTSTRAP_RUN=r TB_NOW_EPOCH=1000 TEAM_BOOTSTRAP_DISPATCH_BRIEF=off "$disp_hook" ) >/dev/null 2>&1
_disp="$D1/.runs/r/dispatch.jsonl"
_chk "$([ -f "$_disp" ] && grep -c '"subagent_type":"code-reviewer"' "$_disp" || echo 0)" 1 "review dispatch recorded"
_chk "$([ -f "$_disp" ] && grep -c '"ts":1000' "$_disp" || echo 0)" 1 "dispatch carries the injected wall-clock ts (per-role timing)"

# --- 2 & 3. delivery-metrics surfaces per-batch wall-time + per-role timing from the ledgers ---------
# Fixture with KNOWN timestamps so every derived number is exact:
#   t0 = earliest dispatch ts = 940
#   B1 closed_at 1000  → wall = 1000-940 = 60s   (start = t0)
#   B2 closed_at 1300  → wall = 1300-1000 = 300s  (start = prior close)
#   run total wall = 1300-940 = 360s
#   B1 review window = 960-940 = 20s over 2 dispatches; B2 = 0s over 1 dispatch
#   per role: code-reviewer 2 dispatches, architecture-reviewer 1
M="$T/proj"; mkdir -p "$M/.runs/r"
printf '%s\n' \
  '{"id":"B1","kind":"code","status":"closed","closed_at":1000}' \
  '{"id":"B2","kind":"code","status":"closed","closed_at":1300}' > "$M/.runs/r/batches.jsonl"
printf '%s\n' \
  '{"batch":"B1","subagent_type":"code-reviewer","outcome":"attempted","ts":940}' \
  '{"batch":"B1","subagent_type":"architecture-reviewer","outcome":"attempted","ts":960}' \
  '{"batch":"B2","subagent_type":"code-reviewer","outcome":"attempted","ts":1200}' > "$M/.runs/r/dispatch.jsonl"

out="$( "$metrics" "$M" 2>/dev/null )"
_contains "$out" "wall-time"  "metrics output has a wall-time section"
_contains "$out" "B1"         "per-batch wall-time names batch B1"
_contains "$out" "B2"         "per-batch wall-time names batch B2"
_contains "$out" "300"        "B2 per-batch wall-time = 300s is reported"
_contains "$out" "360"        "run total wall-time = 360s is reported"
_contains "$out" "code-reviewer" "per-role timing names code-reviewer"

# JSON surface carries the same run total (a machine consumer can attribute the run).
jout="$( "$metrics" --json "$M" 2>/dev/null )"
_contains "$jout" '"total_wall_s":360' "--json carries total_wall_s"

if [ "$fail" -eq 0 ]; then echo "delivery-cost-instrumentation.test.sh: OK"; exit 0; fi
echo "delivery-cost-instrumentation.test.sh: $fail case(s) FAILED" >&2; exit 1
