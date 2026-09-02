#!/usr/bin/env bash
# tests/completeness-slug-widen.test.sh — issue #94 (comment): widen the spec↔test association so a test
# named by the spec NUMBER (`_108.py`) or carrying a declared `Spec:`/`SpecId:` tag associates with the
# spec, not ONLY a test that embeds the full multi-word dir slug (`108-cited-table-cell-false-degrade`).
#
# The cross-spec-collision protection stays: the number is matched as a BOUNDED token scoped per-spec, so
# 108 does not associate with 107 (or 1080, or 2108).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-completeness.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

_runf() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" --final . >/dev/null 2>&1 ); echo $?; }
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

SLUG="108-cited-table-cell-false-degrade"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.runs/r" "$T/specs/$SLUG" "$T/tests"
printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/%s/spec.md"}\n' "$SLUG" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","task_ids":["T001"],"status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
printf '# Spec 108\n\n- AC-0 the degrade path\n' > "$T/specs/$SLUG/spec.md"
printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/$SLUG/tasks.md"

# (1) Test named by the spec NUMBER only (`_108.py`) — no full slug anywhere — associates → PASS.
printf '# 108 degrade suite\n# AC-0\nassert degrade_path\n' > "$T/tests/table_cell_108.py"
_chk "#94 test named by the spec number (_108.py, no full slug) associates → --final PASS" "$(_runf "$T")" 0
rm -f "$T/tests/table_cell_108.py"

# (2) A FOREIGN test named by a DIFFERENT spec number (_107) must NOT associate → FAIL (108 ≠ 107).
printf '# 107 suite\n# AC-0\nassert other_spec_behaviour\n' > "$T/tests/table_cell_107.py"
_chk "#94 foreign test named _107.py does not satisfy spec-108's AC-0 → --final FAIL (per-spec number scope)" "$(_runf "$T")" 1
rm -f "$T/tests/table_cell_107.py"

# (3) The number must be a BOUNDED token — `_1080` / `2108` must NOT associate (no partial-number match).
printf '# unrelated 1080 / 2108 numbers\n# AC-0\nassert unrelated\n' > "$T/tests/thing_1080_2108.py"
_chk "#94 partial-number filenames (1080/2108) do not associate with spec-108 → --final FAIL" "$(_runf "$T")" 1
rm -f "$T/tests/thing_1080_2108.py"

# (4) A declared `Spec:` tag in the test body (path unrelated to 108) associates → PASS.
printf '# Spec: 108\n# AC-0\nassert via_spec_tag\n' > "$T/tests/core_suite.py"
_chk "#94 test carrying a declared 'Spec: 108' tag associates → --final PASS" "$(_runf "$T")" 0
rm -f "$T/tests/core_suite.py"

# (5) A `SpecId:` tag naming the number also associates → PASS.
printf '# SpecId: 108\n# AC-0\nassert via_specid_tag\n' > "$T/tests/other_suite.py"
_chk "#94 test carrying a declared 'SpecId: 108' tag associates → --final PASS" "$(_runf "$T")" 0
rm -f "$T/tests/other_suite.py"

# (6) The full-slug association (the original behaviour) still works → PASS.
printf '# %s\n# AC-0\nassert via_full_slug\n' "$SLUG" > "$T/tests/legacy_suite.py"
_chk "#94 full-slug association still works (back-compat) → --final PASS" "$(_runf "$T")" 0

[ "$fail" -eq 0 ] && { echo "completeness-slug-widen.test.sh: OK"; exit 0; }
echo "completeness-slug-widen.test.sh: $fail failure(s)" >&2; exit 1
