# team-bootstrap Constitution

**Version: 1.0.0** · Governs the invariants every milestone and role change must respect.
This is the `principles` document referenced by
[references/speckit-preimpl-flow.md](references/speckit-preimpl-flow.md) Step 1. It distills
the doctrine already stated across [ARCHITECTURE.md](ARCHITECTURE.md),
[references/irreversibility.md](references/irreversibility.md),
[references/guardrails.md](references/guardrails.md), and
[references/versioning.md](references/versioning.md) into enforceable, versioned rules.

Amendment rules are at the bottom. Changing an invariant is a constitution version bump.

---

## Principles (architectural invariants)

### P1 — Single-thread by default; multi-role for audit
Most tasks run as one Claude session with roles as phase boundaries. Multi-role pipelines
(`mvp`, `full`, `audit`, `audit-dd`) are the **sanctioned exception**, used only when a task
needs formal phase gates and an explicit audit trail (compliance, production release,
regulated or investment work). Adding orchestration where single-thread suffices violates P1.

### P2 — Shared context broadly; subagents narrowly
The full run document is the shared blackboard — every role reads complete prior state, not
just the last handoff. Subagents are dispatched **only for context isolation** (research,
security audit, parallel reviews) and **never to delegate a decision**. A subagent that
decides something the orchestrator should own violates P2.

### P3 — Harness-enforced policy; LLM out of the security loop
Tool surfaces and irreversibility classes are declared in role frontmatter and enforced by
Claude Code permissions/hooks. **The model never decides whether an action is safe — the
harness does.** No role may self-authorize an action outside its declared `tool_surface`.

### P4 — Typed, schema-validated handoffs; no silent extras
Every role ends with a YAML handoff validated against
[references/schemas/role-output.schema.json](references/schemas/role-output.schema.json)
(`unevaluatedProperties: false` — unknown fields are rejected, not ignored). A run does not
advance on an invalid handoff; it takes a bounded retry, then stops.

### P5 — Irreversibility is gated; never act destructively without approval
Destructive or irreversible actions (force-push, prod deploy, data deletion, external
publish) require an explicit per-call approval gate per
[references/irreversibility.md](references/irreversibility.md). **Never push to a remote or
deploy without explicit human authorization** — the orchestrator commits locally and surfaces
state; the human authorizes the outward step.

### P6 — Report truth; blocked over false-complete
A role never claims `completed` when checks failed or were skipped — it emits `blocked` with
concrete failures. No fabricated test results. Any bounded coverage (top-N, sampling, skipped
reviewer) is logged, never silently dropped ("no silent caps").

### P7 — Portable substrate; no runtime lock-in
Roles are markdown; contracts are JSON Schema 2020-12; observability is OpenTelemetry. A
change that makes the framework depend on a proprietary runtime to function violates P7.
"If Claude Code goes away, you keep the spec."

### P8 — Versioned evolution behind an enforced gate
Roles and this constitution follow SemVer. A role behavior change bumps its version and must
pass the eval gate ([references/versioning.md](references/versioning.md),
[references/trace-evals.md](references/trace-evals.md)) — static frontmatter validation plus
behavioral regression — before it lands.

### P9 — Verify by red→green and evidence, never by assertion
Implementation follows TDD: tests are written first, **run and seen to fail**, then implemented to
green, and never weakened to pass ([references/tdd.md](references/tdd.md)). A `completed`
engineering/QA handoff must carry `verification_evidence` — real command output, not a claim —
and fast checks are harness-enforced by the Stop hook ([references/hooks.md](references/hooks.md)).
Wiring is proven end-to-end by [integration-verifier](references/roles/integration-verifier.md),
not by self-report. This operationalizes P6 (report truth) for code.

### P10 — Verification is cumulative and fail-closed
A closure holds only if its invariant holds **across all workflows now**, not "for the workflow that
existed that day": verified acceptance **graduates** into a regression suite re-run every batch/
milestone ([regression-and-invariants.md](references/regression-and-invariants.md),
[regression-guardian](references/roles/regression-guardian.md)). A declared capability must be
**exercised**, not merely present (`declared ⇒ exercised`). And a gate that did not actually run —
green-by-skip, silently disabled, vacuous — is a **failure, not a pass**. Point fixes that close a
class in one place while leaving it open elsewhere violate P10.

---

## Boundary rules

- **In scope:** role playbooks, pipelines, handoff/ frontmatter schemas, orchestration
  doctrine, guardrails, eval harness, tracing conventions, planning doctrine.
- **Out of scope:** a bundled runtime, a hosted service, vendor-specific SDK code. Those are
  separate products, not part of this asset (see P7).

---

## Enumeration invariants

Step 1 of the pre-implementation flow must verify these counts against reality (`grep`/`ls`)
before claiming a threshold, and flag any delta:

| Invariant | Current | Bump trigger |
|---|---|---|
| Role playbooks (`references/roles/*.md`) | 51 | New role → PATCH (new sanctioned enumeration entry) + role-matrix row + schema branch + skills-manifest entry |
| Pipelines (`references/pipelines/*.md`) | 6 | New pipeline → MINOR (new doctrine surface) |
| Reviewer roles carrying `severity_counts` | 4 | New reviewer dimension → MINOR |
| Irreversibility action classes | see [irreversibility.md](references/irreversibility.md) | New class → MINOR |

## Registry impact

Adding a role touches, in the same change: the role playbook, its
`role-output.schema.json` branch, its `role-matrix.md` row, and its `skills-manifest.json`
`used_by` entry. A role added to only some of these is an incomplete change.

---

## Amendment rules (constitution SemVer)

- **PATCH** — clarification or wording; no rule redefined.
- **MINOR** — a new principle, a new sanctioned exception, or a new enumeration invariant.
- **MAJOR** — changing, weakening, or removing an existing invariant (P1–P10).

Every milestone's Step 1 analysis
([references/speckit-preimpl-flow.md](references/speckit-preimpl-flow.md)) must state which,
if any, of these apply, with rationale, before spec drafting begins.
