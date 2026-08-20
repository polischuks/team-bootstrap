#!/usr/bin/env bash
# pipeline-integrity-hardening.test.sh — red-first behavioural spec for the four audit-remediation
# work-streams (specs/pipeline-integrity-hardening). WS-A lands in batch 1; WS-C/WS-D/WS-B append
# their sections in later batches. Written BEFORE the fix → the WS-A cases fail red, then go green.
#
# WS-A (this batch): the role/review gate is anchored at RUN-CLOSE (the Stop hook), not only at
# batch-close (verify-batch). Exercises AC-A1..A5 from specs/pipeline-integrity-hardening/spec.md:
#   - the `csb` direct-delivery allowance is refused for full/mvp AND for an absent/unknown pipeline
#     (only single-thread keeps it — finding-1, HIGH);
#   - the Stop hook independently asserts the >=1 reviewer floor over closed kind:code batches via the
#     shared reviewer_dispatch_count (finding-2) — a full run whose closed batch shows zero reviewer
#     dispatch is blocked.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
HOOK="$here/../bin/delivery-stop-hook.sh"

fail=0
_chk() { # _chk GOT WANT MSG
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit '$1' want '$2')" >&2; fail=$((fail + 1)); fi
}

# --- a temp git repo: baseline = first commit; HEAD = a 2nd commit adding non-doc code -----------------
# (so code_since_baseline("$BASE") is TRUE — the direct-delivery `csb` signal the Stop hook reads).
T="$(mktemp -d)"
(
  cd "$T" || exit 1
  git init -q
  git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git config user.email t@t && git config user.name t
  echo 'base' > f.sh && git add . && git commit -qm base
) >/dev/null 2>&1
BASE="$( ( cd "$T" && git rev-parse --short HEAD ) 2>/dev/null )"
( cd "$T" && printf 'code2\n' >> f.sh && git add . && git commit -qm work ) >/dev/null 2>&1

# _stop RUN → run the Stop hook under run RUN, from the temp repo cwd; echo its exit code
_stop() { ( cd "$T" && TEAM_BOOTSTRAP_RUN="$1" bash "$HOOK" </dev/null >/dev/null 2>&1 ); echo $?; }
mkrun() { mkdir -p "$T/.runs/$1"; printf '%s\n' "$2" > "$T/.runs/$1/RUN"; }

echo "WS-A — role/review gate anchored at run-close (AC-A1..A5):"

# AC-A1 — full run, code since baseline, NO announced batch / NO earned closure → Stop exit 2.
# (the exact spec-169 shape the audit reproduced as Stop exit 0 on the no-batch path)
mkrun full_nb "{\"run\":\"full_nb\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
_chk "$(_stop full_nb)" 2 "full run + code since baseline + no batch → Stop exit 2 (AC-A1)"

# AC-A2 — single-thread run, same shape → Stop exit 0 (the csb allowance is retained for the one
# pipeline that has no role fan-out). The refusal must be pipeline-SCOPED, not global.
mkrun st_nb "{\"run\":\"st_nb\",\"pipeline\":\"single-thread\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
_chk "$(_stop st_nb)" 0 "single-thread run + code since baseline + no batch → Stop exit 0 (AC-A2)"

# AC-A5 — ABSENT pipeline, same shape → Stop exit 2 (fail-closed on the sole gate for the no-batch
# path; a marker without `pipeline` must not inherit the csb allowance — finding-1, HIGH).
mkrun nopipe_nb "{\"run\":\"nopipe_nb\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
_chk "$(_stop nopipe_nb)" 2 "absent-pipeline run + code since baseline + no batch → Stop exit 2 (AC-A5)"

# AC-A3a — full run with an announced+closed kind:code batch that dispatched >=1 reviewer → exit 0.
mkrun full_ok "{\"run\":\"full_ok\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$BASE\"],\"code_delta\":3}" > "$T/.runs/full_ok/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer"}' > "$T/.runs/full_ok/dispatch.jsonl"
_chk "$(_stop full_ok)" 0 "full run + closed batch + reviewer dispatch → Stop exit 0 (AC-A3a)"

# AC-A3b — full run with a closed batch but ZERO reviewer dispatch (dispatch.jsonl present, only a
# builder) → block. The Stop hook independently re-asserts the reviewer floor at run-close.
mkrun full_norev "{\"run\":\"full_norev\",\"pipeline\":\"full\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$BASE\"],\"code_delta\":3}" > "$T/.runs/full_norev/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer"}' > "$T/.runs/full_norev/dispatch.jsonl"
_chk "$(_stop full_norev)" 2 "full run + closed batch + zero reviewer dispatch → Stop exit 2 (AC-A3b)"

# AC-A5b (review CRITICAL-1) — the reviewer floor must NOT be allowlisted to full|mvp: an ABSENT /
# unknown / mislabeled pipeline presenting a closed batch with zero reviewer dispatch must ALSO block,
# else a legacy marker (no `pipeline` field) or a trailing-space "full " evades prong 2 → Stop exit 0.
mkrun nopipe_norev "{\"run\":\"nopipe_norev\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$BASE\"],\"code_delta\":3}" > "$T/.runs/nopipe_norev/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer"}' > "$T/.runs/nopipe_norev/dispatch.jsonl"
_chk "$(_stop nopipe_norev)" 2 "absent-pipeline + closed batch + zero reviewer dispatch → Stop exit 2 (AC-A5b)"

mkrun space_norev "{\"run\":\"space_norev\",\"pipeline\":\"full \",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$BASE\"}"
printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$BASE\"],\"code_delta\":3}" > "$T/.runs/space_norev/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"backend-developer"}' > "$T/.runs/space_norev/dispatch.jsonl"
_chk "$(_stop space_norev)" 2 "mislabeled 'full ' (trailing space) + closed batch + zero reviewer → Stop exit 2 (AC-A5b)"

rm -rf "$T"

# ---------------------------------------------------------------------------------------------------
# WS-C — control-surface scope + dirty-tree precondition (AC-C1..C3). Fixtures copy the REAL
# references/control-surface.txt so T020's additions (guard-git / quality-gate / delivery-stop-hook /
# delivery-marker-init) are exercised against the shipped list.
SEAMACK="$here/../bin/check-seam-ack.sh"
CSREF="$here/../references/control-surface.txt"

echo "WS-C — control-surface scope + dirty-tree (AC-C1..C3):"

# _csfixture → fresh git repo carrying the real control-surface.txt at base; echoes its path.
_csfixture() {
  local d; d="$(mktemp -d)"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t
    mkdir -p references && cp "$CSREF" references/control-surface.txt
    echo seed > seed && git add . && git commit -qm base ) >/dev/null 2>&1
  printf '%s' "$d"
}
# _csrun DIR RUN → run check-seam-ack in DIR under run RUN; echo exit code
_csrun() { ( cd "$1" && TEAM_BOOTSTRAP_RUN="$2" "$SEAMACK" . >/dev/null 2>&1 ); echo $?; }

# AC-C1 — a batch committing a vacuity edit to a newly-listed hook/gate script WITHOUT a control-surface
# ack → seam exit 1 (per file). Before T020 those files aren't in control-surface.txt → exit 0 (red).
for f in bin/guard-git.sh bin/quality-gate.sh bin/delivery-stop-hook.sh bin/delivery-marker-init.sh; do
  D="$(_csfixture)"
  cb="$(cd "$D" && git rev-parse --short HEAD)"                       # baseline = base commit
  ( cd "$D" && mkdir -p "$(dirname "$f")" && printf 'exit 0\n' > "$f" && git add . && git commit -qm "gut $f" ) >/dev/null 2>&1
  mkdir -p "$D/.runs/r"
  printf '{"id":"B1","kind":"code","files":["%s"],"status":"announced"}\n' "$f" > "$D/.runs/r/batches.jsonl"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cb" > "$D/.runs/r/RUN"
  _chk "$(_csrun "$D" r)" 1 "AC-C1 vacuity edit to $f, no control-surface ack → seam exit 1"
  rm -rf "$D"
done

# AC-C2 — a batch closing with UNCOMMITTED modifications to a control-surface path in the working tree,
# even when git diff base..HEAD is clean of them → fail closed (dirty-tree precondition, T022). The
# committed window (baseline = the commit that added the tracked gate) touches ONLY a non-surface file;
# only the uncommitted edit to bin/check-existing.sh makes the tree dirty on the surface.
D="$(_csfixture)"
( cd "$D" && mkdir -p bin && printf '#gate\n' > bin/check-existing.sh && git add . && git commit -qm "add tracked gate" ) >/dev/null 2>&1
cb="$(cd "$D" && git rev-parse --short HEAD)"                          # baseline = post-gate commit
( cd "$D" && mkdir -p src && echo x > src/app.py && git add . && git commit -qm "non-surface work" ) >/dev/null 2>&1
( cd "$D" && printf 'exit 0\n' >> bin/check-existing.sh ) >/dev/null 2>&1   # DIRTY, uncommitted, surface
mkdir -p "$D/.runs/r"
printf '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}\n' > "$D/.runs/r/batches.jsonl"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cb" > "$D/.runs/r/RUN"
_chk "$(_csrun "$D" r)" 1 "AC-C2 dirty control-surface working tree (uncommitted) + clean committed diff → fail closed"
rm -rf "$D"

# AC-C3 — clean working tree + in-window committed NON-surface change → exit 0 (no false positive); and
# a dirty NON-surface file must NOT trip the precondition (it is scoped to control-surface paths).
D="$(_csfixture)"
cb="$(cd "$D" && git rev-parse --short HEAD)"
( cd "$D" && mkdir -p src && echo x > src/app.py && git add . && git commit -qm "non-surface work" ) >/dev/null 2>&1
mkdir -p "$D/.runs/r"
printf '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}\n' > "$D/.runs/r/batches.jsonl"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cb" > "$D/.runs/r/RUN"
_chk "$(_csrun "$D" r)" 0 "AC-C3 clean tree + committed non-surface change → exit 0 (no false positive)"
( cd "$D" && echo more >> src/app.py ) >/dev/null 2>&1                  # dirty a NON-surface file
_chk "$(_csrun "$D" r)" 0 "AC-C3 dirty NON-surface file → exit 0 (precondition scoped to control surface)"
rm -rf "$D"

# AC-C2b (review HIGH) — a dirty surface file whose name contains a SPACE, under a whole-tree surface
# entry (commands/), must still be flagged. git's default core.quotepath double-quotes such a path; a
# naive porcelain parse drops it (fail-open). Requires the -z / core.quotepath=false read.
D="$(_csfixture)"
( cd "$D" && mkdir -p commands && printf 'x\n' > "commands/space file.md" && git add . && git commit -qm "add spaced surface file" ) >/dev/null 2>&1
cb="$(cd "$D" && git rev-parse --short HEAD)"
( cd "$D" && mkdir -p src && echo x > src/app.py && git add . && git commit -qm "non-surface work" ) >/dev/null 2>&1
( cd "$D" && printf 'tampered\n' >> "commands/space file.md" ) >/dev/null 2>&1   # DIRTY, uncommitted, surface, spaced name
mkdir -p "$D/.runs/r"
printf '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}\n' > "$D/.runs/r/batches.jsonl"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cb" > "$D/.runs/r/RUN"
_chk "$(_csrun "$D" r)" 1 "AC-C2b dirty surface file with a SPACE in its name (commands/) → fail closed (quotepath/-z)"
rm -rf "$D"

# AC-C2c (review MEDIUM) — a STAGED rename that moves a surface gate OUT of its namespace must be flagged
# on the SOURCE side (git mv bin/check-existing.sh bin/OTHER.sh: dest non-surface, source surface).
D="$(_csfixture)"
( cd "$D" && mkdir -p bin && printf '#gate\n' > bin/check-existing.sh && git add . && git commit -qm "add tracked gate" ) >/dev/null 2>&1
cb="$(cd "$D" && git rev-parse --short HEAD)"
( cd "$D" && mkdir -p src && echo x > src/app.py && git add . && git commit -qm "non-surface work" ) >/dev/null 2>&1
( cd "$D" && git mv bin/check-existing.sh bin/OTHER.sh ) >/dev/null 2>&1   # STAGED rename out of the surface
mkdir -p "$D/.runs/r"
printf '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}\n' > "$D/.runs/r/batches.jsonl"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cb" > "$D/.runs/r/RUN"
_chk "$(_csrun "$D" r)" 1 "AC-C2c staged rename of a surface gate out (bin/check-existing.sh → bin/OTHER.sh) → fail closed (both rename sides)"
rm -rf "$D"

if [ "$fail" -eq 0 ]; then echo "pipeline-integrity-hardening.test.sh: OK"; exit 0; fi
echo "pipeline-integrity-hardening.test.sh: $fail case(s) FAILED" >&2; exit 1
