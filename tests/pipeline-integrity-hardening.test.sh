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

# ---------------------------------------------------------------------------------------------------
# WS-D — branch-guard parse bypasses (AC-D1..D6). Drives bin/guard-git.sh with PreToolUse payloads on a
# fixture repo whose default branch is main, armed with an intends_code run marker.
GUARD="$here/../bin/guard-git.sh"
echo "WS-D — branch-guard parse bypasses (AC-D1..D6):"
GT="$(mktemp -d)"
(
  cd "$GT" || exit 1
  git init -q; git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base
  mkdir -p .runs/r && printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > .runs/r/RUN
  # an inner NESTED repo whose branch is main — target of the --git-dir/--work-tree retarget (B3)
  mkdir -p inner && ( cd inner && git init -q && git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email t@t && git config user.name t && echo i > g && git add . && git commit -qm ibase )
) >/dev/null 2>&1
_gd()  { ( cd "$GT" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$GUARD" >/dev/null 2>&1 ); echo $?; }
_gon() { ( cd "$GT" && git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" ) >/dev/null 2>&1; }
Pd()   { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

_gon main
# AC-D1 — single-quoted env value with a space (the single-quoted twin of the finding-#1 double-quote fix)
_chk "$(_gd "$(Pd "FOO='a b' git commit -m x")")" 2 "AC-D1 single-quoted env (FOO='a b') git commit on main → block"
# AC-D2 — git-level alias: -c consumes alias.ci=commit, 'ci' is an unrecognized subcommand → fail-closed
_chk "$(_gd "$(Pd 'git -c alias.ci=commit ci')")" 2 "AC-D2 git -c alias.ci=commit ci on main → block"
# AC-D3 — --git-dir/--work-tree retarget: outer on FEATURE, inner on main → only honoring the retarget blocks
_gon feature
_chk "$(_gd "$(Pd 'git --git-dir=inner/.git --work-tree=inner commit -m x')")" 2 "AC-D3 --git-dir/--work-tree retarget to inner(main) → block"
_gon main
# AC-D4 — reads and legitimate feature commits → allow (no new false positives from the tightened posture)
_chk "$(_gd "$(Pd 'git log --oneline')")" 0 "AC-D4 git log → allow (read)"
_chk "$(_gd "$(Pd 'git status')")"        0 "AC-D4 git status → allow (read)"
_chk "$(_gd "$(Pd 'git push origin main')")" 0 "AC-D4 git push → allow (disclosed not-gated)"
_gon feature
_chk "$(_gd "$(Pd 'git commit -m x')")"   0 "AC-D4 feature-branch commit → allow"
_gon main
# AC-D5 — the double-quoted env fix (finding #1) still holds
_chk "$(_gd '{"tool_name":"Bash","tool_input":{"command":"GIT_AUTHOR_NAME=\"A B\" git commit -m x"}}')" 2 "AC-D5 double-quoted env git commit on main → block (regression)"
# AC-D4b (review Finding 1, R5) — a read on default with a shell metachar INSIDE a quoted arg must NOT
# false-block: the quote-blind segment split makes a debris fragment (status'), which fail-closed must
# treat as split debris (punctuation → not a clean subcommand), not as an unrecognized subcommand.
_chk "$(_gd "$(Pd "git log --grep 'x; git status'")")" 0 "AC-D4b read on main w/ metachar in quoted arg → allow (no R5 false block)"
_chk "$(_gd "$(Pd "git log --grep 'x; git deploy'")")" 0 "AC-D4b read on main w/ metachar+word in quoted arg → allow"
rm -rf "$GT"

# ---------------------------------------------------------------------------------------------------
# WS-B — preflight as a readiness gate, not a scaffold linter (AC-B1..B6). Drives bin/check-preflight.sh
# (the three runtime probes) and delivery-lib.sh governed_waiver_ok.
PF="$here/../bin/check-preflight.sh"
LIB="$here/../bin/delivery-lib.sh"
echo "WS-B — preflight readiness probes + governed waiver (AC-B1..B6):"

# _bscaffold DIR → a fully-valid scaffold + an armed marker whose feature points at specs/x (which has
# a spec/plan/tasks docs-contract). AGENTS.md carries a runnable Test: command whose binary exists.
_bscaffold() {
  local d="$1" sha
  git -C "$d" init -q
  printf '# constitution\n' > "$d/constitution.md"
  printf '{"active_spec":"specs/x","specs_dir":"specs","constitution":"constitution.md","adr_dir":"docs/adr"}\n' > "$d/feature.json"
  mkdir -p "$d/specs/TEMPLATE" "$d/specs/x" "$d/docs/adr"
  printf '# spec\n' > "$d/specs/x/spec.md"; printf '# plan\n' > "$d/specs/x/plan.md"; printf '# tasks\n' > "$d/specs/x/tasks.md"
  printf '# AGENTS\n\n- Test: `true`\n' > "$d/AGENTS.md"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
  sha="$(git -C "$d" rev-parse --short HEAD)"
  mkdir -p "$d/.runs/r"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s","feature":"specs/x"}\n' "$sha" > "$d/.runs/r/RUN"
}
_pf() { ( cd "$1" && env -u TEAM_BOOTSTRAP_RUN "$PF" . >/dev/null 2>&1 ); echo $?; }

# AC-B6 — a fully-valid scaffold with a runnable Test: + docs-contract + resolvable baseline → ready (0).
D="$(mktemp -d)"; _bscaffold "$D"; _chk "$(_pf "$D")" 0 "AC-B6 full scaffold + runnable Test: + docs → ready (0)"; rm -rf "$D"
# AC-B1 — a scaffold whose AGENTS.md has NO Test: line (no runnable test command) → HARD fail (1).
D="$(mktemp -d)"; _bscaffold "$D"; printf '# AGENTS\n\n(no test line)\n' > "$D/AGENTS.md"
git -C "$D" -c user.email=t@t -c user.name=t commit -aqm "drop Test:" >/dev/null 2>&1
_chk "$(_pf "$D")" 1 "AC-B1 no runnable Test: command → preflight HARD fail (1)"; rm -rf "$D"
# AC-B2 — a Test: command whose binary is NOT on PATH / not a file → toolchain HARD fail (1).
D="$(mktemp -d)"; _bscaffold "$D"; printf '# AGENTS\n\n- Test: `nonexistent-binary-xyz-9f3 run`\n' > "$D/AGENTS.md"
git -C "$D" -c user.email=t@t -c user.name=t commit -aqm "bad tool" >/dev/null 2>&1
_chk "$(_pf "$D")" 1 "AC-B2 Test: binary absent from PATH → toolchain HARD fail (1)"; rm -rf "$D"
# AC-B3a — baseline_sha does not resolve → HARD fail (1) (was WARN in the shipped linter).
D="$(mktemp -d)"; _bscaffold "$D"
printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"deadbeef","feature":"specs/x"}\n' > "$D/.runs/r/RUN"
_chk "$(_pf "$D")" 1 "AC-B3a baseline_sha unresolvable → preflight HARD fail (1)"; rm -rf "$D"
# AC-B3b — the run's feature docs-contract (spec.md) absent from the tree → HARD fail (1).
D="$(mktemp -d)"; _bscaffold "$D"; rm -f "$D/specs/x/spec.md"
_chk "$(_pf "$D")" 1 "AC-B3b feature docs-contract (spec.md) missing → preflight HARD fail (1)"; rm -rf "$D"

# AC-B3b-greenfield (review HIGH-1) — a feature-bearing marker whose feature dir does NOT exist yet (the
# normal Phase-0 greenfield case: Phase A has not generated spec/plan/tasks) must NOT HARD-fail preflight.
D="$(mktemp -d)"; _bscaffold "$D"
sha_g="$(git -C "$D" rev-parse --short HEAD)"
printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s","feature":"specs/greenfield"}\n' "$sha_g" > "$D/.runs/r/RUN"
_chk "$(_pf "$D")" 0 "AC-B3b greenfield: feature dir not yet generated → ready (0, probe fires only on a partial dir)"; rm -rf "$D"

# HIGH-2 regression — record_preflight must keep the marker VALID JSON when a governed-waiver reason
# carries a double quote (field_str reads it truncated; re-emit must be escaped, not raw).
D="$(mktemp -d)"; mkdir -p "$D/.runs/r"
printf '%s\n' '{"run":"r","intends_code":true,"preflight":{"exit":1,"gaps":[],"ack":true,"by":"f","reason":"needs \"scaffold\" fix","expires":"2999-01-01"}}' > "$D/.runs/r/RUN"
( cd "$D" && . "$LIB" && TEAM_BOOTSTRAP_RUN=r record_preflight 1 '["still broken"]' ) >/dev/null 2>&1
if python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$D/.runs/r/RUN" >/dev/null 2>&1; then
  _chk 0 0 "HIGH-2 record_preflight keeps marker valid JSON with a quote in reason"
else
  _chk 1 0 "HIGH-2 record_preflight keeps marker valid JSON with a quote in reason"
fi
rm -rf "$D"

# AC-B5 — governed_waiver_ok(ack,by,reason,expires,[now]): a complete, unexpired waiver clears; a bare
# ack (missing by/reason/expires) or an expired one does NOT (no standing free pass).
if grep -q 'governed_waiver_ok' "$LIB" 2>/dev/null; then
  _gw() { ( . "$LIB"; governed_waiver_ok "$1" "$2" "$3" "$4" "$5" >/dev/null 2>&1; echo $? ); }
  _chk "$(_gw true founder "scaffold gap" 2999-01-01 2026-08-20)" 0 "AC-B5 complete unexpired waiver → ok (0)"
  _chk "$(_gw true ''      ''            2999-01-01 2026-08-20)" 1 "AC-B5 bare ack (no by/reason) → not ok (1)"
  _chk "$(_gw true founder "gap"          2000-01-01 2026-08-20)" 1 "AC-B5 expired waiver → not ok (1)"
  _chk "$(_gw false founder "gap"         2999-01-01 2026-08-20)" 1 "AC-B5 ack:false → not ok (1)"
else
  _chk 1 0 "AC-B5 governed_waiver_ok present in delivery-lib.sh"   # red until T040 lands
fi

# ---------------------------------------------------------------------------------------------------
# WS-E — post-delivery review hardening: the four fail-opens/false-fails must fail CLOSED (AC-E1..E4).
echo "WS-E — review hardening: fail-opens closed (AC-E1..E4):"

# AC-E1 — quoted subcommands must BLOCK on the default branch (raw escaped-JSON payloads, as a real hook
# receives); reads with a metachar in a quoted arg must still be allowed (R5 preserved).
GTE="$(mktemp -d)"
( cd "$GTE" && git init -q && git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git config user.email t@t && git config user.name t && echo b>f && git add . && git commit -qm b
  mkdir -p .runs/r && printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > .runs/r/RUN ) >/dev/null 2>&1
_ge() { ( cd "$GTE" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$GUARD" >/dev/null 2>&1 ); echo $?; }
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"git \"commit\""}}')"    2 "AC-E1 git \"commit\" (double-quoted sub) on main → block"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"git '"'"'commit'"'"'"}}')" 2 "AC-E1 git 'commit' (single-quoted sub) on main → block"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"git com\"m\"it"}}')"     2 "AC-E1 git com\"m\"it (split-quoted sub) on main → block"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"git \"merge\" x"}}')"    2 "AC-E1 git \"merge\" (quoted sub) on main → block"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"\"git\" commit"}}')"     2 "AC-E1 \"git\" commit (quoted binary) on main → block"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"git log --grep '"'"'x; git status'"'"'"}}')" 0 "AC-E1 read w/ metachar in quoted arg → allow (R5 preserved)"
# AC-E1 (code review) — an ESCAPED quote outside quotes must NOT open a phantom quote that swallows a
# following ; / && and hides a real commit-on-default (backslash-escape handling in _segments).
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"echo \\\" ; git commit -m x"}}')" 2 "AC-E1 escaped-quote then ; git commit → block (no phantom quote)"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"echo \\\" && git commit -m x"}}')" 2 "AC-E1 escaped-quote then && git commit → block"
_chk "$(_ge '{"tool_name":"Bash","tool_input":{"command":"git commit"}}')"         2 "AC-E1 (control) git commit on main → block"
rm -rf "$GTE"

# AC-E2 — a git-status error (corrupt index) must fail the dirty-tree probe CLOSED, not open. The
# committed window is NON-empty and NON-surface (so _batch_files succeeds and touches no committed seam);
# only a corrupt index (git status errors) is the variable — without the fix that silently passes.
CE="$(mktemp -d)"
( cd "$CE" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p references bin && cp "$CSREF" references/control-surface.txt
  printf '#gate\n' > bin/check-x.sh && echo s>seed && git add . && git commit -qm base   # commit1 (baseline)
  cb="$(git rev-parse --short HEAD)"
  mkdir -p src && echo x>src/app.py && git add . && git commit -qm work                  # commit2 (non-surface)
  mkdir -p .runs/r && printf '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}\n' > .runs/r/batches.jsonl
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cb" > .runs/r/RUN
  printf 'garbage-not-an-index' > .git/index ) >/dev/null 2>&1                            # corrupt → git status errors
_chk "$( ( cd "$CE" && TEAM_BOOTSTRAP_RUN=r "$SEAMACK" . >/dev/null 2>&1 ); echo $? )" 1 "AC-E2 git-status error (corrupt index) → seam-ack fail-closed (1)"
rm -rf "$CE"

# AC-E3 — an env-prefixed Test: command must resolve its real binary, not the ENV= token → ready.
DE="$(mktemp -d)"; _bscaffold "$DE"; printf '# AGENTS\n\n- Test: `NODE_ENV=test true`\n' > "$DE/AGENTS.md"
git -C "$DE" -c user.email=t@t -c user.name=t commit -aqm "env-prefixed Test" >/dev/null 2>&1
_chk "$(_pf "$DE")" 0 "AC-E3 env-prefixed Test: (NODE_ENV=test true) → ready (0, strips ENV=)"
rm -rf "$DE"
# AC-E3 (arch review F1) — the env-strip must be FIRST-TOKEN-anchored: a LATER assignment must not strip
# the real command word and resolve a builtin. First command absent + a later NAME=val → HARD, not ready.
DE="$(mktemp -d)"; _bscaffold "$DE"; printf '# AGENTS\n\n- Test: `nomake-xyz-9f3 VAR=x test`\n' > "$DE/AGENTS.md"
git -C "$DE" -c user.email=t@t -c user.name=t commit -aqm "later-assign Test" >/dev/null 2>&1
_chk "$(_pf "$DE")" 1 "AC-E3 later assignment (nomake-xyz VAR=x test), first cmd absent → HARD (1, no strip-to-builtin fail-open)"
rm -rf "$DE"

# AC-E4 — per-batch reviewer floor: a full run with two closed code batches, only ONE reviewed → block.
FE="$(mktemp -d)"
( cd "$FE" && git init -q && git config user.email t@t && git config user.name t && echo a>f && git add . && git commit -qm a ) >/dev/null 2>&1
FBASE="$( ( cd "$FE" && git rev-parse --short HEAD ) )"
mkdir -p "$FE/.runs/r"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$FBASE" > "$FE/.runs/r/RUN"
printf '%s\n%s\n' \
  "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$FBASE\"],\"code_delta\":3}" \
  "{\"id\":\"B2\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$FBASE\"],\"code_delta\":3}" > "$FE/.runs/r/batches.jsonl"
printf '%s\n' '{"batch":"B1","subagent_type":"code-reviewer"}' > "$FE/.runs/r/dispatch.jsonl"   # only B1 reviewed
_chk "$( ( cd "$FE" && TEAM_BOOTSTRAP_RUN=r bash "$HOOK" </dev/null >/dev/null 2>&1 ); echo $? )" 2 "AC-E4 per-batch floor: closed B2 has no reviewer → Stop block (2)"
rm -rf "$FE"

if [ "$fail" -eq 0 ]; then echo "pipeline-integrity-hardening.test.sh: OK"; exit 0; fi
echo "pipeline-integrity-hardening.test.sh: $fail case(s) FAILED" >&2; exit 1
