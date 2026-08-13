#!/usr/bin/env bash
# tdd-red.sh — record an OBSERVED red step, making P9 ("tests written first, run and SEEN to
# fail") a git-grounded fact instead of a self-declared boolean.
#
# Run this at the TDD red step: AFTER writing the failing test(s), BEFORE implementing. It runs
# the project's Test: command and REQUIRES it to fail (non-zero). You cannot record red when the
# suite is already green — nothing failed means no test-first. On red it appends a machine record
# to .runs/<run>/tdd.jsonl:  {"batch","red_sha":<HEAD>,"test_cmd","observed":"red"}.
#
# The record can ONLY be produced by tests actually running red — prose cannot fabricate it — and
# check-tdd.sh later verifies red_sha sits between the run baseline and HEAD (red before the code)
# and that HEAD is now green. Its ABSENCE is caught fail-closed by check-tdd at batch close.
#
# Test command: the backticked cmd on a `Test:` line in AGENTS.md / CLAUDE.md (same convention as
# quality-gate.sh's Typecheck/Lint).
#
# F1 (red-touches-tests): the observed red must be caused by a COMMITTED test-file change — an
# --allow-empty red or a non-test-only red is refused (exit 4), and a worktree-only (uncommitted)
# test is refused with guidance to commit it first, so tdd-red stays consistent with check-tdd's
# red_sha window. Test-path set = default globs ∪ AGENTS.md TestGlobs: (delivery-lib is_test_path).
#
# Usage: bin/tdd-red.sh [--batch <id>] [project-dir]  ·  bin/tdd-red.sh --self-test
# Exit:  0 red recorded · 1 suite is GREEN (no valid red) · 3 no Test: command · 4 red changed no
#        committed test file · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  git_t() { ( cd "$T" && "$@" ); }
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `test -f .green`\n' > AGENTS.md && git add . && git commit -qm baseline ) >/dev/null 2>&1
  mkdir -p "$T/.runs/r"
  _mkrun() { printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$1" > "$T/.runs/r/RUN"; }
  _mkrun "$(git_t git rev-parse --short HEAD)"
  _red() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/tdd-red.sh" --batch "$1" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

  # green suite → refuse (nothing failed)
  ( cd "$T" && : > .green && git add .green && git commit -qm green ) >/dev/null 2>&1
  _chk "green suite → refuse (exit 1)" "$(_red B1)" 1
  ( cd "$T" && git rm -q .green && git commit -qm "back to red" ) >/dev/null 2>&1
  _mkrun "$(git_t git rev-parse --short HEAD)"   # scope the window to what follows the baseline

  # empty (allow-empty) red, no committed test → refuse
  git_t git commit -q --allow-empty -m "empty red" >/dev/null 2>&1
  _chk "empty (--allow-empty) red → refuse (exit 4)" "$(_red B1)" 4
  # non-test-only committed red → refuse
  ( cd "$T" && echo x > src.sh && git add src.sh && git commit -qm "code only" ) >/dev/null 2>&1
  _chk "non-test-only red → refuse (exit 4)" "$(_red B1)" 4
  # worktree-only (uncommitted) test → refuse
  ( cd "$T" && echo t > w_test.sh ) >/dev/null 2>&1
  _chk "worktree-only (uncommitted) test → refuse (exit 4)" "$(_red B1)" 4
  ( cd "$T" && rm -f w_test.sh )
  # committed test red → record
  ( cd "$T" && echo t > a_test.sh && git add a_test.sh && git commit -qm "failing test" ) >/dev/null 2>&1
  _chk "committed test red → record (exit 0)" "$(_red B1)" 0
  if grep -q '"batch":"B1"' "$T/.runs/r/tdd.jsonl" 2>/dev/null; then echo "  PASS record written"; else echo "  FAIL no record written" >&2; fail=$((fail + 1)); fi
  # no Test: command → exit 3
  ( cd "$T" && printf '# AGENTS\n\n- Lint: `true`\n' > AGENTS.md && git add AGENTS.md && git commit -qm "no test cmd" ) >/dev/null 2>&1
  _chk "no Test: command → exit 3" "$(_red B1)" 3
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "tdd-red --self-test: OK"; exit 0; fi
  echo "tdd-red --self-test: $fail case(s) FAILED" >&2; exit 1
fi

batch=""; root="."
while [ $# -gt 0 ]; do
  case "$1" in
    --batch) batch="${2:-}"; shift 2 ;;
    -*) echo "tdd-red: unknown flag '$1'" >&2; exit 64 ;;
    *) root="$1"; shift ;;
  esac
done
cd "$root" 2>/dev/null || { echo "tdd-red: bad dir '$root'" >&2; exit 64; }

# test command from AGENTS.md/CLAUDE.md `Test:` line
doc=""; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done
tcmd=""
[ -n "$doc" ] && tcmd="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*Test:" "$doc" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
case "$tcmd" in ''|N/A|n/a|None|none) echo "tdd-red: no runnable Test: command in AGENTS.md — cannot observe red." >&2; exit 3 ;; esac

echo "tdd-red: running tests (expecting RED) -> $tcmd" >&2
if eval "$tcmd" >/dev/null 2>&1; then
  echo "tdd-red: tests PASS (green) — nothing failed. Write a failing test FIRST (P9 red step), then re-run." >&2
  exit 1
fi

# F1 — the red must be caused by a COMMITTED test-file change (git-anchored, per check-tdd's window).
guard_marker="$(resolve_marker)"; guard_baseline=""
[ -n "$guard_marker" ] && [ -f "$guard_marker" ] && guard_baseline="$(field_str "$(cat "$guard_marker" 2>/dev/null)" baseline_sha)"
guard_base="$(resolve_sha "${guard_baseline:-}")" || guard_base=""
[ -n "$guard_base" ] || guard_base="$(git rev-parse -q --verify 'HEAD^' 2>/dev/null || true)"
if ! window_touches_test "$guard_base" "HEAD" "$(read_test_globs)"; then
  echo "tdd-red: red changed no COMMITTED test file — commit your failing test FIRST so the red is git-anchored, then re-run. (Inline-test projects: widen TestGlobs: in AGENTS.md to your source globs.)" >&2
  exit 4
fi

# red observed — record it, keyed to the active run
run="${TEAM_BOOTSTRAP_RUN:-}"
[ -n "$run" ] || run="$(resolve_marker | sed -E 's#^\.runs/([^/]+)/RUN$#\1#')"
[ -n "$run" ] || run="deliver-run"
mkdir -p ".runs/$run" 2>/dev/null || { echo "tdd-red: cannot write .runs/$run" >&2; exit 1; }
sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$batch" ] || batch="?"
esc_cmd="$(printf '%s' "$tcmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"batch":"%s","red_sha":"%s","test_cmd":"%s","observed":"red"}\n' "$batch" "$sha" "$esc_cmd" >> ".runs/$run/tdd.jsonl"
echo "tdd-red: RED recorded (run=$run batch=$batch red_sha=$sha) — now implement to green." >&2
exit 0
