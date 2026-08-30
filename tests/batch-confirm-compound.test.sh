#!/usr/bin/env bash
# batch-confirm-compound.test.sh — issue #90.1: check-batch-confirm must accept a compound
# `confirm-append && git commit`. PreToolUse fires before the command runs, so the {"confirm":"BID"}
# line isn't on disk yet — but it is in the command text, sequenced ahead of the commit by `&&`, so the
# operator has confirmed in one breath. The gate used to block it, forcing an artificial split.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-batch-confirm.sh"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit $1 want $2)" >&2; fail=$((fail+1)); fi; }

T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base && mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1

# Build a JSON-safe PreToolUse payload for a given command (the gate only INSPECTS the command; it never
# runs it, so the `>>` append below never actually fires — the ledger is untouched by the gate).
_pay(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
_run(){ ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$G" >/dev/null 2>&1 ); echo $?; }
led=".runs/r/batches.jsonl"

_chk "$(_run "$(_pay "git commit -m x")")" 2 \
  "irreversible commit, no confirm anywhere → block (unchanged)"
_chk "$(_run "$(_pay "printf '{\"confirm\":\"B1\"}\n' >> $led && git commit -m x")")" 0 \
  "compound confirm+commit for the in-flight batch → allow (#90)"
_chk "$(_run "$(_pay "printf '{\"confirm\":\"B9\"}\n' >> $led && git commit -m x")")" 2 \
  "compound confirm for a DIFFERENT batch → still block (no self-confirm for B1)"

# The separate-call path is unchanged: a confirm already recorded on the ledger still unblocks.
printf '{"confirm":"B1"}\n' >> "$T/$led"
_chk "$(_run "$(_pay "git commit -m x")")" 0 "pre-recorded confirm (separate call) → allow (unchanged)"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "batch-confirm-compound.test.sh: OK"; exit 0; fi
echo "batch-confirm-compound.test.sh: $fail case(s) FAILED" >&2; exit 1
