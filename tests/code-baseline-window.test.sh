#!/usr/bin/env bash
# tests/code-baseline-window.test.sh — issue #104: the first code batch's window must start AFTER Phase A.
#
# baseline_sha is stamped by delivery-marker-init when /deliver ARMS the run, BEFORE Phase A commits
# `docs(spec-…)` + feature.json. Those Phase-A commits land after baseline and before the first code
# batch, so they fall inside the first batch's window (current_batch_base == baseline_sha for the first
# batch). #93's impl-delta filter drops a pure-doc or pure-test Phase-A commit, but a Phase-A commit that
# ALSO touches a non-test-non-doc artifact (feature.json / a config) has impl_delta > 0 and survives —
# it becomes the first batch's oldest commit_sha and the wrong tdd anchor.
#
# The fix: current_batch_base prefers a `code_baseline_sha` marker field (the harness-recorded A→B
# boundary — after Phase-A producing/doc commits, before the first red) over baseline_sha for the FIRST
# batch. This test drives current_batch_base directly and asserts the Phase-A feature.json commit is NOT
# in current_batch_base..HEAD once code_baseline_sha is recorded, while baseline_sha still names the run's
# true start (untouched, for the reachable-from-HEAD / predate checks). Absent code_baseline_sha ⇒ old
# behaviour (window == baseline_sha), so a spec-already-on-disk run is unchanged.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/bin/delivery-lib.sh"

fail=0
_rc() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 — expected [$2], got [$3]" >&2; fail=$((fail + 1)); fi; }

T="$(mktemp -d)"
git_t() { ( cd "$T" && "$@" ); }
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > app.txt && git add . && git commit -qm baseline ) >/dev/null 2>&1
baseline="$(git_t git rev-parse --short HEAD)"
# Phase A: a MIXED docs commit — spec.md (doc) AND feature.json (non-test-non-doc config). impl_delta > 0,
# so #93's filter would keep it; it is the A→B boundary the first code batch's window must start AFTER.
( cd "$T" && echo spec > spec.md && echo '{}' > feature.json && git add . && git commit -qm "docs(spec-1): scaffold + retarget feature.json" ) >/dev/null 2>&1
phaseA="$(git_t git rev-parse --short HEAD)"
# Phase B: the first code batch — a red (test) then impl.
( cd "$T" && echo t > app_test.sh && git add app_test.sh && git commit -qm "red: failing test" ) >/dev/null 2>&1
red="$(git_t git rev-parse --short HEAD)"
( cd "$T" && echo impl >> app.txt && git add app.txt && git commit -qm "B1 impl" ) >/dev/null 2>&1

mkdir -p "$T/.runs/r"

echo "== 1) no code_baseline_sha → window == baseline_sha (unchanged; Phase-A commit still inside) =="
printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$baseline" > "$T/.runs/r/RUN"
base_noadv="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r bash -c '. "'"$here"'/bin/delivery-lib.sh"; current_batch_base' )"
_rc "current_batch_base falls back to baseline_sha when code_baseline_sha absent" "$baseline" "$base_noadv"
# the Phase-A commit IS reachable in baseline..HEAD (the bug surface)
in_win="$( cd "$T" && git rev-list "$baseline"..HEAD | grep -qF "$(git rev-parse "$phaseA")" && echo yes || echo no )"
_rc "Phase-A feature.json commit is inside the un-advanced window (documents the bug)" "yes" "$in_win"

echo "== 2) code_baseline_sha recorded at the A→B boundary → window advances past Phase A =="
printf '{"run":"r","intends_code":true,"baseline_sha":"%s","code_baseline_sha":"%s"}\n' "$baseline" "$phaseA" > "$T/.runs/r/RUN"
base_adv="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r bash -c '. "'"$here"'/bin/delivery-lib.sh"; current_batch_base' )"
_rc "current_batch_base prefers code_baseline_sha for the first batch" "$phaseA" "$base_adv"
# the Phase-A commit is NOT in current_batch_base..HEAD; the red IS
out_win="$( cd "$T" && git rev-list "$base_adv"..HEAD | grep -qF "$(git rev-parse "$phaseA")" && echo yes || echo no )"
_rc "Phase-A feature.json commit is OUTSIDE the advanced window" "no" "$out_win"
red_in="$( cd "$T" && git rev-list "$base_adv"..HEAD | grep -qF "$(git rev-parse "$red")" && echo yes || echo no )"
_rc "the batch's own red IS inside the advanced window" "yes" "$red_in"

echo "== 3) baseline_sha still names the run's true start (predate/reachable checks unchanged) =="
mk="$(cat "$T/.runs/r/RUN")"
_rc "baseline_sha unchanged in the marker" "$baseline" "$(field_str "$mk" baseline_sha)"

echo "== 4) an unresolvable code_baseline_sha falls back to baseline_sha (operator-safe) =="
printf '{"run":"r","intends_code":true,"baseline_sha":"%s","code_baseline_sha":"deadbeef"}\n' "$baseline" > "$T/.runs/r/RUN"
base_bad="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r bash -c '. "'"$here"'/bin/delivery-lib.sh"; current_batch_base' )"
_rc "unresolvable code_baseline_sha → falls back to baseline_sha" "$baseline" "$base_bad"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "code-baseline-window.test.sh: OK"; exit 0; fi
echo "code-baseline-window.test.sh: $fail assertion(s) FAILED" >&2; exit 1
