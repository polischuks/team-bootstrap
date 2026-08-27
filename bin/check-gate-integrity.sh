#!/usr/bin/env bash
# check-gate-integrity.sh — meta-check that gates actually run (fail-closed).
#
# A gate is only worth its non-disableability. This flags two ways a gate stops
# gating while still reading green:
#   1. green-by-skip — a gate/invariant/constitutional/contract test that passes
#      only because it is skipped (@pytest.mark.skip, .skip(, t.Skip, @Disabled…);
#   2. silent degradation — a `bin/check-*.sh` that exits 0 on an unmet precondition without
#      stating a reason, so "skipped" and "passed" are the same result to every reader (AC-48);
#   3. a gate that can't fail — `continue-on-error: true` on a CI gate job.
# See references/regression-and-invariants.md (section 3).
#
# NOT flagged (a conditional skip still RUNS under the right condition, and an
# explicitly-justified deferral is a decision, not a silent hole):
#   - conditional skips: @pytest.mark.skipif / lines containing `skipif`;
#   - sanctioned skips: any skip line carrying an inline `gate-integrity:
#     sanctioned` marker (add `# gate-integrity: sanctioned — <reason>` on the
#     skip line to record WHY the deferral does not hide a gate).
#
# Usage: bin/check-gate-integrity.sh [project-dir]   # default: current dir
# Exit:  0 clean / not machine-checkable · 1 integrity violation · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-gate-integrity: bad dir '$root'" >&2; exit 64; }

KEY='invariant|constitution|constitutional|gate|contract|security|guard'
SKIP='@pytest\.mark\.skip|@unittest\.skip|pytest\.skip\(|\.skip\(|\bxit\(|\bxdescribe\(|it\.skip|describe\.skip|test\.skip|t\.Skip\(|@Disabled|@Ignore'
# Exclusions applied to matched skip lines. Expressed by the PROPERTY, not by a list of frameworks
# (spec 021 AC-14): a skip that carries a PREDICATE runs under its condition and is therefore not a
# hole, whichever library spells it. `skipif` used to be the whole rule, so pytest was the only
# framework whose conditional form was understood and every other one was reported as green-by-skip —
# a gate that fails on correct code is a gate operators learn to route around (F4).
#
# A predicate is one of, and each is anchored to the skip call's FIRST ARGUMENT — never merely
# present on the line:
#   - a callback:             .skip(({ browserName }) => …)   .skip(function () …)   .skip(async …)
#   - a condition-then-label: .skip(cond, "why")  — a first argument that is not a string literal,
#                             followed by one that is;
#   - a conditional NAME:     skipif / skipIf / skipUnless / skipWhen / assumeTrue.
# A LABEL is not a predicate. `test.skip("gate")` and `test.skip(SKIP_REASON)` are both unconditional —
# the second is why "the first argument is not a string" cannot be the rule on its own — and
# `it.skip("contract", () => {})` is unconditional too, which is why an unanchored `=>` cannot be
# either: the arrow there is the test BODY. Both misreads were caught by tests/gate-detector.test.sh
# before this rule shipped.
# Anything the regex cannot parse (a first argument containing its own parens or comma) falls through
# to FLAGGED — a detector in doubt reports, it does not excuse (P10).
EXCLUDE='skipif|skipIf|skipUnless|skipWhen|assumeTrue|gate-integrity:[[:space:]]*sanctioned'
EXCLUDE="$EXCLUDE"'|\.skip\([[:space:]]*(\(|function|async|[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*(=>|->))'
EXCLUDE="$EXCLUDE"'|\.skip\([[:space:]]*[^"'"'"'[:space:])][^,)]*,[[:space:]]*["'"'"']'

viol=0

# 1) green-by-skip on a gate/invariant/constitutional/contract test -------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  _is_doc_path "${f#./}" && continue     # prose that quotes a skip is not a skipped test (AC-13)
  if printf '%s' "$f" | grep -qiE "$KEY" || grep -qiE "$KEY" "$f" 2>/dev/null; then
    # Candidate skip lines, minus conditional (skipif) and same-line-sanctioned ones.
    # A sanction marker is also honoured on the line IMMEDIATELY ABOVE the skip, so a
    # long skip line need not carry an over-length trailing comment.
    sk=""
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      prev="$(sed -n "$((ln - 1))p" "$f" 2>/dev/null)"
      printf '%s' "$prev" | grep -qiE 'gate-integrity:[[:space:]]*sanctioned' && continue
      sk="${sk}${ln}:${text}
"
    done < <(grep -nEi "$SKIP" "$f" 2>/dev/null | grep -vEi "$EXCLUDE" | head -20)
    sk="$(printf '%s' "$sk" | grep -vE '^$' | head -5)"
    [ -n "$sk" ] || continue
    echo "check-gate-integrity: GREEN-BY-SKIP in gate/invariant test '$f':" >&2
    printf '%s\n' "$sk" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
# The scan matches by FILENAME, and `--include='*spec*'` matches `spec.md` — so a document that merely
# QUOTES a skip was scanned as if it were a suite. Measured: this milestone's own spec.md, plan.md and
# tasks.md turned bin/run-tests.sh red by describing the defect. A skip in prose is not a skipped test,
# so documentation paths are dropped here, through delivery-lib's ONE definition of a doc path
# (_is_doc_path — shared with the code-delta counter, so "documentation" means one thing in this tree).
done < <(grep -rlE "$SKIP" . --include='*test*' --include='*spec*' --include='*_test.go' \
  --exclude='*.pyc' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.claude \
  --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=venv \
  --exclude-dir=dist --exclude-dir=build --exclude-dir=.next \
  --exclude-dir=.mypy_cache --exclude-dir=.ruff_cache --exclude-dir=.pytest_cache \
  2>/dev/null | head -100)

# 2) SILENT DEGRADATION — a gate that returns emptiness instead of a decision (AC-48) ------------
#
# The third way a gate stops gating, and the one no check looked for. `exit 0` on an unmet
# precondition is correct and necessary — check-tdd skips without a Test: command, check-version-sync
# skips without a version location — but a skip that says NOTHING is indistinguishable, in a log and
# in a batch result, from a gate that ran and passed. AC-47 removed exactly this shape from
# size-from-spec.sh (`--per-batch` returned empty where it now returns `degraded=1 reason=…`), and
# AC-48 asks for the audit: every path that declines to decide states why.
#
# Flagged: a `bin/check-*.sh` line that exits 0 inside a conditional with no output on any stream.
# Not flagged: an exit 0 that prints first (the reason IS the output), the unconditional final exit 0
# of a passing gate, and the `--self-test` block (its exits are the test's own results).
SILENT=0
for f in bin/check-*.sh; do
  [ -f "$f" ] || continue
  # `|| exit 0`, `&& exit 0`, `{ exit 0; }` and `then exit 0` with nothing echoed on the same line.
  # The shape is a PRECONDITION guard: `<test> || exit 0` / `<test> && exit 0`, optionally braced.
  # Deliberately NOT the terminal dispatch `if _evaluate; then exit 0; else exit 1; fi` — the function
  # has already printed its verdict there, so the exit carries no information of its own — and not
  # `--help`. A pattern that flagged those would report every gate in the tree, and a check that cries
  # wolf on correct code gets disabled, which is the outcome this whole file exists to prevent.
  q="$(grep -nE '^[[:space:]]*[^#]*(\|\||&&)[[:space:]]*(\{[[:space:]]*)?exit 0' "$f" 2>/dev/null \
       | grep -vE 'echo|printf|>&2|self-test|--help|then[[:space:]]+exit[[:space:]]+0|gate-integrity:[[:space:]]*sanctioned' \
       | head -5)"
  [ -n "$q" ] || continue
  echo "check-gate-integrity: SILENT DEGRADATION in '$f' — exits 0 without stating a reason:" >&2
  printf '%s\n' "$q" | sed 's/^/    /' >&2
  SILENT=$((SILENT + 1))
done
[ "$SILENT" -eq 0 ] || viol=$((viol + SILENT))

# 3) a gate that can't fail: continue-on-error on a CI job -----------------------
if [ -d .github/workflows ]; then
  ce="$(grep -rnE 'continue-on-error:[[:space:]]*true' .github/workflows 2>/dev/null | head -20)"
  if [ -n "$ce" ]; then
    echo "check-gate-integrity: gate cannot fail (continue-on-error) in CI:" >&2
    printf '%s\n' "$ce" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
fi

if [ "$viol" -gt 0 ]; then
  echo "check-gate-integrity: $viol integrity issue(s) — a gate that doesn't run is a failure, not a pass." >&2
  # WS-8 (harness-robustness): a GOVERNED run-level waiver clears pre-existing findings the batch did not
  # introduce (the retro's dashboard skips + e2e continue-on-error OUTSIDE the batch delta, which forced a
  # hand-stamp every batch). It does NOT silence them — the findings are already printed above. Governed =
  # ack + by + reason + expires; expiry forces re-review, so a disabled gate cannot pass forever. In CI
  # there is no run marker, so the waiver is impossible there and a genuinely disabled gate is never hidden.
  # (Full per-finding delta-scoping is deferred — arch-review flagged its risk of silently dropping a
  # finding outside the delta; a surfaced-and-expiring waiver is the sound, simpler mechanism.)
  marker="$(resolve_marker)"
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    mk="$(cat "$marker" 2>/dev/null || true)"
    if governed_waiver_ok \
         "$(field_in_obj "$mk" gate_integrity_waiver ack)" \
         "$(field_in_obj "$mk" gate_integrity_waiver by)" \
         "$(field_in_obj "$mk" gate_integrity_waiver reason)" \
         "$(field_in_obj "$mk" gate_integrity_waiver expires)"; then
      echo "check-gate-integrity: WAIVED by a governed gate_integrity_waiver (findings surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0." >&2
      exit 0
    fi
  fi
  exit 1
fi
echo "check-gate-integrity: OK — no green-by-skip or can't-fail gate detected."
exit 0
