#!/usr/bin/env bash
# operator-tier-reconcile.test.sh — issue #47.
#
# When the operator declares the tier by hand (tier_source=operator), the fields that DEPEND on the
# tier — review_depth, sizing_degraded, risk_categories, assigned_roles, and the harness_context
# sentence — must be brought into agreement with the declared tier, never left describing the
# superseded harness/auto computation. A field that describes a superseded computation is worse than
# an absent one, because a reader trusts it (issue #47, "Expected").
#
# Two defects are pinned here, both reproduced against the SHIPPED hook before the fix:
#   CASE A — a re-arm over an operator marker with stale dependents (and no re-sizeable spec) falls
#            straight through and leaves every dependent field frozen at the first-arm harness verdict.
#   CASE B — the degraded re-size, which has no tier_source guard, RECOMPUTES the tier and OVERRULES
#            the operator's chosen pipeline. "the harness must not overrule a human" (issue #47).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }
# _field KEY FILE — read a flat scalar out of the single-line marker JSON.
_field() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[2]))
except Exception: print('<unreadable>'); sys.exit()
v=d.get(sys.argv[1],'<absent>')
print(json.dumps(v) if isinstance(v,(dict,list)) else ('true' if v is True else 'false' if v is False else v))
" "$1" "$2" 2>/dev/null || echo '<err>'; }

echo "CASE A — an operator marker with stale dependents is reconciled on re-arm (no re-sizeable spec):"
# The first arm was a description-form harness run: no tasks.md, so it degraded to pipeline=auto and
# recorded no risk_categories / assigned_roles, review_depth=low. The operator then chose `full` by
# editing the marker. On the SHIPPED hook the re-arm re-states the frozen context and exits — the
# dependent fields keep describing the superseded auto sizing.
A="$(mktemp -d)"
( cd "$A" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  mkdir -p .runs/op
  cat > .runs/op/RUN <<'JSON'
{"run":"op","pipeline":"full","source":"harness","feature":"specs/op/spec.md","intends_code":true,"baseline_sha":"abc1234","spec_present":false,"tier_source":"operator","review_depth":"low","sizing_degraded":"no-tasks-md","risk_categories":"","assigned_roles":"","harness_context":"team-bootstrap harness sizing for run op: pipeline=auto, tier_source=harness","precond":{"exit":0,"items":[],"ack":false}}
JSON
  printf 'op\n' > .runs/current
  printf '%s' '/team-bootstrap:deliver specs/op' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1
  m=".runs/op/RUN"
  _chk "$(_field pipeline    "$m")" "full"     "A: the operator's tier is PRESERVED, never recomputed"
  _chk "$(_field tier_source "$m")" "operator"  "A: tier_source stays operator"
  _chk "$(_field review_depth "$m")" "high"     "A: review_depth is reconciled to the declared tier (full→high)"
  _chk "$(_field sizing_degraded "$m")" ""       "A: the superseded 'no-tasks-md' degradation is cleared"
  # The full tier's DEPTH BASE roles are a function of the declared tier alone — knowable with no spec.
  _chk "$(_field assigned_roles "$m" | grep -c 'code-reviewer' || true)" "1" \
    "A: assigned_roles carries the declared tier's review floor (no longer empty)"
  ctx="$(_field harness_context "$m")"
  _chk "$(printf '%s' "$ctx" | grep -qF 'pipeline=auto' && echo stale || echo fresh)" "fresh" \
    "A: harness_context no longer advertises the superseded pipeline=auto verdict"
  _chk "$(printf '%s' "$ctx" | grep -qF 'tier_source=operator' && echo yes || echo no)" "yes" \
    "A: harness_context states the operator declaration" )
rm -rf "$A"

echo
echo "CASE A2 — idempotent: a second re-arm over the reconciled marker does not churn or re-announce:"
A2="$(mktemp -d)"
( cd "$A2" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  mkdir -p .runs/op
  cat > .runs/op/RUN <<'JSON'
{"run":"op","pipeline":"full","source":"harness","feature":"specs/op/spec.md","intends_code":true,"baseline_sha":"abc1234","spec_present":false,"tier_source":"operator","review_depth":"low","sizing_degraded":"no-tasks-md","risk_categories":"","assigned_roles":"","harness_context":"team-bootstrap harness sizing for run op: pipeline=auto, tier_source=harness","precond":{"exit":0,"items":[],"ack":false}}
JSON
  printf 'op\n' > .runs/current
  printf '%s' '/team-bootstrap:deliver specs/op' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1
  depth1="$(_field review_depth .runs/op/RUN)"; roles1="$(_field assigned_roles .runs/op/RUN)"
  out2="$(printf '%s' '/team-bootstrap:deliver specs/op' | "$here/bin/delivery-marker-init.sh" 2>/dev/null)"
  _chk "$(_field review_depth .runs/op/RUN)" "$depth1" "A2: a settled reconcile is stable across arms (depth)"
  _chk "$(_field assigned_roles .runs/op/RUN)" "$roles1" "A2: …and stable (roles)"
  _chk "$(printf '%s' "$out2" | grep -qiF 'reconciled' && echo announced || echo quiet)" "quiet" \
    "A2: an already-reconciled run does not keep announcing the reconcile" )
rm -rf "$A2"

echo
echo "CASE B — the degraded re-size must NOT overrule an operator-declared tier:"
# First arm degrades (no tasks.md). The operator forces `full`. Phase A then lands a tasks.md that
# would size to single-thread. On the SHIPPED hook the re-size fires and OVERWRITES full→single-thread,
# overruling the human. The re-size must be guarded to tier_source=harness.
B="$(mktemp -d)"
( cd "$B" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  mkdir -p specs/op
  printf '# Spec\n\nA tiny tweak.\n' > specs/op/spec.md
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  printf '%s' '/team-bootstrap:deliver specs/op' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1
  python3 - .runs/op/RUN <<'PY'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); m['pipeline']='full'; m['tier_source']='operator'; json.dump(m,open(p,'w'))
PY
  # a small, single-directory tasks.md — sizes to single-thread
  printf '# Tasks\n\n## WS-A\n\n- [ ] T1 do it\n  - file: src/util/x.ts \xc2\xb7 (feat \xc2\xb7 P10) \xe2\x80\x94 AC-1\n' > specs/op/tasks.md
  printf '%s' '/team-bootstrap:deliver specs/op' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1
  _chk "$(_field pipeline    .runs/op/RUN)" "full"     "B: operator's full is NOT overruled by the re-size"
  _chk "$(_field tier_source .runs/op/RUN)" "operator"  "B: tier_source stays operator" )
rm -rf "$B"

echo
echo "CASE C — harness runs are unaffected: a degraded harness run still re-sizes when artefacts arrive:"
# The guard must not break the ADR-0025 re-size for the harness path it was built for.
C="$(mktemp -d)"
( cd "$C" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  mkdir -p specs/hz
  printf '# Spec\n\nAn auth change.\n' > specs/hz/spec.md
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  printf '%s' '/team-bootstrap:deliver specs/hz' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1
  _chk "$(_field pipeline .runs/hz/RUN)" "auto" "C: harness first arm with no tasks.md ⇒ auto"
  printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > specs/hz/tasks.md
  printf '%s' '/team-bootstrap:deliver specs/hz' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1
  _chk "$(_field pipeline .runs/hz/RUN)" "full" "C: a harness run STILL re-sizes once tasks.md exists"
  _chk "$(_field tier_source .runs/hz/RUN)" "harness" "C: …and stays harness-sourced" )
rm -rf "$C"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "operator-tier-reconcile.test.sh: OK"; exit 0; }
echo "operator-tier-reconcile.test.sh: $fail failure(s)"; exit 1
