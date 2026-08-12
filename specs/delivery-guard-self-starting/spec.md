# Spec — delivery-guard-self-starting

> Follow-on to the `deliver-delivery-guard` run (v2.11.0, P0–P4: commits `e6bba5d`, `a9b9a8b`,
> `0b7d409`). Those commits **are** on `main` and the gates enforce (see Code review, below).
> But a running review of the mechanism — not the commit names — shows the layer does **not yet
> achieve its own stated goal** ("closure self-report technically inexpressible"). This milestone
> closes the three defects that keep the retrospective's failure reproducible.

## Code review — what v2.11.0 actually does (executed, not read)

Method note: the earlier claim "v2.11.0 already fixed this" was reached by reading commit
messages and the ledger — inferring capability from names, the exact **P11** anti-pattern. This
section replaces that with executed evidence. Fixtures were run against the committed scripts
(working tree == HEAD, `shellcheck --severity=error` clean).

**Verified working (do not rebuild):**

| Case | Ledger state | Result | Verdict |
|---|---|---|---|
| T1 | `kind:code, closed, code_delta:50` | exit 0 | ✅ earned closure passes |
| T2 | `kind:code, closed, code_delta:0` | exit 1 | ✅ P0.3 — zero-delta code batch rejected |
| T3 | first batch `kind:doc`, code later | exit 1 | ✅ P2 — first-batch-must-be-code holds |
| T4 | `kind:code` announced then abandoned | exit 1 | ✅ unearned-closure rejected |
| P1 | `check-preconditions.sh` on this repo | exit 0, correct verdicts | ✅ deliverability probe runs |

**Defects found (this milestone's targets):**

- **F-A — Critical — closure is forgeable.** A hand-written line
  `{"id":"B1","kind":"code","status":"closed","commit_shas":["deadbeef"],"code_delta":137}`
  passed `check-delivery.sh` with **exit 0** — no pipeline, no commit, a SHA git rejects
  (`git cat-file -e deadbeef` → *not a valid object*). `check-delivery` **trusts** the
  self-declared `code_delta` number and **never verifies** `commit_shas` exist or that they
  touched non-doc files. So `enforcement.md:33` — *"the orchestrator's prose cannot flip a batch
  to closed, that is the whole point"* — is **false**. P0 did not make closure self-report
  inexpressible; it moved it from English prose to a forgeable JSON line. `.runs/` is an ordinary
  orchestrator-writable file; nothing distinguishes a `verify-batch` stamp from a fabricated one.
- **F-B — Critical — fail-open on no ledger.** `check-delivery.sh:40-43` returns **exit 0**
  ("delivery not machine-checkable, skipping") when `.runs/<run>/batches.jsonl` is absent (T5).
  The retrospective's failure *is* "never adopt the batch protocol" — which produces no ledger,
  so the delivery-occurred gate certifies nothing and passes. **P10**: a gate that did not run is
  a failure, not a pass.
- **F-C — High — invocation seam.** No hook or plugin manifest invokes `check-delivery`,
  `verify-batch`, or `check-preconditions` (`grep hooks/ .claude-plugin/` → none). They run only
  because `deliver.md` prose tells the orchestrator to — the same ~70%-adherence prose
  `enforcement.md` itself says can't be trusted. The one non-bypassable layer (CI) needs a push
  **and** a committed ledger, but `.runs/` is gitignored and the failing run never pushes.
- **F-D — Medium — precondition is advisory + unrecorded.** `check-preconditions.sh` detects
  "branch not on remote / build-from-git deploy" but exit 2 relies on the orchestrator to surface
  and honor it; the acknowledgement is spoken, never recorded, and nothing blocks Phase B if the
  check is skipped or ignored.
- **F-E — Medium — ordering is kind-only.** first-batch-must-be-code (T3) rejects `kind:doc`
  first, but cannot see that a *code* batch is low-risk infra vs the bleeding-stopper. The
  retrospective's "C-2 before the rest of the code" is not expressible.

## Overview

Make the delivery gate **unforgeable, self-starting, and fail-closed**. F-A is the headline: closure
must be a function of **repository state git can prove**, not a self-declared field — `check-delivery`
recomputes `code_delta` from the named commits and rejects any `commit_sha` that does not exist or did
not change non-doc code. Once closure can't be faked, F-B/F-C make the gate impossible to *skip* under
an active run, F-D records the deliverability ack as blocking state, and F-E promotes ordering from
kind to declared load-bearing rank. The unit that makes self-starting possible is a **harness-owned
run marker**; once "a delivery run is active" is a machine fact, every gate can invert its absent-input
branch from skip to fail without nagging non-delivery sessions.

## In scope

- **F-A — unforgeable closure.** `check-delivery.sh` stops trusting `code_delta`/`commit_shas`: it
  (a) `git cat-file -e` each `commit_sha` (missing SHA → fail), (b) **recomputes** the non-doc delta
  from the batch's commit range and compares to the stamped value (mismatch → fail), (c) requires ≥1
  real commit that changed non-doc files. A forged `closed` line no longer passes.
- **F-B — fail-closed under an active run.** With a run marker present (`intends_code:true`) and no
  ledger, or a ledger with zero `closed kind:code` batches, `check-delivery.sh` **exits 1**. No marker
  (non-delivery session) keeps the exit-0 skip.
- Harness-owned **run marker** `.runs/<run>/RUN` (`{run, pipeline, feature, intends_code}`) written at
  Phase A start — the machine fact "delivery run active."
- **F-C — delivery-aware Stop / SubagentStop hook** that blocks completion only while a marker is
  active *and* the ledger has an announced-but-unclosed `kind:code` batch (or no closed code batch) —
  no-op otherwise, so it is safe on-by-default (unlike the blanket `verify-batch` Stop hook
  `enforcement.md` rejects).
- **F-D — recorded, blocking precondition.** `check-preconditions.sh` exit 2 must write an `ack`
  record to the run marker before Phase B may announce batch 1; exit 1 stays a hard stop.
- **F-E — declared load-bearing rank.** Ledger entries carry an enum `risk_rank`
  (`irreversible > run-rate > feature > doc`); `check-delivery.sh` rejects a lower-rank `kind:code`
  batch closing before a higher-rank one.
- `commands/deliver.md`, `references/enforcement.md` (correct the false "prose cannot flip to closed"
  line to describe the git-derived guarantee), `references/failure-policy.md`; version bump per P8.

## Out of scope

- Proving a `risk_rank` is **honest** — an agent can mis-rank (R3). Enum-constrained + logged for human
  review; explicit beats implicit.
- Proving the deliverability **`ack` is honest** — `/deliver` prose flips it, so an orchestrator could
  self-clear it (F-3, surfaced in the Step-7 architecture review). `check-delivery` enforces the
  **presence** of `ack:true` before batch 1 and that a `precond.exit==2` cannot be silently ignored — not
  that a human truly consented. Same accepted limit as `risk_rank` honesty: flag-constrained + logged, not
  proven. AC-7 is a *recorded, non-skippable* gate, not an honesty gate.
- Making CI bind without a push — P5 forbids un-authorized push. Surfaced at Phase A (F-D), not
  invented. Committing a redacted ledger for CI is deferred (OQ-2).
- The code-clean gates (orphans/architecture/gate-integrity) — already fail closed, unchanged.

## Post-delivery review (v2.12.0, execution-grounded)

An independent execution-grounded review after B1–B5 confirmed the headline fixes hold (deadbeef forge
rejected; 10/10 gate self-tests; historical ledger not falsely failed; shared delta lib) and surfaced
four residuals. **B6** resolved the correctness/honesty ones; two are recorded characterizations.

- **R-1 (fixed, B6)** — a marker-less `check-delivery` run silently ran only the weak checks yet reported
  "git-verified". Now it reports **"MARKER-LESS run — F-2 binding and fail-closed are NOT enforced"** (P6).
- **R-2 (fixed, B6)** — commit binding did not require cited commits to be **reachable from HEAD**, so a
  sibling/discarded/cherry-pick-source commit could earn closure. Now each cited commit must be an
  ancestor of HEAD (this run's delivered history) — the primary "earned by THIS run's commits" guarantee.
- **R-3 (fixed, B6)** — `baseline_sha:"unknown"` disarmed the predate check while fail-closed stayed on.
  The marker writer no longer emits `"unknown"` (omits baseline when HEAD is unresolvable), and
  `check-delivery` warns loudly when an active baseline does not resolve.
- **R-4 (recorded)** — AC-7's blocking ack has a *presence* dependency, not just the honesty one already
  listed: it only bites if `check-preconditions.sh` actually recorded `precond.exit==2`. If that probe is
  never run, nothing is recorded and nothing blocks. Documented in `enforcement.md` and `deliver.md`.
- **CI-scope (recorded)** — F-2 binding + fail-closed are marker-gated ⇒ **in-session only**; CI cannot
  see the gitignored marker/ledger, so the delivery-occurred layer does not run in CI. The "fail-closed
  delivery gate" holds in-session; committing a redacted summary for CI stays deferred (OQ-2).

## User stories

- **US1** — As the founder, I want a hand-written `closed` entry to be **rejected unless git proves the
  code landed**, so "closed by word" is inexpressible whether the word is prose or JSON.
- **US2** — As the founder, I want a delivery run that produces no code to **fail in-session**, so an
  agent cannot finish Phase A, skip Phase B, and report closure.
- **US3** — As the orchestrator, I want the run scaffold created by the harness, so the gate can't be
  disabled by my simply never writing a ledger.
- **US4** — As the founder, I want "is the branch pushed / does the deploy see it" recorded and
  **acknowledged before Phase B**, not discovered after the files are written.
- **US5** — As a reviewer, I want each batch's load-bearing rank machine-checked, so "doctrine first,
  bleeding-stopper last" is rejected at the gate, not in retrospective.

## Acceptance criteria

- **AC-1** (US1, F-A) — A `closed kind:code` entry whose `commit_shas` contains a SHA not in the repo
  → `check-delivery.sh` exit **1**. *(Fixture: the `deadbeef` line that currently passes must now fail.)*
- **AC-2** (US1, F-A) — A `closed kind:code` entry whose stamped `code_delta` exceeds the recomputed
  non-doc delta of its commit range → exit **1**. *(Fixture: real SHA touching only `*.md`, `code_delta:137` → fail.)*
- **AC-3** (US1, F-A) — Regression: the historical `deliver-delivery-guard` ledger (B1–B5, real SHAs)
  still passes — recomputed deltas match, doc batches exempt. *(No false positive on honest history.)*
- **AC-4** (US2, F-B) — Run marker `intends_code:true` + no ledger → exit **1**; + ledger with only
  `kind:doc` closures → exit **1**. *(Two fixtures.)*
- **AC-5** (US2, F-B) — **No** run marker + no ledger → exit **0** ("not a delivery run"). Fail-closed
  applies only under an active run.
- **AC-6** (US3) — `/deliver` writes `.runs/<run>/RUN` at Phase A start **before** any Skill step,
  recording `pipeline`, `feature`, `intends_code`.
- **AC-7** (US4, F-D) — `check-preconditions.sh` exit 2 → `/deliver` records `ack` in the marker and
  refuses to announce batch 1 without it; a marker lacking `ack` blocks Phase B. exit 1 hard-stops.
- **AC-8** (US2, F-C) — The Stop/SubagentStop hook: active marker + announced-unclosed `kind:code`
  → blocks Stop; all code batches closed or no marker → allows Stop. *(Two fixtures.)*
- **AC-9** (US5, F-E) — A `kind:code` batch with lower `risk_rank` closing before a higher-rank
  `kind:code` batch → exit **1**.
- **AC-10** — `shellcheck --severity=error bin/*.sh` clean; every changed script self-tests; `check-gate-integrity.sh`
  confirms no fixture is green-by-skip and the new hook demonstrably fires (P10 declared ⇒ exercised).

## Pre-resolutions (from the retrospective — founder rulings)

- **F1** — "Closed by a gate, not by my word; if the pipeline didn't run, the batch isn't closed." →
  closure derived from git, forgery rejected (AC-1..3); absence under an active run = fail (AC-4).
- **F2** — "First batch is C-2, not doctrine." → `risk_rank` ordering, not just code-before-doc (AC-9).
- **F3** — "Publication question resolved at the Phase-A gate, not after the files." → recorded,
  blocking ack (AC-7).
- **F4** — "'fire' means code, not another review." → already policy; unforgeable + self-starting
  closure makes it bind even when the orchestrator skips the ledger.

## Open questions (for Step 3)

- **OQ-1** — Ship the Stop hook on by default (safe: no-ops without an active marker) or opt-in via a
  `settings.json` snippet in `deliver.md`? · RECOMMENDED: on by default, narrow. · web-verify: no.
- **OQ-2** — Emit a committed `.runs/<run>/summary.json` (redacted) so CI can assert delivery-occurred
  on first push? · RECOMMENDED: defer to a follow-on. · web-verify: no.
- **OQ-3** — `risk_rank` as a fixed enum (`irreversible|run-rate|feature|doc`) mapped to integers, so a
  fuzzy number can't be inflated? · RECOMMENDED: yes. · web-verify: no.
- **OQ-4** — For AC-2, is the batch's commit range the stamped `commit_shas` list, or
  `since-prev-closed..HEAD` as `verify-batch` computes it? · RECOMMENDED: recompute over the stamped
  `commit_shas` set — self-contained, doesn't drift with later history. · web-verify: no.

## Clarifications (Step 3 — resolved)

No open question required web verification: every dependency is in-house (bash/git, `.runs/` ledger,
Claude Code Stop/SubagentStop hooks) — there is no external vendor/SDK/API claim to verify. The
mechanism that *was* grounded (P11) is the Claude Code hook contract, verified against
[`references/hooks.md`](../../references/hooks.md) and [`hooks/hooks.json`](../../hooks/hooks.json), not memory.

- **OQ-1 → [x] Resolution: on by default, narrow.** The Stop/SubagentStop hook **no-ops (exit 0)**
  whenever no active run marker is present — identical to how `quality-gate.sh` no-ops without an
  `AGENTS.md` (`hooks.md:20`), which is why that gate ships global. Same safety property here ⇒ ship on
  by default. Disable escape hatch `TEAM_BOOTSTRAP_DELIVERY_GATE=off` for parity with
  `TEAM_BOOTSTRAP_QUALITY_GATE=off`.
- **OQ-2 → [x] Resolution: defer to a follow-on.** No committed `summary.json` this milestone; CI
  binding without a push stays deferred (P5 forbids un-authorized push; F-D surfaces it at Phase A).
- **OQ-3 → [x] Resolution: yes — fixed enum mapped to integers.** `risk_rank ∈
  {irreversible:4, run-rate:3, feature:2, doc:1}`. A closing `kind:code` batch whose rank-int is
  lower than an already-closed `kind:code` batch's rank-int → fail (AC-9). Enum-constrained so a fuzzy
  number can't be inflated (R4 accepted: honesty of the rank is out of scope, logged for human review).
- **OQ-4 → [x] Resolution: recompute over the stamped `commit_shas` set.** Self-contained; does not
  drift as later history lands. **Empirically validated** against the historical ledger (below).

### Drift catches (Step 3)

- **Catch #1 — AC-2 predicate is `stamped > recomputed → FAIL` (inflation only), NOT `stamped !=
  recomputed`.** Executed evidence: recomputing non-doc delta over each historical batch's stamped
  `commit_shas` set yields B1=144 (stamped 144), B2=236 (236), **B3=43 (stamped 41)**, B4/B5=0 (0).
  B3's honest recompute *exceeds* its stamp by 2. A `!=` check would false-fail honest history and
  break **AC-3**; only "stamped exceeds recomputed" (a forger inflating the number) may fail. AC-2's
  word *"exceeds"* is therefore load-bearing and must be implemented literally.
- **Catch #2 — the Stop/SubagentStop block is exit `2`, not exit `1`.** Claude Code's hook contract
  (`hooks.md:13`) blocks completion on exit **2** and feeds stderr back; other non-zero is a
  non-blocking error. This is distinct from `check-delivery.sh`'s exit `1` (the CI/verify-batch
  contract). The hook and the CI gate share the *logic* but not the *exit convention* — grounded in the
  mechanism, not the shared name "block."
- **Catch #3 — commit-SHA normalization.** The historical ledger stores abbreviated SHAs
  (`e6bba5d`). `check-delivery` must `git rev-parse --verify` / `git cat-file -e` each `commit_sha`
  (abbrev-safe) before recompute; a SHA git cannot resolve → fail (AC-1). Recompute uses
  `git show --numstat` per resolved SHA, summed over the set.

## Principles compliance matrix

| AC | Constitution clause | Verification approach |
|---|---|---|
| AC-1, AC-2, AC-3 | **P9, P11** (verify by evidence; ground in mechanism) | closure recomputed from git objects, not read from a self-declared field |
| AC-4, AC-5 | **P10** (fail-closed; vacuous gate = failure) | fixtures assert exit 1 on absent evidence under an active run, exit 0 without a run |
| AC-4, AC-8 | **P3, P6** (harness-enforced; report truth) | script + hook enforce, not orchestrator prose; false-complete Stop blocked |
| AC-6 | **P3** | run marker written by the command/harness, not left to orchestrator courtesy |
| AC-7 | **P5** (irreversibility gated; never push without auth) | push/deploy precondition recorded + acknowledged before Phase B |
| AC-9 | **P10, P11** | ordering checked against declared rank, cited in the ledger, not inferred |
| AC-10 | **P8, P10** (versioned gate; declared ⇒ exercised) | shellcheck + self-tests + gate-integrity; new hook proven to fire |

## Risks

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Git-recompute (AC-2) diverges from `verify-batch`'s own delta math → honest batches fail | M | H | AC-3 pins the historical ledger as a regression fixture; share one delta function between `verify-batch` and `check-delivery` |
| R2 | Fail-closed inversion nags docs-only / WIP sessions | M | H | Gate keys strictly on an active marker with `intends_code:true`; AC-5 pins the no-marker exit-0 path |
| R3 | Orchestrator omits the RUN marker as it omitted the ledger → same fail-open | M | H | Marker written by `/deliver` step 0 **and** a SessionStart/PreToolUse safety-net on first Skill call in a deliver context; Phase-A summary prints "delivery run: yes/no" for human audit |
| R4 | `risk_rank` self-declared, gameable | H | M | Accepted limit (out of scope); enum-constrained (OQ-3) + rationale logged |
| R5 | Stop-hook block loops (Claude Code caps ~8 consecutive) | L | M | Actionable message (run the pipeline or close the run); existing cap backstops |

## Dependencies

- v2.11.0 artifacts (verified present): `bin/check-delivery.sh`, `bin/verify-batch.sh`,
  `bin/check-preconditions.sh`, `commands/deliver.md`, `references/enforcement.md`, `references/failure-policy.md`.
- `references/hooks.md` (Stop/SubagentStop registration), `references/irreversibility.md` (P5).
- Constitution **P9/P10/P11** as governing invariants; **P8** version-bump gate.
