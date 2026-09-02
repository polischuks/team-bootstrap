#!/usr/bin/env bash
# diff-coverage-waiver.test.sh — check-diff-coverage.sh, issues #110 and #112.
#
# #110 (bug): a doc-only / empty-changed batch has no measurable changed non-doc lines. The changed
#   count was computed `grep -c . "$changed" || echo 0`, but on an empty file `grep -c .` prints `0`
#   AND exits 1, so `|| echo 0` ALSO fires → the substitution captured `0\n0`, and downstream integer
#   arithmetic (`$(( changed_n - m ))`, `$(( 100*c/denom ))`) crashed, blocking a batch that should
#   trivially pass. A doc-only batch must PASS (0 of 0 is not a failure), never crash.
#
# #112 (asymmetry): check-mutation / check-gate-integrity each carry a governed `--waive BY REASON
#   EXPIRES` door; check-diff-coverage carried none. A legitimately-untestable diff (thin glue over an
#   external SDK) had no sanctioned, expiring escape while a low mutation score did. This gate now
#   carries the same governed `diff_coverage_waiver` door (record_governed_waiver / governed_waiver_ok),
#   mirroring check-mutation.sh exactly.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$here/bin/check-diff-coverage.sh"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

# Fixture: a repo whose latest commit is the batch. $2 lines are appended to AGENTS.md.
# The caller controls the changed content (doc-only vs code) and the LCOV in cov.lcov.
_base_repo() { # $1=dir  $2=extra AGENTS lines
  mkdir -p "$1"; cd "$1" || return 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf '.runs/\ncov.lcov\n' > .gitignore
  printf 'code1\n' > app.sh
  { printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n- CoverageThreshold: 80\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"; } > AGENTS.md
  git add -A; git commit -q -m base
}
_arm() { # record the marker with baseline = HEAD~1
  mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$(git rev-parse --short HEAD~1)" > .runs/r/RUN
}
_gate() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$BIN" . >/dev/null 2>&1 ); echo $?; }
_gate_out() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$BIN" . 2>&1 ); }

echo "issue #110 — doc-only / empty-changed batch must PASS, not crash on '0\\n0':"

# AC-110a — a doc-only batch (only AGENTS.md changed → zero changed non-doc lines), non-strict.
T="$(mktemp -d)"; ( _base_repo "$T"
  printf 'more docs\n' >> AGENTS.md; git add -A; git commit -q -m docchange
  _arm ) >/dev/null 2>&1
_chk "$(_gate "$T")" "0" "AC-110a doc-only batch passes (non-strict), no arithmetic crash"
out="$(_gate_out "$T")"
if printf '%s' "$out" | grep -q "syntax error"; then
  _chk "crash" "no-crash" "AC-110a no 'syntax error in expression' on stderr"
else _chk "no-crash" "no-crash" "AC-110a no 'syntax error in expression' on stderr"; fi
rm -rf "$T"

# AC-110b — same doc-only batch under CoverageStrict: true also passes (0 of 0 is not a miss).
T="$(mktemp -d)"; ( _base_repo "$T" '- CoverageStrict: true'
  printf 'more docs\n' >> AGENTS.md; git add -A; git commit -q -m docchange
  _arm ) >/dev/null 2>&1
_chk "$(_gate "$T")" "0" "AC-110b doc-only batch passes (strict), no arithmetic crash"
rm -rf "$T"

echo "issue #112 — governed --waive door (diff_coverage_waiver), mirroring check-mutation:"

# A code batch below threshold: 5 changed lines, only 3 covered = 60% < 80% → FAIL without a waiver.
_low_cov_repo() { # $1=dir  $2=extra AGENTS lines
  _base_repo "$1" "${2:-}"
  printf 'code1\nl2\nl3\nl4\nl5\nl6\n' > app.sh; git add -A; git commit -q -m change
  printf 'SF:app.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:5,0\nDA:6,0\nend_of_record\n' > cov.lcov
  _arm
}

# AC-112a — below threshold, no waiver → fail.
T="$(mktemp -d)"; ( _low_cov_repo "$T" ) >/dev/null 2>&1
_chk "$(_gate "$T")" "1" "AC-112a 60% < 80% with no waiver → fail"
rm -rf "$T"

# AC-112b — a valid governed diff_coverage_waiver relieves the fail → pass.
T="$(mktemp -d)"; ( _low_cov_repo "$T"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s","diff_coverage_waiver":{"ack":true,"by":"x","reason":"thin SDK glue","expires":"2999-01-01"}}\n' "$(git rev-parse --short HEAD~1)" > .runs/r/RUN
) >/dev/null 2>&1
_chk "$(_gate "$T")" "0" "AC-112b 60% < 80% + valid diff_coverage_waiver → pass"
# …and the finding is still printed before the waiver is consulted (never silenced).
out="$(_gate_out "$T")"
if printf '%s' "$out" | grep -q "coverage 60%"; then
  _chk "surfaced" "surfaced" "AC-112b finding surfaced above the waiver line"
else _chk "silenced" "surfaced" "AC-112b finding surfaced above the waiver line"; fi
rm -rf "$T"

# AC-112c — an EXPIRED diff_coverage_waiver is not a waiver → still fails.
T="$(mktemp -d)"; ( _low_cov_repo "$T"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s","diff_coverage_waiver":{"ack":true,"by":"x","reason":"r","expires":"2000-01-01"}}\n' "$(git rev-parse --short HEAD~1)" > .runs/r/RUN
) >/dev/null 2>&1
_chk "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$BIN" . >/dev/null 2>&1 ); echo $? )" "1" "AC-112c expired diff_coverage_waiver → fail"
rm -rf "$T"

# AC-112d — the `--waive` writer records diff_coverage_waiver, and a subsequent enforce run passes on it.
T="$(mktemp -d)"; ( _low_cov_repo "$T" ) >/dev/null 2>&1
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$BIN" --waive x r 2999-01-01 >/dev/null 2>&1 )
case "$(cat "$T/.runs/r/RUN")" in
  *'"diff_coverage_waiver":{'*'"by":"x"'*) _chk "wrote" "wrote" "AC-112d --waive wrote diff_coverage_waiver" ;;
  *) _chk "missing" "wrote" "AC-112d --waive wrote diff_coverage_waiver" ;;
esac
_chk "$(_gate "$T")" "0" "AC-112d after --waive, enforce + low coverage → pass"
rm -rf "$T"

# AC-112e — `--waive` with a PAST expiry is refused (exit 1) and writes nothing.
T="$(mktemp -d)"; ( _low_cov_repo "$T" ) >/dev/null 2>&1
_chk "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$BIN" --waive x r 2000-01-01 >/dev/null 2>&1 ); echo $? )" "1" "AC-112e --waive past expiry → refused (exit 1)"
case "$(cat "$T/.runs/r/RUN")" in
  *diff_coverage_waiver*) _chk "wrote" "clean" "AC-112e refused --waive wrote nothing" ;;
  *) _chk "clean" "clean" "AC-112e refused --waive wrote nothing" ;;
esac
rm -rf "$T"

# AC-112f — `--waive` with the wrong arg count is a usage error (exit 64).
T="$(mktemp -d)"; ( _low_cov_repo "$T" ) >/dev/null 2>&1
_chk "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$BIN" --waive x r >/dev/null 2>&1 ); echo $? )" "64" "AC-112f --waive with 2 args → usage error (exit 64)"
rm -rf "$T"

n="$(cat "$FAILF")"; rm -f "$FAILF"
if [ "$n" = "0" ]; then echo "diff-coverage-waiver.test.sh: OK"; exit 0; fi
echo "diff-coverage-waiver.test.sh: $n case(s) FAILED" >&2; exit 1
