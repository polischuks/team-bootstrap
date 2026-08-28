#!/usr/bin/env bash
# stop-hook-review-wait.test.sh — red-first behavioural spec for issue #65.
#
# delivery-stop-hook.sh blocked (exit 2) EVERY Stop while the orchestrator was legitimately waiting for
# review subagents it had already dispatched for the in-flight batch. An announced-unclosed kind:code
# batch with real code committed reads as "code exists outside any closure" — which the existing D7
# waiting relaxation (no-code-since-anchor) does NOT cover — so every Stop during the review wait burned
# a cycle. The hook could not tell "waiting for dispatched reviewers" from "abandoned Phase B".
#
# The distinguishing signal is OBSERVABLE, never declared: dispatch.jsonl records a reviewer-typed
# subagent dispatched for the in-flight announced batch (record-dispatch.sh, PreToolUse), and that batch
# has not closed → a reviewer is in flight → WAITING, allow Stop. A run that dispatched NO reviewer for
# its open batch is abandoned/skipping → still BLOCK, exactly as before.
#
# Written BEFORE the fix: cases AC-65-1 (waiting → allow) fail red, then go green. The fail-closed cases
# (AC-65-2/3/4) already pass and must KEEP passing after the relaxation — the relaxation must not become
# a blanket "always allow Stop".
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
HOOK="$here/../bin/delivery-stop-hook.sh"

fail=0
_chk() { # _chk GOT WANT MSG
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit '$1' want '$2')" >&2; fail=$((fail + 1)); fi
}

# --- a temp git repo: baseline = first commit; HEAD = a 2nd commit adding non-doc code ---------------
# So code_since_baseline("$BASE") is TRUE and code_state_since("$BASE")=="code": the announced batch has
# real committed code past the anchor, which is exactly the state the existing no-code waiting relaxation
# does NOT catch. Without the #65 fix the hook blocks here even with reviewers in flight.
T="$(mktemp -d)"
(
  cd "$T" || exit 1
  git init -q
  git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git config user.email t@t && git config user.name t
  mkdir -p src && echo 'base' > src/app.js && git add . && git commit -qm base
) >/dev/null 2>&1
BASE="$( ( cd "$T" && git rev-parse --short HEAD ) 2>/dev/null )"
( cd "$T" && printf 'code2\n' >> src/app.js && git add . && git commit -qm work ) >/dev/null 2>&1

# _stop RUN → run the Stop hook under run RUN, from the temp repo cwd; echo its exit code
_stop() { ( cd "$T" && TEAM_BOOTSTRAP_RUN="$1" bash "$HOOK" </dev/null >/dev/null 2>&1 ); echo $?; }
mkrun() { mkdir -p "$T/.runs/$1"; printf '%s\n' "$2" > "$T/.runs/$1/RUN"; }

echo "issue #65 — waiting-for-dispatched-reviewers is not abandoned (AC-65-1..4):"

# AC-65-1 — full run, announced-unclosed kind:code batch WITH code committed, a reviewer dispatched for
# that batch and no closure yet → WAITING. Do NOT exit-2-loop. (RED before the fix: blocks at exit 2.)
mkrun wait_full "{\"run\":\"wait_full\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$T/.runs/wait_full/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer","outcome":"attempted"}' > "$T/.runs/wait_full/dispatch.jsonl"
_chk "$(_stop wait_full)" 0 "full run + announced batch + reviewer in flight → Stop exit 0 (AC-65-1)"

# AC-65-1b — the dedicated plugin-scoped review type also counts as in-flight.
mkrun wait_ded "{\"run\":\"wait_ded\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$T/.runs/wait_ded/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"tb-code-reviewer","outcome":"attempted"}' > "$T/.runs/wait_ded/dispatch.jsonl"
_chk "$(_stop wait_ded)" 0 "full run + announced batch + dedicated reviewer in flight → Stop exit 0 (AC-65-1b)"

# AC-65-2 — the fail-closed twin: SAME shape, but NO dispatch.jsonl at all → genuinely abandoned Phase B
# (code committed under an announced batch, no reviewer ever dispatched) → still BLOCK. (Passes red.)
mkrun abandoned "{\"run\":\"abandoned\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$T/.runs/abandoned/batches.jsonl"
_chk "$(_stop abandoned)" 2 "full run + announced batch + ZERO reviewer dispatch → Stop exit 2 (AC-65-2)"

# AC-65-3 — grounded in a REVIEWER-typed dispatch, not any dispatch: a dispatch.jsonl carrying only a
# builder (backend-developer) is not a reviewer in flight → still BLOCK.
mkrun builder_only "{\"run\":\"builder_only\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > "$T/.runs/builder_only/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer","outcome":"attempted"}' > "$T/.runs/builder_only/dispatch.jsonl"
_chk "$(_stop builder_only)" 2 "full run + announced batch + only a BUILDER dispatched → Stop exit 2 (AC-65-3)"

# AC-65-3b — the reviewer must be dispatched for THIS in-flight batch, not some other one: a reviewer
# credited to a different batch id leaves the open batch with zero reviewers → still BLOCK.
mkrun other_batch "{\"run\":\"other_batch\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' '{"id":"B2","kind":"code","status":"announced"}' > "$T/.runs/other_batch/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer","outcome":"attempted"}' > "$T/.runs/other_batch/dispatch.jsonl"
_chk "$(_stop other_batch)" 2 "reviewer credited to a DIFFERENT batch → open batch still unreviewed → Stop exit 2 (AC-65-3b)"

# AC-65-4 — the relaxation must not leak to the no-ledger abandoned run: full run, code since baseline,
# NO batch ledger at all (nothing announced, no reviewer to be in flight) → still BLOCK (spec-169 shape).
mkrun noledger "{\"run\":\"noledger\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
_chk "$(_stop noledger)" 2 "full run + code since baseline + no ledger → Stop exit 2 (AC-65-4)"

rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "stop-hook-review-wait.test.sh: OK"; exit 0; fi
echo "stop-hook-review-wait.test.sh: $fail case(s) FAILED" >&2; exit 1
