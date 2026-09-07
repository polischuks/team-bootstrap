#!/usr/bin/env bash
# proof-batch-earned.test.sh — #134. A pure test-only / verification / proof batch ships a test and no
# impl (impl_delta 0), so stamp_batch_closed filters every commit and it closes with commit_shas:[] and
# code_delta:0. Its closure is earned by a RECORDED tdd.jsonl proof (observed:"red"+red_sha, or
# observed:"lock-kill" #67/#89), not by an impl commit. check-delivery must credit it, NOT flag FORGED —
# while an empty closure with NO recorded proof (or one still claiming a nonzero code_delta) stays forged.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }

T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  printf 'Test: `true`\n' > AGENTS.md && mkdir -p src tests && git add . && git commit -qm base
  echo 'a=1' > src/s5.py && git add . && git commit -qm 'B5 code'
  echo 'def test6(): assert True' > tests/test_6.py && git add . && git commit -qm 'B6 proof test' ) >/dev/null 2>&1
mkdir -p "$T/.runs/r"
BASE="$(cd "$T" && git rev-parse --short HEAD~2)"; C5="$(cd "$T" && git rev-parse --short HEAD~1)"
T6="$(cd "$T" && git rev-parse --short HEAD)"   # B6's red test commit → its red_sha
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$BASE" > "$T/.runs/r/RUN"
_ledger(){ { printf '{"id":"B5","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":1}\n' "$C5"; printf '%s\n' "$1"; } > "$T/.runs/r/batches.jsonl"; }
_run(){ ( cd "$T" && TEAM_BOOTSTRAP_RUN=r bash "$here/bin/check-delivery.sh" . 2>&1 ); }
_forged_b6(){ printf '%s' "$1" | grep -c "FORGED: batch 'B6'"; }

echo "#134 — a proof batch with a recorded tdd.jsonl red proof is EARNED, not forged:"
_ledger '{"id":"B6","kind":"code","status":"closed","commit_shas":[],"code_delta":0}'
printf '{"batch":"B6","red_sha":"%s","observed":"red"}\n' "$T6" > "$T/.runs/r/tdd.jsonl"
out="$(_run)"
_chk "$(_forged_b6 "$out")" 0 "empty commit_shas + recorded red proof → NOT forged"
_chk "$(printf '%s' "$out" | grep -c "EARNED (test-only): batch 'B6'")" 1 "credited as an earned test-only closure"

echo "#134 — a lock-kill proof also earns the closure:"
printf '{"batch":"B6","lock_sha":"%s","observed":"lock-kill"}\n' "$T6" > "$T/.runs/r/tdd.jsonl"
_chk "$(_forged_b6 "$(_run)")" 0 "empty commit_shas + observed:lock-kill → NOT forged"

echo "#134 — guards: empty closure with NO proof, or claiming impl, stays FORGED:"
rm -f "$T/.runs/r/tdd.jsonl"
_ledger '{"id":"B6","kind":"code","status":"closed","commit_shas":[],"code_delta":0}'
_chk "$(_forged_b6 "$(_run)")" 1 "empty commit_shas + NO tdd proof → still FORGED"
# proof present BUT the batch still claims a nonzero code_delta with no commits → inconsistent, forged
printf '{"batch":"B6","red_sha":"%s","observed":"red"}\n' "$T6" > "$T/.runs/r/tdd.jsonl"
_ledger '{"id":"B6","kind":"code","status":"closed","commit_shas":[],"code_delta":5}'
_chk "$(_forged_b6 "$(_run)")" 1 "empty commit_shas claiming code_delta>0 → still FORGED even with a proof"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "proof-batch-earned.test.sh: OK"; exit 0; fi
echo "proof-batch-earned.test.sh: $fail case(s) FAILED" >&2; exit 1
