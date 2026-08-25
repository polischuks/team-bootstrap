#!/usr/bin/env bash
# branch-protection-gate.test.sh — red-first behavioural spec for bin/guard-git.sh, the commit-on-default
# PreToolUse[Bash] guard (milestone branch-protection-gate, v2.25.0). Exercises AC-1..AC-6 from
# specs/branch-protection-gate/spec.md. Written BEFORE guard-git.sh exists → fails red, then implemented green.
#
# Scope (round-1/2 folded): the guard blocks `git commit`/`git merge` while HEAD == the default branch;
# it does NOT gate push / gh pr merge (no false-pass-safe extraction — AC-5). The extractor is a JSON-decode
# (not field_str, which truncates at the first quote — the BF1 hole exercised by AC-2). Portable termination
# (timeout only if present; this host has none — AC-6). Marker-gated + kill-switch (AC-4).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
GUARD="$here/../bin/guard-git.sh"

fail=0
_chk() { # _chk GOT WANT MSG
  if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (exit '$1' want '$2')" >&2; fail=$((fail + 1)); fi
}

# --- a temp git repo whose default branch is 'main', with an armed intends_code run marker --------------
T="$(mktemp -d)"
(
  cd "$T" || exit 1
  git init -q
  git symbolic-ref HEAD refs/heads/main 2>/dev/null || true   # deterministic default = main (all git versions)
  git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base
  mkdir -p .runs/r        && printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n'     > .runs/r/RUN
  mkdir -p .runs/bad      && printf '{"run":"bad","pipeline":"full","source":"harness","baseline_sha":"x"}\n'                        > .runs/bad/RUN
) >/dev/null 2>&1

_on() { ( cd "$T" && git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" ) >/dev/null 2>&1; }

# _g PAYLOAD → run the guard from the repo cwd under the armed run 'r'; echo its exit code
_g() { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r bash "$GUARD" >/dev/null 2>&1 ); echo $?; }
# _gE 'VAR=val ...' PAYLOAD → same, with extra leading env
# shellcheck disable=SC2086
_gE() { ( cd "$T" && printf '%s' "$2" | env $1 bash "$GUARD" >/dev/null 2>&1 ); echo $?; }
# P COMMAND → a PreToolUse[Bash] payload whose command has NO embedded quotes (safe to interpolate)
P() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

echo "AC-1 — commit/merge on the default branch → exit 2 (blocked, 'branch first'):"
_on main
_chk "$(_g "$(P 'git commit -m hi')")"            2 "git commit on main → block"
_chk "$(_g "$(P 'git -C . commit -m hi')")"       2 "git -C . commit on main → block"
_chk "$(_g "$(P 'FOO=bar git commit -m hi')")"    2 "env-prefixed git commit on main → block"
_chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"GIT_AUTHOR_NAME=\"A B\" git commit -m x"}}')" 2 \
  "quoted-space env prefix (GIT_AUTHOR_NAME=\"A B\") git commit on main → block (review finding #1)"
_chk "$(_g "$(P 'git merge feature')")"           2 "git merge on main → block"
_chk "$(_g "$(P 'echo done && git commit -m hi')")" 2 "chained '&& git commit' on main → block"
# multi-line: JSON \n decodes to a real newline; the newline splitter must still find the commit (round-2 BF1)
_chk "$(_g "$(P 'git add -A\ngit commit -m x')")" 2 "multi-line 'git add\\ngit commit' on main → block (newline split)"

echo "AC-2 — JSON-decode not field_str; message/echoed text never triggers (round-1 BF1 regression):"
_on main
# echo carries a quote then chains a real commit: field_str would truncate at the first quote and MISS the
# commit (false-pass); a JSON-decode + segment split still finds 'git commit' → block.
_chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \"hi\" && git commit -m x"}}')" 2 \
  "quoted-echo then chained git commit on main → block (decode survives the quote)"
# a non-commit command whose text merely MENTIONS the tokens, on the default branch → NOT blocked
_chk "$(_g '{"tool_name":"Bash","tool_input":{"command":"echo \"git commit to main\""}}')" 0 \
  "echo \"git commit to main\" on main → exit 0 (message text is not a subcommand)"

echo "AC-3 — feature branch / non-git → exit 0 (no false block):"
_on feature
_chk "$(_g "$(P 'git commit -m hi')")"   0 "git commit on a feature branch → allow"
_chk "$(_g "$(P 'git merge main')")"     0 "git merge on a feature branch → allow"
_on main
_chk "$(_g "$(P 'ls -la')")"             0 "ls on main → allow"
_chk "$(_g "$(P 'npm test')")"           0 "npm test on main → allow"

echo "AC-4 — no active marker / kill-switch → exit 0 even on default:"
_on main
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=none'            "$(P 'git commit -m hi')")" 0 "no marker (run absent) → allow"
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=bad'             "$(P 'git commit -m hi')")" 0 "marker without intends_code → allow (malformed → fail-open safe)"
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_DELIVERY_GATE=off' "$(P 'git commit -m hi')")" 0 "DELIVERY_GATE=off → allow"
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_GITGUARD=off'      "$(P 'git commit -m hi')")" 0 "GITGUARD=off → allow"

echo "AC-5 — remote-write NOT gated (disclosed gap): push / gh pr merge / gh api → exit 0:"
_on main
_chk "$(_g "$(P 'git push origin main')")"                 0 "git push on main → NOT caught (disclosed)"
_chk "$(_g "$(P 'gh pr merge 5 --merge')")"                0 "gh pr merge → NOT caught (disclosed)"
_chk "$(_g "$(P 'gh api repos/o/r/merges -f base=main')")" 0 "gh api merges → NOT caught (disclosed)"

echo "AC-6 — totality + portable termination (no timeout on this host):"
_on main
_chk "$(_g 'not even json')"                                   0 "undecodable payload → exit 0 (never break the shell)"
_chk "$(_g '{"tool_name":"Bash","tool_input":{}}')"            0 "payload with no command → exit 0"
# force the bare (no-timeout) git path and confirm the gate STILL FIRES on default (round-2 BF2)
_chk "$(_gE 'TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_GITGUARD_FORCE_BARE=1' "$(P 'git commit -m hi')")" 2 \
  "forced-bare (no timeout wrapper) git commit on main → still block (fires without timeout)"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "branch-protection-gate.test.sh: OK"; exit 0; fi
echo "branch-protection-gate.test.sh: $fail case(s) FAILED" >&2; exit 1
