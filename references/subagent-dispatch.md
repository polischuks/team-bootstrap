# Subagent Dispatch

When a role runs **inline** in the main thread vs. dispatched as a **subagent** via Claude Code's `Task` tool.

## Default

**Inline.** The orchestrator activates the role's instructions as the active output style and continues in the main thread. The role reads the shared blackboard ([shared-blackboard.md](shared-blackboard.md)) and emits its handoff. This preserves shared context — the central principle from Cognition's "Don't Build Multi-Agents."

## When to dispatch as subagent

Dispatch **only** when context isolation strictly outweighs the cost of summarization:

| Trigger | Rationale |
|---|---|
| Role will read >5 files of code in detail (e.g. security audit on a wide surface) | Subagent context fills with raw file content; main thread stays clean |
| Multiple reviewers can run in parallel (security + perf + a11y on the same diff) | Wall-clock speedup; outputs merged on return |
| Long-form research (discovery-research with web fetches) | Web content is bulky and rarely needed by downstream roles verbatim |
| **Novel/risky domain before implementation** → dispatch `discovery-research` for a **best-practices brief** (once per domain, novelty-gated) | Ground the domain in current practice before code; distilled brief returns, raw pages stay isolated ([best-practices-research.md](best-practices-research.md)) |
| User explicitly requests isolation for compliance reasons | Auditable separation of inputs |

### Do not dispatch

For these roles, inline execution is mandatory by default ([subagent-mapping.md](subagent-mapping.md#inline-only-roles) lists the same set):

- Planning roles (product-ba, delivery-manager, architects) — they need full context to make decisions
- Implementation roles (backend, frontend) — edits + verification are tightly coupled and must stay coherent
- Anything that produces decisions the next role inherits — Cognition's anti-pattern

## Dispatch contract

When the orchestrator dispatches a role to a subagent:

### Subagent input

```yaml
role: <role-name>
spec: <task brief, full text>
blackboard_slice:
  - <relevant prior-role section, full text>
  - <relevant prior-role section>
artifacts:
  - kind: <type>
    path: <repo-path>
relevant_files: [<paths>]
tool_surface: <from role frontmatter>
permission_mode: <from role frontmatter>
return_format: handoff_yaml
```

The slice is curated by the orchestrator: include sections the role will actually need, not the entire blackboard. Rule of thumb: ≤30% of the main-thread context, never the full transcript.

### Subagent return (enforced budget)

A subagent may burn tens of thousands of tokens internally, but only a **bounded, condensed**
result is allowed to cross back into the main thread. This is what separates a context-isolated
subagent from a naive one that dumps its whole working set into the shared blackboard. The return
budget is a **hard contract**, not a suggestion:

Exactly three things cross back:

1. the **structured handoff** (the role's object per [schemas/role-output.schema.json](schemas/role-output.schema.json)), whose `summary` is **capped at ≤~200 tokens (~1200 chars)** — the schema enforces `maxLength` on `summary`;
2. **artifact paths** — never artifact *bodies*. A security audit's full finding list, a research role's raw fetches, a reviewer's annotated diff all go to **files**; the handoff references their paths;
3. nothing else.

The main thread then:

1. Validates the handoff against schema (a summary over budget fails validation → counts against the role's retry budget);
2. Appends the handoff + the condensed summary to the blackboard;
3. Decides next role per pipeline.

Subagent thinking, intermediate file reads, and tool calls are **not** propagated to the main thread. They are captured in the trace ([tracing.md](tracing.md)) for replay, not forwarded inline. This budget matters most for deep-audit / research roles (`security-reviewer`, `discovery-research`, `performance-reviewer`) whose internal context is large and rarely needed verbatim downstream.

## Failure handling

- **Subagent crashes / no return:** orchestrator records `stop_reason: subagent_failed`, retries once with the same input, then escalates as `blocked`.
- **Subagent returns invalid handoff:** counts against the role's retry budget per [failure-policy.md](failure-policy.md). On exhausted budget, escalate.
- **Subagent timeout** (default: 10 minutes): treat as failure.

## Parallel dispatch (reviewers)

When multiple reviewer roles can run in parallel (data-schema, accessibility, performance, security on the same implementation snapshot), the orchestrator dispatches them as concurrent subagents and collects all returns before continuing.

```text
[main thread] frontend-engineer completed
              ↓
              ├─→ subagent: data-schema-reviewer
              ├─→ subagent: accessibility-reviewer
              ├─→ subagent: performance-reviewer
              └─→ subagent: security-reviewer
              (parallel)
              ↓ (all complete)
[main thread] qa-test-engineer (sees all four review handoffs in blackboard)
```

This is the only place team-bootstrap intentionally fans out. The `full` pipeline accommodates this when the orchestrator decides to parallelize step 11-14; sequential execution remains the conservative default.

## Anti-patterns

- **Dispatching to "save context" without need.** If the role doesn't read a lot or run long, inline is cheaper.
- **Dispatching planning roles.** They make decisions downstream roles inherit; private context fragments those decisions.
- **Forwarding subagent transcript to main thread.** Use the structured handoff and a brief summary; the transcript lives in the trace.
- **Chaining subagents (subagent dispatches another subagent).** team-bootstrap supports one level of dispatch from the main thread. Deeper trees produce the fragmentation Cognition warned about.

## Implementation note for orchestrator

Use Claude Code's `Task` tool. **Resolve `subagent_type` from the role's `preferred_subagent_types` frontmatter** per [subagent-mapping.md](subagent-mapping.md):

1. Read `preferred_subagent_types: [...]` from `references/roles/<role>.md` frontmatter.
2. Apply stack overrides from [subagent-mapping.md](subagent-mapping.md) — e.g. `nextjs-developer` when `AGENTS.md > ## Stack` lists Next.js, `fastapi-developer` for FastAPI, etc. Stack vector is resolved **once** at run start and cached in run metadata.
3. Walk the (possibly stack-overridden) list left-to-right; pick the first slug that resolves in the host environment.
4. If none resolve, fall back to `subagent_type: general-purpose`.
5. Record the resolved slug as `team_bootstrap.subagent_type` on the role span ([tracing.md](tracing.md)) so eval/replay sees the routing decision.

The orchestrator's own guardrails (`tool_surface`, `permission_mode`, irreversibility class) are applied on top of the specialist's defaults — the specialist's expertise is used, but team-bootstrap wins on tools and permissions.

The orchestrator must include explicit instructions to return the handoff YAML — the `Task` tool returns one final string, so the prompt must direct the subagent to emit valid YAML.

See [orchestrator.md](orchestrator.md) for the dispatch decision point in the execution loop, and [subagent-mapping.md](subagent-mapping.md) for the role→specialist mapping table.

## Independent post-code review (v2.20.0, gate C)

A `kind:code` batch's post-code review is dispatched as a **clean-context subagent** that receives **only
the diff + the enumerated refutation criteria** — never the builder's run document or reasoning. This is
what makes the review independent (generator≠verifier): a same-context reviewer inherits the biases that
produced the code. The reviewer is prompted to **refute** (Refute-or-Promote), returns
`review_acks`/`review_refutations` ([roles/code-reviewer.md](roles/code-reviewer.md)), and the orchestrator
transcribes them to the run marker. `check-review-ack.sh` blocks closure without a valid entry
(reviewer≠builder, context:clean, verdict:go, commit anchored). **Escalation:** an `irreversible`-classed
batch, or a review that leaves a credible refutation unresolved, emits `verdict:blocked` → **human ack**;
the orchestrator never self-closes over a blocked review (P5). Cross-model review is optional hardening for
irreversible/security batches; clean-context subagent independence is the enforced floor (P7, ADR-0006).

## Harness-verified reviewer dispatch (v2.21.0, exec-role-integrity — REQUIRED in full/mvp)

v2.20.0's `check-review-ack` proves an independent review *artifact* exists, but that artifact is an
orchestrator-written marker string — forgeable (ADR-0006). This tightens it to a **harness-observed
fact**: in `full`/`mvp`, the **four mandatory review roles** — `integration-verifier`,
`architecture-reviewer` (conformance), `regression-guardian`, `code-reviewer` — **must** be dispatched as
subagents with an **identifiable review `subagent_type`** (the dedicated `independent-reviewer`, or another
type in the single source [`review-types.txt`](review-types.txt)), **never** inline and never as generic
`general-purpose`. A `PreToolUse[Agent]` hook (`bin/record-dispatch.sh`) records each reviewer-typed
dispatch to `.runs/<run>/dispatch.jsonl`, and `bin/check-role-dispatch.sh` (a `verify-batch` gate) **fails
closed + announces to the user** when a `full`/`mvp` `kind:code` batch closes with **zero** reviewer-typed
dispatches — the signature of the spec-169 silent collapse to single-thread.

**Why this is a contract change:** running a review role *inline* in `full`/`mvp` now produces zero
reviewer dispatches and is therefore a **catchable degradation**, not a sanctioned shortcut. In
`single-thread` the opposite holds — P1 sanctions inline roles as phase boundaries, so the gate **skips**
it entirely.

**Honest limit (ADR-0008):** `subagent_type` is the model's dispatch argument, not a harness-minted value.
So this is **degradation-proof, not forgery-proof** — it catches a total inline collapse, not a decoy
review-typed no-op dispatch (that residual stays the ADR-0006 quality/willingness limit). It proves a
reviewer was *dispatched and independent* (≠ builder type), not that the review was *good*.

## Per-role dispatch — each review role under its OWN type (all-four-role-dispatch, v2.22.0)

The exec-role-integrity gate above catches only a **total** collapse (zero reviewer dispatches); a *partial*
collapse — 1 of the 4 mandatory roles dispatching while 3 ran inline — passes it. Per-role dispatch raises the
floor to the mandate: **each mandatory review role dispatches under its own dedicated, collision-free type** —
`integration-verifier`, `architecture-reviewer`, `regression-guardian`, and **`tb-code-reviewer`** (NOT bare
`code-reviewer` — the `team-bootstrap:` prefix is not reliably delivered in `subagent_type`, so the slug must
be attributable even when bare). This is **required** because `subagent_type` alone could not otherwise
attribute a dispatch to a role: `integration-verifier` and `regression-guardian` had byte-identical preferred
types, and `independent-reviewer` was shared by all four. **This supersedes** exec-role-integrity's "dispatch
all four under `independent-reviewer`" mandate.

`references/review-types.txt` maps each dedicated slug → its role (an optional TAB column); `role_of_slug`
attributes, `roles_covered`/`missing_roles` compute the gap, and `check-role-dispatch.sh` / `check-review-ack.sh`
enforce that a `full`/`mvp` `kind:code` batch covers **every** mandated role (`full` = all four; `mvp` =
`code-reviewer` + `regression-guardian`). Dispatch the dedicated agents in `agents/` (`integration-verifier.md`
etc.), supplying the role playbook `references/roles/<role>.md` in the prompt.

**warn → enforce ramp (mechanical, evidence-gated, no version tripwire).** The per-role floor ships in **warn**
(announces the missing roles, does not fail — the ≥1 floor stays hard beneath it). It flips to **enforce** only
when the tracked marker **`references/role-dispatch-enforce`** is present (override: `TEAM_BOOTSTRAP_ROLE_FLOOR`).
Committing that marker is the deliberate, evidenced flip — done **only after the dispatch probe** below confirms
adoption, like a governed waiver. Until then the gate stays warn: the plugin **cannot force** the orchestrator
to emit four distinct slugs (the harness boundary), so enforce is reachable only once measured — never claimed
without proof, never a silent flip.

**Dispatch probe (the enforce precondition).** Before committing `references/role-dispatch-enforce`, run a real
marked `/deliver` and confirm from `.runs/<run>/dispatch.jsonl` that (a) each dedicated slug is dispatchable,
(b) it lands **verbatim** in `tool_input.subagent_type` under prefix-loss, and (c) the orchestrator emits **four
distinct** slugs (not routed through the one `independent-reviewer` agent → ∅ attribution). Cross-check against
the warn-phase `role-telemetry.jsonl`. Only a passing probe authorizes the enforce commit.

**Honest limit carried forward:** per-role raises the **degradation** floor (partial collapse now caught under
enforce), NOT the **forgery** bar — four decoy no-op dispatches under the four dedicated types still satisfy it.
Dispatch ≠ completion (`check-review-ack`).
