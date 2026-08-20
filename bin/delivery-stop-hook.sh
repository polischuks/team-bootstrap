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
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$(git rev-parse --short HEAD 2>/dev/null)\"],\"code_delta\":5}" > ".runs/${d}_closed/batches.jsonl"
  _expect "${d}_closed" 0 "allow — active run + all kind:code closed → exit 0"
  # allow: no marker at all (the on-by-default-safe / omitted-marker path)
  _expect "${d}_nomarker" 0 "allow — no active marker → exit 0 (no-op)"
  root_sha="$(git rev-parse --short "$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)" 2>/dev/null)"
  # WS-A AC-A2 — allow: single-thread DIRECT run (no ledger) that committed code since baseline. The
  # csb allowance is retained only for the pipeline that has no role fan-out.
  mkdir -p ".runs/${d}_direct"
  printf '%s\n' "{\"run\":\"dr\",\"pipeline\":\"single-thread\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$root_sha\"}" > ".runs/${d}_direct/RUN"
  _expect "${d}_direct" 0 "allow — single-thread direct run, no ledger, code since baseline → exit 0 (AC-A2)"
  # WS-A AC-A1 — block: FULL direct run, code since baseline, no earned closure → the csb allowance is
  # refused for full/mvp (the audit's spec-169 no-batch path, formerly Stop exit 0).
  mkdir -p ".runs/${d}_dfull"
  printf '%s\n' "{\"run\":\"df\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$root_sha\"}" > ".runs/${d}_dfull/RUN"
  _expect "${d}_dfull" 2 "block — full direct run, no earned closure → exit 2 (AC-A1)"
  # WS-A AC-A5 — block: ABSENT pipeline, code since baseline, no closure → fail-closed (finding #1).
  mkdir -p ".runs/${d}_dnopipe"
  printf '%s\n' "{\"run\":\"dn\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$root_sha\"}" > ".runs/${d}_dnopipe/RUN"
  _expect "${d}_dnopipe" 2 "block — absent-pipeline direct run → exit 2 (AC-A5, fail-closed)"
  # WS-A AC-A3a — allow: full run, closed batch WITH a reviewer dispatch → run-close floor met.
  mkdir -p ".runs/${d}_frev"
  printf '%s\n' "{\"run\":\"fr\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$root_sha\"}" > ".runs/${d}_frev/RUN"
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$root_sha\"],\"code_delta\":4}" > ".runs/${d}_frev/batches.jsonl"
  printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer"}' > ".runs/${d}_frev/dispatch.jsonl"
  _expect "${d}_frev" 0 "allow — full run, closed batch + reviewer dispatch → exit 0 (AC-A3a)"
  # WS-A AC-A3b — block: full run, closed batch but ZERO reviewer dispatch (dispatch.jsonl present).
  mkdir -p ".runs/${d}_fnorev"
  printf '%s\n' "{\"run\":\"fn\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$root_sha\"}" > ".runs/${d}_fnorev/RUN"
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$root_sha\"],\"code_delta\":4}" > ".runs/${d}_fnorev/batches.jsonl"
  printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer"}' > ".runs/${d}_fnorev/dispatch.jsonl"
  _expect "${d}_fnorev" 2 "block — full run, closed batch, zero reviewer dispatch → exit 2 (AC-A3b)"
  # block: armed run that delivered nothing (no ledger, no code since baseline=HEAD)
  mkdir -p ".runs/${d}_empty"
  printf '%s\n' "{\"run\":\"e\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$(git rev-parse --short HEAD 2>/dev/null)\"}" > ".runs/${d}_empty/RUN"
  _expect "${d}_empty" 2 "block — armed run, no ledger, no code since baseline → exit 2"
  rm -rf ".runs/${d}_block" ".runs/${d}_closed" ".runs/${d}_nomarker" ".runs/${d}_direct" ".runs/${d}_dfull" ".runs/${d}_dnopipe" ".runs/${d}_frev" ".runs/${d}_fnorev" ".runs/${d}_empty"
  if [ "$fail" -eq 0 ]; then echo "delivery-stop-hook --self-test: OK"; exit 0; fi
  echo "delivery-stop-hook --self-test: $fail case(s) FAILED" >&2; exit 1
fi

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
cat >/dev/null 2>&1 || true   # drain the Stop payload (unused)

marker="$(resolve_marker)"
[ -n "$marker" ] && [ -f "$marker" ] || exit 0     # not a delivery run → allow
mk="$(cat "$marker" 2>/dev/null || true)"
[ "$(field_bool "$mk" intends_code)" = "true" ] || exit 0

# pipeline — decides who may deliver directly (WS-A). A well-formed harness marker always records
# full|mvp|single-thread; an absent/unrecognized value is treated as fail-closed below (the Stop hook
# is the SOLE gate on the no-batch path, so a non-fail-closed unknown re-opens the exact spec-169
# bypass — architecture-review finding #1). Mirrors check-role-dispatch's FIX#1 posture.
pipeline="$(field_str "$mk" pipeline)"

# direct-pipeline delivery signal — a run that delivers without the batch ledger
# (`/team-bootstrap single-thread …`) proves delivery by real code committed since baseline.
csb=0
code_since_baseline "$(field_str "$mk" baseline_sha)" && csb=1

ledger="$(resolve_ledger)"
announced_code=0
closed_code=0
closed_ids=""
if [ -n "$ledger" ] && [ -f "$ledger" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field_str "$line" kind)" = "code" ] || continue
    case "$(field_str "$line" status)" in
      announced) announced_code=$((announced_code + 1)) ;;
      closed)    closed_code=$((closed_code + 1)); closed_ids="$closed_ids $(field_str "$line" id)" ;;
    esac
  done < "$ledger"
fi

# WS-A prong 1 (AC-A1/A2/A5) — the `csb` direct-delivery allowance (shipping code with no batch
# ledger) is legitimate ONLY for single-thread, the pipeline with no role fan-out. For full/mvp — and,
# fail-closed, for an ABSENT or unrecognized pipeline — a run that shipped code must show a real EARNED
# batch closure; bare code-since-baseline on those pipelines is the degraded, no-reviewer path the
# audit reproduced as Stop exit 0.
csb_ok=0
[ "$pipeline" = "single-thread" ] && [ "$csb" -eq 1 ] && csb_ok=1

# WS-A prong 2 (AC-A3) — independently assert the >=1 reviewer floor at RUN-CLOSE, not only inside
# verify-batch: for a full/mvp run whose closed kind:code batches are observable via dispatch.jsonl, at
# least one must carry a reviewer-typed subagent dispatch (shared reviewer_dispatch_count — single
# source with the gate). Where dispatch.jsonl is absent the verify-batch stamp is trusted (the
# documented ADR-0006 forgeability ceiling; WS-A stays at that ceiling — no overclaim).
role_floor_ok=1
case "$pipeline" in
  full|mvp)
    rundir_d="$(dirname "$marker")"
    if [ "$closed_code" -gt 0 ] && [ -f "$rundir_d/dispatch.jsonl" ]; then
      role_floor_ok=0
      for cid in $closed_ids; do
        [ -n "$cid" ] || continue
        [ "$(reviewer_dispatch_count "$cid")" -ge 1 ] && { role_floor_ok=1; break; }
      done
    fi ;;
esac

# BLOCK when: an announced code batch is still unclosed; OR no earned closure exists and the csb
# allowance does not apply (prong 1); OR the run-close reviewer floor is unmet (prong 2).
if [ "$announced_code" -gt 0 ] || { [ "$closed_code" -eq 0 ] && [ "$csb_ok" -eq 0 ]; } || [ "$role_floor_ok" -eq 0 ]; then
  run="$(field_str "$mk" run)"
  {
    echo "delivery-stop-hook: BLOCKED — active delivery run '${run:-?}' has unfinished code delivery"
    echo "  (pipeline: ${pipeline:-<absent>}; announced-but-unclosed kind:code batches: $announced_code;"
    echo "   earned closures: $closed_code; reviewer floor met: $([ "$role_floor_ok" -eq 1 ] && echo yes || echo no);"
    echo "   code committed since baseline: $([ "$csb" -eq 1 ] && echo yes || echo no))."
    if [ "$role_floor_ok" -eq 0 ]; then
      echo "  A $pipeline run's closed code batch shows ZERO independent-reviewer dispatch (spec-169 collapse"
      echo "  signature at run-close). Dispatch a review role as a subagent, or run single-thread if one mind is intended."
    elif [ "$csb_ok" -eq 0 ] && [ "$closed_code" -eq 0 ] && [ "$csb" -eq 1 ]; then
      echo "  This ${pipeline:-<absent>-pipeline} run shipped code with no earned batch closure. The bare"
      echo "  code-since-baseline allowance is retained only for single-thread; full/mvp (and an absent/unknown"
      echo "  pipeline, fail-closed) must close a real batch with a reviewer — bin/verify-batch.sh."
    else
      echo "  Finish it: close a batch with bin/verify-batch.sh (a real commit + code_delta), OR — for a"
      echo "  single-thread direct run with no ledger — commit real code (accepted as code since the run baseline)."
    fi
    echo "  If the run is genuinely finished or abandoned, end it by removing its marker"
    echo "  (.runs/${run:-<run>}/RUN). A delivery run may not stop with code work undelivered (P6/P9)."
  } >&2
  exit 2
fi
exit 0
