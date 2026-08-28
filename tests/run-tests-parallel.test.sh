#!/usr/bin/env bash
# run-tests-parallel.test.sh — the suite runner may execute its members concurrently (#52).
#
# The suite is a sum of independent members with no shared mutable state (each builds its own
# mktemp fixture), so its wall-clock is bounded by the slowest member, not by their sum — but only
# if the runner actually overlaps them. This file proves the overlap happens AND that concurrency
# does not cost correctness: the classic parallel-runner bug is a failure counter incremented from
# subshells, where the parent keeps the count it started with and a red suite reports green.
#
# Deliberately NOT placed in tests/run-tests.test.sh: bin/run-tests.sh:39 excludes that name from
# its own sweep, so assertions written there never execute (#54). This name is swept.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
R="$here/bin/run-tests.sh"
fail=0
_chk() { # got want label
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 — got '$1' want '$2'" >&2; fail=$((fail + 1)); fi
}

# fixture: $1 = dir, $2 = count of green sleepers, $3.. = names of failing members
_fx() {
  local d="$1" n="$2"; shift 2
  mkdir -p "$d/bin" "$d/tests"
  local i=1
  while [ "$i" -le "$n" ]; do
    printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$d/tests/slow$i.test.sh"; i=$((i + 1))
  done
  for b in "$@"; do printf '#!/usr/bin/env bash\nexit 1\n' > "$d/tests/$b.test.sh"; done
}

# --- 1. the flag exists and a green suite stays green ------------------------------------------
T="$(mktemp -d)"; _fx "$T" 2
bash "$R" "$T" --jobs 4 >/dev/null 2>&1
_chk "$?" 0 "--jobs 4 on a green suite → 0"

# --- 2. CONCURRENCY, not a flag that parses and ignores ----------------------------------------
# Eight members that sleep 1s each. Serial floor is 8s; four-way overlap has a ceiling near 2s.
# The 5s bar sits between them with room for a loaded host, so it can only pass by overlapping.
T2="$(mktemp -d)"; _fx "$T2" 8
s=$(date +%s); bash "$R" "$T2" --jobs 4 >/dev/null 2>&1; e=$(date +%s)
el=$((e - s))
if [ "$el" -lt 5 ]; then echo "  PASS 8×1s members with --jobs 4 finish in ${el}s (serial floor is 8s)"
else echo "  FAIL members did not overlap — ${el}s, serial floor 8s" >&2; fail=$((fail + 1)); fi

# --- 2b. the VALUE is honoured, not merely parsed ----------------------------------------------
# Case 2 alone cannot tell "--jobs 4 was honoured" from "--jobs was ignored and the new auto default
# ran it in parallel anyway" — both finish fast. The discriminating direction is the serial one: if
# the value reaches run_suite, --jobs 1 on the same eight sleepers must pay the full 8s floor. A
# runner that parses the flag and drops it fails here and only here.
s=$(date +%s); bash "$R" "$T2" --jobs 1 >/dev/null 2>&1; e=$(date +%s)
el=$((e - s))
if [ "$el" -ge 8 ]; then echo "  PASS --jobs 1 on the same fixture pays the serial floor (${el}s ≥ 8s)"
else echo "  FAIL --jobs 1 did not run serially — ${el}s, floor is 8s (value parsed but dropped?)" >&2; fail=$((fail + 1)); fi

# --- 2c. the operator can see the concurrency that actually ran --------------------------------
out2="$(bash "$R" "$T" --jobs 3 2>&1)"
_chk "$(printf '%s' "$out2" | grep -c 'jobs=3')" 1 "the green line reports the concurrency used"

# --- 3. a red member is still red, and the count survives the subshells -------------------------
T3="$(mktemp -d)"; _fx "$T3" 2 broken
bash "$R" "$T3" --jobs 4 >/dev/null 2>&1
_chk "$?" 1 "one failing member under --jobs 4 → non-zero"

# --- 4. EVERY failure is reported, not just the last to finish ---------------------------------
# A counter incremented inside `&` subshells is lost to the parent; a runner written that way
# reports green here. Both names must reach the operator.
T4="$(mktemp -d)"; _fx "$T4" 2 alpha omega
out="$(bash "$R" "$T4" --jobs 4 2>&1)"
_chk "$(printf '%s' "$out" | grep -c 'alpha')" 1 "failing member 'alpha' named in the output"
_chk "$(printf '%s' "$out" | grep -c 'omega')" 1 "failing member 'omega' named in the output"

# --- 5. serial remains available and equivalent -------------------------------------------------
bash "$R" "$T3" --jobs 1 >/dev/null 2>&1
_chk "$?" 1 "--jobs 1 (serial) reaches the same verdict"

# --- 6. a nonsense job count is refused, not silently treated as 1 ------------------------------
bash "$R" "$T" --jobs 0 >/dev/null 2>&1;   _chk "$?" 64 "--jobs 0 → usage error"
bash "$R" "$T" --jobs cat >/dev/null 2>&1; _chk "$?" 64 "--jobs cat → usage error"

rm -rf "$T" "$T2" "$T3" "$T4"
if [ "$fail" -eq 0 ]; then echo "run-tests-parallel: OK"; exit 0; fi
echo "run-tests-parallel: $fail case(s) FAILED" >&2; exit 1
