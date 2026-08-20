# 0014 — Pipeline-integrity hardening (close the four audit gaps A–D)

- **Status:** Accepted (landing batch-by-batch; WS-A accepted, WS-C/WS-D/WS-B follow)
- **Date:** 2026-08-20
- **Constitution clause(s):** P5, P6, P9, P10
- **Related:** [0006](0006-independence-clean-context.md) (forgeable-honesty ceiling),
  [0008](0008-harness-verified-role-execution.md) (degradation- vs forgery-proof),
  [0009](0009-per-role-dispatch-floor.md) (per-role floor, warn-staged),
  [0010](0010-preflight-setup-gate.md) (preflight linter — WS-B reopens),
  [0011](0011-branch-protection-gate.md) (branch guard — WS-D hardens),
  [0012](0012-control-surface-protection.md) (control surface — WS-C hardens)

## Context

The 2026-08-20 audit ([specs/pipeline-execution-integrity/findings.md](../../specs/pipeline-execution-integrity/findings.md))
confirmed that milestones A–D each shipped a **real, working mechanism for its central case**, but each
left a bypass or scope-miss that re-opens the exact hole its milestone was chartered to close — the
founder's req 1/3 ("kill the silent third state") partially open on a path the original milestone did not
gate. This ADR records the remediation decisions. It is **hardening, not new capability**, and it does not
re-litigate the honest enforceability ceilings the original specs disclosed.

Four disjoint work-streams, one per gap, each an independently-committable `kind:code` batch. Ordered by
load-bearing risk: **WS-A first** (the still-open req 1/3 path), then WS-C/WS-D (self-contained gate
hardening), then WS-B (the founder-gated preflight readiness question).

## Decision — WS-A: anchor the role/review gate at run-close, not only at batch-close

**Problem.** `check-role-dispatch` runs in exactly one place — inside `verify-batch` at batch close
(`verify-batch.sh:175`). A degraded `full`/`mvp` run that commits code *inline without announcing a batch*
never reaches that gate: the Stop hook's `code_since_baseline` allowance (`delivery-stop-hook.sh`) accepted
bare code-since-baseline as proof of delivery **regardless of pipeline**, so the run stopped at exit 0 with
no reviewer and no user notice. That is the spec-169 collapse, surviving on the no-batch path.

**Decision (both prongs, landed atomically).**
1. **The `csb` direct-delivery allowance is pipeline-scoped.** Only `single-thread` — the sanctioned
   one-mind contract with no role fan-out — may prove delivery by bare code-since-baseline. For `full`/`mvp`
   a run that shipped code must show a real **earned** batch closure. An **absent or unrecognized** `pipeline`
   is treated **fail-closed** (blocked), mirroring `check-role-dispatch`'s FIX#1: because the Stop hook is the
   *sole* gate on the no-batch path, any non-fail-closed handling of an unknown pipeline would silently
   re-create the exact bypass this fix kills (architecture-review finding #1, HIGH).
2. **The Stop hook independently asserts the reviewer floor at run-close.** For a `full`/`mvp` run whose
   closed `kind:code` batches are observable via `dispatch.jsonl`, at least one must carry a reviewer-typed
   subagent dispatch — computed with the shared `reviewer_dispatch_count` (single source with the gate). This
   is what makes prong 1 sound: the csb-refusal alone is bypassable by a forged `status:closed` ledger line;
   the dispatch-verified floor is the thing that actually gates (architecture-review finding #2).

**Live posture (AC-A4).** The hard, live guarantee is **≥1 independent reviewer** (enforced under both `warn`
and `enforce`). The per-role "all four distinct roles" floor stays **staged in `warn`** pending the adoption
probe, exactly as [ADR-0009](0009-per-role-dispatch-floor.md) already discloses — `references/role-dispatch-enforce`
is deliberately **not** committed here. No document claims all four roles as live-enforced; this ADR makes the
live floor unambiguous rather than leaving it to be inferred. That resolves F-Audit-2 ("no silent dormancy")
without arming a heavier floor on this repo's own delivery runs.

## Honest limits (retained, not regressions)

- **Marker/dispatch forgeability ceiling ([ADR-0006](0006-independence-clean-context.md)).** WS-A trusts a
  `verify-batch`-written `status:closed` stamp when `dispatch.jsonl` is absent (a hand-forged closure with the
  dispatch file deleted escapes). The win is *harness-observed dispatch at run-close*, not tamper-proofing.
  WS-A stays at that documented ceiling — no overclaim.
- **The push-to-`main` half of finding D** stays delegated to remote branch-protection (WS-D scope note).

## Consequences

- A `full`/`mvp` run can no longer stop "green" having shipped code with no reviewer and no announced batch —
  the degraded no-batch path now blocks (Stop exit 2) and announces, telling the operator to close a real
  batch or run `single-thread`.
- Risk R1 (a deliberate tiny inline fix on a `full` run is now blocked): mitigated — the escape is to announce
  and close a batch (the doctrine anyway) or run `single-thread`, which retains the csb allowance (AC-A2).
- `bin/delivery-stop-hook.sh` ships a `--self-test` covering AC-A1/A2/A3a/A3b/A5; `tests/pipeline-integrity-hardening.test.sh`
  carries the behavioural spec; both are in the `Test:` suite so the fix is non-disableable (P10, AC-X1).

## WS-C / WS-D / WS-B (recorded here; land in later batches)

- **WS-C** — add the four missing hook/gate scripts to `references/control-surface.txt` and fail closed on a
  dirty control-surface working tree (in `check-seam-ack`, not a blanket `verify-batch` clean-tree assertion).
  Residual (architecture-review finding #3): adding the two *hook* scripts is weaker than a `verify-batch`
  gate — a gutted hook body is caught only at the next close; documented as a KNOWN GAP (AC-C4), not implied closed.
- **WS-D** — harden `bin/guard-git.sh`'s tokenizer against the three verified parse bypasses (single-quoted
  env, `-c alias`, `--git-dir/--work-tree`) and adopt a fail-closed posture for the unambiguously-git + armed +
  default-branch + non-read case. Determined obfuscation (`eval`, wrappers) stays a disclosed KNOWN GAP (AC-D6).
- **WS-B** — make preflight a readiness gate (three runtime probes + `Prepare:` phase + governed expiring
  waiver), founder-gated per OQ-3 (it reopens the [ADR-0010](0010-preflight-setup-gate.md) descope); may reduce
  to a doc-correction if the descope stands. `governed_waiver_ok` expiry must be darwin-portable.
