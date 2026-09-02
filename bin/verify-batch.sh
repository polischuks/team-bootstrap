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

  # Exclude a batch's non-IMPL commits from commit_shas. commit_shas must be the batch's own CODE
  # commits, because check-tdd anchors on the OLDEST commit_sha, and check-delivery recomputes code_delta
  # over exactly these SHAs. A commit that carries no impl — every file it changed is a test path OR a doc
  # path — is never a code anchor:
  #   - RED: the TDD red step commits the failing test FIRST (that commit is the red_sha, test-only). Left
  #     in, it is the oldest commit_sha, and red_sha cannot be a proper ancestor of itself, so the batch
  #     would FAIL after it was closed.
  #   - DOC (#93): a Phase-A `docs(spec-…)` commit (spec/plan/tasks) after baseline and before the batch's
  #     code sits in the range. Left in, it is the oldest commit_sha → check-tdd's anchor is a DOC commit,
  #     the batch's own red (committed AFTER it) is not its ancestor → a LATER batch's re-verification
  #     FAILS a batch that passed its own close.
  #   - TEST-ONLY ORPHAN (#93 definitive): a rejected wrong-cause first-red (#68) replaced by an importable
  #     stub and NOT recorded in tdd.jsonl leaves a clean test-only commit orphaned. It is not a recorded
  #     red_sha and its nondoc_delta > 0 (a test file is non-doc), so the old doc-only filter kept it — it
  #     became the oldest commit_sha and the leaked anchor.
  # The one filter that subsumes all three: drop any commit whose IMPL delta is zero (impl_delta_of_shas
  # composes _is_doc_path + is_test_path). The recorded-red exclusion is kept as belt-and-suspenders below.
  # code_delta is then computed on the SAME impl-only basis, so a mixed test+impl window is not inflated by
  # its test lines and stays ≤ check-delivery's nondoc recompute (AC-2 holds by construction).
  local tdd rl rs rf red_fulls="" s sfull filtered=""
  tdd="$(dirname "$ledger")/tdd.jsonl"
  if [ -f "$tdd" ]; then
    while IFS= read -r rl; do
      [ -n "$rl" ] || continue
      rs="$(field_str "$rl" red_sha)"; [ -n "$rs" ] || continue
      rf="$(resolve_sha "$rs")"; [ -n "$rf" ] && red_fulls="$red_fulls $rf"
    done < "$tdd"
  fi
  for s in $shas_list; do
    sfull="$(resolve_sha "$s")"
    case " $red_fulls " in *" $sfull "*) continue ;; esac
    # impl-empty commit (every changed file is a test path OR a doc path) → never the code-anchor of a
    # code batch (#93 definitive: subsumes doc-only + test-only-orphan; recorded reds are dropped above).
    [ "$(impl_delta_of_shas "$s")" = "0" ] && continue
    filtered="$filtered $s"
  done
  shas_list="$(printf '%s' "$filtered" | xargs 2>/dev/null || true)"
  shas="$(printf '%s' "$shas_list" | sed 's/[[:space:]]*$//;s/  */,/g')"

  # code_delta on the IMPL-only basis (impl_delta_of_shas) — the same non-test-non-doc definition the
  # filter above used. Because every stamped SHA has impl_delta > 0, the sum is > 0 (no false "changed no
  # code"); and impl_delta ≤ nondoc_delta over the same SHAs, so this stamped value never EXCEEDS
  # check-delivery's nondoc recompute (AC-2's `delta > recomputed` → forged), which stays honest by
  # construction. A mixed test+impl window is therefore credited only for its impl lines, never inflated.
  local delta
  delta="$(impl_delta_of_shas "$shas_list")"; case "$delta" in ''|*[!0-9]*) delta=0 ;; esac

  local shas_json="[]"
  [ -n "$shas" ] && shas_json="[\"$(printf '%s' "$shas" | sed 's/,/","/g')\"]"
  local gates="quality-gate=ok;orphans=ok;architecture=ok;gate-integrity=ok;tdd=ok;version-sync=ok;diff-coverage=ok;mutation=ok;enforcement=ok;completeness=ok;seam-ack=ok;disposition=ok;review-ack=ok;role-dispatch=ok;delivery=ok"

  # closed_at — the wall-clock second this batch closed (issue #61). This is the only per-batch END this
  # plugin observes (only this script flips a batch to closed), so it anchors per-batch wall-time in
  # delivery-metrics: batch N's wall-time = closed_at[N] - closed_at[N-1], with the first batch measured
  # from the run's earliest recorded activity. TB_NOW_EPOCH-stubbable via delivery-lib's _now_epoch, so
  # the self-test below is deterministic and never reads the real clock.
  local closed_at; closed_at="$(_now_epoch)"

  local newline
  newline="$(printf '%s' "$target" \
    | sed -E 's/"status":[[:space:]]*"announced"/"status":"closed"/' \
    | sed 's/}[[:space:]]*$/,"commit_shas":'"$shas_json"',"code_delta":'"$delta"',"gate_results":"'"$gates"'","closed_at":'"$closed_at"'}/')"

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
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TB_NOW_EPOCH=1724800000 stamp_batch_closed ) 2>/dev/null
  got="$(grep -oE '"commit_shas":\[[^]]*\]' "$T/.runs/r/batches.jsonl" 2>/dev/null)"
  if printf '%s' "$got" | grep -q "$impl" && ! printf '%s' "$got" | grep -q "$red"; then
    echo "  PASS commit_shas is IMPL-only ($got) — test-only RED excluded, window = baseline"
  else echo "  FAIL commit_shas=$got (want IMPL=$impl present, RED=$red absent)" >&2; fail=$((fail + 1)); fi
  # issue #61 — the close stamps a DETERMINISTIC closed_at (the injected TB_NOW_EPOCH, never the real
  # clock), so delivery-metrics can attribute per-batch wall-time. This is the per-batch END anchor.
  if grep -q '"closed_at":1724800000' "$T/.runs/r/batches.jsonl" 2>/dev/null; then
    echo "  PASS batch close stamps the injected closed_at wall-clock (per-batch timing, #61)"
  else echo "  FAIL closed_at not stamped: $(cat "$T/.runs/r/batches.jsonl")" >&2; fail=$((fail + 1)); fi
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

  # #93 definitive — a TEST-ONLY ORPHAN commit (a clean test-only commit that is NOT a recorded red_sha:
  # e.g. a #68-rejected first-red replaced by an importable stub, left dangling) must be excluded from
  # commit_shas by the IMPL-delta filter, even though its nondoc_delta > 0 (a test file is non-doc) and
  # the old doc-only filter kept it. Left in, it is the oldest commit_sha and leaks as the tdd anchor.
  T3="$(mktemp -d)"
  ( cd "$T3" && git init -q && git config user.email t@t && git config user.name t
    echo base > app.sh && git add . && git commit -qm c0 ) >/dev/null 2>&1
  o3base="$(cd "$T3" && git rev-parse --short HEAD)"
  ( cd "$T3" && echo t > orphan_test.sh && git add orphan_test.sh && git commit -qm "orphan test (not a recorded red)" ) >/dev/null 2>&1
  o3orphan="$(cd "$T3" && git rev-parse --short HEAD)"
  ( cd "$T3" && echo impl >> app.sh && git add app.sh && git commit -qm IMPL ) >/dev/null 2>&1
  o3impl="$(cd "$T3" && git rev-parse --short HEAD)"
  mkdir -p "$T3/.runs/r"
  printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$o3base" > "$T3/.runs/r/RUN"
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T3/.runs/r/batches.jsonl"
  : > "$T3/.runs/r/tdd.jsonl"   # the orphan is NOT recorded as a red
  ( cd "$T3" && TEAM_BOOTSTRAP_RUN=r stamp_batch_closed ) 2>/dev/null
  got3="$(grep -oE '"commit_shas":\[[^]]*\]' "$T3/.runs/r/batches.jsonl" 2>/dev/null)"
  if printf '%s' "$got3" | grep -q "$o3impl" && ! printf '%s' "$got3" | grep -q "$o3orphan"; then
    echo "  PASS test-only orphan excluded from commit_shas by impl-delta filter ($got3) — #93 definitive"
  else echo "  FAIL test-only orphan leaked: $got3 (want IMPL=$o3impl present, orphan=$o3orphan absent)" >&2; fail=$((fail + 1)); fi
  rm -rf "$T3"

  if [ "$fail" -eq 0 ]; then echo "verify-batch --self-test: OK"; exit 0; fi
  echo "verify-batch --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# issue #95 — say it HERE, in verify-batch's own output, not only in commands/deliver.md doctrine (which
# lands ~70% of the time). This run executes the full Test: suite + the whole gate cascade and routinely
# exceeds the Bash tool's ~2-minute default timeout; a killed run reads as a FAILURE and forces a full
# re-run. Invoke it with a long timeout (e.g. 600000 ms) or in the background.
echo "verify-batch: NOTE — runs the full Test: suite + gate cascade; can exceed the ~2-minute Bash default. Invoke with a long timeout (e.g. 600000) or in the background — a killed run reads as a failure. (#95)" >&2

gate "quality-gate (typecheck + lint)"      "$here/quality-gate.sh" .
gate "orphans (dead code / not wired)"       "$here/check-orphans.sh"
gate "architecture (drift vs baseline)"      "$here/check-architecture.sh" .
gate "gate-integrity (no skip / disabled)"   "$here/check-gate-integrity.sh" .
gate "role-triples (a dispatchable role is complete)" "$here/check-role-triples.sh" .
gate "role-liveness (every routed role is load-bearing, P12)" "$here/check-role-liveness.sh" .
gate "context-phrasing (facts, never imperatives)" "$here/check-context-phrasing.sh" .
gate "version-sync (manifests agree)"        "$here/check-version-sync.sh" .
gate "diff-coverage (changed-line breadth, F2)" "$here/check-diff-coverage.sh" .
gate "mutation (assertion strength, F3)"     "$here/check-mutation.sh" .
gate "enforcement (no silent skip, A)"       "$here/check-enforcement.sh" .
gate "completeness (task_ids [x], B)"        "$here/check-completeness.sh" .
gate "seam-ack (high-risk seam read, C)"     "$here/check-seam-ack.sh" .
gate "disposition (MEDIUM+ finding governed, B)" "$here/check-disposition.sh" .
gate "review-ack (independent review of diff, C)" "$here/check-review-ack.sh" .
# tdd runs the full Test: suite at HEAD — the most expensive gate here. Order it AFTER the cheap
# marker/process gates above (enforcement/completeness/seam-ack/disposition/review-ack), so a retry
# tripped by one of those (they only rewrite the .runs/ ledger) never pays for the suite (#97). Its own
# result is tree-keyed cached, so a genuine retry against an unchanged tree is already cheap.
gate "tdd (red→green observed, P9)"          "$here/check-tdd.sh" .
# Batch-scoped EXTRA suites (#109). The gates above run only the narrow AGENTS.md `Test:` command, so a
# migration's integration invariants (Test: excludes `-m "not integration"`), a frontend/console suite,
# and the repo's own CI-guards are blind spots the close gate never runs — caught only by fallible LLM
# reviewers or at merge. This step runs them when the batch's own paths need them, OPT-IN via AGENTS.md
# IntegrationTest:/ConsoleTest:/Guards: (absent ⇒ warn, never block). It is a SELF-CONTAINED extra step:
# it does not touch stamp_batch_closed, the commit_shas filter, or the ordering of the gates around it —
# and drives the need off the SAME per-batch classifier (select-pipeline risk categories) that sizes the
# review roles below, so "this batch touches migrations/frontend" has one definition and cannot drift.
gate "batch-suites (integration/console/CI-guards, #109)" "$here/check-batch-suites.sh" .
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
