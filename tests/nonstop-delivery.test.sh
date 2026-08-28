#!/usr/bin/env bash
# nonstop-delivery.test.sh — red-first behavioural spec for bin/check-batch-confirm.sh, the
# per-batch operator-confirmation checkpoint (issue #56). Written BEFORE the gate exists → fails red,
# then implemented green.
#
# WHAT IT REPLACES: commands/deliver.md used to make the orchestrator WAIT for operator "fire" before
# EVERY batch, unconditionally — prose, not a mechanism, that could not read the ledger's risk_rank and
# so halted on fully reversible batches too. #56 makes the default NON-STOP and puts the stop on a
# deterministic gate that reads the field the ledger already writes.
#
# CONTRACT (exit code):
#   0 allow  — reversible batch (risk_rank feature|doc, no manual_approval), OR a confirmation is
#              recorded for the in-flight batch, OR the command is not a commit/merge, OR off-delivery
#              (no armed intends_code run), OR kill-switched.
#   2 block  — the in-flight (last-announced) batch has risk_rank ∈ {irreversible, run-rate} OR
#              manual_approval_requested:true, the command is a git commit/merge, and NO confirmation is
#              recorded in the ledger for that batch id.
#
# LAYERING (the forged-low-rank constraint, ADR-0006): risk_rank is self-declared and forgeable. This
# gate only ever ADDS friction ABOVE the action-class backstop (guard-git.sh). A batch that forges a
# LOWER rank escapes THIS friction gate (exit 0) but its irreversible ACTIONS (commit on default,
# push) are still caught by guard-git / remote branch-protection. AC-7 pins that guard-git is unaffected.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
GATE="$here/../bin/check-batch-confirm.sh"
GUARD="$here/../bin/guard-git.sh"

fail=0
_chk() { # _chk GOT WANT MSG
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit '$1' want '$2')" >&2; fail=$((fail + 1)); fi
}

# --- a temp git repo on a FEATURE branch (so guard-git is not what blocks), armed intends_code run -----
T="$(mktemp -d)"
(
  cd "$T" || exit 1
  git init -q
  git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base
  git checkout -q -b feature
  mkdir -p .runs/r   && printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > .runs/r/RUN
  mkdir -p .runs/bad && printf '{"run":"bad","pipeline":"full","source":"harness","baseline_sha":"x"}\n'                    > .runs/bad/RUN
) >/dev/null 2>&1

# _ledger LINES... → write the in-flight ledger for run r (one JSON object per arg)
_ledger() { : > "$T/.runs/r/batches.jsonl"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$T/.runs/r/batches.jsonl"; done; }

# _g PAYLOAD → run the gate from the repo cwd under armed run r; echo its exit code
_g()  { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$GATE" >/dev/null 2>&1 ); echo $?; }
# shellcheck disable=SC2086
_gE() { ( cd "$T" && printf '%s' "$2" | env $1 bash "$GATE" >/dev/null 2>&1 ); echo $?; }
_guard() { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$GUARD" >/dev/null 2>&1 ); echo $?; }
P() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

COMMIT="$(P 'git commit -m x')"

echo "AC-1 — consecutive REVERSIBLE batches proceed with ZERO prompts (the #56 request):"
_ledger '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
_chk "$(_g "$COMMIT")" 0 "risk_rank:feature commit → allow (no prompt)"
_ledger '{"id":"B1","kind":"code","risk_rank":"feature","status":"closed"}' \
        '{"id":"B2","kind":"code","risk_rank":"doc","status":"announced"}'
_chk "$(_g "$COMMIT")" 0 "next batch risk_rank:doc commit → allow (non-stop, no prompt)"
_ledger '{"id":"B1","kind":"code","status":"announced"}'
_chk "$(_g "$COMMIT")" 0 "no risk_rank at all (unknown) → allow (only named-irreversible ranks stop)"

echo "AC-2 — an IRREVERSIBLE/RUN-RATE batch with NO recorded confirmation is BLOCKED (exit 2):"
_ledger '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}'
_chk "$(_g "$COMMIT")"                 2 "risk_rank:irreversible, no confirm, git commit → block"
_chk "$(_g "$(P 'git merge feat')")"   2 "risk_rank:irreversible, no confirm, git merge → block"
_ledger '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}'
_chk "$(_g "$COMMIT")"                 2 "risk_rank:run-rate, no confirm, git commit → block"

echo "AC-3 — a recorded confirmation for the in-flight batch UNBLOCKS the commit (exit 0):"
_ledger '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}' \
        '{"confirm":"B1"}'
_chk "$(_g "$COMMIT")" 0 "risk_rank:irreversible WITH confirm for B1 → allow"
# a confirmation for a DIFFERENT batch does not unblock this one
_ledger '{"id":"B2","kind":"code","risk_rank":"irreversible","status":"announced"}' \
        '{"confirm":"B1"}'
_chk "$(_g "$COMMIT")" 2 "confirm names B1 but in-flight is B2 → still block (id must match)"

echo "AC-4 — manual_approval_requested:true is ALSO a stop condition, even on a reversible rank:"
_ledger '{"id":"B1","kind":"code","risk_rank":"feature","manual_approval_requested":true,"status":"announced"}'
_chk "$(_g "$COMMIT")" 2 "feature rank BUT manual_approval_requested → block (no confirm)"
_ledger '{"id":"B1","kind":"code","risk_rank":"feature","manual_approval_requested":true,"status":"announced"}' \
        '{"confirm":"B1"}'
_chk "$(_g "$COMMIT")" 0 "manual_approval_requested WITH confirm → allow"

echo "AC-5 — scope: only commit/merge is gated; reads/add/push and non-git are never blocked:"
_ledger '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}'
_chk "$(_g "$(P 'git add -A')")"           0 "git add on irreversible batch → allow (not a commit)"
_chk "$(_g "$(P 'git status')")"           0 "git status on irreversible batch → allow"
_chk "$(_g "$(P 'git push origin feat')")" 0 "git push → NOT gated here (action-class backstop owns push)"
_chk "$(_g "$(P 'ls -la')")"               0 "non-git command → allow"

echo "AC-6 — off-delivery / kill-switch / no in-flight batch → allow even for a commit:"
_ledger '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}'
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=none' "$COMMIT")"                                   0 "no marker (off-delivery) → allow"
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=bad'  "$COMMIT")"                                   0 "marker without intends_code → allow"
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_DELIVERY_GATE=off' "$COMMIT")"     0 "DELIVERY_GATE=off → allow"
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_BATCHCONFIRM=off' "$COMMIT")"      0 "BATCHCONFIRM=off (own kill-switch) → allow"
_ledger '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"closed","commit_shas":["x"],"code_delta":1}'
_chk "$(_g "$COMMIT")" 0 "no in-flight announced batch (all closed) → allow (nothing to gate)"
: > "$T/.runs/r/batches.jsonl"
_chk "$(_g "$COMMIT")" 0 "empty ledger → allow (direct-pipeline path preserved)"

echo "AC-7 — totality + the forged-low-rank layering (guard-git is the real irreversibility backstop):"
_ledger '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}'
_chk "$(_g 'not even json')"                            0 "undecodable payload → allow (never break the shell)"
_chk "$(_g '{"tool_name":"Bash","tool_input":{}}')"     0 "payload with no command → allow"
# A batch that is irreversible in reality but forges risk_rank:feature escapes THIS friction gate...
_ledger '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
_chk "$(_g "$COMMIT")" 0 "forged-low risk_rank:feature → this gate adds no friction (exit 0, by design)"
# ...but the irreversible ACTION (commit on the default branch) is STILL blocked by guard-git, unchanged.
( cd "$T" && git checkout -q main ) >/dev/null 2>&1
_chk "$(_guard "$COMMIT")" 2 "guard-git STILL blocks commit-on-default regardless of forged rank (backstop intact)"
( cd "$T" && git checkout -q feature ) >/dev/null 2>&1

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "nonstop-delivery.test.sh: OK"; exit 0; fi
echo "nonstop-delivery.test.sh: $fail case(s) FAILED" >&2; exit 1
