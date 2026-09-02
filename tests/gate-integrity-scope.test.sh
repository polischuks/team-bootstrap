#!/usr/bin/env bash
# tests/gate-integrity-scope.test.sh — issue #123: check-gate-integrity's continue-on-error clause must
# be scoped to the batch's DIFF, like the green-by-skip clause already is (#71).
#
# A PRE-EXISTING `continue-on-error: true` in a workflow the batch never touched (the target repo's
# e2e.yml) must NOT block the batch — it is reported as informational (standing state the batch did not
# introduce). A `continue-on-error` in a file the batch's diff DID touch still fails closed.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-gate-integrity.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# _base_repo DIR: a git repo whose BASE commit already carries a workflow with continue-on-error (the
# pre-existing, out-of-diff signature), plus an armed intends_code marker anchored at that base commit.
_base_repo() {
  local d="$1" base
  mkdir -p "$d/.github/workflows" "$d/.runs/r"
  printf 'name: e2e\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ./e2e.sh\n        continue-on-error: true\n' > "$d/.github/workflows/e2e.yml"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$( cd "$d" && git rev-parse --short HEAD )"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' \
    "$base" > "$d/.runs/r/RUN"
}
_gi() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" . ) >/dev/null 2>&1; echo $?; }
_gi_err() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" . ) 2>&1 >/dev/null; }

# --- (1) batch touches an UNRELATED file; e2e.yml continue-on-error is pre-existing/out-of-diff --------
D1="$T/d1"; _base_repo "$D1"
( cd "$D1" && echo change > src.txt && git add src.txt && git commit -qm 'batch: unrelated change' ) >/dev/null 2>&1
_chk "#123 pre-existing out-of-diff continue-on-error does NOT block a batch that never touched it" "$(_gi "$D1")" 0
case "$(_gi_err "$D1")" in
  *INFO*|*pre-existing*|*not\ introduced*) echo "  PASS #123 the out-of-diff signature is reported as informational" ;;
  *) echo "  FAIL #123 the out-of-diff signature is not surfaced as informational" >&2; fail=$((fail + 1)) ;;
esac

# --- (2) batch INTRODUCES a continue-on-error in a workflow file it changed → still fails closed --------
D2="$T/d2"; _base_repo "$D2"
( cd "$D2" && printf 'name: ci\njobs:\n  t:\n    steps:\n      - run: ./x.sh\n        continue-on-error: true\n' > .github/workflows/ci.yml \
  && git add .github/workflows/ci.yml && git commit -qm 'batch: add ci workflow with continue-on-error' ) >/dev/null 2>&1
_chk "#123 a continue-on-error in a file THIS batch's diff touched still fails closed" "$(_gi "$D2")" 1

# --- (3) --audit still sees the whole tree (out-of-diff signature blocks under audit) -------------------
_gi_audit() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" --audit . ) >/dev/null 2>&1; echo $?; }
_chk "#123 --audit still blocks on the pre-existing continue-on-error (whole-tree audit unchanged)" "$(_gi_audit "$D1")" 1

[ "$fail" -eq 0 ] && { echo "gate-integrity-scope.test.sh: OK"; exit 0; }
echo "gate-integrity-scope.test.sh: $fail failure(s)" >&2; exit 1
