#!/usr/bin/env bash
# spec-resolution-and-retarget.test.sh — issues #105, #114, #118, #124.
#
# #105 — delivery-marker-init classifies spec_present purely from the working tree (`[ -f "$feat" ]`).
#        A spec that exists on a git branch (not checked out) is misread as a bare description (Mode 1).
#        The fix consults git when the tree file is absent and NAMES the git-not-tree case instead of
#        silently choosing Mode 1.
# #114 — feature.json's active_spec is not reconciled to the marker's feature, so the speckit skills
#        (which read feature.json) drive the WRONG milestone. The fix auto-retargets feature.json.
# #118 — deliver.md Mode 2 must be PER-ARTIFACT (spec present but plan/tasks absent → produce just those).
# #124 — deliver.md must name the speckit-runner (.specify/scripts/bash) templates-only case.
#
# Written BEFORE the fix -> red, then green.
set -uo pipefail
unset TEAM_BOOTSTRAP_RUN
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
_has() { if printf '%s' "$1" | grep -qiE "$2"; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (missing /%s/)\n' "$3" "$2" >&2; fail=$((fail + 1)); fi; }
_hasnot() { if printf '%s' "$1" | grep -qiE "$2"; then printf '  FAIL %s (unexpected /%s/)\n' "$3" "$2" >&2; fail=$((fail + 1))
  else printf '  PASS %s\n' "$3"; fi; }
PY() { python3 -c "$1" "${@:2}"; }
_field() { PY "import json;print(json.load(open('$1')).get('$2',''))"; }

# ---------------------------------------------------------------------------
# #105 Part A — a spec that exists on a git branch but NOT in the working tree is flagged git-not-tree,
#              not silently classified as a bare description.
# ---------------------------------------------------------------------------
G="$(mktemp -d)"
( cd "$G" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  # author the spec on a side branch, then return to main so the working tree lacks it
  git checkout -q -b feat
  mkdir -p specs/gitonly; printf '# Spec\n\nauth change.\n' > specs/gitonly/spec.md
  git add -A; git commit -q -m spec
  git checkout -q - ) >/dev/null 2>&1
# the spec.md is NOT in the working tree now:
[ -f "$G/specs/gitonly/spec.md" ] && { echo "  SETUP BAD: spec still in tree" >&2; fail=$((fail+1)); }
( cd "$G" || exit 1; printf '%s' '/team-bootstrap:deliver specs/gitonly' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
g_ctx="$(_field "$G/.runs/gitonly/RUN" harness_context)"
_chk "$(_field "$G/.runs/gitonly/RUN" spec_present)" False "#105 tree file absent => spec_present stays false (on-disk truth)"
_chk "$([ -n "$(_field "$G/.runs/gitonly/RUN" spec_in_git)" ] && echo yes || echo no)" yes \
  "#105 the git-not-tree ref is recorded (spec_in_git field set)"
_has "$g_ctx" "working tree" "#105 the operator is TOLD the spec is in git, not the working tree"
rm -rf "$G"

# ---------------------------------------------------------------------------
# #105 Part B — a genuine description (no spec on disk AND not in git) still classifies Mode 1, silently.
# ---------------------------------------------------------------------------
D="$(mktemp -d)"
( cd "$D" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
( cd "$D" || exit 1; printf '%s' '/team-bootstrap:deliver specs/nowhere' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(_field "$D/.runs/nowhere/RUN" spec_present)" False "#105 genuine description => spec_present false"
_chk "$(_field "$D/.runs/nowhere/RUN" spec_in_git)" "" "#105 genuine description => NO spec_in_git (no spec anywhere)"
_hasnot "$(_field "$D/.runs/nowhere/RUN" harness_context)" "working tree" "#105 genuine description not told about git-not-tree"
rm -rf "$D"

# ---------------------------------------------------------------------------
# #114 — feature.json.active_spec is auto-retargeted to the marker's feature when they disagree.
# ---------------------------------------------------------------------------
F="$(mktemp -d)"
( cd "$F" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
printf '{\n  "active_spec": "specs/179-previous",\n  "specs_dir": "specs",\n  "constitution": "constitution.md"\n}\n' > "$F/feature.json"
mkdir -p "$F/specs/180-current"; printf '# spec\n' > "$F/specs/180-current/spec.md"
( cd "$F" || exit 1; printf '%s' '/team-bootstrap:deliver specs/180-current' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(_field "$F/feature.json" active_spec)" specs/180-current "#114 feature.json retargeted to the marker feature"
# feature.json stays valid JSON after the in-place edit
_chk "$(PY 'import json,sys;json.load(open(sys.argv[1]));print("ok")' "$F/feature.json")" ok "#114 feature.json stays valid JSON"
_has "$(_field "$F/.runs/180-current/RUN" harness_context)" "feature.json" "#114 the retarget is stated in context (names the mismatch)"
rm -rf "$F"

# #114 Part B — when feature.json already agrees, it is left byte-for-byte alone (no needless churn/notice).
F2="$(mktemp -d)"
( cd "$F2" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
printf '{\n  "active_spec": "specs/agree",\n  "specs_dir": "specs"\n}\n' > "$F2/feature.json"
before="$(cat "$F2/feature.json")"
mkdir -p "$F2/specs/agree"; printf '# spec\n' > "$F2/specs/agree/spec.md"
( cd "$F2" || exit 1; printf '%s' '/team-bootstrap:deliver specs/agree' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(cat "$F2/feature.json")" "$before" "#114 agreeing feature.json is left untouched"
_hasnot "$(_field "$F2/.runs/agree/RUN" harness_context)" "retarget" "#114 no retarget notice when already agreeing"
rm -rf "$F2"

# ---------------------------------------------------------------------------
# #118 — deliver.md Mode 2 is per-artifact: present->CHECK, absent->PRODUCE just it, and names the
#        present-spec / absent-plan-tasks case.
# ---------------------------------------------------------------------------
dm="$here/commands/deliver.md"
_has "$(cat "$dm")" "per-artifact" "#118 deliver.md names Mode 2 as per-artifact"
_has "$(cat "$dm")" "plan.md.*tasks.md.*absent|absent.*plan|present spec.*absent" "#118 deliver.md names the present-spec/absent-plan-tasks case"

# ---------------------------------------------------------------------------
# #124 — deliver.md names the speckit-runner (.specify/scripts/bash) templates-only case + how to proceed.
# ---------------------------------------------------------------------------
_has "$(cat "$dm")" "\.specify/scripts/bash" "#124 deliver.md names the speckit runner path"
_has "$(cat "$dm")" "templates-only|produce nothing|manual" "#124 deliver.md states the manual/templates-only fallback"

if [ "$fail" -eq 0 ]; then echo "spec-resolution-and-retarget.test.sh: OK"; exit 0; fi
echo "spec-resolution-and-retarget.test.sh: $fail case(s) FAILED" >&2; exit 1
