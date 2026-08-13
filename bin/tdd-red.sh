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
# Usage: bin/tdd-red.sh [--batch <id>] [project-dir]
# Exit:  0 red recorded · 1 suite is GREEN (no valid red to record) · 3 no Test: command · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

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
