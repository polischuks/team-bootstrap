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
