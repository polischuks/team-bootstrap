#!/usr/bin/env bash
# run-tests-parallel.test.sh — the suite runner may execute its members concurrently (#52).
#
# The suite is a sum of independent members with no shared mutable state (each builds its own
# mktemp fixture), so its wall-clock is bounded by the slowest member, not by their sum — but only
# if the runner actually overlaps them. This file proves the overlap happens AND that concurrency
# does not cost correctness: the classic parallel-runner bug is a failure counter incremented from
# subshells, where the parent keeps the count it started with and a red suite reports green.
#
# Deliberately NOT placed in tests/run-tests.test.sh: bin/run-tests.sh excludes that name from its
# own sweep, so assertions written there never execute (#54). This name is swept.
#
# COST (#78): this test used to spawn eight real 1-second sleepers and time the run against a serial
# floor, which made it the single slowest suite member (~17s). It now asserts the concurrency
# CONTRACT directly from observed overlap, using tiny synthetic no-op members: each member samples
# how many members are live at the instant it starts, and the test reads the peak. That proves
# "≥2 overlap under --jobs>1" and "≤ jobs concurrent" and "every member accounted for" without paying
# a serial floor in wall-time. Under selective mode (#76) this file also runs only when the runner
# changes: a --changed run selects it via the tests-referencing-'run-tests' rule.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
R="$here/bin/run-tests.sh"
fail=0
_chk() { # got want label
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 — got '$1' want '$2'" >&2; fail=$((fail + 1)); fi
}

# _fx DIR N [FAILING…] — N green members that each SAMPLE live-concurrency at entry into DIR/samples
# (via a per-member marker under DIR/live), then a short sleep, then unmark. Plus a bare `exit 1`
# member per FAILING name. The sample stream lets the test read peak concurrency without any
# non-portable hi-res clock (%N is unavailable on BSD/macOS date).
_fx() {
  local d="$1" n="$2"; shift 2
  mkdir -p "$d/bin" "$d/tests" "$d/live"; : > "$d/samples"
  local i=1
  while [ "$i" -le "$n" ]; do
    cat > "$d/tests/slow$i.test.sh" <<EOF
#!/usr/bin/env bash
touch "$d/live/slow$i.\$\$"
ls "$d/live" | wc -l | tr -d ' ' >> "$d/samples"
sleep 0.15
rm -f "$d/live/slow$i.\$\$"
exit 0
EOF
    i=$((i + 1))
  done
  for b in "$@"; do printf '#!/usr/bin/env bash\nexit 1\n' > "$d/tests/$b.test.sh"; done
}
_reset()  { : > "$1/samples"; rm -f "$1/live/"* 2>/dev/null; }        # clear the sample stream
_peak()   { sort -n "$1/samples" 2>/dev/null | tail -1; }              # max observed concurrency
_nsamp()  { grep -c '.' "$1/samples" 2>/dev/null | tr -d ' '; }        # members that actually ran

# --- 1. the flag exists and a green suite stays green ------------------------------------------
T="$(mktemp -d)"; _fx "$T" 2
bash "$R" "$T" --jobs 4 >/dev/null 2>&1
_chk "$?" 0 "--jobs 4 on a green suite → 0"

# --- 2. CONCURRENCY, not a flag that parses and ignores ----------------------------------------
# Six no-op members under --jobs 3. If the runner overlaps them, some member starts while ≥1 other
# is still live, so the peak sample is ≥2; the sliding window caps the peak at the job count, so it
# is also ≤3. Every member samples exactly once, so the sample count equals the member count.
T2="$(mktemp -d)"; _fx "$T2" 6
_reset "$T2"; bash "$R" "$T2" --jobs 3 >/dev/null 2>&1
peak="$(_peak "$T2")"
if [ "${peak:-0}" -ge 2 ]; then echo "  PASS members overlap under --jobs 3 (peak concurrency ${peak} ≥ 2)"
else echo "  FAIL members did not overlap — peak ${peak:-0}, want ≥ 2" >&2; fail=$((fail + 1)); fi
if [ "${peak:-0}" -le 3 ]; then echo "  PASS concurrency never exceeds the job count (peak ${peak} ≤ 3)"
else echo "  FAIL window breached — peak ${peak}, cap is 3" >&2; fail=$((fail + 1)); fi
_chk "$(_nsamp "$T2")" 6 "all 6 members accounted for (each sampled exactly once)"

# --- 2b. the VALUE is honoured, not merely parsed ----------------------------------------------
# Case 2 alone cannot tell "--jobs 3 was honoured" from "--jobs was ignored and the new auto default
# ran it in parallel anyway". The discriminating direction is serial: --jobs 1 on the SAME members
# must never overlap, so the peak is exactly 1. A runner that parses the flag and drops it fails here.
_reset "$T2"; bash "$R" "$T2" --jobs 1 >/dev/null 2>&1
_chk "$(_peak "$T2")" 1 "--jobs 1 runs strictly serially (peak concurrency = 1, value not dropped)"

# --- 2c. the operator can see the concurrency that actually ran --------------------------------
out2="$(bash "$R" "$T" --jobs 3 2>&1)"
_chk "$(printf '%s' "$out2" | grep -c 'jobs=3')" 1 "the green line reports the concurrency used"

# --- 2d. an explicit value above the host's core count is honoured, not clamped ----------------
# The cap in auto_jobs() applies to the DEFAULT only. An operator on a small host who wants more
# concurrency than cores must get it: suite members fork and wait on I/O rather than compute, so
# oversubscription overlaps waiting. A clamp here would silently hand back the slower run.
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$cores" in ''|*[!0-9]*) cores=1 ;; esac
over=$((cores + 4))
_chk "$(bash "$R" "$T" --jobs "$over" 2>&1 | grep -c "jobs=$over")" 1 \
  "--jobs above the core count ($over > $cores) is honoured, not clamped"

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
