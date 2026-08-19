# 0009 — Phase 0 setup-readiness gate (fail-closed before Phase A)

- **Status:** Accepted
- **Date:** 2026-08-19
- **Constitution clause(s):** P3, P6, P10, P11
- **Related:** [0002](0002-closure-from-git-state.md) (closure from git state), [0005](0005-closure-fidelity-gates.md)
  (closure-fidelity gates), [0007](0007-time-boxed-waivers.md) (governed waivers)

## Context

Delivery had a gate for one half of readiness and not the other. [`bin/check-preconditions.sh`](../../bin/check-preconditions.sh)
(end of Phase A) answers *"can the output **land**?"* — remote reachable, branch on the remote, a
build-from-git deploy source, publication authorization — and records a blocking `precond` advisory into
the run marker that `check-delivery` enforces at batch-announce time.

There was **no symmetric gate for setup-readiness**: *"is the project scaffolded so the pre-implementation
flow can even **run** correctly here?"* A `/deliver` could fire against a directory with no
`constitution.md`, no `specs/` convention, no `feature.json` pointer, no `docs/adr/`, or a missing/
un-armed run marker, and Phase A would produce a spec/plan/tasks stack the downstream gates cannot enforce
against. The failure surfaced late (mid-Phase-B, when a gate could not resolve a path) or **never** (a gate
no-oped because the marker was absent). That silent-skip is exactly the P10 failure this project exists to
forbid: a gate that structurally cannot run is a failure, not a pass.

## Decision

A first-class **Phase 0** gate, [`bin/check-preflight.sh`](../../bin/check-preflight.sh), that runs
**before Phase A** and fails **closed** when the project is not setup-ready:

- **Detect-and-report only** — it never mutates the target project (no `mkdir`, no file creation).
- **Fail-closed (exit 1)** on missing scaffold every downstream gate structurally needs: a constitution
  resolved **via the `feature.json` `constitution` key** (P11 — by key, not a hardcoded name; a declared-
  but-unresolvable path fails loud), the `specs/` dir (`specs_dir`), a parseable `feature.json`, `docs/adr/`
  (`adr_dir`), and a run marker carrying `intends_code`+`baseline_sha`. Not a git repo → fail (a non-git
  target cannot anchor a run at all). **Warn-level** (does not fail): `specs/TEMPLATE/`, `AGENTS.md`, and an
  unresolvable `baseline_sha` value.
- **`jq`-free** (P7 portability) — `feature.json` is parsed with the same whitespace-tolerant grep the
  marker path already uses, so the gate runs on target hosts without `jq`.
- **Records a blocking `preflight:{exit,gaps,ack}` verdict** into the run marker via `record_preflight`
  (`delivery-lib.sh`), and `check-delivery` **blocks batch-announce** for an `intends_code` run with a real
  `kind:code` batch while `preflight` is absent (gate never ran), failing-and-unacked, or present-but-
  unreadable — symmetric to the `precond` clause, and gated on an actual code batch so direct-pipeline /
  marker-less / pre-feature runs are never regressed.

The load-bearing plumbing decision (surfaced by the Phase-A **architecture soundness review**): the marker
is grep-parsed, and `precond` and the new `preflight` now **both** carry `exit`/`ack`. `record_precond`'s
historical greedy end-anchored strip only worked because `precond` was the marker's terminal field; once
`preflight` is appended after it, that strip **silently deleted the trailing `preflight` on every
end-of-Phase-A run** — the feature would self-disarm with no error. Resolved with a position-independent
`_marker_strip_obj_key` adopted by **both** writers, plus an object-scoped `field_in_obj` read for both
clauses, landed as the batch-1 foundation before any `preflight` object is written.

## Consequences

- A skipped or unscaffolded Phase 0 is now a **catchable, fail-closed stop** at the cheapest point (before
  any analytical cycle), recorded as a machine fact rather than discovered mid-Phase-B or never (P10).
- Two marker objects now share `exit`/`ack`; the object-scoped read/write is the standing mitigation — new
  marker objects reusing those keys must use `field_in_obj` / `_marker_strip_obj_key`, never global
  first-match or an end-anchored strip.
- **Non-ackable class descoped (report truth).** The spec first proposed a separately-enforced non-ackable
  class (not-a-git-repo / bad baseline). Grounding to the mechanism retired it as unreachable at the
  enforcement layer: a non-git target fails `check-preflight` outright and has **no run marker to ack**; an
  unresolvable baseline is warn-only. A gap-string-parsing carve-out would be dead code, so the honest
  contract is: **all `preflight` verdicts are ackable via `preflight.ack`**, and the non-git case is caught
  before a run exists.
- **In-session only (no CI backstop):** like the delivery/TDD layers, the enforcement is marker-gated and
  `.runs/` is gitignored, so a fresh CI checkout has no marker and the enforcement skips; `check-preflight`
  itself is still runnable in CI as a scaffold linter (its `--self-test` runs in the suite).
- No constitution bump: the gate operationalizes P3/P6/P10/P11 as already written. Asset version **MINOR
  (2.22.0)** — an additive Phase-0 gate + detector script + marker object + doctrine, marker-gated, scoped,
  backward-compatible (a marker without `preflight` is read as "not run" ⇒ blocked on a code batch, the
  intended fail-closed default).
