#!/usr/bin/env bash
# code-baseline-writer.test.sh — #104 (the WRITER) + #127 (empty-sha delta guard).
#
# #104: delivery-marker-init stamps code_baseline_sha=HEAD at the A->B boundary (armed harness run,
# tasks.md COMMITTED at HEAD, no code batch announced, field unset) so current_batch_base uses it for the
# first batch and a Phase-A feature.json commit falls OUTSIDE the first batch's window. #127: the delta
# helpers must not crash on an empty sha list under set -u (bash 3.2).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }

echo "#127 — delta helpers survive an empty sha list (bash 3.2 set -u):"
# MUST run under `set -u`: the empty-array expansion `"${list[@]}"` only trips "unbound variable" on
# bash < 4.4 with nounset — the exact condition the live caller runs under (and where 3.10.0 crashed).
# Without `set -u` this case is vacuous (it passes with or without the fix), so enable it explicitly.
r="$(bash -uc '. "'"$here"'/bin/delivery-lib.sh"; printf "%s %s" "$(nondoc_delta_of_shas "")" "$(impl_delta_of_shas "")"' 2>&1)"
_chk "$r" "0 0" "nondoc_delta_of_shas \"\" and impl_delta_of_shas \"\" both return 0, no unbound-variable crash"

echo "#104 — the writer stamps code_baseline_sha at the A->B boundary:"
# NB: delivery-marker-init derives the run id from the /deliver path argument (specs/foo -> run "foo"),
# so the marker MUST live at .runs/foo/RUN — a mismatched run dir leaves the armed branch (the writer)
# unreached and the fresh-arm path re-arms a different marker instead.
T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
BASE="$(cd "$T" && git rev-parse --short HEAD)"
# Phase A commits spec/plan/tasks + feature.json (the docs commit that used to pollute the first batch).
( cd "$T" && mkdir -p specs/foo && printf '# spec\n' > specs/foo/spec.md && printf '# plan\n' > specs/foo/plan.md \
    && printf '# tasks\n' > specs/foo/tasks.md && printf '{"active_spec":"specs/foo"}\n' > feature.json
  git add . && git commit -qm 'docs(foo): Phase A spec/plan/tasks + feature.json' ) >/dev/null 2>&1
PHASEA="$(cd "$T" && git rev-parse --short HEAD)"
mkdir -p "$T/.runs/foo"
printf '{"run":"foo","pipeline":"full","source":"harness","intends_code":true,"baseline_sha":"%s","spec_present":true,"spec_path":"specs/foo/spec.md","feature":"specs/foo/spec.md","tier_source":"harness"}\n' "$BASE" > "$T/.runs/foo/RUN"
# armed harness run, tasks.md committed at HEAD, NO code batch announced, cbsha unset → boundary.
( cd "$T" && printf '/team-bootstrap:deliver specs/foo' | bash "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
CB="$(grep -oE '"code_baseline_sha":"[^"]*"' "$T/.runs/foo/RUN" | sed 's/.*://; s/"//g')"
_chk "$([ -n "$CB" ] && echo set || echo unset)" set "code_baseline_sha is stamped at the boundary"
_chk "$(cd "$T" && [ "$(git rev-parse "$CB" 2>/dev/null)" = "$(git rev-parse "$PHASEA" 2>/dev/null)" ] && echo yes || echo no)" yes "  …to HEAD (the Phase-A commit — after the docs, so the docs are excluded)"
# current_batch_base (first batch, none closed yet) prefers code_baseline_sha over baseline_sha — but
# ONLY once HEAD has advanced past it (cbsha==HEAD deliberately falls through: an empty window is not a
# base). Simulate the batch's first commit landing after the boundary, then the base is the boundary and
# the Phase-A docs+feature.json commit is OUTSIDE the window (the whole point of #104).
( cd "$T" && printf 'batch1\n' > src.txt && git add . && git commit -qm 'feat(B1): first code commit' ) >/dev/null 2>&1
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/foo/batches.jsonl"
CBB="$(cd "$T" && bash -c '. "'"$here"'/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=foo current_batch_base')"
_chk "$(cd "$T" && [ "$(git rev-parse "$CBB" 2>/dev/null)" = "$(git rev-parse "$PHASEA" 2>/dev/null)" ] && echo yes || echo no)" yes "current_batch_base uses code_baseline_sha (Phase-A commit outside the first batch's window)"

echo "#104 — guards: no re-stamp / no stamp when a code batch is already announced:"
# already set → not overwritten
( cd "$T" && printf '/team-bootstrap:deliver specs/foo' | bash "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
CB2="$(grep -oE '"code_baseline_sha":"[^"]*"' "$T/.runs/foo/RUN" | sed 's/.*://; s/"//g')"
_chk "$CB2" "$CB" "an already-set code_baseline_sha is not re-stamped"
# run WITH a code batch already announced → never stamps (marker at .runs/foo, the resolved run id).
T2="$(mktemp -d)"
( cd "$T2" && git init -q && git config user.email t@t && git config user.name t
  echo b > f && git add . && git commit -qm base && mkdir -p specs/foo .runs/foo
  printf '# t\n' > specs/foo/tasks.md && git add . && git commit -qm docs ) >/dev/null 2>&1
B2="$(cd "$T2" && git rev-parse --short HEAD~1)"
printf '{"run":"foo","pipeline":"full","source":"harness","intends_code":true,"baseline_sha":"%s","spec_present":true,"spec_path":"specs/foo/spec.md","feature":"specs/foo/spec.md","tier_source":"harness"}\n' "$B2" > "$T2/.runs/foo/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T2/.runs/foo/batches.jsonl"
( cd "$T2" && printf '/team-bootstrap:deliver specs/foo' | bash "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(grep -c code_baseline_sha "$T2/.runs/foo/RUN" 2>/dev/null)" 0 "a run with a code batch already announced does NOT stamp code_baseline_sha (too late — not the boundary)"

rm -rf "$T" "$T2"
if [ "$fail" -eq 0 ]; then echo "code-baseline-writer.test.sh: OK"; exit 0; fi
echo "code-baseline-writer.test.sh: $fail case(s) FAILED" >&2; exit 1
