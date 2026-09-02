#!/usr/bin/env bash
# label-failures.sh — issue #119. At close/merge, label each FAILING check as new-this-run vs
# pre-existing, so a standing-red / flaky check is not confused with a regression the run introduced.
#
# The problem: a merge sees a mix — a flaky guard (green on rerun), lint debt in files the run never
# touched, an ESM-import false positive — and the plugin gives no signal to separate "my change broke
# this" from "this was already red / is flaky". The operator has to know the repo's standing-red set from
# memory; the apparent failure surface of every run is inflated, and a real regression can be dismissed as
# "probably the usual noise" or a non-regression chased for hours.
#
# The fix, minimal and offline: read a DECLARED allowlist of known-red / known-flaky checks
# (`KnownRed:` in AGENTS.md/CLAUDE.md) and classify each failing check name against it. A failure that
# matches the allowlist is `pre-existing` (standing-red/flaky — act only if it is newly worse); one that
# does not is `new-this-run` — the regression the run actually introduced. Even this simple diff removes
# the memory dependency the retro named. (Running the whole suite on the base branch to derive the set
# empirically is the heavier alternative the issue mentions; the declared allowlist is the cheap 80%.)
#
# Usage:
#   label-failures.sh [--dir DIR] <failing-check> [<failing-check> ...]
#   printf '%s\n' fail1 fail2 | label-failures.sh [--dir DIR]      # names on stdin, one per line
#   label-failures.sh --self-test
#
# KnownRed: line (AGENTS.md/CLAUDE.md), backtick-tolerant, comma/space separated. Each entry is matched
# as a shell glob against the failing check name, so `KnownRed: lint, adr-042-*, mcp-esm-imports` treats
# any `adr-042-…` check as known-red.
#
# Output: one line per failure — `pre-existing  <name>` or `new-this-run  <name>`.
# Exit:  0 no new-this-run failures (only pre-existing/flaky, or nothing to classify)
#        1 >=1 new-this-run failure (a real regression the operator must act on) — fail-closed
#        64 usage error
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prog="$(basename "$0")"

# read_known_red DIR → space-separated KnownRed globs declared in DIR's AGENTS.md/CLAUDE.md (empty if none).
read_known_red() {
  local dir="$1" f doc="" rest
  for f in "$dir/AGENTS.md" "$dir/CLAUDE.md"; do [ -f "$f" ] && { doc="$f"; break; }; done
  [ -n "$doc" ] || return 0
  rest="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*KnownRed:" "$doc" 2>/dev/null | head -1 | sed -E 's/^[^:]*://')"
  [ -n "$rest" ] || return 0
  printf '%s' "$rest" | tr -d '`' | tr ',' ' ' | xargs 2>/dev/null || true
}

# _is_known_red NAME GLOBS → rc 0 if NAME matches any glob in the (space-separated) allowlist.
_is_known_red() {
  local name="$1" globs="$2" g
  for g in $globs; do
    # shellcheck disable=SC2254
    case "$name" in $g) return 0 ;; esac
  done
  return 1
}

# _label DIR NAMES... → print the labelled lines, return 1 if any is new-this-run.
_label() {
  local dir="$1"; shift
  local globs new=0 name
  globs="$(read_known_red "$dir")"
  for name in "$@"; do
    [ -n "$name" ] || continue
    if _is_known_red "$name" "$globs"; then
      printf 'pre-existing  %s\n' "$name"
    else
      printf 'new-this-run  %s\n' "$name"; new=1
    fi
  done
  [ "$new" -eq 0 ]
}

_self_test() {
  local fail=0 T out rc
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }
  T="$(mktemp -d)"
  printf '# a\n\n- KnownRed: `lint`, `adr-042-*`, `mcp-esm-imports`\n' > "$T/AGENTS.md"
  # all known-red → exit 0
  out="$("$0" --dir "$T" lint adr-042-dfy-guard mcp-esm-imports 2>&1)"; rc=$?
  _c "$rc" "0" "all known-red → exit 0"
  _c "$(printf '%s\n' "$out" | grep -c 'pre-existing')" "3" "three pre-existing"
  _c "$(printf '%s\n' "$out" | grep -c 'new-this-run')" "0" "none new"
  # glob entry matches a family
  out="$("$0" --dir "$T" adr-042-anything 2>&1)"; rc=$?
  _c "$rc" "0" "glob KnownRed entry matches the family"
  # an off-allowlist failure → new + exit 1
  out="$("$0" --dir "$T" lint backend-typecheck 2>&1)"; rc=$?
  _c "$rc" "1" "off-allowlist failure → exit 1"
  _c "$(printf '%s\n' "$out" | grep -c 'new-this-run.*backend-typecheck')" "1" "the new failure is named"
  # names on stdin
  out="$(printf '%s\n' lint newthing | "$0" --dir "$T" 2>&1)"; rc=$?
  _c "$rc" "1" "stdin names classified, new → exit 1"
  _c "$(printf '%s\n' "$out" | grep -c 'pre-existing.*lint')" "1" "stdin known-red stays pre-existing"
  # no failures at all → exit 0 (nothing to act on)
  "$0" --dir "$T" >/dev/null 2>&1; _c "$?" "0" "no failures → exit 0"
  # no KnownRed declared → every failure is new (conservative: nothing is known-red)
  T2="$(mktemp -d)"; out="$("$0" --dir "$T2" whatever 2>&1)"; rc=$?
  _c "$rc" "1" "no KnownRed declared → failure is new-this-run"
  rm -rf "$T" "$T2"
  [ "$fail" -eq 0 ] && { echo "$prog --self-test: OK"; return 0; }
  echo "$prog --self-test: $fail failure(s)" >&2; return 1
}

dir="."
case "${1:-}" in
  --self-test) _self_test; exit $? ;;
  -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:-}"; [ -n "$dir" ] || { echo "$prog: --dir needs a value" >&2; exit 64; }; shift 2 ;;
    --) shift; break ;;
    -*) echo "$prog: unknown option '$1'" >&2; exit 64 ;;
    *) break ;;
  esac
done

# Collect failing check names from args, else stdin (one per line).
names=()
if [ "$#" -gt 0 ]; then
  names=("$@")
elif [ ! -t 0 ]; then
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"
    [ -n "$line" ] && names+=("$line")
  done
fi

_label "$dir" ${names[@]+"${names[@]}"}
exit $?
