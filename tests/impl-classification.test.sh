#!/usr/bin/env bash
# impl-classification.test.sh — #148. agents/<role>.md is the EXECUTABLE PRODUCT (a dispatchable role
# definition the harness loads as team-bootstrap:<role>), so delivery-lib's _is_doc_path must classify it
# as IMPL, not doc — otherwise a migration wave (whose whole output is agents/*.md) closes with
# code_delta=0 + empty commit_shas, earning no delivery credit, never advancing the batch window, and
# tripping the red-ordering check. Regression guard: real docs (references/, docs/, top-level *.md) stay doc.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/bin/delivery-lib.sh" 2>/dev/null || { echo "impl-classification: cannot source delivery-lib" >&2; exit 1; }
fail=0
_doc(){ if _is_doc_path "$1"; then printf '  PASS %s is doc\n' "$1"; else printf '  FAIL %s should be doc\n' "$1" >&2; fail=$((fail+1)); fi; }
_impl(){ if _is_doc_path "$1"; then printf '  FAIL %s should be impl (non-doc)\n' "$1" >&2; fail=$((fail+1)); else printf '  PASS %s is impl (non-doc)\n' "$1"; fi; }

echo "#148 — agents/<role>.md is the executable product (impl), not doc:"
_impl "agents/backend-engineer.md"
_impl "agents/architecture-reviewer.md"
_impl "agents/tb-code-reviewer.md"

echo "#148 — real docs stay doc (regression guard — the exemption is agents/ only):"
_doc "references/roles/backend-engineer.md"
_doc "references/enforcement.md"
_doc "docs/adr/0001-x.md"
_doc "README.md"

echo "#148 — real code stays impl:"
_impl "bin/check-role-triples.sh"

if [ "$fail" -eq 0 ]; then echo "impl-classification.test.sh: OK"; exit 0; fi
echo "impl-classification.test.sh: $fail case(s) FAILED" >&2; exit 1
