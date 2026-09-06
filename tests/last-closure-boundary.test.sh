#!/usr/bin/env bash
# last-closure-boundary.test.sh — #131. last_closure_sha must keep the closure boundary even when the
# LAST closed batch is a doc batch (commit_shas:[]). Reading only tail -1 returned empty for that case,
# regressing current_batch_base to the run baseline and re-attributing every prior commit + Phase-A docs
# to the next code batch. It must instead return the newest CLOSED batch that recorded a code commit.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }

T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo a > f && git add . && git commit -qm base
  echo a >> f && git add . && git commit -qm c1
  echo a >> f && git add . && git commit -qm docs
  mkdir -p .runs/r ) >/dev/null 2>&1
BASE="$(cd "$T" && git rev-parse --short HEAD~2)"
C1="$(cd "$T" && git rev-parse --short HEAD~1)"   # batch-1 newest code commit
DOC="$(cd "$T" && git rev-parse --short HEAD)"     # a later doc-batch commit
printf '{"run":"r","pipeline":"full","baseline_sha":"%s"}\n' "$BASE" > "$T/.runs/r/RUN"

_lcs(){ ( cd "$T" && bash -c '. "'"$here"'/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r last_closure_sha' ); }
_cbb(){ ( cd "$T" && bash -c '. "'"$here"'/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r current_batch_base' ); }

echo "#131 — a closed DOC batch (commit_shas:[]) after a code batch must NOT lose the boundary:"
printf '{"id":"B1","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":5}\n' "$C1" > "$T/.runs/r/batches.jsonl"
printf '{"id":"B2","kind":"doc","status":"closed","commit_shas":[],"code_delta":0}\n' >> "$T/.runs/r/batches.jsonl"
_chk "$(_lcs)" "$C1" "last_closure_sha returns the prior code batch's newest commit (not empty)"
_chk "$(cd "$T" && [ "$(git rev-parse "$(_cbb)" 2>/dev/null)" = "$(git rev-parse "$C1" 2>/dev/null)" ] && echo yes || echo no)" yes "current_batch_base is the closure boundary C1, not the run baseline"

echo "#131 — control: last closed batch IS code → its newest commit is the boundary:"
printf '{"id":"B1","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":5}\n' "$C1" > "$T/.runs/r/batches.jsonl"
printf '{"id":"B2","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":5}\n' "$DOC" >> "$T/.runs/r/batches.jsonl"
_chk "$(_lcs)" "$DOC" "last_closure_sha returns the newest code batch's commit"

echo "#131 — guards: no closed batch at all → empty (first-batch fallback owns the base):"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
_chk "$(_lcs)" "" "no closed batch → last_closure_sha empty"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "last-closure-boundary.test.sh: OK"; exit 0; fi
echo "last-closure-boundary.test.sh: $fail case(s) FAILED" >&2; exit 1
