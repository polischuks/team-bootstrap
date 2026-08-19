#!/usr/bin/env bash
# .github/control-surface-ci.sh — EXAMPLE CI-from-trusted-ref check (milestone control-surface-protection,
# Batch B). SHIPPED AS AN EXAMPLE — recommended repo/org posture, NOT a plugin guarantee.
#
# What it does: on a PR, compare the changed files vs the TRUSTED base (default origin/main) to the
# plugin control surface (references/control-surface.txt, via delivery-lib.sh control_surface_globs) and
# FAIL unless a commit in the PR declares a sanctioned machinery change with a `Control-Surface-Ack:`
# trailer. This gives a NON-circular signal that the in-plugin check-seam-ack (which runs the committed
# HEAD) cannot: the base is a trusted ref the PR cannot edit.
#
# HONEST LIMITS (this is why it is an example, not a guarantee):
#   - Non-circular ONLY under GitHub BRANCH-PROTECTION. A same-repo PR runs its OWN copy of the workflow,
#     so without "require this check" (+ review of workflow edits) a PR can simply disable/rename it.
#     Branch-protection is repo/org config the plugin cannot ship.
#   - The `Control-Surface-Ack:` trailer is AUTHOR-WRITTEN → its value is VISIBILITY + HUMAN REVIEW,
#     NOT prevention. It makes a machinery change a declared, reviewable event; it does not stop a
#     determined author. Uniform with @anthropic-ai/sandbox-runtime protected-path immutability (also
#     org posture the plugin cannot force).
#   - AC-Co — the co-committed circular-core edit is a DISCLOSED KNOWN GAP: a PR that in one diff edits a
#     gate AND drops the check-seam-ack invocation from verify-batch.sh escapes the IN-PLUGIN gate (it
#     runs the edited HEAD). This CI check under branch-protection is the repo/org backstop for that —
#     itself conditional on branch-protection + human review, not an in-plugin guarantee.
#
# Usage: .github/control-surface-ci.sh [base-ref]   (default: origin/main)
# Exit:  0 no surface change, or a declared+trailered change · 1 undeclared surface change · 64 bad usage
set -uo pipefail

base="${1:-origin/main}"
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/bin/delivery-lib.sh"

# _hits FILE → rc 0 if FILE matches any control-surface token (equals / under-dir / glob, * spans /).
# Mirrors the authoritative matcher bin/check-seam-ack.sh:_intersects; iterated line-by-line so glob
# tokens are never pathname-expanded against the CWD before matching.
_hits() {
  local f="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$f" = "$p" ] && return 0
    case "$f" in
      "$p"/*) return 0 ;;
      $p)     return 0 ;;
    esac
  done <<EOF
$(control_surface_globs)
EOF
  return 1
}

changed="$(git diff --name-only "$base"...HEAD 2>/dev/null)"
touched=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  _hits "$f" && touched="${touched:+$touched }$f"
done <<EOF
$changed
EOF

if [ -z "$touched" ]; then
  echo "control-surface-ci: no control-surface files changed vs $base — OK."
  exit 0
fi

if git log --format='%B' "$base"...HEAD 2>/dev/null | grep -qiE '^[[:space:]]*Control-Surface-Ack:'; then
  echo "control-surface-ci: control surface touched [$touched] AND a 'Control-Surface-Ack:' declaration is present — OK (visibility; independent human review still required — this trailer is not prevention)."
  exit 0
fi

echo "control-surface-ci: FAIL — this PR changes control-surface files [$touched] vs $base with NO 'Control-Surface-Ack:' declaration." >&2
echo "  Add a 'Control-Surface-Ack: <why>' trailer to the machinery commit AND get independent human review." >&2
echo "  (Non-circular only under branch-protection; the trailer is author-written → visibility, not prevention.)" >&2
exit 1
