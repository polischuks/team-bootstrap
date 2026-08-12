# Plan — delivery-guard-self-starting

**Source spec:** [`spec.md`](spec.md) · **Constitution:** v1.0.0 (no bump) · **Asset:** 2.11.0 → **2.12.0** (MINOR)
**Shape:** focused hardening milestone — 5 batches, single-track. Data-model + contracts folded in below.

---

## 1. Principles compliance matrix (AC → clause → CI binding)

| AC | Clause | Where enforced (mechanism, file:fn) |
|---|---|---|
| AC-1 missing SHA → fail | P9, P11 | `check-delivery.sh` :: `git cat-file -e` each `commit_sha` |
| AC-2 inflated delta → fail | P9, P11 | `check-delivery.sh` :: `stamped > recomputed` where recomputed = `nondoc_delta_of_shas` (shared lib) |
| AC-3 honest history passes | P10 | `check-delivery.sh` self-test replays `deliver-delivery-guard` B1–B5 |
| AC-4 active marker + no code → fail | P10 | `check-delivery.sh` :: marker `intends_code` + zero `closed kind:code` → exit 1 |
| AC-5 no marker → exit 0 | P10 | `check-delivery.sh` :: absent marker keeps the skip |
| AC-6 marker at Phase A start | P3 | `bin/delivery-marker-init.sh` (`UserPromptSubmit` hook) writes `.runs/<run>/RUN` on `/deliver` submit — harness layer; `deliver.md` step 0 only *enriches* (§2.4) |
| AC-7 recorded, blocking ack | P5 | `check-preconditions.sh` writes `precond` to marker; `check-delivery.sh` asserts ack |
| AC-8 Stop hook blocks/allows | P3, P6, P9 | `delivery-stop-hook.sh` (exit 2 block / 0 allow) + `hooks/hooks.json` |
| AC-9 rank ordering | P10, P11 | `check-delivery.sh` :: `risk_rank` int non-increasing over closed `kind:code` |
| AC-10 declared ⇒ exercised | P8, P10 | `shellcheck` + per-script self-tests + `check-gate-integrity.sh` proves hook fires |

## 2. Architecture

### 2.1 The core inversion (F-A + F-B)

Closure today is a **self-declared JSON field** the orchestrator writes; F-A makes it a **derivation from git objects**. Two machine facts replace two claims:

```
  claim "code_delta:137"      →  derived  nondoc_delta_of_shas(commit_shas)   [git show --numstat]
  claim "delivery happened"   →  derived  marker.intends_code ∧ ∃ closed kind:code  [.runs/<run>/RUN]
```

Because both derive from state git/harness owns, "closed by word" (prose *or* JSON) becomes inexpressible.

### 2.2 Shared delta function (R1 mitigation — one source of truth)

New sourced lib **`bin/delivery-lib.sh`** (`# shellcheck shell=bash`), used by BOTH `check-delivery.sh` (recompute) and `verify-batch.sh` (stamp), so the two **cannot diverge**:

- `resolve_ledger` / `resolve_marker` — `$TEAM_BOOTSTRAP_RUN` else newest `.runs/*/`.
- `resolve_sha SHA` — `git rev-parse --verify -q "$SHA^{commit}"`; empty ⇒ caller fails (AC-1). Abbrev-safe.
- `nondoc_delta_of_shas "sha1 sha2 …"` — Σ per-commit `git show --numstat` added+deleted on non-doc paths (exclude `*.md *.mdx *.txt docs/* references/* LICENSE CHANGELOG*`). **Per-commit sum, not range-diff** — self-contained (OQ-4) and reproduces the historical stamps (§4).
- `risk_rank_int NAME` — `irreversible→4 run-rate→3 feature→2 doc→1`; unknown/absent ⇒ empty (unconstrained).
- `field_str` / `field_num` — the compact-JSONL extractors (moved here, de-duplicated).

`verify-batch.sh` swaps its inline range-diff loop for `nondoc_delta_of_shas` over the SHAs it is about to stamp ⇒ future batches have `stamped == recomputed` by construction. Historical batches (range-stamped) stay safe under the `>=` tolerance (§4, Catch #1).

### 2.3 `check-delivery.sh` rewrite (F-A, F-B, F-E, F-D-assert)

Ordered logic, per active-run resolution:

1. Resolve marker + ledger. **No marker + no ledger → exit 0** (AC-5, non-delivery session).
2. **F-B fail-closed:** marker `intends_code:true` AND (no ledger OR zero `closed kind:code`) → **exit 1** (AC-4).
3. **F-D assert:** marker has `precond.exit==2 && precond.ack==false` AND ledger has ≥1 announced batch → **exit 1** ("Phase-A deliverability ack not recorded"). (AC-7 machine binding, not prose.)
4. Per `closed kind:code` entry:
   a. every `commit_sha` resolves via `resolve_sha`, else fail (AC-1);
   b. `recomputed = nondoc_delta_of_shas(commit_shas)`; **`stamped > recomputed` → fail** (AC-2, inflation only);
   c. ≥1 resolved commit changed a non-doc file, else fail (a `kind:code` batch whose commits touched only docs).
   d. **commit-to-batch binding (F-2) — enforced ONLY under an active harness marker.** When a marker
      (`source:harness`, §2.4) is present: (i) a `commit_sha` may appear in **at most one** `closed` batch
      (reuse → fail; blocks earning N closures from one real commit), and (ii) each `commit_sha` must be
      reachable from `HEAD` and **not** an ancestor of the marker's baseline commit (recorded in the marker
      at Phase-A start), so a forger cannot cite arbitrary pre-existing history. **Marker-less replay skips
      (d)** — this is why AC-3 still passes: the historical `deliver-delivery-guard` ledger legitimately
      reuses `e6bba5d` across B1+B2 (an artifact of the pre-P2 cumulative-range math), which is honest and
      must not fail. Under an active run the *new* per-batch verify-batch range makes each batch's commits
      disjoint, so honest same-run batches never reuse a SHA. Binding recovers the anchoring OQ-4's
      self-contained recompute otherwise drops, without touching the recompute (a–c) that AC-3 exercises.
5. Preserved from v2.11.0: `code_delta<=0` closed code → fail; announced-then-abandoned → fail; first-batch-must-be-code.
6. **F-E rank ordering:** over closed `kind:code` entries **that declare `risk_rank`**, the rank-int sequence (close order) must be **non-increasing**; an ascent (a lower-rank batch closed before a higher-rank one) → fail (AC-9). Entries without `risk_rank` are unconstrained (backward-compat ⇒ AC-3 history, which has none, still passes).

Exit contract unchanged: `0` clean · `1` violation · `64` bad usage.

### 2.4 Run marker (AC-6) — the machine fact "delivery active", **harness-written**

**The marker must be written by the harness, not by `/deliver` prose** — otherwise absence-of-marker fails *open* for the exact "orchestrator skips the protocol" threat (F-1: the fail-open seam would just move from "no ledger" to "no marker"), and `.runs/` is gitignored so CI cannot backstop it. The spec mandates this (R3: "a SessionStart/PreToolUse safety-net on first Skill call in a deliver context"; US3). Two writers, floor + enrichment:

- **Harness floor — `bin/delivery-marker-init.sh`, a `UserPromptSubmit` hook.** Fires whenever the user submits a prompt; if the prompt invokes the deliver command (matches `commands:deliver` / `/deliver` with an `mvp|full` token), it **ensures** `.runs/<run>/RUN` exists with at least `{"intends_code":true,"source":"harness"}`, deriving `run` from the spec-path arg's dir basename. This is orchestrator-independent: the orchestrator cannot make the gate no-op by skipping a step, because the harness already dropped the marker on `/deliver` submit. `UserPromptSubmit` is the load-bearing mechanism — **grounded at build time (T-hook) against the Claude Code hook contract**; fallback if unavailable: a `PreToolUse` floor on the first `Skill` call plus deliver.md step 0 (documented, not assumed).
- **Orchestrator enrichment — `commands/deliver.md` step 0.** Enriches the floor marker with `pipeline`, `feature`, `precond`. Never the *sole* writer.

```json
{ "run":"delivery-guard-self-starting", "pipeline":"full", "source":"harness",
  "feature":"specs/delivery-guard-self-starting/spec.md", "intends_code":true,
  "baseline_sha":"f104f0b", "precond":{ "exit":0, "items":[], "ack":false } }
```

`baseline_sha` = `HEAD` when the marker is first created (the harness floor records it); it anchors the F-2 (ii) reachable-after-baseline check. The floor writer sets it; enrichment never overwrites it.

A prompt that does not invoke deliver writes no marker (keeps AC-5 skip; no nag). `precond` is stamped by `check-preconditions.sh`; `ack` flips to `true` when `/deliver` records the human acknowledgement — **enforced as presence, not honesty** (§2.6, F-3).

### 2.5 Delivery-aware Stop / SubagentStop hook (F-C, AC-8)

New **`bin/delivery-stop-hook.sh`**, registered under `Stop` AND `SubagentStop` in `hooks/hooks.json`:

- `TEAM_BOOTSTRAP_DELIVERY_GATE=off` → exit 0 (parity with quality-gate escape).
- **No active marker → exit 0** (on-by-default-safe; no-ops every non-delivery session, exactly like `quality-gate.sh` without `AGENTS.md`).
- Active marker AND (an announced-but-unclosed `kind:code` batch exists OR zero `closed kind:code`) → **exit 2** (block) with actionable stderr ("run the pipeline to close batch X, or close the run"). Else exit 0.
- **Exit 2, not 1** (Catch #2 — Claude Code blocks completion on exit 2; `hooks.md:13`). Distinct from `check-delivery.sh`'s exit 1. Shares the *logic* (`resolve_marker`, `resolve_ledger`, the announced/closed scan) via `delivery-lib.sh`, not the exit convention.

### 2.6 `check-preconditions.sh` (F-D, AC-7)

Detection logic unchanged (exit 0/1/2 preserved). Addition: on exit 2 with a marker present, write the advisory into the marker — `precond = { exit:2, items:[…detected advisories…], ack:false }`. The script stays the *detector*; the *block* is machine-enforced by `check-delivery.sh` §2.3 step 3.  Hard blocker (exit 1) unchanged.

**Scope honesty (F-3):** `check-delivery` enforces the **presence** of `ack:true` before batch 1, not its **honesty** — `/deliver` (prose) is what flips `ack`, so an orchestrator could self-clear it. This is the same accepted limit as R4 (rank honesty): enum/flag-constrained + logged for human review, **not** proven. AC-7 therefore guarantees "the deliverability question was recorded and a `precond.exit==2` cannot be silently ignored," **not** "a human truly consented." Stated so AC-7 is not oversold as an honesty gate. Added to spec §Out-of-scope for parity with R4.

## 3. Data model (schemas)

**RUN marker** (`.runs/<run>/RUN`): `run:str, pipeline:enum(mvp|full), feature:str, intends_code:bool, precond:{exit:int, items:str[], ack:bool}`.

**Ledger entry** (`.runs/<run>/batches.jsonl`) — extends v2.11.0 with one **optional** field:

| field | v2.11.0 | this milestone |
|---|---|---|
| id, scope, task_ids, files, gate, kind, status | unchanged | unchanged |
| commit_shas, code_delta, gate_results | stamped by verify-batch | now **derived-and-verified** by check-delivery |
| **`risk_rank`** | — | **new, optional** enum `irreversible\|run-rate\|feature\|doc`; written at Announce |

**Migration:** `risk_rank` is additive + optional. Absent ⇒ unconstrained (no AC-9 enforcement) ⇒ the historical `deliver-delivery-guard` ledger (no risk_rank) still passes (AC-3). No rewrite of existing ledgers.

## 4. R1 regression evidence (executed — pins the plan)

Recompute (`nondoc_delta_of_shas`, per-commit sum) over each historical batch's stamped `commit_shas`:

| batch | commit_shas | recomputed | stamped | verdict (`stamped > recomputed → fail`) |
|---|---|---|---|---|
| B1 | e6bba5d | 144 | 144 | pass (==) |
| B2 | a9b9a8b e6bba5d | 236 | 236 | pass (==) |
| B3 | 377ea38 0b7d409 | **43** | **41** | pass (recompute exceeds stamp by 2 — range-diff vs per-commit-sum) |
| B4 | 4d4a42d | 0 | 0 | pass (doc, exempt) |
| B5 | acd0d11 | 0 | 0 | pass (doc, exempt) |

This is why AC-2 must be `>` not `!=` (Catch #1). Bakes into `check-delivery.sh`'s self-test as the AC-3 fixture.

## 5. Phase / batch decomposition — ordered by load-bearing risk

Vertical slices; each code batch ships a `.sh` change with a live consumer (verify-batch/CI/hooks) + its self-test.

| # | scope | risk_rank | kind | files | AC | gate |
|---|---|---|---|---|---|---|
| **B1** | F-A unforgeable closure + shared delta lib | irreversible (4) | code | `bin/delivery-lib.sh`(new), `bin/check-delivery.sh`, `bin/verify-batch.sh` | AC-1,2,3 | shellcheck; deadbeef fixture now fails; B1–B5 history passes; verify-batch self-test |
| **B2** | F-B fail-closed + **harness-written** marker + F-2 commit-binding | run-rate (3) | code | `bin/delivery-marker-init.sh`(new, `UserPromptSubmit` hook), `hooks/hooks.json`, `bin/check-delivery.sh`, `commands/deliver.md`(enrich) | AC-4,5,6 | shellcheck; harness floor writes marker on `/deliver` (F-4 fixture); marker+no-code→1; no-marker→0; reused-SHA→1 |
| **B3** | F-C delivery-aware Stop/SubagentStop hook | run-rate (3) | code | `bin/delivery-stop-hook.sh`(new), `hooks/hooks.json` | AC-8 | shellcheck; block/allow fixtures; gate-integrity proves it fires against BOTH present- and omitted-marker (AC-10, F-4) |
| **B4** | F-D recorded ack + F-E risk_rank ordering | feature (2) | code | `bin/check-preconditions.sh`, `bin/check-delivery.sh` | AC-7,9 | shellcheck; ack-pending→1; rank-ascent→1 fixtures |
| **B5** | docs + version + ADR | doc (1) | doc | `references/enforcement.md`, `failure-policy.md`, `hooks.md`, `commands/deliver.md`, `VERSION`, `CHANGELOG.md`, `docs/adr/0002-*.md` | AC-10(docs) | gate-integrity; review |

Rank sequence **4,3,3,2,1** — non-increasing ⇒ this milestone's own ledger satisfies AC-9 (dogfooding). B5 is `kind:doc`, earns no delivery credit, goes last (`check-delivery` first-batch-must-be-code holds: B1 is code).

**Cross-batch wiring:** `delivery-lib.sh` (B1) is sourced by B2/B3/B4 — B1 lands first. The **harness marker floor** (`delivery-marker-init.sh`, B2) is the machine fact consumed by B3's Stop hook, B4's ack-assert, and B2's own fail-closed + F-2 binding — B2 before B3/B4. The `UserPromptSubmit` mechanism is grounded at B2 build time against the Claude Code hook contract (fallback documented in §2.4). `enforcement.md`'s false "prose cannot flip to closed" line (B5) is only *true to correct* once B1+B2 land.

## 6. ADR candidate (lands in B5)

**ADR-0002 — Closure derives from git-provable repository state, not a self-declared ledger field.** Context: v2.11.0 moved closure from prose to a forgeable JSON line (F-A). Decision: recompute non-doc delta from the stamped `commit_shas` via a shared delta fn; reject unresolvable SHAs and inflated `code_delta`; bind commits to the batch (no cross-batch reuse, reachable-after-baseline) under an active run; a **harness-written** RUN marker (`UserPromptSubmit` floor, not `/deliver` prose) makes "delivery active" a machine fact so gates invert absent-input skip→fail. Consequences: closure unforgeable + self-starting + fail-closed; `risk_rank` honesty (R4) **and `precond.ack` honesty (F-3)** stay advisory/logged, not proven; CI-without-push deferred (OQ-2). **Known edge (F-5):** a history rewrite (rebase/amend) that changes a stored `commit_sha` makes it unresolvable → an honestly-earned batch would false-fail AC-1; acceptable (the ledger records the SHAs as of close), noted here so a future rewrite is understood. **Threat boundary (R-b):** F-2's anchor `baseline_sha` lives in `.runs/<run>/RUN`, an orchestrator-writable file — so binding defends against single-field/casual forgery and raises the bar to *coordinated two-field* tampering (ledger + marker together), **not** against an adversary who rewrites harness state at will. This is the same accepted boundary as R4/F-3 (the F-A premise is that `.runs/` is orchestrator-writable); stated so the guarantee is not overread.

## 7. Risks (delta from spec §Risks — all carried; mitigations bound to mechanism)

R1 divergence → **shared `delivery-lib.sh`** + §4 fixture. R2 nag → strict `intends_code` marker gate + AC-5. **R3 omitted marker → CLOSED by the harness `UserPromptSubmit` floor (§2.4): the marker is written by the harness on `/deliver` submit, not by orchestrator prose, so skipping a step cannot no-op the gate** (this is the F-1 fix — the plan no longer relies on the non-existent CI-sees-`.runs/` backstop). Residual: a run started *without* `/deliver` (direct pipeline call) has no floor — acceptable, that path is not the orchestrated protocol this milestone governs (AC-5). R4 rank gaming → enum + logged (accepted). **F-3 ack honesty → presence-enforced, honesty logged not proven (accepted, parity with R4).** R5 hook loop → actionable message + Claude Code's ~8-block cap. **F-5 history-rewrite false-fail → noted in ADR-0002, accepted.**
