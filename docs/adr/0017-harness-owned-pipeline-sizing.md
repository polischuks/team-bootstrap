# ADR-0017 — The harness sizes each batch; the asymmetry is permanent

- Status: accepted
- Date: 2026-08-21
- Milestone: v2.31.0 (issue #27)
- Relates: ADR-0015 (no gate blocks on its own fragility) · ADR-0016 (no gate re-runs identical work)

## Context

The largest cost lever in the pipeline — how many independent reviewer subagents run — was set **once,
by hand, before any batch existed**, and nothing re-decided it per batch. `select-pipeline.sh` could
size a change but was wired to nothing, reported only *under*-provisioning (`chosen >= recommended`
printed "right-sized", so `full` on a one-file change was silent), and sized per RUN while cost accrues
per BATCH. Anthropic measures multi-agent at ~15× the tokens of a chat and states the effort-scaling
rule explicitly; the four review roles all read the **same** closed diff, which is the shared-context
case their guidance names as a poor fit for fan-out.

## Decision

`full` no longer means "four roles on every batch". It means **the harness sizes each batch**: the role
set is computed from that batch's own diff window and declared `risk_rank`, taking the tier from
`select-pipeline --batch` so the size/risk classifier keeps one definition.

**The asymmetry is deliberate and permanent:**

| Direction | Mechanism | Why |
|---|---|---|
| Under-provisioning | **blocks** at close | the floor is what stops the spec-169 collapse |
| Over-provisioning | **reported**, never blocked | blocking a surplus dispatch pushes review inline — the collapse itself |

## Consequences

- **Two invariants never move.** Every code batch keeps **≥1 independent reviewer** (never sized away),
  and a *required* role that was not dispatched **fails closed**.
- **Hardness follows from computation, not a flag.** A recorded set is enforced hard regardless of
  `role_floor_mode`. This supersedes the plan's OQ-3 ("arm the enforce marker"): the marker arms the
  **blanket** four-role mandate, which is the very thing that was correctly left dormant — demanding
  four roles for a one-line change leaves under-declaring risk as the only escape.
- **Not inert for non-adopters.** When nothing recorded a set, the gate still sizes the batch and
  announces it — advisory. Recording it upgrades that floor to hard. Silently upgrading a
  non-adopter's run to hard per-role enforcement would be the blanket demand this design rejects.
- **Legacy runs are byte-identical**: no recorded set ⇒ today's behaviour.
- `risk_rank` is self-declared and forgeable (ADR-0006), so it only ever **lifts** a recommendation,
  never lowers one the diff earned. Risk touches (auth · schema · infra · API · deps) are derived from
  the diff independently of it.
