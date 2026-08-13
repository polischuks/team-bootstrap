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
# Usage: bin/check-diff-coverage.sh [project-dir]  ·  bin/check-diff-coverage.sh --self-test
# Exit:  0 pass / skip · 1 changed-line coverage below threshold · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

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
  local changed_n; changed_n="$(grep -c . "$changed" 2>/dev/null || echo 0)"

  # run the Coverage command; take LCOV from CoverageFile if given, else its stdout
  lcov="$(mktemp)"
  if [ -n "$covfile" ]; then
    eval "$cov" >/dev/null 2>&1 || true
    [ -f "$covfile" ] && cat "$covfile" > "$lcov" 2>/dev/null || true
  else
    eval "$cov" > "$lcov" 2>/dev/null || true
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

  if [ "$m" -eq 0 ]; then
    if [ "$changed_n" -gt 0 ]; then
      echo "check-diff-coverage: WARN — $changed_n changed non-doc line(s) are not present in the coverage report; the Coverage: command may be omitting untested files (require cover-all/--include). Cannot enforce breadth on this batch." >&2
    else
      echo "check-diff-coverage: no changed non-doc lines to measure — pass."
    fi
    return 0
  fi

  local pct; pct=$(( 100 * c / m ))
  if [ "$pct" -lt "$thr" ]; then
    echo "  FAIL: changed-line coverage ${pct}% (${c}/${m}) < threshold ${thr}% — add tests exercising the changed lines (F2, breadth)." >&2
    return 1
  fi
  echo "check-diff-coverage: changed-line coverage ${pct}% (${c}/${m}) ≥ ${thr}% — OK."
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
  # 5/5 covered = 100% ≥ 80 → pass
  printf 'SF:app.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:5,2\nDA:6,1\nend_of_record\n' > "$T/cov.lcov"
  _chk "changed-line coverage 100%% ≥ 80%% → pass" "$(_run)" 0
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
  if [ "$fail" -eq 0 ]; then echo "check-diff-coverage --self-test: OK"; exit 0; fi
  echo "check-diff-coverage --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-diff-coverage: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
