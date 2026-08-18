# 0007 — Governance waivers are time-boxed, not perpetual

- **Status:** Accepted
- **Date:** 2026-08-18
- **Constitution clause(s):** P6, P10, P3

## Context

The prior milestone's enforcement gate ([0005](0005-closure-fidelity-gates.md)) made a *silently-skipped*
test-quality dimension loud and blocking, requiring an `enforcement_ack` to ship with it OFF. It **worked
but deprecated into routine**: a `feature|doc` batch passed on a bare `enforcement_ack:true`, and the
dogfood project re-acked the same gaps every run as "expected". The detector fired; the ack became a
**perpetual free pass** — the same failure class (a fired signal self-downgraded) as the
architecture-review finding quietly dropped to a comment.

Mature vulnerability programs never let a finding be silently dropped: a waiver is **time-boxed, ticketed,
independently approved, and auto-refires on expiry or on a new change**; and the actor shipping cannot
clear its own finding (separation of duties).

## Decision

Every governance waiver in team-bootstrap is a **governed, expiring object**, not a boolean:

- **Enforcement waiver** (`check-enforcement.sh`): `enforcement_ack` is valid only with `enforcement_ack_by`,
  `enforcement_ack_reason`, `enforcement_ack_expires` (YYYY-MM-DD, unexpired vs `TEAM_BOOTSTRAP_NOW`), and
  `enforcement_ack_category ∈ {host_structural, deferred}`. The category is **derived, not trusted** — a
  declared+resolvable tool forces `deferred`. An *ackable* gap (deferred/unwaived) hard-fails on a
  high-risk-seam-touching **or** `run-rate|irreversible` batch; a valid `host_structural` gap (the tool
  cannot exist on host) is exempt from every tier.
- **Disposition waiver** (`check-disposition.sh`): a fired review finding of severity ≥ MEDIUM cannot be
  self-dispositioned. A downgrade requires an independent `disposition_waiver` (approver ≠ builder,
  category, reason, expiry, **current commit** — a new commit voids it, re-opening the finding).

## Consequences

- A waiver without an expiry is not a waiver; renewal is allowed but dated and surfaced in post-review
  (visible ratchet), never a standing default.
- The `host_structural` exemption is what lets team-bootstrap ship changes to its **own** gate machinery
  (whose bash coverage/mutation tools cannot exist) without self-blocking, while keeping the tiered
  prevention load-bearing for *target* projects where the tooling exists. Honest limit: for a repo whose
  gaps are permanently host_structural, expiry buys **visibility**, not prevention.
- Separation of duties (`approver ≠ builder`, `reviewer ≠ builder`) is enforced by the marker's dispatch
  label; its honesty is the human's, logged not proven (parity with `risk_rank`).
