#!/usr/bin/env bash
# stop-hook-phase-a.test.sh — issue #87: the Stop hook must not exit-2-loop during Phase A.
#
# delivery-stop-hook exists to catch "finished Phase A, then skipped Phase B" — a run that shipped no
# earned closure. But before any batch is announced and before any code is committed, the run is still
# IN Phase A (clarify/plan/tasks/architecture-review); a Stop there is a legitimate yield, not the
# skip-B failure, and it was blocked every turn. The observable that tells them apart: Phase A's
# terminal artefact tasks.md is not yet on disk. Once it is, the relaxation lifts.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
H="$here/bin/delivery-stop-hook.sh"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit $1 want $2)" >&2; fail=$((fail+1)); fi; }

T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base
  mkdir -p specs/foo ) >/dev/null 2>&1
HEAD_SHA="$(cd "$T" && git rev-parse --short HEAD)"
PREV_SHA="$HEAD_SHA"   # baseline == HEAD ⇒ no code since baseline (csb=0)

_mk(){ mkdir -p "$T/.runs/$1"; printf '%s\n' "$2" > "$T/.runs/$1/RUN"; }
_run(){ ( cd "$T" && TEAM_BOOTSTRAP_RUN="$1" "$H" </dev/null >/dev/null 2>&1 ); echo $?; }

# A — Phase A in progress: milestone on disk, tasks.md NOT yet produced, no batch, no code. ALLOW.
printf '# spec\n' > "$T/specs/foo/spec.md"
_mk pa "{\"run\":\"pa\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$HEAD_SHA\",\"spec_present\":true,\"spec_path\":\"specs/foo/spec.md\",\"feature\":\"specs/foo/spec.md\"}"
_chk "$(_run pa)" 0 "Phase A (spec on disk, no tasks.md, nothing shipped) → allow (#87)"

# B — Phase A FINISHED, Phase B skipped: tasks.md present, still no batch, no code. BLOCK (the retro failure).
printf '# tasks\n' > "$T/specs/foo/tasks.md"
_mk pb "{\"run\":\"pb\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$HEAD_SHA\",\"spec_present\":true,\"spec_path\":\"specs/foo/spec.md\",\"feature\":\"specs/foo/spec.md\"}"
_chk "$(_run pb)" 2 "finished Phase A (tasks.md present), skipped Phase B → still block"

# C — no milestone at all (the 'delivered nothing' shape): must still block.
_mk pc "{\"run\":\"pc\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$HEAD_SHA\"}"
_chk "$(_run pc)" 2 "armed run, no milestone, nothing delivered → still block (unchanged)"

# D — a milestone in Phase A shape BUT code shipped since baseline: relaxation must NOT apply. BLOCK.
( cd "$T" && echo more >> f && git commit -qam c ) >/dev/null 2>&1
NEW_HEAD="$(cd "$T" && git rev-parse --short HEAD)"
rm -f "$T/specs/foo/tasks.md"
_mk pd "{\"run\":\"pd\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$PREV_SHA\",\"spec_present\":true,\"spec_path\":\"specs/foo/spec.md\",\"feature\":\"specs/foo/spec.md\"}"
_chk "$(_run pd)" 2 "code shipped since baseline (no tasks.md) → not Phase A, still block (no-code guard)"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "stop-hook-phase-a.test.sh: OK"; exit 0; fi
echo "stop-hook-phase-a.test.sh: $fail case(s) FAILED" >&2; exit 1
