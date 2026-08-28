#!/usr/bin/env bash
# run-tests-selection.test.sh — selective mode (#76) and input-fingerprint cache (#77).
#
# Black-box spec over bin/run-tests.sh. It drives the runner on synthetic no-op fixtures (no real
# heavy members, so it stays cheap) and proves the two properties the repo has been burned on:
#
#   SELECTION (#76): --changed / <glob> run a SUBSET of the SAME member set a full run computes, via
#   the SAME per-member code path — so a selected member reaches the SAME verdict it would in a full
#   run. The false-PASS risk is UNDER-selection (skipping a member a change actually affected) and a
#   selected failure being hidden; both are asserted against directly.
#
#   CACHE (#77): a member is skipped only when the fingerprint of its INPUTS (its own file + the files
#   it sources/invokes) matches its last GREEN result. Editing the member OR any input re-runs it; a
#   red member is never cached; --no-cache ignores the cache entirely. A cached green can NEVER mask a
#   real failure.
#
# Named run-tests-selection.test.sh (not inside run-tests.test.sh, which the sweep excludes) so it is
# a swept member — the full suite (the honest CI gate) verifies these guards on every run.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
R="$here/bin/run-tests.sh"
fail=0
_chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 — got '$1' want '$2'" >&2; fail=$((fail + 1)); fi; }

# A member appends its name to $SENTINEL each time it EXECUTES, so a run-count of a member name tells
# us whether it ran or was skipped/deselected. count NAME → how many times NAME executed so far.
count() { grep -c "^$1\$" "$SENTINEL" 2>/dev/null | tr -d ' '; }

# mkfix DIR — build a fresh synthetic repo of fast members:
#   bin/alpha.sh   self-test member, green, references nothing
#   bin/beta.sh    self-test member, green, SOURCES bin/lib.sh   (fingerprint must include lib.sh)
#   bin/lib.sh     a sourced library, NOT itself a self-test member
#   tests/gamma.test.sh  test member, green, INVOKES bin/alpha.sh (references alpha)
#   tests/broken.test.sh test member, RED (exit 1)
mkfix() {
  local d="$1"; mkdir -p "$d/bin" "$d/tests"
  # alpha/beta count ONLY their --self-test (member) invocation, so a plain call from gamma at
  # runtime does not inflate the run-count we assert on.
  cat > "$d/bin/alpha.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --self-test) [ -n "${SENTINEL:-}" ] && echo alpha >> "$SENTINEL"; exit 0;; esac
SH
  cat > "$d/bin/lib.sh" <<'SH'
#!/usr/bin/env bash
lib_val() { echo ok; }
SH
  cat > "$d/bin/beta.sh" <<'SH'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
case "${1:-}" in --self-test) [ -n "${SENTINEL:-}" ] && echo beta >> "$SENTINEL"; exit 0;; esac
SH
  cat > "$d/tests/gamma.test.sh" <<'SH'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${SENTINEL:-}" ] && echo gamma >> "$SENTINEL"
# references bin/alpha.sh — a change to alpha must re-select gamma
bash "$here/bin/alpha.sh" >/dev/null 2>&1
exit 0
SH
  cat > "$d/tests/broken.test.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${SENTINEL:-}" ] && echo broken >> "$SENTINEL"
exit 1
SH
  : > "$d/sentinel"
}

# ============================================================================================
# SELECTION (#76)
# ============================================================================================

# --- 1. full run is the baseline: every member runs, the red one makes it non-zero -----------
T="$(mktemp -d)"; mkfix "$T"; export SENTINEL="$T/sentinel"
bash "$R" "$T" --jobs 1 >/dev/null 2>&1; _chk "$?" 1 "full run is red (broken member present)"
_chk "$(count alpha)"  1 "full run: alpha ran"
_chk "$(count beta)"   1 "full run: beta ran"
_chk "$(count gamma)"  1 "full run: gamma ran"
_chk "$(count broken)" 1 "full run: broken ran"

# --- 2. <glob> runs ONLY matching members (by member name/stem), nothing else ----------------
: > "$SENTINEL"
bash "$R" "$T" alpha --jobs 1 >/dev/null 2>&1; _chk "$?" 0 "glob 'alpha' → 0 (only the green alpha selected)"
_chk "$(count alpha)"  1 "glob 'alpha': alpha ran"
_chk "$(count beta)"   0 "glob 'alpha': beta did NOT run"
_chk "$(count gamma)"  0 "glob 'alpha': gamma did NOT run"
_chk "$(count broken)" 0 "glob 'alpha': broken did NOT run"

# --- 3. --changed maps a changed bin/X.sh to X's self-test AND every test referencing X -------
: > "$SENTINEL"
TB_CHANGED_FILES="bin/alpha.sh" bash "$R" "$T" --changed --jobs 1 >/dev/null 2>&1
_chk "$?" 0 "--changed bin/alpha.sh → 0"
_chk "$(count alpha)"  1 "--changed alpha: alpha self-test ran"
_chk "$(count gamma)"  1 "--changed alpha: gamma (references alpha) ran"
_chk "$(count beta)"   0 "--changed alpha: beta did NOT run"
_chk "$(count broken)" 0 "--changed alpha: broken did NOT run"

# --- 4. --changed maps a changed tests/Y.test.sh to Y itself ---------------------------------
: > "$SENTINEL"
TB_CHANGED_FILES="tests/broken.test.sh" bash "$R" "$T" --changed --jobs 1 >/dev/null 2>&1
_chk "$?" 1 "--changed tests/broken.test.sh → non-zero (the selected red member is surfaced)"
_chk "$(count broken)" 1 "--changed broken: broken ran"
_chk "$(count alpha)"  0 "--changed broken: alpha did NOT run"

# ============================================================================================
# AGREEMENT / anti-false-PASS (#76 acceptance-critical):
#   a --changed run and a full run AGREE on pass/fail for the members they share; selection
#   NEVER hides a failure inside the selected set.
# ============================================================================================

# --- 5. make the SELECTED member fail: --changed must surface it (no hidden failure) ----------
T5="$(mktemp -d)"; mkfix "$T5"; export SENTINEL="$T5/sentinel"
# break alpha's self-test
cat > "$T5/bin/alpha.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --self-test) [ -n "${SENTINEL:-}" ] && echo alpha >> "$SENTINEL"; exit 1;; esac
SH
full_rc=0; bash "$R" "$T5" --jobs 1 >/dev/null 2>&1 || full_rc=$?
chg_rc=0;  : > "$SENTINEL"; TB_CHANGED_FILES="bin/alpha.sh" bash "$R" "$T5" --changed --jobs 1 >/dev/null 2>&1 || chg_rc=$?
_chk "$full_rc" 1 "full run sees the broken alpha (red)"
_chk "$chg_rc"  1 "--changed selecting alpha sees the SAME failure (agreement; not hidden)"
_chk "$(count alpha)" 1 "--changed: the selected failing alpha actually executed"

# --- 6. a change that does NOT select the red member is green ONLY because it wasn't selected --
#        (proves selection narrows the SET; it does not hide a failure in what it DID select) ---
T6="$(mktemp -d)"; mkfix "$T6"; export SENTINEL="$T6/sentinel"
: > "$SENTINEL"
TB_CHANGED_FILES="bin/beta.sh" bash "$R" "$T6" --changed --jobs 1 >/dev/null 2>&1
_chk "$?" 0 "--changed beta → 0 (broken not affected by beta, so not selected)"
_chk "$(count broken)" 0 "--changed beta: broken (unaffected) not run"
_chk "$(count beta)"   1 "--changed beta: beta run"

# ============================================================================================
# CACHE (#77)
# ============================================================================================

# --- 7. cache skips unchanged green members on a re-run; the red member re-runs every time -----
T7="$(mktemp -d)"; mkfix "$T7"; export SENTINEL="$T7/sentinel"
bash "$R" "$T7" --cache --jobs 1 >/dev/null 2>&1   # cold: everything runs
a1=$(count alpha); b1=$(count broken)
bash "$R" "$T7" --cache --jobs 1 >/dev/null 2>&1   # warm: green members skipped
a2=$(count alpha); b2=$(count broken)
_chk "$a1" 1 "cache cold: alpha ran once"
_chk "$a2" 1 "cache warm: alpha SKIPPED (green + unchanged → not re-run)"
_chk "$b2" 2 "cache warm: broken RE-RAN (red is never cached green)"

# --- 8. editing a member's OWN file invalidates its cache entry (fingerprint on own content) ---
: > "$SENTINEL"; bash "$R" "$T7" --cache --jobs 1 >/dev/null 2>&1   # re-warm, alpha skipped
_chk "$(count alpha)" 0 "cache warm again: alpha skipped before edit"
printf '\n# touch\n' >> "$T7/bin/alpha.sh"
bash "$R" "$T7" --cache --jobs 1 >/dev/null 2>&1
_chk "$(count alpha)" 1 "edit alpha.sh → alpha re-runs (own-content fingerprint)"

# --- 9. THE anti-stale-green proof: editing a SOURCED dependency re-runs the dependent ---------
#        beta sources lib.sh; changing lib.sh must invalidate beta even though beta is untouched.
T9="$(mktemp -d)"; mkfix "$T9"; export SENTINEL="$T9/sentinel"
bash "$R" "$T9" --cache --jobs 1 >/dev/null 2>&1   # cold
: > "$SENTINEL"; bash "$R" "$T9" --cache --jobs 1 >/dev/null 2>&1   # warm: beta skipped
_chk "$(count beta)" 0 "cache warm: beta skipped before dep edit"
printf 'extra() { echo changed; }\n' >> "$T9/bin/lib.sh"
: > "$SENTINEL"; bash "$R" "$T9" --cache --jobs 1 >/dev/null 2>&1
_chk "$(count beta)" 1 "edit sourced lib.sh → beta RE-RUNS (input fingerprint, not stale green)"

# --- 10. a cached green can never mask a member that has turned red -----------------------------
T10="$(mktemp -d)"; mkfix "$T10"; export SENTINEL="$T10/sentinel"
bash "$R" "$T10" --cache --jobs 1 >/dev/null 2>&1   # alpha cached green
cat > "$T10/bin/alpha.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --self-test) [ -n "${SENTINEL:-}" ] && echo alpha >> "$SENTINEL"; exit 1;; esac
SH
: > "$SENTINEL"; rc=0; bash "$R" "$T10" --cache --jobs 1 >/dev/null 2>&1 || rc=$?
_chk "$rc" 1 "member turned red after a green cache → run is RED (green not served stale)"
_chk "$(count alpha)" 1 "the now-red alpha actually re-executed (cache miss on changed content)"

# --- 11. --no-cache forces a full run regardless of a fully-warm cache --------------------------
T11="$(mktemp -d)"; mkfix "$T11"; export SENTINEL="$T11/sentinel"
bash "$R" "$T11" --cache --jobs 1 >/dev/null 2>&1   # warm the cache
: > "$SENTINEL"; bash "$R" "$T11" --no-cache --jobs 1 >/dev/null 2>&1
_chk "$(count alpha)" 1 "--no-cache: alpha ran despite a warm cache"
_chk "$(count beta)"  1 "--no-cache: beta ran despite a warm cache"
_chk "$(count gamma)" 1 "--no-cache: gamma ran despite a warm cache"

rm -rf "$T" "$T5" "$T6" "$T7" "$T9" "$T10" "$T11"
if [ "$fail" -eq 0 ]; then echo "run-tests-selection: OK"; exit 0; fi
echo "run-tests-selection: $fail case(s) FAILED" >&2; exit 1
