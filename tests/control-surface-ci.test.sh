#!/usr/bin/env bash
# tests/control-surface-ci.test.sh — local reproduction of the CI-from-trusted-ref EXAMPLE
# (.github/control-surface-ci.sh) — milestone control-surface-protection, Batch B. AC-CI, AC-Co.
#
# The example CI check fails a PR whose diff vs the trusted base touches the plugin control surface
# UNLESS a commit carries a `Control-Surface-Ack:` trailer (author-written declaration). This test
# reproduces that locally against fixture repos whose files match references/control-surface.txt globs.
#
# AC-Co is a DOC assertion (not an executable negative test): the co-committed circular-core edit is a
# disclosed KNOWN GAP — verified here by asserting the script's own header discloses it honestly.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
ci="$here/.github/control-surface-ci.sh"
fail=0
[ -x "$ci" ] || { echo "FAIL: $ci missing/not executable" >&2; exit 1; }

_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

# mk_repo TMP → git repo with a baseline commit; echo the baseline sha.
mk_repo() {
  local t="$1"
  ( cd "$t" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed && git add . && git commit -qm base ) >/dev/null 2>&1
  ( cd "$t" && git rev-parse HEAD )
}
# _run TMP BASE → run the CI example in TMP against BASE; echo exit code.
_run() { ( cd "$1" && "$ci" "$2" >/dev/null 2>&1 ); echo $?; }

# --- AC-CI — control-surface file changed vs base, NO Control-Surface-Ack: trailer → FAIL.
T="$(mktemp -d)"; base="$(mk_repo "$T")"
( cd "$T" && mkdir -p bin && echo x > bin/check-newgate.sh && git add -A && git commit -qm "edit a gate" ) >/dev/null 2>&1
_chk "AC-CI surface change, no declaration → FAIL" "$(_run "$T" "$base")" 1
rm -rf "$T"

# --- AC-CI — same change WITH a Control-Surface-Ack: trailer → PASS (visibility; human review still required).
T="$(mktemp -d)"; base="$(mk_repo "$T")"
( cd "$T" && mkdir -p bin && echo x > bin/check-newgate.sh && git add -A \
  && git commit -qm "edit a gate

Control-Surface-Ack: hardening the seam gate (declared machinery change)" ) >/dev/null 2>&1
_chk "AC-CI surface change + Control-Surface-Ack: trailer → PASS" "$(_run "$T" "$base")" 0
rm -rf "$T"

# --- AC-CI — a non-surface change (src/app.py) vs base → PASS (nothing to guard).
T="$(mktemp -d)"; base="$(mk_repo "$T")"
( cd "$T" && mkdir -p src && echo x > src/app.py && git add -A && git commit -qm "app change" ) >/dev/null 2>&1
_chk "AC-CI non-surface change → PASS" "$(_run "$T" "$base")" 0
rm -rf "$T"

# --- AC-Co — the disclosed KNOWN GAP is documented honestly in the script header (doc assertion).
if grep -qiE 'Control-Surface-Ack' "$ci" \
   && grep -qiE 'branch.protection' "$ci" \
   && grep -qiE 'visibility.*not prevention|not prevention' "$ci" \
   && grep -qiE 'co-committed|circular core|AC-Co' "$ci"; then
  echo "  PASS AC-Co disclosed-gap + non-circular-only-under-branch-protection documented in the example"
else
  echo "  FAIL AC-Co honesty disclosure missing from $ci header" >&2; fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] && { echo "control-surface-ci.test.sh: OK"; exit 0; }
echo "control-surface-ci.test.sh: $fail failure(s)" >&2; exit 1
