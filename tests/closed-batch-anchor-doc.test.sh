#!/usr/bin/env bash
# closed-batch-anchor-doc.test.sh — issues #93, #97, #95.
#
# #93 — stamp_batch_closed swept a batch's commit_shas over current_batch_base()..HEAD, excluding only
#   recorded RED commits. For the FIRST code batch current_batch_base is the run baseline, so a Phase-A
#   `docs(spec-…)` commit that landed after baseline and before the batch's code leaked into commit_shas
#   as the OLDEST entry. check-tdd's closed path anchors on the oldest commit_sha, and the batch's red
#   (committed AFTER the doc commit) is not its ancestor → a LATER batch's re-verification FAILED a batch
#   that passed its own close. Fix: exclude doc-only commits from commit_shas → the anchor is the oldest
#   CODE commit, and code_delta is measured over the batch's own code window.
#
# #97 — closing a kind:doc batch re-ran the full code Test: suite (via check-tdd's HEAD-green step) even
#   though a doc batch changes no code. Fix: check-tdd skips the expensive suite when the batch being
#   closed is kind:doc (the code was proven green at the last code batch's close).
#
# #95 — verify-batch must print the long-timeout/background advice in its OWN output at the start of a run.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$here/bin"
fail=0
_chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }

# stamp the in-flight batch closed using the REAL stamp_batch_closed from verify-batch.sh.
_stamp() { (
  cd "$1" || exit 1
  export TEAM_BOOTSTRAP_RUN=r
  # shellcheck disable=SC1090
  . "$BIN/delivery-lib.sh"
  here="$BIN"
  eval "$(sed -n '/^stamp_batch_closed() {/,/^}/p' "$BIN/verify-batch.sh")"
  stamp_batch_closed
) 2>/dev/null; }

echo "#93 — a Phase-A doc commit inside the first code batch's window is excluded from commit_shas:"
T="$(mktemp -d)"
(
  cd "$T" || exit 1
  git init -q && git config user.email t@t && git config user.name t
  printf '# AGENTS\n\n- Test: `test -f .green`\n' > AGENTS.md && : > .green
  git add . && git commit -qm baseline
) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
# Phase-A doc commit (spec.md) after baseline, before the batch's code.
( cd "$T" && mkdir -p specs/178 && printf '# spec\n' > specs/178/spec.md && git add . && git commit -qm 'docs(spec-178): spec' ) >/dev/null 2>&1
doc="$(cd "$T" && git rev-parse --short HEAD)"
# B1 red commit (failing test), then B1 code commit.
( cd "$T" && printf 'x\n' > f1_test.sh && git add f1_test.sh && git commit -qm 'redA (B1 failing test)' ) >/dev/null 2>&1
red="$(cd "$T" && git rev-parse --short HEAD)"
( cd "$T" && printf '1\n' > f1.sh && git add f1.sh && git commit -qm 'B1 code' ) >/dev/null 2>&1
code="$(cd "$T" && git rev-parse --short HEAD)"
mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
printf '{"batch":"B1","red_sha":"%s","observed":"red"}\n' "$red" > "$T/.runs/r/tdd.jsonl"
_stamp "$T"
shas="$(grep -oE '"commit_shas":\[[^]]*\]' "$T/.runs/r/batches.jsonl")"
_chk "$(printf '%s' "$shas" | grep -c "$code")" 1 "the batch's CODE commit is in commit_shas"
_chk "$(printf '%s' "$shas" | grep -c "$doc")" 0 "the Phase-A doc commit is NOT in commit_shas (#93)"

echo "#93 — a later batch's re-verification of the closed batch passes (doc is never the tdd anchor):"
# add an in-flight B2 so check-tdd exercises B1's CLOSED path (anchor = oldest commit_sha of B1).
printf '{"id":"B2","kind":"code","status":"announced"}\n' >> "$T/.runs/r/batches.jsonl"
out="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$BIN/check-tdd.sh" . 2>&1 )"
_chk "$(printf '%s' "$out" | grep -c "code batch 'B1' has neither a red step")" 0 \
  "closed batch B1 is NOT failed on the doc anchor when B2 re-verifies (#93)"
rm -rf "$T"

echo "#97 — closing a kind:doc batch does NOT run the full code Test: suite:"
D="$(mktemp -d)"
(
  cd "$D" || exit 1
  git init -q && git config user.email t@t && git config user.name t
  # a Test: command that COUNTS its own runs into a gitignored log
  printf '#!/usr/bin/env bash\necho run >> "$PWD/suite-runs.log"\ntest -f .green\n' > suite.sh && chmod +x suite.sh
  printf '# AGENTS\n\n- Test: `./suite.sh`\n' > AGENTS.md
  printf 'suite-runs.log\n.runs/\n' > .gitignore
  git add -A && git commit -qm base
) >/dev/null 2>&1
dbase="$(cd "$D" && git rev-parse HEAD)"
( cd "$D" && echo t > f1_test.sh && git add f1_test.sh && git commit -qm 'redA (B1 failing test)' ) >/dev/null 2>&1
dred="$(cd "$D" && git rev-parse --short HEAD)"
( cd "$D" && echo 1 > f1 && : > .green && git add -A && git commit -qm 'B1 code (green)' ) >/dev/null 2>&1
dc1="$(cd "$D" && git rev-parse --short HEAD)"
( cd "$D" && printf 'docs\n' > README.md && git add README.md && git commit -qm 'B2 docs' ) >/dev/null 2>&1
mkdir -p "$D/.runs/r"
printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$dbase" > "$D/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":5}\n' "$dc1" > "$D/.runs/r/batches.jsonl"
printf '{"id":"B2","kind":"doc","status":"announced"}\n' >> "$D/.runs/r/batches.jsonl"
printf '{"batch":"B1","red_sha":"%s","observed":"red"}\n' "$dred" > "$D/.runs/r/tdd.jsonl"
: > "$D/suite-runs.log"
rc="$( cd "$D" && TEAM_BOOTSTRAP_RUN=r "$BIN/check-tdd.sh" . >/dev/null 2>&1; echo $? )"
runs="$(grep -c . "$D/suite-runs.log" 2>/dev/null)"; runs="${runs:-0}"
_chk "$rc" 0 "check-tdd passes when the in-flight batch is kind:doc"
_chk "$runs" 0 "the full Test: suite did NOT run for the doc-batch close (#97)"
rm -rf "$D"

echo "#95 — verify-batch prints the timeout/background advice at the start of a run:"
V="$(mktemp -d)"
( cd "$V" && git init -q && git config user.email t@t && git config user.name t
  printf '# AGENTS\n' > AGENTS.md && git add . && git commit -qm base ) >/dev/null 2>&1
adv="$( cd "$V" && "$BIN/verify-batch.sh" . 2>&1 | grep -ciE 'long timeout|background' )"
_chk "$([ "${adv:-0}" -ge 1 ] && echo ok)" ok "verify-batch names the long-timeout/background remedy (#95)"
rm -rf "$V"

if [ "$fail" -eq 0 ]; then echo "closed-batch-anchor-doc.test.sh: OK"; exit 0; fi
echo "closed-batch-anchor-doc.test.sh: $fail case(s) FAILED" >&2; exit 1
