#!/usr/bin/env bash
# check-role-dispatch.sh — verify-batch gate: harness-verified role execution (exec-role-integrity, v2.21.0).
#
# full/mvp exist to give each batch a fresh INDEPENDENT reviewer mind (builder ≠ reviewer). spec-169
# collapsed that silently — the orchestrator ran build AND review inline, dispatched no reviewer subagent,
# and the user was told "delivered, gates passed." This gate makes the collapse catchable + announced:
# a full/mvp kind:code batch whose window recorded ZERO reviewer-typed Agent dispatches
# (record-dispatch.sh @ PreToolUse[Agent], subagent_type ∈ references/review-types.txt) fails closed with
# a LOUD, user-visible message that the run degraded to single-thread.
#
# Signal (probe-confirmed, plan §signal): a reviewer-typed DISPATCH OCCURRENCE — no completion status
# (background dispatch yields async_launched, never completed — soundness N1). A builder-typed dispatch
# (backend-developer / general-purpose / stack specialists — none in review-types.txt) does NOT satisfy it.
# Attribution is by the in-flight batch id the recorder stamped at dispatch time (soundness B4).
#
# HONEST LIMITS (ADR-000Z): subagent_type is model-authored ⇒ DEGRADATION-proof, NOT forgery-proof (a decoy
# review-typed no-op dispatch satisfies it — the ADR-0006 quality/willingness limit); and a dispatch proves
# the reviewer was LAUNCHED, not that it completed or was good (NF1 — completion rests on check-review-ack).
#
# Graceful skips (exit 0): no active marker / not intends_code (AC-3); pipeline is not full|mvp — e.g.
# single-thread, where P1 sanctions inline roles (AC-3); in-flight batch not kind:code (AC-3).
#
# Usage: bin/check-role-dispatch.sh [project-dir]  ·  bin/check-role-dispatch.sh --self-test
# Exit:  0 pass / skip · 1 full/mvp code batch with zero reviewer-typed dispatch (degraded) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _inflight_batch → the in-flight ledger line (last announced; else last non-empty).
_inflight_batch() {
  local ledger line
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  printf '%s' "$line"
}

_evaluate() {
  local marker mk pipeline bline bid bkind cnt
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-role-dispatch: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-role-dispatch: marker not intends_code — skipping."; return 0; }

  pipeline="$(field_str "$mk" pipeline)"
  case "$pipeline" in
    full|mvp) : ;;
    *) echo "check-role-dispatch: pipeline='$pipeline' is not full/mvp — independence-via-subagent is not the contract here (P1); skipping."; return 0 ;;
  esac

  bline="$(_inflight_batch)"
  [ -n "$bline" ] || { echo "check-role-dispatch: no in-flight batch — nothing to check."; return 0; }
  bid="$(field_str "$bline" id)"; bkind="$(field_str "$bline" kind)"
  [ "$bkind" = "code" ] || { echo "check-role-dispatch: in-flight batch '$bid' is kind=$bkind (not code) — skipping."; return 0; }

  cnt="$(reviewer_dispatch_count "$bid")"   # shared delivery-lib definition (single source, B3)
  if [ "${cnt:-0}" -eq 0 ]; then
    # AC-4 — the degradation message MUST reach the user (stdout), not only stderr.
    echo "check-role-dispatch: DEGRADED — $pipeline/code batch '$bid' closed with ZERO independent-review-typed subagent dispatches. The run degraded to single-thread: no reviewer ran in a fresh context (builder ≠ reviewer was not honored). Dispatch the required review roles as subagents with a dedicated review type (references/review-types.txt) before closing, or run single-thread if one mind is intended."
    echo "  FAIL-CLOSED: batch '$bid' — no reviewer-typed Agent dispatch recorded for its window (spec-169 collapse signature)." >&2
    return 1
  fi
  echo "check-role-dispatch: batch '$bid' recorded $cnt independent-review-typed dispatch(es) — the $pipeline role pipeline ran (not collapsed to single-thread). OK."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  _batch()  { printf '%s\n' "$1" > "$T/.runs/r/batches.jsonl"; }
  _disp()   { printf '%s\n' "$1" > "$T/.runs/r/dispatch.jsonl"; }
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  MK='"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"'
  _batch '{"id":"B1","kind":"code","status":"announced"}'
  rm -f "$T/.runs/r/dispatch.jsonl"

  # AC-1 — full+code, no dispatch.jsonl at all → fail (degraded)
  _marker "{$MK}"
  _chk "AC-1 full+code, zero reviewer dispatch → fail" "$(_run)" 1
  # AC-1 — full+code, ONLY a builder-typed dispatch recorded → fail (builder does not satisfy)
  _disp '{"batch":"B1","subagent_type":"backend-developer"}'
  _chk "AC-1 builder-typed dispatch only → fail" "$(_run)" 1
  # AC-1 — full+code, a review-typed dispatch for a DIFFERENT batch → fail (attribution, B4)
  _disp '{"batch":"B0","subagent_type":"code-reviewer"}'
  _chk "AC-1 reviewer dispatch credited to another batch → fail" "$(_run)" 1
  # AC-1 — full+code, ≥1 review-typed dispatch for THIS batch → pass
  _disp '{"batch":"B1","subagent_type":"code-reviewer"}'
  _chk "AC-1 ≥1 reviewer-typed dispatch for this batch → pass" "$(_run)" 0
  # AC-1 — the dedicated plugin-scoped type also satisfies
  _disp '{"batch":"B1","subagent_type":"independent-reviewer"}'
  _chk "AC-1 dedicated review type satisfies → pass" "$(_run)" 0
  # AC-4 — the degradation message is on STDOUT (user-visible)
  rm -f "$T/.runs/r/dispatch.jsonl"
  out="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-role-dispatch.sh" . 2>/dev/null )"
  case "$out" in *DEGRADED*|*degraded*) echo "  PASS AC-4 degradation message on stdout" ;; *) echo "  FAIL AC-4 no stdout message (got: $out)" >&2; fail=$((fail + 1)) ;; esac
  # AC-3 — single-thread pipeline → skip even with zero dispatch
  _marker '{"run":"r","pipeline":"single-thread","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "AC-3 single-thread → skip" "$(_run)" 0
  # AC-3 — non-code batch → skip
  _marker "{$MK}"; _batch '{"id":"Z","kind":"doc","status":"announced"}'
  _chk "AC-3 kind:doc batch → skip" "$(_run)" 0
  # AC-3 — mvp pipeline is in scope (fails on zero, like full)
  _batch '{"id":"B1","kind":"code","status":"announced"}'; rm -f "$T/.runs/r/dispatch.jsonl"
  _marker '{"run":"r","pipeline":"mvp","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "AC-3 mvp+code, zero reviewer dispatch → fail (in scope)" "$(_run)" 1
  # AC-3 — no active marker → skip
  rm -f "$T/.runs/r/RUN"
  _chk "AC-3 no active marker → skip" "$(_run)" 0
  # not intends_code → skip
  _marker '{"run":"r","pipeline":"full","intends_code":false,"source":"harness"}'
  _chk "not intends_code → skip" "$(_run)" 0

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-role-dispatch --self-test: OK"; exit 0; fi
  echo "check-role-dispatch --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-role-dispatch: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
