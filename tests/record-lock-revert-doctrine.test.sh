#!/usr/bin/env bash
# record-lock-revert-doctrine.test.sh — #128. The --record-lock / mutation-kill guidance must WARN that
# reverting the mutation with `git checkout -- <file>` discards ALL co-located uncommitted work, and tell
# the operator to commit green (or stash) FIRST. Doc/message fix: assert the warning is present on the
# reachable message path (exit 4, pre-mutation) and in commands/deliver.md.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" -ge "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want >=[$2])" >&2; fail=$((fail+1)); fi; }

echo "#128 — check-tdd --record-lock pre-mutation message warns about the destructive revert:"
T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  printf 'Test: `true`\n' > AGENTS.md
  echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
# No uncommitted non-test mutation → exit 4 with the pre-mutation instruction (the #128 warning lives here).
msg="$(cd "$T" && bash "$here/bin/check-tdd.sh" --record-lock --batch B1 . 2>&1 >/dev/null)"
_chk "$(printf '%s' "$msg" | grep -c '#128')" 1 "message cites #128"
_chk "$(printf '%s' "$msg" | grep -ci 'discards ALL uncommitted')" 1 "warns git checkout discards ALL uncommitted changes"
_chk "$(printf '%s' "$msg" | grep -ci 'COMMIT the green implementation FIRST\|stash')" 1 "tells the operator to commit green first (or stash)"
rm -rf "$T"

echo "#128 — commands/deliver.md mutation guidance carries the same warning:"
_chk "$(grep -c '#128' "$here/commands/deliver.md")" 1 "deliver.md cites #128"
_chk "$(grep -ci 'discards \*\*all\*\* uncommitted\|commit green first\|stash' "$here/commands/deliver.md")" 1 "deliver.md warns about the destructive revert / commit-green-first"

if [ "$fail" -eq 0 ]; then echo "record-lock-revert-doctrine.test.sh: OK"; exit 0; fi
echo "record-lock-revert-doctrine.test.sh: $fail case(s) FAILED" >&2; exit 1
