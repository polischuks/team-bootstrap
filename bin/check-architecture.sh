#!/usr/bin/env bash
# check-architecture.sh — architecture fitness functions for a target project.
#
# Delegates to the project's own arch-lint tool when a config is present
# (dependency-cruiser / Deptrac / go-arch-lint — ArchUnit runs via the Java test
# suite, not here). Otherwise falls back to declared forbidden-import rules in the
# baseline (ARCHITECTURE.md / AGENTS.md "## Architecture", lines of the form
# "- forbid: <path-prefix> imports <token>"). Advisory + gate signal for the
# architecture-reviewer role. See references/architecture-baseline.md.
#
# Usage: bin/check-architecture.sh [project-dir]   # default: current dir
# Exit:  0 clean / not machine-checkable · 1 violations found · 64 bad usage
set -uo pipefail

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-architecture: bad dir '$root'" >&2; exit 64; }

run() { echo "check-architecture: running $*" >&2; "$@"; }

# 1) delegate to a configured arch-lint tool -------------------------------------
if ls .dependency-cruiser.js .dependency-cruiser.cjs .dependency-cruiser.json >/dev/null 2>&1; then
  if command -v npx >/dev/null 2>&1; then run npx --no-install depcruise --validate .; exit $?; fi
  echo "check-architecture: dependency-cruiser config found — run 'depcruise --validate .'" >&2; exit 0
fi
if [ -f deptrac.yaml ] || [ -f deptrac.yml ]; then
  if command -v deptrac >/dev/null 2>&1; then run deptrac analyse; exit $?; fi
  if [ -x vendor/bin/deptrac ]; then run vendor/bin/deptrac analyse; exit $?; fi
  echo "check-architecture: deptrac config found — run 'deptrac analyse'" >&2; exit 0
fi
if [ -f .go-arch-lint.yml ]; then
  if command -v go-arch-lint >/dev/null 2>&1; then run go-arch-lint check; exit $?; fi
  echo "check-architecture: go-arch-lint config found — run 'go-arch-lint check'" >&2; exit 0
fi

# 2) fallback: declared forbidden-import rules from the baseline ------------------
doc=""
for f in ARCHITECTURE.md AGENTS.md CLAUDE.md; do
  [ -f "$f" ] && { doc="$f"; break; }
done
if [ -z "$doc" ]; then
  echo "check-architecture: no arch-lint config and no ARCHITECTURE.md/AGENTS.md — architecture not machine-checkable; establish a baseline." >&2
  exit 0
fi

viol=0
while IFS= read -r line; do
  rest="${line#*forbid:}"
  prefix="$(printf '%s' "$rest" | sed -n 's/^[[:space:]]*\([^[:space:]][^[:space:]]*\)[[:space:]][[:space:]]*imports[[:space:]][[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p')"
  token="$(printf '%s' "$rest" | sed -n 's/^[[:space:]]*\([^[:space:]][^[:space:]]*\)[[:space:]][[:space:]]*imports[[:space:]][[:space:]]*\([^[:space:]][^[:space:]]*\).*/\2/p')"
  [ -n "$prefix" ] && [ -n "$token" ] || continue
  [ -d "$prefix" ] || continue
  hits="$(grep -rnE "(import|require|use|from).*${token}" "$prefix" 2>/dev/null | head -20)"
  if [ -n "$hits" ]; then
    echo "check-architecture: FORBIDDEN — '$prefix' must not import '$token':" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
done < <(grep -iE '^[[:space:]]*[-*][[:space:]]*forbid:' "$doc" 2>/dev/null)

if [ "$viol" -gt 0 ]; then
  echo "check-architecture: $viol architecture rule violation(s) — drift from baseline." >&2
  exit 1
fi
echo "check-architecture: OK — no declared architecture rules violated."
exit 0
