# ADR-0015 — harness-robustness: gates fail on real problems, not on their own fragility

- Status: accepted
- Date: 2026-08-20
- Milestone: harness-robustness (v2.29.0)
- Supersedes/relates: extends the delivery-gate machinery (exec-role-integrity, closure-fidelity,
  pipeline-integrity-hardening); ADR-0006/0008 forgeability ceilings unchanged.

## Context

Two delivery retrospectives — written by the agents that ran `/team-bootstrap:deliver` against live
product repos — showed the gates are correct on a clean greenfield checkout but **fragile on a live,
multi-session, real repository**: they emit *false blocking signals* from their own infrastructure
(shell-glob expansion, SIGPIPE under `pipefail`, JSON-whitespace assumptions, plugin version skew,
stale/foreign run markers), and the Stop-hook amplifies each false block into a full-context idle turn
(the retro estimated ~2–3× token overspend, dominated by a Stop-hook loop of ~20+ near-empty "holding"
turns). Several failures the agents logged as "my mistake" were in fact harness-induced.

## Decision

Two invariants, and seven fixes toward them (delivered red-first → independent review → verify-batch):

1. **No gate blocks on its own infrastructure fragility** (glob/SIGPIPE/whitespace/skew/stale-marker).
   Fail-closed stays fail-closed for a *real* delivery gap; it must not fire on a mis-read of its own
   state.
2. **A repeated identical block costs one turn, not twenty.**

- **WS-1 (glob-free resolver).** `resolve_marker`/`resolve_ledger` resolved the active `.runs/<run>/…`
  via `ls -t .runs/*/RUN`, which does not expand under `set -f` (noglob) — set by `delivery-stop-hook.sh`
  around its untrusted `closed_ids` loop → empty marker → the reviewer floor falsely reads "not met" →
  the Stop-hook false-blocks in a loop. Fixed with a guarded-`set +f` `_newest_run_file` helper that
  preserves `ls -t` recency (a `find` scan would lose it). **Root of the most expensive loop.**
- **WS-2 (Stop-hook de-dup).** A repeated identical block now emits one terse line but **always exits 2**
  (fingerprint = run + block-counters + ledger content-hash, in `reported_blocks`); a ledger-content
  change re-fires the full block. Never turns a block into a pass. The token fix is WS-1 killing the
  *false* block; the de-dup bounds any legitimately-repeated block. *(Arch-review corrected the original
  "race-tolerant floor" framing as a misdiagnosis that would have reverted the spec-169 anti-collapse
  guarantee — dropped.)*
- **WS-3 (SIGPIPE FP).** `check-completeness --final` fed `_ac_in_tests` through `printf … | consumer`;
  the consumer returns on the first match without draining, so `printf` SIGPIPEs (141) under `pipefail`
  on a large `$files` → an asserted AC falsely reported unasserted. Fixed with a herestring.
- **WS-4 (marker reader).** `field_in_obj` matched only the compact `"obj":{`; a pretty-printed
  (`json.dump(indent=2)`) marker made nested `precond`/`preflight`/`enforcement` reads return empty →
  fail-closed gates silently skipped. Now whitespace/newline-tolerant.
- **WS-5 (tracked-`.runs/`).** Preflight HARD-fails a target repo that commits `.runs/` (git restores
  stale markers → Sisyphean `rm` → re-block cascade), naming the `git rm -r --cached` remediation.
- **WS-6 (version-skew probe).** Preflight WARNs when `$CLAUDE_PLUGIN_ROOT` (live hooks) and the invoked
  bin resolve to different plugin VERSIONs (the 2.19.1-vs-2.28.0 skew that made `review-types.txt`
  diverge and dispatches go unrecognized).
- **WS-8 (gate-integrity governed waiver).** A run-level `gate_integrity_waiver` (ack/by/reason/expires)
  clears pre-existing green-by-skip / continue-on-error findings the batch did not introduce (the retro's
  hand-stamp-every-batch pain) **without silencing them** (findings still printed); expiry forces
  re-review; CI (no marker) still blocks, so a genuinely disabled gate is never hidden.

## Consequences / retained limits

- The **live hooks run from the cached `$CLAUDE_PLUGIN_ROOT`**, so these fixes take effect on the live
  Stop/UserPromptSubmit hooks only after a **plugin reinstall** at 2.29.0. Within the developing session
  the delivery survived on the WS-1 escape-hatch (`TEAM_BOOTSTRAP_RUN`); fix-verification is valid because
  `run-tests.sh` invokes the repo `bin/` self-tests directly. (This milestone dogfooded — and live-reproduced
  — the very loop it fixes.)
- **Deferred (documented follow-up):** WS-7 characterization red-first (niche; `kind:test` already skips
  red for the common case); WS-2 extras (race/staleness/optional real-evidence stamp beyond the de-dup);
  WS-3 repo-wide SIGPIPE sweep-lint; WS-5 orphan-prune/re-arm (arch-review flagged deletion risk — the
  tracked-`.runs` detection covers the root cause). WS-8 is the governed-waiver mechanism, **not** full
  per-finding delta-scoping (arch-review flagged the silent-drop risk of the latter).
- The ADR-0006/0008 forgeability ceiling is unchanged: WS-2 does not claim forgery-proofing.
