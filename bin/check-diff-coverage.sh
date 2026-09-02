#!/usr/bin/env bash
# check-diff-coverage.sh — F2 verify-batch gate: the batch's CHANGED non-doc lines must be covered
# ≥ a threshold, measured from the project's own coverage report (LCOV). Enforces *breadth* — it
# catches "one trivial test for a 200-line change", which check-tdd (a test merely exists and was
# red) cannot. Marker-gated ⇒ in-session (CI has no .runs/ marker), like check-tdd/check-delivery.
#
# Contract (AGENTS.md / CLAUDE.md, same backtick convention as quality-gate.sh):
#   - `Coverage:` — a command that emits an LCOV tracefile to stdout (or writes the file named by
#     `CoverageFile:`). It MUST cover ALL changed files (--include / cover-all), so an untested
#     changed file shows up as DA misses, not as an absence (else its lines are unmeasured).
#   - `CoverageThreshold:` — percent on changed lines (default 80).
#   - `CoverageFile:` — optional path the Coverage command writes LCOV to (else stdout is parsed).
#   - `CoverageStrict:` — `true` makes unmeasured changed lines count as MISSES (denominator = ALL
#     changed non-doc lines), so a non-cover-all report fails instead of passing over its subset.
#     Default (unset/false): pass over the measured subset but emit a LOUD WARN naming the unmeasured
#     lines — a partial report never passes silently (B5).
#
# LCOV grammar consumed: `SF:<path>` opens a file section, `DA:<line>,<count>` per instrumented line
# (count 0 = miss, >0 = hit), `end_of_record` closes. A changed `path:line` is *measured* if some SF
# section whose path equals or ends with `/<path>` has a DA for that line, and *covered* if that DA
# has count>0 (separator-anchored suffix match — `src/model.py` never absorbs a changed `model.py`).
# pct = 100*covered/measured; pct < threshold ⇒ fail.
#
# Graceful skips (exit 0): no active marker; no runnable `Coverage:` command (WARN — unenforceable,
# never a false block, mirrors quality-gate); no measured changed lines (WARN if there ARE changed
# non-doc lines — the report may be omitting untested files; else silent).
#
# gates: `bin/check-diff-coverage.sh --waive BY REASON EXPIRES(YYYY-MM-DD)` records a governed
# `diff_coverage_waiver` in the active run marker, which _evaluate consults AFTER printing the finding.
# A bare/expired waiver is not a waiver (governed_waiver_ok). This does not silence the finding and it
# expires — see references/enforcement.md.
#
# Usage: bin/check-diff-coverage.sh [project-dir]  ·  --self-test  ·  --waive BY REASON EXPIRES
# Exit:  0 pass / skip / waived · 1 changed-line coverage below threshold (unwaived) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# `--waive BY REASON EXPIRES` records the governed `diff_coverage_waiver` this gate reads — the same
# door check-mutation (mutation_waiver) and check-gate-integrity (gate_integrity_waiver) already carry
# (issue #112). It exists because a legitimately-untestable diff — thin glue over an external SDK — has
# no measurable-in-isolation coverage, and the only alternative was writing throwaway mock tests or
# reverting the good change. Validation is record_governed_waiver's, which is governed_waiver_ok's,
# which is this gate's below: ONE definition, so a waiver that records always works.
if [ "${1:-}" = "--waive" ]; then
  shift
  if [ "$#" -ne 3 ]; then
    echo "usage: $(basename "$0") --waive BY REASON EXPIRES(YYYY-MM-DD)" >&2
    echo "  records diff_coverage_waiver in the active run marker. Expiry is mandatory and must be in the future." >&2
    exit 64
  fi
  record_governed_waiver diff_coverage_waiver "$1" "$2" "$3" || {
    echo "$(basename "$0"): REFUSED to record diff_coverage_waiver — needs a non-empty by and reason, and a future YYYY-MM-DD expires, under an unambiguous active run." >&2
    exit 1
  }
  exit 0
fi

DEFAULT_COVERAGE_THRESHOLD=80

# _doc → first AGENTS.md/CLAUDE.md present (empty if none)
_doc() { local f; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; }
# _cmd LABEL DOC → first backticked command on a `Label:` line
_cmd() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`'; }
# _val LABEL DOC → bare value after `Label:` (backticks stripped, trimmed)
_val() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | tr -d '`' | xargs 2>/dev/null || true; }

# _regesc STR → STR with ERE metacharacters escaped (for anchored suffix matching)
_regesc() { printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'; }

_evaluate() {
  local marker mk doc cov thr covfile lcov base changed
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-diff-coverage: no active delivery run — skipping (F2 governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-diff-coverage: marker not intends_code — skipping."; return 0; }

  doc="$(_doc)"
  cov=""; [ -n "$doc" ] && cov="$(_cmd Coverage "$doc")"
  case "$cov" in ''|N/A|n/a|None|none)
    echo "check-diff-coverage: WARN — no runnable Coverage: command in AGENTS.md; diff-coverage unenforceable (declare Coverage: emitting LCOV to enforce)." >&2
    return 0 ;;
  esac
  thr="$(_val CoverageThreshold "$doc")"; case "$thr" in ''|*[!0-9]*) thr="$DEFAULT_COVERAGE_THRESHOLD" ;; esac
  covfile="$(_val CoverageFile "$doc")"

  base="$(current_batch_base)"
  changed="$(mktemp)"; changed_nondoc_lines "$base" | sort -u > "$changed"
  # #110: `grep -c . "$changed"` PRINTS `0` AND EXITS 1 on an empty file (doc-only batch), so a
  # `|| echo 0` fallback ALSO fired → the substitution captured `0\n0`, crashing the integer
  # arithmetic below and blocking a batch that has no code to measure. `awk 'END{print NR}'` prints a
  # single count and exits 0; the case-guard clamps to one integer so downstream `$(( ))` never sees a
  # two-line value. A doc-only / empty-changed batch is 0 of 0 — a pass, not a crash.
  local changed_n; changed_n="$(awk 'END{print NR}' "$changed" 2>/dev/null)"
  case "$changed_n" in ''|*[!0-9]*) changed_n=0 ;; esac

  # `CoverageFrom: test` (issue #23 item 2) — ADDITIVE, opt-in. Declares that the `Test:` run ITSELF
  # produced the artifact named by `CoverageFile:`, so this gate READS it instead of running a coverage
  # command that would execute the whole suite a second time. Absent/unrecognised ⇒ the original
  # behaviour, unchanged (AC-F1/AC-F6): an unknown value must never silently select the weaker path.
  local covfrom stale
  covfrom="$(_val CoverageFrom "$doc")"; covfrom="$(printf '%s' "$covfrom" | tr '[:upper:]' '[:lower:]')"
  lcov="$(mktemp)"
  if [ "$covfrom" = "test" ]; then
    # Reuse is only sound if the artifact provably describes THIS code. Each failure below is LOUD:
    # a graceful skip here would render the gate unenforceable while still reading green.
    if [ -z "$covfile" ]; then
      echo "  FAIL: 'CoverageFrom: test' needs 'CoverageFile:' — there is no artifact path to read (AGENTS.md contract)." >&2
      return 1
    fi
    if [ ! -f "$covfile" ]; then
      echo "  FAIL: 'CoverageFrom: test' declared but '$covfile' does not exist — the Test: run must emit it (or drop CoverageFrom to run Coverage: here)." >&2
      return 1
    fi
    # STALENESS is the risk this reuse introduces: an artifact from an earlier run would score CURRENT
    # code against OLD coverage — a silent fail-open. Any changed file newer than the artifact ⇒ fail.
    stale="$(git diff --name-only "$base" 2>/dev/null | while IFS= read -r f; do
               [ -n "$f" ] && [ -f "$f" ] && [ "$f" -nt "$covfile" ] && printf '%s ' "$f"; done)"
    if [ -n "$stale" ]; then
      echo "  FAIL: '$covfile' is OLDER than changed source ($stale) — the coverage does not describe this code. Re-run Test: so it re-emits the artifact." >&2
      return 1
    fi
    cat "$covfile" > "$lcov" 2>/dev/null || true
  else
    # Same expensive-gate cache as check-mutation (issue #23 item 1): a retry whose diff, dirty state
    # and declared command are all identical reuses the LCOV rather than re-running the suite. An empty
    # key (no marker/repo/baseline, or a pathologically dirty tree) means EXECUTE.
    local ck cached
    ck="$(gate_cache_key diff-coverage "$cov")"
    if cached="$(gate_cache_get "$ck")"; then
      printf '%s' "$cached" > "$lcov"
      echo "check-diff-coverage: reusing the cached LCOV — diff and Coverage: command unchanged since the last run (issue #23; any code change re-executes)."
    else
      if [ -n "$covfile" ]; then
        eval "$cov" >/dev/null 2>&1 || true
        [ -f "$covfile" ] && cat "$covfile" > "$lcov" 2>/dev/null || true
      else
        eval "$cov" > "$lcov" 2>/dev/null || true
      fi
      gate_cache_put "$ck" "$(cat "$lcov" 2>/dev/null)"
    fi
  fi

  # LCOV → two temp lists: measured "sfpath:line", covered "sfpath:line" (count>0)
  local measured covered sf da lno cnt
  measured="$(mktemp)"; covered="$(mktemp)"; sf=""
  while IFS= read -r da; do
    case "$da" in
      SF:*) sf="${da#SF:}" ;;
      end_of_record) sf="" ;;
      DA:*)
        [ -n "$sf" ] || continue
        lno="${da#DA:}"; cnt="${lno#*,}"; lno="${lno%%,*}"; cnt="${cnt%%,*}"
        case "$lno" in ''|*[!0-9]*) continue ;; esac
        printf '%s:%s\n' "$sf" "$lno" >> "$measured"
        case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
        [ "$cnt" -gt 0 ] && printf '%s:%s\n' "$sf" "$lno" >> "$covered"
        ;;
    esac
  done < "$lcov"

  local m=0 c=0 pl p l esc
  while IFS= read -r pl; do
    [ -n "$pl" ] || continue
    p="${pl%:*}"; l="${pl##*:}"; esc="$(_regesc "$p")"
    if grep -qE "(^|/)${esc}:${l}$" "$measured" 2>/dev/null; then
      m=$((m + 1))
      grep -qE "(^|/)${esc}:${l}$" "$covered" 2>/dev/null && c=$((c + 1))
    fi
  done < "$changed"

  rm -f "$changed" "$lcov" "$measured" "$covered"

  # B5 — a PARTIAL coverage report (measured < changed: the Coverage command is not cover-all) must
  # never pass silently over the measured subset. Default: loud WARN + measure over `m`. Strict
  # (`CoverageStrict: true`): unmeasured changed lines count as MISSES (denominator = all changed).
  local strict; strict="$(_val CoverageStrict "$doc")"
  case "$strict" in true|True|TRUE|yes|Yes|1) strict=1 ;; *) strict=0 ;; esac
  local unmeasured=$(( changed_n - m )); [ "$unmeasured" -ge 0 ] || unmeasured=0
  local denom="$m"

  if [ "$strict" -eq 1 ]; then
    if [ "$changed_n" -eq 0 ]; then echo "check-diff-coverage: no changed non-doc lines to measure — pass."; return 0; fi
    [ "$unmeasured" -gt 0 ] && echo "check-diff-coverage: strict — ${unmeasured} of ${changed_n} changed non-doc line(s) unmeasured, counted as MISSES (CoverageStrict: true)." >&2
    denom="$changed_n"
  else
    if [ "$m" -eq 0 ]; then
      if [ "$changed_n" -gt 0 ]; then
        echo "check-diff-coverage: WARN — none of the ${changed_n} changed non-doc line(s) are in the coverage report; the Coverage: command may be omitting untested files (require cover-all/--include). Cannot enforce breadth on this batch — set CoverageStrict: true to count unmeasured as misses." >&2
      else
        echo "check-diff-coverage: no changed non-doc lines to measure — pass."
      fi
      return 0
    fi
    [ "$unmeasured" -gt 0 ] && echo "check-diff-coverage: WARN — ${unmeasured} of ${changed_n} changed non-doc line(s) are NOT in the coverage report; the percentage below is over the measured ${m} only. Declare a cover-all Coverage: command, or set CoverageStrict: true to count unmeasured as misses." >&2
  fi

  # The verdict line states the measurement BASE, not just the ratio (issue #71): a percentage over a
  # hidden denominator reads as wrong. `measured M of T changed non-doc lines` names how much of the
  # change the coverage report actually saw — in non-strict mode M can be < T (a partial report scored
  # over its subset), in strict mode denom == T so the ratio and the base agree.
  local pct; pct=$(( 100 * c / denom ))
  if [ "$pct" -lt "$thr" ]; then
    echo "  FAIL: changed-line coverage ${pct}% (${c}/${denom} covered; measured ${m} of ${changed_n} changed non-doc lines) < threshold ${thr}% — add tests exercising the changed lines (F2, breadth)." >&2
    # #112: consult the governed diff_coverage_waiver AFTER printing the finding — a governed escape that
    # silences its own finding is worse than none. A valid diff_coverage_waiver (ack+by+reason+unexpired
    # YYYY-MM-DD) relieves the fail; a bare/expired one does not. SAME governed_waiver_ok that backs the
    # peer fidelity gates (check-mutation, check-gate-integrity) — one definition, consistent policy.
    if governed_waiver_ok \
         "$(field_in_obj "$mk" diff_coverage_waiver ack)" \
         "$(field_in_obj "$mk" diff_coverage_waiver by)" \
         "$(field_in_obj "$mk" diff_coverage_waiver reason)" \
         "$(field_in_obj "$mk" diff_coverage_waiver expires)"; then
      echo "check-diff-coverage: WAIVED by a governed diff_coverage_waiver (finding surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0. See references/enforcement.md for the procedure." >&2
      return 0
    fi
    return 1
  fi
  echo "check-diff-coverage: changed-line coverage ${pct}% (${c}/${denom} covered; measured ${m} of ${changed_n} changed non-doc lines) ≥ ${thr}% — OK."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  git_t() { ( cd "$T" && "$@" ); }
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    printf 'line1\n' > app.sh
    printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n- CoverageThreshold: 80\n' > AGENTS.md
    git add . && git commit -qm baseline ) >/dev/null 2>&1
  # a change adding 5 new non-doc lines (app.sh lines 2..6)
  ( cd "$T" && printf 'line1\nl2\nl3\nl4\nl5\nl6\n' > app.sh && git add app.sh && git commit -qm "change" ) >/dev/null 2>&1
  mkdir -p "$T/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$(git_t git rev-parse --short HEAD~1)" > "$T/.runs/r/RUN"
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-diff-coverage.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

  # 3/5 changed lines covered = 60% < 80 → fail
  printf 'SF:app.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:5,0\nDA:6,0\nend_of_record\n' > "$T/cov.lcov"
  _chk "changed-line coverage 60%% < 80%% → fail" "$(_run)" 1
  # #112 — a valid governed diff_coverage_waiver relieves the 60% fail (finding still printed) → pass.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s","diff_coverage_waiver":{"ack":true,"by":"x","reason":"thin SDK glue","expires":"2999-01-01"}}\n' "$(git_t git rev-parse --short HEAD~1)" > "$T/.runs/r/RUN"
  _chk "60%% < 80%% + valid diff_coverage_waiver → pass [#112]" "$(_run)" 0
  # an EXPIRED diff_coverage_waiver is not a waiver → still fails.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s","diff_coverage_waiver":{"ack":true,"by":"x","reason":"r","expires":"2000-01-01"}}\n' "$(git_t git rev-parse --short HEAD~1)" > "$T/.runs/r/RUN"
  _chk "60%% < 80%% + EXPIRED diff_coverage_waiver → fail [#112]" "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$here/check-diff-coverage.sh" . >/dev/null 2>&1 ); echo $? )" 1
  # the `--waive` writer records diff_coverage_waiver, then the enforce run passes on it.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$(git_t git rev-parse --short HEAD~1)" > "$T/.runs/r/RUN"
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-diff-coverage.sh" --waive x r 2999-01-01 >/dev/null 2>&1 )
  case "$(cat "$T/.runs/r/RUN")" in *'"diff_coverage_waiver":{'*'"by":"x"'*) echo "  PASS --waive wrote diff_coverage_waiver" ;;
    *) echo "  FAIL --waive did not write diff_coverage_waiver: $(cat "$T/.runs/r/RUN")" >&2; fail=$((fail + 1)) ;; esac
  _chk "after --waive, enforce + low coverage → pass [#112]" "$(_run)" 0
  # `--waive` with a past expiry is REFUSED (exit 1), writes nothing.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$(git_t git rev-parse --short HEAD~1)" > "$T/.runs/r/RUN"
  _chk "--waive past expiry → refused (exit 1) [#112]" "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-diff-coverage.sh" --waive x r 2000-01-01 >/dev/null 2>&1 ); echo $? )" 1
  # 5/5 covered = 100% ≥ 80 → pass
  printf 'SF:app.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:5,2\nDA:6,1\nend_of_record\n' > "$T/cov.lcov"
  _chk "changed-line coverage 100%% ≥ 80%% → pass" "$(_run)" 0
  # [B5] PARTIAL: only 2 of 5 changed lines measured (both hit) — default passes over measured but MUST warn loudly
  printf 'SF:app.sh\nDA:2,1\nDA:3,1\nend_of_record\n' > "$T/cov.lcov"
  out="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-diff-coverage.sh" . 2>&1 )"; rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "NOT in the coverage report"; then
    echo "  PASS (exit 0 + loud WARN) partial measurement (2/5) no longer passes silently [B5]"
  else echo "  FAIL [B5] partial measurement did not warn (rc=$rc)" >&2; fail=$((fail + 1)); fi
  # [B5] same partial + CoverageStrict:true → unmeasured=misses → 2/5=40% < 80 → fail
  ( cd "$T" && printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n- CoverageThreshold: 80\n- CoverageStrict: true\n' > AGENTS.md )
  _chk "partial + CoverageStrict:true → 40%% < 80%% → fail [B5]" "$(_run)" 1
  ( cd "$T" && printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n- CoverageThreshold: 80\n' > AGENTS.md )   # reset non-strict
  # separator-anchored path: SF:src/app.sh must NOT satisfy a changed app.sh → measured=0 → WARN pass
  printf 'SF:src/app.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:5,1\nDA:6,1\nend_of_record\n' > "$T/cov.lcov"
  _chk "unanchored SF (src/app.sh) does not cover app.sh → measured=0 WARN → exit 0" "$(_run)" 0
  # deeper-path SF that DOES suffix-match with a separator → covered
  ( cd "$T" && mkdir -p pkg && git mv app.sh pkg/app.sh && git commit -qm "move" ) >/dev/null 2>&1
  ( cd "$T" && printf 'line1\nl2\nl3\nl4\nl5\nl6\nl7\n' > pkg/app.sh && git add pkg/app.sh && git commit -qm "edit moved" ) >/dev/null 2>&1
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$(git_t git rev-parse --short HEAD~1)" > "$T/.runs/r/RUN"
  printf 'SF:/abs/build/pkg/app.sh\nDA:7,1\nend_of_record\n' > "$T/cov.lcov"
  _chk "abs SF ending /pkg/app.sh covers changed pkg/app.sh:7 → 100%% pass" "$(_run)" 0
  # no Coverage: command → WARN skip
  ( cd "$T" && printf '# AGENTS\n\n- Lint: `true`\n' > AGENTS.md )
  _chk "no Coverage: command → WARN skip (exit 0)" "$(_run)" 0
  # marker-less → skip
  ( cd "$T" && printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n' > AGENTS.md; rm -f .runs/r/RUN )
  _chk "no active marker → skip (exit 0)" "$(_run)" 0
  rm -rf "$T"

  # #110 — a doc-only batch (zero changed non-doc lines) must PASS, not crash on a two-line `0\n0`
  # changed-count. Fresh repo whose only batch change is to AGENTS.md.
  D="$(mktemp -d)"
  ( cd "$D" && git init -q && git config user.email t@t && git config user.name t
    printf 'code1\n' > app.sh
    printf '# AGENTS\n\n- Coverage: `cat cov.lcov`\n- CoverageThreshold: 80\n' > AGENTS.md
    printf 'SF:app.sh\nDA:1,1\nend_of_record\n' > cov.lcov
    git add . && git commit -qm base
    printf 'more docs\n' >> AGENTS.md && git add AGENTS.md && git commit -qm docchange
    mkdir -p .runs/r
    printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$(git rev-parse --short HEAD~1)" > .runs/r/RUN ) >/dev/null 2>&1
  dout="$( cd "$D" && TEAM_BOOTSTRAP_RUN=r "$here/check-diff-coverage.sh" . 2>&1 )"; drc=$?
  if [ "$drc" = 0 ] && ! printf '%s' "$dout" | grep -q "syntax error"; then
    echo "  PASS (exit 0, no crash) doc-only / empty-changed batch passes [#110]"
  else echo "  FAIL [#110] doc-only batch did not pass cleanly (rc=$drc): $dout" >&2; fail=$((fail + 1)); fi
  rm -rf "$D"
  if [ "$fail" -eq 0 ]; then echo "check-diff-coverage --self-test: OK"; exit 0; fi
  echo "check-diff-coverage --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-diff-coverage: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
