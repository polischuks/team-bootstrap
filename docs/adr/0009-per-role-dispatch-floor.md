# ADR-0009 — Per-role dispatch floor (all-four-role-dispatch)

- **Status:** Accepted (v2.22.0). Ships in **warn**; enforce is a committed, evidence-gated flip.
- **Supersedes:** the ADR-0008 *Decision* bullet "the four review roles dispatch under the dedicated
  `independent-reviewer` type." (ADR-0008's mechanism, honest limits, and the ≥1 total-collapse floor stand.)

## Context

ADR-0008 (`exec-role-integrity`) made "a reviewer ran independently" a harness-observable fact: a `full`/`mvp`
`kind:code` batch with **zero** reviewer-typed subagent dispatches fails closed (the spec-169 collapse). But
its floor is **≥1** — a *partial* collapse (1 of the 4 mandatory review roles dispatching while 3 run inline)
passes. The doctrine says all four **must** dispatch; a mandate-of-four enforced-at-one is half-enforcement.

**The blocking constraint (verified):** per-role attribution is impossible on the shipped signal. The recorder
captures only `subagent_type`, and `integration-verifier` / `regression-guardian` had **byte-identical**
`preferred_subagent_types`, with `independent-reviewer` shared by all four. So "count 4 distinct roles" cannot
be derived — it is not a `-eq 0` → `< 4` change.

## Decision

1. **Four dedicated, collision-free per-role dispatch types** — `integration-verifier`, `architecture-reviewer`,
   `regression-guardian`, and **`tb-code-reviewer`** (NOT bare `code-reviewer`: the `team-bootstrap:` prefix is
   not reliably delivered in `subagent_type`, so the slug must be attributable even bare). `agents/<role>.md`
   defines each. This **supersedes** the shared-`independent-reviewer` mandate.
2. **One-file role map.** `references/review-types.txt` gains an optional `<TAB>role` column; the four dedicated
   slugs carry a role (recorded **and** attributed), generics stay bare (recorded, satisfy the ≥1 floor, do
   not attribute). `role_of_slug` / `roles_covered` / `missing_roles` (delivery-lib.sh) read it.
3. **Per-role gate.** `check-role-dispatch.sh` (and `check-review-ack.sh` parity) fail a `full`/`mvp` `kind:code`
   batch missing any mandated role (`full` = all four; `mvp` = `code-reviewer` + `regression-guardian`),
   naming the missing roles. The ≥1 total-collapse floor stays **hard under both modes**.
4. **warn → enforce ramp, mechanically gated on a committed evidence marker — no version tripwire.** The mode
   is read from the presence of the tracked `references/role-dispatch-enforce` marker (override:
   `TEAM_BOOTSTRAP_ROLE_FLOOR`; test-only path override `TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER`). Ships in **warn**
   (marker absent) — announces the missing roles, does not fail. The marker is committed **only after a
   dispatch probe** confirms orchestrators reliably emit four *distinct* slugs (the plugin cannot force
   dispatch — the P7/harness boundary; the shipped default is one `independent-reviewer` agent doing all four
   roles via prompt → ∅ attribution). Committing the marker is the deliberate, evidenced flip — like a
   `host_structural` waiver. **Invariant:** committing the real marker must never change a self-test outcome
   (the marker resolves `BASH_SOURCE`-relative; self-tests point the path override at a temp file).

## Consequences

- **Raises the DEGRADATION floor, not the FORGERY bar (carried from ADR-0008/0006).** A partial inline collapse
  is now caught **under enforce**; but four decoy no-op dispatches under the four dedicated types still satisfy
  the gate. Dispatch ≠ completion (`check-review-ack`).
- **At 2.22.0 the milestone adds no new hard enforcement** — warn + the inherited hard ≥1 floor + FIX#1. This is
  the honest maximum under the harness boundary: enforce engages when-and-only-when adoption is measured, never
  claimed without proof, never silently flipped. If adoption never occurs, the gate honestly stays at warn.
- **In-session only** (`.runs/` gitignored) — like every gate here, not a CI backstop; the marker is read
  during a marked `/deliver`.
- **Per-batch cost.** All four roles per `full` code batch is heavy legit cost against a cheap forgery — an
  asymmetry accepted and disclosed; the value is degradation-detection, not forgery-proofing.
