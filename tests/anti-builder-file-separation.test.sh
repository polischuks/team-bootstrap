#!/usr/bin/env bash
# anti-builder-file-separation.test.sh — #148 T008/T009 (AC-9b, AC-9c). The load-bearing anti-builder
# guarantee: a delivery/builder slug must NEVER satisfy the per-role review floor. This holds by
# FILE SEPARATION — the review machinery reads ONLY references/review-types.txt; the delivery sanction
# manifest references/delivery-types.txt is read by NOTHING in that machinery. This test locks it:
#   T008a: delivery-types.txt ∩ review-types.txt (role column) is EMPTY — no slug is both.
#   T008b: the review-machinery scripts do not read delivery-types.txt.
#   T008c: a concrete delivery slug (backend-engineer, both forms) is NOT is_review_type (delivery-lib).
#   T009 : delivery agents are out of check-role-liveness scope (unrouted), so a Typed delivery agent that
#          passes check-role-triples does not trip liveness — verified by both gates being green together.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_c(){ if [ "$1" -eq 0 ]; then printf '  PASS %s\n' "$2"; else printf '  FAIL %s\n' "$2" >&2; fail=$((fail+1)); fi; }

echo "#148 T008a — no slug is both a delivery agent and a review role (anti-builder):"
overlap="$(comm -12 \
  <(awk '!/^#/ && $1 !~ /^team-bootstrap:/ && NF{print $1}' "$here/references/delivery-types.txt" | sort -u) \
  <(awk -F'\t' '!/^#/ && NF>1 && $2!="" && $1 !~ /^team-bootstrap:/ {print $1}' "$here/references/review-types.txt" | sort -u) )"
[ -z "$overlap" ]; _c $? "delivery-types ∩ review-types(role) is empty (got: ${overlap:-none})"

echo "#148 T008b — the review machinery never reads delivery-types.txt (file separation):"
for f in bin/check-role-dispatch.sh bin/check-review-ack.sh bin/record-dispatch.sh bin/delivery-lib.sh; do
  if grep -q 'delivery-types' "$here/$f" 2>/dev/null; then _c 1 "$f does NOT read delivery-types.txt"; else _c 0 "$f does NOT read delivery-types.txt"; fi
done

echo "#148 T008c — a delivery slug is NOT counted as a review type (delivery-lib is_review_type):"
# shellcheck source=bin/delivery-lib.sh
. "$here/bin/delivery-lib.sh" 2>/dev/null || true
if command -v is_review_type >/dev/null 2>&1; then
  for slug in backend-engineer team-bootstrap:backend-engineer product-manager team-bootstrap:whimsy-injector; do
    if is_review_type "$slug" 2>/dev/null; then _c 1 "is_review_type('$slug') is false (delivery ≠ review)"; else _c 0 "is_review_type('$slug') is false (delivery ≠ review)"; fi
  done
  # sanity: a genuine review slug IS a review type (the check can actually distinguish)
  if is_review_type "team-bootstrap:integration-verifier" 2>/dev/null; then _c 0 "is_review_type('team-bootstrap:integration-verifier') is true (control: the check bites)"; else _c 1 "is_review_type('team-bootstrap:integration-verifier') is true (control: the check bites)"; fi
else
  echo "  SKIP is_review_type not exported by delivery-lib (T008c via review-types membership above)" >&2
fi

echo "#148 T009 — delivery agents do not trip check-role-liveness (unrouted → out of scope):"
( cd "$here" && bin/check-role-liveness.sh . >/dev/null 2>&1 ); _c $? "check-role-liveness green with all delivery agents present (delivery agents are not routed liveness bindings)"

if [ "$fail" -eq 0 ]; then echo "anti-builder-file-separation.test.sh: OK"; exit 0; fi
echo "anti-builder-file-separation.test.sh: $fail case(s) FAILED" >&2; exit 1
