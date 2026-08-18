# 0008 — Role execution is harness-observed by a typed reviewer dispatch

- **Status:** Accepted
- **Date:** 2026-08-18
- **Constitution clause(s):** P2, P3, P6, P10
- **Supersedes the honest limit of:** [0006](0006-independence-clean-context.md) (forgeable-marker residual)

## Context

The `full`/`mvp` pipelines exist to give each batch a fresh, **independent** mind — builder ≠ reviewer
(P2). On spec-169 that separation collapsed **silently**: a builder subagent hung on preconditions, the
orchestrator took over the build **and** the reviewer role, the machine backstop (`verify-batch`) still
went green, and the user was told "delivered, gates passed" while the role pipeline never ran. The result
was four "zoom-out" semantic gaps that only an independent as-built review raises.

[0006](0006-independence-clean-context.md)'s `check-review-ack` already forces an independent-review
*artifact* (reviewer≠builder, context:clean, verdict:go, commit-anchored) — but that artifact is an
**orchestrator-written marker string**, forgeable by the same orchestrator (0006's disclosed limit). The
milestone `exec-role-integrity` asks: can the harness *observe* that an independent reviewer actually ran,
so a silent total-inline collapse becomes catchable and announced?

Two designs were demolished before the shipped one:

- **Occurrence-count** (any `Agent` dispatch happened) — rejected: it **passes spec-169** (the builder was
  a subagent, so ≥1 dispatch occurred) and is satisfied by any incidental dispatch. The signal must
  distinguish a *reviewer* from a *builder*.
- **A completion-gated signal** (`PostToolUse[Agent].status == "completed"`) — rejected: subagents run
  background-by-default, so `PostToolUse[Agent]` returns `status:"async_launched"`, **never** `completed`,
  for the parallel-reviewer fan-out. A completed-gate would false-block every healthy parallel review. And
  `SubagentStop` is flaky ([#27755](https://github.com/anthropics/claude-code/issues/27755)).

## Decision

Record role execution at the **`Agent`-tool dispatch boundary**, keyed on the reviewer **type**:

- A **non-blocking `PreToolUse[Agent]` hook** (`bin/record-dispatch.sh`) reads `tool_input.subagent_type`
  and, when it is in the **dedicated review-type set** ([`references/review-types.txt`](../../references/review-types.txt),
  the single source), appends `{batch, subagent_type}` to `.runs/<run>/dispatch.jsonl`. Dispatch
  **occurrence**, no completion status (probe-confirmed reliable foreground + background). Always `exit 0`
  (recording only — no `SubagentStop` deadlock hazard).
- A `verify-batch` gate (`bin/check-role-dispatch.sh`) **fails closed + announces to the user** when a
  `full`/`mvp` `kind:code` batch closes with **zero** reviewer-typed dispatches for its window — the
  spec-169 collapse signature. `single-thread` (P1 sanctions inline roles) and non-`kind:code` batches skip.
- **Doctrine:** in `full`/`mvp` the four mandatory review roles (integration-verifier,
  architecture-reviewer conformance, regression-guardian, code-reviewer) **must** dispatch as subagents
  with a dedicated review type (the plugin agent `independent-reviewer`), single-sourced so the doctrine,
  the recorder, and the gate cannot drift. Two of those roles previously had no `subagent-mapping` row and
  fell to `general-purpose` (indistinguishable from a builder) — now mapped.
- **Corroboration:** a `check-review-ack` `review_acks` entry is valid in `full`/`mvp` only when a
  reviewer-typed dispatch is recorded for that batch — the marker `reviewer` claim must be
  harness-corroborated, not a bare string.

## Consequences

- A silent collapse of `full`/`mvp` review to inline is now a **catchable, announced degradation**, moving
  enforcement of *process* (not only outcomes) off the LLM and onto the harness — the same prose→harness
  move `verify-batch` already embodies for outcomes.
- **Honest limit (load-bearing, must not be overstated):** `tool_input.subagent_type` is the model's
  dispatch *argument*, not a harness-minted value. So the gate is **degradation-proof, not forgery-proof** —
  it catches an orchestrator that collapses review to inline (dispatches no reviewer-typed subagent), but a
  determined orchestrator could dispatch one throwaway review-typed no-op subagent to satisfy it. That
  residual is the [0006](0006-independence-clean-context.md) quality/willingness limit (raised in cost from
  a free marker string to a real decoy dispatch), **not** a defeat of the independence contract. It must
  never be described as "non-forgeable."
- **Dispatch ≠ completion (NF1):** recording at `PreToolUse` proves the reviewer was *launched*, not that
  it *completed* or was *good*. A reviewer dispatched with the right type that then hangs passes this gate;
  completion rests on `check-review-ack`'s `verdict:go` (honest case) and quality on 0006 + the refutation
  doctrine.
- **≥1, not all four (disclosed floor):** the doctrine asks all four review roles to dispatch as subagents,
  but the gate fails only on **zero** reviewer-typed dispatches — it verifies that *an* independent review
  ran, not that *every* required role did. A partial collapse (e.g. 1 of 4 roles dispatched, the other three
  folded inline) passes. This is deliberate: zero-vs-nonzero is the spec-169 total-collapse signature and is
  robust; a per-role count would need per-role attribution the dispatch record does not carry. Raising the
  bar to a required-role count is future hardening, not a property this gate claims today.
- **In-session only (no CI backstop):** like the delivery/TDD layers, this gate is marker- and
  `dispatch.jsonl`-gated, and `.runs/` is gitignored — so a fresh CI checkout has no dispatch record and the
  gate skips. Enforcement is in-session (the harness records the dispatch as the run happens); it is **not**
  reproduced by CI unless the run commits its `.runs/` artifacts.
- No constitution bump: this hardens P2/P3/P6/P10 as already written. Asset version MINOR (2.21.0) — an
  additive `verify-batch` gate + a non-blocking recorder + a new `dispatch.jsonl` surface, marker-gated and
  scoped, backward-compatible.
