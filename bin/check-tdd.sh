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
#   no committed test file · 5 the red is a WRONG-CAUSE red (#68: a collection/import/syntax/missing-file
#   error, not a failing assertion about the target behaviour — proves nothing, rejected).
#
# REGRESSION-LOCK — the #67 form (bin/check-tdd.sh --record-lock [--batch <id>]). A regression-lock pins
# already-correct behaviour so it cannot silently regress. On safe code the lock is GREEN on arrival, so
# it has NO natural red and red-first cannot express it without an artificial one. Its honest proof is a
# MUTATION check on the lock: with the locked behaviour mutated (uncommitted) in the working tree, the
# suite must go RED — the lock kills the mutant. A closed kind:code batch satisfies this gate with EITHER
# a valid red record OR a valid lock record (one record credits at most one batch; no reuse across the
# two). The lock is exempt from the #68 red-by-cause bar (it has no red commit); its bar is the kill.
#
# Graceful skips (exit 0): no active marker, no code delivered, or no runnable AGENTS.md `Test:`
# command (warns — unenforceable). Marker-gated ⇒ in-session (CI has no marker), like check-delivery.
#
# Usage: bin/check-tdd.sh [project-dir] · --record-red [--batch <id>] · --record-lock [--batch <id>] · --self-test
# Exit:  0 pass / skip · 1 a code batch lacks its red-or-lock step, mis-ordered, or HEAD not green · 64 bad usage
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

# _find_lock BATCH_ID('' = any) ANCHOR_FULL BASE_FULL USED → echo a valid, unused lock_full or return 1.
# The #67 counterpart to _find_red: a regression-LOCK proof. A lock record (observed:"lock-kill",
# written by --record-lock) proves the batch's lock assertion REDDENS when the behaviour it locks is
# mutated — a different, stronger obligation than "the suite was red at HEAD~1", and the one honest way
# to ship a green-on-arrival lock. Valid = a lock record (matching batch id, if given) whose lock_sha
# resolves, is a DESCENDANT of BASE (the lock is this run's work) and an ANCESTOR-OR-EQUAL of ANCHOR
# (the lock test sits within the batch's code — a lock IS a test, it need not precede code), unused.
# Disjoint from _find_red by construction: a lock record carries no red_sha, a red record no lock_sha.
_find_lock() {
  local id="$1" anchor="$2" bfull="$3" used="$4" line ls lfull
  [ -n "$tdd" ] && [ -f "$tdd" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field_str "$line" observed)" = "lock-kill" ] || continue
    [ -z "$id" ] || [ "$(field_str "$line" batch)" = "$id" ] || continue
    ls="$(field_str "$line" lock_sha)"; lfull="$(resolve_sha "$ls")" || lfull=""
    [ -n "$lfull" ] || continue
    case " $used " in *" $lfull "*) continue ;; esac
    if [ "$lfull" != "$anchor" ]; then
      git merge-base --is-ancestor "$lfull" "$anchor" 2>/dev/null || continue
    fi
    [ -z "$bfull" ] || git merge-base --is-ancestor "$bfull" "$lfull" 2>/dev/null || continue
    printf '%s' "$lfull"; return 0
  done < "$tdd"
  return 1
}

# _red_wrong_cause OUTPUT → rc 0 IFF the captured test output looks like a WRONG-CAUSE red (#68): a
# collection/import/syntax/missing-file error that reddens the suite while proving nothing about the
# target behaviour. Deliberately CONSERVATIVE — it rejects only a positively-recognized wrong-cause
# error with NO accompanying assertion/test-failure signal; empty or unrecognized output is ALLOWED, so
# a real red (including a bare `test`/exit-1 red that prints nothing) is never false-rejected. When both
# an assertion signal AND a wrong-cause marker are present, the assertion wins (benefit of the doubt).
_red_wrong_cause() {
  local out="$1"
  # A genuine assertion / test-level failure anywhere → treat as a real red (allow).
  printf '%s' "$out" | grep -qiE \
    'assertionerror|assertion failed|assert |[0-9]+ (failed|failing)|not ok [0-9]|received:|expected:|to equal|to be |toequal|tobe|tomatch|tocontain|expect\(' \
    && return 1
  # Positively-recognized wrong-cause markers (only reached when no genuine signal was found).
  printf '%s' "$out" | grep -qiE \
    'modulenotfounderror|importerror|import error|cannot import|unable to import|cannot find module|module not found|module_not_found|syntaxerror|indentationerror|taberror|error collecting|errors? during collection|collected 0 items|error while (importing|loading)|failed to load config|no such file or directory|command not found|no tests? ran' \
    && return 0
  return 1   # unrecognized / empty → allow (never false-reject a real red)
}

_evaluate() {
  local marker mk baseline ledger tcmd hd bfull run total n line status id anchor r lk
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
        newest="$(resolve_sha "$(_newest_sha "$line")")"
        if [ -z "$anchor" ]; then
          echo "  FAIL: code batch '$id' commit_shas do not resolve — cannot verify red ordering." >&2; viol=$((viol + 1)); continue
        fi
        r="$(_find_red "$id" "$anchor" "$bfull" "$used")" || r=""
        if [ -n "$r" ]; then
          used="$used $r"
          if ! window_touches_test "$prev_tip" "$r" "$tglobs"; then
            echo "  FAIL-CLOSED: code batch '$id' red window changed no test file — a red must touch a test path (F1, red-touches-tests). TestGlobs: extends the default set." >&2; viol=$((viol + 1))
          fi
        else
          lk="$(_find_lock "$id" "${newest:-$anchor}" "$bfull" "$used")" || lk=""
          if [ -n "$lk" ]; then
            used="$used $lk"
            if ! window_touches_test "$prev_tip" "${newest:-$anchor}" "$tglobs"; then
              echo "  FAIL-CLOSED: regression-lock batch '$id' shipped no lock test in its window — a lock is a test that pins the behaviour (#67, lock-is-a-test)." >&2; viol=$((viol + 1))
            fi
          else
            echo "  FAIL-CLOSED: code batch '$id' has neither a red step before its own commits nor a regression-lock proof — a code batch must be red-first, or a declared lock whose lock catches a mutation (P9 / #67, per-batch)." >&2; viol=$((viol + 1))
          fi
        fi
        [ -n "$newest" ] && prev_tip="$newest"
      elif [ "$n" -eq "$total" ]; then
        any_code_batch=1   # in-flight batch being closed now: its code is up to HEAD, not yet stamped
        r="$(_find_red "$id" "$hd" "$bfull" "$used")" || r=""
        if [ -n "$r" ]; then
          used="$used $r"
          if ! window_touches_test "$prev_tip" "$r" "$tglobs"; then
            echo "  FAIL-CLOSED: in-flight code batch '$id' red window changed no test file — a red must touch a test path (F1, red-touches-tests)." >&2; viol=$((viol + 1))
          fi
        else
          lk="$(_find_lock "$id" "$hd" "$bfull" "$used")" || lk=""
          if [ -n "$lk" ]; then
            used="$used $lk"
            if ! window_touches_test "$prev_tip" "$hd" "$tglobs"; then
              echo "  FAIL-CLOSED: in-flight regression-lock batch '$id' shipped no lock test in its window — a lock is a test that pins the behaviour (#67, lock-is-a-test)." >&2; viol=$((viol + 1))
            fi
          else
            echo "  FAIL-CLOSED: in-flight code batch '$id' has neither a red step before HEAD nor a regression-lock proof — run bin/check-tdd.sh --record-red --batch $id (or --record-lock --batch $id for a green-on-arrival lock) before implementing (P9 / #67, per-batch)." >&2; viol=$((viol + 1))
          fi
        fi
      fi
    done < "$ledger"
  fi

  if [ "$any_code_batch" -eq 0 ]; then
    if code_since_baseline "${baseline:-}"; then          # direct run (no ledger): run-level red
      r="$(_find_red "" "$hd" "$bfull" "")" || r=""
      if [ -n "$r" ]; then
        if ! window_touches_test "$bfull" "$r" "$tglobs"; then
          echo "  FAIL-CLOSED: code shipped (direct run) but the red window changed no test file — a red must touch a test path (F1)." >&2; viol=$((viol + 1))
        fi
      else
        lk="$(_find_lock "" "$hd" "$bfull" "")" || lk=""
        if [ -n "$lk" ]; then
          if ! window_touches_test "$bfull" "$hd" "$tglobs"; then
            echo "  FAIL-CLOSED: code shipped (direct run) as a regression-lock but no lock test appears in the window — a lock is a test (#67)." >&2; viol=$((viol + 1))
          fi
        else
          echo "  FAIL-CLOSED: code shipped (direct run) with no observed red step nor regression-lock proof before HEAD (P9 / #67). Run bin/check-tdd.sh --record-red (or --record-lock for a green-on-arrival lock) before implementing." >&2; viol=$((viol + 1))
        fi
      fi
    else
      echo "check-tdd: no code delivered yet — nothing to require a red step for."; return 0
    fi
  fi

  if [ "$viol" -ne 0 ]; then
    # #120 — a governed host_structural tdd-waiver relieves the red-ordering violations printed above,
    # for the batch whose red is genuinely unresolvable by the current Test: (its package is excluded from
    # the top-level suite). Parity with check-mutation's mutation_waiver: the finding is already surfaced,
    # then a VALID governed tdd_waiver (ack+by+reason+unexpired-YYYY-MM-DD) clears the fail; a bare/expired
    # one does not. Routed through the SAME governed_waiver_ok the peer gates decide on — one definition.
    # It does NOT relieve a genuinely RED suite at HEAD (checked below): that is a different failure.
    if governed_waiver_ok \
         "$(field_in_obj "$mk" tdd_waiver ack)" \
         "$(field_in_obj "$mk" tdd_waiver by)" \
         "$(field_in_obj "$mk" tdd_waiver reason)" \
         "$(field_in_obj "$mk" tdd_waiver expires)"; then
      echo "check-tdd: WAIVED by a governed tdd_waiver (finding(s) surfaced above; by/reason/expires recorded, expiry forces re-review) — the batch's red is unresolvable by the top-level Test: (host_structural). See references/enforcement.md." >&2
      viol=0
    else
      return 1
    fi
  fi

  # #97 — a kind:doc batch close changes no code, so HEAD's code is exactly what the last CODE batch
  # already proved green at its OWN close. Running the whole Test: suite (~3.5 min) to close a doc batch
  # proves nothing new and was the single largest wall-clock cost of a doc close. When the batch being
  # closed (the in-flight, last-announced entry) is kind:doc, skip the expensive suite — the cheap
  # red-ordering checks above still ran over every closed CODE batch, so no guarantee is dropped.
  local inflight ifkind
  inflight="$(inflight_batch)"
  ifkind="$(field_str "$inflight" kind)"
  if [ "$ifkind" = "doc" ]; then
    echo "check-tdd: the batch being closed is kind:doc (no code delta) — skipping the HEAD-green suite; its code was proven green at the last code batch's close (#97)."
    return 0
  fi

  # The cheap red-ordering checks above run every attempt (their input is the ledger, which a late
  # gate's retry legitimately changes). The suite run below is the EXPENSIVE step — the whole
  # non-integration suite (~3.5 min) at HEAD. verify-batch re-runs every gate on every retry, so a
  # retry triggered by a LATE cheap gate (completeness / ordering / gate-integrity) re-paid for the
  # full suite against a byte-identical tree — recording an ack only rewrites the ledger under .runs/
  # (gitignored), so the code the suite runs against is unchanged. Reuse this gate's own previous
  # result keyed on the TREE STATE (command string + committed window + uncommitted tracked +
  # untracked content, via delivery-lib gate_cache_key); ANY real code change moves the key and
  # re-runs. An empty key (no marker, no repo, no baseline — e.g. CI) means EXECUTE: gate_cache_get
  # misses and gate_cache_put no-ops, so the suite always runs there (issue #64). A stale green is the
  # ADR-0015 fail-open, so every ambiguity resolves toward re-running.
  local ck out
  ck="$(gate_cache_key tdd "$tcmd")"
  # Trust a hit ONLY when it carries a recognized verdict — a corrupt/empty cache entry falls through
  # to a real run rather than wedging the gate on a spurious permanent red (still the safe direction).
  if out="$(gate_cache_get "$ck")" && { [ "$out" = "green" ] || [ "$out" = "red" ]; }; then
    echo "check-tdd: reusing the cached suite verdict — the tree is unchanged since the last run (issue #64; any code change re-executes)."
  else
    if eval "$tcmd" >/dev/null 2>&1; then out="green"; else out="red"; fi
    gate_cache_put "$ck" "$out"
  fi
  if [ "$out" != "green" ]; then
    echo "  FAIL: suite is RED at HEAD (\`$tcmd\`) — implement to green before closing (P9)." >&2; return 1
  fi
  echo "check-tdd: per-batch red→green verified — every code batch had its own red step before its code, and the suite is green at HEAD."
  return 0
}

# --- --waive: the governed host_structural tdd-waiver door (issue #120) ------------------------------
# `--waive BY REASON EXPIRES(YYYY-MM-DD)` records a governed `tdd_waiver` in the active run marker — the
# same door the other enforce gates already carry (check-mutation → mutation_waiver, check-gate-integrity
# → gate_integrity_waiver). It exists because a batch confined to a package the top-level `Test:` command
# does NOT run (e.g. a dashboard suite standing-red at the monorepo level and excluded from Test:) can
# never produce an observable red on that Test:, so it has no sanctioned red-first escape short of manual
# ledger surgery (deleting/re-recording tdd.jsonl + review_acks by hand). Validation is
# record_governed_waiver's, which is governed_waiver_ok's, which is _evaluate's below — ONE definition, so
# a waiver that records always relieves the gate and one that would not is refused here with a reason. The
# finding is still PRINTED by the gate; a waiver dates and attributes the escape, it does not hide it.
if [ "${1:-}" = "--waive" ]; then
  shift
  if [ "$#" -ne 3 ]; then
    echo "usage: $(basename "$0") --waive BY REASON EXPIRES(YYYY-MM-DD)" >&2
    echo "  records a governed tdd_waiver in the active run marker (host_structural: the batch's red is unresolvable by the top-level Test:). Expiry is mandatory and must be in the future." >&2
    exit 64
  fi
  record_governed_waiver tdd_waiver "$1" "$2" "$3" || {
    echo "$(basename "$0"): REFUSED to record tdd_waiver — needs a non-empty by and reason, and a future YYYY-MM-DD expires, under an unambiguous active run." >&2
    exit 1
  }
  exit 0
fi

# --- --record-red: the observation step (moved here from the deleted bin/tdd-red.sh) -----------------
if [ "${1:-}" = "--record-red" ]; then
  shift
  rr_batch=""; rr_root="."; rr_scope=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) rr_batch="${2:-}"; shift 2 ;;
      # --scope "<args>" (#86): narrow the RED observation to a subset by APPENDING these args to the
      # project's own Test: command — e.g. the batch's touched test path(s). Seeing one new test fail
      # does not need the whole suite, and the full suite runs unchanged at CLOSE (verify-batch), where
      # the guarantee is load-bearing. It appends to the REAL runner (never replaces it), so a scoped
      # red is still a genuine failure of the project's tests; #68 wrong-cause and F1 red-touches-tests
      # apply exactly as to a full red. The recorded test_cmd states what was actually run.
      --scope) rr_scope="${2:-}"; shift 2 ;;
      -*) echo "check-tdd --record-red: unknown flag '$1'" >&2; exit 64 ;;
      *) rr_root="$1"; shift ;;
    esac
  done
  cd "$rr_root" 2>/dev/null || { echo "check-tdd --record-red: bad dir '$rr_root'" >&2; exit 64; }

  rr_cmd="$(_test_cmd)"
  case "$rr_cmd" in '') echo "check-tdd --record-red: no runnable Test: command in AGENTS.md — cannot observe red." >&2; exit 3 ;; esac
  [ -n "$rr_scope" ] && rr_cmd="$rr_cmd $rr_scope"   # #86 — scoped red: the project runner, narrowed

  echo "check-tdd --record-red: running tests (expecting RED) -> $rr_cmd" >&2
  rr_out="$(eval "$rr_cmd" 2>&1)"; rr_rc=$?
  if [ "$rr_rc" -eq 0 ]; then
    echo "check-tdd --record-red: tests PASS (green) — nothing failed. Write a failing test FIRST (P9 red step), then re-run." >&2
    exit 1
  fi

  # #68 red-by-cause bar: the suite went red — but a red for a WRONG cause (collection/import/syntax/
  # missing-file error, unrelated to the test the batch makes green) satisfies the letter of red-first
  # while proving nothing about the target behaviour. Reject a positively-recognized wrong-cause red
  # that carries no assertion signal. Conservative by design: empty/unrecognized output is allowed, so
  # a real red is never false-rejected. This bar guards the RED path; the LOCK path (--record-lock) is
  # proven by a mutation-kill instead and is not subject to it.
  if _red_wrong_cause "$rr_out"; then
    echo "check-tdd --record-red: the red looks like a WRONG-CAUSE failure (collection/import/syntax/missing-file error), not a failing assertion about the target behaviour — a red that fires for an unrelated reason proves nothing about the behaviour being added (#68). Fix the wrong-cause error so the test reaches and fails its OWN assertion, then re-run." >&2
    exit 5
  fi

  # #121 STALE-RED-SHA TRAP: --record-red stamps red_sha = current HEAD. If the failing test is still
  # UNCOMMITTED (recorded from a dirty tree), red_sha points at HEAD — which does NOT contain the test —
  # so the batch's F1 window [prev_tip..red_sha] later resolves empty and the batch fails downstream with
  # "red changed no committed test file". The failure surfaces far from its cause. Enforce the "commit the
  # failing test FIRST" rule AT RECORD TIME: if the working tree carries an uncommitted change to a test
  # path (staged or unstaged), refuse — the red would be anchored at the wrong sha. This is stricter than
  # the committed-window check below (which a STALE already-committed test could satisfy while the real
  # red is uncommitted), so it runs first.
  rr_dirty_test=0
  while IFS= read -r rr_line; do
    [ -n "$rr_line" ] || continue
    rr_p="${rr_line#???}"; rr_p="${rr_p##* -> }"           # strip XY status; take a rename's destination
    [ -n "$rr_p" ] || continue
    case "$rr_p" in .runs/*|.runs) continue ;; esac        # the harness ledger is never the batch's test
    if is_test_path "$rr_p" "$(read_test_globs)"; then rr_dirty_test=1; break; fi
  done < <(git status --porcelain 2>/dev/null)
  if [ "$rr_dirty_test" -eq 1 ]; then
    echo "check-tdd --record-red: an uncommitted test-file change is in the working tree ('$rr_p') — red_sha would be stamped at HEAD, NOT at the commit that introduces your failing test, leaving an EMPTY F1 window that fails the batch downstream. Commit your failing test FIRST, then re-run (#121). To re-anchor after a legitimate commit rebuild: bin/marker.sh red-supersede <batch>, then --record-red again." >&2
    exit 4
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

# --- --record-lock: the #67 observation step — proof that a regression-LOCK catches a mutation -------
# A regression-lock pins already-correct behaviour so it cannot silently regress. On safe code the lock
# is GREEN on arrival, so it has no natural red and red-first cannot express it. Its honest proof is a
# MUTATION check on the lock: with the locked behaviour MUTATED in the working tree, the suite must go
# RED — the lock kills the mutant. Run it AFTER committing the lock test AND the green implementation,
# with the mutation applied but UNCOMMITTED (so it is never shipped), then revert the mutation. Same
# trust model as --record-red: the record exists only because the observation actually ran and SAW the
# lock redden under the mutation.
#
# #128 — DESTRUCTIVE-REVERT HAZARD. The natural revert is `git checkout -- <file>`, which discards ALL
# uncommitted changes in that file, not only the mutation. On spec-110 it wiped co-located uncommitted
# green edits. So COMMIT the green implementation BEFORE mutating (leaving the mutation as the only
# uncommitted change), or `git stash` before mutating and `git stash pop` after — either way the revert
# touches only the mutant. The Stryker `inPlace` variant rewrites the working tree the same way.
#
# Usage: bin/check-tdd.sh --record-lock [--batch <id>] [project-dir]
# Exit:  0 lock proven (recorded) · 1 suite stayed GREEN under the mutation (lock did not catch it) ·
#        3 no Test: command · 4 no uncommitted non-test mutation present · 6 no committed lock test in
#        the window · 64 bad usage.
if [ "${1:-}" = "--record-lock" ]; then
  shift
  rl_batch=""; rl_root="."
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) rl_batch="${2:-}"; shift 2 ;;
      -*) echo "check-tdd --record-lock: unknown flag '$1'" >&2; exit 64 ;;
      *) rl_root="$1"; shift ;;
    esac
  done
  cd "$rl_root" 2>/dev/null || { echo "check-tdd --record-lock: bad dir '$rl_root'" >&2; exit 64; }

  rl_cmd="$(_test_cmd)"
  case "$rl_cmd" in '') echo "check-tdd --record-lock: no runnable Test: command in AGENTS.md — cannot observe the lock." >&2; exit 3 ;; esac

  # The lock's proof requires a MUTATION to be present: a tracked, uncommitted change to a NON-test file
  # (mutating the behaviour, not the assertion). No such change ⇒ nothing to prove the lock against.
  rl_glob="$(read_test_globs)"; rl_mut=0
  while IFS= read -r rl_p; do
    [ -n "$rl_p" ] || continue
    is_test_path "$rl_p" "$rl_glob" && continue
    rl_mut=1; break
  done < <(git diff HEAD --name-only 2>/dev/null)
  if [ "$rl_mut" -eq 0 ]; then
    echo "check-tdd --record-lock: no uncommitted non-test change in the working tree — MUTATE the locked behaviour first (leave it uncommitted), then re-run so the lock can be seen to redden (#67). COMMIT the green implementation FIRST so the mutation is the ONLY uncommitted change: the revert afterward (\`git checkout -- <file>\`) discards ALL uncommitted changes in the file, not just the mutation — or \`git stash\`/\`stash pop\` around the mutation to preserve co-located work (#128)." >&2
    exit 4
  fi

  # The lock itself must be a COMMITTED test in this run's window, so the lock_sha recorded here is the
  # same test _find_lock later credits — symmetric to --record-red's F1 committed-test requirement.
  rl_marker="$(resolve_marker)"; rl_baseline=""
  [ -n "$rl_marker" ] && [ -f "$rl_marker" ] && rl_baseline="$(field_str "$(cat "$rl_marker" 2>/dev/null)" baseline_sha)"
  rl_base="$(resolve_sha "${rl_baseline:-}")" || rl_base=""
  [ -n "$rl_base" ] || rl_base="$(git rev-parse -q --verify 'HEAD^' 2>/dev/null || true)"
  if ! window_touches_test "$rl_base" "HEAD" "$rl_glob"; then
    echo "check-tdd --record-lock: no COMMITTED lock test in the window — commit the lock (a test that pins the behaviour) FIRST, then apply the mutation and re-run (#67)." >&2
    exit 6
  fi

  echo "check-tdd --record-lock: running tests under the mutation (expecting the lock to REDDEN) -> $rl_cmd" >&2
  if eval "$rl_cmd" >/dev/null 2>&1; then
    echo "check-tdd --record-lock: the suite stayed GREEN under your mutation — the lock did NOT catch it. Either the change does not affect the locked behaviour or the lock asserts nothing; strengthen the lock, then re-run (#67)." >&2
    exit 1
  fi

  rl_run="${TEAM_BOOTSTRAP_RUN:-}"
  [ -n "$rl_run" ] || rl_run="$(resolve_marker | sed -E 's#^\.runs/([^/]+)/RUN$#\1#')"
  [ -n "$rl_run" ] || rl_run="deliver-run"
  mkdir -p ".runs/$rl_run" 2>/dev/null || { echo "check-tdd --record-lock: cannot write .runs/$rl_run" >&2; exit 1; }
  rl_sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  [ -n "$rl_batch" ] || rl_batch="?"
  rl_esc="$(printf '%s' "$rl_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"batch":"%s","lock_sha":"%s","test_cmd":"%s","observed":"lock-kill"}\n' \
    "$rl_batch" "$rl_sha" "$rl_esc" >> ".runs/$rl_run/tdd.jsonl"
  echo "check-tdd --record-lock: LOCK proven (run=$rl_run batch=$rl_batch lock_sha=$rl_sha) — the lock reddened under the mutation. Revert the mutation so HEAD is green, then close. NB (#128): \`git checkout -- <file>\` reverts ALL uncommitted changes in that file, not only the mutation — safe only because you committed green first (or stashed); if not, \`git stash pop\` your work back rather than re-typing it." >&2
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

  # ---- #120 governed host_structural tdd-waiver: an unresolvable-red batch closes on a governed waiver --
  # B2's red is missing (its package is excluded from the top-level Test:, so no red is observable). With
  # no waiver the batch fails-closed; a governed tdd_waiver relieves it; an expired one does not.
  printf '%s\n' "{\"batch\":\"B1\",\"red_sha\":\"$rA\",\"observed\":\"red\"}" > "$T/.runs/r/tdd.jsonl"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  _chk "B2 red unresolvable, no waiver → fail-closed (#120 baseline)" 1
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" --waive founder "dashboard pkg excluded from Test:" 2999-01-01 ) >/dev/null 2>&1
  case "$(cat "$T/.runs/r/RUN")" in *'"tdd_waiver":{'*'"by":"founder"'*) echo "  PASS --waive wrote a governed tdd_waiver" ;;
    *) echo "  FAIL --waive did not write tdd_waiver: $(cat "$T/.runs/r/RUN")" >&2; fail=$((fail + 1)) ;; esac
  _chk "B2 red unresolvable + valid governed tdd_waiver → pass (#120)" 0
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s","tdd_waiver":{"ack":true,"by":"x","reason":"r","expires":"2000-01-01"}}\n' "$base" > "$T/.runs/r/RUN"
  got_exp="$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$here/check-tdd.sh" . >/dev/null 2>&1 ); echo $? )"
  if [ "$got_exp" = "1" ]; then echo "  PASS EXPIRED tdd_waiver is not a waiver → fail (#120)"; else echo "  FAIL expired tdd_waiver got exit $got_exp want 1" >&2; fail=$((fail + 1)); fi
  # --waive with a past expiry is REFUSED (exit 64/1), writes nothing.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  got_ref="$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" --waive x r 2000-01-01 >/dev/null 2>&1 ); echo $? )"
  if [ "$got_ref" = "1" ]; then echo "  PASS --waive past expiry → refused (#120)"; else echo "  FAIL --waive past expiry got exit $got_ref want 1" >&2; fail=$((fail + 1)); fi

  # marker-less → skip
  ( cd "$T" && rm -f .runs/r/RUN )
  _chk "no active marker → skip (exit 0)" 0
  rm -rf "$T"

  # generic exit-code check for the fixtures below (they invoke the gate with their own flags)
  _ec() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2, want $3) $1" >&2; fail=$((fail + 1)); fi; }

  # ---- #67 regression-lock: --record-lock observation (mutation-kill proof) ----------------------
  # A lock test asserts on a TRACKED behaviour file; the Test: command runs the lock. On correct
  # behaviour the lock is GREEN on arrival (no natural red). Its proof is that MUTATING the locked
  # behaviour reddens the lock — observed here, not "the suite was red at HEAD~1".
  LK="$(mktemp -d)"
  ( cd "$LK" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `sh lock_test.sh`\n' > AGENTS.md
    printf 'GOOD\n' > behaviour.txt
    git add . && git commit -qm baseline ) >/dev/null 2>&1
  lkbase="$( cd "$LK" && git rev-parse --short HEAD )"
  # the lock test is committed AFTER baseline (it IS the batch's code — a test pinning the behaviour)
  ( cd "$LK" && printf '#!/bin/sh\ngrep -q GOOD behaviour.txt\n' > lock_test.sh
    git add lock_test.sh && git commit -qm "lock: pin behaviour.txt" ) >/dev/null 2>&1
  mkdir -p "$LK/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$lkbase" > "$LK/.runs/r/RUN"
  _rl() { ( cd "$LK" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" --record-lock --batch B3 . >/dev/null 2>&1 ); echo $?; }
  # clean tree → no mutation to prove the lock against
  _ec "--record-lock, clean tree → refuse (no mutation present)" "$(_rl)" 4
  # tracked mutation that does NOT break the lock (suite stays green) → lock did not catch it
  ( cd "$LK" && printf 'GOOD and more\n' > behaviour.txt )
  _ec "--record-lock, mutation present but suite GREEN → refuse (lock did not catch)" "$(_rl)" 1
  ( cd "$LK" && git checkout -q -- behaviour.txt )
  # real mutation: breaks the locked behaviour → suite RED → lock kills the mutant → recorded
  ( cd "$LK" && printf 'BAD\n' > behaviour.txt )
  _ec "--record-lock, mutation reddens the lock → observed, recorded" "$(_rl)" 0
  ( cd "$LK" && git checkout -q -- behaviour.txt )
  _ec "--record-lock wrote a lock-kill record" "$( cd "$LK" && grep -c '"observed":"lock-kill"' .runs/r/tdd.jsonl 2>/dev/null || echo 0 )" 1
  rm -rf "$LK"

  # ---- #67 regression-lock: close-time acceptance of a lock proof ---------------------------------
  # A closed kind:code batch may satisfy red-first with EITHER a red record OR a lock record.
  CL="$(mktemp -d)"
  ( cd "$CL" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `test -f .green`\n' > AGENTS.md && : > .green
    git add . && git commit -qm baseline ) >/dev/null 2>&1
  clbase="$( cd "$CL" && git rev-parse --short HEAD )"
  ( cd "$CL" && echo t > lock_test.sh && git add lock_test.sh && git commit -qm "B3 lock test" ) >/dev/null 2>&1
  cLock="$( cd "$CL" && git rev-parse --short HEAD )"
  mkdir -p "$CL/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$clbase" > "$CL/.runs/r/RUN"
  printf '%s\n' "{\"id\":\"B3\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$cLock\"]}" > "$CL/.runs/r/batches.jsonl"
  _rc() { ( cd "$CL" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" . >/dev/null 2>&1 ); echo $?; }
  # lock record present → batch closes with NO red required (#67)
  printf '%s\n' "{\"batch\":\"B3\",\"lock_sha\":\"$cLock\",\"observed\":\"lock-kill\"}" > "$CL/.runs/r/tdd.jsonl"
  _ec "lock batch closes on a mutation-kill proof, no artificial red (#67)" "$(_rc)" 0
  # neither red nor lock → fail-closed
  : > "$CL/.runs/r/tdd.jsonl"
  _ec "code batch with neither a red nor a lock proof → fail-closed" "$(_rc)" 1
  rm -rf "$CL"

  # a "lock" batch that shipped only NON-test code (no lock test in its window) → fail (F1 analog)
  CL2="$(mktemp -d)"
  ( cd "$CL2" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `test -f .green`\n' > AGENTS.md && : > .green
    git add . && git commit -qm baseline ) >/dev/null 2>&1
  cl2base="$( cd "$CL2" && git rev-parse --short HEAD )"
  ( cd "$CL2" && echo 1 > impl.sh && git add impl.sh && git commit -qm "B3 non-test only" ) >/dev/null 2>&1
  c2Impl="$( cd "$CL2" && git rev-parse --short HEAD )"
  mkdir -p "$CL2/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$cl2base" > "$CL2/.runs/r/RUN"
  printf '%s\n' "{\"id\":\"B3\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$c2Impl\"]}" > "$CL2/.runs/r/batches.jsonl"
  printf '%s\n' "{\"batch\":\"B3\",\"lock_sha\":\"$c2Impl\",\"observed\":\"lock-kill\"}" > "$CL2/.runs/r/tdd.jsonl"
  _rc2() { ( cd "$CL2" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" . >/dev/null 2>&1 ); echo $?; }
  _ec "lock batch that shipped no lock test in its window → fail (a lock must be a test)" "$(_rc2)" 1
  rm -rf "$CL2"

  # ---- #68 red-by-cause bar in --record-red ------------------------------------------------------
  # The red must fail for a plausible target-behaviour reason, not a wrong-cause (collection/import/
  # syntax/missing-file) error that reddens the suite while proving nothing about the batch.
  WC="$(mktemp -d)"
  ( cd "$WC" && git init -q && git config user.email t@t && git config user.name t
    printf '# AGENTS\n\n- Test: `sh run.sh`\n' > AGENTS.md
    printf '#!/bin/sh\ncat out.txt\nexit 1\n' > run.sh && : > out.txt
    git add . && git commit -qm baseline ) >/dev/null 2>&1
  wcbase="$( cd "$WC" && git rev-parse --short HEAD )"
  ( cd "$WC" && echo t > wc_test.sh && git add wc_test.sh && git commit -qm "red: failing test committed" ) >/dev/null 2>&1
  mkdir -p "$WC/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$wcbase" > "$WC/.runs/r/RUN"
  _rr() { ( cd "$WC" && TEAM_BOOTSTRAP_RUN=r "$here/check-tdd.sh" --record-red --batch B1 . >/dev/null 2>&1 ); echo $?; }
  # wrong-cause: import/collection error, unrelated to the target test → reject
  ( cd "$WC" && printf 'ImportError: cannot import name foo\nModuleNotFoundError: No module named bar\n' > out.txt )
  _ec "--record-red, import/collection-error red → reject (#68 wrong-cause)" "$(_rr)" 5
  # wrong-cause: syntax error → reject
  ( cd "$WC" && printf 'SyntaxError: invalid syntax\n' > out.txt )
  _ec "--record-red, syntax-error red → reject (#68 wrong-cause)" "$(_rr)" 5
  # genuine assertion failure → accepted (no false-reject)
  ( cd "$WC" && printf 'FAIL test_x\nAssertionError: expected GOOD got BAD\n1 failed\n' > out.txt )
  _ec "--record-red, genuine assertion red → accepted (#68 no false-reject)" "$(_rr)" 0
  # empty-output red (e.g. a bare \`test -f\`) → accepted (must not false-reject a real red)
  ( cd "$WC" && : > out.txt )
  _ec "--record-red, empty-output red → accepted (no false-reject)" "$(_rr)" 0
  # #121 stale-red-sha: an UNCOMMITTED test file in the working tree → red_sha would be stamped at HEAD
  # (empty F1 window) → refuse with exit 4 (commit the failing test first).
  ( cd "$WC" && printf 'FAIL\nAssertionError: x\n1 failed\n' > out.txt && echo t > dirty_test.sh )
  _ec "--record-red, uncommitted test in tree → refuse (#121 stale-red-sha)" "$(_rr)" 4
  ( cd "$WC" && rm -f dirty_test.sh )
  rm -rf "$WC"

  if [ "$fail" -eq 0 ]; then echo "check-tdd --self-test: OK"; exit 0; fi
  echo "check-tdd --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-tdd: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
