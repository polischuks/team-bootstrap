#!/usr/bin/env bash
# check-gate-integrity.sh — meta-check that gates actually run (fail-closed).
#
# A gate is only worth its non-disableability. This flags two ways a gate stops
# gating while still reading green:
#   1. green-by-skip — a gate/invariant/constitutional/contract test that passes
#      only because it is skipped (@pytest.mark.skip, .skip(, t.Skip, @Disabled…);
#   2. a gate that can't fail — `continue-on-error: true` on a CI gate job.
# See references/regression-and-invariants.md (section 3).
#
# Usage: bin/check-gate-integrity.sh [project-dir]   # default: current dir
# Exit:  0 clean / not machine-checkable · 1 integrity violation · 64 bad usage
set -uo pipefail

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-gate-integrity: bad dir '$root'" >&2; exit 64; }

KEY='invariant|constitution|constitutional|gate|contract|security|guard'
SKIP='@pytest\.mark\.skip|@unittest\.skip|pytest\.skip\(|\.skip\(|xit\(|xdescribe\(|it\.skip|describe\.skip|test\.skip|t\.Skip\(|@Disabled|@Ignore'

viol=0

# 1) green-by-skip on a gate/invariant/constitutional/contract test -------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s' "$f" | grep -qiE "$KEY" || grep -qiE "$KEY" "$f" 2>/dev/null; then
    sk="$(grep -nEi "$SKIP" "$f" 2>/dev/null | head -5)"
    [ -n "$sk" ] || continue
    echo "check-gate-integrity: GREEN-BY-SKIP in gate/invariant test '$f':" >&2
    printf '%s\n' "$sk" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
done < <(grep -rlE "$SKIP" . --include='*test*' --include='*spec*' --include='*_test.go' 2>/dev/null | head -100)

# 2) a gate that can't fail: continue-on-error on a CI job -----------------------
if [ -d .github/workflows ]; then
  ce="$(grep -rnE 'continue-on-error:[[:space:]]*true' .github/workflows 2>/dev/null | head -20)"
  if [ -n "$ce" ]; then
    echo "check-gate-integrity: gate cannot fail (continue-on-error) in CI:" >&2
    printf '%s\n' "$ce" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
fi

if [ "$viol" -gt 0 ]; then
  echo "check-gate-integrity: $viol integrity issue(s) — a gate that doesn't run is a failure, not a pass." >&2
  exit 1
fi
echo "check-gate-integrity: OK — no green-by-skip or can't-fail gate detected."
exit 0
