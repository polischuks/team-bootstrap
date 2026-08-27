#!/usr/bin/env bash
# check-review-batch.sh — PostToolBatch: the moment after a parallel reviewer fan-out resolves.
#
# WHY THIS EVENT. The four review roles are dispatched in ONE parallel fan-out, and until now nothing
# looked at the result until `verify-batch` ran, possibly many turns later. PostToolBatch fires after a
# batch of parallel calls is resolved and before the model's next turn — the first moment the harness
# can compare what was dispatched against what the batch requires, while it is still cheap to fix.
#
# WHY IT REPORTS AND DOES NOT BLOCK, even though PostToolBatch can. Blocking here would refuse the
# model's turn because a dispatch is missing, and the cheapest way out of that refusal is to review
# inline — the spec-169 collapse this whole pipeline exists to prevent. The project already rejected a
# blocking pre-dispatch gate for exactly that reason and the same reasoning applies after the fact. The
# hard floor stays where it can be satisfied without that pressure: check-role-dispatch at closure.
#
# So this is influence delivered at the one moment it is actionable, and the gate is still the gate.
#
# Exit: always 0.
set -uo pipefail
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0   # gate-integrity: sanctioned — explicit operator kill switch, not a degraded evaluation
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
# gate-integrity: sanctioned — THE SEPARATING PRINCIPLE (spec 021 AC-8, plan §8.5, ADR-0023). Clause 4
# of check-gate-integrity flags "declares blindness, then passes", and this line is that shape on
# purpose. The difference from the `seen == 0` branch B4 just made fail-closed is not severity, it is
# WAIVABILITY: a gate that cannot load delivery-lib.sh cannot evaluate ANYTHING, including its own
# governed waiver — governed_waiver_ok lives in the file that failed to load. Blocking here would
# therefore be unconditional and un-waivable, a gate no operator can ever clear by any means, which is
# a worse failure than the one it prevents. `seen == 0`, by contrast, is an evaluable state with a
# working escape, so it refuses. Absent (exit 0) and stating so is the honest report of a gate that
# could not start; a gate that CAN start and cannot confirm must refuse.
. "$here/delivery-lib.sh" 2>/dev/null || { echo "$(basename "$0"): delivery-lib.sh is unreadable — this gate cannot evaluate and is NOT passing; it is absent (AC-48)." >&2; exit 0; }

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }
  T="$(mktemp -d)"
  _c "$( ( cd "$T" || exit 1; printf '{}' | "$here/check-review-batch.sh" ); echo -n )" "" "no armed run ⇒ silent"
  _c "$( ( cd "$T" || exit 1; printf '{}' | "$here/check-review-batch.sh" >/dev/null 2>&1 ); echo $? )" 0 "…and exit 0"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "check-review-batch --self-test: OK"; exit 0; }
  echo "check-review-batch --self-test: $fail FAILED" >&2; exit 1
fi

cat >/dev/null 2>&1 || true

marker="$(resolve_marker 2>/dev/null || true)"
[ -n "$marker" ] && [ -f "$marker" ] || exit 0   # gate-integrity: sanctioned — no armed run: out of scope, nothing to review
mk="$(cat "$marker" 2>/dev/null || true)"
[ "$(field_bool "$mk" intends_code)" = "true" ] || exit 0   # gate-integrity: sanctioned — a doc run has no review fan-out by design
[ "$(field_str "$mk" pipeline)" = "single-thread" ] && exit 0   # gate-integrity: sanctioned — P1: single-thread reviews inline by contract

bline="$(inflight_batch 2>/dev/null || true)"
bid="$(field_str "$bline" id)"
[ -n "$bid" ] || exit 0   # gate-integrity: sanctioned — no in-flight batch: this fan-out belongs to no batch
# inflight_batch FALLS BACK to the last ledger line when nothing is announced — so without this check,
# every session after a batch closed kept re-announcing that batch's role gap as "still missing … fails
# closed at closure": a duty closure already discharged, re-stated as pending (P6). A closed batch is a
# record, not an obligation; its floor was read once, at its own closure.
[ "$(field_str "$bline" status)" = "announced" ] || exit 0   # gate-integrity: sanctioned — no open batch: nothing left to owe
[ "$(field_str "$bline" kind)" = "code" ] || exit 0   # gate-integrity: sanctioned — a doc batch earns no review roles by design

req="$(required_roles_recorded "$bid" 2>/dev/null || true)"
[ -n "$req" ] || req="$(required_roles_for_batch "$bid" 2>/dev/null || true)"
[ -n "$req" ] || exit 0   # gate-integrity: sanctioned — an empty required set IS the answer for this batch, not a failure to compute one
covered="$(roles_covered "$bid" 2>/dev/null || true)"

missing=""
for r in $req; do
  case " $covered " in *" $r "*) : ;; *) missing="${missing:+$missing }$r" ;; esac
done
[ -n "$missing" ] || exit 0   # gate-integrity: sanctioned — every required role is covered; the pass is the result

emit_hook_context PostToolBatch "$(json_esc "team-bootstrap: batch $bid requires review roles [$req]; dispatches recorded so far [${covered:-none}]; still missing [$missing]. check-role-dispatch reads this set at closure and fails closed on a missing required role.")"
exit 0
