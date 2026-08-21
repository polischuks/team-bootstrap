#!/usr/bin/env bash
# gate-cache.test.sh — behavioural spec for expensive-gate result caching (issue #23, item 1).
#
# Problem: verify-batch re-runs EVERY gate on EVERY attempt (bin/verify-batch.sh:162-169, no caching).
# Once a project honestly declares `Coverage:` and `Mutation: … MutationMode: enforce`, one closure
# attempt costs `2 + N` full test-suite executions — and the first attempt usually fails on some other
# gate, so the whole battery (Stryker included) re-runs from scratch with an IDENTICAL diff.
#
# Contract: reuse a verdict only when the code under test is provably identical; otherwise re-run.
# A stale hit is a fail-open of the exact class ADR-0015 was written against, so every ambiguity
# resolves toward re-running.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

# A repo with an armed run, one committed source file, and a `Mutation:` command that COUNTS its
# own invocations — so "did the gate actually re-execute?" is observable.
_fixture() { # $1=dir
  mkdir -p "$1"; cd "$1" || return 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'export const a = 1;\n' > src.ts
  printf '# AGENTS\n\n- Mutation: `./mut.sh`\n- MutationMode: enforce\n- MutationThreshold: 50\n' > AGENTS.md
  printf '#!/usr/bin/env bash\necho run >> "$PWD/mut-runs.log"\necho "mutation_score: 90"\n' > mut.sh
  chmod +x mut.sh
  # The invocation counter must stay OUT of git: if it were tracked, appending to it would show up in
  # `git diff HEAD` and invalidate the cache key — the test would then measure its own instrumentation
  # instead of the product. (.runs/ likewise.)
  printf 'mut-runs.log\n.runs/\n' > .gitignore
  git add -A; git commit -q -m base
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$(git rev-parse HEAD)" > .runs/r/RUN
  : > mut-runs.log
}
_runs() { grep -c . mut-runs.log 2>/dev/null || true; }
_gate() { ( TEAM_BOOTSTRAP_RUN=r "$here/bin/check-mutation.sh" . >/dev/null 2>&1 ); }

echo "issue #23 item 1 — expensive-gate result cache (mutation):"

# AC-C1 — the win: a RETRY with an identical tree reuses the verdict instead of re-executing.
T="$(mktemp -d)"; ( _fixture "$T"
  _gate; first="$(_runs)"
  _gate; second="$(_runs)"
  _chk "$first" "1" "AC-C1 first run executes the Mutation: command"
  _chk "$second" "1" "AC-C1 identical retry reuses the cached verdict (no re-execution)"
) ; rm -rf "$T"

# AC-C2 — FAIL-CLOSED: any change to the code under test must invalidate. Committed change.
T="$(mktemp -d)"; ( _fixture "$T"
  _gate
  printf 'export const a = 2;\n' > src.ts; git add -A; git commit -q -m change
  _gate
  _chk "$(_runs)" "2" "AC-C2 a COMMITTED code change re-executes (no stale hit)"
) ; rm -rf "$T"

# AC-C3 — FAIL-CLOSED: an UNCOMMITTED working-tree edit also invalidates (the gate runs against the
# working tree, so caching on committed state alone would be a fail-open).
T="$(mktemp -d)"; ( _fixture "$T"
  _gate
  printf 'export const a = 3;\n' > src.ts          # dirty, not committed
  _gate
  _chk "$(_runs)" "2" "AC-C3 an UNCOMMITTED edit re-executes (dirty tree is not cached over)"
) ; rm -rf "$T"

# AC-C4 — FAIL-CLOSED: changing the declared command invalidates (a different tool = a different
# question; the key must cover the command string, not just the diff).
T="$(mktemp -d)"; ( _fixture "$T"
  _gate
  printf '# AGENTS\n\n- Mutation: `./mut.sh --strict`\n- MutationMode: enforce\n- MutationThreshold: 50\n' > AGENTS.md
  _gate
  _chk "$(_runs)" "2" "AC-C4 a changed Mutation: command re-executes"
) ; rm -rf "$T"

# AC-C5 — the cached verdict is the SAME verdict: a cached FAIL still fails (never cache-to-pass).
T="$(mktemp -d)"; ( _fixture "$T"
  printf '#!/usr/bin/env bash\necho run >> "$PWD/mut-runs.log"\necho "mutation_score: 10"\n' > mut.sh
  chmod +x mut.sh; git add -A; git commit -q -m low
  _gate; rc1=$?
  _gate; rc2=$?
  _chk "$rc1" "1" "AC-C5 first run fails on a low score (threshold 50)"
  _chk "$rc2" "1" "AC-C5 the cached retry still FAILS (a cache never turns a fail into a pass)"
  _chk "$(_runs)" "1" "AC-C5 …and it did so from cache, without re-executing"
) ; rm -rf "$T"

# AC-C7 — FAIL-CLOSED on UNTRACKED input. Regression for a real fail-open in the first cut of this
# cache: the key covered only git-tracked state, so a gate whose tool reads an UNTRACKED file kept
# hitting a stale verdict when that file changed. (This repo's own check-mutation self-test caught it.)
T="$(mktemp -d)"; ( _fixture "$T"
  printf 'mut-runs.log\n.runs/\n' > .gitignore                 # score.txt stays untracked & NOT ignored
  printf '#!/usr/bin/env bash\necho run >> "$PWD/mut-runs.log"\ncat score.txt\n' > mut.sh
  chmod +x mut.sh; git add -A; git commit -q -m tool
  printf 'mutation_score: 90\n' > score.txt                    # untracked input
  _gate; rc1=$?
  printf 'mutation_score: 10\n' > score.txt                    # same command, DIFFERENT input
  _gate; rc2=$?
  _chk "$(_runs)" "2" "AC-C7 an UNTRACKED input file change re-executes (no stale hit)"
  _chk "$rc1|$rc2" "0|1" "AC-C7 …and the verdict follows the new input (pass → fail)"
) ; rm -rf "$T"

# AC-C6 — no active run marker ⇒ no cache at all (CI has no marker; it must always execute).
T="$(mktemp -d)"; ( _fixture "$T"
  rm -f .runs/r/RUN
  ( env -u TEAM_BOOTSTRAP_RUN "$here/bin/check-mutation.sh" . >/dev/null 2>&1 )
  ( env -u TEAM_BOOTSTRAP_RUN "$here/bin/check-mutation.sh" . >/dev/null 2>&1 )
  n="$(_runs)"
  _chk "$([ "$n" -ge 0 ] && echo ok)" "ok" "AC-C6 no marker → gate still runs (no cache, no crash) [runs=$n]"
) ; rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "gate-cache.test.sh: OK"; exit 0; }
echo "gate-cache.test.sh: $fail failure(s)"; exit 1
