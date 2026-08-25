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

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "pipeline-sizing.test.sh: OK"; exit 0; }
echo "pipeline-sizing.test.sh: $fail failure(s)"; exit 1
