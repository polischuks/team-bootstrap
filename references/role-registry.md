# Role registry — which of the 51 roles is alive, and why the rest are not

> Generated against the tree and maintained by hand. `bin/check-role-triples.sh` reads the
> **Live** table below: an `agents/*.md` this file does not sanction fails the gate (AC-12).

**Liveness is P12's definition, not a file count.** A role is alive iff removing it from the active
profile turns something red — `bin/eval-role.sh --liveness` is the measurement, and the number below
is whatever that command last reported, never the number of playbooks in `references/roles/`.

Four conditions must hold together for a role to be assignable, and each has its own failure mode:

| Condition | Mechanism | Failing it means |
|---|---|---|
| Dispatchable | `agents/<slug>.md` | the role cannot carry a `subagent_type` at all |
| Attributable | a row in `references/review-types.txt` with a role column | the dispatch happened and the harness did not see it |
| Typed | a **required** field in `references/schemas/role-output.schema.json` | the dispatch can be counted, never confirmed |
| Routed | a category in `profiles/default.map` the classifier actually emits | the harness can never assign it on its own |

## Live — routed by the harness from a risk category

| Role | Category | Required verdict field | Agent | Attributable |
|---|---|---|---|---|
| `accessibility-reviewer` | `ui` | `severity_counts, wcag_aa_compliant` | yes | yes |
| `chaos-engineer` | `infra/deploy` | `resilience_verdict` | yes | yes |
| `data-schema-reviewer` | `data/schema` | `severity_counts, migration_safe` | yes | yes |
| `devops-platform` | `infra/deploy` | `ci_status` | yes | yes |
| `ip-contracts-reviewer` | `deps` | `ip_verdict` | yes | yes |
| `legal-compliance-checker` | `licence` | `release_recommendation` | yes | yes |
| `overengineering-reviewer` | `deps` | `verdict` | yes | yes |
| `performance-reviewer` | `perf` | `severity_counts` | yes | yes |
| `security-reviewer` | `security/auth, deps` | `severity_counts, secrets_audit_passed` | yes | yes |
| `test-designer` | `no-tests` | `test_design_verdict` | yes | yes |

## Dispatchable from the tier base set, not profile-routed

The four MANDATORY review roles are carried by `tier_base_roles` (`bin/delivery-lib.sh`), not by a
profile category. Mapping them would be a no-op: the category that would route them forces a tier
whose base set already contains them, and `--liveness` correctly calls such a binding **dead**.

| Role | Dispatch slug | Required verdict field |
|---|---|---|
| `integration-verifier` | `integration-verifier` | `integration_verified, orphans_found` |
| `architecture-reviewer` | `architecture-reviewer` | `architecture_verdict, review_mode` |
| `regression-guardian` | `regression-guardian` | `regressions_found` |
| `code-reviewer` | `tb-code-reviewer` | `approval_status` |

## Dispatchable slugs — the table `bin/check-role-triples.sh` reads

One row per `agents/*.md`. An agent file with no row here fails the gate: a dispatchable role nobody
can point at a reason for is how the set grows without anyone deciding it should (AC-12).

`generic` in the Role column is a deliberate, narrow exemption. A generic satisfies the ≥1
anti-collapse floor **without attributing** to any role, so by construction it carries no role column
in `review-types.txt` and has no playbook of its own. Marking it here is what keeps that from being
indistinguishable from an oversight.

| Slug | Role | Playbook | Why it exists |
|---|---|---|---|
| `accessibility-reviewer` | accessibility-reviewer | `references/roles/accessibility-reviewer.md` | routed from `ui` |
| `architecture-reviewer` | architecture-reviewer | `references/roles/architecture-reviewer.md` | mandatory review role, tier base set |
| `chaos-engineer` | chaos-engineer | `references/roles/chaos-engineer.md` | routed from `infra/deploy` |
| `data-schema-reviewer` | data-schema-reviewer | `references/roles/data-schema-reviewer.md` | routed from `data/schema` |
| `devops-platform` | devops-platform | `references/roles/devops-platform.md` | routed from `infra/deploy` |
| `independent-reviewer` | generic | — | satisfies the ≥1 floor without attributing; kept for host compatibility (OQ-6) |
| `integration-verifier` | integration-verifier | `references/roles/integration-verifier.md` | mandatory review role, tier base set |
| `ip-contracts-reviewer` | ip-contracts-reviewer | `references/roles/ip-contracts-reviewer.md` | routed from `deps` |
| `legal-compliance-checker` | legal-compliance-checker | `references/roles/legal-compliance-checker.md` | routed from `licence` |
| `overengineering-reviewer` | overengineering-reviewer | `references/roles/overengineering-reviewer.md` | routed from `deps` |
| `performance-reviewer` | performance-reviewer | `references/roles/performance-reviewer.md` | routed from `perf` |
| `regression-guardian` | regression-guardian | `references/roles/regression-guardian.md` | mandatory review role, tier base set |
| `security-reviewer` | security-reviewer | `references/roles/security-reviewer.md` | routed from `security/auth`, `deps` |
| `tb-code-reviewer` | code-reviewer | `references/roles/code-reviewer.md` | mandatory review role; the slug is `tb-` prefixed so it stays attributable even when the `team-bootstrap:` prefix is stripped |
| `test-designer` | test-designer | `references/roles/test-designer.md` | routed from `no-tests` |

`independent-reviewer` is kept deliberately (OQ-6): removing it breaks compatibility with external hosts
whose own review slugs resolve through it.

## Not revived — and the reason, per role

| Role | Typed? | Reason |
|---|---|---|
| `ai-engineer` | no | builder — its work is done better by `/build`, `/test` and skills than by a playbook (Д2 §1.2). A builder must never map to a review slug: that is the load-bearing anti-builder guarantee of review-types.txt. |
| `backend-engineer` | no | builder — its work is done better by `/build`, `/test` and skills than by a playbook (Д2 §1.2). A builder must never map to a review slug: that is the load-bearing anti-builder guarantee of review-types.txt. |
| `business-analyst` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `cartographer` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `community-manager` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `cto-architect` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `cto-tech-lead` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `culture-team-dd` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `customer-health-analyst` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `customer-success-manager` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `delivery-manager` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `discovery-research` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `documentation-agent` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `financial-analyst` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `frontend-engineer` | yes | builder — its work is done better by `/build`, `/test` and skills than by a playbook (Д2 §1.2). A builder must never map to a review slug: that is the load-bearing anti-builder guarantee of review-types.txt. |
| `funnel-auditor` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `gap-backlog-author` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `gatekeeper` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `growth-marketer` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `incident-responder` | yes | belongs to the `incident` pipeline, not to a code batch. |
| `investment-thesis-author` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `market-analyst` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `partnerships-lead` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `product-ba` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `product-manager` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `product-marketer` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `qa-test-engineer` | yes | pipeline role; the review-side question it would ask is `test-designer`'s. |
| `recon` | yes | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `release-docs` | yes | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `release-manager` | yes | closure role, dispatched by the pipeline rather than by a risk category. |
| `solution-architect` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `stakeholder-communicator` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `ui-designer` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `usecase-miner` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `ux-designer` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |
| `ux-researcher` | no | orchestration/authoring role, not a reviewer — it produces the artefacts a batch is built from. |
| `whimsy-injector` | no | business tail — belongs to the `audit-dd` / `l2p` pipelines, a separate product track (Д2 §1.2). Not a code-batch review role. |

## Deliberately unmapped categories

- **`api/contract`** — its natural owner is `integration-verifier`, but the category forces the
  `full` tier, whose base set already contains that role. Already in the tier base set for the tier its category forces, so a profile entry could never change an outcome — `--liveness` reports such a binding dead.

## Cost

Fan-out is bounded by what the diff trips, not by the size of this table: a batch earns the tier base
set plus the roles its own categories add. The widest realistic code batch today (a dependency bump
that also touches infra) reaches eight roles. `bin/delivery-metrics.sh` publishes the share of batches
whose assigned set differs from the tier default — a value near zero means the selector does not
discriminate and this table is decoration (ADR-0016, OQ-3).
