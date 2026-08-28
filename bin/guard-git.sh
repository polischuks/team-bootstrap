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
#   - It blocks commit/merge-on-default, PLUS — since pipeline-integrity-hardening (WS-D) — any
#     UNRECOGNIZED git subcommand on the default branch under an armed run (the fail-closed posture that
#     catches `-c alias.ci=commit ci` and other obfuscating tokens; recognized non-commit/merge
#     subcommands, incl. push/pull, stay fail-open). DISCLOSED LIMIT (#6): recognized non-commit/merge
#     mutations — `cherry-pick`, `revert`, `am`, `rebase`, `reset`, `commit-tree` — are allow-listed and can
#     therefore LAND commits on the default branch without blocking (they are kept fail-open to hold the
#     false-positive rate low; the hard backstop is remote branch-protection). It does NOT gate `git push` / `gh pr merge` / `gh api`
#     (round-1 BF1): a chained push can't be extracted from the command string false-pass-safely, and any
#     "push_ack" would be orchestrator-self-written in the same turn (hollow). Remote-write authorization
#     stays P5 prose + check-preconditions advisory; the HARD backstop is the remote's branch-protection
#     (required PR review) — org config the plugin can't force.
#   - Registered with `if: "Bash(git *)"` (permission-rule syntax), which filters BEFORE the process is
#     spawned: the guard used to start on every single Bash call to conclude "not git" in a subshell.
#     The filter is best-effort and FAIL-OPEN by design, so it is a cost control, never the boundary —
#     a hard prohibition belongs in permissions, not in a hook. Every check below still runs on whatever
#     reaches it, so a payload the filter mis-classifies is handled exactly as before.
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

GUARD_BRANCH=""       # set by _on_default_branch when it blocks (for the message)
GUARD_TARGET_KIND=""  # "session" | "resolved" | "ambiguous" — which repo the judged branch belongs to

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

# _branch_query DIR [GITDIR] [WORKTREE] → set Q_CUR (current branch, or "HEAD" if detached) and Q_DEF
# (the default branch) for the repo at DIR; return 0 if DIR is a git repo (branch OR detached), 1 if it is
# not a repo / unresolvable. Best-effort + portable termination (timeout only if present). GITDIR/WORKTREE
# retarget a DIFFERENT repo (B3: `git --git-dir=… --work-tree=… commit`) and are resolved as the real git
# call would (git applies -C first, then --git-dir/--work-tree).
_branch_query() {
  local dir="$1" gitdir="${2:-}" worktree="${3:-}" to=""
  local -a gopt=()
  [ -n "$gitdir" ]   && gopt+=(--git-dir="$gitdir")
  [ -n "$worktree" ] && gopt+=(--work-tree="$worktree")
  if [ -z "${TEAM_BOOTSTRAP_GITGUARD_FORCE_BARE:-}" ]; then
    if   command -v timeout  >/dev/null 2>&1; then to="timeout 5"
    elif command -v gtimeout >/dev/null 2>&1; then to="gtimeout 5"
    fi
  fi
  Q_CUR=""; Q_DEF=""
  # shellcheck disable=SC2086
  Q_CUR="$($to git ${gopt[@]+"${gopt[@]}"} -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$Q_CUR" ] || return 1                 # not a repo / unresolvable dir
  [ "$Q_CUR" = "HEAD" ] && return 0           # detached ⇒ a repo, but determinably not on a branch
  # shellcheck disable=SC2086
  Q_DEF="$($to git ${gopt[@]+"${gopt[@]}"} -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  Q_DEF="${Q_DEF#origin/}"
  if [ -z "$Q_DEF" ]; then
    case "$Q_CUR" in main|master) Q_DEF="$Q_CUR" ;; *) Q_DEF="main" ;; esac   # fallback (safe direction)
  fi
  return 0
}

# _on_default_branch DIR [GITDIR] [WORKTREE] [REDIRECTED] → return 0 if the git command's TARGET repo is on
# its default branch (and stash the branch in GUARD_BRANCH + the target kind in GUARD_TARGET_KIND); else 1.
#
# DIR is the command's effective working directory — the session cwd (".") unless the command scoped the git
# write elsewhere via `git -C <dir>` or a leading `cd <dir> && git …` (issue #49). REDIRECTED=1 means the
# command moved the target off the session cwd. If a redirected target does NOT resolve to a repo (an
# unexpandable `$VAR`/`~`, or a non-existent path — the guard runs BEFORE the command, so it cannot expand
# shell variables), the target is AMBIGUOUS: per P10 we FAIL CLOSED and judge the SESSION repo instead of
# waving the write through (an unresolvable `-C`/`cd` must not become an escape hatch). A detached target is
# determinable (not on any branch) ⇒ allow. Best-effort + portable termination.
_on_default_branch() {
  local dir="$1" gitdir="${2:-}" worktree="${3:-}" redirected="${4:-0}"
  if _branch_query "$dir" "$gitdir" "$worktree"; then
    [ "$Q_CUR" = "HEAD" ] && return 1                 # detached target ⇒ not on default ⇒ allow (safe)
    if [ "$Q_CUR" = "$Q_DEF" ]; then
      GUARD_BRANCH="$Q_CUR"
      GUARD_TARGET_KIND=$([ "$redirected" = "1" ] && echo resolved || echo session)
      return 0
    fi
    return 1                                          # target resolved and is on a feature branch ⇒ allow
  fi
  # Target did not resolve. If the command redirected off the session cwd, fail CLOSED: judge the session.
  if [ "$redirected" = "1" ] && _branch_query "." "" ""; then
    if [ "$Q_CUR" != "HEAD" ] && [ "$Q_CUR" = "$Q_DEF" ]; then
      GUARD_BRANCH="$Q_CUR"; GUARD_TARGET_KIND="ambiguous"; return 0
    fi
  fi
  return 1
}

# _sub_blocks SUB → return 0 if SUB should be blocked on the default branch. commit/merge ALWAYS.
# Fail-closed posture (OQ-4, WS-D): an UNRECOGNIZED subcommand — one not in the known-git-subcommand set
# below, e.g. the alias `ci` from `git -c alias.ci=commit ci` (B2), or any obfuscating token — is treated
# as a possible commit/merge and blocked. Recognized non-commit/merge subcommands (reads AND mutations
# like tag/stash/rebase/reset, AND the explicitly-not-gated push/pull) stay FAIL-OPEN, keeping the
# false-positive rate low (R5) so the guard is never trained-away. Empty subcommand (bare `git`) → allow.
_sub_blocks() {
  local s="$1"
  case "$s" in
    commit|merge) return 0 ;;
    "")           return 1 ;;
  esac
  case "$s" in
    add|am|annotate|apply|archive|bisect|blame|branch|bundle|cat-file|check-attr|check-ignore|\
check-mailmap|check-ref-format|checkout|cherry|cherry-pick|clean|clone|column|commit-tree|config|\
count-objects|describe|diagnose|diff|diff-files|diff-index|diff-tree|difftool|fast-export|fast-import|fetch|\
filter-branch|for-each-ref|format-patch|fsck|gc|get-tar-commit-id|grep|gui|hash-object|help|init|\
instaweb|log|ls-files|ls-remote|ls-tree|maintenance|mailinfo|merge-base|merge-file|merge-tree|mergetool|\
mktag|mktree|mv|name-rev|notes|pack-objects|pack-refs|patch-id|prune|prune-packed|pull|push|quiltimport|\
range-diff|read-tree|rebase|reflog|remote|repack|replace|replay|request-pull|rerere|reset|restore|revert|\
rev-list|rev-parse|rm|send-email|shortlog|show|show-branch|show-ref|sparse-checkout|stash|status|\
stripspace|submodule|switch|symbolic-ref|tag|unpack-objects|update-index|update-ref|update-server-info|\
var|verify-commit|verify-pack|verify-tag|version|whatchanged|worktree|write-tree)
      return 1 ;;   # recognized non-commit/merge subcommand → fail-open (allow)
    *)
      # UNRECOGNIZED subcommand → fail-CLOSED (an alias like `ci`, or obfuscation). WS-E: the caller now
      # DE-OBFUSCATES `sub` (strips quotes) and the segment split is QUOTE-AWARE, so a real quoted subcommand
      # (`git "commit"`) arrives here as `commit` (→ blocked above) and a metachar-in-quoted-arg read
      # (`git log --grep 'x; git status'`) is never split into a fake `status'` fragment — so there is no
      # split-debris to fail open on. The earlier debris allow-rule was itself a fail-OPEN (review #1): it
      # let `"commit"`/`'merge'` through. Fail-closed here is now safe because the debris source is gone.
      return 0 ;;
  esac
}

# _strip_quotes STR → STR with all unescaped `"` and `'` removed (de-obfuscation). A quoted binary or
# subcommand token (`"git"`, `"commit"`, `com"m"it`) is classified by its REAL name, closing the quoted-
# token bypass (review #1 / AC-E1). Bash 3.2 pattern substitution.
_strip_quotes() { local s="${1//\"/}"; printf '%s' "${s//\'/}"; }

# _tokens DECODED_CMD → the command as an operator-tagged stream, quote-aware. For each shell segment it
# prints two lines — `S:<segment>` then `O:<op>` — where <op> is the shell operator that TERMINATES the
# segment: AND (&&) OR (||) PIPE (|) AMP (&) SEMI (;) LP ( RP ) NL (newline) END (end of input). Splitting
# happens ONLY outside single/double quotes (WS-E / AC-E1): a quote-blind split turned
# `git log --grep 'x; git status'` into a fake `git status'` fragment. This supersedes the old `_segments`
# (segments only): the operator is what lets _commit_or_merge_on_default follow a `cd <dir> && git …`
# redirect and, critically, DISCARD a cd that is scoped inside a `( … )` subshell (issue #49). A segment
# never contains a raw newline (newline is a delimiter), so one segment = one `S:` line.
_tokens() {
  local s="$1" n i c q="" seg="" NL
  NL=$'\n'   # a literal newline (command-subst would strip the trailing newline → empty; $'\n' is bash-3.2-safe)
  n=${#s}; i=0
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"; i=$((i + 1))
    # backslash escape (shell semantics: active OUTSIDE quotes and inside "double" quotes, NOT inside
    # 'single' quotes) — copy `\` and the next char through literally without changing quote state, so a
    # `\"` never opens a PHANTOM quote that would swallow a following `;`/`&&` and hide a real git commit
    # (`echo \" ; git commit`). Review WS-E #E1 escaped-quote fail-open regression.
    if [ "$c" = "\\" ] && [ "$q" != "'" ]; then
      seg="$seg$c"
      if [ "$i" -lt "$n" ]; then seg="$seg${s:i:1}"; i=$((i + 1)); fi
      continue
    fi
    if [ -n "$q" ]; then                    # inside a quote: copy through; close on the matching quote
      seg="$seg$c"; [ "$c" = "$q" ] && q=""; continue
    fi
    case "$c" in
      '"'|"'") q="$c"; seg="$seg$c" ;;
      '&')     if [ "${s:i:1}" = "&" ]; then i=$((i + 1)); printf 'S:%s\nO:AND\n'  "$seg"; else printf 'S:%s\nO:AMP\n'  "$seg"; fi; seg="" ;;
      '|')     if [ "${s:i:1}" = "|" ]; then i=$((i + 1)); printf 'S:%s\nO:OR\n'   "$seg"; else printf 'S:%s\nO:PIPE\n' "$seg"; fi; seg="" ;;
      ';')     printf 'S:%s\nO:SEMI\n' "$seg"; seg="" ;;
      '(')     printf 'S:%s\nO:LP\n'   "$seg"; seg="" ;;
      ')')     printf 'S:%s\nO:RP\n'   "$seg"; seg="" ;;
      *) if [ "$c" = "$NL" ]; then printf 'S:%s\nO:NL\n' "$seg"; seg=""; else seg="$seg$c"; fi ;;
    esac
  done
  printf 'S:%s\nO:END\n' "$seg"
}

# _cd_target SEGMENT → print the (de-quoted) directory a `cd` segment changes to, empty if none. Skips
# cd's options (-L/-P/-e/-@) and `--`. `cd` with no operand (→ $HOME) yields an unexpandable target so the
# caller treats it as ambiguous. Best-effort word-split, matching the git-arg parse below.
_cd_target() {
  local tgt=""
  # shellcheck disable=SC2086
  set -- $1; shift                                          # drop 'cd'
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; tgt="${1:-}"; break ;; -*) shift ;; *) tgt="$1"; break ;; esac
  done
  [ -n "$tgt" ] && _strip_quotes "$tgt"
}

# _join_dir BASE REL → BASE with REL applied the way a shell `cd`/git `-C` would: an absolute REL replaces
# BASE; a relative REL is appended (a session-relative BASE of "." is dropped so the result stays relative
# to the guard's cwd, which is the session cwd). Unexpandable/globby REL is passed through verbatim so it
# fails to resolve later → the caller's fail-closed path.
_join_dir() {
  local base="$1" rel="$2"
  case "$rel" in
    /*) printf '%s' "$rel" ;;
    *)  if [ "$base" = "." ]; then printf '%s' "$rel"; else printf '%s/%s' "$base" "$rel"; fi ;;
  esac
}

# _commit_or_merge_on_default DECODED_CMD → return 0 if a git commit/merge (or, under the fail-closed
# posture, an unrecognized subcommand) in the command targets its repo's default branch. Walks the
# operator-tagged token stream; subcommand-position scan; honors `git -C`/`--git-dir`/`--work-tree` AND a
# leading `cd <dir>` that the git write chains off of (issue #49).
#
# EFFECTIVE-CWD TRACKING. `cwd` starts at the session cwd (".") and is moved by a `cd` only when the redirect
# is one the git write is UNAMBIGUOUSLY scoped by, so the guard never mis-attributes a real session-repo
# commit to another directory (a fail-OPEN it must not commit):
#   - a `cd` is honored only when it LEADS its statement (prevop ∈ START/SEMI/NL/LP — not the right operand
#     of `&&`/`||`, which may be skipped) AND is joined to what follows by AND/SEMI/NL (not `|`/`&`, whose
#     left side runs in a subshell). `cd x && git` and `cd x; git` qualify; `foo && cd x; git` and
#     `cd x | git` do not.
#   - `(` pushes the cwd and `)` restores it, so a cd scoped inside a subshell — `(cd x) && git` — is
#     DISCARDED and the trailing git is judged against the session repo. This is the safety case.
# Resolvability is the backstop for the residual ambiguity of `;` (a `cd x` that fails leaves the shell in
# the session repo): if `x` resolves now it will at run time too (git runs in x); if it does not, the write
# lands in the session repo and _on_default_branch's fail-closed path judges the session — either way correct.
_commit_or_merge_on_default() {
  local line seg op prevop="START" first dq tgt
  local cwd="." ; local -a cwdstack=()
  local dir gitdir worktree sub redirected c sq envre
  sq="'"
  # env-assignment prefix: value may be "double-quoted" (spaces ok), 'single-quoted' (spaces ok — B1: the
  # single-quoted twin the finding-#1 fix missed), or bare-nonspace. All three alternations, POSIX-ERE
  # leftmost-longest, so 'a b' is consumed whole rather than leaving `b'` as a fake first token.
  envre="^([A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]]*)[[:space:]]+)+"
  while IFS= read -r line; do
    case "$line" in S:*) seg="${line#S:}" ;; *) continue ;; esac
    IFS= read -r line || line="O:END"; op="${line#O:}"           # the paired operator line

    if [ -n "$seg" ]; then
      seg="${seg#"${seg%%[![:space:]]*}"}"                       # ltrim
      [[ "$seg" =~ $envre ]] && seg="${seg:${#BASH_REMATCH[0]}}"
      first="${seg%%[[:space:]]*}"
      dq="$(_strip_quotes "$first")"
      case "$dq" in
        cd)
          # honor a statement-leading cd that sequences into the git write (see header)
          case "$prevop" in
            START|SEMI|NL|LP)
              case "$op" in
                AND|SEMI|NL)
                  tgt="$(_cd_target "$seg")"
                  [ -n "$tgt" ] && cwd="$(_join_dir "$cwd" "$tgt")" || cwd="?"   # bare `cd` (→ $HOME) = ambiguous
                  ;;
              esac
              ;;
          esac
          ;;
        git|*/git)
          # shellcheck disable=SC2086
          set -- $seg
          shift                                                  # drop 'git'
          dir="$cwd"; gitdir=""; worktree=""; sub=""; redirected=0
          [ "$cwd" != "." ] && redirected=1
          while [ $# -gt 0 ]; do
            case "$1" in
              -C)            shift; c="${1:-.}"; shift; dir="$(_join_dir "$dir" "$c")"; redirected=1; continue ;;
              -C*)           c="${1#-C}"; shift; dir="$(_join_dir "$dir" "$c")"; redirected=1; continue ;;
              --git-dir)     shift; gitdir="${1:-}"; shift; redirected=1; continue ;;
              --git-dir=*)   gitdir="${1#--git-dir=}"; shift; redirected=1; continue ;;
              --work-tree)   shift; worktree="${1:-}"; shift; redirected=1; continue ;;
              --work-tree=*) worktree="${1#--work-tree=}"; shift; redirected=1; continue ;;
              -c)            shift; shift; continue ;;            # -c <k=v> takes an arg
              -c*)           shift; continue ;;                  # -c<k=v> (attached)
              --)            shift; [ $# -gt 0 ] && sub="$1"; break ;;
              -*)            shift; continue ;;                  # any other option before the subcommand
              *)             sub="$1"; break ;;
            esac
          done
          if _sub_blocks "$(_strip_quotes "$sub")"; then         # de-obfuscate: classify the sub by its real name
            _on_default_branch "$dir" "$gitdir" "$worktree" "$redirected" && return 0
          fi
          ;;
      esac
    fi

    case "$op" in
      LP) cwdstack+=("$cwd") ;;                                  # subshell opens: child inherits cwd
      RP) if [ "${#cwdstack[@]}" -gt 0 ]; then cwd="${cwdstack[${#cwdstack[@]}-1]}"; unset 'cwdstack[${#cwdstack[@]}-1]'; fi ;;  # closes: discard child's cd's
    esac
    prevop="$op"
  done < <(_tokens "$1")
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
    local extra=""
    if [ "${GUARD_TARGET_KIND:-}" = "ambiguous" ]; then
      # #49: the git write named a target directory the guard could not resolve (an unexpandable $VAR/~, or
      # a path that does not exist yet), so — fail-closed — it judged the SESSION repo. Say so, so the
      # operator is not sent to `git checkout -b` in a repository the command was not touching.
      extra=$'\n  NOTE: the branch judged is the SESSION repo'"'"$'s — the git write named a target directory that could not be resolved before the command ran, so it was treated as needing the guard (fail-closed). If the write actually targets a different repository, this block does not apply there.'
    fi
    printf 'guard-git: BLOCKED — you are on the default branch (%s). A delivery commit must land on a feature branch; the default branch is reached only via a human-authored PR (P5).\n  Branch first:  git checkout -b <feature>\n  (git push / gh pr merge are NOT gated here — configure required-PR-review branch protection on the remote.)%s\n' "${GUARD_BRANCH:-default}" "$extra" >&2
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
    # an inner NESTED repo on main — target of the --git-dir/--work-tree retarget (B3)
    mkdir -p inner && ( cd inner && git init -q && git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
      git config user.email t@t && git config user.name t && echo i > g && git add . && git commit -qm ibase )
    # a nested repo on a FEATURE branch — target of a `cd … && git` redirect (#49)
    mkdir -p elsewhere && ( cd elsewhere && git init -q && git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
      git config user.email t@t && git config user.name t && echo e > h && git add . && git commit -qm ebase && git checkout -q -b feature )
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
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"GIT_AUTHOR_NAME=\"A B\" git commit -m x"}}')" 2 "quoted-space env prefix commit on default → block"
  _chk "$(_g "$(P 'git merge x')")"                            2 "merge on default → block"
  _chk "$(_g "$(P 'git add -A\ngit commit -m x')")"            2 "multi-line commit on default → block (newline split)"
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \"hi\" && git commit -m x"}}')" 2 "quoted-echo && commit → block (decode)"
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \"git commit\""}}')"            0 "echo mentioning tokens → allow"
  # WS-D bypasses (pipeline-integrity-hardening):
  _chk "$(_g "$(P "FOO='a b' git commit -m x")")"             2 "B1 single-quoted env (FOO='a b') commit on default → block"
  _chk "$(_g "$(P 'git -c alias.ci=commit ci')")"             2 "B2 git -c alias.ci=commit ci on default → block (fail-closed unrecognized sub)"
  _chk "$(_g "$(P 'git --git-dir=inner/.git --work-tree=inner commit -m x')")" 2 "B3 --git-dir/--work-tree retarget to inner(main) → block"
  # #49 — the redirect the branch check follows is the git write's TARGET dir, not the session cwd:
  _chk "$(_g "$(P 'cd elsewhere && git commit -m x')")"      0 "#49 cd <feature-repo> && git commit → allow (follow the cd)"
  _chk "$(_g "$(P 'cd elsewhere; git commit -m x')")"        0 "#49 cd <feature-repo>; git commit → allow (cd persists across ;)"
  _chk "$(_g "$(P 'cd inner && git commit -m x')")"          2 "#49 cd <main-repo> && git commit → block (target repo on default)"
  _chk "$(_g "$(P '(cd elsewhere) && git commit -m x')")"    2 "#49 (cd <feature>) && git commit → block (cd subshell-scoped; git in session/main)"
  _chk "$(_g "$(P 'cd $MISSING && git commit -m x')")"       2 "#49 cd \$MISSING && git commit (unresolvable) → block (fail-closed to session)"
  _chk "$(_g "$(P 'git tag v1')")"                            0 "recognized non-commit/merge sub (tag) on default → allow (fail-open, R5)"
  _chk "$(_g "$(P 'git rev-parse HEAD')")"                    0 "recognized read (rev-parse) on default → allow"
  _chk "$(_g "$(P "git log --grep 'x; git status'")")"       0 "read w/ metachar in quoted arg on default → allow (quote-aware split, R5)"
  # WS-E AC-E1 — quoted subcommand / quoted binary must BLOCK (de-obfuscation + quote-aware split):
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"git \"commit\""}}')"  2 "E1 git \"commit\" (quoted sub) on default → block"
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"\"git\" commit"}}')"  2 "E1 \"git\" commit (quoted binary) on default → block"
  _chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \\\" ; git commit -m x"}}')" 2 "E1 escaped-quote then ; git commit → block (no phantom quote)"
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
_rc=$?
[ "$_rc" -ne 0 ] && exit "$_rc"

# permissionDecision:"ask" — the middle path this guard did not have. Everything above is binary: block
# (exit 2) or stay silent. A force-push to a NON-default branch is not the default-branch write this
# guard refuses, but it is irreversible and rewrites history someone else may have pulled — the one
# shape where "let a human look" is the right answer rather than either extreme. Aider's auditability
# and Cline's approval points, in the one place they actually apply here.
#
# Advisory by construction: any parse failure falls through to exit 0, so a payload we cannot read is
# handled exactly as before. Disable with TEAM_BOOTSTRAP_GITGUARD_ASK=off.
if [ "${TEAM_BOOTSTRAP_GITGUARD_ASK:-on}" != "off" ]; then
  _cmd="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
c=(d.get("tool_input") or {}).get("command")
print(c if isinstance(c,str) else "")' 2>/dev/null || true)"
  case "$_cmd" in
    *"git push"*--force*|*"git push"*-f\ *)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This rewrites published history: `%s`. It is not the default-branch write the guard refuses, and it is not reversible by re-running anything — so it is escalated for a human decision rather than blocked or waved through."}}\n' \
        "$(printf '%s' "$_cmd" | tr -d '"\\' | cut -c1-160)"
      ;;
  esac
fi
exit 0
