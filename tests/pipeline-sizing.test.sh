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
T="$(mktemp -d)"; ( cd "$T"; _repo
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B3 2>&1)"
  _chk "$(printf '%s' "$out" | grep -ciE 'RECOMMENDED pipeline: single-thread')" "1" \
    "AC-2 --batch sizes from the BATCH's window (tiny), not the run's (risky migration)"
) ; rm -rf "$T"

# AC-3: a risk touch inside the batch lifts it to full regardless of how small it is
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
T="$(mktemp -d)"; ( cd "$T"
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
  cd "$1"; git init -q; git config user.email a@b.c; git config user.name t
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
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
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

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "pipeline-sizing.test.sh: OK"; exit 0; }
echo "pipeline-sizing.test.sh: $fail failure(s)"; exit 1
