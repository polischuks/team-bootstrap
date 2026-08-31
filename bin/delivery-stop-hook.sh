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
  # The cases below need one thing of their baseline: that there IS non-doc code between it and HEAD,
  # so code_since_baseline is true and the decision under test (single-thread allow / full block /
  # absent-pipeline block) is the one exercised. The root commit satisfies that — but it forces
  # code_since_baseline to walk the whole 300+-commit history (its 200-sha cap, a git-show per sha)
  # on EVERY such case: ~6s each, ~36s across this block, and it dominated the suite's slowest member.
  # A near baseline exercises the identical decision at ~1/85th. It is chosen by walking back with the
  # SAME authority the hook uses — code_since_baseline itself — so the fixture can never disagree with
  # the code under test about what "code since baseline" means, and it falls back to root if the recent
  # window were ever doc-only. Normally it stops at HEAD~1 (measured 0.07s vs 5.92s).
  csb_base=""
  for _n in 1 2 3 5 8; do
    _cand="$(git rev-parse --short "HEAD~$_n" 2>/dev/null)" || break
    if code_since_baseline "$_cand"; then csb_base="$_cand"; break; fi
  done
  : "${csb_base:=$root_sha}"
  # WS-A AC-A2 — allow: single-thread DIRECT run (no ledger) that committed code since baseline. The
  # csb allowance is retained only for the pipeline that has no role fan-out.
  mkdir -p ".runs/${d}_direct"
  printf '%s\n' "{\"run\":\"dr\",\"pipeline\":\"single-thread\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_direct/RUN"
  _expect "${d}_direct" 0 "allow — single-thread direct run, no ledger, code since baseline → exit 0 (AC-A2)"
  # WS-A AC-A1 — block: FULL direct run, code since baseline, no earned closure → the csb allowance is
  # refused for full/mvp (the audit's spec-169 no-batch path, formerly Stop exit 0).
  mkdir -p ".runs/${d}_dfull"
  printf '%s\n' "{\"run\":\"df\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_dfull/RUN"
  _expect "${d}_dfull" 2 "block — full direct run, no earned closure → exit 2 (AC-A1)"
  # WS-A AC-A5 — block: ABSENT pipeline, code since baseline, no closure → fail-closed (finding #1).
  mkdir -p ".runs/${d}_dnopipe"
  printf '%s\n' "{\"run\":\"dn\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_dnopipe/RUN"
  _expect "${d}_dnopipe" 2 "block — absent-pipeline direct run → exit 2 (AC-A5, fail-closed)"
  # WS-A AC-A3a — allow: full run, closed batch WITH a reviewer dispatch → run-close floor met.
  mkdir -p ".runs/${d}_frev"
  printf '%s\n' "{\"run\":\"fr\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_frev/RUN"
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$root_sha\"],\"code_delta\":4}" > ".runs/${d}_frev/batches.jsonl"
  printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer"}' > ".runs/${d}_frev/dispatch.jsonl"
  _expect "${d}_frev" 0 "allow — full run, closed batch + reviewer dispatch → exit 0 (AC-A3a)"
  # WS-A AC-A3b — block: full run, closed batch but ZERO reviewer dispatch (dispatch.jsonl present).
  mkdir -p ".runs/${d}_fnorev"
  printf '%s\n' "{\"run\":\"fn\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_fnorev/RUN"
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$root_sha\"],\"code_delta\":4}" > ".runs/${d}_fnorev/batches.jsonl"
  printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer"}' > ".runs/${d}_fnorev/dispatch.jsonl"
  _expect "${d}_fnorev" 2 "block — full run, closed batch, zero reviewer dispatch → exit 2 (AC-A3b)"
  # WS-A AC-A5b (review CRITICAL-1) — block: ABSENT pipeline, closed batch, zero reviewer dispatch. The
  # reviewer floor is a DENYLIST (only single-thread exempt), so an unknown/legacy pipeline cannot skip it.
  mkdir -p ".runs/${d}_unkclosed"
  printf '%s\n' "{\"run\":\"uc\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_unkclosed/RUN"
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$root_sha\"],\"code_delta\":4}" > ".runs/${d}_unkclosed/batches.jsonl"
  printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer"}' > ".runs/${d}_unkclosed/dispatch.jsonl"
  _expect "${d}_unkclosed" 2 "block — absent-pipeline, closed batch, zero reviewer dispatch → exit 2 (AC-A5b)"
  # issue #65 — allow: announced-unclosed kind:code batch with code since baseline AND a reviewer
  # dispatched for it → WAITING for live reviewers, not abandoned. (code_state_since is `code` here, so
  # the D7 no-code relaxation does NOT apply — reviewers_in_flight is what allows it.)
  mkdir -p ".runs/${d}_waitrev"
  printf '%s\n' "{\"run\":\"wr\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_waitrev/RUN"
  printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > ".runs/${d}_waitrev/batches.jsonl"
  printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer","outcome":"attempted"}' > ".runs/${d}_waitrev/dispatch.jsonl"
  _expect "${d}_waitrev" 0 "allow — announced batch + reviewer in flight → exit 0 (issue #65 waiting)"
  # issue #65 fail-closed twin — announced-unclosed kind:code batch, code since baseline, but ZERO
  # reviewer dispatch (no dispatch.jsonl) → genuinely abandoned Phase B → still block.
  mkdir -p ".runs/${d}_waitnorev"
  printf '%s\n' "{\"run\":\"wn\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csb_base\"}" > ".runs/${d}_waitnorev/RUN"
  printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > ".runs/${d}_waitnorev/batches.jsonl"
  _expect "${d}_waitnorev" 2 "block — announced batch, code since baseline, zero reviewer dispatch → exit 2 (issue #65 fail-closed)"
  # block: armed run that delivered nothing (no ledger, no code since baseline=HEAD)
  mkdir -p ".runs/${d}_empty"
  printf '%s\n' "{\"run\":\"e\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$(git rev-parse --short HEAD 2>/dev/null)\"}" > ".runs/${d}_empty/RUN"
  _expect "${d}_empty" 2 "block — armed run, no ledger, no code since baseline → exit 2"

  # --- D7: waiting for the operator is not skipping Phase B (spec 021, B5) -----------------------
  #
  # An announced-unclosed kind:code batch blocked unconditionally. That state is ALSO the normal one
  # while the flow legitimately waits for an operator decision before Phase B, and nothing in the hook
  # told the two apart (measured: zero fields distinguish them).
  #
  # The distinguishing signal is OBSERVABLE, never declared (R3): an announced_sha the orchestrator
  # writes into the ledger is forgeable by the same mind this gate exists to check. The anchor is
  # current_batch_base — the window definition closure already uses — and the question asked of it is
  # "has any non-doc code moved that no closure covers?".
  #
  # These run in their OWN repo, not this one: fixture A asserts on a CLEAN non-doc working tree, and
  # asserting that against the live checkout would make the case pass or fail on whatever the developer
  # happens to have uncommitted.
  _d7="$(mktemp -d)"
  ( cd "$_d7" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir -p .runs/w src && echo base > src/app.js && git add . && git commit -qm base ) >/dev/null 2>&1
  _d7_head() { ( cd "$_d7" && git rev-parse --short HEAD ); }
  _d7_marker() { printf '%s\n' "{\"run\":\"w\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$1\"}" > "$_d7/.runs/w/RUN"; }
  _d7_expect() { # expected desc
    local exp="$1" desc="$2" got
    # $0 is relative when this suite is invoked as `bin/delivery-stop-hook.sh`, and these cases run
    # from another directory — resolve through $here or the subshell finds nothing (exit 127).
    ( cd "$_d7" && TEAM_BOOTSTRAP_RUN=w "$here/$(basename "$0")" </dev/null >/dev/null 2>&1 ); got=$?
    if [ "$got" -eq "$exp" ]; then echo "  PASS (exit $got) $desc"
    else echo "  FAIL (exit $got, want $exp) $desc" >&2; fail=$((fail + 1)); fi
  }
  printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$_d7/.runs/w/batches.jsonl"

  # AC-15 — announced-unclosed, nothing has moved since the anchor, clean tree ⇒ WAITING. Do not block.
  _d7_marker "$(_d7_head)"
  _d7_expect 0 "AC-15 announced-unclosed with no code since the anchor → waiting, not blocked"

  # AC-16 — the paired fixture, differing by ONE COMMIT. Code exists that no closure covers ⇒ Phase B
  # was skipped. Block, exactly as before.
  # `src/app.js`, not `code.txt`: `.txt` is a DOC extension to _is_doc_path, so a fixture built on it
  # would assert "code exists" with no code in it and pass for the wrong reason.
  ( cd "$_d7" && echo more >> src/app.js && git commit -qam work ) >/dev/null 2>&1
  _d7_expect 2 "AC-16 announced-unclosed WITH a commit after the anchor → still blocked"

  # AC-16 — commits are not the whole observable. Real, UNCOMMITTED non-doc edits under an announced
  # batch are the spec's own "код есть, батч не закрыт" fixture, and a commit-only anchor would let
  # this stop cleanly (plan §8.1).
  _d7_marker "$(_d7_head)"
  ( cd "$_d7" && echo dirty >> src/app.js )
  _d7_expect 2 "AC-16 uncommitted non-doc edits under an announced batch → still blocked"

  # AC-15 — and the working-tree read must be scoped to NON-doc paths, or committing tasks.md while
  # waiting flips waiting into skipping and the relaxation delivers nothing.
  ( cd "$_d7" && git checkout -q -- src/app.js && mkdir -p docs && echo note >> docs/notes.md )
  _d7_expect 0 "AC-15 an uncommitted DOC edit does not turn waiting into skipping"
  ( cd "$_d7" && rm -rf docs )

  # AC-16 — an UNRESOLVABLE anchor is not "no code". code_since_baseline returns rc 1 for no-code, for
  # an unresolvable sha AND for git failing, and mapping that one rc to "allow" would let an amended
  # history or a shallow clone stop cleanly with an announced batch open (plan §8.1). Three-valued:
  # cannot-determine blocks.
  _d7_marker "0000000"
  _d7_expect 2 "AC-16 an unresolvable anchor blocks — cannot-determine is not no-code"

  rm -rf "$_d7"

  rm -rf ".runs/${d}_block" ".runs/${d}_closed" ".runs/${d}_nomarker" ".runs/${d}_direct" ".runs/${d}_dfull" ".runs/${d}_dnopipe" ".runs/${d}_frev" ".runs/${d}_fnorev" ".runs/${d}_unkclosed" ".runs/${d}_waitrev" ".runs/${d}_waitnorev" ".runs/${d}_empty"
  if [ "$fail" -eq 0 ]; then echo "delivery-stop-hook --self-test: OK"; exit 0; fi
  echo "delivery-stop-hook --self-test: $fail case(s) FAILED" >&2; exit 1
fi

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
cat >/dev/null 2>&1 || true   # drain the Stop payload (unused)

marker="$(resolve_marker)"
# D4 (spec 021 AC-10) — an AMBIGUOUS resolution is not "no run": two .runs/*/RUN tied on mtime with no
# .runs/current. It reaches here as the sentinel, for which [ -f ] is false, so the plain no-run check
# below would exit 0 and let a possibly-unfinished run stop cleanly — a fail-OPEN on exactly the
# tamper/ambiguity class ADR-0015 exists to close. Fail CLOSED, distinct from a clean no-run allow, and
# tell the operator how to disambiguate.
if marker_ambiguous "$marker"; then
  echo "delivery-stop-hook: BLOCKED — the active run is AMBIGUOUS: two runs under .runs/ share the newest" >&2
  echo "  timestamp and no .runs/current names the intended one, so which run this Stop belongs to cannot" >&2
  echo "  be resolved. Failing closed rather than guessing. Pin it with TEAM_BOOTSTRAP_RUN=<id>, or write" >&2
  echo "  .runs/current with the intended run id, then retry." >&2
  exit 2
fi
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
  single-thread) : ;;   # the sanctioned one-mind contract: no role fan-out → reviewer floor N/A.
  *)                    # full | mvp | ABSENT | UNKNOWN → fail-closed, matching prong 1's posture.
    # DENYLIST, not an allowlist: allowlisting full|mvp let an absent/unknown/mislabeled pipeline
    # ("full " with a trailing space, a legacy marker written before the `pipeline` field, an `audit`
    # run) present a CLOSED code batch with zero reviewer dispatch and skip prong 2 entirely — the
    # exact fail-open the review caught (CRITICAL-1). Whenever a closed batch is observable via
    # dispatch.jsonl, the >=1 reviewer floor is asserted; dispatch.jsonl absent → the verify-batch
    # stamp is trusted (the documented ADR-0006 forgeability ceiling).
    rundir_d="$(dirname "$marker")"
    if [ "$closed_code" -gt 0 ] && [ -f "$rundir_d/dispatch.jsonl" ]; then
      # WS-E / AC-E4 — PER-BATCH floor: EVERY closed kind:code batch must carry its OWN reviewer dispatch,
      # not "one reviewer anywhere in the run" (which let a batch that skipped its reviewer pass if any
      # OTHER batch had one — review #5). Block if ANY closed batch shows zero reviewer dispatch. (The
      # forgeable status:closed + absent dispatch.jsonl residual stays the disclosed ADR-0006 ceiling.)
      role_floor_ok=1
      set -f            # closed_ids tokens are untrusted (field_str [^"]* capture) — disable globbing (review LOW-1)
      for cid in $closed_ids; do
        [ -n "$cid" ] || continue
        [ "$(reviewer_dispatch_count "$cid")" -ge 1 ] || { role_floor_ok=0; break; }
      done
      set +f
    fi ;;
esac

# D7 — WAITING IS NOT SKIPPING (spec 021 AC-15/AC-16).
#
# An announced-unclosed kind:code batch blocked unconditionally. That is also the NORMAL state while
# the flow legitimately waits for an operator decision before Phase B, and nothing here told the two
# apart — so the harness blocked the operator for taking the time it asked them to take.
#
# The signal is OBSERVABLE, never declared (R3): an `announced_sha` written into the ledger by the
# orchestrator is forgeable by the same mind this gate exists to check. The anchor is `closure_anchor`
# - the last closure's sha, else the run's own harness-stamped baseline - sharing `last_closure_sha`
# with `current_batch_base`, so the closure boundary has one definition and not two.
#
# It is deliberately NOT current_batch_base itself. That helper answers "what should this batch's diff
# be measured against" and, to always answer, guesses: origin/main, then HEAD~1. Measured - with no
# closed batch and baseline_sha == HEAD it returns HEAD~1, dragging the run's own last commit into the
# window and reporting `code` for a run that shipped nothing. A guess is serviceable for a diff window
# and disqualifying here, where the whole requirement is a stamped observable.
#
# Then, with an announced-unclosed batch present:
#   no-code           → nothing has moved that no closure covers → WAITING. Do not block.
#   code              → code exists outside any closure → Phase B was skipped. Block, as before.
#   cannot-determine  → block, as before. An unresolvable anchor is not evidence of nothing (§8.1).
#
# The relaxation is deliberately narrow. It suppresses TWO conjuncts and only when `waiting` holds:
# its own, and prong 1 — which asks that a run WHICH SHIPPED CODE show an earned closure, a question
# with no content when nothing has shipped. Prong 2 (the reviewer floor) is untouched, and a run with
# no ledger at all still blocks, because `announced_code` is 0 for it and `waiting` never arms.
waiting=0
if [ "$announced_code" -gt 0 ]; then
  [ "$(code_state_since "$(closure_anchor 2>/dev/null || true)")" = "no-code" ] && waiting=1
  # issue #65 — WAITING FOR DISPATCHED REVIEWERS IS NOT ABANDONED. The relaxation above catches only the
  # "no code has moved" wait (waiting for an operator before Phase B). A batch whose code IS committed
  # reads as `code` there and stayed blocked — which is also the normal state while the orchestrator
  # waits for review subagents it ALREADY dispatched for the in-flight batch, so every such Stop burned
  # an exit-2 cycle. reviewers_in_flight is the OBSERVABLE that tells the two apart (R3): a reviewer-typed
  # dispatch recorded in dispatch.jsonl for the announced batch, that batch not yet closed. It is read
  # from the harness-recorded reviewer tally (reviewer_dispatch_count), never a declared marker field. A
  # run that dispatched NO reviewer for its open batch (the abandoned case) has count 0 and never arms —
  # so the block still fires for a real abandoned code run. Suppresses the SAME two conjuncts the no-code
  # waiting does (its own; and prong 1, which asks a run THAT SHIPPED CODE for an earned closure — the
  # very closure the in-flight reviewers are working toward). Prong 2 (the reviewer floor over CLOSED
  # batches) is untouched: an announced batch has closed_code 0 there, so it is not in scope regardless.
  [ "$waiting" -eq 0 ] && reviewers_in_flight && waiting=1
fi

# ISSUE #87 — PHASE A IS NOT ABANDONMENT. Before any batch is announced and before any code is
# committed, an armed run is doing clarify/plan/tasks/architecture-review: it has NOT reached the
# Phase-B decision point where "finished Phase A, then skipped Phase B" (the failure this hook exists to
# catch) becomes possible. A Stop here is a legitimate mid-Phase-A yield (a clarify question, a pause),
# and it was blocked every turn — dozens of wasted exit-2 cycles per run.
# The OBSERVABLE that tells mid-Phase-A from finished-A-skipped-B (R3, never a declared field): Phase A's
# terminal artefact tasks.md is not yet on disk beside the milestone. Once tasks.md exists, Phase A is
# done and this relaxation LIFTS — a run that then announces nothing and ships nothing blocks exactly as
# before. Scoped to "nothing delivered": no announced/closed code batch AND no code since baseline, so
# there is never code to lose. A run with no milestone path at all (feature=unknown / the line-116
# "delivered nothing" shape) is not in Phase A and is unaffected — it still blocks.
if [ "$waiting" -eq 0 ] && [ "$announced_code" -eq 0 ] && [ "$closed_code" -eq 0 ] && [ "$csb" -eq 0 ]; then
  _pa_path="$(field_str "$mk" spec_path)"
  [ -n "$_pa_path" ] || _pa_path="$(field_str "$mk" feature)"
  case "$_pa_path" in
    ""|unknown) : ;;                                          # no milestone to plan → not Phase A
    *) [ -f "$(dirname "$_pa_path")/tasks.md" ] || waiting=1 ;;   # tasks.md not yet produced → Phase A in progress
  esac
fi

# ISSUE #101 — WAITING ON THE PHASE-A SOUNDNESS GATE IS NOT ABANDONMENT (the #87 background-gate residual).
# #87 relaxes only while tasks.md is ABSENT. Once Phase A produces tasks.md AND dispatches a BACKGROUND
# architecture-reviewer for the soundness gate (Phase A, on plan.md — decided BEFORE any batch), the run
# legitimately waits for that verdict before announcing Phase B. That wait presents as the same
# "nothing shipped, tasks.md present" shape #87 stopped relaxing, so the hook blocked it every turn —
# pushing the orchestrator to announce a batch and start code BEFORE architecture_sound is decided, which
# contradicts the flow's own rule (STOP on the gate if architecture_sound:false). Same class as #65's
# in-flight batch reviewers, one phase earlier.
# The OBSERVABLE (R3, never a declared field), the SAME dispatch.jsonl channel #65 reads: an
# architecture-reviewer-typed dispatch is recorded (may be batch:"" pre-batch — see #99), and no
# architecture-reviewer verdict is captured yet (verdicts_captured). Read via role_of_slug (the exact
# attribution roles_covered uses) over the run's dispatch.jsonl — not any marker field the same mind this
# gate checks could forge. A soundness reviewer in flight and UNRESOLVED ⇒ WAITING. A run that dispatched
# NO architecture-reviewer never arms (count 0), so a genuinely abandoned Phase A still blocks. Scoped to
# "nothing delivered" (no announced/closed code batch, no code since baseline), so a code-shipped or
# batch-open abandonment is out of scope here and still handled by the reviewers_in_flight / prong logic.
# Suppresses the SAME two conjuncts the other waits do (its own; and prong 1, which asks a run THAT SHIPPED
# CODE for an earned closure — vacuous when nothing shipped); prong 2 (the CLOSED-batch reviewer floor) is
# untouched (closed_code is 0 here, so it is not in scope regardless).
if [ "$waiting" -eq 0 ] && [ "$announced_code" -eq 0 ] && [ "$closed_code" -eq 0 ] && [ "$csb" -eq 0 ]; then
  _disp101="$(dirname "$marker")/dispatch.jsonl"
  if [ -f "$_disp101" ]; then
    _arch_in_flight=0
    while IFS= read -r _l101; do
      [ -n "$_l101" ] || continue
      [ "$(role_of_slug "$(field_str "$_l101" subagent_type)")" = "architecture-reviewer" ] || continue
      _arch_in_flight=1; break
    done < "$_disp101"
    # UNRESOLVED iff no architecture-reviewer verdict is captured yet. verdicts_captured tokens are
    # "batch/role"; a captured soundness verdict means the gate has resolved and this is no longer a wait.
    # (Where capture never lands — the disclosed ADR-0006/0008 ceiling #65 already runs at — the arm is the
    # dispatch presence, strictly narrower than the ZERO-dispatch class the block still catches.)
    if [ "$_arch_in_flight" -eq 1 ]; then
      case "$(marker_list verdicts_captured 2>/dev/null)" in
        *architecture-reviewer*) : ;;   # soundness verdict recorded → gate resolved → not waiting
        *) waiting=1 ;;
      esac
    fi
  fi
fi

# BLOCK when: an announced code batch is still unclosed AND the run is not merely waiting; OR no earned
# closure exists, the csb allowance does not apply (prong 1), and the run is not waiting; OR the
# run-close reviewer floor is unmet (prong 2).
if { [ "$announced_code" -gt 0 ] && [ "$waiting" -eq 0 ]; } \
   || { [ "$closed_code" -eq 0 ] && [ "$csb_ok" -eq 0 ] && [ "$waiting" -eq 0 ]; } \
   || [ "$role_floor_ok" -eq 0 ]; then
  run="$(field_str "$mk" run)"
  # WS-2 (T021) — de-dup an identical REPEAT block to one terse line, ALWAYS preserving exit 2.
  # The retro's biggest token sink was a repeated block re-emitting the full explanation every Stop
  # (each Stop re-reads the whole conversation for one canned paragraph). Fingerprint the block by
  # run + the four block-condition counters + the ledger CONTENT (cksum); if that exact fingerprint was
  # already reported this run, emit ONE line and still exit 2. This NEVER turns a block into a pass, and
  # any ledger-content change yields a new fingerprint → the full block re-fires. (Note: the LIVE hook
  # benefits only after a plugin reinstall; run-tests.sh verifies the committed bin/ directly.)
  _bfp="$( { printf '%s|%s|%s|%s|%s|' "$run" "$announced_code" "$closed_code" "$csb_ok" "$role_floor_ok"
            [ -n "$ledger" ] && [ -f "$ledger" ] && cat "$ledger"; } | cksum | cut -d' ' -f1 )"
  case " $(marker_list reported_blocks | tr -d '[]"' | tr ',' ' ') " in
    *" $_bfp "*)
      echo "delivery-stop-hook: BLOCKED (repeat) — run '${run:-?}' still has undelivered code; the fix is in this run's first block above. Unchanged since — not re-explaining (P6/P9, exit 2)." >&2
      exit 2 ;;
  esac
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
  # record this block's fingerprint so an IDENTICAL repeat de-dups to the terse line (still exit 2).
  _prev="$(marker_list reported_blocks)"
  if [ -z "$_prev" ] || [ "$_prev" = "[]" ]; then
    record_marker_list reported_blocks "[\"$_bfp\"]"
  else
    record_marker_list reported_blocks "${_prev%]},\"$_bfp\"]"
  fi
  exit 2
fi
exit 0
