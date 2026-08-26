#!/usr/bin/env bash
# check-tdd.sh — harness gate for P9's red→green: tests written first, run and SEEN to fail, then
# implemented to green. A git-grounded fact, not a self-declared `tests_failed_first` boolean.
#
# PER-BATCH (v2.16.0): every code batch must have its OWN red step, observed before that batch's own
# commits. For an ACTIVE delivery run (marker intends_code:true):
#   - Ledger flow — for each kind:code batch (closed, using its commit_shas; and the in-flight last
#     announced one, using HEAD), require a red record (.runs/<run>/tdd.jsonl, written by --record-red)
#     bearing that batch's id, whose red_sha resolves, is a DESCENDANT of the run baseline and a PROPER
#     ANCESTOR of that batch's code. One red record credits at most one batch (no reuse).
#   - Direct flow (no ledger, but code since baseline) — require one red record whose red_sha is
#     post-baseline and a proper ancestor of HEAD.
# Plus: the suite must be GREEN at HEAD now. Any code batch without its own valid red → fail-closed.
#
# A red record exists only because `--record-red` actually ran the tests and SAW them fail — prose
# cannot fabricate it.
#
# DIVISION OF LABOUR WITH `/test` (Д2 Фаза 4, AC-29). `/test` is how you REACH red: it writes the
# failing test and iterates. This gate is how the harness OBSERVES and RECORDS that red, anchored to a
# git sha. Those are different jobs, and the duplication Ф4 found was a SECOND SCRIPT (bin/tdd-red.sh)
# that also drove the suite. It is deleted; its observation entry point lives here, in the gate that
# consumes the record, so there is exactly one of each job.
#
# WHY THE OBSERVATION IS NOT A RE-RUN AT CLOSE TIME. The obvious alternative — have this gate find the
# red commit in git and re-run the suite against it in a detached worktree — was designed and rejected
# after measuring it. A fresh worktree carries only TRACKED files: no node_modules, no .venv, no vendor
# tree. In any project whose Test: command needs them, the suite cannot START and exits non-zero, which
# this gate would read as a genuine red. That is a FALSE red — the precise inversion of what P9 asks —
# and it would fire hardest on exactly the mainstream projects the plugin targets. The observation has
# to happen where the dependencies are, which is the working tree at the moment the red exists.
#
# Usage of the observation step: bin/check-tdd.sh --record-red [--batch <id>] [project-dir]
#   Run it at the TDD red step: AFTER writing the failing test(s), BEFORE implementing. It runs the
#   project's Test: command and REQUIRES it to fail. You cannot record red when the suite is already
#   green — nothing failed means no test-first.
#   Exit: 0 red recorded · 1 the suite is GREEN (no valid red) · 3 no Test: command · 4 the red changed
#   no committed test file.
#
# Graceful skips (exit 0): no active marker, no code delivered, or no runnable AGENTS.md `Test:`
# command (warns — unenforceable). Marker-gated ⇒ in-session (CI has no marker), like check-delivery.
#
# Usage: bin/check-tdd.sh [project-dir]  ·  --record-red [--batch <id>]  ·  --self-test
# Exit:  0 pass / skip · 1 a code batch lacks its red step, mis-ordered, or HEAD not green · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

tdd=""   # path to the run's tdd.jsonl (set in _evaluate; read by _find_red)

# _test_cmd is now defined ONCE in delivery-lib.sh (sourced above) so check-tdd and check-preflight share
# a single definition of the project's Test: command (pipeline-integrity-hardening WS-B, T040).

# _oldest_sha LINE → the batch's oldest commit_sha (commit_shas is stored newest-first).
_oldest_sha() { shas_of_line "$1" | awk '{print $NF}'; }
# _newest_sha LINE → the batch's newest commit_sha (first token, newest-first).
_newest_sha() { shas_of_line "$1" | awk '{print $1}'; }

# _find_red BATCH_ID('' = any) ANCHOR_FULL BASE_FULL USED → echo a valid, unused red_full or return 1.
# Valid = record (matching batch id, if given) whose red_sha resolves, is a PROPER ANCESTOR of ANCHOR
# (red before the code) and a DESCENDANT of BASE (red on this run's work), and not already USED.
_find_red() {
  local id="$1" anchor="$2" bfull="$3" used="$4" line rs rfull
  [ -n "$tdd" ] && [ -f "$tdd" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -z "$id" ] || [ "$(field_str "$line" batch)" = "$id" ] || continue
    rs="$(field_str "$line" red_sha)"; rfull="$(resolve_sha "$rs")" || rfull=""
    [ -n "$rfull" ] || continue
    case " $used " in *" $rfull "*) continue ;; esac
    [ "$rfull" != "$anchor" ] || continue
    git merge-base --is-ancestor "$rfull" "$anchor" 2>/dev/null || continue
    [ -z "$bfull" ] || git merge-base --is-ancestor "$bfull" "$rfull" 2>/dev/null || continue
    printf '%s' "$rfull"; return 0
  done < "$tdd"
  return 1
}

_evaluate() {
  local marker mk baseline ledger tcmd hd bfull run total n line status id anchor r
  local viol=0 used="" any_code_batch=0
  local tglobs prev_tip newest   # F1 (red-touches-tests): per-batch red-window test-path check
  tglobs="$(read_test_globs)"
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-tdd: no active delivery run — skipping (TDD governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-tdd: marker not intends_code — skipping."; return 0; }
  baseline="$(field_str "$mk" baseline_sha)"
  tcmd="$(_test_cmd)"
  [ -n "$tcmd" ] || { echo "check-tdd: WARN — no runnable Test: command in AGENTS.md; red→green cannot be machine-verified (P9 unenforced for this project)." >&2; return 0; }
  hd="$(git rev-parse HEAD 2>/dev/null || true)"
  bfull="$(resolve_sha "${baseline:-}")"
  prev_tip="$bfull"   # window-start for the first code batch's red window (F1)
  run="$(printf '%s' "$marker" | sed -E 's#^.*\.runs/([^/]+)/RUN$#\1#')"
  tdd=".runs/$run/tdd.jsonl"

  ledger="$(resolve_ledger)"
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    total="$(grep -c . "$ledger" 2>/dev/null || echo 0)"; n=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1))
      [ "$(field_str "$line" kind)" = "code" ] || continue
      status="$(field_str "$line" status)"
      id="$(field_str "$line" id)"; [ -n "$id" ] || id="#$n"
      if [ "$status" = "closed" ]; then
        any_code_batch=1
        anchor="$(resolve_sha "$(_oldest_sha "$line")")"
        if [ -z "$anchor" ]; then
          echo "  FAIL: code batch '$id' commit_shas do not resolve — cannot verify red ordering." >&2; viol=$((viol + 1)); continue
        fi
        r="$(_find_red "$id" "$anchor" "$bfull" "$used")" || r=""
        if [ -z "$r" ]; then
          echo "  FAIL-CLOSED: code batch '$id' has no red step before its own commits — each code batch must be red-first (P9, per-batch)." >&2; viol=$((viol + 1))
        else
          used="$used $r"
          if ! window_touches_test "$prev_tip" "$r" "$tglobs"; then
            echo "  FAIL-CLOSED: code batch '$id' red window changed no test file — a red must touch a test path (F1, red-touches-tests). TestGlobs: extends the default set." >&2; viol=$((viol + 1))
          fi
        fi
        newest="$(resolve_sha "$(_newest_sha "$line")")"; [ -n "$newest" ] && prev_tip="$newest"
      elif [ "$n" -eq "$total" ]; then
        any_code_batch=1   # in-flight batch being closed now: its code is up to HEAD, not yet stamped
        r="$(_find_red "$id" "$hd" "$bfull" "$used")" || r=""
        if [ -z "$r" ]; then
          echo "  FAIL-CLOSED: in-flight code batch '$id' has no red step before HEAD — run bin/check-tdd.sh --record-red --batch $id before implementing (P9, per-batch)." >&2; viol=$((viol + 1))
        else
          used="$used $r"
          if ! window_touches_test "$prev_tip" "$r" "$tglobs"; then
            echo "  FAIL-CLOSED: in-flight code batch '$id' red window changed no test file — a red must touch a test path (F1, red-touches-tests)." >&2; viol=$((viol + 1))
          fi
        fi
      fi
    done < "$ledger"
  fi

  if [ "$any_code_batch" -eq 0 ]; then
    if code_since_baseline "${baseline:-}"; then          # direct run (no ledger): run-level red
      r="$(_find_red "" "$hd" "$bfull" "")" || r=""
      if [ -z "$r" ]; then
        echo "  FAIL-CLOSED: code shipped (direct run) with no observed red step before HEAD (P9). Run bin/check-tdd.sh --record-red before implementing." >&2; viol=$((viol + 1))
      elif ! window_touches_test "$bfull" "$r" "$tglobs"; then
        echo "  FAIL-CLOSED: code shipped (direct run) but the red window changed no test file — a red must touch a test path (F1)." >&2; viol=$((viol + 1))
      fi
    else
      echo "check-tdd: no code delivered yet — nothing to require a red step for."; return 0
    fi
  fi

  [ "$viol" -eq 0 ] || return 1

  if ! eval "$tcmd" >/dev/null 2>&1; then
    echo "  FAIL: suite is RED at HEAD (\`$tcmd\`) — implement to green before closing (P9)." >&2; return 1
  fi
  echo "check-tdd: per-batch red→green verified — every code batch had its own red step before its code, and the suite is green at HEAD."
  return 0
}

# --- --record-red: the observation step (moved here from the deleted bin/tdd-red.sh) -----------------
if [ "${1:-}" = "--record-red" ]; then
  shift
  rr_batch=""; rr_root="."
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) rr_batch="${2:-}"; shift 2 ;;
      -*) echo "check-tdd --record-red: unknown flag '$1'" >&2; exit 64 ;;
      *) rr_root="$1"; shift ;;
    esac
  done
  cd "$rr_root" 2>/dev/null || { echo "check-tdd --record-red: bad dir '$rr_root'" >&2; exit 64; }

  rr_cmd="$(_test_cmd)"
  case "$rr_cmd" in '') echo "check-tdd --record-red: no runnable Test: command in AGENTS.md — cannot observe red." >&2; exit 3 ;; esac

  echo "check-tdd --record-red: running tests (expecting RED) -> $rr_cmd" >&2
  if eval "$rr_cmd" >/dev/null 2>&1; then
    echo "check-tdd --record-red: tests PASS (green) — nothing failed. Write a failing test FIRST (P9 red step), then re-run." >&2
    exit 1
  fi

  # F1 (red-touches-tests): the red must be caused by a COMMITTED test-file change, so the red_sha this
  # writes sits in the same window _find_red later verifies. An --allow-empty red, a non-test-only red,
  # or a worktree-only test would all record a sha the ordering check cannot honestly credit.
  rr_marker="$(resolve_marker)"; rr_baseline=""
  [ -n "$rr_marker" ] && [ -f "$rr_marker" ] && rr_baseline="$(field_str "$(cat "$rr_marker" 2>/dev/null)" baseline_sha)"
  rr_base="$(resolve_sha "${rr_baseline:-}")" || rr_base=""
  [ -n "$rr_base" ] || rr_base="$(git rev-parse -q --verify 'HEAD^' 2>/dev/null || true)"
  if ! window_touches_test "$rr_base" "HEAD" "$(read_test_globs)"; then
    echo "check-tdd --record-red: the red changed no COMMITTED test file — commit your failing test FIRST so the red is git-anchored, then re-run. (Inline-test projects: widen TestGlobs: in AGENTS.md.)" >&2
    exit 4
  fi

  rr_run="${TEAM_BOOTSTRAP_RUN:-}"
  [ -n "$rr_run" ] || rr_run="$(resolve_marker | sed -E 's#^\.runs/([^/]+)/RUN$#\1#')"
  [ -n "$rr_run" ] || rr_run="deliver-run"
  mkdir -p ".runs/$rr_run" 2>/dev/null || { echo "check-tdd --record-red: cannot write .runs/$rr_run" >&2; exit 1; }
  rr_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  [ -n "$rr_batch" ] || rr_batch="?"
  rr_esc="$(printf '%s' "$rr_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"batch":"%s","red_sha":"%s","test_cmd":"%s","observed":"red"}\n' \
    "$rr_batch" "$rr_sha" "$rr_esc" >> ".runs/$rr_run/tdd.jsonl"
  echo "check-tdd --record-red: RED recorded (run=$rr_run batch=$rr_batch red_sha=$rr_sha) — now implement to green." >&2
  exit 0
fi

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  T="$(mktemp -d)"
  git_t() { ( cd "$T" && "$@" ); }
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `test -f .green`\n' > AGENTS.md && git add . && git commit -qm baseline ) >/dev/null 2>&1
  base="$(git_t git rev-parse --short HEAD)"
  git_t git commit -q --allow-empty -m "empty (non-test red)" >/dev/null 2>&1;  eA="$(git_t git rev-parse --short HEAD)"
  ( cd "$T" && echo 't' > f1_test.sh && git add f1_test.sh && git commit -qm "redA (B1 failing test)" ) >/dev/null 2>&1; rA="$(git_t git rev-parse --short HEAD)"
  ( cd "$T" && echo 1 > f1 && git add f1 && git commit -qm "B1 code" ) >/dev/null 2>&1; c1="$(git_t git rev-parse --short HEAD)"
  ( cd "$T" && echo 't' > f2_test.sh && git add f2_test.sh && git commit -qm "redB (B2 failing test)" ) >/dev/null 2>&1; rB="$(git_t git rev-parse --short HEAD)"
  ( cd "$T" && : > .green && echo 2 > f2 && git add . && git commit -qm "B2 code (green)" ) >/dev/null 2>&1; c2="$(git_t git rev-parse --short HEAD)"
  mkdir -p "$T/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  printf '%s\n%s\n' \
    "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$c1\"],\"code_delta\":5}" \
    "{\"id\":\"B2\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$c2\"],\"code_delta\":5}" > "$T/.runs/r/batches.jsonl"
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { local got; got="$(_run)"; if [ "$got" = "$2" ]; then echo "  PASS (exit $got) $1"; else echo "  FAIL (exit $got, want $2) $1" >&2; fail=$((fail + 1)); fi; }

  # both batches have their own test-touching red → pass
  printf '%s\n%s\n' \
    "{\"batch\":\"B1\",\"red_sha\":\"$rA\",\"observed\":\"red\"}" \
    "{\"batch\":\"B2\",\"red_sha\":\"$rB\",\"observed\":\"red\"}" > "$T/.runs/r/tdd.jsonl"
  _chk "two code batches, each red-first (test-touching) + green HEAD → pass" 0
  # B1's red window touches no test file (empty commit) → F1 fail
  printf '%s\n%s\n' \
    "{\"batch\":\"B1\",\"red_sha\":\"$eA\",\"observed\":\"red\"}" \
    "{\"batch\":\"B2\",\"red_sha\":\"$rB\",\"observed\":\"red\"}" > "$T/.runs/r/tdd.jsonl"
  _chk "B1 red window changed no test file → fail (F1, red-touches-tests)" 1
  # B2's red missing → fail-closed
  printf '%s\n' "{\"batch\":\"B1\",\"red_sha\":\"$rA\",\"observed\":\"red\"}" > "$T/.runs/r/tdd.jsonl"
  _chk "B2 has no red step → fail-closed (per-batch)" 1
  # B2 tries to reuse B1's red (mislabelled) → still fail (rA is not an ancestor-only-of B2; and reuse)
  printf '%s\n%s\n' \
    "{\"batch\":\"B1\",\"red_sha\":\"$rA\",\"observed\":\"red\"}" \
    "{\"batch\":\"B2\",\"red_sha\":\"$rA\",\"observed\":\"red\"}" > "$T/.runs/r/tdd.jsonl"
  _chk "B2 reuses B1's red_sha → fail (one red, one batch)" 1
  # both present again but HEAD red (remove .green) → fail
  printf '%s\n%s\n' \
    "{\"batch\":\"B1\",\"red_sha\":\"$rA\",\"observed\":\"red\"}" \
    "{\"batch\":\"B2\",\"red_sha\":\"$rB\",\"observed\":\"red\"}" > "$T/.runs/r/tdd.jsonl"
  ( cd "$T" && rm -f .green && git commit -qam "regress" ) >/dev/null 2>&1
  _chk "both reds present but HEAD is RED → fail" 1
  ( cd "$T" && : > .green && git add .green && git commit -qm regreen ) >/dev/null 2>&1
  # marker-less → skip
  ( cd "$T" && rm -f .runs/r/RUN )
  _chk "no active marker → skip (exit 0)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-tdd --self-test: OK"; exit 0; fi
  echo "check-tdd --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-tdd: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
