#!/usr/bin/env bash
# quality-gate.sh — fast, harness-enforced quality gate for team-bootstrap projects.
#
# Runs the FAST checks (Typecheck, Lint) declared in AGENTS.md / CLAUDE.md and fails
# (exit 2) if any is red, so a Stop hook can block completion until green. Anthropic's
# data shows hooks enforce rules at ~100% vs ~70% for prose instructions, so the
# always-on lint/typecheck gate belongs here, not in a role playbook.
#
# Full unit / E2E suites are intentionally NOT run here — those stay with the
# pipeline's `integration-verifier` and CI (they are too slow for every Stop).
#
# No-ops (exit 0) when there is no AGENTS.md/CLAUDE.md (a non-team-bootstrap session)
# or when a command is N/A. Disable with: TEAM_BOOTSTRAP_QUALITY_GATE=off
#
# Wire it via hooks/hooks.json (Stop hook). See references/hooks.md.

set -uo pipefail

[ "${TEAM_BOOTSTRAP_QUALITY_GATE:-on}" = "off" ] && exit 0

doc=""
for f in AGENTS.md CLAUDE.md; do
  [ -f "$f" ] && { doc="$f"; break; }
done
[ -n "$doc" ] || exit 0   # not a team-bootstrap project → no-op

# first backticked command on a "Label:" line
extract() {
  grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$doc" 2>/dev/null \
    | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`'
}

fails=0
for label in Typecheck Lint; do
  cmd="$(extract "$label")"
  [ -n "$cmd" ] || continue
  case "$cmd" in N/A | n/a | None | none) continue ;; esac
  echo "quality-gate: $label -> $cmd" >&2
  if ! eval "$cmd" >/dev/null 2>&1; then
    echo "quality-gate: FAIL — $label (\`$cmd\`) is red. Fix before completing." >&2
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "quality-gate: $fails check(s) failing — completion blocked (evidence over assertion)." >&2
  exit 2
fi
exit 0
