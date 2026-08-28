#!/usr/bin/env bash
# run-tests.sh — team-bootstrap's `Test:` command (milestone closed-loop-fidelity, batch A1).
#
# Runs every `bin/*.sh --self-test` and every `tests/*.test.sh` under ROOT (default: repo root)
# and exits non-zero if any fails. This is the runnable suite AGENTS.md declares as `Test:`, so the
# harness red-first gate (check-tdd.sh --record-red → check-tdd.sh) has something real to observe red→green against
# on team-bootstrap's own delivery runs — closing the `red-first` enforcement gap the repo carried.
#
# It deliberately does NOT back a `Coverage:`/`Mutation:` contract: there is no bash coverage/mutation
# tool on the host, and a declared-but-toolless command is exactly the vacuous gate this milestone
# forbids. Those two dimensions stay honestly gapped and are covered by a governed, expiring
# enforcement waiver (see references/enforcement.md) — never a faked runner.
#
# Members are independent — each builds its own mktemp fixture and none writes into the repo — so
# they may run concurrently. Wall-clock is then bounded by the slowest member rather than by their
# sum. Concurrency does not reorder the report: a failure is recorded as a file named after its
# member and the report is emitted by sorted glob, so the same red suite prints the same lines in
# the same order on every run, whatever order the members happen to finish in.
#
# Usage: bin/run-tests.sh [root] [--jobs N]   ·   bin/run-tests.sh --self-test
#        N defaults to the host CPU count capped at 8; --jobs 1 forces the serial path.
#        TB_TEST_JOBS sets the default without touching the command line.
# Exit:  0 all green · 1 one or more suites failed · 64 bad usage
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# auto_jobs → a sane default concurrency for this host: CPU count, capped at 8, floor 1.
# The cap is not about CPUs — most members are shell and I/O rather than compute, and beyond a
# handful of them the host's fork/exec and disk become the limit while the failure blast radius of
# a genuinely order-dependent member keeps growing.
auto_jobs() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -gt 8 ] && n=8
  [ "$n" -lt 1 ] && n=1
  echo "$n"
}

# run_member SPEC DIR — run one member; on failure drop a file named after it into DIR.
# The verdict travels as a FILE, not a variable: a counter incremented inside a `&` subshell is
# lost to the parent, which is how a parallel runner comes to report a red suite as green.
run_member() {
  local spec="$1" dir="$2" kind path base
  kind="${spec%%|*}"; path="${spec#*|}"; base="$(basename "$path")"
  if [ "$kind" = "self" ]; then
    bash "$path" --self-test >/dev/null 2>&1 \
      || printf 'run-tests: FAIL self-test — %s\n' "$base" > "$dir/$base.self.fail"
  else
    bash "$path" >/dev/null 2>&1 \
      || printf 'run-tests: FAIL test — %s\n' "$base" > "$dir/$base.test.fail"
  fi
}

# run_suite ROOT [JOBS] → 0 if every bin/*.sh --self-test and tests/*.test.sh under ROOT passes.
# Skips the runner itself and its own test to avoid re-entry. JOBS defaults to 1 (serial).
run_suite() {
  local root="$1" jobs="${2:-1}" fails=0 f base m dir ff
  local mem=()
  for f in "$root"/bin/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "run-tests.sh" ] && continue
    # A script HANDLES --self-test only if it dispatches on the flag. Matching the bare string anywhere
    # made any mention — a comment, or a call to ANOTHER script's self-test — look like a self-test mode,
    # and the runner then invoked a flag the script does not accept and reported it as a failing suite.
    grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$f" 2>/dev/null || continue
    mem[${#mem[@]}]="self|$f"
  done
  for f in "$root"/tests/*.test.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "run-tests.test.sh" ] && continue
    mem[${#mem[@]}]="test|$f"
  done
  [ "${#mem[@]}" -eq 0 ] && return 0

  dir="$(mktemp -d)"
  for m in "${mem[@]}"; do
    if [ "$jobs" -gt 1 ]; then
      # Sliding window rather than fixed chunks: a chunk barrier would idle every finished slot
      # until the chunk's slowest member returned, which is the same wasted wall-clock the whole
      # change is here to remove. `jobs -pr` counts only this shell's running background members.
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$jobs" ]; do sleep 0.05; done
      run_member "$m" "$dir" &
    else
      run_member "$m" "$dir"
    fi
  done
  wait

  # Sorted glob, so the report is byte-identical across runs no matter who finished first.
  for ff in "$dir"/*.fail; do
    [ -e "$ff" ] || continue
    cat "$ff" >&2; fails=$((fails + 1))
  done
  rm -rf "$dir"
  [ "$fails" -eq 0 ]
}

# --- self-test: run_suite is red iff some member fails, green iff none -------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/tests"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --self-test) exit 0;; esac\n' > "$T/bin/ok.sh"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --self-test) exit 1;; esac\n' > "$T/bin/bad.sh"
  if run_suite "$T"; then echo "  FAIL: red suite (bad self-test) reported green" >&2; fail=$((fail + 1)); else echo "  PASS red suite (bad self-test) → non-zero"; fi
  rm -f "$T/bin/bad.sh"
  if run_suite "$T"; then echo "  PASS green suite → zero"; else echo "  FAIL: green suite reported red" >&2; fail=$((fail + 1)); fi
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/tests/x.test.sh"
  if run_suite "$T"; then echo "  FAIL: failing tests/ member not caught" >&2; fail=$((fail + 1)); else echo "  PASS failing tests/ member → non-zero"; fi
  # The parallel path must reach the SAME verdict — a red suite stays red when the members run
  # in subshells, which is where a lost failure count would show.
  if run_suite "$T" 4; then echo "  FAIL: red suite reported green under jobs=4" >&2; fail=$((fail + 1)); else echo "  PASS red suite under jobs=4 → non-zero"; fi
  rm -f "$T/tests/x.test.sh"
  if run_suite "$T" 4; then echo "  PASS green suite under jobs=4 → zero"; else echo "  FAIL: green suite reported red under jobs=4" >&2; fail=$((fail + 1)); fi
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "run-tests --self-test: OK"; exit 0; fi
  echo "run-tests --self-test: $fail case(s) FAILED" >&2; exit 1
fi

usage() { echo "usage: run-tests.sh [root] [--jobs N] | --self-test"; }

root=""; jobs="${TB_TEST_JOBS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --jobs|-j)  shift; jobs="${1:-}" ;;
    --jobs=*)   jobs="${1#*=}" ;;
    -*) echo "run-tests: unknown option '$1'" >&2; usage >&2; exit 64 ;;
    *)  [ -n "$root" ] && { echo "run-tests: more than one root given" >&2; exit 64; }
        root="$1" ;;
  esac
  shift
done

# A job count that cannot be honoured is a usage error, never a silent fall back to serial: the
# operator who asked for concurrency would otherwise be told nothing and wait out the serial time.
if [ -n "$jobs" ]; then
  case "$jobs" in ''|*[!0-9]*) echo "run-tests: --jobs takes a positive integer, got '$jobs'" >&2; exit 64 ;; esac
  [ "$jobs" -ge 1 ] || { echo "run-tests: --jobs takes a positive integer, got '$jobs'" >&2; exit 64; }
else
  jobs="$(auto_jobs)"
fi

[ -n "$root" ] || root="$(cd "$here/.." && pwd)"
[ -d "$root" ] || { echo "run-tests: bad root '$root'" >&2; exit 64; }
if run_suite "$root" "$jobs"; then echo "run-tests: all green ($root, jobs=$jobs)"; exit 0; fi
echo "run-tests: one or more suites failed" >&2; exit 1
