#!/usr/bin/env bash
# verify-batch.sh — the harness-enforced batch gate.
#
# The reviewer roles (integration-verifier, code-reviewer, architecture-reviewer,
# regression-guardian) are prose the orchestrator can skip (~70% adherence). This
# script enforces the OUTCOMES those roles exist to guarantee, regardless of which
# roles actually ran — so a /deliver batch cannot pass by skipping review:
#   - quality-gate    : typecheck + lint (from AGENTS.md)
#   - check-orphans   : dead code / created-but-not-wired
#   - check-architecture : drift from the baseline
#   - check-gate-integrity : no green-by-skip / disabled gate
#
# Run it at batch completion AND in CI (the independent backstop that catches a
# batch whose local run skipped the roles). See references/enforcement.md.
#
# Usage: bin/verify-batch.sh [project-dir]   # default: current dir
# Exit:  0 all gates pass · 1 a gate failed · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-.}"
cd "$root" 2>/dev/null || { echo "verify-batch: bad dir '$root'" >&2; exit 64; }

fails=0
gate() {
  local name="$1"; shift
  echo "verify-batch: → $name" >&2
  if "$@"; then
    echo "verify-batch:   OK — $name" >&2
  else
    echo "verify-batch:   FAILED — $name" >&2
    fails=$((fails + 1))
  fi
}

gate "quality-gate (typecheck + lint)"      "$here/quality-gate.sh" .
gate "orphans (dead code / not wired)"       "$here/check-orphans.sh"
gate "architecture (drift vs baseline)"      "$here/check-architecture.sh" .
gate "gate-integrity (no skip / disabled)"   "$here/check-gate-integrity.sh" .

if [ "$fails" -gt 0 ]; then
  echo "verify-batch: $fails gate(s) failed — batch cannot pass. Fix and re-run." >&2
  exit 1
fi
echo "verify-batch: all gates passed."
exit 0
