#!/usr/bin/env bash
# check-enforcement.sh — closure-fidelity gate A: make a SILENTLY-SKIPPED quality gate LOUD + BLOCKING.
#
# The retrospective's CAS bug passed because P9 red-first (check-tdd), F2 diff-coverage, and F3 mutation
# ALL skipped for lack of project tooling — the bug slipped through *disarmed* gates, not absent ones
# (the same self-disarm class as the v2.18.1 marker-whitespace bug). This gate detects, on an armed
# code-delivery run, which of those three dimensions is UNENFORCEABLE on this project, records the gaps
# in the RUN marker, and BLOCKS a code batch from closing until the human acknowledges shipping with them
# OFF (same blocking-ack machinery as precond). "Shipped with test-quality enforcement OFF" becomes a
# logged, dated decision — never an invisible default (US1).
#
# Gap detection mirrors the exact signal each peer gate skips on (AGENTS.md/CLAUDE.md, backtick contract):
#   - no `Test:` command                         → gap "red-first"     (check-tdd skips)
#   - no `Coverage:` command                     → gap "diff-coverage" (check-diff-coverage skips)
#   - no `Mutation:` command, or MutationMode≠enforce → gap "mutation" (check-mutation only advisory)
#
# Ack model (OQ-1, risk-tied strictness): a `feature|doc` batch may pass on `enforcement_ack:true`; a
# `run-rate|irreversible` batch (the CAS bug was a run-rate reconciliation path) HARD-FAILS on any gap,
# ack or not — the strictest tier is where the silent skip cost the most. Honesty of the ack is the
# human's (recorded, dated, visible in post-review — parity with risk_rank/precond).
#
# Graceful skips (exit 0): no active marker, or marker not intends_code — identical to the peer gates,
# never a false block on a non-delivery session (AC-6).
#
# Usage: bin/check-enforcement.sh [project-dir]  ·  bin/check-enforcement.sh --self-test
# Exit:  0 no gaps / gaps acked (feature|doc) / skip · 1 unacked gaps or hard-required tier · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

_doc() { local f; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; }
# _cmd LABEL DOC → first backticked command on a `Label:` line (empty if none/N-A)
_cmd() {
  local c; c="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  case "$c" in N/A|n/a|None|none) c="" ;; esac
  printf '%s' "$c"
}
# _val LABEL DOC → bare value after `Label:` (backticks stripped, trimmed, lowercased)
_val() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | tr -d '`' | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || true; }

# _inflight_risk_rank → risk_rank of the batch being closed now (last announced ledger entry; else last).
_inflight_risk_rank() {
  local ledger line
  ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 0
  field_str "$line" risk_rank
}

_evaluate() {
  local marker mk doc test cov mut mmode rank ack
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-enforcement: no active delivery run — skipping (governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-enforcement: marker not intends_code — skipping."; return 0; }

  doc="$(_doc)"
  test=""; cov=""; mut=""; mmode=""
  if [ -n "$doc" ]; then
    test="$(_cmd Test "$doc")"; cov="$(_cmd Coverage "$doc")"; mut="$(_cmd Mutation "$doc")"; mmode="$(_val MutationMode "$doc")"
  fi

  # detect the unenforceable dimensions — one gap string per disarmed peer gate.
  local gaps=""
  [ -n "$test" ] || gaps="$gaps red-first"
  [ -n "$cov" ]  || gaps="$gaps diff-coverage"
  { [ -z "$mut" ] || [ "$mmode" != "enforce" ]; } && gaps="$gaps mutation"
  gaps="$(printf '%s' "$gaps" | xargs 2>/dev/null || true)"

  # record enforcement_gaps to the marker (JSON array), so the gap set is a machine-readable fact.
  local arr="[]" g
  if [ -n "$gaps" ]; then
    arr="["; local first=1
    for g in $gaps; do [ "$first" -eq 1 ] && first=0 || arr="$arr,"; arr="$arr\"$g\""; done
    arr="$arr]"
  fi
  record_marker_list enforcement_gaps "$arr" || echo "check-enforcement: WARN — could not record enforcement_gaps to marker." >&2

  if [ -z "$gaps" ]; then
    echo "check-enforcement: all three quality dimensions enforceable (Test:/Coverage:/Mutation: enforce present) — no gaps, OK."
    return 0
  fi

  rank="$(_inflight_risk_rank)"
  ack="$(field_bool "$mk" enforcement_ack)"; [ "$ack" = "true" ] || ack="false"

  # OQ-1 — a run-rate|irreversible batch hard-fails on ANY gap, ack or not.
  if [ "$rank" = "run-rate" ] || [ "$rank" = "irreversible" ]; then
    echo "  FAIL-CLOSED: batch risk_rank=$rank with test-quality enforcement gaps [$gaps] — a bleeding-stopper batch must run against real tooling; the ack does not apply to this tier (OQ-1). Declare Test:/Coverage:/Mutation: enforce, or split the risk out." >&2
    return 1
  fi

  if [ "$ack" = "true" ]; then
    echo "check-enforcement: gaps [$gaps] present but enforcement_ack:true (risk_rank=${rank:-unset}) — shipped with those dimensions OFF, logged decision. OK."
    return 0
  fi

  echo "  FAIL-CLOSED: test-quality enforcement gaps [$gaps] recorded but enforcement_ack≠true — a code batch may not close with red-first/diff-coverage/mutation silently OFF (US1). Declare the missing tooling in AGENTS.md, or record enforcement_ack:true in the run marker to ship with them OFF (a logged, dated decision)." >&2
  return 1
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  _agents() { printf '%s\n' "$1" > "$T/AGENTS.md"; }
  _batch() { printf '%s\n' "$1" > "$T/.runs/r/batches.jsonl"; }
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-enforcement.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  ALL='# AGENTS

- Test: `true`
- Coverage: `true`
- Mutation: `true`
- MutationMode: enforce
'
  NONE='# AGENTS

- Lint: `true`
'
  # AC-1 — armed run, no Test:/Coverage:/Mutation:, feature batch, no ack → gap recorded + fail
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}'
  _agents "$NONE"; _batch '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  _chk "AC-1 gaps + no ack (feature) → fail" "$(_run)" 1
  got="$(cat "$T/.runs/r/RUN")"
  case "$got" in
    *'"enforcement_gaps":['*'red-first'*'diff-coverage'*'mutation'*']'*) echo "  PASS enforcement_gaps recorded [red-first,diff-coverage,mutation]" ;;
    *) echo "  FAIL enforcement_gaps not recorded correctly: $got" >&2; fail=$((fail + 1)) ;;
  esac
  case "$got" in *'"baseline_sha":"x"'*) echo "  PASS marker round-trip: non-target key baseline_sha survived" ;;
    *) echo "  FAIL marker round-trip clobbered baseline_sha: $got" >&2; fail=$((fail + 1)) ;; esac
  # AC-1 — same gaps but enforcement_ack:true (feature) → pass
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","enforcement_ack":true}'
  _chk "AC-1 gaps + enforcement_ack:true (feature) → pass" "$(_run)" 0
  # AC-2 — all tooling present (Mutation enforce) → no gap → pass
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}'
  _agents "$ALL"
  _chk "AC-2 Test:+Coverage:+Mutation:enforce → no gap → pass" "$(_run)" 0
  got="$(cat "$T/.runs/r/RUN")"
  case "$got" in *'"enforcement_gaps":[]'*) echo "  PASS enforcement_gaps recorded empty when no gaps" ;;
    *) echo "  FAIL enforcement_gaps not emptied: $got" >&2; fail=$((fail + 1)) ;; esac
  # OQ-1 — run-rate batch + gaps + ack:true → HARD fail (ack does not apply)
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","enforcement_ack":true}'
  _agents "$NONE"; _batch '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}'
  _chk "OQ-1 run-rate + gaps + ack → hard fail" "$(_run)" 1
  # mutation-only gap: Test:+Coverage: present but MutationMode advisory → gap "mutation", feature+ack → pass
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","enforcement_ack":true}'
  _agents '# AGENTS

- Test: `true`
- Coverage: `true`
- Mutation: `true`
- MutationMode: advisory
'
  _batch '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  out="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-enforcement.sh" . 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$(cat "$T/.runs/r/RUN")" | grep -q '"enforcement_gaps":\["mutation"\]'; then
    echo "  PASS mutation-only gap (MutationMode advisory) recorded + acked → pass"
  else echo "  FAIL mutation-only gap wrong (rc=$rc, marker=$(cat "$T/.runs/r/RUN"))" >&2; fail=$((fail + 1)); fi
  # R6 (marker-rewrite seam) — record_marker_list must REPLACE an existing enforcement_gaps that
  # follows a NESTED key (high_risk_seams) without leaking a backslash or clobbering the nested value.
  # Locks the bash-5.2 ${//}-replacement bug found building this gate.
  _agents "$NONE"; _batch '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","high_risk_seams":[{"seam":"marker-rewrite","paths":["bin/a.sh","bin/b.sh"]}],"enforcement_gaps":["stale"]}'
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-enforcement.sh" . >/dev/null 2>&1 ) || true
  got="$(cat "$T/.runs/r/RUN")"
  if printf '%s' "$got" | grep -q '\\'; then
    echo "  FAIL R6 marker rewrite leaked a backslash: $got" >&2; fail=$((fail + 1))
  elif printf '%s' "$got" | grep -q '"high_risk_seams":\[{"seam":"marker-rewrite","paths":\["bin/a.sh","bin/b.sh"\]}\]' \
    && printf '%s' "$got" | grep -q '"enforcement_gaps":\["red-first","diff-coverage","mutation"\]'; then
    echo "  PASS R6 marker rewrite replaced enforcement_gaps, nested high_risk_seams intact, no backslash"
  else
    echo "  FAIL R6 marker rewrite result malformed: $got" >&2; fail=$((fail + 1))
  fi

  # AC-6 — no active marker → skip
  rm -f "$T/.runs/r/RUN"
  _chk "AC-6 no active marker → skip (exit 0)" "$(_run)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-enforcement --self-test: OK"; exit 0; fi
  echo "check-enforcement --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-enforcement: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
