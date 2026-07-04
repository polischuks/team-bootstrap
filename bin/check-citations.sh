#!/usr/bin/env bash
# check-citations.sh — evidence-discipline gate for the l2p pipeline.
#
# Scans the downstream l2p-artifacts for assertion lines that neither cite a
# grounding id (C###/S###/F###/I###/P##/UC##/FND##) nor carry an allowed tag
# (HYPOTHESIS/ESTIMATE/INFERRED/PATH-BREAK/unverifiable). Heuristic, line-based:
# it inspects table rows and bullets, skipping headers and separators.
#
# Usage:
#   bin/check-citations.sh [l2p-artifacts-dir]   # default: ./l2p-artifacts
#
# Exit codes:
#   0 — no uncited assertions found (or no artifacts present)
#   1 — at least one uncited assertion
#   64 — bad usage

set -uo pipefail

DIR="${1:-./l2p-artifacts}"
if [ ! -d "$DIR" ]; then
  echo "check-citations: no artifacts dir at '$DIR' — nothing to check." >&2
  exit 0
fi

ID_RE='C[0-9]|S[0-9]|F[0-9]|I[0-9]|P[0-9]|UC[0-9]|FND[0-9]'
TAG_RE='HYPOTHESIS|ESTIMATE|INFERRED|PATH-BREAK|unverifiable'
HEADER_RE='(^| )(id|Promise|Journey|Fulfillment|Status|Note|Gate|Stage|persona|use-case|claims|surfaces|features|instrumentation|verbatim|source|type)( |$|\|)'

DOWNSTREAM="01-use-cases.md 02-map.md 03-funnel-audit.md 04-gates.md l2p-backlog.md"

violations=0
for f in $DOWNSTREAM; do
  path="$DIR/$f"
  [ -f "$path" ] || continue
  while IFS= read -r entry; do
    num="${entry%%:*}"
    text="${entry#*:}"
    # skip table separator rows
    case "$text" in
      *---*) continue ;;
    esac
    # skip header-ish rows
    if printf '%s' "$text" | grep -qE "$HEADER_RE"; then
      continue
    fi
    # pass if the line cites an id or carries an allowed tag
    if printf '%s' "$text" | grep -qE "$ID_RE|$TAG_RE"; then
      continue
    fi
    echo "  $f:$num: uncited assertion -> $(printf '%s' "$text" | sed 's/^ *//')"
    violations=$((violations + 1))
  done < <(grep -nE '^[[:space:]]*[|*-][[:space:]]' "$path")
done

if [ "$violations" -gt 0 ]; then
  echo "check-citations: $violations uncited assertion(s). Cite a grounding id (C###/S###/F###/I###/UC##/FND##) or tag HYPOTHESIS/ESTIMATE." >&2
  exit 1
fi

echo "check-citations: OK — every assertion cites a grounding id or is tagged."
exit 0
