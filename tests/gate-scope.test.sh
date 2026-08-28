#!/usr/bin/env bash
# gate-scope.test.sh — issue #71: two gate-reporting scopes are misreported.
#
# (1) check-gate-integrity scanned the WHOLE tree for green-by-skip on every per-batch run, so the same
#     standing skips OUTSIDE the batch delta were flagged (and hand-waived) every run — the waiver stops
#     being a signal. The per-batch scan must be scoped to the batch DELTA: a standing skip the batch
#     never touched must NOT demand a waiver, while a skip INTRODUCED in a changed file is still caught.
#     A whole-tree audit stays reachable (--audit, and the no-marker/CI path).
#
# (2) check-diff-coverage reported a percentage over the MEASURED changed lines with an opaque
#     denominator, so a failure read as wrong without the measurement base. The verdict line must state
#     measured-vs-total changed lines.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }
_git() { git -c user.email=t@t -c user.name=t "$@"; }

GI="$here/bin/check-gate-integrity.sh"
DC="$here/bin/check-diff-coverage.sh"

echo "issue #71 (1) — gate-integrity green-by-skip scan scoped to the batch delta:"

# (a) A batch whose delta touches NONE of the standing-skip files passes WITHOUT a waiver, even though a
#     standing green-by-skip sits elsewhere in the tree.
T="$(mktemp -d)"
( cd "$T" || exit 1
  _git init -q
  printf '@pytest.mark.skip\ndef test_gate_invariant(): pass\n' > standing_gate_test.py  # gate-integrity: sanctioned — fixture: standing green-by-skip written into the scratch repo, not this suite
  _git add -A; _git commit -qm base
  base="$(_git rev-parse HEAD)"
  printf 'def helper():\n    return 1\n' > feature.py     # the batch changes an unrelated NON-skip file
  _git add -A; _git commit -qm batch
  mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > .runs/r/RUN
  ( TEAM_BOOTSTRAP_RUN=r "$GI" . >/dev/null 2>&1 ); rc=$?
  _chk "$rc" "0" "(a) delta touches no standing-skip file → passes without a waiver [was: flagged whole-tree, exit 1]"
)
rm -rf "$T"

# (b) A skip INTRODUCED in a file the batch changed is still caught (in-delta detection preserved).
T="$(mktemp -d)"
( cd "$T" || exit 1
  _git init -q
  printf '@pytest.mark.skip\ndef test_gate_invariant(): pass\n' > standing_gate_test.py  # gate-integrity: sanctioned — fixture: standing green-by-skip in the scratch repo
  _git add -A; _git commit -qm base
  base="$(_git rev-parse HEAD)"
  printf '@pytest.mark.skip\ndef test_new_gate(): pass\n' > batch_gate_test.py   # gate-integrity: sanctioned — fixture: in-delta green-by-skip written into the scratch repo
  _git add -A; _git commit -qm batch
  mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > .runs/r/RUN
  out="$( TEAM_BOOTSTRAP_RUN=r "$GI" . 2>&1 )"; rc=$?
  _chk "$rc" "1" "(b) skip introduced in a changed file → still caught (exit 1)"
  _chk "$(printf '%s' "$out" | grep -c 'batch_gate_test.py')" "1" "(b) …and the in-delta file is named in the finding"
)
rm -rf "$T"

# (c) --audit forces the whole-tree scan even in-session: a standing skip outside the delta is flagged.
T="$(mktemp -d)"
( cd "$T" || exit 1
  _git init -q
  printf '@pytest.mark.skip\ndef test_gate_invariant(): pass\n' > standing_gate_test.py  # gate-integrity: sanctioned — fixture: standing green-by-skip for the --audit case
  _git add -A; _git commit -qm base
  base="$(_git rev-parse HEAD)"
  printf 'def helper():\n    return 1\n' > feature.py
  _git add -A; _git commit -qm batch
  mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > .runs/r/RUN
  ( TEAM_BOOTSTRAP_RUN=r "$GI" --audit . >/dev/null 2>&1 ); rc=$?
  _chk "$rc" "1" "(c) --audit forces whole-tree → the standing skip is flagged (exit 1)"
)
rm -rf "$T"

echo "issue #71 (2) — diff-coverage verdict states measured-vs-total changed lines:"

# Shared coverage fixture: app.sh gains 5 new non-doc lines (2..6); cov.lcov measures all 5.
_dc_fixture() { # $1=dir  $2=lcov body
  cd "$1" || return 1
  _git init -q
  printf 'line1\n' > app.sh
  printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n- CoverageThreshold: 80\n' > AGENTS.md
  _git add -A; _git commit -qm base
  local base; base="$(_git rev-parse HEAD)"
  printf 'line1\nl2\nl3\nl4\nl5\nl6\n' > app.sh
  _git add -A; _git commit -qm change
  mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > .runs/r/RUN
  printf '%s' "$2" > cov.lcov
}

# (d) FAIL, fully measured (5 of 5), 2 covered = 40% < 80 → the FAIL line names measured vs total.
T="$(mktemp -d)"
( _dc_fixture "$T" 'SF:app.sh
DA:2,1
DA:3,1
DA:4,0
DA:5,0
DA:6,0
end_of_record
'
  out="$( TEAM_BOOTSTRAP_RUN=r "$DC" . 2>&1 )"; rc=$?
  _chk "$rc" "1" "(d) 40% < 80% → fail"
  _chk "$(printf '%s' "$out" | grep -c 'measured 5 of 5')" "1" "(d) FAIL verdict states measured 5 of 5 changed lines [was: opaque]"
)
rm -rf "$T"

# (e) PASS, fully measured (5 of 5), all covered = 100% → the OK line also names measured vs total.
T="$(mktemp -d)"
( _dc_fixture "$T" 'SF:app.sh
DA:2,1
DA:3,1
DA:4,1
DA:5,1
DA:6,1
end_of_record
'
  out="$( TEAM_BOOTSTRAP_RUN=r "$DC" . 2>&1 )"; rc=$?
  _chk "$rc" "0" "(e) 100% ≥ 80% → pass"
  _chk "$(printf '%s' "$out" | grep -c 'measured 5 of 5')" "1" "(e) OK verdict states measured 5 of 5 changed lines [was: opaque]"
)
rm -rf "$T"

n="$(cat "$FAILF")"; rm -f "$FAILF"
if [ "$n" = "0" ]; then echo "gate-scope.test.sh: OK"; exit 0; fi
echo "gate-scope.test.sh: $n case(s) FAILED" >&2; exit 1
