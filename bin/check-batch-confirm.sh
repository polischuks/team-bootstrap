#!/usr/bin/env bash
# check-batch-confirm.sh — per-batch operator-confirmation checkpoint (issue #56).
#
# THE PROBLEM IT REPLACES. commands/deliver.md used to tell the orchestrator to WAIT for operator
# "fire" before EVERY batch, unconditionally. That pause was prose, not a mechanism: no hook enforced
# it and none read the `risk_rank` the ledger already records, so it halted on fully reversible batches
# (a pure function + test, committed locally on a feature branch behind guard-git and undone by
# `git reset`) for a guarantee that protected nothing there. #56 makes the default NON-STOP and moves
# the stop onto this deterministic gate, which READS the ledger field instead of asking the model to
# remember to check the rank.
#
# WHAT IT DOES. A BLOCKING PreToolUse[Bash] gate. On an armed intends_code run, when the model is about
# to `git commit`/`git merge` (the progression-to-commit point), it looks up the in-flight batch (the
# last still-`announced` ledger entry) and blocks (exit 2) IFF that batch's declared
# `risk_rank ∈ {irreversible, run-rate}` OR it carries `manual_approval_requested:true`, AND no
# confirmation for that batch id is recorded in the ledger. Everything else — a reversible rank
# (feature|doc), an unknown/absent rank, a recorded confirmation, a non-commit command, off-delivery,
# or a kill-switch — is allowed (exit 0). Net effect: reversible batches run with zero prompts; an
# irreversible/run-rate (or role-flagged) batch cannot reach commit until a confirmation is recorded.
#
# HOW A CONFIRMATION IS RECORDED. When the operator fires ("fire"/"continue"), the orchestrator appends
# one line to .runs/<run>/batches.jsonl:  {"confirm":"<batch-id>"}  — the same append-only ledger it
# already writes the announce entry to (commands/deliver.md, Phase B). This gate reads that line; it is
# an auditable, machine-checked record, not a prose pause the model may forget.
#
# THE FORGED-LOW-RANK LAYERING (ADR-0006). `risk_rank` is self-declared and FORGEABLE, and the codebase
# treats it one-directionally (it may only LIFT a tier, never lower one). This gate inherits that
# posture: it only ever ADDS friction ABOVE the action-class layer. A batch that forges a LOWER rank
# (claims `feature` while doing something irreversible) escapes THIS friction gate — but its irreversible
# ACTIONS are unaffected: a commit on the default branch is still blocked by guard-git.sh (exit 2), and
# push/deploy are still the remote's branch-protection backstop (references/irreversibility.md). So this
# checkpoint is never the SOLE guard for irreversibility; it is the operator-checkpoint friction on top.
# Consequently the command parsing below is best-effort (friction, not a security boundary): a missed
# commit lets a LOCAL, `git reset`-able commit through, while the real irreversible actions stay gated.
#
# SAFETY. TOTAL (anything unrecognized/undecodable/malformed ⇒ exit 0, never break the shell), marker-
# gated (no active intends_code run ⇒ no-op), and kill-switchable (TEAM_BOOTSTRAP_DELIVERY_GATE=off or
# TEAM_BOOTSTRAP_BATCHCONFIRM=off ⇒ exit 0), so a parse bug can't brick the delivery shell.
#
# Usage: (hook) echo '<PreToolUse json>' | bin/check-batch-confirm.sh   ·   --self-test
# Exit:  0 allow (or no-op) · 2 blocked (unconfirmed irreversible/run-rate/manual-approval commit).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _decode_command → read the raw PreToolUse JSON on stdin, print the decoded tool_input.command string
# (empty if absent). A JSON-string decoder (no jq): un-escapes \" \\ \n \t \r \/ ; leaves \uXXXX literal.
# Ported from guard-git.sh so the two hooks decode identically; the blocking path stays awk (not python),
# matching guard-git's portability posture.
_decode_command() {
  awk '
    BEGIN { RS="\1"; ORS="" }
    {
      s=$0; key="\"command\""
      p=index(s,key); if (p==0) exit
      rest=substr(s,p+length(key)); n=length(rest); i=1
      while (i<=n){ c=substr(rest,i,1); if(c==":"){i++;break} if(c==" "||c=="\t"||c=="\n"||c=="\r"){i++;continue} exit }
      while (i<=n){ c=substr(rest,i,1); if(c=="\""){i++;break} if(c==" "||c=="\t"||c=="\n"||c=="\r"){i++;continue} exit }
      out=""
      while (i<=n){
        c=substr(rest,i,1)
        if (c=="\\"){
          e=substr(rest,i+1,1)
          if      (e=="\"") out=out "\""
          else if (e=="\\") out=out "\\"
          else if (e=="n")  out=out "\n"
          else if (e=="t")  out=out "\t"
          else if (e=="r")  out=out "\r"
          else if (e=="/")  out=out "/"
          else if (e=="u"){ out=out "\\u"; i+=2; continue }
          else              out=out "\\" e
          i+=2; continue
        }
        if (c=="\"") break
        out=out c; i++
      }
      print out
    }
  '
}

# _strip_quotes STR → STR with all `"` and `'` removed (de-obfuscation of a quoted binary/subcommand token).
_strip_quotes() { local s="${1//\"/}"; printf '%s' "${s//\'/}"; }

# _segments DECODED_CMD → one shell segment per line, splitting on & | ; ( ) and newline ONLY when NOT
# inside single/double quotes (so a `;`/`&&` inside a quoted arg does not create a fake segment). Ported
# from guard-git.sh.
_segments() {
  local s="$1" n i c q="" seg="" NL
  NL=$'\n'
  n=${#s}; i=0
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"; i=$((i + 1))
    if [ "$c" = "\\" ] && [ "$q" != "'" ]; then
      seg="$seg$c"
      if [ "$i" -lt "$n" ]; then seg="$seg${s:i:1}"; i=$((i + 1)); fi
      continue
    fi
    if [ -n "$q" ]; then
      seg="$seg$c"; [ "$c" = "$q" ] && q=""; continue
    fi
    case "$c" in
      '"'|"'")             q="$c"; seg="$seg$c" ;;
      '&'|'|'|';'|'('|')') printf '%s\n' "$seg"; seg="" ;;
      *) if [ "$c" = "$NL" ]; then printf '%s\n' "$seg"; seg=""; else seg="$seg$c"; fi ;;
    esac
  done
  printf '%s\n' "$seg"
}

# _is_commit_or_merge DECODED_CMD → return 0 if any segment is a `git commit`/`git merge` (subcommand
# position; honors an env-assignment prefix and -C/--git-dir/--work-tree/-c options before the sub). This
# is the branch-AGNOSTIC twin of guard-git's _commit_or_merge_on_default: guard-git asks "commit on the
# default branch?"; this asks "a commit/merge at all?", because the confirmation checkpoint applies on any
# branch. Best-effort by design (see header): friction, not a boundary.
_is_commit_or_merge() {
  local seg tok sub sq envre
  sq="'"
  envre="^([A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]]*)[[:space:]]+)+"
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    seg="${seg#"${seg%%[![:space:]]*}"}"                       # ltrim
    [[ "$seg" =~ $envre ]] && seg="${seg:${#BASH_REMATCH[0]}}"
    tok="${seg%%[[:space:]]*}"
    case "$(_strip_quotes "$tok")" in git|*/git) ;; *) continue ;; esac
    # shellcheck disable=SC2086
    set -- $seg
    shift                                                      # drop 'git'
    sub=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -C)            shift; shift; continue ;;
        -C*)           shift; continue ;;
        --git-dir)     shift; shift; continue ;;
        --git-dir=*)   shift; continue ;;
        --work-tree)   shift; shift; continue ;;
        --work-tree=*) shift; continue ;;
        -c)            shift; shift; continue ;;
        -c*)           shift; continue ;;
        --)            shift; [ $# -gt 0 ] && sub="$1"; break ;;
        -*)            shift; continue ;;
        *)             sub="$1"; break ;;
      esac
    done
    case "$(_strip_quotes "$sub")" in commit|merge) return 0 ;; esac
  done < <(_segments "$1")
  return 1
}

# _inflight_line LEDGER → the last still-`announced` ledger entry (the batch being worked), or empty.
# Same selector stamp_batch_closed uses to pick which entry to flip closed.
_inflight_line() {
  grep -nE '"status":[[:space:]]*"announced"' "$1" 2>/dev/null | tail -1 | sed -E 's/^[0-9]+://'
}

# _confirmed LEDGER BID → return 0 if a confirmation for batch BID is recorded (a ledger line whose
# "confirm" field equals BID).
_confirmed() {
  local ledger="$1" bid="$2" l
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    [ "$(field_str "$l" confirm)" = "$bid" ] && return 0
  done < "$ledger"
  return 1
}

# check_batch_confirm PAYLOAD → the pure core. Returns 0 (allow/no-op) or 2 (block).
check_batch_confirm() {
  local payload="$1" marker ledger cmd line bid rank manual
  [ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && return 0
  [ "${TEAM_BOOTSTRAP_BATCHCONFIRM:-on}" = "off" ] && return 0
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0            # no active run ⇒ no-op
  [ "$(field_bool "$(cat "$marker")" intends_code)" = "true" ] || return 0
  cmd="$(printf '%s' "$payload" | _decode_command)"
  [ -n "$cmd" ] || return 0                                   # nothing decodable ⇒ allow (total)
  _is_commit_or_merge "$cmd" || return 0                      # only commit/merge is the progression point

  ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0            # no ledger (direct pipeline) ⇒ nothing to gate
  line="$(_inflight_line "$ledger")"
  [ -n "$line" ] || return 0                                  # no in-flight announced batch ⇒ allow

  rank="$(field_str "$line" risk_rank)"
  manual="$(field_bool "$line" manual_approval_requested)"
  # Stop condition: an unrecoverable-by-reset rank OR a role that explicitly flagged a question.
  case "$rank" in irreversible|run-rate) : ;; *) [ "$manual" = "true" ] || return 0 ;; esac

  bid="$(field_str "$line" id)"
  [ -n "$bid" ] && _confirmed "$ledger" "$bid" && return 0    # a recorded confirmation unblocks it

  printf 'check-batch-confirm: BLOCKED — the in-flight batch (%s) is %s%s and has no recorded operator confirmation.\n  This is the per-batch checkpoint (#56): reversible batches run non-stop, but an irreversible/run-rate (or role-flagged) batch must be confirmed before its work is committed.\n  On the operator'\''s go ("fire"), record the confirmation, then retry:\n    printf '\''%%s\\n'\'' '\''{"confirm":"%s"}'\'' >> %s\n  (Irreversible git ACTIONS remain gated by guard-git / remote branch-protection regardless of rank.)\n' \
    "${bid:-?}" "${rank:+risk_rank=$rank}" "$( [ "$manual" = "true" ] && printf ' manual_approval_requested' )" "${bid:-BID}" "$ledger" >&2
  return 2
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  (
    cd "$T" || exit 1
    git init -q; git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email t@t && git config user.name t
    echo base > f && git add . && git commit -qm base
    mkdir -p .runs/r && printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > .runs/r/RUN
  ) >/dev/null 2>&1
  _led() { : > "$T/.runs/r/batches.jsonl"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$T/.runs/r/batches.jsonl"; done; }
  _r()  { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$here/check-batch-confirm.sh" >/dev/null 2>&1 ); echo $?; }
  _chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit '$1' want '$2')" >&2; fail=$((fail + 1)); fi; }
  P() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
  C="$(P 'git commit -m x')"

  _led '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  _chk "$(_r "$C")" 0 "reversible feature commit → allow"
  _led '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}'
  _chk "$(_r "$C")" 2 "irreversible, no confirm → block"
  _led '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}' '{"confirm":"B1"}'
  _chk "$(_r "$C")" 0 "irreversible + confirm → allow"
  _led '{"id":"B1","kind":"code","risk_rank":"feature","manual_approval_requested":true,"status":"announced"}'
  _chk "$(_r "$C")" 2 "manual_approval_requested → block"
  _led '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}'
  _chk "$(_r "$(P 'git add -A')")" 0 "git add → allow (not commit)"
  _chk "$(_r 'not json')" 0 "undecodable → allow (total)"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-batch-confirm --self-test: OK"; exit 0; fi
  echo "check-batch-confirm --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- hook entry: read the PreToolUse payload from stdin, decide, block with exit 2 if warranted ----
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0   # gate-integrity: sanctioned — kill-switch, silent no-op by design
[ "${TEAM_BOOTSTRAP_BATCHCONFIRM:-on}" = "off" ] && exit 0    # gate-integrity: sanctioned — kill-switch, silent no-op by design
payload="$(head -c 1048576 2>/dev/null || true)"
check_batch_confirm "$payload"
exit $?
