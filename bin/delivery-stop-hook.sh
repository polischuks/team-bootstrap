#!/usr/bin/env bash
# delivery-stop-hook.sh — delivery-aware Stop hook (fail-closed on premature completion).
#
# The retrospective failure is an agent that finishes Phase A, skips Phase B, and
# reports the run "done" while no code shipped. check-delivery.sh catches that at a
# GATE run; this hook catches it at the moment the agent tries to STOP: if an active
# delivery run still has code work announced-but-unclosed (or has delivered no code at
# all), completion is BLOCKED and the agent is told to finish or end the run.
#
# Exit contract (Claude Code Stop hook): exit 2 BLOCKS completion and feeds stderr
# back; exit 0 allows. (This is exit 2 — NOT the exit 1 that check-delivery.sh/CI use;
# the two share the run-state logic via delivery-lib.sh, not the exit convention.)
#
# On-by-default-safe: with no active run marker it exits 0 (no-op) on EVERY session,
# exactly as quality-gate.sh no-ops without an AGENTS.md — which is why it is safe to
# ship globally. Disable with TEAM_BOOTSTRAP_DELIVERY_GATE=off.
#
# Registered under **Stop only** (hooks/hooks.json). It is deliberately NOT on
# SubagentStop: worker subagents (integration-verifier, reviewers) finish BEFORE
# verify-batch stamps the batch closed, so blocking their SubagentStop on an
# announced-unclosed batch would deadlock the very step that closes it. The agent
# whose premature completion this guards is the MAIN orchestrator (Stop).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# ---- self-test --------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _expect() { # runname expected_exit desc
    local rn="$1" exp="$2" desc="$3" got
    TEAM_BOOTSTRAP_RUN="$rn" "$0" </dev/null >/dev/null 2>&1; got=$?
    if [ "$got" -eq "$exp" ]; then echo "  PASS (exit $got) $desc"
    else echo "  FAIL (exit $got, want $exp) $desc" >&2; fail=$((fail + 1)); fi
  }
  d="_st_stop"
  mkdir -p ".runs/${d}_block" ".runs/${d}_closed" ".runs/${d}_nomarker"
  # block: active marker + an announced-unclosed kind:code batch
  printf '%s\n' '{"run":"b","intends_code":true,"source":"harness"}' > ".runs/${d}_block/RUN"
  printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > ".runs/${d}_block/batches.jsonl"
  _expect "${d}_block" 2 "block — active run + announced-unclosed kind:code → exit 2"
  # allow: active marker + all code closed
  printf '%s\n' '{"run":"c","intends_code":true,"source":"harness"}' > ".runs/${d}_closed/RUN"
  printf '%s\n' '{"id":"B1","kind":"code","status":"closed","commit_shas":["0ad81d9"],"code_delta":5}' > ".runs/${d}_closed/batches.jsonl"
  _expect "${d}_closed" 0 "allow — active run + all kind:code closed → exit 0"
  # allow: no marker at all (the on-by-default-safe / omitted-marker path)
  _expect "${d}_nomarker" 0 "allow — no active marker → exit 0 (no-op)"
  rm -rf ".runs/${d}_block" ".runs/${d}_closed" ".runs/${d}_nomarker"
  if [ "$fail" -eq 0 ]; then echo "delivery-stop-hook --self-test: OK"; exit 0; fi
  echo "delivery-stop-hook --self-test: $fail case(s) FAILED" >&2; exit 1
fi

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
cat >/dev/null 2>&1 || true   # drain the Stop payload (unused)

marker="$(resolve_marker)"
[ -n "$marker" ] && [ -f "$marker" ] || exit 0     # not a delivery run → allow
mk="$(cat "$marker" 2>/dev/null || true)"
[ "$(field_bool "$mk" intends_code)" = "true" ] || exit 0

ledger="$(resolve_ledger)"
announced_code=0
closed_code=0
if [ -n "$ledger" ] && [ -f "$ledger" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field_str "$line" kind)" = "code" ] || continue
    case "$(field_str "$line" status)" in
      announced) announced_code=$((announced_code + 1)) ;;
      closed)    closed_code=$((closed_code + 1)) ;;
    esac
  done < "$ledger"
fi

if [ "$announced_code" -gt 0 ] || [ "$closed_code" -eq 0 ]; then
  run="$(field_str "$mk" run)"
  {
    echo "delivery-stop-hook: BLOCKED — active delivery run '${run:-?}' has unfinished code delivery"
    echo "  (announced-but-unclosed kind:code batches: $announced_code; earned closures: $closed_code)."
    echo "  Finish it: run the batch through the pipeline and close it with bin/verify-batch.sh"
    echo "  (a real commit + code_delta). If the run is genuinely finished or abandoned, end it by"
    echo "  removing its marker (.runs/${run:-<run>}/RUN). A delivery run may not stop with code"
    echo "  work announced-but-undelivered (constitution P6/P9)."
  } >&2
  exit 2
fi
exit 0
