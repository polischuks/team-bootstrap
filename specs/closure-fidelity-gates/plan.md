# Plan — closure-fidelity-gates

**Source spec:** [spec.md](spec.md) · **Constitution pin:** 1.0.1 · **Pipeline:** full (chosen) ·
**Version target:** 2.18.1 → **2.19.0** (MINOR)

Three new `verify-batch` gates that make *closure* certify fidelity + non-vacuousness, not just
"tests green". Each mirrors the four existing peer gates (`check-tdd`, `check-diff-coverage`,
`check-mutation`, `check-version-sync`): marker-gated ⇒ in-session, git/artifact-grounded, `--self-test`,
`shellcheck --severity=error` clean, and **never a false block on a non-delivery session**. Architecture
is "one more peer gate" — sound by direct precedent (see Architecture + Soundness below).

## Clarifications resolved (Step 3)

Recorded in [spec.md](spec.md) → *Resolutions*. All four OQs `web-verify: no` (in-house bash, no
vendor surface) → adopt RECOMMENDED; no drift catch. Load-bearing consequences for this plan:

- **OQ-1** → A ties strictness to `risk_rank`: `run-rate|irreversible` batch + gaps ⇒ hard-fail even
  with the ack; `feature|doc` ⇒ ack passes.
- **OQ-2** → B's `--final` matches the literal `AC-N` token (default `AC-[0-9]+`, `AcPattern:` overrides)
  in an `is_test_path` file.
- **OQ-3** → `high_risk_seams` recorded to the marker (reviewer handoff field + orchestrator transcribe);
  C enforces *presence of a matching ack*.
- **OQ-4** → seam↔batch intersection is coarse (by file path); accepted, noted.

## Architecture

All three are sourced-`delivery-lib.sh` consumers with the identical skeleton of the peer gates:

```
resolve_marker → intends_code? ──no─→ exit 0 (skip; never a false block)   [AC-6]
       │ yes
       ▼
   read git/artifact state (AGENTS.md fields · tasks.md · spec.md · ledger entry · marker lists)
       │
       ▼
   record machine fact to marker (enforcement_gaps / high_risk_seams)  ── pure-bash rewrite, NO sed
       │                                                                  (items may contain '/')
       ▼
   block unless the recorded ack is present  ── enforcement_ack / seam_acks (parity with precond.ack)
       │
       ▼
   exit 0 pass · exit 1 fail(-closed) · 64 bad usage
```

- **A — `bin/check-enforcement.sh`.** Detects the three unenforceable dimensions by the SAME signal the
  peer gates skip on: no `Test:` ⇒ `red-first` gap; no `Coverage:` ⇒ `diff-coverage` gap; no `Mutation:`
  or `MutationMode:`≠`enforce` ⇒ `mutation` gap. Records `enforcement_gaps:[…]` to the marker. Blocks
  while gaps non-empty ∧ `enforcement_ack`≠true. OQ-1: if the in-flight batch `risk_rank` ∈
  `{run-rate,irreversible}`, gaps hard-fail regardless of the ack.
- **B — `bin/check-completeness.sh`.** Per-batch: slug from marker `feature` → `specs/<slug>/tasks.md`;
  every `task_id` in the in-flight ledger entry must be `[x]`. `--final`: **no** `[ ]` left in tasks.md ∧
  every `AC-N` in `spec.md` appears in ≥1 `is_test_path` file (`AcPattern:` configurable). Reads tasks.md /
  spec.md; **never writes** tasks.md (auto-mark is out of scope).
- **C — `bin/check-seam-ack.sh`.** Reads `high_risk_seams:[{seam,paths}]` from the marker. If the in-flight
  batch's files (git range for the batch window) intersect any flagged seam's paths, a `seam_acks` entry
  naming that seam + a resolvable commit must exist. Missing ack for a touched seam ⇒ fail.

### Shared helpers (delivery-lib.sh)

One definition, added once, reused by A/C (mirrors `record_precond`'s pure-bash marker rewrite):

- `record_marker_list KEY JSON_ITEMS` — insert/replace a top-level `"KEY":[…]` array in the marker via
  pure-bash prefix surgery (no `sed` — seam paths / gap strings contain `/`), preserving the rest.
- `marker_list KEY` — echo the raw JSON array body for a top-level list key (for read-back).
- `json_has_obj_field ARRAYJSON FIELD VALUE` — presence test over an array-of-objects (seam_acks lookup).
- `is_test_path` / `read_test_globs` already exist (F1) — B reuses them verbatim.

### Wiring

- A, B(per-batch), C each added as a `gate` line in `bin/verify-batch.sh` (after `mutation`, before
  `delivery`), so the machine backstop runs them regardless of which roles ran (AC-8).
- B `--final` invoked by `commands/deliver.md` at end-of-run finalization, before "milestone done".
- Marker schema (`enforcement_gaps`, `enforcement_ack`, `high_risk_seams`, `seam_acks`, `AcPattern:`) +
  `references/agents-md-contract.md` + `references/enforcement.md` (new closure-fidelity layer) + ADR.

## Batch decomposition (full; vertical, risk-first)

Each code batch is a vertical slice: **gate script + its verify-batch wiring + its `--self-test` + a
`tests/<gate>.test.sh` (`is_test_path`) carrying its `AC-N` tokens**. Order A→B→C (spec Dependencies);
A first — it directly closes the silent-skip root cause. Docs/version bump last (`kind:doc`).

| Batch | Scope | kind | risk_rank | Gate |
|---|---|---|---|---|
| **B1** | Gate A + shared `record_marker_list`/`marker_list` in delivery-lib + wire + tests | code | feature | E2E: verify-batch self-tests unregressed; A self-test; A fires in verify-batch |
| **B2** | Gate B (per-batch + `--final`) + wire + tests | code | feature | B self-test both modes; wired; verify-batch green |
| **B3** | Gate C + `json_has_obj_field` + `architecture-reviewer` handoff `high_risk_seams` + wire + tests | code | feature | C self-test; wired; **touches a flagged seam → its own `seam_acks` dogfood** |
| **B4** | docs (agents-md-contract, enforcement layer, marker schema), `deliver.md` `--final` wiring + Phase-B ack steps, ADR, CHANGELOG `[2.19.0]`, bump VERSION+plugin.json+marketplace.json×2 | doc | doc | `--final` green on this repo; version-sync green; full sweep |

**Dogfood (this repo, no AGENTS.md tooling):** B1's Gate A, once wired, detects all three gaps on this
very repo. Batches are `feature` rank ⇒ the `enforcement_ack` is permitted (OQ-1). The founder's
`fire all` is the recorded go-ahead; `enforcement_ack:true` is set in the marker with the three gaps
named — "shipped this bash-gate milestone with machine-enforced red-first/coverage/mutation OFF" becomes
a logged decision, exactly the behavior US1 specifies. (Genuine red→green is still done by hand per gate:
`--self-test` written and seen to fail before the gate exists, then to green — shown in each batch report.)

## Compliance matrix (doctrine → AC → verification)

| AC | Constitution | Batch | Verification |
|---|---|---|---|
| AC-1, AC-2 | P6, P10 | B1 | A records `enforcement_gaps`, blocks until ack; all-tooling ⇒ exit 0 (self-test fixtures) |
| AC-3 | P9, P10 | B2 | per-batch task_ids `[x]` in tasks.md (self-test both sides) |
| AC-4 | P9, P10 | B2 | `--final`: no `[ ]` + every AC referenced by a test-path file (self-test) |
| AC-5 | P3, P11 | B3 | seam intersect + `seam_acks` presence, commit-anchored (self-test) |
| AC-6 | P3 | B1–B3 | no active `intends_code` marker ⇒ exit 0 skip, identical to peers (self-test) |
| AC-7 | P8, P10 | B1–B3 | `--self-test` each; `check-gate-integrity` clean; `shellcheck` clean; peer self-tests unregressed |
| AC-8 | P8, P10 | B1–B4 | A/B(per-batch)/C wired into verify-batch; B `--final` in deliver.md; verify-batch on this repo passes (gaps acked) |

## Soundness review (Step 7 — inline, against the architecture baseline)

Reviewed by the orchestrator against [architecture-baseline.md](../../references/architecture-baseline.md)
and the four peer gates rather than a separate agent: the planned architecture is **not novel** — it is a
fourth application of an already-sanctioned pattern (sourced `delivery-lib.sh` consumer; marker-gated
skip; pure-bash marker rewrite; `--self-test`). No new layer, boundary, or dependency direction. Verdict:
**architecture_sound: true.**

**Highest-risk seam (recorded to the marker `high_risk_seams`, consumed by Gate C):**

- **`marker-rewrite`** — paths: `bin/check-enforcement.sh`, `bin/check-seam-ack.sh`,
  `bin/delivery-lib.sh`. A/C mutate `.runs/<run>/RUN` in place. A botched rewrite that clobbers or
  malforms the marker disarms **every** fail-closed gate (the exact v2.18.1 self-disarm class). This seam
  requires a recorded "read it in the shipped code" ack on the batch that touches it (B3 dogfoods C on
  itself). Mitigation: reuse the proven pure-bash `record_precond` surgery (no `sed`; validate the result
  matches `\{*\}` before writing; no-op on absent marker), plus a `--self-test` case asserting the marker
  round-trips and non-target keys survive.

## Best-practices briefs (Step 8 — novelty gate)

**Skipped, logged:** every domain here is in-house and familiar — bash gate scripting against the
existing `delivery-lib.sh` contract, git-plumbing (`merge-base`, `rev-parse`, `show --numstat`), and the
established marker/ledger schema. No unfamiliar tech, no external vendor/SDK, no security-/data-sensitive
surface, no new pattern. Pulling a discovery-research brief would add nothing over the precedent already
in-repo. (Per [best-practices-research.md](../../references/best-practices-research.md): skip familiar/
in-house domains and log the skip.)

## Version-bump verdict (Step 1)

**MINOR → 2.19.0.** New doctrine/enforcement surface (three new gates + marker-schema fields + a new
enforcement layer) — the same class as v2.18.0 (version-sync gate, MINOR). No principle is added,
weakened, or removed, so the **constitution stays at 1.0.1** (the new gates operationalize existing
P6/P9/P10/P3/P11). Enumeration invariants unaffected (gates are not in the role/pipeline/reviewer/
irreversibility tables). Four version locations move together (VERSION, plugin.json, marketplace.json
metadata + plugins[]) — which B1's own dogfood + `check-version-sync` then verify.

## Risks

Carried from [spec.md](spec.md) R1–R5. Plan-level additions:

- **R6 — self-referential marker rewrite (marker-rewrite seam).** A/C write the same marker every gate
  reads. Mitigation: reuse `record_precond`'s exact pure-bash surgery; round-trip `--self-test`; Gate C
  dogfoods the seam ack on B3. (This is the recorded `high_risk_seams` entry.)
- **R7 — dogfood deadlock.** If A hard-required tooling on this repo, this very delivery could not close.
  Mitigation: batches are `feature` rank (OQ-1 ⇒ ack permitted); the ack is recorded + dated + visible in
  post-review, not a silent escape.
