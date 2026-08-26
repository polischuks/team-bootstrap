#!/usr/bin/env bash
# pipeline-sizing.test.sh — the harness sizes each batch (issue #27, milestone harness-owned-pipeline-sizing).
#
# Today select-pipeline can only ever push cost UP: its one non-zero verdict is `exit 2 = under-sized`,
# and `chosen >= recommended` prints "right-sized" — so `full` on a one-file change reports success and
# says nothing. It also sizes per RUN while cost accrues per BATCH.
#
# Contract: report BOTH directions, size a single batch from its own window + risk_rank, and never turn
# over-provisioning into a failure (blocking it would push the orchestrator to review inline — the
# spec-169 collapse; see the spec's enforceability boundary).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }
SP="$here/bin/select-pipeline.sh"

echo "issue #27 — two-directional, batch-aware sizing:"

# ---- AC-1: the missing direction — over-provisioning must be REPORTED, not silent ----
out="$(printf '20\t5\tsrc/util.ts\n' | "$SP" --from-stdin --chosen full 2>&1)"; rc=$?
_chk "$(printf '%s' "$out" | grep -ciE 'over-?provision|HEAVIER')" "1" \
  "AC-1 chosen full on a single-thread-sized diff → reports over-provisioned"
_chk "$rc" "0" "AC-1 …and stays exit 0 (advice, never a block — spec boundary)"

# ---- AC-1 regression: the under-sized contract is unchanged (exit 2 + ADVISORY) ----
out="$(printf '5\t0\tsrc/auth/login.ts\n' | "$SP" --from-stdin --chosen single-thread 2>&1)"; rc=$?
_chk "$rc" "2" "AC-1 under-sized still exits 2 (existing contract untouched)"
_chk "$(printf '%s' "$out" | grep -ciE 'LIGHTER')" "1" "AC-1 …with the existing ADVISORY wording"

# ---- AC-1: a correctly-sized choice stays quiet in BOTH senses ----
out="$(printf '20\t5\tsrc/util.ts\n' | "$SP" --from-stdin --chosen single-thread 2>&1)"; rc=$?
_chk "$rc" "0" "AC-1 right-sized → exit 0"
_chk "$(printf '%s' "$out" | grep -ciE 'over-?provision|LIGHTER')" "0" \
  "AC-1 …and says neither over- nor under- (no false nag)"

# ---- AC-2/AC-3: --batch sizes from THAT batch's window and risk_rank ----
_repo() { # build a repo whose RUN window is heavy but whose batch B3 is tiny
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"
  mkdir -p src db/migrations .runs/r
  printf 'a\n' > db/migrations/001.sql; git add -A; git commit -q -m heavy      # run-level: risky
  printf 'b\n' > src/small.ts;         git add -A; git commit -q -m light       # B3's own commit
  B3="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B3","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s"]}\n' "$B3" > .runs/r/batches.jsonl
}
T="$(mktemp -d)"; ( cd "$T" || exit 1; _repo
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B3 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: single-thread')" "1" \
    "AC-2 --batch sizes from the BATCH's window (tiny), not the run's (risky migration)"
) ; rm -rf "$T"

# AC-3: a risk touch inside the batch lifts it to full regardless of how small it is
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src/auth .runs/r
  printf 'b\n' > src/auth/login.ts; git add -A; git commit -q -m auth
  S="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s"]}\n' "$S" > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B1 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: full')" "1" \
    "AC-3 a one-line auth touch still recommends full (risk dominates size)"
) ; rm -rf "$T"

# AC-3: risk_rank alone lifts it, even with a trivial diff and no risky path
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src .runs/r
  printf 'b\n' > src/tiny.ts; git add -A; git commit -q -m tiny
  S="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced","commit_shas":["%s"]}\n' "$S" > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B1 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: full')" "1" \
    "AC-3 risk_rank:irreversible lifts a trivial diff to full"
) ; rm -rf "$T"

# ---- AC-4: a kind:doc batch is sized as the lightest tier ----
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p docs .runs/r
  printf 'b\n' > docs/note.md; git add -A; git commit -q -m doc
  S="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"D1","kind":"doc","risk_rank":"doc","status":"announced","commit_shas":["%s"]}\n' "$S" > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch D1 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: single-thread')" "1" \
    "AC-4 a kind:doc batch sizes to the lightest tier"
) ; rm -rf "$T"

# ---- REVIEW FINDINGS (HS-1 round 1) ----------------------------------------
# CRITICAL: an in-flight batch (no commit_shas) must NOT be sized over the whole run. Using the run's
# baseline_sha attributes every previously CLOSED batch's commits to the in-flight one — reproducing
# both defects of #27 inside the fix. The repo already owns the one true window: current_batch_base().
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p db/migrations src .runs/r
  printf 'a\n' > db/migrations/001.sql; git add -A; git commit -q -m b1     # B1's risky work
  B1="$(git rev-parse --short HEAD)"
  printf 'b\n' > src/tiny.ts; git add -A; git commit -q -m b2               # B2's tiny work
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  { printf '{"id":"B1","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":1}\n' "$B1"
    printf '{"id":"B2","kind":"code","risk_rank":"feature","status":"announced"}\n'; } > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B2 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: single-thread')" "1" \
    "AC-2 in-flight batch is sized from ITS window, not the run's (no closed-batch bleed)"
  _chk "$(printf '%s' "$out" | grep -ci 'data/schema')" "0" \
    "AC-2 …and does not inherit a CLOSED batch's risk signals"
) ; rm -rf "$T"

# HIGH: the declared-risk lift must survive an EMPTY window — sizing a batch BEFORE its code exists is
# the primary use of the flag (pick the tier when you announce, not after you have coded).
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}\n' > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B1 --chosen single-thread 2>&1)"; rc=$?
  _chk "$rc" "2" "AC-3 irreversible batch with no code yet + single-thread → still under-sized (exit 2)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: full')" "1" "AC-3 …and the lift still recommends full"
) ; rm -rf "$T"

# HIGH: an unresolvable --batch must fail LOUD, not read as "no changes" with exit 0 — that silently
# voids the exit-2 contract (the check-completeness declared-but-unresolvable class, already fixed once).
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src/auth .runs/r
  printf 'b\n' > src/auth/login.ts; git add -A; git commit -q -m auth
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
  ( TEAM_BOOTSTRAP_RUN=r "$SP" --batch TYPO9 --chosen single-thread >/dev/null 2>&1 ); rc=$?
  _chk "$([ "$rc" -ne 0 ] && echo loud || echo silent)" "loud" \
    "AC-2 an unresolvable --batch id fails loud (never a silent exit-0 no-op)"
) ; rm -rf "$T"

# MEDIUM: files/layers are SET cardinalities — a path touched by both the red and the green commit must
# count once. Otherwise every batch inflates upward and suppresses the OVER-PROVISIONED verdict.
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src .runs/r
  printf 'a\n' > src/a.ts; git add -A; git commit -q -m red;   R="$(git rev-parse --short HEAD)"
  printf 'aa\n' > src/a.ts; git add -A; git commit -q -m green; G="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s","%s"]}\n' "$G" "$R" > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B1 2>&1)"
  _chk "$(printf '%s' "$out" | grep -oE '[0-9]+ file\(s\)' | grep -oE '^[0-9]+')" "1" \
    "AC-2 a path touched by both red and green counts ONCE (files is a set)"
) ; rm -rf "$T"

# Round-2 review finding: the id was still interpolated into a BRE, and `.` was inside the allowed
# charset — so `--batch 'B.'` matched B1 and silently sized ANOTHER batch's window and risk_rank.
# It also defeated the exit-64 guard: an unresolvable-but-regex-matching id reached sizing.
T="$(mktemp -d)"; ( cd "$T" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src/auth src .runs/r
  printf 'b\n' > src/auth/login.ts; git add -A; git commit -q -m b1; B1="$(git rev-parse --short HEAD)"
  printf 'c\n' > src/tiny.ts;       git add -A; git commit -q -m b2; B2="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  { printf '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced","commit_shas":["%s"]}\n' "$B1"
    printf '{"id":"B2","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s"]}\n' "$B2"; } > .runs/r/batches.jsonl
  ( TEAM_BOOTSTRAP_RUN=r "$SP" --batch 'B.' --chosen single-thread >/dev/null 2>&1 ); rc=$?
  _chk "$rc" "64" "AC-2 a metacharacter batch id is REJECTED (never silently sizes another batch)"
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B2 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: single-thread')" "1" \
    "AC-2 …and an exact id still sizes its own window"
) ; rm -rf "$T"

# ---- WS-2: the harness computes the required role set per batch ------------
# The set is derived from the SAME sizer WS-1 built (one definition, no drift). The >=1 independent
# reviewer floor is an INVARIANT: it is never sized away, whatever the computation returns, because it
# is the anti-collapse guarantee itself (exec-role-integrity).
_rr() { # $1=batch id → the computed role set, space-separated
  ( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch "$1" )
}
_mkrun() { # $1=dir $2=path-to-touch $3=risk_rank $4=kind
  cd "$1" || return 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p "$(dirname "$2")" .runs/r
  printf 'b\n' > "$2"; git add -A; git commit -q -m work; S="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"%s","risk_rank":"%s","status":"announced","commit_shas":["%s"]}\n' "$4" "$3" "$S" > .runs/r/batches.jsonl
}

T="$(mktemp -d)"; ( _mkrun "$T" src/auth/login.ts feature code
  got="$(_rr B1)"
  for r in integration-verifier architecture-reviewer regression-guardian code-reviewer; do
    _chk "$(printf '%s' "$got" | grep -cw "$r")" "1" "AC-3 risky batch requires $r"
  done ) ; rm -rf "$T"

# single-thread-sized batch → the INVARIANT floor only (one mind, no fan-out — the pipeline's own
# contract). This is the cheapest legal outcome and it still carries an independent reviewer.
T="$(mktemp -d)"; ( _mkrun "$T" src/tiny.ts feature code
  got="$(_rr B1)"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" "AC-5 single-thread-sized batch still requires code-reviewer (>=1 floor INVARIANT)"
  _chk "$(printf '%s' "$got" | grep -cw architecture-reviewer)" "0" "AC-2 …and NOT architecture-reviewer (sized down)"
  _chk "$(printf '%s' "$got" | grep -cw regression-guardian)" "0" "AC-2 …and NOT regression-guardian (sized down)" ) ; rm -rf "$T"

# mvp-sized batch (several files across layers, no risk touch) → the OQ-2 reduced set:
# code-reviewer (the semantic class no fitness function sees) + integration-verifier (wiring/orphans).
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src lib .runs/r
  printf 'a\n' > src/x.ts; printf 'b\n' > src/y.ts; printf 'c\n' > lib/z.ts; printf 'd\n' > lib/w.ts
  git add -A; git commit -q -m work; S="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s"]}\n' "$S" > .runs/r/batches.jsonl
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 )"
  _chk "$(printf '%s' "$got" | grep -cw integration-verifier)" "1" "AC-2 mvp-sized batch adds integration-verifier (OQ-2 reduced set)"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" "AC-2 …plus code-reviewer"
  _chk "$(printf '%s' "$got" | grep -cw regression-guardian)" "0" "AC-2 …but not the full four" ) ; rm -rf "$T"

T="$(mktemp -d)"; ( _mkrun "$T" src/tiny.ts irreversible code
  got="$(_rr B1)"
  _chk "$(printf '%s' "$got" | grep -cw architecture-reviewer)" "1" "AC-3 risk_rank:irreversible lifts a tiny batch to the full set" ) ; rm -rf "$T"

T="$(mktemp -d)"; ( _mkrun "$T" docs/note.md doc doc
  _chk "$(printf '%s' "$(_rr B1)" | grep -c .)" "0" "AC-4 a kind:doc batch requires NO review roles" ) ; rm -rf "$T"

# T021 — the computed set is RECORDED on the batch's ledger entry (so the close gate reads a fact, not
# a recomputation), and an entry WITHOUT the field falls back to today's fixed floor (back-compat: old
# runs and hand-written ledgers keep working).
T="$(mktemp -d)"; ( _mkrun "$T" src/auth/login.ts feature code
  ( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r record_required_roles B1 )
  line="$(grep '"id"' .runs/r/batches.jsonl | tail -1)"
  _chk "$(printf '%s' "$line" | grep -c '"required_roles"')" "1" "AC-8 required_roles is recorded on the ledger entry"
  _chk "$(printf '%s' "$line" | grep -c 'architecture-reviewer')" "1" "AC-8 …with the computed set for a risky batch"
  _chk "$(python3 -c "import json,sys;json.loads(sys.stdin.read());print('ok')" <<< "$line")" "ok" "AC-8 …and the ledger line stays valid JSON"
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_recorded B1 )"
  _chk "$(printf '%s' "$got" | grep -cw regression-guardian)" "1" "AC-8 …and reads back through required_roles_recorded"
) ; rm -rf "$T"

T="$(mktemp -d)"; ( _mkrun "$T" src/tiny.ts feature code
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_recorded B1 )"
  _chk "$(printf '%s' "$got" | grep -c .)" "0" "AC-8 an entry with no required_roles reads empty (legacy fallback, not a guess)"
) ; rm -rf "$T"

# ---- HS-2 review findings --------------------------------------------------
# CRITICAL: a final ledger line with NO trailing newline is dropped by `while read`. That is exactly
# what a freshly-announced entry looks like (deliver.md has the orchestrator author it), and because
# record_required_roles REWRITES the ledger, the entry is deleted and rc=0 is reported. The same drop
# makes a kind:code batch resolve to an EMPTY role set — the >=1 anti-collapse floor evaporates.
T="$(mktemp -d)"; ( cd "$T" || exit 1; mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"baseline_sha":"x"}\n' > .runs/r/RUN
  { printf '{"id":"A0","kind":"code","status":"closed","commit_shas":["dead"]}\n'
    printf '{"id":"B1","kind":"code","status":"announced"}'; } > .runs/r/batches.jsonl   # no final \n
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 )"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" \
    "AC-5 unterminated last line: a code batch still requires code-reviewer (floor INVARIANT)"
  ( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r record_required_roles B1 )
  _chk "$(grep -c '"id":"B1"' .runs/r/batches.jsonl)" "1" \
    "AC-8 …and rewriting the ledger does NOT delete that entry"
  _chk "$(grep -c '"id":"A0"' .runs/r/batches.jsonl)" "1" "AC-8 …other entries survive too"
) ; rm -rf "$T"

# HIGH: an unresolvable batch must not fail OPEN. Empty is the doc-batch answer; a code batch whose
# line cannot be found must fall back to the SAFE direction (the floor), per the precedent
# select-pipeline set one workstream earlier (declared-but-unresolvable fails loud, never silent).
T="$(mktemp -d)"; ( _mkrun "$T" src/tiny.ts feature code
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch NOPE9 )"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" \
    "AC-5 an unresolvable batch id fails SAFE (still requires a reviewer), never open"
) ; rm -rf "$T"

# MEDIUM: the repo deliberately tolerates spaced ledger JSON. Writing over a spaced required_roles must
# REPLACE it (not append a duplicate key), and reading it must return roles (not the line prefix).
T="$(mktemp -d)"; ( cd "$T" || exit 1; mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"baseline_sha":"x"}\n' > .runs/r/RUN
  printf '{"id": "B1", "kind": "code", "required_roles": ["code-reviewer"], "status": "announced"}\n' > .runs/r/batches.jsonl
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_recorded B1 )"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" "AC-8 spaced-JSON required_roles reads back as roles"
  _chk "$(printf '%s' "$got" | grep -c '{')" "0" "AC-8 …not the line prefix"
  ( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r record_required_roles B1 )
  _chk "$(grep -o 'required_roles' .runs/r/batches.jsonl | grep -c .)" "1" "AC-8 …and a rewrite REPLACES it (no duplicate key)"
) ; rm -rf "$T"

# Round-2 finding: a SPACED required_roles that is the LAST key left `", "` before it, so neither
# comma-drop branch in _marker_strip_flat_key fired and the splice produced `, ,` — INVALID JSON, a
# regression versus the duplicate-key it replaced. The shape check (first/last char) cannot see it.
T="$(mktemp -d)"; ( cd "$T" || exit 1; mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"baseline_sha":"x"}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code", "required_roles": [ "stale" ]}\n' > .runs/r/batches.jsonl
  ( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r record_required_roles B1 )
  ok="$(python3 -c "import json,sys;json.loads(open('.runs/r/batches.jsonl').readline());print('ok')" 2>/dev/null)"
  _chk "$ok" "ok" "AC-8 spaced required_roles as the LAST key still rewrites to VALID JSON"
  _chk "$(grep -o 'required_roles' .runs/r/batches.jsonl | grep -c .)" "1" "AC-8 …and exactly once"
) ; rm -rf "$T"

# ---- WS-3: the close gate enforces the RECORDED set, and reports surplus ----
_crd() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" . 2>&1 ); }
_mkclose() { # $1=dir  $2=required_roles JSON array  $3...=dispatched role slugs
  local d="$1" req="$2"; shift 2
  cd "$d" || return 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"; mkdir -p src .runs/r
  printf 'b\n' > src/x.ts; git add -A; git commit -q -m work; S="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s"],"required_roles":%s}\n' "$S" "$req" > .runs/r/batches.jsonl
  : > .runs/r/dispatch.jsonl
  for r in "$@"; do printf '{"batch":"B1","subagent_type":"team-bootstrap:%s"}\n' "$r" >> .runs/r/dispatch.jsonl; done
}

T="$(mktemp -d)"; ( _mkclose "$T" '["integration-verifier","code-reviewer"]' tb-code-reviewer
  out="$(_crd "$T")"; rc=$?
  _chk "$rc" "1" "AC-6 a RECORDED role that was not dispatched fails closed"
  _chk "$(printf '%s' "$out" | grep -c 'MISSING: \[integration-verifier\]')" "1" "AC-6 …naming the missing role" ) ; rm -rf "$T"

T="$(mktemp -d)"; ( _mkclose "$T" '["integration-verifier","code-reviewer"]' tb-code-reviewer integration-verifier
  ( _crd "$T" >/dev/null ); _chk "$?" "0" "AC-6 exactly the recorded set passes" ) ; rm -rf "$T"

T="$(mktemp -d)"; ( _mkclose "$T" '["code-reviewer"]' tb-code-reviewer integration-verifier regression-guardian architecture-reviewer
  out="$(_crd "$T")"; rc=$?
  _chk "$rc" "0" "AC-7 dispatching MORE than required never blocks"
  _chk "$(printf '%s' "$out" | grep -ciE 'surplus|over-provision')" "1" "AC-7 …but the surplus is reported" ) ; rm -rf "$T"

# AC-5 INVARIANT: a reduced recorded set never sizes away the >=1 reviewer floor.
T="$(mktemp -d)"; ( _mkclose "$T" '["code-reviewer"]'
  ( _crd "$T" >/dev/null ); _chk "$?" "1" "AC-5 zero reviewer dispatches still fails, whatever the recorded set says" ) ; rm -rf "$T"

# Review HIGH: nothing wired record_required_roles, so the recorded-set branch was unreachable in a
# real run — the milestone shipped a no-op and the doctrine claimed a fact the harness never produced.
# The gate must SIZE the batch and say so even when no set was recorded (advisory), so the feature is
# live on every run; recording it is what upgrades that floor to hard.
T="$(mktemp -d)"; ( _mkclose "$T" 'null' tb-code-reviewer
  sed -i.bak 's/,"required_roles":null//' .runs/r/batches.jsonl 2>/dev/null || true
  out="$(_crd "$T")"; rc=$?
  _chk "$(printf '%s' "$out" | grep -c 'SIZED')" "1" "AC-9 the harness announces the sized set even with nothing recorded (not inert)"
  # AC-26 (milestone 020) changed what happens NEXT, not what is announced. The sized announcement is
  # still advisory in the sense that matters — it does not invent a requirement — but the per-role floor
  # it reports against now ENFORCES by default, so a run that dispatched nothing is blocked rather than
  # warned. That is the migration cost R8 names, and it is asserted here rather than left to be
  # discovered by a user. Under warn the old contract still holds exactly.
  _chk "$rc" "1" "AC-9/AC-26 the sized announcement now blocks under the shipped enforce default"
  rc_warn=0; ( cd "$T" && TEAM_BOOTSTRAP_ROLE_FLOOR=warn _crd "$T" >/dev/null 2>&1 ) || rc_warn=$?
  _chk "$rc_warn" "0" "AC-9 …and remains advisory under warn — a non-adopter's run is not blocked" ) ; rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "pipeline-sizing.test.sh: OK"; exit 0; }
echo "pipeline-sizing.test.sh: $fail failure(s)"; exit 1
