# Ground claims in the mechanism, not the name

The dominant, *avoidable* failure when agents work in a mature codebase: **inferring a capability
from a name that sounds right, and stopping at the first hop.** Retrospective on real `/deliver`
output — every example is the same shape:

- `enumerate_active_engagement_ids` → "active? sounds right, taken." The meaning of *active* actually
  lives four hops away — `workflow → activity → SECDEF function → SQL predicate` — in the terminal
  SQL, not the function name. The agent read the first hop.
- `PublicSessionReason.schedule_fanout_enumerate` → "an existing leg reads cross-tenant *via* this
  reason, so the reason grants access." It doesn't: the **SECDEF function** grants access; the reason
  is an audit label. Capability inferred from a matching token, not from the mechanism.
- `FirstHandInputWire` = "mirror of FirstHandInput" → assumed the mirror includes the provenance
  validator. It didn't. The soft model was taken minutes after writing a docstring saying the gate
  must not be duplicated.

The worst part: the same mistake was made **twice**, the second time *inside the fix for the first*,
while the repo warned in plain text — a docstring saying "non-owner reads zero rows" and `AGENTS.md >
## Known Hazards` saying "workers that forget to set it will read zero rows, not all rows — that's
intentional." **The information was there; it wasn't opened.**

## The rule

> **For any claim of the form "X already handles this" / "X provides this" / "this mirrors Y" / "this
> reason grants access" — open X and follow the references to the TERMINAL definition (the SQL
> predicate, the validator, the CHECK constraint, the actual enforcement), and cite it `file:line`.
> Never infer a capability from a matching name or token.**

The reviewer who found more didn't do it by being smarter — they read **three hops deeper**. This is
[source-driven-development](../references/best-practices-research.md) turned inward: ground on the
*codebase's own* mechanism the way you ground on an external library's docs; judge by ground truth
from the environment, not by a name ([Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).

## What it demands, concretely

1. **Trace to the terminal definition.** A "handled-by-X" assertion carries the `file:line` of the
   enforcing mechanism (SQL/validator/CHECK/guard), not the name of a wrapper. Stop only at the leaf.
2. **Read the hazards for the surface you touch.** Before implementing, open `AGENTS.md > ## Known
   Hazards` / `## Architecture` / `## Invariants` for the touched surface. Half of the blast radius
   of a change in a mature codebase (RLS, SECDEF perimeters, head-pins, CHECK enums, contract/
   determinism gates) is invisible in the diff and only surfaces at runtime — **planning by reading
   the edited file alone is insufficient; run the gates** ([enforcement.md](enforcement.md)).
3. **A mitigation is verified by exercising it, not by prose.** "A separate activity gives isolation"
   (it didn't exist), "the index supports the predicate" (existence was checked, not *usage*), "no new
   SECDEF" (that was exactly what broke the query) — each is a *claimed property no one exercised*.
   A mitigation claim must carry a test/probe that exercises the actual behavior, or it is a finding.
4. **One source of truth across artifacts.** `plan.md` is authoritative; `tasks.md` derives. Re-run
   `speckit-analyze` after **every** plan revision — divergence across revisions (write-intent in the
   plan vs save-id-after-start in tasks; `FAIL` vs `USE_EXISTING` in two files) is a contradiction, not
   a nuance.

## Who owns it

- **Architects** (`cto-architect`, `solution-architect`): every "the platform already does X" in the
  design traces to the mechanism before it's ratified.
- **Engineers** (`backend-engineer`, `frontend-engineer`): before reusing/extending existing behavior,
  open it to the leaf; read the surface's Known Hazards.
- **Reviewers** (`code-reviewer`, `architecture-reviewer`, `integration-verifier`): the reviewer's job
  is to **read three hops deeper** — verify each "X handles this" claim against the terminal mechanism
  and each mitigation against an exercising test. This is where the missed hops get caught.

Constitution: this is **P11** — ground claims in the mechanism, not the name.
