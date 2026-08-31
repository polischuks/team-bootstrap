#!/usr/bin/env bash
# dispatch-empty-batch-attribution.test.sh — issue #99: a review dispatch recorded with "batch":""
# (the Phase-A architecture-reviewer, dispatched BEFORE any batch id was resolvable) is orphaned —
# roles_covered(bid) filters on batch==bid and never credits it, so the PostToolBatch hook
# (check-review-batch.sh) and the dispatch brief (subagent-brief.sh) both read "dispatches recorded so
# far [none]" while dispatch.jsonl already holds the batch's reviewers, inviting a needless re-dispatch.
#
# roles_covered is the SINGLE source both readers consume ("covered=$(roles_covered "$bid")"). This test
# pins the attribution fix on that one function: a batch:"" reviewer dispatch is credited to the in-flight
# batch when — and ONLY when — that batch is the SOLE open (announced, not-closed) kind:code batch; with 0
# or >=2 open batches it stays orphaned rather than credited to a guess.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/../bin"
fail=0
_chk() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (got [$2] want [$3])" >&2; fail=$((fail + 1)); fi; }
_has() { case " $1 " in *" $2 "*) printf yes ;; *) printf no ;; esac; }

_covered() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r bash -c '. "'"$BIN"'/delivery-lib.sh"; roles_covered "'"$1"'"' ); }

# --- scenario 1: ONE open code batch → the batch:"" reviewer is credited to it -----------------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
# The first dispatch is recorded before B1 is resolvable → batch:"" (the live CA/101 shape). The second
# is a normal in-batch dispatch.
{ printf '{"batch":"","subagent_type":"architecture-reviewer","outcome":"attempted"}\n'
  printf '{"batch":"B1","subagent_type":"tb-code-reviewer","outcome":"attempted"}\n'; } > "$T/.runs/r/dispatch.jsonl"

cov="$(_covered B1)"
echo "  roles_covered(B1) = [$cov]"
_chk "batch:\"\" architecture-reviewer credited to the sole open batch B1" "$(_has "$cov" architecture-reviewer)" yes
_chk "the in-batch tb-code-reviewer is still credited (role code-reviewer)" "$(_has "$cov" code-reviewer)" yes
rm -rf "$T"

# --- scenario 2: TWO open code batches → the batch:"" reviewer stays ORPHANED (ambiguous) -------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
{ printf '{"id":"B1","kind":"code","status":"announced"}\n'
  printf '{"id":"B2","kind":"code","status":"announced"}\n'; } > "$T/.runs/r/batches.jsonl"
printf '{"batch":"","subagent_type":"architecture-reviewer","outcome":"attempted"}\n' > "$T/.runs/r/dispatch.jsonl"
cov2="$(_covered B1)"
echo "  roles_covered(B1) with 2 open batches = [$cov2]"
_chk "with two open batches the batch:\"\" dispatch is NOT credited to B1 (no guess)" "$(_has "$cov2" architecture-reviewer)" no
rm -rf "$T"

# --- scenario 3: a CLOSED sole code batch does not make B1 the sole OPEN one --------------------------
# Only OPEN (announced, not-closed) batches count toward "sole open". If B1 is closed, an empty-batch
# dispatch must not be retro-credited to it.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"closed"}\n' > "$T/.runs/r/batches.jsonl"
printf '{"batch":"","subagent_type":"architecture-reviewer","outcome":"attempted"}\n' > "$T/.runs/r/dispatch.jsonl"
cov3="$(_covered B1)"
echo "  roles_covered(B1) with B1 closed = [$cov3]"
_chk "a batch:\"\" dispatch is NOT credited to a CLOSED batch" "$(_has "$cov3" architecture-reviewer)" no
rm -rf "$T"

# --- scenario 4: empty bid is non-matchable (parity with reviewer_dispatch_count FIX#3) ---------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
printf '{"batch":"","subagent_type":"architecture-reviewer","outcome":"attempted"}\n' > "$T/.runs/r/dispatch.jsonl"
cov4="$(_covered '')"
_chk "empty bid → empty covered set (never credits an orphan to a non-matchable id)" "$cov4" ""
rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "dispatch-empty-batch-attribution.test.sh: OK"; exit 0; fi
echo "dispatch-empty-batch-attribution.test.sh: $fail case(s) FAILED" >&2; exit 1
