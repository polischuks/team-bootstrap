#!/usr/bin/env bash
# description-form-resolve.test.sh — issue #92: a description-form run must resolve pipeline auto→sized.
#
# THE BUG. A description-form delivery run (invoked with NO spec.md on disk — Phase A authors the spec)
# arms with pipeline=auto, spec_present=false, and — because it never entered the fresh-arm sizing block —
# NO sizing_degraded and NO spec_path. Phase A then produces a fully sizable spec.md+tasks.md, but the
# marker never picks it up: the existing-marker branch calls resize_degraded_marker, which returns 1
# because it is gated on `sizing_degraded` non-empty AND `spec_path` set — fields this run never had. So
# the run stays pipeline=auto for its whole life, over-enforcing every run-level tier gate (observed live
# on content_agentstvo/101-untrusted-fetch-injection-guardrail).
#
# THE FIX. resize_degraded_marker must ALSO fire for "pipeline=auto and the feature's spec is now on
# disk" (resolving the spec path from the marker's `feature` field when spec_path was never recorded),
# resize via size-from-spec, and record spec_path. One-directional + operator-safe: never overrule an
# operator-declared tier; a run with no resolvable spec stays auto (fail-closed).
#
# BELT-AND-SUSPENDERS. check-role-dispatch must treat pipeline=auto as `full` (certify against the
# strictest known set) rather than hard-failing on the literal string, so an unresolved-but-fully-
# reviewed batch is not blocked at close.
#
# Written BEFORE the fix -> red (marker stays auto; check-role-dispatch hard-fails on auto), then green.
set -uo pipefail
unset TEAM_BOOTSTRAP_RUN
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
PY() { python3 -c "$1" "${@:2}"; }
_field() { PY "import json;print(json.load(open('$1')).get('$2',''))"; }

# ---------------------------------------------------------------------------
# Part 1 — a description-form run (NO spec at init) resolves auto→sized when Phase A lands the spec.
# ---------------------------------------------------------------------------
E="$(mktemp -d)"; mkdir -p "$E/specs"
( cd "$E" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1

# FIRST ARM — the spec directory does NOT exist yet (description form). The prompt names the path Phase A
# will author; on disk there is nothing, so spec_present=false and NO sizing_degraded/spec_path is set.
( cd "$E" || exit 1; printf '%s' '/team-bootstrap:deliver specs/dsc' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(_field "$E/.runs/dsc/RUN" pipeline)"        auto  "description-form first arm => pipeline=auto"
_chk "$(_field "$E/.runs/dsc/RUN" spec_present)"    False "  …spec_present=false (nothing on disk)"
_chk "$(_field "$E/.runs/dsc/RUN" sizing_degraded)" ""    "  …and NO sizing_degraded (the missing trigger)"
_chk "$(_field "$E/.runs/dsc/RUN" spec_path)"       ""    "  …and NO spec_path (the missing trigger)"
_chk "$(_field "$E/.runs/dsc/RUN" feature)"         specs/dsc/spec.md "  …feature carries the path Phase A will fill"

# PHASE A lands a fully sizable spec.md + tasks.md — no new prompt.
mkdir -p "$E/specs/dsc"
printf '# Spec\n\nAn auth change touching src/auth/login.ts and src/api/routes.ts.\n' > "$E/specs/dsc/spec.md"
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n- [ ] T2 b `src/api/y.ts`\n' > "$E/specs/dsc/tasks.md"

# MID-TURN resolution (prompt-less, PostToolBatch) — the run must resolve auto→sized here.
( cd "$E" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" >/dev/null 2>&1 )
_chk "$([ "$(_field "$E/.runs/dsc/RUN" pipeline)" != auto ] && echo resolved || echo auto)" resolved \
  "the description-form run RESOLVES from auto (issue #92 primary fix)"
_chk "$(_field "$E/.runs/dsc/RUN" spec_path)" specs/dsc/spec.md \
  "  …and records spec_path from the feature field"
rm -rf "$E"

# ---------------------------------------------------------------------------
# Part 2 — the same resolution also fires on the UserPromptSubmit path (delivery-marker-init re-arm).
# ---------------------------------------------------------------------------
P="$(mktemp -d)"; mkdir -p "$P/specs"
( cd "$P" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
( cd "$P" || exit 1; printf '%s' '/team-bootstrap:deliver specs/pf' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(_field "$P/.runs/pf/RUN" pipeline)" auto "prompt-path: first arm => auto"
mkdir -p "$P/specs/pf"
printf '# Spec\n\nAn auth change touching src/auth/login.ts and src/api/routes.ts.\n' > "$P/specs/pf/spec.md"
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n- [ ] T2 b `src/api/y.ts`\n' > "$P/specs/pf/tasks.md"
# A SECOND arm (same command, new prompt) takes the existing-marker branch.
( cd "$P" || exit 1; printf '%s' '/team-bootstrap:deliver specs/pf' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$([ "$(_field "$P/.runs/pf/RUN" pipeline)" != auto ] && echo resolved || echo auto)" resolved \
  "prompt-path: re-arm resolves auto→sized (delivery-marker-init)"
_chk "$(_field "$P/.runs/pf/RUN" spec_path)" specs/pf/spec.md "  …and records spec_path"
rm -rf "$P"

# ---------------------------------------------------------------------------
# Part 3 — operator-safe: an operator-declared tier is NEVER overruled by the auto re-derivation.
# ---------------------------------------------------------------------------
OP="$(mktemp -d)"; mkdir -p "$OP/specs/op"
printf '# Spec\n\nAn auth change touching src/auth/login.ts.\n' > "$OP/specs/op/spec.md"
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > "$OP/specs/op/tasks.md"
( cd "$OP" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
mkdir -p "$OP/.runs/op"; printf 'op\n' > "$OP/.runs/current"
# An operator marker carrying pipeline=auto (hypothetical hand value) + feature on disk: the guard keys on
# tier_source=operator and must refuse to touch the tier, even though the spec would size.
PY "import json;json.dump({'run':'op','intends_code':True,'pipeline':'auto','tier_source':'operator','feature':'specs/op/spec.md'}, open('$OP/.runs/op/RUN','w'))"
( cd "$OP" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" >/dev/null 2>&1 )
_chk "$(_field "$OP/.runs/op/RUN" pipeline)" auto "operator tier is NEVER overruled by the auto re-derivation"
rm -rf "$OP"

# ---------------------------------------------------------------------------
# Part 4 — a run with genuinely NO resolvable spec stays auto (fail-closed) — unchanged.
# ---------------------------------------------------------------------------
N="$(mktemp -d)"; mkdir -p "$N/specs"
( cd "$N" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
( cd "$N" || exit 1; printf '%s' '/team-bootstrap:deliver specs/none' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
# Phase A never produces a spec — the path stays missing on disk.
( cd "$N" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" >/dev/null 2>&1 )
_chk "$(_field "$N/.runs/none/RUN" pipeline)" auto "no resolvable spec => stays auto (fail-closed, unchanged)"
rm -rf "$N"

# ---------------------------------------------------------------------------
# Part 5 — belt-and-suspenders: check-role-dispatch treats pipeline=auto as `full` (strictest known set),
# not a hard-fail on the literal string.
# ---------------------------------------------------------------------------
D="$(mktemp -d)"; mkdir -p "$D/.runs/r"
( cd "$D" || exit 1; git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
dbase="$(cd "$D" && git rev-parse --short HEAD)"
_dmk() { printf '%s\n' "$1" > "$D/.runs/r/RUN"; }
_dbatch() { printf '%s\n' "$1" > "$D/.runs/r/batches.jsonl"; }
_ddisp() { printf '%s\n' "$1" > "$D/.runs/r/dispatch.jsonl"; }
# warn mode isolates the ≥1 anti-collapse floor from the per-role floor (this file tests the auto→full
# treatment, not role completeness — that has its own coverage).
_dgate() { ( cd "$D" || exit 1; TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_ROLE_FLOOR=warn "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }
_dbatch '{"id":"B1","kind":"code","status":"announced"}'

# auto + code batch + a reviewer-typed dispatch for THIS batch → must PASS (certified as full, not hard-failed).
_dmk '{"run":"r","pipeline":"auto","intends_code":true,"source":"harness","baseline_sha":"'"$dbase"'"}'
_ddisp '{"batch":"B1","subagent_type":"code-reviewer"}'
_chk "$(_dgate)" 0 "check-role-dispatch: auto + ≥1 reviewer dispatch => PASS (auto treated as full, #92 safety net)"

# auto + code batch + ZERO dispatch → still FAIL (the real collapse floor still bites; auto is not a bypass).
rm -f "$D/.runs/r/dispatch.jsonl"
_chk "$(_dgate)" 1 "check-role-dispatch: auto + zero dispatch => still FAIL (≥1 floor intact under auto)"

# a genuinely malformed/unknown pipeline still fails closed (auto's treatment must not weaken that).
_dmk '{"run":"r","pipeline":"audit","intends_code":true,"source":"harness","baseline_sha":"'"$dbase"'"}'
_ddisp '{"batch":"B1","subagent_type":"code-reviewer"}'
_chk "$(_dgate)" 1 "check-role-dispatch: unknown pipeline (audit) still fails closed (auto is a KNOWN placeholder)"
rm -rf "$D"

if [ "$fail" -eq 0 ]; then echo "description-form-resolve.test.sh: OK"; exit 0; fi
echo "description-form-resolve.test.sh: $fail case(s) FAILED" >&2; exit 1
