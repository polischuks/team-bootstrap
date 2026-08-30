#!/usr/bin/env bash
# scoped-red.test.sh — issue #86: --record-red --scope narrows the RED observation by APPENDING args to
# the project's own Test: command (e.g. the batch's touched test paths), so the fast inner red/green loop
# does not re-run the whole suite. The full suite stays load-bearing at CLOSE (verify-batch, unchanged).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-tdd.sh"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }

T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  # Test: command echoes its args and always fails (red), so we can see what --scope appended.
  printf '# AGENTS\n\n- Test: `sh t.sh`\n' > AGENTS.md
  printf 'echo "ARGS=[$*]"\nexit 1\n' > t.sh
  git add . && git commit -qm baseline ) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
# commit a test file so F1 (red-touches-tests) is satisfied within the window
( cd "$T" && mkdir -p tests && printf 'x\n' > tests/x_test.py && git add tests/x_test.py && git commit -qm "failing test" ) >/dev/null 2>&1
mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"

_rr(){ ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$G" "$@" . ) ; }

echo "1 — --record-red --scope appends the scope to the project runner and records the red:"
: > "$T/.runs/r/tdd.jsonl"
rc="$( _rr --record-red --batch B1 --scope "tests/x_test.py" >/dev/null 2>&1; echo $? )"
_chk "$rc" 0 "scoped red is observed and recorded (exit 0)"
_chk "$(grep -c 'tests/x_test.py' "$T/.runs/r/tdd.jsonl" 2>/dev/null)" 1 "the recorded test_cmd states the scoped command (#86)"
_chk "$(grep -c '"observed":"red"' "$T/.runs/r/tdd.jsonl" 2>/dev/null)" 1 "  …as a red record"

echo "2 — without --scope the full Test: command is used, unchanged:"
: > "$T/.runs/r/tdd.jsonl"
_rr --record-red --batch B1 >/dev/null 2>&1
_chk "$(grep -c 'x_test.py' "$T/.runs/r/tdd.jsonl" 2>/dev/null)" 0 "no scope → recorded test_cmd is the bare Test: command"
_chk "$(grep -c '"test_cmd":"sh t.sh"' "$T/.runs/r/tdd.jsonl" 2>/dev/null)" 1 "  …the full runner"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "scoped-red.test.sh: OK"; exit 0; fi
echo "scoped-red.test.sh: $fail case(s) FAILED" >&2; exit 1
