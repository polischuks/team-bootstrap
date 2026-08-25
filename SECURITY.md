# Security Policy

team-bootstrap orchestrates AI agents that can read, write, and execute against
your repositories. Security is a first-class concern of the design, not an
afterthought — see [references/irreversibility.md](references/irreversibility.md)
and [references/guardrails.md](references/guardrails.md).

## Supported versions

The latest released version receives security fixes. Older versions do not.

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository. This opens a private
advisory visible only to the maintainer.

Please include:

- The affected file(s), role, or pipeline.
- A description of the issue and its impact (e.g. a role's `tool_surface` allowing
  an irreversible action it shouldn't, a guardrail that can be bypassed, a prompt-
  injection path that escalates tool access).
- Steps to reproduce, and a suggested fix if you have one.

You can expect an initial response within a few days. Coordinated disclosure is
appreciated: please give a reasonable window to ship a fix before public discussion.

## What this project executes

Reasoning happens inside the user's Claude Code harness, against the user's own
credentials and repository. But the plugin is **not** inert markdown: it ships
`bin/*.sh` and wires them into four Claude Code hook points via
[hooks/hooks.json](hooks/hooks.json):

| Hook | Script | Effect |
| --- | --- | --- |
| `UserPromptSubmit` | `delivery-marker-init.sh` | arms/updates the run marker |
| `PreToolUse[Agent\|Task]` | `record-dispatch.sh` | records role dispatches |
| `PreToolUse[Bash]` | `guard-git.sh` | **blocking** — can refuse a git command |
| `Stop` | `quality-gate.sh`, `delivery-stop-hook.sh` | **blocking** — can refuse completion |

Hooks run automatically, without a per-call permission prompt.

## Trust boundary: `AGENTS.md` commands are executed

The gates read their commands from the **target repository's**
`AGENTS.md`/`CLAUDE.md` — the `Lint:`, `Typecheck:`, `Test:`, `Coverage:` and
`Mutation:` contracts — and run them through `eval`:

| Site | Contract read | Reached via |
| --- | --- | --- |
| [`quality-gate.sh:39`](bin/quality-gate.sh) | `Lint:`, `Typecheck:` | **`Stop` hook — no prompt** |
| [`check-tdd.sh:131`](bin/check-tdd.sh), [`tdd-red.sh:88`](bin/tdd-red.sh) | `Test:` | gate run during a batch |
| [`check-diff-coverage.sh:106,109`](bin/check-diff-coverage.sh) | `Coverage:` | `verify-batch.sh` |
| [`check-mutation.sh:60`](bin/check-mutation.sh) | `Mutation:` | `verify-batch.sh` |

**Consequence:** opening a session in a repository whose `AGENTS.md` you have not
read is equivalent to running that repository's build commands. For
`quality-gate.sh` this happens on the `Stop` hook, i.e. without the harness asking.
This is deliberate — a gate that cannot run the project's own tooling cannot gate
anything — but it means:

- **Treat a cloned repository's `AGENTS.md` as untrusted input.** Read the
  `Lint:`/`Typecheck:`/`Test:`/`Coverage:`/`Mutation:` lines before working in an
  unfamiliar repo, exactly as you would read a `Makefile` before running `make`.
- **Kill switches, if you would rather not:** `TEAM_BOOTSTRAP_QUALITY_GATE=off`
  disables the `Stop`-hook `eval` entirely. Removing a command line from `AGENTS.md`
  makes the gate that reads it skip rather than execute — silently for
  `quality-gate.sh`, with a WARN for the coverage/mutation gates.

A malicious `AGENTS.md` is therefore an **accepted, documented** risk rather than a
vulnerability. Report a way to reach `eval` that these lines do *not* describe —
for example a gate executing a string from somewhere other than the declared
contract, or one that ignores its kill switch.

## Scope and threat model

In scope:

- **Guardrail / irreversibility correctness** — a role permitted to take a
  destructive or irreversible action without the documented approval gate.
- **Tool-surface declarations** — a role frontmatter `tool_surface` that grants more
  than the role needs.
- **Hook-script defects** — a hook that can be made to execute something outside the
  documented `AGENTS.md` contract, or `guard-git.sh` being made to *allow* a command
  it documents as blocked. Note that `guard-git.sh` is explicitly best-effort and
  **not** a security boundary; it says so in its own header.
- **Prompt-injection resistance** — content in a target repo or data room that could
  subvert a role's instructions or escalate its tool access.
- **Data handling guidance** — incorrect advice about where customer/repo data flows
  (it reaches the foundation-model provider during inference).

Out of scope: vulnerabilities in Claude Code itself, the Anthropic API, or
third-party MCP servers — report those to their respective maintainers. Also out of
scope: the `AGENTS.md` execution path described above, when used as documented.
