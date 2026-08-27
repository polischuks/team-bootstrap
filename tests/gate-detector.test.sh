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
  d="$T/case$RANDOM$RANDOM"; mkdir -p "$d/$(dirname "$rel")"
  printf '%s\n' "$content" > "$d/$rel"
  out="$( cd "$d" && "$gate" . 2>&1 )"
  case "$out" in *GREEN-BY-SKIP*) printf 'yes' ;; *) printf 'no' ;; esac
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

[ "$fail" -eq 0 ] && { echo "gate-detector.test.sh: OK"; exit 0; }
echo "gate-detector.test.sh: $fail failure(s)" >&2; exit 1
