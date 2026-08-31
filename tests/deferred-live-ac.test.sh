#!/usr/bin/env bash
# tests/deferred-live-ac.test.sh — issue #100: a sanctioned, GOVERNED deferred-live AC.
#
# Some ACs can only be exercised against a live/P5-gated resource. The natural `pytest.skip("AC-4 live")`
# trips check-gate-integrity's green-by-skip, while check-completeness --final still needs the AC
# referenced by a test — an unsatisfiable pair. The fix is a sanctioned deferred-live form
# (a `DeferredLiveAC:`/`deferred_live` marker) PLUS a governed `deferred_live_waiver` (by+reason+expiry)
# in the run marker, such that:
#   - check-gate-integrity does NOT count the marked skip as green-by-skip (governed, expiring deferral);
#   - check-completeness --final counts the AC as referenced (the deferred test IS its reference);
#   - an ORDINARY (unmarked / ungoverned) skip STILL trips gate-integrity — the escape is governed.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gi="$here/bin/check-gate-integrity.sh"
cc="$here/bin/check-completeness.sh"
fail=0
[ -x "$gi" ] || { echo "FAIL: $gi missing" >&2; exit 1; }
[ -x "$cc" ] || { echo "FAIL: $cc missing" >&2; exit 1; }
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

GOV='"deferred_live_waiver":{"ack":true,"by":"alice","reason":"AC-4 live/P5-gated, deferred to live run","expires":"2099-01-01"}'

# The skip literals below are DATA written into throwaway fixture trees, not skipped tests of THIS
# suite — the recorded-deferral marker is how this tree already tells check-gate-integrity that
# (tests/gate-detector.test.sh does the same for its fixtures). Each sits on its own line so the
# marker above it is unambiguous.
# gate-integrity: sanctioned — fixture: the DEFERRED-LIVE skip written into a throwaway gate test
dl_skip='    pytest.skip("AC-4 deferred to live run")'
# gate-integrity: sanctioned — fixture: an ORDINARY (unmarked) skip written into a throwaway gate test
plain_skip='    pytest.skip("gate invariant not implemented")'
# gate-integrity: sanctioned — fixture: the deferred-live skip for the --final suite (no def-test nearby)
dl_skip_final='pytest.skip("AC-4 deferred to live run")'

# ================= gate-integrity: green-by-skip vs a governed deferred-live skip ====================
_gi() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gi" . >/dev/null 2>&1 ); echo $?; }

# A gate/invariant test whose live AC is deferred, with the DeferredLiveAC marker on the line above.
mk_deferred() { mkdir -p "$1/tests"; {
  printf 'def test_live_fetch():\n'
  printf '    # DeferredLiveAC: AC-4 — live/P5-gated, deferred to a live run\n'
  printf '%s\n' "$dl_skip"; } > "$1/tests/gate_invariant_test.py"; }

# (a) governed waiver present + DeferredLiveAC marker → NOT green-by-skip → exit 0.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness",%s}\n' "$GOV" > "$T/.runs/r/RUN"
mk_deferred "$T"
_chk "governed deferred_live_waiver + DeferredLiveAC marker → gate-integrity clean (exit 0)" "$(_gi "$T")" 0

# (b) SAME deferred-live skip but NO governed waiver → still green-by-skip → exit 1 (escape is governed).
printf '{"run":"r","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
_chk "DeferredLiveAC marker but NO governed waiver → still trips gate-integrity (exit 1)" "$(_gi "$T")" 1

# (c) ordinary skip (no marker) WITH the governed waiver present → still trips (not a blanket exemption).
printf '{"run":"r","intends_code":true,"source":"harness",%s}\n' "$GOV" > "$T/.runs/r/RUN"
{ printf 'def test_plain():\n'; printf '%s\n' "$plain_skip"; } > "$T/tests/gate_invariant_test.py"
_chk "ordinary unmarked skip + governed waiver → still trips gate-integrity (exit 1)" "$(_gi "$T")" 1
rm -rf "$T"

# ================= check-completeness --final counts a governed deferred-live AC ======================
_runf() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$cc" --final . >/dev/null 2>&1 ); echo $?; }

# spec s101 declares AC-4; its only test DEFERS it (skip + DeferredLiveAC marker, NO assertion construct).
T="$(mktemp -d)"; mkdir -p "$T/.runs/r" "$T/specs/s101" "$T/tests"
printf '# Spec s101\n\n- AC-4 the live/P5-gated behaviour\n' > "$T/specs/s101/spec.md"
printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/s101/tasks.md"
{ printf '# suite for s101\n'
  printf '# DeferredLiveAC: AC-4 — live/P5-gated, deferred to a live run\n'
  printf '%s\n' "$dl_skip_final"; } > "$T/tests/s101_live_test.py"

# (d) with the governed waiver, the deferred AC-4 counts as referenced → --final PASS.
printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/s101/spec.md",%s}\n' "$GOV" > "$T/.runs/r/RUN"
_chk "governed deferred_live_waiver → --final counts the deferred AC-4 as referenced (exit 0)" "$(_runf "$T")" 0

# (e) without the governed waiver, a deferred AC with no assertion construct is NOT referenced → FAIL.
printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/s101/spec.md"}\n' > "$T/.runs/r/RUN"
_chk "no governed waiver → deferred AC-4 not counted, no assertion construct → --final FAIL (exit 1)" "$(_runf "$T")" 1
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "deferred-live-ac.test.sh: OK"; exit 0; }
echo "deferred-live-ac.test.sh: $fail failure(s)" >&2; exit 1
