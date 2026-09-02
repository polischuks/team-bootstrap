#!/usr/bin/env bash
# tests/completeness-untokenized-ac.test.sh — issue #111: check-completeness --final must NOT pass
# vacuously when a spec DECLARES acceptance criteria but none are in the recognized AC-N/AcPattern form.
#
# The AC→test half of --final greps for `AC-N` tokens. A spec that writes its acceptance criteria as
# unmarked/checkbox bullets (`- [ ] …`, as specs 179/180 do) has NO tokens, so the grep finds nothing to
# map and the gate prints "no tokens → nothing to enforce" and passes — a green-by-skip on the AC→test
# guarantee. This pins the fix:
#   - a spec that declares ACs only as bullets (no token) → --final FAILS-CLOSED naming the reason;
#   - a spec with GENUINELY no acceptance criteria → --final still passes gracefully;
#   - token-marked ACs (`AC-N`) enforce exactly as before (#94 scoping intact).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-completeness.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

_runf() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" --final . >/dev/null 2>&1 ); echo $?; }
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.runs/r" "$T/specs/demo" "$T/tests"
printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md"}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","task_ids":["T001"],"status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"

# (1) ACs declared ONLY as checkbox bullets under an Acceptance heading, no AC-N token → FAIL-CLOSED.
printf '# Spec\n\n## Acceptance Criteria\n\n- [ ] the widget renders on load\n- [ ] the widget degrades on error\n' > "$T/specs/demo/spec.md"
_chk "#111 spec declares ACs as unmarked bullets (no token) → --final FAIL-CLOSED (no vacuous pass)" "$(_runf "$T")" 1

# (2) An Acceptance section with plain (dash) bullets, still no token → FAIL-CLOSED.
printf '# Spec\n\n## Acceptance\n\n- the export must be idempotent\n- the export must be atomic\n' > "$T/specs/demo/spec.md"
_chk "#111 spec declares ACs as plain bullets under an Acceptance heading (no token) → --final FAIL-CLOSED" "$(_runf "$T")" 1

# (3) A spec with GENUINELY no acceptance criteria (prose only) → passes gracefully.
printf '# Spec\n\nThis milestone documents the rollout plan. There are no acceptance criteria to test.\n' > "$T/specs/demo/spec.md"
_chk "#111 spec with genuinely no ACs → --final PASS (graceful, not a false block)" "$(_runf "$T")" 0

# (4) Token-marked ACs still enforce: AC-1 asserted by an associated test → PASS.
printf '# Spec\n\n## Acceptance Criteria\n\n- AC-1 the thing works\n' > "$T/specs/demo/spec.md"
printf '# AC-1\nassert demo_behaviour\n' > "$T/tests/demo_core.test.sh"
_chk "#111 token-marked AC-1 asserted by an associated test → --final PASS (unchanged)" "$(_runf "$T")" 0

# (5) Token-marked AC with no test still FAILS (guarantee unchanged), not a vacuous skip.
rm -f "$T/tests/demo_core.test.sh"
printf '# Spec\n\n## Acceptance Criteria\n\n- AC-1 the thing works\n' > "$T/specs/demo/spec.md"
_chk "#111 token-marked AC-1 with no associated test → --final FAIL (guarantee holds)" "$(_runf "$T")" 1

[ "$fail" -eq 0 ] && { echo "completeness-untokenized-ac.test.sh: OK"; exit 0; }
echo "completeness-untokenized-ac.test.sh: $fail failure(s)" >&2; exit 1
