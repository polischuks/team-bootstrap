# 0011 — Commit-on-default branch guard (PreToolUse[Bash], best-effort)

- **Status:** Accepted
- **Date:** 2026-08-19
- **Constitution clause(s):** P3, P5, P6, P11
- **Related:** [0008](0008-harness-verified-role-execution.md) (harness-observed dispatch), [0010](0010-preflight-setup-gate.md)
  (fail-closed Phase 0 gate), [irreversibility.md](../../references/irreversibility.md)

## Context

P5 (irreversibility): "never push to a remote or deploy without explicit human authorization; the
orchestrator commits locally and surfaces state." A delivery's commits are meant to land on a feature/
milestone branch; the default branch (`main`/`master`) is reached only through a human-approved PR. Until
now that was **prose** — honored only by discipline. Nothing machine-stopped a direct commit to the default
branch during a run, and nothing stopped an unauthorized `git push`. A framework whose central claim is
harness-enforced guardrails should not leave its most irreversible action to the model's good behavior;
GitHub Copilot, Cursor, and Codex all enforce the branch/PR boundary at the environment level.

Two independent adversarial review rounds established the honest **boundary** of what a *plugin* can enforce
here (the milestone shrank to its sound core, it was not shipped as first imagined):

- **The push half is not enforceable in-plugin.** A `git push` chained after a commit
  (`git commit -m "x" && git push`) cannot be extracted from the raw command string false-pass-safely: a
  greedy extractor re-admits the commit *message* text (false-block), a conservative one drops the chained
  push (false-pass on the irreversible action). And any `push_ack` the hook could require would be written
  by the same orchestrator, in the same turn, that runs the push — hollow (the hook cannot see the chat
  where a human authorizes, and there is no trusted clock to require a pre-dated ack). `gh pr merge` / `gh
  api …/merges` are likewise remote writes the hook could match syntactically but not *authorize*.
- **The commit-on-default half IS enforceable, and safely.** Blocking a `git commit`/`git merge` while HEAD
  is the default branch has a trivial, *safe* remediation — "branch first" — so a rare false-positive costs
  a branch-and-retry, never data, and it needs no message-parse and no ack.

## Decision

Ship **only the sound core**: a new **blocking** `PreToolUse[Bash]` hook,
[`bin/guard-git.sh`](../../bin/guard-git.sh), that on an armed `intends_code` run **blocks a `git commit`/
`git merge` while the current branch is the default branch** (exit 2, "branch first"); everything else exits
0. Registered on a `PreToolUse` `Bash`-tool matcher ([hooks/hooks.json](../../hooks/hooks.json)). Confirmed
lever (T0 probe): a `PreToolUse` hook's `exit 2` blocks the tool call, `matcher:"Bash"` targets the Bash
tool, and the command is at `tool_input.command`.

- **JSON-decode extractor, not `field_str`.** `field_str` terminates at the first quote (it would truncate
  `git commit -m "x" && …` and lose chained/quoted content); `guard-git.sh` decodes `tool_input.command` as
  a JSON string (un-escapes `\" \\ \n \t \r \/`; leaves `\uXXXX` literal — a documented non-goal, bash 3.2
  cannot `printf` code points and every matched token is ASCII). Segments split on `&& || | ; ( )` and
  **newline** (a multi-line `git add⏎git commit` must not slip). The scan is **subcommand-position** (first
  token of each segment), so a commit *message* or an `echo` that merely mentions "git commit"/"push"/"main"
  never triggers a block.
- **Total + fail-safe + kill-switch.** As the first *blocking* hook on the universal Bash path, it exits 0
  on anything unrecognized/undecodable/malformed-marker (never breaks the shell), and honors a kill-switch
  (`TEAM_BOOTSTRAP_DELIVERY_GATE=off` / `TEAM_BOOTSTRAP_GITGUARD=off`) so a parse bug cannot brick the
  delivery shell.
- **Portable termination.** Branch detection (`git rev-parse --abbrev-ref HEAD` + `git symbolic-ref
  refs/remotes/origin/HEAD`, `main`/`master` fallback) wraps its git calls in `timeout`/`gtimeout` **only if
  present** (the reference host has neither) — else runs them bare (local + instant). A literal unconditional
  `timeout git …` on a host without it would command-not-found → empty branch → silently no-op the gate.

## Disclosed limits (P11 — ground in mechanism, not aspiration)

- **`git push` / `gh pr merge` / `gh api` are NOT gated** (above). Remote-write authorization stays P5 prose
  + the [`check-preconditions`](../../bin/check-preconditions.sh) advisory; the **hard** backstop is the
  remote's **branch-protection** (required PR review) — org config the plugin cannot force. This session
  itself merged PRs #11/#12/#13 to `main` via `gh pr merge`, which a git-parsing hook does not see.
- **Best-effort git-parsing, not a security boundary.** It catches the default/accidental invocation (incl.
  `git -C p`, `ENV=… git` with quoted or bare values, chained/multi-line segments); an obfuscated form
  (`eval`, subshell, backtick/brace grouping, alias, `cd other && git commit` in another repo) can slip.
  Branch-detection is best-effort too (no `origin/HEAD` ⇒ `main`/`master` fallback) — always in the **safe**
  direction (a false-block costs a branch-retry; a false-pass is the accidental-commit case the remote
  catches).
- **Bootstrap:** like the [ADR-0008](0008-harness-verified-role-execution.md) recorder, a hook added in a
  session only goes live at the next session start; the guard is verified by its `--self-test` +
  `tests/branch-protection-gate.test.sh` and takes effect on subsequent runs.

## Consequences

- A delivery commit accidentally issued on the default branch is machine-refused with a "branch first"
  remediation, instead of relying on orchestrator discipline. No new constitution invariant (enforcement-
  hardening of P5/P3/P6); asset **MINOR → 2.25.0**. Remote-write hardening remains the remote's job — and is
  now honestly documented as such rather than implied.
