#!/usr/bin/env bash
# check-tdd.sh — harness gate for P9's red→green: tests written first, run and SEEN to fail,
# then implemented to green. A git-grounded fact, not a self-declared `tests_failed_first` boolean.
#
# For an ACTIVE delivery run (marker intends_code:true) that shipped code, require:
#   1. a RED RECORD — .runs/<run>/tdd.jsonl, written by tdd-red.sh, which can only exist because
#      the suite actually ran red — whose red_sha resolves, is a DESCENDANT of the run baseline and
#      a PROPER ANCESTOR of HEAD (red observed on this run's work, before the implementation);
#   2. the suite is GREEN at HEAD now (re-run the AGENTS.md `Test:` command).
# An armed run that shipped code with NO valid red record is fail-closed — the red step was skipped
# (prose "tests_failed_first: true" is not accepted; only the git-anchored record is).
#
# Graceful skips (exit 0): not an active delivery run (no marker), no code shipped yet, or no
# runnable `Test:` command (red→green not machine-verifiable — warns). In-session only: CI has no
# marker (.runs/ is gitignored), same reach as check-delivery.
#
# Usage: bin/check-tdd.sh [project-dir]  ·  bin/check-tdd.sh --self-test
# Exit:  0 pass / skip · 1 red step missing, mis-ordered, or HEAD not green · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

_test_cmd() { # echo the AGENTS.md/CLAUDE.md `Test:` command (empty if none/N/A)
  local doc="" f c
  for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done
  [ -n "$doc" ] || return 0
  c="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*Test:" "$doc" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  case "$c" in N/A|n/a|None|none) c="" ;; esac
  printf '%s' "$c"
}

# evaluate a project dir; echo nothing, return exit code (0 pass/skip, 1 fail)
_evaluate() {
  local marker mk intends baseline ledger closed_code=0 csb=0 delivered=0 tcmd
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-tdd: no active delivery run — skipping (TDD governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  intends="$(field_bool "$mk" intends_code)"
  [ "$intends" = "true" ] || { echo "check-tdd: marker not intends_code — skipping."; return 0; }
  baseline="$(field_str "$mk" baseline_sha)"

  # did this run ship code? (a closed kind:code batch OR real code since baseline)
  ledger="$(resolve_ledger)"
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    local line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ "$(field_str "$line" kind)" = "code" ] || continue
      [ "$(field_str "$line" status)" = "closed" ] && closed_code=$((closed_code + 1))
    done < "$ledger"
  fi
  code_since_baseline "${baseline:-}" && csb=1
  { [ "$closed_code" -gt 0 ] || [ "$csb" -eq 1 ]; } && delivered=1
  [ "$delivered" -eq 1 ] || { echo "check-tdd: no code delivered yet — nothing to require a red step for."; return 0; }

  tcmd="$(_test_cmd)"
  [ -n "$tcmd" ] || { echo "check-tdd: WARN — no runnable Test: command in AGENTS.md; red→green cannot be machine-verified (P9 unenforced for this project)." >&2; return 0; }

  # require a valid red record
  local run tdd
  run="$(printf '%s' "$marker" | sed -E 's#^.*\.runs/([^/]+)/RUN$#\1#')"
  tdd=".runs/$run/tdd.jsonl"
  if [ ! -f "$tdd" ] || ! grep -q '"observed":"red"' "$tdd" 2>/dev/null; then
    echo "  FAIL-CLOSED: code shipped but NO observed red step (.runs/$run/tdd.jsonl) — P9 requires tests written first and SEEN to fail. Run bin/tdd-red.sh before implementing." >&2
    return 1
  fi
  local hd; hd="$(git rev-parse HEAD 2>/dev/null || true)"
  local bfull; bfull="$(resolve_sha "${baseline:-}")"
  local valid=0 line rs rfull
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rs="$(field_str "$line" red_sha)"; [ -n "$rs" ] || continue
    rfull="$(resolve_sha "$rs")" || rfull=""
    [ -n "$rfull" ] || continue                                       # red_sha must resolve
    [ "$rfull" != "$hd" ] || continue                                 # red must precede the code (proper ancestor)
    git merge-base --is-ancestor "$rfull" "$hd" 2>/dev/null || continue
    if [ -n "$bfull" ]; then
      git merge-base --is-ancestor "$bfull" "$rfull" 2>/dev/null || continue   # red on this run's work (post-baseline)
    fi
    valid=1; break
  done < "$tdd"
  if [ "$valid" -eq 0 ]; then
    echo "  FAIL-CLOSED: red record(s) exist but none is a post-baseline, pre-HEAD commit — the red step was not observed before the code (P9)." >&2
    return 1
  fi

  # green now
  if ! eval "$tcmd" >/dev/null 2>&1; then
    echo "  FAIL: suite is RED at HEAD (\`$tcmd\`) — red→green not reached; implement to green before closing (P9)." >&2
    return 1
  fi
  echo "check-tdd: red→green verified — a test was observed to fail before the code, and the suite is green at HEAD."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  T="$(mktemp -d)"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `test -f .green`\n' > AGENTS.md
    git add AGENTS.md && git commit -qm baseline ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  mkdir -p "$T/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  ( cd "$T" && echo t > testfile && git add testfile && git commit -qm "failing test (red)" ) >/dev/null 2>&1
  red="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && : > .green && git add .green && git commit -qm "impl to green" ) >/dev/null 2>&1
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { local got; got="$(_run)"; if [ "$got" = "$2" ]; then echo "  PASS (exit $got) $1"; else echo "  FAIL (exit $got, want $2) $1" >&2; fail=$((fail + 1)); fi; }

  _chk "code shipped, NO red record → fail-closed" 1
  printf '{"batch":"B1","red_sha":"%s","test_cmd":"test -f .green","observed":"red"}\n' "$red" > "$T/.runs/r/tdd.jsonl"
  _chk "valid red record (post-baseline, pre-HEAD) + green HEAD → pass" 0
  # red_sha == HEAD (no impl after red) → invalid
  hd="$(cd "$T" && git rev-parse --short HEAD)"
  printf '{"batch":"B1","red_sha":"%s","test_cmd":"test -f .green","observed":"red"}\n' "$hd" > "$T/.runs/r/tdd.jsonl"
  _chk "red_sha == HEAD (no code after red) → fail" 1
  # restore valid record, then break green at HEAD
  printf '{"batch":"B1","red_sha":"%s","test_cmd":"test -f .green","observed":"red"}\n' "$red" > "$T/.runs/r/tdd.jsonl"
  ( cd "$T" && rm -f .green && git commit -qam "regress: remove green" ) >/dev/null 2>&1
  _chk "valid red record but HEAD is RED → fail" 1
  ( cd "$T" && : > .green && git add .green && git commit -qm "re-green" ) >/dev/null 2>&1
  # marker-less → skip
  ( cd "$T" && rm -f .runs/r/RUN )
  _chk "no active marker → skip (exit 0)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-tdd --self-test: OK"; exit 0; fi
  echo "check-tdd --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-tdd: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
