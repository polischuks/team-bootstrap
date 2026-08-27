#!/usr/bin/env bash
# tests/gate-detector.test.sh — behavioural test for check-gate-integrity's green-by-skip detector.
#
# The detector answers one question: is this line a GATE THAT STOPPED GATING? Two ways it gets that
# wrong, both of which teach operators to disable it (spec 021 D6, F4):
#   - a CONDITIONAL skip runs under its condition, so it is not a hole — but only pytest's `skipif`
#     spelling was excluded, so every other framework's conditional form was flagged;
#   - a skip quoted in PROSE is not a skipped test at all — but the scan matched `--include='*spec*'`,
#     which matches `spec.md`, so a milestone that merely DESCRIBES the defect reddened the suite.
#
# AC-13 — a conditional skip (callback or predicate-argument form) is not flagged; an unconditional
#         one, INCLUDING one whose label is a variable, still is; prose is never scanned as a test.
# AC-14 — the exclusion is expressed by the property (does the call carry a predicate?), so a
#         framework named nowhere in the implementation behaves correctly with no code edit.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-gate-integrity.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# _flagged FILE CONTENT → "yes" if the detector reports GREEN-BY-SKIP for FILE, else "no".
# Each case gets its own pristine directory: the gate scans a whole tree, so a leftover fixture from
# an earlier case would attribute another case's finding to this one.
_flagged() {
  local rel="$1" content="$2" d out
  d="$(mktemp -d "$T/caseXXXXXX")"; mkdir -p "$d/$(dirname "$rel")"
  printf '%s\n' "$content" > "$d/$rel"
  out="$( cd "$d" && "$gate" . 2>&1 )"
  case "$out" in
    *GREEN-BY-SKIP*)              printf 'yes' ;;
    *"OK — no green-by-skip"*)    printf 'no'  ;;
    # Neither line means the gate did not reach a verdict — a crash, a bad-dir exit, an unreadable
    # library. Reporting that as "no" would make every negative assertion pass against a broken gate.
    *)                            printf 'crashed' ;;
  esac
}
_c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got $1 want $2)" >&2; fail=$((fail + 1)); fi; }

# The fixtures below are DATA for the detector under test, not skipped tests of this suite — the
# recorded-deferral marker is how this tree already says that (tests/harness-robustness.test.sh:257).
# Each literal sits on its own line so the marker above it is unambiguous.

# gate-integrity: sanctioned — fixture: conditional callback form (must NOT be flagged)
cond_cb='test.skip(({ browserName }) => browserName === "webkit", "gate");'
# gate-integrity: sanctioned — fixture: conditional predicate-argument form (must NOT be flagged)
cond_arg='test.skip(process.env.CI !== "1", "gate invariant");'
# gate-integrity: sanctioned — fixture: unconditional, string label (MUST be flagged)
uncond_str='test.skip("gate invariant holds");'
# gate-integrity: sanctioned — fixture: unconditional, VARIABLE label (MUST be flagged)
uncond_var='test.skip(SKIP_REASON);'
# gate-integrity: sanctioned — fixture: the same token quoted in prose (must NOT be flagged)
prose='The gate flags `test.skip("gate")` but not the conditional form.'
# gate-integrity: sanctioned — fixture: unconditional skip whose callback body carries an arrow (MUST be flagged)
uncond_body='it.skip("security contract", () => {});'
# gate-integrity: sanctioned — fixture: an unnamed framework, conditional (must NOT be flagged)
other_cond='bench.skip((ctx) -> ctx.slow, "invariant")'
# gate-integrity: sanctioned — fixture: the same unnamed framework, unconditional (MUST be flagged)
other_uncond='bench.skip("invariant")'

# AC-13 — the callback form of a conditional skip: it RUNS under its condition.
_c "$(_flagged tests/gate.spec.ts "$cond_cb")" no "AC-13 conditional callback skip in a gate test is not flagged"
# AC-13 — the predicate-argument form.
_c "$(_flagged tests/gate.spec.ts "$cond_arg")" no "AC-13 conditional predicate-argument skip is not flagged"
# AC-13 — the unconditional form must STILL be caught, or the exclusion swallows the real finding (R4).
_c "$(_flagged tests/gate.spec.ts "$uncond_str")" yes "AC-13 unconditional skip in a gate test is still flagged"
# AC-13 — unconditional with a VARIABLE label: a label is not a predicate (Step-7 review).
_c "$(_flagged tests/gate.spec.ts "$uncond_var")" yes "AC-13 unconditional skip with a variable label is still flagged"
# AC-13 — PROSE. A markdown document that QUOTES a skip is not a test file.
_c "$(_flagged specs/021-x/spec.md "$prose")" no "AC-13 a skip quoted in a markdown spec is not scanned as a test"
# AC-13 — the same construct in a real test file still is, so the rule is about the FILE, not the string;
# and the arrow in its BODY must not be read as a predicate.
_c "$(_flagged tests/contract.spec.js "$uncond_body")" yes "AC-13 the same string in a real test file is still flagged"
# AC-14 — a framework named nowhere in check-gate-integrity.sh, conditional form, no code edit.
_c "$(_flagged tests/gate_test.exs "$other_cond")" no "AC-14 an unnamed framework's conditional skip is not flagged"
# AC-14 — the same unnamed framework, unconditional, is flagged: the rule reads the property, not the name.
_c "$(_flagged tests/gate_test.exs "$other_uncond")" yes "AC-14 the same unnamed framework's unconditional skip is flagged"


# --- Regressions caught by the B1 conformance review (R4: a fix must not swallow real findings) ---
# The rule that decides conditional-vs-unconditional is framework-aware where it has to be: the
# CALLBACK form is universal, but "first argument is the condition" is a JS test-runner signature.
# Applying it language-agnostically excused Go, whose t.Skip(args ...any) has no conditional form.

# gate-integrity: sanctioned — fixture: Go's two-argument skip is UNCONDITIONAL (MUST be flagged)
go_two='	t.Skip(reason, "temporarily disabled while we refactor")'
# gate-integrity: sanctioned — fixture: nested call inside the first argument (MUST be flagged)
go_nested='	t.Skip(fmt.Sprintf("%s", "gate invariant"))'
# gate-integrity: sanctioned — fixture: a conditional NAME merely mentioned in a comment (MUST be flagged)
comment_mention='test.skip("gate invariant"); // was skipUnless(CI)'
# gate-integrity: sanctioned — fixture: a merely parenthesised label (MUST be flagged)
paren_label='test.skip(("gate invariant"));'
# gate-integrity: sanctioned — fixture: two skips on one line, one conditional, one not (MUST be flagged)
two_on_a_line='test.skip(isCI, "flaky"); test.skip("gate invariant");'
# gate-integrity: sanctioned — fixture: a real suite living under docs/ (MUST be flagged)
docs_suite='it.skip("gate invariant", () => {});'

_c "$(_flagged gate_test.go "$go_two")" yes "AC-13 Go's two-argument skip is unconditional and still flagged"
_c "$(_flagged gate_test.go "$go_nested")" yes "AC-13 a nested call in the first argument does not excuse the skip"
_c "$(_flagged tests/gate.spec.ts "$comment_mention")" yes "AC-13 a conditional name in a COMMENT does not excuse the skip"
_c "$(_flagged tests/gate.spec.ts "$paren_label")" yes "AC-13 a parenthesised label is not a predicate"
_c "$(_flagged tests/gate.spec.ts "$two_on_a_line")" yes "AC-13 one conditional skip does not excuse another on the same line"
_c "$(_flagged docs/gate.test.js "$docs_suite")" yes "AC-13 a real test suite under docs/ is still scanned"

# gate-integrity: sanctioned — fixture: a hard-coded TRUE condition is a constant, not a predicate (MUST be flagged)
const_true='test.skip(true, "gate not implemented");'
# gate-integrity: sanctioned — fixture: an identifier merely STARTING with `async` (MUST be flagged)
async_prefix='it.skip(asyncCaseLabel);'

_c "$(_flagged tests/gate.spec.ts "$const_true")" yes "AC-13 a hard-coded true condition is not a predicate"
_c "$(_flagged tests/gate.spec.ts "$async_prefix")" yes "AC-13 an identifier starting with async is a label, not a callback"

# gate-integrity: sanctioned — fixture: a CHAINED receiver with a constant condition (MUST be flagged)
chained='test.describe.skip(true, "gate");'
# gate-integrity: sanctioned — fixture: the same chain, genuinely conditional (must NOT be flagged)
chained_cond='test.describe.skip(process.env.CI !== "1", "gate");'

_c "$(_flagged tests/gate.spec.ts "$chained")" yes "AC-13 a chained receiver does not hide an unconditional skip"
_c "$(_flagged tests/gate.spec.ts "$chained_cond")" no "AC-13 a chained receiver's conditional form is still excluded"

[ "$fail" -eq 0 ] && { echo "gate-detector.test.sh: OK"; exit 0; }
echo "gate-detector.test.sh: $fail failure(s)" >&2; exit 1
