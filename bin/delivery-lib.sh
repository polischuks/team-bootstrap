#!/usr/bin/env bash
# shellcheck shell=bash
# delivery-lib.sh — shared helpers for the delivery-occurred gate, the batch
# stamper, and the delivery-aware Stop hook. Sourced, never executed.
#
# One definition of: ledger/marker resolution, the compact-JSONL field extractors,
# SHA resolution, the risk_rank enum, and — critically — the non-doc code delta.
# check-delivery.sh RECOMPUTES the delta to verify a stamp; verify-batch.sh COMPUTES
# it to write the stamp. They share THIS function so recompute and stamp cannot
# diverge (spec R1): a batch verify-batch stamps will, by construction, pass the
# check-delivery recompute. Sourcing has no side effects.

# resolve_ledger — echo the active batch ledger path (or empty).
#   If $TEAM_BOOTSTRAP_RUN names a run, resolve to THAT run only (empty if it has no
#   ledger yet) — a named run means that run, not "whatever's newest", and this keeps
#   a self-test run isolated from any real ledger in the tree. Unset => newest.
resolve_ledger() {
  if [ -n "${TEAM_BOOTSTRAP_RUN:-}" ]; then
    [ -f ".runs/${TEAM_BOOTSTRAP_RUN}/batches.jsonl" ] && printf '%s' ".runs/${TEAM_BOOTSTRAP_RUN}/batches.jsonl"
    return 0
  fi
  ls -t .runs/*/batches.jsonl 2>/dev/null | head -1 || true
}

# resolve_marker — echo the active RUN marker path (or empty). Same run-scoping rule.
resolve_marker() {
  if [ -n "${TEAM_BOOTSTRAP_RUN:-}" ]; then
    [ -f ".runs/${TEAM_BOOTSTRAP_RUN}/RUN" ] && printf '%s' ".runs/${TEAM_BOOTSTRAP_RUN}/RUN"
    return 0
  fi
  ls -t .runs/*/RUN 2>/dev/null | head -1 || true
}

# field_str LINE KEY  → "key":"value"  string value
field_str() { printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/\"$2\":\"([^\"]*)\"/\1/"; }
# field_num LINE KEY  → "key":<int>    integer value
field_num() { printf '%s' "$1" | grep -oE "\"$2\":-?[0-9]+" | head -1 | sed -E "s/\"$2\"://"; }
# field_bool LINE KEY → "key":true|false
field_bool() { printf '%s' "$1" | grep -oE "\"$2\":(true|false)" | head -1 | sed -E "s/\"$2\"://"; }

# extract every commit_sha from a ledger line as space-separated tokens.
shas_of_line() {
  printf '%s' "$1" | grep -oE "\"commit_shas\":\[[^]]*\]" | head -1 \
    | grep -oE '"[0-9a-fA-F]+"' | tr -d '"' | tr '\n' ' '
}

# resolve_sha SHA → full commit hash if it names a commit, else empty (rc 1).
# Abbrev-safe: the historical ledger stores 7-char SHAs.
resolve_sha() { git rev-parse --verify -q "$1^{commit}" 2>/dev/null; }

# risk_rank_int NAME → integer rank (higher = more load-bearing); empty if unknown.
risk_rank_int() {
  case "$1" in
    irreversible) printf '4' ;;
    run-rate)     printf '3' ;;
    feature)      printf '2' ;;
    doc)          printf '1' ;;
    *)            printf '' ;;
  esac
}

# _is_doc_path PATH → rc 0 if the path is documentation / non-code.
# ONE definition of the non-doc boundary, shared by delta + stamp.
_is_doc_path() {
  case "$1" in
    *.md|*.mdx|*.txt|docs/*|references/*|LICENSE|CHANGELOG*) return 0 ;;
    *) return 1 ;;
  esac
}

# code_since_baseline BASELINE → rc 0 if there is > 0 non-doc code delta on commits
# reachable from HEAD since BASELINE, else rc 1 (incl. unresolvable/empty baseline).
#
# The direct-pipeline delivery signal. `/deliver` writes a batch ledger and closes it with
# verify-batch; but a direct pipeline run (`/team-bootstrap single-thread …`, which deliver.md
# itself recommends for small changes) writes NO ledger. Such a run still proves delivery the
# same git-grounded way: real code committed since the run baseline, reachable from HEAD —
# unforgeable by prose. The guard accepts EITHER a git-verified ledger closure OR this signal.
# Uses the same shared nondoc_delta_of_shas, so "code" means the same thing everywhere.
code_since_baseline() {
  local bfull shas d
  bfull="$(resolve_sha "${1:-}")" || bfull=""
  [ -n "$bfull" ] || return 1
  shas="$(git log --format=%h "${bfull}..HEAD" 2>/dev/null | head -200 | tr '\n' ' ')"
  [ -n "$shas" ] || return 1
  d="$(nondoc_delta_of_shas "$shas")"; case "$d" in ''|*[!0-9]*) d=0 ;; esac
  [ "$d" -gt 0 ]
}

# --- F1 (red-touches-tests) test-path detection --------------------------------
# is_test_path PATH [EXTRA_GLOBS] → rc 0 if PATH is a test file, else rc 1.
# Default set (OQ-1): basename matches *_test.* *.test.* test_*.* *.spec.* *Test.* *_spec.rb,
# OR any path segment ∈ {test, tests, spec, __tests__}. EXTRA_GLOBS (space/comma-separated,
# from AGENTS.md TestGlobs:) EXTENDS the default set — a project can widen the check, never
# shrink it. Extra globs are matched against BOTH the full path and the basename.
is_test_path() {
  local p="$1" extra="${2:-}" base glob
  base="${p##*/}"
  case "$base" in
    *_test.*|*.test.*|test_*.*|*.spec.*|*Test.*|*_spec.rb) return 0 ;;
  esac
  case "/$p/" in
    */test/*|*/tests/*|*/spec/*|*/__tests__/*) return 0 ;;
  esac
  if [ -n "$extra" ]; then
    extra="${extra//,/ }"
    for glob in $extra; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254  # unquoted on purpose: $glob is a glob pattern to match
      case "$p" in $glob) return 0 ;; esac
      # shellcheck disable=SC2254
      case "$base" in $glob) return 0 ;; esac
    done
  fi
  return 1
}

# read_test_globs [DOC] → echo the space-separated globs on a `TestGlobs:` line in
# AGENTS.md/CLAUDE.md (empty if none). Values may be backticked or bare, comma- or
# space-separated. Extends is_test_path's default set; never replaces it.
read_test_globs() {
  local doc="${1:-}" f rest
  if [ -z "$doc" ]; then for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done; fi
  [ -n "$doc" ] && [ -f "$doc" ] || return 0
  rest="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*TestGlobs:" "$doc" 2>/dev/null | head -1 | sed -E 's/^[^:]*://')"
  [ -n "$rest" ] || return 0
  printf '%s' "$rest" | tr -d '`' | tr ',' ' ' | xargs 2>/dev/null || true
}

# window_touches_test BASE TIP [EXTRA_GLOBS] → rc 0 if the diff BASE..TIP changes ≥1 test path.
# BASE empty ⇒ compare against the canonical empty tree (TIP's whole content). Used by check-tdd
# (F1) to require a code batch's red window to have changed a test file.
window_touches_test() {
  local base="$1" tip="$2" extra="${3:-}" p
  [ -n "$base" ] || base="4b825dc642cb6eb9a060e54bf8d69288fbee4904"  # git empty tree
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    is_test_path "$p" "$extra" && return 0
  done < <(git diff --name-only "$base" "$tip" 2>/dev/null)
  return 1
}

# nondoc_delta_of_shas "sha1 sha2 …" → Σ (added+deleted) lines on NON-doc files
# across the commits, counted PER COMMIT (self-contained; does not drift with later
# history — OQ-4). Unresolvable SHAs contribute 0; callers enforce existence
# separately (AC-1). IFS is pinned locally so a caller's IFS cannot corrupt splitting.
nondoc_delta_of_shas() {
  local shas="$1" sha full add del path total=0
  local -a list=()
  IFS=' ' read -r -a list <<<"$shas"
  for sha in "${list[@]}"; do
    [ -n "$sha" ] || continue
    full="$(resolve_sha "$sha")" || full=""
    [ -n "$full" ] || continue
    while IFS="$(printf '\t')" read -r add del path; do
      [ -n "${path:-}" ] || continue
      _is_doc_path "$path" && continue
      case "$add" in ''|*[!0-9]*) add=0 ;; esac
      case "$del" in ''|*[!0-9]*) del=0 ;; esac
      total=$((total + add + del))
    done < <(git show --numstat --format= "$full" 2>/dev/null)
  done
  printf '%s' "$total"
}

# --- F2 (diff-coverage) batch window ------------------------------------------
# current_batch_base — echo the base ref/sha for the IN-FLIGHT batch's diff, using the EXACT
# chain verify-batch.sh's stamp uses: newest commit of the last `closed` ledger entry → the first
# existing of origin/main|main|origin/master|master (if it differs from HEAD) → HEAD~1. F2 and the
# code_delta stamp both take their window from HERE, so "the batch's changed lines" is one definition
# and cannot drift (spec R1). Echoes a usable base (empty only in a repo with no HEAD~1).
current_batch_base() {
  local ledger since base b
  ledger="$(resolve_ledger)"
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    since="$(grep '"status":"closed"' "$ledger" 2>/dev/null | tail -1 \
      | sed -nE 's/.*"commit_shas":\["([0-9a-fA-F]+)".*/\1/p')"
    if [ -n "$since" ] && git rev-parse --verify -q "$since^{commit}" >/dev/null 2>&1; then
      printf '%s' "$since"; return 0
    fi
  fi
  base=""
  for b in origin/main main origin/master master; do
    if git rev-parse --verify -q "$b^{commit}" >/dev/null 2>&1; then base="$b"; break; fi
  done
  if [ -n "$base" ] && [ "$(git rev-parse -q "$base" 2>/dev/null)" != "$(git rev-parse -q HEAD 2>/dev/null)" ]; then
    printf '%s' "$base"; return 0
  fi
  git rev-parse --verify -q 'HEAD~1^{commit}' >/dev/null 2>&1 && printf 'HEAD~1'
  return 0
}

# changed_nondoc_lines BASE → emit "path:line" for each added/changed NON-doc line in BASE..HEAD
# (git diff --unified=0, new-side hunk ranges). Doc paths (_is_doc_path) are filtered out. Pure
# deletions (new-side count 0) contribute nothing. Used by F2 as the denominator's source set.
changed_nondoc_lines() {
  local base="$1" path="" line plus start cnt i
  [ -n "$base" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*) path="${line#+++ b/}" ;;
      "+++ "*)   path="" ;;
      "@@ "*)
        [ -n "$path" ] || continue
        _is_doc_path "$path" && continue
        plus="$(printf '%s' "$line" | sed -nE 's/^@@ [^+]*\+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p')"
        [ -n "$plus" ] || continue
        start="${plus%% *}"; cnt="${plus##* }"
        case "$cnt" in ''|*[!0-9]*) cnt=1 ;; esac
        [ "$cnt" -eq 0 ] && continue
        i=0
        while [ "$i" -lt "$cnt" ]; do printf '%s:%s\n' "$path" "$((start + i))"; i=$((i + 1)); done
        ;;
    esac
  done < <(git diff --unified=0 "$base" HEAD 2>/dev/null)
}
