# ADR-0024 — Roles are first-class in-repo agents (agent-is-source)

- **Status:** Accepted
- **Date:** 2026-09-13
- **Milestone:** `specs/148-roles-as-first-class-agents` (US1–US5, AC-1..AC-9, AC-12)

## Context

A `/deliver` run promises a specified cast of roles — CTO → QA → GTM — each working to current best
practice. But only **15 of 51** roles shipped as real, dispatchable agents (`agents/*.md`, all
reviewers). The other 36 were `references/roles/<role>.md` **playbooks** that pointed *outward* via
`preferred_subagent_types` to a host/external catalog the plugin does not ship (`backend-developer`,
`sprint-prioritizer`, …; worst case `→ general-purpose`, a generic model reading an injected text file).
That is non-portable (a fresh install with no host catalog loses the cast), not harness-attributable
(the dispatch resolves to a foreign type), and the "role" was a document, not an agent.

The governance core actively enforced the INVERSE of what we wanted: `check-role-triples.sh` required
the playbook to be the source and the agent to be a ≤40-line shell that *must reference* its playbook.

## Decision

**The agent is the source of truth.** Every dispatchable role ships as a self-contained
`agents/<role>.md` — system prompt = mission + folded criteria + current-best-practice + a typed
numeric acceptance contract (`role-output.schema.json` `$def`, #147) + a read-map (#146) + a `version`
and freshness sourcing (AC-6). Its playbook `references/roles/<role>.md` is folded in and **deleted**
(single-source, AC-2). Dispatch targets the in-repo `team-bootstrap:<role>` type; the external
`preferred_subagent_types` is removed (AC-3). A fresh install with no host catalog yields the full cast
(AC-4).

**Definition ≠ dispatch (F2/AC-5).** A role being a dedicated agent does NOT mean it is always a
separate subagent spawn. The default remains inline single-thread build (#144, constitution P1);
dispatch is for independence/attribution/parallelism. Measured on this milestone (AC-8, see
[cost-measure-148.md](../cost-measure-148.md)): making all 36 roles first-class agents added **zero**
per-role build dispatches — every recorded dispatch was a review role.

**Review-agent vs delivery-agent (AC-9b).** Reviewers are sanctioned in `references/review-types.txt`;
delivery/builder agents in a SEPARATE `references/delivery-types.txt`. The review machinery reads ONLY
review-types.txt, so a builder can never be miscounted toward the independent-review floor — the
anti-builder guarantee, held by file separation, tested in
[anti-builder-file-separation.test.sh](../../tests/anti-builder-file-separation.test.sh).

**Governance flipped first, fail-closed (AC-9, Phase 0).** Before any migration, `check-role-triples.sh`
was flipped to accept agent-is-source (transition-aware: a not-yet-migrated legacy playbook still
passes), and the loader (`subagent-dispatch.md`, `orchestrator.md`) rewired to resolve AGENT-FIRST.

## Consequences

- **37 first-class agents** now exist (15 reviewers + 6 engineering + 6 product/delivery + 10 GTM/UX +
  the generic `independent-reviewer`); `references/roles/` holds only the **15 non-dispatchable pipeline
  personas** (analysis/recon roles outside the dispatchable cast), which the single-source lint does not
  flag.
- **Standing machine enforcement:** `check-roles-are-agents.sh` (AC-1/AC-2/AC-3/AC-6/AC-7) and
  `check-roles-portable.sh` (AC-4) are wired into `verify-batch.sh`, so a future agent that drops its
  version, read-map, typed contract, or self-containment — or a cast role that reaches for an external
  type — fails the batch.
- **Delivery-machinery correction:** `agents/*.md` are classified as IMPL (not doc) by
  `delivery-lib.sh _is_doc_path`, so a role migration earns delivery credit and advances the batch window.
- **Freshness is a process, not a snapshot** (AC-6): each agent carries durable principles + a `version`
  + an instruction to consult current sources (skills/WebSearch) + a maintained `references/` read-map;
  the static prompt is refreshed rather than trusted to stay current.

## Alternatives considered

- **In-repo agent + external fallback.** Rejected: a fallback to a host catalog reintroduces the
  non-portability and non-attributability this milestone exists to remove (AC-4 would not hold).
- **Leave the 15 pipeline personas as playbooks.** Accepted as-is: they are not dispatchable (absent
  from both manifests), so they are outside the cast; migrating them is out of scope, not drift.
