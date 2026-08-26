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
# Usage: bin/run-tests.sh [root]   ·   bin/run-tests.sh --self-test
# Exit:  0 all green · 1 one or more suites failed · 64 bad usage
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# run_suite ROOT → 0 if every bin/*.sh --self-test and tests/*.test.sh under ROOT passes, else 1.
# Skips the runner itself and its own test to avoid re-entry.
run_suite() {
  local root="$1" fails=0 f base
  for f in "$root"/bin/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "run-tests.sh" ] && continue
    # A script HANDLES --self-test only if it dispatches on the flag. Matching the bare string anywhere
    # made any mention — a comment, or a call to ANOTHER script's self-test — look like a self-test mode,
    # and the runner then invoked a flag the script does not accept and reported it as a failing suite.
    if grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$f" 2>/dev/null; then
      if ! bash "$f" --self-test >/dev/null 2>&1; then
        echo "run-tests: FAIL self-test — $base" >&2; fails=$((fails + 1))
      fi
    fi
  done
  for f in "$root"/tests/*.test.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "run-tests.test.sh" ] && continue
    if ! bash "$f" >/dev/null 2>&1; then
      echo "run-tests: FAIL test — $base" >&2; fails=$((fails + 1))
    fi
  done
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
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "run-tests --self-test: OK"; exit 0; fi
  echo "run-tests --self-test: $fail case(s) FAILED" >&2; exit 1
fi

case "${1:-}" in
  -h|--help) echo "usage: run-tests.sh [root] | --self-test"; exit 0 ;;
esac
root="${1:-"$(cd "$here/.." && pwd)"}"
[ -d "$root" ] || { echo "run-tests: bad root '$root'" >&2; exit 64; }
if run_suite "$root"; then echo "run-tests: all green ($root)"; exit 0; fi
echo "run-tests: one or more suites failed" >&2; exit 1
