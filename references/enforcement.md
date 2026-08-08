# Enforcement — make the gates non-skippable

A gate written as a role playbook is **prose the orchestrator can skip**. Anthropic's own data:
written instructions are followed ~70% of the time, a hook enforces at ~100%
([Claude Code best practices](https://code.claude.com/docs/en/best-practices)). Auditing real
`/deliver` output confirmed it — the reviewer roles existed, yet batches shipped dead code, drift,
and unreviewed diffs because the roles simply weren't run ("gate didn't run"). The fix is to move
enforcement of the **outcomes** off the LLM and onto the **harness**: roles *reason*, the harness
*enforces they held* ([The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification);
deterministic control flow, [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).

## Three enforcement layers (defense in depth)

| Layer | Mechanism | Catches | Bypassable? |
|---|---|---|---|
| **Always-on** | Stop hook → [`../bin/quality-gate.sh`](../bin/quality-gate.sh) | typecheck + lint red on completion | no (harness) |
| **Batch gate** | [`../bin/verify-batch.sh`](../bin/verify-batch.sh) at each batch close | dead code (orphans), drift, green-by-skip | LLM-invoked (see CI) |
| **Independent backstop** | **CI** runs `verify-batch.sh` on every PR/push | everything above, from scratch, regardless of what the local run did | **no** — the merge blocks |

The batch gate is the same script CI runs, so a batch whose local run skipped `integration-verifier`
or `code-reviewer` still fails at merge. That is the point: **CI is the layer the orchestrator cannot
talk its way past.**

## CI backstop (add to the target project)

Add a job that runs the batch gate against the change — this is what makes review non-optional:

```yaml
# .github/workflows/verify.yml (target project)
name: verify
on: [pull_request, push]
jobs:
  gates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }   # check-orphans needs the diff
      - run: path/to/team-bootstrap/bin/verify-batch.sh .
```

A red `verify` check blocks the merge. Dead code, drift, and green-by-skip cannot reach `main` even
if the delivery run skipped the reviewer roles.

## Strict opt-in — block completion in-session

For zero tolerance within a session, register `verify-batch.sh` on the **Stop / SubagentStop** hook
so Claude Code **cannot finish a batch** until the gates pass ([Hooks reference](https://code.claude.com/docs/en/hooks)):

```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "${CLAUDE_PLUGIN_ROOT}/bin/verify-batch.sh" } ] } ] } }
```

This is **not shipped on by default** — the outcome checks (orphans/architecture) are heuristic and
would block *every* stop, including intentional work-in-progress pauses. Claude Code caps consecutive
Stop-hook blocks (default 8) to prevent loops. Enable it per project when you want the session itself
to be non-bypassable; otherwise rely on the CI backstop, which is both non-bypassable and non-annoying.

## Role coverage (the other half)

Enforcement assumes the reviewer roles are *in the pipeline* to begin with. `code-reviewer`,
`integration-verifier`, `architecture-reviewer`, and `regression-guardian` are now in **`mvp`,
`full`, and `single-thread`** — no pipeline ships a batch unreviewed. The harness layers above make
sure they actually run.
