# 0012 — Control-surface protection (declaration discipline, not immutability)

- **Status:** Accepted
- **Date:** 2026-08-19
- **Constitution clause(s):** P3, P6, P10, P11
- **Related:** [0005](0005-closure-fidelity-gates.md) (closure-fidelity gates), [0006](0006-independence-clean-context.md)
  (forgeable-honesty limit), [0008](0008-harness-verified-role-execution.md) (degradation- vs forgery-proof)

## Context

Every enforcement layer this project ships — `check-tdd`, `check-seam-ack`, `check-enforcement`,
`verify-batch`'s gate wiring, the hook registrations — protects the *delivered code*. Nothing protected
the **gates and hooks themselves**. `check-gate-integrity` catches *green-by-skip* (a gate that passed
because it was skipped) but has **no notion of the expected gate set**, so "a batch edited `bin/check-*.sh`
into vacuity" or "a batch dropped a gate line from `verify-batch.sh`" was caught by **nothing**. This is
the same class Anthropic's `sandbox-runtime` blocks by making `.git/hooks`, `.mcp.json`, `.claude/commands`,
and `.claude/agents` write-protected: an agent (or a malicious repo) that edits those *disables the
guardrails themselves*. team-bootstrap edits its own control surface every milestone — always trusted by
convention, never recorded.

P10 already governs non-disableability ("a gate that did not actually run — green-by-skip, silently
disabled, vacuous — is a failure, not a pass"), but no gate extended that to the gate scripts and hook
registrations. This ADR does.

## Decision

**Make a machinery change a declared, acked, independently-reviewed event — do not attempt in-plugin
immutability.** A `kind:code` batch whose git window intersects the plugin's own control surface
(`references/control-surface.txt`: `bin/check-*.sh`, `bin/verify-batch.sh`, `bin/delivery-lib.sh`,
`bin/tdd-red.sh`, `bin/record-dispatch.sh`, `hooks/*.json`, `.claude`, `.mcp.json`, `AGENTS.md`,
`commands`, `agents`, and the list file itself) **must record a `control-surface` seam-ack** — enforced
by `check-seam-ack` treating that glob set as an **always-present high-risk seam**, in addition to the
per-run marker `high_risk_seams`.

**Consolidated into `check-seam-ack`, not a new gate.** A separate `check-control-surface` gate would
duplicate `check-seam-ack`'s ack-validation chain (extractable only by editing `check-seam-ack` anyway —
BF1) and would re-introduce glob-blindness on the validation side (BF2). So the design instead hardens the
one gate everyone already runs:

1. **Glob-aware `_intersects`** — the shipped matcher did equals + under-dir only (its `"$p"` was quoted →
   `*` literal), silently under-matching `bin/check-*.sh` / `hooks/*.json`. An unquoted-`$token` `case`
   branch (iterated line-by-line so globs are never pathname-expanded against the CWD) fixes **both**
   detection and ack-validation at once — they route through the same helper and cannot disagree.
2. **Fail-closed `_batch_files`** — a tamper-relevant gate must never fall back to the ledger's
   self-declared `"files"` (a tamperer controls them). An empty/unresolvable git window now fails closed.
3. **Standing `control-surface` seam** — unioned in **before** the "no high_risk_seams recorded" early
   return, so it fires even when the marker records zero seams. Its ack must be named `control-surface`
   specifically (a different seam-ack does not satisfy it).

No `machinery:true` flag: the commit-anchored seam-ack **is** the declaration; a second self-declared bit
adds nothing at the same forgeable ceiling.

## Honest limits (this is why the headline is "declaration discipline," not "tamper-proof")

- **The self-reference circularity (deepest).** `check-seam-ack` is *itself* control surface, and
  `verify-batch` runs every gate from the **committed HEAD** — the edited one. A batch that co-edits the
  **circular core** (`check-seam-ack.sh` body / `verify-batch.sh`'s gate wiring / `delivery-lib.sh`'s
  reader / `references/control-surface.txt`) **and** drops the `check-seam-ack` invocation runs the edited
  version, so the gate never fires. The in-plugin gate is non-silent against **isolated** tampering (edit
  one gate alone) but a determined **co-committed core edit** escapes. Nothing in-plugin can enforce its
  own core.
- **The backstop is repo/org POSTURE the plugin cannot force.** A CI-from-trusted-ref check (shipped as an
  *example*, [`.github/control-surface-ci.sh`](../../.github/control-surface-ci.sh) +
  [`control-surface-guard.yml`](../../.github/workflows/control-surface-guard.yml)) compares a PR's
  control-surface files to `main`, but a same-repo PR runs its own workflow copy → it is non-circular
  **only under GitHub branch-protection** ("require this check" + review of workflow edits), and its
  `Control-Surface-Ack:` trailer is author-written → **visibility + human review, not prevention**. Uniform
  with org-level `sandbox-runtime` / managed-settings immutability. The plugin ships the discipline; the
  anti-tamper is the repo's/org's to enforce.
- **Forgeable honesty.** A batch that both edits a gate to vacuity *and* records a `control-surface`
  seam-ack could still self-weaken — the same ceiling as `risk_rank`/`seam_acks` (ADR-0006). What changes:
  tampering can no longer be *silent* or *undeclared*; it becomes a visible, acked, reviewable decision.

## Consequences

- Every future machinery change in this repo must record a `control-surface` seam-ack — intended (the
  discipline), and dogfooded from this milestone's own Batch A onward.
- No constitution bump (v1.0.1): this operationalizes P10/P3/P6/P11 as already written. No new gate script;
  `references/control-surface.txt` + `delivery-lib.sh:control_surface_globs()` are the only additions.
- Asset **MINOR → 2.26.0** (hardening a shipped gate + a standing seam + a CI example; 2.24.0 at delivery,
  rebumped over `branch-protection-gate`'s 2.25.0 at merge).
