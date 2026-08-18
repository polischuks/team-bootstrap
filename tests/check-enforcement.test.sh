#!/usr/bin/env bash
# tests/check-enforcement.test.sh — behavioral test for Gate A (bin/check-enforcement.sh).
#
# Runs the gate's authoritative --self-test (the AC fixtures live there, per AC-7) and asserts a
# black-box smoke case, so the AC→gate mapping is verifiable from an is_test_path file (B --final,
# AC-4). AC references carried for check-completeness --final: AC-1, AC-2, AC-6.
#
# AC-1 — armed run + no Test: → records enforcement_gaps(red-first) + fails until enforcement_ack:true.
# AC-2 — all of Test:/Coverage:/Mutation: enforce present → no gap → exit 0.
# AC-6 — no active intends_code marker ⇒ exit 0 (skip), identical to peer gates.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-enforcement.sh"
fail=0

[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

# 1) authoritative fixtures (AC-1, AC-2, AC-6, OQ-1, marker round-trip)
if "$gate" --self-test >/dev/null 2>&1; then echo "  PASS check-enforcement --self-test"; else
  echo "  FAIL check-enforcement --self-test" >&2; fail=$((fail + 1)); fi

# 2) black-box smoke — armed run, no Test: (all gaps), no ack, feature batch → exit 1 (AC-1)
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
printf '# AGENTS\n\n- Lint: `true`\n' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$gate" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS smoke: gap+no-ack → exit 1 (AC-1)"; else
  echo "  FAIL smoke: gap+no-ack expected exit 1, got $rc (AC-1)" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

# 3) A2 governed waiver — EXPIRED (feature) → exit 1 (AC-2). A bare enforcement_ack:true no longer
#    suffices; the waiver must carry by/reason/expires/category and be unexpired.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","enforcement_ack":true,"enforcement_ack_by":"x","enforcement_ack_reason":"x","enforcement_ack_expires":"2000-01-01","enforcement_ack_category":"host_structural"}\n' > "$T/.runs/r/RUN"
printf '# AGENTS\n\n- Lint: `true`\n' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-18 "$gate" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS A2 expired governed waiver → exit 1 (AC-2)"; else
  echo "  FAIL A2 expired waiver expected exit 1, got $rc (AC-2)" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

# 4) A2 governed waiver — MISSING category (feature) → exit 1 (AC-2): an incomplete waiver is no ack.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","enforcement_ack":true,"enforcement_ack_by":"x","enforcement_ack_reason":"x","enforcement_ack_expires":"2999-01-01"}\n' > "$T/.runs/r/RUN"
printf '# AGENTS\n\n- Lint: `true`\n' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$gate" . >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then echo "  PASS A2 governed waiver missing category → exit 1 (AC-2)"; else
  echo "  FAIL A2 missing-category expected exit 1, got $rc (AC-2)" >&2; fail=$((fail + 1)); fi
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "check-enforcement.test.sh: OK"; exit 0; }
echo "check-enforcement.test.sh: $fail failure(s)" >&2; exit 1
