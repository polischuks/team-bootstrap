#!/usr/bin/env bash
# check-batch-suites.sh — batch-scoped EXTRA test suites at close (issue #109).
#
# verify-batch's machine close gate runs ONLY the narrow AGENTS.md `Test:` command. Three whole classes
# of check are therefore blind spots the backstop never runs — caught only by (fallible) LLM reviewers
# running them by hand, or at merge:
#   - INTEGRATION tests, which the repo's `Test:` deliberately EXCLUDES (`pytest -m "not integration"`)
#     — exactly the RLS/trigger invariants a migration exists to protect (spec-180 REG-1: an integration
#     test green-by-skip passed verify-batch and only regression-guardian, running integration by hand,
#     caught it).
#   - FRONTEND / console tests (`pnpm -r test`, vitest, a11y) not in `Test:` at all (spec-180: a real
#     WCAG contrast defect was caught by a reviewer, no gate).
#   - the repo's own CI-GUARDS — a guard-caught gap (spec-182: a missing Copilot cost-signal caught only
#     by a repo `.github` guard at MERGE, after 8 review roles missed it) never runs at close.
#
# This gate closes those, OPT-IN via AGENTS.md declarations so a repo without them is UNAFFECTED
# (warn, never block — the same posture check-tdd takes when there is no runnable `Test:`):
#
#   IntegrationTest: `<cmd>`     run when the batch trips the data/schema risk category
#   ConsoleTest:     `<cmd>`     run when the batch trips the ui risk category
#   Guards:          `a.sh b.sh` repo CI-guard scripts, run for every kind:code batch
#
# BATCH-SCOPED. The "does this batch need integration / console" decision is driven off the SAME
# per-batch classifier that already SIZES the review roles (bin/select-pipeline.sh risk categories:
# `data/schema` ⇒ migrations/schema/.sql, `ui` ⇒ frontend paths). Reusing that one classifier means
# "this batch touches migrations / frontend" has ONE definition and cannot drift from role sizing.
#
# A required suite that is DECLARED and RED → the batch is BLOCKED (this script exits 1, so verify-batch
# counts a failed gate). A category the batch trips with NO command declared → WARN (unenforceable),
# never a block. Not a code batch / nothing in flight / no declaration and no tripped category ⇒ no-op.
#
# It does NOT touch stamp_batch_closed, the commit_shas filter, or the gate ordering in verify-batch —
# it is a self-contained extra step verify-batch invokes. It READS delivery-lib.sh / select-pipeline.sh
# classifier helpers; it modifies neither.
#
# Usage: bin/check-batch-suites.sh [project-dir]   (default: current dir)
# Exit:  0 all required suites green (or nothing to run) · 1 a required suite failed · 64 bad usage
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# --- helpers (LOCAL: read the contract, never modify delivery-lib) --------------------------------
# _labeled_cmd LABEL [DOC] → the backticked command on a `LABEL:` line in AGENTS.md/CLAUDE.md, or empty
# (N/A|none ⇒ empty). Mirrors delivery-lib's _test_cmd exactly, parameterised on the label so the same
# "first backticked token on the Label: line" contract governs Test:, IntegrationTest: and ConsoleTest:.
_labeled_cmd() {
  local label="$1" doc="${2:-}" f c
  if [ -z "$doc" ]; then for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done; fi
  [ -n "$doc" ] && [ -f "$doc" ] || return 0
  c="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*${label}:" "$doc" 2>/dev/null | head -1 \
       | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  case "$c" in N/A|n/a|None|none) c="" ;; esac
  printf '%s' "$c"
}

# _labeled_list LABEL [DOC] → the space-separated tokens on a `LABEL:` line (backticks stripped, comma
# OR space separated). Mirrors delivery-lib's read_test_globs; used for the `Guards:` script list.
_labeled_list() {
  local label="$1" doc="${2:-}" f rest
  if [ -z "$doc" ]; then for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done; fi
  [ -n "$doc" ] && [ -f "$doc" ] || return 0
  rest="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*${label}:" "$doc" 2>/dev/null | head -1 | sed -E 's/^[^:]*://')"
  [ -n "$rest" ] || return 0
  case "$rest" in *N/A*|*n/a*|*None*|*none*) : ;; esac
  printf '%s' "$rest" | tr -d '`' | tr ',' ' ' | xargs 2>/dev/null || true
}

# batch_risk_categories BATCH_ID → the risk-category tokens this batch's diff trips, from the SAME
# classifier that sizes the review roles (select-pipeline.sh's own `(reasons: …)` line). Parsed exactly
# as delivery-lib's profile_roles_for_batch parses it, so composition and this gate cannot disagree
# about what the diff contains. Empty on any failure — the fail-SAFE direction is "no extra suite
# required", which never turns a real gap into a silent block; a declared-but-unresolvable batch id is
# already failed LOUD by select-pipeline itself.
batch_risk_categories() {
  local bid="$1"
  [ -n "$bid" ] || return 0
  "$here/select-pipeline.sh" --batch "$bid" 2>/dev/null \
    | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | tail -1
}

# run_cmd DESC CMD → run CMD via bash -c in the project dir; 0 green, non-zero red. DESC labels the log.
run_cmd() {
  local desc="$1" cmd="$2"
  echo "check-batch-suites: → $desc: $cmd" >&2
  if bash -c "$cmd"; then
    echo "check-batch-suites:   OK — $desc" >&2; return 0
  fi
  echo "check-batch-suites:   FAILED — $desc" >&2; return 1
}

# gate_run — the gate body, factored out so the --self-test can drive it over fixtures. Reads the
# in-flight batch from the ledger, classifies it, and runs the extra suites its paths and the repo's
# declarations require. Returns 1 iff a DECLARED required suite (or guard) is red.
gate_run() {
  local ib kind bid cats fails=0
  ib="$(inflight_batch)"
  # Nothing in flight (no ledger / no run) → not a team-bootstrap code close. Clean no-op.
  [ -n "$ib" ] || { echo "check-batch-suites: no in-flight batch — nothing to gate." >&2; return 0; }
  kind="$(field_str "$ib" kind)"
  # A doc batch earns no code review and ships no behaviour to integration/console-test → no-op.
  [ "$kind" = "code" ] || { echo "check-batch-suites: in-flight batch is kind:'${kind:-?}', not code — no extra suites." >&2; return 0; }
  bid="$(field_str "$ib" id)"
  cats="$(batch_risk_categories "$bid")"

  # 1) INTEGRATION — required when the batch trips data/schema (migrations, schema, .sql, models). The
  #    repo's `Test:` runs `-m "not integration"`; a declared IntegrationTest: is the command that does
  #    NOT exclude it, so the migration's own invariants are machine-checked at close.
  case " $cats " in
    *" data/schema "*)
      local icmd; icmd="$(_labeled_cmd IntegrationTest)"
      if [ -n "$icmd" ]; then
        run_cmd "integration suite (data/schema batch)" "$icmd" || fails=$((fails + 1))
      else
        echo "check-batch-suites: WARN — batch touches data/schema (migrations/schema) but AGENTS.md declares no IntegrationTest:; the migration's integration invariants are NOT machine-checked at close (unenforceable, not blocking). Declare 'IntegrationTest: \`<cmd>\`' to enforce. (#109)" >&2
      fi
      ;;
  esac

  # 2) CONSOLE — required when the batch trips ui (frontend paths). `Test:` does not run vitest / a11y;
  #    a declared ConsoleTest: is the frontend suite the backstop otherwise never runs.
  case " $cats " in
    *" ui "*)
      local ccmd; ccmd="$(_labeled_cmd ConsoleTest)"
      if [ -n "$ccmd" ]; then
        run_cmd "console suite (frontend batch)" "$ccmd" || fails=$((fails + 1))
      else
        echo "check-batch-suites: WARN — batch touches frontend/ui paths but AGENTS.md declares no ConsoleTest:; the frontend suite is NOT machine-checked at close (unenforceable, not blocking). Declare 'ConsoleTest: \`<cmd>\`' to enforce. (#109)" >&2
      fi
      ;;
  esac

  # 3) GUARDS — the repo's own CI-guards, run for every kind:code batch so a guard-caught gap fails at
  #    CLOSE, not at merge. A declared-but-missing guard file WARNS (a config error, not a code gap —
  #    blocking on it would punish the wrong thing); a present guard that exits non-zero BLOCKS.
  local guards g
  guards="$(_labeled_list Guards)"
  for g in $guards; do
    [ -n "$g" ] || continue
    if [ -f "$g" ]; then
      run_cmd "repo CI-guard $g" "bash '$g'" || fails=$((fails + 1))
    else
      echo "check-batch-suites: WARN — declared Guard '$g' not found; cannot run it (unenforceable, not blocking). Fix the Guards: path in AGENTS.md. (#109)" >&2
    fi
  done

  [ "$fails" -eq 0 ] && return 0
  echo "check-batch-suites: $fails required suite(s)/guard(s) FAILED — batch cannot close. Fix and re-run. (#109)" >&2
  return 1
}

# --- self-test ------------------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  # shellcheck source=bin/delivery-lib.sh
  . "$here/delivery-lib.sh"
  fail=0
  _mkrepo() { local T; T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email t@t && git config user.name t && echo base > app.py && git add . && git commit -qm c0 ) >/dev/null 2>&1; printf '%s' "$T"; }
  _ledger() { mkdir -p "$1/.runs/r"; printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$2" > "$1/.runs/r/RUN"; printf '{"id":"B1","kind":"%s","status":"announced"}\n' "${3:-code}" > "$1/.runs/r/batches.jsonl"; }
  _run() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r bash "$here/check-batch-suites.sh" . >/dev/null 2>&1; echo $? ); }

  # data/schema batch + RED IntegrationTest: → blocks (exit 1).
  T="$(_mkrepo)"; B="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && mkdir -p db/migrations && echo x > db/migrations/1.sql \
    && printf '# A\n- Test: `true`\n- IntegrationTest: `false`\n' > AGENTS.md && git add . && git commit -qm m ) >/dev/null 2>&1
  _ledger "$T" "$B"
  [ "$(_run "$T")" = 1 ] && echo "  PASS migrations + RED IntegrationTest → blocks" || { echo "  FAIL migrations + RED IntegrationTest not blocked" >&2; fail=$((fail+1)); }
  rm -rf "$T"

  # data/schema batch + NO IntegrationTest: → warns, not blocks (exit 0).
  T="$(_mkrepo)"; B="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && mkdir -p db/migrations && echo x > db/migrations/1.sql \
    && printf '# A\n- Test: `true`\n' > AGENTS.md && git add . && git commit -qm m ) >/dev/null 2>&1
  _ledger "$T" "$B"
  [ "$(_run "$T")" = 0 ] && echo "  PASS migrations + absent IntegrationTest → warns, not blocks" || { echo "  FAIL migrations + absent IntegrationTest blocked" >&2; fail=$((fail+1)); }
  rm -rf "$T"

  # ui batch + RED ConsoleTest: → blocks (exit 1).
  T="$(_mkrepo)"; B="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && mkdir -p web/components && echo 'export const A=1' > web/components/App.tsx \
    && printf '# A\n- Test: `true`\n- ConsoleTest: `false`\n' > AGENTS.md && git add . && git commit -qm u ) >/dev/null 2>&1
  _ledger "$T" "$B"
  [ "$(_run "$T")" = 1 ] && echo "  PASS frontend + RED ConsoleTest → blocks" || { echo "  FAIL frontend + RED ConsoleTest not blocked" >&2; fail=$((fail+1)); }
  rm -rf "$T"

  # failing Guards: on any code batch → blocks (exit 1).
  T="$(_mkrepo)"; B="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && echo more >> app.py && mkdir -p .github && printf '#!/usr/bin/env bash\nexit 1\n' > .github/g.sh \
    && printf '# A\n- Test: `true`\n- Guards: `.github/g.sh`\n' > AGENTS.md && git add . && git commit -qm c ) >/dev/null 2>&1
  _ledger "$T" "$B"
  [ "$(_run "$T")" = 1 ] && echo "  PASS failing Guard → blocks" || { echo "  FAIL failing Guard not blocked" >&2; fail=$((fail+1)); }
  rm -rf "$T"

  # neutral code batch (no risk path, no guards) → unaffected (exit 0), even with a RED IntegrationTest:.
  T="$(_mkrepo)"; B="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && echo more >> app.py \
    && printf '# A\n- Test: `true`\n- IntegrationTest: `false`\n' > AGENTS.md && git add . && git commit -qm c ) >/dev/null 2>&1
  _ledger "$T" "$B"
  [ "$(_run "$T")" = 0 ] && echo "  PASS neutral batch → unaffected (batch-scoped)" || { echo "  FAIL neutral batch blocked" >&2; fail=$((fail+1)); }
  rm -rf "$T"

  # doc batch → unaffected (exit 0).
  T="$(_mkrepo)"; B="$(cd "$T" && git rev-parse --short HEAD)"
  ( cd "$T" && mkdir -p db/migrations && echo x > db/migrations/1.sql \
    && printf '# A\n- Test: `true`\n- IntegrationTest: `false`\n' > AGENTS.md && git add . && git commit -qm m ) >/dev/null 2>&1
  _ledger "$T" "$B" doc
  [ "$(_run "$T")" = 0 ] && echo "  PASS doc batch → unaffected" || { echo "  FAIL doc batch blocked" >&2; fail=$((fail+1)); }
  rm -rf "$T"

  if [ "$fail" -eq 0 ]; then echo "check-batch-suites --self-test: OK"; exit 0; fi
  echo "check-batch-suites --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- gate ------------------------------------------------------------------------------------------
root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-batch-suites: bad dir '$root'" >&2; exit 64; }
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"
gate_run
