#!/usr/bin/env bash
# check-orphans.sh — heuristic dead-code / unwired-artifact scan for a batch diff.
#
# Advisory input to the `integration-verifier` role: flags producers (exported
# symbols, registered routes) ADDED in a diff that have no consumer elsewhere in
# the repo — the classic "backend built the endpoint, frontend never calls it".
# Heuristic and best-effort (JS/TS + Python patterns); every hit must be confirmed
# by opening the file. It does NOT replace the end-to-end check.
#
# Usage:
#   bin/check-orphans.sh [git-range]     # default: HEAD~1..HEAD
#
# Exit codes:
#   0  — no candidate orphans (heuristic)
#   2  — candidate orphan(s) found (advisory — confirm before blocking)
#   64 — not a git repo / bad usage

set -uo pipefail

RANGE="${1:-HEAD~1..HEAD}"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "check-orphans: not a git repository" >&2; exit 64; }

diff="$(git diff "$RANGE" --unified=0 2>/dev/null || true)"
if [ -z "$diff" ]; then
  echo "check-orphans: empty diff for '$RANGE' — nothing to scan."
  exit 0
fi

added="$(printf '%s\n' "$diff" | grep -E '^\+' || true)"

symbols="$(printf '%s\n' "$added" \
  | grep -oE 'export (default )?(async )?function [A-Za-z_][A-Za-z0-9_]*|export const [A-Za-z_][A-Za-z0-9_]*|export class [A-Za-z_][A-Za-z0-9_]*|def [A-Za-z_][A-Za-z0-9_]*|class [A-Za-z_][A-Za-z0-9_]*' 2>/dev/null \
  | sed -E 's/.* ([A-Za-z_][A-Za-z0-9_]*)$/\1/' | sort -u || true)"

routes="$(printf '%s\n' "$added" \
  | grep -oE "(get|post|put|patch|delete)\((['\"])/[^'\"]*" 2>/dev/null \
  | grep -oE "/[^'\"]*" | sort -u || true)"

# total occurrences of a needle across the repo, excluding vendored dirs
refcount() {
  grep -rnF --include='*.*' --exclude-dir=node_modules --exclude-dir=.git \
    --exclude-dir=dist --exclude-dir=build "$1" . 2>/dev/null | grep -c . || true
}

cands=0
for name in $symbols; do
  [ -n "$name" ] || continue
  if [ "$(refcount "$name")" -le 1 ]; then
    echo "  orphan? symbol '$name' — defined but no other reference found"
    cands=$((cands + 1))
  fi
done
for route in $routes; do
  [ -n "$route" ] || continue
  if [ "$(refcount "$route")" -le 1 ]; then
    echo "  orphan? route '$route' — registered but no caller references the path"
    cands=$((cands + 1))
  fi
done

if [ "$cands" -gt 0 ]; then
  echo "check-orphans: $cands candidate orphan(s) — CONFIRM by opening the files (heuristic)." >&2
  exit 2
fi
echo "check-orphans: no candidate orphans in $RANGE (heuristic)."
exit 0
