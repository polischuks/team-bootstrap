#!/usr/bin/env bash
# coverage-from-test.test.sh — `CoverageFrom: test` (issue #23 item 2).
#
# Problem: `Test:` and `Coverage:` are two declared commands and each runs the whole suite, so a
# closure attempt costs two full suite executions before mutation even starts.
#
# Contract (ADDITIVE — absent field ⇒ today's behaviour, byte for byte):
#   CoverageFrom: test   declares that the `Test:` run ITSELF produces the coverage artifact named by
#                        `CoverageFile:`. The gate then READS that artifact instead of running any
#                        coverage command — one suite execution serves both gates.
#
# The safety question this raises is staleness: an artifact left over from an older run would let the
# gate score CURRENT code against OLD coverage — a silent fail-open. So the artifact must be provably
# newer than the changed sources; anything else fails LOUD rather than passing quietly.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

# Fixture: a repo whose batch changed src.ts, plus a counter-instrumented coverage command.
_fixture() { # $1=dir  $2=extra AGENTS lines
  mkdir -p "$1"; cd "$1" || return 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'cov-runs.log\n.runs/\nlcov.info\n' > .gitignore
  printf 'export const a = 1;\n' > src.ts
  printf '#!/usr/bin/env bash\necho run >> "$PWD/cov-runs.log"\nprintf "SF:src.ts\\nDA:1,1\\nend_of_record\\n" > lcov.info\n' > cov.sh
  chmod +x cov.sh
  { printf '# AGENTS\n\n- Coverage: `./cov.sh`\n- CoverageFile: `lcov.info`\n- CoverageThreshold: 50\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"; } > AGENTS.md
  git add -A; git commit -q -m base
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$(git rev-parse HEAD)" > .runs/r/RUN
  printf 'export const a = 2;\n' > src.ts; git add -A; git commit -q -m change   # a changed line to measure
  : > cov-runs.log
}
_runs() { grep -c . cov-runs.log 2>/dev/null || true; }
_gate() { ( TEAM_BOOTSTRAP_RUN=r "$here/bin/check-diff-coverage.sh" . >/dev/null 2>&1 ); }

echo "issue #23 item 2 — CoverageFrom: test (one instrumented run serves both gates):"

# AC-F1 — BACKWARD COMPATIBILITY: without the new field, nothing changes — the Coverage command runs.
T="$(mktemp -d)"; ( _fixture "$T"
  ./cov.sh >/dev/null 2>&1; : > cov-runs.log        # pretend Test: already produced an artifact
  _gate
  _chk "$(_runs)" "1" "AC-F1 no CoverageFrom → the Coverage: command still runs (unchanged behaviour)"
) ; rm -rf "$T"

# AC-F2 — THE WIN: with CoverageFrom: test, the gate READS the artifact and runs no coverage command.
T="$(mktemp -d)"; ( _fixture "$T" '- CoverageFrom: `test`'
  ./cov.sh >/dev/null 2>&1; : > cov-runs.log        # the Test: run produced lcov.info
  _gate; rc=$?
  _chk "$(_runs)" "0" "AC-F2 CoverageFrom: test → no coverage command executed (one suite run total)"
  _chk "$rc" "0" "AC-F2 …and the gate still scores the artifact (passes on covered lines)"
) ; rm -rf "$T"

# AC-F3 — FAIL-CLOSED on a STALE artifact: coverage older than the code it claims to describe must
# NOT quietly pass. This is the whole risk the reuse introduces.
T="$(mktemp -d)"; ( _fixture "$T" '- CoverageFrom: `test`'
  ./cov.sh >/dev/null 2>&1; : > cov-runs.log
  sleep 1; printf 'export const a = 3;\n' > src.ts   # source now NEWER than the artifact
  _gate; rc=$?
  _chk "$rc" "1" "AC-F3 artifact older than the changed source → FAILS (no silent stale pass)"
) ; rm -rf "$T"

# AC-F4 — FAIL-CLOSED on a MISSING artifact: declaring reuse without producing the file is a contract
# error, not a skip (a skip here would be an unenforceable gate reading as green).
T="$(mktemp -d)"; ( _fixture "$T" '- CoverageFrom: `test`'
  rm -f lcov.info
  _gate; rc=$?
  _chk "$rc" "1" "AC-F4 CoverageFrom: test but no artifact → FAILS loud (not a graceful skip)"
) ; rm -rf "$T"

# AC-F5 — CONTRACT ERROR: reuse requires CoverageFile:; without it there is nothing to read.
T="$(mktemp -d)"; ( _fixture "$T" '- CoverageFrom: `test`'
  grep -v 'CoverageFile' AGENTS.md > a.tmp && mv a.tmp AGENTS.md
  _gate; rc=$?
  _chk "$rc" "1" "AC-F5 CoverageFrom: test without CoverageFile: → FAILS with a contract error"
) ; rm -rf "$T"

# AC-F6 — an UNRECOGNISED value is not silently treated as reuse (per the plugin docs' additive-field
# posture, an unknown value must fall back to the documented default, never to a weaker check).
T="$(mktemp -d)"; ( _fixture "$T" '- CoverageFrom: `magic`'
  ./cov.sh >/dev/null 2>&1; : > cov-runs.log
  _gate
  _chk "$(_runs)" "1" "AC-F6 unknown CoverageFrom value → falls back to running Coverage: (no silent reuse)"
) ; rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "coverage-from-test.test.sh: OK"; exit 0; }
echo "coverage-from-test.test.sh: $fail failure(s)"; exit 1
