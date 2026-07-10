# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Architecture conformance & soundness gates** ([references/architecture-reviewer.md](references/roles/architecture-reviewer.md),
  [references/architecture-baseline.md](references/architecture-baseline.md)) — closes the gap where
  a batch passes tests + E2E wiring yet violates the app's architecture (architectural **drift**).
  New independent `architecture-reviewer` role (builder ≠ auditor, `thinking: extended`) with two
  modes: **soundness** (Phase A — is `plan.md` correct and baseline-fitting? gate before any batch)
  and **conformance** (Phase B — per batch, no drift from the baseline; hard gate). Schema-enforced:
  a `completed` handoff requires `architecture_sound`/`conformance_verified` true and
  `drift_findings: 0`.
- **`bin/check-architecture.sh`** — architecture **fitness functions**: delegates to the project's
  arch-lint tool (dependency-cruiser / Deptrac / go-arch-lint) or applies declared forbidden-import
  rules from the baseline. Wired into `mvp`/`full` (after `integration-verifier`) and both `/deliver`
  phases.
- Role count 49 → 50; MVP 8 → 9, Full 21 → 22 (role-matrix, constitution enumeration, SKILL).
  `AGENTS.md` gains an optional `## Architecture` (baseline) section.
  Grounded in [architectural fitness functions](https://www.infoq.com/articles/fitness-functions-architecture/),
  [conformance/governance](https://developersvoice.com/blog/architecture/architectural-fitness-functions-automating-governance/),
  and [drift vs. erosion](https://earezki.com/ai-news/2026-06-08-architecture-drift-detection-keep-your-code-aligned-with-design/).

## [2.3.0] - 2026-07-09

Agent-quality & autonomy hardening — Tier 1 + Tier 2 practices from Anthropic and other vendors,
applied to the pipeline. Sources: [Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents),
[Claude Code best practices](https://code.claude.com/docs/en/best-practices),
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents),
[Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents),
[OpenAI — A practical guide to building agents](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/),
[The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification).

### Added

- **TDD red→green discipline** ([references/tdd.md](references/tdd.md)) — tests first, **run and
  seen to fail**, implement to green, tests immutable. Engineer handoffs set `tests_failed_first`.
- **Harness-enforced quality gate (hooks, ~100% vs ~70% prose)** — `hooks/hooks.json` Stop hook
  runs `bin/quality-gate.sh` (fast typecheck+lint from AGENTS.md; no-ops outside team-bootstrap
  projects; `TEAM_BOOTSTRAP_QUALITY_GATE=off` to disable). Full/E2E stay with integration-verifier
  + CI. ([references/hooks.md](references/hooks.md)).
- **Evidence, not assertion** — `verification_evidence` (real command output) is schema-required
  when a `backend-engineer` / `frontend-engineer` / `qa-test-engineer` handoff is `completed`.
  Verified: `completed` without evidence is REJECTED.
- **Per-step ground-truth verification** — engineer roles verify (typecheck+lint+tests) after each
  significant change, not only at the end.
- **Structured note-taking** ([references/note-taking.md](references/note-taking.md)) — durable
  run-notes across compaction (third context lever beyond compaction + distilled subagent returns).
- **Adversarial & cross-model verification** ([references/adversarial-verification.md](references/adversarial-verification.md))
  — refutation panels + optional cross-provider second opinion for high-stakes calls.
- **Extended thinking** — new `thinking: extended` frontmatter field on high-reasoning roles
  (`cto-architect`, `cto-tech-lead`, `solution-architect`, `integration-verifier`,
  `release-manager`); documented in [references/model-tiers.md](references/model-tiers.md).
- **Outcome-based evals (north-star)** + new grader dimensions (`evidence_present`,
  `red_green_followed`, `outcome_pass_rate`, `adversarial_escalation_honored`) in
  [references/trace-evals.md](references/trace-evals.md).
- **Constitution P9** — verify by red→green and evidence, never by assertion.

## [2.2.0] - 2026-07-09

Reliability milestone: an outcome-based integration gate that stops agents from shipping unwired
/ dead code while reporting success. MINOR — new role + additive gate, no breaking changes.

### Added

- **`integration-verifier` role + hard integration gate** — closes the "backend built the
  endpoint, frontend never called it, both reported done" failure. An independent, read-only
  auditor runs after the builders (`mvp`/`full`, and each `/deliver` batch) with a **clean
  context** (builder ≠ auditor): it executes the E2E command from `AGENTS.md` and scans for
  orphans (any produced endpoint/component with no live consumer). Schema-enforced hard gate — a
  handoff **cannot be `completed` unless `integration_verified: true` and `orphans_found: 0`**;
  otherwise `blocked`, sent back, and after 3–5 attempts stopped for human rollback. Grounded in
  published vendor practice: outcome-based verification, evaluator-optimizer separation, and
  harness-enforced gates ([Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents),
  [The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification)).
- **`bin/check-orphans.sh`** — heuristic dead-code/unwired-artifact scan over a batch diff
  (advisory input to the verifier): flags added exports/routes with no consumer.
- **Vertical-slice doctrine** in the pre-implementation flow and `/deliver`: batches deliver a
  working end-to-end path, and acceptance criteria are written as user-observable outcomes — not
  horizontal layers. Role count 48 → 49 (constitution enumeration updated, MINOR).

## [2.1.1] - 2026-07-04

Patch: portability + correctness fix for the l2p citation gate, surfaced by dogfooding the
pipeline on a live landing.

### Fixed

- **`bin/check-citations.sh`**: table-header rows are now skipped structurally (the line above a
  `|---|` separator) instead of by a case-sensitive keyword list — fixes false positives on
  lowercase headers. Rewritten single-pass without `mapfile` so it runs on bash 3.2 (macOS),
  where the previous version silently passed. Surfaced by dogfooding the `l2p` pipeline on a live
  landing.

## [2.1.0] - 2026-07-04

Adds the `l2p` (Landing-to-Platform) gap-audit pipeline — a third read-only audit lens that
turns landing↔platform↔docs gaps into an implementation backlog. MINOR: new pipeline + six
roles, no breaking changes.

### Added

- **`l2p` pipeline** ([references/pipelines/l2p.md](references/pipelines/l2p.md)) — read-only
  Landing-to-Platform gap audit: finds where landing promises, platform delivery, and docs
  diverge, and turns each gap into an ICE-ranked implementation task that `single-thread` /
  `mvp` / `full` (or `/deliver`) consume. Six new roles (`recon`, `usecase-miner`,
  `cartographer`, `funnel-auditor`, `gatekeeper`, `gap-backlog-author`) with strict evidence
  discipline — every downstream claim cites a `recon` grounding id (C###/S###/F###/I###) or is
  tagged HYPOTHESIS/ESTIMATE. Domain refs under [references/l2p/](references/l2p/).
- **`bin/check-citations.sh`** — machine-checked evidence gate: scans `l2p-artifacts/` for
  assertions lacking a grounding id, hardening the citation discipline that was previously
  prose-only.
- Role count 42 → 48; pipelines 5 → 6 (constitution enumeration updated, MINOR per its rules).
  Ports the funnel-cartography framework into team-bootstrap as a native audit→backlog lens.

## [2.0.0] - 2026-07-04

Spec-driven delivery milestone: a one-command flow (`/deliver`) chains the full
pre-implementation sequence into step-by-step batch delivery, backed by a versioned
constitution and milestone scaffolding, plus reviewer-consensus and disposition gates. Major
bump reflects the new delivery entry point and governance model. The handoff-contract change is
**backward-compatible** (the new field is optional; older handoffs still validate).

### Added

- **`/deliver` command** ([commands/deliver.md](commands/deliver.md)) — one entry point that runs
  the full pre-implementation flow autonomously (`speckit-constitution` → `specify` → `clarify` →
  `plan` → `tasks` → `analyze`), gates on unresolved blockers, then drives implementation batches
  **step-by-step** through `mvp`/`full` (waits for confirmation between batches; commits local,
  never pushes without authorization). Documented in USAGE.md.

- **Pre-implementation flow doctrine** ([references/speckit-preimpl-flow.md](references/speckit-preimpl-flow.md)):
  a 6-step spec → plan → tasks → dispatch sequence, positioned as the recommended **first step**
  before pipelines run and mapped onto the bundled `speckit-*` skills. Linked from README and SKILL.md.
- **Pre-implementation scaffolding** so the flow runs against team-bootstrap itself:
  [`constitution.md`](constitution.md) v1.0.0 (invariants P1–P8 + amendment/enumeration rules
  distilled from existing doctrine), [`specs/`](specs/) convention with a milestone
  [`TEMPLATE/`](specs/TEMPLATE/), [`feature.json`](feature.json) active-milestone pointer, and
  [`docs/adr/`](docs/adr/) seeded with ADR-0001 (single-thread-by-default).

- **Reviewer consensus signal.** Optional `reviewer_consensus` array on the reviewer roles
  (`code-reviewer`, `security-reviewer`, `performance-reviewer`, `accessibility-reviewer`,
  `data-schema-reviewer`): per-finding `flagged_by` / `reviewers_total` / `disposition`, so a
  finding raised by a majority of independent reviewers reads as high-confidence and the
  denominator stays honest about reviewers that didn't run. Documented in
  [trace-evals.md](references/trace-evals.md).
- **Disposition gate before `go`.** `release-manager` emits an optional
  `unresolved_blocking_findings`; whenever present, a `go` decision requires it to be `0`, so no
  open CRITICAL/HIGH finding can coexist with a ship verdict. The field is optional (older
  handoffs stay valid) and the playbook instructs roles to always emit it. New grading dimensions
  `disposition_gate_honored` and `consensus_denominator_honest` in
  [trace-evals.md](references/trace-evals.md).
- **Repo hygiene: `.github/dependabot.yml`** (github-actions ecosystem — the only dependency
  surface for a markdown asset) and **`.github/workflows/security.yml`** (shellcheck + `bash -n`
  on `bin/*.sh`, gitleaks secret scan). The markdown/shell analog of a vuln-scan gate.
- **`.github/workflows/release.yml`** — on a `v*` tag: verifies the tag matches `VERSION` and
  `plugin.json`, re-runs the role/JSON gates, packages the plugin as a tarball, and cuts a
  GitHub Release with auto-generated notes.

### Changed

- **Handoff contract (backward-compatible):** `release-manager` gains an optional
  `unresolved_blocking_findings` field. Existing handoffs without it remain valid; when present,
  the `go`-requires-`0` gate is enforced. No migration required.

## [1.7.0] - 2026-06-26

SOTA-hardening pass (steps B–E): tiered models, layered guardrails + circuit breaker, an
independent evaluator gate with a runnable per-role eval, an enforced subagent return budget, and a
runnable version gate. Also corrects `.claude-plugin/plugin.json` version (was stale at `1.0.0`) to
track the CHANGELOG line.

### Added

**Tiered model strategy across all 42 roles (step B).** The `model:` frontmatter field — previously
uniform `claude-opus-4-7` on every role — is now differentiated into three tiers and bumped to the
current generation. Opus (`claude-opus-4-8`, 12 roles) for production-critical / irreversible /
high-stakes reasoning (architecture, security, legal, money, release go/no-go, incident response,
schema migrations, AI engineering); Sonnet (`claude-sonnet-4-6`, 24 roles) for implementation,
reviews, and product/design/research; Haiku (`claude-haiku-4-5-20251001`, 6 roles) for mechanical /
comms / simple-check work. New [references/model-tiers.md](references/model-tiers.md) documents the
assignment rule and is the source of truth. This cuts run cost on long pipelines without lowering
quality where reasoning depth changes the outcome.

**Layered guardrails + circuit breaker (step C).** New [references/guardrails.md](references/guardrails.md)
formalizes guardrails as a layered defense instead of ad-hoc rules inside roles:

- **Input guardrail** — a new orchestrator Step 0.5 that screens the spec for injection/integrity,
  scope, and feasibility *before* the pipeline fans out, so a doomed or unsafe run is stopped before
  N roles burn tokens. Verdicts `pass` / `needs_input` / `reject`; safety is hard, scope is advisory.
  New stop reason `input_guardrail_rejected`.
- **Output guardrail** — documented secret/PII scan before any `Write`/`Edit`/commit/publish,
  composing with (not replacing) the irreversibility action-class gate.
- **Circuit breaker** — orchestrator now tracks tool-calls-without-progress per role and trips at
  `max_tool_calls_without_progress` (default `12`), independent of the schema retry budget (2) and
  verification loop (3). New stop reason `circuit_breaker_tripped`; policy in
  [failure-policy.md](references/failure-policy.md#circuit-breaker-policy).

The tool-layer guardrail (`tool_surface` + irreversibility action classes) already existed and is
cross-referenced, not changed.

**Independent evaluator gate + runnable per-role eval (step A).** New
[references/evaluator.md](references/evaluator.md) adds a GAN-style evaluator that judges a role's
artifact *before* the handoff is accepted, countering self-evaluation bias:

- **Context-reset judge** — the evaluator runs as a fresh subagent receiving only the success
  criteria + the artifact, never the generator's narrative or the full blackboard. This is the one
  sanctioned exception to inline shared-context execution; generators stay inline (Cognition intact),
  only the judge is isolated. The judge runs on a strong model regardless of the role's own tier.
- **Mandatory for** `release-manager`, `security-reviewer`, and code/migration-writing roles;
  on-demand elsewhere; skipped for roles with no verifiable artifact.
- **Per-dimension rubric** — `criteria_coverage` / `grounding` / `correctness` / `safety` /
  `quality`, scored one at a time on a 0–4 scale with concrete-evidence justifications and shuffled
  dimension order to cancel position bias.
- **Bounded evaluator-optimizer loop** — `pass` accepts; `revise`/`fail` triggers one optimizer
  cycle (`max_evaluator_cycles` default `1`); `safety-fail` is a hard stop. New stop reason
  `evaluator_gate_failed`. Wired into orchestrator Step 5.5.
- **`bin/eval-role.sh`** — runnable eval: deterministic frontmatter validation against the role
  schema (`--all` for a CI gate) + LLM-as-judge prompt assembly (emits the prompt; invokes `claude`
  only with `--judge`; never fabricates a score). `evals/` is no longer docs-only.

### Changed

**Subagent return budget is now enforced (step D).** Previously the condensed summary was an
*optional* ≤200-token convention; it is now a **hard contract**. `summary` in the role-output schema
gains `maxLength: 1200` (~200 tokens), so an over-budget summary fails handoff validation. The
`### Subagent return` contract in [references/subagent-dispatch.md](references/subagent-dispatch.md)
is rewritten: exactly three things cross back to the main thread — the structured handoff (capped
summary), artifact **paths** (never bodies), and nothing else. This stops deep-audit / research
roles (`security-reviewer`, `discovery-research`, `performance-reviewer`) from dumping large working
sets into the shared blackboard.

**Trace-replay as an enforced version gate (step E).** [references/versioning.md](references/versioning.md)
previously described regression evals aspirationally; they are now a concrete, runnable **version
gate** with two layers: Layer 1 (static) is `bin/eval-role.sh <role>` / `--all`, blocking on
frontmatter drift and runnable today; Layer 2 (behavioral) replays a role's baseline specs and
blocks the bump on any grader regression, verdict flip, new schema failure, or >25% unjustified
token regression. [references/trace-evals.md](references/trace-evals.md) is cross-linked as the
behavioral half. Agent configuration (instructions, tool defs, guardrails, model pin) is now treated
as code: a behavior change is reviewed like a code change. Documents the model-tier change (step B)
as a minor-class pending ratification. Fixed a stale `claude-opus-4-7` example in the versioning
docs.

## [1.6.0] - 2026-05-20

### Added

**Senior-grade skill integration across all 29 previously skill-less roles + 2026 best-practice rules.** Pre-v1.6, only 13 of 42 roles had skills integrated (the v1.2.1 audit-dd team, v1.3 design roles, v1.4 marketing roles, v1.5 post-release roles). v1.6 backfills the remaining 29 roles with senior-grade skill integration patterns.

**Roles updated to v1.1.0 with skill integration + senior-grade rules:**

*Implementation (3):*
- `backend-engineer` — TDD + source-driven + incremental + security-as-code patterns
- `frontend-engineer` — production UI + browser-testing + performance budget enforcement
- `devops-platform` — CI-as-code + deploy-checklist + security-hardening + observability-first

*Architecture (3):*
- `cto-architect` — ADR-grade decisions + stable interface contracts + convergent design
- `solution-architect` — interface boundaries + ADRs + integration-pattern decisions
- `cto-tech-lead` — multi-axis quality framework + adversarial verification + ADR-grade standards

*Strategic & Discovery (5):*
- `discovery-research` — cited research + competitive intelligence + AI-visibility baseline
- `product-manager` — convergent prioritization + ICP precision + AI-displacement awareness
- `product-ba` — spec-driven requirements + edge-case discipline + ADR records
- `business-analyst` — spec-grade requirements + research synthesis + NFRs first-class
- `delivery-manager` — task decomposition + incremental delivery + parallelism documented

*Review & Quality (8):*
- `test-designer` — TDD discipline + adversarial coverage + property-based tests
- `qa-test-engineer` — real-browser verification + root-cause debugging + multi-tenant isolation tests
- `accessibility-reviewer` — UI-engineering patterns + real-browser a11y tree + WCAG 2.2 awareness
- `performance-reviewer` — profile-first + CWV budget enforcement + LLM cost budgets
- `security-reviewer` — security-hardening + LLM-specific threats + multi-tenant as security boundary
- `data-schema-reviewer` — migration safety + multi-tenancy isolation + audit-log immutability
- `overengineering-reviewer` — simplification patterns + YAGNI + AI-aesthetic detection
- `code-reviewer` — multi-axis review + AI-generated code awareness + test correctness verification

*Release & Communication (4):*
- `release-manager` — shipping checklist + staged rollout + observability pre-verification
- `release-docs` — runbook discipline + ADR-grade configuration documentation
- `stakeholder-communicator` — humanized customer comms + outcome-led framing
- `documentation-agent` — ADR-grade docs + humanized end-user content

*Optional / Specialty (6):*
- `ux-researcher` — research synthesis + competitive UX + persona-grounded friction
- `whimsy-injector` — production UI + humanized whimsy copy + brand-consistent voice
- `ai-engineer` — context engineering + LLM TDD + AI-visibility measurement + multi-provider architecture
- `chaos-engineer` — experiment-as-code + ADR-grade hypothesis records + LLM failure modes
- `legal-compliance-checker` — cited 2026-current research + structured policy extraction + EU AI Act
- `incident-responder` — systematic root-cause + blameless postmortems + humanized status updates

### Skill mappings — all locally installed

All skills referenced by new role integrations are present in the canonical local installs (`~/.claude/skills/<name>/SKILL.md`). No new skills to install — v1.6 leverages the existing 47-skill local set fully.

**`skills-manifest.json` v1.4.0** — `full` pipeline section now declares **5 required + 12 recommended + 25 optional skills** with `used_by` lists covering all 42 roles. `bin/check-skills.sh full` resolves all 42 in reference setup.

**Highest-coverage skills** (used across many roles):
- `documentation-and-adrs` — **14 roles** (canonical documentation pattern)
- `competitor-analysis` — 9 roles
- `tavily-research` — 9 roles
- `copywriter` — 7 roles
- `idea-refine` — 8 roles
- `research-synthesis` — 6 roles
- `data-storyteller` — 5 roles
- `test-driven-development` — 5 roles
- `code-review-and-quality` — 5 roles
- `spec-driven-development` — 5 roles

### 2026 best-practice rules added to each role

Beyond skill integration, each role's `## Rules` section was extended with 2026-current best practices:

**Engineering roles:**
- TDD + doubt-driven verification before believing yourself
- Source-driven implementation (cite docs, never hallucinate APIs)
- Strict typing — no `any` in strict-mode codebases
- Multi-provider LLM architectures (foundation-model TOS changes quarterly)
- Performance budgets enforced in CI (CWV, p95 SLOs, LLM cost per request)
- Security shift-left (multi-tenant isolation as security boundary, not just architecture)
- Observability-first design (OpenTelemetry, structured logs from day one)

**Strategic roles:**
- ICP precision over breadth
- AI-displacement risk awareness (24-36 month horizon for any product decision)
- AEO/GEO posture in market-facing decisions
- Outcome-led, not feature-led
- Honest measurement (no vanity metrics, no rounding tricks)

**Review roles:**
- AI-generated code pattern awareness (flag generic over-abstraction)
- Multi-axis quality framework over subjective taste
- Performance + a11y budgets enforced, not optional
- WCAG 2.2 awareness (not just 2.1)

### Why senior-grade matters in 2026

The 2025-2026 shift from "AI agents can write code" to "AI agents can be senior engineers" requires explicit pattern documentation. Without skill-grounded rules:

1. **Engineering decisions default to AI-aesthetic** — over-abstracted factories, generic error messages, comment ceremony
2. **Architecture lacks decision provenance** — tribal knowledge evaporates with team changes
3. **Strategic roles produce wishlist scope** — no convergent narrowing, no ICP precision
4. **Reviews catch surface issues only** — multi-axis frameworks missing means missing systemic problems
5. **Communications read as AI-generated** — trust erodes with stakeholders, customers, partners, community

v1.6 closes these gaps by making senior-grade patterns explicit and skill-validated.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. All 29 role updates are version 1.0.0 → 1.1.0 (minor bump, additive). Existing pipelines continue to work; new skill invocations are recommended/optional unless explicitly listed as required (the 5 blocking skills from v1.5 remain the only blocking ones).

If `bin/check-skills.sh full` shows missing recommended/optional skills, the pipeline still runs via fallbacks. Quality drops proportionally to missing skills. Reference setup has all 42 skills installed locally.

### Total skill coverage in team-bootstrap v1.6.0

| Tier | Count | Notes |
|---|---:|---|
| Required (blocking) | 5 | humanize, humanize-ai-text, persona-customer-support, research-synthesis, idea-refine |
| Recommended | 12 | Used by 4+ roles each; core senior toolkit |
| Optional | 25 | Used by 1-3 roles each; specialized |
| **Total** | **42 skills** | **across 42 roles** |

Skills installed in reference setup: 47 (5 unused but available for future roles).

## [1.5.0] - 2026-05-20

### Added

Three post-release strategic roles closing the **customer + ecosystem + community** gap. Pipeline previously shipped products and translated launches into growth motion, but had no dedicated owner for retention motion, partner ecosystem, or community-led growth. v1.5 introduces all three with a parallel fan-out pattern (CSM + partnerships + community) feeding `growth-marketer` synthesis.

**New roles (all inline-only, opt-in for `full` + `single-thread`, all skill-blocking by design):**

- **`customer-success-manager` role** ([references/roles/customer-success-manager.md](references/roles/customer-success-manager.md)) — Canonical CSM function. Owns customer health framework (weighted dimensions + status definitions), voice-of-customer report, per-account QBR prep template (with industry + competitive context), onboarding playbook (0/7/30/60/90-day milestones + escalation triage), customer communication templates (onboarding / renewal / expansion / at-risk sequences), cohort retention dashboard. Position: after `release-manager`, parallel with partnerships-lead + community-manager. Pipeline-blocking on `persona-customer-support` + `research-synthesis` + `humanize-ai-text`.

- **`partnerships-lead` role** ([references/roles/partnerships-lead.md](references/roles/partnerships-lead.md)) — Ecosystem strategy + partner pipeline execution. Owns partner landscape map (with competitive overlap analysis), partnership thesis (top 3-5 with strategic rationale + expected lift), per-partner brief template, outreach + activation playbook (humanized for AI-detect avoidance), co-launch comms package (multi-platform), partnership performance dashboard. Conditional: technical integration vetting rubric (api-and-interface-design) + content / SEO partner scoring rubric (backlink-analyzer). Position: parallel with CSM + community-manager. Pipeline-blocking on `humanize` + `idea-refine`.

- **`community-manager` role** ([references/roles/community-manager.md](references/roles/community-manager.md)) — Community-led growth motion end-to-end. Owns channel strategy (tiered: Own / Native presence / Listen only), daily engagement engine (cross-platform with humanized copy), moderation playbook (5-tier escalation), voice-of-community report, 3-tier ambassador / advocacy program, community visual assets (badges + banners + reaction visuals), community health dashboard. Position: parallel with CSM + partnerships-lead. Pipeline-blocking on `humanize` + `humanize-ai-text`.

### Skill-blocking constraint (new in v1.5)

Unlike all prior roles where missing skills caused graceful degradation, v1.5 introduces **strictly required skills** that cause `status: blocked` if missing. The harness validates skill availability before role dispatch and refuses to run the role without them.

| Skill | Required by role(s) | Why blocking |
|---|---|---|
| `humanize` | partnerships-lead (outreach + co-launch), community-manager (every post + moderation) | AI-detected partner outreach has < 1% reply rate; communities reject AI-flagged posts |
| `humanize-ai-text` | CSM (renewal/expansion/at-risk sequences), community-manager (ambassador program) | AI-detected customer comms erode trust; ambassadors ghost transactional programs |
| `persona-customer-support` | CSM (health framework + onboarding escalation) | Manual customer-management framework fails QA on triage rigor |
| `research-synthesis` | CSM (VoC theme extraction) | Unstructured summary loses theme density + segment correlation |
| `idea-refine` | partnerships-lead (thesis convergence audit trail) | Unstructured prioritization fails QA on convergence rigor |

All 5 blocking skills present in canonical local installs at `~/.claude/skills/<name>/SKILL.md`. `bin/check-skills.sh full` now reports a `[required]` tier separate from `[recommended]` + `[optional]`.

### Deep skill integration in role workflows

All three v1.5 roles document **per-skill invocation point** within their Output Template — skills aren't listed as references, they're called out at the specific workflow step where they're invoked, producing named artifacts. This pattern is stronger than v1.3 / v1.4 (where skills were recommended without binding to specific output sections).

Example from `customer-success-manager.md`:
> **Invocation:** Used `Skill: persona-customer-support` to derive escalation triage patterns from existing support behavior + ticket categorization.
> **Invocation:** Used `Skill: data-storyteller` to design the health score visualization + cohort breakdown.

Each role's `checks:` section includes per-skill invocation verifications (`skill_X_invoked: passed`), making skill usage auditable in the handoff trace.

### Parallel fan-out pattern (post-release coordination)

When 2+ of {CSM, partnerships-lead, community-manager} run, they execute in **parallel** as separate subagent dispatches (if available) or sequentially. Each produces independent strategic artifacts that `growth-marketer` then **synthesizes** into the unified channel + content + AI search posture + growth loops strategy:

```
release-manager
       ↓
  ┌────┼────┐                ← v1.5 parallel fan-out
  ↓    ↓    ↓
 CSM  PL   CM
  └────┼────┘
       ↓
growth-marketer (synthesizes)
       ↓
stakeholder-communicator
```

This pattern is documented in `pipelines/full.md` ("Post-release stages — when to include").

### Supporting updates

- **`skills-manifest.json` v1.3.0** — `full` pipeline section now declares 5 required + 9 recommended + 18 optional skills. New `[required]` tier introduces blocking semantics.
- **`pipelines/full.md`** — rewritten with parallel fan-out diagram + new "Post-release stages — when to include" decision matrix (per-role triggers + skip conditions).
- **`subagent-mapping.md`** — new "Customer / Partnership / Community roles (v1.5)" section with primary + fallback subagent types; all three roles added to inline-only list with skill-blocking caveat documented.
- **`role-matrix.md`** — all three roles in Optional Roles table with triggers + skill-blocking flags + parallel-execution position; new selection-rule entries (with CSM / with partnerships / with community).
- **`role-output.schema.json`** — three roles added to root `oneOf`; per-role definitions with role-specific required fields (`retention_strategy_confidence`, `voc_themes_count`, `at_risk_arr_percent`, `partnership_priorities_count`, `expected_partner_channel_contribution`, `owned_channels_count`, `ambassador_program_tiers`, `expected_community_channel_contribution`).
- **`INSTALL.md`** — new "Required: Full pipeline — install skills for v1.5 post-release roles" section. Per-skill table + install priority by product context (SaaS-with-retention / developer-tools / ecosystem-first / consumer / internal-tool / patch).

### Total role count

team-bootstrap v1.5.0 now ships **41 roles** total (up from 38 in v1.4): 14 implementation + 8 review + 6 audit-DD + 4 strategic (discovery / product-manager / product-ba / business-analyst) + 2 design + 2 marketing-strategy + **3 customer/partnership/community (NEW)** + 2 release + others.

### Why dedicated post-release strategic roles

Pre-v1.5, the pipeline assumed `release-manager` → `stakeholder-communicator` → `documentation-agent` was sufficient post-release. This worked for shipping, but failed for:

1. **Retention** — without CSM, NRR / GRR / logo retention strategy was implicit. Subscription businesses live or die on retention math.
2. **Ecosystem** — without partnerships-lead, partner pipeline was opportunistic. Products with distribution ceilings on direct channels can't scale without ecosystem motion.
3. **Community** — without community-manager, community-led growth defaulted to "we'll figure it out post-launch." For developer tools / prosumer SaaS / AI products, community signal is the primary buyer evaluation channel.

These three roles aren't optional luxuries — they're **deal-defining for products in their respective contexts** (subscription / ecosystem / community). v1.5 closes the gap by making them first-class pipeline citizens with skill-validated execution.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when v1.5 roles are not opted in.

Opt into v1.5 roles by inserting them in the pipeline per `pipelines/full.md` "Post-release stages — when to include" decision matrix. If any v1.5 role is invoked but its required skills are missing, the role returns `status: blocked` immediately (no work attempted) — install required skills via the paths in `INSTALL.md` and retry.

## [1.4.0] - 2026-05-20

### Added

Dedicated GTM + ongoing growth stages for the `full` and `single-thread` pipelines. Closes a gap from v1.0–v1.3 where the pipeline shipped products but had no role responsible for positioning, ICP selection, pricing strategy, launch sequencing, channel strategy, content engine, or AI search posture. Existing `stakeholder-communicator` produced release notes one-shot; nothing built the ongoing growth motion.

- **`product-marketer` role** ([references/roles/product-marketer.md](references/roles/product-marketer.md)) — Canonical Product Marketing Manager (PMM) function. Owns ICP definition, positioning statement, category framing, messaging hierarchy, pricing strategy, launch sequencing (alpha/beta/GA), sales enablement (discovery questions + objection handling + ROI calculator inputs), competitive battle cards. Position: after `product-manager`, before `business-analyst` — positioning shapes downstream requirements rather than arriving post-release. Inline-only by default.

- **`growth-marketer` role** ([references/roles/growth-marketer.md](references/roles/growth-marketer.md)) — Strategic growth function (CMO-equivalent, named for work not title). Owns channel strategy (mix + CAC + ramp + kill criteria), content engine (cadence + topic clusters + SEO/AEO posture), brand-as-moat (category-defining terminology, recognized-metric play, community positioning), growth loops (with k-factor / payback), attribution model, AI search posture per platform (ChatGPT / Perplexity / Claude / Gemini / Google AI Overview), growth experiments backlog (ICE-ranked), 30/60/90 day plan. Position: after `release-manager`, before `stakeholder-communicator` — translates ship event into compounding growth motion. Inline-only by default.

- **Skill ecosystem integration for both roles** — `Skill` in `tool_surface.allow`; `## Recommended skills` section per role; all referenced skills present in canonical local installs (`~/.claude/skills/<name>/SKILL.md`):
  - `product-marketer` core: `competitor-analysis` (non-negotiable for positioning), `copywriter`, `brief`, `tavily-research`, `idea-refine`, `persona-customer-support`
  - `growth-marketer` core: `30x-seo-ai-visibility` (highest leverage in 2026), `ai-seo`, `seo-aeo-best-practices`, `seo-audit`, `seo-geo`, `find-keywords`, `programmatic-seo`, `backlink-analyzer`, `competitor-analysis`, `tavily-research`, `social-media-posts`, `copywriter`, `brief`, `data-storyteller`, `idea-refine`

- **`skills-manifest.json`** v1.2.0 — extends `full` pipeline section with 14 additional marketing-specific optional skills. Total `full` pipeline now: 4 recommended + 18 optional skills. `bin/check-skills.sh full` resolves all 22 against local installs.

- **`pipelines/full.md`** updated — `product-marketer` inserted after `product-manager` (before `business-analyst`); `growth-marketer` inserted after `release-manager` (before `stakeholder-communicator`); updated role flow diagram + new "Marketing stages — when to include" decision matrix (greenfield launch / pricing change / repositioning / growth plateau / AEO shift / internal tool / patch).

- **`subagent-mapping.md`** updated — new "Marketing roles (v1.4)" section with primary + fallback subagent types; both roles added to inline-only list.

- **`role-matrix.md`** updated — both roles in Optional Roles table with triggers + "Inserts after" position; new selection-rule entries (with product-marketer / with growth-marketer).

- **`role-output.schema.json`** updated — `product-marketer` + `growth-marketer` added to root `oneOf`; new per-role definitions with role-specific required fields (`positioning_confidence`, `pricing_confidence`, `primary_channel_thesis`, `ai_search_priority`).

- **`INSTALL.md`** updated with new "Full pipeline — install referenced skills for marketing roles" section. Per-skill table + install priority by product type (greenfield launch / pricing change / growth plateau / content scaling / internal tool / patch).

### Why dedicated marketing stages

The pipeline previously assumed products would just "ship" — `release-manager` made go/no-go, `stakeholder-communicator` wrote business-language release notes, done. But the gap between "shipping" and "growing" is where most products die — `product-marketer` answers "who buys this and what do we say" before development, and `growth-marketer` answers "how does this compound week-over-week" after launch. Without these roles, GTM decisions are made by founders at runtime under pressure, which is the wrong cognitive context (focus on shipping, not market motion).

For products entering markets where AI search visibility (AEO / GEO) is now the primary growth surface — every consumer / prosumer / B2B product launching in 2026 — `growth-marketer` is the role that owns the AI search posture explicitly. Without it, AEO/GEO defaults to "we'll figure it out post-launch," which is too late.

### Total role count

team-bootstrap v1.4.0 now ships **38 roles** total (up from 36 in v1.3): 14 implementation roles + 8 review roles + 6 audit-DD roles + 4 strategic roles (discovery / product-manager / product-ba / business-analyst) + 2 design roles + 2 marketing roles + 2 release roles + others.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when marketing roles are not opted in. Opt into marketing stages by inserting `product-marketer` and/or `growth-marketer` in the pipeline per the [pipelines/full.md](references/pipelines/full.md) "Marketing stages — when to include" decision matrix.

### Inline-only rationale

Both `product-marketer` and `growth-marketer` run inline by default — their strategic artifacts (positioning / pricing / channel mix / content cadence / launch sequencing) are inherited by downstream release + communication roles. Fragmenting them across subagent contexts risks `release-manager` missing the launch sequencing or `stakeholder-communicator` missing the brand narrative. Dispatch only with explicit `--isolate` when running a marketing-only audit with no release decision downstream.

## [1.3.0] - 2026-05-20

### Added

Dedicated UX/UI design stages for the `full` and `single-thread` pipelines. Closes a gap from v1.0–v1.2 where `frontend-engineer` was expected to consume "UI specs" that no upstream role produced — design decisions defaulted to runtime intuition, which is the root cause of generic AI-aesthetic output across the pipeline.

- **`ux-designer` role** ([references/roles/ux-designer.md](references/roles/ux-designer.md)) — Translates research into interaction architecture: information architecture, user flows, screen-by-screen wireframes (structural only, no visual styling), interaction patterns, mental-model mapping, UX writing guidelines. Position: after `ux-researcher` (or `product-manager` if research skipped), before `ui-designer`. Inline-only by default (downstream roles inherit component inventory + mental model).

- **`ui-designer` role** ([references/roles/ui-designer.md](references/roles/ui-designer.md)) — Translates UX architecture into visual design: design tokens (color/type/spacing/motion/radii), component library spec (variants/states/a11y contract), screen-by-screen reference prototype in HTML + Tailwind, implementation mapping (component → primitive → token usage). Position: after `ux-designer`, before `frontend-engineer`. Inline-only by default.

- **Skill ecosystem integration for both roles** — `Skill` in `tool_surface.allow`; `## Recommended skills` section per role with skill-name → when-to-invoke → what-it-gives mapping:
  - `ux-designer`: `research-synthesis`, `idea-refine`, `competitor-analysis`, `tavily-research`, `persona-customer-support`
  - `ui-designer`: `frontend-ui-engineering` (highest-leverage), `api-and-interface-design`, `image-generation`, `competitor-analysis`, `documentation-and-adrs`, `idea-refine`
  - All recommended skills present in canonical local skill installs (`~/.claude/skills/<name>/SKILL.md`)

- **`skills-manifest.json`** v1.1.0 — added `full` pipeline section with 4 recommended + 5 optional skills per design role. `bin/check-skills.sh full` now verifies install state for design stages.

- **`pipelines/full.md`** updated — new "Optional Roles" section explicitly lists `ux-designer` + `ui-designer` insertion points; new "Design stages — when to include" decision matrix; updated role flow diagram with optional design stage branches.

- **`subagent-mapping.md`** updated — new "Design roles (v1.3 — dedicated UX + UI design stages)" section with primary + fallback subagent types; both roles added to inline-only list.

- **`role-matrix.md`** updated — both roles in Optional Roles table with triggers + "Inserts after" position; new selection-rule entries.

- **`role-output.schema.json`** updated — `ux-designer` + `ui-designer` added to root `oneOf`; new per-role definitions extending `base`.

- **`INSTALL.md`** updated with new "Full pipeline — install referenced skills for design roles" section. Includes per-skill table + "When to actually install these" decision matrix (greenfield consumer / B2B / internal tool / iteration).

### Why dedicated design stages

The pipeline previously assumed UI specs would arrive from somewhere — `product-manager` produces requirements (the *what*), but neither requirements nor research produce IA/flows/wireframes/tokens (the *how*). Without dedicated design roles, `frontend-engineer` makes visual decisions at implementation time, which is the wrong cognitive context (focus on code correctness, not design coherence). Result: generic AI-aesthetic interfaces that look obviously LLM-generated.

For products where UX = differentiation moat (operator-first tools, prosumer apps, AI-native workflows, anything consumer-facing), this is the difference between shippable and shippable-by-a-top-company.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when design roles are not opted in. Opt into design stages by inserting `ux-designer` and/or `ui-designer` in the pipeline per the [pipelines/full.md](references/pipelines/full.md) "Design stages — when to include" decision matrix.

### Inline-only rationale

Both `ux-designer` and `ui-designer` run inline by default — their artifacts (IA / wireframes / tokens / reference prototype) are inherited by `frontend-engineer` as the foundation for implementation. Fragmenting them across subagent contexts risks design-token-to-implementation mismatches that produce visual inconsistency in the shipped UI. Dispatch only with explicit `--isolate` when running an audit-only design review with no implementation downstream.

## [1.2.1] - 2026-05-20

### Added

Skill ecosystem integration for `audit-dd` pipeline (gap closed from v1.2.0 — roles referenced skills in prose but `tool_surface` didn't permit the `Skill` tool, and there was no install verification).

- **`Skill` tool** added to all 6 audit-dd role `tool_surface.allow` lists (financial-analyst, market-analyst, customer-health-analyst, ip-contracts-reviewer, culture-team-dd, investment-thesis-author). Roles can now invoke skills at runtime.
- **`## Recommended skills` section** in each of the 6 role playbooks — explicit skill-name → when-to-invoke → what-it-gives mapping per role. Highest-leverage skills called out (e.g. `30x-seo-ai-visibility` for market-analyst's AI-displacement assessment; `data-storyteller` for investment-thesis-author's memo synthesis).
- **`skills-manifest.json`** at repo root — declarative list of required / recommended / optional skills per pipeline. Includes per-skill `purpose` + `fallback` so users know what's lost if a skill is missing.
- **`bin/check-skills.sh`** — verification script. Reads manifest, checks `~/.claude/skills/<name>/SKILL.md` for each, reports installed / missing. JSON output (`--json`) for CI gating. Exit codes: 0 = all recommended present, 1 = required missing, 2 = recommended missing (pipeline runs with fallbacks).
- **INSTALL.md** updated with new "Audit-DD pipeline — install referenced skills" section. Documents that team-bootstrap does NOT auto-fetch skills (no canonical marketplace registry across users); provides install paths via `/plugin install`, manual git clone, or scp from another machine. Includes per-skill table with fallback behavior.

### Why no auto-fetch

Skills live in disparate sources: some come from `addyosmani/agent-skills`, some from 30x.dev / Anthropic bundles, some are personal / community packs. License terms vary; canonical URLs aren't tracked across installs. Auto-fetching would either pin upstream sources (fragile when they move) or vendor copies in this repo (license risk). Manifest + verification is the safer default; users opt-in to fetching.

### Migration

All 6 audit-dd roles bump to `version: 1.1.0`. Backwards compatible — fallback paths preserve the v1.0.0 behavior (WebSearch/WebFetch only) when skills aren't installed.

## [1.2.0] - 2026-05-20

### Added

Commercial / financial due-diligence support. Six new roles + one new pipeline targeting the **`audit-dd`** use case (pre-fundraise / M&A / board prep), distinct from the existing technical `audit` pipeline.

- **`audit-dd` pipeline** ([references/pipelines/audit-dd.md](references/pipelines/audit-dd.md)) — six-role read-only DD run; output is an investor-grade memo (1-pager + 10-page deep dive), not a backlog. Composes with `audit` (run technical audit first, then DD on top).
- **`financial-analyst` role** — ARR build with cohort retention, unit economics (LTV/CAC, CAC payback, Burn Multiple, Magic Number, Rule of 40, NRR), valuation triangulation against 2026 SaaS / AI comps (Bull/Base/Bear).
- **`market-analyst` role** — TAM/SAM/SOM triangulated top-down × bottoms-up, 5-vector moat scoring, **AI-search displacement risk** assessment (can ChatGPT/Perplexity/Claude/Gemini answer the JTBD directly?).
- **`customer-health-analyst` role** — cohort retention curves (logo + GRR + NRR all separate, never aggregated), concentration table (top-customer > 20% = red flag), AI-product-specific signals (API usage retention, model-call cohort behavior, prompt-engineering education curve).
- **`ip-contracts-reviewer` role** — OSS license audit (AGPL / SSPL / Elastic-2.0 contamination detection), **foundation-model TOS** verification (OpenAI / Anthropic / Google — terms change quarterly), customer-contract red flags (AI accuracy warranties, training-data rights, uncapped indemnities), data residency (GDPR + Schrems II SCC, CCPA / CPRA, India DPDPA, China PIPL).
- **`culture-team-dd` role** — org depth + bus factor, retention signals, compensation posture (Levels.fyi / Pave / Carta benchmarks), public sentiment (Glassdoor / LinkedIn / Blind — ethically gathered), founder dynamics.
- **`investment-thesis-author` role** — terminal synthesizer; produces 1-page memo + 10-page deep dive + invest/pass/conditional verdict with probability-weighted MOIC and explicit Bull/Base/Bear scenario weights.
- Schema updates: `audit-dd` added to `compatible_pipelines` enum; six new role consts in `role-output.schema.json` `oneOf` with role-specific required fields (e.g. `investment_recommendation`, `probability_weighted_moic`).
- `role-matrix.md` + `subagent-mapping.md` updated to surface the new DD team and inline-only constraints.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing audit / mvp / full / single-thread runs continue unchanged. Opt into the new commercial DD by invoking `/team-bootstrap audit-dd <spec>`.

## [1.0.0] - 2026-05-10

Initial productized release. Distribution structure, full P0 + P1 implementation, top-level docs.

### Added

- **Subagent dispatch model** ([references/subagent-dispatch.md](references/subagent-dispatch.md)) — when roles run inline vs. as Task-tool subagents.
- **Shared blackboard** ([references/shared-blackboard.md](references/shared-blackboard.md)) — full run document available to every role.
- **Irreversibility taxonomy** ([references/irreversibility.md](references/irreversibility.md)) — four-class action gating replaces role-level approval booleans.
- **Tracing spec** ([references/tracing.md](references/tracing.md)) — OpenTelemetry GenAI semantic conventions, run/role/tool span hierarchy, replay format.
- **Role versioning** ([references/versioning.md](references/versioning.md)) — semver per role, eval-gate convention.
- **Memory model** ([references/memory.md](references/memory.md)) — three-tier (persistent / per-run / per-role), checkpoint and resume.
- **AGENTS.md contract** ([references/agents-md-contract.md](references/agents-md-contract.md)) — required fields, per-role consumption.
- **MCP integration** ([references/mcp-integration.md](references/mcp-integration.md)) — tool-surface mapping to MCP servers.
- **Tool surface** in every role frontmatter — allow/deny lists, MCP servers, permission mode.
- **Verification loops** in `backend-engineer` and `frontend-engineer` — explicit edit→verify→repair with bounded attempts.
- **Single-thread pipeline** ([references/pipelines/single-thread.md](references/pipelines/single-thread.md)) — recommended default.
- **Role frontmatter schema** ([references/schemas/role-frontmatter.schema.json](references/schemas/role-frontmatter.schema.json)).
- Top-level docs: [README.md](README.md), [INSTALL.md](INSTALL.md), [USAGE.md](USAGE.md), [ARCHITECTURE.md](ARCHITECTURE.md).
- Plugin manifest at [.claude-plugin/plugin.json](.claude-plugin/plugin.json).
- Examples: [examples/AGENTS.md.template](examples/AGENTS.md.template), [examples/quickstart-spec.md](examples/quickstart-spec.md).
- Eval suite skeleton at [evals/](evals/).

### Changed

- `next_role` in role templates uses `<determined-by-pipeline>` placeholder; orchestrator resolves from active pipeline.
- `role-output.schema.json` — root `oneOf` discriminator on `role`; `unevaluatedProperties: false` per role; per-role required fields for 12 roles (release_decision, severity_counts, verdict, ci_status, etc.).
- [failure-policy.md](references/failure-policy.md) — irreversibility classes drive approval gates instead of role-level booleans.
- [orchestrator.md](references/orchestrator.md) — incorporates shared-blackboard load step and subagent-dispatch decision point.
- [trace-evals.md](references/trace-evals.md) — cross-links to tracing.md (capture) and versioning.md (regression gate).
- [SKILL.md](SKILL.md) — points to README/USAGE/ARCHITECTURE as primary entry; retains handoff contract reference.

### Migration from pre-1.0

- Hardcoded `next_role` values were replaced with placeholders. No action needed if you used the bundled orchestrator.
- Role files now require frontmatter (`version`, `tool_surface`, `permission_mode`). Custom roles must be updated.
- Per-role required handoff fields are enforced. Custom handoffs that omit them will fail validation.
- `manual_approval_requested` at role level still works but is deprecated. Use `irreversibility_class` per action ([references/irreversibility.md](references/irreversibility.md)).

## Pre-1.0

Earlier versions used hardcoded `next_role` per role and a JSON Schema with `$defs` only (no root discriminator). See git history for details.
