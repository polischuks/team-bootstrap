# 0006 — Reviewer independence is clean-context, not cross-model

- **Status:** Accepted
- **Date:** 2026-08-18
- **Constitution clause(s):** P2, P7, P9, P10

## Context

A second post-delivery retrospective found six defects that shipped and were caught only at human
code-review — **none structural**. All were semantic/behavioral correctness on edge inputs (priority
inversion under capacity, orphaned writes before a validation throw, byte-cut where the plan said top-N, a
filter eating a benign token, a first-row aggregation bug) plus one architecture-review finding that was
self-downgraded to a comment. The machine gates in `verify-batch` are all *structural* (orphans, drift,
gate-integrity, delivery, red-first, breadth); the one layer that catches semantic correctness — an
independent adversarial post-code review — was still prose the orchestrator could consolidate away, and
was.

Research is explicit that a model is a **fallible judge** of its own work (self-preference bias;
verification lags generation; a same-context reviewer inherits the biases that produced the code). The
strongest lever is to separate the actor doing the work from the actor judging it, and to give the judge a
**fresh context** that sees only the diff + criteria.

## Decision

`check-review-ack.sh` (verify-batch gate C) makes an independent post-code review a **recorded,
fail-closed machine outcome**. Reviewer **independence is defined as a clean-context subagent** (P2): the
reviewer runs in a fresh subagent seeing only the diff + enumerated refutation criteria, never the
builder's run document. Cross-model / cross-provider review is **optional hardening** reserved for
`irreversible`/security batches — team-bootstrap stays Claude-Code-native by default (P7).

The gate enforces **presence, independence, clean-context attestation, commit anchor, and refutation
governance** — **not the correctness of the verdict**. Honest limit (parity with `risk_rank`/`seam_acks`):
the *who* (`reviewer ≠ builder`) is a marker string, forgeable by the same orchestrator; the *when*
(commit) is git-grounded. What changes is that "no independent review ran" moves from *invisible* to
*fail-closed*.

## Consequences

- A `kind:code` batch cannot close without a recorded independent review (reviewer≠builder, context:clean,
  verdict:go, commit reachable+post-baseline). Dogfooded on its own delivery: the gate's own three rounds
  of adversarial review caught three distinct fail-open bugs in the gate before it could close.
- The review is refutation-shaped (Refute-or-Promote) over standing edge classes; a credible refutation is
  governed through gate B ([0007](0007-time-boxed-waivers.md)), not dropped.
- The independence guarantee is bounded by the honest limit above; cross-model is the escalation when that
  bound is too weak (irreversible/security).
