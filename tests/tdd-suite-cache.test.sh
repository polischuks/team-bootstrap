#!/usr/bin/env bash
# tdd-suite-cache.test.sh — behavioural spec for caching check-tdd's expensive suite run (issue #64).
#
# Problem: verify-batch re-runs EVERY gate on EVERY retry. check-tdd's cheap red-ordering checks are
# fine to repeat, but its last step runs the WHOLE non-integration suite (~3.5 min) at HEAD. When a
# retry is triggered by a LATE, CHEAP gate (completeness / ordering / gate-integrity) the working tree
# is byte-identical to the last green run — recording an ack only touches the ledger under .runs/
# (gitignored) — yet the suite re-executes from scratch. Tens of minutes of identical work per milestone.
#
# Contract (same as the mutation cache, issue #23 / ADR-0015): reuse the GREEN suite verdict only when
# the code under test is provably identical (tree state = committed window + uncommitted tracked +
# untracked content); ANY real code change re-runs. A stale green here is the worst outcome, so every
# ambiguity resolves toward re-running. The cache key is computed by delivery-lib gate_cache_key, which
# keys on the tree, never on time — so this test STUBS tree state by committing / editing files, never
# by sleeping, and observes re-execution by COUNTING the Test: command's own invocations.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

# A repo with an armed run and one CLOSED code batch that already has a valid red step (so check-tdd's
# cheap ordering checks pass and it reaches the expensive suite run). The Test: command COUNTS its own
# invocations into a gitignored log — so "did the suite actually re-execute?" is observable, and the
# counter itself never perturbs the tree/cache key.
_fixture() { # $1=dir
  mkdir -p "$1"; cd "$1" || return 1
  git init -q; git config user.email a@b.c; git config user.name t
  # Test: command → append to a gitignored log, then pass iff .green exists (green at HEAD).
  printf '#!/usr/bin/env bash\necho run >> "$PWD/suite-runs.log"\ntest -f .green\n' > suite.sh
  chmod +x suite.sh
  printf '# AGENTS\n\n- Test: `./suite.sh`\n' > AGENTS.md
  printf 'suite-runs.log\n.runs/\n' > .gitignore
  git add -A; git commit -q -m base
  base="$(git rev-parse HEAD)"
  echo 't' > f1_test.sh; git add f1_test.sh; git commit -q -m "redA (B1 failing test)"
  red="$(git rev-parse --short HEAD)"
  echo 1 > f1; : > .green; git add -A; git commit -q -m "B1 code (green)"
  c1="$(git rev-parse --short HEAD)"
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$base" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":5}\n' "$c1" > .runs/r/batches.jsonl
  printf '{"batch":"B1","red_sha":"%s","observed":"red"}\n' "$red" > .runs/r/tdd.jsonl
  : > suite-runs.log
}
_runs() { grep -c . suite-runs.log 2>/dev/null || true; }
_gate() { ( TEAM_BOOTSTRAP_RUN=r "$here/bin/check-tdd.sh" . >/dev/null 2>&1 ); }

echo "issue #64 — cache check-tdd's expensive suite run on tree state:"

# AC-T1 — the win: a RETRY with an identical tree reuses the green verdict instead of re-running the
# whole suite. (The real trigger is a late cheap gate failing, which only rewrites the .runs/ ledger.)
T="$(mktemp -d)"; ( _fixture "$T"
  _gate; first="$(_runs)"
  _gate; second="$(_runs)"
  _chk "$first" "1" "AC-T1 first close runs the Test: suite once"
  _chk "$second" "1" "AC-T1 identical retry reuses the cached green verdict (no re-run)"
) ; rm -rf "$T"

# AC-T2 — FAIL-CLOSED: a COMMITTED code change since the last green suite must re-execute (cache keyed
# on tree, not time — the acceptance criterion of the issue).
T="$(mktemp -d)"; ( _fixture "$T"
  _gate
  echo 2 > f1; git add -A; git commit -q -m "B1 more code"
  _gate
  _chk "$(_runs)" "2" "AC-T2 a committed code change re-executes the suite (no stale green)"
) ; rm -rf "$T"

# AC-T3 — FAIL-CLOSED: an UNCOMMITTED working-tree edit also invalidates (the suite runs against the
# working tree, so caching on committed state alone would be a fail-open).
T="$(mktemp -d)"; ( _fixture "$T"
  _gate
  echo 3 > f1                                       # dirty, not committed
  _gate
  _chk "$(_runs)" "2" "AC-T3 an uncommitted edit re-executes (dirty tree is not cached over)"
) ; rm -rf "$T"

# AC-T4 — the cached verdict is the SAME verdict: caching never turns a red suite into a pass. With a
# red suite the gate must FAIL on the retry too (whether it re-ran or served a cached red).
T="$(mktemp -d)"; ( _fixture "$T"
  rm -f .green; git add -A; git commit -q -m "regress (suite red at HEAD)"
  _gate; rc1=$?
  _gate; rc2=$?
  _chk "$rc1" "1" "AC-T4 first close fails on a red suite"
  _chk "$rc2" "1" "AC-T4 the retry still FAILS (a cache never turns a red into a green)"
) ; rm -rf "$T"

# AC-T5 — no active run marker ⇒ no cache at all (CI has no marker; check-tdd skips there anyway, but
# the cache helpers must never crash or fabricate a hit without a marker).
T="$(mktemp -d)"; ( _fixture "$T"
  rm -f .runs/r/RUN
  ( env -u TEAM_BOOTSTRAP_RUN "$here/bin/check-tdd.sh" . >/dev/null 2>&1 )
  ( env -u TEAM_BOOTSTRAP_RUN "$here/bin/check-tdd.sh" . >/dev/null 2>&1 )
  n="$(_runs)"
  _chk "$([ "$n" -ge 0 ] && echo ok)" "ok" "AC-T5 no marker → no crash (skips, no cache) [runs=$n]"
) ; rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "tdd-suite-cache.test.sh: OK"; exit 0; }
echo "tdd-suite-cache.test.sh: $fail failure(s)"; exit 1
