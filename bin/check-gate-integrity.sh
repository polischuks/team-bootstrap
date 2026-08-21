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
# NOT flagged (a conditional skip still RUNS under the right condition, and an
# explicitly-justified deferral is a decision, not a silent hole):
#   - conditional skips: @pytest.mark.skipif / lines containing `skipif`;
#   - sanctioned skips: any skip line carrying an inline `gate-integrity:
#     sanctioned` marker (add `# gate-integrity: sanctioned — <reason>` on the
#     skip line to record WHY the deferral does not hide a gate).
#
# Usage: bin/check-gate-integrity.sh [project-dir]   # default: current dir
# Exit:  0 clean / not machine-checkable · 1 integrity violation · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-gate-integrity: bad dir '$root'" >&2; exit 64; }

KEY='invariant|constitution|constitutional|gate|contract|security|guard'
SKIP='@pytest\.mark\.skip|@unittest\.skip|pytest\.skip\(|\.skip\(|\bxit\(|\bxdescribe\(|it\.skip|describe\.skip|test\.skip|t\.Skip\(|@Disabled|@Ignore'
# Exclusions applied to matched skip lines: a conditional skipif RUNS under its
# condition, and a line explicitly sanctioned is a recorded deferral, not a hole.
EXCLUDE='skipif|gate-integrity:[[:space:]]*sanctioned'

viol=0

# 1) green-by-skip on a gate/invariant/constitutional/contract test -------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s' "$f" | grep -qiE "$KEY" || grep -qiE "$KEY" "$f" 2>/dev/null; then
    # Candidate skip lines, minus conditional (skipif) and same-line-sanctioned ones.
    # A sanction marker is also honoured on the line IMMEDIATELY ABOVE the skip, so a
    # long skip line need not carry an over-length trailing comment.
    sk=""
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      prev="$(sed -n "$((ln - 1))p" "$f" 2>/dev/null)"
      printf '%s' "$prev" | grep -qiE 'gate-integrity:[[:space:]]*sanctioned' && continue
      sk="${sk}${ln}:${text}
"
    done < <(grep -nEi "$SKIP" "$f" 2>/dev/null | grep -vEi "$EXCLUDE" | head -20)
    sk="$(printf '%s' "$sk" | grep -vE '^$' | head -5)"
    [ -n "$sk" ] || continue
    echo "check-gate-integrity: GREEN-BY-SKIP in gate/invariant test '$f':" >&2
    printf '%s\n' "$sk" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
done < <(grep -rlE "$SKIP" . --include='*test*' --include='*spec*' --include='*_test.go' \
  --exclude='*.pyc' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.claude \
  --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=venv \
  --exclude-dir=dist --exclude-dir=build --exclude-dir=.next \
  --exclude-dir=.mypy_cache --exclude-dir=.ruff_cache --exclude-dir=.pytest_cache \
  2>/dev/null | head -100)

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
  # WS-8 (harness-robustness): a GOVERNED run-level waiver clears pre-existing findings the batch did not
  # introduce (the retro's dashboard skips + e2e continue-on-error OUTSIDE the batch delta, which forced a
  # hand-stamp every batch). It does NOT silence them — the findings are already printed above. Governed =
  # ack + by + reason + expires; expiry forces re-review, so a disabled gate cannot pass forever. In CI
  # there is no run marker, so the waiver is impossible there and a genuinely disabled gate is never hidden.
  # (Full per-finding delta-scoping is deferred — arch-review flagged its risk of silently dropping a
  # finding outside the delta; a surfaced-and-expiring waiver is the sound, simpler mechanism.)
  marker="$(resolve_marker)"
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    mk="$(cat "$marker" 2>/dev/null || true)"
    if governed_waiver_ok \
         "$(field_in_obj "$mk" gate_integrity_waiver ack)" \
         "$(field_in_obj "$mk" gate_integrity_waiver by)" \
         "$(field_in_obj "$mk" gate_integrity_waiver reason)" \
         "$(field_in_obj "$mk" gate_integrity_waiver expires)"; then
      echo "check-gate-integrity: WAIVED by a governed gate_integrity_waiver (findings surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0." >&2
      exit 0
    fi
  fi
  exit 1
fi
echo "check-gate-integrity: OK — no green-by-skip or can't-fail gate detected."
exit 0
