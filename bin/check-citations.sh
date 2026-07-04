#!/usr/bin/env bash
# check-citations.sh — evidence-discipline gate for the l2p pipeline.
#
# Scans the downstream l2p-artifacts for assertion lines (table data rows and
# bullets) that neither cite a grounding id (C###/S###/F###/I###/P##/UC##/FND##)
# nor carry an allowed tag (HYPOTHESIS/ESTIMATE/INFERRED/PATH-BREAK/unverifiable).
# A table header row (the line directly above a `|---|` separator) and separators
# are skipped, so header labels don't count as assertions. Single-pass with a
# one-line lookbehind buffer — portable to bash 3.2 (no mapfile).
#
# Usage:
#   bin/check-citations.sh [l2p-artifacts-dir]   # default: ./l2p-artifacts
#
# Exit codes:
#   0 — no uncited assertions (or no artifacts present)
#   1 — at least one uncited assertion

set -uo pipefail

DIR="${1:-./l2p-artifacts}"
if [ ! -d "$DIR" ]; then
  echo "check-citations: no artifacts dir at '$DIR' — nothing to check." >&2
  exit 0
fi

ID_RE='C[0-9]|S[0-9]|F[0-9]|I[0-9]|P[0-9]|UC[0-9]|FND[0-9]'
TAG_RE='HYPOTHESIS|ESTIMATE|INFERRED|PATH-BREAK|unverifiable'
DOWNSTREAM="01-use-cases.md 02-map.md 03-funnel-audit.md 04-gates.md l2p-backlog.md"

violations=0

# assess FILE NUM TEXT — echo + return 1 if TEXT is an uncited assertion.
assess() {
  text="$3"
  printf '%s' "$text" | grep -qE '^[[:space:]]*[|*-][[:space:]]' || return 0
  case "$text" in *---*) return 0 ;; esac
  printf '%s' "$text" | grep -qE "$ID_RE|$TAG_RE" && return 0
  echo "  $1:$2: uncited assertion -> $(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
  return 1
}

for f in $DOWNSTREAM; do
  path="$DIR/$f"
  [ -f "$path" ] || continue
  prev=""
  prev_num=0
  have_prev=0
  num=0
  while IFS= read -r line || [ -n "$line" ]; do
    num=$((num + 1))
    if [ "$have_prev" -eq 1 ]; then
      # prev is a table header iff the current line is a separator -> skip it
      case "$line" in
        *---*) : ;;
        *) assess "$f" "$prev_num" "$prev" || violations=$((violations + 1)) ;;
      esac
    fi
    prev="$line"
    prev_num="$num"
    have_prev=1
  done < "$path"
  # the final buffered line has no following line, so it can't be a header
  if [ "$have_prev" -eq 1 ]; then
    assess "$f" "$prev_num" "$prev" || violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "check-citations: $violations uncited assertion(s). Cite a grounding id (C###/S###/F###/I###/UC##/FND##) or tag HYPOTHESIS/ESTIMATE." >&2
  exit 1
fi

echo "check-citations: OK — every assertion cites a grounding id or is tagged."
exit 0
