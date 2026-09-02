#!/usr/bin/env bash
# batch-suite-gates.test.sh — the batch-scoped extra-suite close gate (issue #109).
#
# verify-batch's machine close gate runs ONLY the narrow AGENTS.md `Test:` command, so integration
# tests (excluded by `-m "not integration"`), frontend/console tests, and repo CI-guards are blind
# spots — caught only by fallible LLM reviewers or at merge. bin/check-batch-suites.sh closes those,
# OPT-IN via AGENTS.md `IntegrationTest:`/`ConsoleTest:`/`Guards:` declarations, BATCH-SCOPED off the
# same per-batch classifier (select-pipeline risk categories) that already sizes the review roles.
#
# This is the RED-first artifact (#109 discipline): it fails before bin/check-batch-suites.sh exists.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$here/.." && pwd)/bin"
GATE="$BIN/check-batch-suites.sh"
fail=0

# mkrepo → a fresh git repo with a baseline commit; prints its path. Sets $BASE (baseline sha).
mkrepo() {
  local T; T="$(mktemp -d)"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t \
    && echo base > app.py && git add . && git commit -qm c0 ) >/dev/null 2>&1
  printf '%s' "$T"
}
base_of() { ( cd "$1" && git rev-parse --short HEAD ); }

# ledger RUN_DIR BASELINE — write a RUN marker + a single announced kind:code batch B1.
ledger() {
  local dir="$1" b="$2"
  mkdir -p "$dir/.runs/r"
  printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$b" > "$dir/.runs/r/RUN"
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$dir/.runs/r/batches.jsonl"
}

run_gate() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r bash "$GATE" . >/dev/null 2>&1; echo $? ); }
ok()   { echo "  PASS $1"; }
bad()  { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------------------------------
# 1. migrations/ + declared IntegrationTest: that is RED  →  the gate BLOCKS (exit 1).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && mkdir -p db/migrations && echo 'select 1' > db/migrations/001.sql \
  && printf '# AGENTS\n\n- Test: `true`\n- IntegrationTest: `false`\n' > AGENTS.md \
  && git add . && git commit -qm mig ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 1 ] && ok "migrations batch + RED IntegrationTest → blocks (exit 1)" \
             || bad "migrations + RED IntegrationTest: exit=$r want 1"
rm -rf "$T"

# 2. migrations/ + declared IntegrationTest: that is GREEN  →  passes (exit 0).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && mkdir -p db/migrations && echo 'select 1' > db/migrations/001.sql \
  && printf '# AGENTS\n\n- Test: `true`\n- IntegrationTest: `true`\n' > AGENTS.md \
  && git add . && git commit -qm mig ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 0 ] && ok "migrations batch + GREEN IntegrationTest → passes (exit 0)" \
             || bad "migrations + GREEN IntegrationTest: exit=$r want 0"
rm -rf "$T"

# 3. migrations/ + NO IntegrationTest: declared  →  WARNS, does not block (exit 0).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && mkdir -p db/migrations && echo 'select 1' > db/migrations/001.sql \
  && printf '# AGENTS\n\n- Test: `true`\n' > AGENTS.md \
  && git add . && git commit -qm mig ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 0 ] && ok "migrations batch + no IntegrationTest declared → warns, not blocks (exit 0)" \
             || bad "migrations + absent IntegrationTest: exit=$r want 0 (must warn, not block)"
rm -rf "$T"

# 4. frontend paths + declared ConsoleTest: that is RED  →  the gate BLOCKS (exit 1).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && mkdir -p web/components && echo 'export const A = 1' > web/components/App.tsx \
  && printf '# AGENTS\n\n- Test: `true`\n- ConsoleTest: `false`\n' > AGENTS.md \
  && git add . && git commit -qm ui ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 1 ] && ok "frontend batch + RED ConsoleTest → blocks (exit 1)" \
             || bad "frontend + RED ConsoleTest: exit=$r want 1"
rm -rf "$T"

# 5. frontend paths + NO ConsoleTest: declared  →  WARNS, does not block (exit 0).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && mkdir -p web/components && echo 'export const A = 1' > web/components/App.tsx \
  && printf '# AGENTS\n\n- Test: `true`\n' > AGENTS.md \
  && git add . && git commit -qm ui ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 0 ] && ok "frontend batch + no ConsoleTest declared → warns, not blocks (exit 0)" \
             || bad "frontend + absent ConsoleTest: exit=$r want 0 (must warn, not block)"
rm -rf "$T"

# 6. declared Guards: script that FAILS  →  batch BLOCKED (exit 1), on ANY code batch (no risk path).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && echo 'more' >> app.py && mkdir -p .github \
  && printf '#!/usr/bin/env bash\nexit 1\n' > .github/guard.sh && chmod +x .github/guard.sh \
  && printf '# AGENTS\n\n- Test: `true`\n- Guards: `.github/guard.sh`\n' > AGENTS.md \
  && git add . && git commit -qm code ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 1 ] && ok "failing Guards: script → batch blocked (exit 1)" \
             || bad "failing Guards: exit=$r want 1"
rm -rf "$T"

# 7. declared Guards: script that PASSES  →  passes (exit 0).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && echo 'more' >> app.py && mkdir -p .github \
  && printf '#!/usr/bin/env bash\nexit 0\n' > .github/guard.sh && chmod +x .github/guard.sh \
  && printf '# AGENTS\n\n- Test: `true`\n- Guards: `.github/guard.sh`\n' > AGENTS.md \
  && git add . && git commit -qm code ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 0 ] && ok "passing Guards: script → passes (exit 0)" \
             || bad "passing Guards: exit=$r want 0"
rm -rf "$T"

# 8. a batch that touches NEITHER migrations NOR frontend, with NO Guards:  →  unaffected (exit 0),
#    even though AGENTS.md declares a RED IntegrationTest: (it must not fire on a non-migration batch).
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && echo 'more' >> app.py \
  && printf '# AGENTS\n\n- Test: `true`\n- IntegrationTest: `false`\n- ConsoleTest: `false`\n' > AGENTS.md \
  && git add . && git commit -qm code ) >/dev/null 2>&1
ledger "$T" "$B"
r="$(run_gate "$T")"
[ "$r" = 0 ] && ok "neutral batch (no migrations/frontend, no guards) → unaffected (exit 0)" \
             || bad "neutral batch: exit=$r want 0 (extra suites must be batch-scoped)"
rm -rf "$T"

# 9. a kind:doc batch  →  unaffected (exit 0), even with a RED IntegrationTest: and a migration touch.
T="$(mkrepo)"; B="$(base_of "$T")"
( cd "$T" && mkdir -p db/migrations && echo 'select 1' > db/migrations/001.sql \
  && printf '# AGENTS\n\n- Test: `true`\n- IntegrationTest: `false`\n' > AGENTS.md \
  && git add . && git commit -qm mig ) >/dev/null 2>&1
mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$B" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"doc","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
r="$(run_gate "$T")"
[ "$r" = 0 ] && ok "doc batch → unaffected (exit 0)" \
             || bad "doc batch: exit=$r want 0"
rm -rf "$T"

# 10. no active run at all (no ledger)  →  clean no-op (exit 0): a non-team-bootstrap session.
T="$(mkrepo)"
r="$( cd "$T" && bash "$GATE" . >/dev/null 2>&1; echo $? )"
[ "$r" = 0 ] && ok "no active run → clean no-op (exit 0)" \
             || bad "no run: exit=$r want 0"
rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "batch-suite-gates.test: OK"; exit 0; fi
echo "batch-suite-gates.test: $fail case(s) FAILED" >&2; exit 1
