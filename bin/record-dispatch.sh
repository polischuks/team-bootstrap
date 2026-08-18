#!/usr/bin/env bash
# record-dispatch.sh — NON-BLOCKING PreToolUse[Agent] recorder (milestone exec-role-integrity, v2.21.0).
#
# team-bootstrap's full/mvp pipelines exist to give each batch a fresh, INDEPENDENT mind (builder ≠
# reviewer). That separation used to be prose the orchestrator could silently collapse — and did
# (spec-169: the orchestrator absorbed builder AND reviewer, the machine backstop still went green, the
# user was told "delivered, gates passed" while the role pipeline never ran). This hook makes "a
# reviewer-typed subagent was DISPATCHED" a harness-observed fact instead of a claim.
#
# Registered as a PreToolUse hook matched on the Agent (subagent-dispatch) tool. On each dispatch it
# reads tool_input.subagent_type from the hook stdin; when that type is a dedicated review type
# (delivery-lib is_review_type ← references/review-types.txt, the N3 single source) it appends
#   {"batch":"<in-flight batch id>","subagent_type":"<type>"}
# to .runs/<run>/dispatch.jsonl. The batch is the one IN FLIGHT when the reviewer is launched (last
# announced ledger entry) — dispatch-time attribution (soundness B4: a reviewer runs within its own
# batch, before verify-batch closes it, so this credits the correct batch).
#
# WHY PreToolUse, no completion status (probe-confirmed, plan §signal):
#   - Subagents run background-by-default, so PostToolUse[Agent] returns status:"async_launched", never
#     "completed" — any completed-gated recorder would false-block a healthy parallel-reviewer batch (N1).
#   - SubagentStop is flaky (#27755). PreToolUse[Agent] reliably carries tool_input.subagent_type at
#     dispatch, foreground and background. So the signal is dispatch OCCURRENCE of a review type.
#
# HONEST LIMIT (ADR-000Z): subagent_type is model-authored → degradation-proof, NOT forgery-proof; and
# recording at dispatch proves the reviewer was LAUNCHED, not that it completed or was good (NF1).
#
# Safety: this hook must never disrupt a dispatch. It ALWAYS exits 0 (recording only — no deadlock, per
# references/hooks.md). Marker-gated: no active run ⇒ no-op. Disable with TEAM_BOOTSTRAP_DELIVERY_GATE=off.
#
# Usage: (hook) echo '<PreToolUse json>' | bin/record-dispatch.sh   ·   bin/record-dispatch.sh --self-test
# Exit:  always 0 (0 on --self-test only reflects pass/fail).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _inflight_batch_id → the id of the in-flight ledger entry (last announced; else last non-empty; else "").
_inflight_batch_id() {
  local ledger line
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] && field_str "$line" id
}

# record_dispatch PAYLOAD → the pure core (own function so the self-test can drive it): parse the
# subagent_type, and on a review type under an active marker, append a dispatch record. Always rc 0.
record_dispatch() {
  local payload="$1" stype marker rundir bid
  [ -n "$payload" ] || return 0
  stype="$(field_str "$payload" subagent_type)"
  [ -n "$stype" ] || return 0
  is_review_type "$stype" || return 0            # a builder-typed dispatch never records
  marker="$(resolve_marker)"                     # marker-gated: no active run ⇒ no-op
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  rundir="$(dirname "$marker")"
  bid="$(_inflight_batch_id)"
  printf '{"batch":"%s","subagent_type":"%s"}\n' "$bid" "$stype" >> "$rundir/dispatch.jsonl" 2>/dev/null || true
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
  disp="$T/.runs/r/dispatch.jsonl"
  _run() { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r "$here/record-dispatch.sh" ); }
  _chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL ($1 want $2) $3" >&2; fail=$((fail + 1)); fi; }

  # a review-typed dispatch (host review slug in review-types.txt) → recorded, credited to B1
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}'
  _chk "$([ -f "$disp" ] && grep -c '"subagent_type":"code-reviewer"' "$disp" || echo 0)" 1 "review-typed dispatch recorded"
  _chk "$([ -f "$disp" ] && grep -c '"batch":"B1"' "$disp" || echo 0)" 1 "recorded against the in-flight batch B1"
  # the dedicated plugin-scoped type is also recorded
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"independent-reviewer","prompt":"review"}}'
  _chk "$(grep -c '"subagent_type":"independent-reviewer"' "$disp" 2>/dev/null || echo 0)" 1 "dedicated review type recorded"
  # a builder-typed dispatch → NOT recorded (count unchanged at 2)
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"backend-developer","prompt":"build"}}'
  _chk "$(grep -c . "$disp" 2>/dev/null || echo 0)" 2 "builder-typed dispatch NOT recorded"
  # empty stdin → no-op, exit 0
  ec="$(printf '' | ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/record-dispatch.sh" ); echo $?)"
  _chk "$ec" 0 "empty stdin → non-blocking exit 0"
  # no active marker → no-op (nothing appended); use an isolated empty run
  rm -f "$T/.runs/r/RUN"; before="$(grep -c . "$disp" 2>/dev/null || echo 0)"
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}'
  _chk "$(grep -c . "$disp" 2>/dev/null || echo 0)" "$before" "no active marker → no record appended"
  # a review-typed dispatch ALWAYS exits 0 (non-blocking), even under an active marker
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  ec2="$(_run '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer"}}'; echo $?)"
  _chk "$ec2" 0 "review dispatch under active marker → non-blocking exit 0"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "record-dispatch --self-test: OK"; exit 0; fi
  echo "record-dispatch --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- hook entry: read the PreToolUse payload from stdin, record, never block ----
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
payload="$(cat 2>/dev/null || true)"
record_dispatch "$payload"
exit 0
