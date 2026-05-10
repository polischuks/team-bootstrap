# Irreversibility Taxonomy

Approval gates are about **actions**, not roles. A role like `devops-platform` may issue 90% read-only operations and one destructive deploy — gating the whole role mistakes scope.

## Four classes

| Class | Examples | Default policy |
|---|---|---|
| `read_only` | `Read`, `Grep`, `Glob`, `WebSearch`, `WebFetch`, `Bash` with read-only commands (`ls`, `cat`, `git log`, `npm test --no-mutate`) | **auto-allow** |
| `stateful_local` | `Edit`, `Write`, `NotebookEdit`, `Bash` with local mutations (`npm install`, `git add`, `git commit`) | **confirm-once-per-run** |
| `stateful_remote` | `git push` to feature branch, MCP calls that create issues/comments, posting Slack messages | **confirm-each** |
| `irreversible` | `git push --force`, `git push` to main/master, prod deploy, `rm -rf`, dropping DB tables, posting customer emails, force-pushing to shared branches | **deny-by-default; explicit approval per call** |

## Where the class is declared

The class lives with the **tool**, not the **role**. Each role's `tool_surface.allow` enumerates what that role may use. The harness (Claude Code) maps the tool to its irreversibility class:

- For built-in tools (`Read`, `Edit`, `Bash`, …): the harness has the mapping baked in.
- For `Bash`: the harness inspects the command and may upgrade the class (e.g., `git push --force` is `irreversible` regardless of who calls it).
- For MCP tools: the MCP server should declare `x-irreversibility-class` in tool metadata; otherwise default to `stateful_remote`.
- For project-specific destructive scripts (e.g., `npm run reset:prod-db`): declare in project `AGENTS.md` under a `Destructive scripts` section. See [agents-md-contract.md](agents-md-contract.md).

## Approval semantics

| Class | UX |
|---|---|
| `read_only` | No prompt. |
| `stateful_local` | Prompt on first use per run; "allow for this run" / "ask again next time" / "deny." |
| `stateful_remote` | Prompt every call. Show the recipient/target (URL, branch, channel). |
| `irreversible` | Prompt every call with full command preview, target, and a typed-confirmation requirement (e.g., type the branch name). Default: deny. |

## Role-level overrides

A role's frontmatter can tighten (never loosen) the default policy:

```yaml
permission_mode: ask | acceptEdits | plan
```

- `plan`: deny everything that isn't `read_only` (used by reviewer roles)
- `acceptEdits`: auto-accept `stateful_local`, retain confirm for the rest (used by implementation roles in trusted runs)
- `ask`: default behavior (used by devops, release, incident-responder)

A role can never declare `permission_mode: bypass` — that requires user override at the harness level (Claude Code's `--dangerously-skip-permissions` or equivalent).

## Bash command classification

Because `Bash` is a single tool that can do anything, classify by command. Reference patterns:

| Pattern | Class |
|---|---|
| `ls`, `cat`, `head`, `tail`, `grep`, `find`, `git log`, `git status`, `git diff`, `git show` | `read_only` |
| `npm test`, `pytest`, `cargo test` (no mutation flags) | `read_only` |
| `npm install`, `pip install`, `cargo build`, `make`, `git add`, `git commit`, `git checkout -b` | `stateful_local` |
| `git push origin <feature-branch>`, `gh issue create`, `gh pr create` | `stateful_remote` |
| `git push --force`, `git push origin main`, `git reset --hard <upstream>`, `rm -rf`, `psql -c "DROP …"`, `kubectl delete`, prod deploy scripts | `irreversible` |

Project-specific patterns go in `AGENTS.md`.

## What the schema records

Per-call irreversibility is recorded in the trace ([tracing.md](tracing.md)) as a span attribute, not in the role handoff. The handoff records what was done (artifacts, checks); irreversibility is metadata about *how* it was done. This keeps handoffs portable across approval policies.

## Migration from pre-1.0

Earlier versions of team-bootstrap used a role-level boolean `manual_approval_requested` plus a hardcoded list of "always-approval" roles (`devops-platform`, `release-manager`). That approach:

- Couldn't distinguish a `devops-platform` role doing `kubectl get pods` (read-only) from one doing `kubectl rollout restart` (stateful_remote)
- Forced approval prompts for entire roles even when 90% of their work was read-only
- Provided no way to flag a previously-safe role's call that *became* destructive (e.g., a backend-engineer issuing `git push --force`)

The boolean flag is retained as a deprecated fallback: if `manual_approval_requested: true` appears in a handoff, treat it as advisory ("the role suggests human review of the entire output"), not as an action gate. Action gates always derive from class.

## Anti-patterns

- **Asking the LLM if an action is safe.** Use the harness mapping. Prompt injection trivially defeats LLM-judged safety.
- **Allowing `git push --force` in `permission_mode: acceptEdits`.** `irreversible` always prompts regardless of mode.
- **Treating MCP servers as uniformly safe.** A GitHub MCP server's `create_issue` is `stateful_remote`; `delete_repository` is `irreversible`. Class is per-tool.
- **Hiding the target from the approval prompt.** "Confirm push" is not enough; the prompt must show the branch and remote.

## See also

- [failure-policy.md](failure-policy.md) — manual-approval semantics, stop reasons, retry rules
- [tracing.md](tracing.md) — how irreversibility classification is recorded per call
- [mcp-integration.md](mcp-integration.md) — MCP server tool-class declaration
