# 0014 — Pipeline-integrity hardening (close the four audit gaps A–D)

- **Status:** Accepted (WS-A/C/D/B delivered; WS-E post-delivery review-hardening delivered)
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
- **Both prongs fail-closed on the same untrusted field (no allowlist asymmetry).** An early draft
  gated prong 2 (the reviewer-floor assertion) on an *allowlist* — `case full|mvp)` — while prong 1 was
  fail-closed for unknown pipelines. Independent review (CRITICAL-1) caught that a *closed* batch under an
  absent/`audit`/mislabeled (`"full "` trailing-space) or legacy (pre-`pipeline`-field) marker would then
  skip prong 2 entirely and Stop at exit 0 with zero reviewer. Corrected: prong 2 is a **denylist** —
  exempting only `single-thread` — so every non-single-thread pipeline (full, mvp, absent, unknown) has the
  ≥1 reviewer floor asserted whenever a closed batch is observable via `dispatch.jsonl`. Where `dispatch.jsonl`
  is absent the verify-batch stamp is trusted (the ADR-0006 ceiling above). Both prongs now treat an
  unknown/absent pipeline identically: fail-closed.
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
- **WS-B — DELIVERED (founder chose the full readiness gate, 2026-08-20, reopening the
  [ADR-0010](0010-preflight-setup-gate.md) descope).** Three HARD runtime probes in `check-preflight`
  (test-command presence, toolchain/dependency presence, operating-tree coherence incl. baseline-resolves and
  the feature docs-contract), the `_test_cmd` promotion into `delivery-lib` (single source with `check-tdd`),
  a reusable `governed_waiver_ok` (by/reason/unexpired-`expires`, `YYYY-MM-DD` lexical compare — darwin-portable,
  no `date -d`) that replaces the bare preflight ack in `check-delivery` (AC-B5) with `record_preflight` widened
  to preserve the waiver fields, and a `Prepare:` contract field run in Phase 0 before the pipeline fires. The
  shipped scaffold-linter checks are retained (AC-B6). This closes the founder's req 2 that the descope left open.
  **Honest limit (WS-B):** WS-B edits `bin/delivery-lib.sh` — the shared core that `check-delivery`, `check-tdd`,
  and `check-preflight` all `source` to enforce themselves — so this change is inside the same **circular core**
  as the C4 gap: the gate that would detect drift in `delivery-lib` is built on `delivery-lib`. Unchanged
  unavoidable self-reference; the answer stays repo/org posture (CI-from-trusted-ref under branch-protection;
  `sandbox-runtime`), per control-surface-protection §"Honest limits". **Scope (retained):** the readiness gate
  covers the batch-ledger path; a direct/ledger-less `single-thread` run reaches `check-delivery`'s
  direct-delivery allowance before the preflight block (the pre-existing D10 design), so preflight is not
  enforced there — consistent with WS-A keeping the `csb` allowance for `single-thread` alone.

## WS-E — post-delivery review hardening (the fail-opens the milestone's own review found)

The milestone's independent delivery review found that three of the four batches' review-fixes had
relaxed into **fail-open** — the exact failure mode this milestone forbids ("a gate that didn't truly run
is a failure, not a pass"). WS-E closes them **fail-closed**, each with a test asserting the fail-closed
direction (the missing assertions are why they shipped):

- **AC-E1 (#1, WS-D)** — `git "commit"` / `'commit'` / `com"m"it` / `"merge"` / `"git" commit` reached
  exit 0 on the default branch: the R5 "debris" allow-rule (itself a review-fix) treated a quoted
  subcommand token as split-debris. Fixed by a **quote-aware** segment splitter (delimiters inside quotes
  no longer split) + **de-obfuscation** (strip quotes from the binary/subcommand token before
  classifying); a clean unrecognized token now fails **closed**. The R5 read (`git log --grep 'x; git
  status'`) still passes because the `;` inside quotes no longer creates a fake segment.
- **AC-E2 (#3, WS-C)** — the dirty-control-surface probe swallowed `git status`'s exit code, so a corrupt
  index (git status errors) produced zero dirty paths → the tree read as clean → fail-open. Now probes the
  exit and **fails closed** on a git-status error, matching `_batch_files`.
- **AC-E3 (#4, WS-B)** — the toolchain probe HARD-failed legitimate projects: an env-prefixed `Test:`
  (`NODE_ENV=test npm test`), a project-local binary (venv/Yarn-PnP not on the global PATH), a
  lockfile-without-`node_modules` (valid under PnP). Now strips the `ENV=` prefix, resolves
  `node_modules/.bin` and venvs, and the lockfile↔deps check is a **WARN**. Prevents the blanket-waiving
  that would hollow out the governed-waiver discipline.
- **AC-E4 (#5, WS-A)** — the Stop-hook reviewer floor was coarse ("one reviewer anywhere in the run");
  now **per-batch** (every closed `kind:code` batch needs its own dispatch).

### Retained limits (reaffirmed, not overclaimed)
- **#2 (WS-A) — forgeable `status:closed` + absent `dispatch.jsonl`** is the disclosed **ADR-0006
  forgeability ceiling**: prong-2 gates on `dispatch.jsonl` existing (so it never blocks a legit run whose
  dispatch the harness didn't record), which means a hand-forged `status:closed` with the dispatch file
  deleted escapes. In the field this also depends on the plugin being current enough to emit
  `dispatch.jsonl` at all (see the delivery-integrity caveat below). Closing it is org posture
  (CI-from-trusted-ref; sandbox-runtime), not in-plugin.
- **#7 (WS-B) — `Prepare:` is orchestrator-honored convention**, not a harness-executed step (the plugin
  cannot run an install for the host); readiness rests on the orchestrator running it in Phase 0. Disclosed.
- **#9 (WS-B) — B3b docs-contract** is scoped to a *present-but-partial* feature dir (a wholly-absent dir
  is the greenfield pre-Phase-A case and is skipped), so it fires narrowly by design.

### Delivery-integrity caveats bounding what this run proved
- **Dispatch evidence is self-attested this run.** The live plugin cache is stale (2.19.1, predating
  `record-dispatch.sh`), so `dispatch.jsonl` was written through the repo's own recorder, not the harness
  hook — "an independent review ran" is at the forgeable ceiling until the plugin is reinstalled at 2.28.0.
- **`check-completeness --final` AC↔test mapping ran vacuous** (default `AC-[0-9]+` does not match this
  repo's `AC-A1` naming). A follow-up should set `AcPattern: AC-[A-Za-z0-9]+` in AGENTS.md and reference the
  doc-assertion ACs (C4/D6/A4/B4/X1/X2) from a test-path file so the gate bites — deferred as a deliberate,
  tested change rather than a rushed persistent-config edit at close.
