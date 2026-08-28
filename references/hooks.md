# Hooks (harness-enforced gates)

Prose instructions in a role or CLAUDE.md are followed ~70% of the time; **hooks enforce rules at
~100%** ([Anthropic — Claude Code best practices](https://code.claude.com/docs/en/best-practices),
[The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification)). So the always-on
quality gate belongs in a hook, not a playbook.

## What ships

[`../hooks/hooks.json`](../hooks/hooks.json) registers a **Stop hook** that runs
[`../bin/quality-gate.sh`](../bin/quality-gate.sh). The Stop hook fires when the agent declares it
is done; if the gate exits non-zero (2), completion is **blocked** and the failure is fed back —
the agent cannot stop over red checks.

`quality-gate.sh` runs the **fast** checks (`Typecheck`, `Lint`) declared in the project's
`AGENTS.md` / `CLAUDE.md`. It is deliberately fast:

- Full unit / E2E suites stay with [integration-verifier](roles/integration-verifier.md) and CI —
  too slow to run on every Stop.
- It **no-ops** (exit 0) when there is no `AGENTS.md`/`CLAUDE.md` (a non-team-bootstrap session)
  or when a command is `N/A`, so it is safe to have active globally.

### Delivery-run hooks (v2.12.0)

Two more hooks make the delivery-occurred gate ([enforcement.md](enforcement.md)) **self-starting** and
**fail-closed** without nagging non-delivery sessions. Both key on the run marker `.runs/<run>/RUN` and
**no-op (exit 0) whenever no active marker is present** — the same on-by-default-safe property as
`quality-gate.sh` without an `AGENTS.md`.

- **`UserPromptSubmit` → [`../bin/delivery-marker-init.sh`](../bin/delivery-marker-init.sh)** — when a
  prompt invokes `/deliver` (an `mvp`/`full` pipeline + a spec path), it writes the run marker
  (`intends_code:true`, `baseline_sha`) **before any Skill/tool runs**. This makes "a delivery run is
  active" a harness-owned machine fact, so an orchestrator that skips the batch protocol cannot make the
  gate no-op (the marker exists regardless). It detects the invocation by scanning the whole stdin
  payload, so it is agnostic to the exact prompt-field name, and it always exits 0 (never blocks a
  prompt). On any non-`/deliver` prompt it no-ops.
- **`Stop` → [`../bin/delivery-stop-hook.sh`](../bin/delivery-stop-hook.sh)** — while a marked run still
  has a `kind:code` batch announced-but-unclosed (or has delivered no code), it **blocks completion
  (exit 2)** with an actionable message; it allows the stop (exit 0) once all code batches are closed or
  no marker is present. It is deliberately **not** on `SubagentStop`: worker subagents
  (integration-verifier, reviewers) finish *before* `verify-batch.sh` stamps the batch closed, so
  blocking their `SubagentStop` on an unclosed batch would deadlock the step that closes it — the
  premature-completion this guards is the **main orchestrator's** (`Stop`).

### Pre-dispatch brief (harness research §5 step 3)

- **`SubagentStart` (matcher: the review-role agent types) →
  [`../bin/subagent-brief.sh`](../bin/subagent-brief.sh)** — a **non-blocking, read-only** hook. When a
  review role is spawned during an armed `intends_code` run with an in-flight `kind:code` batch, it
  returns `hookSpecificOutput.additionalContext` naming the batch, the **sized** role set for it
  (preferring the set `verify-batch.sh` recorded against the real diff), and the reviewer dispatches
  already recorded. `SubagentStart` addresses its context to the **subagent**, not to the parent
  conversation — which is precisely the delivery a per-role brief needs.

  **Why this event rather than a `PreToolUse[Agent|Task]` gate.** A blocking pre-dispatch gate was
  considered and rejected: refusing an off-plan dispatch pushes the orchestrator to review **inline**,
  which is the spec-169 collapse the review pipeline exists to prevent. `SubagentStart` **cannot block**,
  so that failure mode is excluded by construction rather than by discipline — influence without a veto.

  Registered as a `command` handler. The text is written as **fact statements**, never as imperatives:
  the hooks reference is explicit that out-of-band-instruction phrasing trips the prompt-injection
  defence, after which Claude shows the text to the user instead of accepting it as context. Always
  exits 0, emits nothing off-delivery, and honours `TEAM_BOOTSTRAP_DELIVERY_GATE=off`.

### Role-execution recorder (v2.21.0, exec-role-integrity)

- **`PreToolUse` (matcher `Agent|Task`) → [`../bin/record-dispatch.sh`](../bin/record-dispatch.sh)** — a
  **non-blocking, recording-only** hook. On each subagent dispatch it reads `tool_input.subagent_type`
  and, when that type is in the dedicated review-type set ([`review-types.txt`](review-types.txt)),
  appends `{batch, subagent_type}` for the in-flight batch to `.runs/<run>/dispatch.jsonl`. This makes
  "an independent reviewer was **dispatched**" a harness-observed fact, so the `role-dispatch`
  `verify-batch` gate ([`../bin/check-role-dispatch.sh`](../bin/check-role-dispatch.sh)) can catch a
  `full`/`mvp` batch that silently collapsed build+review into one inline mind (spec-169) and announce it.
  It records **dispatch occurrence, no completion status** — subagents run background-by-default, so
  `PostToolUse[Agent]` returns `status:"async_launched"` (never `completed`) and `SubagentStop` is flaky
  ([#27755](https://github.com/anthropics/claude-code/issues/27755)); `PreToolUse[Agent]` reliably carries
  the type at dispatch. It **always exits 0** (recording only — like the marker writer, never a deadlock
  or a block) and marker-gates to a no-op off-session. Honest limit: `subagent_type` is model-authored, so
  this is **degradation-proof, not forgery-proof** (ADR [0008](../docs/adr/0008-harness-verified-role-execution.md)).

### Verdict capture (v3.4.x, issue #60)

- **`SubagentStop` (matcher: the review-role agent types) →
  [`../bin/check-role-verdict.sh`](../bin/check-role-verdict.sh)** — a **plugin-level** registration that
  fires when a review subagent finishes. The capture path used to be **only** each review agent's
  frontmatter `Stop` (converted to `SubagentStop` while that subagent runs); relying on that alone,
  verdict capture measured **0-of-N** on live Agent/Task-tool runs, so every `kind:code` batch closed on
  a `role_verdict_waiver`. Two mechanism facts from the Claude Code hooks reference drove the fix:
  - `SubagentStop` **matches on `agent_type`** (the same values as `SubagentStart`, which this plugin
    already uses successfully), so a single plugin-level registration covers every review type and
    recovers the role from the payload's `agent_type` — no per-agent `--hook-role` needed.
  - the payload carries **`agent_transcript_path`** (the finished subagent's OWN transcript) distinct
    from **`transcript_path`** (the MAIN session transcript). The verdict object lives in the subagent
    transcript, so the hook now reads `agent_transcript_path` first and falls back to `transcript_path`.
    Reading only `transcript_path` scanned the wrong file and captured nothing **even when the hook
    fired** — a second, independent cause of the 0-of-N symptom.

  Both channels (plugin-level `SubagentStop` and per-agent frontmatter `Stop`) now coexist; a capture is
  recorded **once** (deduped by batch+role). It **blocks (exit 2) only on a malformed verdict** — a
  well-formed verdict passes, so it cannot deadlock the closure step.

  **Honest limit.** That the host actually *delivers* a plugin-level `SubagentStop` for an Agent-tool
  dispatch is a host capability this layer cannot force or self-test; the documentation asserts it, and a
  bash test can prove the hook's LOGIC (role from `agent_type`, verdict from `agent_transcript_path`) but
  not the event's firing. So the **batch-close gate** (`check-role-verdict --gate`, a proven-firing path)
  writes a diagnostic trace to `.runs/<run>/verdict-capture.jsonl` whenever a `kind:code` batch closes
  with zero captured verdicts, recording WHY (reviewers dispatched but capture produced nothing ⇒
  `capture-channel-did-not-fire`) instead of the old "did not run OR could not read" guess.

## Layering (which gate runs where)

| Gate | Where | Enforces |
|---|---|---|
| Typecheck + Lint | **Stop hook** (`quality-gate.sh`) | fast, every completion — 100% |
| Red→green + evidence | role handoff schema (`verification_evidence`, `tests_failed_first`) | TDD + evidence, per role |
| E2E + no-orphans | `integration-verifier` role | wiring, per batch |
| Batch gate (orphans + drift + gate-integrity) | `bin/verify-batch.sh` at batch close **+ CI** | dead code / drift / green-by-skip — non-bypassable at merge ([enforcement.md](enforcement.md)) |
| Role execution (reviewer dispatched, not inline collapse) | `PreToolUse` recorder + `check-role-dispatch.sh` in `verify-batch` | a `full`/`mvp` code batch that dispatched no reviewer subagent — announced, per batch (ADR [0008](../docs/adr/0008-harness-verified-role-execution.md)) |
| Full suite from scratch | CI (`.github/workflows/ci.yml`) | independent environment |

## Controls

- Disable the quality gate for a session: `TEAM_BOOTSTRAP_QUALITY_GATE=off`.
- Disable the delivery hooks (marker writer + Stop) for a session: `TEAM_BOOTSTRAP_DELIVERY_GATE=off`.
- Optional hardening (not shipped on by default): a **PreToolUse** hook can block destructive Bash
  ahead of the [irreversibility](irreversibility.md) taxonomy — add it in project
  `.claude/settings.json` if you want belt-and-suspenders on top of `tool_surface`.

## Two vendor facts that bound what a hook can promise

**A `PreToolUse` hook timeout does not block.** The hooks reference states it directly: do not expect a
hung hook to act as a gate. A timeout is not a refusal — the tool call proceeds. This matters because
the obvious mental model is the opposite one, and a gate designed around "if my hook hangs, nothing
happens" would fail open exactly when it is under load or under attack.

Audited against this project: **no gate here relies on a hook hanging.** Every blocking point exits
with code **2**, which is the only exit code that blocks (`1` is a non-blocking error — the reference
warns about this separately). `guard-git.sh` is the one blocking `PreToolUse` body, and it refuses by
exiting 2 or by returning `permissionDecision`; it has no path that blocks by delay. `Stop` hooks
(`quality-gate.sh`, `delivery-stop-hook.sh`) and `PostToolBatch` (`check-review-batch.sh`) likewise
refuse by exit code. Re-run the audit with:

```
grep -rn 'exit 1' bin/guard-git.sh bin/quality-gate.sh bin/delivery-stop-hook.sh
```

Any blocking decision found on `exit 1` rather than `exit 2` is a gate that does not gate.

**`SubagentStart` cannot block and is command-only.** Its `additionalContext` reaches the **subagent's**
conversation, not the parent's, and `prompt`/`agent` handlers are not supported on it. So a verdict a
subagent needs must be *already computed* before the spawn — `UserPromptExpansion` is where this project
computes it (`judge-tier.sh`), and `SubagentStart` only delivers it (`subagent-brief.sh`). That split is
not a preference; it is what the event supports.
