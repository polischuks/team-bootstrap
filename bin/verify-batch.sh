#!/usr/bin/env bash
# verify-batch.sh — the harness-enforced batch gate.
#
# The reviewer roles (integration-verifier, code-reviewer, architecture-reviewer,
# regression-guardian) are prose the orchestrator can skip (~70% adherence). This
# script enforces the OUTCOMES those roles exist to guarantee, regardless of which
# roles actually ran — so a /deliver batch cannot pass by skipping review:
#   - quality-gate    : typecheck + lint (from AGENTS.md)
#   - check-orphans   : dead code / created-but-not-wired
#   - check-architecture : drift from the baseline
#   - check-gate-integrity : no green-by-skip / disabled gate
#   - check-delivery  : no unearned closure (a prior code batch announced but never closed)
#
# On success it STAMPS the in-flight batch closed in the run ledger
# (.runs/<run>/batches.jsonl): status->closed + commit_shas + code_delta. Only this
# script — not the orchestrator's prose — can flip a batch to closed. That is what
# makes "batch closed" a machine fact, not a claim (see check-delivery.sh).
#
# Run it at batch completion AND in CI (the independent backstop that catches a
# batch whose local run skipped the roles). See references/enforcement.md.
#
# Usage: bin/verify-batch.sh [project-dir]   # default: current dir
# Exit:  0 all gates pass · 1 a gate failed · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-.}"
if [ "$root" != "--self-test" ]; then
  cd "$root" 2>/dev/null || { echo "verify-batch: bad dir '$root'" >&2; exit 64; }
fi
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

fails=0
gate() {
  local name="$1"; shift
  echo "verify-batch: → $name" >&2
  if "$@"; then
    echo "verify-batch:   OK — $name" >&2
  else
    echo "verify-batch:   FAILED — $name" >&2
    fails=$((fails + 1))
  fi
}

# stamp_batch_closed — machine-only closure. On a passing batch, flip the in-flight
# (last still-announced) ledger entry to status:closed and record the commit_shas and
# code_delta that earned it. No ledger / nothing in flight -> no-op. This is the half
# the orchestrator cannot do in prose: closure becomes a recorded fact.
stamp_batch_closed() {
  local ledger; ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0

  local target
  target="$(grep -nE '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1 | sed -E 's/^[0-9]+://')"
  [ -n "$target" ] || return 0   # nothing in flight to close

  # per-batch commit range: since the PREVIOUS closed batch's newest commit (so each batch's
  # code_delta counts only its own work, not the cumulative run). The base is computed by the
  # shared delivery-lib current_batch_base — the SAME window F2 (check-diff-coverage) measures, so
  # "the batch's changed lines" is one definition and cannot drift (spec R1). Falls back to
  # main..HEAD for the first batch, else HEAD~1..HEAD.
  local range
  range="$(current_batch_base)..HEAD"

  # the batch's commits, space-separated (for the shared delta fn) and comma-joined
  # (for the ledger JSON). One list, two renderings.
  local shas_list shas
  shas_list="$(git log --format=%h "$range" 2>/dev/null | head -50 | tr '\n' ' ' || true)"

  # Exclude test-only RED commits from commit_shas. The TDD red step commits the failing test
  # FIRST (that commit becomes the red_sha), then implementation follows. commit_shas must be
  # IMPL-only: otherwise the RED commit is the OLDEST commit_sha, which check-tdd uses as the
  # batch's code-anchor — and red_sha cannot be a proper ancestor of itself, so the batch would
  # FAIL after it was closed. Drop any stamped commit that is a recorded red_sha for this run.
  local tdd rl rs rf red_fulls="" s sfull filtered=""
  tdd="$(dirname "$ledger")/tdd.jsonl"
  if [ -f "$tdd" ]; then
    while IFS= read -r rl; do
      [ -n "$rl" ] || continue
      rs="$(field_str "$rl" red_sha)"; [ -n "$rs" ] || continue
      rf="$(resolve_sha "$rs")"; [ -n "$rf" ] && red_fulls="$red_fulls $rf"
    done < "$tdd"
  fi
  if [ -n "$red_fulls" ]; then
    for s in $shas_list; do
      sfull="$(resolve_sha "$s")"
      case " $red_fulls " in *" $sfull "*) continue ;; esac
      filtered="$filtered $s"
    done
    shas_list="$(printf '%s' "$filtered" | xargs 2>/dev/null || true)"
  fi
  shas="$(printf '%s' "$shas_list" | sed 's/[[:space:]]*$//;s/  */,/g')"

  # code_delta from the SAME shared function check-delivery.sh recomputes with
  # (delivery-lib.sh nondoc_delta_of_shas) — per-commit non-doc sum over exactly the
  # stamped SHAs. Sharing this makes stamp == recompute by construction (spec R1),
  # so a batch this script closes always survives the check-delivery recompute.
  local delta
  delta="$(nondoc_delta_of_shas "$shas_list")"; case "$delta" in ''|*[!0-9]*) delta=0 ;; esac

  local shas_json="[]"
  [ -n "$shas" ] && shas_json="[\"$(printf '%s' "$shas" | sed 's/,/","/g')\"]"
  local gates="quality-gate=ok;orphans=ok;architecture=ok;gate-integrity=ok;tdd=ok;version-sync=ok;diff-coverage=ok;mutation=ok;enforcement=ok;completeness=ok;seam-ack=ok;disposition=ok;review-ack=ok;role-dispatch=ok;delivery=ok"

  local newline
  newline="$(printf '%s' "$target" \
    | sed -E 's/"status":[[:space:]]*"announced"/"status":"closed"/' \
    | sed 's/}[[:space:]]*$/,"commit_shas":'"$shas_json"',"code_delta":'"$delta"',"gate_results":"'"$gates"'"}/')"

  local tmp; tmp="$(mktemp)"
  while IFS= read -r l; do
    if [ "$l" = "$target" ]; then printf '%s\n' "$newline"; else printf '%s\n' "$l"; fi
  done < "$ledger" > "$tmp" && mv "$tmp" "$ledger"
  echo "verify-batch: stamped closed in $ledger — code_delta=$delta shas=${shas:-none}" >&2
}

# --- self-test: stamp_batch_closed writes IMPL-only commit_shas over the baseline window --------
# Locks the bug where the test-only RED commit (and pre-baseline commits via the origin/main
# fallback) leaked into commit_shas, breaking check-tdd's oldest-commit anchor after closure.
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo base > app.sh && git add . && git commit -qm c0 ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && echo t > app_test.sh && git add app_test.sh && git commit -qm RED ) >/dev/null 2>&1
  red="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && : > .green && echo impl >> app.sh && git add . && git commit -qm IMPL ) >/dev/null 2>&1
  impl="$(cd "$T" && git rev-parse --short HEAD)"
  mkdir -p "$T/.runs/r"
  printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
  printf '{"batch":"B1","red_sha":"%s","observed":"red"}\n' "$red" > "$T/.runs/r/tdd.jsonl"
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r stamp_batch_closed ) 2>/dev/null
  got="$(grep -oE '"commit_shas":\[[^]]*\]' "$T/.runs/r/batches.jsonl" 2>/dev/null)"
  if printf '%s' "$got" | grep -q "$impl" && ! printf '%s' "$got" | grep -q "$red"; then
    echo "  PASS commit_shas is IMPL-only ($got) — test-only RED excluded, window = baseline"
  else echo "  FAIL commit_shas=$got (want IMPL=$impl present, RED=$red absent)" >&2; fail=$((fail + 1)); fi
  rm -rf "$T"

  # whitespace tolerance: an announced entry with a SPACE after the colon (any JSON serializer using
  # default separators) must still be stamped closed — peer gates match '"status":[[:space:]]*"announced"',
  # so stamp_batch_closed must not be stricter (else the batch stays announced with no stamp, a silent no-op).
  T2="$(mktemp -d)"
  ( cd "$T2" && git init -q && git config user.email t@t && git config user.name t
    echo base > app.sh && git add . && git commit -qm c0
    echo more >> app.sh && git add . && git commit -qm impl ) >/dev/null 2>&1
  b2="$(cd "$T2" && git rev-parse --short HEAD~1)"
  mkdir -p "$T2/.runs/r"
  printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$b2" > "$T2/.runs/r/RUN"
  printf '{"id":"B1","kind":"code","status": "announced"}\n' > "$T2/.runs/r/batches.jsonl"
  ( cd "$T2" && TEAM_BOOTSTRAP_RUN=r stamp_batch_closed ) 2>/dev/null
  if grep -q '"status":"closed"' "$T2/.runs/r/batches.jsonl"; then
    echo "  PASS spaced '\"status\": \"announced\"' stamped closed (whitespace-tolerant)"
  else echo "  FAIL spaced status left unstamped: $(cat "$T2/.runs/r/batches.jsonl")" >&2; fail=$((fail + 1)); fi
  rm -rf "$T2"

  if [ "$fail" -eq 0 ]; then echo "verify-batch --self-test: OK"; exit 0; fi
  echo "verify-batch --self-test: $fail case(s) FAILED" >&2; exit 1
fi

gate "quality-gate (typecheck + lint)"      "$here/quality-gate.sh" .
gate "orphans (dead code / not wired)"       "$here/check-orphans.sh"
gate "architecture (drift vs baseline)"      "$here/check-architecture.sh" .
gate "gate-integrity (no skip / disabled)"   "$here/check-gate-integrity.sh" .
gate "role-triples (a dispatchable role is complete)" "$here/check-role-triples.sh" .
gate "role-liveness (every routed role is load-bearing, P12)" "$here/check-role-liveness.sh" .
gate "context-phrasing (facts, never imperatives)" "$here/check-context-phrasing.sh" .
gate "tdd (red→green observed, P9)"          "$here/check-tdd.sh" .
gate "version-sync (manifests agree)"        "$here/check-version-sync.sh" .
gate "diff-coverage (changed-line breadth, F2)" "$here/check-diff-coverage.sh" .
gate "mutation (assertion strength, F3)"     "$here/check-mutation.sh" .
gate "enforcement (no silent skip, A)"       "$here/check-enforcement.sh" .
gate "completeness (task_ids [x], B)"        "$here/check-completeness.sh" .
gate "seam-ack (high-risk seam read, C)"     "$here/check-seam-ack.sh" .
gate "disposition (MEDIUM+ finding governed, B)" "$here/check-disposition.sh" .
gate "review-ack (independent review of diff, C)" "$here/check-review-ack.sh" .
# The sized role set is fixed HERE, in code, immediately before the gate that reads it — not requested
# from the orchestrator in commands/deliver.md prose at announce time. Two reasons, and the gate's own
# comment (check-role-dispatch.sh) already stated both: prose lands ~70% of the time against a hook's
# ~100%, so nothing actually wired it and the recorded-set (enforce) branch was unreachable in
# production; and at announce the batch window is still EMPTY, so the set computed then is sized
# against no diff. Best-effort by construction — a ledger that cannot be rewritten leaves the gate on
# its advisory path, exactly as before, and never blocks a close on a bookkeeping failure.
_ib="$(inflight_batch)"
if [ -n "$_ib" ] && [ "$(field_str "$_ib" kind)" = "code" ] \
   && [ "$(field_str "$_ib" status)" = "announced" ]; then
  record_required_roles "$(field_str "$_ib" id)" || \
    echo "verify-batch: WARN — could not record required_roles for '$(field_str "$_ib" id)'; the dispatch gate stays advisory." >&2
fi
gate "role-dispatch (reviewer subagent ran, not inline collapse)" "$here/check-role-dispatch.sh" .
gate "role-verdict (each required role returned a typed verdict)" "$here/check-role-verdict.sh" --gate .
gate "delivery (no unearned closure)"        "$here/check-delivery.sh" .

if [ "$fails" -gt 0 ]; then
  echo "verify-batch: $fails gate(s) failed — batch cannot pass. Fix and re-run." >&2
  exit 1
fi
stamp_batch_closed
# issue #22 — surface a review LOOP before it eats the budget. Advisory only: it never affects the exit
# code, and it runs AFTER the stamp so it can never gate a closure. This is the one place the operator
# reliably reads (per batch), which is why the escalation lives here rather than in a PreToolUse hook
# whose exit-0 stderr the harness does not surface.
review_loop_signals || true
echo "verify-batch: all gates passed."
exit 0
