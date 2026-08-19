#!/usr/bin/env bash
# guard-git.sh — BLOCKING PreToolUse[Bash] guard (milestone branch-protection-gate, v2.25.0).
#
# Hardens P5 (irreversibility) at the harness: on an armed delivery run, a `git commit`/`git merge`
# whose CURRENT branch is the DEFAULT branch (main/master/…) is refused (exit 2, "branch first"). A
# delivery commit must land on a feature branch; the default branch is reached only via a human-authored
# PR (GitHub Copilot's copilot/-branch model). Remediation is trivial and SAFE — branch, then retry — so a
# rare false-positive costs a branch-and-retry, never data.
#
# SCOPE (shrunk over two adversarial review rounds — see specs/branch-protection-gate/):
#   - It blocks ONLY commit/merge-on-default. It does NOT gate `git push` / `gh pr merge` / `gh api`
#     (round-1 BF1): a chained push can't be extracted from the command string false-pass-safely, and any
#     "push_ack" would be orchestrator-self-written in the same turn (hollow). Remote-write authorization
#     stays P5 prose + check-preconditions advisory; the HARD backstop is the remote's branch-protection
#     (required PR review) — org config the plugin can't force.
#   - Best-effort git-parsing, NOT a security boundary: it catches the default/accidental invocation
#     (incl. `git -C p`, `ENV=… git`, `&&`/`;`/`|`/newline chains, after JSON-decode); an obfuscated form
#     (eval, subshell, alias, `cd other && git commit` in another repo) can slip. Branch-detection is
#     best-effort too (no origin/HEAD ⇒ main/master fallback) — always in the SAFE direction.
#
# WHY a JSON-decode, not field_str (round-1 BF1): delivery-lib's field_str terminates at the first quote,
# so `git commit -m "wip" && git push` would truncate to `git commit -m \` and lose a chained op. This hook
# decodes tool_input.command as a JSON string (un-escapes \" \\ \n \t \r \/; leaves \uXXXX literal — a
# documented non-goal, bash 3.2 can't printf code points and every matched token is ASCII) so chained and
# multi-line segments survive; the scan is subcommand-position (first token of each segment) so a message
# body like -m "…push…" or an `echo "git commit"` never triggers a block.
#
# SAFETY: first BLOCKING hook on the universal Bash path. It is TOTAL (anything unrecognized/undecodable/
# malformed-marker ⇒ exit 0, never break the shell), FAST, and has a KILL-SWITCH
# (TEAM_BOOTSTRAP_DELIVERY_GATE=off or TEAM_BOOTSTRAP_GITGUARD=off ⇒ exit 0) so a parse bug can't brick the
# delivery shell. Sub-git calls run under `timeout`/`gtimeout` ONLY when present (this host has neither) —
# else bare, since rev-parse/symbolic-ref are local and instant.
#
# Marker-gated: no active intends_code run ⇒ no-op (off-delivery, ordinary local commits are free).
#
# Usage: (hook) echo '<PreToolUse json>' | bin/guard-git.sh   ·   bin/guard-git.sh --self-test
# Exit:  0 allow (or no-op) · 2 blocked (commit/merge on the default branch).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

GUARD_BRANCH=""   # set by _on_default_branch when it blocks (for the message)

# _decode_command → read the raw PreToolUse JSON on stdin, print the decoded tool_input.command string
# (empty if absent). A JSON-string decoder (no jq): un-escapes \" \\ \n \t \r \/ ; leaves \uXXXX literal.
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
          else if (e=="u"){ out=out "\\u"; i+=2; continue }   # leave \uXXXX literal (non-goal)
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

# _on_default_branch DIR → return 0 if DIR's current branch IS the default branch (and stash it in
# GUARD_BRANCH); else return 1. Best-effort + portable termination (timeout only if present).
_on_default_branch() {
  local dir="$1" cur def to=""
  if [ -z "${TEAM_BOOTSTRAP_GITGUARD_FORCE_BARE:-}" ]; then
    if   command -v timeout  >/dev/null 2>&1; then to="timeout 5"
    elif command -v gtimeout >/dev/null 2>&1; then to="gtimeout 5"
    fi
  fi
  # shellcheck disable=SC2086
  cur="$($to git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$cur" ] && [ "$cur" != "HEAD" ] || return 1   # not a repo / detached ⇒ don't block (safe)
  # shellcheck disable=SC2086
  def="$($to git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  def="${def#origin/}"
  if [ -z "$def" ]; then
    case "$cur" in main|master) def="$cur" ;; *) def="main" ;; esac   # fallback (safe direction)
  fi
  if [ "$cur" = "$def" ]; then GUARD_BRANCH="$cur"; return 0; fi
  return 1
}

# _commit_or_merge_on_default DECODED_CMD → return 0 if a git commit/merge in the command targets the
# default branch. Splits on && || | ; ( ) and newline (over-split is safe); subcommand-position scan.
_commit_or_merge_on_default() {
  local norm seg tok cwd sub
  norm="$(printf '%s' "$1" | tr '&|;()' '\n\n\n\n\n')"
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    seg="${seg#"${seg%%[![:space:]]*}"}"                       # ltrim
    while printf '%s' "$seg" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; do
      seg="${seg#* }"; seg="${seg#"${seg%%[![:space:]]*}"}"    # drop a leading ENV=val token
    done
    tok="${seg%%[[:space:]]*}"
    case "$tok" in git|*/git) ;; *) continue ;; esac           # first token must be git
    # shellcheck disable=SC2086
    set -- $seg
    shift                                                      # drop 'git'
    cwd="."; sub=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -C) shift; cwd="${1:-.}"; shift; continue ;;           # -C <path> overrides cwd
        -c) shift; shift; continue ;;                          # -c <k=v> takes an arg
        --) shift; [ $# -gt 0 ] && { sub="$1"; }; break ;;
        -*) shift; continue ;;                                 # any other option before the subcommand
        *)  sub="$1"; break ;;
      esac
    done
    case "$sub" in
      commit|merge) _on_default_branch "$cwd" && return 0 ;;
    esac
  done < <(printf '%s\n' "$norm")
  return 1
}

# guard_git PAYLOAD → the pure core (own function so the self-test can drive it). Returns 0 (allow/no-op)
# or 2 (blocked: commit/merge on the default branch).
guard_git() {
  local payload="$1" marker cmd
  [ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && return 0
  [ "${TEAM_BOOTSTRAP_GITGUARD:-on}" = "off" ] && return 0
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0            # no active run ⇒ no-op
  [ "$(field_bool "$(cat "$marker")" intends_code)" = "true" ] || return 0
  cmd="$(printf '%s' "$payload" | _decode_command)"
  [ -n "$cmd" ] || return 0                                   # nothing decodable ⇒ allow (total)
  if _commit_or_merge_on_default "$cmd"; then
    printf 'guard-git: BLOCKED — you are on the default branch (%s). A delivery commit must land on a feature branch; the default branch is reached only via a human-authored PR (P5).\n  Branch first:  git checkout -b <feature>\n  (git push / gh pr merge are NOT gated here — configure required-PR-review branch protection on the remote.)\n' "${GUARD_BRANCH:-default}" >&2
    return 2
  fi
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  (
    cd "$T" || exit 1
    git init -q; git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email t@t && git config user.name t
    echo base > f && git add . && git commit -qm base
    mkdir -p .runs/r   && printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > .runs/r/RUN
    mkdir -p .runs/bad && printf '{"run":"bad","pipeline":"full","source":"harness","baseline_sha":"x"}\n'                    > .runs/bad/RUN
  ) >/dev/null 2>&1
  _g()  { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$here/guard-git.sh" >/dev/null 2>&1 ); echo $?; }
  # shellcheck disable=SC2086  # $1 carries intentional multi-word env assignments (VAR=val …)
  _gE() { ( cd "$T" && printf '%s' "$2" | env $1 bash "$here/guard-git.sh" >/dev/null 2>&1 ); echo $?; }
  _on() { ( cd "$T" && git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" ) >/dev/null 2>&1; }
  _chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit '$1' want '$2')" >&2; fail=$((fail + 1)); fi; }
  P() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

  _on main
  _chk "$(_g "$(P 'git commit -m hi')")"                       2 "commit on default → block"
  _chk "$(_g "$(P 'git -C . commit -m hi')")"                  2 "git -C . commit on default → block"
  _chk "$(_g "$(P 'git merge x')")"                            2 "merge on default → block"
  _chk "$(_g "$(P 'git add -A\ngit commit -m x')")"            2 "multi-line commit on default → block (newline split)"
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \"hi\" && git commit -m x"}}')" 2 "quoted-echo && commit → block (decode)"
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \"git commit\""}}')"            0 "echo mentioning tokens → allow"
  _chk "$(_g "$(P 'git push origin main')")"                   0 "push on default → NOT gated (disclosed)"
  _chk "$(_g "$(P 'gh pr merge 1 --merge')")"                  0 "gh pr merge → NOT gated (disclosed)"
  _on feature
  _chk "$(_g "$(P 'git commit -m hi')")"                       0 "commit on feature branch → allow"
  _on main
  _chk "$(_g "$(P 'ls -la')")"                                 0 "non-git → allow"
  _chk "$(_gE 'TEAM_BOOTSTRAP_RUN=none' "$(P 'git commit -m x')")"                          0 "no marker → allow"
  _chk "$(_gE 'TEAM_BOOTSTRAP_RUN=bad'  "$(P 'git commit -m x')")"                          0 "marker without intends_code → allow"
  _chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_GITGUARD=off' "$(P 'git commit -m x')")" 0 "kill-switch → allow"
  _chk "$(_g 'not json')"                                      0 "undecodable → allow (total)"
  _chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_GITGUARD_FORCE_BARE=1' "$(P 'git commit -m x')")" 2 "forced-bare (no timeout) commit on default → still block"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "guard-git --self-test: OK"; exit 0; fi
  echo "guard-git --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- hook entry: read the PreToolUse payload from stdin, decide, block with exit 2 if warranted ----
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
[ "${TEAM_BOOTSTRAP_GITGUARD:-on}" = "off" ] && exit 0
payload="$(head -c 1048576 2>/dev/null || true)"
guard_git "$payload"
exit $?
