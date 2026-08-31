#!/usr/bin/env bash
# tests/completeness-scope.test.sh — issue #94: check-completeness --final must scope the AC→test
# search to the spec UNDER DELIVERY, not a repo-wide grep.
#
# AC-N numbering is shared across every spec, so a global grep lets an AC-7 in spec X be "satisfied"
# by a same-numbered AC-7 token in an UNRELATED spec's test (a token collision). This asserts the fix:
#   - an AC referenced only by a FOREIGN spec's test (no association to this spec) → --final FAILS;
#   - the same AC referenced by a test ASSOCIATED with this spec (slug in path/content, or under the
#     spec's directory) → --final PASSES.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-completeness.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

_runf() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" --final . >/dev/null 2>&1 ); echo $?; }
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

# --- fixture: spec s178 declares AC-7; tasks all done ------------------------------------------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r" "$T/specs/s178" "$T/tests"
printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/s178/spec.md"}\n' > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","task_ids":["T001"],"status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
printf '# Spec s178\n\n- AC-7 the spec-178 behaviour\n' > "$T/specs/s178/spec.md"
printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/s178/tasks.md"

# A FOREIGN test (belongs to spec-109): carries an AC-7 token near an assert but never names s178.
printf '# spec 109 cluster gates\n# AC-7\nassert cluster_gate_holds\n' > "$T/tests/spec109_cluster.test.sh"

# #94: an AC satisfied ONLY by a foreign spec's same-numbered token must FAIL --final.
_chk "AC-7 referenced only by a FOREIGN spec's test → --final FAIL (no cross-spec collision)" "$(_runf "$T")" 1

# Now add a test ASSOCIATED with s178 (slug in its path) that asserts AC-7 → PASS.
printf '# core suite for s178\n# AC-7\nassert spec178_behaviour\n' > "$T/tests/s178_core.test.sh"
_chk "AC-7 asserted by a test associated with s178 (slug in path) → --final PASS" "$(_runf "$T")" 0

# Association by CONTENT (slug named in the file body, path unrelated) also counts.
rm -f "$T/tests/s178_core.test.sh"
printf '# suite tagged spec s178\n# AC-7\nassert spec178_behaviour\n' > "$T/tests/core_suite.test.sh"
_chk "AC-7 asserted by a test naming the slug in its content → --final PASS" "$(_runf "$T")" 0
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "completeness-scope.test.sh: OK"; exit 0; }
echo "completeness-scope.test.sh: $fail failure(s)" >&2; exit 1
