# 0002 — Batch closure derives from git-provable repository state, not a self-declared field

- **Status:** Accepted
- **Date:** 2026-08-12
- **Constitution clause(s):** P3, P5, P6, P9, P10, P11

## Context

v2.11.0 introduced the delivery-occurred gate: a batch is `closed` only when `verify-batch.sh` stamps
the ledger with `commit_shas` + `code_delta`. This moved closure from English prose to a JSON line — but
the line was **trusted**. A running review (spec `delivery-guard-self-starting`) showed a hand-written
`{"status":"closed","commit_shas":["deadbeef"],"code_delta":137}` passed `check-delivery.sh` with exit 0:
nothing verified the SHA existed or that the delta was real. The gate also **failed open** when no ledger
existed (the retrospective's actual failure — never adopting the batch protocol — produces no ledger),
and `.runs/` is gitignored so CI could not backstop it. The claim in `enforcement.md` that "the
orchestrator's prose cannot flip a batch to closed" was therefore false: closure had merely moved from
prose to a forgeable JSON line.

## Decision

Make closure a **function of repository state git can prove**, and make "a delivery run is active" a
**machine fact the harness owns**:

1. `check-delivery.sh` `git rev-parse`s every `commit_sha` (missing → fail), **recomputes** the non-doc
   delta from those commits via a shared `nondoc_delta_of_shas` (`bin/delivery-lib.sh` — the same
   function `verify-batch.sh` stamps with, so stamp == recompute by construction), and fails if the
   stamped `code_delta` **exceeds** the recomputed value ("exceeds", not "differs", so honest history
   whose range-diff stamp is ≤ its per-commit recompute still passes).
2. Under an active run, **commit-to-batch binding**: no `commit_sha` may be credited to more than one
   closed batch, and each must post-date the run's `baseline_sha` — closure cannot be earned from
   arbitrary pre-existing history.
3. A harness `UserPromptSubmit` hook (`bin/delivery-marker-init.sh`) writes `.runs/<run>/RUN` on
   `/deliver`, so gates invert absent-input from *skip* to *fail* (`intends_code:true` + no ledger / zero
   closed code → fail), while a no-marker session keeps the exit-0 skip. A delivery-aware `Stop` hook
   blocks premature completion.

## Alternatives considered

- **Recompute over `since-prev-closed..HEAD` (a range) instead of the stamped `commit_shas` set** —
  rejected: not self-contained; the recompute would drift as later history lands. The stamped-set
  recompute reproduces the historical ledger exactly (regression-pinned).
- **Write the marker from `commands/deliver.md` step 0 (prose)** — rejected (Step-7 architecture review,
  F-1): prose-written means an orchestrator that skips the protocol writes no marker and the gate
  no-ops; the fail-open seam would just move from "no ledger" to "no marker". The harness must own it.
- **Register the Stop hook on `SubagentStop` too** (as the spec's AC-8 names) — rejected: worker
  subagents finish before `verify-batch` closes the batch, so blocking their `SubagentStop` would
  deadlock closure. Guard the **main** orchestrator's `Stop` only.
- **Commit a redacted `.runs/<run>/summary.json` so CI can assert delivery-occurred on first push** —
  deferred (OQ-2); `.runs/` stays gitignored this milestone.

## Consequences

- Closure is unforgeable, self-starting, and fail-closed **in-session**; a forged `closed` line (prose
  or JSON) is inexpressible.
- **Accepted limits (honesty, not presence):** `risk_rank` (R4) and the deliverability `precond.ack`
  (F-3) are enum/flag-constrained and logged for human review, **not proven** — an agent can mis-rank or
  self-clear the ack. The gates enforce that these are *recorded and non-skippable*, not that a human
  truly consented.
- **Threat boundary:** `baseline_sha` (the F-2 anchor) lives in `.runs/<run>/RUN`, an orchestrator-writable
  file. Binding therefore defends against single-field/casual forgery and raises the bar to *coordinated
  two-field* tampering (ledger + marker together); it does **not** defend against an adversary who
  rewrites harness state at will — the same accepted boundary as R4/F-3.
- **Known edge (F-5):** a history rewrite (rebase/amend) that changes a stored `commit_sha` makes it
  unresolvable → an honestly-earned batch would false-fail AC-1. Acceptable: the ledger records the SHAs
  as of close.
- CI binding without a push remains unavailable (`.runs/` gitignored) — deferred, not solved.
